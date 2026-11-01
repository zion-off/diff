--- diff.nvim — the pull request API, over `gh`.
---
--- Turns GitHub's responses into plain tables the rest of the plugin uses:
---   pr     { id, number, title, url, head_oid, base_name, base_repo, branch }
---   review { pr, viewer = login, commits = { [oid] = true }, commits_complete = boolean,
---            pending = { id, commit, count }|nil, threads = thread[] }
---   thread { id, path, side, line, start_side, start_line, original_line,
---            original_start_line, resolved, outdated, pending, commit,
---            can_reply, can_resolve, can_unresolve, comments = comment[] }
---   comment { id, author, body, created_at, pending, commit, can_update, can_delete }
--- `side` is "old" or "new", the diff view's names for GitHub's LEFT and RIGHT.
--- Every callback is fun(result|nil, err: string|nil).
local M = {}

local gh  = require("diff.gh")
local log = require("diff.log").scope("github")

local SIDE_FROM_GITHUB = { LEFT = "old", RIGHT = "new" }
local SIDE_TO_GITHUB   = { old = "LEFT", new = "RIGHT" }

local MAX_THREADS  = 100
local MAX_COMMENTS = 100
local MAX_COMMITS  = 250

M.EVENTS = { comment = "COMMENT", approve = "APPROVE", request_changes = "REQUEST_CHANGES" }

local PR_FIELDS = "id,number,title,url,state,headRefOid,headRefName,baseRefName"

local function pr_from(raw)
  return {
    id = raw.id, number = raw.number, title = raw.title, url = raw.url,
    head_oid = raw.headRefOid, base_name = raw.baseRefName, branch = raw.headRefName,
    -- "owner/name" of the repository the pull request is on, from its URL.
    base_repo = raw.url and raw.url:match("^https?://[^/]+/([^/]+/[^/]+)/pull/%d+") or nil,
  }
end

--- The open pull request whose head is `branch` (nil: the checked-out
--- branch, which gh matches through its upstream too).
--- @param callback fun(pr: table|nil, err: string|nil)  nil, nil: there is none
function M.find_pull_request(root, branch, callback)
  local args = { "pr", "view" }
  if branch then table.insert(args, branch) end
  vim.list_extend(args, { "--json", PR_FIELDS })
  gh.run(args, root, function(stdout, stderr, code)
    if code ~= 0 then
      -- "no pull requests found for branch …" is the common, quiet case.
      log.debug("no pull request for %s: %s", branch or "the current branch", stderr:match("^[^\n]*") or "")
      callback(nil, nil)
      return
    end
    local ok, raw = pcall(vim.json.decode, stdout, { luanil = { object = true, array = true } })
    if not ok or type(raw) ~= "table" then
      log.warn("unreadable gh pr view output for %s", branch or "the current branch")
      callback(nil, "unreadable response from gh")
      return
    end
    if raw.state ~= "OPEN" then
      log.debug("pull request #%s for %s is %s", tostring(raw.number), branch or "HEAD", tostring(raw.state))
      callback(nil, nil)
      return
    end
    callback(pr_from(raw), nil)
  end)
end

local THREAD_FIELDS = string.format([[
          id isResolved isOutdated path line startLine originalLine originalStartLine
          diffSide startDiffSide viewerCanReply viewerCanResolve viewerCanUnresolve
          comments(first: %d) {
            pageInfo { hasNextPage }
            nodes {
              id body createdAt state viewerCanUpdate viewerCanDelete
              author { login }
              originalCommit { oid }
            }
          }]], MAX_COMMENTS)

local REVIEW_QUERY = string.format([[
query PullRequestReview($id: ID!) {
  viewer { login }
  node(id: $id) {
    ... on PullRequest {
      id number title url headRefOid headRefName baseRefName
      commits(last: %d) { totalCount nodes { commit { oid } } }
      reviews(states: [PENDING], first: 10) {
        nodes { id viewerDidAuthor commit { oid } comments { totalCount } }
      }
      reviewThreads(first: %d) {
        pageInfo { hasNextPage endCursor }
        nodes { %s }
      }
    }
  }
}]], MAX_COMMITS, MAX_THREADS, THREAD_FIELDS)

local THREADS_PAGE_QUERY = string.format([[
query PullRequestThreads($id: ID!, $after: String!) {
  node(id: $id) {
    ... on PullRequest {
      reviewThreads(first: %d, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes { %s }
      }
    }
  }
}]], MAX_THREADS, THREAD_FIELDS)

local function nodes(conn)
  return type(conn) == "table" and type(conn.nodes) == "table" and conn.nodes or {}
end

local function comment_from(raw)
  return {
    id = raw.id,
    author = raw.author and raw.author.login or "ghost",
    body = raw.body or "",
    created_at = raw.createdAt,
    pending = raw.state == "PENDING",
    commit = raw.originalCommit and raw.originalCommit.oid or nil,
    can_update = raw.viewerCanUpdate == true,
    can_delete = raw.viewerCanDelete == true,
  }
