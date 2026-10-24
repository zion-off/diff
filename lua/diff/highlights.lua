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
  hover_bg        = "#232a3d",
  edge_hover      = "#5f87d7",
  tab_active_bg   = "#2e3650",
  gutter_added    = "#3a8c3a",
  gutter_removed  = "#8c3a3a",
  gutter_changed  = "#8c7a3a",
  ref_head        = "#f0d080",
  title_fg        = "#b0b0c0",
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
  hover_bg        = "#e3eaf7",
  edge_hover      = "#3a6fc4",
  tab_active_bg   = "#d5deef",
  gutter_added    = "#2a7a2a",
  gutter_removed  = "#9a2a2a",
  gutter_changed  = "#8a6a1a",
  ref_head        = "#8a6600",
  title_fg        = "#505060",
  note_marker     = "#9a6200",
  note_virt       = "#606060",
}

-- ---------------------------------------------------------------------------
-- Deriving chrome colours from the colorscheme
--
-- The diff tints above are hand-picked and stay fixed. The plugin's *chrome*
-- — header bar, filler bands, collapsed separators, hover and the active-file
-- mark — must instead sit a measured step away from whatever Normal is, or it
-- lands at the wrong weight on every theme but the one it was tuned for.
-- ---------------------------------------------------------------------------

--- A resolved attribute of `group`, following links; nil when unset.
local function hl_attr(group, attr)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
  if not ok then return nil end
  return hl and hl[attr] or nil
end

--- `base` moved `alpha` of the way towards `other`. Both are 24-bit ints.
local function blend(base, other, alpha)
  local out = 0
  for _, shift in ipairs({ 16, 8, 0 }) do
    local b = math.floor(base / 2 ^ shift) % 256
    local o = math.floor(other / 2 ^ shift) % 256
    local v = math.floor(b + (o - b) * alpha + 0.5)
    out = out + math.min(255, math.max(0, v)) * 2 ^ shift
  end
  return string.format("#%06x", out)
end

--- Surfaces a measured distance from Normal: a raised one for the header,
--- quieter ones for fillers and separators, and tints for hover and the
--- active file. Falls back to the static palette when Normal carries no
--- background (a transparent terminal), where there is nothing to derive from.
local function surfaces(p)
  local bg, fg = hl_attr("Normal", "bg"), hl_attr("Normal", "fg")
  if not bg or not fg then
    return {
      header_bg = p.filler_bg, filler_bg = p.filler_bg,
      separator_bg = p.separator_bg, hover_bg = p.hover_bg,
      active_bg = p.hover_bg, tab_active_bg = p.tab_active_bg,
      accent = p.ref_head, title_fg = p.title_fg, dim_fg = p.separator_fg,
    }
  end
  -- An accent to tint hover and the active file towards, so they read as
  -- "selected" rather than merely "a different grey".
  local accent = hl_attr("Function", "fg") or hl_attr("Identifier", "fg") or fg
  return {
    header_bg    = blend(bg, fg, 0.10),
    filler_bg    = blend(bg, fg, 0.04),
    separator_bg = blend(bg, fg, 0.05),
    hover_bg     = blend(bg, accent, 0.14),
    active_bg    = blend(bg, accent, 0.20),
    tab_active_bg = blend(bg, accent, 0.22),
    accent       = string.format("#%06x", accent),
    -- Text tiers: secondary chrome text, and dim text that recedes further.
    title_fg     = blend(fg, bg, 0.25),
    dim_fg       = blend(fg, bg, 0.55),
  }
end

