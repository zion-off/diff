# diff.nvim

A NeoVim plugin that replicates the Git source-control UX of VSCode's SCM sidebar — with an enhanced code-review annotation feature.

---

## Features

| Feature | Details |
|---|---|
| **File Status Panel** | Staged & unstaged changes with collapsible sections, status badges, right-aligned |
| **Commit Graph Panel** | Recent commit history with `HEAD`, branch, remote, and tag ref badges |
| **Branch changes** | Press `<leader>gB` to see everything the branch changed since it left `main`, like a pull request's "Files changed" tab |
| **Branch preview** | Browse another branch's commits without checking it out — pick from a floating list with `<leader>gb` |
| **Split Diff View** | Side-by-side old/new diff computed in-process with Neovim's built-in xdiff — no `git diff` subprocess |
| **Accurate syntax highlighting** | Tree-sitter parses each whole file once (asynchronously on 0.11+), so collapsed context never breaks highlighting |
| **Line-level colours** | Subtle red for removed, green for added — layered on top of syntax colours |
| **Word-level highlights** | Darker red/green marks the exact tokens that changed within a line |
| **Filler lines** | Grey visual-only placeholders keep both panes aligned |
| **Real line numbers** | The gutter shows file line numbers, not pane row numbers |
| **Scroll sync** | Split panes stay locked together, whether you scroll with the keyboard, the mouse wheel over either pane, or with `smoothscroll` on |
| **Line wrapping** | Long lines wrap at word boundaries, GitHub-style; the shorter side of each row is padded so both panes stay row-aligned (split view needs Neovim ≥ 0.10) |
| **Gutter indicators** | Coloured `▍` strip marks changed regions |
| **Hunk staging** | Stage or unstage the change under the cursor straight from the diff |
| **Live updates** | Panels follow `git` activity from anywhere (CLI, other tools); the open diff follows edits on disk, keeping your place |
| **Fast navigation** | `]f` / `[f` move between files, `gf` jumps to the real file at the same line |
| **Annotation notes** | Select lines, press `<leader>n`, type a note — saved to an XDG Markdown file |
| **Notes panel** | Toggle with `<leader>N`; `dd` deletes a note, `q` closes |

---

## Requirements

- NeoVim ≥ 0.9 (developed and tested on 0.11; asynchronous tree-sitter parsing needs 0.11, older versions parse synchronously)
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

  -- Branch mode compares the branch against this branch (default: nil, which
  -- uses the remote's default branch origin/HEAD, else a local main or master).
  base_branch = nil,

  -- Mouse interactivity in the sidebar (default: true). Clicking a file opens
  -- its diff; clicking a commit expands/collapses it; clicking a section header
  -- toggles it. Only enables Neovim's 'mouse' option while the interface is
  -- open (if not already enabled) and restores it on close.
  mouse = true,

  -- Lines of context around each change (nil shows whole files).
  context_lines = 3,

  -- Soft-wrap long lines in the diff panes (default: true). In the split view
  -- the shorter side of each row is padded to the taller side's height, so the
  -- panes stay aligned while scrolling. Split panes narrower than 20 text
  -- columns scroll horizontally instead. Needs Neovim 0.10+ in the split view;
  -- on 0.9 split panes stay unwrapped.
  wrap = true,

  -- Log verbosity: "trace" | "debug" | "info" | "warn" (default) | "error" | "off".
  -- The log lives at stdpath("log")/diff.nvim.log; open it with :DiffNvimLog.
  log_level = "warn",

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
    next_file            = "]f",
    prev_file            = "[f",
    goto_file            = "gf",
    stage_hunk           = "s",
    unstage_hunk         = "u",
    leave_note           = "<leader>n",
    toggle_notes         = "<leader>N",
    preview_branch       = "<leader>gb",
    branch_changes       = "<leader>gB",
    expand_context       = "zo",
    expand_all           = "zR",
    collapse_all         = "zM",
    commit_tooltip       = "K",
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
| `<leader>gB` | Toggle branch mode (see [Branch Changes](#branch-changes)) |

### File Status Panel

| Key | Action |
|---|---|
| `<CR>` / click | Open diff for file / toggle section or directory |
| `s` | Stage file (the cursor moves on to the next file) |
| `u` | Unstage file |
| `z` | Toggle directory / section collapse |

The file shown in the diff view is marked with `▎` in the panel.

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
| `]c` / `[c` | Next / previous change |
| `]f` / `[f` | Next / previous file (same panel section, or same commit) |
| `gf` | Open the real file at this line, in the window the interface was opened from |
| `s` | Stage the change under the cursor (unstaged working-tree diffs) |
| `u` | Unstage the change under the cursor (staged diffs) |
| `l` / `zo` | Reveal 10 more lines at each edge of the collapsed section under the cursor (`zo` uses the nearest one) |
| `zR` | Show all context |
| `zM` | Collapse back to the configured context |
| `<leader>n` | Leave a note on current / visual selection |
| `<leader>N` | Toggle notes panel |
| `q` | Close diff view |

`j` / `k` step over filler rows. The cursor starts on the first change, and stays on its line when the file changes on disk.

Hunk staging uses zero-context patches. A change directly next to a final line without a trailing newline cannot be expressed that way; the plugin says so instead of guessing, and the whole file can still be staged from the panel.

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
| `:DiffNvimRefresh` | Re-fetch the panels |
| `:DiffNvimLog` | Open the log file |

---

## Branch Changes

Press `<leader>gB` to switch the file panel into **branch mode**: instead of
staged and unstaged changes it lists every file the branch changed since its
merge base with the base branch — the same set a pull request's "Files changed"
tab shows (`git diff <base>...HEAD`). Commits that landed on the base branch
after the branch left it are not included, and uncommitted changes aren't either.
The commit panel is closed and the file panel takes the whole sidebar. Press
`<leader>gB` again to go back.

Each file opens as one diff from the merge base to the branch's latest version.
In preview mode, branch mode shows the previewed branch's changes.

The base is the remote's default branch (`origin/HEAD`), falling back to a local
`main` or `master`. Set `base_branch` to use a different one. It is looked up
each time you enter branch mode.

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

### Worktrees

Branches checked out in another git worktree are marked `(worktree)`. Selecting
one switches the interface to that worktree: the file panel shows its staged and
unstaged changes (diffs, staging and hunk staging all act on it) and the commit
panel its history. Pick the branch of the worktree you opened the interface in
to switch back.

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
| `DiffNvimActiveFile` | Panel row of the file shown in the diff view |
| `DiffNvimActiveSign` | `▎` marker on that row |
| `DiffNvimHeader` | Filename bar above the diff |
| `DiffNvimSeparator` | Collapsed-context marker |

---

## Events

The plugin fires `User` autocommands that other code can hook into:

| Pattern | When | `data` |
|---|---|---|
| `DiffNvimViewChanged` | The diff view opened another file, or closed | `{ kind, path, staged, hash }`, or `{}` when closed |
| `DiffNvimGitChanged` | The repository's index or HEAD changed | — |

---

## Troubleshooting

Set `log_level = "debug"` and run `:DiffNvimLog`. The log records every git command with its duration, watcher events, and how long each diff took to load and render.

---

## Development

Run the test suite with:

```sh
tests/run.sh            # all specs
tests/run.sh interface  # specs whose file name contains "interface"
```

Each spec runs in its own headless Neovim and creates throwaway git repositories, so the tests need `nvim` and `git` on `$PATH` and nothing else.

---

## License

MIT
