local M = {}

local git         = require("diff.git")
local diff_parser = require("diff.diff_parser")
local word_diff   = require("diff.word_diff")
local config      = require("diff.config")

local NS = vim.api.nvim_create_namespace("diff_nvim_diff")

-- ---------------------------------------------------------------------------
-- Module-level state
-- ---------------------------------------------------------------------------

M._left_win     = nil
M._right_win    = nil
M._left_buf     = nil
M._right_buf    = nil
M._left_aligned = nil   -- list of aligned line entries for the left pane
M._right_aligned= nil
M._scroll_guard = false
M._scroll_aug   = nil   -- augroup id for scroll sync
M._current_repo = nil
M._current_file = nil

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Create a scratch buffer for a diff pane.
--- @param  name string
--- @return integer
local function make_buf(name)
  -- Wipe existing buffer with same name
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == name then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.api.nvim_buf_set_option(buf, "buftype",   "nofile")
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(buf, "swapfile",  false)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  vim.api.nvim_buf_set_option(buf, "readonly",   true)
  return buf
end

--- Apply per-window options appropriate for a diff pane.
--- @param win integer
local function set_win_opts(win)
  local opts = {
    number         = true,
    relativenumber = false,
    wrap           = false,
    foldcolumn     = "0",
    signcolumn     = "yes:1",
    cursorline     = true,
    scrollbind     = false,  -- we handle sync manually via WinScrolled
    cursorbind     = false,
    diff           = false,
  }
  for k, v in pairs(opts) do
    pcall(vim.api.nvim_win_set_option, win, k, v)
  end
end

--- Find the best window to host the diff view (widest non-diff.nvim window).
--- @return integer|nil
local function find_host_window()
  local best_win   = nil
  local best_width = 0
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if not vim.api.nvim_win_is_valid(win) then goto cont end
    local buf  = vim.api.nvim_win_get_buf(win)
    local name = vim.api.nvim_buf_get_name(buf)
    -- Skip sidebar panels and existing diff panes
    if not name:match("^diff://") then
      local w = vim.api.nvim_win_get_width(win)
      if w > best_width then
        best_width = w
        best_win   = win
      end
    end
    ::cont::
  end
  return best_win
end

--- Close any open diff pane windows.
local function close_diff_wins()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) then
      local buf  = vim.api.nvim_win_get_buf(win)
      local name = vim.api.nvim_buf_get_name(buf)
      if name:match("^diff://old/") or name:match("^diff://new/") then
        -- Before closing, check if this is the last non-sidebar window
        -- and if so, replace its buffer with a new scratch buffer
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
  end

  if M._scroll_aug then
    pcall(vim.api.nvim_del_augroup_by_id, M._scroll_aug)
    M._scroll_aug = nil
  end

  M._left_win     = nil
  M._right_win    = nil
  M._left_buf     = nil
  M._right_buf    = nil
  M._left_aligned = nil
  M._right_aligned= nil
end

-- ---------------------------------------------------------------------------
-- Highlight application
-- ---------------------------------------------------------------------------

