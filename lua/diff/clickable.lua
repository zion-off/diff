--- diff.nvim — windows outside the sidebar that react to the mouse, such as
--- the review floats. The sidebar's mouse handling (which sees every press,
--- release and move while the interface is open) asks here before its own
--- panels, so a float gets clicks and hover without mapping <LeftMouse>.
---
--- A handler is { item_at(line, col) -> key|nil, click(line, col) -> boolean,
--- hover(line|nil, col|nil) }, with 1-based buffer lines and display columns.
local M = {}

local handlers = {} -- win -> handler

function M.register(win, handler)
  handlers[win] = handler
end

function M.unregister(win)
  handlers[win] = nil
end

--- @return table|nil  the handler of `win`
function M.get(win)
  local h = handlers[win]
  if h and not vim.api.nvim_win_is_valid(win) then
    handlers[win] = nil
    return nil
  end
  return h
end

--- Tell every handler where the pointer is: the one under it gets the
--- position, the others nil.
function M.hover(win, line, col)
  for w, h in pairs(handlers) do
    if not vim.api.nvim_win_is_valid(w) then
      handlers[w] = nil
    elseif w == win then
      h.hover(line, col)
    else
      h.hover(nil, nil)
    end
  end
end

return M
