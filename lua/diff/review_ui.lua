--- diff.nvim — what the reader does to a pull request review: comment on
--- lines, read and act on threads, submit the review. Connects the review
--- state (pr.lua) and its actions (review_actions.lua) to the floats that
--- ask for text (compose.lua) and show threads (pr_thread.lua).
local M = {}

local pr        = require("diff.pr")
local actions   = require("diff.review_actions")
local compose   = require("diff.compose")
local pr_thread = require("diff.pr_thread")
local log       = require("diff.log").scope("review")

local function notify(msg, level)
  vim.notify("diff.nvim: " .. msg, level or vim.log.levels.INFO)
end

local function lines_label(first, last)
  return first == last and ("line " .. first) or ("lines " .. first .. "–" .. last)
end

--- `run` for a button of a float opened on the pull request shown now. If
--- another pull request (or none) is shown by the time it is pressed, it
--- refuses, and the float keeps what was typed.
local function bound_to_shown_pr(run)
  local p = pr.pull_request()
  local id = p and p.id
  return function(text, done)
    local now = pr.pull_request()
    if not (now and now.id == id) then
      log.info("pull request changed since the float opened; refusing")
      done("the pull request shown changed since this was opened")
      return
    end
    run(text, done)
  end
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
        { label = pending and "Add to review" or "Start a review", style = "primary",
          run = bound_to_shown_pr(function(text, done) done(actions.add_comment(target, anchor, text)) end) },
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
        { label = pr.pending() and "Add reply to review" or "Reply", style = "primary",
          run = bound_to_shown_pr(function(text, done) done(actions.reply(thread, text)) end) },
        { label = "Cancel" },
      },
    })
  end,
  set_resolved = function(thread, resolved)
    actions.set_resolved(thread, resolved)
  end,
  edit = function(_, comment)
    compose.open({
      title = "Edit comment",
      text = comment.body,
      on_close = refocus_thread,
      buttons = {
        { label = "Save", style = "primary",
          run = bound_to_shown_pr(function(text, done) done(actions.edit_comment(comment, text)) end) },
        { label = "Cancel" },
      },
    })
  end,
  delete = function(comment)
    actions.delete_comment(comment)
  end,
}

--- The threads `source` shows at `anchors` ({ side, line }), in order.
local function threads_at(source, anchors)
  local out = {}
  for _, group in ipairs(pr.threads_for(source)) do
    for _, a in ipairs(anchors) do
      if group.side == a.side and group.line == a.line then vim.list_extend(out, group.threads) end
    end
  end
  return out
end

--- Open the threads at `anchors` ({ side, line }: one per side a diff row
--- stands for) of the diff of `source`, in a float under buffer row `row`
--- of `win`.
function M.show_threads(win, row, source, anchors)
  if #threads_at(source, anchors) == 0 then return false end
  local first = anchors[1]
  pr_thread.open({
    win = win, row = row,
    where = string.format("%s %s", vim.fn.fnamemodify(source.path, ":t"), lines_label(first.line, first.line)),
    threads = function() return threads_at(source, anchors) end,
    actions = THREAD_ACTIONS,
  })
  return true
end

--- The draft comments as list lines at `width`: where each is, then its
--- text, wrapped.
--- @return string[] lines, table[] hls { row, s, e, hl }
local function drafts_list(drafts, width)
  local lines, hls = {}, {}
  for i, d in ipairs(drafts) do
    if i > 1 then table.insert(lines, "") end
    local where = " " .. d.path .. (d.line and (" line " .. d.line) or "")
    local kind = d.reply and "  reply" or (d.side == "old" and "  removed line" or "")
    table.insert(lines, where .. kind)
    table.insert(hls, { #lines - 1, 0, #where, "DiffNvimThreadAuthor" })
    if kind ~= "" then table.insert(hls, { #lines - 1, #where, -1, "DiffNvimThreadMeta" }) end
    for _, para in ipairs(vim.split(d.body:gsub("\r", ""), "\n", { plain = true })) do
      for _, wrapped in ipairs(require("diff.util").wrap(para, width - 3)) do table.insert(lines, "   " .. wrapped) end
    end
  end
  return lines, hls
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
      local err = actions.submit(event, text)
      if not err then notify(done_msg) end
      done(err)
    end
  end
  local items = {
    { label = "Comment", style = "primary", allow_empty = drafts > 0, run = bound_to_shown_pr(submit("comment", "review submitted")) },
    { label = "Approve", allow_empty = true, run = bound_to_shown_pr(submit("approve", "pull request approved")) },
    { label = "Request changes", run = bound_to_shown_pr(submit("request_changes", "changes requested")) },
  }
  if pending then
    table.insert(items, { label = "Discard drafts", style = "danger", confirm = "Confirm discard", allow_empty = true,
      run = bound_to_shown_pr(function(_, done)
        local err = actions.discard()
        if not err then notify("draft comments discarded") end
        done(err)
      end) })
  end
  table.insert(items, { label = "Open on GitHub", allow_empty = true, run = bound_to_shown_pr(function(_, done)
    pr.open_in_browser()
    done(nil)
  end) })
  table.insert(items, { label = "Cancel" })
  local drafts = pr.drafts()
  local list = #drafts > 0 and {
    title = string.format("Your %d draft comment%s", #drafts, #drafts == 1 and "" or "s"),
    render = function(width) return drafts_list(drafts, width) end,
  } or nil
  compose.open({ title = title, buttons = items, list = list })
end

--- Close the review floats (the interface closed).
function M.close()
  compose.close()
  pr_thread.close()
end

return M
