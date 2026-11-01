local H = require("helpers")
local gh = require("diff.gh")
local github = require("diff.github")
local pr = require("diff.pr")
local actions = require("diff.review_actions")

local repo = H.repo({ ["a.lua"] = "one\n" })
local head = vim.trim(H.git(repo, "rev-parse", "HEAD"))
local TARGET = { pr_id = "PR_1", commit = head }

local calls = {}
local responses = {}   -- request name -> { result, err } to answer with
local held = {}        -- request name -> true: answer only when released
local waiting = {}     -- held answers: { name, fn }

--- GitHub as the tests script it: each request is logged, then answered on
--- the next tick (or held until released) with what `responses` says.
local function answer(name, cb, default)
  local r = responses[name] or { default }
  local function reply() cb(r[1], r[2]) end
  if held[name] then
    table.insert(waiting, { name = name, fn = reply })
  else
    vim.schedule(reply)
  end
end

local function release(name)
  for i, w in ipairs(waiting) do
    if w.name == name then
      table.remove(waiting, i)
      vim.schedule(w.fn)
      return
    end
  end
  error("nothing held for " .. name)
end

local review
local function fresh_review()
  return {
    pr = { id = "PR_1", number = 7, head_oid = head, base_name = "main", branch = "feature" },
    viewer = "me", commits = { [head] = true }, commits_complete = true, pending = nil,
    threads = { {
      id = "T1", path = "a.lua", side = "new", line = 1, original_line = 1, outdated = false, resolved = false,
      pending = false, commit = head, can_reply = true, can_resolve = true,
      comments = { { id = "C1", author = "alice", body = "hm", pending = false } },
    } },
  }
end

gh.authenticated = function(_, cb) vim.schedule(function() cb(true) end) end
github.find_pull_request = function(_, _, cb) vim.schedule(function() cb(review.pr) end) end
github.fetch_review = function(_, _, cb)
  table.insert(calls, "fetch")
  answer("fetch", cb, vim.deepcopy(review))
end
github.start_review = function(_, _, commit, cb) table.insert(calls, "start " .. commit:sub(1, 7)); answer("start", cb, "R_new") end
github.add_thread = function(_, rid, anchor, body, cb)
  table.insert(calls, string.format("thread %s %s:%d %s", rid, anchor.side, anchor.line, body))
  answer("thread", cb, { thread = "T_new", comment = "C_new" })
end
github.reply = function(_, tid, body, rid, cb)
  table.insert(calls, string.format("reply %s %s %s", tid, body, tostring(rid)))
  answer("reply", cb, "C_reply")
end
github.set_resolved = function(_, tid, v, cb) table.insert(calls, "resolve " .. tid .. " " .. tostring(v)); answer("resolve", cb, true) end
github.update_comment = function(_, cid, body, cb) table.insert(calls, "update " .. cid .. " " .. body); answer("update", cb, true) end
github.delete_comment = function(_, cid, cb) table.insert(calls, "delete " .. cid); answer("delete", cb, true) end
github.delete_review = function(_, rid, cb) table.insert(calls, "delete review " .. rid); answer("delete_review", cb, true) end
github.submit_review = function(_, rid, ev, _, cb) table.insert(calls, "submit " .. rid .. " " .. ev); answer("submit", cb, "COMMENTED") end
github.post_review = function(_, _, _, ev, _, cb) table.insert(calls, "post " .. ev); answer("post", cb, "APPROVED") end

local notices = {}
vim.notify = function(msg, level) table.insert(notices, { msg = msg, level = level }) end

local function load()
  pr.clear()
  calls, responses, held, waiting, notices = {}, {}, {}, {}, {}
  pr.sync(repo, nil, { head = "feature" })
  H.wait(function() return pr._state().review ~= nil and not pr.loading() end, "review loaded")
  calls = {}
end

