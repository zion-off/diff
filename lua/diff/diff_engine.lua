--- diff.nvim — diff model and display layout.
---
--- The model is computed in-process with Neovim's built-in xdiff (vim.diff),
--- so opening a diff needs no `git diff` subprocess and no Lua similarity
--- matching. linematch pairs the lines of a changed region so that modified
--- lines sit side by side.
---
--- Model:
---   rows   — one entry per display row of the fully expanded diff:
---            { old = n|nil, new = n|nil, change = true|nil, block = i|nil }
---            A row with both sides and no `change` is context; a change row
---            with one side missing renders as filler on the other side.
---   blocks — maximal runs of change rows (what ]c / [c and hunk staging act on):
---            { first, last, old_first, old_count, new_first, new_count }
---            first/last are row indices; *_first is the first line of the
---            block on that side (for an empty side, the line it would occupy).
local M = {}

-- linematch is quadratic in the size of a region: measured at ~3 ms for an
-- 80-line region but ~110 ms for a 90+90 line one. Larger regions are paired
-- by position, which is exactly right for the common equal-length rewrite.
M.LINEMATCH_MAX = 80

-- Total linematch work allowed per diff, in old×new lines summed over the
-- regions it runs on (a 20×20 region costs 400). Past it the remaining
-- regions are paired by position: a diff with hundreds of rewritten regions
-- should open promptly rather than pair every one of them perfectly.
M.LINEMATCH_BUDGET = 40000

-- Separators hiding fewer rows than this are not worth collapsing; showing
-- the line costs the same space as the "N hidden lines" marker.
local MIN_COLLAPSE = 2

local function join(lines)
  if #lines == 0 then return "" end
  return table.concat(lines, "\n") .. "\n"
end

local function join_range(lines, first, count)
  local slice = {}
  for i = 1, count do slice[i] = lines[first + i - 1] end
  return join(slice)
end

--- Run linematch on each changed region by itself. Asking vim.diff for
--- linematch on the whole file costs time per region proportional to the file
--- size (1.3 s for 5000 one-line edits in 20k lines); on the region's own
--- lines it costs only the region. A one-line-for-one-line region needs no
--- pairing.
local function linematch_regions(raw, a, b)
  local out, budget = {}, M.LINEMATCH_BUDGET
  for _, h in ipairs(raw) do
    local oc, nc = h[2], h[4]
    local work = oc * nc
    if work > 1 and work <= budget then
      budget = budget - work
      local sub = vim.diff(join_range(a, h[1], oc), join_range(b, h[3], nc), {
        result_type = "indices",
        algorithm   = "histogram",
        linematch   = M.LINEMATCH_MAX,
      }) or {}
      -- Back to file line numbers (an empty side still names the line before
      -- its gap, possibly the line before the region).
      for _, s in ipairs(sub) do
        table.insert(out, { s[1] + h[1] - 1, s[2], s[3] + h[3] - 1, s[4] })
      end
    else
      table.insert(out, h)
    end
  end
  return out
end

