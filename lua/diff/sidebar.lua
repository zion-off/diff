--- diff.nvim — interface layout: a dedicated tab with the sidebar panels
--- (the mode bar, file status below it, commits at the bottom) and a main
--- area for the diff view.
--- In branch mode the file panel lists the branch's changes and takes the
--- whole sidebar; the commit panel is closed.
---
--- Also owns what is shared across the interface: the git-directory watcher,
--- refresh scheduling, mouse activation and the interface-scoped keymaps.
local M = {}

local mode_bar     = require("diff.mode_bar")
local file_panel   = require("diff.file_panel")
local commit_panel = require("diff.commit_panel")
local config       = require("diff.config")
local git          = require("diff.git")
local log          = require("diff.log").scope("sidebar")

local uv = vim.uv or vim.loop

local REFRESH_DEBOUNCE_MS = 50
local WATCH_DEBOUNCE_MS   = 100

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

M._bar_win        = nil
M._bar_buf        = nil
M._head_name      = nil   -- checked-out branch of _repo_root (nil: detached)
M._file_win       = nil
M._commit_win     = nil
M._file_buf       = nil
M._commit_buf     = nil
M._main_win       = nil   -- main area (diff view host)
M._repo_root      = nil
M._git_dir        = nil
M._home           = nil   -- {root, git_dir} the interface was opened in; _repo_root/_git_dir
                          -- differ while another worktree's changes are shown
M._saved_layout   = nil   -- tab + window to return to on close
M._sidebar_hidden = false
M._saved_mouse    = nil   -- previous global 'mouse' value (restored on close)
M._saved_mousemove = nil  -- previous 'mousemoveevent' value (restored on close)
M._panel_sizes    = nil   -- {width, file_height} kept across a hide/show toggle
M._preview_branch = nil   -- when set, panels source data from this branch
M._branch_mode    = false -- file panel shows the branch's changes; no commit panel

local watcher, watch_timer, refresh_timer
local get_diff_tab -- defined with the panels, used by the mouse handling
-- Panel refreshes in flight, and the scope of a coalesced refresh waiting for
-- them. refresh_epoch drops callbacks from before the interface was closed.
local refreshing, queued_scope, refresh_epoch = 0, nil, 0
local mouse_ns = vim.api.nvim_create_namespace("diff_nvim_mouse")
local aug = vim.api.nvim_create_augroup("DiffNvimSidebar", { clear = true })

local function is_valid_win(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

-- ---------------------------------------------------------------------------
-- Interface-scoped global keymaps
-- ---------------------------------------------------------------------------

-- Every global mapping installed on open, with whatever it shadowed, so close()
-- can put the user's own mappings back.
-- Entries: { mode = string, lhs = string, prev = <keymap table>|false }
M._installed_maps = {}

local function normalize_lhs(lhs)
  return vim.api.nvim_replace_termcodes(lhs, true, true, true)
end

local function find_global_map(mode, lhs)
  local target = normalize_lhs(lhs)
  for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
    if normalize_lhs(m.lhs) == target then return m end
  end
  return nil
end

local function set_global_map(mode, lhs, rhs, desc)
  if not lhs or lhs == "" then return end
  table.insert(M._installed_maps, { mode = mode, lhs = lhs, prev = find_global_map(mode, lhs) or false })
  vim.keymap.set(mode, lhs, rhs, { silent = true, desc = desc })
end

local function restore_global_maps()
  for i = #M._installed_maps, 1, -1 do
    local entry = M._installed_maps[i]
    pcall(vim.keymap.del, entry.mode, entry.lhs)
    local prev = entry.prev
    if prev then
      local rhs = prev.callback or prev.rhs
      if rhs then
        pcall(vim.keymap.set, entry.mode, entry.lhs, rhs, {
          silent  = prev.silent  == 1,
          noremap = prev.noremap == 1,
          expr    = prev.expr    == 1,
          nowait  = prev.nowait  == 1,
          desc    = prev.desc,
        })
      end
    end
  end
  M._installed_maps = {}
end

-- ---------------------------------------------------------------------------
-- Mouse
-- ---------------------------------------------------------------------------

-- A click on a panel row activates it (and one on a diff view's "hidden lines"
-- row expands it), even when another window had focus.
-- vim.on_key observes the click without mapping <LeftMouse>, so Neovim's own
-- handling (focus, cursor placement, separator drag-resize) and any user
-- mapping of the key are untouched. The row is read after Neovim has
-- processed the click.
local LEFT_MOUSE = normalize_lhs("<LeftMouse>")
local LEFT_DRAG  = normalize_lhs("<LeftDrag>")
local MOUSE_MOVE = normalize_lhs("<MouseMove>")

-- Set once the pointer moves with the button held. The click is read after
-- the fact, so by then a drag (resizing the panels, say) may have carried the
-- pointer onto a row; that row was never clicked.
local dragged = false

-- The window focused before the latest click: Neovim focuses whatever is
-- clicked, and a click on the mode bar should leave focus where it was.
local focus_before_click

--- The buffer line under the pointer, or nil. getmousepos() reports the last
--- line for the empty rows below it, which nothing should react to.
local function line_under_mouse(mp)
  if mp.line < 1 or not is_valid_win(mp.winid) then return nil end
  local last = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(mp.winid))
  if mp.line == last then
    local pos = vim.fn.screenpos(mp.winid, last, 1)
    if pos.row > 0 and mp.screenrow > pos.row then return nil end
  end
  return mp.line