--- Apply line-level background highlights and gutter signs to one pane.
--- @param buf      integer
--- @param aligned  table[]   list of aligned line entries
local function apply_line_highlights(buf, aligned)
  for i, entry in ipairs(aligned) do
    local row = i - 1   -- 0-based

    if entry.type == "filler" then
      -- Filler: colour the whole line including EOL
      vim.api.nvim_buf_set_extmark(buf, NS, row, 0, {
        end_row    = row,
        end_col    = 0,
        hl_group   = "DiffNvimFiller",
        hl_eol     = true,
        priority   = 10,
      })

    elseif entry.type == "removed" then
      vim.api.nvim_buf_set_extmark(buf, NS, row, 0, {
        end_row      = row,
        end_col      = 0,
        hl_group     = "DiffNvimRemoved",
        hl_eol       = true,
        priority     = 10,
        sign_text    = "▍",
        sign_hl_group= "DiffNvimGutterRemoved",
      })

    elseif entry.type == "added" then
      vim.api.nvim_buf_set_extmark(buf, NS, row, 0, {
        end_row      = row,
        end_col      = 0,
        hl_group     = "DiffNvimAdded",
        hl_eol       = true,
        priority     = 10,
        sign_text    = "▍",
        sign_hl_group= "DiffNvimGutterAdded",
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
    if l.type == "removed" and r.type == "added" then
      local old_ranges, new_ranges = word_diff.compute(l.content, r.content)
      local row = i - 1

      for _, range in ipairs(old_ranges) do
        pcall(vim.api.nvim_buf_set_extmark, left_buf, NS, row, range.start_col, {
          end_row  = row,
          end_col  = range.end_col,
          hl_group = "DiffNvimRemovedWord",
          priority = 20,
        })
      end

      for _, range in ipairs(new_ranges) do
        pcall(vim.api.nvim_buf_set_extmark, right_buf, NS, row, range.start_col, {
          end_row  = row,
          end_col  = range.end_col,
          hl_group = "DiffNvimAddedWord",
          priority = 20,
        })
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Scroll synchronisation
-- ---------------------------------------------------------------------------

--- Set up WinScrolled autocmd to keep both panes in sync.
--- @param left_win  integer
--- @param right_win integer
local function setup_scroll_sync(left_win, right_win)
  if M._scroll_aug then
    pcall(vim.api.nvim_del_augroup_by_id, M._scroll_aug)
  end

  local aug = vim.api.nvim_create_augroup("DiffNvimScroll", { clear = true })
  M._scroll_aug = aug

  vim.api.nvim_create_autocmd("WinScrolled", {
    group    = aug,
    callback = function(ev)
      if M._scroll_guard then return end

      local scrolled_win = tonumber(ev.match)
      if not scrolled_win then return end

      local other_win
      if scrolled_win == left_win then
        other_win = right_win
      elseif scrolled_win == right_win then
        other_win = left_win
      else
        return
      end

      if not vim.api.nvim_win_is_valid(other_win) then return end

      M._scroll_guard = true
      local view = vim.api.nvim_win_call(scrolled_win, function()
        return vim.fn.winsaveview()
      end)
      vim.api.nvim_win_call(other_win, function()
        vim.fn.winrestview({ topline = view.topline, leftcol = view.leftcol })
      end)
      M._scroll_guard = false
    end,
  })
end

-- ---------------------------------------------------------------------------
-- Keymaps in diff pane
-- ---------------------------------------------------------------------------

--- Set up keymaps for both diff pane buffers.
--- @param left_buf  integer
--- @param right_buf integer
--- @param opts      table  {file_path, repo_root}
local function setup_keymaps(left_buf, right_buf, opts)
  local cfg = config.get()
  local km  = cfg.keymaps or {}

  local function map(buf, mode, key, fn)
    vim.keymap.set(mode, key, fn, { buffer = buf, nowait = true, silent = true })
  end

  local function leave_note(buf, side)
    return function()
      -- Capture visual selection marks (still valid after leaving visual mode)
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

  for _, entry in ipairs({
    { left_buf,  "old" },
    { right_buf, "new" },
  }) do
    local buf  = entry[1]
    local side = entry[2]

    -- Leave note (normal and visual mode)
    map(buf, { "n", "v" }, km.leave_note or "<leader>n", leave_note(buf, side))

    -- Toggle notes panel
    map(buf, "n", km.toggle_notes or "<leader>N", function()
      local annotations = require("diff.annotations")
      annotations.toggle_notes(opts.repo_root)
    end)

    -- Navigate to next changed hunk
    map(buf, "n", km.next_hunk or "]c", function()
      local cur  = vim.api.nvim_win_get_cursor(0)[1]
      local aln  = (buf == left_buf) and M._left_aligned or M._right_aligned
      if not aln then return end
      for i = cur + 1, #aln do
        if aln[i].type == "removed" or aln[i].type == "added" then
          vim.api.nvim_win_set_cursor(0, { i, 0 })
          return
        end
      end
    end)

    -- Navigate to previous changed hunk
    map(buf, "n", km.prev_hunk or "[c", function()
      local cur  = vim.api.nvim_win_get_cursor(0)[1]
      local aln  = (buf == left_buf) and M._left_aligned or M._right_aligned
      if not aln then return end
      for i = cur - 1, 1, -1 do
        if aln[i].type == "removed" or aln[i].type == "added" then
          vim.api.nvim_win_set_cursor(0, { i, 0 })
          return
        end
      end
    end)

    -- Close diff view
    map(buf, "n", "q", function()
      close_diff_wins()
    end)
  end
end

-- ---------------------------------------------------------------------------
-- Core open function
-- ---------------------------------------------------------------------------

--- Open the split diff view with the provided content.
--- @param opts table {repo_root, file_path, old_lines, new_lines, diff_text, filetype}
function M.open(opts)
  close_diff_wins()

  local old_lines = opts.old_lines or {}
  local new_lines = opts.new_lines or {}
  local diff_text = opts.diff_text or ""

  -- Parse diff and build aligned line lists
  local hunks = diff_parser.parse(diff_text)
  local left_aln, right_aln = diff_parser.build_aligned_lines(hunks, old_lines, new_lines)

  M._left_aligned  = left_aln
  M._right_aligned = right_aln
  M._current_repo  = opts.repo_root
  M._current_file  = opts.file_path

  -- Create buffers
  local left_name  = "diff://old/" .. opts.file_path
  local right_name = "diff://new/" .. opts.file_path
  local left_buf   = make_buf(left_name)
  local right_buf  = make_buf(right_name)

  M._left_buf  = left_buf
  M._right_buf = right_buf

  -- Populate buffers with content lines (filler lines = empty string)
  local function fill_buf(buf, aligned)
    local content = {}
    for _, entry in ipairs(aligned) do
      table.insert(content, entry.content)
    end
    vim.api.nvim_buf_set_option(buf, "modifiable", true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
    vim.api.nvim_buf_set_option(buf, "modifiable", false)
  end

  fill_buf(left_buf,  left_aln)
  fill_buf(right_buf, right_aln)

  -- Set filetype for syntax highlighting (Tree-sitter / filetype pipelines)
  local ft = opts.filetype or ""
  if ft == "" then
    ft = vim.filetype.match({ filename = opts.file_path }) or ""
  end
  if ft ~= "" then
    pcall(vim.api.nvim_buf_set_option, left_buf,  "filetype", ft)
    pcall(vim.api.nvim_buf_set_option, right_buf, "filetype", ft)
  end

  -- ── Create windows ───────────────────────────────────────────────────────
  local host = find_host_window()

  if host then
    vim.api.nvim_set_current_win(host)
    -- Replace host with the right (new) pane
    vim.api.nvim_win_set_buf(host, right_buf)
    local right_win = host
    -- Split left for the old pane
    vim.cmd("leftabove vsplit")
    local left_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(left_win, left_buf)

    M._left_win  = left_win
    M._right_win = right_win
  else
    -- No suitable host — create both windows fresh
    vim.cmd("vsplit")
    local right_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(right_win, right_buf)
    vim.cmd("leftabove vsplit")
    local left_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(left_win, left_buf)

    M._left_win  = left_win
    M._right_win = right_win
  end

  set_win_opts(M._left_win)
  set_win_opts(M._right_win)

  -- ── Apply highlights ─────────────────────────────────────────────────────
  vim.api.nvim_buf_clear_namespace(left_buf,  NS, 0, -1)
  vim.api.nvim_buf_clear_namespace(right_buf, NS, 0, -1)

  apply_line_highlights(left_buf,  left_aln)
  apply_line_highlights(right_buf, right_aln)
  apply_word_highlights(left_buf, right_buf, left_aln, right_aln)

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
-- Open diff for a file from the file panel
-- ---------------------------------------------------------------------------

--- Determine the old (left) file content for a given file and staging state.
--- @param root     string
--- @param file     table   file_info from git.get_status
--- @param callback fun(lines: string[])
local function get_old_content(root, file, callback)
  if file.staged then
    -- staged diff → old = HEAD
    git.get_file_at_ref(root, "HEAD", file.path, function(lines, err)
      callback(err and {} or lines)
    end)
  else
    -- unstaged diff → old = index (:path)
    git.run({ "show", ":" .. file.path }, root, function(lines, _, code)
      if code == 0 then
        callback(lines)
      else
        -- no staged version → fall back to HEAD
        git.get_file_at_ref(root, "HEAD", file.path, function(lines2, err2)
          callback(err2 and {} or lines2)
        end)
      end
    end)
  end
end

--- Determine the new (right) file content.
--- @param root     string
--- @param file     table
--- @param callback fun(lines: string[])
local function get_new_content(root, file, callback)
  if file.staged then
    -- staged diff → new = index
    git.run({ "show", ":" .. file.path }, root, function(lines, _, code)
      callback(code == 0 and lines or {})
    end)
  else
    -- unstaged diff → new = working tree
    local full = root .. "/" .. file.path
    local lines = {}
    local f = io.open(full, "r")
    if f then
      for line in f:lines() do table.insert(lines, line) end
      f:close()
    end
    callback(lines)
  end
end

--- Open the diff view for a file from the file panel.
--- @param repo_root string
--- @param file_info table   {path, status, staged}
function M.open_file_diff(repo_root, file_info)
  -- Binary detection
  git.is_binary(repo_root, file_info.path, function(is_bin)
    if is_bin then
      vim.notify(
        "diff.nvim: binary file — " .. file_info.path,
        vim.log.levels.INFO
      )
      return
    end

    local pending = 3
    local old_lines, new_lines, diff_text

    local function done()
      pending = pending - 1
      if pending > 0 then return end

      local ft = vim.filetype.match({ filename = file_info.path }) or ""
      M.open({
        repo_root  = repo_root,
        file_path  = file_info.path,
        old_lines  = old_lines  or {},
        new_lines  = new_lines  or {},
        diff_text  = diff_text  or "",
        filetype   = ft,
      })
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
end

-- ---------------------------------------------------------------------------
-- Open diff for a commit
-- ---------------------------------------------------------------------------

--- Open a diff view scoped to a specific commit (all changed files).
--- @param repo_root string
--- @param hash      string
--- @param file_path string|nil   narrow to a single file if provided
function M.open_commit_diff(repo_root, hash, file_path)
  git.get_commit_diff(repo_root, hash, file_path, function(diff_text, err)
    if err then
      vim.notify("diff.nvim: commit diff error: " .. err, vim.log.levels.ERROR)
      return
    end

    -- Determine which file path to use for the view label
    local fp = file_path

    if not fp then
      -- Try to extract the first changed file from the diff header
      for line in (diff_text or ""):gmatch("[^\n]+") do
        local m = line:match("^%+%+%+ b/(.+)$")
        if m then fp = m break end
      end
      fp = fp or (hash:sub(1, 7) .. " (all files)")
    end

    -- Fetch old and new content for the file (or leave empty for multi-file commit)
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
      local ft = fp and (vim.filetype.match({ filename = fp }) or "") or ""
      M.open({
        repo_root = repo_root,
        file_path = fp or hash:sub(1, 7),
        old_lines = old_lines or {},
        new_lines = new_lines or {},
        diff_text = diff_text or "",
        filetype  = ft,
      })
    end

    fetch_side(hash .. "^", file_path, function(lines)
      old_lines = lines; done()
    end)
    fetch_side(hash, file_path, function(lines)
      new_lines = lines; done()
    end)
  end)
end

return M
