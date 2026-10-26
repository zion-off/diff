local H = require("helpers")

vim.o.columns, vim.o.lines = 160, 50

-- src/m.lua: two functions of plain statements. The edit rewrites line 10
-- and inserts a line after it, in the first, and deletes line 45, in the
-- second.
local function m_lines()
  local l = { "local M = {}", "", "function M.first()" }
  for i = 4, 27 do l[i] = "  local v" .. i .. " = " .. i end
  l[28], l[29], l[30] = "end", "", "function M.second()"
  for i = 31, 57 do l[i] = "  local v" .. i .. " = " .. i end
  l[58], l[59], l[60] = "end", "", "return M"
  return l
end

local repo = H.repo({
  ["src/m.lua"] = H.text(m_lines()),
  ["src/o.lua"] = "return 1\n",
  ["src/heading.lua"] = H.text(m_lines()),
  ["bin.dat"] = "a\0b\n",
})
local edited = m_lines()
edited[10] = "  local v10 = 100"
table.insert(edited, 11, "  local extra = true")
table.remove(edited, 46)
H.write(repo, "src/m.lua", H.text(edited))
H.write(repo, "src/o.lua", "return 2\n")
H.write(repo, "fresh.lua", "local a = 1\nlocal b = 2\n")
-- heading.lua: a change three lines into M.second(), so its hunk starts on
-- the function's own signature.
H.write(repo, "src/heading.lua", H.text(vim.list_extend(vim.list_slice(m_lines(), 1, 32),
  vim.list_extend({ "  local v33 = 330" }, vim.list_slice(m_lines(), 34, 60)))))
H.write(repo, "bin.dat", "a\0c\n")

vim.cmd("cd " .. repo)
require("diff").setup({ layout = "unified", log_level = os.getenv("DIFF_LOG") or "warn" })
vim.cmd("runtime plugin/diff.lua")

local dv      = require("diff.diff_view")
local sidebar = require("diff.sidebar")
local fp      = require("diff.file_panel")
local S       = dv._state

local function press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

--- Open `name` from the panel's unstaged "Changes" (a staged entry can
--- linger there until a refresh catches up with the index).
local function open_file(name)
  H.wait(function()
    local in_changes = false
    for i, l in ipairs(vim.api.nvim_buf_get_lines(sidebar._file_buf, 0, -1, false)) do
      in_changes = in_changes or l:find("Changes", 1, true) and not l:find("Staged", 1, true)
      if in_changes and l:find(vim.fn.fnamemodify(name, ":t"), 1, true) then fp.activate_line(i) return true end
    end
  end, name .. " in panel")
  H.wait(function() return S().layout and S().source.path == name end, "diff of " .. name)
end

local function pane() return S().panes.unified end
local function cursor(win) return vim.api.nvim_win_get_cursor(win or 0)[1] end
local function items() return S().layout.items end

local function find_item(pred)
  for i, it in ipairs(items()) do if pred(it, i) then return i end end
end

--- Item showing `line` of `side` (context counts for both sides).
local function item_for(side, line)
  return find_item(function(it)
    local row = it.row and S().model.rows[it.row]
    return row and (not it.side or it.side == side) and row[side] == line
  end)
end

local function gutter(lnum, highlights)
  local win = pane()
  return vim.api.nvim_eval_statusline(vim.wo[win].statuscolumn,
    { winid = win, use_statuscol_lnum = lnum, highlights = highlights })
end

local function engine_header(item)
  return require("diff.diff_engine").hunk_header(item.hunk)
end

local function marks(buf, ns)
  return vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_get_namespaces()[ns], 0, -1, { details = true })
end

