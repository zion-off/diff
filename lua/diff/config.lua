local M = {}

M.defaults = {
  sidebar_position = "left", -- "left" or "right"
  sidebar_width = 40,
  notes_width = 40,          -- width of the notes right-side split
  context_lines = 3, -- lines of context around each hunk (nil = show all)
  wrap = true, -- soft-wrap long lines in the diff panes, keeping split panes row-aligned
  notes_path = nil, -- nil = XDG default (ignored; kept for backward compat)
  auto_refresh = true,
  base_branch = nil, -- branch mode compares against this; nil = origin/HEAD, else main or master
  mouse = true, -- enable mouse interactivity in the sidebar (clicks open/toggle)
  log_level = "warn", -- trace | debug | info | warn | error | off  (see :DiffNvimLog)
  keymaps = {
    toggle_sidebar       = "<leader>gs",
    toggle_sidebar_panel = "<leader>gS",
    copy_notes_path      = "<leader>gy",
    open_diff            = "<CR>",
    stage_file           = "s",
    unstage_file         = "u",
    collapse             = "z",
    next_hunk            = "]c",
    prev_hunk            = "[c",
    next_file            = "]f",
    prev_file            = "[f",
    goto_file            = "gf",
    stage_hunk           = "s",
    unstage_hunk         = "u",
    leave_note           = "<leader>n",
    toggle_notes         = "<leader>N",
    preview_branch       = "<leader>gb",
    branch_changes       = "<leader>gB",
    expand_context       = "zo",
    expand_all           = "zR",
    collapse_all         = "zM",
    commit_tooltip       = "K",
  },
  highlights = {},
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

function M.get()
  return M.options
end

return M
