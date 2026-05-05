local M = {}

local git    = require("diff.git")
local config = require("diff.config")

local NS = vim.api.nvim_create_namespace("diff_nvim_commit_panel")

-- ---------------------------------------------------------------------------
-- Module-level state
-- ---------------------------------------------------------------------------

-- line_map[lnr] = { type = "commit", commit = <commit table> }
local line_map = {}

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
    -- heuristic: anything with a slash that isn't HEAD is treated as remote
    return "DiffNvimRefRemote"
  else
    return "DiffNvimRefBranch"
  end
end

-- ---------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------

--- Truncate a string to max_len, appending "…" if truncated.
--- @param s       string
--- @param max_len integer
--- @return string
local function trunc(s, max_len)
  if #s <= max_len then return s end
  return s:sub(1, max_len - 1) .. "…"
end

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

  -- Column widths: hash(7) + space(1) + refs(variable) + subject + author + time
  -- We allocate fixed widths for hash, author, time and let subject fill the rest.
  local HASH_W   = 7
  local AUTHOR_W = 12
  local TIME_W   = 10

  for _, commit in ipairs(commits) do
    -- ── Build ref badges string ──────────────────────────────────────────
    local ref_parts  = {}   -- { text, hl } pairs used for colouring
    local refs_plain = ""   -- plain string for line length computation

    for _, r in ipairs(commit.refs or {}) do
      local badge = " [" .. r .. "]"
      table.insert(ref_parts, { text = badge, hl = ref_hl(r) })
      refs_plain = refs_plain .. badge
    end

    -- ── Compute available width for the subject ──────────────────────────
    -- Layout: "  <hash> <refs><subject>  <author>  <time>"
    local prefix_w  = 2 + HASH_W + 1 -- "  " + hash + " "
    local suffix_w  = 2 + AUTHOR_W + 2 + TIME_W -- "  " + author + "  " + time
    local refs_w    = #refs_plain
    local subject_w = math.max(4, panel_w - prefix_w - refs_w - suffix_w - 2)

    local hash_str    = commit.short_hash or commit.hash:sub(1, HASH_W)
    local author_str  = trunc(commit.author or "", AUTHOR_W)
    local time_str    = trunc(commit.time   or "", TIME_W)
    local subject_str = trunc(commit.subject or "", subject_w)

    -- ── Build full line ──────────────────────────────────────────────────
    -- We build the line in segments so we can compute highlight columns.
    local seg_hash    = "  " .. hash_str .. " "
    local seg_refs    = refs_plain
    local seg_subject = subject_str
    -- Right-side padding to align author/time; ensure non-negative.
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
    local hash_col_s = 2
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
  end

  if #lines == 0 then
    table.insert(lines, "  (no commits)")
    line_map[1] = { type = "empty" }
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  for _, h in ipairs(hl_queue) do
    local ok, err = pcall(
      vim.api.nvim_buf_add_highlight, buf, NS, h[2], h[1], h[3], h[4]
    )
    if not ok then
      vim.notify("diff.nvim commit_panel highlight error: " .. tostring(err), vim.log.levels.DEBUG)
    end
  end

  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Wire up keymaps for the commit panel buffer.
--- @param buf       integer
--- @param win       integer
--- @param repo_root string
function M.setup(buf, win, repo_root)
  local cfg  = config.get()
  local km   = cfg.keymaps or {}
  local opts = { buffer = buf, nowait = true, silent = true }

  -- <CR>: open commit diff
  vim.keymap.set("n", km.open_diff or "<CR>", function()
    local lnr  = vim.api.nvim_win_get_cursor(win)[1]
    local meta = line_map[lnr]
    if not meta or meta.type ~= "commit" then return end
    local dv = require("diff.diff_view")
    dv.open_commit_diff(repo_root, meta.commit.hash, nil)
  end, opts)

  -- '<leader>gr': refresh
  vim.keymap.set("n", km.refresh or "<leader>gr", function()
    M.refresh(buf, win, repo_root)
  end, opts)
end

--- Fetch recent commits and re-render the panel.
--- @param buf       integer
--- @param win       integer
--- @param repo_root string
function M.refresh(buf, win, repo_root)
  git.get_commits(repo_root, 50, function(commits, err)
    if err then
      vim.notify("diff.nvim: commits error: " .. err, vim.log.levels.WARN)
    end
    render(buf, commits or {})
  end)
end

return M
