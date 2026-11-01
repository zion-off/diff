local H = require("helpers")
local gh = require("diff.gh")
local github = require("diff.github")
local pr = require("diff.pr")

local repo = H.repo({ ["a.lua"] = "one\n" })
local head = vim.trim(H.git(repo, "rev-parse", "HEAD"))
-- origin is the repository the pull request is on; "fork" is a contributor's
-- fork, a remote not named after its owner.
H.git(repo, "remote", "add", "origin", "git@github.com:acme/r.git")
H.git(repo, "remote", "add", "fork", "https://github.com/someone/r")
H.git(repo, "update-ref", "refs/remotes/fork/feature", "HEAD")
H.git(repo, "branch", "mine")
H.git(repo, "config", "branch.mine.remote", "fork")
H.git(repo, "config", "branch.mine.merge", "refs/heads/feature")

local log = {}
local logged_in = true
local review

local function fake_review()
  return {
    pr = { id = "PR_1", number = 7, head_oid = head, base_name = "main", branch = "feature" },
    commits = { [head] = true, c_old = true },
    pending = nil,
    threads = {
      { id = "T1", path = "a.lua", side = "new", line = 3, original_line = 2, outdated = false, commit = head, comments = {} },
      { id = "T2", path = "a.lua", side = "old", line = 3, original_line = 3, outdated = false, commit = head, comments = {} },
      { id = "T3", path = "a.lua", side = "new", line = nil, original_line = 9, outdated = true, commit = "c_old", comments = {} },
      { id = "T4", path = "b.lua", side = "new", line = 1, original_line = 1, outdated = false, commit = head, comments = {} },
      { id = "T5", path = "a.lua", side = "new", line = 3, original_line = 2, outdated = false, commit = head, comments = {} },
    },
  }
end

local function later(cb, ...)
  local args = { ... }
  vim.schedule(function() cb(unpack(args, 1, 2)) end)
end

gh.authenticated = function(_, cb) later(cb, logged_in) end
-- gh finds the pull request as the checked-out branch, by its bare name
-- (as if it were on origin), or as the fork's "owner:branch".
local FOUND = { feature = true, ["someone:feature"] = true }
github.find_pull_request = function(_, branch, cb)
  table.insert(log, "find " .. tostring(branch))
  later(cb, (branch == nil or FOUND[branch]) and review.pr or nil)
end
github.fetch_review = function(_, _, cb) table.insert(log, "fetch"); later(cb, vim.deepcopy(review)) end
github.start_review = function(_, _, commit, cb) table.insert(log, "start " .. commit); later(cb, "R_new") end
github.delete_review = function(_, id, cb) table.insert(log, "delete " .. id); later(cb, true) end

local changes = 0
vim.api.nvim_create_autocmd("User", { pattern = "DiffNvimPrChanged", callback = function() changes = changes + 1 end })

local function await(fn)
  local result, done = nil, false
  fn(function(...) result = { ... }; done = true end)
  H.wait(function() return done end, "callback")
  return unpack(result, 1, 2)
end

local function synced(branch, opts)
  local before = changes
  pr.sync(repo, branch, opts)
  H.wait(function()
    return changes > before and pr._state().review ~= nil and (branch ~= nil or pr._state().local_oid ~= nil)
  end, "review loaded")
end