end

-- Row the pointer was last seen over, so a move within a row does nothing.
local hover_win, hover_line

--- The draggable window edge under the pointer: the window it belongs to and
--- "vsep" (its right-hand separator) or "status" (its status line), or nil.
--- The pointer is then just outside the window, one past its width or height.
local function edge_under_mouse(mp)
  local win = mp.winid
  if mp.line ~= 0 or not is_valid_win(win) or vim.api.nvim_win_get_tabpage(win) ~= get_diff_tab() then
    return nil
  end
  -- The rule under the diff header and the bottom of the mode bar are not
  -- meant to be moved.
  if win == require("diff.diff_view")._state().header_win then return nil end
  if win == M._bar_win and mp.wincol ~= vim.api.nvim_win_get_width(win) + 1 then return nil end
  if mp.wincol == vim.api.nvim_win_get_width(win) + 1 then return win, "vsep" end
  if mp.winrow == vim.api.nvim_win_get_height(win) + 1 then
    -- The bottom status line resizes the command line, not a window.
    local bottom = vim.api.nvim_win_get_position(win)[1] + vim.api.nvim_win_get_height(win) + 1
    if bottom >= vim.o.lines - vim.o.cmdheight then return nil end
    return win, "status"
  end
  return nil
end

-- Floats that let the mouse through (needed to paint over an edge without
-- blocking the drag) and can be hidden arrived in Neovim 0.11.
local CAN_PAINT_EDGES = vim.fn.has("nvim-0.11") == 1

-- The highlighted edge: { win, kind, key } (key: the painted area and glyphs).
-- One float and buffer are reused for every edge, so hovering and dragging
-- never create windows or buffers.
local edge
local edge_float, edge_buf
-- A per-window status line is tinted through its window's 'winhighlight'
-- instead (a float would cover its text): { win, saved }.
local tinted_status

local function window_boxes(tab)
  local boxes = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.api.nvim_win_get_config(w).relative == "" then
      local pos = vim.api.nvim_win_get_position(w)
      table.insert(boxes, { win = w, row = pos[1], col = pos[2],
        height = vim.api.nvim_win_get_height(w), width = vim.api.nvim_win_get_width(w) })
    end
  end
  return boxes
end

--- The separator glyphs in effect for `win` ('fillchars' or its defaults).
local function fill_chars(win)
  local fc = { vert = "│", horiz = "─", vertleft = "┤", vertright = "├", verthoriz = "┼" }
  local opt = vim.api.nvim_get_option_value("fillchars", { win = win })
  for key, ch in opt:gmatch("(%w+):([^,]+)") do
    if fc[key] then fc[key] = ch end
  end
  return fc
end

