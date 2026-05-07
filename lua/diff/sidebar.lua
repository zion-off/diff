local M = {}

local file_panel   = require("diff.file_panel")
local commit_panel = require("diff.commit_panel")
local config       = require("diff.config")
local git          = require("diff.git")

local NS_DETAIL = vim.api.nvim_create_namespace("diff_nvim_detail")

-- ---------------------------------------------------------------------------
-- Module-level state
-- ---------------------------------------------------------------------------

M._file_win      = nil
M._commit_win    = nil
M._detail_win    = nil
M._file_buf      = nil
M._commit_buf    = nil
M._detail_buf    = nil
M._main_win      = nil   -- the main editing area (right side) for diff panes
M._repo_root     = nil
M._aug           = nil   -- augroup for auto-refresh
M._saved_layout  = nil   -- saved session state to restore on close
M._sidebar_hidden = false -- true when sidebar panels are temporarily hidden
M._notes_win     = nil   -- notes right-side split window
M._notes_buf     = nil   -- notes buffer
M._fs_watcher    = nil   -- libuv fs_event handle for .git/index watch
M._debounce_timer = nil  -- pending debounce timer for fs_event (module-level for cleanup)
M._detail_req_id = 0     -- monotonic request id for async commit-detail fetches

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- @param win integer|nil
--- @return boolean
local function is_valid_win(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function clear_panel_state()
  M._file_win   = nil
  M._commit_win = nil
  M._detail_win = nil
  M._file_buf   = nil
  M._commit_buf = nil
  M._detail_buf = nil
end

local function clear_notes_state()
  M._notes_win = nil
  M._notes_buf = nil
end

--- @param win integer|nil
local function close_tracked_win(win)
  if is_valid_win(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
end

--- Return the tabpage that owns any tracked diff.nvim window.
--- @return integer|nil
local function get_diff_tab()
  for _, win in ipairs({ M._file_win, M._detail_win, M._commit_win, M._notes_win, M._main_win }) do
    if is_valid_win(win) then
      return vim.api.nvim_win_get_tabpage(win)
    end
  end
  return nil
end

--- Returns true when the plugin layout is currently open.
--- @return boolean
function M.is_open()
  -- When sidebar panels are hidden, check the main diff window instead
  if M._sidebar_hidden then
    return is_valid_win(M._main_win)
  end
  return is_valid_win(M._file_win) and is_valid_win(M._commit_win)
end

--- Cancel and clean up the pending debounce timer (if any).
local function cancel_debounce_timer()
  if M._debounce_timer then
    pcall(function() M._debounce_timer:stop() M._debounce_timer:close() end)
    M._debounce_timer = nil
  end
end

local function stop_fs_watcher()
  if M._fs_watcher then
    pcall(function()
      M._fs_watcher:stop()
      M._fs_watcher:close()
    end)
    M._fs_watcher = nil
  end
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

local function set_detail_win_opts(win)
  set_panel_win_opts(win)
  local wopts = {
    wrap           = true,
    linebreak      = true,
    number         = false,
    relativenumber = false,
  }
  for k, v in pairs(wopts) do
    pcall(vim.api.nvim_set_option_value, k, v, { win = win })
  end
end

local function layout_two_panels()
  if not is_valid_win(M._file_win) or not is_valid_win(M._commit_win) then return end
  local total_h = vim.api.nvim_win_get_height(M._file_win)
                + vim.api.nvim_win_get_height(M._commit_win)
                + 1
  local file_h  = math.max(1, math.floor(total_h * 0.60))
  file_h = math.min(file_h, math.max(1, total_h - 1))
  pcall(vim.api.nvim_win_set_height, M._file_win, file_h)
end

local function layout_three_panels()
  if not is_valid_win(M._file_win) or not is_valid_win(M._detail_win) or not is_valid_win(M._commit_win) then return end
  local total_h = vim.api.nvim_win_get_height(M._file_win)
                + vim.api.nvim_win_get_height(M._detail_win)
                + vim.api.nvim_win_get_height(M._commit_win)
                + 2
  local usable_h = math.max(3, total_h - 2)
  local file_h   = math.max(1, math.floor(usable_h * 0.40))
  local detail_h = math.max(1, math.floor(usable_h * 0.20))
  if file_h + detail_h > usable_h - 1 then
    detail_h = math.max(1, usable_h - file_h - 1)
  end
  pcall(vim.api.nvim_win_set_height, M._file_win, file_h)
  pcall(vim.api.nvim_win_set_height, M._detail_win, detail_h)
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
  if M._file_win or M._commit_win or M._notes_win or M._main_win then
    if not M.is_open() then
      -- Partial state — clean it up first
      M.close()
    else
      return -- already fully open
    end
  end

  M._repo_root = repo_root
  M._sidebar_hidden = false
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
  layout_two_panels()

  set_panel_win_opts(M._file_win)
  set_panel_win_opts(M._commit_win)

  -- Wire up panels
  file_panel.setup(file_buf, M._file_win, repo_root)
  commit_panel.setup(commit_buf, M._commit_win, repo_root)

  -- Focus the file panel to start
  vim.api.nvim_set_current_win(M._file_win)

  -- Start the filesystem watcher now that the repo root is set
  M._start_fs_watcher()

  -- Register interface-scoped keymaps (removed on close)
  local cfg = config.get()
  local km  = cfg.keymaps or {}
  local function nmap(key, fn, desc)
    if key and key ~= "" then
      vim.keymap.set("n", key, fn, { silent = true, desc = desc .. " (diff)" })
    end
  end
  nmap(km.toggle_sidebar_panel or "<leader>gS", function()
    M.toggle_sidebar_panel()
  end, "Toggle sidebar")
  nmap(km.copy_notes_path or "<leader>gy", function()
    require("diff.annotations").copy_notes_path()
  end, "Copy notes path")
  nmap(km.toggle_notes or "<leader>N", function()
    require("diff.annotations").toggle_notes(repo_root)
  end, "Toggle notes panel")

  -- Populate
  M.refresh()
end

--- Close the diff.nvim interface, restore previous layout.
function M.close()
  -- Remove interface-scoped keymaps
  local cfg = config.get()
  local km  = cfg.keymaps or {}
  for _, key in ipairs({
    km.toggle_sidebar_panel or "<leader>gS",
    km.copy_notes_path      or "<leader>gy",
    km.toggle_notes         or "<leader>N",
  }) do
    pcall(vim.keymap.del, "n", key)
  end

  -- Stop the filesystem watcher if running
  stop_fs_watcher()

  -- Cancel any pending debounce timer
  cancel_debounce_timer()

  local diff_tab = get_diff_tab()

  -- Close the notes panel split if open
  close_tracked_win(M._notes_win)
  clear_notes_state()
  commit_panel.close_tooltip()
  M.hide_commit_detail()

  -- Note: We intentionally do NOT delete M._aug (auto-refresh augroup) here.
  -- The callback checks M.is_open() so it's harmless when closed,
  -- and it needs to survive close/reopen cycles.

  -- Close the diff.nvim tab (all windows in it will be closed)
  -- Restore previous layout first (switch to old tab)
  restore_layout(M._saved_layout)
  M._saved_layout = nil

  -- Now close the diff.nvim tab
  if diff_tab and vim.api.nvim_tabpage_is_valid(diff_tab) then
    -- Use tabclose which handles the "last window" edge case correctly
    local tab_nr = vim.api.nvim_tabpage_get_number(diff_tab)
    pcall(vim.cmd, "tabclose " .. tab_nr)
  end

  clear_panel_state()
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
  local caller_tab = vim.api.nvim_get_current_tabpage()
  local caller_win = vim.api.nvim_get_current_win()

  if not M._sidebar_hidden then
    -- Hide: close the two sidebar windows
    M.hide_commit_detail()
    close_tracked_win(M._file_win)
    close_tracked_win(M._commit_win)
    clear_panel_state()
    M._sidebar_hidden = true
  else
    -- Show: recreate the sidebar split alongside the diff area.
    local diff_tab = get_diff_tab()
    if not diff_tab or not vim.api.nvim_tabpage_is_valid(diff_tab) then return end
    if vim.api.nvim_get_current_tabpage() ~= diff_tab then
      local ok_tab = pcall(vim.api.nvim_set_current_tabpage, diff_tab)
      if not ok_tab then return end
    end

    local tab_wins = vim.api.nvim_tabpage_list_wins(diff_tab)
    local target_win = nil
    local position = cfg.sidebar_position == "right" and "botright" or "topleft"

    if cfg.sidebar_position == "right" then
      -- Sidebar goes on the right — split from the rightmost window
      local best_col = -1
      for _, win in ipairs(tab_wins) do
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
      for _, win in ipairs(tab_wins) do
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
    local ok_sw = pcall(vim.api.nvim_set_current_win, target_win)
    if not ok_sw then return end
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
    layout_two_panels()

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

    -- Restore caller focus when possible; otherwise focus file panel.
    local restored = false
    if caller_tab and vim.api.nvim_tabpage_is_valid(caller_tab) then
      if vim.api.nvim_get_current_tabpage() ~= caller_tab then
        restored = pcall(vim.api.nvim_set_current_tabpage, caller_tab)
      else
        restored = true
      end
      if restored and caller_win and vim.api.nvim_win_is_valid(caller_win) then
        restored = pcall(vim.api.nvim_set_current_win, caller_win)
      end
    end
    if not restored and is_valid_win(M._file_win) then
      pcall(vim.api.nvim_set_current_win, M._file_win)
    end
  end
end

--- Render commit detail content into the detail buffer with highlights.
--- @param meta_lines string[]  Output of `git show --no-patch --format=%an%n%ar%n%s%n%b`
--- @param stat_lines string[]  Output of `git show --stat --format=`
--- @param short_hash string
local function render_commit_detail(meta_lines, stat_lines, short_hash)
  if not M._detail_buf or not vim.api.nvim_buf_is_valid(M._detail_buf) then return end

  -- Parse metadata: line 1 = author, line 2 = relative time, line 3 = subject,
  -- remaining lines = body (may be empty).
  local author  = meta_lines[1] or ""
  local reltime = meta_lines[2] or ""
  local subject = meta_lines[3] or ""
  local body    = {}
  for i = 4, #meta_lines do
    table.insert(body, meta_lines[i])
  end
  -- Strip leading/trailing blank lines from body
  while #body > 0 and body[1]  == "" do table.remove(body, 1) end
  while #body > 0 and body[#body] == "" do table.remove(body) end

  -- Find the summary stat line ("N files changed, ...")
  local stat_line = ""
  for i = #stat_lines, 1, -1 do
    if stat_lines[i]:match("changed") then
      stat_line = stat_lines[i]:gsub("^%s+", "")
      break
    end
  end

  -- Build buffer lines
  local lines = {}
  -- Header: "author, 2 hours ago"
  table.insert(lines, author .. (reltime ~= "" and (", " .. reltime) or ""))
  table.insert(lines, "")
  -- Subject (bold via highlight)
  table.insert(lines, subject)
  -- Body
  if #body > 0 then
    table.insert(lines, "")
    for _, l in ipairs(body) do
      table.insert(lines, l)
    end
  end
  -- Stats + hash
  table.insert(lines, "")
  if stat_line ~= "" then
    table.insert(lines, stat_line)
  end
  table.insert(lines, short_hash)

  vim.api.nvim_set_option_value("modifiable", true,  { buf = M._detail_buf })
  vim.api.nvim_buf_clear_namespace(M._detail_buf, NS_DETAIL, 0, -1)
  vim.api.nvim_buf_set_lines(M._detail_buf, 0, -1, false, lines)

  -- Author highlight (col 0 to end of author name)
  if #author > 0 then
    pcall(vim.api.nvim_buf_add_highlight, M._detail_buf, NS_DETAIL,
      "DiffNvimCommitAuthor", 0, 0, #author)
  end
  -- Time highlight (", <reltime>" portion of header line)
  if #reltime > 0 then
    local time_start = #author + 2  -- ", " separator
    pcall(vim.api.nvim_buf_add_highlight, M._detail_buf, NS_DETAIL,
      "DiffNvimCommitTime", 0, time_start, time_start + #reltime)
  end
  -- Subject bold (line index 2)
  pcall(vim.api.nvim_buf_add_highlight, M._detail_buf, NS_DETAIL,
    "DiffNvimCommitSubject", 2, 0, -1)

  -- Stat line highlights: green insertions, red deletions
  if stat_line ~= "" then
    local stat_lnr = #lines - 2  -- 0-based index of the stat line
    local ins_pat  = "%d+ insertions?%(%+%)"
    local del_pat  = "%d+ deletions?%(%-?%)"
    local s, e = stat_line:find(ins_pat)
    if s then
      pcall(vim.api.nvim_buf_add_highlight, M._detail_buf, NS_DETAIL,
        "DiffNvimStatInserted", stat_lnr, s - 1, e)
    end
    s, e = stat_line:find(del_pat)
    if s then
      pcall(vim.api.nvim_buf_add_highlight, M._detail_buf, NS_DETAIL,
        "DiffNvimStatDeleted", stat_lnr, s - 1, e)
    end
  end

  -- Hash highlight (last line)
  pcall(vim.api.nvim_buf_add_highlight, M._detail_buf, NS_DETAIL,
    "DiffNvimCommitHash", #lines - 1, 0, #short_hash)

  vim.api.nvim_set_option_value("modifiable", false, { buf = M._detail_buf })
end

--- Show commit details in a panel between file and commit panels.
--- Makes two parallel async git calls (message + stat) then renders.
--- @param hash string
function M.show_commit_detail(hash)
  if not hash or hash == "" then return end
  if M._sidebar_hidden then return end
  if not is_valid_win(M._file_win) or not is_valid_win(M._commit_win) then return end
  local root = M._repo_root
  if not root or root == "" then return end

  M._detail_req_id = M._detail_req_id + 1
  local req_id    = M._detail_req_id
  local short_hash = hash:sub(1, 7)

  local results   = {}
  local pending   = 2

  local function on_done()
    pending = pending - 1
    if pending > 0 then return end
    -- Stale or layout gone — discard
    if req_id ~= M._detail_req_id then return end
    if M._repo_root ~= root or M._sidebar_hidden then return end
    if not is_valid_win(M._file_win) or not is_valid_win(M._commit_win) then return end

    if not M._detail_buf or not vim.api.nvim_buf_is_valid(M._detail_buf) then
      M._detail_buf = make_panel_buf("diff://commit-detail")
    end

    render_commit_detail(results.meta or {}, results.stat or {}, short_hash)

    if not is_valid_win(M._detail_win) then
      local focus = vim.api.nvim_get_current_win()
      if pcall(vim.api.nvim_set_current_win, M._file_win) then
        vim.cmd("rightbelow split")
        M._detail_win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(M._detail_win, M._detail_buf)
        pcall(vim.api.nvim_set_current_win, focus)
      end
    else
      vim.api.nvim_win_set_buf(M._detail_win, M._detail_buf)
    end

    if is_valid_win(M._detail_win) then
      set_detail_win_opts(M._detail_win)
      layout_three_panels()
    end
  end

  -- author, relative time, subject, body
  git.run({ "show", "--no-patch", "--format=%an%n%ar%n%s%n%b", hash }, root,
    function(lines, _, code)
      if code == 0 then results.meta = lines end
      on_done()
    end)

  -- stat summary
  git.run({ "show", "--stat", "--format=", hash }, root,
    function(lines, _, code)
      if code == 0 then results.stat = lines end
      on_done()
    end)
end

--- Hide commit detail panel and restore two-panel sizing.
function M.hide_commit_detail()
  M._detail_req_id = M._detail_req_id + 1
  close_tracked_win(M._detail_win)
  M._detail_win = nil
  if is_valid_win(M._file_win) and is_valid_win(M._commit_win) then
    layout_two_panels()
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

  if M._file_buf and vim.api.nvim_buf_is_valid(M._file_buf) and is_valid_win(M._file_win) then
    file_panel.refresh(M._file_buf, M._file_win, root)
  end

  if M._commit_buf and vim.api.nvim_buf_is_valid(M._commit_buf) and is_valid_win(M._commit_win) then
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
  stop_fs_watcher()

  -- Cancel any pending debounce timer from the old watcher
  cancel_debounce_timer()

  local root = M._repo_root
  if not root then return end

  local index_path = root .. "/.git/index"

  -- Prefer vim.uv (Neovim 0.10+) over deprecated vim.loop
  local uv = vim.uv or vim.loop
  local ok, fs_event = pcall(uv.new_fs_event)
  if not ok or not fs_event then return end

  local started = fs_event:start(index_path, {}, vim.schedule_wrap(function(err, _, _)
    if err then return end
    -- Debounce: cancel any pending timer and restart it
    if M._debounce_timer then
      cancel_debounce_timer()
    end
    M._debounce_timer = vim.defer_fn(function()
      M._debounce_timer = nil
      if M.is_open() then
        M.refresh()
      end
    end, 300)
  end))

  if started then
    M._fs_watcher = fs_event
  else
    pcall(function()
      fs_event:stop()
      fs_event:close()
    end)
  end
end

return M
