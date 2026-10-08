--- diff.nvim — file status panel (staged / unstaged changes as trees).
---
--- refresh() fetches git data into S.status; render() draws S.status into the
--- buffer. Collapsing, resizing and re-marking the active file only render,
--- so they never wait on git.
local M = {}

local git    = require("diff.git")
local util   = require("diff.util")
local log    = require("diff.log").scope("file_panel")

local NS        = vim.api.nvim_create_namespace("diff_nvim_file_panel")
local NS_ACTIVE = vim.api.nvim_create_namespace("diff_nvim_file_panel_active")

local function fresh_state()
  return {
    buf = nil, win = nil, root = nil,
    status  = nil,  -- { staged = file[], unstaged = file[] } from the last refresh
    preview = nil,  -- branch name while previewing
    collapsed = { staged = false, unstaged = false },
    collapsed_dirs = {}, -- "<section>:<dir path>" -> true
    line_map = {},       -- lnr -> { type, key, section, file?, dir_key? }
    active = nil,        -- key of the file shown in the diff view
    gen = 0,
  }
end

local S = fresh_state()

local STATUS_BADGE = {
  modified = "M", added = "A", deleted = "D", renamed = "R",
  copied = "C", unmerged = "U", untracked = "?", unknown = "·",
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

local function file_hl(file, section)
  if file.status == "deleted" then return "DiffNvimDeletedFile" end
  if section == "staged" then return "DiffNvimStagedFile" end
  return "DiffNvimUnstagedFile"
end

local function file_key(section, path)
  return "file:" .. section .. ":" .. path
end

local function valid()
  return S.buf and vim.api.nvim_buf_is_valid(S.buf) and S.win and vim.api.nvim_win_is_valid(S.win)
end

--- " +12 -3" diffstat segment with byte ranges for highlighting.
local function diffstat_segment(f)
  local st = f.stat
  if not st then return "", nil, nil end
  if st.binary then return "  bin", nil, nil end
  local added, deleted = st.added or 0, st.deleted or 0
  if added == 0 and deleted == 0 then return "", nil, nil end
  local text, add_range, del_range = "  ", nil, nil
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

-- ---------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------

local function build(width)
  local lines, hl, map = {}, {}, {}

  local function push(line, meta)
    table.insert(lines, line)
    map[#lines] = meta
    return #lines - 1
  end

  if S.preview then
    push(util.trunc("Preview: " .. S.preview, math.max(8, width)), { type = "preview_header", key = "preview" })
    table.insert(hl, { 0, "DiffNvimSectionHeader", 0, -1 })
    return lines, hl, map
  end

  local render_node

  local function render_dir(node, depth, section, prefix)
    local display, cur = util.compact_dir_chain(node)
    local dir_path = prefix .. display
    local key = section .. ":" .. dir_path
    local is_collapsed = S.collapsed_dirs[key] or false
    local indent = string.rep("  ", depth + 1)
    -- Reserve a column for "/" and one for the collapsed marker "…".
    local name = util.trunc_middle(display, math.max(1, width - #indent - 2))
    local line = indent .. name .. "/" .. (is_collapsed and "…" or "")
    local r = push(line, { type = "dir_node", key = "dir:" .. key, section = section, dir_key = key })
    table.insert(hl, { r, "Comment", #indent, #line })
    if is_collapsed then return end
    for _, child in ipairs(util.sort_tree_children(cur.children)) do
      render_node(child, depth + 1, section, dir_path .. "/")
    end
  end

  render_node = function(node, depth, section, prefix)
    if not node.file then
      render_dir(node, depth, section, prefix)
      return
    end
    local f = node.file
    local indent = string.rep("  ", depth + 1)
    local stat_text, add_range, del_range = diffstat_segment(f)
    local right_w = 3 + #stat_text -- "[X]" + stats
    local name = util.trunc_middle(node.name, math.max(1, width - #indent - right_w - 1))
    local pad = math.max(1, width - #indent - vim.fn.strdisplaywidth(name) - right_w)
    local line = indent .. name .. string.rep(" ", pad) .. "[" .. (STATUS_BADGE[f.status] or "·") .. "]" .. stat_text
    local r = push(line, { type = "file", key = file_key(section, f.path), section = section, file = f })

    table.insert(hl, { r, file_hl(f, section), #indent, #indent + #name })
    local badge_col = #line - #stat_text - 3
    table.insert(hl, { r, STATUS_HL[f.status] or "DiffNvimStatusUntracked", badge_col, badge_col + 3 })
    local base = #line - #stat_text
    if add_range then table.insert(hl, { r, "DiffNvimStatAdded", base + add_range[1], base + add_range[2] }) end
    if del_range then table.insert(hl, { r, "DiffNvimStatRemoved", base + del_range[1], base + del_range[2] }) end
  end

  local function render_section(section, label)
    local files = S.status and S.status[section] or {}
    local r = push((S.collapsed[section] and "▶ " or "▼ ") .. label .. " (" .. #files .. ")",
      { type = "header", key = "header:" .. section, section = section })
    table.insert(hl, { r, "DiffNvimSectionHeader", 0, -1 })
    if S.collapsed[section] then return end
    for _, child in ipairs(util.sort_tree_children(util.build_file_tree(files).children)) do
      render_node(child, 0, section, "")
    end
  end

  render_section("staged", "Staged Changes")
  push("", { type = "blank" })
  render_section("unstaged", "Changes")
  return lines, hl, map
end

--- Rows belonging to `section`, in display order.
local function section_rows(section)
  local rows = {}
  for lnr, meta in pairs(S.line_map) do
    if meta.section == section then table.insert(rows, lnr) end
  end
  table.sort(rows)
  return rows
end

--- Remember the item under the cursor so it can be found after re-rendering,
--- including its position within its section.
local function cursor_identity()
  local row = vim.api.nvim_win_get_cursor(S.win)[1]
  local meta = S.line_map[row]
  local id = { row = row, key = meta and meta.key, section = meta and meta.section }
  if id.section then
    for i, lnr in ipairs(section_rows(id.section)) do
      if lnr == row then id.ordinal = i end
    end
  end
  return id
end

--- Put the cursor back on the same item. An item that left its section (a
--- file just staged) leaves the cursor at the same position in that section,
--- i.e. on the next file — so pressing `s` repeatedly stages file after file.
--- Position, not row number: the other section may have grown above it.
local function restore_cursor(prev)
  local target
  for lnr, meta in pairs(S.line_map) do
    if prev.key and meta.key == prev.key then target = lnr break end
  end
  if not target and prev.ordinal then
    local rows = section_rows(prev.section)
    target = rows[math.min(prev.ordinal, #rows)]
  end
  target = math.min(target or prev.row, vim.api.nvim_buf_line_count(S.buf))
  pcall(vim.api.nvim_win_set_cursor, S.win, { target, 0 })
end

local function apply_active()
  if not (S.buf and vim.api.nvim_buf_is_valid(S.buf)) then return end
  vim.api.nvim_buf_clear_namespace(S.buf, NS_ACTIVE, 0, -1)
  if not S.active then return end
  for lnr, meta in pairs(S.line_map) do
    if meta.key == S.active then
      vim.api.nvim_buf_set_extmark(S.buf, NS_ACTIVE, lnr - 1, 0, {
        line_hl_group = "DiffNvimActiveFile",
        virt_text = { { "▎", "DiffNvimActiveSign" } }, virt_text_pos = "overlay",
      })
      return
    end
  end
end

--- Draw the cached status into the panel at the window's current width.
function M.render()
  if not valid() then return end
  local prev = cursor_identity()
  local lines, hl, map = build(vim.api.nvim_win_get_width(S.win))
  S.line_map = map

  vim.bo[S.buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(S.buf, NS, 0, -1)
  vim.api.nvim_buf_set_lines(S.buf, 0, -1, false, lines)
  vim.bo[S.buf].modifiable = false
  for _, h in ipairs(hl) do
    pcall(vim.api.nvim_buf_add_highlight, S.buf, NS, h[2], h[1], h[3], h[4])
  end
  restore_cursor(prev)
  apply_active()
end

-- ---------------------------------------------------------------------------
-- Navigation (]f / [f in the diff view)
-- ---------------------------------------------------------------------------

local function ordered_files(section)
  local out = {}
  local function walk(node)
    for _, child in ipairs(util.sort_tree_children(node.children)) do
      if child.file then table.insert(out, child.file) else walk(child) end
    end
  end
  walk(util.build_file_tree(S.status and S.status[section] or {}))
  return out
end

local function to_source(file, section)
  return {
    kind = "worktree", path = file.path, old_path = file.old_path,
    status = file.status, staged = section == "staged",
  }
end

--- Next/previous file in display order within the same section.
function M.navigator(source, dir)
  local section = source.staged and "staged" or "unstaged"
  local files = ordered_files(section)
  for i, f in ipairs(files) do
    if f.path == source.path then
      return files[i + dir] and to_source(files[i + dir], section) or nil
    end
  end
  -- The current file has left this section (e.g. it was fully staged).
  return files[1] and to_source(files[1], section) or nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Activate the row `lnr`: toggle a header or directory, or open a file.
function M.activate_line(lnr)
  local meta = S.line_map[lnr]
  if not meta then return end
  if meta.type == "header" then
    S.collapsed[meta.section] = not S.collapsed[meta.section]
    M.render()
  elseif meta.type == "dir_node" then
    S.collapsed_dirs[meta.dir_key] = not S.collapsed_dirs[meta.dir_key] or nil
    M.render()
  elseif meta.type == "file" then
    require("diff.diff_view").open(S.root, to_source(meta.file, meta.section), M.navigator)
  end
end

--- Mark the file shown in the diff view (data from DiffNvimViewChanged).
function M.mark_active(data)
  data = data or {}
  S.active = data.kind == "worktree" and file_key(data.staged and "staged" or "unstaged", data.path) or nil
  apply_active()
end

local function meta_at_cursor()
  if not valid() then return nil end
  return S.line_map[vim.api.nvim_win_get_cursor(S.win)[1]]
end

local function stage(action)
  local meta = meta_at_cursor()
  local want = action == "stage" and "unstaged" or "staged"
  if not meta or meta.type ~= "file" or meta.section ~= want then return end
  local fn = action == "stage" and git.stage_file or git.unstage_file
  fn(S.root, meta.file.path, function(ok, err)
    if not ok then
      log.warn("%s %s failed: %s", action, meta.file.path, err or "?")
      vim.notify("diff.nvim: " .. action .. " failed: " .. (err or ""), vim.log.levels.ERROR)
    else
      log.info("%sd %s", action, meta.file.path)
    end
    M.refresh(S.preview)
  end)
end

--- Wire up keymaps for the panel buffer.
function M.setup(buf, win, repo_root)
  local keep = S
  S = fresh_state()
  S.buf, S.win, S.root = buf, win, repo_root
  -- Keep fetched data and collapse state across a sidebar hide/show.
  if keep.root == repo_root then
    S.status, S.collapsed, S.collapsed_dirs, S.active = keep.status, keep.collapsed, keep.collapsed_dirs, keep.active
  end

  local km = require("diff.config").get().keymaps or {}
  local function map(key, fn, desc, extra)
    if not key or key == "" then return end
    vim.keymap.set("n", key, fn, vim.tbl_extend("force",
      { buffer = buf, nowait = true, silent = true, desc = desc .. " (diff)" }, extra or {}))
  end

  map(km.open_diff, function()
    if valid() then M.activate_line(vim.api.nvim_win_get_cursor(S.win)[1]) end
  end, "Open diff / toggle section")
  map(km.stage_file, function() stage("stage") end, "Stage file")
  map(km.unstage_file, function() stage("unstage") end, "Unstage file")
  map(km.collapse, function()
    local meta = meta_at_cursor()
    if not meta then return end
    if meta.type == "dir_node" then
      S.collapsed_dirs[meta.dir_key] = not S.collapsed_dirs[meta.dir_key] or nil
    elseif meta.section then
      S.collapsed[meta.section] = not S.collapsed[meta.section]
    else
      return
    end
    M.render()
  end, "Toggle directory / section")

  -- Step over the blank spacer between the sections.
  for key, dir in pairs({ j = 1, k = -1, ["<Down>"] = 1, ["<Up>"] = -1 }) do
    map(key, function()
      local row = vim.api.nvim_win_get_cursor(0)[1]
      local last = vim.api.nvim_buf_line_count(buf)
      local start = row
      for _ = 1, vim.v.count1 do
        local t = row + dir
        while S.line_map[t] and S.line_map[t].type == "blank" do t = t + dir end
        if t < 1 or t > last then break end
        row = t
      end
      if row == start then return "" end
      return string.format("<Cmd>normal! %d%s<CR>", math.abs(row - start), dir > 0 and "j" or "k")
    end, "Move, skip blank rows", { expr = true })
  end

  map("q", function() require("diff.sidebar").close() end, "Close")

  if S.status or S.preview then M.render() end
end

--- Fetch status and diffstat (in parallel) and re-render.
--- @param preview string|nil  Branch being previewed; no working-tree status then.
function M.refresh(preview)
  S.gen = S.gen + 1
  local gen = S.gen
  S.preview = preview
  if preview then
    S.status = nil
    M.render()
    return
  end

  local elapsed = require("diff.log").timer()
  local status, stats
  local pending = 2
  local function done()
    pending = pending - 1
    if pending > 0 then return end
    -- A newer refresh started while this one was in flight.
    if gen ~= S.gen then return end
    for _, section in ipairs({ "staged", "unstaged" }) do
      for _, f in ipairs(status[section]) do
        f.stat = stats and stats[section][f.path] or nil
      end
    end
    S.status = status
    M.render()
    log.debug("refreshed: %d staged, %d unstaged in %.1f ms", #status.staged, #status.unstaged, elapsed())
  end

  git.get_status(S.root, function(st, err)
    if err then
      log.warn("git status failed: %s", err)
      vim.notify("diff.nvim: status error: " .. err, vim.log.levels.WARN)
    end
    status = st or { staged = {}, unstaged = {} }
    done()
  end)
  git.get_diffstat(S.root, function(st)
    stats = st
    done()
  end)
end

return M