--- Screen area (0-based editor cells) and lines of glyphs for `win`'s edge,
--- worked out from the layout. A vertical edge is shared by every window
--- stacked against the same separator column (the mode bar and the file and
--- commit panels), which all resize together when it is dragged. Where a
--- horizontal separator meets it (global status line), the junction glyph.
local function edge_shape(win, kind)
  local fc = fill_chars(win)
  local boxes = window_boxes(vim.api.nvim_win_get_tabpage(win))
  local b
  for _, bw in ipairs(boxes) do if bw.win == win then b = bw end end
  if kind == "status" then
    return { row = b.row + b.height, col = b.col, height = 1, width = b.width,
      lines = { string.rep(fc.horiz, b.width) } }
  end

  local x = b.col + b.width
  local column = {}
  for _, bw in ipairs(boxes) do
    if bw.col + bw.width == x then table.insert(column, bw) end
  end
  table.sort(column, function(a, c) return a.row < c.row end)
  local first, last
  for i, bw in ipairs(column) do
    if bw.win == win then first, last = i, i end
  end
  -- Windows touch when one starts on the row after the other's bottom edge.
  while first > 1 and column[first - 1].row + column[first - 1].height + 1 == column[first].row do
    first = first - 1
  end
  while last < #column and column[last].row + column[last].height + 1 == column[last + 1].row do
    last = last + 1
  end
  local top, bottom = column[first].row, column[last].row + column[last].height - 1

  -- Rows where a horizontal separator ends against the column on either side.
  local left, right = {}, {}
  if vim.o.laststatus == 3 then
    for _, bw in ipairs(boxes) do
      local sep_row = bw.row + bw.height
      if bw.col + bw.width == x then left[sep_row] = true end
      if bw.col == x + 1 then right[sep_row] = true end
    end
  end
  local lines = {}
  for r = top, bottom do
    local ch = fc.vert
    if left[r] and right[r] then ch = fc.verthoriz
    elseif left[r] then ch = fc.vertleft
    elseif right[r] then ch = fc.vertright end
    table.insert(lines, ch)
  end
  return { row = top, col = x, height = #lines, width = 1, lines = lines }
end

local function untint_status()
  if tinted_status and is_valid_win(tinted_status.win) then
    vim.wo[tinted_status.win].winhighlight = tinted_status.saved
  end
  tinted_status = nil
end

local function hide_edge()
  if edge_float and is_valid_win(edge_float) then
    pcall(vim.api.nvim_win_set_config, edge_float, { hide = true })
  end
  untint_status()
  edge = nil
end

local function destroy_edge()
  hide_edge()
  if edge_float and is_valid_win(edge_float) then pcall(vim.api.nvim_win_close, edge_float, true) end
  if edge_buf and vim.api.nvim_buf_is_valid(edge_buf) then pcall(vim.api.nvim_buf_delete, edge_buf, { force = true }) end
  edge_float, edge_buf = nil, nil
end

--- Highlight `win`'s edge (nil: none) by covering it with a float that shows
--- the same glyphs in the hover colour and lets the mouse through. Only in
--- the interface tab, which the float belongs to.
local function highlight_edge(win, kind)
  if not CAN_PAINT_EDGES then return end
  local tab = get_diff_tab()
  if not win or not tab or tab ~= vim.api.nvim_get_current_tabpage() then
    if edge then hide_edge() end
    return
  end
  if kind == "status" and vim.o.laststatus ~= 3 then
    if edge and edge.win == win and edge.kind == kind then return end
    hide_edge()
    local saved = vim.wo[win].winhighlight
    tinted_status = { win = win, saved = saved }
    vim.wo[win].winhighlight = (saved ~= "" and saved .. "," or "")
      .. "StatusLine:DiffNvimEdgeHoverStatus,StatusLineNC:DiffNvimEdgeHoverStatus"
    edge = { win = win, kind = kind }
    return
  end
  untint_status()
  local shape = edge_shape(win, kind)
  local key = table.concat({ shape.row, shape.col, shape.width, shape.height, table.concat(shape.lines) }, ":")
  if edge and edge.win == win and edge.kind == kind and edge.key == key then return end

  if not (edge_buf and vim.api.nvim_buf_is_valid(edge_buf)) then
    edge_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[edge_buf].bufhidden = "hide"
  end
  vim.api.nvim_buf_set_lines(edge_buf, 0, -1, false, shape.lines)
  local cfg = { relative = "editor", row = shape.row, col = shape.col,
    width = shape.width, height = shape.height, hide = false }
  -- The float lives in the interface tab; recreate it if that tab was replaced.
  if edge_float and is_valid_win(edge_float) and vim.api.nvim_win_get_tabpage(edge_float) ~= tab then
    pcall(vim.api.nvim_win_close, edge_float, true)
    edge_float = nil
  end
  if edge_float and is_valid_win(edge_float) then
    vim.api.nvim_win_set_config(edge_float, cfg)
  else
    local ok, float = pcall(vim.api.nvim_open_win, edge_buf, false, vim.tbl_extend("force", cfg, {
      focusable = false, mouse = false, style = "minimal", zindex = 1, noautocmd = true,
    }))
    if not ok then
      log.debug("cannot highlight edge: %s", tostring(float))
      return
    end
    edge_float = float
    vim.wo[float].winhighlight = "Normal:DiffNvimEdgeHover,NormalFloat:DiffNvimEdgeHover"
  end
  edge = { win = win, kind = kind, key = key }
end

--- Re-place the edge highlight after a resize, so it follows a drag (the
--- pointer stays on the edge being dragged).
local function refresh_edge()
  if not edge then return end
  highlight_edge(edge_under_mouse(vim.fn.getmousepos()))
end

--- Drop every hover effect (the pointer left Neovim or the interface).
local function clear_hover()
  hover_win, hover_line = nil, nil
  hide_edge()
  mode_bar.hover(nil)
  file_panel.hover(nil)
  commit_panel.hover(nil)
  require("diff.diff_view").hover(nil, nil)
end

local function on_mouse_move()
  vim.schedule(function()
    if not M.is_open() then return end
    local mp = vim.fn.getmousepos()
    highlight_edge(edge_under_mouse(mp))
    local line = line_under_mouse(mp)
    -- The bar's items share rows, so there the column matters too.
    local key = line and mp.winid == M._bar_win and line .. ":" .. mp.wincol or line
    if mp.winid == hover_win and key == hover_line then return end
    hover_win, hover_line = mp.winid, key
    mode_bar.hover(mp.winid == M._bar_win and line or nil, mp.wincol)
    file_panel.hover(mp.winid == M._file_win and line or nil)
    commit_panel.hover(mp.winid == M._commit_win and line or nil)
    require("diff.diff_view").hover(mp.winid, line)
  end)
end

-- Whether pointer moves are wanted (mouse support on, interface open).
local hover_enabled = false

--- 'mousemoveevent' on only while the interface tab is current: elsewhere it
--- would cost the user's other tabs (it can cut pending mappings short).
local function sync_mousemove()
  local want = hover_enabled and get_diff_tab() ~= nil and get_diff_tab() == vim.api.nvim_get_current_tabpage()
  if want and M._saved_mousemove == nil then
    M._saved_mousemove = vim.o.mousemoveevent
    vim.o.mousemoveevent = true
  elseif not want and M._saved_mousemove ~= nil then
    vim.o.mousemoveevent = M._saved_mousemove
    M._saved_mousemove = nil
  end
end

local function on_mouse_key(key)
  if key == MOUSE_MOVE then
    on_mouse_move()
    return
  end
  if key == LEFT_DRAG then
    dragged = true
    return
  end
  if key ~= LEFT_MOUSE then return end
  dragged = false
  -- on_key runs before Neovim handles the click.
  focus_before_click = vim.api.nvim_get_current_win()
  vim.schedule(function()
    if dragged then return end
    local mp = vim.fn.getmousepos()
    if mp.winid == M._bar_win then
      -- Focus goes back where it was; an item may then open the picker.
      local back = focus_before_click ~= M._bar_win and focus_before_click or M._file_win
      if is_valid_win(back) then vim.api.nvim_set_current_win(back) end
      local line = line_under_mouse(mp)
      if line then mode_bar.click(line, mp.wincol) end
      return
    end
    local target
    if mp.winid == M._commit_win then
      target = commit_panel
    elseif mp.winid == M._file_win then
      target = file_panel
    end
    if not target and mp.line >= 1 and mp.winid ~= 0 then
      require("diff.diff_view").click(mp.winid, mp.line)
      return
    end
    -- line is 0 on a separator or status line: leave those to Neovim.
    if target and mp.line >= 1 and is_valid_win(mp.winid) then
      log.trace("click on %s row %d", target == file_panel and "file panel" or "commit panel", mp.line)
      pcall(vim.api.nvim_win_set_cursor, mp.winid, { mp.line, 0 })
      local ok, err = pcall(target.activate_line, mp.line)
      if not ok then log.warn("click activation failed: %s", tostring(err)) end
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Refresh scheduling and the git-directory watcher
-- ---------------------------------------------------------------------------

local function stop_timer(t)
  if t then pcall(function() t:stop() t:close() end) end
end

local function stop_watcher()
  stop_timer(watch_timer)
  watch_timer = nil
  if watcher then
    pcall(function() watcher:stop() watcher:close() end)
    watcher = nil
  end
end

--- Watch the git directory itself, not .git/index: git replaces the index by
--- renaming a new file over it, which gives it a new inode, and a watch on the
--- old inode never fires again. A directory watch sees every replacement, plus
--- HEAD moves (checkout) and COMMIT_EDITMSG/ORIG_HEAD writes (commit, reset).
local function start_watcher()
  stop_watcher()
  if not M._git_dir then return end
  local ok, handle = pcall(uv.new_fs_event)
  if not ok or not handle then return end
  local timer = uv.new_timer()
  local started = handle:start(M._git_dir, {}, function(err, fname)
    if err then
      log.warn("git dir watcher error: %s", tostring(err))
      return
    end
    -- Lock files come and go around every write; the rename that follows is
    -- the event that matters.
    if not fname or fname:match("%.lock$") then return end
    log.trace("git dir event: %s", fname)
    timer:stop()
    timer:start(WATCH_DEBOUNCE_MS, 0, vim.schedule_wrap(function()
      if not M.is_open() then return end
      log.debug("git state changed (%s); refreshing", fname)
      M.refresh({ coalesce = true })
      vim.api.nvim_exec_autocmds("User", { pattern = "DiffNvimGitChanged", modeline = false })
    end))
  end)
  if started then
    watcher, watch_timer = handle, timer
    log.debug("watching %s", M._git_dir)
  else
    log.warn("cannot watch %s; relying on focus/write refresh", M._git_dir)
    pcall(function() handle:close() timer:close() end)
  end
end

--- Coalesce refresh requests (FocusGained, :wa writing many buffers, …) into
--- a single re-fetch.
--- @param scope string|nil  see M.refresh
function M.request_refresh(scope)
  if not refresh_timer then refresh_timer = uv.new_timer() end
  refresh_timer:stop()
  refresh_timer:start(REFRESH_DEBOUNCE_MS, 0, vim.schedule_wrap(function()
    if M.is_open() then M.refresh({ scope = scope, coalesce = true }) end
  end))
end

-- ---------------------------------------------------------------------------
-- Panels
-- ---------------------------------------------------------------------------

local function clear_panel_state()
  M._file_win, M._commit_win, M._file_buf, M._commit_buf = nil, nil, nil, nil
  M._bar_win, M._bar_buf = nil, nil
end

--- Return the tabpage of the interface, if it is open.
function get_diff_tab()
  for _, win in ipairs({ M._file_win or false, M._commit_win or false, M._bar_win or false, M._main_win or false }) do
    if win and is_valid_win(win) then return vim.api.nvim_win_get_tabpage(win) end
  end
  return nil
end

function M.is_open()
  if M._sidebar_hidden then
    return is_valid_win(M._main_win)
  end
  return is_valid_win(M._file_win) and (M._branch_mode or is_valid_win(M._commit_win))
end

--- A scratch buffer for a sidebar panel, reusing one of the same name (it
--- is emptied rather than deleted: deleting a displayed buffer closes its window).
local function make_panel_buf(name)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == name then
      vim.bo[b].modifiable = true
      pcall(vim.api.nvim_buf_set_lines, b, 0, -1, false, {})
      vim.bo[b].modifiable = false
      return b
    end
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype    = "nofile"
  vim.bo[buf].bufhidden  = "wipe"
  vim.bo[buf].swapfile   = false
  vim.bo[buf].undolevels = -1
  vim.bo[buf].modifiable = false
  return buf
end

--- Panel lines are rendered to the window's exact width, so 'wrap' never
--- actually wraps — but it does make horizontal scrolling impossible, which
--- is what keeps the panels pinned without intercepting any keys.
local function set_panel_win_opts(win)
  for k, v in pairs({
    number = false, relativenumber = false, wrap = true, linebreak = false,
    signcolumn = "no", foldcolumn = "0", statuscolumn = "", cursorline = true,
    winfixwidth = true, spell = false, list = false,
  }) do
    pcall(vim.api.nvim_set_option_value, k, v, { win = win })
  end
end

local function layout_two_panels()
  if not is_valid_win(M._file_win) or not is_valid_win(M._commit_win) then return end
  local total_h = vim.api.nvim_win_get_height(M._file_win) + vim.api.nvim_win_get_height(M._commit_win) + 1
  local file_h  = math.min(math.max(1, math.floor(total_h * 0.60)), math.max(1, total_h - 1))
  pcall(vim.api.nvim_win_set_height, M._file_win, file_h)
end

--- Create the commit panel window below the file panel.
--- Returns false when there is no room for it (E36).
local function create_commit_panel()
  vim.api.nvim_set_current_win(M._file_win)
  local ok, err = pcall(vim.cmd, "rightbelow split")
  if not ok then
    log.warn("no room for the commit panel: %s", tostring(err))
    return false
  end
  M._commit_win = vim.api.nvim_get_current_win()
  M._commit_buf = make_panel_buf("diff://commit-panel")
  vim.api.nvim_win_set_buf(M._commit_win, M._commit_buf)
  set_panel_win_opts(M._commit_win)
  commit_panel.setup(M._commit_buf, M._commit_win, M._repo_root)
  -- The split the user left, else the default one.
  if M._commit_height then
    pcall(vim.api.nvim_win_set_height, M._commit_win, M._commit_height)
  else
    layout_two_panels()
  end
  return true
end

--- Remember the commit panel's height, to restore when it comes back.
local function save_commit_height()
  if is_valid_win(M._commit_win) then M._commit_height = vim.api.nvim_win_get_height(M._commit_win) end
end

--- Create the mode bar window above the file panel, at a fixed height.
--- Skipped when there is no room for it: the panels matter more.
local function create_mode_bar()
  vim.api.nvim_set_current_win(M._file_win)
  local ok, err = pcall(vim.cmd, "leftabove " .. mode_bar.HEIGHT .. " split")
  if not ok then
    log.warn("no room for the mode bar: %s", tostring(err))
    return
  end
  M._bar_win = vim.api.nvim_get_current_win()
  M._bar_buf = make_panel_buf("diff://mode-bar")
  vim.api.nvim_win_set_buf(M._bar_win, M._bar_buf)
  set_panel_win_opts(M._bar_win)
  -- Unwrapped, so a narrow sidebar clips its rows instead of wrapping them
  -- out of its two-row window.
  for k, v in pairs({ winfixheight = true, cursorline = false, wrap = false }) do
    pcall(vim.api.nvim_set_option_value, k, v, { win = M._bar_win })
  end
  mode_bar.setup(M._bar_buf, M._bar_win)
end

--- Create the panel windows by splitting off `anchor`: the mode bar, the file
--- panel, and below it the commit panel unless in branch mode.
--- Returns false when there is no room; the caller rolls back.
local function create_panels(anchor, width)
  local position = config.get().sidebar_position == "right" and "botright" or "topleft"
  vim.api.nvim_set_current_win(anchor)
  local ok, err = pcall(vim.cmd, position .. " " .. width .. " vsplit")
  if not ok then
    log.warn("no room for the sidebar: %s", tostring(err))
    return false
  end
  M._file_win = vim.api.nvim_get_current_win()
  M._file_buf = make_panel_buf("diff://file-panel")
  vim.api.nvim_win_set_buf(M._file_win, M._file_buf)
  set_panel_win_opts(M._file_win)
  file_panel.setup(M._file_buf, M._file_win, M._repo_root)
  create_mode_bar()
  if not M._branch_mode then return create_commit_panel() end
  return true
end

--- Fill `win` with the "select a file" placeholder.
function M.show_placeholder(win)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "",
    "  diff.nvim",
    "",
    "  Select a file from the sidebar to view its diff.",
    "  Press 'q' in the sidebar to close.",
    "",
  })
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_win_set_buf, win, buf)
  for k, v in pairs({ number = false, relativenumber = false, statuscolumn = "", signcolumn = "no",
                      scrollbind = false, cursorbind = false }) do
    pcall(vim.api.nvim_set_option_value, k, v, { win = win })
  end
