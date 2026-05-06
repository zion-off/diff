local M = {}

local TOKEN_CAP = 300 -- max tokens per side before capping LCS work

-- ---------------------------------------------------------------------------
-- Tokenize
-- ---------------------------------------------------------------------------

--- Split a string into tokens: word-char runs, whitespace runs, or single chars.
--- @param  s      string
--- @return string[]
function M.tokenize(s)
  local tokens = {}
  local i = 1
  local len = #s

  while i <= len do
    -- Word characters
    local w_start, w_end = s:find("^%w+", i)
    if w_start then
      table.insert(tokens, s:sub(w_start, w_end))
      i = w_end + 1

    else
      -- Whitespace run
      local sp_start, sp_end = s:find("^%s+", i)
      if sp_start then
        table.insert(tokens, s:sub(sp_start, sp_end))
        i = sp_end + 1

      else
        -- Single character (punctuation, etc.)
        table.insert(tokens, s:sub(i, i))
        i = i + 1
      end
    end
  end

  return tokens
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
  local ops = {}
  local i, j = m, n

  while i > 0 and j > 0 do
    if old[i] == new[j] then
      table.insert(ops, 1, { type = "common", old_tok = old[i], new_tok = new[j] })
      i = i - 1
      j = j - 1
    elseif (t[(i - 1) * width + j] or 0) >= (t[i * width + (j - 1)] or 0) then
      table.insert(ops, 1, { type = "removed", old_tok = old[i] })
      i = i - 1
    else
      table.insert(ops, 1, { type = "added", new_tok = new[j] })
      j = j - 1
    end
  end

  while i > 0 do
    table.insert(ops, 1, { type = "removed", old_tok = old[i] })
    i = i - 1
  end

  while j > 0 do
    table.insert(ops, 1, { type = "added", new_tok = new[j] })
    j = j - 1
  end

  return ops
end

-- ---------------------------------------------------------------------------
-- compute
-- ---------------------------------------------------------------------------

--- Compute word-level diff between two strings.
--- Returns two lists of {start_col, end_col} (0-indexed byte offsets) marking
--- the non-whitespace tokens that differ on each side.
---
--- @param  old_line string
--- @param  new_line string
--- @return table[], table[]   old_ranges, new_ranges
function M.compute(old_line, new_line)
  local old_tokens = M.tokenize(old_line)
  local new_tokens = M.tokenize(new_line)

  -- Cap token lists to keep the O(m*n) LCS bounded
  local function cap_tokens(tokens, cap)
    local out = {}
    for i = 1, math.min(#tokens, cap) do out[i] = tokens[i] end
    return out
  end

  local old_capped = cap_tokens(old_tokens, TOKEN_CAP)
  local new_capped = cap_tokens(new_tokens, TOKEN_CAP)

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

  return old_ranges, new_ranges
end

return M
