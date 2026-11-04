local H = require("helpers")

vim.o.columns, vim.o.lines = 200, 50
-- As in a normal setup; -u NONE leaves detection off, and the language
-- server starts on the filetype.
vim.cmd("filetype on")

-- src/a.lua: line 4 defines helper(), line 20 old_name(); line 42 (a context
-- line) uses helper, B.util and C.const. The edit inserts a line at 10 and
-- rewrites line 40, which called old_name, so old line 42 is new line 43.
local function a_lines()
  local l = {}
  for i = 1, 60 do l[i] = "local v" .. i .. " = " .. i end
  l[1], l[2], l[3] = 'local B = require("b")', 'local C = require("c")', ""
  l[4], l[5], l[6] = "local function helper()", "  return 1", "end"
  l[20] = "local function old_name(x) return x end"
  l[40] = "local r = old_name(1)"
  l[42] = "local t = helper() + B.util() + C.const"
  return l
end

local function d_lines()
  local l = { "int counter = 0;", "" }
  for i = 3, 30 do l[i] = "int v" .. i .. " = " .. i .. ";" end
  l[22] = "int bump(void) { return counter + 1; }"
  return l
end

local repo = H.repo({
  ["src/a.lua"] = H.text(a_lines()),
  ["src/b.lua"] = "local M = {}\n\nfunction M.util() return 1 end\n\nreturn M\n",
  ["src/c.lua"] = "local M = {}\nM.const = 42\nreturn M\n",
  ["src/d.c"] = H.text(d_lines()),
})
local edited = a_lines()
edited[40] = "local r = helper()"
table.insert(edited, 10, "local inserted = true")
H.write(repo, "src/a.lua", H.text(edited))
H.write(repo, "src/b.lua", "local M = {}\n\nfunction M.util() return 2 end\n\nreturn M\n")
local d_edited = d_lines()
d_edited[20] = "int v20 = 200;"
H.write(repo, "src/d.c", H.text(d_edited))

-- A language server in-process, for lua files only. `answer(params)` gives
-- its definition result and `hover_answer(params)` its hover result; every
-- request of each is recorded.
local requests, answer, delay = {}, nil, 0
local hovers, hover_answer = {}, nil
local attached = {}
local function fake_server()
  local closing, id = false, 0
  return {
    request = function(method, params, callback)
      id = id + 1
      local result
      if method == "initialize" then
        result = { capabilities = { definitionProvider = true, hoverProvider = true, textDocumentSync = 1 } }
      elseif method == "textDocument/definition" then
        table.insert(requests, params)
        result = answer and answer(params) or vim.NIL
      elseif method == "textDocument/hover" then
        table.insert(hovers, params)
        result = hover_answer and hover_answer(params) or vim.NIL
      end
      vim.defer_fn(function() callback(nil, result) end, method == "textDocument/definition" and delay or 0)
      return true, id
    end,
    notify = function(method)
      if method == "exit" then closing = true end
      return true
    end,
    is_closing = function() return closing end,
    terminate = function() closing = true end,
  }
end
vim.api.nvim_create_autocmd("FileType", {
  pattern = "lua",
  callback = function(args)
    vim.lsp.start({ name = "fake", cmd = fake_server, root_dir = repo }, { bufnr = args.buf })
  end,
})
vim.api.nvim_create_autocmd("LspAttach", {
  callback = function(args) attached[vim.api.nvim_buf_get_name(args.buf)] = true end,
})

local function location(path, line, col)
  local pos = { line = line - 1, character = col }
  return { uri = vim.uri_from_fname(repo .. "/" .. path), range = { start = pos, ["end"] = pos } }
end

vim.cmd("cd " .. repo)
require("diff").setup({ context_lines = 3, log_level = os.getenv("DIFF_LOG") or "warn" })
vim.cmd("runtime plugin/diff.lua")

local dv      = require("diff.diff_view")
local sidebar = require("diff.sidebar")
local fp      = require("diff.file_panel")
local lsp     = require("diff.lsp")
local S       = dv._state

local function press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

local function open_file(name)
  H.wait(function()
    for i, l in ipairs(vim.api.nvim_buf_get_lines(sidebar._file_buf, 0, -1, false)) do
      if l:find(vim.fn.fnamemodify(name, ":t"), 1, true) then fp.activate_line(i) return true end
    end
  end, name .. " in panel")
  H.wait(function() return S().layout and S().source.path == name end, "diff of " .. name)
end

