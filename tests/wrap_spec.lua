local H = require("helpers")

vim.o.columns, vim.o.lines = 160, 50

-- big.lua: 60 short lines. The edit lengthens line 10 far past a pane's width
-- (so only the new side wraps) and adds a long new-only line after 20 (so the
-- old side shows a filler that must grow with it).
local LONG = "local s = '" .. string.rep("lorem ipsum dolor ", 20) .. "'"
local base = H.lines(60)
local repo = H.repo({ ["big.lua"] = H.text(base) })
local edited = H.lines(60, { [10] = LONG })
table.insert(edited, 21, LONG)
H.write(repo, "big.lua", H.text(edited))

vim.cmd("cd " .. repo)
require("diff").setup({ log_level = os.getenv("DIFF_LOG") or "warn" })

local dv      = require("diff.diff_view")
local sidebar = require("diff.sidebar")
local fp      = require("diff.file_panel")
local S       = dv._state
local NS_WRAP = vim.api.nvim_get_namespaces().diff_nvim_wrap

local function pane(side) return S().panes[side] end

--- Screen line (0-based) where buffer row r's text starts. Padding below a
--- row counts as fill above the next one, so the range ends at r, column 0.
local function text_start(win, r)
  return vim.api.nvim_win_text_height(win, { start_row = 0, end_row = r, end_vcol = 0 }).all
end

local function assert_aligned()
  for r = 0, #S().layout.items - 1 do
    local o, n = text_start(pane("old"), r), text_start(pane("new"), r)
    if o ~= n then error(string.format("row %d starts at screen line %d (old) vs %d (new)", r, o, n), 2) end
  end
end

--- Screen lines of `win`'s top line scrolled out of view ('smoothscroll').
local function skipped(win)
  local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  if view.skipcol == 0 then return 0 end
  return vim.api.nvim_win_text_height(win, { start_row = view.topline - 1, end_row = view.topline - 1, end_vcol = view.skipcol }).all
end

