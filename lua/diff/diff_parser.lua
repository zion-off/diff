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
    -- Hunk header: @@ -a[,b] +c[,d] @@
    local os, oc, ns, nc =
      raw:match("^@@ %-(%d+),(%d+) %+(%d+),(%d+) @@")

    if not os then
      -- Handle omitted counts (@@ -a +c @@ means count=1)
      local os2, ns2 = raw:match("^@@ %-(%d+) %+(%d+) @@")
      if os2 then
        os, oc, ns, nc = os2, "1", ns2, "1"
      end
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
      -- Lines beginning with anything else (e.g. diff/index/---/+++ headers)
      -- outside a hunk are already handled by the hunk-header branch above;
      -- inside a hunk they are silently ignored.
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
-- build_aligned_lines
-- ---------------------------------------------------------------------------

--- Build two parallel display lists (left = old, right = new) of equal length.
---
--- @param  hunks      table[]  Result of M.parse()
--- @param  old_lines  string[] Full content of the old file (1-based)
--- @param  new_lines  string[] Full content of the new file (1-based)
--- @return table[], table[]    left_lines, right_lines
function M.build_aligned_lines(hunks, old_lines, new_lines)
  local left  = {}
  local right = {}

  local old_cursor = 1 -- next old file line not yet emitted
  local new_cursor = 1 -- next new file line not yet emitted

  for _, hunk in ipairs(hunks) do
    -- Emit shared context lines that appear before this hunk
    local context_end_old = hunk.old_start - 1
    while old_cursor <= context_end_old do
      local content = old_lines[old_cursor] or ""
      table.insert(left,  make_entry(content, old_cursor, "context"))
      table.insert(right, make_entry(new_lines[new_cursor] or "", new_cursor, "context"))
      old_cursor = old_cursor + 1
      new_cursor = new_cursor + 1
    end

    -- Walk the hunk lines, grouping consecutive removed/added runs
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
        -- Flush any pending change group before emitting the context pair
        flush()
        table.insert(left,  make_entry(ln.content, ln.old_line, "context"))
        table.insert(right, make_entry(ln.content, ln.new_line, "context"))
        old_cursor = ln.old_line + 1
        new_cursor = ln.new_line + 1

      elseif ln.type == "removed" then
        -- If we already accumulated added lines and now see a removed line,
        -- flush to keep the removed-then-added ordering correct.
        if #added_buf > 0 then
          flush()
        end
        table.insert(removed_buf, ln)
        old_cursor = ln.old_line + 1

      elseif ln.type == "added" then
        table.insert(added_buf, ln)
        new_cursor = ln.new_line + 1
      end
    end

    flush()
  end

  -- Emit any remaining lines after the last hunk
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

  -- Guarantee equal lengths (should always be true, but be defensive)
  while #left < #right do table.insert(left,  filler()) end
  while #right < #left do table.insert(right, filler()) end

  return left, right
end

return M
