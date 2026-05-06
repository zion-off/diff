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

-- ---------------------------------------------------------------------------
-- Similarity-based line matching
-- ---------------------------------------------------------------------------

--- Bigram Jaccard similarity (whitespace-normalised).
--- Returns a score in [0.0, 1.0]; 1.0 for identical stripped strings.
local function similarity(a, b)
  a = a:gsub("%s+", "")
  b = b:gsub("%s+", "")
  if #a == 0 and #b == 0 then return 1.0 end
  -- Exact-match fast path: also handles strings that are too short to produce
  -- bigrams (length 1) where the bigram loop would produce an empty table.
  if a == b then return 1.0 end
  if #a == 0 or #b == 0 then return 0.0 end

  local function bigrams(s)
    local t = {}
    for i = 1, #s - 1 do
      local bg = s:sub(i, i + 1)
      t[bg] = (t[bg] or 0) + 1
    end
    return t
  end

  local ba, bb = bigrams(a), bigrams(b)
  local inter, union_val = 0, 0
  local all = {}
  for k in pairs(ba) do all[k] = true end
  for k in pairs(bb) do all[k] = true end
  for k in pairs(all) do
    local ca = ba[k] or 0
    local cb = bb[k] or 0
    inter     = inter     + math.min(ca, cb)
    union_val = union_val + math.max(ca, cb)
  end
  return union_val == 0 and 0.0 or (inter / union_val)
end

--- Minimum similarity for two lines to be considered a correspondence.
local MATCH_THRESHOLD = 0.25
--- Per-side cap for the DP; groups larger than this fall back to positional.
local MATCH_MAX_DIM   = 100

--- Order-preserving similarity matching via a weighted-LCS DP.
--- Returns a sorted list of {ri, aj} index pairs (1-based), or nil to signal
--- that the caller should fall back to positional pairing (group too large).
local function find_matches(removed, added)
  local nr = #removed
  local na = #added
  if nr == 0 or na == 0 then return {} end
  if nr > MATCH_MAX_DIM or na > MATCH_MAX_DIM then return nil end

  -- Pre-compute similarity matrix to avoid recomputing during DP.
  local sim = {}
  for i = 1, nr do
    sim[i] = {}
    for j = 1, na do
      sim[i][j] = similarity(removed[i].content, added[j].content)
    end
  end

  -- dp[i][j] = best total matched similarity for removed[1..i] and added[1..j].
  local dp = {}
  for i = 0, nr do
    dp[i] = {}
    for j = 0, na do
      dp[i][j] = 0.0
    end
  end

  for i = 1, nr do
    for j = 1, na do
      local best = math.max(dp[i-1][j], dp[i][j-1])
      local s    = sim[i][j]
      if s >= MATCH_THRESHOLD then
        local pair_score = dp[i-1][j-1] + s
        if pair_score > best then best = pair_score end
      end
      dp[i][j] = best
    end
  end

  -- Backtrack from (nr, na) to recover matched pairs in ascending order.
  local matched = {}
  local i, j = nr, na
  while i > 0 and j > 0 do
    local s = sim[i][j]
    -- Check whether the DP arrived here via the (i,j) pair transition.
    -- Use 1e-6 epsilon (not 1e-9): each similarity score is in [0.0, 1.0],
    -- so accumulated sums can reach up to MATCH_MAX_DIM (100.0) when many
    -- lines match.  At magnitude 100, machine epsilon is ~1e-14, so 1e-6
    -- provides ample headroom while remaining far tighter than any meaningful
    -- score difference.
    local took_pair = s >= MATCH_THRESHOLD
      and math.abs(dp[i][j] - (dp[i-1][j-1] + s)) < 1e-6
    if took_pair then
      table.insert(matched, 1, { i, j })
      i = i - 1
      j = j - 1
    elseif dp[i-1][j] >= dp[i][j-1] then
      i = i - 1
    else
      j = j - 1
    end
  end

  return matched
end

--- Emit a block of removed/added lines, placing semantically similar lines
--- on the same row (bigram Jaccard >= MATCH_THRESHOLD) so that modified
--- lines appear side-by-side as in VSCode's diff editor.
--- Unmatched sub-segments between matches are aligned positionally (the
--- original behaviour).  Falls back to purely positional pairing when a side
--- exceeds MATCH_MAX_DIM lines.
local function emit_change_group(removed, added, left, right)
  local nr = #removed
  local na = #added

  local matched = find_matches(removed, added)

  if matched == nil then
    -- Positional fallback for very large groups.
    local len = math.max(nr, na)
    for k = 1, len do
      local l = removed[k]
        and make_entry(removed[k].content, removed[k].old_line, "removed")
        or filler()
      local r = added[k]
        and make_entry(added[k].content, added[k].new_line, "added")
        or filler()
      table.insert(left,  l)
      table.insert(right, r)
    end
    return
  end

  -- Walk matched pairs in order, emitting unmatched sub-segments positionally.
  local r_ptr = 1
  local a_ptr = 1

  for _, pair in ipairs(matched) do
    local ri, aj = pair[1], pair[2]

    -- Positional pairing for unmatched lines in the gap before this match.
    local seg_r   = ri - r_ptr           -- count of unmatched removed in gap
    local seg_a   = aj - a_ptr           -- count of unmatched added in gap
    local seg_len = math.max(seg_r, seg_a)
    for k = 1, seg_len do
      local rem_k = k <= seg_r and removed[r_ptr + k - 1]
      local add_k = k <= seg_a and added[a_ptr + k - 1]
      local l = rem_k
        and make_entry(rem_k.content, rem_k.old_line, "removed")
        or filler()
      local r = add_k
        and make_entry(add_k.content, add_k.new_line, "added")
        or filler()
      table.insert(left,  l)
      table.insert(right, r)
    end

    -- Emit the matched pair on the same row.
    table.insert(left,  make_entry(removed[ri].content, removed[ri].old_line, "removed"))
    table.insert(right, make_entry(added[aj].content,   added[aj].new_line,   "added"))

    r_ptr = ri + 1
    a_ptr = aj + 1
  end

  -- Positional pairing for any trailing unmatched lines.
  local tail_r   = math.max(0, nr - r_ptr + 1)
  local tail_a   = math.max(0, na - a_ptr + 1)
  local tail_len = math.max(tail_r, tail_a)
  for k = 1, tail_len do
    local rem_k = k <= tail_r and removed[r_ptr + k - 1]
    local add_k = k <= tail_a and added[a_ptr + k - 1]
    local l = rem_k
      and make_entry(rem_k.content, rem_k.old_line, "removed")
      or filler()
    local r = add_k
      and make_entry(add_k.content, add_k.new_line, "added")
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
