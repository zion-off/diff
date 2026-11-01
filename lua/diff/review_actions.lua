--- diff.nvim — review actions, shown before GitHub confirms them.
---
--- Each action changes the loaded review at once (pr.edit_review), so the
--- diff, the mode bar and the floats show it immediately, and queues its
--- GitHub request. Requests run one at a time, in the order they were made:
--- a reply to a comment written a moment ago waits until that comment exists
--- on GitHub, and picks up its real id. When a request fails, a notification
--- says what failed and why, and any text written for it goes to the unnamed
--- register. Once the queue is empty the review is read again, which replaces
--- what was shown with what GitHub has, failures included.
---
--- Each action returns nil once queued, or a reason it cannot be made.
local M = {}

local pr     = require("diff.pr")
local github = require("diff.github")
local log    = require("diff.log").scope("review-actions")

local queue, running = {}, false
local local_seq = 0

--- An id for something not on GitHub yet; replaced when it is.
local function local_id(kind)
  local_seq = local_seq + 1
  return "local:" .. kind .. ":" .. local_seq
end

local function now_iso()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function where(path, line)
  return path .. (line and (" line " .. line) or "")
end

--- Why a request on `obj` cannot be sent: it was never created on GitHub
--- (the request creating it failed). nil when it can.
local function not_on_github(obj)
  if type(obj.id) == "string" and obj.id:match("^local:") then
    return "it was never created on GitHub"
  end
end

local function report_failure(what, err, text)
  local msg = string.format("diff.nvim: couldn't %s: %s", what, err)
  if text and text ~= "" then
    vim.fn.setreg('"', text)
    msg = msg .. '. Your text is in the " register.'
  end
  vim.notify(msg, vim.log.levels.ERROR)
end

local function run_next()
  local task = table.remove(queue, 1)
  if not task then
    running = false
    log.debug("queue empty; reading the review again")
    pr.reload()
    return
  end
  running = true
  local elapsed = require("diff.log").timer()
  task.run(function(err)
    if err then
      log.warn("%s failed after %.0f ms: %s", task.what, elapsed(), err)
      report_failure(task.what, err, task.text)
    else
      log.info("%s: done in %.0f ms", task.what, elapsed())
    end
    run_next()
  end)
end

