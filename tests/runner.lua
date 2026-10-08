-- Executes one spec file (path in $SPEC). A spec returns a list of
-- { name, fn } cases that run in order and may share state.
package.path = vim.fn.getcwd() .. "/tests/?.lua;" .. package.path

local spec_path = vim.fn.fnamemodify(assert(os.getenv("SPEC"), "SPEC not set"), ":p")
local loaded, cases = xpcall(dofile, debug.traceback, spec_path)
if not loaded then
  io.stdout:write(spec_path .. "\n  FAIL  loading spec\n" .. tostring(cases) .. "\n")
  vim.cmd("cquit 1")
end
local failed = 0

io.stdout:write(spec_path .. "\n")
for _, case in ipairs(cases) do
  local name, fn = case[1], case[2]
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    io.stdout:write("  ok    " .. name .. "\n")
  else
    failed = failed + 1
    io.stdout:write("  FAIL  " .. name .. "\n" .. tostring(err):gsub("\n", "\n        ") .. "\n")
  end
end

if failed > 0 then
  io.stdout:write(string.format("  %d of %d failed\n", failed, #cases))
  vim.cmd("cquit 1")
else
  vim.cmd("qall!")
end
