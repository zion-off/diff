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
  -- highlights.setup already installs a ColorScheme autocmd; nothing extra needed here.

  local cfg = config.get()
  local km  = cfg.keymaps or {}

  -- ── Global keymaps ────────────────────────────────────────────────────────

  local function nmap(key, fn, desc)
    if key and key ~= "" then
      vim.keymap.set("n", key, fn, { silent = true, desc = "diff.nvim: " .. desc })
    end
  end

  -- Toggle sidebar
  nmap(km.toggle_sidebar or "<leader>gs", function()
    M.toggle()
  end, "toggle sidebar")

  -- Refresh panels
  nmap(km.refresh or "<leader>gr", function()
    M.refresh()
  end, "refresh panels")

  -- Toggle notes panel
  nmap(km.toggle_notes or "<leader>N", function()
    M._with_root(function(root)
      require("diff.annotations").toggle_notes(root)
    end)
  end, "toggle notes panel")

  -- Auto-refresh sidebar on focus / save
  sidebar.setup_auto_refresh()
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Resolve the current repository root and call cb(root).
--- Shows a warning if not inside a git repository.
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
-- Public API (usable without calling setup first)
-- ---------------------------------------------------------------------------

--- Open the sidebar.
function M.open()
  M._with_root(function(root)
    sidebar.open(root)
  end)
end

--- Close the sidebar.
function M.close()
  sidebar.close()
end

--- Toggle the sidebar open / closed.
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
--- @param staged    boolean
function M.open_diff(file_path, staged)
  M._with_root(function(root)
    local dv = require("diff.diff_view")
    dv.open_file_diff(root, {
      path   = file_path,
      status = staged and "modified" or "modified",
      staged = staged,
    })
  end)
end

return M
