--- diff.nvim — opens the plugin's bordered floats (the branch picker, the
--- comment editor, the comments float) with one look: the picker colours,
--- and a footer listing keys where Neovim can draw one.
local M = {}

local chrome = require("diff.chrome")
local log    = require("diff.log").scope("float")

local WINHIGHLIGHT = "Normal:DiffNvimPickerNormal,FloatBorder:DiffNvimPickerBorder,"
  .. "FloatTitle:DiffNvimPickerTitle,FloatFooter:DiffNvimPickerFooter"

--- Open `buf` in a float.
--- @param buf   integer
--- @param enter boolean  focus it
--- @param cfg   table    nvim_open_win config; a `title` is padded and centred
--- @param opts  table|nil { footer = string|nil, winhighlight = string|nil (added to the shared one) }
--- @return integer|nil  the window, nil when it could not open
function M.open(buf, enter, cfg, opts)
  opts = opts or {}
  cfg = vim.tbl_extend("force", { style = "minimal", border = "rounded" }, cfg)
  if cfg.title then cfg.title, cfg.title_pos = " " .. cfg.title .. " ", "center" end
  local ok, win
  if opts.footer then
    -- Footers need Neovim 0.10; without one the keys go unlisted rather
    -- than the float failing to open.
    ok, win = pcall(vim.api.nvim_open_win, buf, enter,
      vim.tbl_extend("force", cfg, { footer = " " .. opts.footer .. " ", footer_pos = "center" }))
  end
  if not ok then ok, win = pcall(vim.api.nvim_open_win, buf, enter, cfg) end
  if not ok then
    log.warn("cannot open a float: %s", tostring(win))
    return nil
  end
  vim.wo[win].winhighlight = WINHIGHLIGHT .. (opts.winhighlight and ("," .. opts.winhighlight) or "")
  return win
end

--- A scratch buffer for a float, wiped when hidden.
--- @param kind string  chrome tag ("compose", "pr-thread")
--- @param name string  buffer name
function M.scratch(kind, name)
  local buf = vim.api.nvim_create_buf(false, true)
  chrome.tag(buf, kind)
  chrome.name(buf, name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  return buf
end

--- Replace the lines of read-only `buf` and its highlights in `ns`.
--- @param hls table[]  { row (0-based), start_col, end_col (-1: end of line), hl_group }
function M.set_lines(buf, ns, lines, hls)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    local end_col = h[3] == -1 and #(lines[h[1] + 1] or "") or h[3]
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, h[1], h[2], { end_col = end_col, hl_group = h[4] })
  end
end

return M