--- Row of the pane showing `line` of `side`, or nil when it is not shown.
local function row_of(side, line)
  for i, it in ipairs(S().layout.items) do
    local row = it.row and S().model.rows[it.row]
    if row and row[side] == line then return i end
  end
end

--- Put the cursor of `side`'s pane on `line`, on the first `word` in it.
local function cursor_on(side, line, word)
  local win = S().panes[side]
  vim.api.nvim_set_current_win(win)
  local text = S().model[side].lines[line]
  vim.api.nvim_win_set_cursor(win, { H.ok(row_of(side, line), "line shown"), text:find(word, 1, true) - 1 })
end

local function cursor_at()
  local win = vim.api.nvim_get_current_win()
  local c = vim.api.nvim_win_get_cursor(win)
  return c[1], c[2]
end

local function abs(path) return repo .. "/" .. path end

return {
  { "opening a diff loads no real file and starts no language server", function()
    require("diff").open()
    H.wait(function() return sidebar.is_open() and pcall(vim.api.nvim_buf_get_lines, sidebar._file_buf, 0, -1, false) end)
    open_file("src/a.lua")
    H.eq(S().mode, "split")
    H.eq(vim.fn.bufloaded(abs("src/a.lua")), 0)
    H.eq(next(attached), nil)
  end },

  { "a definition in collapsed context of this file is revealed and jumped to; <C-o> comes back", function()
    H.eq(row_of("new", 4), nil, "line 4 starts hidden")
    answer = function() return location("src/a.lua", 4, 15) end
    cursor_on("new", 43, "helper")
    local from = cursor_at()
    press("gd")
    H.wait(function() return #requests == 1 and row_of("new", 4) and cursor_at() == row_of("new", 4) end, "jump")
    H.eq(requests[1].position.line, 42, "asked about the line in the file on disk")
    H.eq(select(2, cursor_at()), 15)
    H.eq(vim.api.nvim_get_current_win(), S().panes.new)

    local buf = vim.fn.bufnr(abs("src/a.lua"))
    H.eq(vim.fn.bufloaded(buf), 1, "the real file is loaded to ask about it")
    H.eq(vim.bo[buf].buflisted, false, "but not listed")
    H.eq(vim.fn.swapname(buf), "", "and without a swap file another editor would warn about")
    for name in pairs(attached) do H.eq(name, abs("src/a.lua"), "the server attached to the real file only") end

    press("<C-o>")
    H.eq(cursor_at(), row_of("new", 43))
  end },

  { "the old side's context line is asked about at its line on disk", function()
    answer = function() return location("src/a.lua", 4, 15) end
    cursor_on("old", 42, "helper")
    press("gd")
    H.wait(function() return #requests == 2 end, "request")
    H.eq(requests[2].position.line, 42, "old line 42 is new line 43")
    H.wait(function() return vim.api.nvim_get_current_win() == S().panes.new and cursor_at() == row_of("new", 4) end)
    press("<C-o>")
    H.eq(S().source.path, "src/a.lua")
  end },

  { "a definition in another changed file opens that file's diff; <C-o> returns", function()
    answer = function() return location("src/b.lua", 3, 11) end
    cursor_on("new", 43, "util")
    press("gd")
    H.wait(function() return S().source.path == "src/b.lua" and S().layout end, "b.lua opened")
    H.eq({ cursor_at() }, { row_of("new", 3), 11 })
    press("<C-o>")
    H.wait(function() return S().source.path == "src/a.lua" and S().layout end, "back to a.lua")
    H.eq(cursor_at(), row_of("new", 43))
  end },

  { "a definition in an unchanged file is previewed in a float", function()
    answer = function() return location("src/c.lua", 2, 2) end
    cursor_on("new", 43, "const")
    local pane = vim.api.nvim_get_current_win()
    press("gd")
    H.wait(function() return vim.api.nvim_win_get_config(0).relative ~= "" end, "preview")
    H.eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "local M = {}", "M.const = 42", "return M" })
    H.eq({ cursor_at() }, { 2, 2 })
    H.eq(S().source.path, "src/a.lua", "the review stays where it was")
    press("q")
    H.eq(vim.api.nvim_get_current_win(), pane)
  end },

  { "several definitions are offered to pick from", function()
    answer = function() return { location("src/c.lua", 2, 2), location("src/a.lua", 4, 15) } end
    local select = vim.ui.select
    local offered
    vim.ui.select = function(items, opts, on_choice)
      offered = vim.tbl_map(opts.format_item, items)
      on_choice(items[1])
    end
    cursor_on("new", 43, "helper")
    press("gd")
    H.wait(function() return offered ~= nil end, "choice")
    vim.ui.select = select
    H.eq(offered, { "src/a.lua:4", "src/c.lua:2" }, "in file order")
    H.wait(function() return cursor_at() == row_of("new", 4) end)
    press("<C-o>")
  end },

  { "a removed line is searched for in its own side's text", function()
    H.wait(function() return S().sources.old.ready end, "parse")
    local before = #requests
    cursor_on("old", 40, "old_name")
    press("gd")
    H.eq(#requests, before, "the server is not asked about a line it does not have")
    H.eq(vim.api.nvim_get_current_win(), S().panes.old)
    H.eq({ cursor_at() }, { row_of("old", 20), 15 })
    press("<C-o>")
    H.eq(cursor_at(), row_of("old", 40))
  end },

  { "a server that knows of no definition says so as JSON null", function()
    local notify, said = vim.notify, nil
    vim.notify = function(msg) said = msg end
    answer = function() return vim.NIL end
    cursor_on("new", 43, "helper")
    press("gd")
    H.wait(function() return said ~= nil end, "message")
    vim.notify = notify
    H.eq(said, "diff.nvim: no definition found")
  end },

  { "a late answer does not pull focus back from another window", function()
    delay = 200
    answer = function() return location("src/a.lua", 4, 15) end
    cursor_on("new", 43, "helper")
    local from = cursor_at()
    press("gd")
    local panel = vim.fn.bufwinid(sidebar._file_buf)
    H.ok(panel ~= -1, "sidebar window")
    vim.api.nvim_set_current_win(panel)
    vim.wait(400)
    delay = 0
    H.eq(vim.api.nvim_get_current_win(), panel)
    vim.api.nvim_set_current_win(S().panes.new)
    H.eq(cursor_at(), from)
  end },

  { "a definition the shown version does not have is previewed, not misplaced", function()
    local buf = vim.fn.bufnr(abs("src/a.lua"))
    vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "local function unsaved() end" })
    answer = function() return location("src/a.lua", 2, 15) end
    cursor_on("new", 43, "helper")
    press("gd")
    H.wait(function() return vim.api.nvim_win_get_config(0).relative ~= "" end, "preview")
    H.eq(requests[#requests].position.line, 43, "the unsaved line above moves the question down")
    H.eq(vim.api.nvim_get_current_line(), "local function unsaved() end")
    press("q")
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, {})
    vim.bo[buf].modified = false
  end },

  { "an answer for a view that moved on is dropped", function()
    delay = 200
    answer = function() return location("src/a.lua", 4, 15) end
    cursor_on("new", 43, "helper")
    local trail = #S().trail
    press("gd")
    dv.goto_neighbor(1)
    H.wait(function() return S().source.path == "src/b.lua" and S().layout end, "next file")
    vim.wait(400)
    H.eq(S().source.path, "src/b.lua")
    H.eq(#S().trail, trail)
    delay = 0
  end },

  { "with no language server, the search answers, and the next lookup does not wait", function()
    local timeout = lsp.ATTACH_TIMEOUT_MS
    lsp.ATTACH_TIMEOUT_MS = 200
    open_file("src/d.c")
    H.wait(function() return S().sources.new.ready end, "parse")
    cursor_on("new", 22, "counter")
    press("gd")
    H.wait(function() return cursor_at() == row_of("new", 1) end, "search result", 2000)
    H.eq(select(2, cursor_at()), 4)
    press("<C-o>")
    cursor_on("new", 22, "counter")
    press("gd")
    H.eq(cursor_at(), row_of("new", 1), "answered at once")
    lsp.ATTACH_TIMEOUT_MS = timeout
  end },

  { "the unified layout jumps in its one pane", function()
    open_file("src/a.lua")
    dv.set_layout("unified")
    H.eq(S().mode, "unified")
    answer = function() return location("src/a.lua", 4, 15) end
    local win = S().panes.unified
    vim.api.nvim_set_current_win(win)
    local function new_line_at_cursor()
      local it = S().layout.items[cursor_at()]
      return it and it.row and S().model.rows[it.row].new
    end
    local idx
    for i, it in ipairs(S().layout.items) do
      local row = it.row and S().model.rows[it.row]
      if row and row.new == 43 then idx = i end
    end
    vim.api.nvim_win_set_cursor(win, { idx, 10 })
    press("gd")
    H.wait(function() return new_line_at_cursor() == 4 end, "jump in the unified pane")
    H.eq(vim.api.nvim_get_current_win(), win)
    press("<C-o>")
    H.eq(new_line_at_cursor(), 43)
    dv.set_layout("split")
  end },

  { "while previewing another branch, only the text is searched", function()
    local preview_branch = sidebar.preview_branch
    sidebar.preview_branch = function() return "other" end
    H.wait(function() return S().sources.new and S().sources.new.ready end, "parse")
    local before = #requests
    cursor_on("new", 43, "helper")
    press("gd")
    sidebar.preview_branch = preview_branch
    H.eq(#requests, before, "the language server is not asked")
    H.eq({ cursor_at() }, { row_of("new", 4), 15 })
    press("<C-o>")
  end },

  { "K shows the language server's hover in a float; K again moves into it", function()
    open_file("src/a.lua")
    hover_answer = function()
      return { contents = { kind = "markdown", value = "```lua\nfunction helper()\n```\n\nReturns one." } }
    end
    cursor_on("new", 43, "helper")
    local pane = vim.api.nvim_get_current_win()
    press("K")
    local float
    H.wait(function()
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_config(w).relative ~= "" then
          local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false), "\n")
          if text:find("function helper()", 1, true) then float = w return true end
        end
      end
    end, "hover float")
    H.eq(hovers[#hovers].position.line, 42, "asked about the line in the file on disk")
    H.eq(vim.api.nvim_get_current_win(), pane, "the cursor stays in the diff")
    press("K")
    H.wait(function() return vim.api.nvim_get_current_win() == float end, "into the float")
    vim.api.nvim_win_close(float, true)
    vim.api.nvim_set_current_win(pane)
  end },

  { "K says why there is no hover", function()
    local notify, said = vim.notify, nil
    vim.notify = function(msg) said = msg end
    hover_answer = function() return vim.NIL end
    cursor_on("new", 43, "helper")
    press("K")
    H.wait(function() return said ~= nil end, "message")
    H.eq(said, "diff.nvim: no hover information for this symbol")

    said = nil
    local before = #hovers
    cursor_on("old", 40, "old_name")
    press("K")
    H.eq(#hovers, before, "the server is not asked about a line it does not have")
    H.eq(said, "diff.nvim: no hover information (this line is not in the current file)")
    vim.notify = notify
  end },

  { "closing the view unloads the files loaded for lookups, not the user's", function()
    vim.cmd("badd " .. vim.fn.fnameescape(abs("src/b.lua")))
    local mine = vim.fn.bufnr(abs("src/b.lua"))
    vim.fn.bufload(mine)
    H.eq(vim.fn.bufloaded(abs("src/a.lua")), 1)
    dv.close()
    H.eq(vim.fn.bufexists(abs("src/a.lua")), 0)
    H.eq(vim.fn.bufexists(abs("src/d.c")), 0)
    H.eq(vim.fn.bufloaded(mine), 1)
  end },

  { "files are looked up by their exact name, never as a pattern", function()
    H.write(repo, "app/i/page.lua", "return 'i'\n")
    H.write(repo, "app/[id]/page.lua", "return 'id'\n")
    local i = vim.fn.bufadd(abs("app/i/page.lua"))
    vim.fn.bufload(i)
    H.eq(lsp.file_lines(abs("app/[id]/page.lua")), { "return 'id'" })
    vim.api.nvim_buf_delete(i, { force = true })
  end },

  { "no more than MAX_LOADED files stay loaded for questions", function()
    local max, timeout = lsp.MAX_LOADED, lsp.ATTACH_TIMEOUT_MS
    lsp.MAX_LOADED, lsp.ATTACH_TIMEOUT_MS = 1, 100
    local answered = 0
    local function ask(path, lines)
      lsp.hover({ path = abs(path), lines = lines, line = 1, col = 0 }, function() answered = answered + 1 end)
    end
    ask("src/c.lua", { "local M = {}", "M.const = 42", "return M" })
    H.eq(vim.fn.bufloaded(abs("src/c.lua")), 1)
    ask("src/d.c", d_edited)
    H.wait(function() return answered == 2 end, "answers")
    H.eq(vim.fn.bufexists(abs("src/c.lua")), 0, "the least recent one is unloaded")
    H.eq(vim.fn.bufloaded(abs("src/d.c")), 1)
    lsp.release()
    lsp.MAX_LOADED, lsp.ATTACH_TIMEOUT_MS = max, timeout
  end },
}
