--- diff.nvim — mode bar: a two-row strip above the sidebar panels that keeps
--- the interface's modes in view and in reach of the mouse.
---
---   ⎇ feature/x                      ▾      branch shown; opens the picker
---    Changes   Branch changes                 file panel mode
---
--- While another branch is previewed (or another worktree shown) the first
--- row is tagged and gains a ✕ that returns to the home branch.
---
--- The bar knows nothing about git or the panels: render() is given what to
--- show, and each clickable segment carries the action the sidebar supplied.
local M = {}

local util = require("diff.util")

local NS       = vim.api.nvim_create_namespace("diff_nvim_mode_bar")
local NS_HOVER = vim.api.nvim_create_namespace("diff_nvim_mode_bar_hover")

M.HEIGHT = 2

local S = {
  buf = nil, win = nil,
  segments = {}, -- { row, s, e (byte cols, end exclusive), c1, c2 (display cols, inclusive), action, inert }
  hover = nil,   -- segment under the mouse pointer
  pointer = nil, -- { line, col } of the pointer over the bar
  info = nil,    -- what the last render() was given
}

local NS_CURSOR = vim.api.nvim_create_namespace("diff_nvim_mode_bar_cursor")

local function valid()
  return S.buf and vim.api.nvim_buf_is_valid(S.buf) and S.win and vim.api.nvim_win_is_valid(S.win)
end

-- ---------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------

