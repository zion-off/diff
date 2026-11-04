--- diff.nvim — syntax highlighting for diff panes.
---
--- A diff pane shows fragments of a file with gaps (collapsed context) and
--- padding (fillers). Parsing the pane itself would hand tree-sitter text that
--- is not valid code — a fragment that starts inside a block comment or a
--- multi-line string is highlighted as code. Instead each side of the diff is
--- kept whole in a hidden "source" buffer and parsed once (asynchronously when
--- Neovim supports it). A decoration provider maps every visible pane row back
--- to its line in the source and draws that line's captures, so only the rows
--- on screen cost anything and the panes never need a parser of their own.
local M = {}

local log = require("diff.log").scope("syntax")

local NS = vim.api.nvim_create_namespace("diff_nvim_syntax")
local TS_PRIORITY = (vim.hl or vim.highlight).priorities.treesitter

local SKIP_CAPTURE = { spell = true, nospell = true, conceal = true }

-- bindings[pane_buf] = { sources = Source[], line_of = fun(row0): integer|nil, Source|nil }
local bindings = {}

local query_cache = {}
local function highlights_query(lang)
  if query_cache[lang] == nil then
    local ok, q = pcall(vim.treesitter.query.get, lang, "highlights")
    query_cache[lang] = (ok and q) or false
  end
  return query_cache[lang] or nil
end

local function redraw(buf)
  if not pcall(vim.api.nvim__redraw, { buf = buf, valid = false }) then
    pcall(vim.cmd, "redraw")
  end
end

--- Resolve a filetype from the path, consulting buffer content for the
--- extensions Neovim detects by content (.h, .ts, shebang scripts, …).
local function detect_ft(path, buf)
  for _, name in ipairs({ path, vim.fn.fnamemodify(path, ":t") }) do
    local ok, ft = pcall(vim.filetype.match, { buf = buf, filename = name })
    if ok and ft and ft ~= "" then return ft end
  end
  local ext = vim.fn.fnamemodify(path, ":e")
  if ext ~= "" then
    local ok, ft = pcall(vim.filetype.match, { filename = "x." .. ext })
    if ok and ft and ft ~= "" then return ft end
  end
  return ""
end

-- ---------------------------------------------------------------------------
-- Source: one whole side of a diff, parsed
-- ---------------------------------------------------------------------------

local Source = {}
Source.__index = Source

