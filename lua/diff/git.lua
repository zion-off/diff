local M = {}

-- ---------------------------------------------------------------------------
-- Core runner
-- ---------------------------------------------------------------------------

--- Run a git command asynchronously.
--- @param args     string[]   Arguments passed to git (after "git").
--- @param cwd      string     Working directory for the process.
--- @param callback fun(lines: string[], stderr: string, code: number)
function M.run(args, cwd, callback)
  local stdout_data = {}
  local stderr_data = {}

  local cmd = vim.list_extend({ "git" }, args)

  vim.fn.jobstart(cmd, {
    cwd = cwd,
    stdout_buffered = true,
    stderr_buffered = true,

    on_stdout = function(_, data)
      stdout_data = data
    end,

    on_stderr = function(_, data)
      stderr_data = data
    end,

    on_exit = function(_, code)
      vim.schedule(function()
        -- jobstart gives a trailing empty string; strip it
        while #stdout_data > 0 and stdout_data[#stdout_data] == "" do
          table.remove(stdout_data)
        end

        local stderr_str = table.concat(stderr_data, "\n"):gsub("\n+$", "")
        callback(stdout_data, stderr_str, code)
      end)
    end,
  })
end

-- ---------------------------------------------------------------------------
-- Repo root
-- ---------------------------------------------------------------------------

--- Resolve the git repo root for a given directory.
--- @param cwd      string
--- @param callback fun(root: string|nil, err: string|nil)
function M.get_repo_root(cwd, callback)
  M.run({ "rev-parse", "--show-toplevel" }, cwd, function(lines, stderr, code)
    if code ~= 0 or #lines == 0 then
      callback(nil, stderr ~= "" and stderr or "not a git repository")
    else
      callback(lines[1]:gsub("%s+$", ""), nil)
    end
  end)
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

-- Porcelain column values that carry no actionable status
local IGNORED_CHARS = { [" "] = true, ["?"] = true, ["!"] = true }
-- The unstaged column uses only space and ! for "clean" states
local UNSTAGED_CLEAN = { [" "] = true, ["!"] = true }

local function parse_status_char(c)
  return STATUS_MAP[c] or "unknown"
end

local function parse_porcelain_line(line)
  if #line < 4 then return nil end

  local x = line:sub(1, 1) -- staged column
  local y = line:sub(2, 2) -- unstaged column
  local rest = line:sub(4) -- path (possibly "old -> new" for renames)

  local path, old_path

  -- Porcelain v1 (without -z): renames are "old -> new"
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

      -- Staged entry (x column)
      if not IGNORED_CHARS[x] then
        table.insert(staged, {
          path        = path,
          old_path    = old_path,
          status      = parse_status_char(x),
          status_char = x,
        })
      end

      -- Unstaged / untracked entry (y column)
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
-- Diffs
-- ---------------------------------------------------------------------------

--- Get the diff for a tracked file.
--- @param root     string
--- @param path     string
--- @param staged   boolean   true → --cached
--- @param callback fun(diff: string, err: string|nil)
function M.get_diff(root, path, staged, callback)
  local args = { "diff", "--no-ext-diff" }
  if staged then
    table.insert(args, "--cached")
  end
  vim.list_extend(args, { "--", path })

  M.run(args, root, function(lines, stderr, code)
    if code ~= 0 then
      callback(nil, stderr)
    else
      callback(table.concat(lines, "\n"), nil)
    end
  end)
end

--- Get a diff for an untracked file by comparing /dev/null with the file.
--- Exit code 1 is normal for `git diff --no-index`.
--- @param root     string
--- @param path     string
--- @param callback fun(diff: string, err: string|nil)
function M.get_untracked_diff(root, path, callback)
  M.run(
    { "diff", "--no-ext-diff", "--no-index", "--", "/dev/null", path },
    root,
    function(lines, stderr, code)
      -- exit code 1 means "differences found" — that is expected
      if code ~= 0 and code ~= 1 then
        callback(nil, stderr)
      else
        callback(table.concat(lines, "\n"), nil)
      end
    end
  )
end

