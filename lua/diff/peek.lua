--- diff.nvim — a float showing a definition in a file the diff is not
--- about, so the reader can look without leaving the review. It is a copy of
--- the file: highlighted, scrollable and read-only, with a key to open the
--- real file in the editor.
local M = {}

local float = require("diff.float")
local log   = require("diff.log").scope("peek")

local MAX_WIDTH  = 100
local MAX_HEIGHT = 15
-- Lines of the file shown above the definition.
local LEAD = 2

local NS = vim.api.nvim_create_namespace("diff_nvim_peek")

local current -- { win, buf } of the open float

local function valid_win(w) return w ~= nil and vim.api.nvim_win_is_valid(w) end

function M.close()
  if current and valid_win(current.win) then pcall(vim.api.nvim_win_close, current.win, true) end
  current = nil
end

--- Highlight `buf` as `path`'s filetype without setting 'filetype', which
--- would run FileType autocmds and could attach a language server to a copy.
local function highlight(buf, path)
  local ok, ft = pcall(vim.filetype.match, { filename = path, buf = buf })
  if not ok or not ft or ft == "" then return end
  local lang = vim.treesitter.language.get_lang(ft) or ft
  if not pcall(vim.treesitter.start, buf, lang) then
    pcall(function() vim.bo[buf].syntax = ft end)
  end
end

--- Show `lines` of the file at `path`, with the cursor on `line`, `col`.
--- @param q table { path: string (absolute), title: string, lines: string[], line: integer, col: integer,
---   open: fun() opens the real file }
function M.open(q)
  M.close()
  local buf = float.scratch("definition-peek", "diff.nvim definition " .. q.title)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, q.lines)
  vim.bo[buf].modifiable = false
  highlight(buf, q.path)
  pcall(vim.api.nvim_buf_set_extmark, buf, NS, q.line - 1, 0, { line_hl_group = "Visual", priority = 50 })

  local width = math.max(20, math.min(MAX_WIDTH, vim.o.columns - 6))
  local height = math.max(3, math.min(MAX_HEIGHT, #q.lines, vim.o.lines - vim.o.cmdheight - 6))
  local win = float.open(buf, true, {
    relative = "cursor", row = 1, col = 0, width = width, height = height,
    title = string.format("%s:%d", q.title, q.line),
  }, { footer = "enter open in editor   q close", options = { wrap = false, cursorline = true, number = true } })
  if not win then return end
  current = { win = win, buf = buf }
  pcall(vim.api.nvim_win_set_cursor, win, { q.line, q.col })
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview({ topline = math.max(1, q.line - LEAD) })
  end)

  local function map(key, fn)
    vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, silent = true, desc = "Definition preview (diff)" })
  end
  map("q", M.close)
  map("<Esc>", M.close)
  map("<CR>", function()
    log.debug("opening %s:%d in the editor from the preview", q.path, q.line)
    M.close()
    q.open()
  end)
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf, once = true,
    callback = function() vim.schedule(function() if current and current.win == win then M.close() end end) end,
  })
  log.debug("previewing %s:%d (%d lines)", q.path, q.line, #q.lines)
end

return M
