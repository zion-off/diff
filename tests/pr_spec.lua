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
  H.wait(function() return changes > before and pr._state().review ~= nil end, "review loaded")
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
    H.eq(target, { commit = head })
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
    H.eq(target, { commit = "c_old" })
  end },

  { "the first comment starts a draft review, removed again if GitHub rejects the comment", function()
    pr._state().review.pending = nil
    log = {}
    github.add_thread = function(_, id, _, _, cb) table.insert(log, "thread " .. id); later(cb, nil, "Line could not be resolved") end
    local err = await(function(cb)
      pr.add_comment({ commit = head }, { path = "a.lua", side = "new", line = 1 }, "hi", cb)
    end)
    H.eq(err, "Line could not be resolved")
    H.eq(log, { "start " .. head, "thread R_new", "delete R_new" })
  end },

  { "an empty draft review on another commit is replaced", function()
    pr._state().review.pending = { id = "R_empty", commit = "c_old", count = 0 }
    log = {}
    github.add_thread = function(_, id, _, _, cb) table.insert(log, "thread " .. id); later(cb, "T9") end
    local err = await(function(cb)
      pr.add_comment({ commit = head }, { path = "a.lua", side = "new", line = 1 }, "hi", cb)
    end)
    H.eq(err, nil)
    H.eq(log, { "delete R_empty", "start " .. head, "thread R_new", "fetch" })
  end },

  { "clearing forgets the pull request", function()
    pr.clear()
    H.eq(pr.pull_request(), nil)
    H.eq(pr.threads_for({ kind = "range", head = "HEAD", path = "a.lua" }), {})
  end },
}
