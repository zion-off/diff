--- diff.nvim — asks the language server about a symbol in a diff: where it
--- is defined, and what it is (hover).
---
--- A diff pane holds a copy of one version of a file, which no language
--- server knows. The server knows the file as the editor has it, so the
--- question is put to that: the real file is loaded in a hidden buffer the
--- first time it is asked about (which starts the user's language server as
--- opening it would), the line under the cursor is matched to its line
--- there, and the server is asked about that position. A line that is not
--- in the file as the editor has it (removed, rewritten) cannot be asked
--- about this way, and is reported as such for the caller to fall back on.
---
--- Nothing here runs until a question is asked, and nothing blocks: the
--- caller gets one answer, later, through a callback.
local M = {}

local engine = require("diff.diff_engine")
local log    = require("diff.log").scope("lsp")

-- A server is given this long to attach to a freshly loaded file; one that
-- starts for the first time in a session may take a while.
M.ATTACH_TIMEOUT_MS = 5000
-- And this long to answer: a large project may still be indexing.
M.REQUEST_TIMEOUT_MS = 10000

local HAS_011 = vim.fn.has("nvim-0.11") == 1

-- Buffers this module loaded, least recently asked about first. They are
-- unloaded again on release, or once more than M.MAX_LOADED are kept, unless
-- the user has opened them since: each one is a file the language server
-- keeps analysing.
local loaded_here = {}
M.MAX_LOADED = 10

-- filetype -> { [capability] = true } for the questions no server attached
-- to answer within the timeout. Asking again would only wait out the timeout
-- again, so they are answered at once until a server attaches to a buffer of
-- that filetype.
local no_server = {}

local aug = vim.api.nvim_create_augroup("DiffNvimLsp", { clear = true })
vim.api.nvim_create_autocmd("LspAttach", {
  group = aug,
  callback = function(args)
    local ft = vim.bo[args.buf].filetype
    if no_server[ft] then
      log.debug("a language server attached to a %s buffer; asking it again", ft)
      no_server[ft] = nil
    end
  end,
})

local function get_clients(buf)
  if vim.lsp.get_clients then return vim.lsp.get_clients({ bufnr = buf }) end
  return vim.lsp.get_active_clients({ bufnr = buf })
end

--- Call a method of an LSP client: Neovim 0.11 made them methods (`:`),
--- before that they were plain functions (`.`).
local function client_call(client, method, ...)
  if HAS_011 then return client[method](client, ...) end
  return client[method](...)
end

local function capable_client(buf, capability)
  for _, client in ipairs(get_clients(buf)) do
    if client.server_capabilities and client.server_capabilities[capability] then return client end
  end
end

--- The loaded buffer named exactly `path`, if any. bufnr() would read the
--- name as a pattern, and `app/[id]/page.lua` would find `app/i/page.lua`.
local function loaded_buf(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf) == path and vim.api.nvim_buf_is_loaded(buf) then return buf end
  end
end

local function index_of(list, value)
  for i, v in ipairs(list) do
    if v == value then return i end
  end
end

--- Unload `buf`, loaded here, unless the user has opened it since (shown in
--- a window, listed) or it has unsaved changes.
--- @return boolean whether it was unloaded
local function unload_if_unused(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buflisted or vim.bo[buf].modified
    or #vim.fn.win_findbuf(buf) > 0 then
    return false
  end
  log.debug("unloading %s, loaded to ask about it", vim.api.nvim_buf_get_name(buf))
  pcall(vim.api.nvim_buf_delete, buf, {})
  return true
end

--- Note `buf` as the one asked about last, unloading the least recently
--- asked about beyond M.MAX_LOADED.
local function touch(buf)
  local i = index_of(loaded_here, buf)
  if i then table.remove(loaded_here, i) end
  table.insert(loaded_here, buf)
  while #loaded_here > M.MAX_LOADED do
    unload_if_unused(table.remove(loaded_here, 1))
  end
end

--- The buffer of `path`, loaded if it was not. A buffer the user already had
--- is used as it is and never unloaded by this module.
local function load(path)
  local buf = loaded_buf(path)
  if buf then
    if index_of(loaded_here, buf) then touch(buf) end
    return buf
  end
  buf = vim.fn.bufadd(path)
  local elapsed = require("diff.log").timer()
  -- No swap file: another editor opening the file would otherwise warn that
  -- it is being edited here. It is restored if the user opens the buffer.
  vim.bo[buf].swapfile = false
  -- bufload() reads the file as :edit would, filetype detection included,
  -- which is what starts the language server. It never prompts about a swap file.
  local ok, err = pcall(vim.fn.bufload, buf)
  if not ok then
    log.warn("cannot load %s: %s", path, tostring(err))
    return nil
  end
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = aug, buffer = buf, once = true,
    callback = function() vim.bo[buf].swapfile = vim.go.swapfile end,
  })
  touch(buf)
  log.debug("loaded %s in the background (%s) in %.1f ms", path, vim.bo[buf].filetype, elapsed())
  return buf
