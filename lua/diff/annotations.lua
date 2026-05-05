local M = {}

local config = require("diff.config")

-- Namespace for highlights in the notes panel
local NS = vim.api.nvim_create_namespace("diff_nvim_notes")

-- Track the open notes window
M._win = nil
M._buf = nil

--- Get the path to the notes Markdown file for a given repo root.
--- Uses config.notes_path if set, otherwise XDG_DATA_HOME/diff.nvim/<slug>.md
--- @param repo_root string
--- @return string
function M.get_notes_path(repo_root)
  local cfg = config.get()
  if cfg.notes_path and cfg.notes_path ~= "" then
    return cfg.notes_path
  end

  local xdg = os.getenv("XDG_DATA_HOME")
  if not xdg or xdg == "" then
    xdg = (os.getenv("HOME") or "") .. "/.local/share"
  end
  local dir = xdg .. "/diff.nvim"
  vim.fn.mkdir(dir, "p")

  -- Slug: last path component + sanitised full path hash suffix
  local repo_name = repo_root:match("[^/]+$") or "repo"
  local slug = repo_root:gsub("[^%w%-_]", "_")
  -- Keep path manageable: take last 60 chars of the slug
  if #slug > 60 then slug = slug:sub(-60) end

  return dir .. "/" .. repo_name .. "_" .. slug .. ".md"
end

--- Append a note entry to the notes file.
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
    lines_str = lines_str .. "–" .. tostring(note.line_end)
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

  vim.notify("diff.nvim: note saved → " .. path, vim.log.levels.INFO)
end

--- Open a small floating input prompt and call back with the entered text.
--- @param opts table  {file_path, line_start, line_end, side, repo_root}
function M.prompt_note(opts)
  -- Create a scratch buffer for the prompt
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("buftype", "prompt", { buf = buf })
  vim.fn.prompt_setprompt(buf, "Note: ")

  local width  = math.min(70, vim.o.columns - 4)
  local row    = math.floor((vim.o.lines - 3) / 2)
  local col    = math.floor((vim.o.columns - width) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative   = "editor",
    width      = width,
    height     = 1,
    row        = row,
    col        = col,
    style      = "minimal",
    border     = "rounded",
    title      = " Leave Note ",
    title_pos  = "center",
  })

  vim.cmd("startinsert")

  -- Confirm with <CR>
  vim.fn.prompt_setcallback(buf, function(text)
    vim.api.nvim_win_close(win, true)
    if text and text ~= "" then
      M.append_note(vim.tbl_extend("force", opts, {
        text      = text,
        timestamp = os.date("%Y-%m-%d %H:%M:%S"),
      }))
    end
  end)

  -- Cancel with <Esc>
  vim.keymap.set({ "n", "i" }, "<Esc>", function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end, { buffer = buf, nowait = true })
end

--- Toggle the notes panel (floating window with all saved notes).
--- @param repo_root string
function M.toggle_notes(repo_root)
  -- Close if already open
  if M._win and vim.api.nvim_win_is_valid(M._win) then
    vim.api.nvim_win_close(M._win, true)
    M._win = nil
    M._buf = nil
    return
  end

  local path  = M.get_notes_path(repo_root)
  local lines = {}

  local f = io.open(path, "r")
  if f then
    for line in f:lines() do
      table.insert(lines, line)
    end
    f:close()
  end

  if #lines == 0 then
    lines = { "# diff.nvim Notes", "", "No notes yet." }
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local width  = math.min(80, vim.o.columns - 4)
  local height = math.min(40, vim.o.lines - 4)
  local row    = math.floor((vim.o.lines   - height) / 2)
  local col    = math.floor((vim.o.columns - width)  / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    width     = width,
    height    = height,
    row       = row,
    col       = col,
    style     = "minimal",
    border    = "rounded",
    title     = " diff.nvim Notes  [dd=delete  q=close] ",
    title_pos = "center",
  })

  vim.api.nvim_set_option_value("wrap", false, { win = win })
  vim.api.nvim_set_option_value("number", false, { win = win })

  M._win = win
  M._buf = buf

  -- Apply highlights
  M._apply_notes_highlights(buf, lines)

  -- Keymaps: close
  for _, k in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", k, function()
      if M._win and vim.api.nvim_win_is_valid(M._win) then
        vim.api.nvim_win_close(M._win, true)
        M._win = nil
        M._buf = nil
      end
    end, { buffer = buf, nowait = true })
  end

  -- Keymap: delete note under cursor
  vim.keymap.set("n", "dd", function()
    M._delete_note_at_cursor(buf, path, repo_root)
  end, { buffer = buf, nowait = true })
end

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
  local f = io.open(path, "w")
  if f then
    f:write(table.concat(new_lines, "\n") .. "\n")
    f:close()
    vim.notify("diff.nvim: note deleted", vim.log.levels.INFO)
  end

  -- Re-apply highlights
  M._apply_notes_highlights(buf, new_lines)
end

return M
