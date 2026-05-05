local M = {}

M.defaults = {
  sidebar_position = "left", -- "left" or "right"
  sidebar_width = 40,
  context_lines = 3, -- lines of context around each hunk (nil = show all)
  notes_path = nil, -- nil = XDG default
  auto_refresh = true,
  keymaps = {
    toggle_sidebar = "<leader>gs",
    refresh        = "<leader>gr",
    open_diff      = "<CR>",
    stage_file     = "s",
    unstage_file   = "u",
    collapse       = "z",
    next_hunk      = "]c",
    prev_hunk      = "[c",
    leave_note     = "<leader>n",
    toggle_notes   = "<leader>N",
    expand_context = "zo",
    expand_all     = "zR",
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