end

--- The lines of `path` as the editor has them: its buffer when one is loaded
--- (unsaved edits included, as the language server sees them), else the file.
--- @return string[]|nil
function M.file_lines(path)
  local buf = loaded_buf(path)
  if buf then return vim.api.nvim_buf_get_lines(buf, 0, -1, false) end
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and lines or nil
end

--- Call `on_client(client)` once a server with `capability` is attached to
--- `buf`, or `on_client(nil)` when none is within the timeout.
local function with_client(buf, capability, on_client)
  local client = capable_client(buf, capability)
  if client then return on_client(client) end
  local ft = vim.bo[buf].filetype
  if ft == "" then
    log.debug("%s has no filetype, so no language server starts for it; not waiting", vim.api.nvim_buf_get_name(buf))
    return on_client(nil)
  end
  if no_server[ft] and no_server[ft][capability] then
    log.debug("no language server with %s for %s files earlier this session; not waiting", capability, ft)
    return on_client(nil)
  end

  log.info("waiting for a language server with %s to attach to %s", capability, vim.api.nvim_buf_get_name(buf))
  vim.api.nvim_echo({ { "diff.nvim: waiting for the language server…", "Comment" } }, false, {})
  local done, autocmd = false, nil
  local timer = (vim.uv or vim.loop).new_timer()
  local elapsed = require("diff.log").timer()
  local function finish(c)
    if done then return end
    done = true
    timer:stop()
    timer:close()
    if autocmd then pcall(vim.api.nvim_del_autocmd, autocmd) end
    on_client(c)
  end
  autocmd = vim.api.nvim_create_autocmd("LspAttach", {
    group = aug,
    buffer = buf,
    callback = function()
      -- Several servers may attach; only one that can answer will do.
      local c = capable_client(buf, capability)
      if c then
        log.info("language server %s attached after %.0f ms", c.name, elapsed())
        vim.api.nvim_echo({ { "" } }, false, {})
        vim.schedule(function() finish(c) end)
      end
    end,
  })
  timer:start(M.ATTACH_TIMEOUT_MS, 0, vim.schedule_wrap(function()
    if done then return end
    log.info("no language server with %s attached to a %s file within %d ms", capability, ft, M.ATTACH_TIMEOUT_MS)
    no_server[ft] = no_server[ft] or {}
    no_server[ft][capability] = true
    finish(nil)
  end))
end

--- A definition answer is one Location, a list of Locations or LocationLinks, or nil.
local function as_list(result)
  if result == nil then return {} end
  if result.uri or result.targetUri then return { result } end
  return result
end

local function definition_answer(result, enc)
  local locations = {}
  for _, item in ipairs(vim.lsp.util.locations_to_items(as_list(result), enc)) do
    table.insert(locations, { path = item.filename, line = item.lnum, col = math.max(item.col - 1, 0) })
  end
  if #locations == 0 then return { status = "none" } end
  return { status = "found", locations = locations }
end

local function hover_answer(result)
  local lines = result and result.contents and vim.lsp.util.convert_input_to_markdown_lines(result.contents) or {}
  local first, last = 1, #lines
  while first <= last and vim.trim(lines[first]) == "" do first = first + 1 end
  while last >= first and vim.trim(lines[last]) == "" do last = last - 1 end
  if first > last then return { status = "none" } end
  return { status = "found", lines = vim.list_slice(lines, first, last) }
end

-- What can be asked: the LSP method, the server capability it needs, and
-- how its result becomes an answer.
local QUESTIONS = {
  definition = { method = "textDocument/definition", capability = "definitionProvider", answer = definition_answer },
  hover      = { method = "textDocument/hover",      capability = "hoverProvider",      answer = hover_answer },
}