--- @param old {lines: string[], eol: boolean}
--- @param new {lines: string[], eol: boolean}
--- @return table model
function M.compute(old, new)
  local a, b = old.lines, new.lines
  local raw = linematch_regions(vim.diff(join(a), join(b), {
    result_type      = "indices",
    algorithm        = "histogram",
    indent_heuristic = true,
  }) or {}, a, b)

  local rows, blocks = {}, {}
  local added, removed = 0, 0
  local o, n = 1, 1
  local block

  local function context_until(old_stop)
    while o < old_stop do
      table.insert(rows, { old = o, new = n })
      o, n = o + 1, n + 1
      block = nil
    end
  end

  for _, h in ipairs(raw) do
    -- vim.diff reports an empty side by the line *before* the gap.
    local oc, nc = h[2], h[4]
    local old_first = oc > 0 and h[1] or h[1] + 1
    local new_first = nc > 0 and h[3] or h[3] + 1

    context_until(old_first)

    if not block then
      block = { first = #rows + 1, old_first = old_first, new_first = new_first, old_count = 0, new_count = 0 }
      table.insert(blocks, block)
    end
    for k = 1, math.max(oc, nc) do
      table.insert(rows, {
        old    = k <= oc and old_first + k - 1 or nil,
        new    = k <= nc and new_first + k - 1 or nil,
        change = true,
        block  = #blocks,
      })
    end
    block.old_count = block.old_count + oc
    block.new_count = block.new_count + nc
    block.last = #rows
    added, removed = added + nc, removed + oc
    o, n = old_first + oc, new_first + nc
  end

  context_until(#a + 1)

  return {
    old     = old,
    new     = new,
    rows    = rows,
    blocks  = blocks,
    added   = added,
    removed = removed,
  }
end

--- Index of the row showing new-side line `line`, built lazily.
local function row_of_new(model, line)
  if not model._row_of_new then
    local map = {}
    for i, row in ipairs(model.rows) do
      if row.new then map[row.new] = i end
    end
    model._row_of_new = map
  end
  return model._row_of_new[line]
end

--- @param model   table
--- @param ctx     integer|nil  context lines around each block; nil shows all
--- @param reveals table[]      expanded ranges, { first, last } in new-side lines
--- @return table layout  { items = { {row = i} | {sep = {first, last}} }, index_of = { [row] = item } }
function M.layout(model, ctx, reveals)
  local rows = model.rows
  local visible

  if ctx == nil or #model.blocks == 0 then
    visible = setmetatable({}, { __index = function() return true end })
  else
    visible = {}
    for _, blk in ipairs(model.blocks) do
      for r = math.max(1, blk.first - ctx), math.min(#rows, blk.last + ctx) do
        visible[r] = true
      end
    end
    for _, range in ipairs(reveals or {}) do
      for line = range[1], range[2] do
        local r = row_of_new(model, line)
        if r then visible[r] = true end
      end
    end
  end

  local items, index_of = {}, {}
  local i = 1
  while i <= #rows do
    if visible[i] then
      table.insert(items, { row = i })
      index_of[i] = #items
      i = i + 1
    else
      local j = i
      while j + 1 <= #rows and not visible[j + 1] do j = j + 1 end
      if j - i + 1 < MIN_COLLAPSE then
        for r = i, j do
          table.insert(items, { row = r })
          index_of[r] = #items
        end
      else
        table.insert(items, { sep = { first = i, last = j } })
      end
      i = j + 1
    end
  end

  return { items = items, index_of = index_of }
end

--- Describe the hidden span of a separator in both files' coordinates.
--- @return {count: integer, old: integer[], new: integer[]}
function M.separator_span(model, sep)
  local first, last = model.rows[sep.first], model.rows[sep.last]
  return {
    count = sep.last - sep.first + 1,
    old   = { first.old, last.old },
    new   = { first.new, last.new },
  }
end

--- Return `reveals` extended to uncover `step` lines at each edge of `sep`,
--- or the whole span when little would remain hidden.
--- @return table[] reveals
function M.reveal(model, reveals, sep, step)
  local out = vim.deepcopy(reveals or {})
  local first, last = sep.first, sep.last
  local new_of = function(r) return model.rows[r].new end
  if last - first + 1 <= 2 * step + MIN_COLLAPSE then
    table.insert(out, { new_of(first), new_of(last) })
  else
    table.insert(out, { new_of(first), new_of(first + step - 1) })
    table.insert(out, { new_of(last - step + 1), new_of(last) })
  end
  return out
end

--- Map line numbers of one version of a file to the next version, so a cursor
--- or an expanded range follows its content when lines are inserted or removed
--- above it (a formatter adding an import, say). A line inside a rewritten
--- region maps to the same offset within the replacement, clamped to it.
--- @param before string[]
--- @param after  string[]
--- @return fun(line: integer): integer
function M.line_mapper(before, after)
  local hunks = vim.diff(join(before), join(after), { result_type = "indices", algorithm = "histogram" }) or {}
  return function(line)
    local shift = 0
    for _, h in ipairs(hunks) do
      local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
      local a_first = ca > 0 and sa or sa + 1
      local b_first = cb > 0 and sb or sb + 1
      if line < a_first then break end
      if line < a_first + ca then
        return math.max(1, b_first + math.min(line - a_first, math.max(cb - 1, 0)))
      end
      shift = (b_first + cb) - (a_first + ca)
    end
    return math.max(1, line + shift)
  end
end

--- Build a zero-context patch that applies `block` (old side -> new side).
--- Returns nil and a reason when the block cannot be expressed safely.
--- @param model table
--- @param block table
--- @param path  string  Repo-relative path of the file in the index.
--- @return string|nil patch, string|nil err
function M.block_patch(model, block, path)
  local a, b = model.old.lines, model.new.lines
  local oc, nc = block.old_count, block.new_count

  -- A zero-context hunk that ends exactly at a final line lacking its newline
  -- cannot carry the "\ No newline" marker for a line it does not contain.
  local touches_old_eof = oc == 0 and block.old_first > #a and #a > 0 and not model.old.eol
  local touches_new_eof = nc == 0 and block.new_first > #b and #b > 0 and not model.new.eol
  if touches_old_eof or touches_new_eof then
    return nil, "change is next to a final line without a trailing newline; stage the whole file instead"
  end

  local out = {
    "--- a/" .. path,
    "+++ b/" .. path,
    string.format("@@ -%d,%d +%d,%d @@",
      oc > 0 and block.old_first or block.old_first - 1, oc,
      nc > 0 and block.new_first or block.new_first - 1, nc),
  }
  for i = block.old_first, block.old_first + oc - 1 do
    table.insert(out, "-" .. a[i])
    if i == #a and not model.old.eol then table.insert(out, "\\ No newline at end of file") end
  end
  for i = block.new_first, block.new_first + nc - 1 do
    table.insert(out, "+" .. b[i])
    if i == #b and not model.new.eol then table.insert(out, "\\ No newline at end of file") end
  end
  return table.concat(out, "\n") .. "\n", nil
end

return M