local function settled()
  H.wait(function() return not actions.busy() end, "queue empty")
  H.wait(function() return calls[#calls] == "fetch" end, "review read again")
  vim.wait(20)
end

local function find_thread(id)
  for _, t in ipairs(pr._state().review.threads) do if t.id == id then return t end end
end

return {
  { "a comment shows at once, before GitHub answers, and gets GitHub's ids", function()
    review = fresh_review()
    load()
    held.start = true
    H.eq(actions.add_comment(TARGET, { path = "a.lua", side = "new", line = 1 }, "why?"), nil)
    local threads = pr._state().review.threads
    local mine = threads[#threads]
    H.eq({ mine.pending, mine.comments[1].body, mine.comments[1].author }, { true, "why?", "me" })
    H.eq(pr.pending().count, 1, "the mode bar can count it already")
    H.ok(mine.id:match("^local:"), "not on GitHub yet")
    release("start")
    H.wait(function() return mine.id == "T_new" end, "GitHub's thread id")
    H.eq(mine.comments[1].id, "C_new")
    settled()
    H.eq(calls, { "start " .. head:sub(1, 7), "thread R_new new:1 why?", "fetch" })
  end },

  { "requests run in order: a reply to a new comment waits for it to exist", function()
    review = fresh_review()
    load()
    held.thread = true
    actions.add_comment(TARGET, { path = "a.lua", side = "new", line = 1 }, "first")
    local threads = pr._state().review.threads
    local mine = threads[#threads]
    actions.reply(mine, "second")
    H.eq(#mine.comments, 2, "the reply shows at once")
    H.wait(function() return #waiting > 0 end, "comment request sent")
    vim.wait(30)
    H.eq(calls, { "start " .. head:sub(1, 7), "thread R_new new:1 first" }, "the reply has not been sent")
    release("thread")
    settled()
    H.eq(calls, { "start " .. head:sub(1, 7), "thread R_new new:1 first", "reply T_new second R_new", "fetch" })
  end },

  { "a failure says what failed, keeps the text, and the review catches up with GitHub", function()
    review = fresh_review()
    load()
    responses.thread = { nil, "Line could not be resolved" }
    actions.add_comment(TARGET, { path = "a.lua", side = "new", line = 9 }, "lost words")
    settled()
    H.eq(calls, { "start " .. head:sub(1, 7), "thread R_new new:9 lost words", "delete review R_new", "fetch" })
    local n = notices[#notices]
    H.eq(n.level, vim.log.levels.ERROR)
    H.ok(n.msg:find("add your comment on a.lua line 9", 1, true) and n.msg:find("Line could not be resolved", 1, true), n.msg)
    H.eq(vim.fn.getreg('"'), "lost words")
    H.eq(pr.pending(), nil, "the failed draft is gone again")
    H.eq(#pr._state().review.threads, 1)
  end },

  { "an action on a comment that never reached GitHub fails with a reason, not an id", function()
    review = fresh_review()
    load()
    responses.thread = { nil, "nope" }
    held.thread = true
    actions.add_comment(TARGET, { path = "a.lua", side = "new", line = 1 }, "x")
    local threads = pr._state().review.threads
    actions.reply(threads[#threads], "y")
    H.wait(function() return #waiting > 0 end, "comment request sent")
    release("thread")
    settled()
    H.ok(notices[#notices].msg:find("never created on GitHub", 1, true), notices[#notices].msg)
  end },

  { "resolving, editing and deleting show at once", function()
    review = fresh_review()
    load()
    local t = find_thread("T1")
    actions.set_resolved(t, true)
    H.eq(t.resolved, true)
    actions.edit_comment(t.comments[1], "better")
    H.eq(t.comments[1].body, "better")
    actions.delete_comment(t.comments[1])
    H.eq(find_thread("T1"), nil, "a thread left with no comments goes")
    settled()
    H.eq(calls, { "resolve T1 true", "update C1 better", "delete C1", "fetch" })
  end },

  { "a comment written for one pull request is not sent to another", function()
    review = fresh_review()
    load()
    local err = actions.add_comment({ pr_id = "PR_other", commit = head }, { path = "a.lua", side = "new", line = 1 }, "x")
    H.ok(err and err:find("changed"), tostring(err))
    vim.wait(50)
    H.eq(calls, {})
  end },

  { "an empty draft review on another commit is replaced", function()
    review = fresh_review()
    review.pending = { id = "R_empty", commit = "c_old", count = 0 }
    load()
    actions.add_comment(TARGET, { path = "a.lua", side = "new", line = 1 }, "hi")
    settled()
    H.eq(calls, { "delete review R_empty", "start " .. head:sub(1, 7), "thread R_new new:1 hi", "fetch" })
  end },

  { "discarding removes the drafts at once, and they stay gone while GitHub still lists them", function()
    review = fresh_review()
    review.pending = { id = "R_draft", commit = head, count = 2 }
    table.insert(review.threads, { id = "TD", path = "a.lua", side = "new", line = 2, pending = true, commit = head,
      comments = { { id = "CD", pending = true, body = "draft" } } })
    table.insert(review.threads[1].comments, { id = "CR", pending = true, body = "draft reply" })
    load()
    H.eq(#pr.drafts(), 2)
    actions.discard()
    H.eq(pr.pending(), nil)
    H.eq(pr.drafts(), {})
    -- GitHub keeps answering with the draft review after deleting it.
    settled()
    H.eq(calls, { "delete review R_draft", "fetch" })
    H.eq(pr.drafts(), {}, "still gone after reading GitHub")
    H.eq(find_thread("TD"), nil)
  end },

  { "discarding drafts that are already gone on GitHub is no failure", function()
    review = fresh_review()
    review.pending = { id = "R_stale", commit = head, count = 1 }
    load()
    review.pending = nil
    responses.delete_review = { nil, "Could not resolve to a node with the global id of 'R_stale'" }
    actions.discard()
    settled()
    for _, n in ipairs(notices) do H.ok(n.level ~= vim.log.levels.ERROR, n.msg) end
  end },

  { "submitting publishes the drafts at once, and they stay published while GitHub still lists them", function()
    review = fresh_review()
    review.pending = { id = "R_sub", commit = head, count = 1 }
    table.insert(review.threads, { id = "TS", path = "a.lua", side = "new", line = 3, pending = true, commit = head,
      comments = { { id = "CS", pending = true, body = "draft" } } })
    load()
    H.eq(actions.submit("comment", ""), nil)
    H.eq(pr.pending(), nil)
    H.eq(find_thread("TS").comments[1].pending, false)
    settled()
    H.eq(calls, { "submit R_sub COMMENT", "fetch" })
    H.eq(pr.drafts(), {})
    H.ok(find_thread("TS"), "kept, as submitted")
  end },

  { "a failed submit brings the drafts back", function()
    review = fresh_review()
    review.pending = { id = "R_sub", commit = head, count = 1 }
    table.insert(review.threads, { id = "TS", path = "a.lua", side = "new", line = 3, pending = true, commit = head,
      comments = { { id = "CS", pending = true, body = "draft" } } })
    load()
    responses.submit = { nil, "Can not approve your own pull request" }
    actions.submit("approve", "lgtm")
    H.eq(pr.pending(), nil, "shown as submitted at first")
    settled()
    H.eq(pr.pending() and pr.pending().id, "R_sub", "back once GitHub said no")
    H.eq(vim.fn.getreg('"'), "lgtm")
    H.ok(notices[#notices].msg:find("submit your review", 1, true), notices[#notices].msg)
  end },

  { "a read of the review that started before a new comment does not undo it", function()
    review = fresh_review()
    load()
    held.fetch = true
    actions.edit_comment(find_thread("T1").comments[1], "edited")
    H.wait(function() return calls[#calls] == "fetch" end, "the review read as the queue emptied")
    held.start = true
    actions.add_comment(TARGET, { path = "a.lua", side = "new", line = 1 }, "kept")
    release("fetch")
    vim.wait(30)
    local threads = pr._state().review.threads
    H.eq(threads[#threads].comments[1].body, "kept", "still shown")
    H.eq(pr.pending().count, 1)
    actions.add_comment(TARGET, { path = "a.lua", side = "new", line = 1 }, "second")
    held.fetch = false
    release("start")
    settled()
    local starts = vim.tbl_filter(function(c) return c:match("^start") end, calls)
    H.eq(#starts, 1, "one draft review started")
  end },

  { "after the draft review failed to start, a reply is not published and a submit posts a plain review", function()
    review = fresh_review()
    load()
    responses.start = { nil, "no" }
    actions.add_comment(TARGET, { path = "a.lua", side = "new", line = 1 }, "x")
    actions.reply(find_thread("T1"), "y")
    actions.submit("approve", "")
    settled()
    H.eq(vim.tbl_filter(function(c) return c:match("^reply") end, calls), {}, "the reply was not sent")
    H.ok(vim.tbl_contains(calls, "post APPROVE"), vim.inspect(calls))
    H.ok(notices[#notices - 1].msg:find("never created", 1, true) or notices[#notices].msg:find("never created", 1, true))
  end },

  { "a draft review with comments is kept even when GitHub does not say its commit", function()
    review = fresh_review()
    review.pending = { id = "R_kept", commit = nil, count = 1 }
    load()
    actions.add_comment(TARGET, { path = "a.lua", side = "new", line = 1 }, "more")
    settled()
    H.eq(calls, { "thread R_kept new:1 more", "fetch" })
  end },

  { "acting on a thread from before the review was read again acts on the loaded one", function()
    review = fresh_review()
    load()
    local old = find_thread("T1")
    pr.reload()
    H.wait(function() return find_thread("T1") ~= old end, "read again")
    calls = {}
    actions.delete_comment(old.comments[1])
    H.eq(find_thread("T1"), nil, "gone from the screen")
    settled()
    H.eq(calls, { "delete C1", "fetch" })
  end },
}
