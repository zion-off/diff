--- diff.nvim — loads the old and new sides of a diff.
---
--- A "source" describes what is being diffed:
---   { kind = "worktree", path, old_path?, status, staged }
---   { kind = "commit",   path, old_path?, status, hash }
---   { kind = "range",    path, old_path?, status, old_blob, new_blob, base }
---     (a branch's changes since its merge base with `base`)
--- Both sides are returned as { lines = string[], eol = boolean }, read the
--- same way (binary mode, CRs and trailing blank lines kept) so identical
--- content always compares equal.
local M = {}

local git = require("diff.git")
local log = require("diff.log").scope("content")

local EMPTY = { lines = {}, eol = true }

--- Read a working-tree file exactly.
--- @param abs_path string
--- @return {lines: string[], eol: boolean}|nil, string|nil
function M.read_worktree(abs_path)
  local ok, lines = pcall(vim.fn.readfile, abs_path, "b")
  if not ok then return nil, tostring(lines) end
  local eol = true
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines)
  elseif #lines > 0 then
    eol = false
  end
  return { lines = lines, eol = eol }, nil
end

--- Both readfile() and jobstart deliver NUL bytes as "\n" inside a line, so a
--- line containing "\n" means the content had a NUL — git's own heuristic
--- for binary data. Only the first 8000 bytes are inspected, as git does.
--- @param content {lines: string[]}|nil
--- @return boolean
function M.looks_binary(content)
  if not content then return false end
  local budget = 8000
  for _, line in ipairs(content.lines) do
    if line:find("\n", 1, true) then return true end
    budget = budget - #line - 1
    if budget <= 0 then break end
  end
  return false
end

local function from_object(root, object, cb)
  git.get_object(root, object, function(content, err)
    if not content then
      log.debug("no content for %s (%s)", object, err or "?")
    end
    cb(content or EMPTY)
  end)
end

local function from_ref(root, ref, path, cb)
  from_object(root, ref .. ":" .. path, cb)
end

local function from_worktree(root, path, cb)
  -- Deferred so callers always receive results asynchronously, like the git
  -- readers, and never re-enter their own setup code.
  vim.schedule(function()
    local content, err = M.read_worktree(root .. "/" .. path)
    if not content then
      log.warn("cannot read %s: %s", path, err or "?")
    end
    cb(content or EMPTY)
  end)
end

local function empty(cb)
  vim.schedule(function() cb(EMPTY) end)
end

--- Load both sides of `source` in parallel.
--- @param root   string
--- @param source table
--- @param cb     fun(old: table, new: table)
function M.load(root, source, cb)
  local old, new
  local pending = 2
  local function done()
    pending = pending - 1
    if pending == 0 then cb(old, new) end
  end
  local function set_old(c) old = c; done() end
  local function set_new(c) new = c; done() end

  local status   = source.status
  local old_path = source.old_path or source.path

  if source.kind == "commit" then
    if status == "added" then empty(set_old) else from_ref(root, source.hash .. "^", old_path, set_old) end
    if status == "deleted" then empty(set_new) else from_ref(root, source.hash, source.path, set_new) end
  elseif source.kind == "range" then
    if status == "added" then empty(set_old) else from_object(root, source.old_blob, set_old) end
    if status == "deleted" then empty(set_new) else from_object(root, source.new_blob, set_new) end
  elseif source.staged then
    if status == "added" then empty(set_old) else from_ref(root, "HEAD", old_path, set_old) end
    if status == "deleted" then empty(set_new) else from_ref(root, "", source.path, set_new) end
  else
    if status == "untracked" then empty(set_old) else from_ref(root, "", source.path, set_old) end
    if status == "deleted" then empty(set_new) else from_worktree(root, source.path, set_new) end
  end
end

return M
