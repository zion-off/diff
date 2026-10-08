--- diff.nvim — leveled file logger.
---
--- Writes to `stdpath("log")/diff.nvim.log`. The threshold comes from the
--- `log_level` config option; at the default ("warn") only problems are
--- recorded, so normal use costs nothing. Set it to "debug" to trace git
--- commands, watcher events and render timings in a live session.
local M = {}

local LEVELS = { trace = 0, debug = 1, info = 2, warn = 3, error = 4, off = 5 }

local threshold = LEVELS.warn
local log_dir   = (vim.fn.stdpath("log") or vim.fn.stdpath("cache"))
local log_path  = log_dir .. "/diff.nvim.log"

--- @param level string|nil  One of trace, debug, info, warn, error, off.
function M.setup(level)
  threshold = LEVELS[level or "warn"] or LEVELS.warn
  -- Created here, not in write(): loggers run inside libuv callbacks (file
  -- watchers), where Vimscript functions such as mkdir() are not allowed.
  pcall(vim.fn.mkdir, log_dir, "p")
end

--- @return string
function M.path()
  return log_path
end

--- @param level string
--- @return boolean
function M.enabled(level)
  return LEVELS[level] >= threshold
end

local function write(level, scope, fmt, ...)
  if LEVELS[level] < threshold then return end
  local ok, msg = pcall(string.format, fmt, ...)
  if not ok then msg = fmt .. " (format error: " .. tostring(msg) .. ")" end
  -- Plain Lua I/O only: this must be safe in fast (libuv) callbacks.
  local f = io.open(log_path, "a")
  if not f then return end
  f:write(string.format("%s %-5s %s: %s\n", os.date("%Y-%m-%d %H:%M:%S"), level:upper(), scope, msg))
  f:close()
end

--- Create a logger bound to a scope name, e.g. `log.scope("git")`.
--- @param name string
function M.scope(name)
  local logger = {}
  for level in pairs(LEVELS) do
    if level ~= "off" then
      logger[level] = function(fmt, ...) write(level, name, fmt, ...) end
    end
  end
  return logger
end

--- Start a stopwatch; the returned function reports elapsed milliseconds.
--- @return fun(): number
function M.timer()
  local uv = vim.uv or vim.loop
  local t0 = uv.hrtime()
  return function() return (uv.hrtime() - t0) / 1e6 end
end

return M
