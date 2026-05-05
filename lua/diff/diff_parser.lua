local M = {}

-- ---------------------------------------------------------------------------
-- parse
-- ---------------------------------------------------------------------------

--- Parse a unified diff string into a list of hunks.
---
--- Each hunk:
---   { old_start, old_count, new_start, new_count,
---     lines = [ { type, old_line, new_line, content } ] }
---
--- @param  diff_text string
--- @return table[]   hunks
function M.parse(diff_text)
  local hunks = {}
  local current_hunk = nil
  local old_line = 0
  local new_line = 0

  for _, raw in ipairs(vim.split(diff_text, "\n", { plain = true })) do
    -- Hunk header: @@ -a[,b] +c[,d] @@  (counts are each optional → default 1)
    local os, oc, ns, nc

    -- Try all four combinations of present/omitted counts
    os, oc, ns, nc = raw:match("^@@ %-(%d+),(%d+) %+(%d+),(%d+) @@")

    if not os then
      local a, b, c = raw:match("^@@ %-(%d+),(%d+) %+(%d+) @@")
      if a then os, oc, ns, nc = a, b, c, "1" end
    end

    if not os then
      local a, b, c = raw:match("^@@ %-(%d+) %+(%d+),(%d+) @@")
      if a then os, oc, ns, nc = a, "1", b, c end
    end

    if not os then
      local a, b = raw:match("^@@ %-(%d+) %+(%d+) @@")
      if a then os, oc, ns, nc = a, "1", b, "1" end
    end

    if os then
      current_hunk = {
        old_start = tonumber(os),
        old_count = tonumber(oc),
        new_start = tonumber(ns),
        new_count = tonumber(nc),
        lines     = {},
      }
      table.insert(hunks, current_hunk)
      old_line = tonumber(os)
      new_line = tonumber(ns)

    elseif current_hunk then
      local first = raw:sub(1, 1)

      if first == "-" then
        table.insert(current_hunk.lines, {
          type     = "removed",
          old_line = old_line,
          new_line = nil,
          content  = raw:sub(2),
        })
        old_line = old_line + 1

      elseif first == "+" then
        table.insert(current_hunk.lines, {
          type     = "added",
          old_line = nil,
          new_line = new_line,
          content  = raw:sub(2),
        })
        new_line = new_line + 1

      elseif first == " " then
        table.insert(current_hunk.lines, {
          type     = "context",
          old_line = old_line,
          new_line = new_line,
          content  = raw:sub(2),
        })
        old_line = old_line + 1
        new_line = new_line + 1

      elseif raw:match("^\\ No newline") then
        -- skip
      end
    end
  end

  return hunks
end

-- ---------------------------------------------------------------------------
-- build_aligned_lines helpers
-- ---------------------------------------------------------------------------

local function make_entry(content, line_num, typ)
  return { content = content, line_num = line_num, type = typ }
end

local function filler()
  return make_entry("", nil, "filler")
end

--- Emit a block of removed/added lines, padding the shorter side with fillers
--- so left and right lists grow by the same amount.
local function emit_change_group(removed, added, left, right)
  local nr = #removed
  local na = #added
  local len = math.max(nr, na)

  for i = 1, len do
    local l = removed[i]
      and make_entry(removed[i].content, removed[i].old_line, "removed")
      or filler()
    local r = added[i]
      and make_entry(added[i].content, added[i].new_line, "added")
      or filler()
    table.insert(left,  l)
    table.insert(right, r)
  end
end

-- ---------------------------------------------------------------------------
-- build_aligned_lines — with context-only mode (collapsed hunks)
-- ---------------------------------------------------------------------------

