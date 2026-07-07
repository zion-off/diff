local M = {}

-- ---------------------------------------------------------------------------
-- Color palettes — chosen to be muted enough that tree-sitter foreground
-- colors are clearly legible on top of the diff background tints.
-- Priorities: PRIORITY_LINE_BG (50) < TS (~100) < PRIORITY_WORD_HL (150)
-- ---------------------------------------------------------------------------

-- Dark-background palette (vim.o.background == "dark")
local DARK = {
  added_bg        = "#0e2716",  -- very dark green  — line background
  removed_bg      = "#2b1116",  -- very dark red    — line background
  added_word_bg   = "#1a4728",  -- medium dark green — word highlight
  removed_word_bg = "#4a1520",  -- medium dark red   — word highlight
  filler_bg       = "#1e1e2e",
  filler_fg       = "#3a3a4a",
  separator_bg    = "#1a1a2a",
  separator_fg    = "#606070",
  gutter_added    = "#3a8c3a",
  gutter_removed  = "#8c3a3a",
  gutter_changed  = "#8c7a3a",
  ref_head        = "#f0d080",
  note_marker     = "#d0a040",
  note_virt       = "#808080",
}

-- Light-background palette (vim.o.background == "light")
local LIGHT = {
  added_bg        = "#dff0e8",  -- very pale green  — line background
  removed_bg      = "#f0dde0",  -- very pale red    — line background
  added_word_bg   = "#b5ddc7",  -- moderate green   — word highlight
  removed_word_bg = "#dbb5bc",  -- moderate red     — word highlight
  filler_bg       = "#f0f0f5",
  filler_fg       = "#c0c0cc",
  separator_bg    = "#e8e8f0",
  separator_fg    = "#909099",
  gutter_added    = "#2a7a2a",
  gutter_removed  = "#9a2a2a",
  gutter_changed  = "#8a6a1a",
  ref_head        = "#8a6600",
  note_marker     = "#9a6200",
  note_virt       = "#606060",
}

-- Default highlight definitions: group name -> nvim_set_hl opts.
-- DiffNvimAdded/Removed use explicit bg values (never link to DiffAdd/DiffDelete)
-- so they remain muted regardless of colorscheme. Re-built on ColorScheme autocmd.
local function build_defaults()
  local p = vim.o.background == "light" and LIGHT or DARK
  return {
    -- Diff line backgrounds (PRIORITY_LINE_BG=50: below tree-sitter ~100)
    -- Explicit bg; fg=NONE so tree-sitter foreground colours show through.
    DiffNvimAdded           = { bg = p.added_bg,   fg = "NONE" },
    DiffNvimRemoved         = { bg = p.removed_bg,  fg = "NONE" },
    DiffNvimFiller          = { bg = p.filler_bg },
    DiffNvimFillerChar      = { fg = p.filler_fg },

    -- Word-level highlights (PRIORITY_WORD_HL=150: above tree-sitter ~100)
    -- More saturated than line bg so changed tokens stand out, fg=NONE so
    -- tree-sitter colours still show for context.
    DiffNvimAddedWord       = { bg = p.added_word_bg,    fg = "NONE" },
    DiffNvimRemovedWord     = { bg = p.removed_word_bg,  fg = "NONE" },

    -- Gutter indicators (palette-adaptive for light/dark mode)
    DiffNvimGutterAdded     = { fg = p.gutter_added,   bold = true },
    DiffNvimGutterRemoved   = { fg = p.gutter_removed, bold = true },
    DiffNvimGutterChanged   = { fg = p.gutter_changed, bold = true },

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

    -- File panel diffstat counts
    DiffNvimStatAdded       = { fg = p.gutter_added,   bold = false },
    DiffNvimStatRemoved     = { fg = p.gutter_removed, bold = false },

    -- Commit panel
    DiffNvimCommitHash      = { link = "Identifier" },
    DiffNvimCommitAuthor    = { link = "Comment" },
    DiffNvimCommitTime      = { link = "Comment" },
    DiffNvimCommitSubject   = { link = "Normal" },
    -- Dim metadata line beneath a commit subject (two-line layout)
    DiffNvimCommitMeta      = { link = "Comment" },
    -- Full commit message body shown when a commit is expanded inline
    DiffNvimCommitBody      = { link = "Comment" },
    -- Cursor highlight spanning both header lines (subject + author/date) of
    -- the commit the cursor is on.
    DiffNvimCommitCursor    = { link = "CursorLine" },

    -- Ref badges
    DiffNvimRefHead         = { fg = p.ref_head, bold = true },
    DiffNvimRefBranch       = { link = "String" },
    DiffNvimRefRemote       = { link = "Identifier" },
    DiffNvimRefTag          = { link = "Constant" },

    -- Notes
    DiffNvimNoteHeader      = { bold = true, link = "WarningMsg" },
    DiffNvimNoteText        = { link = "Comment" },
    DiffNvimNoteMarker      = { fg = p.note_marker, bold = true },
    DiffNvimNoteVirtText    = { fg = p.note_virt, italic = true },

    -- Separators (collapsed hunks)
    DiffNvimSeparator       = { fg = p.separator_fg, bg = p.separator_bg, italic = true },
    -- Enclosing-declaration heading shown next to a collapsed separator
    DiffNvimSeparatorDecl   = { fg = p.separator_fg, bg = p.separator_bg, italic = true, bold = true },

    -- Commit file entries
    DiffNvimCommitFileEntry = { link = "Normal" },

    -- Winbar for diff panes
    DiffNvimWinbar          = { bold = true, link = "StatusLine" },
    -- Full-width filename header bar spanning both diff panes
    DiffNvimHeader          = { bold = true, link = "StatusLine" },
  }
end

-- Merged table of defaults + user overrides, populated in setup()
local applied = {}
local _user_overrides = {}

local function apply_highlights()
  local defaults = build_defaults()
  applied = {}
  for group, def_opts in pairs(defaults) do
    if _user_overrides[group] then
      applied[group] = vim.tbl_deep_extend("force", vim.deepcopy(def_opts), _user_overrides[group])
    else
      applied[group] = vim.deepcopy(def_opts)
    end
  end
  -- Apply any extra groups the user defined that aren't in defaults
  for group, hl_opts in pairs(_user_overrides) do
    if not applied[group] then
      applied[group] = vim.deepcopy(hl_opts)
    end
  end

  for group, opts in pairs(applied) do
    if opts.link then
      -- Neovim 0.9+ supports link + extra attributes (bold, italic, etc.) together.
      -- Build the full opts table so groups like DiffNvimSectionHeader (link=Title,
      -- bold=true) correctly apply both the link and the bold attribute.
      local hl_opts = vim.deepcopy(opts)
      vim.api.nvim_set_hl(0, group, hl_opts)
    else
      local hl_opts = vim.deepcopy(opts)
      vim.api.nvim_set_hl(0, group, hl_opts)
    end
  end
end

function M.setup(opts)
  _user_overrides = (opts and opts.highlights) or {}
  apply_highlights()

  -- Re-apply on every ColorScheme change so our groups survive theme switches
  -- and re-read vim.o.background to pick the correct palette.
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("DiffNvimHighlights", { clear = true }),
    callback = function()
      pcall(apply_highlights)
    end,
  })
end

return M
