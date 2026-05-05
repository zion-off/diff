local M = {}

-- Default highlight definitions: group name -> nvim_set_hl opts.
-- Uses `link` where appropriate so that the plugin degrades gracefully
-- on both dark and light backgrounds. Hardcoded bg/fg values only for
-- groups that have no meaningful built-in equivalent.
local defaults = {
  -- Diff line backgrounds (priority 50: below tree-sitter ~100)
  DiffNvimAdded           = { link = "DiffAdd" },
  DiffNvimRemoved         = { link = "DiffDelete" },
  DiffNvimFiller          = { bg = "#1e1e2e" },
  DiffNvimFillerChar      = { fg = "#3a3a4a" },

  -- Word-level highlights (priority 60)
  DiffNvimAddedWord       = { link = "DiffText" },
  DiffNvimRemovedWord     = { bg = "#5c1a1a", fg = "NONE" },

  -- Gutter indicators
  DiffNvimGutterAdded     = { fg = "#3a8c3a", bold = true },
  DiffNvimGutterRemoved   = { fg = "#8c3a3a", bold = true },
  DiffNvimGutterChanged   = { fg = "#8c7a3a", bold = true },

  -- File panel status badges
  DiffNvimStatusModified  = { link = "Type" },
  DiffNvimStatusAdded     = { link = "String" },
  DiffNvimStatusDeleted   = { link = "Error" },
  DiffNvimStatusRenamed   = { link = "Special" },
  DiffNvimStatusUntracked = { link = "Comment" },

  -- Section headers (bold)
  DiffNvimSectionHeader   = { bold = true, link = "Title" },

  -- File panel names
  DiffNvimStagedFile      = { link = "String" },
  DiffNvimUnstagedFile    = { link = "Normal" },
  DiffNvimDeletedFile     = { link = "Error" },

  -- Commit panel
  DiffNvimCommitHash      = { link = "Identifier" },
  DiffNvimCommitAuthor    = { link = "Special" },
  DiffNvimCommitTime      = { link = "Comment" },
  DiffNvimCommitSubject   = { link = "Normal" },

  -- Ref badges
  DiffNvimRefHead         = { fg = "#f0d080", bold = true },
  DiffNvimRefBranch       = { link = "String" },
  DiffNvimRefRemote       = { link = "Identifier" },
  DiffNvimRefTag          = { link = "Constant" },

  -- Notes
  DiffNvimNoteHeader      = { bold = true, link = "WarningMsg" },
  DiffNvimNoteText        = { link = "Comment" },
  DiffNvimNoteMarker      = { fg = "#d0a040", bold = true },
  DiffNvimNoteVirtText    = { fg = "#808080", italic = true },

  -- Separators (collapsed hunks)
  DiffNvimSeparator       = { fg = "#606070", bg = "#1a1a2a", italic = true },

  -- Commit file entries
  DiffNvimCommitFileEntry = { link = "Normal" },

  -- Winbar for diff panes
  DiffNvimWinbar          = { bold = true, link = "StatusLine" },
}

-- Merged table of defaults + user overrides, populated in setup()
local applied = {}

local function apply_highlights()
  for group, opts in pairs(applied) do
    -- If the group uses `link`, set it as a link; otherwise set raw attrs
    if opts.link and not opts.bg and not opts.fg then
      vim.api.nvim_set_hl(0, group, { link = opts.link, default = false })
    else
      -- Remove 'link' if other attrs are also specified (user override)
      local hl_opts = vim.deepcopy(opts)
      hl_opts.link = nil
      vim.api.nvim_set_hl(0, group, hl_opts)
    end
  end
end

function M.setup(opts)
  local overrides = (opts and opts.highlights) or {}

  applied = {}
  for group, def_opts in pairs(defaults) do
    if overrides[group] then
      applied[group] = vim.tbl_deep_extend("force", vim.deepcopy(def_opts), overrides[group])
    else
      applied[group] = vim.deepcopy(def_opts)
    end
  end

  -- Also apply any extra groups the user defined that aren't in defaults
  for group, hl_opts in pairs(overrides) do
    if not applied[group] then
      applied[group] = vim.deepcopy(hl_opts)
    end
  end

  apply_highlights()

  -- Re-apply on every ColorScheme change so our groups survive theme switches
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("DiffNvimHighlights", { clear = true }),
    callback = apply_highlights,
  })
end

return M
