local M = {}

local git    = require("diff.git")
local config = require("diff.config")

local NS = vim.api.nvim_create_namespace("diff_nvim_commit_panel")

-- ---------------------------------------------------------------------------
-- Module-level state
-- ---------------------------------------------------------------------------

-- line_map[lnr] = { type = "commit"|"commit_file", commit = <commit>,
--                   file = <file_info> (for commit_file type) }
local line_map = {}

-- expanded[hash] = true/false — tracks which commits are expanded
local expanded = {}

-- cached file lists per commit hash
local file_cache = {}

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

--- Truncate a string to max_len display columns, appending "…" if truncated.
--- Handles multibyte characters correctly.
--- @param s       string
--- @param max_len integer
--- @return string
local function trunc(s, max_len)
  local display_w = vim.fn.strdisplaywidth(s)
  if display_w <= max_len then return s end
  -- Use strcharpart to safely truncate without splitting codepoints
  local result = vim.fn.strcharpart(s, 0, max_len - 1)
  -- If still too wide (wide chars), trim further
  while vim.fn.strdisplaywidth(result) >= max_len and #result > 0 do
    result = vim.fn.strcharpart(result, 0, vim.fn.strchars(result) - 1)
  end
  return result .. "…"
end

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

--- Render commits into buf and populate line_map.
--- @param buf     integer
--- @param commits table[]
local function render(buf, commits)
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  line_map = {}

  local lines    = {}
  local hl_queue = {} -- { lnr_0based, group, col_start, col_end }

  local cfg     = config.get()
  local panel_w = cfg.sidebar_width or 40

  local HASH_W   = 7
  local AUTHOR_W = 12
  local TIME_W   = 10

  for _, commit in ipairs(commits) do
    -- ── Build ref badges string ──────────────────────────────────────────
    local ref_parts  = {}
    local refs_plain = ""

    for _, r in ipairs(commit.refs or {}) do
      local badge = " [" .. r .. "]"
      table.insert(ref_parts, { text = badge, hl = ref_hl(r) })
      refs_plain = refs_plain .. badge
    end

    -- ── Compute available width for the subject ──────────────────────────
    local prefix_w  = 2 + HASH_W + 1
    local suffix_w  = 2 + AUTHOR_W + 2 + TIME_W
    local refs_w    = #refs_plain
    local subject_w = math.max(4, panel_w - prefix_w - refs_w - suffix_w - 2)

    local hash_str    = commit.short_hash or commit.hash:sub(1, HASH_W)
    local author_str  = trunc(commit.author or "", AUTHOR_W)
    local time_str    = trunc(commit.time   or "", TIME_W)
    local subject_str = trunc(commit.subject or "", subject_w)

    -- Expand/collapse indicator
    local is_expanded = expanded[commit.hash] or false
    local arrow = is_expanded and "▼ " or "▶ "

    -- ── Build full line ──────────────────────────────────────────────────
    local seg_hash    = arrow .. hash_str .. " "
    local seg_refs    = refs_plain
    local seg_subject = subject_str
    local fixed_w = #seg_hash + #seg_refs + #seg_subject + #author_str + 2 + #time_str
    local pad     = math.max(1, panel_w - fixed_w)
    local line = seg_hash .. seg_refs .. seg_subject
                 .. string.rep(" ", pad)
                 .. author_str .. "  " .. time_str

    table.insert(lines, line)
    local lnr   = #lines
    local lnr_0 = lnr - 1
    line_map[lnr] = { type = "commit", commit = commit }

    -- ── Highlight hash ───────────────────────────────────────────────────
    local hash_col_s = #arrow
    local hash_col_e = hash_col_s + #hash_str
    table.insert(hl_queue, { lnr_0, "DiffNvimCommitHash", hash_col_s, hash_col_e })

    -- ── Highlight ref badges ─────────────────────────────────────────────
    local ref_cursor = #seg_hash
    for _, rp in ipairs(ref_parts) do
      table.insert(hl_queue, { lnr_0, rp.hl, ref_cursor, ref_cursor + #rp.text })
      ref_cursor = ref_cursor + #rp.text
    end

    -- ── Highlight subject ────────────────────────────────────────────────
    local subj_col_s = #seg_hash + #seg_refs
    local subj_col_e = subj_col_s + #seg_subject
    table.insert(hl_queue, { lnr_0, "DiffNvimCommitSubject", subj_col_s, subj_col_e })

    -- ── Highlight author ─────────────────────────────────────────────────
    local author_col_s = #line - #time_str - 2 - #author_str
    local author_col_e = author_col_s + #author_str
    table.insert(hl_queue, { lnr_0, "DiffNvimCommitAuthor", author_col_s, author_col_e })

    -- ── Highlight time ───────────────────────────────────────────────────
    local time_col_s = #line - #time_str
    table.insert(hl_queue, { lnr_0, "DiffNvimCommitTime", time_col_s, #line })

    -- ── Expanded file list beneath this commit ───────────────────────────
    if is_expanded and file_cache[commit.hash] then
      for _, f in ipairs(file_cache[commit.hash]) do
        local badge = STATUS_BADGE[f.status] or "·"
        local fname = f.path
        local available = panel_w - 6 - 4 -- "    " indent + " [X]"
        local display_name = #fname > available
          and ("…" .. fname:sub(-(available - 1)))
          or fname
        local fpad = math.max(1, panel_w - 4 - #display_name - 4)
        local fline = "    " .. display_name .. string.rep(" ", fpad) .. " [" .. badge .. "]"

        table.insert(lines, fline)
        local flnr = #lines
        line_map[flnr] = { type = "commit_file", commit = commit, file = f }

        -- Highlight filename
        table.insert(hl_queue, { flnr - 1, "DiffNvimUnstagedFile", 4, 4 + #display_name })
        -- Highlight badge
        local badge_col = #fline - 3
        table.insert(hl_queue, { flnr - 1, "DiffNvimStatusModified", badge_col, badge_col + 3 })
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
  line_map = {}
  _commits = nil

  local cfg  = config.get()
  local km   = cfg.keymaps or {}
  local opts = { buffer = buf, nowait = true, silent = true }

  -- <CR>: toggle commit expansion or open file diff
  vim.keymap.set("n", km.open_diff or "<CR>", function()
    if not _win or not vim.api.nvim_win_is_valid(_win) then return end
    local lnr  = vim.api.nvim_win_get_cursor(_win)[1]
    local meta = line_map[lnr]
    if not meta then return end

    if meta.type == "commit" then
      -- Toggle expansion
      local hash = meta.commit.hash
      if expanded[hash] then
        expanded[hash] = false
        render(buf, _commits or {})
      else
        -- Fetch file list if not cached, then expand
        if file_cache[hash] then
          expanded[hash] = true
          render(buf, _commits or {})
        else
          git.get_commit_files(repo_root, hash, function(files, err)
            if err then
              vim.notify("diff.nvim: " .. err, vim.log.levels.WARN)
              return
            end
            if not vim.api.nvim_buf_is_valid(buf) then return end
            file_cache[hash] = files or {}
            expanded[hash] = true
            render(buf, _commits or {})
          end)
        end
      end
    elseif meta.type == "commit_file" then
      -- Open diff for this specific file in the commit
      local ok, dv_err = pcall(function()
        local dv = require("diff.diff_view")
        dv.open_commit_diff(repo_root, meta.commit.hash, meta.file.path)
      end)
      if not ok then
        vim.notify("diff.nvim: error opening commit diff: " .. tostring(dv_err), vim.log.levels.ERROR)
      end
    end
  end, opts)

  -- '<leader>gr': refresh
  vim.keymap.set("n", km.refresh or "<leader>gr", function()
    M.refresh(buf, win, repo_root)
  end, opts)

  -- 'q': close the entire diff.nvim interface
  vim.keymap.set("n", "q", function()
    require("diff.sidebar").close()
  end, opts)
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

return M
