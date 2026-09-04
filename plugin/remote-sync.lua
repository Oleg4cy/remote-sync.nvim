if vim.g.loaded_remote_sync then
  return
end

vim.g.loaded_remote_sync = true

vim.api.nvim_create_user_command("SyncUpload", function()
  require("remote-sync").upload()
end, {})

vim.api.nvim_create_user_command("SyncDownload", function()
  require("remote-sync").download()
end, {})

vim.api.nvim_create_user_command("SyncGitUpload", function()
  require("remote-sync").git_upload()
end, {})