end

local function thread_from(raw)
  local comments = {}
  for _, c in ipairs(nodes(raw.comments)) do table.insert(comments, comment_from(c)) end
  if raw.comments and raw.comments.pageInfo and raw.comments.pageInfo.hasNextPage then
    log.warn("thread %s has more than %d comments; showing the first %d", tostring(raw.id), MAX_COMMENTS, MAX_COMMENTS)
  end
  local first = comments[1] or {}
  return {
    id = raw.id, path = raw.path,
    side = SIDE_FROM_GITHUB[raw.diffSide] or "new",
    start_side = raw.startDiffSide and SIDE_FROM_GITHUB[raw.startDiffSide] or nil,
    line = raw.line, start_line = raw.startLine,
    original_line = raw.originalLine, original_start_line = raw.originalStartLine,
    resolved = raw.isResolved == true, outdated = raw.isOutdated == true,
    pending = first.pending == true, commit = first.commit,
    can_reply = raw.viewerCanReply == true,
    can_resolve = raw.viewerCanResolve == true,
    can_unresolve = raw.viewerCanUnresolve == true,
    comments = comments,
  }
end

--- Fetch the threads after `cursor`, page by page, into `review.threads`.
local function fetch_more_threads(root, pr_id, review, cursor, callback)
  gh.graphql(root, THREADS_PAGE_QUERY, { id = pr_id, after = cursor }, function(data, err)
    local conn = data and data.node and data.node.reviewThreads
    if not conn then
      callback(err or "pull request not found")
      return
    end
    for _, t in ipairs(nodes(conn)) do table.insert(review.threads, thread_from(t)) end
    local page = conn.pageInfo or {}
    if page.hasNextPage and page.endCursor then
      return fetch_more_threads(root, pr_id, review, page.endCursor, callback)
    end
    callback(nil)
  end)
end

