local M = {}

local log = require("diff.log").scope("highlights")

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
  added_nr_bg     = "#14371f",  -- between the two  — unified line numbers
  removed_nr_bg   = "#3a131b",
  hunk_bg         = "#121d2f",  -- GitHub's blue hunk header band
  hunk_hover_bg   = "#18294a",
  filler_bg       = "#1e1e2e",
  filler_fg       = "#3a3a4a",
  separator_fg    = "#606070",
  hover_bg        = "#232a3d",
  edge_hover      = "#5f87d7",
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
  added_nr_bg     = "#cae6d7",  -- between the two  — unified line numbers
  removed_nr_bg   = "#e6c9ce",
  hunk_bg         = "#ddf4ff",  -- GitHub's blue hunk header band
  hunk_hover_bg   = "#c6e6ff",
  filler_bg       = "#f0f0f5",
  filler_fg       = "#c0c0cc",
  separator_fg    = "#909099",
  hover_bg        = "#e3eaf7",
  edge_hover      = "#3a6fc4",
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
-- The diff tints above are only the fallback for a theme with no background;
-- otherwise they are derived from Normal like the rest. The plugin's *chrome*
-- — header bar, filler bands, hunk headers, hover and the active-file
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
--- quieter ones for fillers and hunk headers, and tints for hover and the
--- active file. Falls back to the static palette when Normal carries no
--- background (a transparent terminal), where there is nothing to derive from.
local function surfaces(p)
  local bg, fg = hl_attr("Normal", "bg"), hl_attr("Normal", "fg")
  if not bg or not fg then
    return {
      header_bg = p.hover_bg, filler_bg = p.filler_bg,
      hover_bg = p.hover_bg,
      active_bg = p.hover_bg,
      track_bg = p.filler_bg, segment_bg = p.hover_bg, away_bg = p.hover_bg,
      cell_hover_bg = p.hover_bg, track_hover_bg = p.hover_bg, away_hover_bg = p.hover_bg,
      accent = p.ref_head, title_fg = p.title_fg, dim_fg = p.separator_fg,
      filler_fg = p.filler_fg, hunk_bg = p.hunk_bg, hunk_hover_bg = p.hunk_hover_bg,
    }, nil
  end
  -- The colour picked-out text is drawn in: the prompt glyph and the matched
  -- letters of the branch picker.
  local accent = hl_attr("Directory", "fg") or hl_attr("Function", "fg") or fg
  -- Hover, the active file and the active mode are selections in a list, so
  -- they are tints of the theme's own list selection (the completion menu's
  -- selected item), else of its visual selection. Tinting towards a syntax
  -- colour instead turned them olive wherever that colour was yellow.
  local sel = hl_attr("PmenuSel", "bg") or hl_attr("Visual", "bg")
  local function select_tint(alpha, accent_alpha)
    return sel and blend(bg, sel, alpha) or blend(bg, accent, accent_alpha)
  end
  -- Hunk headers are tinted towards the theme's informational blue, as
  -- GitHub's are towards its own.
  local info = hl_attr("DiagnosticInfo", "fg") or accent
  -- The mode bar and the diff header use two surface levels and no others:
  -- raised (the branch row, the file header, the selected half of the
  -- control) and sunken (the control's track).
  local raised, sunken = blend(bg, fg, 0.10), blend(bg, fg, 0.045)
  return {
    header_bg    = raised,
    filler_bg    = blend(bg, fg, 0.04),
    hover_bg     = select_tint(0.35, 0.14),
    active_bg    = select_tint(0.55, 0.20),
    accent       = string.format("#%06x", accent),
    -- Text tiers: secondary chrome text, and dim text that recedes further.
    title_fg     = blend(fg, bg, 0.25),
    dim_fg       = blend(fg, bg, 0.55),
    -- The filler hatch: just visible on its band, never louder than text.
    filler_fg    = blend(bg, fg, 0.16),
    -- The mode bar's segmented control: a track a step above Normal, its
    -- selected half raised to the header's level; and the tint of a mode
    -- you are visiting (another branch, another worktree).
    track_bg     = sunken,
    segment_bg   = raised,
    away_bg      = blend(bg, accent, 0.20),
    -- Their hover tints, each a step from its own surface: the list hover
    -- is measured from Normal and vanishes on a raised one. The track's
    -- stops short of the selected half, so hovering never reads as chosen.
    cell_hover_bg  = blend(bg, fg, 0.17),
    track_hover_bg = blend(bg, fg, 0.075),
    away_hover_bg  = blend(bg, accent, 0.32),
    hunk_bg       = blend(bg, info, 0.12),
    hunk_hover_bg = blend(bg, info, 0.22),
  }, bg
end

local function as_int(color)
  return type(color) == "number" and color or tonumber(color:sub(2), 16)
end

--- Diff tints measured from Normal: the line's, its line numbers' and the
--- changed words', each the given share of the way from the background to the
--- theme's add / remove colour. Falls back to the static palette when Normal
--- carries no background.
local function diff_tints(p, bg, added, removed)
  if not bg then
    return {
      added_bg = p.added_bg, removed_bg = p.removed_bg,
      added_nr_bg = p.added_nr_bg, removed_nr_bg = p.removed_nr_bg,
      added_word_bg = p.added_word_bg, removed_word_bg = p.removed_word_bg,
    }
  end
  local a, r = as_int(added), as_int(removed)
  return {
    added_bg = blend(bg, a, 0.11), removed_bg = blend(bg, r, 0.11),
    added_nr_bg = blend(bg, a, 0.19), removed_nr_bg = blend(bg, r, 0.19),
    added_word_bg = blend(bg, a, 0.34), removed_word_bg = blend(bg, r, 0.34),
  }
end

--- The first foreground colour defined among `groups`.
local function first_fg(...)
  for _, group in ipairs({ ... }) do
    local fg = hl_attr(group, "fg")
    if fg then return fg end
  end
  return nil
end

--- A ref pill: the ref's colour on a tint of it, so it reads as a label
--- attached to the commit rather than more metadata.
local function pill(color, bg, extra)
  local spec = vim.tbl_extend("force", { fg = color }, extra or {})
  if bg and type(color) == "number" then spec.bg = blend(bg, color, 0.16) end
  return spec
end

-- Default highlight definitions: group name -> nvim_set_hl opts.
-- DiffNvimAdded/Removed use explicit bg values (never link to DiffAdd/DiffDelete)
-- so they stay muted on any colorscheme. Re-built on ColorScheme autocmd.
local function build_defaults()
  local p = vim.o.background == "light" and LIGHT or DARK
  local s, bg = surfaces(p)
  -- Interface colours come from the theme's git colours, never from its
  -- syntax groups: linking a badge to Type or a file name to String brought
  -- the code's styling along — italics on every badge, staged files green
  -- as strings. They are foreground-only: a file name in a list must never
  -- gain a block of background, and a deleted file must not read as an alert.
  local added   = first_fg("GitSignsAdd", "diffAdded", "Added", "String") or p.gutter_added
  local changed = first_fg("GitSignsChange", "diffChanged", "Changed", "DiagnosticWarn") or p.gutter_changed
  local removed = first_fg("GitSignsDelete", "diffRemoved", "Removed", "DiagnosticError") or p.gutter_removed
  local renamed = first_fg("Special", "Identifier") or changed
  local text_fg = hl_attr("Normal", "fg")
  local nr_fg = hl_attr("LineNr", "fg") or s.dim_fg
  local t = diff_tints(p, bg, added, removed)
  return {
    -- Diff line backgrounds (PRIORITY_LINE_BG=50: below tree-sitter ~100)
    -- Explicit bg; fg=NONE so tree-sitter foreground colours show through.
    DiffNvimAdded           = { bg = t.added_bg,   fg = "NONE" },
    DiffNvimRemoved         = { bg = t.removed_bg,  fg = "NONE" },
    DiffNvimFiller          = { bg = s.filler_bg },
    -- The filler's glyphs are drawn as an overlay, which replaces the cell
    -- highlight outright: the band's colour has to ride on them, or the row
    -- below a deletion shows Normal between the hatching.
    DiffNvimFillerChar      = { fg = s.filler_fg, bg = s.filler_bg },

    -- Word-level highlights (PRIORITY_WORD_HL=150: above tree-sitter ~100)
    -- More saturated than line bg so changed tokens stand out, fg=NONE so
    -- tree-sitter colours still show for context.
    DiffNvimAddedWord       = { bg = t.added_word_bg,    fg = "NONE" },
    DiffNvimRemovedWord     = { bg = t.removed_word_bg,  fg = "NONE" },

    -- Diff gutter, after GitHub's: line numbers on a stronger tint than the
    -- line, and the padding after them on the line's own tint so the band runs
    -- unbroken from the numbers into the code
    DiffNvimAddedNr         = { fg = nr_fg, bg = t.added_nr_bg },
    DiffNvimRemovedNr       = { fg = nr_fg, bg = t.removed_nr_bg },
    DiffNvimAddedMarker     = { fg = p.gutter_added,   bg = t.added_bg },
    DiffNvimRemovedMarker   = { fg = p.gutter_removed, bg = t.removed_bg },
    -- Hunk headers ("@@ -12,7 +12,9 @@ function …") and the declaration
    -- after them; hovered when they expand on a click
    DiffNvimHunkHeader          = { fg = s.dim_fg, bg = s.hunk_bg },
    DiffNvimHunkHeaderDecl      = { fg = s.title_fg, bg = s.hunk_bg },
    DiffNvimHunkHeaderHover     = { fg = s.dim_fg, bg = s.hunk_hover_bg },
    DiffNvimHunkHeaderDeclHover = { fg = s.title_fg, bg = s.hunk_hover_bg },

    -- Status badges
    DiffNvimStatusModified  = { fg = changed },
    DiffNvimStatusAdded     = { fg = added },
    DiffNvimStatusDeleted   = { fg = removed },
    DiffNvimStatusRenamed   = { fg = renamed },
    DiffNvimStatusUntracked = { fg = added },

    -- Section headings inside a panel, in the panel title's colour, and the
    -- disclosure marker before a section or a commit
    DiffNvimSectionHeader   = { fg = s.title_fg, bold = true },
    DiffNvimChevron         = { fg = s.dim_fg },

    -- File names follow the file's status, never the section it is listed
    -- in: neutral, a new file in the added colour, a deleted one struck out.
    DiffNvimFileName        = text_fg and { fg = text_fg } or { link = "Normal" },
    DiffNvimAddedFile       = { fg = added },
    DiffNvimDeletedFile     = { fg = removed, strikethrough = true },
    -- Directory rows of a file tree, and quiet explanatory text
    DiffNvimDirName         = { fg = s.dim_fg },
    DiffNvimHint            = { fg = s.dim_fg },

    -- File panel diffstat counts
    DiffNvimStatAdded       = { fg = p.gutter_added,   bold = false },
    DiffNvimStatRemoved     = { fg = p.gutter_removed, bold = false },

    -- Commit panel: the subject as text; the hash, author and age under it
    -- as metadata, a step back
    DiffNvimCommitHash      = { fg = s.dim_fg },
    DiffNvimCommitSubject   = text_fg and { fg = text_fg } or { link = "Normal" },
    DiffNvimCommitMeta      = { fg = s.dim_fg },
    -- Commit message body in the tooltip
    DiffNvimCommitBody      = { fg = s.title_fg },
    -- Cursor highlight spanning both header lines (subject + author/date) of
    -- the commit the cursor is on.
    DiffNvimCommitCursor    = { link = "CursorLine" },

    -- Ref pills
    DiffNvimRefHead         = pill(hl_attr("DiagnosticWarn", "fg") or p.ref_head, bg, { bold = true }),
    DiffNvimRefBranch       = pill(added, bg),
    DiffNvimRefRemote       = pill(first_fg("Directory", "Identifier") or changed, bg),
    DiffNvimRefTag          = pill(first_fg("Constant", "Number") or changed, bg),

    -- Notes
    DiffNvimNoteHeader      = { bold = true, link = "WarningMsg" },
    DiffNvimNoteText        = { fg = s.title_fg },
    DiffNvimNoteMarker      = { fg = p.note_marker, bold = true },
    DiffNvimNoteVirtText    = { fg = p.note_virt, italic = true },

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
    -- The branch row is a pop-up button on the raised surface the diff
    -- view's file header uses, the two reading as one bar across the top;
    -- the branch name is what leads in it.
    DiffNvimModeCell        = { bg = s.header_bg },
    DiffNvimModeBranch      = { fg = text_fg, bg = s.header_bg, bold = true },
    DiffNvimModeTag         = { fg = s.dim_fg, bg = s.header_bg },
    DiffNvimModeCellHover   = { bg = s.cell_hover_bg },
    -- Visiting another branch or worktree tints the row, ending in Done
    DiffNvimModeAway        = { bg = s.away_bg },
    DiffNvimModeAwayBranch  = { fg = text_fg, bg = s.away_bg, bold = true },
    DiffNvimModeAwayTag     = { fg = s.title_fg, bg = s.away_bg },
    DiffNvimModeDone        = { fg = s.accent, bg = s.away_bg, bold = true },
    DiffNvimModeAwayHover   = { bg = s.away_hover_bg },
    -- The segmented control under it: the track and its unselected half,
    -- tinted under the pointer as every clickable item is, and the raised
    -- selected half
    DiffNvimModeTrack       = { fg = s.dim_fg, bg = s.track_bg },
    DiffNvimModeTrackHover  = { fg = text_fg, bg = s.track_hover_bg },
    DiffNvimModeSegment     = { fg = text_fg, bg = s.segment_bg },
    -- Mode bar item under the cursor, while the bar has keyboard focus
    DiffNvimModeCursor      = { link = "CursorLine" },

    -- The status line of the plugin's own windows is a divider, not a
    -- heading, so it recedes to the separator colour.
    DiffNvimRule            = { fg = p.separator_fg, bg = s.header_bg },
    -- Panel headings ('winbar'), set like the panels' section headings: on
    -- Normal's own background (the raised band is for what can be clicked),
    -- the title a step quieter than text so it organises without competing.
    DiffNvimPanelTitle      = { fg = s.title_fg, bg = bg, bold = true },
    DiffNvimPanelTitleDim   = { fg = s.dim_fg, bg = bg },

    -- Branch picker. The prompt row is the only place typing goes, so it is
    -- lit as an input: glyph in the accent colour, a block caret, a dimmed
    -- placeholder, and the match count receding at the far end.
    DiffNvimPickerNormal      = { link = "NormalFloat" },
    DiffNvimPickerBorder      = { link = "FloatBorder" },
    DiffNvimPickerTitle       = { link = "FloatTitle" },
    DiffNvimPickerFooter      = { fg = p.separator_fg },
    DiffNvimPickerPrompt      = { fg = s.accent, bold = true },
    DiffNvimPickerPlaceholder = { fg = s.dim_fg },
    DiffNvimPickerCaret       = { reverse = true },
    DiffNvimPickerCount       = { fg = p.separator_fg },
    DiffNvimPickerRule        = { fg = p.separator_fg },
    DiffNvimPickerSelected    = { bg = s.active_bg },
    DiffNvimPickerCurrent     = { bold = true },
    DiffNvimPickerRemote      = { fg = s.dim_fg },
    DiffNvimPickerMatch       = { fg = s.accent, bold = true },

    -- Full-width filename header bar spanning both diff panes. A raised
    -- surface a step above Normal — linking it to StatusLine made it the
    -- brightest, heaviest band on screen while naming the least urgent thing.
    DiffNvimHeader          = { bg = s.header_bg },
    -- The file name in it, the one bold thing; its directory and notes recede
    DiffNvimHeaderName      = { fg = text_fg, bg = s.header_bg, bold = true },
    -- The directory and notes, on the header's surface
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

-- Groups the diff view no longer draws, and those that took their place.
local RENAMED = {
  DiffNvimSeparator          = "DiffNvimHunkHeader",
  DiffNvimSeparatorDecl      = "DiffNvimHunkHeaderDecl",
  DiffNvimSeparatorHover     = "DiffNvimHunkHeaderHover",
  DiffNvimSeparatorDeclHover = "DiffNvimHunkHeaderDeclHover",
  DiffNvimGutterAdded        = "DiffNvimAddedMarker",
  DiffNvimGutterRemoved      = "DiffNvimRemovedMarker",
  DiffNvimModeClose          = "DiffNvimModeDone",
  DiffNvimModeTab            = "DiffNvimModeTrack",
  DiffNvimModeTabActive      = "DiffNvimModeSegment",
}
local REMOVED = { DiffNvimGutterChanged = true }

--- `overrides` with those of retired groups moved to the groups that took
--- their place (unless those are overridden too), so they keep taking effect.
local function migrate(overrides)
  local out, retired = vim.deepcopy(overrides), {}
  for old, new in pairs(RENAMED) do
    if out[old] then
      log.warn("highlight %s is now %s; applying its override there", old, new)
      out[new] = out[new] or out[old]
      out[old] = nil
      table.insert(retired, old .. " → " .. new)
    end
  end
  for old in pairs(REMOVED) do
    if out[old] then
      log.warn("highlight %s is no longer drawn; its override is ignored", old)
      out[old] = nil
      table.insert(retired, old .. " (no longer drawn)")
    end
  end
  if #retired > 0 then
    table.sort(retired)
    vim.notify("diff.nvim: renamed highlight groups in your config: " .. table.concat(retired, ", "),
      vim.log.levels.WARN)
  end
  return out
end

function M.setup(opts)
  _user_overrides = migrate((opts and opts.highlights) or {})
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