return {
  { "layout = unified opens one pane: removed lines, then added, under @@ headers", function()
    require("diff").open()
    H.wait(function() return sidebar.is_open() and pcall(vim.api.nvim_buf_get_lines, sidebar._file_buf, 0, -1, false) end)
    open_file("src/m.lua")
    H.eq(S().mode, "unified")
    H.eq({ S().panes.old, S().panes.new }, { nil, nil })
    H.eq(dv.pane_wins(), { pane() })

    local lines = vim.api.nvim_buf_get_lines(S().bufs.unified, 0, -1, false)
    local first = S().layout.block_start[1]
    H.eq({ lines[first], lines[first + 1], lines[first + 2] },
      { "  local v10 = 10", "  local v10 = 100", "  local extra = true" })
    H.eq(cursor(pane()), first, "the cursor starts on the first change")

    -- Each run of rows is headed by git's range and the function it is in.
    local src = S().sources.old
    H.wait(function() return src.ready end, "parse")
    local headers = {}
    for _, m in ipairs(marks(S().bufs.unified, "diff_nvim_diff")) do
      local d = m[4]
      if d.line_hl_group == "DiffNvimHunkHeader" then
        local text = ""
        for _, chunk in ipairs(d.virt_text or {}) do text = text .. chunk[1] end
        table.insert(headers, text)
      end
    end
    H.eq(headers[1], "@@ -7,7 +7,8 @@ function M.first()")
    H.eq(headers[2], "@@ -42,7 +43,6 @@ function M.second()")
  end },

  { "the gutter numbers each side as GitHub does: old, new, then +/-", function()
    local w = S().lnum_width
    local function expect(lnum, old, new, marker, group)
      local ev = gutter(lnum, true)
      local want = string.rep(" ", 2) .. string.format("%" .. w .. "s %" .. w .. "s %s ", old, new, marker)
      H.eq(ev.str, want, "gutter of row " .. lnum)
      local groups = {}
      for _, h in ipairs(ev.highlights) do groups[h.group] = true end
      H.ok(groups[group], group .. " in " .. vim.inspect(ev.highlights))
    end
    expect(item_for("old", 10), "10", "", "-", "DiffNvimRemovedNr")
    expect(item_for("new", 10), "", "10", "+", "DiffNvimAddedNr")
    expect(item_for("new", 11), "", "11", "+", "DiffNvimAddedMarker")
    -- Context below an insertion: the two numbers differ.
    expect(item_for("new", 12), "11", "12", " ", "LineNr")
    expect(item_for("old", 45), "45", "", "-", "DiffNvimRemovedMarker")

    local width = vim.api.nvim_strwidth(gutter(1).str)
    H.eq(vim.fn.getwininfo(pane())[1].textoff, width, "the drawn gutter is as wide as 'numberwidth' was pinned")
    local header = gutter(1, true)
    H.eq(header.highlights[1].group, "DiffNvimHunkHeader")
    H.eq(vim.api.nvim_strwidth(header.str), width, "the header band spans the whole gutter")
    H.ok(header.str:find("↕", 1, true), "a header hiding rows offers to expand")
  end },

  { "changed lines are tinted by side and the words that changed marked", function()
    vim.cmd("redraw")
    local tints = {}
    for _, m in ipairs(marks(S().bufs.unified, "diff_nvim_diff")) do
      if m[4].hl_group then tints[m[2] + 1] = m[4].hl_group end
    end
    H.eq(tints[item_for("old", 10)], "DiffNvimRemoved")
    H.eq(tints[item_for("new", 10)], "DiffNvimAdded")
    H.eq(S().words[S().layout.items[item_for("new", 10)].row].new[1],
      { start_col = 14, end_col = 17 }, "word ranges computed for the paired lines")
    -- Both sides are highlighted from their own parse.
    H.ok(S().sources.old.cache[9], "the removed line was highlighted from the old side")
    H.ok(S().sources.new.cache[9], "the added line was highlighted from the new side")
  end },

  { "the toggle switches to split and back, keeping the cursor on its line", function()
    local host = pane()
    vim.api.nvim_set_current_win(host)
    vim.api.nvim_win_set_cursor(host, { item_for("new", 11), 0 })
    dv.toggle_layout()
    H.eq(S().mode, "split")
    H.eq(S().panes.new, host, "the window is reused")
    H.ok(S().panes.old, "the old pane is back")
    H.eq(vim.api.nvim_get_current_win(), host)
    local row = S().model.rows[items()[cursor(host)].row]
    H.eq(row.new, 11)

    -- A removed line keeps its place too.
    local old_row = find_item(function(it) return it.row and S().model.rows[it.row].old == 45 end)
    vim.api.nvim_win_set_cursor(host, { old_row, 0 })
    dv.toggle_layout()
    H.eq(S().mode, "unified")
    H.eq(cursor(pane()), item_for("old", 45))
    H.eq(#vim.api.nvim_tabpage_list_wins(0), 5, "sidebar×3 + header + one pane")
  end },

  { "the layout lasts for the session: other files open in it", function()
    vim.cmd("DiffNvimLayout split")
    open_file("src/o.lua")
    H.eq(S().mode, "split")
    vim.cmd("DiffNvimLayout")
    H.eq(S().mode, "unified")
    open_file("src/m.lua")
    H.eq(S().mode, "unified")
  end },

  { "]c / [c land on the first line of each block, its removed lines", function()
    vim.api.nvim_set_current_win(pane())
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    press("]c")
    H.eq(cursor(), item_for("old", 10))
    press("]c")
    H.eq(cursor(), item_for("old", 45))
    press("[c")
    H.eq(cursor(), item_for("old", 10))
  end },

  { "clicking a hunk header expands the rows hidden above it", function()
    local header = find_item(function(it, i) return it.sep and it.hunk and i > 1 end)
    local before = items()[header].hunk.old_first
    dv.hover(pane(), header)
    local hover = marks(S().bufs.unified, "diff_nvim_hover")
    H.eq(hover[1][4].line_hl_group, "DiffNvimHunkHeaderHover")
    H.ok(hover[1][4].virt_text[#hover[1][4].virt_text][1]:match("click to expand"), vim.inspect(hover))
    H.ok(dv.click(pane(), header))
    H.ok(find_item(function(it) return it.hunk and it.hunk.old_first == before - 10 end),
      "the header's range grows over the 10 revealed rows above it")
    press("zM")
  end },

  { "a note covering removed and added lines goes on the side of its first line", function()
    local annotations = require("diff.annotations")
    local prompt = annotations.prompt_note
    local got
    annotations.prompt_note = function(opts) got = opts end
    vim.api.nvim_set_current_win(pane())
    vim.api.nvim_win_set_cursor(0, { item_for("old", 10), 0 })
    press("V2j\\n")
    annotations.prompt_note = prompt
    H.eq({ got.side, got.line_start, got.line_end }, { "old", 10, 10 })

    -- Starting on an added line, context below counts on the new side.
    annotations.prompt_note = function(opts) got = opts end
    vim.api.nvim_win_set_cursor(0, { item_for("new", 11), 0 })
    press("Vj\\n")
    annotations.prompt_note = prompt
    H.eq({ got.side, got.line_start, got.line_end }, { "new", 11, 12 })
  end },

  { "staging a hunk from the unified view", function()
    vim.api.nvim_set_current_win(pane())
    vim.api.nvim_win_set_cursor(0, { item_for("new", 10), 0 })
    press("s")
    H.wait(function() return H.git(repo, "diff", "--cached", "--", "src/m.lua"):match("local extra = true") end,
      "hunk staged")
    local staged = H.git(repo, "diff", "--cached", "--", "src/m.lua")
    H.ok(not staged:match("v45"), "only the hunk under the cursor is staged:\n" .. staged)
    H.wait(function() return #S().model.blocks == 1 end, "view refreshed")
    H.git(repo, "reset", "-q", "--", "src/m.lua")
    H.wait(function() return #S().model.blocks == 2 end, "view refreshed after the reset")
  end },

  { "an added file is all + lines from line 0 of the old side", function()
    open_file("fresh.lua")
    H.eq(S().mode, "unified")
    local header = items()[1]
    H.eq(require("diff.diff_engine").hunk_header(header.hunk), "@@ -0,0 +1,2 @@")
    H.eq(vim.api.nvim_buf_get_lines(S().bufs.unified, 0, -1, false), { "", "local a = 1", "local b = 2" })
  end },

  { "only a header that hides rows reacts to the pointer", function()
    open_file("src/m.lua")
    vim.api.nvim_set_current_win(pane())
    press("zR")
    H.ok(items()[1].hunk and not items()[1].sep, "fully expanded, the top header hides nothing")
    dv.hover(pane(), 1)
    H.eq(gutter(1, true).highlights[1].group, "DiffNvimHunkHeader", "no hover tint on a header that cannot expand")
    H.eq(#marks(S().bufs.unified, "diff_nvim_hover"), 0)
    dv.hover(nil, nil)
    press("zM")
  end },

  { "toggling forgets the row under the pointer", function()
    local header = find_item(function(it) return it.sep and it.hunk end)
    dv.hover(pane(), header)
    H.eq(#marks(S().bufs.unified, "diff_nvim_hover"), 1)
    dv.toggle_layout()
    H.eq(S().hover, nil)
    for _, side in ipairs({ "old", "new" }) do
      H.eq(#marks(S().bufs[side], "diff_nvim_hover"), 0, "no stale hover in the " .. side .. " pane")
    end
    dv.toggle_layout()
  end },

  { "a pane switched away from is emptied, and sources no pane shows dropped", function()
    dv.set_layout("split")
    H.eq(vim.api.nvim_buf_get_lines(S().bufs.unified, 0, -1, false), { "" })
    H.eq(#vim.api.nvim_buf_get_extmarks(S().bufs.unified, -1, 0, -1, {}), 0)
    open_file("fresh.lua")
    H.eq(S().mode, "new")
    H.eq(S().sources.old, nil, "an added file in a split shows no old side")
    H.eq(vim.api.nvim_buf_get_lines(S().bufs.old, 0, -1, false), { "" })
    dv.set_layout("unified")
    H.ok(S().sources.old, "unified shows both sides again")
    H.eq(vim.api.nvim_buf_get_lines(S().bufs.new, 0, -1, false), { "" })
    open_file("src/m.lua")
  end },

  { "gf on a hunk header opens the hunk it names", function()
    local opened
    local open_in_editor = sidebar.open_in_editor
    sidebar.open_in_editor = function(_, line) opened = line end
    vim.api.nvim_set_current_win(pane())
    local header = find_item(function(it) return it.sep and it.hunk end)
    vim.api.nvim_win_set_cursor(0, { header, 0 })
    dv.goto_file()
    sidebar.open_in_editor = open_in_editor
    H.eq(opened, items()[header].hunk.new_first)
  end },

  { "under 'ambiwidth' double the header gutter keeps its width", function()
    -- 'ambiwidth' itself cannot be set here: the interface's 'fillchars'
    -- holds box-drawing characters, which conflict with "double". Measure
    -- '↕' as it would then measure instead.
    local strwidth = vim.api.nvim_strwidth
    local function double(text)
      local _, wide = text:gsub("↕", "")
      return strwidth(text) + wide
    end
    local header = find_item(function(it) return it.sep and it.hunk end)
    local width = double(gutter(item_for("new", 12)).str)
    vim.api.nvim_strwidth = double
    local ok, drawn = pcall(gutter, header)
    vim.api.nvim_strwidth = strwidth
    assert(ok, drawn)
    H.ok(drawn.str:find("↕", 1, true))
    H.eq(double(drawn.str), width)
  end },

  { "the function after @@ is the one git names: searched from above the hunk", function()
    open_file("src/heading.lua")
    H.wait(function() return S().sources.old.ready end, "parse")
    local header = find_item(function(it) return it.hunk end)
    H.eq(engine_header(items()[header]), "@@ -30,7 +30,7 @@")
    local virt = marks(S().bufs.unified, "diff_nvim_diff")
    for _, m in ipairs(virt) do
      if m[2] == header - 1 and m[4].virt_text then
        H.eq(#m[4].virt_text, 1, "no declaration: the line above the hunk is outside any function")
      end
    end
    open_file("src/m.lua")
  end },

  { "a binary file leaves the toggle working both ways", function()
    for i, l in ipairs(vim.api.nvim_buf_get_lines(sidebar._file_buf, 0, -1, false)) do
      if l:find("bin.dat", 1, true) then fp.activate_line(i) end
    end
    H.wait(function() return S().source and S().source.binary end, "binary file shown")
    local before = dv.layout()
    local notify = vim.notify
    vim.notify = function() end
    dv.toggle_layout()
    local after_one = dv.layout()
    dv.toggle_layout()
    vim.notify = notify
    H.ok(before ~= after_one, "the first toggle flips the layout")
    H.eq(dv.layout(), before, "the second flips it back")
    open_file("src/m.lua")
    H.eq(S().mode, before)
  end },

  { ":DiffNvimLayout completes what was typed and logs a bad layout", function()
    H.eq(vim.fn.getcompletion("DiffNvimLayout u", "cmdline"), { "unified" })
    H.eq(vim.fn.getcompletion("DiffNvimLayout ", "cmdline"), { "split", "unified" })
    local notify = vim.notify
    vim.notify = function() end
    vim.cmd("DiffNvimLayout Unified")
    vim.notify = notify
    local log = table.concat(vim.fn.readfile(require("diff.log").path()), "\n")
    H.ok(log:find('unknown layout "Unified"', 1, true), "logged")
    H.eq(S().mode, "unified", "a bad layout changes nothing")
  end },

  { "a split with no room falls back to unified", function()
    dv.close()
    dv.set_layout("split")
    -- Splitting the pane fails as it does on a screen too narrow for it.
    local cmd = vim.cmd
    vim.cmd = function(c)
      if c == "leftabove vsplit" then error("Vim(vsplit):E36: Not enough room") end
      return cmd(c)
    end
    local warned
    local notify = vim.notify
    vim.notify = function(msg, level) if level == vim.log.levels.WARN then warned = msg end end
    local ok, err = pcall(open_file, "src/o.lua")
    vim.cmd, vim.notify = cmd, notify
    assert(ok, err)
    H.eq(S().mode, "unified")
    H.eq(dv.pane_wins(), { S().panes.unified })
    H.ok(warned and warned:match("unified"), tostring(warned))
    H.eq(dv.layout(), "unified")
    H.eq(vim.api.nvim_buf_get_lines(S().bufs.unified, 0, -1, false), { "", "return 1", "return 2" })
  end },
}
