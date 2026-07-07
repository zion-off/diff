# diff.nvim

A NeoVim plugin that replicates the Git source-control UX of VSCode's SCM sidebar — with an enhanced code-review annotation feature.

---

## Features

| Feature | Details |
|---|---|
| **File Status Panel** | Staged & unstaged changes with collapsible sections, status badges, right-aligned |
| **Commit Graph Panel** | Recent commit history with `HEAD`, branch, remote, and tag ref badges |
| **Branch preview** | Browse another branch's commits without checking it out — pick from a floating list with `<leader>gb` |
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
  -- Sidebar position: "left" (default) or "right"
  sidebar_position = "left",

  -- Sidebar width in columns (default: 40)
  sidebar_width = 40,

  -- Notes panel width in columns (default: 40)
  notes_width = 40,

  -- Auto-refresh panels on FocusGained / BufWritePost (default: true)
  -- Also watches .git/index via libuv fs_event for immediate refresh.
  auto_refresh = true,

  -- Mouse interactivity in the sidebar (default: true). Clicking a file opens
  -- its diff; clicking a commit expands/collapses it; clicking a section header
  -- toggles it. Only enables Neovim's 'mouse' option while the interface is
  -- open (if not already enabled) and restores it on close.
  mouse = true,

  -- Keybinding overrides (set any to false/"" to disable)
  keymaps = {
    toggle_sidebar       = "<leader>gs",
    toggle_sidebar_panel = "<leader>gS",
    copy_notes_path      = "<leader>gy",
    open_diff            = "<CR>",
    stage_file           = "s",
    unstage_file         = "u",
    collapse             = "z",
    next_hunk            = "]c",
    prev_hunk            = "[c",
    leave_note           = "<leader>n",
    toggle_notes         = "<leader>N",
    preview_branch       = "<leader>gb",
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
| `<leader>gs` | Toggle interface |

### While interface is open

| Key | Action |
|---|---|
| `<leader>gS` | Toggle sidebar panels (show/hide file + commit panels) |
| `<leader>gy` | Copy session notes file path to clipboard |
| `<leader>N` | Toggle notes panel |
| `<leader>gb` | Preview another branch (open branch picker) |

### File Status Panel

| Key | Action |
|---|---|
| `<CR>` / click | Open diff for file / toggle section collapse |
| `s` | Stage file |
| `u` | Unstage file |
| `z` | Toggle section collapse |

### Commit Graph Panel

| Key | Action |
|---|---|
| `<CR>` / click | Expand/collapse commit / open commit file diff |
| `K` | Show full commit message tooltip |

### Branch Picker

Opened with `<leader>gb` (or `:DiffNvimPreviewBranch`).

| Key | Action |
|---|---|
| `<any char>` | Filter the branch list (substring match) |
| `<BS>` / `<C-h>` | Delete last filter character |
| `<Down>` / `<C-n>` / `<Tab>` | Next branch |
| `<Up>` / `<C-p>` / `<S-Tab>` | Previous branch |
| `<CR>` | Preview the selected branch |
| `<Esc>` / `q` / `<C-c>` | Cancel |

### Diff View

| Key | Action |
|---|---|
| `]c` | Next change chunk |
| `[c` | Previous change chunk |
| `zo` | Expand context (+10 lines) |
| `l` | Expand collapsed separator line (otherwise normal `l` motion) |
| `zR` | Show all context |
| `<leader>n` | Leave a note on current / visual selection |
| `<leader>N` | Toggle notes panel |
| `q` | Close diff view |

### Notes Panel

| Key | Action |
|---|---|
| `dd` | Delete note under cursor |
| `q` | Close panel |

---

## User Commands

| Command | Description |
|---|---|
| `:DiffNvimOpen` | Open sidebar |
| `:DiffNvimClose` | Close sidebar |
| `:DiffNvimToggle` | Toggle sidebar |
| `:DiffNvimPreviewBranch` | Preview another branch's commits without checking it out |
| `:DiffNvimNotes` | Toggle notes panel |

---

## Branch Preview

Press `<leader>gb` (or run `:DiffNvimPreviewBranch`) to open a floating picker
listing all local and remote branches, sorted by most recent commit. Selecting a
branch puts the interface into **preview mode**:

- The commit panel is re-sourced from the chosen branch (`git log <branch>`), so
  you can browse its history and open per-file diffs — all **without checking it
  out** and without touching your working tree.
- The file status panel shows a `Preview: <branch>` header instead of changes,
  since uncommitted working-tree changes belong only to the branch you actually
  have checked out.

The picker marks your current branch with `(current)`; selecting it returns to
normal live mode. Preview mode is read-only and is cleared when the interface is
closed.

---

## Notes Storage Format

Notes are stored in a per-session Markdown file at:

```
$XDG_DATA_HOME/diff.nvim/<repo-name>_<timestamp>.md
```

(Falls back to `~/.local/share/diff.nvim/` when `XDG_DATA_HOME` is unset.)

The timestamp (`YYYYMMDDTHHmmss`) is captured once when the plugin first writes
a note in the session. The file is created **lazily** — only when the first note
is actually written. Each Neovim session produces its own file.

Example filename: `diff_20260507T142301.md`

Each note looks like:

```markdown
## Note — path/to/file.py, lines 42–57 (new side)

> The context manager here should use `contextlib.suppress` instead of bare
> except.

*2025-01-15 14:23:01*

---
```

Copy the session file path to the clipboard with `<leader>gy`, then paste it
directly into a coding-agent prompt.

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
