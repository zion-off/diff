--- diff.nvim — interface layout: a dedicated tab with the sidebar panels
--- (file status on top, commits below) and a main area for the diff view.
---
--- Also owns what is shared across the interface: the git-directory watcher,
--- refresh scheduling, mouse activation and the interface-scoped keymaps.
local M = {}

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
M._panel_sizes    = nil   -- {width, file_height} kept across a hide/show toggle
M._preview_branch = nil   -- when set, panels source data from this branch

local watcher, watch_timer, refresh_timer
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

-- Set once the pointer moves with the button held. The click is read after
-- the fact, so by then a drag (resizing the panels, say) may have carried the
-- pointer onto a row; that row was never clicked.
local dragged = false

local function on_mouse_key(key)
  if key == LEFT_DRAG then
    dragged = true
    return
  end
  if key ~= LEFT_MOUSE then return end
  dragged = false
  vim.schedule(function()
    if dragged then return end
    local mp = vim.fn.getmousepos()
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
      M.refresh()
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
function M.request_refresh()
  if not refresh_timer then refresh_timer = uv.new_timer() end
  refresh_timer:stop()
  refresh_timer:start(REFRESH_DEBOUNCE_MS, 0, vim.schedule_wrap(function()
    if M.is_open() then M.refresh() end
  end))
end

-- ---------------------------------------------------------------------------
-- Panels
-- ---------------------------------------------------------------------------

local function clear_panel_state()
  M._file_win, M._commit_win, M._file_buf, M._commit_buf = nil, nil, nil, nil
end

--- Return the tabpage of the interface, if it is open.
local function get_diff_tab()
  for _, win in ipairs({ M._file_win or false, M._commit_win or false, M._main_win or false }) do
    if win and is_valid_win(win) then return vim.api.nvim_win_get_tabpage(win) end
  end
  return nil
end

function M.is_open()
  if M._sidebar_hidden then
    return is_valid_win(M._main_win)
  end
  return is_valid_win(M._file_win) and is_valid_win(M._commit_win)
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

--- Create the two panel windows by splitting off `anchor`.
local function create_panels(anchor, width)
  local position = config.get().sidebar_position == "right" and "botright" or "topleft"
  vim.api.nvim_set_current_win(anchor)
  vim.cmd(position .. " " .. width .. " vsplit")
  M._file_win = vim.api.nvim_get_current_win()
  M._file_buf = make_panel_buf("diff://file-panel")
  vim.api.nvim_win_set_buf(M._file_win, M._file_buf)

  vim.cmd("rightbelow split")
  M._commit_win = vim.api.nvim_get_current_win()
  M._commit_buf = make_panel_buf("diff://commit-panel")
  vim.api.nvim_win_set_buf(M._commit_win, M._commit_buf)

  set_panel_win_opts(M._file_win)
  set_panel_win_opts(M._commit_win)
  file_panel.setup(M._file_buf, M._file_win, M._repo_root)
  commit_panel.setup(M._commit_buf, M._commit_win, M._repo_root)
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

  create_panels(M._main_win, cfg.sidebar_width or 40)
  layout_two_panels()
  vim.api.nvim_set_current_win(M._file_win)

  if cfg.auto_refresh then start_watcher() end

  local km = cfg.keymaps or {}
  local function nmap(key, fn, desc) set_global_map("n", key, fn, desc .. " (diff)") end
  nmap(km.toggle_sidebar_panel, M.toggle_sidebar_panel, "Toggle sidebar")
  nmap(km.copy_notes_path, function() require("diff.annotations").copy_notes_path() end, "Copy notes path")
  nmap(km.toggle_notes, function() require("diff.annotations").toggle_notes(M._repo_root) end, "Toggle notes panel")
  nmap(km.preview_branch, M.pick_preview_branch, "Preview branch")

  M.refresh()
  log.info("opened interface for %s (git dir %s) in %.1f ms", info.root, info.git_dir, elapsed())
end

--- Close the interface and return to where it was opened from.
function M.close()
  restore_global_maps()
  vim.on_key(nil, mouse_ns)
  M._preview_branch = nil
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
  if saved and vim.api.nvim_tabpage_is_valid(saved.tabpage) then
    vim.api.nvim_set_current_tabpage(saved.tabpage)
    if is_valid_win(saved.win) then vim.api.nvim_set_current_win(saved.win) end
  end
  if diff_tab and vim.api.nvim_tabpage_is_valid(diff_tab) then
    pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(diff_tab))
  end

  clear_panel_state()
  M._main_win, M._saved_layout, M._panel_sizes = nil, nil, nil
  M._sidebar_hidden = false
  if M._saved_mouse ~= nil then
    vim.o.mouse = M._saved_mouse
    M._saved_mouse = nil
  end
  log.info("closed interface")
end

function M.toggle(info)
  if M.is_open() then
    M.close()
  else
    M.open(info)
  end
end

--- Hide or show the sidebar panels without closing the diff view.
function M.toggle_sidebar_panel()
  if not M.is_open() then return end
  local cfg = config.get()
  local caller_win = vim.api.nvim_get_current_win()

  if not M._sidebar_hidden then
    if is_valid_win(M._file_win) then
      M._panel_sizes = {
        width       = vim.api.nvim_win_get_width(M._file_win),
        file_height = vim.api.nvim_win_get_height(M._file_win),
      }
    end
    for _, win in ipairs({ M._file_win, M._commit_win }) do
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

  create_panels(target, (M._panel_sizes and M._panel_sizes.width) or cfg.sidebar_width or 40)
  if M._panel_sizes and M._panel_sizes.file_height then
    pcall(vim.api.nvim_win_set_height, M._file_win, M._panel_sizes.file_height)
  else
    layout_two_panels()
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

--- Re-fetch git data for the visible panels.
function M.refresh()
  if not M.is_open() or M._sidebar_hidden or not M._repo_root then return end
  file_panel.refresh(M._preview_branch)
  commit_panel.refresh(M._preview_branch)
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
      if not M.is_open() or M._sidebar_hidden then return end
      local resized = vim.v.event and vim.v.event.windows or {}
      local affects_panels = #resized == 0
      for _, w in ipairs(resized) do
        if w == M._file_win or w == M._commit_win then affects_panels = true end
      end
      if affects_panels then
        file_panel.on_resize()
        commit_panel.on_resize()
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
      if M.is_open() then M.request_refresh() end
    end,
  })
end

return M
