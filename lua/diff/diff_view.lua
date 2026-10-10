--- diff.nvim — side-by-side diff view.
---
--- The view owns a header window and one or two pane windows inside the
--- interface's main area. Those windows and their buffers live for as long as
--- the view is open: opening another file, expanding context or a live refresh
--- only replaces buffer content, so the layout never reflows and focus never
--- jumps.
---
--- State flows one way: content.load -> diff_engine.compute (model) ->
--- diff_engine.layout (items) -> render. Keymaps read the current state, so
--- they are installed once per buffer.
local M = {}

local config  = require("diff.config")
local log     = require("diff.log").scope("view")
local git     = require("diff.git")
local content = require("diff.content")
local engine  = require("diff.diff_engine")
local syntax  = require("diff.syntax")
local word_diff = require("diff.word_diff")

local NS       = vim.api.nvim_create_namespace("diff_nvim_diff")
local NS_WORDS = vim.api.nvim_create_namespace("diff_nvim_words")
local NS_NOTES = vim.api.nvim_create_namespace("diff_nvim_notes_markers")
local NS_HEAD  = vim.api.nvim_create_namespace("diff_nvim_header")
local NS_WRAP  = vim.api.nvim_create_namespace("diff_nvim_wrap")

-- Highlight priorities relative to tree-sitter's 100.
local PRIORITY_LINE_BG   = 50   -- below syntax so colours show through
local PRIORITY_NOTE_SIGN = 70
local PRIORITY_WORD_HL   = 150  -- above syntax so changed tokens stand out

local EXPAND_STEP = 10
local WATCH_DEBOUNCE_MS = 150

local SIDES = { "old", "new" }

-- Aligning wrapped split panes needs per-line screen heights (Neovim 0.10+).
local CAN_ALIGN_WRAP = vim.api.nvim_win_text_height ~= nil
-- Split panes narrower than this scroll horizontally instead: wrapping into a
-- sliver is unreadable, and measuring lines that wrap dozens of times is slow.
local MIN_WRAP_WIDTH = 20

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local function fresh_state()
  return {
    header_win = nil, header_buf = nil,
    extra_win  = nil,           -- second pane (old side) in split mode
    bufs  = {},                 -- side -> pane buffer (persist while open)
    panes = {},                 -- side -> window currently showing that side
    root = nil, source = nil, navigator = nil,
    model = nil, layout = nil, ctx = nil, reveals = {},
    sources = {},               -- side -> syntax Source
    words = {},                 -- model row -> word ranges (lazy)
    lnum_width = 1,
    wrap_widths = {},           -- side -> pane width the wrap padding was computed for
    watcher = nil, watch_timer = nil,
    -- open_gen counts opens, refresh_gen counts in-place refreshes. They are
    -- separate so a background refresh (watcher, index change) can never
    -- cancel an open the user asked for, while an open always supersedes a
    -- refresh still in flight.
    open_gen = 0, refresh_gen = 0,
    opening = false,
  }
end

local S = fresh_state()

local function valid_win(w) return w ~= nil and vim.api.nvim_win_is_valid(w) end
local function valid_buf(b) return b ~= nil and vim.api.nvim_buf_is_valid(b) end

local function sidebar() return require("diff.sidebar") end

local function notify(msg, level)
  vim.notify("diff.nvim: " .. msg, level or vim.log.levels.INFO)
end

--- Side shown in `buf`, or nil when it is not one of our panes.
local function side_of_buf(buf)
  if buf == S.bufs.old then return "old" end
  if buf == S.bufs.new then return "new" end
end

local function side_of_win(win)
  if win == S.panes.old then return "old" end
  if win == S.panes.new then return "new" end
end

local function item_at(idx)
  return S.layout and S.layout.items[idx] or nil
end

local function row_of_item(item)
  return item and item.row and S.model.rows[item.row] or nil
end

local function fire_view_changed()
  local src = S.source
  local data = src and { kind = src.kind, path = src.path, staged = src.staged, hash = src.hash } or {}
  vim.api.nvim_exec_autocmds("User", { pattern = "DiffNvimViewChanged", data = data, modeline = false })
end

-- ---------------------------------------------------------------------------
-- Live file watcher (unstaged working-tree files)
-- ---------------------------------------------------------------------------

local function stop_watcher()
  if S.watch_timer then
    pcall(function() S.watch_timer:stop() S.watch_timer:close() end)
    S.watch_timer = nil
  end
  if S.watcher then
    pcall(function() S.watcher:stop() S.watcher:close() end)
    S.watcher = nil
  end
end

--- Watch the file's directory rather than the file. Editors save atomically
--- (write a temp file, rename it over the original), which replaces the inode;
--- a watch on the file itself goes silent after the first such save, while a
--- directory watch keeps reporting the new file under the same name.
local function start_watcher(abs_path)
  stop_watcher()
  local uv = vim.uv or vim.loop
  local dir, name = vim.fn.fnamemodify(abs_path, ":h"), vim.fn.fnamemodify(abs_path, ":t")
  local ok, handle = pcall(uv.new_fs_event)
  if not ok or not handle then return end
  local timer = uv.new_timer()
  local started = handle:start(dir, {}, function(err, fname)
    if err or fname ~= name then return end
    timer:stop()
    timer:start(WATCH_DEBOUNCE_MS, 0, vim.schedule_wrap(function()
      log.debug("file changed on disk: %s", abs_path)
      M.refresh_content()
    end))
  end)
  if started then
    S.watcher, S.watch_timer = handle, timer
    log.debug("watching %s", abs_path)
  else
    log.warn("cannot watch %s", dir)
    pcall(function() handle:close() timer:close() end)
  end
