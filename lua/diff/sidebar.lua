local M = {}

local file_panel   = require("diff.file_panel")
local commit_panel = require("diff.commit_panel")
local config       = require("diff.config")

-- ---------------------------------------------------------------------------
-- Module-level state
-- ---------------------------------------------------------------------------

M._file_win   = nil
M._commit_win = nil
M._file_buf   = nil
M._commit_buf = nil
M._repo_root  = nil
M._aug        = nil  -- augroup for auto-refresh

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Returns true when the sidebar is currently open and its windows are valid.
--- @return boolean
function M.is_open()
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
  local opts = {
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
  for k, v in pairs(opts) do
    pcall(vim.api.nvim_set_option_value, k, v, { win = win })
  end
end

-- ---------------------------------------------------------------------------
-- Open / close
-- ---------------------------------------------------------------------------

--- Open the sidebar for the given repository root.
--- @param repo_root string
function M.open(repo_root)
  if M.is_open() then return end

  M._repo_root = repo_root
  local cfg      = config.get()
  local width    = cfg.sidebar_width    or 40
  local position = cfg.sidebar_position or "right"

  -- Save current editing window so we can restore focus
  local prev_win = vim.api.nvim_get_current_win()

  -- Create scratch buffers
  local file_buf   = make_panel_buf("diff://file-panel")
  local commit_buf = make_panel_buf("diff://commit-panel")

  M._file_buf   = file_buf
  M._commit_buf = commit_buf

  -- ── Open the sidebar column ─────────────────────────────────────────────
  -- botright / topleft vsplit creates a column taking the full editor height
  local split_cmd = (position == "right") and "botright" or "topleft"
  vim.cmd(split_cmd .. " " .. width .. "vsplit")

  -- The new window (cursor is here) becomes the top panel
  local file_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(file_win, file_buf)
  M._file_win = file_win

  -- Split below for the commit panel
  vim.cmd("rightbelow split")
  local commit_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(commit_win, commit_buf)
  M._commit_win = commit_win

  -- Size: top panel ≈ 60%, bottom ≈ 40%
  local total_h  = vim.api.nvim_win_get_height(file_win)
                 + 1                                        -- separator
                 + vim.api.nvim_win_get_height(commit_win)
  local file_h   = math.max(4, math.floor(total_h * 0.60))
  local commit_h = math.max(3, total_h - file_h - 1)

  vim.api.nvim_win_set_height(file_win,   file_h)
  vim.api.nvim_win_set_height(commit_win, commit_h)

  set_panel_win_opts(file_win)
  set_panel_win_opts(commit_win)

  -- ── Wire up panels ───────────────────────────────────────────────────────
  file_panel.setup(file_buf, file_win, repo_root)
  commit_panel.setup(commit_buf, commit_win, repo_root)

  -- ── Return focus to the previous editing window ─────────────────────────
  if vim.api.nvim_win_is_valid(prev_win) then
    vim.api.nvim_set_current_win(prev_win)
  end

  M.refresh()
end

--- Close the sidebar and clean up its windows.
function M.close()
  if M._aug then
    pcall(vim.api.nvim_del_augroup_by_id, M._aug)
    M._aug = nil
  end

  for _, win in ipairs({ M._file_win, M._commit_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  M._file_win   = nil
  M._commit_win = nil
  M._file_buf   = nil
  M._commit_buf = nil
end

--- Toggle the sidebar open/closed.
--- @param repo_root string|nil  If nil and sidebar is closed, resolves from cwd.
function M.toggle(repo_root)
  if M.is_open() then
    M.close()
  else
    M.open(repo_root or M._repo_root or vim.fn.getcwd())
  end
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------

--- Refresh both panels (re-fetch git status and commits).
function M.refresh()
  if not M.is_open() then return end

  local root = M._repo_root
  if not root then return end

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

--- Install autocmds that refresh the sidebar when NeoVim regains focus or
--- after a buffer is written.
function M.setup_auto_refresh()
  local cfg = config.get()
  if not cfg.auto_refresh then return end

  if M._aug then
    pcall(vim.api.nvim_del_augroup_by_id, M._aug)
  end

  M._aug = vim.api.nvim_create_augroup("DiffNvimAutoRefresh", { clear = true })

  vim.api.nvim_create_autocmd({ "FocusGained", "BufWritePost" }, {
    group    = M._aug,
    callback = function()
      if M.is_open() then
        M.refresh()
      end
    end,
  })
end

return M
