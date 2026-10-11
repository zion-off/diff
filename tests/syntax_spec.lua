local H = require("helpers")
local syntax = require("diff.syntax")

local LUA = {
  "--[[",
  "  long block comment",
  "  local not_code = 1",
  "]]",
  "local function greet(name)",
  "  local msg = 'hi ' .. name",
  "  return msg",
  "end",
}

local function groups(src, row)
  local out = {}
  for _, c in ipairs(src:captures(row)) do out[c[3]] = true end
  return out
end

return {
  { "updates write only the changed lines, and the source matches the new content", function()
    math.randomseed(3)
    local lines = {}
    for i = 1, 300 do lines[i] = "local v" .. i .. " = " .. i end
    local src = syntax.source("x.lua", lines)
    src:parse()
    H.wait(function() return src.ready end, "parse")
    for _ = 1, 40 do
      local nxt, i = {}, 1
      while i <= #lines do
        local r = math.random()
        if r < 0.03 then i = i + math.random(1, 4)
        elseif r < 0.06 then for _ = 1, math.random(1, 3) do nxt[#nxt + 1] = "local fresh = " .. math.random(999) end
        elseif r < 0.1 then nxt[#nxt + 1] = lines[i] .. " -- edited"; i = i + 1
        else nxt[#nxt + 1] = lines[i]; i = i + 1 end
      end
      if #nxt == 0 then nxt = { "" } end
      src:update(nxt)
      H.eq(vim.api.nvim_buf_get_lines(src.buf, 0, -1, false), nxt)
      lines = nxt
    end
    -- One edited line is one small write, not a whole-buffer replace.
    local edited = vim.deepcopy(lines)
    edited[100] = edited[100] .. " -- once more"
    local changed = {}
    vim.api.nvim_buf_attach(src.buf, false, {
      on_lines = function(_, _, _, first, last_old, last_new) table.insert(changed, { first, last_old, last_new }) end,
    })
    src:update(edited)
    H.eq(changed, { { 99, 100, 100 } })
    H.eq(vim.api.nvim_buf_get_lines(src.buf, 0, -1, false), edited)
    src:destroy()
  end },

  { "lines inside a multi-line comment are highlighted as comment", function()
    local src = syntax.source("x.lua", LUA)
    H.eq(src.ft, "lua")
    src:parse()
    H.wait(function() return src.ready end, "parse")
    local g = groups(src, 2) -- "  local not_code = 1"
    H.ok(g["@comment.lua"], "expected @comment, got " .. vim.inspect(g))
    H.ok(not g["@keyword.lua"], "comment text must not be highlighted as a keyword")
    H.ok(groups(src, 5)["@keyword.lua"] or groups(src, 5)["@keyword.function.lua"]
      or next(groups(src, 5)), "code row should have captures")
    src:destroy()
  end },

  { "enclosing declaration resolves the function signature", function()
    local src = syntax.source("x.lua", LUA)
    src:parse()
    H.wait(function() return src.ready end, "parse")
    H.eq(src:enclosing_decl(7), "local function greet(name)")
    H.eq(src:enclosing_decl(2), nil)
    src:destroy()
  end },

  { "content-dependent filetypes are detected from the source", function()
    local src = syntax.source("scripts/run", { "#!/usr/bin/env python3", "print(1)" })
    H.eq(src.ft, "python")
    src:destroy()
  end },

  { "panes are drawn through the decoration provider", function()
    local src = syntax.source("x.lua", LUA)
    src:parse()
    H.wait(function() return src.ready end, "parse")
    local pane = vim.api.nvim_create_buf(false, true)
    -- The pane shows only source rows 6–7 behind a separator row.
    vim.api.nvim_buf_set_lines(pane, 0, -1, false, { "", LUA[6], LUA[7] })
    syntax.bind(pane, src, function(row) return ({ [1] = 5, [2] = 6 })[row] end)
    vim.api.nvim_win_set_buf(0, pane)
    vim.cmd("redraw")
    H.ok(src.cache[5] and src.cache[6], "visible rows should have been queried")
    H.eq(src.cache[0], nil, "rows not on screen must not be queried")
    syntax.unbind(pane)
    src:destroy()
  end },
}
