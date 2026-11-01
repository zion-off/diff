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
  { "Ctrl-S sends the text with the first button and closes", function()
    local s = open()
    H.eq(vim.api.nvim_get_current_win(), s.editor, "the editor has focus")
    type_text(s, "Why this?\n\nIt looks off.")
    vim.cmd("stopinsert")
    feed("<C-s>")
    H.eq(sent, { "Why this?\n\nIt looks off." })
    H.eq(compose.is_open(), false)
    H.ok(not vim.api.nvim_win_is_valid(s.bar), "the buttons close with the editor")
  end },

  { "a rejected request keeps the window and the text", function()
    local s = open()
    reply = "Line could not be resolved"
    type_text(s, "draft")
    vim.cmd("stopinsert")
    feed("<C-s>")
    H.eq(compose.is_open(), true)
    H.eq(vim.api.nvim_buf_get_lines(s.editor_buf, 0, -1, false), { "draft" })
    compose.close()
  end },

  { "nothing is sent without text unless the button allows it", function()
    local s = open()
    vim.cmd("stopinsert")
    feed("<C-s>")
    H.eq(sent, {})
    H.eq(compose.is_open(), true)
    compose.close()
    s = open({ buttons = { { label = "Approve", allow_empty = true, run = function(text, done)
      table.insert(sent, text)
      done(nil)
    end } } })
    vim.cmd("stopinsert")
    feed("<C-s>")
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
}
