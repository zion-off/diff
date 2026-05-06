local M = {}

local file_panel   = require("diff.file_panel")
local commit_panel = require("diff.commit_panel")
local config       = require("diff.config")

-- ---------------------------------------------------------------------------
-- Module-level state
-- ---------------------------------------------------------------------------

M._file_win      = nil
M._commit_win    = nil
M._file_buf      = nil
M._commit_buf    = nil
M._main_win      = nil   -- the main editing area (right side) for diff panes
M._repo_root     = nil
M._aug           = nil   -- augroup for auto-refresh
M._saved_layout  = nil   -- saved session state to restore on close
M._sidebar_hidden = false -- true when sidebar panels are temporarily hidden
M._notes_win     = nil   -- notes right-side split window
M._notes_buf     = nil   -- notes buffer
M._fs_watcher    = nil   -- libuv fs_event handle for .git/index watch

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Returns true when the plugin layout is currently open.
--- @return boolean
function M.is_open()
  -- When sidebar panels are hidden, check the main diff window instead
  if M._sidebar_hidden then
    return M._main_win ~= nil and vim.api.nvim_win_is_valid(M._main_win)
  end
  return M._file_win ~= nil
    and vim.api.nvim_win_is_valid(M._file_win)
    and M._commit_win ~= nil
    and vim.api.nvim_win_is_valid(M._commit_win)
end

--- Create a scratch buffer suitable for a sidebar panel.
--- @param  name string
--- @return integer
local function make_panel_buf(name)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == name then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  return buf
end

--- Apply common window options for a sidebar panel.
--- @param win integer
local function set_panel_win_opts(win)
  local wopts = {
    number         = false,
    relativenumber = false,
    wrap           = false,
    signcolumn     = "no",
    foldcolumn     = "0",
    cursorline     = true,
    winfixwidth    = true,
    spell          = false,
    list           = false,
  }
  for k, v in pairs(wopts) do
    pcall(vim.api.nvim_set_option_value, k, v, { win = win })
  end
end

--- Save the current window/buffer layout so it can be restored later.
local function save_layout()
  local layout = {
    tabpage   = vim.api.nvim_get_current_tabpage(),
    wins      = {},
    current   = vim.api.nvim_get_current_win(),
  }
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) then
      table.insert(layout.wins, {
        win  = win,
        buf  = vim.api.nvim_win_get_buf(win),
      })
    end
  end
  return layout
end

--- Restore a previously saved layout. Closes the diff.nvim tab if we opened one.
local function restore_layout(saved)
  if not saved then return end
  -- Switch back to original tabpage if it still exists
  if saved.tabpage and vim.api.nvim_tabpage_is_valid(saved.tabpage) then
    vim.api.nvim_set_current_tabpage(saved.tabpage)
  end
  -- Restore cursor to the original window if valid
  if saved.current and vim.api.nvim_win_is_valid(saved.current) then
    vim.api.nvim_set_current_win(saved.current)
  end
end

-- ---------------------------------------------------------------------------
-- Open / close — takes over a new tab to create the full layout
-- ---------------------------------------------------------------------------

--- Open the diff.nvim interface.
--- Creates a new tab with: sidebar (left: file panel top, commit panel bottom)
--- and main editing area on the right.
--- @param repo_root string
function M.open(repo_root)
  -- Clean up any partial state from a previous session
  if M._file_win or M._commit_win or M._main_win then
    if not M.is_open() then
      -- Partial state — clean it up first
      M.close()
    else
      return -- already fully open
    end
  end

  M._repo_root = repo_root
  local cfg    = config.get()
  local width  = cfg.sidebar_width or 40

  -- Save the current layout before taking over
  M._saved_layout = save_layout()

  -- Open a new tab for the diff.nvim interface
  vim.cmd("tabnew")

  -- The new tab has one window — this becomes the main area (right side)
  M._main_win = vim.api.nvim_get_current_win()

  -- Create a scratch buffer for the main area (placeholder)
  local main_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = main_buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = main_buf })
  vim.api.nvim_buf_set_lines(main_buf, 0, -1, false, {
    "",
    "  diff.nvim",
    "",
    "  Select a file from the sidebar to view its diff.",
    "  Press 'q' to close.",
    "",
  })
  vim.api.nvim_win_set_buf(M._main_win, main_buf)

  -- Create sidebar split (respects sidebar_position config)
  local position = cfg.sidebar_position == "right" and "botright" or "topleft"
  vim.cmd(position .. " " .. width .. " vsplit")
  local sidebar_win = vim.api.nvim_get_current_win()

  -- Create the file panel buffer and assign it to the sidebar
  local file_buf = make_panel_buf("diff://file-panel")
  vim.api.nvim_win_set_buf(sidebar_win, file_buf)
  M._file_win = sidebar_win
  M._file_buf = file_buf

  -- Split below for the commit panel
  vim.cmd("rightbelow split")
  local commit_win = vim.api.nvim_get_current_win()
  local commit_buf = make_panel_buf("diff://commit-panel")
  vim.api.nvim_win_set_buf(commit_win, commit_buf)
  M._commit_win = commit_win
  M._commit_buf = commit_buf

  -- Size: file panel ≈ 60%, commit panel ≈ 40%
  local total_h  = vim.api.nvim_win_get_height(M._file_win)
                 + vim.api.nvim_win_get_height(commit_win)
                 + 1  -- status line separator
  local file_h   = math.max(4, math.floor(total_h * 0.60))
  vim.api.nvim_win_set_height(M._file_win, file_h)

  set_panel_win_opts(M._file_win)
  set_panel_win_opts(M._commit_win)

  -- Wire up panels
  file_panel.setup(file_buf, M._file_win, repo_root)
  commit_panel.setup(commit_buf, M._commit_win, repo_root)

  -- Focus the file panel to start
  vim.api.nvim_set_current_win(M._file_win)

  -- Start the filesystem watcher now that the repo root is set
  M._start_fs_watcher()

  -- Populate
  M.refresh()
