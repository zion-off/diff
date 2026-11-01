--- diff.nvim — windows outside the sidebar that react to the mouse, such as
--- the review floats. The sidebar's mouse handling (which sees every press,
--- release and move while the interface is open) asks here before its own
--- panels, so a float gets clicks and hover without mapping <LeftMouse>.
---
--- A handler is { item_at(line, col) -> key|nil, click(line, col) -> boolean,
--- hover(line|nil, col|nil) }, with 1-based buffer lines and 1-based display
--- columns of the text. Callers pass the pointer's window column, which
--- counts a float's left border; it is turned into a text column here.
local M = {}

local handlers = {} -- win -> handler

function M.register(win, handler)
  handlers[win] = handler
end

function M.unregister(win)
  handlers[win] = nil
end

local function handler_of(win)
  local h = win and handlers[win]
  if h and not vim.api.nvim_win_is_valid(win) then
    handlers[win] = nil
    return nil
  end
  return h
end

--- Whether `win` has a handler.
function M.has(win)
  return handler_of(win) ~= nil
end

--- The text column of window column `wincol` in `win`: one less per cell
--- of a left border.
local function text_col(win, wincol)
  local border = vim.api.nvim_win_get_config(win).border
  local left = type(border) == "table" and border[8] or nil
  if type(left) == "table" then left = left[1] end
  return wincol - (type(left) == "string" and vim.api.nvim_strwidth(left) or 0)
end

function M.item_at(win, line, wincol)
  local h = handler_of(win)
  return h and h.item_at(line, text_col(win, wincol)) or nil
end

function M.click(win, line, wincol)
  local h = handler_of(win)
  return h ~= nil and h.click(line, text_col(win, wincol))
end

--- Tell every handler where the pointer is: the one under it gets the
--- position, the others nil.
function M.hover(win, line, wincol)
  for w, h in pairs(handlers) do
    if not vim.api.nvim_win_is_valid(w) then
      handlers[w] = nil
    elseif w == win and line then
      h.hover(line, text_col(w, wincol))
    else
      h.hover(nil, nil)
    end
  end
end

return M