end

-- ---------------------------------------------------------------------------
-- Open / close
-- ---------------------------------------------------------------------------

--- Open the interface in a new tab.
--- @param info {root: string, git_dir: string}
function M.open(info)
  if M._file_win or M._commit_win or M._main_win then
    if M.is_open() then return end
    M.close() -- partial state from an earlier session
  end

  local elapsed = require("diff.log").timer()
  M._repo_root, M._git_dir = info.root, info.git_dir
  M._home = info
  M._sidebar_hidden = false
  local cfg = config.get()

  M._saved_mouse = nil
  if cfg.mouse then
    local cur = vim.o.mouse
    if not (cur:find("n") or cur:find("a")) then
      M._saved_mouse = cur
      vim.o.mouse = "a"
    end
    hover_enabled = true
    vim.on_key(on_mouse_key, mouse_ns)
  end

  M._saved_layout = { tabpage = vim.api.nvim_get_current_tabpage(), win = vim.api.nvim_get_current_win() }

  vim.cmd("tabnew")
  M._main_win = vim.api.nvim_get_current_win()
  -- `:tabnew` leaves a listed, empty [No Name] buffer behind; wipe it once
  -- the placeholder has replaced it.
  local tabnew_buf = vim.api.nvim_win_get_buf(M._main_win)
  M.show_placeholder(M._main_win)
  if vim.api.nvim_buf_is_valid(tabnew_buf) and vim.api.nvim_buf_get_name(tabnew_buf) == ""
    and not vim.bo[tabnew_buf].modified then
    pcall(vim.api.nvim_buf_delete, tabnew_buf, { force = true })
  end

  if not create_panels(M._main_win, cfg.sidebar_width or 40) then
    vim.notify("diff.nvim: not enough room to open the interface", vim.log.levels.WARN)
    M.close()
    return
  end
  vim.api.nvim_set_current_win(M._file_win)
  -- Pointer moves are delivered while the interface tab is current.
  sync_mousemove()

  if cfg.auto_refresh then start_watcher() end

  local km = cfg.keymaps or {}
  local function nmap(key, fn, desc) set_global_map("n", key, fn, desc .. " (diff)") end
  nmap(km.toggle_sidebar_panel, M.toggle_sidebar_panel, "Toggle sidebar")
  nmap(km.copy_notes_path, function() require("diff.annotations").copy_notes_path() end, "Copy notes path")
  nmap(km.toggle_notes, function() require("diff.annotations").toggle_notes(M._repo_root) end, "Toggle notes panel")
  nmap(km.preview_branch, M.pick_preview_branch, "Preview branch")
  nmap(km.branch_changes, M.toggle_branch_mode, "Toggle branch changes")

  M.refresh()
  log.info("opened interface for %s (git dir %s) in %.1f ms", info.root, info.git_dir, elapsed())
