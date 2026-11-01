--- diff.nvim — a float showing the comment threads on one diff line, under
--- that line, with buttons for what can be done to them.
---
---    Open · a.lua line 12
---    alice · 2h ago                  Edit  Delete
---     Should this handle nil?
---
---    Reply  Resolve
---
--- Keys act on what the cursor is in: r replies to the thread, R resolves or
--- reopens it, e edits the comment, x deletes it (twice: the first press asks
--- to confirm), Enter presses the button under the cursor, Tab moves between
--- buttons, and q, Esc or K (which opened it) closes it. Moving to another
--- window closes it too, except to the editor it opened for a reply or an
--- edit. The border lists the keys. The float follows the review: when it changes,
--- the threads are read again from `opts.threads()`, and the float closes when
--- none are left.
local M = {}

local buttons = require("diff.buttons")
local util    = require("diff.util")
local log     = require("diff.log").scope("thread")

local NS = vim.api.nvim_create_namespace("diff_nvim_pr_thread")

local MAX_WIDTH = 84
local aug = vim.api.nvim_create_augroup("DiffNvimPrThread", { clear = true })

-- The float open now: { win, buf, target, opts, meta = { [lnum] = { thread, comment } }, confirm = { [id] = true } }
local S = nil

local function valid_win(w) return w and vim.api.nvim_win_is_valid(w) end

function M.close()
  local s = S
  S = nil
  vim.api.nvim_clear_autocmds({ group = aug })
  if not s then return end
  if s.target then s.target:release() end
  if valid_win(s.win) then pcall(vim.api.nvim_win_close, s.win, true) end
end

function M.is_open()
  return S ~= nil
end

function M.win()
  return S and valid_win(S.win) and S.win or nil
end

local function state_of(thread)
  if thread.pending then return "Draft", "DiffNvimThreadDraft" end
  if thread.resolved then return "Resolved", "DiffNvimThreadResolved" end
  if thread.outdated then return "Outdated", "DiffNvimThreadResolved" end
  return "Open", "DiffNvimThreadMarker"
end

