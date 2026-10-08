--- diff.nvim — public API and plugin setup.
local M = {}

local config     = require("diff.config")
local highlights = require("diff.highlights")
local sidebar    = require("diff.sidebar")
local git        = require("diff.git")
local log        = require("diff.log")

-- ---------------------------------------------------------------------------
-- setup
-- ---------------------------------------------------------------------------

--- Bootstrap the plugin.  Call this once from your config:
---   require("diff").setup({ ... })
---
--- @param opts table|nil  See config.lua for available options.
function M.setup(opts)
  config.setup(opts)
  log.setup(config.get().log_level)
  highlights.setup(config.get())

  local cfg = config.get()
  local km  = cfg.keymaps or {}

  -- ── Global keymaps ────────────────────────────────────────────────────────

  local function nmap(key, fn, desc)
    if key and key ~= "" then
      vim.keymap.set("n", key, fn, { silent = true, desc = desc .. " (diff)" })
    end
  end

  -- Toggle interface (global — needed to open the plugin)
  nmap(km.toggle_sidebar or "<leader>gs", function()
    M.toggle()
  end, "Toggle interface")

  -- Auto-refresh sidebar on focus / save (and start fs watcher)
  sidebar.setup_auto_refresh()
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Resolve the current repository and call cb(info).
--- @param cb fun(info: {root: string, git_dir: string})
function M._with_repo(cb)
  local cwd = vim.fn.getcwd()
  git.get_repo_info(cwd, function(info, err)
    if not info then
      log.scope("init").info("not a git repository (%s): %s", cwd, err or "?")
      vim.notify("diff.nvim: not in a git repository", vim.log.levels.WARN)
      return
    end
    cb(info)
  end)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Open the diff.nvim interface.
function M.open()
  M._with_repo(sidebar.open)
end

--- Close the interface.
function M.close()
  sidebar.close()
end

--- Toggle the interface open / closed.
function M.toggle()
  if sidebar.is_open() then
    sidebar.close()
  else
    M._with_repo(sidebar.open)
  end
end

--- Refresh file and commit panels.
function M.refresh()
  sidebar.refresh()
end

--- Open the branch picker to preview another branch's history without checking
--- it out. In preview mode the commit panel is sourced from the chosen branch
--- and the file panel shows only a "Preview: <branch>" header (working-tree
--- changes belong to the live HEAD only). Selecting the current branch returns
--- to normal live mode. Opens the interface first if it is closed.
function M.preview_branch()
  if not sidebar.is_open() then
    M._with_repo(function(info)
      sidebar.open(info)
      vim.schedule(function() sidebar.pick_preview_branch() end)
    end)
  else
    sidebar.pick_preview_branch()
  end
end

--- Open the diff view for a file programmatically.
--- @param file_path string  Path relative to the repo root.
--- @param staged    boolean  true to diff against the staged (index) version.
function M.open_diff(file_path, staged)
  M._with_repo(function(info)
    require("diff.diff_view").open(info.root, {
      kind   = "worktree",
      path   = file_path,
      status = "modified",
      staged = staged or false,
    })
  end)
end

return M