--- Lay out one row from parts { text, hl, action? }; returns the line, its
--- highlights and its clickable segments.
local function row_from(parts, row)
  local line, hl, segs = "", {}, {}
  for _, p in ipairs(parts) do
    local s, c1 = #line, vim.fn.strdisplaywidth(line) + 1
    line = line .. p[1]
    if p[2] then table.insert(hl, { row, p[2], s, #line }) end
    if p[3] then
      table.insert(segs, { row = row, s = s, e = #line, c1 = c1, c2 = vim.fn.strdisplaywidth(line),
        action = p[3], inert = p[4] })
    end
  end
  return line, hl, segs
end

local function build(width, info)
  local a = info.actions
  -- Row 1: the branch, a tag when it is not the home branch, ▾ and maybe ✕.
  local tag = info.preview and " (preview)" or (info.worktree and " (worktree)" or "")
  local tail = info.away and " ✕ " or ""
  -- Leave at least one column of padding before ▾.
  local name_w = math.max(4, width - 3 - vim.fn.strdisplaywidth(tag) - 3 - vim.fn.strdisplaywidth(tail))
  local name = util.trunc(info.branch or "…", name_w)
  local pad = math.max(1, width - 3 - vim.fn.strdisplaywidth(name .. tag) - 2 - vim.fn.strdisplaywidth(tail))
  local parts1 = {
    { " ⎇ " .. name, "DiffNvimModeBranch", a.pick_branch },
    { tag, "DiffNvimModeTag", a.pick_branch },
    { string.rep(" ", pad) .. "▾ ", "DiffNvimModeTag", a.pick_branch },
  }
  if info.away then table.insert(parts1, { tail, "DiffNvimModeClose", a.go_home }) end
  local l1, hl1, seg1 = row_from(parts1, 0)

  -- Row 2: the file panel modes. The active one does nothing when clicked
  -- (an inert segment, so <CR> on it does not fall through to the other).
  local function tab(label, active, action)
    return { " " .. label .. " ", active and "DiffNvimModeTabActive" or "DiffNvimModeTab",
      active and function() end or action, active }
  end
  -- " Changes " and " Branch changes " with their gaps take 28 columns.
  local branch_label = width >= 28 and "Branch changes" or "Branch"
  local l2, hl2, seg2 = row_from({
    { " " },
    tab("Changes", not info.branch_mode, a.show_changes),
    { "  " },
    tab(branch_label, info.branch_mode, a.show_branch),
  }, 1)

  return { l1, l2 }, vim.list_extend(hl1, hl2), vim.list_extend(seg1, seg2)
end

local function apply_hover()
  if not (S.buf and vim.api.nvim_buf_is_valid(S.buf)) then return end
  vim.api.nvim_buf_clear_namespace(S.buf, NS_HOVER, 0, -1)
  local seg = S.hover
  if not seg or seg.inert then return end
  pcall(vim.api.nvim_buf_set_extmark, S.buf, NS_HOVER, seg.row, seg.s, {
    end_col = seg.e, hl_group = "DiffNvimHover", priority = 300,
  })
end

--- Draw the bar.
--- @param info table|nil  { branch, preview, worktree, away, branch_mode,
---   actions = { pick_branch, go_home, show_changes, show_branch } }; nil
---   redraws what was last given (after a resize).
--- The clickable segment at row `line`, display column `col` (both 1-based).
local function segment_at(line, col)
  for _, seg in ipairs(S.segments) do
    if seg.row == line - 1 and col >= seg.c1 and col <= seg.c2 then return seg end
  end
end

--- Mark the item under the cursor while the bar has focus, which is how a
--- keyboard user sees what <CR> will do.
local function apply_cursor()
  if not valid() then return end
  vim.api.nvim_buf_clear_namespace(S.buf, NS_CURSOR, 0, -1)
  if vim.api.nvim_get_current_win() ~= S.win then return end
  local cur = vim.api.nvim_win_get_cursor(S.win)
  local line = vim.api.nvim_buf_get_lines(S.buf, cur[1] - 1, cur[1], false)[1] or ""
  local seg = segment_at(cur[1], vim.fn.strdisplaywidth(line:sub(1, cur[2])) + 1)
  if seg then
    pcall(vim.api.nvim_buf_set_extmark, S.buf, NS_CURSOR, seg.row, seg.s, {
      end_col = seg.e, hl_group = "DiffNvimModeCursor", priority = 250,
    })
  end
end

function M.render(info)
  S.info = info or S.info
  if not (valid() and S.info) then return end
  local lines, hl, segs = build(vim.api.nvim_win_get_width(S.win), S.info)
  S.segments = segs
  -- The pointer may still be over an item that was just redrawn.
  S.hover = S.pointer and segment_at(S.pointer.line, S.pointer.col) or nil
  vim.bo[S.buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(S.buf, NS, 0, -1)
  vim.api.nvim_buf_set_lines(S.buf, 0, -1, false, lines)
  vim.bo[S.buf].modifiable = false
  for _, h in ipairs(hl) do
    pcall(vim.api.nvim_buf_add_highlight, S.buf, NS, h[2], h[1], h[3], h[4])
  end
  -- Never scrolled: both rows always in view.
  vim.api.nvim_win_call(S.win, function() vim.fn.winrestview({ topline = 1, leftcol = 0 }) end)
  apply_hover()
  apply_cursor()
end

-- ---------------------------------------------------------------------------
-- Mouse and keyboard
-- ---------------------------------------------------------------------------

--- The mouse pointer is at row `line`, column `col` of the bar (nil: elsewhere).
function M.hover(line, col)
  S.pointer = line and col and { line = line, col = col } or nil
  local seg = S.pointer and segment_at(line, col) or nil
  if seg == S.hover then return end
  S.hover = seg
  apply_hover()
end

--- A click at row `line`, column `col`. Returns whether it acted (false on
--- padding or the active mode).
function M.click(line, col)
  local seg = segment_at(line, col)
  if not seg or seg.inert then return false end
  seg.action()
  return true
end

local function activate_cursor()
  if not valid() then return end
  local cur = vim.api.nvim_win_get_cursor(S.win)
  local col = vim.fn.strdisplaywidth(vim.api.nvim_get_current_line():sub(1, cur[2])) + 1
  local here = segment_at(cur[1], col)
  if here then return here.action() end
  -- Between items: the nearest one on the row.
  local best, best_d
  for _, seg in ipairs(S.segments) do
    if seg.row == cur[1] - 1 then
      local d = col < seg.c1 and seg.c1 - col or col - seg.c2
      if not best_d or d < best_d then best, best_d = seg, d end
    end
  end
  if best then best.action() end
end

function M.setup(buf, win)
  S.buf, S.win, S.hover = buf, win, nil
  local km = require("diff.config").get().keymaps or {}
  local function map(key, fn, desc)
    if key and key ~= "" then
      vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, silent = true, desc = desc .. " (diff)" })
    end
  end
  map(km.open_diff, activate_cursor, "Activate mode bar item")
  map("q", function() require("diff.sidebar").close() end, "Close")
  -- The bar never scrolls (its two rows are the whole buffer).
  for _, key in ipairs({ "<C-e>", "<C-y>", "<C-d>", "<C-u>", "<C-f>", "<C-b>", "zt", "zb", "zz",
    "<ScrollWheelUp>", "<ScrollWheelDown>", "<ScrollWheelLeft>", "<ScrollWheelRight>" }) do
    vim.keymap.set("n", key, "<Nop>", { buffer = buf, nowait = true, silent = true })
  end
  local aug = vim.api.nvim_create_augroup("DiffNvimModeBarCursor", { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "WinEnter", "WinLeave" }, {
    group = aug, buffer = buf, callback = function() vim.schedule(apply_cursor) end,
  })
  M.render()
end

function M.win()
  return valid() and S.win or nil
end

function M.on_resize()
  if valid() then M.render() end
end

return M
