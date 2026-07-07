local M = {}

local git    = require("diff.git")
local config = require("diff.config")
local util   = require("diff.util")

local NS = vim.api.nvim_create_namespace("diff_nvim_commit_panel")

-- ---------------------------------------------------------------------------
-- Module-level state
-- ---------------------------------------------------------------------------

-- line_map[lnr] = { type = "commit"|"commit_file", commit = <commit>,
--                   file = <file_info> (for commit_file type) }
local line_map = {}

-- expanded[hash] = true/false
local expanded = {}

-- cached file lists per commit hash
local file_cache = {}

-- cached full commit message bodies per commit hash (string[])
local body_cache = {}

-- cached aggregate stat summary per commit hash (string, e.g.
-- "3 files changed, 40 insertions(+), 12 deletions(-)")
local stat_cache = {}

-- Track the currently open tooltip window so rapid K presses don't stack
-- multiple tooltips and so cleanup is always possible.
M._tooltip_win     = nil
M._tooltip_buf     = nil
-- Monotonic counter to detect stale callbacks from superseded tooltip requests.
M._tooltip_req_id  = 0

-- ---------------------------------------------------------------------------
-- Ref badge helpers
-- ---------------------------------------------------------------------------

--- Classify a ref string and return the appropriate highlight group.
--- @param ref string
--- @return string  highlight group name
local function ref_hl(ref)
  if ref == "HEAD" or ref:match("^HEAD %->") then
    return "DiffNvimRefHead"
  elseif ref:match("^tag:") then
    return "DiffNvimRefTag"
  elseif ref:match("^origin/") or ref:match("^%a[%w%-]+/") then
    return "DiffNvimRefRemote"
  else
    return "DiffNvimRefBranch"
  end
end

-- ---------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------

-- Multibyte-safe truncation (head-keeping). Provided by the shared util module.
local trunc = util.trunc

local STATUS_BADGE = {
  modified  = "M",
  added     = "A",
  deleted   = "D",
  renamed   = "R",
  copied    = "C",
  unmerged  = "U",
  untracked = "?",
  unknown   = "·",
}

local STATUS_HL = {
  modified  = "DiffNvimStatusModified",
  added     = "DiffNvimStatusAdded",
  deleted   = "DiffNvimStatusDeleted",
  renamed   = "DiffNvimStatusRenamed",
  copied    = "DiffNvimStatusRenamed",
  unmerged  = "DiffNvimStatusModified",
  untracked = "DiffNvimStatusUntracked",
  unknown   = "DiffNvimStatusUntracked",
}