end

--- Close the interface and return to where it was opened from.
--- @param opts table|nil  { tab_gone = true }: the interface tab was already
---   closed (:tabclose); only clean up, without moving between tabs.
local function close_interface(opts)
  restore_global_maps()
  vim.on_key(nil, mouse_ns)
  hover_enabled = false
  refresh_epoch, refreshing, queued_scope = refresh_epoch + 1, 0, nil
  hover_win, hover_line = nil, nil
  destroy_edge()
  M._preview_branch = nil
  M._branch_mode = false
  pcall(function() require("diff.branch_picker").close() end)
  stop_watcher()
  stop_timer(refresh_timer)
  refresh_timer = nil

  -- The view first, so its watchers and buffers go before the tab does.
  require("diff.diff_view").close()
  require("diff.annotations").close_panel()
  commit_panel.close_tooltip()

  local diff_tab = get_diff_tab()
  local saved = M._saved_layout
  if not opts.tab_gone and saved and vim.api.nvim_tabpage_is_valid(saved.tabpage) then
    vim.api.nvim_set_current_tabpage(saved.tabpage)
    if is_valid_win(saved.win) then vim.api.nvim_set_current_win(saved.win) end
  end
  if diff_tab and vim.api.nvim_tabpage_is_valid(diff_tab) then
    pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(diff_tab))
  end

  clear_panel_state()
  M._main_win, M._saved_layout, M._panel_sizes, M._commit_height = nil, nil, nil, nil
  M._sidebar_hidden = false
  if M._saved_mouse ~= nil then
    vim.o.mouse = M._saved_mouse
    M._saved_mouse = nil
  end
  sync_mousemove()
  log.info("closed interface")
