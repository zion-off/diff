# diff.nvim

A NeoVim plugin that replicates the Git source-control UX of VSCode's SCM sidebar — with an enhanced code-review annotation feature.

---

## Features

| Feature | Details |
|---|---|
| **File Status Panel** | Staged & unstaged changes with collapsible sections, status badges, right-aligned |
| **Commit Graph Panel** | Recent commit history with `HEAD`, branch, remote, and tag ref badges |
| **Split Diff View** | Side-by-side old/new diff with syntax highlighting preserved via Tree-sitter/LSP |
| **Line-level colours** | Subtle red for removed, green for added — layered on top of syntax colours |
| **Word-level highlights** | Darker red/green marks the exact tokens that changed within a line |
| **Filler lines** | Grey visual-only placeholders keep both panes aligned |
| **Scroll sync** | Both panes scroll together via `WinScrolled` with recursion guard |
| **Gutter indicators** | Coloured `▍` strip marks changed regions |
| **Annotation notes** | Select lines, press `<leader>n`, type a note — saved to an XDG Markdown file |
| **Notes panel** | Toggle with `<leader>N`; `dd` deletes a note, `q` closes |

---

## Requirements

- NeoVim ≥ 0.9
- `git` on `$PATH`
- No external plugin dependencies

---

## Installation

### lazy.nvim

```lua
{
  "zion-off/diff",
  config = function()
    require("diff").setup()
  end,
}
```

### packer.nvim

```lua
use {
  "zion-off/diff",
  config = function()
    require("diff").setup()
  end,
}
```

---

## Configuration

Call `require("diff").setup(opts)` once from your config. All fields are optional.

```lua
require("diff").setup({
  -- Sidebar position: "right" (default) or "left"
  sidebar_position = "right",

  -- Sidebar width in columns (default: 40)
  sidebar_width = 40,

  -- Override the notes file path. nil = XDG default:
  --   $XDG_DATA_HOME/diff.nvim/<repo>.md  (or ~/.local/share/diff.nvim/...)
  notes_path = nil,

  -- Auto-refresh panels on FocusGained / BufWritePost (default: true)
  auto_refresh = true,

  -- Keybinding overrides (set any to false/"" to disable)
  keymaps = {
    toggle_sidebar = "<leader>gs",
    refresh        = "<leader>gr",
    open_diff      = "<CR>",
    stage_file     = "s",
    unstage_file   = "u",
    collapse       = "z",
    next_hunk      = "]c",
    prev_hunk      = "[c",
    leave_note     = "<leader>n",
    toggle_notes   = "<leader>N",
  },

  -- Highlight colour overrides — any valid :hi attribute table
  highlights = {
    -- e.g. { bg = "#0d1f0d" }
  },
})
```

---

## Keybindings

### Global

| Key | Action |
|---|---|
| `<leader>gs` | Toggle sidebar |
| `<leader>gr` | Refresh file & commit panels |
| `<leader>N` | Toggle notes panel |

### File Status Panel

| Key | Action |
|---|---|
| `<CR>` | Open diff for file / toggle section collapse |
| `s` | Stage file |
| `u` | Unstage file |
| `z` | Toggle section collapse |
| `<leader>gr` | Refresh |

### Commit Graph Panel

| Key | Action |
|---|---|
| `<CR>` | Open diff for commit |
| `<leader>gr` | Refresh |

### Diff View

| Key | Action |
|---|---|
| `]c` | Next change chunk |
| `[c` | Previous change chunk |
| `<leader>n` | Leave a note on current / visual selection |
| `<leader>N` | Toggle notes panel |
| `q` | Close diff view |

### Notes Panel

| Key | Action |
|---|---|
| `dd` | Delete note under cursor |
| `q` / `<Esc>` | Close panel |

---

## User Commands

| Command | Description |
|---|---|
| `:DiffNvimOpen` | Open sidebar |
| `:DiffNvimClose` | Close sidebar |
| `:DiffNvimToggle` | Toggle sidebar |
| `:DiffNvimRefresh` | Refresh panels |
| `:DiffNvimNotes` | Toggle notes panel |

---

## Notes Storage Format

Notes are stored in a per-repository Markdown file at:

```
$XDG_DATA_HOME/diff.nvim/<repo-name>_<path-slug>.md
```

(Falls back to `~/.local/share/diff.nvim/` when `XDG_DATA_HOME` is unset.)

Each note looks like:

```markdown
## Note — path/to/file.py, lines 42–57 (new side)

> The context manager here should use `contextlib.suppress` instead of bare
> except.

*2025-01-15 14:23:01*

---
```

The file is append-only by default. Copy-paste the whole file directly into a coding-agent prompt.

---

## Highlight Groups

Override any group via `vim.api.nvim_set_hl` after `setup()`, or use the `highlights` config table:

| Group | Used for |
|---|---|
| `DiffNvimAdded` | Added-line background |
| `DiffNvimRemoved` | Removed-line background |
| `DiffNvimFiller` | Filler-line background |
| `DiffNvimAddedWord` | Word-level added token |
| `DiffNvimRemovedWord` | Word-level removed token |
| `DiffNvimGutterAdded` | Gutter `▍` for added |
| `DiffNvimGutterRemoved` | Gutter `▍` for removed |
| `DiffNvimGutterChanged` | Gutter `▍` for changed |
| `DiffNvimSectionHeader` | "Staged Changes" / "Changes" headers |
| `DiffNvimStagedFile` | Staged file name |
| `DiffNvimUnstagedFile` | Unstaged file name |
| `DiffNvimDeletedFile` | Deleted file name |
| `DiffNvimStatusModified` | `[M]` badge |
| `DiffNvimStatusAdded` | `[A]` badge |
| `DiffNvimStatusDeleted` | `[D]` badge |
| `DiffNvimStatusRenamed` | `[R]` badge |
| `DiffNvimStatusUntracked` | `[?]` badge |
| `DiffNvimCommitHash` | Commit short hash |
| `DiffNvimCommitAuthor` | Commit author |
| `DiffNvimCommitTime` | Relative timestamp |
| `DiffNvimCommitSubject` | Commit subject |
| `DiffNvimRefHead` | `HEAD` ref badge |
| `DiffNvimRefBranch` | Local branch badge |
| `DiffNvimRefRemote` | Remote tracking badge |
| `DiffNvimRefTag` | Tag badge |
| `DiffNvimNoteHeader` | `## Note` heading in notes panel |
| `DiffNvimNoteText` | Note body text |

---

## License

MIT
