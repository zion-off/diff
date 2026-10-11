local H = require("helpers")

-- src/a.lua: a 40-line block comment, then plain statements.
local function a_lines(edits)
  local l = { "--[[" }
  for i = 2, 40 do l[i] = "  comment line " .. i end
  l[41] = "]]"
  for i = 42, 100 do l[i] = "local v" .. i .. " = " .. i end
  for k, v in pairs(edits or {}) do l[k] = v end
  return l
end

local repo = H.repo({
  ["src/a.lua"] = H.text(a_lines()),
  ["src/b.lua"] = "return 1\n",
  ["docs/c.md"] = "# c\n",
  ["deep/x/y/z.txt"] = "z\n",
})
-- Unstaged: a.lua (line 30 inside the comment, line 80, and an insertion after
-- 90), b.lua, z.txt and an untracked file. Staged: c.md.
local a_new = a_lines({ [30] = "  comment line 30 EDITED", [80] = "local v80 = 800" })
table.insert(a_new, 91, "local inserted = true")
H.write(repo, "src/a.lua", H.text(a_new))
H.write(repo, "src/b.lua", "return 2\n")
H.write(repo, "deep/x/y/z.txt", "zz\n")
H.write(repo, "new.lua", "local fresh = 1\n")
H.write(repo, "docs/c.md", "# c\nmore\n")
H.git(repo, "add", "docs/c.md")

vim.cmd("cd " .. repo)
vim.keymap.set("n", "<leader>gb", function() vim.g.user_map_ran = true end, { desc = "user mapping" })
require("diff").setup({ log_level = os.getenv("DIFF_LOG") or "warn" })

local dv      = require("diff.diff_view")
local sidebar = require("diff.sidebar")
local fp      = require("diff.file_panel")
local cp      = require("diff.commit_panel")
local S       = dv._state

local function press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

local function panel_row(pat, buf)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf or sidebar._file_buf, 0, -1, false)) do
    if l:match(pat) then return i end
  end
  error("no panel row matches " .. pat)
end

local view_events = 0
vim.api.nvim_create_autocmd("User", {
  pattern = "DiffNvimViewChanged",
  callback = function() view_events = view_events + 1 end,
})

--- Open a file from the panel and wait for *that* open to finish.
local function open_file(pat, path)
  local seen = view_events
  fp.activate_line(panel_row(pat))
  H.wait(function()
    local s = S()
    return view_events > seen and s.source and s.source.path == path and (s.layout or s.source.binary)
  end, "diff for " .. path)
end

local function pane(side) return S().panes[side] end
local function cursor(win) return vim.api.nvim_win_get_cursor(win or 0)[1] end
local function item(i) return S().layout.items[i] end
local function row(i) local it = item(i); return it and it.row and S().model.rows[it.row] end

local function find_item(pred)
  for i, it in ipairs(S().layout.items) do if pred(it, i) then return i end end
end