end

--- Close the diff.nvim interface, restore previous layout.
function M.close()
  -- Stop the filesystem watcher if running
  if M._fs_watcher then
    pcall(function() M._fs_watcher:stop() end)
    M._fs_watcher = nil
  end

  -- Close the notes panel split if open
  if M._notes_win and vim.api.nvim_win_is_valid(M._notes_win) then
    pcall(vim.api.nvim_win_close, M._notes_win, true)
  end
  M._notes_win = nil
  M._notes_buf = nil

  -- Note: We intentionally do NOT delete M._aug (auto-refresh augroup) here.
  -- The callback checks M.is_open() so it's harmless when closed,
  -- and it needs to survive close/reopen cycles.

  -- Close the diff.nvim tab (all windows in it will be closed)
  -- First, check if the current tab is the diff.nvim tab
  local cur_tab = vim.api.nvim_get_current_tabpage()
  local diff_tab = nil

  -- Find the tab containing our file panel window (or main window if sidebar hidden)
  if M._file_win and vim.api.nvim_win_is_valid(M._file_win) then
    diff_tab = vim.api.nvim_win_get_tabpage(M._file_win)
  elseif M._main_win and vim.api.nvim_win_is_valid(M._main_win) then
    diff_tab = vim.api.nvim_win_get_tabpage(M._main_win)
  end

  -- Restore previous layout first (switch to old tab)
  restore_layout(M._saved_layout)
  M._saved_layout = nil

  -- Now close the diff.nvim tab
  if diff_tab and vim.api.nvim_tabpage_is_valid(diff_tab) then
    -- Use tabclose which handles the "last window" edge case correctly
    local tab_nr = vim.api.nvim_tabpage_get_number(diff_tab)
    pcall(vim.cmd, "tabclose " .. tab_nr)
  end

  M._file_win      = nil
  M._commit_win    = nil
  M._file_buf      = nil
  M._commit_buf    = nil
  M._main_win      = nil
  M._sidebar_hidden = false
end

--- Toggle the interface open/closed.
--- @param repo_root string|nil
function M.toggle(repo_root)
  if M.is_open() then
    M.close()
  else
    M.open(repo_root or M._repo_root or vim.fn.getcwd())
  end
end