--- Build two parallel display lists (left = old, right = new) of equal length.
--- When context_lines is provided and >= 0, only shows N lines of context around
--- each hunk, with collapsed separator entries between them.
---
--- @param  hunks         table[]  Result of M.parse()
--- @param  old_lines     string[] Full content of the old file (1-based)
--- @param  new_lines     string[] Full content of the new file (1-based)
--- @param  context_lines number|nil  Lines of context around hunks (nil = show all)
--- @return table[], table[]    left_lines, right_lines
function M.build_aligned_lines(hunks, old_lines, new_lines, context_lines)
  local left  = {}
  local right = {}

  -- If no hunks or context_lines is nil, show the entire file
  if #hunks == 0 or context_lines == nil then
    return M._build_full_aligned(hunks, old_lines, new_lines)
  end

  local ctx = math.max(0, context_lines)

  -- Calculate which old-file lines are "visible" (within context of a hunk)
  -- We work in terms of old-file line numbers for context regions
  local visible_ranges = {} -- { {start_old, end_old, start_new, end_new} }

  for _, hunk in ipairs(hunks) do
    local h_start_old = hunk.old_start
    local h_end_old   = hunk.old_start + hunk.old_count - 1
    local h_start_new = hunk.new_start
    local h_end_new   = hunk.new_start + hunk.new_count - 1

    -- Context above/below this hunk
    local ctx_start_old = math.max(1, h_start_old - ctx)
    local ctx_end_old   = math.min(#old_lines, h_end_old + ctx)
    local ctx_start_new = math.max(1, h_start_new - ctx)
    local ctx_end_new   = math.min(#new_lines, h_end_new + ctx)

    table.insert(visible_ranges, {
      start_old = ctx_start_old,
      end_old   = ctx_end_old,
      start_new = ctx_start_new,
      end_new   = ctx_end_new,
      hunk      = hunk,
    })
  end

  -- Merge overlapping ranges
  local merged = { visible_ranges[1] }
  for i = 2, #visible_ranges do
    local prev = merged[#merged]
    local cur  = visible_ranges[i]
    if cur.start_old <= prev.end_old + 1 then
      prev.end_old = math.max(prev.end_old, cur.end_old)
      prev.end_new = math.max(prev.end_new, cur.end_new)
      -- Merge hunks into a list
      if not prev.hunks then
        prev.hunks = { prev.hunk }
        prev.hunk = nil
      end
      table.insert(prev.hunks, cur.hunk)
    else
      table.insert(merged, cur)
    end
  end

  -- Now build the aligned output, inserting separator entries between ranges
  local old_cursor = 1
  local new_cursor = 1

  for idx, range in ipairs(merged) do
    -- Insert separator if there are hidden lines before this range
    if range.start_old > old_cursor then
      local hidden_old = range.start_old - old_cursor
      local hidden_new = range.start_new - new_cursor
      local hidden = math.max(hidden_old, hidden_new)
      local sep_text = string.format("··· %d hidden lines ···", hidden)
      table.insert(left,  make_entry(sep_text, nil, "separator"))
      table.insert(right, make_entry(sep_text, nil, "separator"))
      old_cursor = range.start_old
      new_cursor = range.start_new
    end

    -- Get the hunks for this range
    local range_hunks = range.hunks or { range.hunk }

    -- Emit context and hunk content for this visible region
    for _, hunk in ipairs(range_hunks) do
      -- Context before hunk (within this range)
      local ctx_end_old = hunk.old_start - 1
      while old_cursor <= ctx_end_old and old_cursor <= range.end_old do
        local content = old_lines[old_cursor] or ""
        table.insert(left,  make_entry(content, old_cursor, "context"))
        table.insert(right, make_entry(new_lines[new_cursor] or "", new_cursor, "context"))
        old_cursor = old_cursor + 1
        new_cursor = new_cursor + 1
      end

      -- Hunk lines
      local removed_buf = {}
      local added_buf   = {}

      local function flush()
        if #removed_buf > 0 or #added_buf > 0 then
          emit_change_group(removed_buf, added_buf, left, right)
          removed_buf = {}
          added_buf   = {}
        end
      end

      for _, ln in ipairs(hunk.lines) do
        if ln.type == "context" then
          flush()
          table.insert(left,  make_entry(ln.content, ln.old_line, "context"))
          table.insert(right, make_entry(ln.content, ln.new_line, "context"))
          old_cursor = ln.old_line + 1
          new_cursor = ln.new_line + 1
        elseif ln.type == "removed" then
          if #added_buf > 0 then flush() end
          table.insert(removed_buf, ln)
          old_cursor = ln.old_line + 1
        elseif ln.type == "added" then
          table.insert(added_buf, ln)
          new_cursor = ln.new_line + 1
        end
      end
      flush()
    end

    -- Context after the last hunk in this range
    while old_cursor <= range.end_old and old_cursor <= #old_lines do
      local content = old_lines[old_cursor] or ""
      table.insert(left,  make_entry(content, old_cursor, "context"))
      table.insert(right, make_entry(new_lines[new_cursor] or "", new_cursor, "context"))
      old_cursor = old_cursor + 1
      new_cursor = new_cursor + 1
    end
  end

  -- Trailing separator if there are lines after the last visible range
  if old_cursor <= #old_lines or new_cursor <= #new_lines then
    local remaining = math.max(#old_lines - old_cursor + 1, #new_lines - new_cursor + 1)
    if remaining > 0 then
      local sep_text = string.format("··· %d hidden lines ···", remaining)
      table.insert(left,  make_entry(sep_text, nil, "separator"))
      table.insert(right, make_entry(sep_text, nil, "separator"))
    end
  end

  -- Guarantee equal lengths
  while #left < #right do table.insert(left,  filler()) end
  while #right < #left do table.insert(right, filler()) end

  return left, right
end

-- ---------------------------------------------------------------------------
-- Full (non-collapsed) aligned lines — original behavior
-- ---------------------------------------------------------------------------

--- @param  hunks      table[]
--- @param  old_lines  string[]
--- @param  new_lines  string[]
--- @return table[], table[]
function M._build_full_aligned(hunks, old_lines, new_lines)
  local left  = {}
  local right = {}

  local old_cursor = 1
  local new_cursor = 1

  for _, hunk in ipairs(hunks) do
    -- Emit shared context lines before this hunk
    local context_end_old = hunk.old_start - 1
    while old_cursor <= context_end_old do
      local content = old_lines[old_cursor] or ""
      table.insert(left,  make_entry(content, old_cursor, "context"))
      table.insert(right, make_entry(new_lines[new_cursor] or "", new_cursor, "context"))
      old_cursor = old_cursor + 1
      new_cursor = new_cursor + 1
    end

    -- Walk the hunk lines
    local removed_buf = {}
    local added_buf   = {}

    local function flush()
      if #removed_buf > 0 or #added_buf > 0 then
        emit_change_group(removed_buf, added_buf, left, right)
        removed_buf = {}
        added_buf   = {}
      end
    end

    for _, ln in ipairs(hunk.lines) do
      if ln.type == "context" then
        flush()
        table.insert(left,  make_entry(ln.content, ln.old_line, "context"))
        table.insert(right, make_entry(ln.content, ln.new_line, "context"))
        old_cursor = ln.old_line + 1
        new_cursor = ln.new_line + 1
      elseif ln.type == "removed" then
        if #added_buf > 0 then flush() end
        table.insert(removed_buf, ln)
        old_cursor = ln.old_line + 1
      elseif ln.type == "added" then
        table.insert(added_buf, ln)
        new_cursor = ln.new_line + 1
      end
    end
    flush()
  end

  -- Emit remaining lines after the last hunk
  local old_total = #old_lines
  local new_total = #new_lines

  while old_cursor <= old_total or new_cursor <= new_total do
    local l = old_cursor <= old_total
      and make_entry(old_lines[old_cursor], old_cursor, "context")
      or filler()
    local r = new_cursor <= new_total
      and make_entry(new_lines[new_cursor], new_cursor, "context")
      or filler()
    table.insert(left,  l)
    table.insert(right, r)
    old_cursor = old_cursor + 1
    new_cursor = new_cursor + 1
  end

  -- Guarantee equal lengths
  while #left < #right do table.insert(left,  filler()) end
  while #right < #left do table.insert(right, filler()) end

  return left, right
end

return M
