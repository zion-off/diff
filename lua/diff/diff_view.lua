local M = {}

local git         = require("diff.git")
local diff_parser = require("diff.diff_parser")
local word_diff   = require("diff.word_diff")
local config      = require("diff.config")

local NS = vim.api.nvim_create_namespace("diff_nvim_diff")

-- ---------------------------------------------------------------------------
-- Module-level state
-- ---------------------------------------------------------------------------

M._left_win      = nil
M._right_win     = nil
M._left_buf      = nil
M._right_buf     = nil
M._left_aligned  = nil
M._right_aligned = nil
M._scroll_guard  = false
M._scroll_aug    = nil
M._current_repo  = nil
M._current_file  = nil
M._buf_aligned   = {}

-- Cursor alignment lookup tables (built at render time)
-- Maps: left_to_right[left_buf_line] = right_buf_line (and vice-versa)
M._left_to_right = nil
M._right_to_left = nil

-- State needed for expand-context feature
M._current_hunks    = nil
M._current_old      = nil
M._current_new      = nil
M._current_ctx      = nil
M._current_ft       = nil

-- Single-pane mode
M._single_pane      = false
M._single_side      = nil  -- "old" or "new"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Create a scratch buffer for a diff pane.
--- @param  name string
--- @return integer
local function make_buf(name)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == name then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  return buf
end

--- Apply per-window options appropriate for a diff pane.
--- @param win integer
local function set_win_opts(win)
  local wopts = {
    number         = true,
    relativenumber = false,
    wrap           = false,
    foldcolumn     = "0",
    signcolumn     = "yes:1",
    cursorline     = true,
    scrollbind     = false,
    cursorbind     = false,
    diff           = false,
  }
  for k, v in pairs(wopts) do
    pcall(vim.api.nvim_set_option_value, k, v, { win = win })
  end
end

--- Close any open diff pane windows safely.
local function close_diff_wins()
  if M._scroll_aug then
    pcall(vim.api.nvim_del_augroup_by_id, M._scroll_aug)
    M._scroll_aug = nil
  end

  -- Reset scroll guard to prevent permanent lockout
  M._scroll_guard = false

  -- Determine if we need to restore the main area window
  local sidebar = require("diff.sidebar")
  local right_is_main = (M._right_win == sidebar._main_win)
  local left_is_main  = (M._left_win  == sidebar._main_win)

  for _, win in ipairs({ M._left_win, M._right_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      -- Don't close the main area window — just clear its buffer
      if (win == M._right_win and right_is_main) or (win == M._left_win and left_is_main) then
        local placeholder = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_set_option_value("buftype", "nofile", { buf = placeholder })
        vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = placeholder })
        vim.api.nvim_buf_set_lines(placeholder, 0, -1, false, {
          "",
          "  diff.nvim",
          "",
          "  Select a file from the sidebar to view its diff.",
          "",
        })
        pcall(vim.api.nvim_win_set_buf, win, placeholder)
        -- Clear winbar
        pcall(vim.api.nvim_set_option_value, "winbar", "", { win = win })
      else
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
  end

  if M._left_buf  then M._buf_aligned[M._left_buf]  = nil end
  if M._right_buf then M._buf_aligned[M._right_buf] = nil end

  M._left_win      = nil
  M._right_win     = nil
  M._left_buf      = nil
  M._right_buf     = nil
  M._left_aligned  = nil
  M._right_aligned = nil
  M._left_to_right = nil
  M._right_to_left = nil
  M._single_pane   = false
  M._single_side   = nil
end

