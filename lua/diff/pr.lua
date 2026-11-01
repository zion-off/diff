--- diff.nvim — the pull request of the branch on screen, and its review.
---
--- Holds what github.lua fetched for the branch the panels show, decides
--- where comments can go, and carries out review actions. Every change of
--- state fires `User DiffNvimPrChanged`, which the diff view and the mode bar
--- redraw from. Nothing is fetched in the background: only on entering a
--- branch's view, after an action, and on an explicit refresh.
---
--- Comments can go on two kinds of diff:
---   - the branch's changes ("range" sources), when the local branch is at
---     the commit GitHub has as the pull request's head;
---   - one of the pull request's commits ("commit" sources), on new-side
---     lines only: GitHub measures removed lines against the pull request's
---     base, not the commit's parent, so their line numbers would not match.
--- A draft review is tied to one commit, so while one exists, comments go
--- only on that commit's diff.
local M = {}

local gh     = require("diff.gh")
local github = require("diff.github")
local git    = require("diff.git")
local log    = require("diff.log").scope("pr")

local function fresh_state()
  return {
    root = nil,
    branch = nil,    -- the branch shown: nil for HEAD, else a previewed branch
    head = nil,      -- the checked-out branch's name, which a checkout changes
    synced = false,  -- root/branch/head have been looked up at least once
    loading = false, -- a lookup is in flight
    local_oid = nil, -- the commit the branch shown is at locally
    pr = nil, review = nil,
    gen = 0,         -- bumps on every sync, so stale responses are dropped
  }
end

local S = fresh_state()

--- @param data table|nil  { switched = true }: another pull request (or
---   none) is being loaded, so anything acting on the old one must stop
local function fire(data)
  vim.api.nvim_exec_autocmds("User", { pattern = "DiffNvimPrChanged", modeline = false, data = data or {} })
end

local function short(oid)
  return oid and oid:sub(1, 7) or "?"
end

-- ---------------------------------------------------------------------------
-- Loading
-- ---------------------------------------------------------------------------