-- Default highlight definitions: group name -> nvim_set_hl opts.
-- DiffNvimAdded/Removed use explicit bg values (never link to DiffAdd/DiffDelete)
-- so they remain muted regardless of colorscheme. Re-built on ColorScheme autocmd.
local function build_defaults()
  local p = vim.o.background == "light" and LIGHT or DARK
  local s = surfaces(p)
  -- Status colours are foreground-only: a file name in a list must never gain
  -- a block of background (linking to Error drags one in, and a deleted file
  -- then reads as an alert rather than an entry).
  local error_fg = hl_attr("DiagnosticError", "fg") or hl_attr("ErrorMsg", "fg") or p.gutter_removed
  return {
    -- Diff line backgrounds (PRIORITY_LINE_BG=50: below tree-sitter ~100)
    -- Explicit bg; fg=NONE so tree-sitter foreground colours show through.
    DiffNvimAdded           = { bg = p.added_bg,   fg = "NONE" },
    DiffNvimRemoved         = { bg = p.removed_bg,  fg = "NONE" },
    DiffNvimFiller          = { bg = s.filler_bg },
    -- The filler's glyphs are drawn as an overlay, which replaces the cell
    -- highlight outright: the band's colour has to ride on them, or the row
    -- below a deletion shows Normal between the hatching.
    DiffNvimFillerChar      = { fg = p.filler_fg, bg = s.filler_bg },

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
    DiffNvimStatusDeleted   = { fg = error_fg },
    DiffNvimStatusRenamed   = { link = "Special" },
    DiffNvimStatusUntracked = { link = "Comment" },

    -- Section headers (bold)
    DiffNvimSectionHeader   = { bold = true, link = "Title" },

    -- File panel names
    DiffNvimStagedFile      = { link = "String" },
    DiffNvimUnstagedFile    = { link = "Normal" },
    DiffNvimDeletedFile     = { fg = error_fg },

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
    DiffNvimSeparator       = { fg = p.separator_fg, bg = s.separator_bg, italic = true },
    -- Enclosing-declaration heading shown next to a collapsed separator
    DiffNvimSeparatorDecl   = { fg = p.separator_fg, bg = s.separator_bg, italic = true, bold = true },
    -- A separator under the mouse pointer (click to expand)
    DiffNvimSeparatorHover     = { fg = p.separator_fg, bg = s.hover_bg, italic = true },
    DiffNvimSeparatorDeclHover = { fg = p.separator_fg, bg = s.hover_bg, italic = true, bold = true },

    -- Commit file entries
    DiffNvimCommitFileEntry = { link = "Normal" },

    -- The file currently shown in the diff view, marked in either panel. A
    -- quiet tint, not Visual: it is a standing mark, not a selection, and has
    -- to stay legible under the cursor line and the hover tint both.
    DiffNvimActiveFile      = { bg = s.active_bg },
    -- A clickable row under the mouse pointer
    DiffNvimHover           = { bg = s.hover_bg },
    -- A draggable window edge under the mouse pointer: a separator, or a
    -- status line when each window has its own
    DiffNvimEdgeHover       = { fg = p.edge_hover, bold = true },
    DiffNvimEdgeHoverStatus = { bg = p.edge_hover },
    -- Mode bar above the sidebar
    DiffNvimModeBranch      = { link = "Title" },
    DiffNvimModeTag         = { link = "Comment" },
    DiffNvimModeClose       = { link = "WarningMsg" },
    DiffNvimModeTab         = { link = "Comment" },
    DiffNvimModeTabActive   = { bg = s.tab_active_bg, bold = true },
    -- Mode bar item under the cursor, while the bar has keyboard focus
    DiffNvimModeCursor      = { link = "CursorLine" },

    -- The status line of the plugin's own windows is a divider, not a
    -- heading, so it recedes to the separator colour.
    DiffNvimRule            = { fg = p.separator_fg, bg = s.header_bg },
    -- Panel headings ('winbar'): the same raised surface as the diff header,
    -- the title a step quieter than text so it organises without competing.
    DiffNvimPanelTitle      = { fg = s.title_fg, bg = s.header_bg, bold = true },
    DiffNvimPanelTitleDim   = { fg = s.dim_fg, bg = s.header_bg },

    -- Branch picker. The prompt row is the only place typing goes, so it is
    -- lit as an input: glyph in the accent colour, a block caret, a dimmed
    -- placeholder, and the match count receding at the far end.
    DiffNvimPickerNormal      = { link = "NormalFloat" },
    DiffNvimPickerBorder      = { link = "FloatBorder" },
    DiffNvimPickerTitle       = { link = "FloatTitle" },
    DiffNvimPickerFooter      = { fg = p.separator_fg },
    DiffNvimPickerPrompt      = { fg = s.accent, bold = true },
    DiffNvimPickerPlaceholder = { fg = p.separator_fg, italic = true },
    DiffNvimPickerCaret       = { reverse = true },
    DiffNvimPickerCount       = { fg = p.separator_fg },
    DiffNvimPickerRule        = { fg = p.separator_fg },
    DiffNvimPickerSelected    = { bg = s.active_bg },
    DiffNvimPickerMatch       = { fg = s.accent, bold = true },

    -- Full-width filename header bar spanning both diff panes. A raised
    -- surface a step above Normal — linking it to StatusLine made it the
    -- brightest, heaviest band on screen while naming the least urgent thing.
    DiffNvimHeader          = { bold = true, bg = s.header_bg },
    -- "Before" / "After" over each pane of a split, on the header's surface
    DiffNvimHeaderLabel     = { fg = s.dim_fg, bg = s.header_bg },
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
