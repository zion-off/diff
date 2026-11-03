local H = require("helpers")
local engine = require("diff.diff_engine")

local function side(lines, eol)
  return { lines = lines, eol = eol ~= false }
end

local function compute(a, b)
  return engine.compute(side(a), side(b))
end

-- Every old line appears once, in order, on the left; likewise new lines on
-- the right; context rows pair equal content; blocks cover the change rows.
local function check_invariants(model)
  local a, b = model.old.lines, model.new.lines
  local next_old, next_new = 1, 1
  for i, row in ipairs(model.rows) do
    if row.old then
      H.eq(row.old, next_old, "old lines out of order at row " .. i)
      next_old = next_old + 1
    end
    if row.new then
      H.eq(row.new, next_new, "new lines out of order at row " .. i)
      next_new = next_new + 1
    end
    H.ok(row.old or row.new, "empty row " .. i)
    if not row.change then
      H.eq(a[row.old], b[row.new], "context row " .. i .. " pairs unequal lines")
    else
      local blk = model.blocks[row.block]
      H.ok(blk and i >= blk.first and i <= blk.last, "change row " .. i .. " outside its block")
    end
  end
  H.eq(next_old - 1, #a, "not every old line was emitted")
  H.eq(next_new - 1, #b, "not every new line was emitted")
end

--- A unified layout written out as `git diff` writes its hunks: headers
--- without the function name, then " ", "-" or "+" and the line.
local function unified_text(m, ctx)
  local out = {}
  for _, it in ipairs(engine.unified_layout(m, ctx, {}).items) do
    if it.hunk then
      table.insert(out, engine.hunk_header(it.hunk))
    elseif it.row then
      local row = m.rows[it.row]
      local mark = it.side == "old" and "-" or it.side == "new" and "+" or " "
      local line = it.side == "old" and m.old.lines[row.old] or m.new.lines[row.new]
      table.insert(out, mark .. line)
    end
  end
  return out
end

--- What `git diff` prints for the same change, from the first hunk on.
local function git_hunks(a, b, ctx)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  H.write(dir, "a", H.text(a))
  H.write(dir, "b", H.text(b))
  local out = vim.fn.systemlist({ "git", "-C", dir, "diff", "--no-index", "--no-ext-diff", "--histogram",
    "--indent-heuristic", "-U" .. ctx, "--", "a", "b" })
  local hunks, started = {}, false
  for _, l in ipairs(out) do
    started = started or l:sub(1, 2) == "@@"
    if started then table.insert(hunks, (l:gsub("^(@@ .- @@).*$", "%1"))) end
  end
  return hunks
end

return {
  { "insertion, deletion and empty-side conventions", function()
    local m = compute({ "a", "b", "c" }, { "a", "X", "b", "c" })
    H.eq(m.rows[2], { old = nil, new = 2, change = true, block = 1 })
    H.eq(#m.rows, 4)

    m = compute({ "a", "b", "c" }, { "a", "c" })
    H.eq(m.rows[2], { old = 2, new = nil, change = true, block = 1 })

    m = compute({}, { "a", "b" })
    H.eq(#m.blocks, 1)
    H.eq({ m.blocks[1].old_first, m.blocks[1].old_count, m.blocks[1].new_first }, { 1, 0, 1 })

    m = compute({ "a", "b" }, {})
    H.eq(#m.rows, 2)
    H.ok(m.rows[1].new == nil and m.rows[2].new == nil)
  end },

  { "randomised edits keep alignment invariants", function()
    math.randomseed(42)
    for _ = 1, 300 do
      local a = {}
      for i = 1, math.random(0, 40) do a[i] = "l" .. math.random(1, 8) end
      local b = {}
      for _, l in ipairs(a) do
        local r = math.random()
        if r < 0.15 then
          -- deleted
        elseif r < 0.3 then
          table.insert(b, l .. "x")
        elseif r < 0.4 then
          table.insert(b, "new" .. math.random(1, 5))
          table.insert(b, l)
        else
          table.insert(b, l)
        end
      end
      check_invariants(compute(a, b))
    end
  end },

  { "modified lines are paired on the same row (linematch)", function()
    local m = compute(
      { "local a = 1", "local b = 2", "return a" },
      { "local a = 10", "-- comment", "local b = 20", "return a" })
    check_invariants(m)
    local pairs_found = 0
    for _, row in ipairs(m.rows) do
      if row.change and row.old and row.new then
        H.eq(m.old.lines[row.old]:sub(1, 7), m.new.lines[row.new]:sub(1, 7), "paired unrelated lines")
        pairs_found = pairs_found + 1
      end
    end
    H.eq(pairs_found, 2)
  end },

  { "a rewrite reads as removed lines beside added ones, top-aligned", function()
    -- One call split over several lines: no old line is a version of a new
    -- one, so none is paired by likeness and the filler gathers at the bottom.
    local a = {
      "    validate(config)",
      "    store = Store(conn)",
      "    item = store.save(",
      "        alpha, beta, payload.to_dict(skip_empty=True), session.owner",
      "    )",
    }
    local b = {
      "    validate(config)",
      "    item = Saver(conn).save_item(",
      "        alpha,",
      "        beta,",
      "        payload.to_dict(skip_empty=True),",
      "        session.owner,",
      "        extra=extra,",
      "    )",
    }
    local m = compute(a, b)
    check_invariants(m)
    local pairs = {}
    for _, row in ipairs(m.rows) do table.insert(pairs, { row.old or 0, row.new or 0 }) end
    H.eq(pairs, { { 1, 1 }, { 2, 2 }, { 3, 3 }, { 4, 4 }, { 0, 5 }, { 0, 6 }, { 0, 7 }, { 5, 8 } })
    H.eq(#m.blocks, 1)

    -- The other way round, the lines are joined into one: the same layout,
    -- with the filler on the left.
    m = compute(b, a)
    check_invariants(m)
    pairs = {}
    for _, row in ipairs(m.rows) do table.insert(pairs, { row.old or 0, row.new or 0 }) end
    H.eq(pairs, { { 1, 1 }, { 2, 2 }, { 3, 3 }, { 4, 4 }, { 5, 0 }, { 6, 0 }, { 7, 0 }, { 8, 5 } })
    local word_diff = require("diff.word_diff")
    for r = 2, 4 do
      H.eq({ word_diff.compute(a[r], b[r]) }, { {}, {} }, "row " .. r .. " pairs unlike lines: no marks")
    end
  end },

  { "lines alike keep their rows; the unlike ones between pair by position", function()
    local m = compute(
      { "  foo(a, b)", "  x = completely()", "  bar(x)" },
      { "  foo(a, b, c)", "  inserted()", "  another(1)", "  bar(x, y)" })
    check_invariants(m)
    local pairs = {}
    for _, row in ipairs(m.rows) do table.insert(pairs, { row.old or 0, row.new or 0 }) end
    H.eq(pairs, { { 1, 1 }, { 2, 2 }, { 0, 3 }, { 3, 4 } })
  end },

  { "a call or literal opened up around its contents reads top-aligned", function()
    local function rows_of(m)
      local pairs = {}
      for _, row in ipairs(m.rows) do table.insert(pairs, { row.old or 0, row.new or 0 }) end
      return pairs
    end
    for _, case in ipairs({
      { "    process(alpha_value, beta_value, gamma_value, delta_value)",
        { "    process(", "        alpha_value, beta_value, gamma_value, delta_value", "    )" } },
      { '    config = {"name": user_name, "email": user_email, "active": True}',
        { "    config = {", '        "name": user_name, "email": user_email, "active": True', "    }" } },
    }) do
      local a = { "start()", case[1], "finish()" }
      local b = { "start()", case[2][1], case[2][2], case[2][3], "finish()" }
      local m = compute(a, b)
      check_invariants(m)
      H.eq(rows_of(m), { { 1, 1 }, { 2, 2 }, { 0, 3 }, { 0, 4 }, { 3, 5 } }, case[1])
      m = compute(b, a)
      check_invariants(m)
      H.eq(rows_of(m), { { 1, 1 }, { 2, 2 }, { 3, 0 }, { 4, 0 }, { 5, 3 } }, "joined: " .. case[1])
    end
  end },

  { "a region at the top of the file keeps an inserted first line in place", function()
    local m = compute({ "  foo(a, b)", "  bar(x)" }, { "  fresh()", "  foo(a, b, c)", "  bar(x, y)" })
    check_invariants(m)
    local pairs = {}
    for _, row in ipairs(m.rows) do table.insert(pairs, { row.old or 0, row.new or 0 }) end
    H.eq(pairs, { { 0, 1 }, { 1, 2 }, { 2, 3 } })
  end },

  { "a one-for-one rewrite measures no pairs", function()
    -- Pairs at their own place need no measuring: this is what keeps the
    -- check off the cost of ordinary diffs.
    local word_diff = require("diff.word_diff")
    local real, calls = word_diff.same_line, 0
    word_diff.same_line = function(...) calls = calls + 1 return real(...) end
    local a, b = {}, {}
    for i = 1, 2000 do
      a[#a + 1] = "  local value_" .. i .. " = compute(alpha, beta, gamma, " .. i .. ")"
      a[#a + 1] = "  result_" .. i .. " = transform(value_" .. i .. ", options)"
      b[#b + 1] = "  local value_" .. i .. " = calc(alpha, beta, gamma, delta, " .. i .. ")"
      b[#b + 1] = "  output_" .. i .. " = reshape(value_" .. i .. ", settings, extra)"
      a[#a + 1] = "  -- " .. i
      b[#b + 1] = "  -- " .. i
    end
    local ok, err = pcall(function() check_invariants(compute(a, b)) end)
    word_diff.same_line = real
    assert(ok, err)
    H.eq(calls, 0)
  end },

  { "layout collapses distant context and reveal expands one gap only", function()
    local a = H.lines(100)
    local b = H.lines(100, { [20] = "changed 20", [80] = "changed 80" })
    local m = compute(a, b)
    local lay = engine.layout(m, 3, {})
    local seps = {}
    for _, it in ipairs(lay.items) do if it.sep then table.insert(seps, it.sep) end end
    H.eq(#seps, 3, "expected gaps before, between and after the changes")
    H.eq(engine.separator_span(m, seps[2]).new, { 24, 76 })

    local reveals = engine.reveal(m, {}, seps[2], 10)
    local lay2 = engine.layout(m, 3, reveals)
    H.eq(#lay2.items, #lay.items + 20, "only 20 lines should be revealed")
    local seps2 = {}
    for _, it in ipairs(lay2.items) do if it.sep then table.insert(seps2, it.sep) end end
    H.eq(#seps2, 3)
    H.eq(engine.separator_span(m, seps2[1]).count, engine.separator_span(m, seps[1]).count,
      "the first gap must not change")

    H.eq(#engine.layout(m, nil, {}).items, 101, "every row, under one header")
  end },

  { "split layout heads each run with the @@ range the unified one gives it", function()
    local a = H.lines(60)
    local b = H.lines(60, { [10] = "line ten", [40] = "line forty" })
    table.insert(b, 11, "inserted")
    table.remove(b, 26)
    local m = compute(a, b)
    local function headers(lay)
      local out = {}
      for _, it in ipairs(lay.items) do
        if it.hunk then table.insert(out, engine.hunk_header(it.hunk)) end
      end
      return out
    end
    for _, ctx in ipairs({ 3, 0, nil }) do
      local split = headers(engine.layout(m, ctx, {}))
      H.ok(#split > 0, "headed")
      H.eq(split, headers(engine.unified_layout(m, ctx, {})), "context " .. tostring(ctx))
    end
    local items = engine.layout(m, 3, {}).items
    H.ok(items[1].sep and items[1].hunk, "the rows hidden above a run sit in its header")
    H.ok(items[#items].sep and not items[#items].hunk, "rows hidden at the end have no header")
    local first = engine.layout(compute(H.lines(5), H.lines(5, { [1] = "one" })), 3, {}).items[1]
    H.ok(first.hunk and not first.sep, "a run from the first line is headed too")
  end },

  { "reveals survive recomputation after an unrelated edit", function()
    local a = H.lines(100)
    local m1 = compute(a, H.lines(100, { [20] = "x", [80] = "y" }))
    local sep
    for _, it in ipairs(engine.layout(m1, 3, {}).items) do
      if it.sep and engine.separator_span(m1, it.sep).new[1] == 24 then sep = it.sep end
    end
    local reveals = engine.reveal(m1, {}, sep, 10)
    local m2 = compute(a, H.lines(100, { [20] = "x", [80] = "y", [95] = "z" }))
    local shown = {}
    for _, it in ipairs(engine.layout(m2, 3, reveals).items) do
      if it.row then shown[m2.rows[it.row].new or -1] = true end
    end
    H.ok(shown[30] and shown[70], "revealed lines disappeared after recompute")
  end },

  { "line mapper follows content across insertions, deletions and rewrites", function()
    local before = H.lines(10)
    local after = vim.list_extend({ "new 1", "new 2" }, H.lines(10))
    local map = engine.line_mapper(before, after)
    H.eq({ map(1), map(5), map(10) }, { 3, 7, 12 })

    map = engine.line_mapper(H.lines(10), { "line 1", "line 2", "line 6", "line 7", "line 8", "line 9", "line 10" })
    H.eq({ map(2), map(4), map(6), map(10) }, { 2, 3, 3, 7 })

    map = engine.line_mapper(H.lines(5), { "line 1", "X", "line 3", "line 4", "line 5" })
    H.eq({ map(2), map(3) }, { 2, 3 })
  end },

  { "line mapper maps unchanged content to itself without diffing it", function()
    local diffs, orig = 0, vim.diff
    vim.diff = function(...) diffs = diffs + 1 return orig(...) end
    local map = engine.line_mapper(H.lines(10), H.lines(10))
    vim.diff = orig
    H.eq(diffs, 0)
    H.eq({ map(0), map(1), map(10), map(12) }, { 1, 1, 10, 12 })
  end },

  { "identical files show everything", function()
    local m = compute(H.lines(10), H.lines(10))
    H.eq(#m.blocks, 0)
    H.eq(#engine.layout(m, 3, {}).items, 10)
  end },

  { "block patches apply cleanly with git apply --unidiff-zero", function()
    local cases = {
      { H.lines(10), H.lines(10, { [5] = "five" }) },                    -- modify
      { H.lines(5), vim.list_extend({ "top" }, H.lines(5)) },           -- insert at top
      { H.lines(5), vim.list_extend(H.lines(5), { "end" }) },           -- insert at end
      { H.lines(5), { "line 1", "line 2", "line 3" } },                -- delete at end
      { H.lines(5), { "line 1", "line 4", "line 5" } },                -- delete middle
      { {}, { "only" } },                                               -- into empty file
    }
    for i, c in ipairs(cases) do
      local repo = H.repo({ ["f.txt"] = c[1][1] and H.text(c[1]) or "" })
      H.write(repo, "f.txt", H.text(c[2]))
      local m = compute(c[1], c[2])
      for _, blk in ipairs(m.blocks) do
        local patch = H.ok(engine.block_patch(m, blk, "f.txt"))
        vim.fn.system({ "git", "-C", repo, "apply", "--cached", "--unidiff-zero", "-" }, patch)
        H.eq(vim.v.shell_error, 0, "case " .. i .. " failed to apply:\n" .. patch)
      end
      H.eq(H.git(repo, "diff", "--name-only"), "", "case " .. i .. ": index should match worktree")
    end
  end },

  { "patches carry the no-newline marker, unsafe EOF hunks are refused", function()
    local repo = H.repo({ ["f.txt"] = "a\nb" })
    H.write(repo, "f.txt", "a\nB")
    local m = engine.compute(side({ "a", "b" }, false), side({ "a", "B" }, false))
    local patch = H.ok(engine.block_patch(m, m.blocks[1], "f.txt"))
    vim.fn.system({ "git", "-C", repo, "apply", "--cached", "--unidiff-zero", "-" }, patch)
    H.eq(vim.v.shell_error, 0, "no-eol patch failed:\n" .. patch)
    H.eq(H.git(repo, "diff", "--name-only"), "")

    local m2 = engine.compute(side({ "a" }, false), side({ "a", "b" }, true))
    local p2, err = engine.block_patch(m2, m2.blocks[1], "f.txt")
    H.eq(p2, nil)
    H.ok(err and err:find("newline"))
  end },

  { "large rewrite computes quickly", function()
    local a, b = {}, {}
    for i = 1, 2000 do a[i] = "  local value_" .. i .. " = compute(" .. i .. ")" end
    for i = 1, 2000 do b[i] = a[i] end
    for i = 700, 790 do b[i] = a[i]:gsub("compute", "calc") end
    for i = 40, 2000, 60 do b[i] = b[i] .. " -- edited" end
    local t = vim.uv.hrtime()
    local m = compute(a, b)
    engine.layout(m, 3, {})
    local ms = (vim.uv.hrtime() - t) / 1e6
    check_invariants(m)
    H.ok(ms < 50, string.format("compute+layout took %.1f ms", ms))
    t = vim.uv.hrtime()
    engine.unified_layout(m, 3, {})
    engine.unified_layout(m, nil, {})
    ms = (vim.uv.hrtime() - t) / 1e6
    H.ok(ms < 20, string.format("unified layouts took %.1f ms", ms))
  end },

  { "unified layout reads as git diff: hunk ranges, removed lines before added", function()
    local a = H.lines(60)
    local b = H.lines(60, { [10] = "line ten", [40] = "line forty" })
    table.insert(b, 11, "inserted")
    table.remove(b, 26)
    table.insert(b, 53, "late")
    for _, ctx in ipairs({ 3, 0, 5 }) do
      H.eq(unified_text(compute(a, b), ctx), git_hunks(a, b, ctx), "context " .. ctx)
    end
    -- Unlike git, a single line between two hunks is shown rather than
    -- headed: the header would take the same row.
    local joined = H.lines(20, { [5] = "five", [13] = "thirteen" })
    local text = unified_text(compute(H.lines(20), joined), 3)
    H.eq(text[1], "@@ -2,15 +2,15 @@", "a lone hidden line at the top collapses into the header")
    H.ok(vim.tbl_contains(text, " line 9"), "the line between the hunks is shown")
    -- A whole file added, or deleted, has an empty side numbered 0.
    H.eq(unified_text(compute({}, { "x", "y" }), 3), { "@@ -0,0 +1,2 @@", "+x", "+y" })
    H.eq(unified_text(compute({ "x" }, {}), 3), { "@@ -1 +0,0 @@", "-x" })
  end },

  { "unified layout: separators, block starts and the item of each side", function()
    local a = H.lines(30)
    local b = H.lines(30, { [15] = "changed" })
    local m = compute(a, b)
    local lay = engine.unified_layout(m, 3, {})
    local items = lay.items
    H.ok(items[1].sep and items[1].hunk, "the rows hidden above the hunk sit in its header")
    H.ok(items[#items].sep and not items[#items].hunk, "rows hidden at the end have no header")
    local first = lay.block_start[1]
    H.eq({ items[first].side, items[first + 1].side }, { "old", "new" })
    H.eq(engine.item_of(lay, items[first].row, "old"), first)
    H.eq(engine.item_of(lay, items[first].row, "new"), first + 1)
    local ctx_row = items[2].row
    H.eq(engine.item_of(lay, ctx_row, "old"), 2, "context shows both sides on one item")
    H.eq(engine.item_of(lay, ctx_row, "new"), 2)
    H.eq(engine.item_of(lay, 1, "new"), nil, "hidden rows have no item")

    -- Fully expanded, one header covers the whole file; with no change, none.
    local all = engine.unified_layout(m, nil, {}).items
    H.eq(engine.hunk_header(all[1].hunk), "@@ -1,30 +1,30 @@")
    H.eq(#all, 32)
    local same = engine.unified_layout(compute(a, a), 3, {}).items
    H.eq(#same, 30)
    H.ok(not same[1].hunk)
  end },

  { "word diff marks a changed phrase as one range, not word by word", function()
    local word_diff = require("diff.word_diff")
    local old, new = word_diff.compute("call(alpha beta, first, second)", "call(gamma delta, first, second)")
    H.eq(old, { { start_col = 5, end_col = 15 } })
    H.eq(new, { { start_col = 5, end_col = 16 } })
    old = word_diff.compute("a = 1", "a = 2")
    H.eq(old, { { start_col = 4, end_col = 5 } }, "separate changes stay separate")
  end },

  { "word diff marks whole identifiers, and only between lines alike", function()
    local word_diff = require("diff.word_diff")
    local old, new = word_diff.compute("x = user_id + 1", "x = user_name + 1")
    H.eq(old, { { start_col = 4, end_col = 11 } }, "snake_case is one token")
    H.eq(new, { { start_col = 4, end_col = 13 } })
    -- `user` must not match inside `user_id`.
    old, new = word_diff.compute("f(user, other_arg)", "f(user_id, other_arg)")
    H.eq(old, { { start_col = 2, end_col = 6 } })
    H.eq(new, { { start_col = 2, end_col = 9 } })

    H.ok(word_diff.similar("local a = 1", "local a = 10"))
    H.ok(word_diff.similar("user_id = 1", "user_name = 1"), "likeness reads inside identifiers")
    H.ok(word_diff.similar("    foo", "foo"), "indentation alone is alike")
    H.ok(word_diff.similar("", "  "), "blank lines are alike")
    H.ok(not word_diff.similar("", "foo"))
    H.ok(not word_diff.similar("return nil", "log.debug(msg)"))
    H.ok(not word_diff.similar("    item = store.save(", "        item_id,"))
    H.eq({ word_diff.compute("return nil", "log.debug(msg)") }, { {}, {} })

    -- A split line is alike to its largest piece, but its other pieces sit
    -- around that one; an edited line's neighbours add nothing of it.
    local whole = "    alpha, beta, payload.to_dict(skip_empty=True), session.owner"
    local piece = "        payload.to_dict(skip_empty=True),"
    H.ok(word_diff.similar(whole, piece))
    H.ok(not word_diff.same_line(whole, piece, {}, { before = "        beta,", after = "        session.owner," }))
    H.ok(not word_diff.same_line(piece, whole, { before = "        beta,", after = "        session.owner," }, {}),
      "a join is a split read backwards")
    H.ok(word_diff.same_line(whole, piece, {}, {}), "with nothing around it, the piece is the line")
    H.ok(word_diff.same_line("  foo(a, b)", "  foo(a, b, c)", { after = "  x = completely()" },
      { before = "  first()", after = "  inserted()" }))
    -- Neighbours that share a stray `,` or name with an edited line do not
    -- make it a piece.
    H.ok(word_diff.same_line("  call(a, b)", "  call(a, b, d)", { after = "  call(a, c)" }, {}))
    H.ok(word_diff.same_line("  foo(a, b)", "  foo(a, b, c)", { after = "  bar(x, y)" }, {}))
    H.ok(word_diff.same_line("", "    ", {}, { before = "  foo()" }), "blank lines stay together")

    -- Non-ASCII words are whole tokens: unrelated comments are not alike, and
    -- a mark never cuts a character in two.
    H.ok(not word_diff.similar("// проверить настройки", "// вернуть результат"))
    old, new = word_diff.compute("x = 'café' .. name", "x = 'thé' .. name")
    H.eq(old, { { start_col = 5, end_col = 10 } })
    H.eq(new, { { start_col = 5, end_col = 9 } })
  end },
}