return {
  { "opening the interface populates both panels", function()
    local calls = H.count_git(function()
      require("diff").open()
      H.wait(function() return sidebar.is_open() and fp.render and
        vim.api.nvim_buf_get_lines(sidebar._file_buf, 0, 1, false)[1]:match("Staged") end, "panels")
    end)
    local text = table.concat(vim.api.nvim_buf_get_lines(sidebar._file_buf, 0, -1, false), "\n")
    H.ok(text:match("Staged Changes %(1%)"), text)
    H.ok(text:match("Changes %(4%)"), text)
    H.ok(#calls <= 6, "open spawned " .. #calls .. " git processes: " .. vim.inspect(calls))
  end },

  { "opening a diff: one git process, real line numbers, cursor on first change", function()
    local calls = H.count_git(function() open_file("a%.lua", "src/a.lua") end, 50)
    H.eq(#calls, 1, "expected only `git show :path`, got " .. vim.inspect(calls))
    local s = S()
    H.ok(pane("old") and pane("new"), "split view expected")
    H.ok(vim.api.nvim_buf_get_lines(s.header_buf, 0, 1, false)[1]:match("src/a%.lua.*%+3 %-2"),
      vim.api.nvim_buf_get_lines(s.header_buf, 0, 1, false)[1])
    local first = row(cursor(pane("new")))
    H.eq(first.new, 30, "cursor should start on the first change")
    local win = pane("new")
    local gutter = vim.api.nvim_eval_statusline(vim.wo[win].statuscolumn,
      { winid = win, use_statuscol_lnum = cursor(win) }).str
    H.eq(gutter:match("(%d+)%s*$"), "30", "gutter must show the file line number, got " .. vim.inspect(gutter))
  end },

  { "a line inside a collapsed block comment is highlighted as a comment", function()
    local src = S().sources.new
    H.wait(function() return src.ready end, "parse")
    local idx = find_item(function(it) return it.row and S().model.rows[it.row].new == 30 end)
    local found = false
    for _, c in ipairs(src:captures(29)) do
      if c[3]:match("^@comment") then found = true end
    end
    H.ok(idx and found, "row for line 30 should carry a @comment capture")
  end },

  { "switching files reuses the windows", function()
    local before = { S().header_win, pane("old"), pane("new") }
    open_file("b%.lua", "src/b.lua")
    H.eq({ S().header_win, pane("old"), pane("new") }, before)
    H.eq(vim.api.nvim_buf_get_lines(S().bufs.new, 0, -1, false), { "return 2" })
  end },

  { "untracked files show a single pane; split comes back after", function()
    local host = pane("new")
    open_file("new%.lua", "new.lua")
    H.eq(pane("old"), nil)
    H.eq(pane("new"), host)
    H.eq(#vim.api.nvim_tabpage_list_wins(0), 5, "sidebar×3 + header + one pane")
    open_file("a%.lua", "src/a.lua")
    H.ok(pane("old"), "split restored")
    H.eq(pane("new"), host)
  end },

  { "expanding a separator reveals that gap only and keeps the cursor in place", function()
    vim.api.nvim_set_current_win(pane("new"))
    local seps_before = 0
    for _, it in ipairs(S().layout.items) do if it.sep then seps_before = seps_before + 1 end end
    local sep_idx = find_item(function(it, i) return it.sep and i > 5 end)
    vim.api.nvim_win_set_cursor(0, { sep_idx, 0 })
    local screen_row = vim.fn.winline()
    local items_before = #S().layout.items
    press("l")
    H.eq(#S().layout.items, items_before + 20, "one press reveals 10 lines at each edge")
    H.ok(item(cursor()).sep, "cursor should stay on the remaining separator")
    H.eq(vim.fn.winline(), screen_row, "separator should stay at the same screen row")
    local seps_after = 0
    for _, it in ipairs(S().layout.items) do if it.sep then seps_after = seps_after + 1 end end
    H.eq(seps_after, seps_before, "other gaps must stay collapsed")
    press("zM")
    H.eq(#S().layout.items, items_before)
  end },

  { "clicking a separator row expands it", function()
    local win = pane("new")
    vim.api.nvim_set_current_win(win)
    local sep_idx = find_item(function(it, i) return it.sep and i > 5 end)
    vim.api.nvim_win_set_cursor(win, { sep_idx, 0 })
    local items_before = #S().layout.items
    -- A click on an ordinary row does nothing.
    H.eq(dv.click(win, find_item(function(it) return it.row end)), false)
    H.eq(#S().layout.items, items_before)
    H.eq(dv.click(win, sep_idx), true)
    H.eq(#S().layout.items, items_before + 20, "one click reveals 10 lines at each edge")
    press("zM")
    H.eq(#S().layout.items, items_before)
  end },

  { "]c and [c move between changes; j skips filler rows", function()
    vim.api.nvim_set_current_win(pane("new"))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    press("]c")
    H.eq(row(cursor()).new, 30)
    press("]c")
    H.eq(row(cursor()).new, 80)
    press("]c")
    H.eq(row(cursor()).new, 91)
    press("[c")
    H.eq(row(cursor()).new, 80)

    vim.api.nvim_set_current_win(pane("old"))
    local ins = find_item(function(it) return it.row and S().model.rows[it.row].new == 91 end)
    vim.api.nvim_win_set_cursor(0, { ins - 1, 0 })
    press("j")
    H.ok(row(cursor()).old, "j must not land on a filler row of the old side")
    H.eq(cursor(), ins + 1)
  end },

  { "a filler row shows its pattern", function()
    local ins = find_item(function(it) return it.row and S().model.rows[it.row].new == 91 end)
    vim.cmd("redraw")
    local pos = vim.fn.screenpos(pane("old"), ins, 1)
    H.ok(pos.row > 0, "filler row on screen")
    H.eq(vim.fn.screenstring(pos.row, pos.col), "░")
  end },

  { "s stages the hunk under the cursor and the view refreshes in place", function()
    vim.api.nvim_set_current_win(pane("new"))
    local wins = { pane("old"), pane("new") }
    local idx = find_item(function(it) return it.row and S().model.rows[it.row].new == 80 end)
    vim.api.nvim_win_set_cursor(0, { idx, 0 })
    press("s")
    H.wait(function() return H.git(repo, "diff", "--cached", "--", "src/a.lua"):match("local v80 = 800") end,
      "hunk staged")
    H.wait(function() return S().model.added == 2 end, "view refreshed")
    H.eq({ pane("old"), pane("new") }, wins)
    local staged = H.git(repo, "diff", "--cached", "--", "src/a.lua")
    H.ok(not staged:match("EDITED"), "only the hunk under the cursor may be staged")
  end },

  { "u unstages a hunk from the staged diff", function()
    H.wait(function()
      return vim.api.nvim_buf_get_lines(sidebar._file_buf, 0, 1, false)[1]:match("Staged Changes %(2%)")
    end, "a.lua listed as staged")
    fp.activate_line(panel_row("a%.lua")) -- first match is in the staged section
    H.wait(function() return S().source and S().source.staged and S().layout end, "staged diff")
    vim.api.nvim_set_current_win(pane("new"))
    vim.api.nvim_win_set_cursor(0, { S().layout.index_of[S().model.blocks[1].first], 0 })
    press("u")
    H.wait(function() return H.git(repo, "diff", "--cached", "--", "src/a.lua") == "" end, "hunk unstaged")
  end },

  { "the file panel keeps its place: collapse needs no git, staging moves to the next file", function()
    H.wait(function()
      return vim.api.nvim_buf_get_lines(sidebar._file_buf, 0, 1, false)[1]:match("Staged Changes %(1%)")
    end, "panel caught up")
    vim.api.nvim_set_current_win(sidebar._file_win)
    vim.wait(500) -- let the watcher-driven refresh from the previous test land
    local calls = H.count_git(function() fp.activate_line(panel_row("deep/x/y")) end, 100)
    H.eq(#calls, 0, "collapsing a directory must not spawn git: " .. vim.inspect(calls))
    H.ok(vim.api.nvim_buf_get_lines(sidebar._file_buf, 0, -1, false)[panel_row("deep/x/y")]:match("…$"))
    fp.activate_line(panel_row("deep/x/y"))

    local a_row = panel_row("a%.lua")
    vim.api.nvim_win_set_cursor(sidebar._file_win, { a_row, 0 })
    press("s")
    H.wait(function() return H.git(repo, "diff", "--cached", "--name-only"):match("src/a.lua") end, "file staged")
    H.wait(function()
      local line = vim.api.nvim_buf_get_lines(sidebar._file_buf, cursor(sidebar._file_win) - 1, cursor(sidebar._file_win), false)[1]
      return line:match("b%.lua")
    end, "cursor should move to the next unstaged file (b.lua)")
    H.git(repo, "reset", "-q", "--", "src/a.lua")
    H.wait(function()
      return vim.api.nvim_buf_get_lines(sidebar._file_buf, 0, 1, false)[1]:match("Staged Changes %(1%)")
    end, "panel picks up the reset")
  end },

  { "panels render to the window width and mark the open file", function()
    H.wait(function() return pcall(panel_row, "b%.lua") end)
    open_file("b%.lua", "src/b.lua")
    vim.api.nvim_win_set_width(sidebar._file_win, 55)
    vim.cmd("doautocmd WinResized")
    H.wait(function()
      local l = vim.api.nvim_buf_get_lines(sidebar._file_buf, panel_row("b%.lua") - 1, panel_row("b%.lua"), false)[1]
      return vim.fn.strdisplaywidth(l) == 55
    end, "badge should be right-aligned at the new width")
    local renders = 0
    local orig_render = fp.render
    fp.render = function(...) renders = renders + 1; return orig_render(...) end
    vim.api.nvim_win_set_height(sidebar._file_win, vim.api.nvim_win_get_height(sidebar._file_win) - 2)
    vim.cmd("doautocmd WinResized")
    fp.render = orig_render
    H.eq(renders, 0, "a height-only resize must not re-render the panel")

    local marks = vim.api.nvim_buf_get_extmarks(sidebar._file_buf,
      vim.api.nvim_create_namespace("diff_nvim_file_panel_active"), 0, -1, {})
    H.eq(#marks, 1)
    H.eq(marks[1][2] + 1, panel_row("b%.lua"))
  end },

  { "]f and [f walk the files of the section", function()
    vim.api.nvim_set_current_win(pane("new"))
    -- Display order: directories first (deep/…, src/…), then new.lua.
    press("]f")
    H.wait(function() return S().source.path == "new.lua" end, "]f to the next file")
    press("[f")
    H.wait(function() return S().source.path == "src/b.lua" end, "[f back")
    local seen = view_events
    press("[f")
    H.wait(function() return view_events > seen and S().source.path == "src/a.lua" end, "[f again")
  end },

  { "the view live-updates when the file changes on disk", function()
    open_file("a%.lua", "src/a.lua")
    vim.api.nvim_set_current_win(pane("new"))
    local idx = find_item(function(it) return it.row and S().model.rows[it.row].new == 80 end)
    vim.api.nvim_win_set_cursor(0, { idx, 0 })
    local wins = { S().header_win, pane("old"), pane("new") }
    local added = S().model.added
    local edited = vim.deepcopy(a_new)
    table.insert(edited, 1, "-- new first line")
    H.write(repo, "src/a.lua", H.text(edited))
    H.wait(function() return S().model.added == added + 1 end, "live refresh")
    H.eq({ S().header_win, pane("old"), pane("new") }, wins, "windows must survive a live refresh")
    H.eq(row(cursor(pane("new"))).new, 81, "cursor should follow its line (80 -> 81)")
    H.write(repo, "src/a.lua", H.text(a_new))
    H.wait(function() return S().model.added == added end, "live refresh back")
  end },

  { "a background refresh never cancels an open in flight", function()
    open_file("b%.lua", "src/b.lua")
    local seen = view_events
    fp.activate_line(panel_row("a%.lua"))  -- open starts loading…
    dv.refresh_content()                   -- …and a watcher refresh fires meanwhile
    vim.api.nvim_exec_autocmds("User", { pattern = "DiffNvimGitChanged" })
    H.wait(function() return view_events > seen and S().source.path == "src/a.lua" end,
      "the open must win over the refresh")
  end },

  { "gf opens the real file at the corresponding line", function()
    vim.api.nvim_set_current_win(pane("new"))
    local idx = find_item(function(it) return it.row and S().model.rows[it.row].new == 80 end)
    vim.api.nvim_win_set_cursor(0, { idx, 0 })
    local diff_tab = vim.api.nvim_get_current_tabpage()
    press("gf")
    H.eq(vim.api.nvim_buf_get_name(0), repo .. "/src/a.lua")
    H.eq(cursor(), 80)
    vim.cmd("bwipeout!")
    vim.api.nvim_set_current_tabpage(diff_tab)
  end },

  { "the git dir watcher catches every index write and commits, without self-triggering", function()
    local refreshes = 0
    local orig = sidebar.refresh
    sidebar.refresh = function(...) refreshes = refreshes + 1; return orig(...) end
    vim.wait(400)
    refreshes = 0
    for i = 1, 3 do
      H.write(repo, "src/b.lua", "return " .. (10 + i) .. "\n")
      H.git(repo, "add", "src/b.lua")
      H.wait(function() return refreshes >= i end, "refresh after git add #" .. i)
      vim.wait(250)
    end
    local settled = refreshes
    vim.wait(600)
    H.eq(refreshes, settled, "refreshes kept firing while idle (feedback loop)")

    H.git(repo, "commit", "-qm", "watched commit")
    H.wait(function()
      return vim.api.nvim_buf_get_lines(sidebar._commit_buf, 0, 1, false)[1]:match("watched commit")
    end, "commit panel should show the new commit")
    sidebar.refresh = orig
  end },

  { "expanding a commit uses two processes; its files open as diffs", function()
    local calls = H.count_git(function()
      cp.activate_line(1)
      H.wait(function() return pcall(panel_row, "b%.lua", sidebar._commit_buf) end, "commit expanded")
    end, 50)
    H.eq(#calls, 2, vim.inspect(calls))
    cp.activate_line(panel_row("b%.lua", sidebar._commit_buf))
    H.wait(function() return S().source and S().source.kind == "commit" and S().layout end, "commit diff")
    H.eq(vim.api.nvim_buf_get_lines(S().bufs.new, 0, -1, false), { "return 13" })
  end },

  { "selecting a branch checked out in another worktree shows that worktree's changes", function()
    local wt = vim.fn.resolve(vim.fn.tempname())
    H.git(repo, "worktree", "add", "-q", "-b", "wt-branch", wt)
    H.write(wt, "only-in-wt.lua", "return 0\n")
    local branches
    require("diff.git").list_branches(repo, function(b) branches = b end)
    H.wait(function() return branches end, "branches")
    local entry
    for _, b in ipairs(branches) do if b.name == "wt-branch" then entry = b end end
    H.eq(entry and vim.fn.resolve(entry.worktree), wt, "worktree path missing from branch list")

    sidebar.set_preview_branch("wt-branch", entry.worktree)
    H.wait(function() return pcall(panel_row, "only%-in%-wt%.lua") end, "worktree changes in file panel")
    H.eq(sidebar._preview_branch, nil)

    -- Back to the tree the interface was opened in.
    sidebar.set_preview_branch("main", repo)
    H.wait(function()
      return sidebar._repo_root == repo and not pcall(panel_row, "only%-in%-wt%.lua") and pcall(panel_row, "a%.lua")
    end, "home changes: " .. sidebar._repo_root .. "\n"
      .. table.concat(vim.api.nvim_buf_get_lines(sidebar._file_buf, 0, -1, false), "\n"))
    H.git(repo, "worktree", "remove", "--force", wt)
  end },

  { "hovering tints the clickable row and highlights draggable edges", function()
    open_file("a%.lua", "src/a.lua")
    local function marks(buf, ns)
      return vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_get_namespaces()[ns], 0, -1, { details = true })
    end
    -- Headless Neovim cannot place a synthetic pointer over a window, so the
    -- position is stubbed and a real <MouseMove> key is fed through.
    local real_getmousepos = vim.fn.getmousepos
    local function point(mp)
      vim.fn.getmousepos = function() return vim.tbl_extend("keep", mp, { line = 0, winrow = 1, wincol = 1 }) end
      press("<MouseMove>")
    end
    local function over_row(win, lnr, below)
      local row = vim.fn.screenpos(win, lnr, 1).row
      point({ winid = win, line = lnr, winrow = lnr, screenrow = row + (below and 1 or 0) })
    end
    local fp_ns, cp_ns = "diff_nvim_file_panel_hover", "diff_nvim_commit_hover"

    local row_a = panel_row("a%.lua")
    over_row(sidebar._file_win, row_a)
    H.wait(function() return #marks(sidebar._file_buf, fp_ns) == 1 end, "file row tinted")
    local mark = marks(sidebar._file_buf, fp_ns)[1]
    H.eq({ mark[2], mark[4].line_hl_group }, { row_a - 1, "DiffNvimHover" })

    -- The empty rows below the last line are not the last line.
    over_row(sidebar._file_win, vim.api.nvim_buf_line_count(sidebar._file_buf), true)
    H.wait(function() return #marks(sidebar._file_buf, fp_ns) == 0 end, "no tint below the rows")

    -- A commit tints both its header lines.
    over_row(sidebar._commit_win, 2)
    H.wait(function() return #marks(sidebar._commit_buf, cp_ns) == 2 end, "commit header tinted")

    -- A separator is tinted in both panes, with a hint; leaving the panel clears it.
    local sep = find_item(function(it) return it.sep end)
    over_row(pane("new"), sep)
    H.wait(function() return #marks(S().bufs.old, "diff_nvim_hover") == 1 end, "separator tinted")
    H.eq(#marks(sidebar._commit_buf, cp_ns), 0)
    local virt = marks(S().bufs.new, "diff_nvim_hover")[1][4].virt_text
    H.ok(virt[#virt][1]:match("click to expand"), vim.inspect(virt))
    over_row(pane("new"), find_item(function(it) return not it.sep end))
    H.wait(function() return #marks(S().bufs.new, "diff_nvim_hover") == 0 end, "separator untinted")

    -- Edges are painted by a float over exactly their cells.
    local function edge()
      local f = sidebar._edge_float()
      if not (f and vim.api.nvim_win_is_valid(f)) then return nil end
      local c = vim.api.nvim_win_get_config(f)
      local pos = vim.api.nvim_win_get_position(f)
      return { row = pos[1], col = pos[2], width = c.width, height = c.height, mouse = c.mouse }
    end
    local fw, cw = sidebar._file_win, sidebar._commit_win
    local fpos, cpos = vim.api.nvim_win_get_position(fw), vim.api.nvim_win_get_position(cw)
    local fh, ch = vim.api.nvim_win_get_height(fw), vim.api.nvim_win_get_height(cw)
    local width = vim.api.nvim_win_get_width(fw)

    -- The sidebar's edge runs down beside the mode bar and both panels,
    -- whichever is hovered.
    local bpos = vim.api.nvim_win_get_position(sidebar._bar_win)
    local sidebar_edge = { row = bpos[1], col = fpos[2] + width, width = 1,
      height = cpos[1] + ch - bpos[1], mouse = false }
    point({ winid = fw, wincol = width + 1 })
    H.wait(function() return vim.deep_equal(edge(), sidebar_edge) end, "sidebar edge: " .. vim.inspect(edge()))
    point({ winid = cw, wincol = width + 1, winrow = 3 })
    vim.wait(50)
    H.eq(edge(), sidebar_edge)

    -- The boundary between the panels is only that. With a status line per
    -- window it is that status line, tinted in place.
    local own = vim.wo[fw].winhighlight
    point({ winid = fw, winrow = fh + 1 })
    H.wait(function() return vim.wo[fw].winhighlight:match("StatusLineNC:DiffNvimEdgeHoverStatus") end,
      "status line tinted")
    H.eq(edge(), nil, "the vertical edge should not stay highlighted")
    point({ winid = cw, winrow = 1 }) -- off the edges
    H.wait(function() return vim.wo[fw].winhighlight == own end, "status line restored")

    -- With a global status line it is a separator line, painted like the
    -- vertical edge, and the junction where the two meet keeps its glyph.
    vim.o.laststatus = 3
    vim.cmd("redraw")
    fh = vim.api.nvim_win_get_height(fw)
    point({ winid = fw, winrow = fh + 1 })
    local boundary = { row = fpos[1] + fh, col = fpos[2], width = width, height = 1, mouse = false }
    H.wait(function() return vim.deep_equal(edge(), boundary) end, "panel boundary: " .. vim.inspect(edge()))
    point({ winid = fw, wincol = width + 1 })
    H.wait(function() return edge() and edge().width == 1 end, "vertical edge")
    local glyphs = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(sidebar._edge_float()), 0, -1, false)
    H.eq(glyphs[fpos[1] + fh - bpos[1] + 1], "┤", vim.inspect(glyphs))
    vim.o.laststatus = 2
    vim.cmd("redraw")

    -- The bottom status line resizes the command line: not a pane edge.
    point({ winid = cw, winrow = vim.api.nvim_win_get_height(cw) + 1 })
    H.wait(function() return edge() == nil end, "no edge at the bottom")
    vim.fn.getmousepos = real_getmousepos
  end },

  { "branch mode lists the branch's changes in a full-height panel, without the commit panel", function()
    local base = vim.trim(H.git(repo, "rev-parse", "--abbrev-ref", "HEAD"))
    H.git(repo, "checkout", "-q", "-b", "topic")
    H.write(repo, "topic.lua", "return 'topic'\n")
    H.git(repo, "add", "topic.lua")
    H.git(repo, "commit", "-qm", "topic work", "--", "topic.lua")

    local sidebar_h = vim.api.nvim_win_get_height(sidebar._file_win)
      + vim.api.nvim_win_get_height(sidebar._commit_win) + 1
    vim.api.nvim_set_current_win(sidebar._file_win)
    press("<leader>gB")
    H.wait(function() return pcall(panel_row, "topic%.lua") end, "branch changes listed")
    H.ok(panel_row("Branch Changes vs " .. base .. " %(1%)"))
    H.ok(not pcall(panel_row, "Staged"), "status sections should be gone")
    H.eq(sidebar._commit_win, nil)
    H.eq(vim.api.nvim_win_get_height(sidebar._file_win), sidebar_h)

    open_file("topic%.lua", "topic.lua")
    H.eq(S().source.kind, "range")
    H.eq(vim.api.nvim_buf_get_lines(S().bufs.new, 0, -1, false), { "return 'topic'" })
    H.ok(vim.api.nvim_buf_get_lines(S().header_buf, 0, 1, false)[1]:match("vs " .. base))

    -- Previewing a branch shows that branch's changes: none, for the base itself.
    sidebar.set_preview_branch(base)
    H.wait(function() return pcall(panel_row, "Branch Changes vs .*%(0%)") end, "preview's branch changes")
    sidebar.set_preview_branch(nil)
    H.wait(function() return pcall(panel_row, "topic%.lua") end, "HEAD's branch changes again")

    press("<leader>gB")
    H.wait(function() return pcall(panel_row, "Staged") end, "status back")
    H.ok(vim.api.nvim_win_is_valid(sidebar._commit_win), "commit panel back")
    H.wait(function()
      return vim.api.nvim_buf_get_lines(sidebar._commit_buf, 0, 1, false)[1]:match("topic work")
    end, "commit panel filled")
    H.git(repo, "checkout", "-q", base)
  end },

  { "branch mode: the diff is cached, follows commits, and the split and cursor survive", function()
    local base = vim.trim(H.git(repo, "rev-parse", "--abbrev-ref", "HEAD"))
    H.git(repo, "checkout", "-q", "topic")
    vim.api.nvim_win_set_height(sidebar._commit_win, 7)
    vim.api.nvim_set_current_win(sidebar._file_win)
    H.wait(function() return pcall(panel_row, "a%.lua") end, "status listed")
    vim.api.nvim_win_set_cursor(sidebar._file_win, { panel_row("a%.lua"), 0 })

    sidebar.toggle_branch_mode()
    H.wait(function() return pcall(panel_row, "topic%.lua") end, "branch changes")
    vim.wait(300) -- the switch's own refresh
    -- Nothing moved: one rev-parse, no diff.
    local calls = H.count_git(function() sidebar.refresh() end, 150)
    H.eq(calls, { "rev-parse HEAD refs/heads/" .. base }, vim.inspect(calls))

    -- A commit to the open file: the open diff follows the branch tip.
    open_file("topic%.lua", "topic.lua")
    H.write(repo, "topic.lua", "return 'topic v2'\n")
    H.git(repo, "commit", "-qm", "topic v2", "--", "topic.lua")
    H.wait(function()
      return vim.deep_equal(vim.api.nvim_buf_get_lines(S().bufs.new, 0, -1, false), { "return 'topic v2'" })
    end, "range diff followed the commit")
    H.eq(S().source.kind, "range")

    sidebar.toggle_branch_mode()
    H.wait(function() return pcall(panel_row, "Staged") end, "changes again")
    H.eq(vim.api.nvim_win_get_height(sidebar._commit_win), 7, "commit panel height")
    H.eq(vim.api.nvim_win_get_cursor(sidebar._file_win)[1], panel_row("a%.lua"), "cursor back on a.lua")
    H.git(repo, "checkout", "-q", base)
  end },

  { "a burst of background refreshes runs one at a time", function()
    vim.wait(300)
    local calls = H.count_git(function()
      for _ = 1, 10 do sidebar.refresh({ coalesce = true }) end
    end, 400)
    -- One refresh now and one queued: two rounds of status + diffstat + log.
    H.ok(#calls <= 8, #calls .. " git processes: " .. vim.inspect(calls))
  end },

  { "the mode bar shows the branch, switches modes and leaves a preview", function()
    local base = vim.trim(H.git(repo, "rev-parse", "--abbrev-ref", "HEAD"))
    local mb = require("diff.mode_bar")
    local function bar() return vim.api.nvim_buf_get_lines(sidebar._bar_buf, 0, -1, false) end
    local function col_of(row, text)
      local l = bar()[row]
      return vim.fn.strdisplaywidth(l:sub(1, l:find(text, 1, true) - 1)) + 1
    end
    H.wait(function() return bar()[1]:match("⎇ " .. vim.pesc(base)) end, "branch name: " .. vim.inspect(bar()))
    H.eq(vim.api.nvim_win_get_height(sidebar._bar_win), mb.HEIGHT)

    -- Items are tinted under the pointer, like rows.
    local real_getmousepos = vim.fn.getmousepos
    vim.fn.getmousepos = function()
      return { winid = sidebar._bar_win, line = 2, winrow = 2, wincol = col_of(2, "Branch changes"),
        screenrow = vim.fn.screenpos(sidebar._bar_win, 2, 1).row }
    end
    press("<MouseMove>")
    local ns = vim.api.nvim_get_namespaces()["diff_nvim_mode_bar_hover"]
    H.wait(function() return #vim.api.nvim_buf_get_extmarks(sidebar._bar_buf, ns, 0, -1, {}) == 1 end, "item tinted")
    vim.fn.getmousepos = real_getmousepos

    H.ok(mb.click(2, col_of(2, "Branch changes")))
    H.wait(function() return pcall(panel_row, "Branch Changes vs") end, "branch mode")
    H.eq(mb.click(2, col_of(2, "Branch changes")), false, "the active mode is not a button")
    H.ok(mb.click(2, col_of(2, "Changes")))
    H.wait(function() return pcall(panel_row, "Staged") end, "changes mode")
    H.eq(sidebar._branch_mode, false)

    sidebar.set_preview_branch("topic")
    H.wait(function() return bar()[1]:match("⎇ topic %(preview%)") and bar()[1]:match("✕") end,
      "preview shown: " .. vim.inspect(bar()))
    H.ok(mb.click(1, col_of(1, "✕")))
    H.wait(function() return sidebar._preview_branch == nil and bar()[1]:match(vim.pesc(base)) end, "home again")
    H.ok(not bar()[1]:match("✕"))

    -- The branch opens the picker.
    H.ok(mb.click(1, 3))
    H.wait(function()
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_config(w).relative ~= "" then
          local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false), "\n")
          if text:match("topic") then return true end
        end
      end
    end, "branch picker")
    require("diff.branch_picker").close()
  end },

  { "closing tears everything down and restores user mappings", function()
    local tabs = #vim.api.nvim_list_tabpages()
    require("diff").toggle()
    H.eq(#vim.api.nvim_list_tabpages(), tabs - 1)
    H.eq(S().source, nil)
    H.eq(S().watcher, nil)
    H.eq(vim.o.mousemoveevent, false, "'mousemoveevent' should be restored")
    local m = vim.fn.maparg("<leader>gb", "n", false, true)
    H.eq(m.desc, "user mapping")
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      H.ok(not vim.api.nvim_buf_get_name(b):match("^diff://"), "leaked buffer " .. vim.api.nvim_buf_get_name(b))
    end
  end },

  { "'mousemoveevent' is only on in the interface tab; :tabclose cleans up", function()
    require("diff").open()
    H.wait(function() return sidebar.is_open() end, "open")
    H.eq(vim.o.mousemoveevent, true)
    local diff_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd("tabnew")
    H.eq(vim.o.mousemoveevent, false, "other tabs keep the user's setting")
    vim.api.nvim_set_current_tabpage(diff_tab)
    H.eq(vim.o.mousemoveevent, true)
    vim.cmd("tabclose")
    H.eq(sidebar.is_open(), false)
    H.eq(vim.o.mousemoveevent, false)
    H.eq(vim.fn.maparg("<leader>gb", "n", false, true).desc, "user mapping")
    vim.cmd("tabonly")
  end },

  { "a terminal too small for the interface leaves nothing behind", function()
    local lines = vim.o.lines
    vim.o.lines = 6
    local tabs = #vim.api.nvim_list_tabpages()
    local notified
    local notify = vim.notify
    vim.notify = function(msg) notified = msg end
    require("diff").open()
    vim.wait(200)
    vim.notify = notify
    vim.o.lines = lines
    H.ok(notified and notified:match("not enough room"), tostring(notified))
    H.eq(#vim.api.nvim_list_tabpages(), tabs)
    H.eq(sidebar.is_open(), false)
    H.eq(vim.o.mousemoveevent, false)
  end },
}