end

function M.close(opts)
  -- Closing the tab fires TabClosed, which must not close again.
  if M._closing then return end
  M._closing = true
  local ok, err = pcall(close_interface, opts or {})
  M._closing = false
  if not ok then error(err, 0) end
end

function M.toggle(info)
  if M.is_open() then
    M.close()
  else
    M.open(info)
  end
end

--- The float highlighting a hovered edge (tests).
function M._edge_float()
  return edge and edge.kind and not tinted_status and edge_float or nil
end

--- Hide or show the sidebar panels without closing the diff view.
function M.toggle_sidebar_panel()
  if not M.is_open() then return end
  local cfg = config.get()
  local caller_win = vim.api.nvim_get_current_win()

  if not M._sidebar_hidden then
    if is_valid_win(M._file_win) then
      M._panel_sizes = { width = vim.api.nvim_win_get_width(M._file_win) }
    end
    save_commit_height()
    clear_hover()
    for _, win in ipairs({ M._bar_win, M._file_win, M._commit_win }) do
      if is_valid_win(win) then pcall(vim.api.nvim_win_close, win, true) end
    end
    clear_panel_state()
    M._sidebar_hidden = true
    return
  end

  local diff_tab = get_diff_tab()
  if not diff_tab then return end
  pcall(vim.api.nvim_set_current_tabpage, diff_tab)

  -- Split from the outermost window on the configured side.
  local target, best
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(diff_tab)) do
    local col = vim.api.nvim_win_get_position(win)[2]
    local better = cfg.sidebar_position == "right" and (not best or col > best) or (not best or col < best)
    if better then target, best = win, col end
  end
  if not target then return end

  if not create_panels(target, (M._panel_sizes and M._panel_sizes.width) or cfg.sidebar_width or 40) then
    for _, win in ipairs({ M._bar_win, M._file_win, M._commit_win }) do
      if is_valid_win(win) then pcall(vim.api.nvim_win_close, win, true) end
    end
    clear_panel_state()
    vim.notify("diff.nvim: not enough room for the sidebar", vim.log.levels.WARN)
    return
  end
  M._sidebar_hidden = false
  M.refresh()
  if is_valid_win(caller_win) then pcall(vim.api.nvim_set_current_win, caller_win) end
