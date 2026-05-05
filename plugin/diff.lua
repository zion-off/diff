-- plugin/diff.lua — entry point (loaded automatically by NeoVim's rtp loader)
-- Prevent double-loading.
if vim.g.loaded_diff_nvim then
  return
end
vim.g.loaded_diff_nvim = true

-- ── User commands ────────────────────────────────────────────────────────────

vim.api.nvim_create_user_command("DiffNvimOpen", function()
  require("diff").open()
end, { desc = "Open diff.nvim sidebar" })

vim.api.nvim_create_user_command("DiffNvimClose", function()
  require("diff").close()
end, { desc = "Close diff.nvim sidebar" })

vim.api.nvim_create_user_command("DiffNvimToggle", function()
  require("diff").toggle()
end, { desc = "Toggle diff.nvim sidebar" })

vim.api.nvim_create_user_command("DiffNvimRefresh", function()
  require("diff").refresh()
end, { desc = "Refresh diff.nvim file and commit panels" })

vim.api.nvim_create_user_command("DiffNvimNotes", function()
  local git = require("diff.git")
  local cwd = vim.fn.getcwd()
  git.get_repo_root(cwd, function(root, err)
    if err or not root then
      vim.notify("diff.nvim: not in a git repository", vim.log.levels.WARN)
      return
    end
    require("diff.annotations").toggle_notes(root)
  end)
end, { desc = "Toggle diff.nvim notes panel" })