--- Build cursor alignment lookup tables from aligned lists.
--- Both aligned arrays are guaranteed to be the same length by the diff_parser.
--- Since line i in left corresponds to line i in right by construction
--- (fillers pad both sides equally), the mapping is identity.
--- This function exists to make the cursor sync code explicit about the invariant.
--- @param left_aln  table[]
--- @param right_aln table[]
local function build_cursor_map(left_aln, right_aln)
  local len = math.min(#left_aln, #right_aln)
  local l2r = {}
  local r2l = {}

  for i = 1, len do
    l2r[i] = i
    r2l[i] = i
  end

  M._left_to_right = l2r
  M._right_to_left = r2l
end

-- ---------------------------------------------------------------------------
-- Highlight application
-- ---------------------------------------------------------------------------

--- Apply line-level background highlights, gutter signs, and separator/filler styling.
--- @param buf      integer
--- @param aligned  table[]
--- @param side     string "old"|"new"|nil
local function apply_line_highlights(buf, aligned, side)
  for i, entry in ipairs(aligned) do
    local row = i - 1

    if entry.type == "filler" then
      -- Use virtual text with stipple character for visual distinction
      vim.api.nvim_buf_set_extmark(buf, NS, row, 0, {
        line_hl_group = "DiffNvimFiller",
        virt_text     = { { string.rep("░", 80), "DiffNvimFillerChar" } },
        virt_text_pos = "overlay",
        priority      = 50,
      })

    elseif entry.type == "removed" then
      vim.api.nvim_buf_set_extmark(buf, NS, row, 0, {
        line_hl_group  = "DiffNvimRemoved",
        sign_text      = "▍",
        sign_hl_group  = "DiffNvimGutterRemoved",
        priority       = 50,
      })

    elseif entry.type == "added" then
      vim.api.nvim_buf_set_extmark(buf, NS, row, 0, {
        line_hl_group  = "DiffNvimAdded",
        sign_text      = "▍",
        sign_hl_group  = "DiffNvimGutterAdded",
        priority       = 50,
      })

    elseif entry.type == "separator" then
      vim.api.nvim_buf_set_extmark(buf, NS, row, 0, {
        line_hl_group = "DiffNvimSeparator",
        priority      = 50,
      })
    end
  end
end

--- Apply word-level diff highlights on paired removed/added lines.
--- @param left_buf   integer
--- @param right_buf  integer
--- @param left_aln   table[]
--- @param right_aln  table[]
local function apply_word_highlights(left_buf, right_buf, left_aln, right_aln)
  local len = math.min(#left_aln, #right_aln)
  for i = 1, len do
    local l = left_aln[i]
    local r = right_aln[i]
    if l.type == "removed" and r.type == "added" and l.content ~= "" and r.content ~= "" then
      local ok, old_ranges, new_ranges = pcall(word_diff.compute, l.content, r.content)
      if not ok then goto continue end
      local row = i - 1

      for _, range in ipairs(old_ranges) do
        if range.end_col > range.start_col then
          pcall(vim.api.nvim_buf_set_extmark, left_buf, NS, row, range.start_col, {
            end_row  = row,
            end_col  = math.min(range.end_col, #l.content),
            hl_group = "DiffNvimRemovedWord",
            priority = 60,
          })
        end
      end

      for _, range in ipairs(new_ranges) do
        if range.end_col > range.start_col then
          pcall(vim.api.nvim_buf_set_extmark, right_buf, NS, row, range.start_col, {
            end_row  = row,
            end_col  = math.min(range.end_col, #r.content),
            hl_group = "DiffNvimAddedWord",
            priority = 60,
          })
        end
      end
    end
    ::continue::
  end
end

--- Place note markers (gutter sign + virtual text) for any notes matching the file.
--- @param buf       integer
--- @param aligned   table[]
--- @param side      string "old"|"new"
--- @param repo_root string
--- @param file_path string
local function apply_note_markers(buf, aligned, side, repo_root, file_path)
  local annotations = require("diff.annotations")
  local notes_path = annotations.get_notes_path(repo_root)

  local f = io.open(notes_path, "r")
  if not f then return end

  local content = f:read("*a")
  f:close()
  if not content or content == "" then return end

  -- Parse notes to find any referencing this file
  local ns_notes = vim.api.nvim_create_namespace("diff_nvim_notes_markers")
  vim.api.nvim_buf_clear_namespace(buf, ns_notes, 0, -1)

  -- Pattern: ## Note — <file_path>, lines <start>[–<end>] [(<side> side)]
  -- Tolerant: accepts both en-dash and hyphen; handles blank line between header and quote
  for header, note_text in content:gmatch("## Note [—%-]- ([^\n]+)\n+> ([^\n]+)") do
    local note_file = header:match("^(.+), lines %d+")
    if note_file and note_file == file_path then
      local note_side = header:match("%((.+) side%)")
      -- Only show markers on the matching side (or both if side unspecified)
      if not note_side or note_side == side then
        local line_start = tonumber(header:match("lines (%d+)"))
        if line_start then
          -- Find the buffer line that corresponds to this file line
          for i, entry in ipairs(aligned) do
            if entry.line_num == line_start then
              local row = i - 1
              local preview = note_text:sub(1, 40)
              if #note_text > 40 then preview = preview .. "…" end
              pcall(vim.api.nvim_buf_set_extmark, buf, ns_notes, row, 0, {
                sign_text     = "▸",
                sign_hl_group = "DiffNvimNoteMarker",
                virt_text     = { { "  " .. preview, "DiffNvimNoteVirtText" } },
                virt_text_pos = "eol",
                priority      = 70,
              })
              break
            end
          end
        end
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Scroll synchronisation — topline-based, properly guarded
-- ---------------------------------------------------------------------------

local function setup_scroll_sync(left_win, right_win)
  if M._scroll_aug then
    pcall(vim.api.nvim_del_augroup_by_id, M._scroll_aug)
  end

  local aug = vim.api.nvim_create_augroup("DiffNvimScroll", { clear = true })
  M._scroll_aug = aug

  -- Sync topline: since both buffers have identical line count (aligned),
  -- syncing topline directly keeps them visually aligned.
  vim.api.nvim_create_autocmd("WinScrolled", {
    group    = aug,
    callback = function()
      if M._scroll_guard then return end

      local cur_win = vim.api.nvim_get_current_win()
      local source_win, target_win

      if cur_win == left_win then
        source_win = left_win
        target_win = right_win
      elseif cur_win == right_win then
        source_win = right_win
        target_win = left_win
      else
        return
      end

      if not vim.api.nvim_win_is_valid(source_win) then return end
      if not vim.api.nvim_win_is_valid(target_win) then return end

      M._scroll_guard = true

      local info = vim.fn.getwininfo(source_win)
      if not info or #info == 0 then
        vim.schedule(function() M._scroll_guard = false end)
        return
      end
      local topline = info[1].topline
      local leftcol = info[1].leftcol or 0

      vim.api.nvim_win_call(target_win, function()
        vim.fn.winrestview({ topline = topline, leftcol = leftcol })
      end)

      -- Release guard asynchronously to prevent cascading
      vim.schedule(function()
        M._scroll_guard = false
      end)
    end,
  })

  -- Sync cursor line via aligned_index (handles filler lines correctly)
  vim.api.nvim_create_autocmd("CursorMoved", {
    group    = aug,
    callback = function()
      if M._scroll_guard then return end

      local cur_win = vim.api.nvim_get_current_win()
      local source_win, target_win, lookup

      if cur_win == left_win then
        source_win = left_win
        target_win = right_win
        lookup     = M._left_to_right
      elseif cur_win == right_win then
        source_win = right_win
        target_win = left_win
        lookup     = M._right_to_left
      else
        return
      end

      if not vim.api.nvim_win_is_valid(target_win) then return end
      if not lookup then return end

      M._scroll_guard = true

      local cursor = vim.api.nvim_win_get_cursor(source_win)
      local target_line = lookup[cursor[1]]
      if target_line then
        local target_buf = vim.api.nvim_win_get_buf(target_win)
        local line_count = vim.api.nvim_buf_line_count(target_buf)
        target_line = math.min(target_line, line_count)
        pcall(vim.api.nvim_win_set_cursor, target_win, { target_line, 0 })
      end

      vim.schedule(function()
        M._scroll_guard = false
      end)
    end,
  })
end

-- ---------------------------------------------------------------------------
-- Keymaps in diff pane
-- ---------------------------------------------------------------------------

local function setup_keymaps(left_buf, right_buf, opts)
  local cfg = config.get()
  local km  = cfg.keymaps or {}

  local function map(buf, mode, key, fn, desc)
    vim.keymap.set(mode, key, fn, { buffer = buf, nowait = true, silent = true, desc = "diff.nvim: " .. desc })
  end

  local function leave_note(buf, side)
    return function()
      local annotations = require("diff.annotations")
      local vstart = vim.fn.getpos("'<")
      local vend   = vim.fn.getpos("'>")
      local line_start, line_end

      if vstart[2] > 0 then
        line_start = vstart[2]
        line_end   = vend[2]
      else
        local pos  = vim.api.nvim_win_get_cursor(0)
        line_start = pos[1]
        line_end   = pos[1]
      end

      -- Map buffer line to actual file line via aligned table
      local aligned = (buf == left_buf) and M._left_aligned or M._right_aligned
      if aligned then
        local function file_line(buf_line)
          local entry = aligned[buf_line]
          return entry and entry.line_num or buf_line
        end
        line_start = file_line(line_start) or line_start
        line_end   = file_line(line_end)   or line_end
      end

      annotations.prompt_note({
        file_path  = opts.file_path,
        line_start = line_start,
        line_end   = line_end,
        side       = side,
        repo_root  = opts.repo_root,
      })
    end
  end

  local bufs_to_map = {}
  if left_buf then table.insert(bufs_to_map, { left_buf, "old" }) end
  if right_buf then table.insert(bufs_to_map, { right_buf, "new" }) end

  for _, entry in ipairs(bufs_to_map) do
    local buf  = entry[1]
    local side = entry[2]

    -- Leave note
    map(buf, { "n", "v" }, km.leave_note or "<leader>n", leave_note(buf, side), "leave note")

    -- Toggle notes panel
    map(buf, "n", km.toggle_notes or "<leader>N", function()
      require("diff.annotations").toggle_notes(opts.repo_root)
    end, "toggle notes panel")

    -- Next hunk
    map(buf, "n", km.next_hunk or "]c", function()
      local cur = vim.api.nvim_win_get_cursor(0)[1]
      local aln = (buf == left_buf) and M._left_aligned or M._right_aligned
      if not aln then return end
      for i = cur + 1, #aln do
        if aln[i].type == "removed" or aln[i].type == "added" then
          vim.api.nvim_win_set_cursor(0, { i, 0 })
          return
        end
      end
    end, "next hunk")

    -- Prev hunk
    map(buf, "n", km.prev_hunk or "[c", function()
      local cur = vim.api.nvim_win_get_cursor(0)[1]
      local aln = (buf == left_buf) and M._left_aligned or M._right_aligned
      if not aln then return end
      for i = cur - 1, 1, -1 do
        if aln[i].type == "removed" or aln[i].type == "added" then
          vim.api.nvim_win_set_cursor(0, { i, 0 })
          return
        end
      end
    end, "prev hunk")

    -- Expand context (zo)
    map(buf, "n", km.expand_context or "zo", function()
      M.expand_context()
    end, "expand context (+10 lines)")

    -- Expand all (zR)
    map(buf, "n", km.expand_all or "zR", function()
      M.expand_all()
    end, "show all context")

    -- Close diff view (return to sidebar)
    map(buf, "n", "q", function()
      close_diff_wins()
      local sidebar = require("diff.sidebar")
      if sidebar._file_win and vim.api.nvim_win_is_valid(sidebar._file_win) then
        vim.api.nvim_set_current_win(sidebar._file_win)
      end
    end, "close diff view")
  end
end

--- Expand context by 10 lines and re-render.
function M.expand_context()
  if not M._current_hunks then return end
  local current = M._current_ctx or 3
  M._current_ctx = current + 10
  M.rerender()
end

--- Show all context (no collapsing).
function M.expand_all()
  if not M._current_hunks then return end
  M._current_ctx = nil
  M.rerender()
end

--- Re-render the diff with current state (used after context expansion).
function M.rerender()
  -- Single-pane mode does not support expand/collapse
  if M._single_pane then return end

  if not M._current_hunks or not M._current_old or not M._current_new then return end
  if not M._left_buf or not vim.api.nvim_buf_is_valid(M._left_buf) then return end
  if M._right_buf and not vim.api.nvim_buf_is_valid(M._right_buf) then return end

  local left_aln, right_aln = diff_parser.build_aligned_lines(
    M._current_hunks, M._current_old, M._current_new, M._current_ctx
  )

  M._left_aligned  = left_aln
  M._right_aligned = right_aln
  M._buf_aligned[M._left_buf] = left_aln
  if M._right_buf then
    M._buf_aligned[M._right_buf] = right_aln
  end

  -- Rebuild cursor alignment map
  build_cursor_map(left_aln, right_aln)

  -- Re-fill buffers
  local function fill_buf(buf, aligned)
    local content = {}
    for _, e in ipairs(aligned) do
      table.insert(content, e.content)
    end
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  end

  fill_buf(M._left_buf, left_aln)
  if M._right_buf then
    fill_buf(M._right_buf, right_aln)
  end

  -- Re-apply highlights
  vim.api.nvim_buf_clear_namespace(M._left_buf, NS, 0, -1)
  apply_line_highlights(M._left_buf, left_aln, "old")
  if M._right_buf then
    vim.api.nvim_buf_clear_namespace(M._right_buf, NS, 0, -1)
    apply_line_highlights(M._right_buf, right_aln, "new")
    apply_word_highlights(M._left_buf, M._right_buf, left_aln, right_aln)
  end

  -- Re-apply tree-sitter
  local ft = M._current_ft or ""
  if ft ~= "" then
    pcall(vim.treesitter.start, M._left_buf, ft)
    if M._right_buf then
      pcall(vim.treesitter.start, M._right_buf, ft)
    end
  end

  -- Re-apply note markers
  if M._current_repo and M._current_file then
    apply_note_markers(M._left_buf, left_aln, "old", M._current_repo, M._current_file)
    if M._right_buf then
      apply_note_markers(M._right_buf, right_aln, "new", M._current_repo, M._current_file)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Core open function
-- ---------------------------------------------------------------------------

--- Open the split diff view with the provided content.
--- @param opts table {repo_root, file_path, old_lines, new_lines, diff_text, filetype, file_status}
function M.open(opts)
  close_diff_wins()

  local old_lines = opts.old_lines or {}
  local new_lines = opts.new_lines or {}
  local diff_text = opts.diff_text or ""
  local file_status = opts.file_status or nil

  -- Detect single-pane mode: added/untracked files (no old) or deleted files (no new)
  local single_pane = false
  local single_side = nil

  if file_status == "added" or file_status == "untracked" then
    single_pane = true
    single_side = "new"
  elseif file_status == "deleted" then
    single_pane = true
    single_side = "old"
  end

  M._single_pane = single_pane
  M._single_side = single_side

  -- Parse diff and build aligned line lists
  local hunks = diff_parser.parse(diff_text)

  local cfg = config.get()
  local ctx = cfg.context_lines

  local left_aln, right_aln
  if single_pane then
    -- For single-pane mode, create a simple list with all lines marked
    if single_side == "new" then
      left_aln = {}
      right_aln = {}
      for i, line in ipairs(new_lines) do
        table.insert(right_aln, { content = line, line_num = i, type = "added" })
      end
      left_aln = right_aln  -- unused in single-pane but keeps structure consistent
    else
      left_aln = {}
      right_aln = {}
      for i, line in ipairs(old_lines) do
        table.insert(left_aln, { content = line, line_num = i, type = "removed" })
      end
      right_aln = left_aln
    end
  else
    left_aln, right_aln = diff_parser.build_aligned_lines(hunks, old_lines, new_lines, ctx)
  end

  M._left_aligned    = left_aln
  M._right_aligned   = right_aln
  M._current_repo    = opts.repo_root
  M._current_file    = opts.file_path
  M._current_hunks   = hunks
  M._current_old     = old_lines
  M._current_new     = new_lines
  M._current_ctx     = ctx
  M._current_ft      = opts.filetype

  -- Build cursor alignment map
  if not single_pane then
    build_cursor_map(left_aln, right_aln)
  end

  -- ── Single-pane mode ────────────────────────────────────────────────────
  if single_pane then
    local pane_name = single_side == "new"
      and ("diff://new/" .. opts.file_path)
      or  ("diff://old/" .. opts.file_path)
    local pane_buf = make_buf(pane_name)
    local aln = single_side == "new" and right_aln or left_aln

    -- Populate buffer
    local content = {}
    for _, e in ipairs(aln) do table.insert(content, e.content) end
    vim.api.nvim_set_option_value("modifiable", true, { buf = pane_buf })
    vim.api.nvim_buf_set_lines(pane_buf, 0, -1, false, content)
    vim.api.nvim_set_option_value("modifiable", false, { buf = pane_buf })

    -- Set filetype
    local ft = opts.filetype or ""
    if ft == "" then ft = vim.filetype.match({ filename = opts.file_path }) or "" end
    if ft ~= "" then
      pcall(vim.api.nvim_set_option_value, "filetype", ft, { buf = pane_buf })
      pcall(vim.treesitter.start, pane_buf, ft)
    end

    -- Create window
    local sidebar = require("diff.sidebar")
    local main_win = sidebar.get_main_win()

    if main_win and vim.api.nvim_win_is_valid(main_win) then
      vim.api.nvim_set_current_win(main_win)
      vim.api.nvim_win_set_buf(main_win, pane_buf)
      if single_side == "new" then
        M._right_win = main_win
        M._right_buf = pane_buf
        M._left_win = nil
        M._left_buf = nil
      else
        M._left_win = main_win
        M._left_buf = pane_buf
        M._right_win = nil
        M._right_buf = nil
      end

      set_win_opts(main_win)

      -- Winbar
      local label = single_side == "new" and "NEW: " or "DELETED: "
      pcall(vim.api.nvim_set_option_value, "winbar",
        "%#DiffNvimWinbar#  " .. label .. opts.file_path .. "  ",
        { win = main_win })
    end

    -- Apply highlights
    vim.api.nvim_buf_clear_namespace(pane_buf, NS, 0, -1)
    apply_line_highlights(pane_buf, aln, single_side)

    -- Note markers
    apply_note_markers(pane_buf, aln, single_side, opts.repo_root, opts.file_path)

    -- Keymaps (single buffer)
    M._buf_aligned[pane_buf] = aln
    setup_keymaps(
      single_side == "old" and pane_buf or nil,
      single_side == "new" and pane_buf or nil,
      { file_path = opts.file_path, repo_root = opts.repo_root }
    )

    return
  end

  -- ── Two-pane mode ───────────────────────────────────────────────────────
  local left_name  = "diff://old/" .. opts.file_path
  local right_name = "diff://new/" .. opts.file_path
  local left_buf   = make_buf(left_name)
  local right_buf  = make_buf(right_name)

  M._left_buf  = left_buf
  M._right_buf = right_buf
  M._buf_aligned[left_buf]  = left_aln
  M._buf_aligned[right_buf] = right_aln

  -- Populate buffers
  local function fill_buf(buf, aligned)
    local content = {}
    for _, e in ipairs(aligned) do table.insert(content, e.content) end
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  end

  fill_buf(left_buf,  left_aln)
  fill_buf(right_buf, right_aln)

  -- Set filetype and start tree-sitter for syntax highlighting
  local ft = opts.filetype or ""
  if ft == "" then ft = vim.filetype.match({ filename = opts.file_path }) or "" end
  if ft ~= "" then
    pcall(vim.api.nvim_set_option_value, "filetype", ft, { buf = left_buf })
    pcall(vim.api.nvim_set_option_value, "filetype", ft, { buf = right_buf })
    -- Explicitly start tree-sitter (buftype=nofile doesn't auto-attach)
    pcall(vim.treesitter.start, left_buf, ft)
    pcall(vim.treesitter.start, right_buf, ft)
  end

  -- ── Create windows in the main area ─────────────────────────────────────
  local sidebar = require("diff.sidebar")
  local main_win = sidebar.get_main_win()

  if main_win and vim.api.nvim_win_is_valid(main_win) then
    vim.api.nvim_set_current_win(main_win)
    vim.api.nvim_win_set_buf(main_win, right_buf)
    local right_win = main_win

    vim.cmd("leftabove vsplit")
    local left_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(left_win, left_buf)

    M._left_win  = left_win
    M._right_win = right_win

    sidebar.set_main_win(right_win)
  else
    -- Fallback: find the widest non-panel window
    local best_win, best_width = nil, 0
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(win) then
        local buf = vim.api.nvim_win_get_buf(win)
        local name = vim.api.nvim_buf_get_name(buf)
        if not name:match("^diff://file") and not name:match("^diff://commit") then
          local w = vim.api.nvim_win_get_width(win)
          if w > best_width then
            best_width = w
            best_win   = win
          end
        end
      end
    end

    if best_win then
      vim.api.nvim_set_current_win(best_win)
      vim.api.nvim_win_set_buf(best_win, right_buf)
      vim.cmd("leftabove vsplit")
      local left_win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(left_win, left_buf)
      M._left_win  = left_win
      M._right_win = best_win
    else
      vim.cmd("vsplit")
      M._right_win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(M._right_win, right_buf)
      vim.cmd("leftabove vsplit")
      M._left_win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(M._left_win, left_buf)
    end
  end

  set_win_opts(M._left_win)
  set_win_opts(M._right_win)

  -- ── Winbar (shows filename + side) ───────────────────────────────────────
  local short_path = opts.file_path
  pcall(vim.api.nvim_set_option_value, "winbar",
    "%#DiffNvimWinbar#  OLD: " .. short_path .. "  ",
    { win = M._left_win })
  pcall(vim.api.nvim_set_option_value, "winbar",
    "%#DiffNvimWinbar#  NEW: " .. short_path .. "  ",
    { win = M._right_win })

  -- ── Apply highlights ─────────────────────────────────────────────────────
  vim.api.nvim_buf_clear_namespace(left_buf,  NS, 0, -1)
  vim.api.nvim_buf_clear_namespace(right_buf, NS, 0, -1)

  apply_line_highlights(left_buf,  left_aln,  "old")
  apply_line_highlights(right_buf, right_aln, "new")
  apply_word_highlights(left_buf, right_buf, left_aln, right_aln)

  -- ── Note markers ─────────────────────────────────────────────────────────
  apply_note_markers(left_buf, left_aln, "old", opts.repo_root, opts.file_path)
  apply_note_markers(right_buf, right_aln, "new", opts.repo_root, opts.file_path)

  -- ── Scroll sync ──────────────────────────────────────────────────────────
  setup_scroll_sync(M._left_win, M._right_win)

  -- ── Keymaps ──────────────────────────────────────────────────────────────
  setup_keymaps(left_buf, right_buf, {
    file_path = opts.file_path,
    repo_root = opts.repo_root,
  })

  -- Focus the right (new) pane
  vim.api.nvim_set_current_win(M._right_win)
end

-- ---------------------------------------------------------------------------
-- Open diff for a file from the file panel (with crash protection)
-- ---------------------------------------------------------------------------

local function get_old_content(root, file, callback)
  if file.staged then
    git.get_file_at_ref(root, "HEAD", file.path, function(lines, err)
      callback(err and {} or lines)
    end)
  else
    git.run({ "show", ":" .. file.path }, root, function(lines, _, code)
      if code == 0 then
        callback(lines)
      else
        git.get_file_at_ref(root, "HEAD", file.path, function(lines2, err2)
          callback(err2 and {} or lines2)
        end)
      end
    end)
  end
end

local function get_new_content(root, file, callback)
  if file.staged then
    git.run({ "show", ":" .. file.path }, root, function(lines, _, code)
      callback(code == 0 and lines or {})
    end)
  else
    local full = root .. "/" .. file.path
    vim.schedule(function()
      local ok, lines = pcall(vim.fn.readfile, full)
      if not ok or not lines then
        vim.notify("diff.nvim: cannot read " .. file.path, vim.log.levels.WARN)
        callback({})
      else
        callback(lines)
      end
    end)
  end
end

--- Open the diff view for a file from the file panel.
--- Wrapped in pcall for crash resilience.
--- @param repo_root string
--- @param file_info table   {path, status, staged}
function M.open_file_diff(repo_root, file_info)
  local ok, err = pcall(function()
    git.is_binary(repo_root, file_info.path, function(is_bin)
      if is_bin then
        vim.notify("diff.nvim: binary file — " .. file_info.path, vim.log.levels.INFO)
        return
      end

      local pending = 3
      local old_lines, new_lines, diff_text

      local function done()
        pending = pending - 1
        if pending > 0 then return end

        local open_ok, open_err = pcall(function()
          local ft = vim.filetype.match({ filename = file_info.path }) or ""
          M.open({
            repo_root   = repo_root,
            file_path   = file_info.path,
            old_lines   = old_lines  or {},
            new_lines   = new_lines  or {},
            diff_text   = diff_text  or "",
            filetype    = ft,
            file_status = file_info.status,
          })
        end)
        if not open_ok then
          vim.notify("diff.nvim: error rendering diff: " .. tostring(open_err), vim.log.levels.ERROR)
          close_diff_wins()
        end
      end

      get_old_content(repo_root, file_info, function(lines)
        old_lines = lines
        done()
      end)

      get_new_content(repo_root, file_info, function(lines)
        new_lines = lines
        done()
      end)

      if file_info.status == "untracked" then
        git.get_untracked_diff(repo_root, file_info.path, function(text, _)
          diff_text = text or ""
          done()
        end)
      else
        git.get_diff(repo_root, file_info.path, file_info.staged or false, function(text, _)
          diff_text = text or ""
          done()
        end)
      end
    end)
  end)

  if not ok then
    vim.notify("diff.nvim: unexpected error: " .. tostring(err), vim.log.levels.ERROR)
    close_diff_wins()
  end
end

-- ---------------------------------------------------------------------------
-- Open diff for a commit (with crash protection)
-- ---------------------------------------------------------------------------

--- Open a diff view scoped to a specific commit.
--- @param repo_root    string
--- @param hash         string
--- @param file_path    string|nil
--- @param file_status  string|nil  "A","M","D" etc.
function M.open_commit_diff(repo_root, hash, file_path, file_status)
  local ok, err = pcall(function()
    git.get_commit_diff(repo_root, hash, file_path, function(diff_text, cb_err)
      if cb_err then
        vim.notify("diff.nvim: commit diff error: " .. cb_err, vim.log.levels.ERROR)
        return
      end

      local fp = file_path

      if not fp then
        for line in (diff_text or ""):gmatch("[^\n]+") do
          local m = line:match("^%+%+%+ b/(.+)$")
          if m then fp = m break end
        end
        fp = fp or (hash:sub(1, 7) .. " (all files)")
      end

      local function fetch_side(ref, path, cb)
        if not path or path:match("%(all files%)") then
          cb({})
          return
        end
        git.get_file_at_ref(repo_root, ref, path, function(lines, ferr)
          cb(ferr and {} or lines)
        end)
      end

      local pending = 2
      local old_lines, new_lines

      local function done()
        pending = pending - 1
        if pending > 0 then return end

        local open_ok, open_err = pcall(function()
          local ft = fp and (vim.filetype.match({ filename = fp }) or "") or ""
          -- Determine file status for single-pane detection
          local status = nil
          if file_status then
            if file_status == "A" then status = "added"
            elseif file_status == "D" then status = "deleted"
            end
          end
          M.open({
            repo_root   = repo_root,
            file_path   = fp or hash:sub(1, 7),
            old_lines   = old_lines or {},
            new_lines   = new_lines or {},
            diff_text   = diff_text or "",
            filetype    = ft,
            file_status = status,
          })
        end)
        if not open_ok then
          vim.notify("diff.nvim: error rendering commit diff: " .. tostring(open_err), vim.log.levels.ERROR)
          close_diff_wins()
        end
      end

      fetch_side(hash .. "^", fp, function(lines)
        old_lines = lines; done()
      end)
      fetch_side(hash, fp, function(lines)
        new_lines = lines; done()
      end)
    end)
  end)

  if not ok then
    vim.notify("diff.nvim: unexpected error in commit diff: " .. tostring(err), vim.log.levels.ERROR)
    close_diff_wins()
  end
end

return M