end

-- ---------------------------------------------------------------------------
-- Windows and buffers
-- ---------------------------------------------------------------------------

local function set_opts(win, opts)
  for k, v in pairs(opts) do
    pcall(vim.api.nvim_set_option_value, k, v, { win = win })
  end
end

local STATUSCOL = "%s%#LineNr#%{v:lua.require'diff.diff_view'.statuscol()} "

--- Whether panes soft-wrap. Split panes wrap only when their rows can be
--- kept aligned; otherwise scrollbind would drift apart.
local warned_no_align = false
local function wraps(split)
  if not config.get().wrap then return false end
  if split and not CAN_ALIGN_WRAP then
    if not warned_no_align then
      log.warn("wrap needs Neovim 0.10+ in a split diff; lines stay unwrapped")
      warned_no_align = true
    end
    return false
  end
  return true
end

local function set_wrap(win, wrap)
  set_opts(win, { wrap = wrap, linebreak = wrap, breakindent = wrap })
end

local function pane_opts(win, bound)
  set_wrap(win, wraps(bound))
  set_opts(win, {
    number         = true,
    relativenumber = false,
    statuscolumn   = STATUSCOL,
    foldcolumn     = "0",
    signcolumn     = "yes:1",
    cursorline     = true,
    list           = false,
    winbar         = "",
    scrollbind     = bound,
    cursorbind     = bound,
    diff           = false,
  })
end

local function header_opts(win)
  set_opts(win, {
    number = false, relativenumber = false, statuscolumn = "", wrap = false,
    foldcolumn = "0", signcolumn = "no", cursorline = false, list = false,
    winfixheight = true, winbar = "",
    winhighlight = "Normal:DiffNvimHeader,NormalNC:DiffNvimHeader,EndOfLine:DiffNvimHeader",
    -- With 'laststatus' 1/2 the header gets its own status line; draw it as a
    -- thin rule under the filename instead of a "[Scratch]" bar.
    statusline = "%#DiffNvimHeaderRule#%=",
    fillchars = "stl:─,stlnc:─",
  })
end

local function scratch_buf(bufhidden)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype    = "nofile"
  vim.bo[buf].bufhidden  = bufhidden
  vim.bo[buf].swapfile   = false
  vim.bo[buf].undolevels = -1
  vim.bo[buf].modifiable = false
  return buf
end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local setup_keymaps -- defined below; installed once per pane buffer

local function pane_buf(side)
  if not valid_buf(S.bufs[side]) then
    S.bufs[side] = scratch_buf("hide")
    setup_keymaps(S.bufs[side], side)
  end
  return S.bufs[side]
end

--- The window the primary pane lives in: the interface's main area, or the
--- widest window that is not a sidebar panel.
local function host_window()
  local main = sidebar().get_main_win()
  if valid_win(main) then return main end
  local best, best_w
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
    local w = vim.api.nvim_win_get_width(win)
    if win ~= S.header_win and not name:match("^diff://file") and not name:match("^diff://commit")
      and (not best_w or w > best_w) then
      best, best_w = win, w
    end
  end
  return best
end

--- Split a new window off `anchor` with `cmd`; nil when there is no room
--- (E36), which callers treat as "degrade", never as a fatal error.
local function split_from(anchor, cmd)
  local prev = vim.api.nvim_get_current_win()
  if not pcall(vim.api.nvim_set_current_win, anchor) then return nil end
  local ok = pcall(vim.cmd, cmd)
  local win = vim.api.nvim_get_current_win()
  pcall(vim.api.nvim_set_current_win, prev)
  if not ok or win == anchor then return nil end
  return win
end

--- Arrange header + panes for `mode` ("split", "new" or "old"), reusing
--- every window that already exists. Returns the mode actually achieved.
local function ensure_layout(mode)
  local host = host_window()
  if not host then return nil end

  if not valid_win(S.header_win) then
    S.header_win = split_from(host, "aboveleft 1split")
    if S.header_win then
      S.header_buf = valid_buf(S.header_buf) and S.header_buf or scratch_buf("hide")
      vim.api.nvim_win_set_buf(S.header_win, S.header_buf)
      header_opts(S.header_win)
      pcall(vim.api.nvim_win_set_height, S.header_win, 1)
    end
  end

  local primary = mode == "old" and "old" or "new"
  S.panes = { [primary] = host }
  if vim.api.nvim_win_get_buf(host) ~= pane_buf(primary) then
    vim.api.nvim_win_set_buf(host, pane_buf(primary))
  end

  if mode == "split" then
    if not valid_win(S.extra_win) then
      S.extra_win = split_from(host, "leftabove vsplit")
    end
    if S.extra_win then
      if vim.api.nvim_win_get_buf(S.extra_win) ~= pane_buf("old") then
        vim.api.nvim_win_set_buf(S.extra_win, pane_buf("old"))
      end
      S.panes.old = S.extra_win
    else
      log.warn("no room for a split diff; showing the new side only")
      notify("not enough width for a split diff — showing the new side only", vim.log.levels.WARN)
      mode = "new"
    end
  elseif valid_win(S.extra_win) then
    pcall(vim.api.nvim_win_close, S.extra_win, true)
    S.extra_win = nil
  end

  for _, win in pairs(S.panes) do pane_opts(win, mode == "split") end
  return mode
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

