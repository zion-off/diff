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

-- bindings[pane_buf] = { source = Source, line_of = fun(row0): integer|nil }
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
    buf = buf, lines = lines, cache = {}, trees = {},
    ready = false, gen = 0, listeners = {},
  }, Source)
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
  -- Rows below an edit move: drop captures cached by row.
  self.cache = {}
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

function Source:_collect()
  self.trees, self.cache, self.root = {}, {}, nil
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
      if b.source == self then redraw(pane_buf) end
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

--- Captures intersecting 0-based source row `row`, clipped to that row.
--- @return table[]  { start_col, end_col, hl_group, priority }
function Source:captures(row)
  local hit = self.cache[row]
  if hit then return hit end

  local out = {}
  local text = self.lines[row + 1] or ""
  for _, t in ipairs(self.trees) do
    local tsr, _, ter = t.root:range()
    if row >= tsr and row <= ter then
      for id, node, metadata in t.query:iter_captures(t.root, self.buf, row, row + 1) do
        local name = t.query.captures[id]
        if name:sub(1, 1) ~= "_" and not SKIP_CAPTURE[name] then
          local sr, sc, er, ec = node:range()
          local ends_before = er < row or (er == row and ec == 0 and sr < row)
          if sr <= row and not ends_before then
            local scol = sr < row and 0 or sc
            local ecol = er > row and #text or ec
            if ecol > scol then
              local prio = tonumber(metadata.priority or (metadata[id] and metadata[id].priority))
              table.insert(out, { scol, ecol, "@" .. name .. "." .. t.lang, prio or TS_PRIORITY })
            end
          end
        end
      end
    end
  end
  self.cache[row] = out
  return out
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

--- The signature line of the declaration enclosing 1-based `line`, or nil.
--- @return string|nil
function Source:enclosing_decl(line)
  if not (self.ready and self.root and line) then return nil end
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

--- Highlight `pane_buf` from `source`. `line_of(row0)` returns the 0-based
--- source row shown on pane row `row0`, or nil for fillers and separators.
--- Without a tree-sitter parser, falls back to regex syntax on the pane.
function M.bind(pane_buf, source, line_of)
  bindings[pane_buf] = { source = source, line_of = line_of }
  local regex = (not source:has_parser()) and source.ft or ""
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
    return b ~= nil and b.source.ready
  end,
  on_line = function(_, _, buf, row)
    local b = bindings[buf]
    if not b then return end
    local src_row = b.line_of(row)
    if not src_row then return end
    for _, c in ipairs(b.source:captures(src_row)) do
      pcall(vim.api.nvim_buf_set_extmark, buf, NS, row, c[1], {
        end_row = row, end_col = c[2], hl_group = c[3], priority = c[4], ephemeral = true,
      })
    end
  end,
})

return M
