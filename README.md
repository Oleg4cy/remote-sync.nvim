# remote-sync.nvim

Manual-only file synchronization between local projects and remote projects over SSH and rsync. The plugin does not synchronize files implicitly.

## Features

- Upload and download individual files.
- Upload the current file after saving it.
- Batch-upload Git changes.
- Built-in commands and mappings.
- Passive health checks.

## Requirements

- Neovim with `vim.system()` support.
- `rsync` and `ssh` available in `PATH`.
- `git` available in `PATH` when `git_upload()` is used.

## Installation

The recommended setup uses an external remote-sync.nvim configuration file:

```lua
{
  "Oleg4cy/remote-sync.nvim",
  opts = {
    config = "lua/config/remote-sync.lua",
  },
}
```

### External config file

Relative paths are resolved from `vim.fn.stdpath("config")`, not from the current working directory. For example, when:

```lua
vim.fn.stdpath("config") == "/home/user/.config/nvim"
```

`config = "lua/config/remote-sync.lua"` resolves to `/home/user/.config/nvim/lua/config/remote-sync.lua`.

The external Lua file is a remote-sync.nvim configuration file loaded directly by the plugin. It must return a table:

```lua
return {
  projects = {
    ["/home/user/project"] = {
      host = "user@example.com",
      remote = "/var/www/project",
    },
  },
}
```

The table key is the local project root. `host` is the SSH destination, and `remote` is the corresponding remote project root. Nested configured roots use the nearest configured ancestor.

The file referenced by `opts.config` is loaded directly by remote-sync.nvim. The main Neovim configuration does not need to require it, call `dofile()` or `loadfile()`, inspect `fs_stat()`, extract projects manually, or define machine-specific loading helpers.

The config file must exist, be valid Lua, execute successfully, and return a table. It may contain `projects`, but it must not contain another `config` key or unknown setup keys.

### Absolute config path

Absolute paths are accepted unchanged:

```lua
{
  "Oleg4cy/remote-sync.nvim",
  opts = {
    config = "/home/user/.config/nvim/remote-sync.lua",
  },
}
```

### Inline configuration

Inline `projects` remain fully supported:

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

Choose either inline `projects` or an external `config` file. `projects` and `config` cannot be supplied together.

## Configuration

The setup API accepts exactly these options:

- `projects`: inline project definitions.
- `config`: a path to an external Lua configuration file.

For example:

```lua
require("remote-sync").setup({
  config = "lua/config/remote-sync.lua",
})
```

## Public API

```lua
require("remote-sync").setup(opts)
require("remote-sync").upload(file_path)
require("remote-sync").upload_current()
require("remote-sync").download(file_path)
require("remote-sync").git_upload(file_path)
```

`upload(file_path)` accepts an optional path; when omitted, it uses the current buffer path. It does not execute `:write`. `upload_current()` takes no path, executes `:write`, and then calls `upload()`; if `:write` fails, upload does not start. `download(file_path)` accepts an optional path and uses the current buffer path when omitted; it does not implicitly save. `git_upload(file_path)` also accepts an optional path and uses the current buffer path for project detection when omitted; it does not implicitly save.

`upload()` itself does not save; `upload_current()` is the save-and-upload action. After a successful download, the current buffer is reloaded only if the downloaded path is still the current buffer. External commands are launched asynchronously through `vim.system()`. There is no background polling or persistent worker.

## Built-in commands

- `:SyncUpload` calls `upload()`.
- `:SyncDownload` calls `download()`.
- `:SyncGitUpload` calls `git_upload()`.

`:SyncUpload` does not execute `:write`.

## Built-in mappings

- `<leader>ru` calls `<Plug>(RemoteSyncUpload)`, which calls `upload_current()` and saves the current buffer before uploading it.
- `<leader>rd` calls `<Plug>(RemoteSyncDownload)`, which calls `download()`.
- `<leader>rg` calls `<Plug>(RemoteSyncGitUpload)`, which calls `git_upload()`.

An already occupied original default lhs is not overwritten.

## Remapping with `<Plug>`

The stable mapping targets are:

- `<Plug>(RemoteSyncUpload)`
- `<Plug>(RemoteSyncDownload)`
- `<Plug>(RemoteSyncGitUpload)`

The built-in mappings use `hasmapto()` replacement semantics: define a mapping to the corresponding `<Plug>` target and the built-in mapping is not installed for that action.

For example:

```lua
vim.keymap.set(
  "n",
  "<leader>su",
  "<Plug>(RemoteSyncUpload)",
  { desc = "Remote Sync: Upload current file" }
)
```

The plugin checks `hasmapto()` before installing each original default. If this mapping is defined before `VimEnter`, `<leader>ru` is not created. This is a true replacement, not an alias. Upload, Download, and GitUpload are handled independently.

## Git batch behavior

Git batch upload uses:

```text
git status --porcelain=v1 -z --untracked-files=all
```

Modified paths, staged paths, and untracked paths are included. Locally deleted paths are skipped. For renames and copies, the destination/current path is uploaded; the old/source path is not remotely deleted. No remote deletion is performed. This is not a mirror or deployment system.

## Healthcheck

Run:

```vim
:Lazy load remote-sync.nvim
:checkhealth remote-sync
```

The healthcheck performs passive checks for `vim.system()`, `rsync`, `ssh`, `git`, and the configured project count. It does not contact remote servers, verify credentials, execute rsync, execute ssh, execute git, mutate configuration, or read arbitrary configuration files beyond already configured runtime state.

Using any configured remote-sync command or mapping first loads the plugin. After that, `:checkhealth remote-sync` works normally. The healthcheck does not discover the plugin before the lazy plugin is present in `runtimepath`.

## Tests

```sh
nvim --headless -u tests/minimal_init.lua -i NONE -l tests/remote_sync_spec.lua
```

The suite uses plain Neovim/Lua and requires no external testing framework. `minimal_init.lua` disables unrelated plugin loading.

## License

MIT
