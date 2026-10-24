--- diff.nvim — branch picker.
---
--- A zero-dependency floating-window list of branches with incremental
--- substring filtering. Selecting a branch puts the interface into
--- "preview mode" (commits sourced from that branch, working-tree file panel
--- emptied). Selecting the current branch returns to live mode. A branch that
--- is checked out in another worktree is passed on with that worktree's path,
--- so its working-tree changes can be shown instead.
local M = {}

local git = require("diff.git")

-- Track the open picker so repeated invocations never stack windows.
M._win = nil
M._buf = nil

-- ---------------------------------------------------------------------------
-- State for the currently open picker instance
-- ---------------------------------------------------------------------------

local state = nil
-- state = {
--   branches   = table[],   -- full list { name, is_head, is_remote }
--   filtered   = table[],   -- currently displayed subset
--   query      = string,    -- current filter text
--   cursor     = integer,   -- 1-based index into `filtered`
--   on_select  = fun(branch|nil, worktree|nil),  -- called with chosen branch (nil = current/live)
--   current    = string|nil,-- name of the real current branch
-- }

local NS = vim.api.nvim_create_namespace("diff_nvim_branch_picker")

local chrome = require("diff.chrome")

-- Room the float leaves around the list: the prompt row plus its rule.
local CHROME_ROWS = 2
local PROMPT = "❯ "
local PLACEHOLDER = "Type to filter branches"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function is_valid(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

--- Case-insensitive substring match.
local function matches(name, query)
  if query == "" then return true end
  return name:lower():find(query:lower(), 1, true) ~= nil
end

local function apply_filter()
  local out = {}
  for _, b in ipairs(state.branches) do
    if matches(b.name, state.query) then
      table.insert(out, b)
    end
  end
  state.filtered = out
  if state.cursor > #out then state.cursor = #out end
  if state.cursor < 1 then state.cursor = 1 end
end

--- Height the float wants for the current result set, so a filter that leaves
--- two branches does not leave twenty rows of empty box below them.
local function wanted_height()
  local rows = math.max(#state.filtered, 1) + CHROME_ROWS
  return math.max(CHROME_ROWS + 1, math.min(rows, math.floor(vim.o.lines * 0.6)))
end

--- Re-centre the float at the height the list now needs.
local function resize()
  if not is_valid(M._win) then return end
  local height = wanted_height()
  local cfg = vim.api.nvim_win_get_config(M._win)
  if cfg.height == height then return end
  cfg.height = height
  cfg.row = math.max(0, math.floor((vim.o.lines - height) / 2))
  pcall(vim.api.nvim_win_set_config, M._win, cfg)
end

--- Redraw the buffer contents (prompt line + branch rows).
local function render()
  if not (M._buf and vim.api.nvim_buf_is_valid(M._buf)) then return end

  vim.api.nvim_set_option_value("modifiable", true, { buf = M._buf })
  vim.api.nvim_buf_clear_namespace(M._buf, NS, 0, -1)

  local width    = is_valid(M._win) and vim.api.nvim_win_get_width(M._win) or 50
  local lines    = {}
  local hl_queue = {}

  -- Prompt line: a glyph marking where typing goes, the query, a caret where
  -- the next character will land, and the match count at the far end. A row
  -- with nothing on it reads as a window that is not listening.
  local head  = PROMPT .. state.query
  local body  = head .. " " -- the cell the caret occupies
  local hint  = state.query == "" and ("  " .. PLACEHOLDER) or ""
  local count = ("%d/%d"):format(#state.filtered, #state.branches)
  local used  = vim.fn.strdisplaywidth(body .. hint) + vim.fn.strdisplaywidth(count) + 1
  local gap   = math.max(1, width - used)
  local prompt = body .. hint .. string.rep(" ", gap) .. count .. " "
  table.insert(lines, prompt)
  table.insert(hl_queue, { 0, "DiffNvimPickerPrompt", 0, #PROMPT })
  if hint ~= "" then
    table.insert(hl_queue, { 0, "DiffNvimPickerPlaceholder", #body, #body + #hint })
  end
  -- A caret of its own: the real cursor is parked on the selected row.
  table.insert(hl_queue, { 0, "DiffNvimPickerCaret", #head, #body })
  table.insert(hl_queue, { 0, "DiffNvimPickerCount", #prompt - #count - 1, -1 })
  table.insert(hl_queue, { 0, "DiffNvimPickerCount", #prompt - #count - 1, -1 })

  table.insert(lines, string.rep("─", width))
  table.insert(hl_queue, { 1, "DiffNvimPickerRule", 0, -1 })

  if #state.filtered == 0 then
    table.insert(lines, "  No branch matches “" .. state.query .. "”")
    table.insert(hl_queue, { 2, "DiffNvimCommitMeta", 0, -1 })
  else
    for _, b in ipairs(state.filtered) do
      local marker = "  "
      local flag   = b.is_head and "  (current)" or (b.worktree and "  (worktree)" or "")
      local line   = marker .. b.name .. flag
      table.insert(lines, line)

      local row = #lines - 1
      local hl
      if b.is_head then
        hl = "DiffNvimRefHead"
      elseif b.is_remote then
        hl = "DiffNvimRefRemote"
      else
        hl = "DiffNvimRefBranch"
      end
      table.insert(hl_queue, { row, hl, #marker, #marker + #b.name })
      if flag ~= "" then
        table.insert(hl_queue, { row, "DiffNvimCommitMeta", #marker + #b.name, -1 })
      end
      -- Show why this row survived the filter.
      if state.query ~= "" then
        local s, e = b.name:lower():find(state.query:lower(), 1, true)
        if s then
          table.insert(hl_queue, { row, "DiffNvimPickerMatch", #marker + s - 1, #marker + e })
        end
      end
    end
  end

  vim.api.nvim_buf_set_lines(M._buf, 0, -1, false, lines)
  for _, h in ipairs(hl_queue) do
    pcall(vim.api.nvim_buf_add_highlight, M._buf, NS, h[2], h[1], h[3], h[4])
  end
  vim.api.nvim_set_option_value("modifiable", false, { buf = M._buf })

  resize()

  -- Keep the cursor visually parked on the selected row.
  if is_valid(M._win) then
    local line = #state.filtered > 0 and state.cursor + CHROME_ROWS or CHROME_ROWS + 1
    pcall(vim.api.nvim_win_set_cursor, M._win, { line, 0 })
  end
end

--- Close the picker and clean up.
function M.close()
  if is_valid(M._win) then
    pcall(vim.api.nvim_win_close, M._win, true)
  end
  M._win = nil
  M._buf = nil
  state  = nil
end

local function move(dir)
  if #state.filtered == 0 then return end
  state.cursor = state.cursor + dir
  if state.cursor < 1 then state.cursor = #state.filtered end
  if state.cursor > #state.filtered then state.cursor = 1 end
  render()
end

local function accept()
  local sel = state.filtered[state.cursor]
  local cb  = state.on_select
  M.close()
  if not sel or not cb then return end
  -- Selecting the current branch means "return to live mode" (nil ref).
  if sel.is_head then
    cb(nil)
  else
    cb(sel.name, sel.worktree)
  end
end

--- Handle a printable character typed into the prompt.
local function on_char(ch)
  state.query = state.query .. ch
  apply_filter()
  render()
end

local function on_backspace()
  if #state.query == 0 then return end
  -- Drop one byte-safe character from the end.
  state.query = vim.fn.strcharpart(state.query, 0, vim.fn.strchars(state.query) - 1)
  apply_filter()
  render()
end

-- ---------------------------------------------------------------------------
-- Keymaps
-- ---------------------------------------------------------------------------

local function install_keymaps(buf)
  local opts = { buffer = buf, nowait = true, silent = true }

  -- Printable ASCII (space through tilde) feeds the filter.
  for c = 32, 126 do
    local ch = string.char(c)
    vim.keymap.set("n", ch, function() on_char(ch) end, opts)
  end

  vim.keymap.set("n", "<BS>",   on_backspace, opts)
  vim.keymap.set("n", "<C-h>",  on_backspace, opts)

  vim.keymap.set("n", "<Down>", function() move(1) end, opts)
  vim.keymap.set("n", "<C-n>",  function() move(1) end, opts)
  vim.keymap.set("n", "<Tab>",  function() move(1) end, opts)
  vim.keymap.set("n", "<Up>",   function() move(-1) end, opts)
  vim.keymap.set("n", "<C-p>",  function() move(-1) end, opts)
  vim.keymap.set("n", "<S-Tab>", function() move(-1) end, opts)

  vim.keymap.set("n", "<CR>", accept, opts)

  for _, key in ipairs({ "<Esc>", "q", "<C-c>" }) do
    vim.keymap.set("n", key, function() M.close() end, opts)
  end
end

-- ---------------------------------------------------------------------------
-- Public entry point
-- ---------------------------------------------------------------------------

--- Open the branch picker.
--- @param repo_root string
--- @param on_select fun(branch: string|nil, worktree: string|nil)
---   Called with the chosen branch name (and the worktree it is checked out
---   in, if any), or nil to return to live mode.
function M.open(repo_root, on_select)
  M.close()

  git.list_branches(repo_root, function(branches, err)
    if err then
      vim.notify("diff.nvim: " .. err, vim.log.levels.WARN)
      return
    end
    branches = branches or {}
    if #branches == 0 then
      vim.notify("diff.nvim: no branches found", vim.log.levels.INFO)
      return
    end

    local current
    for _, b in ipairs(branches) do
      if b.is_head then current = b.name break end
    end

    state = {
      branches  = branches,
      filtered  = branches,
      query     = "",
      cursor    = 1,
      on_select = on_select,
      current   = current,
    }

    -- Window geometry: centered, sized to content within sane bounds.
    local width  = 50
    for _, b in ipairs(branches) do
      width = math.max(width, #b.name + 16)
    end
    width = math.min(width, math.max(30, math.floor(vim.o.columns * 0.6)))
    local height = math.min(#branches + CHROME_ROWS, math.floor(vim.o.lines * 0.6))
    height = math.max(height, CHROME_ROWS + 1)
    local row = math.max(0, math.floor((vim.o.lines - height) / 2))
    local col = math.max(0, math.floor((vim.o.columns - width) / 2))

    local buf = vim.api.nvim_create_buf(false, true)
    chrome.tag(buf, "branch-picker")
    chrome.name(buf, "diff.nvim Branches")
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
    vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

    local win_cfg = {
      relative  = "editor",
      width     = width,
      height    = height,
      row       = row,
      col       = col,
      style     = "minimal",
      border    = "rounded",
      title     = " Preview branch ",
      title_pos = "center",
    }
    -- Footers need Neovim 0.10; without one the keys are simply undocumented
    -- rather than the window failing to open.
    local with_footer = vim.tbl_extend("force", win_cfg, {
      footer = " ↑↓ move   ⏎ select   esc cancel ", footer_pos = "center",
    })
    local ok, win = pcall(vim.api.nvim_open_win, buf, true, with_footer)
    if not ok then ok, win = pcall(vim.api.nvim_open_win, buf, true, win_cfg) end
    if not ok or not vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
      return
    end

    pcall(vim.api.nvim_set_option_value, "cursorline", true,  { win = win })
    pcall(vim.api.nvim_set_option_value, "wrap",       false, { win = win })
    pcall(vim.api.nvim_set_option_value, "winhighlight",
      "Normal:DiffNvimPickerNormal,FloatBorder:DiffNvimPickerBorder,"
      .. "FloatTitle:DiffNvimPickerTitle,FloatFooter:DiffNvimPickerFooter,"
      .. "CursorLine:DiffNvimPickerSelected", { win = win })

    M._win = win
    M._buf = buf

    install_keymaps(buf)

    -- Auto-close when focus leaves the picker.
    vim.api.nvim_create_autocmd("BufLeave", {
      buffer = buf,
      once   = true,
      callback = function()
        vim.schedule(function()
          if M._buf == buf then M.close() end
        end)
      end,
    })

    render()
  end)
end

return M
