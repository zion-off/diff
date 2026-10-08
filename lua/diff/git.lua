local M = {}

local log = require("diff.log").scope("git")

-- Unit Separator (0x1F) used as a field delimiter in --format outputs to avoid
-- clashes with commit content. Declared at module scope so every helper (log,
-- for-each-ref, …) can reference it regardless of definition order.
local SEP = string.char(0x1F)

-- Record Separator (0x1E) marks the end of the commit message in `git show`
-- output that is followed by a file list.
local RS = string.char(0x1E)

-- GIT_OPTIONAL_LOCKS=0 stops read-only commands such as `git status` from
-- opportunistically rewriting .git/index to refresh stat info. Without it the
-- panel's own refresh writes the index, which the .git watcher then reports as
-- an external change.
local GIT_ENV = { GIT_OPTIONAL_LOCKS = "0" }

-- core.quotepath=false keeps non-ASCII paths verbatim instead of octal-escaped
-- and quoted, so they match the paths used to read files.
local GIT_PREFIX = { "git", "-c", "core.quotepath=false" }

-- ---------------------------------------------------------------------------
-- Core runner
-- ---------------------------------------------------------------------------

--- Run a git command asynchronously.
--- @param args     string[]   Arguments passed to git (after "git").
--- @param cwd      string     Working directory for the process.
--- @param callback fun(lines: string[], stderr: string, code: number)
--- @param opts     table|nil  { stdin = string|nil, raw = boolean|nil }
---   raw: keep stdout exactly as delivered. The final element is "" when the
---   output ended with a newline, which content readers need to see.
function M.run(args, cwd, callback, opts)
  opts = opts or {}
  local stdout_chunks = {}
  local stderr_chunks = {}
  local elapsed = require("diff.log").timer()

  local cmd = vim.list_extend(vim.list_extend({}, GIT_PREFIX), args)

  local job_id = vim.fn.jobstart(cmd, {
    cwd = cwd,
    env = GIT_ENV,
    stdout_buffered = true,
    stderr_buffered = true,

    -- Append rather than assign: a second callback must not discard data
    -- received before it.
    on_stdout = function(_, data)
      if data then vim.list_extend(stdout_chunks, data) end
    end,

    on_stderr = function(_, data)
      if data then vim.list_extend(stderr_chunks, data) end
    end,

    on_exit = function(_, code)
      vim.schedule(function()
        if not opts.raw then
          while #stdout_chunks > 0 and stdout_chunks[#stdout_chunks] == "" do
            table.remove(stdout_chunks)
          end
        end
        local stderr_str = table.concat(stderr_chunks, "\n"):gsub("\n+$", "")
        log.debug("git %s -> exit %d in %.1f ms (%d lines)",
          table.concat(args, " "), code, elapsed(), #stdout_chunks)
        if code ~= 0 and stderr_str ~= "" then
          log.debug("git %s stderr: %s", args[1], stderr_str)
        end
        callback(stdout_chunks, stderr_str, code)
      end)
    end,
  })

  -- jobstart returns <= 0 on failure (command not found, invalid args, etc.)
  if job_id <= 0 then
    log.error("failed to start git %s (jobstart returned %d)", table.concat(args, " "), job_id)
    vim.schedule(function()
      callback({}, "failed to start git process (is git installed?)", -1)
    end)
    return
  end

  if opts.stdin then
    vim.fn.chansend(job_id, opts.stdin)
  end
  vim.fn.chanclose(job_id, "stdin")
end

-- ---------------------------------------------------------------------------
-- Repository
-- ---------------------------------------------------------------------------

--- Resolve the work-tree root and the git directory for `cwd`.
--- The git directory is resolved by git rather than assumed to be
--- `<root>/.git`: in a linked worktree or submodule `.git` is a file, and the
--- index lives elsewhere.
--- @param cwd      string
--- @param callback fun(info: {root: string, git_dir: string}|nil, err: string|nil)
function M.get_repo_info(cwd, callback)
  M.run({ "rev-parse", "--show-toplevel", "--absolute-git-dir" }, cwd, function(lines, stderr, code)
    if code ~= 0 or #lines < 2 then
      callback(nil, stderr ~= "" and stderr or "not a git repository")
      return
    end
    callback({ root = vim.trim(lines[1]), git_dir = vim.trim(lines[2]) }, nil)
  end)
end

-- ---------------------------------------------------------------------------
-- Branches
-- ---------------------------------------------------------------------------

--- List local and remote branches, sorted by most-recent commit.
--- @param root     string
--- @param callback fun(branches: table[], err: string|nil)
---   Each entry: { name = string, is_head = boolean, is_remote = boolean }
function M.list_branches(root, callback)
  -- Fields: %(HEAD) "*" for current branch; full %(refname) to reliably tell
  -- local (refs/heads/…) from remote (refs/remotes/…); short name for display.
  local fmt = "%(HEAD)" .. SEP .. "%(refname)" .. SEP .. "%(refname:short)"
  M.run(
    { "for-each-ref", "--sort=-committerdate", "--format=" .. fmt,
      "refs/heads", "refs/remotes" },
    root,
    function(lines, stderr, code)
      if code ~= 0 then
        callback(nil, stderr ~= "" and stderr or "cannot list branches")
        return
      end

      local branches = {}
      for _, line in ipairs(lines) do
        if line ~= "" then
          local head_mark, full, name = line:match("^(.-)" .. SEP .. "(.-)" .. SEP .. "(.+)$")
          if name and name ~= "" then
            local is_remote = full:match("^refs/remotes/") ~= nil
            -- Skip the symbolic "origin/HEAD -> origin/main" pointer.
            if not (is_remote and name:match("/HEAD$")) then
              table.insert(branches, {
                name      = name,
                is_head   = (head_mark == "*"),
                is_remote = is_remote,
              })
            end
          end
        end
      end
      callback(branches, nil)
    end
  )
end

-- ---------------------------------------------------------------------------
-- Status
-- ---------------------------------------------------------------------------

local STATUS_MAP = {
  M = "modified",
  A = "added",
  D = "deleted",
  R = "renamed",
  C = "copied",
  U = "unmerged",
  ["?"] = "untracked",
}

local IGNORED_CHARS = { [" "] = true, ["?"] = true, ["!"] = true }
local UNSTAGED_CLEAN = { [" "] = true, ["!"] = true }

local function parse_status_char(c)
  return STATUS_MAP[c] or "unknown"
end

local function parse_porcelain_line(line)
  if #line < 4 then return nil end

  local x = line:sub(1, 1)
  local y = line:sub(2, 2)
  local rest = line:sub(4)

  local path, old_path

  if x == "R" or x == "C" or y == "R" or y == "C" then
    local arrow = rest:find(" -> ", 1, true)
    if arrow then
      old_path = rest:sub(1, arrow - 1)
      path = rest:sub(arrow + 4)
    else
      path = rest
    end
  else
    path = rest
  end

  return x, y, path, old_path
end

--- Get the working-tree / index status.
--- @param root     string
--- @param callback fun(status: {staged: table[], unstaged: table[]}, err: string|nil)
function M.get_status(root, callback)
  M.run({ "status", "--porcelain", "-u" }, root, function(lines, stderr, code)
    if code ~= 0 then
      callback({ staged = {}, unstaged = {} }, stderr)
      return
    end

    local staged   = {}
    local unstaged = {}

    for _, line in ipairs(lines) do
      local x, y, path, old_path = parse_porcelain_line(line)
      if not x then goto continue end

      if not IGNORED_CHARS[x] then
        table.insert(staged, {
          path        = path,
          old_path    = old_path,
          status      = parse_status_char(x),
          status_char = x,
        })
      end

      if not UNSTAGED_CLEAN[y] then
        table.insert(unstaged, {
          path        = path,
          old_path    = old_path,
          status      = parse_status_char(y),
          status_char = y,
        })
      end

      ::continue::
    end

    callback({ staged = staged, unstaged = unstaged }, nil)
  end)
end

-- ---------------------------------------------------------------------------
-- Diffstat (per-file insertions/deletions)
-- ---------------------------------------------------------------------------

local function numstat_entry(a, d)
  return { added = tonumber(a), deleted = tonumber(d), binary = (a == "-" or d == "-") }
end

--- Parse `--numstat` output (newline-terminated records) into a map keyed by
--- path. For renames the new path is used.
--- @param lines string[]
--- @return table<string, {added: number|nil, deleted: number|nil, binary: boolean}>
local function parse_numstat(lines)
  local map = {}
  for _, line in ipairs(lines) do
    local a, d, rest = line:match("^(%S+)\t(%S+)\t(.+)$")
    if a then
      local path = rest
      local arrow = rest:find(" => ", 1, true)
      if arrow then
        -- "old => new" or brace form "dir/{old => new}/file".
        local pre, new_mid, post = rest:match("^(.-){.- => (.-)}(.*)$")
        if pre then
          path = (pre .. new_mid .. post):gsub("//", "/")
        else
          path = rest:sub(arrow + 4)
        end
      end
      map[path] = numstat_entry(a, d)
    end
  end
  return map
end

--- Get per-file insertion/deletion counts for the index and the working tree.
--- Both queries run in parallel.
---
--- Plumbing (diff-index / diff-files) on purpose: porcelain `git diff`
--- refreshes stale stat info and rewrites .git/index even with
--- GIT_OPTIONAL_LOCKS=0, which the .git watcher would report as an external
--- change after every save.
--- @param root     string
--- @param callback fun(stats: {staged: table, unstaged: table}, err: string|nil)
function M.get_diffstat(root, callback)
  local result, pending, first_err = { staged = {}, unstaged = {} }, 2, nil
  local function collect(key)
    return function(lines, stderr, code)
      if code == 0 then
        result[key] = parse_numstat(lines)
      else
        first_err = first_err or stderr
      end
      pending = pending - 1
      if pending == 0 then callback(result, first_err) end
    end
  end
  M.run({ "diff-index", "--cached", "--numstat", "-M", "HEAD" }, root, collect("staged"))
  M.run({ "diff-files", "--numstat" }, root, collect("unstaged"))
end

-- ---------------------------------------------------------------------------
-- File content
-- ---------------------------------------------------------------------------

--- Retrieve a file's exact content at a ref. Pass ref = "" for the index.
--- Trailing blank lines and CR characters are preserved, and `eol` reports
--- whether the content ended with a newline, so the result compares cleanly
--- against the working tree read in binary mode.
--- @param callback fun(content: {lines: string[], eol: boolean}|nil, err: string|nil)
function M.get_file_at_ref(root, ref, path, callback)
  M.run({ "show", ref .. ":" .. path }, root, function(lines, stderr, code)
    if code ~= 0 then
      callback(nil, stderr)
      return
    end
    local eol = true
    if #lines > 0 and lines[#lines] == "" then
      table.remove(lines)
    elseif #lines > 0 then
      eol = false
    end
    callback({ lines = lines, eol = eol }, nil)
  end, { raw = true })
end

-- ---------------------------------------------------------------------------
-- Log — uses Unit Separator (0x1F) as field delimiter to avoid NUL byte issues
-- ---------------------------------------------------------------------------

local LOG_FMT = "%H" .. SEP .. "%h" .. SEP .. "%an" .. SEP .. "%ar" .. SEP .. "%s" .. SEP .. "%D"

--- Fetch recent commits.
--- @param root     string
--- @param n        number    Max number of commits.
--- @param callback fun(commits: table[], err: string|nil)
--- @param ref      string|nil Optional ref/branch to read history from
---   (defaults to HEAD when nil). Used by branch-preview mode.
function M.get_commits(root, n, callback, ref)
  local args = { "log", "--format=" .. LOG_FMT, "-n", tostring(n) }
  if ref and ref ~= "" then
    table.insert(args, ref)
  end
  M.run(args, root, function(lines, stderr, code)
    if code ~= 0 then
      callback(nil, stderr)
      return
    end

    local commits = {}
    for _, line in ipairs(lines) do
      local parts = vim.split(line, SEP, { plain = true })
      if #parts >= 5 then
        local refs = {}
        for r in (parts[6] or ""):gmatch("[^,]+") do
          local trimmed = vim.trim(r)
          if trimmed ~= "" then
            -- git emits the current branch as "HEAD -> main"; split it into
            -- two distinct refs so each gets its own pill/colour.
            local head, branch = trimmed:match("^(HEAD)%s*%->%s*(.+)$")
            if head then
              table.insert(refs, head)
              table.insert(refs, branch)
            else
              table.insert(refs, trimmed)
            end
          end
        end

        table.insert(commits, {
          hash       = parts[1],
          short_hash = parts[2],
          author     = parts[3],
          time       = parts[4],
          subject    = parts[5],
          refs       = refs,
        })
      end
    end

    callback(commits, nil)
  end)
end

-- ---------------------------------------------------------------------------
-- Commit details (message + changed files + per-file stats)
-- ---------------------------------------------------------------------------

--- Parse `--numstat -z` output. jobstart reports NUL bytes as "\n" inside
--- each delivered line, so the records are recovered by splitting on "\n".
--- Rename records are "a\td\t" followed by separate old and new path fields.
local function parse_numstat_z(lines)
  local fields = vim.split(table.concat(lines, "\n"), "\n", { plain = true })
  local map, i = {}, 1
  while i <= #fields do
    local a, d, path = fields[i]:match("^(%S+)\t(%S+)\t(.*)$")
    if a then
      if path == "" then
        path = fields[i + 2] -- rename: skip the old path, keep the new one
        i = i + 2
      end
      if path and path ~= "" then map[path] = numstat_entry(a, d) end
    end
    i = i + 1
  end
  return map
end

--- Fetch everything the commit panel shows for an expanded commit, using two
--- parallel processes.
--- @param root     string
--- @param hash     string
--- @param callback fun(details: {body: string[], files: table[], added: integer, deleted: integer}|nil, err: string|nil)
---   Each file: { path, old_path|nil, status, status_char, stat|nil }
function M.get_commit_details(root, hash, callback)
  local body, files, stats, err
  local pending = 2

  local function done()
    pending = pending - 1
    if pending > 0 then return end
    if not files then
      callback(nil, err or "cannot read commit")
      return
    end
    local added, deleted = 0, 0
    for _, f in ipairs(files) do
      f.stat = stats and stats[f.path] or nil
      if f.stat then
        added   = added + (f.stat.added or 0)
        deleted = deleted + (f.stat.deleted or 0)
      end
    end
    callback({ body = body, files = files, added = added, deleted = deleted }, nil)
  end

  M.run({ "show", "--no-color", "--no-show-signature", "--format=%B" .. RS, "--name-status", hash }, root,
    function(lines, stderr, code)
      if code ~= 0 then
        err = stderr
        done()
        return
      end
      body, files = {}, {}
      local in_files = false
      for _, line in ipairs(lines) do
        if not in_files then
          local rs = line:find(RS, 1, true)
          if rs then
            in_files = true
            local before = line:sub(1, rs - 1)
            if before ~= "" then table.insert(body, before) end
          else
            table.insert(body, line)
          end
        elseif line ~= "" then
          -- "M\tpath" or "R100\told\tnew"
          local status_char, rest = line:match("^(%a)%d*\t(.+)$")
          if status_char then
            local path, old_path = rest, nil
            if status_char == "R" or status_char == "C" then
              old_path, path = rest:match("^(.-)\t(.+)$")
              path = path or rest
            end
            table.insert(files, {
              path        = path,
              old_path    = old_path,
              status      = parse_status_char(status_char),
              status_char = status_char,
            })
          end
        end
      end
      while #body > 0 and body[#body] == "" do table.remove(body) end
      done()
    end)

  M.run({ "show", "--no-color", "--no-show-signature", "--format=", "--numstat", "-z", hash }, root,
    function(lines, _, code)
      if code == 0 then stats = parse_numstat_z(lines) end
      done()
    end)
end

-- ---------------------------------------------------------------------------
-- Staging
-- ---------------------------------------------------------------------------

function M.stage_file(root, path, callback)
  M.run({ "add", "--", path }, root, function(_, stderr, code)
    callback(code == 0, code ~= 0 and stderr or nil)
  end)
end

function M.unstage_file(root, path, callback)
  M.run({ "restore", "--staged", "--", path }, root, function(_, stderr, code)
    callback(code == 0, code ~= 0 and stderr or nil)
  end)
end

--- Apply a patch to the index (used for hunk staging).
--- @param root     string
--- @param patch    string     Unified diff, zero context lines allowed.
--- @param reverse  boolean    true to unapply (unstage).
--- @param callback fun(ok: boolean, err: string|nil)
function M.apply_to_index(root, patch, reverse, callback)
  local args = { "apply", "--cached", "--unidiff-zero", "--whitespace=nowarn" }
  if reverse then table.insert(args, "--reverse") end
  table.insert(args, "-")
  M.run(args, root, function(_, stderr, code)
    callback(code == 0, code ~= 0 and stderr or nil)
  end, { stdin = patch })
end

return M