--- Build the float's lines for `threads` at `width`.
--- @return string[] lines, table[] hls { row, s, e, hl }, table[] segs, table meta
local function build(s, threads, width)
  local lines, hls, segs, meta = {}, {}, {}, {}
  local a = s.actions
  local function push(text, info)
    table.insert(lines, text)
    meta[#lines] = info
    return #lines - 1
  end
  local function add_buttons(row, row_segs, row_hls)
    for _, h in ipairs(row_hls) do table.insert(hls, { row, h[1], h[2], h[3] }) end
    for _, seg in ipairs(row_segs) do
      seg.row = row
      table.insert(segs, seg)
    end
  end

  for ti, thread in ipairs(threads) do
    if ti > 1 then
      local r = push(string.rep("─", width), nil)
      table.insert(hls, { r, 0, -1, "DiffNvimHint" })
    end
    local label, label_hl = state_of(thread)
    local where = s.opts.where or ""
    local r = push(" " .. label .. (where ~= "" and (" · " .. where) or ""), { thread = thread })
    table.insert(hls, { r, 1, 1 + #label, label_hl })
    table.insert(hls, { r, 1 + #label, -1, "DiffNvimThreadMeta" })

    for _, comment in ipairs(thread.comments) do
      local info = { thread = thread, comment = comment }
      local head = " " .. comment.author .. " · " .. util.relative_time(comment.created_at)
        .. (comment.pending and " · draft" or "")
      local items = {}
      if comment.can_update and a.edit then
        table.insert(items, { label = "Edit", action = function() a.edit(thread, comment) end })
      end
      if comment.can_delete and a.delete then
        local confirming = s.confirm[comment.id]
        table.insert(items, {
          label = confirming and "Confirm delete" or "Delete", style = "danger",
          action = function() M.delete(comment) end,
        })
      end
      local line, row_hls, row_segs = buttons.row(items, "")
      local pad = math.max(2, width - vim.api.nvim_strwidth(head) - vim.api.nvim_strwidth(line))
      local prefix = head .. string.rep(" ", pad)
      line, row_hls, row_segs = buttons.row(items, prefix)
      r = push(#items > 0 and line or head, info)
      table.insert(hls, { r, 1, 1 + #comment.author, "DiffNvimThreadAuthor" })
      table.insert(hls, { r, 1 + #comment.author, #head, "DiffNvimThreadMeta" })
      add_buttons(r, row_segs, row_hls)
      for _, wrapped in ipairs(util.wrap_text(comment.body, width, "  ")) do push(wrapped, info) end
      push("", info)
    end

    local items = {}
    if thread.can_reply and a.reply then
      table.insert(items, { label = "Reply", style = "primary", action = function() a.reply(thread) end })
    end
    if not thread.pending and a.set_resolved then
      if thread.resolved and thread.can_unresolve then
        table.insert(items, { label = "Unresolve", action = function() a.set_resolved(thread, false) end })
      elseif not thread.resolved and thread.can_resolve then
        table.insert(items, { label = "Resolve", action = function() a.set_resolved(thread, true) end })
      end
    end
    if #items > 0 then
      local line, row_hls, row_segs = buttons.row(items, " ")
      r = push(line, { thread = thread })
      add_buttons(r, row_segs, row_hls)
    end
  end
  return lines, hls, segs, meta
end

local function render(s)
  local threads = s.opts.threads()
  if #threads == 0 then
    log.debug("no threads left on the line; closing")
    M.close()
    return
  end
  local width = vim.api.nvim_win_get_width(s.win)
  local lines, hls, segs, meta = build(s, threads, width)
  s.meta = meta
  require("diff.float").set_lines(s.buf, NS, lines, hls)
  s.target:set(segs)
  local max_h = math.max(5, math.floor(vim.o.lines * 0.5))
  pcall(vim.api.nvim_win_set_height, s.win, math.min(#lines, max_h))
end

--- What the cursor is in: { thread, comment|nil }.
local function at_cursor()
  if not (S and valid_win(S.win)) then return nil end
  local lnum = vim.api.nvim_win_get_cursor(S.win)[1]
  for l = lnum, 1, -1 do
    if S.meta[l] then return S.meta[l] end
  end
end

--- Delete `comment`, asking first: the first call marks it to confirm.
function M.delete(comment)
  local s = S
  if not s then return end
  if not s.confirm[comment.id] then
    s.confirm = { [comment.id] = true }
    render(s)
    return
  end
  s.confirm = {}
  log.debug("delete comment %s from the comments float", tostring(comment.id))
  s.actions.delete(comment)
end

--- Screen position for a float of `height` rows next to buffer row `row`
--- of `win`: below the line, or above it when it would not fit below.
local function placement(win, row, height, width)
  local pos = vim.fn.screenpos(win, row + 1, 1)
  local wpos = vim.api.nvim_win_get_position(win)
  local textoff = vim.fn.getwininfo(win)[1].textoff
  local col = math.max(0, math.min(wpos[2] + textoff, vim.o.columns - width - 2))
  if pos.row == 0 then
    return math.floor((vim.o.lines - height) / 2), col
  end
  local below = pos.row -- 0-based row of the screen line after this one
  if below + height + 2 <= vim.o.lines - vim.o.cmdheight - 1 then return below, col end
  return math.max(0, pos.row - 1 - height - 2), col
end

--- @param opts table {
---   win = pane window, row = 0-based buffer row the threads are on,
---   where = string (e.g. "a.lua line 12"),
---   threads = fun(): thread[]   the threads now on that line,
---   actions = { reply(thread), set_resolved(thread, bool), edit(thread, comment), delete(comment) } }
function M.open(opts)
  M.close()
  if not valid_win(opts.win) then return end
  local width = math.max(30, math.min(MAX_WIDTH, vim.api.nvim_win_get_width(opts.win) - 4))
  local buf = require("diff.float").scratch("pr-thread", "diff.nvim Comments")
  local row, col = placement(opts.win, opts.row, 6, width)
  local win = require("diff.float").open(buf, true, {
    relative = "editor", row = row, col = col, width = width, height = 6, title = "Comments",
  }, { footer = "r reply   R resolve   e edit   x delete   q close", options = { wrap = false, cursorline = false } })
  if not win then return end

  local s = { win = win, buf = buf, opts = opts, meta = {}, confirm = {} }
  -- Reply and edit open the comment editor, and focus moving to it keeps
  -- this float open; focus moving anywhere else closes it.
  local function opens_editor(name)
    local fn = opts.actions[name]
    return fn and function(...)
      log.debug("%s from the comments float", name)
      s.opened_editor = true
      return fn(...)
    end
  end
  s.actions = { reply = opens_editor("reply"), edit = opens_editor("edit"),
    set_resolved = opts.actions.set_resolved, delete = opts.actions.delete }
  s.target = buttons.target(buf, win)
  S = s
  render(s)
  if S ~= s then return end
  -- With its height known, move it above the line if it does not fit below.
  local r2, c2 = placement(opts.win, opts.row, vim.api.nvim_win_get_height(win), width)
  pcall(vim.api.nvim_win_set_config, win, { relative = "editor", row = r2, col = c2 })

  local function map(key, fn)
    vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, silent = true })
  end
  local a = s.actions
  map("r", function()
    local here = at_cursor()
    if here and here.thread.can_reply then a.reply(here.thread) end
  end)
  map("R", function()
    local t = at_cursor() and at_cursor().thread
    if not t or t.pending then return end
    if t.resolved and t.can_unresolve then a.set_resolved(t, false)
    elseif not t.resolved and t.can_resolve then a.set_resolved(t, true) end
  end)
  map("e", function()
    local here = at_cursor()
    if here and here.comment and here.comment.can_update then a.edit(here.thread, here.comment) end
  end)
  map("x", function()
    local here = at_cursor()
    if here and here.comment and here.comment.can_delete then M.delete(here.comment) end
  end)
  map("<CR>", function() s.target:press_cursor() end)
  map("<Tab>", function() s.target:step(1) end)
  map("<S-Tab>", function() s.target:step(-1) end)
  map("q", M.close)
  map("<Esc>", M.close)
  -- Unmapped, K would fall through to 'keywordprg' (man) on the word under the cursor.
  map("K", M.close)

  vim.api.nvim_create_autocmd("User", {
    group = aug, pattern = "DiffNvimPrChanged",
    callback = function() if S == s and valid_win(s.win) then render(s) end end,
  })
  -- Focus moving elsewhere (a click outside, a window command) closes it,
  -- unless it moved to the editor a reply or an edit opened.
  vim.api.nvim_create_autocmd("WinLeave", {
    group = aug, buffer = buf,
    callback = function()
      vim.schedule(function()
        if S ~= s or vim.api.nvim_get_current_win() == s.win then return end
        if s.opened_editor and require("diff.compose").is_open() then return end
        log.debug("focus left the comments float; closing")
        M.close()
      end)
    end,
  })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = aug, buffer = buf,
    -- A float opening from this one enters it while still showing this buffer.
    callback = function() if vim.api.nvim_get_current_win() == s.win then s.opened_editor = false end end,
  })
  -- A delete waiting for its confirming press is called off by moving to another comment.
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = aug, buffer = buf,
    callback = function()
      if S ~= s or not next(s.confirm) then return end
      local here = at_cursor()
      if here and here.comment and s.confirm[here.comment.id] then return end
      log.debug("delete not confirmed; calling it off")
      s.confirm = {}
      render(s)
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = aug, pattern = tostring(win), once = true,
    callback = function() vim.schedule(function() if S == s then M.close() end end) end,
  })
  log.debug("opened %d threads at %s", #opts.threads(), opts.where or "?")
end

--- The open float (tests).
function M._state()
  return S
end

return M