--- Toggle just the sidebar panels (file + commit) without closing the diff view.
--- When hidden the diff panes expand to fill the space.
--- When shown again the sidebar is recreated from cached state.
function M.toggle_sidebar_panel()
  if not M.is_open() then return end

  local cfg   = config.get()
  local width = cfg.sidebar_width or 40

  if not M._sidebar_hidden then
    -- Hide: close the two sidebar windows
    if M._file_win and vim.api.nvim_win_is_valid(M._file_win) then
      pcall(vim.api.nvim_win_close, M._file_win, true)
    end
    if M._commit_win and vim.api.nvim_win_is_valid(M._commit_win) then
      pcall(vim.api.nvim_win_close, M._commit_win, true)
    end
    M._file_win    = nil
    M._commit_win  = nil
    M._sidebar_hidden = true
  else
    -- Show: recreate the sidebar split alongside the diff area.
    local target_win = nil
    local position = cfg.sidebar_position == "right" and "botright" or "topleft"

    if cfg.sidebar_position == "right" then
      -- Sidebar goes on the right — split from the rightmost window
      local best_col = -1
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(win) then
          local pos = vim.api.nvim_win_get_position(win)
          if pos[2] > best_col then
            best_col   = pos[2]
            target_win = win
          end
        end
      end
    else
      -- Sidebar goes on the left — split from the leftmost window
      local best_col = math.huge
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(win) then
          local pos = vim.api.nvim_win_get_position(win)
          if pos[2] < best_col then
            best_col   = pos[2]
            target_win = win
          end
        end
      end
    end

    if not target_win then return end
    vim.api.nvim_set_current_win(target_win)
    vim.cmd(position .. " " .. width .. " vsplit")
    local sidebar_win = vim.api.nvim_get_current_win()

    -- Re-use existing buffers (they were wiped with the window, recreate)
    local file_buf = make_panel_buf("diff://file-panel")
    vim.api.nvim_win_set_buf(sidebar_win, file_buf)
    M._file_win = sidebar_win
    M._file_buf = file_buf

    vim.cmd("rightbelow split")
    local commit_win = vim.api.nvim_get_current_win()
    local commit_buf = make_panel_buf("diff://commit-panel")
    vim.api.nvim_win_set_buf(commit_win, commit_buf)
    M._commit_win = commit_win
    M._commit_buf = commit_buf

    -- Size: file panel ≈ 60%
    local total_h = vim.api.nvim_win_get_height(M._file_win)
                  + vim.api.nvim_win_get_height(commit_win)
                  + 1
    local file_h  = math.max(4, math.floor(total_h * 0.60))
    vim.api.nvim_win_set_height(M._file_win, file_h)

    set_panel_win_opts(M._file_win)
    set_panel_win_opts(M._commit_win)

    -- Wire up and repopulate from last-fetched git data (no re-run)
    local root = M._repo_root
    file_panel.setup(file_buf, M._file_win, root)
    commit_panel.setup(commit_buf, M._commit_win, root)

    -- Clear hidden flag before refreshing so refresh() doesn't skip panels
    M._sidebar_hidden = false

    -- Refresh using cached state
    M.refresh()

    -- Restore focus to file panel
    vim.api.nvim_set_current_win(M._file_win)
  end
end

--- Get the main editing window (right side) for the diff view to use.
--- @return integer|nil
function M.get_main_win()
  if M._main_win and vim.api.nvim_win_is_valid(M._main_win) then
    return M._main_win
  end
  return nil
end

--- Set/update the main window reference (called by diff_view when it creates panes).
--- @param win integer
function M.set_main_win(win)
  M._main_win = win
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------

--- Refresh both panels (re-fetch git status and commits).
function M.refresh()
  if not M.is_open() then return end

  local root = M._repo_root
  if not root then return end

  -- Only refresh panels when they are visible (skip when hidden)
  if M._sidebar_hidden then return end

  if M._file_buf and vim.api.nvim_buf_is_valid(M._file_buf) then
    file_panel.refresh(M._file_buf, M._file_win, root)
  end

  if M._commit_buf and vim.api.nvim_buf_is_valid(M._commit_buf) then
    commit_panel.refresh(M._commit_buf, M._commit_win, root)
  end
end

-- ---------------------------------------------------------------------------
-- Auto-refresh
-- ---------------------------------------------------------------------------

function M.setup_auto_refresh()
  local cfg = config.get()
  if not cfg.auto_refresh then return end

  if M._aug then
    pcall(vim.api.nvim_del_augroup_by_id, M._aug)
  end

  M._aug = vim.api.nvim_create_augroup("DiffNvimAutoRefresh", { clear = true })

  -- Keep FocusGained and BufWritePost autocmds — they complement the watcher
  -- for cases like rebases that touch more than just the index.
  vim.api.nvim_create_autocmd({ "FocusGained", "BufWritePost" }, {
    group    = M._aug,
    callback = function()
      if M.is_open() then
        M.refresh()
      end
    end,
  })

  -- Filesystem watch on <repo_root>/.git/index for instant refresh.
  -- Started when the sidebar opens (called from open()), stopped on close().
  -- We defer the actual watch start until after the repo root is set.
  vim.schedule(function()
    M._start_fs_watcher()
  end)
end

--- Start (or restart) the libuv filesystem watcher on .git/index.
function M._start_fs_watcher()
  -- Stop any previous watcher
  if M._fs_watcher then
    pcall(function() M._fs_watcher:stop() end)
    M._fs_watcher = nil
  end

  local root = M._repo_root
  if not root then return end

  local index_path = root .. "/.git/index"

  local ok, fs_event = pcall(vim.loop.new_fs_event)
  if not ok or not fs_event then return end

  local debounce_timer = nil

  local started = fs_event:start(index_path, {}, vim.schedule_wrap(function(err, _, _)
    if err then return end
    -- Debounce: cancel any pending timer and restart it
    if debounce_timer then
      pcall(function() debounce_timer:stop() debounce_timer:close() end)
      debounce_timer = nil
    end
    debounce_timer = vim.defer_fn(function()
      debounce_timer = nil
      if M.is_open() then
        M.refresh()
      end
    end, 300)
  end))

  if started then
    M._fs_watcher = fs_event
  else
    pcall(function() fs_event:stop() end)
  end
end

return M
