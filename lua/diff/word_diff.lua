local M = {}

local TOKEN_CAP = 300 -- max tokens per side before capping LCS work

-- ---------------------------------------------------------------------------
-- Tokenize
-- ---------------------------------------------------------------------------

--- Split `s` into tokens: runs matching `word`, whitespace runs, or single
--- other characters, stopping after `max` tokens.
local function split(s, max, word)
  local tokens = {}
  local i = 1
  local len = #s
  max = max or math.huge

  while i <= len and #tokens < max do
    local _, e = s:find(word, i)
    if not e then _, e = s:find("^%s+", i) end
    e = e or i -- a single character (punctuation, etc.)
    tokens[#tokens + 1] = s:sub(i, e)
    i = e + 1
  end

  return tokens
end

--- Split a string into tokens: identifiers (letters, digits and underscores)
--- whole, whitespace runs, or single characters. A changed identifier is
--- marked whole, snake_case or camelCase alike. Bytes of non-ASCII
--- characters count as letters, so a mark never cuts a character in two.
--- @param  s      string
--- @param  max    integer|nil  stop after this many tokens
--- @return string[]
function M.tokenize(s, max)
  return split(s, max, "^[%w_\128-\255]+")
end

-- ---------------------------------------------------------------------------
-- LCS
-- ---------------------------------------------------------------------------

--- Compute the LCS DP table for two token sequences.
--- Returns the 2-D table (1-indexed rows = old tokens, cols = new tokens).
--- @param  old  string[]
--- @param  new  string[]
--- @return number[][]
local function lcs_table(old, new)
  local m = #old
  local n = #new

  -- Use a flat array for speed; index = (i*(n+1)) + j + 1
  local t = {}
  local width = n + 1

  -- Initialize first row and first col to 0
  for i = 0, m do
    t[i * width] = 0
  end
  for j = 0, n do
    t[j] = 0
  end

  for i = 1, m do
    local row_base  = i * width
    local prev_base = (i - 1) * width
    for j = 1, n do
      if old[i] == new[j] then
        t[row_base + j] = (t[prev_base + (j - 1)] or 0) + 1
      else
        local up   = t[prev_base + j] or 0
        local left = t[row_base + (j - 1)] or 0
        t[row_base + j] = up > left and up or left
      end
    end
  end

  return t, m, n, width
end

--- Backtrack through the LCS table and return diff operations.
--- Each op: { type = "common"|"removed"|"added", old_tok, new_tok }
--- @param  t      number[]  flat LCS table
--- @param  old    string[]
--- @param  new    string[]
--- @param  m      number
--- @param  n      number
--- @param  width  number
--- @return table[]
local function backtrack(t, old, new, m, n, width)
  -- Collected end to start, then reversed (inserting at the front is
  -- quadratic).
  local rev = {}
  local i, j = m, n

  while i > 0 and j > 0 do
    if old[i] == new[j] then
      rev[#rev + 1] = { type = "common", old_tok = old[i], new_tok = new[j] }
      i = i - 1
      j = j - 1
    elseif (t[(i - 1) * width + j] or 0) >= (t[i * width + (j - 1)] or 0) then
      rev[#rev + 1] = { type = "removed", old_tok = old[i] }
      i = i - 1
    else
      rev[#rev + 1] = { type = "added", new_tok = new[j] }
      j = j - 1
    end
  end

  while i > 0 do
    rev[#rev + 1] = { type = "removed", old_tok = old[i] }
    i = i - 1
  end

  while j > 0 do
    rev[#rev + 1] = { type = "added", new_tok = new[j] }
    j = j - 1
  end

  local ops = {}
  for k = #rev, 1, -1 do ops[#ops + 1] = rev[k] end
  return ops
end

-- ---------------------------------------------------------------------------
-- similar
-- ---------------------------------------------------------------------------

-- Two lines are alike when at least this share of the longer one, in
-- non-whitespace bytes, is unchanged.
M.SIMILARITY = 0.5

--- Non-whitespace bytes of a token.
local function weight(tok)
  return tok:find("^%s") and 0 or #tok
end

--- Non-whitespace bytes in `tokens`.
local function solid_bytes(tokens)
  local n = 0
  for _, tok in ipairs(tokens) do n = n + weight(tok) end
  return n
end

--- Non-whitespace bytes of the longest common subsequence of two token
--- lists. A shared start and end are part of it and are counted without the
--- table, which keeps two rows over only what lies between.
local function common_bytes(x, y)
  local total, first, mx, my = 0, 1, #x, #y
  while first <= mx and first <= my and x[first] == y[first] do
    total = total + weight(x[first])
    first = first + 1
  end
  while mx >= first and my >= first and x[mx] == y[my] do
    total = total + weight(x[mx])
    mx, my = mx - 1, my - 1
  end
  if mx < first or my < first then return total end

  local prev, cur = {}, {}
  for j = first - 1, my do prev[j] = 0 end
  cur[first - 1] = 0
  for i = first, mx do
    local tok = x[i]
    local w = weight(tok)
    for j = first, my do
      if tok == y[j] then
        cur[j] = prev[j - 1] + w
      else
        local up, left = prev[j], cur[j - 1]
        cur[j] = up > left and up or left
      end
    end
    prev, cur = cur, prev
  end
  return total + prev[my]
end

--- The non-whitespace tokens of a list, counted.
local function bag_of(tokens)
  local bag = {}
  for _, tok in ipairs(tokens) do
    if weight(tok) > 0 then bag[tok] = (bag[tok] or 0) + 1 end
  end
  return bag
end

--- Take the tokens of `tokens` found in `bag` out of it; returns their bytes.
local function take(bag, tokens)
  local n = 0
  for _, tok in ipairs(tokens) do
    local c = bag[tok]
    if c and c > 0 then
      bag[tok] = c - 1
      n = n + #tok
    end
  end
  return n
end

--- An upper bound on common_bytes, in one pass: the non-whitespace tokens the
--- lists share, in any order. Different lines fail on it without the table.
local function shared_bytes(x, y)
  return take(bag_of(x), y)
end

--- Tokens for measuring likeness: split at underscores too, so `user_id` ->
--- `user_name` keeps its `user_`.
local function measure_tokens(s)
  return split(s, TOKEN_CAP, "^[%w\128-\255]+")
end

--- Whether two token lists are alike (see M.similar).
local function alike(old, new)
  local lo, ln = solid_bytes(old), solid_bytes(new)
  local need = M.SIMILARITY * math.max(lo, ln)
  if need == 0 then return true end
  -- The common part is no longer than the shorter line, nor than what the
  -- two share in any order.
  if math.min(lo, ln) < need or shared_bytes(old, new) < need then return false end
  return common_bytes(old, new) >= need
end

--- Whether two lines are versions of one line rather than different lines:
--- at least M.SIMILARITY of the longer one is unchanged.
--- @param  old_line string
--- @param  new_line string
--- @return boolean
function M.similar(old_line, new_line)
  return alike(measure_tokens(old_line), measure_tokens(new_line))
end

-- A line is one piece of a longer one when the lines around it, each made
-- at least this much of what it lacks of the longer line, hold at least
-- this much of that.
M.PIECE = 0.5

--- Whether `old_line` became `new_line`, so that the two belong on one row:
--- they are alike, and the shorter is not one piece of the longer. A line
--- split over several (or several joined into one) is alike to its largest
--- piece, but the lines around that piece are made of the rest of it:
--- `process(` and `)` around the arguments of a call opened up. The lines
--- around an edited line are not, though they may share a `,` or a name.
--- Tokens are counted in any order.
--- @param old_around {before: string|nil, after: string|nil}  lines next to old_line
--- @param new_around {before: string|nil, after: string|nil}  lines next to new_line
--- @return boolean
function M.same_line(old_line, new_line, old_around, new_around)
  local old, new = measure_tokens(old_line), measure_tokens(new_line)
  if not alike(old, new) then return false end
  local whole, piece, around = old, new, new_around
  if solid_bytes(new) > solid_bytes(old) then
    whole, piece, around = new, old, old_around
  end
  -- What of `whole` the piece lacks.
  local rest = bag_of(whole)
  local lacking = solid_bytes(whole) - take(rest, piece)
  if lacking == 0 then return true end
  local found = 0
  for _, line in ipairs({ around.before or "", around.after or "" }) do
    local tokens = measure_tokens(line)
    local trial = {}
    for tok, c in pairs(rest) do trial[tok] = c end
    local n = take(trial, tokens)
    if n > 0 and n >= M.PIECE * solid_bytes(tokens) then
      found, rest = found + n, trial
    end
  end
  return found < M.PIECE * lacking
end

-- ---------------------------------------------------------------------------
-- compute
-- ---------------------------------------------------------------------------

--- Join ranges separated by nothing but whitespace, so a changed phrase is
--- one mark rather than a string of words with unmarked gaps between them.
--- @param ranges table[]  ordered { start_col, end_col }
--- @param line   string   the text the ranges index
--- @return table[]
local function merge_adjacent(ranges, line)
  local out = {}
  for _, r in ipairs(ranges) do
    local last = out[#out]
    if last and line:sub(last.end_col + 1, r.start_col):match("^%s*$") then
      last.end_col = r.end_col
    else
      out[#out + 1] = { start_col = r.start_col, end_col = r.end_col }
    end
  end
  return out
end

--- Compute word-level diff between two strings.
--- Returns two lists of {start_col, end_col} (0-indexed byte offsets) marking
--- the non-whitespace tokens that differ on each side; changed tokens with
--- only whitespace between them form one range. Lines that are not alike
--- (see M.similar) get no marks: between different lines they would mark
--- nearly everything, and the few tokens left unmarked match by chance.
---
--- @param  old_line string
--- @param  new_line string
--- @return table[], table[]   old_ranges, new_ranges
function M.compute(old_line, new_line)
  if not M.similar(old_line, new_line) then return {}, {} end

  -- Capped to keep the O(m*n) LCS bounded; tokenizing stops there too.
  local old_capped = M.tokenize(old_line, TOKEN_CAP)
  local new_capped = M.tokenize(new_line, TOKEN_CAP)

  local t, m, n, width = lcs_table(old_capped, new_capped)
  local ops = backtrack(t, old_capped, new_capped, m, n, width)

  local old_ranges = {}
  local new_ranges = {}

  -- Walk through the ops while maintaining byte offsets into each string
  local old_byte = 0 -- current byte position in old_line
  local new_byte = 0 -- current byte position in new_line

  for _, op in ipairs(ops) do
    if op.type == "common" then
      old_byte = old_byte + #op.old_tok
      new_byte = new_byte + #op.new_tok

    elseif op.type == "removed" then
      local tok = op.old_tok
      local s   = old_byte
      local e   = old_byte + #tok
      -- Only highlight non-whitespace tokens
      if not tok:match("^%s+$") then
        table.insert(old_ranges, { start_col = s, end_col = e })
      end
      old_byte = e

    elseif op.type == "added" then
      local tok = op.new_tok
      local s   = new_byte
      local e   = new_byte + #tok
      if not tok:match("^%s+$") then
        table.insert(new_ranges, { start_col = s, end_col = e })
      end
      new_byte = e
    end
  end

  return merge_adjacent(old_ranges, old_line), merge_adjacent(new_ranges, new_line)
end

return M
