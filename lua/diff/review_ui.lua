--- diff.nvim — what the reader does to a pull request review: comment on
--- lines, read and act on threads, submit the review. Connects the review
--- state (pr.lua) to the floats that ask for text (compose.lua) and show
--- threads (pr_thread.lua).
local M = {}

local pr        = require("diff.pr")
local compose   = require("diff.compose")
local pr_thread = require("diff.pr_thread")
local log       = require("diff.log").scope("review")

local function notify(msg, level)
  vim.notify("diff.nvim: " .. msg, level or vim.log.levels.INFO)
end

local function report(what)
  return function(err)
    if err then notify(what .. " failed: " .. err, vim.log.levels.ERROR) end
  end
end

local function lines_label(first, last)
  return first == last and ("line " .. first) or ("lines " .. first .. "–" .. last)
end

local function refocus_thread()
  local win = pr_thread.win()
  if win then pcall(vim.api.nvim_set_current_win, win) end
end

--- Comment on lines `first`..`last` of `side` ("old" or "new") in the diff
--- of `source`, after checking a comment can go there.
function M.comment(root, source, side, first, last)
  pr.comment_target(root, source, side, function(target, reason)
    if not target then
      log.info("comment on %s refused: %s", source.path, reason)
      notify(reason, vim.log.levels.WARN)
      return
    end
    local anchor = { path = source.path, side = side, line = last, start_line = first ~= last and first or nil }
    local pending = pr.pending()
    compose.open({
      title = string.format("Comment on %s %s", vim.fn.fnamemodify(source.path, ":t"), lines_label(first, last)),
      buttons = {
        { label = pending and "Add to review" or "Start a review", style = "primary", run = function(text, done)
          pr.add_comment(target, anchor, text, done)
        end },
        { label = "Cancel" },
      },
    })
  end)
end

local THREAD_ACTIONS = {
  reply = function(thread)
    compose.open({
      title = "Reply",
      on_close = refocus_thread,
      buttons = {
        { label = pr.pending() and "Add reply to review" or "Reply", style = "primary", run = function(text, done)
          pr.reply(thread, text, done)
        end },
        { label = "Cancel" },
      },
    })
  end,
  set_resolved = function(thread, resolved)
    pr.set_resolved(thread, resolved, report(resolved and "resolve" or "unresolve"))
  end,
  edit = function(_, comment)
    compose.open({
      title = "Edit comment",
      text = comment.body,
      on_close = refocus_thread,
      buttons = {
        { label = "Save", style = "primary", run = function(text, done) pr.edit_comment(comment, text, done) end },
        { label = "Cancel" },
      },
    })
  end,
  delete = function(comment)
    pr.delete_comment(comment, report("delete"))
  end,
}

--- The threads `source` shows on `side` line `line`.
local function threads_on(source, side, line)
  for _, group in ipairs(pr.threads_for(source)) do
    if group.side == side and group.line == line then return group.threads end
  end
  return {}
end

--- Open the threads on `side` line `line` of the diff of `source`, in a
--- float under buffer row `row` of `win`.
function M.show_threads(win, row, source, side, line)
  if #threads_on(source, side, line) == 0 then return false end
  pr_thread.open({
    win = win, row = row,
    where = string.format("%s %s", vim.fn.fnamemodify(source.path, ":t"), lines_label(line, line)),
    threads = function() return threads_on(source, side, line) end,
    actions = THREAD_ACTIONS,
  })
  return true
end

--- Open the review float: a summary, and buttons to submit it as a comment,
--- an approval or a request for changes, discard the draft comments, or open
--- the pull request on GitHub.
function M.open_review()
  local p = pr.pull_request()
  if not p then
    notify("this branch has no open pull request", vim.log.levels.WARN)
    return
  end
  local pending = pr.pending()
  local drafts = pending and pending.count or 0
  local title = "Review #" .. p.number
  if drafts > 0 then title = title .. string.format(" · %d draft comment%s", drafts, drafts == 1 and "" or "s") end
  local function submit(event, done_msg)
    return function(text, done)
      pr.submit(event, text, function(err)
        if not err then notify(done_msg) end
        done(err)
      end)
    end
  end
  local items = {
    { label = "Comment", style = "primary", allow_empty = drafts > 0, run = submit("comment", "review submitted") },
    { label = "Approve", allow_empty = true, run = submit("approve", "pull request approved") },
    { label = "Request changes", run = submit("request_changes", "changes requested") },
  }
  if pending then
    table.insert(items, { label = "Discard drafts", style = "danger", confirm = "Confirm discard", allow_empty = true,
      run = function(_, done) pr.discard(done) end })
  end
  table.insert(items, { label = "Open on GitHub", allow_empty = true, run = function(_, done)
    pr.open_in_browser()
    done(nil)
  end })
  table.insert(items, { label = "Cancel" })
  compose.open({ title = title, buttons = items })
end

--- Close the review floats (the interface closed).
function M.close()
  compose.close()
  pr_thread.close()
end

return M