--- Everything the interface shows of a pull request's review: its threads,
--- its commits, and the viewer's draft (pending) review. GitHub lists only
--- a pull request's last commits; `commits_complete` says whether that is
--- all of them.
--- @param callback fun(review: table|nil, err: string|nil)
function M.fetch_review(root, pr_id, callback)
  gh.graphql(root, REVIEW_QUERY, { id = pr_id }, function(data, err)
    local raw = data and data.node
    if not raw then
      callback(nil, err or "pull request not found")
      return
    end
    local commit_nodes = nodes(raw.commits)
    local review = {
      pr = pr_from(raw), commits = {}, threads = {}, pending = nil,
      viewer = data.viewer and data.viewer.login or nil,
      commits_complete = not (raw.commits and raw.commits.totalCount and raw.commits.totalCount > #commit_nodes),
    }
    for _, c in ipairs(commit_nodes) do
      if c.commit and c.commit.oid then review.commits[c.commit.oid] = true end
    end
    for _, r in ipairs(nodes(raw.reviews)) do
      if r.viewerDidAuthor then
        review.pending = {
          id = r.id, commit = r.commit and r.commit.oid or nil,
          count = r.comments and r.comments.totalCount or 0,
        }
        break
      end
    end
    for _, t in ipairs(nodes(raw.reviewThreads)) do table.insert(review.threads, thread_from(t)) end
    local function done(page_err)
      if page_err then
        callback(nil, page_err)
        return
      end
      log.debug("pull request #%d: %d threads, %s commits, pending review %s", raw.number, #review.threads,
        review.commits_complete and "all" or "the last " .. #commit_nodes, review.pending and review.pending.id or "none")
      callback(review, nil)
    end
    local page = raw.reviewThreads and raw.reviewThreads.pageInfo or {}
    if page.hasNextPage and page.endCursor then
      log.debug("pull request #%d has more than %d threads; fetching the rest", raw.number, MAX_THREADS)
      return fetch_more_threads(root, pr_id, review, page.endCursor, done)
    end
    done(nil)
  end)
end

-- ---------------------------------------------------------------------------
-- Mutations
-- ---------------------------------------------------------------------------

--- Run `mutation` and hand back the field at `path` (a list of keys) of its data.
local function mutate(root, mutation, vars, path, callback)
  gh.graphql(root, mutation, vars, function(data, err)
    if not data then
      callback(nil, err)
      return
    end
    local value = data
    for _, key in ipairs(path) do
      if type(value) ~= "table" then value = nil break end
      value = value[key]
    end
    if value == nil or value == vim.NIL then
      local field = table.concat(path, ".")
      log.warn("GitHub's answer has no %s", field)
      return callback(nil, "GitHub's answer has no " .. field)
    end
    callback(value, nil)
  end)
end

--- Start the viewer's draft review, its comments tied to `commit`.
--- @param callback fun(review_id: string|nil, err: string|nil)
function M.start_review(root, pr_id, commit, callback)
  mutate(root, [[
mutation StartReview($pr: ID!, $commit: GitObjectID) {
  addPullRequestReview(input: { pullRequestId: $pr, commitOID: $commit }) { pullRequestReview { id } }
}]], { pr = pr_id, commit = commit }, { "addPullRequestReview", "pullRequestReview", "id" }, callback)
end

--- Add a draft comment thread to the draft review `review_id`.
--- @param anchor   table { path, side, line, start_side|nil, start_line|nil }
--- @param callback fun(ids: {thread: string, comment: string|nil}|nil, err: string|nil)
function M.add_thread(root, review_id, anchor, body, callback)
  local vars = {
    review = review_id, path = anchor.path, body = body,
    line = anchor.line, side = SIDE_TO_GITHUB[anchor.side],
  }
  if anchor.start_line and anchor.start_line ~= anchor.line then
    vars.startLine = anchor.start_line
    vars.startSide = SIDE_TO_GITHUB[anchor.start_side or anchor.side]
  end
  mutate(root, [[
mutation AddThread($review: ID!, $path: String!, $body: String!, $line: Int!, $side: DiffSide!,
                   $startLine: Int, $startSide: DiffSide) {
  addPullRequestReviewThread(input: { pullRequestReviewId: $review, path: $path, body: $body,
      line: $line, side: $side, startLine: $startLine, startSide: $startSide }) {
    thread { id comments(first: 1) { nodes { id } } }
  }
}]], vars, { "addPullRequestReviewThread", "thread" }, function(thread, err)
    if err then return callback(nil, err) end
    local first = type(thread) == "table" and nodes(thread.comments)[1] or nil
    callback({ thread = type(thread) == "table" and thread.id or nil, comment = first and first.id or nil }, nil)
  end)
end

--- Reply in a thread. With a draft review the reply joins it; without one
--- it is published at once.
function M.reply(root, thread_id, body, review_id, callback)
  mutate(root, [[
mutation Reply($thread: ID!, $body: String!, $review: ID) {
  addPullRequestReviewThreadReply(input: { pullRequestReviewThreadId: $thread, body: $body,
      pullRequestReviewId: $review }) { comment { id } }
}]], { thread = thread_id, body = body, review = review_id }, { "addPullRequestReviewThreadReply", "comment", "id" },
    callback)
end

function M.set_resolved(root, thread_id, resolved, callback)
  local field = resolved and "resolveReviewThread" or "unresolveReviewThread"
  mutate(root, string.format([[
mutation SetResolved($thread: ID!) {
  %s(input: { threadId: $thread }) { thread { id isResolved } }
}]], field), { thread = thread_id }, { field, "thread", "isResolved" }, callback)
end

function M.update_comment(root, comment_id, body, callback)
  mutate(root, [[
mutation UpdateComment($comment: ID!, $body: String!) {
  updatePullRequestReviewComment(input: { pullRequestReviewCommentId: $comment, body: $body }) {
    pullRequestReviewComment { id }
  }
}]], { comment = comment_id, body = body }, { "updatePullRequestReviewComment", "pullRequestReviewComment", "id" },
    callback)
end

function M.delete_comment(root, comment_id, callback)
  mutate(root, [[
mutation DeleteComment($comment: ID!) {
  deletePullRequestReviewComment(input: { id: $comment }) { clientMutationId }
}]], { comment = comment_id }, {}, callback)
end

--- Submit the draft review `review_id` with `event` (see M.EVENTS).
function M.submit_review(root, review_id, event, body, callback)
  mutate(root, [[
mutation SubmitReview($review: ID!, $event: PullRequestReviewEvent!, $body: String) {
  submitPullRequestReview(input: { pullRequestReviewId: $review, event: $event, body: $body }) {
    pullRequestReview { id state }
  }
}]], { review = review_id, event = event, body = body }, { "submitPullRequestReview", "pullRequestReview", "state" },
    callback)
end

--- Review with no draft comments: create and submit in one step.
function M.post_review(root, pr_id, commit, event, body, callback)
  mutate(root, [[
mutation PostReview($pr: ID!, $commit: GitObjectID, $event: PullRequestReviewEvent!, $body: String) {
  addPullRequestReview(input: { pullRequestId: $pr, commitOID: $commit, event: $event, body: $body }) {
    pullRequestReview { id state }
  }
}]], { pr = pr_id, commit = commit, event = event, body = body }, { "addPullRequestReview", "pullRequestReview", "state" },
    callback)
end

--- Throw away the draft review and its comments.
function M.delete_review(root, review_id, callback)
  mutate(root, [[
mutation DeleteReview($review: ID!) {
  deletePullRequestReview(input: { pullRequestReviewId: $review }) { pullRequestReview { id } }
}]], { review = review_id }, { "deletePullRequestReview", "pullRequestReview", "id" }, callback)
end

return M