--- Ask `client` question `kind` about 0-based (`row`, `col`) of `buf`.
local function request(client, kind, buf, row, col, on_done)
  local question = QUESTIONS[kind]
  local enc = client.offset_encoding or "utf-16"
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = { line = row, character = vim.lsp.util.character_offset(buf, row, col, enc) },
  }
  local done = false
  local timer = (vim.uv or vim.loop).new_timer()
  local elapsed = require("diff.log").timer()
  local function finish(answer)
    if done then return end
    done = true
    timer:stop()
    timer:close()
    on_done(answer)
  end
  local ok, sent, id = pcall(client_call, client, "request", question.method, params, function(err, result)
    if err then
      log.warn("%s answered %s with an error: %s", client.name, question.method, vim.inspect(err))
      return finish({ status = "error", message = err.message or tostring(err) })
    end
    if result == vim.NIL then result = nil end
    local answer = question.answer(result, enc)
    log.info("%s answered %s (%s) in %.0f ms", client.name, question.method, answer.status, elapsed())
    finish(answer)
  end, buf)
  if not (ok and sent) then
    log.warn("cannot send %s to %s: %s", question.method, client.name, tostring(sent))
    return finish({ status = "error", message = "the language server did not take the request" })
  end
  if done then return end
  timer:start(M.REQUEST_TIMEOUT_MS, 0, vim.schedule_wrap(function()
    if done then return end
    log.warn("%s did not answer %s within %d ms", client.name, question.method, M.REQUEST_TIMEOUT_MS)
    if id then pcall(client_call, client, "cancel_request", id) end
    finish({ status = "timeout" })
  end))
end

--- Ask question `kind` about the symbol at `line`, byte `col` (0-based) of
--- `lines`, one version of the file at `path`.
local function ask(kind, q, on_result)
  local elapsed = require("diff.log").timer()
  local function reply(result)
    log.debug("%s at %s:%d:%d -> %s in %.0f ms", kind, q.path, q.line, q.col, result.status, elapsed())
    on_result(result)
  end
  if vim.fn.filereadable(q.path) == 0 then return reply({ status = "unmapped" }) end
  local buf = load(q.path)
  if not buf then return reply({ status = "error", message = "cannot read " .. q.path }) end
  local line = engine.exact_line_mapper(q.lines, vim.api.nvim_buf_get_lines(buf, 0, -1, false))(q.line)
  if not line then return reply({ status = "unmapped" }) end
  if line ~= q.line then log.debug("line %d is line %d in the editor's %s", q.line, line, q.path) end
  with_client(buf, QUESTIONS[kind].capability, function(client)
    if not client then return reply({ status = "no_server" }) end
    if not vim.api.nvim_buf_is_valid(buf) then return reply({ status = "error", message = "the file was closed" }) end
    request(client, kind, buf, line - 1, q.col, reply)
  end)
end

-- Both questions take `q` = { path: string (absolute), lines: string[],
-- line: integer, col: integer }: the symbol at `line`, byte `col` (0-based)
-- of `lines`, one version of the file at `path`. `on_result` gets one of
--   { status = "found", ... }  the answer, as below
--   { status = "none" }        the server has nothing to say about it
--   { status = "unmapped" }    the line is not in the file as the editor has it
--   { status = "no_server" }   no language server can answer for the file
--   { status = "timeout" }     the server did not answer in time
--   { status = "error", message }

--- Where the symbol is defined: `locations` = { { path, line, col } },
--- 1-based line, 0-based byte col.
--- @param q table
--- @param on_result fun(result: table)
function M.definition(q, on_result)
  ask("definition", q, on_result)
end

--- What the symbol is: `lines` of markdown.
--- @param q table
--- @param on_result fun(result: table)
function M.hover(q, on_result)
  ask("hover", q, on_result)
end

--- Unload the buffers loaded to ask about, unless the user has opened them
--- since (shown in a window, listed) or they have unsaved changes. The
--- language server stops tracking them.
function M.release()
  local released = 0
  for _, buf in ipairs(loaded_here) do
    if unload_if_unused(buf) then released = released + 1 end
  end
  loaded_here = {}
  if released > 0 then log.debug("released %d buffer(s) loaded for language server questions", released) end
end

return M
