local H = require("helpers")

-- main: a.lua with 6 lines; feature: line 3 changed and a line added after 5.
local repo = H.repo({ ["a.lua"] = H.text(H.lines(6)) })
H.git(repo, "branch", "-M", "main")
H.git(repo, "branch", "develop")
H.git(repo, "checkout", "-q", "-b", "feature")
local new_lines = H.lines(6, { [3] = "line 3 changed" })
table.insert(new_lines, 6, "line inserted")
H.write(repo, "a.lua", H.text(new_lines))
H.git(repo, "commit", "-qam", "change")
local head = vim.trim(H.git(repo, "rev-parse", "HEAD"))

vim.cmd("cd " .. repo)
require("diff").setup({})

local gh = require("diff.gh")
local github = require("diff.github")
local pr = require("diff.pr")
local dv = require("diff.diff_view")
local pr_thread = require("diff.pr_thread")
local compose = require("diff.compose")
local clickable = require("diff.clickable")

local calls = {}
local function later(cb, ...)
  local args = { ... }
  vim.schedule(function() cb(unpack(args, 1, 2)) end)
end

local thread = {
  id = "T1", path = "a.lua", side = "new", line = 3, original_line = 3, outdated = false, resolved = false,
  pending = false, commit = head, can_reply = true, can_resolve = true, can_unresolve = false,
  comments = { { id = "C1", author = "alice", body = "Is this right?", created_at = "2026-01-01T00:00:00Z",
    pending = false, commit = head, can_update = false, can_delete = false } },
}
local extra_threads = {}
local function review()
  local threads = { vim.deepcopy(thread) }
  vim.list_extend(threads, vim.deepcopy(extra_threads))
  return {
    pr = { id = "PR_1", number = 7, head_oid = head, base_name = "develop", branch = "feature" },
    commits = { [head] = true }, pending = nil, threads = threads,
  }
end

gh.authenticated = function(_, cb) later(cb, true) end
github.find_pull_request = function(_, _, cb) later(cb, review().pr) end
github.fetch_review = function(_, _, cb) table.insert(calls, "fetch"); later(cb, review()) end
github.set_resolved = function(_, id, v, cb) table.insert(calls, "resolve " .. id .. " " .. tostring(v)); later(cb, true) end
github.start_review = function(_, _, commit, cb) table.insert(calls, "start " .. commit); later(cb, "R1") end
github.add_thread = function(_, id, anchor, body, cb)
  table.insert(calls, string.format("thread %s %s %s:%d %s", id, anchor.path, anchor.side, anchor.line, body))
  later(cb, { thread = "T2", comment = "C2" })
end

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

local S = dv._state

--- The new pane's row (1-based) showing new-side line `n`.
local function row_of_new(n)
  for i, item in ipairs(S().layout.items) do
    local r = item.row and S().model.rows[item.row]
    if r and r.new == n and item.side ~= "old" then return i end
  end
end

local function thread_marks(buf)
  local ns = vim.api.nvim_create_namespace("diff_nvim_pr_threads")
  return vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
end

