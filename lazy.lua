return {
  cmd = {
    "SyncUpload",
    "SyncDownload",
    "SyncGitUpload",
  },
  init = function()
    vim.keymap.set("n", "<Plug>(RemoteSyncUpload)", function()
      require("remote-sync").upload_current()
    end, { desc = "Remote Sync: Upload current file", silent = true })

    vim.keymap.set("n", "<Plug>(RemoteSyncDownload)", function()
      require("remote-sync").download()
    end, { desc = "Remote Sync: Download current file", silent = true })

    vim.keymap.set("n", "<Plug>(RemoteSyncGitUpload)", function()
      require("remote-sync").git_upload()
    end, { desc = "Remote Sync: Git upload current file", silent = true })

    vim.api.nvim_create_autocmd("VimEnter", {
      once = true,
      callback = function()
        local defaults = {
          { "<leader>ru", "<Plug>(RemoteSyncUpload)" },
          { "<leader>rd", "<Plug>(RemoteSyncDownload)" },
          { "<leader>rg", "<Plug>(RemoteSyncGitUpload)" },
        }

        for _, mapping in ipairs(defaults) do
          if vim.fn.hasmapto(mapping[2], "n") == 0 and vim.fn.maparg(mapping[1], "n") == "" then
            vim.keymap.set("n", mapping[1], mapping[2])
          end
        end
      end,
    })
  end,
}
