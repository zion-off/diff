local H = require("helpers")
local gh = require("diff.gh")
local github = require("diff.github")

local real_run = gh.run
local calls = {}

--- Answer gh invocations from `responder(args, stdin)` -> stdout, stderr, code.
local function stub(responder)
  calls = {}
  gh.run = function(args, _, cb, opts)
    local stdin = opts and opts.stdin
    table.insert(calls, { args = args, stdin = stdin and vim.json.decode(stdin) or nil })
    local out, err, code = responder(args, stdin)
    vim.schedule(function() cb(out or "", err or "", code or 0) end)
  end
end

local function await(fn)
  local result, done = nil, false
  fn(function(...) result = { ... }; done = true end)
  H.wait(function() return done end, "callback")
  return unpack(result, 1, 2)
end

local function pr_json(state)
  return vim.json.encode({
    id = "PR_1", number = 7, title = "Add things", url = "https://github.com/o/r/pull/7", state = state,
    headRefOid = "abc", headRefName = "feature", baseRefName = "main",
  })
end

return {
  { "finds the open pull request for a branch", function()
    stub(function() return pr_json("OPEN") end)
    local pr = await(function(cb) github.find_pull_request("/r", "feature", cb) end)
    H.eq(pr, { id = "PR_1", number = 7, title = "Add things", url = "https://github.com/o/r/pull/7",
      head_oid = "abc", base_name = "main", base_repo = "o/r", branch = "feature" })
    H.eq(calls[1].args[1], "pr")
    H.eq(calls[1].args[3], "feature")
  end },

  { "a closed pull request, or none, is no pull request", function()
    stub(function() return pr_json("MERGED") end)
    local pr, err = await(function(cb) github.find_pull_request("/r", nil, cb) end)
    H.eq({ pr, err }, {})
    H.eq(calls[1].args[3], "--json", "no branch argument for the checked-out branch")
    stub(function() return "", "no pull requests found for branch \"x\"", 1 end)
    pr, err = await(function(cb) github.find_pull_request("/r", "x", cb) end)
    H.eq({ pr, err }, {})
  end },

  { "reads threads, commits and the viewer's draft review", function()
    stub(function()
      return vim.json.encode({ data = { node = {
        id = "PR_1", number = 7, title = "t", url = "u", headRefOid = "c2", headRefName = "feature", baseRefName = "main",
        commits = { nodes = { { commit = { oid = "c1" } }, { commit = { oid = "c2" } } } },
        reviews = { nodes = {
          { id = "R_other", viewerDidAuthor = false, commit = { oid = "c1" }, comments = { totalCount = 4 } },
          { id = "R_mine", viewerDidAuthor = true, commit = { oid = "c2" }, comments = { totalCount = 1 } },
        } },
        reviewThreads = { pageInfo = { hasNextPage = false }, nodes = { {
          id = "T1", isResolved = false, isOutdated = false, path = "a.lua", line = 12, startLine = 10,
          originalLine = 12, originalStartLine = 10, diffSide = "LEFT", startDiffSide = "LEFT",
          viewerCanReply = true, viewerCanResolve = true, viewerCanUnresolve = false,
          comments = { nodes = { {
            id = "C1", body = "why?", createdAt = "2026-01-01T00:00:00Z", state = "PENDING",
            viewerCanUpdate = true, viewerCanDelete = true, author = { login = "me" }, originalCommit = { oid = "c2" },
          } } },
        } } },
      } } })
    end)
    local review = await(function(cb) github.fetch_review("/r", "PR_1", cb) end)
    H.eq(review.commits, { c1 = true, c2 = true })
    H.eq(review.pending, { id = "R_mine", commit = "c2", count = 1 })
    local t = review.threads[1]
    H.eq({ t.side, t.start_side, t.line, t.start_line, t.pending, t.commit }, { "old", "old", 12, 10, true, "c2" })
    H.eq(t.comments[1].author, "me")
    H.eq(calls[1].stdin.variables, { id = "PR_1" })
  end },

  { "pages through more threads than one request returns, and says whether all commits came", function()
    local function thread(id) return { id = id, path = "a.lua", diffSide = "RIGHT", line = 1, comments = { nodes = {} } } end
    stub(function(_, stdin)
      local req = vim.json.decode(stdin)
      if not req.variables.after then
        return vim.json.encode({ data = { node = {
          id = "PR_1", number = 7, url = "https://github.com/o/r/pull/7", headRefOid = "c3",
          commits = { totalCount = 300, nodes = { { commit = { oid = "c3" } } } },
          reviews = { nodes = {} },
          reviewThreads = { pageInfo = { hasNextPage = true, endCursor = "p1" }, nodes = { thread("T1") } },
        } } })
      elseif req.variables.after == "p1" then
        return vim.json.encode({ data = { node = { reviewThreads = {
          pageInfo = { hasNextPage = true, endCursor = "p2" }, nodes = { thread("T2") } } } } })
      end
      return vim.json.encode({ data = { node = { reviewThreads = {
        pageInfo = { hasNextPage = false }, nodes = { thread("T3") } } } } })
    end)
    local review = await(function(cb) github.fetch_review("/r", "PR_1", cb) end)
    local ids = {}
    for _, t in ipairs(review.threads) do table.insert(ids, t.id) end
    H.eq(ids, { "T1", "T2", "T3" })
    H.eq(review.commits_complete, false)
    H.eq(review.pr.base_repo, "o/r")
  end },

  { "sends requests on stdin, never as flags", function()
    stub(function() return vim.json.encode({ data = { addPullRequestReviewThread = { thread = { id = "T9" } } } }) end)
    local id = await(function(cb)
      github.add_thread("/r", "R1", { path = "a.lua", side = "new", line = 5 }, "@/etc/passwd", cb)
    end)
    H.eq(id, { thread = "T9" })
    H.eq(calls[1].args, { "api", "graphql", "--input", "-" })
    local vars = calls[1].stdin.variables
    H.eq(vars.body, "@/etc/passwd")
    H.eq({ vars.side, vars.line, vars.startLine, vars.startSide }, { "RIGHT", 5, nil, nil })
  end },

  { "a range sends where it starts", function()
    stub(function() return vim.json.encode({ data = { addPullRequestReviewThread = { thread = { id = "T9" } } } }) end)
    await(function(cb)
      github.add_thread("/r", "R1", { path = "a.lua", side = "old", line = 8, start_line = 6 }, "b", cb)
    end)
    local vars = calls[1].stdin.variables
    H.eq({ vars.side, vars.line, vars.startLine, vars.startSide }, { "LEFT", 8, 6, "LEFT" })
  end },

  { "GitHub's error message reaches the caller", function()
    stub(function()
      return vim.json.encode({ errors = { { message = "Line could not be resolved" } } }), "gh: Line could not be resolved", 1
    end)
    local id, err = await(function(cb) github.reply("/r", "T1", "x", nil, cb) end)
    H.eq(id, nil)
    H.eq(err, "Line could not be resolved")
    gh.run = real_run
  end },
}
