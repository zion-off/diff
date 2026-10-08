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