end

-- ---------------------------------------------------------------------------
-- Services for the diff view
-- ---------------------------------------------------------------------------

function M.get_main_win()
  return is_valid_win(M._main_win) and M._main_win or nil
end

function M.focus_panel()
  if is_valid_win(M._file_win) then pcall(vim.api.nvim_set_current_win, M._file_win) end
end

--- Open `path` at `line` in the window the interface was opened from (the
--- interface tab stays open; return to it with gt or :tabnext).
function M.open_in_editor(path, line)
  local saved = M._saved_layout
  if saved and vim.api.nvim_tabpage_is_valid(saved.tabpage) then
    vim.api.nvim_set_current_tabpage(saved.tabpage)
    if is_valid_win(saved.win) then vim.api.nvim_set_current_win(saved.win) end
  else
    vim.cmd("tabnew")
  end
  local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
  if not ok then
    log.warn("cannot open %s: %s", path, tostring(err))
    vim.notify("diff.nvim: cannot open " .. path .. ": " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
  vim.cmd("normal! zz")
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------

local function away_from_home()
  return M._home ~= nil and M._repo_root ~= M._home.root
end

--- Back to the branch checked out where the interface was opened.
local function go_home()
  if away_from_home() then
    M.set_preview_branch(nil, M._home.root)
  else
    M.set_preview_branch(nil)
  end
end

local function render_mode_bar()
  mode_bar.render({
    branch = M._preview_branch or M._head_name or "detached HEAD",
    preview = M._preview_branch ~= nil,
    worktree = away_from_home(),
    away = M._preview_branch ~= nil or away_from_home(),
    branch_mode = M._branch_mode,
    actions = {
      pick_branch  = function() M.pick_preview_branch() end,
      go_home      = go_home,
      show_changes = function() if M._branch_mode then M.toggle_branch_mode() end end,
      show_branch  = function() if not M._branch_mode then M.toggle_branch_mode() end end,
    },
  })
end

--- The checked-out branch, read from the work tree's HEAD file (no git
--- process); nil when HEAD is detached.
local function read_head_name()
  local f = M._git_dir and io.open(M._git_dir .. "/HEAD", "r")
  if not f then return nil end
  local line = f:read("*l") or ""
  f:close()
  return line:match("^ref: refs/heads/(.+)$") or line:match("^ref: (.+)$")
end

--- Re-fetch git data for the visible panels.
--- @param opts table|nil
---   scope:    "all" (default) or "worktree": only what a working-tree edit
---             can change (the file status; nothing in branch or preview mode)
---   coalesce: when a refresh is in flight, run once more after it rather
---             than now. For background triggers: a burst of .git changes
---             (a rebase) must not pile up git processes, or keep superseding
---             itself so the panels never update. User actions refresh at once.
function M.refresh(opts)
  opts = opts or {}
  if not M.is_open() or M._sidebar_hidden or not M._repo_root then return end
  local scope = opts.scope or "all"
  if opts.coalesce and refreshing > 0 then
    queued_scope = (queued_scope == "all" or scope == "all") and "all" or "worktree"
    return
  end
  if scope == "worktree" and (M._branch_mode or M._preview_branch) then return end

  local epoch = refresh_epoch
  local function done()
    if epoch ~= refresh_epoch then return end
    refreshing = refreshing - 1
    if refreshing == 0 and queued_scope then
      local q = queued_scope
      queued_scope = nil
      M.refresh({ scope = q })
    end
  end
  if scope == "all" then
    M._head_name = read_head_name()
    render_mode_bar()
  end
  refreshing = refreshing + 1
  file_panel.refresh(M._preview_branch, M._branch_mode, done)
  if scope == "all" and not M._branch_mode then
    refreshing = refreshing + 1
    commit_panel.refresh(M._preview_branch, done)
  end
end

