--- diff.nvim — file status panel. Normally the staged / unstaged changes as
--- trees; in branch mode, every change the branch made since its merge base
--- with the base branch, as a pull request's "Files changed" tab shows them.
---
--- refresh() fetches git data into S.status and S.branch; render() draws them
--- into the buffer. Collapsing, resizing and re-marking the active file only render,
--- so they never wait on git.
local M = {}

local git    = require("diff.git")
local util   = require("diff.util")
local log    = require("diff.log").scope("file_panel")

local NS        = vim.api.nvim_create_namespace("diff_nvim_file_panel")
local NS_ACTIVE = vim.api.nvim_create_namespace("diff_nvim_file_panel_active")
local NS_HOVER  = vim.api.nvim_create_namespace("diff_nvim_file_panel_hover")

-- Rows a click acts on (and so get the hover tint).
local CLICKABLE = { header = true, dir_node = true, file = true }

local function fresh_state()
  return {
    buf = nil, win = nil, root = nil,
    status  = nil,  -- { staged = file[], unstaged = file[] } from the last refresh
    preview = nil,  -- branch name while previewing
    branch_mode = false,
    cursors = {},   -- mode -> cursor identity when the mode was left
    restore = nil,  -- cursor identity to restore on the next render with data
    branch  = nil,  -- { base, head, files|nil, error|nil } changes since the merge base with the base branch
    base    = nil,  -- { ref, name } of the base branch; false = none found, nil = not looked up
    collapsed = { staged = false, unstaged = false, branch = false },
    collapsed_dirs = {}, -- "<section>:<dir path>" -> true
    line_map = {},       -- lnr -> { type, key, section, file?, dir_key? }
    active = nil,        -- key of the file shown in the diff view
    hover = nil,         -- row under the mouse pointer
    gen = 0,
    width = nil,    -- width of the last render
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
  if section == "branch" then return "DiffNvimCommitFileEntry" end
  return "DiffNvimUnstagedFile"
end

local function file_key(section, path)
  return "file:" .. section .. ":" .. path
end

--- Files listed in `section`: "staged", "unstaged" or "branch".
local function section_files(section)
  if section == "branch" then return S.branch and S.branch.files or {} end
  return S.status and S.status[section] or {}
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
    local files = section_files(section)
    local r = push((S.collapsed[section] and "▶ " or "▼ ") .. label .. " (" .. #files .. ")",
      { type = "header", key = "header:" .. section, section = section })
    table.insert(hl, { r, "DiffNvimSectionHeader", 0, -1 })
    if S.collapsed[section] then return end
    for _, child in ipairs(util.sort_tree_children(util.build_file_tree(files).children)) do
      render_node(child, 0, section, "")
    end
  end

  if S.preview then
    push(util.trunc("Preview: " .. S.preview, math.max(8, width)), { type = "preview_header", key = "preview" })
    table.insert(hl, { #lines - 1, "DiffNvimSectionHeader", 0, -1 })
    if not S.branch_mode then return lines, hl, map end
    push("", { type = "blank" })
  end
  if S.branch_mode then
    local function note(text)
      push(util.trunc("  " .. text, math.max(8, width)), { type = "blank" })
      table.insert(hl, { #lines - 1, "Comment", 0, -1 })
    end
    if S.branch and S.branch.files then
      render_section("branch", "Branch Changes vs " .. S.branch.base)
    elseif S.branch then
      note("Cannot compare with " .. S.branch.base .. ":")
      note(S.branch.error or "?")
    elseif S.base == false then
      note("No base branch (origin/HEAD, main or")
      note("master); set base_branch in setup().")
    else
      note("Loading branch changes…")
    end
    return lines, hl, map
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
      })
      return
    end
  end
end

--- Tint the clickable row under the mouse pointer.
local function apply_hover()
  if not (S.buf and vim.api.nvim_buf_is_valid(S.buf)) then return end
  vim.api.nvim_buf_clear_namespace(S.buf, NS_HOVER, 0, -1)
  local meta = S.hover and S.line_map[S.hover]
  if not (meta and CLICKABLE[meta.type]) then return end
  -- Above the cursor line and active-file highlights, so the hover always shows.
  pcall(vim.api.nvim_buf_set_extmark, S.buf, NS_HOVER, S.hover - 1, 0, {
    line_hl_group = "DiffNvimHover", priority = 300,
  })
end

--- Draw the cached status into the panel at the window's current width.
function M.render()
  if not valid() then return end
  -- After a mode switch, the cursor goes back to where it was in that mode,
  -- once the mode's data is there to find it in.
  local prev = S.restore or cursor_identity()
  if S.restore and (S.branch_mode and S.branch or not S.branch_mode and (S.status or S.preview)) then
    S.restore = nil
  end
  S.width = vim.api.nvim_win_get_width(S.win)
  local lines, hl, map = build(S.width)
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
  apply_hover()
end

--- The mouse pointer is over row `lnr` (nil: not over this panel).
function M.hover(lnr)
  if lnr == S.hover then return end
  S.hover = lnr
  apply_hover()
end

--- Re-render after a resize, but only when the width changed: a height-only
--- resize (a split elsewhere in the tab) leaves every line as it was.
function M.on_resize()
  if valid() and vim.api.nvim_win_get_width(S.win) ~= S.width then M.render() end
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
  walk(util.build_file_tree(section_files(section)))
  return out
end

local function to_source(file, section)
  if section == "branch" then
    return {
      kind = "range", path = file.path, old_path = file.old_path, status = file.status,
      old_blob = file.old_blob, new_blob = file.new_blob, base = S.branch.base, head = S.branch.head,
    }
  end
  return {
    kind = "worktree", path = file.path, old_path = file.old_path,
    status = file.status, staged = section == "staged",
  }
end

--- Next/previous file in display order within the same section.
function M.navigator(source, dir)
  local section = source.kind == "range" and "branch" or source.staged and "staged" or "unstaged"
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
  if data.kind == "worktree" then
    S.active = file_key(data.staged and "staged" or "unstaged", data.path)
  elseif data.kind == "range" then
    S.active = file_key("branch", data.path)
  else
    S.active = nil
  end
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

--- Point the panel at another work tree (a linked worktree), dropping the data
--- of the previous one.
function M.set_root(root)
  S.gen = S.gen + 1
  S.root, S.status, S.active, S.preview, S.branch, S.base = root, nil, nil, nil, nil, nil
  S.collapsed_dirs = {}
end

--- Wire up keymaps for the panel buffer.
function M.setup(buf, win, repo_root)
  local keep = S
  S = fresh_state()
  S.buf, S.win, S.root = buf, win, repo_root
  -- Keep fetched data and collapse state across a sidebar hide/show.
  if keep.root == repo_root then
    S.status, S.collapsed, S.collapsed_dirs, S.active = keep.status, keep.collapsed, keep.collapsed_dirs, keep.active
    S.branch, S.base, S.branch_mode = keep.branch, keep.base, keep.branch_mode
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

  if S.status or S.preview or S.branch then M.render() end
end

--- Look the base branch up again on the next branch-mode refresh.
function M.forget_base()
  S.base = nil
end

--- Fetch what `head` changed since its merge base with the base branch.
--- The base is looked up once per entry into branch mode. The diff is only
--- recomputed when `head` or the base point at new commits: saves and index
--- writes cannot change it, and on a large branch it is the slow part.
--- @param cb fun(branch: {key, base: string, head: string, files: table[]|nil, error: string|nil}|nil)
---   nil when there is no base branch; S.branch itself when nothing moved.
local function fetch_branch(head, cb)
  local root = S.root
  local function with_base(base)
    if not base then cb(nil) return end
    git.rev_parse(root, { head, base.ref }, function(shas)
      local key = shas and table.concat(shas, " ")
      local cached = S.branch
      if key and cached and cached.key == key and cached.base == base.name and cached.head == head then
        return cb(cached)
      end
      local from, to = shas and shas[2] or base.ref, shas and shas[1] or head
      git.get_branch_changes(root, from, to, function(files, err)
        if err then log.debug("branch changes for %s: %s", head, err) end
        cb({ key = key, base = base.name, head = head, files = files, error = err })
      end)
    end)
  end
  if S.base ~= nil then return with_base(S.base or nil) end
  local configured = require("diff.config").get().base_branch
  if configured then
    S.base = { ref = configured, name = configured }
    return with_base(S.base)
  end
  git.get_default_base(root, function(base)
    log.debug("base branch: %s", base and base.ref or "(none)")
    if root == S.root then S.base = base or false end
    with_base(base)
  end)
end

--- Keep an open branch-changes diff on the branch's latest version of its
--- file, or close it when the file is no longer changed on the branch.
local function follow_open_diff()
  local dv = require("diff.diff_view")
  local src = dv._state().source
  if not (src and src.kind == "range" and S.branch and S.branch.files and src.head == S.branch.head) then return end
  for _, f in ipairs(S.branch.files) do
    if f.path == src.path then
      if f.old_blob ~= src.old_blob or f.new_blob ~= src.new_blob then dv.retarget(to_source(f, "branch")) end
      return
    end
  end
  dv.close()
end

--- Fetch what the current mode shows and re-render: status and diffstat (in
--- parallel), or in branch mode the branch's changes.
--- @param preview     string|nil  Branch being previewed; no working-tree status
---   then, and branch mode shows that branch's changes rather than HEAD's.
--- @param branch_mode boolean|nil
--- @param on_done     fun()|nil  called once this refresh has finished (or
---   been superseded by a newer one)
function M.refresh(preview, branch_mode, on_done)
  local function finish()
    if on_done then
      local f = on_done
      on_done = nil
      f()
    end
  end
  S.gen = S.gen + 1
  local gen = S.gen
  local head = preview or "HEAD"
  branch_mode = branch_mode or false
  if branch_mode ~= S.branch_mode then
    -- Remember the cursor in the mode being left; return to it next time.
    if valid() then S.cursors[S.branch_mode] = cursor_identity() end
    S.restore = S.cursors[branch_mode] or { row = 1 }
  end
  local mode_changed = branch_mode ~= S.branch_mode or preview ~= S.preview
  -- Another branch's changes must not linger while this one's load.
  if S.branch and S.branch.head ~= head then S.branch = nil end
  S.preview, S.branch_mode = preview, branch_mode

  if branch_mode then
    -- At once: the cached list, or a loading note while there is none.
    if mode_changed or not S.branch then M.render() end
    fetch_branch(head, function(branch)
      if gen == S.gen and branch ~= S.branch then
        S.branch = branch
        M.render()
        follow_open_diff()
      end
      finish()
    end)
    return
  end
  if preview then
    S.status = nil
    M.render()
    finish()
    return
  end
  -- At once: the last status, rather than the other mode's rows.
  if mode_changed then M.render() end

  local elapsed = require("diff.log").timer()
  local status, stats
  local pending = 2
  local function done()
    pending = pending - 1
    if pending > 0 then return end
    -- A newer refresh started while this one was in flight.
    if gen ~= S.gen then return finish() end
    for _, section in ipairs({ "staged", "unstaged" }) do
      for _, f in ipairs(status[section]) do
        f.stat = stats and stats[section][f.path] or nil
      end
    end
    S.status = status
    M.render()
    log.debug("refreshed: %d staged, %d unstaged in %.1f ms", #status.staged, #status.unstaged, elapsed())
    finish()
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
