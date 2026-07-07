local M = {}

local git    = require("diff.git")
local config = require("diff.config")
local util   = require("diff.util")

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

  local lines    = {}
  local hl_queue = {}
  local cfg      = config.get()
  local panel_w  = cfg.sidebar_width or 40

  local function push(line, meta, hl_group, hl_start, hl_end)
    table.insert(lines, line)
    local lnr = #lines
    line_map[lnr] = meta
    if hl_group then
      table.insert(hl_queue, { lnr - 1, hl_group, hl_start or 0, hl_end or -1 })
    end
  end

  -- Tree construction/sorting are shared via the util module.
  local build_tree = util.build_file_tree
  local sorted     = util.sort_tree_children

  local render_node  -- forward declaration for mutual recursion

  local function render_dir(node, depth, section)
    -- Compact single-child-dir chains: "src/" + "components/" → "src/components/"
    local display, cur = util.compact_dir_chain(node)

    local indent = string.rep("  ", depth + 1)
    -- Middle-ellipsize the (possibly long, compacted) dir path; reserve 1 col
    -- for the trailing "/".
    local avail        = math.max(1, panel_w - #indent - 1)
    local display_name = util.trunc_middle(display, avail)
    local dir_line     = indent .. display_name .. "/"
    table.insert(lines, dir_line)
    local lnr = #lines
    line_map[lnr] = { type = "dir_node", section = section }
    table.insert(hl_queue, { lnr - 1, "Comment", #indent, #indent + #display_name + 1 })

    for _, child in ipairs(sorted(cur.children)) do
      render_node(child, depth + 1, section)
    end
  end

  -- Build the right-aligned diffstat segment for a file, e.g. " +12 -3".
  -- Returns: text (string), add_range {s,e} | nil, del_range {s,e} | nil
  -- Ranges are byte offsets relative to the start of the returned text.
  local function diffstat_segment(f)
    local st = f.stat
    if not st then return "", nil, nil end
    if st.binary then
      return "  bin", nil, nil
    end
    local added   = st.added or 0
    local deleted = st.deleted or 0
    if added == 0 and deleted == 0 then return "", nil, nil end

    local text = "  "
    local add_range, del_range
    if added > 0 then
      local s = #text
      text = text .. "+" .. tostring(added)
      add_range = { s, #text }
    end
    if deleted > 0 then
      if added > 0 then text = text .. " " end
      local s = #text
      text = text .. "-" .. tostring(deleted)
      del_range = { s, #text }
    end
    return text, add_range, del_range
  end

  render_node = function(node, depth, section)
    if node.file then
      local f      = node.file
      local indent = string.rep("  ", depth + 1)
      local badge  = STATUS_BADGE[f.status] or "·"

      -- Right side: "[X]" badge + optional diffstat segment.
      local stat_text, add_range, del_range = diffstat_segment(f)
      local right_w = 3 + #stat_text  -- "[X]" is 3 bytes/cols

      -- Space available for the (middle-ellipsized) name, leaving 1 col gap.
      local available    = math.max(1, panel_w - #indent - right_w - 1)
      local display_name = util.trunc_middle(node.name, available)
      local name_w       = vim.fn.strdisplaywidth(display_name)
      local pad          = math.max(1, panel_w - #indent - name_w - right_w)

      local line     = indent .. display_name .. string.rep(" ", pad)
                       .. "[" .. badge .. "]" .. stat_text
      local fhl      = file_hl(f, section)
      local badge_hl = STATUS_HL[f.status] or "DiffNvimStatusUntracked"

      table.insert(lines, line)
      local lnr   = #lines
      local lnr_0 = lnr - 1
      line_map[lnr] = { type = "file", section = section, file = f }

      -- Name highlight (use display byte length, not char count).
      table.insert(hl_queue, { lnr_0, fhl, #indent, #indent + #display_name })

      -- Badge highlight: locate "[X]" which sits right before stat_text.
      local badge_col = #line - #stat_text - 3
      table.insert(hl_queue, { lnr_0, badge_hl, badge_col, badge_col + 3 })

      -- Diffstat highlights, offset by where stat_text begins.
      local stat_base = #line - #stat_text
      if add_range then
        table.insert(hl_queue, { lnr_0, "DiffNvimStatAdded",
          stat_base + add_range[1], stat_base + add_range[2] })
      end
      if del_range then
        table.insert(hl_queue, { lnr_0, "DiffNvimStatRemoved",
          stat_base + del_range[1], stat_base + del_range[2] })
      end
    else
      render_dir(node, depth, section)
    end
  end

  local function render_section(files, section, label)
    local arrow = collapsed[section] and "▶" or "▼"
    push(arrow .. " " .. label .. " (" .. #files .. ")",
      { type = "header", section = section }, "DiffNvimSectionHeader")
    if not collapsed[section] then
      local tree = build_tree(files)
      for _, child in ipairs(sorted(tree.children)) do
        render_node(child, 0, section)
      end
    end
  end

  render_section(status.staged,   "staged",   "Staged Changes")
  push("", { type = "blank" })
  render_section(status.unstaged, "unstaged", "Changes")

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  for _, h in ipairs(hl_queue) do
    local ok, err = pcall(vim.api.nvim_buf_add_highlight, buf, NS, h[2], h[1], h[3], h[4])
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
  -- Reset state on each setup (prevents leaks between open/close cycles)
  line_map = {}
  collapsed = { staged = false, unstaged = false }

  local cfg = config.get()
  local km  = cfg.keymaps or {}

  local opts = { buffer = buf, nowait = true, silent = true }

  -- Activate the entry on line `lnr`: toggle a section header, or open a file's
  -- diff. Shared by <CR> and mouse clicks.
  local function activate_line(lnr)
    local meta = line_map[lnr]
    if not meta then return end

    if meta.type == "header" then
      collapsed[meta.section] = not collapsed[meta.section]
      M.refresh(buf, win, repo_root)
    elseif meta.type == "file" then
      local dv   = require("diff.diff_view")
      local file = vim.tbl_extend("force", meta.file, {
        staged = (meta.section == "staged"),
      })
      local ok, err = pcall(dv.open_file_diff, repo_root, file)
      if not ok then
        vim.notify("diff.nvim: error opening diff: " .. tostring(err), vim.log.levels.ERROR)
      end
    end
  end

  -- <CR>: open diff or toggle section collapse
  vim.keymap.set("n", km.open_diff or "<CR>", function()
    if not vim.api.nvim_win_is_valid(win) then return end
    activate_line(vim.api.nvim_win_get_cursor(win)[1])
  end, vim.tbl_extend("force", opts, { desc = "Open diff / toggle section (diff)" }))

  -- Mouse: clicking a row activates it (same as <CR>). getmousepos() gives the
  -- exact clicked window + line, so this works regardless of cursor position.
  local function on_mouse_click()
    local mp = vim.fn.getmousepos()
    if mp.winid ~= win then return end
    if mp.line < 1 then return end
    pcall(vim.api.nvim_win_set_cursor, win, { mp.line, 0 })
    activate_line(mp.line)
  end
  vim.keymap.set("n", "<LeftMouse>", on_mouse_click,
    vim.tbl_extend("force", opts, { desc = "Activate row (diff)" }))

  -- Expose the row activator so the global click dispatcher can reach it.
  M.activate_line = activate_line

  -- 's': stage file (unstaged section only)
  vim.keymap.set("n", km.stage_file or "s", function()
    local lnr  = vim.api.nvim_win_get_cursor(win)[1]
    local meta = line_map[lnr]
    if not meta or meta.type ~= "file" or meta.section ~= "unstaged" then return end
    git.stage_file(repo_root, meta.file.path, function(success, err)
      if not success then
        vim.notify("diff.nvim: stage failed: " .. (err or ""), vim.log.levels.ERROR)
      end
      M.refresh(buf, win, repo_root)
    end)
  end, vim.tbl_extend("force", opts, { desc = "Stage file (diff)" }))

  -- 'u': unstage file (staged section only)
  vim.keymap.set("n", km.unstage_file or "u", function()
    local lnr  = vim.api.nvim_win_get_cursor(win)[1]
    local meta = line_map[lnr]
    if not meta or meta.type ~= "file" or meta.section ~= "staged" then return end
    git.unstage_file(repo_root, meta.file.path, function(success, err)
      if not success then
        vim.notify("diff.nvim: unstage failed: " .. (err or ""), vim.log.levels.ERROR)
      end
      M.refresh(buf, win, repo_root)
    end)
  end, vim.tbl_extend("force", opts, { desc = "Unstage file (diff)" }))

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
  end, vim.tbl_extend("force", opts, { desc = "Toggle section (diff)" }))

  -- 'q': close the entire diff.nvim interface
  vim.keymap.set("n", "q", function()
    require("diff.sidebar").close()
  end, vim.tbl_extend("force", opts, { desc = "Close (diff)" }))
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
    if not vim.api.nvim_buf_is_valid(buf) then return end
    status = status or { staged = {}, unstaged = {} }

    -- Enrich files with per-file diffstat counts, then render. The diffstat
    -- call is best-effort: if it fails we still render without counts.
    git.get_diffstat(repo_root, function(stats)
      if not vim.api.nvim_buf_is_valid(buf) then return end
      stats = stats or { staged = {}, unstaged = {} }
      for _, f in ipairs(status.staged or {}) do
        f.stat = stats.staged[f.path]
      end
      for _, f in ipairs(status.unstaged or {}) do
        f.stat = stats.unstaged[f.path]
      end
      render(buf, status)
    end)
  end)
end

return M
