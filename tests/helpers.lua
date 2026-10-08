local H = {}

function H.eq(actual, expected, msg)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s\n  expected: %s\n  actual:   %s",
      msg or "values differ", vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

function H.ok(value, msg)
  if not value then error(msg or "expected a truthy value", 2) end
  return value
end

--- Wait for `pred` to become true, failing with `msg` after `ms`.
function H.wait(pred, msg, ms)
  if not vim.wait(ms or 3000, pred, 5) then
    error("timed out: " .. (msg or "condition"), 2)
  end
end

--- Run a shell command (list form) and return its output, failing on error.
function H.sh(cmd, cwd)
  local out = vim.fn.system(cwd and vim.list_extend({ "git", "-C", cwd }, cmd) or cmd)
  if vim.v.shell_error ~= 0 then
    error(string.format("command failed (%d): %s\n%s", vim.v.shell_error, table.concat(cmd, " "), out), 2)
  end
  return out
end

function H.git(repo, ...)
  return H.sh({ ... }, repo)
end

--- Write exact bytes to a file inside `repo`, creating directories.
function H.write(repo, path, content)
  local full = repo .. "/" .. path
  vim.fn.mkdir(vim.fn.fnamemodify(full, ":h"), "p")
  local f = assert(io.open(full, "wb"))
  f:write(content)
  f:close()
end

function H.read(repo, path)
  local f = assert(io.open(repo .. "/" .. path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

--- Create a committed repository containing `files` ({ path = content }).
--- The path is resolved so it matches what `git rev-parse` reports.
function H.repo(files)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  dir = vim.fn.resolve(dir)
  H.git(dir, "init", "-q")
  H.git(dir, "config", "user.email", "test@example.com")
  H.git(dir, "config", "user.name", "test")
  H.git(dir, "config", "commit.gpgsign", "false")
  for path, content in pairs(files or {}) do H.write(dir, path, content) end
  H.git(dir, "add", "-A")
  H.git(dir, "commit", "-q", "--allow-empty", "-m", "initial")
  return dir
end

--- Numbered lines "line 1\n" … "line n\n", optionally overridden per line.
function H.lines(n, overrides)
  local out = {}
  for i = 1, n do out[i] = (overrides and overrides[i]) or ("line " .. i) end
  return out
end

function H.text(lines)
  return table.concat(lines, "\n") .. "\n"
end

--- Count git processes spawned while `fn` runs (and until `settle_ms` later).
function H.count_git(fn, settle_ms)
  local git = require("diff.git")
  local orig = git.run
  local calls = {}
  git.run = function(args, ...)
    table.insert(calls, table.concat(args, " "))
    return orig(args, ...)
  end
  local ok, err = pcall(fn)
  vim.wait(settle_ms or 200)
  git.run = orig
  if not ok then error(err, 0) end
  return calls
end

return H
