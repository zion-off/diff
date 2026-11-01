--- diff.nvim — a floating editor for writing a comment, with a row of
--- buttons under it.
---
---   ╭──────── Comment on a.lua:12 ────────╮
---   │ text, in Markdown, any number of     │   the editor (insert mode)
---   │ lines                                │
---   ╰──────────────────────────────────────╯
---    Add to review   Cancel                     the buttons
---
--- A float may also show a list under the buttons (the review's draft
--- comments), as GitHub puts the review's box above its comments: it scrolls
--- with the usual keys or the mouse wheel, and Shift-Tab from the editor
--- moves into it.
---
--- In normal mode, the `submit_comment` key (Enter) presses the first
--- button, Tab moves to the buttons (where h/l move and Enter presses), and
--- Esc or q cancels. So from insert mode: Esc, then Enter sends, Esc cancels.
--- A button's `run(text, done)` gets the text and calls done(err): on an error
--- the window stays open, text intact, so nothing typed is lost.
local M = {}

local buttons = require("diff.buttons")
local float   = require("diff.float")
local log     = require("diff.log").scope("compose")

local NS = vim.api.nvim_create_namespace("diff_nvim_compose")
local aug = vim.api.nvim_create_augroup("DiffNvimCompose", { clear = true })

local EDITOR_HEIGHT = 8
local MAX_WIDTH = 80

-- The window open now, if any: { editor, editor_buf, bar, bar_buf, list, target, opts,
-- busy = the button whose request is in flight }
local S = nil

local function valid_win(w) return w and vim.api.nvim_win_is_valid(w) end

--- Close the editor and its buttons.
function M.close()
  local s = S
  S = nil
  vim.api.nvim_clear_autocmds({ group = aug })
  if not s then return end
  if s.target then s.target:release() end
  -- Insert mode would otherwise carry over into the window focus returns to.
  if vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then vim.cmd("stopinsert") end
  for _, w in ipairs({ s.bar, s.editor, s.list or false }) do
    if valid_win(w) then pcall(vim.api.nvim_win_close, w, true) end
  end
  if s.opts.on_close then s.opts.on_close() end
end

function M.is_open()
  return S ~= nil
end

local function text_of(s)
  if not vim.api.nvim_buf_is_valid(s.editor_buf) then return "" end
  local lines = vim.api.nvim_buf_get_lines(s.editor_buf, 0, -1, false)
  return vim.trim(table.concat(lines, "\n"))
end

--- Whether the open editor holds text the reader wrote, which closing it would lose.
local function has_unsent_text(s)
  local text = text_of(s)
  return text ~= "" and text ~= vim.trim(s.opts.text or "")
end

local render_bar