--- Queue a GitHub request. `run(done)` calls done(err).
--- @param what string  what it does, for the reader ("add your comment on a.lua line 3")
--- @param text string|nil  text written for it, kept when it fails
local function enqueue(what, text, run)
  table.insert(queue, { what = what, text = text, run = run })
  log.info("queued: %s (%d waiting)", what, #queue)
  if not running then run_next() end
end

--- @return boolean  whether requests are waiting or running (tests)
function M.busy()
  return running
end

local function new_comment(body, pending, commit)
  return {
    id = local_id("comment"), author = pr.viewer() or "you", body = body, created_at = now_iso(),
    pending = pending, commit = commit, can_update = true, can_delete = true,
  }
end

--- Add a draft comment at `anchor`, starting the draft review on
--- `target.commit` if there is none. A draft review started for a comment
--- GitHub then rejects is removed again, so it leaves nothing behind.
--- @param target table  from pr.comment_target: { pr_id, commit }
--- @param anchor table  { path, side, line, start_line|nil }
--- @return string|nil  why it cannot be made
function M.add_comment(target, anchor, body)
  local p, root = pr.pull_request(), pr.root()
  if not p then return "this branch has no open pull request" end
  if target.pr_id ~= p.id then
    log.info("comment written for another pull request; not sending it")
    return "the pull request shown changed while the comment was written"
  end
  -- A draft review GitHub has on another commit is empty (comment_target
  -- refuses one with comments); it is replaced by one on this commit.
  local before = pr.pending()
  local replaced = before and before.commit ~= target.commit and before.id or nil
  local comment = new_comment(body, true, target.commit)
  local thread = {
    id = local_id("thread"), path = anchor.path, side = anchor.side, line = anchor.line,
    start_line = anchor.start_line, original_line = anchor.line, start_side = anchor.start_line and anchor.side or nil,
    resolved = false, outdated = false, pending = true, commit = target.commit,
    can_reply = true, can_resolve = false, can_unresolve = false, comments = { comment },
  }
  local pending
  pr.edit_review(function(review)
    table.insert(review.threads, thread)
    if before and not replaced then
      before.count = before.count + 1
      pending = before
    else
      pending = { id = nil, commit = target.commit, count = 1 }
      review.pending = pending
    end
  end)
  enqueue("add your comment on " .. where(anchor.path, anchor.line), body, function(done)
    local function add(review_id, started)
      github.add_thread(root, review_id, anchor, body, function(ids, err)
        if err then
          if started then
            log.info("removing the draft review started for the rejected comment")
            pending.id = nil
            github.delete_review(root, review_id, function() end)
          end
          return done(err)
        end
        thread.id = ids.thread or thread.id
        comment.id = ids.comment or comment.id
        done(nil)
      end)
    end
    local function start()
      github.start_review(root, p.id, target.commit, function(review_id, err)
        if err then return done(err) end
        pending.id = review_id
        add(review_id, true)
      end)
    end
    -- An earlier comment in the queue may have started the draft review.
    if pending.id then return add(pending.id, false) end
    if not replaced then return start() end
    log.info("replacing the empty draft review %s", replaced)
    github.delete_review(root, replaced, function(_, err)
      if err then return done(err) end
      replaced = nil
      start()
    end)
  end)
end

--- Reply in `thread`. With a draft review the reply joins it; without one
--- it is published.
function M.reply(thread, body)
  local root, pending = pr.root(), pr.pending()
  local comment = new_comment(body, pending ~= nil, thread.commit)
  pr.edit_review(function()
    table.insert(thread.comments, comment)
    if pending then pending.count = pending.count + 1 end
  end)
  enqueue("reply on " .. where(thread.path, thread.line or thread.original_line), body, function(done)
    local why = not_on_github(thread)
    if why then return done(why) end
    github.reply(root, thread.id, body, pending and pending.id or nil, function(id, err)
      if err then return done(err) end
      if type(id) == "string" then comment.id = id end
      done(nil)
    end)
  end)
end

function M.set_resolved(thread, resolved)
  local root = pr.root()
  pr.edit_review(function() thread.resolved = resolved end)
  local what = (resolved and "resolve" or "reopen") .. " the thread on " .. where(thread.path, thread.line)
  enqueue(what, nil, function(done)
    local why = not_on_github(thread)
    if why then return done(why) end
    github.set_resolved(root, thread.id, resolved, function(_, err) done(err) end)
  end)
end

function M.edit_comment(comment, body)
  local root = pr.root()
  pr.edit_review(function() comment.body = body end)
  enqueue("save your edited comment", body, function(done)
    local why = not_on_github(comment)
    if why then return done(why) end
    github.update_comment(root, comment.id, body, function(_, err) done(err) end)
  end)
end

function M.delete_comment(comment)
  local root, pending = pr.root(), pr.pending()
  pr.edit_review(function(review)
    for i, t in ipairs(review.threads) do
      for j, c in ipairs(t.comments) do
        if c == comment then
          table.remove(t.comments, j)
          if #t.comments == 0 then table.remove(review.threads, i) end
          if c.pending and pending then pending.count = math.max(0, pending.count - 1) end
          return
        end
      end
    end
  end)
  enqueue("delete your comment", nil, function(done)
    local why = not_on_github(comment)
    if why then return done(why) end
    github.delete_comment(root, comment.id, function(_, err) done(err) end)
  end)
end

--- Submit the review: the draft review if there is one, else a review of
--- the head commit with just `body`.
--- @param event string  a key of github.EVENTS
function M.submit(event, body)
  local p, root, pending = pr.pull_request(), pr.root(), pr.pending()
  if not p then return "this branch has no open pull request" end
  local gh_event = github.EVENTS[event]
  local summary = body ~= "" and body or nil
  log.info("submit review of #%d as %s (%s)", p.number, gh_event, pending and "draft review" or "no drafts")
  if pending then pr.edit_review(function(review) pr.settle_drafts(review, "submitted") end) end
  enqueue("submit your review", body, function(done)
    if not pending then
      return github.post_review(root, p.id, p.head_oid, gh_event, summary, function(_, err) done(err) end)
    end
    github.submit_review(root, pending.id, gh_event, summary, function(_, err)
      if not err then pr.settle(pending.id, "submitted") end
      done(err)
    end)
  end)
end

--- Throw the draft review away. Drafts already gone on GitHub (submitted
--- or discarded in the browser) are no failure.
function M.discard()
  local p, root, pending = pr.pull_request(), pr.root(), pr.pending()
  if not (p and pending) then return nil end
  log.info("discard draft review %s", tostring(pending.id))
  pr.edit_review(function(review) pr.settle_drafts(review, "discarded") end)
  enqueue("discard your draft comments", nil, function(done)
    if not pending.id then return done(nil) end
    github.delete_review(root, pending.id, function(_, err)
      if not err then
        pr.settle(pending.id, "discarded")
        return done(nil)
      end
      github.fetch_review(root, p.id, function(review)
        local still = review and review.pending and review.pending.id == pending.id
        if review and not still then
          log.info("draft review %s was already gone on GitHub", pending.id)
          return done(nil)
        end
        done(err)
      end)
    end)
  end)
end

return M
