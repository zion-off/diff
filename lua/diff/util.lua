local M = {}

-- ---------------------------------------------------------------------------
-- String truncation helpers (multibyte / display-width safe)
-- ---------------------------------------------------------------------------

--- Truncate a string to `max_len` display columns, appending "…" if truncated.
--- Keeps the head of the string. Handles multibyte characters correctly.
--- @param s       string
--- @param max_len integer
--- @return string
function M.trunc(s, max_len)
  if max_len <= 0 then return "" end
  local display_w = vim.fn.strdisplaywidth(s)
  if display_w <= max_len then return s end
  local result = vim.fn.strcharpart(s, 0, max_len - 1)
  while vim.fn.strdisplaywidth(result) >= max_len and #result > 0 do
    result = vim.fn.strcharpart(result, 0, vim.fn.strchars(result) - 1)
  end
  return result .. "…"
end

--- Truncate a string to `max_len` display columns with a MIDDLE ellipsis,
--- preserving both the head and the tail. Ideal for file names so the base
--- name and extension both stay visible (e.g. "Button.compo…nt.tsx").
--- Handles multibyte characters correctly.
--- @param s       string
--- @param max_len integer
--- @return string
function M.trunc_middle(s, max_len)
  if max_len <= 0 then return "" end
  local display_w = vim.fn.strdisplaywidth(s)
  if display_w <= max_len then return s end
  -- Reserve one column for the ellipsis.
  local budget = max_len - 1
  if budget <= 0 then return "…" end

  -- Favor the tail slightly (extensions live there).
  local head_budget = math.floor(budget / 2)
  local tail_budget = budget - head_budget

  -- Build the head up to head_budget display columns.
  local head = vim.fn.strcharpart(s, 0, head_budget)
  while vim.fn.strdisplaywidth(head) > head_budget and #head > 0 do
    head = vim.fn.strcharpart(head, 0, vim.fn.strchars(head) - 1)
  end

  -- Build the tail up to tail_budget display columns, taken from the end.
  local total_chars = vim.fn.strchars(s)
  local tail_start  = total_chars
  local tail        = ""
  while tail_start > 0 do
    local candidate = vim.fn.strcharpart(s, tail_start - 1, total_chars - (tail_start - 1))
    if vim.fn.strdisplaywidth(candidate) > tail_budget then break end
    tail = candidate
    tail_start = tail_start - 1
  end

  return head .. "…" .. tail
end

--- Hard-wrap a single (already display-width-measured) string to at most
--- `width` display columns, breaking between characters. Used as a fallback
--- when a single word is longer than the available width.
--- @param s     string
--- @param width integer
--- @return string[]
local function hard_wrap(s, width)
  local out = {}
  local remaining = s
  while remaining ~= "" do
    if vim.fn.strdisplaywidth(remaining) <= width then
      table.insert(out, remaining)
      break
    end
    local chunk = vim.fn.strcharpart(remaining, 0, width)
    while vim.fn.strdisplaywidth(chunk) > width and #chunk > 0 do
      chunk = vim.fn.strcharpart(chunk, 0, vim.fn.strchars(chunk) - 1)
    end
    if chunk == "" then break end  -- safety: avoid infinite loop
    table.insert(out, chunk)
    remaining = vim.fn.strcharpart(remaining, vim.fn.strchars(chunk))
  end
  return out
end

--- Soft-wrap a string to `width` display columns, breaking at word (space)
--- boundaries. Words longer than `width` are hard-broken. Returns a list of
--- display rows. An empty input yields a single empty row.
--- Multibyte / display-width aware.
--- @param s     string
--- @param width integer
--- @return string[]
function M.wrap(s, width)
  if width <= 0 then return { s } end
  if s == "" then return { "" } end
  if vim.fn.strdisplaywidth(s) <= width then return { s } end

  local rows = {}
  local cur  = ""
  for word in s:gmatch("%S+") do
    if vim.fn.strdisplaywidth(word) > width then
      -- Flush the current line, then hard-break the long word.
      if cur ~= "" then
        table.insert(rows, cur)
        cur = ""
      end
      local pieces = hard_wrap(word, width)
      for i = 1, #pieces - 1 do
        table.insert(rows, pieces[i])
      end
      cur = pieces[#pieces] or ""
    elseif cur == "" then
      cur = word
    elseif vim.fn.strdisplaywidth(cur .. " " .. word) <= width then
      cur = cur .. " " .. word
    else
      table.insert(rows, cur)
      cur = word
    end
  end
  if cur ~= "" then
    table.insert(rows, cur)
  end
  if #rows == 0 then rows = { "" } end
  return rows
end

-- ---------------------------------------------------------------------------
-- File-path tree construction & traversal (shared by file/commit panels)
-- ---------------------------------------------------------------------------

--- Build a directory tree from a flat list of file entries.
--- Each entry must have a `.path` (e.g. "src/components/Button.tsx").
--- Dir nodes:  { name, children = {}, _dirs = {} }
--- File nodes: { name, file = <entry> }
--- @param files table[]   list of entries with a `.path` field
--- @return table          root node ({ children = {}, _dirs = {} })
function M.build_file_tree(files)
  local root = { children = {}, _dirs = {} }
  for _, f in ipairs(files) do
    local parts = {}
    for part in f.path:gmatch("[^/]+") do
      table.insert(parts, part)
    end
    if #parts == 0 then goto continue end
    local node = root
    for i = 1, #parts - 1 do
      local part = parts[i]
      if not node._dirs[part] then
        local dir_node = { name = part, children = {}, _dirs = {} }
        node._dirs[part] = dir_node
        table.insert(node.children, dir_node)
      end
      node = node._dirs[part]
    end
    table.insert(node.children, { name = parts[#parts], file = f })
    ::continue::
  end
  return root
end

--- Return a node's children sorted: directories first, then files,
--- each alphabetically.
--- @param children table[]
--- @return table[]
function M.sort_tree_children(children)
  local out = {}
  for _, c in ipairs(children) do table.insert(out, c) end
  table.sort(out, function(a, b)
    local ad, bd = not a.file, not b.file
    if ad ~= bd then return ad end
    return a.name < b.name
  end)
  return out
end

--- Compact a single-child directory chain starting at `node`, e.g.
--- "src/" + "components/" -> "src/components". Returns the compacted display
--- name and the deepest node in the chain (whose children should be rendered).
--- @param node table   a directory node
--- @return string display_name, table tail_node
function M.compact_dir_chain(node)
  local display = node.name
  local cur     = node
  while true do
    local dir_kids, has_files = {}, false
    for _, c in ipairs(cur.children) do
      if c.file then has_files = true
      else table.insert(dir_kids, c) end
    end
    if not has_files and #dir_kids == 1 then
      cur     = dir_kids[1]
      display = display .. "/" .. cur.name
    else
      break
    end
  end
  return display, cur
end

return M
