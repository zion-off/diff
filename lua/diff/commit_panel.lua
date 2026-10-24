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
local chrome = require("diff.chrome")

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
    header_pair = {}, -- lnr -> { l1, l2 }: both header rows, for either of them
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

-- ---------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------

-- The disclosure marker leading each commit, as the file panel's sections.
local CHEVRON = { open = "▾ ", closed = "▸ " }

--- A commit is two rows: the subject, which is what the reader scans for,
--- given all the width the marker leaves; and under it, dimmed, the hash,
--- author and age, then whichever refs fit. Expanded, its changed files
--- follow as a tree with the file panel's columns, closed by a blank row.
--- The message stays in the tooltip (K): inline it pushed the files a
--- screen away and repeated the subject.
local function build(width)
  local lines, hl, map, pairs_ = {}, {}, {}, {}

  local function push(line, meta)
    table.insert(lines, line)
    map[#lines] = meta
    return #lines - 1
  end

  for _, commit in ipairs(S.commits or {}) do
    local d = S.expanded[commit.hash] and S.details[commit.hash]
    local hash_str = commit.short_hash or commit.hash:sub(1, 7)

    local chevron = d and CHEVRON.open or CHEVRON.closed
    local line1 = chevron .. util.trunc(commit.subject or "", math.max(8, width - vim.api.nvim_strwidth(chevron)))
    local r1 = push(line1, { type = "commit", key = "commit:" .. commit.hash, commit = commit })
    table.insert(hl, { r1, "DiffNvimCommitMeta", 0, #chevron })
    table.insert(hl, { r1, "DiffNvimCommitSubject", #chevron, #line1 })

    local meta = META_INDENT .. hash_str
    local hash_end = #meta
    local author = util.trunc(commit.author or "", math.max(8, math.floor(width / 3)))
    if author ~= "" then meta = meta .. " · " .. author end
    if (commit.time or "") ~= "" then meta = meta .. " · " .. commit.time end
    local meta_end = #meta
    local pills = {}
    for _, ref in ipairs(commit.refs or {}) do
      local pill = " [" .. ref .. "]"
      if vim.api.nvim_strwidth(meta .. pill) <= width then
        table.insert(pills, { #meta, #meta + #pill, ref_hl(ref) })
        meta = meta .. pill
      end
    end
    local r2 = push(meta, { type = "commit", meta_line = true, commit = commit })
    table.insert(hl, { r2, "DiffNvimCommitHash", #META_INDENT, hash_end })
    table.insert(hl, { r2, "DiffNvimCommitMeta", hash_end, meta_end })
    for _, p in ipairs(pills) do table.insert(hl, { r2, p[3], p[1], p[2] }) end
    local pair = { r1 + 1, r2 + 1 }
    pairs_[r1 + 1], pairs_[r2 + 1] = pair, pair

    if d then
      local stat_w = 0
      for _, f in ipairs(d.files) do stat_w = math.max(stat_w, #(util.diffstat(f.stat))) end
      stat_w = math.min(stat_w, math.max(0, width - 16))

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
        local stat, add_range, del_range = util.diffstat(f.stat)
        local line, cols = util.file_row(width, META_INDENT .. string.rep("  ", depth), node.name, stat, stat_w,
          util.STATUS_BADGE[f.status] or "·")
        local r = push(line, { type = "commit_file", key = file_key(commit.hash, f.path), commit = commit, file = f })
        table.insert(hl, { r, "DiffNvimCommitFileEntry", cols.name[1], cols.name[2] })
        table.insert(hl, { r, util.STATUS_HL[f.status] or "DiffNvimStatusUntracked", cols.badge[1], cols.badge[2] })
        if cols.stat then
          local base = cols.stat[1]
          if add_range then table.insert(hl, { r, "DiffNvimStatAdded", base + add_range[1], base + add_range[2] }) end
          if del_range then table.insert(hl, { r, "DiffNvimStatRemoved", base + del_range[1], base + del_range[2] }) end
        end
      end
      for _, child in ipairs(util.sort_tree_children(util.build_file_tree(d.files).children)) do
        render_node(child, 0)
      end
      if #d.files == 0 then
        local r = push(META_INDENT .. "No files changed", { type = "commit_dir", commit = commit })
        table.insert(hl, { r, "DiffNvimCommitMeta", 0, -1 })
      end
      push("", { type = "blank", blank = true, commit = commit })
    end
  end

  if #lines == 0 then push("  (no commits)", { type = "empty" }) end
  return lines, hl, map, pairs_
end

--- Mark both rows of the commit under the cursor, as one item — but only
--- while the panel has focus: like the cursor line it extends, it answers
--- "what does <CR> act on here", which an unfocused panel is not asked.
local function highlight_cursor_commit()
  if not valid() then return end
  vim.api.nvim_buf_clear_namespace(S.buf, CURSOR_NS, 0, -1)
  if vim.api.nvim_get_current_win() ~= S.win then return end
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

--- Lay the commit out as a card: who and when at the top, a rule, then the
--- message. The panel row already shows the subject, so a tooltip that shows
--- only the subject again tells the reader nothing.
local function tooltip_lines(commit, body)
  local lines, hl = {}, {}
  local hash = commit.short_hash or commit.hash:sub(1, 7)
  local head = hash
  if (commit.author or "") ~= "" then head = head .. "  " .. commit.author end
  if (commit.time or "") ~= "" then head = head .. "  ·  " .. commit.time end
  table.insert(lines, head)
  table.insert(hl, { 0, "DiffNvimCommitHash", 0, #hash })
  table.insert(hl, { 0, "DiffNvimCommitMeta", #hash, -1 })

  local refs = {}
  for _, ref in ipairs(commit.refs or {}) do table.insert(refs, ref) end
  if #refs > 0 then
    local line, spans = "", {}
    for _, ref in ipairs(refs) do
      local pill = (line == "" and "" or " ") .. "[" .. ref .. "]"
      table.insert(spans, { #line + (line == "" and 0 or 1), #line + #pill, ref_hl(ref) })
      line = line .. pill
    end
    table.insert(lines, line)
    for _, s in ipairs(spans) do table.insert(hl, { #lines - 1, s[3], s[1], s[2] }) end
  end

  table.insert(lines, "")
  local first_body = #lines
  local empty = true
  for i, raw in ipairs(body or {}) do
    table.insert(lines, raw)
    if raw ~= "" then
      empty = false
      table.insert(hl, { #lines - 1, i == 1 and "DiffNvimCommitSubject" or "DiffNvimCommitBody", 0, -1 })
    end
  end
  if empty then
    table.insert(lines, "(empty commit message)")
    table.insert(hl, { #lines - 1, "DiffNvimCommitMeta", 0, -1 })
  end
  -- Trailing blanks from `git show` would show as dead rows inside the border.
  while #lines > first_body and lines[#lines] == "" do table.remove(lines) end
  return lines, hl
end

local TOOLTIP_NS = vim.api.nvim_create_namespace("diff_nvim_commit_tooltip")

local function open_tooltip(commit, body)
  local lines, hl = tooltip_lines(commit, body)
  local width = 0
  for _, l in ipairs(lines) do width = math.max(width, vim.api.nvim_strwidth(l)) end
  width = math.max(30, math.min(width + 2, math.min(80, vim.o.columns - 4)))
  local height = math.max(1, math.min(#lines, math.floor(vim.o.lines * 0.6)))

  local buf = vim.api.nvim_create_buf(false, true)
  chrome.tag(buf, "commit-tooltip")
  chrome.name(buf, "diff.nvim Commit " .. (commit.short_hash or commit.hash:sub(1, 7)))
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  for _, h in ipairs(hl) do
    pcall(vim.api.nvim_buf_add_highlight, buf, TOOLTIP_NS, h[2], h[1], h[3], h[4])
  end

  -- Anchored to the row it describes, like a tooltip, rather than dropped in
  -- the middle of the screen with no connection to what was asked about.
  local cfg = {
    relative = "cursor", width = width, height = height, row = 1, col = 0,
    style = "minimal", border = "rounded", title = " Commit ", title_pos = "center",
  }
  local ok, win = pcall(vim.api.nvim_open_win, buf, true, cfg)
  if not ok then
    cfg.relative, cfg.row, cfg.col = "editor",
      math.max(0, math.floor((vim.o.lines - height) / 2)),
      math.max(0, math.floor((vim.o.columns - width) / 2))
    ok, win = pcall(vim.api.nvim_open_win, buf, true, cfg)
  end
  if not ok then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    return
  end
  M._tooltip_win, M._tooltip_buf = win, buf
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  pcall(vim.api.nvim_set_option_value, "winhighlight",
    "NormalFloat:DiffNvimPickerNormal,FloatBorder:DiffNvimPickerBorder,FloatTitle:DiffNvimPickerTitle",
    { win = win })

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

local function show_commit_tooltip(commit)
  close_tooltip()
  local d = S.details[commit.hash]
  if d then
    open_tooltip(commit, vim.deepcopy(d.body))
    return
  end
  M._tooltip_req_id = M._tooltip_req_id + 1
  local req = M._tooltip_req_id
  git.run({ "show", "--no-patch", "--format=%B", commit.hash }, S.root, function(lines, stderr, code)
    if req ~= M._tooltip_req_id then return end
    if code ~= 0 then
      log.warn("cannot read message of %s: %s", commit.hash, stderr)
      vim.notify("diff.nvim: " .. (stderr ~= "" and stderr or "cannot fetch commit message"), vim.log.levels.WARN)
      return
    end
    open_tooltip(commit, lines)
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
  if meta.type == "commit" then
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
--- highlights together with the subject above) and the blank row closing an
--- expanded commit.
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
  vim.api.nvim_create_autocmd({ "CursorMoved", "BufEnter", "WinEnter" }, {
    group = aug, buffer = buf, callback = highlight_cursor_commit,
  })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = aug, buffer = buf,
    callback = function()
      if S.buf and vim.api.nvim_buf_is_valid(S.buf) then vim.api.nvim_buf_clear_namespace(S.buf, CURSOR_NS, 0, -1) end
    end,
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
    if meta and meta.commit then show_commit_tooltip(meta.commit) end
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
