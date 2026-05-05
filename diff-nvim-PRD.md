# diff.nvim — Product Requirements Document

## Overview

Build a NeoVim plugin called **diff.nvim** that replicates the Git source control UX of VSCode's SCM sidebar, with an enhanced code review annotation feature. The plugin is written in Lua and integrates deeply with NeoVim's native APIs, Git, and the filesystem. It is designed for developers who want a rich, visual Git workflow without leaving NeoVim.

---

## Core Experience

The plugin opens as a sidebar panel (right side by default) split into two vertical regions:

- **Top half — File Status Panel**: Shows staged and unstaged file changes, mirroring VSCode's "Changes" and "Staged Changes" sections.
- **Bottom half — Commit Graph Panel**: Shows recent commit history for the current repository, including clear visual indicators for the local branch head, the remote tracking branch, and where `origin/main` (or equivalent) diverges.

Selecting any file from either panel opens a **split diff view** in the main editing area. The diff view is the visual and functional centerpiece of the plugin.

---

## File Status Panel

### Behavior

The panel lists all files with uncommitted changes in the working tree, grouped into two collapsible sections: **Staged Changes** and **Changes** (unstaged). Each entry shows the file path relative to the repository root and a status indicator (modified, added, deleted, renamed, untracked).

The user can navigate the list with standard NeoVim movement keys. Pressing Enter or a configured key on any file opens the diff view for that file.

Collapsing and expanding each section should be supported with a single keypress. The panel should auto-refresh when the underlying Git state changes (e.g., after a stage, unstage, or external `git` command).

### Visual Design

The layout and visual density should closely match VSCode's SCM panel. Status badges (M, A, D, R, U) should appear right-aligned next to file names, using distinct highlight groups for each status type. Staged files appear with a muted-green tint; unstaged with a muted-yellow or neutral tint. Deleted files use a muted red. The visual intent is: at a glance, the developer understands the state of every file.

---

## Commit Graph Panel

### Behavior

This panel occupies the bottom half of the sidebar and shows the recent commit history of the current branch. It should display each commit on its own line, with the commit hash (short), author, relative timestamp (e.g., "3 hours ago"), and the commit subject line.

Branch ref labels (e.g., `main`, `origin/main`, `HEAD`) appear inline as badges on the relevant commits — exactly as they do in VSCode's Git Graph extensions. The user should be able to visually identify:

- Where `HEAD` currently points
- Where the local branch tip is
- Where the remote tracking branch (`origin/<branch>`) is
- Where `origin/main` is (if different from the tracking branch)

Selecting a commit from this panel should show what changed in that commit. The user can press Enter on a commit to open a diff view scoped to that commit's changes.

---

## Diff View

### Layout

When a file is selected, the main window splits into a two-pane side-by-side diff: the **old version** on the left and the **new version** on the right. This matches VSCode's default diff editor layout exactly.

### Visual Fidelity — This is the most critical section

The diff view must look and behave as close to VSCode's diff editor as possible. Specifically:

**Syntax highlighting** must be fully preserved in both panes. The plugin should use NeoVim's built-in Tree-sitter or LSP-based highlighting. The file type is detected from the file extension. The diff coloring (red/green backgrounds for removed/added lines) must layer on top of syntax highlighting without destroying it.

**Line-level diff coloring**: Removed lines in the left pane get a red background tint. Added lines in the right pane get a green background tint. These should use subtle, low-saturation colors that don't obliterate the syntax highlighting underneath — similar to VSCode's `diffEditor.removedLineBackground` and `diffEditor.insertedLineBackground` defaults.

**Inline word-level diff highlighting**: Within changed lines, the specific words or tokens that changed should be highlighted with a more saturated version of the line background — darker red for deleted words, darker green for added words. This mirrors VSCode's inline diff highlighting.

**Filler lines**: Lines that exist in one pane but have no corresponding line in the other pane must be filled with a greyed-out placeholder — a subtle, distinct background that clearly communicates "this space is structural, not content." The filler blocks should be visually consistent in height with the surrounding content and use a neutral dark grey. No text should appear in filler lines. This is a key visual detail that separates a polished diff view from a basic one.

**Line numbers**: Both panes show their own line numbers, corresponding to the original file (left pane) and new file (right pane) respectively. Filler lines show no line number.

**Scrolling**: Both panes scroll in sync, driven by a `WinScrolled` autocmd. The sync strategy is line-for-line with filler lines counted — i.e., the visible row positions in both panes stay aligned, not the semantic diff chunks. This means large unchanged blocks in the middle of a file stay visually aligned across panes. The implementation must guard against recursive scroll events.

**Gutter indicators**: A thin gutter strip on the inside edge of each pane (between line numbers and code) uses colored blocks to mark changed, added, or removed regions — matching VSCode's diff gutter marks.

---

## Annotation Feature (Code Review Notes)

