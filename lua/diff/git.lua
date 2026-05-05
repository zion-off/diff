local M = {}

-- ---------------------------------------------------------------------------
-- Core runner
-- ---------------------------------------------------------------------------

--- Run a git command asynchronously.
--- @param args     string[]   Arguments passed to git (after "git").
--- @param cwd      string     Working directory for the process.
--- @param callback fun(lines: string[], stderr: string, code: number)
function M.run(args, cwd, callback)
  local stdout_chunks = {}
  local stderr_chunks = {}

  local cmd = vim.list_extend({ "git" }, args)

  vim.fn.jobstart(cmd, {
    cwd = cwd,
    stdout_buffered = true,
    stderr_buffered = true,

    on_stdout = function(_, data)
      if data then
        stdout_chunks = data
      end
    end,

    on_stderr = function(_, data)
      if data then
        stderr_chunks = data
      end
    end,

    on_exit = function(_, code)
      vim.schedule(function()
        -- jobstart gives a trailing empty string; strip it
        while #stdout_chunks > 0 and stdout_chunks[#stdout_chunks] == "" do
          table.remove(stdout_chunks)
        end

        local stderr_str = table.concat(stderr_chunks, "\n"):gsub("\n+$", "")
        callback(stdout_chunks, stderr_str, code)
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
-- Diffs
-- ---------------------------------------------------------------------------

--- Get the diff for a tracked file.
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

--- Get a diff for an untracked file.
function M.get_untracked_diff(root, path, callback)
  M.run(
    { "diff", "--no-ext-diff", "--no-index", "--", "/dev/null", path },
    root,
    function(lines, stderr, code)
      if code ~= 0 and code ~= 1 then
        callback(nil, stderr)
      else
        callback(table.concat(lines, "\n"), nil)
      end
    end
  )
end

--- Retrieve a file's content at a specific ref.
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
-- Log — uses Unit Separator (0x1F) as field delimiter to avoid NUL byte issues
-- ---------------------------------------------------------------------------

local SEP = string.char(0x1F)
local LOG_FMT = "%H" .. SEP .. "%h" .. SEP .. "%an" .. SEP .. "%ar" .. SEP .. "%s" .. SEP .. "%D"

--- Fetch recent commits.
--- @param root     string
--- @param n        number    Max number of commits.
--- @param callback fun(commits: table[], err: string|nil)
function M.get_commits(root, n, callback)
  M.run(
    { "log", "--format=" .. LOG_FMT, "-n", tostring(n) },
    root,
    function(lines, stderr, code)
      if code ~= 0 then
        callback(nil, stderr)
        return
      end

      local commits = {}
      for _, line in ipairs(lines) do
        if line == "" then goto next_line end

        -- Split on the Unit Separator character
        local parts = {}
        local start_pos = 1
        while true do
          local sep_pos = line:find(SEP, start_pos, true)
          if sep_pos then
            table.insert(parts, line:sub(start_pos, sep_pos - 1))
            start_pos = sep_pos + 1
          else
            table.insert(parts, line:sub(start_pos))
            break
          end
        end

        if #parts >= 5 then
          local refs_str = parts[6] or ""
          local refs = {}
          if refs_str ~= "" then
            for r in refs_str:gmatch("[^,]+") do
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

        ::next_line::
      end

      callback(commits, nil)
    end
  )
end

-- ---------------------------------------------------------------------------
-- Commit diff
-- ---------------------------------------------------------------------------

--- Get the diff introduced by a commit.
function M.get_commit_diff(root, hash, file_path, callback)
  local args = { "diff", "--no-ext-diff", hash .. "^.." .. hash }
  if file_path then
    vim.list_extend(args, { "--", file_path })
  end

  M.run(args, root, function(lines, stderr, code)
    if code ~= 0 then
      -- Initial commit — no parent; fall back to git show
      local show_args = { "show", "--no-ext-diff", "--format=", hash }
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

-- ---------------------------------------------------------------------------
-- Commit file list
-- ---------------------------------------------------------------------------

--- Get the list of files changed in a commit.
--- @param root     string
--- @param hash     string
--- @param callback fun(files: table[]|nil, err: string|nil)
---   Each file entry: { path = string, old_path = string|nil, status = string, status_char = string }
function M.get_commit_files(root, hash, callback)
  M.run(
    { "diff-tree", "--no-commit-id", "-r", "--name-status", hash },
    root,
    function(lines, stderr, code)
      if code ~= 0 then
        callback(nil, stderr)
        return
      end

      local files = {}
      for _, line in ipairs(lines) do
        if line == "" then goto next end
        -- Format: "M\tpath" or "R100\told\tnew"
        local status_char, rest = line:match("^(%a%d*)%s+(.+)$")
        if status_char and rest then
          local s = status_char:sub(1, 1)
          local path = rest
          local old_path = nil
          -- Handle renames/copies (R100, C100)
          if s == "R" or s == "C" then
            local tab = rest:find("\t", 1, true)
            if tab then
              old_path = rest:sub(1, tab - 1)
              path = rest:sub(tab + 1)
            end
          end
          table.insert(files, {
            path        = path,
            old_path    = old_path,
            status      = parse_status_char(s),
            status_char = s,
          })
        end
        ::next::
      end

      callback(files, nil)
    end
  )
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

-- ---------------------------------------------------------------------------
-- Binary detection
-- ---------------------------------------------------------------------------

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
