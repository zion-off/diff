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

vim.api.nvim_create_user_command("DiffNvimPreviewBranch", function()
  require("diff").preview_branch()
end, { desc = "Preview another branch's commits without checking it out" })

vim.api.nvim_create_user_command("DiffNvimNotes", function()
  require("diff")._with_repo(function(info)
    require("diff.annotations").toggle_notes(info.root)
  end)
end, { desc = "Toggle diff.nvim notes panel" })

vim.api.nvim_create_user_command("DiffNvimLog", function()
  vim.cmd("tabnew " .. vim.fn.fnameescape(require("diff.log").path()))
end, { desc = "Open the diff.nvim log file (set log_level = \"debug\" for detail)" })