local function press(s, item)
  if s.busy or S ~= s then return end
  if not item.run then
    log.debug("%s pressed", item.label)
    M.close()
    return
  end
  if item.confirm and s.confirming ~= item then
    s.confirming = item
    render_bar(s)
    return
  end
  s.confirming = nil
  local text = text_of(s)
  if text == "" and not item.allow_empty then
    vim.notify("diff.nvim: write something first", vim.log.levels.WARN)
    return
  end
  log.debug("%s pressed (%d characters)", item.label, #text)
  s.busy = item
  render_bar(s)
  item.run(text, function(err)
    if S ~= s then return end
    s.busy = nil
    if err then
      vim.notify("diff.nvim: " .. item.label .. " failed: " .. err, vim.log.levels.ERROR)
      render_bar(s)
      return
    end
    if item.keep_open then return render_bar(s) end
    M.close()
  end)
end

render_bar = function(s)
  if not vim.api.nvim_buf_is_valid(s.bar_buf) then return end
  local items = {}
  if s.busy then
    items = { { label = s.busy.busy or (s.busy.label .. "…"), action = function() end } }
  else
    for _, item in ipairs(s.opts.buttons) do
      local confirming = s.confirming == item
      table.insert(items, {
        label = confirming and item.confirm or item.label, style = confirming and "danger" or item.style,
        action = function() press(s, item) end,
      })
    end
  end
  local line, hls, segs = buttons.row(items, "")
  local row_hls = {}
  for _, h in ipairs(hls) do table.insert(row_hls, { 0, h[1], h[2], h[3] }) end
  float.set_lines(s.bar_buf, NS, { line }, row_hls)
  for _, seg in ipairs(segs) do seg.row = 0 end
  s.target:set(segs)
end

--- The key that presses the first button from the editor, or nil when unset.
local function submit_key()
  local key = (require("diff.config").get().keymaps or {}).submit_comment
  return key ~= "" and key or nil
end

local KEY_GLYPHS = { ["<cr>"] = "⏎", ["<enter>"] = "⏎", ["<return>"] = "⏎" }

local function key_label(key)
  if not key then return "" end
  return KEY_GLYPHS[key:lower()] or key
end

local function map(buf, modes, key, fn)
  vim.keymap.set(modes, key, fn, { buffer = buf, nowait = true, silent = true })
end

--- Open the editor, replacing one already open.
--- @param opts table {
---   title   = string,
---   text    = string|nil,     initial text
---   buttons = { { label, style?, allow_empty?, confirm?, busy?, keep_open?, run = fun(text, done)|nil } },
---             busy: what the row says while its request is in flight ("Approving…"),
---             keep_open: the window stays open once it is done,
---             the first is pressed by `submit_comment`; one without `run` cancels; one
---             with `confirm` (a label) asks for a second press first
---   list    = { title, render = fun(width): lines: string[], hls: { row, s, e, hl }[] }|nil,
---             shown under the buttons
---   on_close = fun()|nil }
--- @return boolean  false when an editor with unsent text is open: it is
---   focused instead, so nothing typed is lost
function M.open(opts)
  if S and has_unsent_text(S) then
    log.info("not replacing %q: it holds unsent text", S.opts.title)
    vim.notify("diff.nvim: finish or cancel the comment you are writing first", vim.log.levels.WARN)
    if valid_win(S.editor) then vim.api.nvim_set_current_win(S.editor) end
    return false
  end
  M.close()
  local width = math.max(30, math.min(MAX_WIDTH, vim.o.columns - 8))
  local height = math.min(EDITOR_HEIGHT, math.max(3, vim.o.lines - 8))
  local list_lines, list_hls, list_height = nil, nil, 0
  if opts.list then
    list_lines, list_hls = opts.list.render(width)
    -- Whatever the screen has left over the editor, its buttons and both
    -- borders, up to most of it: the list scrolls for the rest.
    local room = vim.o.lines - vim.o.cmdheight - 1 - (height + 3) - 2
    list_height = math.max(0, math.min(#list_lines, room, math.floor(vim.o.lines * 0.5)))
  end
  local list_rows = list_height > 0 and list_height + 2 or 0
  -- Rows: the editor and its border, the buttons right under it, then the
  -- list and its border.
  local row = math.max(0, math.floor((vim.o.lines - list_rows - height - 3) / 2))
  local col = math.max(0, math.floor((vim.o.columns - width - 2) / 2))

  local editor_buf = float.scratch("compose", "diff.nvim Comment")
  vim.bo[editor_buf].modifiable = true
  vim.bo[editor_buf].filetype = "markdown"
  if opts.text and opts.text ~= "" then
    vim.api.nvim_buf_set_lines(editor_buf, 0, -1, false, vim.split(opts.text, "\n", { plain = true }))
  end
  local submit = submit_key()
  local footer = (submit and string.format("esc %s %s   ", key_label(submit), opts.buttons[1].label:lower()) or "")
    .. "tab buttons   esc esc cancel"
  local editor = float.open(editor_buf, true, {
    relative = "editor", row = row, col = col, width = width, height = height, title = opts.title,
  }, { footer = footer })
  if not editor then return false end
  for k, v in pairs({ wrap = true, linebreak = true, cursorline = false, spell = false }) do
    pcall(vim.api.nvim_set_option_value, k, v, { win = editor })
  end

  local bar_buf = float.scratch("compose-buttons", "diff.nvim Comment buttons")
  local bar_ok, bar = pcall(vim.api.nvim_open_win, bar_buf, false, {
    relative = "editor", row = row + height + 2, col = col + 1, width = width, height = 1,
    style = "minimal", border = "none", focusable = true, zindex = 60,
  })
  if not bar_ok then
    log.warn("cannot open the buttons: %s", tostring(bar))
    pcall(vim.api.nvim_win_close, editor, true)
    return false
  end
  vim.wo[bar].winhighlight = "Normal:DiffNvimPickerNormal"

  local list
  if list_height > 0 then
    local list_buf = float.scratch("compose-list", "diff.nvim Comment list")
    float.set_lines(list_buf, NS, list_lines, list_hls)
    list = float.open(list_buf, false, {
      relative = "editor", row = row + height + 3, col = col, width = width, height = list_height,
      title = opts.list.title,
    }, { footer = "j/k scroll   tab back" })
    if list then
      for k, v in pairs({ wrap = false, cursorline = false }) do
        pcall(vim.api.nvim_set_option_value, k, v, { win = list })
      end
      map(list_buf, "n", "<Tab>", function() if valid_win(editor) then vim.api.nvim_set_current_win(editor) end end)
      map(list_buf, "n", "<S-Tab>", function() if valid_win(editor) then vim.api.nvim_set_current_win(editor) end end)
      map(list_buf, "n", "<Esc>", M.close)
      map(list_buf, "n", "q", M.close)
    end
  end

  local s = { editor = editor, editor_buf = editor_buf, bar = bar, bar_buf = bar_buf, list = list, opts = opts,
    busy = nil }
  s.target = buttons.target(bar_buf, bar)
  S = s
  render_bar(s)

  local function to_editor() if valid_win(s.editor) then vim.api.nvim_set_current_win(s.editor) end end
  local function to_bar()
    if not valid_win(s.bar) then return end
    vim.cmd("stopinsert")
    vim.api.nvim_set_current_win(s.bar)
    pcall(vim.api.nvim_win_set_cursor, s.bar, { 1, 1 })
  end

  if submit then map(editor_buf, "n", submit, function() press(s, opts.buttons[1]) end) end
  map(editor_buf, "n", "<Tab>", to_bar)
  if list then map(editor_buf, "n", "<S-Tab>", function() vim.api.nvim_set_current_win(list) end) end
  map(editor_buf, "n", "<Esc>", M.close)
  map(editor_buf, "n", "q", M.close)

  map(bar_buf, "n", "<CR>", function() s.target:press_cursor() end)
  for _, key in ipairs({ "l", "w", "<Tab>", "<Right>" }) do map(bar_buf, "n", key, function() s.target:step(1) end) end
  for _, key in ipairs({ "h", "b", "<S-Tab>", "<Left>" }) do map(bar_buf, "n", key, function() s.target:step(-1) end) end
  for _, key in ipairs({ "i", "a", "k", "<Up>" }) do map(bar_buf, "n", key, to_editor) end
  map(bar_buf, "n", "<Esc>", M.close)
  map(bar_buf, "n", "q", M.close)

  -- Closing either window some other way (:q) closes the pair.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = aug, pattern = { tostring(editor), tostring(bar), list and tostring(list) or nil }, once = true,
    callback = function() vim.schedule(function() if S == s then M.close() end end) end,
  })

  local last = vim.api.nvim_buf_line_count(editor_buf)
  pcall(vim.api.nvim_win_set_cursor, editor, { last, 0 })
  vim.cmd("startinsert!")
  log.debug("opened the editor: %s", opts.title)
  return true
end

--- The windows of the open editor (tests).
function M._state()
  return S
end

return M
