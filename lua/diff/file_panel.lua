local M = {}

local git    = require("diff.git")
local config = require("diff.config")

local NS = vim.api.nvim_create_namespace("diff_nvim_file_panel")

-- ---------------------------------------------------------------------------
-- Module-level state
-- ---------------------------------------------------------------------------

-- line_map[lnr] = { type = "header"|"file", section = "staged"|"unstaged",
--                   file = <file_info table> (for type=="file") }
local line_map = {}

local collapsed = {
  staged   = false,
  unstaged = false,
}

-- ---------------------------------------------------------------------------
-- Status badge helpers
-- ---------------------------------------------------------------------------

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

local FILE_HL = {
  added     = "DiffNvimStagedFile",
  deleted   = "DiffNvimDeletedFile",
}

local function file_hl(file_info, section)
  if file_info.status == "deleted" then
    return "DiffNvimDeletedFile"
  end
  if section == "staged" then
    return FILE_HL[file_info.status] or "DiffNvimStagedFile"
  end
  return "DiffNvimUnstagedFile"
end

-- ---------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------

--- Build display lines and line_map from status data, write into buf.
--- @param buf     integer
--- @param status  table   {staged: table[], unstaged: table[]}
local function render(buf, status)
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  line_map = {}

  local lines     = {}
  local hl_queue  = {} -- { lnr, group, col_start, col_end }

  local function push(line, meta, hl_group, hl_start, hl_end)
    table.insert(lines, line)
    local lnr = #lines -- 1-based
    line_map[lnr] = meta
    if hl_group then
      table.insert(hl_queue, { lnr - 1, hl_group, hl_start or 0, hl_end or -1 })
    end
  end

  local cfg      = config.get()
  local panel_w  = cfg.sidebar_width or 40

  -- ── Staged section ──────────────────────────────────────────────────────
  local staged_count = #status.staged
  local staged_arrow = collapsed.staged and "▶" or "▼"
  local staged_hdr   = staged_arrow .. " Staged Changes (" .. staged_count .. ")"
  push(staged_hdr, { type = "header", section = "staged" }, "DiffNvimSectionHeader")

  if not collapsed.staged then
    for _, f in ipairs(status.staged) do
      local badge    = STATUS_BADGE[f.status] or "·"
      local name     = f.path
      -- Right-align the badge with at least one space separator.
      -- panel_w - 2 (indent) - 1 (space) - 3 ("[X]") = available for name
      local available = panel_w - 2 - 1 - 3
      local display_name = #name > available and ("…" .. name:sub(-(available - 1))) or name
      local pad      = math.max(1, panel_w - 2 - #display_name - 3)
      local line     = "  " .. display_name .. string.rep(" ", pad) .. "[" .. badge .. "]"
      local fhl      = file_hl(f, "staged")
      local badge_hl = STATUS_HL[f.status] or "DiffNvimStatusUntracked"

      table.insert(lines, line)
      local lnr = #lines
      line_map[lnr] = { type = "file", section = "staged", file = f }

      -- filename highlight (cols 2 .. 2+#display_name)
      table.insert(hl_queue, { lnr - 1, fhl, 2, 2 + #display_name })
      -- badge highlight: last 3 chars "[X]"
      local badge_col = #line - 3
      table.insert(hl_queue, { lnr - 1, badge_hl, badge_col, badge_col + 3 })
    end
  end

  -- blank separator
  push("", { type = "blank" })

  -- ── Unstaged / Changes section ──────────────────────────────────────────
  local unstaged_count = #status.unstaged
  local unstaged_arrow = collapsed.unstaged and "▶" or "▼"
  local unstaged_hdr   = unstaged_arrow .. " Changes (" .. unstaged_count .. ")"
  push(unstaged_hdr, { type = "header", section = "unstaged" }, "DiffNvimSectionHeader")

  if not collapsed.unstaged then
    for _, f in ipairs(status.unstaged) do
      local badge    = STATUS_BADGE[f.status] or "·"
      local name     = f.path
      local available = panel_w - 2 - 1 - 3
      local display_name = #name > available and ("…" .. name:sub(-(available - 1))) or name
      local pad      = math.max(1, panel_w - 2 - #display_name - 3)
      local line     = "  " .. display_name .. string.rep(" ", pad) .. "[" .. badge .. "]"
      local fhl      = file_hl(f, "unstaged")
      local badge_hl = STATUS_HL[f.status] or "DiffNvimStatusUntracked"

      table.insert(lines, line)
      local lnr = #lines
      line_map[lnr] = { type = "file", section = "unstaged", file = f }

      table.insert(hl_queue, { lnr - 1, fhl, 2, 2 + #display_name })
      local badge_col = #line - 3
      table.insert(hl_queue, { lnr - 1, badge_hl, badge_col, badge_col + 3 })
    end
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- Apply highlight extmarks
  for _, h in ipairs(hl_queue) do
    local ok, err = pcall(
      vim.api.nvim_buf_add_highlight, buf, NS, h[2], h[1], h[3], h[4]
    )
    if not ok then
      vim.notify("diff.nvim file_panel highlight error: " .. tostring(err), vim.log.levels.DEBUG)
    end
  end

  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Wire up keymaps for the file panel buffer.
--- @param buf       integer
--- @param win       integer
--- @param repo_root string
function M.setup(buf, win, repo_root)
  local cfg = config.get()
  local km  = cfg.keymaps or {}

  local opts = { buffer = buf, nowait = true, silent = true }

  -- <CR>: open diff or toggle section collapse
  vim.keymap.set("n", km.open_diff or "<CR>", function()
    local lnr  = vim.api.nvim_win_get_cursor(win)[1]
    local meta = line_map[lnr]
    if not meta then return end

    if meta.type == "header" then
      collapsed[meta.section] = not collapsed[meta.section]
      M.refresh(buf, win, repo_root)
    elseif meta.type == "file" then
      local dv   = require("diff.diff_view")
      -- Merge staging state into the file info
      local file = vim.tbl_extend("force", meta.file, {
        staged = (meta.section == "staged"),
      })
      local ok, err = pcall(dv.open_file_diff, repo_root, file)
      if not ok then
        vim.notify("diff.nvim: error opening diff: " .. tostring(err), vim.log.levels.ERROR)
      end
    end
  end, opts)

  -- 's': stage file (unstaged section only)
  vim.keymap.set("n", km.stage_file or "s", function()
    local lnr  = vim.api.nvim_win_get_cursor(win)[1]
    local meta = line_map[lnr]
    if not meta or meta.type ~= "file" or meta.section ~= "unstaged" then return end
    git.stage_file(repo_root, meta.file.path, function(ok, err)
      if not ok then
        vim.notify("diff.nvim: stage failed: " .. (err or ""), vim.log.levels.ERROR)
      end
      M.refresh(buf, win, repo_root)
    end)
  end, opts)

  -- 'u': unstage file (staged section only)
  vim.keymap.set("n", km.unstage_file or "u", function()
    local lnr  = vim.api.nvim_win_get_cursor(win)[1]
    local meta = line_map[lnr]
    if not meta or meta.type ~= "file" or meta.section ~= "staged" then return end
    git.unstage_file(repo_root, meta.file.path, function(ok, err)
      if not ok then
        vim.notify("diff.nvim: unstage failed: " .. (err or ""), vim.log.levels.ERROR)
      end
      M.refresh(buf, win, repo_root)
    end)
  end, opts)

  -- 'z': toggle collapse of the section the cursor is in
  vim.keymap.set("n", km.collapse or "z", function()
    local lnr  = vim.api.nvim_win_get_cursor(win)[1]
    local meta = line_map[lnr]
    if not meta then return end
    local section = meta.section
    if section then
      collapsed[section] = not collapsed[section]
      M.refresh(buf, win, repo_root)
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

--- Fetch git status and re-render the panel.
--- @param buf       integer
--- @param win       integer
--- @param repo_root string
function M.refresh(buf, win, repo_root)
  git.get_status(repo_root, function(status, err)
    if err then
      vim.notify("diff.nvim: status error: " .. err, vim.log.levels.WARN)
    end
    render(buf, status or { staged = {}, unstaged = {} })
  end)
end

return M