return {
  { "without a gh login nothing is looked up", function()
    logged_in, review, log = false, fake_review(), {}
    pr.sync(repo, nil)
    vim.wait(100)
    H.eq(pr.pull_request(), nil)
    H.eq(log, {})
  end },

  { "finds a previewed remote branch's pull request by its bare name", function()
    logged_in, log = true, {}
    synced("origin/feature", { force = true })
    H.eq(pr.pull_request().number, 7)
    H.eq(log, { "find acme:feature", "find feature", "fetch" })
  end },

  { "finds a fork's pull request as owner:branch, the owner read from the remote's URL", function()
    log = {}
    synced("fork/feature")
    H.eq(log, { "find someone:feature", "fetch" })
  end },

  { "finds a local branch's pull request through the branch it tracks", function()
    log = {}
    FOUND.feature = nil
    synced("mine")
    FOUND.feature = true
    H.eq(log, { "find mine", "find someone:feature", "fetch" })
  end },

  { "the branch's changes show live threads at their current lines", function()
    synced(nil)
    local groups = pr.threads_for({ kind = "range", head = "HEAD", path = "a.lua" })
    local got = {}
    for _, g in ipairs(groups) do
      local ids = {}
      for _, t in ipairs(g.threads) do table.insert(ids, t.id) end
      got[g.side .. ":" .. g.line] = table.concat(ids, ",")
    end
    H.eq(got, { ["new:3"] = "T1,T5", ["old:3"] = "T2" })
    H.eq(pr.threads_for({ kind = "range", head = "other", path = "a.lua" }), {}, "another branch's changes")
    H.eq(pr.threads_for({ kind = "worktree", path = "a.lua" }), {})
  end },

  { "a commit shows the new-side threads made on it, outdated or not", function()
    local groups = pr.threads_for({ kind = "commit", hash = "c_old", path = "a.lua" })
    H.eq(#groups, 1)
    H.eq({ groups[1].side, groups[1].line, groups[1].threads[1].id }, { "new", 9, "T3" })
  end },

  { "says why a comment cannot go somewhere", function()
    local _, why = await(function(cb) pr.comment_target(repo, { kind = "worktree", path = "a.lua" }, "new", cb) end)
    H.ok(why:find("uncommitted"), why)
    _, why = await(function(cb) pr.comment_target(repo, { kind = "commit", hash = "nothere", path = "a.lua" }, "new", cb) end)
    H.ok(why:find("not part of pull request #7"), why)
    _, why = await(function(cb) pr.comment_target(repo, { kind = "commit", hash = "c_old", path = "a.lua" }, "old", cb) end)
    H.ok(why:find("new%-side"), why)
  end },

  { "the branch's changes take comments only when the local branch is the pull request's head", function()
    local target = await(function(cb) pr.comment_target(repo, { kind = "range", head = "HEAD", path = "a.lua" }, "old", cb) end)
    H.eq(target, { pr_id = "PR_1", commit = head })
    H.write(repo, "a.lua", "two\n")
    H.git(repo, "commit", "-qam", "unpushed")
    local _, why = await(function(cb) pr.comment_target(repo, { kind = "range", head = "HEAD", path = "a.lua" }, "new", cb) end)
    H.ok(why:find("Push or pull"), why)
  end },

  { "a draft review with comments keeps comments on its commit", function()
    pr._state().review.pending = { id = "R1", commit = "c_old", count = 2 }
    local _, why = await(function(cb) pr.comment_target(repo, { kind = "commit", hash = head, path = "a.lua" }, "new", cb) end)
    H.ok(why:find("draft review is on commit c_old"), why)
    local target = await(function(cb) pr.comment_target(repo, { kind = "commit", hash = "c_old", path = "a.lua" }, "new", cb) end)
    H.eq(target, { pr_id = "PR_1", commit = "c_old" })
  end },

  { "an older commit of a long pull request is in it when the head descends from it", function()
    local st = pr._state()
    local saved_commits, saved_head = st.review.commits, st.pr.head_oid
    st.review.pending = nil
    st.review.commits = {}
    st.review.commits_complete = false
    st.pr.head_oid = vim.trim(H.git(repo, "rev-parse", "HEAD"))
    local target = await(function(cb) pr.comment_target(repo, { kind = "commit", hash = head, path = "a.lua" }, "new", cb) end)
    H.eq(target, { pr_id = "PR_1", commit = head })
    st.review.commits_complete = true
    local _, why = await(function(cb) pr.comment_target(repo, { kind = "commit", hash = head, path = "a.lua" }, "new", cb) end)
    H.ok(why and why:find("not part of"), tostring(why))
    st.review.commits, st.pr.head_oid = saved_commits, saved_head
  end },

  { "a reload superseded by a branch switch still reports back", function()
    local reported = false
    pr.reload(function() reported = true end)
    pr.sync(repo, "fork/feature")
    H.wait(function() return reported end, "reload callback")
  end },

  { "checking out another branch looks its pull request up again, and says so", function()
    synced(nil, { head = "feature" })
    local switched = 0
    local id = vim.api.nvim_create_autocmd("User", { pattern = "DiffNvimPrChanged", callback = function(ev)
      if ev.data and ev.data.switched then switched = switched + 1 end
    end })
    log = {}
    pr.sync(repo, nil, { head = "feature" })
    vim.wait(100)
    H.eq(log, {}, "same branch: nothing looked up")
    synced(nil, { head = "other" })
    H.eq(log, { "find nil", "fetch" })
    H.eq(switched, 1)
    vim.api.nvim_del_autocmd(id)
  end },

  { "threads on the branch's changes are hidden while the local branch is not at the head", function()
    -- HEAD has moved on from the head the fake pull request has (an earlier test committed).
    local cur = vim.trim(H.git(repo, "rev-parse", "HEAD"))
    review.pr.head_oid = cur
    synced(nil, { head = "again", force = true })
    H.eq(pr.in_sync(), true)
    H.ok(#pr.threads_for({ kind = "range", head = "HEAD", path = "a.lua" }) > 0, "shown in sync")
    H.write(repo, "a.lua", "three\n")
    H.git(repo, "commit", "-qam", "ahead")
    pr.sync(repo, nil, { head = "again" })
    H.wait(function() return not pr.in_sync() end, "out of sync noticed")
    H.eq(pr.threads_for({ kind = "range", head = "HEAD", path = "a.lua" }), {})
    review.pr.head_oid = head
  end },

  { "a review that failed to load says so when commenting", function()
    github.fetch_review = function(_, _, cb) later(cb, nil, "boom") end
    local notify = vim.notify
    vim.notify = function() end
    pr.sync(repo, nil, { head = "failing" })
    H.wait(function() return not pr.loading() end, "settled")
    vim.notify = notify
    local _, why = await(function(cb) pr.comment_target(repo, { kind = "commit", hash = head, path = "a.lua" }, "new", cb) end)
    H.ok(why:find("did not load"), why)
    github.fetch_review = function(_, _, cb) table.insert(log, "fetch"); later(cb, vim.deepcopy(review)) end
  end },

  { "clearing forgets the pull request", function()
    pr.clear()
    H.eq(pr.pull_request(), nil)
    H.eq(pr.threads_for({ kind = "range", head = "HEAD", path = "a.lua" }), {})
  end },
}