local function separator_virt(side, sep)
  local span = engine.separator_span(S.model, sep)
  local virt = { { string.format("··· %d hidden lines ···", span.count), "DiffNvimSeparator" } }
  local src = S.sources[side]
  local heading = src and span[side][2] and src:enclosing_decl(span[side][2])
  if heading then table.insert(virt, { "  " .. heading, "DiffNvimSeparatorDecl" }) end
  return virt
end

local FILLER = string.rep("░", 400)

--- Persistent per-row decorations: line backgrounds, gutter signs, fillers and
--- separators. Word and syntax highlights are drawn lazily per visible row.
local function decorate(side)
  local buf = S.bufs[side]
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  local change_hl = side == "old" and "DiffNvimRemoved" or "DiffNvimAdded"
  local sign_hl   = side == "old" and "DiffNvimGutterRemoved" or "DiffNvimGutterAdded"

  for i, item in ipairs(S.layout.items) do
    local r = i - 1
    if item.sep then
      vim.api.nvim_buf_set_extmark(buf, NS, r, 0, {
        line_hl_group = "DiffNvimSeparator",
        virt_text = separator_virt(side, item.sep), virt_text_pos = "overlay",
        priority = PRIORITY_LINE_BG,
      })
    else
      local row = S.model.rows[item.row]
      if not row[side] then
        vim.api.nvim_buf_set_extmark(buf, NS, r, 0, {
          line_hl_group = "DiffNvimFiller",
          virt_text = { { FILLER, "DiffNvimFillerChar" } }, virt_text_pos = "overlay",
          priority = PRIORITY_LINE_BG,
        })
      elseif row.change then
        vim.api.nvim_buf_set_extmark(buf, NS, r, 0, {
          line_hl_group = change_hl, sign_text = "▍", sign_hl_group = sign_hl,
          priority = PRIORITY_LINE_BG,
        })
      end
    end
  end
end

