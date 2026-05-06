local M = {}

local config = require("diff.config")

-- Namespace for highlights in the notes panel
local NS = vim.api.nvim_create_namespace("diff_nvim_notes")

-- ---------------------------------------------------------------------------
-- Session-scoped file state
-- ---------------------------------------------------------------------------

-- Computed once at first append_note call and cached for the session.
-- Nil until the first note is written this session.
M._session_path    = nil
M._session_file_created = false

-- Timestamp captured once at module-load time; used to name the session file.
local _session_timestamp = os.date("%Y%m%dT%H%M%S")

-- ---------------------------------------------------------------------------
-- Session file path helpers
-- ---------------------------------------------------------------------------

--- Compute the session file path for a given repo root.
--- Format: ~/.local/share/diff.nvim/<repo-name>_<timestamp>.md
--- The path is cached in M._session_path after the first call.
--- @param repo_root string
--- @return string
function M.get_notes_path(repo_root)
  if M._session_path then
    return M._session_path
  end

  local xdg = os.getenv("XDG_DATA_HOME")
  if not xdg or xdg == "" then
    xdg = (os.getenv("HOME") or "") .. "/.local/share"
  end
  local dir = xdg .. "/diff.nvim"
  vim.fn.mkdir(dir, "p")

  local repo_name = repo_root:match("[^/]+$") or "repo"
  M._session_path = dir .. "/" .. repo_name .. "_" .. _session_timestamp .. ".md"
  return M._session_path
end

-- ---------------------------------------------------------------------------
-- Append note — lazy file creation
-- ---------------------------------------------------------------------------

--- Append a note entry to the session notes file.
--- The file is created on the very first write (lazy init).
--- @param note table {file_path, line_start, line_end, side, text, repo_root, timestamp}
function M.append_note(note)
  local path = M.get_notes_path(note.repo_root)

  local f = io.open(path, "a")
  if not f then
    vim.notify("diff.nvim: cannot open notes file: " .. path, vim.log.levels.ERROR)
    return
  end

  local lines_str = tostring(note.line_start)
  if note.line_end and note.line_end ~= note.line_start then
    -- Use ASCII hyphen (U+002D) as range separator. The note marker parser
    -- in diff_view.lua accepts both hyphen and en-dash for backward compat.
    lines_str = lines_str .. "-" .. tostring(note.line_end)
  end

  local side_str = note.side and (" (" .. note.side .. " side)") or ""

  -- Escape any leading > in the note text to avoid breaking the blockquote
  local body = note.text:gsub("\n", "\n> ")

  local entry = string.format(
    "\n## Note — %s, lines %s%s\n\n> %s\n\n*%s*\n\n---\n",
    note.file_path,
    lines_str,
    side_str,
    body,
    note.timestamp or os.date("%Y-%m-%d %H:%M:%S")
  )

  f:write(entry)
  f:close()

  -- Mark file as created for this session
  M._session_file_created = true

  vim.notify("diff.nvim: note saved → " .. path, vim.log.levels.INFO)

  -- Refresh note markers in the current diff view
  local dv = require("diff.diff_view")
  if dv._current_repo and dv._current_file then
    dv.rerender()
  end

  -- Live-update the notes panel split if it is open
  local sidebar = require("diff.sidebar")
  if sidebar._notes_win and vim.api.nvim_win_is_valid(sidebar._notes_win) then
    M._render_notes_buf(sidebar._notes_buf)
  end
end

-- ---------------------------------------------------------------------------
-- Copy notes path to clipboard
-- ---------------------------------------------------------------------------

--- Copy the current session notes file path to the system clipboard.
--- Shows a warning if no note has been written yet this session.
function M.copy_notes_path()
  if not M._session_file_created then
    vim.notify("diff.nvim: no notes yet this session", vim.log.levels.WARN)
    return
  end
  local path = M._session_path
  vim.fn.setreg("+", path)
  vim.notify("diff.nvim: path copied to clipboard", vim.log.levels.INFO)
