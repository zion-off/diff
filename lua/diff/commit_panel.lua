--- diff.nvim — commit history panel.
---
--- refresh() fetches the commit list into S.commits; expanding a commit
--- fetches its details once into S.details. render() draws from those caches,
--- so expanding/collapsing a cached commit, resizing and re-marking the
--- active file never wait on git.
local M = {}

local git    = require("diff.git")
local util   = require("diff.util")
local log    = require("diff.log").scope("commit_panel")

local NS        = vim.api.nvim_create_namespace("diff_nvim_commit_panel")
-- Separate namespace for the two-line cursor highlight, redrawn on every move.
local CURSOR_NS = vim.api.nvim_create_namespace("diff_nvim_commit_cursor")
local NS_ACTIVE = vim.api.nvim_create_namespace("diff_nvim_commit_active")
local NS_HOVER  = vim.api.nvim_create_namespace("diff_nvim_commit_hover")

local COMMIT_LIMIT = 50
local META_INDENT  = "  "

local function fresh_state()
  return {
    buf = nil, win = nil, root = nil, ref = nil,
    commits  = nil, -- commit list from the last refresh
    expanded = {},  -- hash -> true
    details  = {},  -- hash -> { body, files, added, deleted }
    loading  = {},  -- hash -> true while details are being fetched
    line_map = {},  -- lnr -> { type, key?, commit, file? }
    header_pair = {}, -- lnr -> { l1, l2 } header lines of the commit owning lnr
    active = nil,
    hover = nil,    -- row under the mouse pointer
    gen = 0,
    width = nil,    -- width of the last render
  }
end

local S = fresh_state()

M._tooltip_win    = nil
M._tooltip_buf    = nil
M._tooltip_req_id = 0

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

local function ref_hl(ref)
  if ref == "HEAD" or ref:match("^HEAD %->") then
    return "DiffNvimRefHead"
  elseif ref:match("^tag:") then
    return "DiffNvimRefTag"
  elseif ref:match("^origin/") or ref:match("^%a[%w%-]+/") then
    return "DiffNvimRefRemote"
  end
  return "DiffNvimRefBranch"
end

local function file_key(hash, path)
  return "cfile:" .. hash .. ":" .. path
end

local function valid()
  return S.buf and vim.api.nvim_buf_is_valid(S.buf) and S.win and vim.api.nvim_win_is_valid(S.win)
end