--- Switch the file panel between the working-tree status and everything the
--- branch (the previewed one, else HEAD) changed since its merge base with
--- the base branch. The commit panel is closed while the branch's changes
--- are shown.
function M.toggle_branch_mode()
  if not M.is_open() then return end
  M._branch_mode = not M._branch_mode
  log.info("branch mode %s", M._branch_mode and "on" or "off")
  if M._branch_mode then file_panel.forget_base() end
  if not M._sidebar_hidden then
    local caller_win = vim.api.nvim_get_current_win()
    if M._branch_mode then
      commit_panel.close_tooltip()
      save_commit_height()
      if is_valid_win(M._commit_win) then pcall(vim.api.nvim_win_close, M._commit_win, true) end
      M._commit_win, M._commit_buf = nil, nil
    elseif not create_commit_panel() then
      M._branch_mode = true
      vim.notify("diff.nvim: not enough room for the commit panel", vim.log.levels.WARN)
      pcall(vim.api.nvim_set_current_win, caller_win)
      return
    end
    if not is_valid_win(caller_win) then caller_win = M._file_win end
    pcall(vim.api.nvim_set_current_win, caller_win)
  end
  M.refresh()
end

-- ---------------------------------------------------------------------------
-- Branch preview
-- ---------------------------------------------------------------------------

--- Switch the panels to another work tree: its changes and its commits.
--- @param info {root: string, git_dir: string}
local function switch_root(info)
  if info.root == M._repo_root then return end
  log.info("showing worktree %s", info.root)
  M._repo_root, M._git_dir = info.root, info.git_dir
  require("diff.diff_view").close()
  file_panel.set_root(info.root)
  commit_panel.set_root(info.root)
  if require("diff.config").get().auto_refresh then start_watcher() end
end

local function same_path(a, b)
  return (uv.fs_realpath(a) or a) == (uv.fs_realpath(b) or b)
end

--- @param branch   string|nil  Branch to preview; nil returns to live mode.
--- @param worktree string|nil  Worktree the branch is checked out in. Its
---   changes are shown live rather than the branch's history.
function M.set_preview_branch(branch, worktree)
  log.info("preview branch: %s (worktree %s)", branch or "(live)", worktree or "-")
  if worktree and M._home and same_path(worktree, M._home.root) then
    -- Back to the tree the interface was opened in.
    M._preview_branch = nil
    switch_root(M._home)
    M.refresh()
    return
  end
  if worktree then
    git.get_repo_info(worktree, function(info, err)
      if err or not info then
        vim.notify("diff.nvim: cannot open worktree " .. worktree .. ": " .. tostring(err), vim.log.levels.WARN)
        return
      end
      if not M.is_open() then return end
      M._preview_branch = nil
      switch_root(info)
      M.refresh()
    end)
    return
  end
  M._preview_branch = branch
  M.refresh()
end

function M.pick_preview_branch()
  if not M.is_open() or not M._repo_root then return end
  require("diff.branch_picker").open(M._repo_root, M.set_preview_branch)
end

-- ---------------------------------------------------------------------------
-- Autocommands
-- ---------------------------------------------------------------------------

function M.setup_auto_refresh()
  vim.api.nvim_clear_autocmds({ group = aug })

  -- Panels are rendered to their window width: re-render from cached data
  -- (no git) when a panel's width changes, e.g. while dragging a separator.
  -- VimResized carries no window list and may change every width.
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = aug,
    callback = function()
      if not M.is_open() then return end
      refresh_edge()
      if M._sidebar_hidden then return end
      local resized = vim.v.event and vim.v.event.windows or {}
      -- winfixheight does not stop a mouse drag of the bar's bottom edge.
      if is_valid_win(M._bar_win) and vim.api.nvim_win_get_height(M._bar_win) ~= mode_bar.HEIGHT then
        pcall(vim.api.nvim_win_set_height, M._bar_win, mode_bar.HEIGHT)
      end
      local affects_panels = #resized == 0
      for _, w in ipairs(resized) do
        if w == M._file_win or w == M._commit_win or w == M._bar_win then affects_panels = true end
      end
      if affects_panels then
        mode_bar.on_resize()
        file_panel.on_resize()
        commit_panel.on_resize()
      end
    end,
  })

  -- Hover state belongs to the pointer: drop it when the pointer leaves the
  -- interface, and deliver pointer moves only while its tab is current.
  vim.api.nvim_create_autocmd({ "FocusLost", "TabLeave" }, {
    group = aug,
    callback = function()
      if M.is_open() then clear_hover() end
    end,
  })
  vim.api.nvim_create_autocmd("TabEnter", { group = aug, callback = function() sync_mousemove() end })
  -- :tabclose of the interface tab: clean up what close() would have.
  vim.api.nvim_create_autocmd("TabClosed", {
    group = aug,
    callback = function()
      if M._main_win and not get_diff_tab() then
        log.info("interface tab closed")
        M.close({ tab_gone = true })
      end
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = aug,
    pattern = "DiffNvimViewChanged",
    callback = function(ev)
      file_panel.mark_active(ev.data)
      commit_panel.mark_active(ev.data)
    end,
  })

  if not config.get().auto_refresh then return end
  -- The watcher covers .git changes; these cover working-tree edits, which
  -- change `git status` without touching .git.
  vim.api.nvim_create_autocmd({ "FocusGained", "BufWritePost" }, {
    group = aug,
    callback = function()
      -- With the watcher running, .git changes are already covered.
      if M.is_open() then M.request_refresh(watcher and "worktree" or "all") end
    end,
  })
end

return M
