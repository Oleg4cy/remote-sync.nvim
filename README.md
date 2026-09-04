# remote-sync.nvim

`remote-sync.nvim` provides manual, one-shot synchronization between local files and configured remote projects. It does not provide background synchronization, polling, filesystem watchers, automatic `BufWritePost` uploads, deployment orchestration, or remote deletion mirroring.

## Features

- Upload one current/local file.
- Download one remote file to its corresponding local path.
- Upload current Git modified, staged, and untracked paths in a batch.
- Launch external commands asynchronously.
- Select projects from configured local roots using the nearest configured ancestor.
- Execute external commands with argv lists rather than shell command composition.
- Manual-only synchronization.

## Requirements

- Neovim with `vim.system()` support.
- `rsync`.
- `ssh`.
- `git` only when `git_upload()` is used.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "Oleg4cy/remote-sync.nvim",
  opts = {
    projects = {
      ["/home/user/project"] = {
        host = "user@example.com",
        remote = "/var/www/project",
      },
    },
  },
}
```

The plugin owns its lazy.nvim package metadata and is configured through `opts.projects`. `projects` is the only setup option.

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

`projects` is a Lua table whose key is the local project root. Each value contains `host`, the SSH destination, and `remote`, the corresponding remote project root. If configured roots are nested, the nearest configured ancestor is selected. `projects` is the only setup option. The plugin does not know about `config.local`, `local.lua`, or machine-specific configuration files; loading projects from such files is policy belonging to your main Neovim configuration.

## Public API

```lua
local remote_sync = require("remote-sync")

remote_sync.setup(opts)
remote_sync.upload(file_path)
remote_sync.upload_current()
remote_sync.download(file_path)
remote_sync.git_upload(file_path)
```

`upload(file_path)` accepts an optional path; when omitted, it uses the current buffer path. It does not execute `:write`. `upload_current()` takes no path, executes `:write`, then calls `upload()`; if `:write` fails, upload does not start. `download(file_path)` accepts an optional path and otherwise uses the current buffer path; it does not implicitly save the buffer. `git_upload(file_path)` also accepts an optional path and otherwise uses the current buffer path for project detection; it does not implicitly save the buffer.

## Built-in commands

- `:SyncUpload` calls `upload()` and does not execute `:write`.
- `:SyncDownload` calls `download()`.
- `:SyncGitUpload` calls `git_upload()`.

`:SyncUpload` is intentionally different from the default `<leader>ru` mapping, which saves first.

## Built-in mappings

The default mappings are:

- `<leader>ru` → `<Plug>(RemoteSyncUpload)` → `upload_current()`; saves the current buffer and then uploads it;
- `<leader>rd` → `<Plug>(RemoteSyncDownload)` → `download()`;
- `<leader>rg` → `<Plug>(RemoteSyncGitUpload)` → `git_upload()`.

An already occupied default left-hand side is left untouched.

## Remapping with `<Plug>`

Stable plugin-owned targets are available:

- `<Plug>(RemoteSyncUpload)`
- `<Plug>(RemoteSyncDownload)`
- `<Plug>(RemoteSyncGitUpload)`

For example:

```lua
vim.keymap.set(
  "n",
  "<leader>su",
  "<Plug>(RemoteSyncUpload)",
  { desc = "Remote Sync: Upload current file" }
)
```

Because the plugin checks `hasmapto()` before creating defaults, defining this mapping before `VimEnter` means `<leader>ru` is not created. This is a true replacement, not an alias. The decision is independent for Upload, Download, and GitUpload. An already occupied original left-hand side is not overwritten.

`upload()` itself does not save the current buffer. `upload_current()` performs the save-and-upload action. `download()` and `git_upload()` do not implicitly save the current buffer. After a successful download, the current buffer is reloaded only if the downloaded path is still the current buffer. External processes are launched asynchronously through `vim.system()`; the plugin does not perform background polling or use persistent workers.

## Git batch behavior

`git_upload()` uses:

```text
git status --porcelain=v1 -z --untracked-files=all
```

Current existing paths are uploaded through `rsync`. Modified, staged, and untracked paths are included. Locally deleted paths are skipped. For rename/copy records, the current/destination path is uploaded; the old/source path is not remotely deleted. Remote deletion is not performed. This is not a mirror or deployment system.

## Healthcheck

The healthcheck performs only passive local checks for:

- `vim.system()` availability;
- `rsync` executable availability;
- `ssh` executable availability;
- `git` executable availability;
- configured-project count.

It does not contact remote servers, verify credentials, execute `rsync`, execute `ssh`, execute `git`, mutate configuration, or read `config.local`.

With lazy.nvim, if the plugin has not been loaded yet, run:

```vim
:Lazy load remote-sync.nvim
:checkhealth remote-sync
```

Using a remote-sync command or mapping first also loads the plugin, after which `:checkhealth remote-sync` works normally. The checkhealth report is not available before the lazy plugin enters `runtimepath`.

## Tests

```sh
nvim --headless -u tests/minimal_init.lua -i NONE -l tests/remote_sync_spec.lua
```

The suite uses plain Neovim/Lua and requires no external testing framework. `minimal_init.lua` disables unrelated plugin loading.

## License

MIT
