--- diff.nvim — mode bar: a two-row strip above the sidebar panels that keeps
--- the interface's modes in view and in reach of the mouse, after the way a
--- macOS sidebar heads itself.
---
---    ⎇ feature/x ⌃⌄                  ↑2 ↓1   the branch shown: a pop-up
---                                            button across the whole row
---         Changes          Since main        the file panel's view: a
---                                            segmented control
---
--- The branch row says how far the branch is ahead of and behind its
--- upstream. Previewing another branch (or showing another worktree) is a
--- mode of its own: the row is tinted, names the mode, and ends in a Done
--- button that returns to the home branch. The control's halves split the
--- width evenly, so each is a large target, and the selected one is raised.
--- Both rows run edge to edge, their text inset a column inside them.
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
  segments = {}, -- { row, s, e (byte cols, end exclusive), c1, c2 (display cols, inclusive), action, inert, hover_hl }
  hover = nil,   -- segment under the mouse pointer
  pointer = nil, -- { line, col } of the pointer over the bar
  info = nil,    -- what the last render() was given
}

local NS_CURSOR = vim.api.nvim_create_namespace("diff_nvim_mode_bar_cursor")

-- The bar's own colours sit below the hover tint (300) and the keyboard
-- cursor (250): drawn at the default priority, a row with a background of
-- its own would hide both.
local PRIORITY_BASE = 100

local function valid()
  return S.buf and vim.api.nvim_buf_is_valid(S.buf) and S.win and vim.api.nvim_win_is_valid(S.win)
end

-- ---------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------

--- Lay out one row from parts { text, hl, action?, inert?, hover_hl? };
--- returns the line, its highlights and its clickable segments. Adjacent
--- parts with the same action are one segment, tinted and clicked as a
--- whole (in `hover_hl`, else DiffNvimHover).
local function row_from(parts, row)
  local line, hl, segs = "", {}, {}
  for _, p in ipairs(parts) do
    local s, c1 = #line, vim.api.nvim_strwidth(line) + 1
    line = line .. p[1]
    if p[2] then table.insert(hl, { row, p[2], s, #line }) end
    if p[3] then
      local last = segs[#segs]
      if last and last.action == p[3] and last.e == s then
        last.e, last.c2 = #line, vim.api.nvim_strwidth(line)
      else
        table.insert(segs, { row = row, s = s, e = #line, c1 = c1, c2 = vim.api.nvim_strwidth(line),
          action = p[3], inert = p[4], hover_hl = p[5] })
      end
    end
  end
  return line, hl, segs
end

--- `text` centred in `cells` columns, shortened to leave a column either side.
local function centred(text, cells)
  text = util.trunc(text, math.max(1, cells - 2))
  local free = math.max(0, cells - vim.api.nvim_strwidth(text))
  local left = math.floor(free / 2)
  return string.rep(" ", left) .. text .. string.rep(" ", free - left)
end

--- "↑2 ↓1": commits ahead of and behind the upstream; "" when level or unknown.
local function sync_text(ahead, behind)
  local parts = {}
  if ahead and ahead > 0 then table.insert(parts, "↑" .. ahead) end
  if behind and behind > 0 then table.insert(parts, "↓" .. behind) end
  return table.concat(parts, " ")
end

local function build(width, info)
  local a = info.actions
  local w = vim.api.nvim_strwidth
  local away = info.away

  -- Row 1: the branch as a pop-up button across the row (⌃⌄ is how macOS
  -- marks picking one of many). Away from home the row is tinted, names the
  -- mode, and ends in Done; at home it shows the upstream counts. Its text
  -- keeps the column of margin the control below has on either side.
  local hl = away
    and { cell = "DiffNvimModeAway", name = "DiffNvimModeAwayBranch", dim = "DiffNvimModeAwayTag",
      hover = "DiffNvimModeAwayHover" }
    or { cell = "DiffNvimModeCell", name = "DiffNvimModeBranch", dim = "DiffNvimModeTag",
      hover = "DiffNvimModeCellHover" }
  local done = away and " Done " or ""
  local mode = info.preview and "  Preview" or (info.worktree and "  Worktree" or "")
  local sync = away and "" or sync_text(info.ahead, info.behind)
  local right = sync ~= "" and (sync .. " ") or ""
  local cell_w = width - w(done) - 1
  local function room() return cell_w - w("⎇  ⌃⌄" .. mode .. right) - 1 end
  -- A narrow sidebar gives up the counts, then the mode's name, before the
  -- branch name shrinks below a few characters.
  if room() < 4 then right = "" end
  if room() < 4 then mode = "" end
  local name = util.trunc(info.branch or "…", math.max(4, room()))
  local left = "⎇ " .. name .. " ⌃⌄" .. mode
  local pick = a.pick_branch
  local parts1 = {
    { " ", hl.cell, pick, nil, hl.hover },
    { "⎇ " .. name, hl.name, pick },
    { " ⌃⌄" .. mode, hl.dim, pick },
    { string.rep(" ", math.max(1, cell_w - w(left) - w(right))), hl.cell, pick },
    { right, hl.dim, pick },
  }
  if away then table.insert(parts1, { done, "DiffNvimModeDone", a.go_home, nil, hl.hover }) end
  local l1, hl1, seg1 = row_from(parts1, 0)

  -- Row 2: the file panel's view, as a segmented control running edge to
  -- edge like the row above: a track split into equal halves, the selected
  -- one raised. The selected half does nothing when clicked (inert, so <CR>
  -- on it does not fall through to the other), so only the other one reacts
  -- to the pointer.
  local left_w = math.floor(width / 2)
  local right_w = width - left_w
  local since = info.base and ("Since " .. info.base) or "Branch"
  if w(since) > right_w - 2 then since = "Branch" end
  local noop = function() end
  local function half(label, cells, selected, action)
    return {
      centred(label, cells), selected and "DiffNvimModeSegment" or "DiffNvimModeTrack",
      selected and noop or action, selected or nil, not selected and "DiffNvimModeTrackHover" or nil,
    }
  end
  local l2, hl2, seg2 = row_from({
    half("Changes", left_w, not info.branch_mode, a.show_changes),
    half(since, right_w, info.branch_mode, a.show_branch),
  }, 1)

  return { l1, l2 }, vim.list_extend(hl1, hl2), vim.list_extend(seg1, seg2)
end

local function apply_hover()
  if not (S.buf and vim.api.nvim_buf_is_valid(S.buf)) then return end
  vim.api.nvim_buf_clear_namespace(S.buf, NS_HOVER, 0, -1)
  local seg = S.hover
  if not seg or seg.inert then return end
  pcall(vim.api.nvim_buf_set_extmark, S.buf, NS_HOVER, seg.row, seg.s, {
    end_col = seg.e, hl_group = seg.hover_hl or "DiffNvimHover", priority = 300,
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
  local seg = segment_at(cur[1], vim.api.nvim_strwidth(line:sub(1, cur[2])) + 1)
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
    pcall(vim.api.nvim_buf_set_extmark, S.buf, NS, h[1], h[3], {
      end_col = h[4], hl_group = h[2], priority = PRIORITY_BASE,
    })
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

--- A key naming the item at row `line`, column `col` (both 1-based), or nil
--- between items. It survives a redraw that keeps the item in place, so a
--- press and its release can be matched to the same item.
function M.item_at(line, col)
  local seg = segment_at(line, col)
  return seg and (seg.row .. ":" .. seg.c1) or nil
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
  local col = vim.api.nvim_strwidth(vim.api.nvim_get_current_line():sub(1, cur[2])) + 1
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
