local H = require("helpers")
require("diff.highlights").setup({})
local pr_thread = require("diff.pr_thread")

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

local done = {}
local threads = {
  {
    id = "T1", pending = true, resolved = false, outdated = false,
    can_reply = true, can_resolve = false, can_unresolve = false,
    comments = {
      { id = "C1", author = "me", body = "first line\nsecond line", created_at = "2026-01-01T00:00:00Z",
        pending = true, can_update = true, can_delete = true },
    },
  },
  {
    id = "T2", pending = false, resolved = true, outdated = false,
    can_reply = true, can_resolve = false, can_unresolve = true,
    comments = {
      { id = "C2", author = "bob", body = "settled", created_at = "2026-01-01T00:00:00Z",
        pending = false, can_update = false, can_delete = false },
    },
  },
}

local function open()
  done = {}
  local win = vim.api.nvim_get_current_win()
  pr_thread.open({
    win = win, row = 0, where = "a.lua line 3",
    threads = function() return threads end,
    actions = {
      reply = function(t) table.insert(done, "reply " .. t.id) end,
      set_resolved = function(t, v) table.insert(done, "resolved " .. t.id .. " " .. tostring(v)) end,
      edit = function(_, c) table.insert(done, "edit " .. c.id) end,
      delete = function(c) table.insert(done, "delete " .. c.id) end,
    },
  })
  return pr_thread._state()
end

local function lines(s) return vim.api.nvim_buf_get_lines(s.buf, 0, -1, false) end

local function goto_text(s, text)
  for i, l in ipairs(lines(s)) do
    if l:find(text, 1, true) then
      vim.api.nvim_win_set_cursor(s.win, { i, 0 })
      return i
    end
  end
  error("no line with " .. text)
end

return {
  { "shows each thread's state, comments and the buttons the viewer may use", function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, H.lines(10))
    local s = open()
    local text = table.concat(lines(s), "\n")
    H.ok(text:find("Draft · a.lua line 3", 1, true), text)
    H.ok(text:find("Resolved", 1, true), text)
    H.ok(text:find("  second line", 1, true), "bodies keep their lines")
    H.ok(text:find("Unresolve", 1, true), "a resolved thread can be reopened")
    H.eq(select(2, text:gsub(" Edit ", "")), 1, "only the viewer's own comment can be edited")
    pr_thread.close()
  end },

  { "keys act on the thread and comment under the cursor", function()
    local s = open()
    goto_text(s, "first line")
    feed("e")
    feed("r")
    goto_text(s, "settled")
    feed("R")
    feed("e")
    H.eq(done, { "edit C1", "reply T1", "resolved T2 false" })
    pr_thread.close()
  end },

  { "deleting asks for a second press", function()
    local s = open()
    goto_text(s, "first line")
    feed("x")
    H.eq(done, {})
    H.ok(table.concat(lines(s), "\n"):find("Confirm delete", 1, true), "the button asks to confirm")
    feed("x")
    H.eq(done, { "delete C1" })
    pr_thread.close()
  end },

  { "K, which opens it, closes it, and so does leaving it", function()
    local s = open()
    local footer = vim.inspect(vim.api.nvim_win_get_config(s.win).footer)
    H.ok(footer:find("q close", 1, true), footer)
    feed("K")
    H.eq(pr_thread.is_open(), false, "K closes")
    local behind = vim.api.nvim_get_current_win()
    open()
    vim.api.nvim_set_current_win(behind)
    H.wait(function() return not pr_thread.is_open() end, "leaving closes")
  end },

  { "the editor it opens keeps it open behind; another editor closes it", function()
    local compose = require("diff.compose")
    pr_thread.open({
      win = vim.api.nvim_get_current_win(), row = 0, where = "a.lua line 3",
      threads = function() return threads end,
      actions = { reply = function() compose.open({ title = "Reply", buttons = { { label = "Cancel" } } }) end },
    })
    local s = pr_thread._state()
    goto_text(s, "first line")
    feed("r")
    vim.wait(50)
    H.eq(pr_thread.is_open(), true, "its own reply editor")
    vim.cmd("stopinsert")
    compose.close()
    vim.api.nvim_set_current_win(s.win)
    compose.open({ title = "Review", buttons = { { label = "Cancel" } } })
    H.wait(function() return not pr_thread.is_open() end, "another editor closes it")
    vim.cmd("stopinsert")
    compose.close()
  end },

  { "moving to another comment calls off a delete waiting to be confirmed", function()
    local s = open()
    goto_text(s, "first line")
    feed("x")
    goto_text(s, "settled")
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = s.buf })
    H.ok(not table.concat(lines(s), "\n"):find("Confirm delete", 1, true), "back to Delete")
    goto_text(s, "first line")
    feed("x")
    H.eq(done, {}, "the first press asks again")
    pr_thread.close()
  end },

  { "opening with no threads opens nothing", function()
    pr_thread.open({ win = vim.api.nvim_get_current_win(), row = 0, threads = function() return {} end, actions = {} })
    H.eq(pr_thread.is_open(), false)
  end },

  { "closes when the line has no threads left", function()
    open()
    local saved = threads
    threads = {}
    vim.api.nvim_exec_autocmds("User", { pattern = "DiffNvimPrChanged" })
    H.eq(pr_thread.is_open(), false)
    threads = saved
  end },
}