--- "+12 -3" with byte ranges relative to the returned text.
local function stat_text(added, deleted, lead)
  added, deleted = added or 0, deleted or 0
  if added == 0 and deleted == 0 then return "", nil, nil end
  local text, add_range, del_range = lead or "", nil, nil
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
  local lines, hl, map, pairs_ = {}, {}, {}, {}

  local function push(line, meta)
    table.insert(lines, line)
    map[#lines] = meta
    return #lines - 1
  end

  for _, commit in ipairs(S.commits or {}) do
    local is_expanded = S.expanded[commit.hash] and S.details[commit.hash]
    local hash_str = commit.short_hash or commit.hash:sub(1, 7)

    -- Line 1: hash + subject
    local seg = hash_str .. "  "
    local line1 = seg .. util.trunc(commit.subject or "", math.max(8, width - #seg))
    local r1 = push(line1, { type = "commit", key = "commit:" .. commit.hash, commit = commit })
    table.insert(hl, { r1, "DiffNvimCommitHash", 0, #hash_str })
    table.insert(hl, { r1, "DiffNvimCommitSubject", #seg, #line1 })

    -- Line 2: dim "author · time" + ref pills that fit
    local meta = META_INDENT .. util.trunc(commit.author or "", math.max(8, math.floor(width / 2)))
    if (commit.time or "") ~= "" then meta = meta .. " · " .. commit.time end
    local meta_end = #meta
    local pills = {}
    for _, ref in ipairs(commit.refs or {}) do
      local pill = " [" .. ref .. "]"
      if vim.fn.strdisplaywidth(meta .. pill) <= width then
        table.insert(pills, { #meta, #meta + #pill, ref_hl(ref) })
        meta = meta .. pill
      end
    end
    local r2 = push(meta, { type = "commit", meta_line = true, commit = commit })
    table.insert(hl, { r2, "DiffNvimCommitMeta", 0, meta_end })
    for _, p in ipairs(pills) do table.insert(hl, { r2, p[3], p[1], p[2] }) end

    local first = r1 + 1
    if is_expanded then
      local d = S.details[commit.hash]
      local avail = math.max(8, width - #META_INDENT)

      for i, raw in ipairs(d.body) do
        if raw == "" then
          push("", { type = "commit_body", blank = true, commit = commit })
        else
          for _, chunk in ipairs(util.wrap(raw, avail)) do
            local line = META_INDENT .. chunk
            local r = push(line, { type = "commit_body", commit = commit })
            table.insert(hl, { r, i == 1 and "DiffNvimCommitSubject" or "DiffNvimCommitBody", #META_INDENT, #line })
          end
        end
      end
      if #d.body > 0 then push("", { type = "commit_body", blank = true, commit = commit }) end

      local stat, add_range, del_range = stat_text(d.added, d.deleted, META_INDENT)
      if stat ~= "" then
        local r = push(stat, { type = "commit_body", commit = commit })
        if add_range then table.insert(hl, { r, "DiffNvimStatAdded", add_range[1], add_range[2] }) end
        if del_range then table.insert(hl, { r, "DiffNvimStatRemoved", del_range[1], del_range[2] }) end
      end

      local render_node
      local function render_dir(node, depth)
        local display, cur = util.compact_dir_chain(node)
        local pad = META_INDENT .. string.rep("  ", depth)
        local name = util.trunc_middle(display, math.max(1, width - #pad - 1))
        local r = push(pad .. name .. "/", { type = "commit_dir", commit = commit })
        table.insert(hl, { r, "Comment", #pad, #pad + #name + 1 })
        for _, child in ipairs(util.sort_tree_children(cur.children)) do render_node(child, depth + 1) end
      end
      render_node = function(node, depth)
        if not node.file then return render_dir(node, depth) end
        local f = node.file
        local pad = META_INDENT .. string.rep("  ", depth)
        local st, a_r, d_r = stat_text(f.stat and f.stat.added, f.stat and f.stat.deleted, "  ")
        if f.stat and f.stat.binary then st, a_r, d_r = "  bin", nil, nil end
        local right_w = 3 + #st
        local name = util.trunc_middle(node.name, math.max(1, width - #pad - right_w - 1))
        local gap = math.max(1, width - #pad - vim.fn.strdisplaywidth(name) - right_w)
        local line = pad .. name .. string.rep(" ", gap) .. "[" .. (STATUS_BADGE[f.status] or "·") .. "]" .. st
        local r = push(line, { type = "commit_file", key = file_key(commit.hash, f.path), commit = commit, file = f })
        table.insert(hl, { r, "DiffNvimCommitFileEntry", #pad, #pad + #name })
        local badge_col = #line - #st - 3
        table.insert(hl, { r, STATUS_HL[f.status] or "DiffNvimStatusUntracked", badge_col, badge_col + 3 })
        local base = #line - #st
        if a_r then table.insert(hl, { r, "DiffNvimStatAdded", base + a_r[1], base + a_r[2] }) end
        if d_r then table.insert(hl, { r, "DiffNvimStatRemoved", base + d_r[1], base + d_r[2] }) end
      end
      for _, child in ipairs(util.sort_tree_children(util.build_file_tree(d.files).children)) do
        render_node(child, 0)
      end
    end

    local pair = { first, first + 1 }
    for ln = first, #lines do pairs_[ln] = pair end
  end

  if #lines == 0 then push("  (no commits)", { type = "empty" }) end
  return lines, hl, map, pairs_
end

local function highlight_cursor_commit()
  if not valid() then return end
  vim.api.nvim_buf_clear_namespace(S.buf, CURSOR_NS, 0, -1)
  local pair = S.header_pair[vim.api.nvim_win_get_cursor(S.win)[1]]
  if not pair then return end
  for _, l in ipairs(pair) do
    pcall(vim.api.nvim_buf_set_extmark, S.buf, CURSOR_NS, l - 1, 0, {
      line_hl_group = "DiffNvimCommitCursor", priority = 10,
    })
  end
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

--- Tint the clickable entry under the mouse pointer: both header lines of a
--- commit, or a file row.
local function apply_hover()
  if not (S.buf and vim.api.nvim_buf_is_valid(S.buf)) then return end
  vim.api.nvim_buf_clear_namespace(S.buf, NS_HOVER, 0, -1)
  local meta = S.hover and S.line_map[S.hover]
  if not meta then return end
  local rows
  if meta.type == "commit" then
    rows = S.header_pair[S.hover]
  elseif meta.type == "commit_file" then
    rows = { S.hover }
  end
  for _, l in ipairs(rows or {}) do
    -- Above the cursor and active-file highlights, so the hover always shows.
    pcall(vim.api.nvim_buf_set_extmark, S.buf, NS_HOVER, l - 1, 0, {
      line_hl_group = "DiffNvimHover", priority = 5000,
    })
  end
end

--- Put the cursor back on the same entry after the line layout changed.
local function restore_cursor(prev)
  local target, fallback
  for lnr, meta in pairs(S.line_map) do
    if prev.key and meta.key == prev.key then target = lnr break end
    if prev.hash and meta.key == "commit:" .. prev.hash then fallback = lnr end
  end
  target = math.min(target or fallback or prev.row, vim.api.nvim_buf_line_count(S.buf))
  pcall(vim.api.nvim_win_set_cursor, S.win, { target, 0 })
end

--- Draw the cached commits into the panel at the window's current width.
function M.render()
  if not valid() then return end
  local row = vim.api.nvim_win_get_cursor(S.win)[1]
  local cur = S.line_map[row]
  local prev = { row = row, key = cur and cur.key, hash = cur and cur.commit and cur.commit.hash }

  S.width = vim.api.nvim_win_get_width(S.win)
  local lines, hl, map, header_pair = build(S.width)
  S.line_map, S.header_pair = map, header_pair

  vim.bo[S.buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(S.buf, NS, 0, -1)
  vim.api.nvim_buf_set_lines(S.buf, 0, -1, false, lines)
  vim.bo[S.buf].modifiable = false
  for _, h in ipairs(hl) do
    pcall(vim.api.nvim_buf_add_highlight, S.buf, NS, h[2], h[1], h[3], h[4])
  end
  restore_cursor(prev)
  highlight_cursor_commit()
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
-- Commit tooltip (K)
-- ---------------------------------------------------------------------------

local function close_tooltip()
  M._tooltip_req_id = M._tooltip_req_id + 1
  if M._tooltip_win and vim.api.nvim_win_is_valid(M._tooltip_win) then
    pcall(vim.api.nvim_win_close, M._tooltip_win, true)
  end
  M._tooltip_win = nil
  M._tooltip_buf = nil
end

local function open_tooltip(lines)
  if #lines == 0 then lines = { "(empty commit message)" } end
  local width = 0
  for _, l in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(l)) end
  width = math.max(1, math.min(width + 2, 80))
  local height = math.max(1, math.min(#lines, math.floor(vim.o.lines * 0.6)))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local ok, win = pcall(vim.api.nvim_open_win, buf, true, {
    relative = "editor", width = width, height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal", border = "rounded", title = " Commit ", title_pos = "center",
  })
  if not ok then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    return
  end
  M._tooltip_win, M._tooltip_buf = win, buf
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, close_tooltip, { buffer = buf, nowait = true, silent = true, desc = "Close tooltip (diff)" })
  end
  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf, once = true,
    callback = function()
      vim.schedule(function() if M._tooltip_buf == buf then close_tooltip() end end)
    end,
  })
end

local function show_commit_tooltip(hash)
  close_tooltip()
  local d = S.details[hash]
  if d then
    open_tooltip(vim.deepcopy(d.body))
    return
  end
  M._tooltip_req_id = M._tooltip_req_id + 1
  local req = M._tooltip_req_id
  git.run({ "show", "--no-patch", "--format=%B", hash }, S.root, function(lines, stderr, code)
    if req ~= M._tooltip_req_id then return end
    if code ~= 0 then
      log.warn("cannot read message of %s: %s", hash, stderr)
      vim.notify("diff.nvim: " .. (stderr ~= "" and stderr or "cannot fetch commit message"), vim.log.levels.WARN)
      return
    end
    open_tooltip(lines)
  end)
end

-- ---------------------------------------------------------------------------
-- Navigation (]f / [f in the diff view)
-- ---------------------------------------------------------------------------

local function to_source(hash, f)
  return { kind = "commit", hash = hash, path = f.path, old_path = f.old_path, status = f.status }
end

function M.navigator(source, dir)
  local d = S.details[source.hash]
  if not d then return nil end
  local files = {}
  local function walk(node)
    for _, child in ipairs(util.sort_tree_children(node.children)) do
      if child.file then table.insert(files, child.file) else walk(child) end
    end
  end
  walk(util.build_file_tree(d.files))
  for i, f in ipairs(files) do
    if f.path == source.path then
      return files[i + dir] and to_source(source.hash, files[i + dir]) or nil
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

local function toggle_commit(commit)
  local hash = commit.hash
  if S.expanded[hash] then
    S.expanded[hash] = nil
    M.render()
    return
  end
  S.expanded[hash] = true
  if S.details[hash] then
    M.render()
    return
  end
  if S.loading[hash] then return end
  S.loading[hash] = true
  local elapsed = require("diff.log").timer()
  git.get_commit_details(S.root, hash, function(details, err)
    S.loading[hash] = nil
    if not details then
      S.expanded[hash] = nil
      log.warn("cannot read commit %s: %s", hash, err or "?")
      vim.notify("diff.nvim: " .. (err or "cannot read commit"), vim.log.levels.WARN)
      return
    end
    S.details[hash] = details
    log.debug("details for %s: %d files in %.1f ms", hash:sub(1, 7), #details.files, elapsed())
    M.render()
  end)
end

function M.activate_line(lnr)
  local meta = S.line_map[lnr]
  if not meta then return end
  if meta.type == "commit" or meta.type == "commit_body" then
    toggle_commit(meta.commit)
  elseif meta.type == "commit_file" then
    require("diff.diff_view").open(S.root, to_source(meta.commit.hash, meta.file), M.navigator)
  end
end

function M.mark_active(data)
  data = data or {}
  S.active = data.kind == "commit" and file_key(data.hash, data.path) or nil
  apply_active()
end

--- Rows that carry no information of their own: the metadata line (it
--- highlights together with the subject above) and blank spacers.
local function skippable(lnr)
  local meta = S.line_map[lnr]
  return meta and (meta.meta_line or meta.blank) or false
end

--- Point the panel at another work tree (a linked worktree), dropping the data
--- of the previous one.
function M.set_root(root)
  S.gen = S.gen + 1
  S.root, S.ref = root, nil
  S.commits, S.expanded, S.details, S.loading, S.active = nil, {}, {}, {}, nil
end

function M.setup(buf, win, repo_root)
  local keep = S
  S = fresh_state()
  S.buf, S.win, S.root = buf, win, repo_root
  if keep.root == repo_root then
    S.commits, S.expanded, S.details, S.active, S.ref = keep.commits, keep.expanded, keep.details, keep.active, keep.ref
  end
  close_tooltip()

  -- The two-line commit highlight replaces 'cursorline'.
  pcall(vim.api.nvim_set_option_value, "cursorline", false, { win = win })
  local aug = vim.api.nvim_create_augroup("DiffNvimCommitCursor", { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "BufEnter" }, {
    group = aug, buffer = buf, callback = highlight_cursor_commit,
  })

  local km = require("diff.config").get().keymaps or {}
  local function map(key, fn, desc, extra)
    if not key or key == "" then return end
    vim.keymap.set("n", key, fn, vim.tbl_extend("force",
      { buffer = buf, nowait = true, silent = true, desc = desc .. " (diff)" }, extra or {}))
  end

  map(km.open_diff, function()
    if valid() then M.activate_line(vim.api.nvim_win_get_cursor(S.win)[1]) end
  end, "Expand commit / open file diff")

  for key, dir in pairs({ j = 1, k = -1, ["<Down>"] = 1, ["<Up>"] = -1 }) do
    map(key, function()
      local row = vim.api.nvim_win_get_cursor(0)[1]
      local last = vim.api.nvim_buf_line_count(buf)
      local start = row
      for _ = 1, vim.v.count1 do
        local t = row + dir
        while t >= 1 and t <= last and skippable(t) do t = t + dir end
        if t < 1 or t > last then break end
        row = t
      end
      if row == start then return "" end
      return string.format("<Cmd>normal! %d%s<CR>", math.abs(row - start), dir > 0 and "j" or "k")
    end, "Move, skip meta/blank rows", { expr = true })
  end

  map(km.commit_tooltip, function()
    local meta = S.line_map[vim.api.nvim_win_get_cursor(0)[1]]
    if meta and meta.commit then show_commit_tooltip(meta.commit.hash) end
  end, "Show full commit message")

  map("q", function() require("diff.sidebar").close() end, "Close")

  if S.commits then M.render() end
end

--- Fetch the commit list and re-render.
--- @param ref string|nil  Branch to read history from (preview mode); nil = HEAD.
--- @param on_done fun()|nil  called once the refresh has finished (or been
---   superseded by a newer one)
function M.refresh(ref, on_done)
  S.gen = S.gen + 1
  local gen = S.gen
  if ref ~= S.ref then
    S.expanded, S.ref = {}, ref
  end
  git.get_commits(S.root, COMMIT_LIMIT, function(commits, err)
    if on_done then on_done() end
    if gen ~= S.gen then return end
    if err then
      log.warn("git log failed: %s", err)
      vim.notify("diff.nvim: commits error: " .. err, vim.log.levels.WARN)
    end
    S.commits = commits or {}
    M.render()
  end, ref)
end

M.close_tooltip = close_tooltip

return M