end

-- ---------------------------------------------------------------------------
-- Note input prompt
-- ---------------------------------------------------------------------------

--- Open an input prompt and call back with the entered text.
--- Tries nui.nvim first; falls back to vim.ui.input (styled by noice/dressing
--- if the user has those plugins).
--- @param opts table  {file_path, line_start, line_end, side, repo_root}
function M.prompt_note(opts)
  -- Try nui.nvim
  local nui_ok, NuiInput = pcall(require, "nui.input")
  if nui_ok and NuiInput then
    local width = 60
    local input = NuiInput({
      position = "50%",
      size     = { width = width },
      border   = {
        style = "rounded",
        text  = { top = " Leave a note ", top_align = "center" },
      },
      win_options = { winhighlight = "Normal:Normal" },
    }, {
      prompt   = "> ",
      on_submit = function(text)
        if text and text ~= "" then
          M.append_note(vim.tbl_extend("force", opts, {
            text      = text,
            timestamp = os.date("%Y-%m-%d %H:%M:%S"),
          }))
        end
      end,
    })
    input:mount()
    input:map("i", "<Esc>", function() input:unmount() end, { noremap = true })
    return
  end

  -- Fallback: vim.ui.input (styled by noice.nvim / dressing.nvim if present)
  vim.ui.input({ prompt = "Leave a note: " }, function(text)
    if text and text ~= "" then
      M.append_note(vim.tbl_extend("force", opts, {
        text      = text,
        timestamp = os.date("%Y-%m-%d %H:%M:%S"),
      }))
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Notes panel — right-side split
-- ---------------------------------------------------------------------------

--- Load lines from the session file (or return placeholder).
--- @return string[]
local function load_notes_lines()
  local path = M._session_path
  local lines = {}

  if path then
    local f = io.open(path, "r")
    if f then
      for line in f:lines() do
        table.insert(lines, line)
      end
      f:close()
    end
  end

  if #lines == 0 then
    lines = { "# diff.nvim Notes", "", "No notes yet." }
  end
  return lines
end

--- (Re-)render the notes buffer from the session file.
--- @param buf integer
function M._render_notes_buf(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  local lines = load_notes_lines()
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  M._apply_notes_highlights(buf, lines)
end

--- Toggle the notes panel (right-side vertical split).
--- @param repo_root string
function M.toggle_notes(repo_root)
  local sidebar = require("diff.sidebar")

  -- Close if already open
  if sidebar._notes_win and vim.api.nvim_win_is_valid(sidebar._notes_win) then
    pcall(vim.api.nvim_win_close, sidebar._notes_win, true)
    sidebar._notes_win = nil
    sidebar._notes_buf = nil
    return
  end

  -- Ensure we have a session path (may still be nil if no note written yet)
  -- get_notes_path will compute and cache it.
  M.get_notes_path(repo_root)

  local cfg   = config.get()
  local width = cfg.notes_width or 40

  -- Create a scratch buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype",    "nofile",   { buf = buf })
  vim.api.nvim_set_option_value("bufhidden",  "wipe",     { buf = buf })
  vim.api.nvim_set_option_value("filetype",   "markdown", { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false,      { buf = buf })

  -- Open a rightbelow vsplit from the rightmost diff pane.
  -- Find the rightmost valid window (by x-position / column).
  local target_win = nil
  local best_col   = -1
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) then
      local pos = vim.api.nvim_win_get_position(win)
      if pos[2] > best_col then
        best_col   = pos[2]
        target_win = win
      end
    end
  end

  if not target_win then
    target_win = vim.api.nvim_get_current_win()
  end

  -- Open the split from that window
  pcall(vim.api.nvim_set_current_win, target_win)
  vim.cmd("rightbelow " .. width .. " vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)

  -- Window options
  local wopts = {
    winfixwidth = true,
    wrap        = true,
    linebreak   = true,
    number      = false,
    signcolumn  = "no",
    cursorline  = true,
  }
  for k, v in pairs(wopts) do
    pcall(vim.api.nvim_set_option_value, k, v, { win = win })
  end

  sidebar._notes_win = win
  sidebar._notes_buf = buf

  -- Render content
  M._render_notes_buf(buf)

  -- Keymaps: close
  vim.keymap.set("n", "q", function()
    if sidebar._notes_win and vim.api.nvim_win_is_valid(sidebar._notes_win) then
      pcall(vim.api.nvim_win_close, sidebar._notes_win, true)
      sidebar._notes_win = nil
      sidebar._notes_buf = nil
    end
  end, { buffer = buf, nowait = true, desc = "diff.nvim: close notes panel" })

  -- Keymap: delete note under cursor
  vim.keymap.set("n", "dd", function()
    local path = M._session_path
    if not path then
      vim.notify("diff.nvim: no notes file this session", vim.log.levels.WARN)
      return
    end
    M._delete_note_at_cursor(buf, path, repo_root)
  end, { buffer = buf, nowait = true, desc = "diff.nvim: delete note" })

  -- Return focus to the file panel if it's open
  if sidebar._file_win and vim.api.nvim_win_is_valid(sidebar._file_win) then
    pcall(vim.api.nvim_set_current_win, sidebar._file_win)
  end
end

-- ---------------------------------------------------------------------------
-- Highlight helpers
-- ---------------------------------------------------------------------------

--- Apply syntax-style highlights to the notes buffer lines.
function M._apply_notes_highlights(buf, lines)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for i, line in ipairs(lines) do
    local lnr = i - 1
    if line:match("^## Note") then
      vim.api.nvim_buf_add_highlight(buf, NS, "DiffNvimNoteHeader", lnr, 0, -1)
    elseif line:match("^> ") then
      vim.api.nvim_buf_add_highlight(buf, NS, "DiffNvimNoteText", lnr, 0, -1)
    elseif line:match("^%*") then
      vim.api.nvim_buf_add_highlight(buf, NS, "Comment", lnr, 0, -1)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Delete note
-- ---------------------------------------------------------------------------

--- Delete the note block that the cursor is currently in.
function M._delete_note_at_cursor(buf, path, repo_root)
  local cur_line = vim.api.nvim_win_get_cursor(0)[1] -- 1-based
  local lines    = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  -- Find the "## Note" header for this block (search upward)
  local block_start = nil
  for i = cur_line, 1, -1 do
    if lines[i]:match("^## Note") then
      block_start = i
      break
    end
  end
  if not block_start then
    vim.notify("diff.nvim: cursor is not inside a note block", vim.log.levels.WARN)
    return
  end

  -- Find the "---" separator for this block (search downward from block_start)
  local block_end = block_start
  for i = block_start + 1, #lines do
    if lines[i] == "---" then
      block_end = i
      break
    end
  end

  -- If no separator found, extend to the next ## Note header or end of file
  if block_end == block_start then
    for i = block_start + 1, #lines do
      if lines[i]:match("^## Note") then
        block_end = i - 1
        break
      end
    end
    if block_end == block_start then
      block_end = #lines
    end
  end

  -- Also consume any blank lines immediately after the separator
  while block_end < #lines and lines[block_end + 1] == "" do
    block_end = block_end + 1
  end

  -- Remove lines from buffer
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, block_start - 1, block_end, false, {})
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  -- Persist the change to disk
  local new_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local f2, f2_err = io.open(path, "w")
  if f2 then
    f2:write(table.concat(new_lines, "\n") .. "\n")
    f2:close()
    vim.notify("diff.nvim: note deleted", vim.log.levels.INFO)
    -- Re-apply highlights on successfully updated buffer
    M._apply_notes_highlights(buf, new_lines)
  else
    -- Write failed — revert the buffer to its original content
    vim.notify("diff.nvim: failed to persist deletion: " .. tostring(f2_err), vim.log.levels.ERROR)
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
    M._apply_notes_highlights(buf, lines)
  end
end

return M