--- `ref` ("remote/branch") split at the longest remote name it starts with.
local function split_remote(ref, remotes)
  local best
  for name in pairs(remotes) do
    if vim.startswith(ref, name .. "/") and (not best or #name > #best) then best = name end
  end
  if best then return best, ref:sub(#best + 2) end
end

--- Names to ask gh about for `branch`, most precise first. A pull request
--- from a fork is found only as "owner:branch", and the remote it was
--- fetched from is often not named after its owner, so the owner comes from
--- the remote's URL. A remote-tracking name ("origin/x") is also tried bare,
--- and a local branch through the remote branch it tracks.
--- @param callback fun(names: (string|false)[])  false: the checked-out branch
local function branch_candidates(root, branch, callback)
  if not branch then return callback({ false }) end
  git.remotes(root, function(remotes)
    local function from_remote_ref(ref, out)
      local remote, bare = split_remote(ref, remotes)
      if not remote then return out end
      local owner = git.github_repo(remotes[remote])
      if owner then table.insert(out, owner .. ":" .. bare) end
      table.insert(out, bare)
      return out
    end
    local out = from_remote_ref(branch, {})
    if #out > 0 then
      table.insert(out, branch)
      return callback(out)
    end
    git.upstream(root, branch, function(upstream)
      out = upstream and from_remote_ref(upstream, {}) or {}
      table.insert(out, 1, branch)
      callback(out)
    end)
  end)
end

local function find_pr(root, branch, callback)
  branch_candidates(root, branch, function(candidates)
    log.debug("looking up the pull request of %s as %s", branch or "HEAD", vim.inspect(candidates))
    local function try(i)
      local name = candidates[i]
      if name == nil then return callback(nil) end
      github.find_pull_request(root, name or nil, function(pr)
        if pr then return callback(pr) end
        try(i + 1)
      end)
    end
    try(1)
  end)
end

local function set_review(review)
  S.review = review
  S.pr = review and review.pr or S.pr
end

--- Read where the branch shown is locally. Threads are drawn on the
--- branch's changes only while it is at the pull request's head, so a
--- commit, pull or reset that moves it redraws them.
local function read_local_oid(root, branch, gen)
  git.rev_parse(root, { branch or "HEAD" }, function(shas)
    local oid = shas and shas[1] or nil
    if gen ~= S.gen or oid == S.local_oid then return end
    log.debug("%s is now at %s locally", branch or "HEAD", short(oid))
    S.local_oid = oid
    if S.pr then fire() end
  end)
end

local function finish_loading(gen)
  if gen ~= S.gen then return end
  S.loading = false
  fire()
end

--- Look up the pull request of the branch shown and load its review.
--- @param root   string
--- @param branch string|nil  previewed branch; nil for the checked-out one
--- @param opts   table|nil   {
---   head  = the checked-out branch's name (nil when detached): checking out
---           another branch looks its pull request up,
---   force = fetch again even when nothing changed, and check the gh login again }
function M.sync(root, branch, opts)
  opts = opts or {}
  local changed = S.root ~= root or S.branch ~= branch or S.head ~= opts.head
  if S.synced and not changed and not opts.force then
    if S.pr then read_local_oid(root, branch, S.gen) end
    return
  end
  S.gen = S.gen + 1
  local gen = S.gen
  S.root, S.branch, S.head, S.synced, S.loading = root, branch, opts.head, true, true
  if changed then
    S.local_oid = nil
    if S.pr then
      log.info("branch shown changed; forgetting pull request #%d", S.pr.number)
      S.pr, S.review = nil, nil
      -- Announced after the caller's own work (a sidebar refresh), not in it.
      vim.schedule(function() if gen == S.gen then fire({ switched = true }) end end)
    end
  end
  local elapsed = require("diff.log").timer()
  gh.authenticated(root, function(ok)
    if gen ~= S.gen then return end
    if not ok then
      S.pr, S.review = nil, nil
      return finish_loading(gen)
    end
    find_pr(root, branch, function(pr)
      if gen ~= S.gen then return end
      if not pr then
        log.debug("no open pull request for %s", branch or "HEAD")
        S.pr, S.review = nil, nil
        return finish_loading(gen)
      end
      read_local_oid(root, branch, gen)
      github.fetch_review(root, pr.id, function(review, err)
        if gen ~= S.gen then return end
        if not review then
          log.warn("cannot load the review of #%d: %s", pr.number, tostring(err))
          vim.notify("diff.nvim: cannot load pull request #" .. pr.number .. ": " .. tostring(err), vim.log.levels.WARN)
          S.pr, S.review = pr, nil
        else
          set_review(review)
          log.info("pull request #%d for %s: %d threads in %.0f ms", pr.number, branch or "HEAD",
            #review.threads, elapsed())
        end
        finish_loading(gen)
      end)
    end)
  end, { recheck = opts.force })
end

--- Fetch the review of the loaded pull request again (after an action).
--- The callback always runs; a result for a pull request no longer shown is
--- dropped.
--- @param callback fun()|nil
function M.reload(callback)
  local pr, root, gen = S.pr, S.root, S.gen
  if not pr then
    if callback then callback() end
    return
  end
  github.fetch_review(root, pr.id, function(review, err)
    if gen ~= S.gen then
      log.debug("dropping the reload of #%d: the branch shown changed", pr.number)
    elseif review then
      set_review(review)
      fire()
    else
      log.warn("cannot reload the review of #%d: %s", pr.number, tostring(err))
    end
    if callback then callback() end
  end)
end

--- Forget everything (the interface closed).
function M.clear()
  local had = S.pr ~= nil
  local gen = S.gen
  S = fresh_state()
  S.gen = gen + 1
  if had then fire() end
end

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

--- @return table|nil  the loaded pull request
function M.pull_request()
  return S.pr
end

--- @return table|nil  the viewer's draft review { id, commit, count }
function M.pending()
  return S.review and S.review.pending or nil
end

--- @return boolean  whether a lookup is in flight
function M.loading()
  return S.loading
end

--- @return boolean  whether the branch shown is at the pull request's head
---   locally (true while unknown or without a pull request)
function M.in_sync()
  return not (S.pr and S.local_oid) or S.local_oid == S.pr.head_oid
end

--- @return table|nil  the loaded review (tests)
function M._state()
  return S
end

--- Whether a "range" source shows the branch the pull request was loaded for.
local function shows_pr_branch(source)
  return source.head == (S.branch or "HEAD")
end

--- Comment threads to show in the diff of `source`, grouped by the line they
--- are drawn on: { { side, line, threads = thread[] } }.
function M.threads_for(source)
  local out = {}
  if not (S.review and source) then return out end
  local by_key = {}
  local function add(side, line, thread)
    if not line then return end
    local key = side .. ":" .. line
    if not by_key[key] then
      by_key[key] = { side = side, line = line, threads = {} }
      table.insert(out, by_key[key])
    end
    table.insert(by_key[key].threads, thread)
  end
  for _, t in ipairs(S.review.threads) do
    if t.path == source.path then
      if source.kind == "range" and shows_pr_branch(source) and not t.outdated and S.local_oid == S.pr.head_oid then
        add(t.side, t.line, t)
      elseif source.kind == "commit" and t.commit == source.hash and t.side == "new" then
        add("new", t.original_line, t)
      end
    end
  end
  return out
end

--- Where a comment on `side` of the diff of `source` would go, checked
--- against the local branch. Calls back with the pull request and the
--- commit GitHub ties the comment to, or with the reason it cannot be made,
--- in words for the reader.
--- @param callback fun(target: {pr_id: string, commit: string}|nil, reason: string|nil)
function M.comment_target(root, source, side, callback)
  local pr, review = S.pr, S.review
  if not pr then
    callback(nil, "This branch has no open pull request.")
    return
  end
  if not review then
    callback(nil, string.format("The comments of pull request #%d did not load. Run :DiffNvimRefresh to try again.",
      pr.number))
    return
  end
  local function check_pending(commit)
    local pending = review.pending
    if pending and pending.count > 0 and pending.commit and pending.commit ~= commit then
      callback(nil, string.format(
        "Your draft review is on commit %s. Submit or discard it before commenting on commit %s.",
        short(pending.commit), short(commit)))
      return
    end
    callback({ pr_id = pr.id, commit = commit }, nil)
  end

  if source.kind == "commit" then
    if side ~= "new" then
      callback(nil, "On a single commit, comments go on new-side lines. "
        .. "GitHub measures removed lines against the pull request's base, not the commit's parent.")
      return
    end
    local function not_in_pr()
      callback(nil, string.format("Commit %s is not part of pull request #%d.", short(source.hash), pr.number))
    end
    if review.commits[source.hash] then return check_pending(source.hash) end
    if review.commits_complete then return not_in_pr() end
    -- GitHub lists a pull request's last commits only; an older one is in
    -- it if the head descends from it.
    git.is_ancestor(root, source.hash, pr.head_oid, function(yes)
      if yes then check_pending(source.hash) else not_in_pr() end
    end)
    return
  end

  if source.kind ~= "range" or not shows_pr_branch(source) then
    callback(nil, "Comments go on the branch's changes or on one of the pull request's commits, "
      .. "not on uncommitted changes.")
    return
  end
  git.rev_parse(root, { source.head }, function(shas)
    local local_oid = shas and shas[1]
    if local_oid ~= pr.head_oid then
      log.info("local %s is at %s, pull request #%d head at %s", source.head, short(local_oid), pr.number,
        short(pr.head_oid))
      callback(nil, string.format(
        "Your local branch is at %s but pull request #%d is at %s. Push or pull before commenting.",
        short(local_oid), pr.number, short(pr.head_oid)))
      return
    end
    check_pending(pr.head_oid)
  end)
end

-- ---------------------------------------------------------------------------
-- Actions. Each calls back with nil on success, else GitHub's error, after
-- the review has been fetched again.
-- ---------------------------------------------------------------------------

local function finish(action, callback)
  return function(_, err)
    if err then
      log.warn("%s failed: %s", action, err)
      callback(err)
      return
    end
    log.info("%s done", action)
    M.reload(function() callback(nil) end)
  end
end

--- Add a draft comment, starting the draft review on `target.commit` if
--- there is none. A draft review started here is removed again when the
--- comment is rejected, so a failed first comment leaves nothing behind.
--- @param anchor table { path, side, line, start_line|nil }
function M.add_comment(target, anchor, body, callback)
  local pr, root = S.pr, S.root
  if not pr then return callback("no pull request") end
  if target.pr_id ~= pr.id then
    log.info("comment written for another pull request; not sending it")
    return callback("the pull request shown changed while the comment was written")
  end
  local pending = M.pending()
  log.info("comment on %s %s:%d%s at %s", anchor.path, anchor.side, anchor.line,
    anchor.start_line and (" from " .. anchor.start_line) or "", short(target.commit))
  local function add(review_id, created)
    github.add_thread(root, review_id, anchor, body, function(id, err)
      if err and created then
        log.info("removing the draft review started for the rejected comment")
        github.delete_review(root, review_id, function() end)
      end
      finish("comment on " .. anchor.path, callback)(id, err)
    end)
  end
  local function start()
    github.start_review(root, pr.id, target.commit, function(review_id, err)
      if err then return finish("start review", callback)(nil, err) end
      add(review_id, true)
    end)
  end
  if pending and pending.commit == target.commit then return add(pending.id, false) end
  if not pending then return start() end
  -- An empty draft review on another commit (comment_target refuses one
  -- that has comments): replace it with one on this commit.
  log.info("replacing the empty draft review on %s", short(pending.commit))
  github.delete_review(root, pending.id, function(_, err)
    if err then return finish("replace draft review", callback)(nil, err) end
    start()
  end)
end

function M.reply(thread, body, callback)
  local pending = M.pending()
  log.info("reply in thread %s%s", thread.id, pending and " (draft)" or "")
  github.reply(S.root, thread.id, body, pending and pending.id or nil, finish("reply", callback))
end

function M.set_resolved(thread, resolved, callback)
  github.set_resolved(S.root, thread.id, resolved, finish(resolved and "resolve" or "unresolve", callback))
end

function M.edit_comment(comment, body, callback)
  github.update_comment(S.root, comment.id, body, finish("edit comment", callback))
end

function M.delete_comment(comment, callback)
  github.delete_comment(S.root, comment.id, finish("delete comment", callback))
end

--- Submit the review: the draft review if there is one, else a review of
--- the head commit with just `body`.
--- @param event string  a key of github.EVENTS
function M.submit(event, body, callback)
  local pr = S.pr
  if not pr then return callback("no pull request") end
  local pending = M.pending()
  local gh_event = github.EVENTS[event]
  body = body ~= "" and body or nil
  log.info("submit review of #%d as %s (%s)", pr.number, gh_event, pending and "draft review" or "no drafts")
  if pending then
    github.submit_review(S.root, pending.id, gh_event, body, finish("submit review", callback))
  else
    github.post_review(S.root, pr.id, pr.head_oid, gh_event, body, finish("submit review", callback))
  end
end

--- Throw the draft review away.
function M.discard(callback)
  local pending = M.pending()
  if not pending then return callback(nil) end
  log.info("discard draft review %s", pending.id)
  github.delete_review(S.root, pending.id, finish("discard review", callback))
end

--- Open the pull request in the browser.
function M.open_in_browser()
  local pr = S.pr
  if not pr then return end
  log.info("opening #%d in the browser", pr.number)
  gh.run({ "pr", "view", tostring(pr.number), "--web" }, S.root, function(_, stderr, code)
    if code ~= 0 then
      vim.notify("diff.nvim: cannot open the pull request: " .. stderr, vim.log.levels.WARN)
    end
  end)
end

return M
