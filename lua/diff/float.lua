--- diff.nvim — opens the plugin's bordered floats (the branch picker, the
--- comment editor, the comments float) with one look: the picker colours,
--- and a footer listing keys where Neovim can draw one.
local M = {}

local log = require("diff.log").scope("float")

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

return M
