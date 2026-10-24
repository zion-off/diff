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

--- A status line for a plugin window: a single dimmed label, no file name,
--- no ruler. `right` is an optional second segment pushed to the far end.
--- Percent signs in the caller's text are escaped so a branch or path
--- containing one cannot be read as a status-line item.
--- With no label the line carries no text, only its highlight, so 'fillchars'
--- draws it as a rule — a divider between two stacked panels rather than a
--- heading. It cannot be the empty string: a window-local 'statusline' of ""
--- means "fall back to the global one", which is the default ruler.
function M.statusline(label, right)
  local function esc(s) return (tostring(s or ""):gsub("%%", "%%%%")) end
  if (label == nil or label == "") and (right == nil or right == "") then
    return "%#DiffNvimRule#"
  end
  local line = "%#DiffNvimStatusLine# " .. esc(label)
  if right and right ~= "" then
    line = line .. "%=%#DiffNvimStatusLineDim#" .. esc(right) .. " "
  end
  return line
end

--- Dress a plugin window: hide the end-of-buffer tildes and give it a quiet
--- status line. `opts.label` / `opts.right` build that line; `opts.fillchars`
--- adds further entries (the diff header's rule, say).
--- A window with no label gets its status line filled with a rule, so the gap
--- between two stacked panels reads as a divider rather than a blank band.
---
--- Under 'laststatus' 3 there are no per-window status lines — there is one
--- global bar, and a window-local 'statusline' only decides what that single
--- bar says while the window has focus. Writing a panel label there would
--- replace the reader's own status line with the word "Changes" every time
--- they stepped into the sidebar. So in that mode the label is left unset and
--- their bar keeps saying what they configured it to say; the panels are
--- already separated by the window dividers that mode draws.
--- @param win integer
--- @param opts table|nil { label?, right?, fillchars? }
function M.dress(win, opts)
  opts = opts or {}
  local global_bar = vim.o.laststatus == 3
  local unlabelled = (opts.label == nil or opts.label == "")
    and (opts.right == nil or opts.right == "")
  local fc = { eob = " " }
  if global_bar then
    -- The one bar is the reader's, and it is filled with the fill characters
    -- of whichever window has focus: a rule set here would draw dashes
    -- through the gaps of their status line.
    local global = vim.go.fillchars
    fc.stl = global:match("stl:([^,]+)") or " "
    fc.stlnc = global:match("stlnc:([^,]+)") or " "
  else
    -- Authoritative, not merged: these windows are reused across states, so
    -- a rule left behind by an unlabelled state would otherwise bleed through
    -- a labelled one and pad its heading out with dashes.
    fc.stl, fc.stlnc = unlabelled and "─" or " ", unlabelled and "─" or " "
  end
  fc = vim.tbl_extend("force", fc, opts.fillchars or {})
  pcall(vim.api.nvim_set_option_value, "fillchars", M.fillchars(win, fc), { win = win })
  if global_bar then
    -- Clear any label left from a session that began under a per-window bar,
    -- so switching 'laststatus' at runtime cannot strand one in the global one.
    pcall(vim.api.nvim_set_option_value, "statusline", "", { win = win })
    return
  end
  pcall(vim.api.nvim_set_option_value, "statusline",
    M.statusline(opts.label, opts.right), { win = win })
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