--- @param path  string        Repo-relative path (for filetype detection).
--- @param lines string[]      Full file content.
--- @param ft    string|nil    Known filetype; detected when nil.
function M.source(path, lines, ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype    = "nofile"
  vim.bo[buf].bufhidden  = "hide"
  vim.bo[buf].swapfile   = false
  vim.bo[buf].undolevels = -1
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local self = setmetatable({
    buf = buf, lines = lines, trees = {},
    ready = false, gen = 0, listeners = {},
  }, Source)
  self:_forget_rows()
  self.ft = ft or detect_ft(path, buf)

  if self.ft ~= "" then
    local lang = vim.treesitter.language.get_lang(self.ft) or self.ft
    local ok, parser = pcall(vim.treesitter.get_parser, buf, lang, { error = false })
    if ok and parser then
      self.parser, self.lang = parser, lang
    end
  end
  log.debug("source %s: ft=%s parser=%s lines=%d", path, self.ft, tostring(self.lang), #lines)
  return self
end

--- @return boolean  true when tree-sitter can highlight this source
function Source:has_parser()
  return self.parser ~= nil
end

-- More changed regions than this are applied as one whole-buffer replace.
local MAX_INCREMENTAL_HUNKS = 200

local function join(lines)
  if #lines == 0 then return "" end
  return table.concat(lines, "\n") .. "\n"
end

--- Replace the content in place. Only the changed regions are written, so
--- tree-sitter sees small edits and reparses incrementally instead of
--- parsing the whole file again.
function Source:update(lines)
  local hunks = vim.diff(join(self.lines), join(lines), { result_type = "indices" }) or {}
  if #hunks == 0 then return end
  self.lines = lines
  -- Rows below an edit move.
  self:_forget_rows()
  if #hunks > MAX_INCREMENTAL_HUNKS then
    vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  else
    -- Bottom up, so earlier hunks' line numbers stay valid. An empty side
    -- names the line before its gap.
    for i = #hunks, 1, -1 do
      local h = hunks[i]
      local start = h[2] > 0 and h[1] - 1 or h[1]
      local repl = {}
      for k = 1, h[4] do repl[k] = lines[h[3] + k - 1] end
      vim.api.nvim_buf_set_lines(self.buf, start, start + h[2], false, repl)
    end
  end
  self:parse()
end

--- Register a callback run whenever a parse completes.
function Source:on_ready(fn)
  table.insert(self.listeners, fn)
end

--- Drop everything cached by row: captures and enclosing declarations.
function Source:_forget_rows()
  self.cache, self.decls = {}, {}
end

function Source:_collect()
  self.trees, self.root = {}, nil
  self:_forget_rows()
  local main = self.parser:trees()[1]
  self.root = main and main:root() or nil
  self.parser:for_each_tree(function(tstree, ltree)
    local lang = ltree:lang()
    local query = highlights_query(lang)
    if query then
      table.insert(self.trees, { root = tstree:root(), query = query, lang = lang })
    end
  end)
end

--- Parse the source, then notify listeners and redraw bound panes. On
--- Neovim 0.11+ the parse is time-sliced; small files still finish (and call
--- back) synchronously within the first slice.
function Source:parse()
  if not self.parser then return end
  self.gen = self.gen + 1
  local gen = self.gen
  local elapsed = require("diff.log").timer()

  local function done()
    if self.dead or gen ~= self.gen then return end
    local ok, err = pcall(self._collect, self)
    if not ok then
      log.warn("collecting trees failed: %s", tostring(err))
      return
    end
    self.ready = true
    log.debug("parsed %s (%d lines) in %.1f ms", self.lang, #self.lines, elapsed())
    for pane_buf, b in pairs(bindings) do
      if vim.tbl_contains(b.sources, self) then redraw(pane_buf) end
    end
    for _, fn in ipairs(self.listeners) do pcall(fn) end
  end

  if vim.fn.has("nvim-0.11") == 1 then
    local ok, err = pcall(self.parser.parse, self.parser, true, function(perr)
      if perr then log.warn("parse error: %s", tostring(perr)) end
      done()
    end)
    if not ok then log.warn("async parse failed: %s", tostring(err)) end
  else
    local ok, err = pcall(self.parser.parse, self.parser, true)
    if not ok then log.warn("parse failed: %s", tostring(err)) end
    done()
  end
end

-- Captures are collected for a whole chunk of rows at a time: a query run
-- over one row costs nearly as much as one over sixty, since each run walks
-- down from the root to its range. Chunks are aligned, so what a row gets
-- never depends on which row was asked for first. Where two captures of
-- equal priority overlap, the query may yield them in another order than a
-- query over the row alone would, as Neovim's own highlighter's queries over
-- the window do.
M.CAPTURE_CHUNK = 64

--- Collect the captures of 0-based rows `first` to `last` into the cache,
--- each clipped to its row, tree by tree in the order the query yields them.
function Source:_collect_captures(first, last)
  local cache = self.cache
  for row = first, last do cache[row] = {} end
  for _, t in ipairs(self.trees) do
    local tsr, _, ter = t.root:range()
    local lo, hi = math.max(first, tsr), math.min(last, ter)
    if lo <= hi then
      for id, node, metadata in t.query:iter_captures(t.root, self.buf, lo, hi + 1) do
        local name = t.query.captures[id]
        if name:sub(1, 1) ~= "_" and not SKIP_CAPTURE[name] then
          local sr, sc, er, ec = node:range()
          local prio = tonumber(metadata.priority or (metadata[id] and metadata[id].priority)) or TS_PRIORITY
          local hl = "@" .. name .. "." .. t.lang
          for row = math.max(sr, lo), math.min(er, hi) do
            -- A node ending at the start of a row does not reach into it.
            if not (er == row and ec == 0 and sr < row) then
              local scol = sr < row and 0 or sc
              local ecol = er > row and #(self.lines[row + 1] or "") or ec
              if ecol > scol then
                local out = cache[row]
                out[#out + 1] = { scol, ecol, hl, prio }
              end
            end
          end
        end
      end
    end
  end
end

--- Captures intersecting 0-based source row `row`, clipped to that row.
--- @return table[]  { start_col, end_col, hl_group, priority }
function Source:captures(row)
  local hit = self.cache[row]
  if hit then return hit end
  local first = row - row % M.CAPTURE_CHUNK
  local elapsed = require("diff.log").timer()
  self:_collect_captures(first, first + M.CAPTURE_CHUNK - 1)
  log.trace("captures of %s rows %d-%d in %.1f ms", self.lang, first, first + M.CAPTURE_CHUNK - 1, elapsed())
  return self.cache[row]
end

-- Node-type substrings that qualify as a "section heading" (function, class,
-- etc.). Deliberately excludes variable declarations / assignments so a
-- collapsed region is never labelled with an unrelated `local x = ...` line.
local DECL_INCLUDE = {
  "function", "method", "class", "struct", "interface", "impl",
  "module", "namespace", "constructor", "enum", "trait", "def",
}
local DECL_EXCLUDE = {
  "variable", "field", "assignment", "call", "parameter", "argument",
}

local function node_is_decl(t)
  for _, x in ipairs(DECL_EXCLUDE) do
    if t:find(x, 1, true) then return false end
  end
  for _, x in ipairs(DECL_INCLUDE) do
    if t:find(x, 1, true) then return true end
  end
  return false
end

local function find_decl(self, line)
  local ok, node = pcall(self.root.descendant_for_range, self.root, line - 1, 0, line - 1, 0)
  if not ok then return nil end
  while node do
    if node_is_decl(node:type()) then
      local text = vim.trim(self.lines[node:start() + 1] or ""):gsub("%s*[{(]%s*$", "")
      return text ~= "" and text or nil
    end
    node = node:parent()
  end
  return nil
end

--- The signature line of the declaration enclosing 1-based `line`, or nil.
--- Remembered until the content or its parse changes: every redraw of the
--- hunk headers asks again.
--- @return string|nil
function Source:enclosing_decl(line)
  if not (self.ready and self.root and line) then return nil end
  local hit = self.decls[line]
  if hit == nil then
    hit = find_decl(self, line) or false
    self.decls[line] = hit
  end
  return hit or nil
end

-- ---------------------------------------------------------------------------
-- Local definitions: where a name is declared, found in this side's text
-- alone, for when no language server can answer.
-- ---------------------------------------------------------------------------

local locals_cache = {}
local function locals_query(lang)
  if locals_cache[lang] == nil then
    local ok, q = pcall(vim.treesitter.query.get, lang, "locals")
    locals_cache[lang] = (ok and q) or false
  end
  return locals_cache[lang] or nil
end

--- "def", "scope" or nil for a locals capture. Queries name these
--- `local.definition.*` and `local.scope`, or `definition.*` and `scope`
--- in the older convention.
local function locals_kind(capture)
  if capture:find("^local%.definition") or capture:find("^definition") then return "def" end
  if capture == "local.scope" or capture == "scope" then return "scope" end
end

-- A function, type or the like is visible in the scope around its own
-- body, not only inside it.
local HOISTED = { "function", "method", "type", "macro", "associated", "class" }

local function hoisted(capture)
  for _, kind in ipairs(HOISTED) do
    if capture:find(kind, 1, true) then return true end
  end
  return false
end

--- The innermost scope around `node` (one further out when `hoist`), and how
--- deep it is; nil and 0 for the file itself.
local function scope_of(node, scopes, hoist)
  local scope, n = nil, node:parent()
  while n do
    if scopes[n:id()] then
      if not hoist then scope = n break end
      hoist = false
    end
    n = n:parent()
  end
  local depth = 0
  local p = scope
  while p do depth, p = depth + 1, p:parent() end
  return scope, depth
end

--- Tree-sitter's answer: the declaration of the name at 0-based (`row`,
--- `col`) visible there, preferring the innermost scope, then the nearest
--- declaration above the cursor.
function Source:_scoped_definition(row, col)
  local query = self.ready and self.root and self.lang and locals_query(self.lang)
  if not query then return nil end
  local target = self.root:named_descendant_for_range(row, col, row, col)
  if not target or target:named_child_count() > 0 then return nil end
  local name = vim.treesitter.get_node_text(target, self.buf)
  local defs, scopes = {}, {}
  for id, node in query:iter_captures(self.root, self.buf, 0, -1) do
    local capture = query.captures[id]
    local kind = locals_kind(capture)
    if kind == "scope" then
      scopes[node:id()] = true
    elseif kind == "def" and vim.treesitter.get_node_text(node, self.buf) == name then
      table.insert(defs, { node = node, hoist = hoisted(capture) })
    end
  end
  local best, best_depth, best_above
  for _, def in ipairs(defs) do
    local scope, depth = scope_of(def.node, scopes, def.hoist)
    if not scope or vim.treesitter.is_in_node_range(scope, row, col) then
      local r, c = def.node:start()
      local above = r < row or (r == row and c <= col)
      local better = not best or depth > best_depth
        or (depth == best_depth and above and (not best_above or r > best:start()))
      if better then best, best_depth, best_above = def.node, depth, above end
    end
  end
  if best then return best:start() end
end

--- Vim's own `gd` on this side's text: the first use of the word in the
--- function around it (or the file), found by searching. It leaves the
--- user's search pattern and jump list alone.
function Source:_searched_definition(row, col)
  local pos
  vim.api.nvim_buf_call(self.buf, function()
    local win = vim.api.nvim_get_current_win()
    local saved = vim.api.nvim_win_get_cursor(win)
    pcall(vim.api.nvim_win_set_cursor, win, { row + 1, col })
    if pcall(vim.cmd, "keepjumps keeppatterns normal! gd") then
      local cur = vim.api.nvim_win_get_cursor(win)
      -- Staying on the word searched from finds nothing: it is the first use
      -- of the name, not a declaration.
      local start = vim.fn.matchstrpos(vim.api.nvim_buf_get_lines(self.buf, row, row + 1, false)[1] or "",
        "\\k*\\%" .. (col + 1) .. "c\\k*")[2]
      if cur[1] - 1 ~= row or cur[2] ~= start then pos = { cur[1] - 1, cur[2] } end
    end
    pcall(vim.api.nvim_win_set_cursor, win, saved)
  end)
  if pos then return pos[1], pos[2] end
end

--- Where the name at 0-based (`row`, `col`) is declared in this side, from
--- its text alone: tree-sitter's scopes where the language has them, else a
--- search. Both 0-based; nil when neither finds it.
--- @return integer|nil row, integer|nil col
function Source:local_definition(row, col)
  local elapsed = require("diff.log").timer()
  local how = "scopes"
  local ok, r, c = pcall(self._scoped_definition, self, row, col)
  if not ok then
    log.warn("scoped definition lookup failed: %s", tostring(r))
    r = nil
  end
  if not r then
    how = "search"
    r, c = self:_searched_definition(row, col)
  end
  log.debug("local definition at %d:%d (%s) -> %s by %s in %.1f ms",
    row + 1, col, tostring(self.lang), r and string.format("%d:%d", r + 1, c) or "none", how, elapsed())
  return r, c
end

function Source:destroy()
  self.dead = true
  self.listeners = {}
  if vim.api.nvim_buf_is_valid(self.buf) then
    pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
  end
end

-- ---------------------------------------------------------------------------
-- Pane bindings
-- ---------------------------------------------------------------------------

--- Highlight `pane_buf` from `sources`, the whole sides of the diff it
--- shows. `line_of(row0)` returns the 0-based source row shown on pane row
--- `row0` and the source it is from (the first when omitted), or nil for
--- fillers and separators. Without a tree-sitter parser, falls back to
--- regex syntax on the pane, in the filetype of the first source that has
--- one (an empty side of the diff may not).
--- @param sources table[]  Sources; a unified pane shows lines of both sides
function M.bind(pane_buf, sources, line_of)
  bindings[pane_buf] = { sources = sources, line_of = line_of }
  local regex = ""
  for _, src in ipairs(sources) do
    if src.ft ~= "" then
      regex = (not src:has_parser()) and src.ft or ""
      break
    end
  end
  if vim.bo[pane_buf].syntax ~= regex then
    pcall(function() vim.bo[pane_buf].syntax = regex end)
  end
end

function M.unbind(pane_buf)
  bindings[pane_buf] = nil
  if vim.api.nvim_buf_is_valid(pane_buf) then
    pcall(function() vim.bo[pane_buf].syntax = "" end)
  end
end

vim.api.nvim_set_decoration_provider(NS, {
  on_win = function(_, _, buf)
    local b = bindings[buf]
    if not b then return false end
    for _, src in ipairs(b.sources) do
      if src.ready then return true end
    end
    return false
  end,
  on_line = function(_, _, buf, row)
    local b = bindings[buf]
    if not b then return end
    local src_row, src = b.line_of(row)
    src = src or b.sources[1]
    if not (src_row and src.ready) then return end
    for _, c in ipairs(src:captures(src_row)) do
      pcall(vim.api.nvim_buf_set_extmark, buf, NS, row, c[1], {
        end_row = row, end_col = c[2], hl_group = c[3], priority = c[4], ephemeral = true,
      })
    end
  end,
})

return M