This is the plugin's signature feature, designed for the use case of reviewing a diff and annotating it for a coding agent or collaborator.

### Behavior

While in the diff view, the user can select a range of lines (using NeoVim's visual selection) and trigger a "leave note" keybinding. This opens a small floating input prompt where the user types a freeform note.

On confirmation, the note is saved along with:

- The **file path** (relative to repo root)
- The **line number range** selected
- The **note text**
- The **side** of the diff the selection was made on (old/left or new/right), if distinguishable
- A **timestamp**

### Storage Format

All notes are written to a single Markdown file stored under an XDG-compliant path — specifically `$XDG_DATA_HOME/diff.nvim/` (falling back to `~/.local/share/diff.nvim/` if the env var is unset). The filename is auto-generated from the repository's root directory name and a hash or absolute path slug, so each repository gets its own notes file without any manual naming. The full storage path is configurable. Each note is appended as a structured entry. The format should be clean enough to paste directly into a prompt for a coding agent. Example structure:

```
## Note — path/to/file.py, lines 42–57

> [note text here]

---
```

Notes accumulate in this file across sessions. The file is append-only by default. The user can manually clear or edit it.

### Viewing Notes

A keybinding should toggle a panel or floating window showing all notes saved in the current session or in the notes file. Notes should be displayed in a readable Markdown-rendered or plain-text format. From this view, the user can delete individual entries.

---

## Keybindings

All keybindings should be configurable. Sensible defaults should be provided and documented. Default bindings should follow NeoVim conventions and avoid conflicting with common plugins. Key actions include:

- Open/close the diff.nvim sidebar
- Navigate up/down in file or commit lists
- Open diff for selected file or commit
- Stage / unstage the selected file
- Collapse / expand a section in the file panel
- In diff view: leave a note on current selection
- In diff view: navigate to next/previous change chunk
- Toggle the notes panel
- Refresh the file/commit state

---

## Configuration

The plugin should expose a `setup()` function accepting a configuration table. Configurable options include at minimum:

- Sidebar position (right or left)
- Sidebar width (in columns)
- The path/filename for the notes Markdown file
- Whether to auto-refresh on focus
- Keybinding overrides
- Color/highlight overrides for diff colors

---

## Technical Constraints and Quality Expectations

- The plugin must be pure Lua and compatible with NeoVim 0.9+.
- It must not require any external plugin dependencies. Syntax highlighting in the diff panes is achieved by setting the correct filetype on each buffer and letting NeoVim's normal highlighting pipeline (Tree-sitter, LSP, or filetype-based) apply naturally. This means if the user already has parsers installed, they get full highlighting automatically; if not, they get whatever NeoVim would normally fall back to. The plugin does not manage parser installation.
- Git operations are performed by shelling out to `git` asynchronously using `vim.uv` (or `vim.loop` on NeoVim 0.9). Synchronous calls via `vim.fn.system` are not acceptable for any operation that populates UI panels, as they block the editor. The plugin must handle repositories at any working directory, detecting the repo root automatically.
- All UI panels must use NeoVim's native window and buffer APIs. No external UI framework.
- The diff computation is done by calling `git diff` (for unstaged), `git diff --cached` (for staged), or `git show <commit>:<file>` (for commit diffs) and parsing the unified diff output to drive line-level rendering. All `git diff` invocations must include `--no-ext-diff` to suppress any external diff driver the user may have configured via `diff.external` or `GIT_EXTERNAL_DIFF`, ensuring the plugin always receives plain unified diff output. Word-level diff highlighting is computed by running a second-pass character/token diff on changed line pairs directly in Lua — do not rely on `git diff --word-diff` for this, as its output format is fragile to parse. Filler lines must be implemented using NeoVim's `nvim_buf_set_extmark` virtual lines API, which is the correct primitive for inserting visual-only rows with no buffer content.
- The plugin must handle edge cases gracefully: binary files (show a message instead of diff), renamed files, new untracked files, deleted files, and merge conflicts.
- Performance: the file list and commit graph should render without noticeable lag on repositories with hundreds of changed files or thousands of commits. Async loading should be used wherever the Git call may take time.

---

## Development Process

Work end-to-end, delivering a fully functional plugin. Use subagents or parallel workstreams to tackle independent components (e.g., the diff renderer, the sidebar layout, the Git data layer, the annotation system) simultaneously where possible.

Make well-scoped Git commits as you work. Each commit should correspond to a discrete, working unit of functionality — not a dump of all changes at the end. Commit messages should follow conventional commit style (e.g., `feat: implement line-level split diff rendering`).

Before completing, verify the plugin works end-to-end: opening the sidebar, browsing files, opening a diff, annotating lines, and finding the notes in the XDG notes file. The diff view in particular should be visually tested to confirm syntax highlighting, filler lines, word-level highlights, and synchronized scrolling all work correctly.