local function decorate_notes(side)
  local buf = S.bufs[side]
  vim.api.nvim_buf_clear_namespace(buf, NS_NOTES, 0, -1)
  local notes = require("diff.annotations").notes_for(S.root, S.source.path)
  if #notes == 0 then return end
  local row_of_line = {}
  for i, item in ipairs(S.layout.items) do
    local row = row_of_item(item)
    if row and row[side] then row_of_line[row[side]] = i - 1 end
  end
  for _, note in ipairs(notes) do
    local r = (not note.side or note.side == side) and row_of_line[note.line_start]
    if r then
      local preview = note.text:sub(1, 40) .. (#note.text > 40 and "…" or "")
      vim.api.nvim_buf_set_extmark(buf, NS_NOTES, r, 0, {
        sign_text = "▸", sign_hl_group = "DiffNvimNoteMarker",
        virt_text = { { "  " .. preview, "DiffNvimNoteVirtText" } }, virt_text_pos = "eol",
        priority = PRIORITY_NOTE_SIGN,
      })
    end
  end
end

local function render_header()
  if not (valid_buf(S.header_buf) and S.source) then return end
  local src, m = S.source, S.model
  local text = "  " .. src.path
  if src.old_path and src.old_path ~= src.path then text = "  " .. src.old_path .. " → " .. src.path end
  if src.kind == "commit" then text = text .. "  @ " .. src.hash:sub(1, 7) end
  if src.status == "added" or src.status == "untracked" then text = text .. "  (new file)" end
  if src.status == "deleted" then text = text .. "  (deleted)" end
  if src.binary then text = text .. "  (binary)" end

  local spans = {}
  if m then
    if m.old.eol ~= m.new.eol then text = text .. "  (newline at end of file changed)" end
    local add, del = "+" .. m.added, "-" .. m.removed
    table.insert(spans, { #text + 2, #text + 2 + #add, "DiffNvimStatAdded" })
    table.insert(spans, { #text + 3 + #add, #text + 3 + #add + #del, "DiffNvimStatRemoved" })
    text = text .. "  " .. add .. " " .. del
  end
  set_lines(S.header_buf, { text })
  vim.api.nvim_buf_clear_namespace(S.header_buf, NS_HEAD, 0, -1)
  for _, s in ipairs(spans) do
    pcall(vim.api.nvim_buf_set_extmark, S.header_buf, NS_HEAD, 0, s[1], { end_col = s[2], hl_group = s[3] })
  end
end

--- Pad item row `r` of `side` with inline virtual text so it wraps onto
--- exactly `target` screen lines. Measuring rather than computing the length
--- keeps 'linebreak', 'breakindent' and 'showbreak' exact; the largest pad
--- that still fits is used so the band fills the row's last screen line.
local function pad_to_height(side, r, row, target, width)
  local win, buf = S.panes[side], S.bufs[side]
  local line = row[side] and S.model[side].lines[row[side]] or ""
  -- Fillers draw their pattern; text rows rely on the row's line background.
  local char, hl = " ", nil
  if not row[side] then char, hl = "░", "DiffNvimFillerChar" end
  local id
  local function height_with(n)
    id = vim.api.nvim_buf_set_extmark(buf, NS_WRAP, r, #line, {
      id = id, virt_text = { { string.rep(char, n), hl } }, virt_text_pos = "inline",
    })
    return vim.api.nvim_win_text_height(win, { start_row = r, end_row = r }).all
  end
  -- A screen line holds at most `width` cells, so `hi` always overflows.
  local lo, hi = 0, width * (target + 1)
  while hi - lo > 1 do
    local mid = math.floor((lo + hi) / 2)
    if height_with(mid) <= target then lo = mid else hi = mid end
  end
  height_with(lo)
end

--- Keep wrapped split panes row-aligned. 'scrollbind' pairs buffer lines, so
--- both sides of a row must wrap onto the same number of screen lines: the
--- shorter side is padded to the taller one's height. Padding inside the line
--- (rather than virtual lines below it) leaves no filler lines for 'scrollbind'
--- to step through at different rates.
local function align_wrapped()
  for _, side in ipairs(SIDES) do
    if valid_buf(S.bufs[side]) then vim.api.nvim_buf_clear_namespace(S.bufs[side], NS_WRAP, 0, -1) end
  end
  S.wrap_widths = {}
  local wins = S.panes
  if not (S.layout and valid_win(wins.old) and valid_win(wins.new) and wraps(true)) then return end

  local elapsed = require("diff.log").timer()
  -- 'statuscolumn' width (and so the text width) is only settled by a redraw.
  vim.cmd("redraw")
  local text_width = {}
  for _, side in ipairs(SIDES) do
    local info = vim.fn.getwininfo(wins[side])[1]
    text_width[side] = math.max(1, info.width - info.textoff)
    S.wrap_widths[side] = info.width
  end
  local room = math.min(text_width.old, text_width.new) >= MIN_WRAP_WIDTH
  for _, side in ipairs(SIDES) do set_wrap(wins[side], room) end
  if not room then
    log.debug("panes too narrow to wrap (%d/%d columns); scrolling horizontally", text_width.old, text_width.new)
    return
  end

  local m, padded = S.model, 0
  for i, item in ipairs(S.layout.items) do
    local row = row_of_item(item)
    if row then
      local height = {}
      for _, side in ipairs(SIDES) do
        local line = row[side] and m[side].lines[row[side]] or ""
        -- Bytes never undercount display cells except for tabs, so a short
        -- tab-free line cannot wrap and needs no measuring.
        if #line <= text_width[side] and not line:find("\t", 1, true) then
          height[side] = 1
        else
          height[side] = vim.api.nvim_win_text_height(wins[side], { start_row = i - 1, end_row = i - 1 }).all
        end
      end
      if height.old ~= height.new then
        local short = height.old < height.new and "old" or "new"
        pad_to_height(short, i - 1, row, math.max(height.old, height.new), text_width[short])
        padded = padded + 1
      end
    end
  end
  log.debug("wrap alignment %s: %d rows padded at widths %d/%d in %.1f ms",
    S.source.path, padded, text_width.old, text_width.new, elapsed())
end

--- Bind each visible pane to its syntax source.
local function bind_syntax()
  for _, side in ipairs(SIDES) do
    local buf, src = S.bufs[side], S.sources[side]
    if S.panes[side] and src then
      syntax.bind(buf, src, function(row0)
        local row = row_of_item(item_at(row0 + 1))
        local line = row and row[side]
        return line and line - 1 or nil
      end)
    elseif valid_buf(buf) then
      syntax.unbind(buf)
    end
  end
end

--- Item index for an anchor, evaluated against the current layout.
---   { side, line }        the row showing that line (or the gap hiding it)
---   { sep_from = line }   the separator whose span starts at new-side `line`
---   { block = i }         first row of block i
local function resolve_anchor(anchor)
  if not anchor then return 1 end
  local items = S.layout.items
  if anchor.block then
    local blk = S.model.blocks[anchor.block]
    return blk and S.layout.index_of[blk.first] or 1
  end
  if anchor.sep_from then
    for i, item in ipairs(items) do
      if item.sep and S.model.rows[item.sep.first].new == anchor.sep_from then return i end
    end
    return resolve_anchor(anchor.fallback)
  end
  local target
  for r, row in ipairs(S.model.rows) do
    if row[anchor.side] == anchor.line then target = r break end
  end
  if not target then
    -- The line no longer exists (content shrank): nearest row on that side.
    local best, best_d = 1, math.huge
    for r, row in ipairs(S.model.rows) do
      local l = row[anchor.side]
      if l and math.abs(l - anchor.line) < best_d then best, best_d = r, math.abs(l - anchor.line) end
    end
    target = best
  end
  if S.layout.index_of[target] then return S.layout.index_of[target] end
  for i, item in ipairs(items) do
    if item.sep and target >= item.sep.first and target <= item.sep.last then return i end
  end
  return 1
end

--- Describe what is under the cursor of `win` so it can be found again after
--- the layout changes, plus its screen offset from the top of the window.
local function capture_anchor(win)
  win = valid_win(win) and win or S.panes.new or S.panes.old
  if not (valid_win(win) and S.layout) then return nil, nil end
  local side = side_of_win(win) or "new"
  local idx = vim.api.nvim_win_get_cursor(win)[1]
  local offset = idx - vim.fn.getwininfo(win)[1].topline
  local item = item_at(idx)
  if not item then return nil, offset end
  if item.sep then
    local span = engine.separator_span(S.model, item.sep)
    return { side = "new", line = span.new[1] }, offset
  end
  local row = S.model.rows[item.row]
  if row[side] then return { side = side, line = row[side] }, offset end
  local other = side == "old" and "new" or "old"
  return { side = other, line = row[other] }, offset
end

local function place_cursor(idx, offset)
  idx = math.max(1, math.min(idx, #S.layout.items))
  for _, win in pairs(S.panes) do
    if valid_win(win) then
      local col = vim.api.nvim_win_get_cursor(win)[2]
      pcall(vim.api.nvim_win_set_cursor, win, { idx, col })
      vim.api.nvim_win_call(win, function()
        if offset then
          vim.fn.winrestview({ topline = math.max(1, idx - offset) })
        else
          vim.cmd("normal! zz")
        end
      end)
    end
  end
end

--- Render the current model into the panes and restore the cursor.
--- @param anchor table|nil  see resolve_anchor
--- @param offset integer|nil  screen offset to keep; nil centres the cursor
local function render(anchor, offset)
  local elapsed = require("diff.log").timer()
  local m = S.model
  S.layout = engine.layout(m, S.ctx, S.reveals)

  local text = { old = {}, new = {} }
  for i, item in ipairs(S.layout.items) do
    local row = row_of_item(item)
    for _, side in ipairs(SIDES) do
      text[side][i] = row and row[side] and m[side].lines[row[side]] or ""
    end
  end

  for _, side in ipairs(SIDES) do
    if S.panes[side] then
      set_lines(S.bufs[side], text[side])
      decorate(side)
      decorate_notes(side)
    end
  end
  bind_syntax()
  render_header()
  align_wrapped()
  place_cursor(resolve_anchor(anchor), offset)
  log.debug("render %s: %d rows, %d items in %.1f ms", S.source.path, #m.rows, #S.layout.items, elapsed())
end

-- Word-level highlights, computed on demand for rows that are on screen.
vim.api.nvim_set_decoration_provider(NS_WORDS, {
  on_win = function(_, _, buf)
    return S.layout ~= nil and side_of_buf(buf) ~= nil
  end,
  on_line = function(_, _, buf, r)
    local side = side_of_buf(buf)
    local item = side and item_at(r + 1)
    local row = row_of_item(item)
    if not (row and row.change and row.old and row.new) then return end
    local w = S.words[item.row]
    if not w then
      local ok, o, n = pcall(word_diff.compute, S.model.old.lines[row.old], S.model.new.lines[row.new])
      w = ok and { old = o, new = n } or { old = {}, new = {} }
      S.words[item.row] = w
    end
    local hl = side == "old" and "DiffNvimRemovedWord" or "DiffNvimAddedWord"
    for _, range in ipairs(w[side]) do
      pcall(vim.api.nvim_buf_set_extmark, buf, NS_WORDS, r, range.start_col, {
        end_col = range.end_col, hl_group = hl, priority = PRIORITY_WORD_HL, ephemeral = true,
      })
    end
  end,
})

--- Real file line numbers for the gutter ('statuscolumn'). Pane rows are not
--- file lines: fillers and collapsed context shift every row after them.
--- %{} items are evaluated with the drawn window made current (only %!
--- expressions get g:statusline_winid), so the current window is the pane.
function M.statuscol()
  local side = side_of_win(vim.api.nvim_get_current_win())
  if not side or not S.layout or vim.v.virtnum ~= 0 then return "" end
  local row = row_of_item(item_at(vim.v.lnum))
  local n = row and row[side]
  return string.format("%" .. S.lnum_width .. "s", n and tostring(n) or "")
end

-- ---------------------------------------------------------------------------
-- Opening
-- ---------------------------------------------------------------------------

local function destroy_sources()
  for _, side in ipairs(SIDES) do
    if valid_buf(S.bufs[side]) then syntax.unbind(S.bufs[side]) end
    if S.sources[side] then S.sources[side]:destroy() end
  end
  S.sources = {}
end

local function mode_for(source)
  if source.status == "added" or source.status == "untracked" then return "new" end
  if source.status == "deleted" then return "old" end
  return "split"
end

--- Renaming a buffer makes Neovim keep an unlisted buffer under the old name
--- (as `:file` does, even with :keepalt); wipe it so renames cannot leak.
local function rename_buf(buf, name)
  local old = vim.api.nvim_buf_get_name(buf)
  if old == name then return end
  pcall(vim.api.nvim_buf_set_name, buf, name)
  if old == "" then return end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if b ~= buf and vim.api.nvim_buf_get_name(b) == old and #vim.fn.win_findbuf(b) == 0 then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
end

local function name_buffers()
  local src = S.source
  local tag = src.kind == "commit" and src.hash:sub(1, 7) or (src.staged and "index" or "worktree")
  for _, side in ipairs(SIDES) do
    if valid_buf(S.bufs[side]) then
      rename_buf(S.bufs[side],
        string.format("diff://%s/%s/%s", tag, side, side == "old" and (src.old_path or src.path) or src.path))
    end
  end
end

local function make_sources(old, new)
  destroy_sources()
  local src = S.source
  if S.panes.new then S.sources.new = syntax.source(src.path, new.lines) end
  if S.panes.old then
    local ft = S.sources.new and S.sources.new.ft ~= "" and S.sources.new.ft or nil
    S.sources.old = syntax.source(src.old_path or src.path, old.lines, ft)
  end
  for _, side in ipairs(SIDES) do
    local s = S.sources[side]
    if s then
      -- Separator headings need the parse; redraw them once it lands.
      s:on_ready(function()
        if S.sources[side] == s and S.layout and valid_buf(S.bufs[side]) then decorate(side) end
      end)
    end
  end
end

local function show_binary(root, source, navigator)
  S.root, S.source, S.navigator, S.model, S.layout = root, vim.tbl_extend("force", source, { binary = true }), navigator, nil, nil
  destroy_sources()
  if not ensure_layout("new") then return end
  local buf = S.bufs.new
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, NS_NOTES, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, NS_WRAP, 0, -1)
  set_lines(buf, { "", "  Binary file — no text diff to show." })
  render_header()
  name_buffers()
  stop_watcher()
  fire_view_changed()
end

local function show(root, source, navigator, old, new)
  S.root, S.source, S.navigator = root, source, navigator
  local mode = ensure_layout(mode_for(source))
  if not mode then
    notify("no window available for the diff", vim.log.levels.ERROR)
    return
  end
  S.model   = engine.compute(old, new)
  S.ctx     = config.get().context_lines
  S.reveals = {}
  S.words   = {}
  S.lnum_width = #tostring(math.max(#old.lines, #new.lines, 1))
  name_buffers()
  make_sources(old, new)
  render({ block = 1 })
  for _, side in ipairs(SIDES) do
    if S.sources[side] then S.sources[side]:parse() end
  end

  if source.kind == "worktree" and not source.staged and source.status ~= "deleted" then
    start_watcher(root .. "/" .. source.path)
  else
    stop_watcher()
  end
  pcall(vim.api.nvim_set_current_win, S.panes.new or S.panes.old)
  fire_view_changed()
end

--- Open a diff.
--- @param root      string
--- @param source    table  see content.lua
--- @param navigator fun(source: table, dir: integer): table|nil  supplies ]f / [f targets
function M.open(root, source, navigator)
  S.open_gen = S.open_gen + 1
  S.opening = true
  local gen = S.open_gen
  local elapsed = require("diff.log").timer()
  log.debug("open %s:%s (%s)", source.kind, source.path, source.hash or (source.staged and "staged" or "unstaged"))

  content.load(root, source, function(old, new)
    -- A newer file was requested while this one was loading.
    if gen ~= S.open_gen then
      log.debug("dropping stale load for %s", source.path)
      return
    end
    S.opening = false
    local fetch_ms = elapsed()
    local ok, err = xpcall(function()
      if content.looks_binary(old) or content.looks_binary(new) then
        show_binary(root, source, navigator)
      else
        show(root, source, navigator, old, new)
      end
    end, debug.traceback)
    if not ok then
      log.error("rendering %s failed: %s", source.path, err)
      notify("error rendering diff: " .. tostring(err):match("^[^\n]*"), vim.log.levels.ERROR)
      M.close()
      return
    end
    log.info("opened %s in %.1f ms (load %.1f ms)", source.path, elapsed(), fetch_ms)
  end)
end

--- Re-read both sides and update the panes in place, keeping the cursor on
--- the same line and the window scrolled to the same place. Skips rendering
--- entirely when nothing changed.
function M.refresh_content()
  local source, root = S.source, S.root
  -- An open in flight will load fresh content anyway.
  if not (source and S.model) or S.opening then return end
  S.refresh_gen = S.refresh_gen + 1
  local gen, open_gen = S.refresh_gen, S.open_gen
  content.load(root, source, function(old, new)
    if gen ~= S.refresh_gen or open_gen ~= S.open_gen or S.source ~= source then
      log.debug("dropping superseded refresh of %s", source.path)
      return
    end
    if vim.deep_equal(old, S.model.old) and vim.deep_equal(new, S.model.new) then
      log.trace("refresh %s: unchanged", source.path)
      return
    end
    if content.looks_binary(old) or content.looks_binary(new) then
      show_binary(root, source, S.navigator)
      return
    end
    local focus = vim.api.nvim_get_current_win()
    local anchor, offset = capture_anchor(side_of_win(focus) and focus or nil)
    -- Carry the cursor line and expanded ranges over to the new content.
    if anchor then
      anchor.line = engine.line_mapper(S.model[anchor.side].lines, (anchor.side == "old" and old or new).lines)(anchor.line)
    end
    local map_new = engine.line_mapper(S.model.new.lines, new.lines)
    for _, range in ipairs(S.reveals) do
      range[1], range[2] = map_new(range[1]), map_new(range[2])
    end
    S.model = engine.compute(old, new)
    S.words = {}
    S.lnum_width = #tostring(math.max(#old.lines, #new.lines, 1))
    if S.sources.old then S.sources.old:update(old.lines) end
    if S.sources.new then S.sources.new:update(new.lines) end
    render(anchor, offset)
    log.debug("refreshed %s in place", source.path)
  end)
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

local function current_pane()
  local win = vim.api.nvim_get_current_win()
  if side_of_win(win) then return win, side_of_win(win) end
  local fallback = S.panes.new or S.panes.old
  return fallback, side_of_win(fallback)
end

local function cursor_idx()
  local win = current_pane()
  return valid_win(win) and vim.api.nvim_win_get_cursor(win)[1] or 1
end

--- Expand context. what = "cursor" (separator under the cursor, or the
--- nearest one), "all", or "reset" (back to the configured context).
function M.expand(what)
  if not S.model then return end
  local win = current_pane()
  local anchor, offset = capture_anchor(win)

  if what == "all" then
    S.ctx = nil
  elseif what == "reset" then
    S.ctx, S.reveals = config.get().context_lines, {}
    offset = nil
  else
    local idx, items = cursor_idx(), S.layout.items
    local sep
    for d = 0, #items do
      for _, i in ipairs({ idx + d, idx - d }) do
        if items[i] and items[i].sep then sep = items[i].sep break end
      end
      if sep then break end
    end
    if not sep then return end
    local span = engine.separator_span(S.model, sep)
    S.reveals = engine.reveal(S.model, S.reveals, sep, EXPAND_STEP)
    -- Stay on what remains of this separator so repeated presses keep
    -- expanding it; once fully revealed, land on its first line.
    if items[idx] and items[idx].sep == sep then
      anchor = { sep_from = span.new[1] + EXPAND_STEP, fallback = { side = "new", line = span.new[1] } }
    end
  end
  render(anchor, offset)
end

--- A mouse click on row `line` of pane `win`: a "hidden lines" separator
--- expands one step, like `expand_context` on it.
--- @return boolean handled
function M.click(win, line)
  if not (S.layout and side_of_win(win)) then return false end
  local item = S.layout.items[line]
  if not (item and item.sep) then return false end
  vim.api.nvim_set_current_win(win)
  pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
  M.expand("cursor")
  return true
end

local function block_at_cursor()
  local row = row_of_item(item_at(cursor_idx()))
  return row and row.block and S.model.blocks[row.block] or nil
end

function M.jump_hunk(dir)
  if not S.model or #S.model.blocks == 0 then return end
  local idx = cursor_idx()
  local current = block_at_cursor()
  local target
  if dir > 0 then
    for _, blk in ipairs(S.model.blocks) do
      local i = S.layout.index_of[blk.first]
      if i and i > idx and blk ~= current then target = i break end
    end
  else
    for b = #S.model.blocks, 1, -1 do
      local blk = S.model.blocks[b]
      local i = S.layout.index_of[blk.first]
      if i and i < idx and blk ~= current then target = i break end
    end
  end
  if target then
    vim.cmd("normal! m'")
    local win = current_pane()
    pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
  end
end

--- Keys for a vertical move of `count` rows that skips filler rows on `side`.
local function vertical_keys(side, dir)
  if not S.layout then return dir > 0 and "j" or "k" end
  local items = S.layout.items
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local start = row
  for _ = 1, vim.v.count1 do
    local nxt = row + dir
    while items[nxt] and items[nxt].row and not S.model.rows[items[nxt].row][side] do
      nxt = nxt + dir
    end
    if not items[nxt] then break end
    row = nxt
  end
  local n = math.abs(row - start)
  if n == 0 then return "" end
  -- `normal!` keeps 'curswant', so the column is remembered across short lines.
  return string.format("<Cmd>normal! %d%s<CR>", n, dir > 0 and "j" or "k")
end

function M.stage_hunk(reverse)
  local src = S.source
  if not (src and S.model) then return end
  if src.kind ~= "worktree" or src.status == "untracked" then
    notify("hunks can be staged only in working-tree diffs of tracked files")
    return
  end
  if reverse and not src.staged then
    notify("this diff is unstaged — use " .. config.get().keymaps.stage_hunk .. " to stage a hunk")
    return
  end
  if not reverse and src.staged then
    notify("this diff is already staged — use " .. config.get().keymaps.unstage_hunk .. " to unstage a hunk")
    return
  end
  local block = block_at_cursor()
  if not block then
    notify("no change under the cursor")
    return
  end
  local patch, err = engine.block_patch(S.model, block, src.path)
  if not patch then
    notify(err, vim.log.levels.WARN)
    return
  end
  git.apply_to_index(S.root, patch, reverse, function(ok, gerr)
    if not ok then
      log.warn("%s hunk in %s failed: %s\n%s", reverse and "unstage" or "stage", src.path, gerr or "", patch)
      notify((reverse and "unstage" or "stage") .. " failed: " .. (gerr or "?"), vim.log.levels.ERROR)
      return
    end
    log.info("%s hunk %d in %s", reverse and "unstaged" or "staged", block.first, src.path)
    M.refresh_content()
    sidebar().refresh()
  end)
end

--- New-side line for item `idx`. Rows that exist only on the old side (and
--- fillers) have no new line, so the nearest one below, then above, is used.
local function new_line_near(idx)
  local items = S.layout.items
  for _, step in ipairs({ 1, -1 }) do
    local i = idx
    while items[i] do
      local item = items[i]
      if item.sep then return engine.separator_span(S.model, item.sep).new[1] end
      local row = S.model.rows[item.row]
      if row.new then return row.new end
      i = i + step
    end
  end
  return 1
end

function M.goto_file()
  local src = S.source
  if not src then return end
  if src.status == "deleted" then
    notify("the file was deleted; there is nothing to open")
    return
  end
  local line = S.layout and new_line_near(cursor_idx()) or 1
  log.debug("goto %s:%d", src.path, line)
  sidebar().open_in_editor(S.root .. "/" .. src.path, line)
end

function M.goto_neighbor(dir)
  if not (S.source and S.navigator) then return end
  local nxt = S.navigator(S.source, dir)
  if not nxt then
    vim.api.nvim_echo({ { dir > 0 and "diff.nvim: last file" or "diff.nvim: first file", "WarningMsg" } }, false, {})
    return
  end
  M.open(S.root, nxt, S.navigator)
end

local function leave_note(side)
  return function()
    if not S.model then return end
    local first, last
    local mode = vim.fn.mode()
    if mode == "v" or mode == "V" or mode == "\22" then
      -- Leave visual mode first: '< and '> only update when it ends.
      vim.cmd([[execute "normal! \<Esc>"]])
      first, last = vim.fn.getpos("'<")[2], vim.fn.getpos("'>")[2]
    else
      first = vim.api.nvim_win_get_cursor(0)[1]
      last = first
    end
    if last < first then first, last = last, first end

    local lines = {}
    for i = first, last do
      local row = row_of_item(item_at(i))
      if row and row[side] then table.insert(lines, row[side]) end
    end
    if #lines == 0 then
      notify("cannot leave a note on a filler or separator line", vim.log.levels.WARN)
      return
    end
    require("diff.annotations").prompt_note({
      file_path  = S.source.path,
      line_start = lines[1],
      line_end   = lines[#lines],
      side       = side,
      repo_root  = S.root,
    })
  end
end

--- Re-draw note markers after a note is added or removed.
function M.refresh_annotations()
  if not S.layout then return end
  for _, side in ipairs(SIDES) do
    if S.panes[side] and valid_buf(S.bufs[side]) then decorate_notes(side) end
  end
end

-- ---------------------------------------------------------------------------
-- Keymaps (installed once per pane buffer; they read the current state)
-- ---------------------------------------------------------------------------

setup_keymaps = function(buf, side)
  local km = config.get().keymaps or {}
  local function map(mode, key, rhs, desc, extra)
    if not key or key == "" then return end
    vim.keymap.set(mode, key, rhs, vim.tbl_extend("force",
      { buffer = buf, nowait = true, silent = true, desc = desc .. " (diff)" }, extra or {}))
  end

  map({ "n", "v" }, km.leave_note, leave_note(side), "Leave note")
  map("n", km.toggle_notes, function() require("diff.annotations").toggle_notes(S.root) end, "Toggle notes panel")
  map("n", km.next_hunk, function() M.jump_hunk(1) end, "Next hunk")
  map("n", km.prev_hunk, function() M.jump_hunk(-1) end, "Previous hunk")
  map("n", km.next_file, function() M.goto_neighbor(1) end, "Next file")
  map("n", km.prev_file, function() M.goto_neighbor(-1) end, "Previous file")
  map("n", km.goto_file, M.goto_file, "Open file at this line")
  map("n", km.stage_hunk, function() M.stage_hunk(false) end, "Stage hunk")
  map("n", km.unstage_hunk, function() M.stage_hunk(true) end, "Unstage hunk")
  map("n", km.expand_context, function() M.expand("cursor") end, "Expand context here")
  map("n", km.expand_all, function() M.expand("all") end, "Show all context")
  map("n", km.collapse_all, function() M.expand("reset") end, "Collapse context")

  -- Filler rows hold no content, so vertical moves step over them.
  for key, dir in pairs({ j = 1, k = -1, ["<Down>"] = 1, ["<Up>"] = -1 }) do
    map("n", key, function() return vertical_keys(side, dir) end, "Move, skipping filler rows", { expr = true })
  end

  -- l expands a separator; anywhere else it is the ordinary motion (and
  -- returning "l" keeps any count the user typed).
  map("n", "l", function()
    local item = item_at(vim.api.nvim_win_get_cursor(0)[1])
    if item and item.sep then return "<Cmd>lua require('diff.diff_view').expand('cursor')<CR>" end
    return "l"
  end, "Expand separator / move right", { expr = true })

  map("n", "q", function()
    M.close()
    sidebar().focus_panel()
  end, "Close diff view")
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function M.is_open()
  return S.source ~= nil
end

function M.current_source()
  return S.source
end

--- Internal state, exposed for the test suite only.
function M._state()
  return S
end

--- Close the view: windows, buffers, sources and watchers. Safe to call when
--- the tab has already been closed underneath it.
function M.close()
  local had_view = S.source ~= nil
  stop_watcher()
  destroy_sources()
  if valid_win(S.header_win) then pcall(vim.api.nvim_win_close, S.header_win, true) end
  if valid_win(S.extra_win) then pcall(vim.api.nvim_win_close, S.extra_win, true) end
  local host = sidebar().get_main_win()
  if valid_win(host) then sidebar().show_placeholder(host) end
  -- Buffers go last: deleting a displayed buffer would close its window.
  for _, buf in pairs(S.bufs) do
    if valid_buf(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
  end
  if valid_buf(S.header_buf) then pcall(vim.api.nvim_buf_delete, S.header_buf, { force = true }) end
  local gen = S.open_gen
  S = fresh_state()
  S.open_gen = gen + 1 -- invalidate loads still in flight
  if had_view then
    log.debug("view closed")
    fire_view_changed()
  end
end

-- Horizontal scroll sync. 'scrollbind' handles the vertical direction
-- natively; horizontal binding would need the global 'scrollopt', so leftcol
-- is mirrored here instead.
local aug = vim.api.nvim_create_augroup("DiffNvimView", { clear = true })
vim.api.nvim_create_autocmd("WinScrolled", {
  group = aug,
  callback = function()
    if not (valid_win(S.panes.old) and valid_win(S.panes.new)) then return end
    for win, delta in pairs(vim.v.event) do
      local id = tonumber(win)
      if id and (id == S.panes.old or id == S.panes.new) and delta.leftcol ~= 0 then
        local other = id == S.panes.old and S.panes.new or S.panes.old
        local leftcol = vim.fn.getwininfo(id)[1].leftcol
        vim.api.nvim_win_call(other, function() vim.fn.winrestview({ leftcol = leftcol }) end)
        return
      end
    end
  end,
})

-- Wrapping depends on the pane width, so a width change re-aligns the rows.
-- Height-only resizes (a split elsewhere in the tab) leave wrapping as it was.
vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
  group = aug,
  callback = function()
    if not (S.layout and next(S.wrap_widths)) then return end
    for side, width in pairs(S.wrap_widths) do
      local win = S.panes[side]
      if valid_win(win) and vim.api.nvim_win_get_width(win) ~= width then
        log.debug("%s pane width %d -> %d; re-aligning wrapped rows", side, width, vim.api.nvim_win_get_width(win))
        align_wrapped()
        return
      end
    end
  end,
})

-- The index or HEAD moved (staging from the CLI, a commit, a checkout): the
-- working-tree diff may be stale on either side.
vim.api.nvim_create_autocmd("User", {
  group = aug,
  pattern = "DiffNvimGitChanged",
  callback = function()
    if S.source and S.source.kind == "worktree" then M.refresh_content() end
  end,
})

return M
