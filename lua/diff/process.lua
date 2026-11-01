--- diff.nvim — runs an external command asynchronously and collects its
--- output. Shared by the git and gh clients, which add their own logging.
local M = {}

--- @param cmd      string[]   The command and its arguments.
--- @param opts     table      { cwd = string, env = table|nil, stdin = string|nil, raw = boolean|nil }
---   raw: keep stdout exactly as delivered. The final element is "" when the
---   output ended with a newline, which content readers need to see.
--- @param callback fun(lines: string[], stderr: string, code: integer)
---   Called on the main loop. code is -1 when the command could not start.
--- @return boolean started
function M.run(cmd, opts, callback)
  local stdout_chunks = {}
  local stderr_chunks = {}

  local ok, job_id = pcall(vim.fn.jobstart, cmd, {
    cwd = opts.cwd,
    env = opts.env,
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
        callback(stdout_chunks, stderr_str, code)
      end)
    end,
  })

  -- jobstart returns <= 0 (or raises, for a missing executable on some
  -- versions) when the command cannot start.
  if not ok or job_id <= 0 then
    vim.schedule(function()
      callback({}, "failed to start " .. tostring(cmd[1]), -1)
    end)
    return false
  end

  if opts.stdin then
    vim.fn.chansend(job_id, opts.stdin)
  end
  vim.fn.chanclose(job_id, "stdin")
  return true
end

return M
