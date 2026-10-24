--- diff.nvim — shared window chrome.
---
--- Every window the plugin owns is a composed surface, not a stock buffer, so
--- none of Neovim's editor furniture belongs in it: no end-of-buffer tildes
--- below a panel's last row, and no status line reciting an internal
--- `diff://` buffer name and a cursor position the reader cannot use.
---
--- Panels also carry a buffer-local tag rather than relying on their name, so
--- the rest of the plugin can recognise its own windows while the names stay
--- free to be whatever reads best in the tab line.
local M = {}

-- Buffer-local flag naming the surface a plugin buffer belongs to.
M.VAR = "diff_nvim_panel"

--- 'fillchars' for `win` with `extra` merged over the value already in
--- effect, so the user's own separator glyphs survive. Window-local
--- 'fillchars' replaces the global value outright, so it has to be rebuilt
--- rather than appended to.
function M.fillchars(win, extra)
  local merged = {}
  local ok, current = pcall(vim.api.nvim_get_option_value, "fillchars", { win = win })
  for _, part in ipairs(vim.split(ok and current or "", ",", { trimempty = true })) do
    local key, val = part:match("^([^:]+):(.*)$")
    if key then merged[key] = val end
  end
  for key, val in pairs(extra or {}) do merged[key] = val end
  local out = {}
  for key, val in pairs(merged) do table.insert(out, key .. ":" .. val) end
  table.sort(out)
  return table.concat(out, ",")
end

local function esc(s) return (tostring(s or ""):gsub("%%", "%%%%")) end

--- The status line of a plugin window: no text, only its highlight, so
--- 'fillchars' draws it as a rule — a divider under the window rather than
--- a second heading. It cannot be the empty string: a window-local
--- 'statusline' of "" means "fall back to the global one", which is the
--- default ruler.
M.RULE = "%#DiffNvimRule#"

--- A panel heading for 'winbar': the title in capitals on a raised band,
--- with an optional dimmer segment pushed to the far end. Percent signs in
--- the caller's text are escaped so a branch or path containing one cannot
--- be read as a status-line item. Empty when there is nothing to say.
function M.winbar(label, right)
  if (label == nil or label == "") and (right == nil or right == "") then return "" end
  local line = "%#DiffNvimPanelTitle# " .. esc((label or ""):upper()) .. "%="
  if right and right ~= "" then
    line = line .. "%#DiffNvimPanelTitleDim#" .. esc(right) .. " "
  end
  return line
end

--- Dress a plugin window: hide the end-of-buffer tildes, head it with
--- `opts.label` / `opts.right` when given, and draw its status line as a
--- rule. `opts.fillchars` adds further entries.
---
--- Headings go in 'winbar', never the status line. A status line is a
--- footer: a title there sits under the window it names, directly above the
--- next one, and reads as that one's heading. And under 'laststatus' 3
--- there are no per-window status lines at all — one global bar, which is
--- the reader's own — so a title there is never seen.
---
--- Under the global bar the window's status line is left unset and the
--- global fill characters are kept: that bar is filled with the focused
--- window's fill characters, and a rule set here would draw dashes through
--- the gaps of the reader's status line.
--- @param win integer
--- @param opts table|nil { label?, right?, fillchars? }
function M.dress(win, opts)
  opts = opts or {}
  local global_bar = vim.o.laststatus == 3
  local fc = { eob = " " }
  if global_bar then
    local global = vim.go.fillchars
    fc.stl = global:match("stl:([^,]+)") or " "
    fc.stlnc = global:match("stlnc:([^,]+)") or " "
  else
    fc.stl, fc.stlnc = "─", "─"
  end
  fc = vim.tbl_extend("force", fc, opts.fillchars or {})
  pcall(vim.api.nvim_set_option_value, "fillchars", M.fillchars(win, fc), { win = win })
  pcall(vim.api.nvim_set_option_value, "winbar", M.winbar(opts.label, opts.right), { win = win })
  pcall(vim.api.nvim_set_option_value, "statusline", global_bar and "" or M.RULE, { win = win })
end

--- Tag `buf` as the plugin's own, so windows can be recognised without
--- matching buffer names.
function M.tag(buf, kind)
  pcall(vim.api.nvim_buf_set_var, buf, M.VAR, kind)
end

--- The surface `buf` belongs to ("file-panel", "diff-pane", …), or nil when
--- it is not one of the plugin's.
function M.kind(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return nil end
  local ok, kind = pcall(vim.api.nvim_buf_get_var, buf, M.VAR)
  return ok and kind or nil
end

--- Name `buf` so the tab line can show it verbatim. Neovim shortens a buffer
--- name that looks like a path ("diff://worktree/new/src/app.lua" becomes
--- "d//w/n/s/app.lua"), so plugin names carry no slashes; brackets confuse it
--- too.
--- Names must be unique, and the name is resolved against the working
--- directory, so a plugin name can collide with another plugin buffer or with
--- a file the user has open. A collision is disambiguated rather than
--- ignored: a surface left unnamed shows as "[Scratch]" for the rest of the
--- session.
--- Renaming leaves Neovim holding an unlisted buffer under the old name, as
--- `:file` does; those are wiped so repeated renames cannot pile up.
function M.name(buf, name)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  name = name:gsub("[/\\%[%]]", " "):gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
  if name == "" then return end
  local old = vim.api.nvim_buf_get_name(buf)
  if old == name or vim.fn.fnamemodify(old, ":t") == name then return end

  local named = pcall(vim.api.nvim_buf_set_name, buf, name)
  for n = 2, 9 do
    if named then break end
    named = pcall(vim.api.nvim_buf_set_name, buf, name .. " (" .. n .. ")")
  end
  if not named or old == "" then return end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if b ~= buf and vim.api.nvim_buf_get_name(b) == old and #vim.fn.win_findbuf(b) == 0 then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
end

return M
