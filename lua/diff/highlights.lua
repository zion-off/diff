local M = {}

-- Default highlight definitions: group name → nvim_set_hl opts
local defaults = {
  DiffNvimAdded           = { bg = "#0e2a0e" },
  DiffNvimRemoved         = { bg = "#2a0e0e" },
  DiffNvimFiller          = { bg = "#1e1e2e" },
  DiffNvimAddedWord       = { bg = "#1a5c1a" },
  DiffNvimRemovedWord     = { bg = "#5c1a1a" },
  DiffNvimGutterAdded     = { fg = "#3a8c3a", bold = true },
  DiffNvimGutterRemoved   = { fg = "#8c3a3a", bold = true },
  DiffNvimGutterChanged   = { fg = "#8c7a3a", bold = true },
  DiffNvimStatusModified  = { fg = "#c0a020" },
  DiffNvimStatusAdded     = { fg = "#20a020" },
  DiffNvimStatusDeleted   = { fg = "#a02020" },
  DiffNvimStatusRenamed   = { fg = "#2080a0" },
  DiffNvimStatusUntracked = { fg = "#808080" },
  DiffNvimSectionHeader   = { fg = "#c0c0c0", bold = true },
  DiffNvimStagedFile      = { fg = "#90c090" },
  DiffNvimUnstagedFile    = { fg = "#c0c080" },
  DiffNvimDeletedFile     = { fg = "#c09090" },
  DiffNvimCommitHash      = { fg = "#80a0c0" },
  DiffNvimCommitAuthor    = { fg = "#a080a0" },
  DiffNvimCommitTime      = { fg = "#708070" },
  DiffNvimCommitSubject   = { fg = "#c0c0c0" },
  DiffNvimRefHead         = { fg = "#f0d080", bold = true },
  DiffNvimRefBranch       = { fg = "#80d080" },
  DiffNvimRefRemote       = { fg = "#80a0d0" },
  DiffNvimRefTag          = { fg = "#d080d0" },
  DiffNvimNoteHeader      = { fg = "#d0b060", bold = true },
  DiffNvimNoteText        = { fg = "#c0c0c0" },
  DiffNvimSeparator       = { fg = "#606070", bg = "#1a1a2a", italic = true },
  DiffNvimCommitFileEntry = { fg = "#a0a0b0" },
}

-- Merged table of defaults + user overrides, populated in setup()
local applied = {}

local function apply_highlights()
  for group, opts in pairs(applied) do
    vim.api.nvim_set_hl(0, group, opts)
  end
end

function M.setup(opts)
  -- opts.highlights is a table of { GroupName = { bg=..., fg=..., ... } }
  local overrides = (opts and opts.highlights) or {}

  applied = {}
  for group, def_opts in pairs(defaults) do
    if overrides[group] then
      -- User override: deep-merge so they can change individual fields
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
