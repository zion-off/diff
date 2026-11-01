--- diff.nvim — buttons drawn as text in a float's buffer, clicked with the
--- mouse or pressed with <CR> when the cursor is on one.
---
--- M.row() lays a row of buttons out as text; M.target() makes a window's
--- buttons clickable: hit testing, the hover tint, the keyboard cursor mark,
--- and registration with the shared mouse handling (clickable.lua).
local M = {}

local clickable = require("diff.clickable")

local NS_HOVER  = vim.api.nvim_create_namespace("diff_nvim_button_hover")
local NS_CURSOR = vim.api.nvim_create_namespace("diff_nvim_button_cursor")

local STYLE = {
  primary = "DiffNvimButtonPrimary",
  danger  = "DiffNvimButtonDanger",
  plain   = "DiffNvimButton",
}

--- Lay out `items` ({ label, action, style = "primary"|"danger"|nil }) as
--- one line after `prefix`.
--- @return string line, table[] hls { s, e, hl }, table[] segs { s, e, c1, c2, action }
---   byte columns end-exclusive, display columns 1-based inclusive
function M.row(items, prefix)
  local line, hls, segs = prefix or "", {}, {}
  for i, item in ipairs(items) do
    if i > 1 then line = line .. " " end
    local text = " " .. item.label .. " "
    local s, c1 = #line, vim.api.nvim_strwidth(line) + 1
    line = line .. text
    table.insert(hls, { s, #line, STYLE[item.style or "plain"] or STYLE.plain })
    table.insert(segs, { s = s, e = #line, c1 = c1, c2 = vim.api.nvim_strwidth(line), action = item.action })
  end
  return line, hls, segs
end

local Target = {}
Target.__index = Target

--- Make the buttons of `win` (showing `buf`) clickable.
function M.target(buf, win)
  local t = setmetatable({ buf = buf, win = win, segs = {}, hover_seg = nil }, Target)
  clickable.register(win, {
    item_at = function(line, col) return t:item_at(line, col) end,
    click = function(line, col) return t:click(line, col) end,
    hover = function(line, col) t:hover(line, col) end,
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "WinEnter", "WinLeave" }, {
    buffer = buf, callback = function() vim.schedule(function() t:mark_cursor() end) end,
  })
  return t
end

--- Replace the buttons: segments as from M.row(), each with a `row` (0-based).
function Target:set(segs)
  self.segs = segs
  self.hover_seg = nil
  self:paint_hover()
  self:mark_cursor()
end

function Target:segment_at(line, col)
  for _, seg in ipairs(self.segs) do
    if seg.row == line - 1 and col >= seg.c1 and col <= seg.c2 then return seg end
  end
end

function Target:item_at(line, col)
  local seg = self:segment_at(line, col)
  return seg and (seg.row .. ":" .. seg.c1) or nil
end

function Target:click(line, col)
  local seg = self:segment_at(line, col)
  if not seg then return false end
  seg.action()
  return true
end

function Target:paint_hover()
  if not vim.api.nvim_buf_is_valid(self.buf) then return end
  vim.api.nvim_buf_clear_namespace(self.buf, NS_HOVER, 0, -1)
  local seg = self.hover_seg
  if seg then
    pcall(vim.api.nvim_buf_set_extmark, self.buf, NS_HOVER, seg.row, seg.s,
      { end_col = seg.e, hl_group = "DiffNvimButtonHover", priority = 300 })
  end
end

function Target:hover(line, col)
  local seg = line and col and self:segment_at(line, col) or nil
  if seg == self.hover_seg then return end
  self.hover_seg = seg
  self:paint_hover()
end

--- The button under the cursor of the window, if it has focus.
function Target:cursor_segment()
  if not vim.api.nvim_win_is_valid(self.win) or vim.api.nvim_get_current_win() ~= self.win then return nil end
  local cur = vim.api.nvim_win_get_cursor(self.win)
  for _, seg in ipairs(self.segs) do
    if seg.row == cur[1] - 1 and cur[2] >= seg.s and cur[2] < seg.e then return seg end
  end
end

function Target:mark_cursor()
  if not vim.api.nvim_buf_is_valid(self.buf) then return end
  vim.api.nvim_buf_clear_namespace(self.buf, NS_CURSOR, 0, -1)
  local seg = self:cursor_segment()
  if seg then
    pcall(vim.api.nvim_buf_set_extmark, self.buf, NS_CURSOR, seg.row, seg.s,
      { end_col = seg.e, hl_group = "DiffNvimButtonCursor", priority = 250 })
  end
end

--- Press the button under the cursor. Returns whether there was one.
function Target:press_cursor()
  local seg = self:cursor_segment()
  if not seg then return false end
  seg.action()
  return true
end

--- Move the cursor to the next (dir 1) or previous (-1) button, wrapping.
function Target:step(dir)
  if #self.segs == 0 or not vim.api.nvim_win_is_valid(self.win) then return end
  local cur = vim.api.nvim_win_get_cursor(self.win)
  local pos = { cur[1] - 1, cur[2] }
  -- The cursor rests one past a button's start, so a button counts as behind it only
  -- when its label starts before the cursor; else stepping back stays on this one.
  local function before(seg) return seg.row < pos[1] or (seg.row == pos[1] and seg.s + 1 < pos[2]) end
  local function after(seg) return seg.row > pos[1] or (seg.row == pos[1] and seg.s > pos[2]) end
  local pick
  if dir > 0 then
    for _, seg in ipairs(self.segs) do
      if after(seg) then pick = seg break end
    end
    pick = pick or self.segs[1]
  else
    for i = #self.segs, 1, -1 do
      if before(self.segs[i]) then pick = self.segs[i] break end
    end
    pick = pick or self.segs[#self.segs]
  end
  -- One past the leading space, so the cursor sits on the label.
  pcall(vim.api.nvim_win_set_cursor, self.win, { pick.row + 1, pick.s + 1 })
end

function Target:release()
  clickable.unregister(self.win)
end

return M