return {
  { "the branch's changes show a thread's sign and first comment on its line", function()
    pr.sync(repo, nil)
    H.wait(function() return pr._state().review ~= nil end, "review loaded")
    local old_blob = vim.trim(H.git(repo, "rev-parse", "main:a.lua"))
    local new_blob = vim.trim(H.git(repo, "rev-parse", "HEAD:a.lua"))
    dv.open(repo, { kind = "range", path = "a.lua", status = "modified", old_blob = old_blob,
      new_blob = new_blob, base = "main", head = "HEAD" })
    H.wait(function() return S().layout ~= nil end, "diff open")
    local marks = thread_marks(S().bufs.new)
    H.eq(#marks, 1)
    H.eq(marks[1][2], row_of_new(3) - 1, "on new line 3")
    H.ok(marks[1][4].virt_text[1][1]:find("alice: Is this right?", 1, true), vim.inspect(marks[1][4].virt_text))
    H.eq(#thread_marks(S().bufs.old), 0, "the old side has none")
  end },

  { "K opens the line's thread under it", function()
    local win = S().panes.new
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { row_of_new(3), 0 })
    feed("K")
    H.ok(pr_thread.is_open(), "thread float open")
    local text = table.concat(vim.api.nvim_buf_get_lines(pr_thread._state().buf, 0, -1, false), "\n")
    H.ok(text:find("Is this right?", 1, true), text)
    H.ok(text:find("Resolve", 1, true), text)
    pr_thread.close()
  end },

  { "K on a line without comments keeps its own meaning", function()
    local win = S().panes.new
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { row_of_new(1), 0 })
    vim.api.nvim_create_user_command("ReviewSpecKeyword", function(o) vim.g.keyword_looked_up = o.args end, { nargs = "*" })
    vim.o.keywordprg = ":ReviewSpecKeyword"
    feed("K")
    H.eq(pr_thread.is_open(), false)
    H.eq(vim.g.keyword_looked_up, "line")
  end },

  { "K on a line without comments runs the user's own K mapping", function()
    local win = S().panes.new
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { row_of_new(1), 0 })
    vim.g.global_k = nil
    vim.keymap.set("n", "K", function() vim.g.global_k = true end)
    feed("K")
    vim.keymap.del("n", "K")
    H.eq(vim.g.global_k, true)
    H.eq(pr_thread.is_open(), false)
  end },

  { "clicking a thread's sign opens it; clicking its Resolve button resolves it", function()
    local win = S().panes.new
    H.eq(dv.click(win, row_of_new(4), 1), false, "a line without threads")
    local text = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), row_of_new(3) - 1, row_of_new(3), false)[1]
    H.eq(dv.click(win, row_of_new(3), 40, #text), false, "a click on the text")
    H.ok(dv.click(win, row_of_new(3), 40, #text + 1), "a click past the end of the text, however it wraps")
    pr_thread.close()
    H.ok(dv.click(win, row_of_new(3), 1), "click on the sign")
    local s = pr_thread._state()
    local lines = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
    local at
    for i, l in ipairs(lines) do
      local c = l:find(" Resolve ", 1, true)
      if c then at = { i, vim.api.nvim_strwidth(l:sub(1, c - 1)) + 1, vim.api.nvim_strwidth(" Resolve ") } end
    end
    H.ok(at, "a Resolve button")
    -- Window columns count the float's left border: the button spans
    -- columns at+1 .. at+width, not the cell before it.
    H.eq(clickable.item_at(s.win, at[1], at[2]), nil, "the cell before the button")
    H.ok(clickable.item_at(s.win, at[1], at[2] + at[3]), "the button's last cell")
    calls = {}
    H.ok(clickable.click(s.win, at[1], at[2] + 1))
    H.wait(function() return #calls >= 2 end, "resolve and reload")
    H.eq(calls, { "resolve T1 true", "fetch" })
    pr_thread.close()
  end },

  { "in the unified view, a context row opens the threads of both its sides", function()
    local function side_thread(id, side)
      return vim.tbl_extend("force", vim.deepcopy(thread), { id = id, side = side, line = 2,
        comments = { vim.tbl_extend("force", thread.comments[1], { id = "C" .. id, body = "on " .. side }) } })
    end
    extra_threads = { side_thread("TO", "old"), side_thread("TN", "new") }
    pr.reload()
    dv.set_layout("unified")
    H.wait(function() return S().panes.unified ~= nil end, "unified")
    local row
    for i, item in ipairs(S().layout.items) do
      local r = item.row and S().model.rows[item.row]
      if r and r.old == 2 and r.new == 2 then row = i end
    end
    H.wait(function() return #thread_marks(S().bufs.unified) >= 2 end, "marks drawn")
    local on_row = 0
    for _, m in ipairs(thread_marks(S().bufs.unified)) do
      if m[2] == row - 1 then on_row = on_row + 1 end
    end
    H.eq(on_row, 1, "one mark for both sides")
    H.ok(dv.click(S().panes.unified, row, 1))
    H.ok(pr_thread.is_open(), "open after click")
    local text = table.concat(vim.api.nvim_buf_get_lines(pr_thread._state().buf, 0, -1, false), "\n")
    H.ok(text:find("on old", 1, true) and text:find("on new", 1, true), text)
    pr_thread.close()
    extra_threads = {}
    pr.reload()
    dv.set_layout("split")
  end },

  { "a comment on a line starts a review on the pull request's head", function()
    local win = S().panes.new
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { row_of_new(6), 0 })
    feed("\\c")
    H.wait(function() return compose.is_open() end, "comment editor open")
    local s = compose._state()
    vim.api.nvim_buf_set_lines(s.editor_buf, 0, -1, false, { "Why insert this?" })
    vim.cmd("stopinsert")
    calls = {}
    feed("<CR>")
    H.eq(compose.is_open(), false, "closes at once")
    H.wait(function() return calls[#calls] == "fetch" end, "sent, then the review read again")
    H.eq(calls, { "start " .. head, "thread R1 a.lua new:6 Why insert this?", "fetch" })
  end },

  { "the mode bar names the pull request and opens its review", function()
    dv.close()
    require("diff").open()
    local sidebar = require("diff.sidebar")
    H.wait(function() return sidebar.is_open() end, "interface open")
    local bar = sidebar._bar_buf
    H.wait(function()
      return (vim.api.nvim_buf_get_lines(bar, 0, 1, false)[1] or ""):find("#7", 1, true) ~= nil
    end, "pull request in the branch row")
    local line = vim.api.nvim_buf_get_lines(bar, 0, 1, false)[1]
    local col = vim.api.nvim_strwidth(line:sub(1, line:find("#7", 1, true) - 1)) + 1
    H.ok(require("diff.mode_bar").click(1, col), "the label is a button")
    H.wait(function() return compose.is_open() end, "review float open")
    local title = vim.api.nvim_win_get_config(compose._state().editor).title
    H.ok(vim.inspect(title):find("Review #7", 1, true), vim.inspect(title))
    compose.close()
  end },

  { "the pointer on a float's border is not on a draggable edge", function()
    local sidebar = require("diff.sidebar")
    require("diff.review_ui").open_review()
    local float = compose._state().editor
    local errors = {}
    local real_getmousepos, real_notify = vim.fn.getmousepos, vim.notify
    vim.notify = function(m, l) if l == vim.log.levels.ERROR then table.insert(errors, m) end end
    -- One past the float's width and height: where a split's edges would be.
    for _, mp in ipairs({
      { wincol = vim.api.nvim_win_get_width(float) + 1, winrow = 1 },
      { wincol = 1, winrow = vim.api.nvim_win_get_height(float) + 1 },
    }) do
      vim.fn.getmousepos = function() return vim.tbl_extend("force", { winid = float, line = 0, screenrow = 1 }, mp) end
      feed("<MouseMove>")
      vim.wait(50)
    end
    vim.fn.getmousepos, vim.notify = real_getmousepos, real_notify
    H.eq(errors, {})
    H.eq(sidebar._edge_float(), nil, "no edge highlighted")
    compose.close()
  end },

  { "the branch's changes are measured from the pull request's base", function()
    local sidebar = require("diff.sidebar")
    local fp = require("diff.file_panel")
    local row2 = vim.api.nvim_buf_get_lines(sidebar._bar_buf, 1, 2, false)[1]
    H.ok(row2:find("Since develop", 1, true), row2)
    sidebar.toggle_branch_mode()
    H.wait(function() return fp.branch_base() == "develop" end, "branch mode on develop")
    require("diff").close()
  end },

  { "the review float lists the draft comments under the summary, scrollably", function()
    local function draft(id, line, body)
      return vim.tbl_extend("force", vim.deepcopy(thread), { id = id, line = line, pending = true,
        comments = { vim.tbl_extend("force", thread.comments[1], { id = "C" .. id, body = body, pending = true }) } })
    end
    extra_threads = {}
    for i = 1, 30 do table.insert(extra_threads, draft("D" .. i, 40 - i, "draft number " .. i .. "\nsecond line")) end
    pr.sync(repo, nil, { force = true })
    H.wait(function() return pr._state().review ~= nil and #pr.drafts() == 30 end, "drafts loaded")
    require("diff.review_ui").open_review()
    local s = compose._state()
    H.ok(s.list and vim.api.nvim_win_is_valid(s.list), "a list window")
    local function top(w) return vim.api.nvim_win_get_position(w)[1] end
    H.ok(top(s.editor) < top(s.bar) and top(s.bar) < top(s.list), "editor, then buttons, then the list")
    local buf = vim.api.nvim_win_get_buf(s.list)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    H.eq(lines[1], " a.lua line 10")
    H.eq(lines[2], "   draft number 30", "the text, nearest line first")
    H.eq(lines[3], "   second line")
    H.ok(vim.api.nvim_win_get_height(s.list) < #lines, "taller than its window: it scrolls")
    H.eq(vim.api.nvim_get_current_win(), s.editor, "the editor keeps focus")
    vim.cmd("stopinsert")
    feed("<S-Tab>")
    H.eq(vim.api.nvim_get_current_win(), s.list)
    feed("G")
    H.ok(vim.fn.line("w0", s.list) > 1, "scrolled")
    feed("<Tab>")
    H.eq(vim.api.nvim_get_current_win(), s.editor)
    compose.close()
    H.ok(not vim.api.nvim_win_is_valid(s.list), "closes with the editor")
    extra_threads = {}
    pr.reload()
  end },

  { "with draft comments, the summary may be empty for a comment or a request for changes; without, only for an approval", function()
    local function allowed(drafts)
      extra_threads = {}
      for i = 1, drafts do
        table.insert(extra_threads, vim.tbl_extend("force", vim.deepcopy(thread), { id = "E" .. i, line = 40 - i, pending = true,
          comments = { vim.tbl_extend("force", thread.comments[1], { id = "CE" .. i, body = "d", pending = true }) } }))
      end
      pr.sync(repo, nil, { force = true })
      H.wait(function() return pr._state().review ~= nil and #pr.drafts() == drafts end, "drafts loaded")
      require("diff.review_ui").open_review()
      local out = {}
      for _, b in ipairs(compose._state().opts.buttons) do out[b.label] = b.allow_empty or false end
      compose.close()
      return out
    end
    local with = allowed(2)
    H.eq({ with["Comment"], with["Request changes"], with["Approve"] }, { true, true, true })
    local without = allowed(0)
    H.eq({ without["Comment"], without["Request changes"], without["Approve"] }, { false, false, true })
    extra_threads = {}
    pr.reload()
  end },

  { "a review float opened on one pull request refuses to act on another, keeping the text", function()
    pr.sync(repo, nil)
    H.wait(function() return pr._state().review ~= nil end, "review loaded")
    require("diff.review_ui").open_review()
    local s = compose._state()
    vim.api.nvim_buf_set_lines(s.editor_buf, 0, -1, false, { "Looks good" })
    vim.cmd("stopinsert")
    pr._state().pr = vim.tbl_extend("force", pr._state().pr, { id = "PR_2", number = 8 })
    local msgs = {}
    local notify = vim.notify
    vim.notify = function(m) table.insert(msgs, m) end
    feed("<CR>")
    vim.notify = notify
    H.eq(compose.is_open(), true)
    H.eq(vim.api.nvim_buf_get_lines(s.editor_buf, 0, -1, false), { "Looks good" })
    H.ok(msgs[1] and msgs[1]:find("changed"), vim.inspect(msgs))
    compose.close()
    pr.clear()
  end },

  { "a working-tree diff takes no comments, and says why", function()
    pr.sync(repo, nil)
    H.wait(function() return pr._state().review ~= nil end, "review loaded")
    H.write(repo, "a.lua", "edited\n")
    dv.open(repo, { kind = "worktree", path = "a.lua", status = "modified", staged = false })
    H.wait(function() return S().source and S().source.kind == "worktree" and S().layout end, "worktree diff")
    vim.api.nvim_set_current_win(S().panes.new)
    vim.api.nvim_win_set_cursor(S().panes.new, { row_of_new(1), 0 })
    local msgs = {}
    local notify = vim.notify
    vim.notify = function(m) table.insert(msgs, m) end
    feed("\\c")
    vim.wait(200, function() return #msgs > 0 end)
    vim.notify = notify
    H.eq(compose.is_open(), false)
    H.ok(msgs[1] and msgs[1]:find("uncommitted"), vim.inspect(msgs))
  end },
}
