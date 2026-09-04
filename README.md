# remote-sync.nvim

Manual remote synchronization for Neovim using `rsync` over `ssh`.

The plugin is intentionally manual-only. It does not provide background synchronization, polling, filesystem watchers, automatic `BufWritePost` uploads, deployment orchestration, or remote deletion mirroring.

## Features

- Upload one current/local file.
- Download one remote file to the corresponding local path.
- Upload current Git modified, staged, and untracked paths in a batch.
- Launch external commands asynchronously.
- Select projects from configured local roots; nested paths use the nearest configured ancestor.
- Execute external processes with argv lists, without shell command composition.
- Manual-only synchronization.

## Requirements

- Neovim with `vim.system()` support.
- `rsync`.
- `ssh`.
- `git` only when `git_upload()` is used.

## Installation

With lazy.nvim:

```lua
{
  "Oleg4cy/remote-sync.nvim",
  lazy = true,
}
```

## Configuration

```lua
require("remote-sync").setup({
  projects = {
    ["/home/user/project"] = {
      host = "user@example.com",
      remote = "/var/www/project",
    },
  },
})
```

Each table key is a local project root. `host` is the rsync/ssh remote host, and `remote` is the corresponding remote project root. For a file inside nested configured roots, the nearest configured ancestor is selected.

Configuration is explicit. The plugin does not know about `config.local`; the caller or main Neovim configuration owns configuration-source policy. `setup()` receives only the resulting `projects` table. No other setup options are supported.

## Public API

- `setup(opts)`
- `upload(file_path)`
- `download(file_path)`
- `git_upload(file_path)`

`file_path` is optional for `upload()`, `download()`, and `git_upload()`. When omitted, the current buffer path is used. `upload()` does not save the current buffer automatically.

## Usage

Optional command wrappers:

```lua
vim.api.nvim_create_user_command("SyncUpload", function()
  require("remote-sync").upload()
end, {})

vim.api.nvim_create_user_command("SyncDownload", function()
  require("remote-sync").download()
end, {})

vim.api.nvim_create_user_command("SyncGitUpload", function()
  require("remote-sync").git_upload()
end, {})
```

Final mapping examples:

```lua
vim.keymap.set("n", "<leader>ru", function()
  vim.cmd("write")
  require("remote-sync").upload()
end)

vim.keymap.set("n", "<leader>rd", function()
  require("remote-sync").download()
end)

vim.keymap.set("n", "<leader>rg", function()
  require("remote-sync").git_upload()
end)
```

Saving before upload is user/mapping policy; `upload()` itself does not write the buffer. `download()` and `git_upload()` do not implicitly save the current buffer. After a successful download, the current buffer is reloaded only if the downloaded path is still the current buffer.

External processes are launched asynchronously through `vim.system()`. The plugin does not perform background polling or use persistent workers.

## Git batch behavior

`git_upload()` uses:

```text
git status --porcelain=v1 -z --untracked-files=all
```

It uploads current existing paths through rsync. Modified paths, staged paths, and untracked files are included. Locally deleted paths are skipped. For rename/copy records, the current/destination path is uploaded; the old/source remote path is not deleted. This is not a mirror or deployment system, and remote deletion is not performed.

## Healthcheck

Run:

```vim
:checkhealth remote-sync
```

The healthcheck performs only local passive checks for `vim.system()` availability, `rsync`, `ssh`, and `git` executable availability, and the current configured-project count. It does not contact remote servers, verify credentials, run rsync, ssh, or git, mutate configuration, or read `config.local`.

## Tests

```bash
nvim --headless -u tests/minimal_init.lua -i NONE -l tests/remote_sync_spec.lua
```

The suite uses plain Neovim/Lua and requires no external testing framework. The minimal init disables unrelated plugin loading.

## License

MIT