--- Retrieve a file's content at a specific ref.
--- @param root     string
--- @param ref      string    e.g. "HEAD", "main", a commit hash
--- @param path     string
--- @param callback fun(lines: string[], err: string|nil)
function M.get_file_at_ref(root, ref, path, callback)
  M.run({ "show", ref .. ":" .. path }, root, function(lines, stderr, code)
    if code ~= 0 then
      callback(nil, stderr)
    else
      callback(lines, nil)
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Log
-- ---------------------------------------------------------------------------

--- Fetch recent commits.
--- @param root     string
--- @param n        number    Max number of commits.
--- @param callback fun(commits: table[], err: string|nil)
function M.get_commits(root, n, callback)
  local fmt = "%H%x00%h%x00%an%x00%ar%x00%s%x00%D"
  M.run(
    { "log", "--format=" .. fmt, "-n", tostring(n) },
    root,
    function(lines, stderr, code)
      if code ~= 0 then
        callback(nil, stderr)
        return
      end

      local commits = {}
      for _, line in ipairs(lines) do
        local parts = vim.split(line, "\0", { plain = true })
        if #parts >= 5 then
          local refs_str = parts[6] or ""
          local refs = {}
          if refs_str ~= "" then
            for _, r in ipairs(vim.split(refs_str, ", ", { plain = true })) do
              local trimmed = r:gsub("^%s+", ""):gsub("%s+$", "")
              if trimmed ~= "" then
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
    end
  )
end

-- ---------------------------------------------------------------------------
-- Commit diff
-- ---------------------------------------------------------------------------

--- Get the diff introduced by a commit (or for a specific file in that commit).
--- Falls back to `git show` for the initial commit (no parent).
--- @param root      string
--- @param hash      string
--- @param file_path string|nil
--- @param callback  fun(diff: string, err: string|nil)
function M.get_commit_diff(root, hash, file_path, callback)
  local function run_diff(args_extra)
    local args = { "diff", "--no-ext-diff", hash .. "^.." .. hash }
    if file_path then
      vim.list_extend(args, { "--", file_path })
    end
    vim.list_extend(args, args_extra or {})

    M.run(args, root, function(lines, stderr, code)
      if code ~= 0 then
        -- Likely an initial commit — no parent exists; fall back to git show
        local show_args = { "show", "--no-ext-diff", hash }
        if file_path then
          vim.list_extend(show_args, { "--", file_path })
        end
        M.run(show_args, root, function(show_lines, show_stderr, show_code)
          if show_code ~= 0 then
            callback(nil, show_stderr)
          else
            callback(table.concat(show_lines, "\n"), nil)
          end
        end)
      else
        callback(table.concat(lines, "\n"), nil)
      end
    end)
  end

  run_diff()
end

-- ---------------------------------------------------------------------------
-- Staging
-- ---------------------------------------------------------------------------

--- Stage a file.
--- @param root     string
--- @param path     string
--- @param callback fun(ok: boolean, err: string|nil)
function M.stage_file(root, path, callback)
  M.run({ "add", "--", path }, root, function(_, stderr, code)
    if code ~= 0 then
      callback(false, stderr)
    else
      callback(true, nil)
    end
  end)
end

--- Unstage a file.
--- @param root     string
--- @param path     string
--- @param callback fun(ok: boolean, err: string|nil)
function M.unstage_file(root, path, callback)
  M.run({ "restore", "--staged", "--", path }, root, function(_, stderr, code)
    if code ~= 0 then
      callback(false, stderr)
    else
      callback(true, nil)
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Binary detection
-- ---------------------------------------------------------------------------

--- Check whether a file is binary by inspecting `git diff --numstat` output.
--- Binary files are reported as `-\t-\t<path>`.
--- @param root     string
--- @param path     string
--- @param callback fun(is_binary: boolean)
function M.is_binary(root, path, callback)
  M.run(
    { "diff", "--no-ext-diff", "--numstat", "HEAD", "--", path },
    root,
    function(lines, _, _)
      local binary = false
      for _, line in ipairs(lines) do
        if line:match("^%-\t%-\t") then
          binary = true
          break
        end
      end
      callback(binary)
    end
  )
end

return M
