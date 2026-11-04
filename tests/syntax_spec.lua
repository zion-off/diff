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

  { "the enclosing declaration follows an edit to the source", function()
    local src = syntax.source("x.lua", LUA)
    src:parse()
    H.wait(function() return src.ready end, "parse")
    H.eq(src:enclosing_decl(7), "local function greet(name)")
    H.eq(src:enclosing_decl(7), "local function greet(name)", "asked again")
    local edited = vim.deepcopy(LUA)
    edited[5] = "local function welcome(name, place)"
    src:update(edited)
    H.wait(function() return src:enclosing_decl(7) == "local function welcome(name, place)" end, "renamed after the reparse")
    src:destroy()
  end },

  { "content-dependent filetypes are detected from the source", function()
    local src = syntax.source("scripts/run", { "#!/usr/bin/env python3", "print(1)" })
    H.eq(src.ft, "python")
    src:destroy()
  end },

  { "regex syntax falls back to the first source with a filetype", function()
    local empty = syntax.source("script", {}, "")
    local conf = syntax.source("script", { "# a comment", "key = value" }, "conf")
    H.ok(not conf:has_parser(), "conf has no tree-sitter parser")
    local pane = vim.api.nvim_create_buf(false, true)
    syntax.bind(pane, { empty, conf }, function(row) return row, conf end)
    H.eq(vim.bo[pane].syntax, "conf")
    syntax.unbind(pane)
    empty:destroy()
    conf:destroy()
  end },

  { "panes are drawn through the decoration provider", function()
    local chunk = syntax.CAPTURE_CHUNK
    local lines = {}
    for i = 1, 3 * chunk do lines[i] = LUA[(i - 1) % #LUA + 1] end
    local src = syntax.source("x.lua", lines)
    src:parse()
    H.wait(function() return src.ready end, "parse")
    local pane = vim.api.nvim_create_buf(false, true)
    -- The pane shows two source rows of the middle chunk behind a separator row.
    local a, b = chunk + 5, chunk + 6
    vim.api.nvim_buf_set_lines(pane, 0, -1, false, { "", lines[a + 1], lines[b + 1] })
    syntax.bind(pane, { src }, function(row) return ({ [1] = a, [2] = b })[row] end)
    vim.api.nvim_win_set_buf(0, pane)
    vim.cmd("redraw")
    H.ok(src.cache[a] and src.cache[b], "visible rows should have been queried")
    H.eq(src.cache[0], nil, "rows of chunks not on screen must not be queried")
    H.eq(src.cache[2 * chunk], nil, "rows of chunks not on screen must not be queried")
    syntax.unbind(pane)
    src:destroy()
  end },

  { "captures queried a chunk at a time are those a query of each row finds", function()
    local SKIP = { spell = true, nospell = true, conceal = true }
    local prio_default = (vim.hl or vim.highlight).priorities.treesitter
    local function row_by_row(src, row)
      local out, text = {}, src.lines[row + 1] or ""
      for _, t in ipairs(src.trees) do
        local tsr, _, ter = t.root:range()
        if row >= tsr and row <= ter then
          for id, node, metadata in t.query:iter_captures(t.root, src.buf, row, row + 1) do
            local name = t.query.captures[id]
            if name:sub(1, 1) ~= "_" and not SKIP[name] then
              local sr, sc, er, ec = node:range()
              local ends_before = er < row or (er == row and ec == 0 and sr < row)
              if sr <= row and not ends_before then
                local scol = sr < row and 0 or sc
                local ecol = er > row and #text or ec
                if ecol > scol then
                  local prio = tonumber(metadata.priority or (metadata[id] and metadata[id].priority))
                  table.insert(out, { scol, ecol, "@" .. name .. "." .. t.lang, prio or prio_default })
                end
              end
            end
          end
        end
      end
      return out
    end
    -- Overlapping captures of equal priority may come in another order.
    local function sorted(caps)
      local out = vim.deepcopy(caps)
      table.sort(out, function(x, y)
        for k = 1, 4 do
          if x[k] ~= y[k] then return tostring(x[k]) < tostring(y[k]) end
        end
        return false
      end)
      return out
    end
    local function check(src, label)
      for row = 0, #src.lines - 1 do
        H.eq(sorted(src:captures(row)), sorted(row_by_row(src, row)), string.format("%s row %d", label, row))
      end
    end
    -- The plugin's own sources: block comments, long strings and vim.cmd
    -- strings (an injected language) spanning chunk boundaries.
    local files = vim.api.nvim_get_runtime_file("lua/diff/*.lua", true)
    H.ok(#files > 10, "plugin sources found")
    for _, path in ipairs(files) do
      local src = syntax.source(path, vim.fn.readfile(path))
      src:parse()
      H.wait(function() return src.ready end, "parse " .. path)
      check(src, path)
      local edited = vim.deepcopy(src.lines)
      table.insert(edited, math.floor(#edited / 2), "--[[ opened")
      table.insert(edited, math.floor(#edited / 2) + 40, "]]")
      src.ready = false
      src:update(edited)
      H.wait(function() return src.ready end, "reparse " .. path)
      check(src, path .. " (edited)")
      src:destroy()
    end
  end },

  { "a local definition follows scopes: the innermost visible declaration wins", function()
    local src = syntax.source("x.lua", {
      "local name = 1",             -- 1
      "local function f()",         -- 2
      "  local name = 2",           -- 3
      "  return name",              -- 4
      "end",                        -- 5
      "local function g() return name end", -- 6
      "return f, g",                -- 7
    })
    src:parse()
    H.wait(function() return src.ready end, "parse")
    H.eq({ src:local_definition(3, 9) }, { 2, 8 }, "the shadowing local inside f")
    H.eq({ src:local_definition(5, 26) }, { 0, 6 }, "the file's own outside f")
    H.eq({ src:local_definition(6, 7) }, { 1, 15 }, "a function is visible after its body")
    src:destroy()
  end },

  { "without scopes, a local definition is searched for as Vim's gd does", function()
    local src = syntax.source("notes.txt", { "alpha = 1", "", "beta = alpha + 1" })
    H.eq(src:has_parser(), false)
    local search = vim.fn.getreg("/")
    H.eq({ src:local_definition(2, 7) }, { 0, 0 })
    H.eq(vim.fn.getreg("/"), search, "the search pattern is left alone")
    H.eq({ src:local_definition(2, 0) }, {}, "a name used first right here has no declaration to find")
    src:destroy()
  end },
}
