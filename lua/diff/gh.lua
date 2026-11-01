--- diff.nvim — runs the GitHub CLI (`gh`), which supplies the logged-in
--- session. Nothing here knows about pull requests; see github.lua.
local M = {}

local log = require("diff.log").scope("gh")

-- No pager, prompt or colour: the output is parsed, never shown.
local GH_ENV = { GH_PAGER = "", GH_PROMPT_DISABLED = "1", NO_COLOR = "1", GH_NO_UPDATE_NOTIFIER = "1" }

--- Run `gh <args>`.
--- @param args     string[]
--- @param cwd      string
--- @param callback fun(stdout: string, stderr: string, code: integer)  code -1: gh did not start
--- @param opts     table|nil  { stdin = string|nil }
function M.run(args, cwd, callback, opts)
  opts = opts or {}
  local elapsed = require("diff.log").timer()
  local cmd = vim.list_extend({ "gh" }, args)
  require("diff.process").run(cmd, { cwd = cwd, env = GH_ENV, stdin = opts.stdin }, function(lines, stderr, code)
    log.debug("gh %s -> exit %d in %.1f ms", table.concat(args, " "), code, elapsed())
    if code ~= 0 and stderr ~= "" then log.debug("gh %s stderr: %s", args[1] or "", stderr) end
    callback(table.concat(lines, "\n"), stderr, code)
  end)
end

-- nil until checked; then whether gh is installed and logged in. Checked once
-- per session: logging in or out mid-session is rare, and `:DiffNvimRefresh`
-- can check again.
local authenticated = nil

--- Whether gh can talk to GitHub for the repository at `cwd`.
--- @param cwd      string
--- @param callback fun(ok: boolean)
--- @param opts     table|nil  { recheck = boolean }
function M.authenticated(cwd, callback, opts)
  if authenticated ~= nil and not (opts and opts.recheck) then
    callback(authenticated)
    return
  end
  M.run({ "auth", "status" }, cwd, function(_, stderr, code)
    authenticated = code == 0
    if code == -1 then
      log.info("gh is not installed; pull request features are off")
    elseif code ~= 0 then
      log.info("gh is not logged in; pull request features are off (%s)", stderr:match("^[^\n]*") or "")
    else
      log.debug("gh is logged in")
    end
    callback(authenticated)
  end)
end

--- The messages of a GraphQL error response, or nil.
local function graphql_errors(decoded)
  if type(decoded) ~= "table" or type(decoded.errors) ~= "table" then return nil end
  local msgs = {}
  for _, e in ipairs(decoded.errors) do
    table.insert(msgs, type(e) == "table" and tostring(e.message) or tostring(e))
  end
  return #msgs > 0 and table.concat(msgs, "; ") or nil
end

--- Send a GraphQL request. The request goes in on stdin as JSON, so no
--- value is ever read as a gh flag or as a file to attach (gh's `-F key=@x`).
--- @param cwd      string
--- @param query    string
--- @param vars     table
--- @param callback fun(data: table|nil, err: string|nil)
function M.graphql(cwd, query, vars, callback)
  local name = query:match("^%s*(%a+%s+%a+)") or "graphql"
  local body = vim.json.encode({ query = query, variables = next(vars) == nil and vim.empty_dict() or vars })
  M.run({ "api", "graphql", "--input", "-" }, cwd, function(stdout, stderr, code)
    local ok, decoded = pcall(vim.json.decode, stdout ~= "" and stdout or "null", { luanil = { object = true, array = true } })
    if not ok then decoded = nil end
    local err = graphql_errors(decoded)
    if code ~= 0 or err then
      local reason = stderr:gsub("^gh: ", "")
      err = err or (reason ~= "" and reason) or ("gh exited with " .. code)
      log.warn("%s failed: %s", name, err)
      callback(nil, err)
      return
    end
    if type(decoded) ~= "table" or type(decoded.data) ~= "table" then
      log.warn("%s returned no data", name)
      callback(nil, "GitHub returned no data")
      return
    end
    callback(decoded.data, nil)
  end, { stdin = body })
end

--- Forget the login check (tests, and a refresh that asks to recheck).
function M._reset()
  authenticated = nil
end

return M