--- Both panes show the same rows on the same screen lines.
local function assert_same_screen()
  vim.cmd("redraw")
  local old, new = pane("old"), pane("new")
  local top = vim.fn.getwininfo(new)[1].topline
  H.eq(vim.fn.getwininfo(old)[1].topline, top, "topline")
  H.eq(skipped(old), skipped(new), "screen lines of topline " .. top .. " scrolled past")
  for r = top + 1, math.min(top + 5, #S().layout.items) do
    H.eq(vim.fn.screenpos(old, r, 1).row, vim.fn.screenpos(new, r, 1).row, "screen row of line " .. r)
  end
end

--- Scroll the focused pane with `keys` (or run `fn`), then let the panes sync.
--- WinScrolled fires from the main loop, which a test never returns to.
local function scroll(keys)
  if type(keys) == "function" then keys() else vim.cmd("normal! " .. vim.keycode(keys)) end
  vim.api.nvim_exec_autocmds("WinScrolled", {})
end

local function pads(side)
  return vim.api.nvim_buf_get_extmarks(S().bufs[side], NS_WRAP, 0, -1, { details = true })
end

return {
  { "split panes wrap and every row starts on the same screen line", function()
    require("diff").open()
    H.wait(function() return sidebar.is_open() and pcall(vim.api.nvim_buf_get_lines, sidebar._file_buf, 0, -1, false) end)
    H.wait(function()
      for i, l in ipairs(vim.api.nvim_buf_get_lines(sidebar._file_buf, 0, -1, false)) do
        if l:match("big%.lua") then fp.activate_line(i) return true end
      end
    end, "big.lua in panel")
    H.wait(function() return S().layout and S().source.path == "big.lua" end, "diff")
    H.ok(vim.wo[pane("old")].wrap and vim.wo[pane("new")].wrap, "both panes should wrap")
    H.ok(#pads("old") == 2 and #pads("new") == 0, "old side pads both long rows: " .. vim.inspect(pads("old")))
    assert_aligned()
  end },

  { "a filler pads with its pattern; a text row pads under its line background", function()
    for _, mark in ipairs(pads("old")) do
      local row = S().model.rows[S().layout.items[mark[2] + 1].row]
      local chunk = mark[4].virt_text[1]
      H.eq(mark[4].virt_text_pos, "inline")
      H.eq(chunk[2], (not row.old) and "DiffNvimFillerChar" or nil)
    end
  end },

  { "scrolling keeps the panes aligned through padded rows", function()
    local old, new = pane("old"), pane("new")
    vim.api.nvim_set_current_win(new)
    for _ = 1, 30 do
      scroll("<C-e>")
      local top = vim.fn.getwininfo(new)[1].topline
      if top >= #S().layout.items then break end
      assert_same_screen()
    end
    H.eq(vim.wo[old].scrollbind, false, "'scrollbind' would fight the sync")
    scroll("gg")
  end },

  { "scrolling the unfocused pane (the mouse wheel) moves the focused one", function()
    local old, new = pane("old"), pane("new")
    vim.api.nvim_set_current_win(new)
    scroll(function() vim.api.nvim_win_call(old, function() vim.fn.winrestview({ topline = 15, lnum = 16 }) end) end)
    H.eq(vim.fn.getwininfo(old)[1].topline, 15, "the scrolled pane leads")
    assert_same_screen()
    -- Left on line 1, the focused pane's cursor would make Neovim scroll it back.
    H.eq(vim.api.nvim_win_get_cursor(new)[1], 16, "focused cursor follows into view")
    scroll("gg")
  end },

  { "'smoothscroll' part-way offsets match, even at unequal pane widths", function()
    local old, new = pane("old"), pane("new")
    vim.api.nvim_win_set_width(old, vim.api.nvim_win_get_width(new) + 3)
    vim.cmd("doautocmd WinResized")
    H.ok(S().wrap_widths.old ~= S().wrap_widths.new, "widths should differ")
    vim.wo[old].smoothscroll, vim.wo[new].smoothscroll = true, true
    vim.api.nvim_set_current_win(new)
    local partway = 0
    for _ = 1, 40 do
      scroll("<C-e>")
      if vim.fn.winsaveview().skipcol > 0 then partway = partway + 1 end
      assert_same_screen()
    end
    H.ok(partway > 0, "should have stopped part-way through a wrapped row")
    for _, keys in ipairs({ "<C-u>", "<C-d>", "<C-d>", "<C-u>", "<C-u>" }) do
      scroll(keys)
      assert_same_screen()
    end
    vim.wo[old].smoothscroll, vim.wo[new].smoothscroll = false, false
    scroll("gg")
  end },

  { "a width change re-aligns the rows", function()
    local long = S().layout.index_of[10] - 1 -- model row 10 is the lengthened line
    local function long_height() return vim.api.nvim_win_text_height(pane("new"), { start_row = long, end_row = long }).all end
    local before = long_height()
    vim.api.nvim_win_set_width(pane("old"), vim.api.nvim_win_get_width(pane("old")) + 20)
    vim.cmd("doautocmd WinResized")
    H.wait(function() return S().wrap_widths.new == vim.api.nvim_win_get_width(pane("new")) end, "re-align")
    H.ok(long_height() > before,
      "narrower new pane should wrap onto more lines")
    assert_aligned()
  end },

  { "panes too narrow to wrap scroll horizontally, and wrap again when widened", function()
    local wide = vim.api.nvim_win_get_width(pane("new"))
    vim.api.nvim_win_set_width(pane("new"), 22)
    vim.cmd("doautocmd WinResized")
    H.ok(not vim.wo[pane("old")].wrap and not vim.wo[pane("new")].wrap, "narrow panes should not wrap")
    H.eq(#pads("old") + #pads("new"), 0)
    vim.api.nvim_win_set_width(pane("new"), wide)
    vim.cmd("doautocmd WinResized")
    H.ok(vim.wo[pane("old")].wrap and vim.wo[pane("new")].wrap, "widened panes should wrap again")
    assert_aligned()
  end },

  { "wrap = false leaves lines unwrapped and unpadded", function()
    require("diff.config").setup({ wrap = false })
    dv.open(S().root, S().source, S().navigator)
    H.wait(function() return S().layout and not vim.wo[pane("new")].wrap end, "reopen")
    H.eq(#pads("old") + #pads("new"), 0)
  end },
}
