--- diff.nvim — public API and plugin setup.
local M = {}

local config     = require("diff.config")
local highlights = require("diff.highlights")
local sidebar    = require("diff.sidebar")
local git        = require("diff.git")

-- ---------------------------------------------------------------------------
-- setup
-- ---------------------------------------------------------------------------

--- Bootstrap the plugin.  Call this once from your config:
---   require("diff").setup({ ... })
---
--- @param opts table|nil  See config.lua for available options.
function M.setup(opts)
  config.setup(opts)
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

--- Resolve the current repository root and call cb(root).
--- @param cb fun(root: string)
function M._with_root(cb)
  local cwd = vim.fn.getcwd()
  git.get_repo_root(cwd, function(root, err)
    if err or not root then
      vim.notify("diff.nvim: not in a git repository", vim.log.levels.WARN)
      return
    end
    cb(root)
  end)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Open the diff.nvim interface.
function M.open()
  M._with_root(function(root)
    sidebar.open(root)
  end)
end

--- Close the interface.
function M.close()
  sidebar.close()
end

--- Toggle the interface open / closed.
function M.toggle()
  M._with_root(function(root)
    sidebar.toggle(root)
  end)
end

--- Refresh file and commit panels.
function M.refresh()
  sidebar.refresh()
end

--- Open the diff view for a file programmatically.
--- @param file_path string  Path relative to the repo root.
--- @param staged    boolean  true to diff against the staged (index) version.
function M.open_diff(file_path, staged)
  M._with_root(function(root)
    local dv = require("diff.diff_view")
    dv.open_file_diff(root, {
      path   = file_path,
      status = "modified",
      staged = staged or false,
    })
  end)
end

return M
