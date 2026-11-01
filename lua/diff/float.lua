--- diff.nvim — opens the plugin's bordered floats (the branch picker, the
--- comment editor, the comments float) with one look: the picker colours,
--- and a footer listing keys where Neovim can draw one.
local M = {}

local chrome = require("diff.chrome")
local log    = require("diff.log").scope("float")

local aug = vim.api.nvim_create_augroup("DiffNvimFloat", { clear = true })

-- window -> { winhighlight = string, options = table|nil }: the look each float keeps.
local kept = {}
local watching = false
local sweep_pending = false

local WINHIGHLIGHT = "Normal:DiffNvimPickerNormal,FloatBorder:DiffNvimPickerBorder,"
  .. "FloatTitle:DiffNvimPickerTitle,FloatFooter:DiffNvimPickerFooter"

local function restore(win, look)
  for name, value in pairs(look.options or {}) do
    if vim.api.nvim_get_option_value(name, { win = win }) ~= value then
      pcall(vim.api.nvim_set_option_value, name, value, { win = win })
    end
  end
  if vim.api.nvim_get_option_value("winhighlight", { win = win }) ~= look.winhighlight then
    log.debug("window %d lost its highlights to another plugin or config; restoring them", win)
    pcall(vim.api.nvim_set_option_value, "winhighlight", look.winhighlight, { win = win })
  end
end

--- Keep `win`'s highlights and options as they are now, against a config or
--- plugin that rewrites them when focus moves (a "dim the inactive window"
--- autocmd would otherwise strip a float's border and colours once it is left).
--- @param look table  { winhighlight = string, options = table|nil }
function M.keep_look(win, look)
  kept[win] = look
  if watching then return end
  watching = true
  vim.api.nvim_create_autocmd({ "WinEnter", "WinLeave", "BufWinEnter" }, {
    group = aug,
    callback = function()
      if sweep_pending then return end
      sweep_pending = true
      vim.schedule(function()
        sweep_pending = false
        for w, l in pairs(kept) do
          if vim.api.nvim_win_is_valid(w) then restore(w, l) else kept[w] = nil end
        end
      end)
    end,
  })
end

--- Open `buf` in a float.
--- @param buf   integer
--- @param enter boolean  focus it
--- @param cfg   table    nvim_open_win config; a `title` is padded and centred
--- @param opts  table|nil { footer = string|nil, winhighlight = string|nil (added to the shared one),
---   options = table|nil  window options to set and keep, such as { cursorline = false } }
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
  local winhighlight = WINHIGHLIGHT .. (opts.winhighlight and ("," .. opts.winhighlight) or "")
  vim.wo[win].winhighlight = winhighlight
  for name, value in pairs(opts.options or {}) do
    pcall(vim.api.nvim_set_option_value, name, value, { win = win })
  end
  M.keep_look(win, { winhighlight = winhighlight, options = opts.options })
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