--- Build the right-aligned diffstat segment for a commit file, e.g. "  +12 -3".
--- Returns: text, add_range {s,e}|nil, del_range {s,e}|nil (byte offsets within text).
local function commit_diffstat_segment(f)
  local st = f.stat
  if not st then return "", nil, nil end
  if st.binary then return "  bin", nil, nil end
  local added, deleted = st.added or 0, st.deleted or 0
  if added == 0 and deleted == 0 then return "", nil, nil end
  local text = "  "
  local add_range, del_range
  if added > 0 then
    local s = #text
    text = text .. "+" .. added
    add_range = { s, #text }
  end
  if deleted > 0 then
    if added > 0 then text = text .. " " end
    local s = #text
    text = text .. "-" .. deleted
    del_range = { s, #text }
  end
  return text, add_range, del_range
end

--- Render commits into buf and populate line_map.
--- @param buf     integer
--- @param commits table[]
local function render(buf, commits)
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  line_map = {}

  local lines    = {}
  local hl_queue = {}

  local cfg     = config.get()
  local panel_w = cfg.sidebar_width or 40

  local HASH_W = 7
  -- Indentation for the dim metadata line beneath each subject. Aligns roughly
  -- under the subject text (arrow "▸ " + hash + space).
  local META_INDENT = "  "

  for _, commit in ipairs(commits) do
    -- Expand/collapse indicator
    local is_expanded = expanded[commit.hash] or false
    local arrow = is_expanded and "▾ " or "▸ "

    local hash_str = commit.short_hash or commit.hash:sub(1, HASH_W)

    -- ----- Line 1: arrow + hash + full-width subject -----
    local seg_hash    = arrow .. hash_str .. "  "
    local subject_w   = math.max(8, panel_w - #seg_hash)
    local subject_str = trunc(commit.subject or "", subject_w)
    local line1       = seg_hash .. subject_str

    table.insert(lines, line1)
    local l1   = #lines
    local l1_0 = l1 - 1
    line_map[l1] = { type = "commit", commit = commit }

    -- Highlight hash (after the arrow) and subject.
    local hash_col_s = #arrow
    table.insert(hl_queue, { l1_0, "DiffNvimCommitHash", hash_col_s, hash_col_s + #hash_str })
    table.insert(hl_queue, { l1_0, "DiffNvimCommitSubject", #seg_hash, #line1 })

    -- ----- Line 2: dim "author · time" + ref pills -----
    local author = trunc(commit.author or "", math.max(8, math.floor(panel_w / 2)))
    local time   = commit.time or ""
    local meta   = META_INDENT .. author
    if time ~= "" then
      meta = meta .. " · " .. time
    end

    -- Append ref pills (e.g. [HEAD] [main]) if they fit.
    local ref_segments = {}
    for _, r in ipairs(commit.refs or {}) do
      local pill = " [" .. r .. "]"
      if vim.fn.strdisplaywidth(meta .. pill) <= panel_w then
        local start_col = #meta
        meta = meta .. pill
        table.insert(ref_segments, { s = start_col, e = #meta, hl = ref_hl(r) })
      end
    end

    table.insert(lines, meta)
    local l2   = #lines
    local l2_0 = l2 - 1
    -- The metadata line belongs to the same commit so clicking it still works.
    line_map[l2] = { type = "commit", commit = commit }

    -- Dim the whole author/time portion.
    local meta_end = #META_INDENT + #author + (time ~= "" and (#" · " + #time) or 0)
    table.insert(hl_queue, { l2_0, "DiffNvimCommitMeta", 0, meta_end })
    -- Color the ref pills.
    for _, seg in ipairs(ref_segments) do
      table.insert(hl_queue, { l2_0, seg.hl, seg.s, seg.e })
    end

    -- ----- Expanded: full commit message body, then the file list -----
    if is_expanded then
      -- Expanded content is flush with the metadata (author) line beneath each
      -- commit subject, so it reads as a continuation of that commit block.
      local indent = META_INDENT

      -- Full commit message, untruncated. The collapsed row only shows a
      -- truncated subject, so render the entire message here starting at line 1
      -- (the subject) followed by the description. The subject line(s) get the
      -- subject highlight; the rest get the dim body highlight.
      local body = body_cache[commit.hash]
      if body and #body > 0 then
        local avail = math.max(8, panel_w - #indent)
        for i = 1, #body do
          local raw = body[i]
          local hl  = (i == 1) and "DiffNvimCommitSubject" or "DiffNvimCommitBody"
          if raw == "" then
            table.insert(lines, "")
            line_map[#lines] = { type = "commit_body", commit = commit }
          else
            -- Word-wrap at space boundaries; long words are hard-broken.
            for _, chunk in ipairs(util.wrap(raw, avail)) do
              local bline = indent .. chunk
              table.insert(lines, bline)
              local bl = #lines
              line_map[bl] = { type = "commit_body", commit = commit }
              table.insert(hl_queue, { bl - 1, hl, #indent, #bline })
            end
          end
        end
        -- Blank spacer between message and stat/file list.
        table.insert(lines, "")
        line_map[#lines] = { type = "commit_body", commit = commit }
      end

      -- Aggregate stat summary, rendered compactly as "+N -M" (green / red).
      local stat = stat_cache[commit.hash]
      if stat and stat ~= "" then
        local ins = tonumber(stat:match("(%d+) insertions?%(%+%)")) or 0
        local del = tonumber(stat:match("(%d+) deletions?%(%-?%)")) or 0
        if ins > 0 or del > 0 then
          local stat_line = indent
          local add_range, del_range
          if ins > 0 then
            local s = #stat_line
            stat_line = stat_line .. "+" .. ins
            add_range = { s, #stat_line }
          end
          if del > 0 then
            if ins > 0 then stat_line = stat_line .. " " end
            local s = #stat_line
            stat_line = stat_line .. "-" .. del
            del_range = { s, #stat_line }
          end

          table.insert(lines, stat_line)
          local sl_0 = #lines - 1
          line_map[#lines] = { type = "commit_body", commit = commit }
          if add_range then
            table.insert(hl_queue, { sl_0, "DiffNvimStatAdded", add_range[1], add_range[2] })
          end
          if del_range then
            table.insert(hl_queue, { sl_0, "DiffNvimStatRemoved", del_range[1], del_range[2] })
          end
        end
      end

      -- Changed-file list, rendered as a directory tree (same structure as the
      -- file panel). Base indent is META_INDENT; each tree depth nests further.
      if file_cache[commit.hash] then
        local tree = util.build_file_tree(file_cache[commit.hash])

        local render_tree_node  -- forward declaration for mutual recursion

        local function render_tree_dir(node, depth)
          local display, cur = util.compact_dir_chain(node)
          local pad   = indent .. string.rep("  ", depth)
          local avail = math.max(1, panel_w - #pad - 1)
          local name  = util.trunc_middle(display, avail)
          local dline = pad .. name .. "/"
          table.insert(lines, dline)
          local dl = #lines
          line_map[dl] = { type = "commit_dir", commit = commit }
          table.insert(hl_queue, { dl - 1, "Comment", #pad, #pad + #name + 1 })
          for _, child in ipairs(util.sort_tree_children(cur.children)) do
            render_tree_node(child, depth + 1)
          end
        end

        render_tree_node = function(node, depth)
          if not node.file then
            render_tree_dir(node, depth)
            return
          end
          local f     = node.file
          local pad   = indent .. string.rep("  ", depth)
          local badge = STATUS_BADGE[f.status] or "·"

          local stat_text, add_range, del_range = commit_diffstat_segment(f)
          local right_w = 3 + #stat_text  -- "[X]" is 3 cols

          local avail = math.max(1, panel_w - #pad - right_w - 1)
          local name  = util.trunc_middle(node.name, avail)
          local name_w = vim.fn.strdisplaywidth(name)
          local gap   = math.max(1, panel_w - #pad - name_w - right_w)
          local fline = pad .. name .. string.rep(" ", gap) .. "[" .. badge .. "]" .. stat_text

          table.insert(lines, fline)
          local flnr   = #lines
          local flnr_0 = flnr - 1
          line_map[flnr] = { type = "commit_file", commit = commit, file = f }

          table.insert(hl_queue, { flnr_0, "DiffNvimCommitFileEntry", #pad, #pad + #name })
          local badge_hl  = STATUS_HL[f.status] or "DiffNvimStatusUntracked"
          local badge_col = #fline - #stat_text - 3
          table.insert(hl_queue, { flnr_0, badge_hl, badge_col, badge_col + 3 })

          local stat_base = #fline - #stat_text
          if add_range then
            table.insert(hl_queue, { flnr_0, "DiffNvimStatAdded",
              stat_base + add_range[1], stat_base + add_range[2] })
          end
          if del_range then
            table.insert(hl_queue, { flnr_0, "DiffNvimStatRemoved",
              stat_base + del_range[1], stat_base + del_range[2] })
          end
        end

        for _, child in ipairs(util.sort_tree_children(tree.children)) do
          render_tree_node(child, 0)
        end
      end
    end
  end

  if #lines == 0 then
    table.insert(lines, "  (no commits)")
    line_map[1] = { type = "empty" }
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  for _, h in ipairs(hl_queue) do
    pcall(vim.api.nvim_buf_add_highlight, buf, NS, h[2], h[1], h[3], h[4])
  end

  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

-- ---------------------------------------------------------------------------
-- Commit tooltip (K key)
-- ---------------------------------------------------------------------------

--- Close any existing tooltip, cleaning up module state.
local function close_tooltip()
  M._tooltip_req_id = M._tooltip_req_id + 1
  if M._tooltip_win and vim.api.nvim_win_is_valid(M._tooltip_win) then
    pcall(vim.api.nvim_win_close, M._tooltip_win, true)
  end
  M._tooltip_win = nil
  M._tooltip_buf = nil
end

--- Show a floating window with the full commit message for hash.
--- Tracked in M._tooltip_win so rapid invocations never stack.
--- Uses a monotonic request counter to discard stale callbacks.
--- @param repo_root string
--- @param hash      string
local function show_commit_tooltip(repo_root, hash)
  -- Close any pre-existing tooltip before starting the async fetch
  close_tooltip()

  -- Snapshot the current request ID; if another K press fires before this
  -- callback completes, M._tooltip_req_id is incremented and we discard.
  M._tooltip_req_id = M._tooltip_req_id + 1
  local my_req_id = M._tooltip_req_id

  -- Wrap the entire async callback in xpcall so an error inside never leaves
  -- M._tooltip_win pointing at a dead/inconsistent state.
  git.run({ "show", "--no-patch", "--format=%B", hash }, repo_root, function(lines, stderr, code)
    local ok = xpcall(function()
      -- Stale callback: a newer K press has superseded this one
      if my_req_id ~= M._tooltip_req_id then return end

      if code ~= 0 then
        vim.notify("diff.nvim: " .. (stderr or "cannot fetch commit message"), vim.log.levels.WARN)
        return
      end

      -- Strip trailing empty lines
      while #lines > 0 and lines[#lines] == "" do
        table.remove(lines)
      end
      if #lines == 0 then
        lines = { "(empty commit message)" }
      end

      -- Calculate window dimensions
      local max_width = 80
      local max_height = math.floor(vim.o.lines * 0.6)
      local width = 0
      for _, l in ipairs(lines) do
        width = math.max(width, vim.fn.strdisplaywidth(l))
      end
      width = math.max(1, math.min(width + 2, max_width))
      local height = math.max(1, math.min(#lines, max_height))

      -- Clamp to viewport bounds
      local row = math.max(0, math.floor((vim.o.lines - height) / 2))
      local col = math.max(0, math.floor((vim.o.columns - width) / 2))

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
      vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

      -- The request ID check at the top of the xpcall body already guarantees
      -- this callback belongs to the current tooltip request; no additional
      -- per-buffer validity guard is needed here.

      local ok_win, win = pcall(vim.api.nvim_open_win, buf, true, {
        relative  = "editor",
        width     = width,
        height    = height,
        row       = row,
        col       = col,
        style     = "minimal",
        border    = "rounded",
        title     = " Commit ",
        title_pos = "center",
      })
      if not ok_win then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
        return
      end

      -- Validate immediately; open_win can theoretically succeed but return an
      -- invalid win if the editor is closing.
      if not vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
        return
      end

      M._tooltip_win = win
      M._tooltip_buf = buf

      pcall(vim.api.nvim_set_option_value, "wrap",          true,  { win = win })
      pcall(vim.api.nvim_set_option_value, "linebreak",     true,  { win = win })
      pcall(vim.api.nvim_set_option_value, "sidescroll",    0,     { win = win })
      pcall(vim.api.nvim_set_option_value, "sidescrolloff", 0,     { win = win })
      pcall(vim.api.nvim_set_option_value, "number",        false, { win = win })

      -- Block horizontal movement/scroll
      local nop_keys = { "<ScrollWheelRight>", "<ScrollWheelLeft>", "<Left>", "<Right>", "zh", "zl" }
      for _, key in ipairs(nop_keys) do
        vim.keymap.set("n", key, "<Nop>", { buffer = buf, silent = true, desc = "(disabled) (diff)" })
      end

      -- Close on q/Esc: always clears module state
      local function do_close()
        close_tooltip()
      end
      for _, key in ipairs({ "q", "<Esc>" }) do
        vim.keymap.set("n", key, do_close,
          { buffer = buf, nowait = true, silent = true, desc = "Close tooltip (diff)" })
      end

      -- BufLeave: auto-close so tooltip dismisses when focus moves away.
      -- Capture the buffer reference so the scheduled callback only closes
      -- THIS tooltip and not a newer one that may have been opened in the gap.
      local captured_buf = buf
      vim.api.nvim_create_autocmd("BufLeave", {
        buffer  = buf,
        once    = true,
        callback = function()
          vim.schedule(function()
            if M._tooltip_buf == captured_buf then
              close_tooltip()
            end
          end)
        end,
      })
    end, function(err_msg)
      -- xpcall error handler: clean up state and notify user
      close_tooltip()
      vim.notify("diff.nvim: tooltip error: " .. tostring(err_msg), vim.log.levels.ERROR)
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Module-level references for re-render
local _buf, _win, _repo_root, _commits

--- Wire up keymaps for the commit panel buffer.
--- @param buf       integer
--- @param win       integer
--- @param repo_root string
function M.setup(buf, win, repo_root)
  _buf = buf
  _win = win
  _repo_root = repo_root

  -- Reset state on each setup (prevents leaks between open/close cycles)
  expanded = {}
  file_cache = {}
  body_cache = {}
  stat_cache = {}
  line_map = {}
  _commits = nil
  -- Close any open tooltip from previous session and reset the request counter
  close_tooltip()
  M._tooltip_req_id = 0

  local cfg  = config.get()
  local km   = cfg.keymaps or {}
  local opts = { buffer = buf, nowait = true, silent = true }

  -- Activate the entry on line `lnr`: expand/collapse a commit, or open a
  -- commit file's diff. Shared by <CR> and mouse clicks.
  local function activate_line(lnr)
    local meta = line_map[lnr]
    if not meta then return end

    if meta.type == "commit" or meta.type == "commit_body" then
      local hash = meta.commit.hash
      if expanded[hash] then
        expanded[hash] = false
        render(buf, _commits or {})
      elseif file_cache[hash] and body_cache[hash] and stat_cache[hash] ~= nil then
        expanded[hash] = true
        render(buf, _commits or {})
      else
        -- Fetch the changed-file list, full commit message, and stat summary in
        -- parallel; expand once all have arrived so everything renders together.
        local pending = 3
        local failed  = false
        local function done()
          pending = pending - 1
          if pending > 0 or failed then return end
          if not vim.api.nvim_buf_is_valid(buf) then return end
          expanded[hash] = true
          render(buf, _commits or {})
        end

        if file_cache[hash] then
          pending = pending - 1
        else
          git.get_commit_files(repo_root, hash, function(files, err)
            if err then
              vim.notify("diff.nvim: " .. err, vim.log.levels.WARN)
              failed = true
              return
            end
            file_cache[hash] = files or {}
            done()
          end)
        end

        if body_cache[hash] then
          pending = pending - 1
        else
          git.get_commit_body(repo_root, hash, function(body, err)
            if err then
              -- Body is non-critical; degrade gracefully to file list only.
              body_cache[hash] = {}
            else
              body_cache[hash] = body or {}
            end
            done()
          end)
        end

        if stat_cache[hash] ~= nil then
          pending = pending - 1
        else
          git.get_commit_stat(repo_root, hash, function(summary, _)
            -- Stat is non-critical; cache empty string on failure.
            stat_cache[hash] = summary or ""
            done()
          end)
        end

        -- If everything was already cached above, render immediately.
        if pending == 0 and not failed then
          if vim.api.nvim_buf_is_valid(buf) then
            expanded[hash] = true
            render(buf, _commits or {})
          end
        end
      end
    elseif meta.type == "commit_file" then
      local ok, dv_err = pcall(function()
        local dv = require("diff.diff_view")
        dv.open_commit_diff(repo_root, meta.commit.hash, meta.file.path, meta.file.status_char)
      end)
      if not ok then
        vim.notify("diff.nvim: error opening commit diff: " .. tostring(dv_err), vim.log.levels.ERROR)
      end
    end
  end

  -- <CR>: toggle commit expansion or open file diff
  vim.keymap.set("n", km.open_diff or "<CR>", function()
    if not _win or not vim.api.nvim_win_is_valid(_win) then return end
    activate_line(vim.api.nvim_win_get_cursor(_win)[1])
  end, vim.tbl_extend("force", opts, { desc = "Expand commit / open file diff (diff)" }))

  -- Mouse: clicking a row activates it (same as <CR>). getmousepos() gives the
  -- exact clicked window + line, so this works regardless of cursor position.
  local function on_mouse_click()
    local mp = vim.fn.getmousepos()
    if mp.winid ~= _win then return end
    if mp.line < 1 then return end
    pcall(vim.api.nvim_win_set_cursor, _win, { mp.line, 0 })
    activate_line(mp.line)
  end
  vim.keymap.set("n", "<LeftMouse>", on_mouse_click,
    vim.tbl_extend("force", opts, { desc = "Activate row (diff)" }))

  -- Block horizontal scrolling: content is truncated to fit the panel width,
  -- so scrolling right only reveals blank space. Disable the horizontal mouse
  -- wheel and horizontal-scroll keys to keep the view pinned to column 1.
  for _, key in ipairs({ "<ScrollWheelRight>", "<ScrollWheelLeft>", "zh", "zl", "zH", "zL" }) do
    vim.keymap.set("n", key, "<Nop>",
      vim.tbl_extend("force", opts, { desc = "(disabled) (diff)" }))
  end

  -- K: show full commit message tooltip
  vim.keymap.set("n", km.commit_tooltip or "K", function()
    if not _win or not vim.api.nvim_win_is_valid(_win) then return end
    local lnr  = vim.api.nvim_win_get_cursor(_win)[1]
    local meta = line_map[lnr]
    if not meta then return end
    -- Find the commit (works for both commit and commit_file rows)
    local commit = meta.commit
    if commit then
      show_commit_tooltip(repo_root, commit.hash)
    end
  end, vim.tbl_extend("force", opts, { desc = "Show full commit message (diff)" }))

  -- 'q': close the entire diff.nvim interface
  vim.keymap.set("n", "q", function()
    require("diff.sidebar").close()
  end, vim.tbl_extend("force", opts, { desc = "Close (diff)" }))
end

--- Fetch recent commits and re-render the panel.
--- @param buf       integer
--- @param win       integer
--- @param repo_root string
function M.refresh(buf, win, repo_root)
  _buf = buf
  _win = win
  _repo_root = repo_root

  git.get_commits(repo_root, 50, function(commits, err)
    if err then
      vim.notify("diff.nvim: commits error: " .. err, vim.log.levels.WARN)
    end
    if not vim.api.nvim_buf_is_valid(buf) then return end
    _commits = commits or {}
    render(buf, _commits)
  end)
end

M.close_tooltip = close_tooltip

return M
