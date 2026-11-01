local H = require("helpers")
require("diff.highlights").setup({})
local compose = require("diff.compose")
local clickable = require("diff.clickable")

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

local sent, reply
local function open(extra)
  sent, reply = {}, nil
  compose.open(vim.tbl_extend("force", {
    title = "Comment on a.lua:3",
    buttons = {
      { label = "Add to review", style = "primary", run = function(text, done)
        table.insert(sent, text)
        done(reply)
      end },
      { label = "Cancel" },
    },
  }, extra or {}))
  return compose._state()
end

local function type_text(s, text)
  vim.api.nvim_buf_set_lines(s.editor_buf, 0, -1, false, vim.split(text, "\n"))
end

--- Display column of `label` in the button row.
local function col_of(s, label)
  local line = vim.api.nvim_buf_get_lines(s.bar_buf, 0, 1, false)[1]
  return vim.api.nvim_strwidth(line:sub(1, line:find(label, 1, true) - 1)) + 1
end

return {
  { "Enter in normal mode sends the text with the first button and closes", function()
    local s = open()
    H.eq(vim.api.nvim_get_current_win(), s.editor, "the editor has focus")
    type_text(s, "Why this?\n\nIt looks off.")
    vim.cmd("stopinsert")
    feed("<CR>")
    H.eq(sent, { "Why this?\n\nIt looks off." })
    H.eq(compose.is_open(), false)
    H.ok(not vim.api.nvim_win_is_valid(s.bar), "the buttons close with the editor")
  end },

  { "a rejected request keeps the window and the text", function()
    local s = open()
    reply = "Line could not be resolved"
    type_text(s, "draft")
    vim.cmd("stopinsert")
    feed("<CR>")
    H.eq(compose.is_open(), true)
    H.eq(vim.api.nvim_buf_get_lines(s.editor_buf, 0, -1, false), { "draft" })
    compose.close()
  end },

  { "while a request is in flight the row says what it is doing", function()
    local pending_done
    local s = open({ buttons = {
      { label = "Discard drafts", busy = "Discarding drafts…", allow_empty = true, run = function(_, done) pending_done = done end },
      { label = "Approve", run = function(_, done) pending_done = done end },
    } })
    vim.cmd("stopinsert")
    feed("<CR>")
    H.eq(vim.api.nvim_buf_get_lines(s.bar_buf, 0, 1, false)[1], " Discarding drafts… ")
    pending_done(nil)
    s = open({ buttons = { { label = "Approve", allow_empty = true, run = function(_, done) pending_done = done end } } })
    vim.cmd("stopinsert")
    feed("<CR>")
    H.eq(vim.api.nvim_buf_get_lines(s.bar_buf, 0, 1, false)[1], " Approve… ", "a button without its own words")
    pending_done(nil)
  end },

  { "nothing is sent without text unless the button allows it", function()
    local s = open()
    vim.cmd("stopinsert")
    feed("<CR>")
    H.eq(sent, {})
    H.eq(compose.is_open(), true)
    compose.close()
    s = open({ buttons = { { label = "Approve", allow_empty = true, run = function(text, done)
      table.insert(sent, text)
      done(nil)
    end } } })
    vim.cmd("stopinsert")
    feed("<CR>")
    H.eq(sent, { "" })
  end },

  { "buttons answer the mouse: hover tints, a click presses", function()
    local s = open()
    type_text(s, "hi")
    H.ok(clickable.has(s.bar), "the button row is registered")
    local col = col_of(s, "Add to review")
    H.ok(clickable.item_at(s.bar, 1, col), "a button is an item")
    H.eq(clickable.item_at(s.bar, 1, 200), nil, "past the buttons is not")
    clickable.hover(s.bar, 1, col)
    local marks = vim.api.nvim_buf_get_extmarks(s.bar_buf, -1, 0, -1, { details = true })
    local hovered = false
    for _, m in ipairs(marks) do
      if m[4].hl_group == "DiffNvimButtonHover" then hovered = true end
    end
    H.ok(hovered, "hovered button is tinted")
    H.ok(clickable.click(s.bar, 1, col))
    H.eq(sent, { "hi" })
    H.eq(clickable.has(s.bar), false, "unregistered once closed")
  end },

  { "the keyboard reaches the buttons: Tab, then l and Enter", function()
    local s = open()
    vim.cmd("stopinsert")
    feed("<Tab>")
    H.eq(vim.api.nvim_get_current_win(), s.bar)
    feed("l")
    feed("<CR>")
    H.eq(compose.is_open(), false, "Cancel pressed")
    H.eq(sent, {})
  end },

  { "opening another editor keeps one holding unsent text", function()
    local s = open()
    type_text(s, "half a thought")
    H.eq(compose.open({ title = "Review", buttons = { { label = "Cancel" } } }), false)
    H.eq(compose._state(), s, "the first editor stays")
    H.eq(vim.api.nvim_get_current_win(), s.editor, "and is focused")
    type_text(s, "")
    H.eq(compose.open({ title = "Review", buttons = { { label = "Cancel" } } }), true, "an empty one is replaced")
    vim.cmd("stopinsert")
    compose.close()
  end },

  { "a button marked to keep the window open leaves it, and its text, as they were", function()
    local pressed = 0
    compose.open({ title = "Review", buttons = {
      { label = "Open on GitHub", allow_empty = true, keep_open = true, run = function(_, done)
        pressed = pressed + 1
        done(nil)
      end },
    } })
    local s = compose._state()
    type_text(s, "summary")
    H.ok(clickable.click(s.bar, 1, col_of(s, "Open on GitHub")))
    H.eq(pressed, 1)
    H.eq(compose.is_open(), true)
    H.eq(vim.api.nvim_buf_get_lines(s.editor_buf, 0, -1, false), { "summary" })
    vim.cmd("stopinsert")
    compose.close()
  end },

  { "Shift-Tab steps back through the buttons, wrapping at the first", function()
    local s = open()
    vim.cmd("stopinsert")
    feed("<Tab>")
    local first = vim.api.nvim_win_get_cursor(s.bar)[2]
    feed("<Tab>")
    local second = vim.api.nvim_win_get_cursor(s.bar)[2]
    H.ok(second > first, "Tab moved on")
    feed("<S-Tab>")
    H.eq(vim.api.nvim_win_get_cursor(s.bar)[2], first, "back on the first button")
    feed("<S-Tab>")
    H.eq(vim.api.nvim_win_get_cursor(s.bar)[2], second, "wraps to the last")
    compose.close()
  end },

  { "a config that rewrites window highlights on focus changes does not strip the floats' look", function()
    local id = vim.api.nvim_create_autocmd({ "WinEnter", "WinLeave" }, {
      callback = function() vim.wo.winhighlight = "Normal:SomeOtherGroup" vim.wo.cursorline = true end,
    })
    local s = open()
    vim.cmd("stopinsert")
    feed("<Tab>")
    H.eq(vim.api.nvim_get_current_win(), s.bar)
    H.wait(function()
      return vim.wo[s.bar].winhighlight == "Normal:DiffNvimPickerNormal" and vim.wo[s.editor].winhighlight:find("FloatBorder:DiffNvimPickerBorder", 1, true)
    end, "highlights restored")
    H.eq(vim.wo[s.bar].cursorline, false, "no row marked in the button row")
    vim.api.nvim_del_autocmd(id)
    compose.close()
  end },
}
