local config = require("remote-sync.config")
local runner = require("remote-sync.runner")

local M = {}

local upload_ssh_command =
  "ssh -T -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o Compression=no -o ControlMaster=auto -o ControlPersist=30s -o ControlPath=~/.ssh/cm-%C"

local download_ssh_command =
  "ssh -T -o Compression=no -o ControlMaster=auto -o ControlPersist=30s -o ControlPath=~/.ssh/cm-%C"

local supported_options = {
  on_stdout = true,
  on_stderr = true,
  on_exit = true,
}

local function normalize_file_path(file_path)
  if type(file_path) ~= "string" or file_path:match("%S") == nil then
    return nil, "file path must be a non-empty string"
  end

  local path = vim.fn.expand(file_path)
  path = vim.fn.fnamemodify(path, ":p")

  while path ~= "/" and path:sub(-1) == "/" do
    path = path:sub(1, -2)
  end

  return path
end

local function validate_options(opts)
  if opts ~= nil and type(opts) ~= "table" then
    return nil, "opts must be a table"
  end

  opts = opts or {}

  for key, value in pairs(opts) do
    if not supported_options[key] then
      return nil, "unsupported option: " .. tostring(key)
    end

    if value ~= nil and type(value) ~= "function" then
      return nil, key .. " must be a function"
    end
  end

  return opts
end

local function relative_path(project_root, file_path)
  if type(project_root) ~= "string" or project_root == "" then
    return nil, "invalid project root"
  end

  local root = project_root
  while root ~= "/" and root:sub(-1) == "/" do
    root = root:sub(1, -2)
  end

  local relative
  if root == "/" then
    if file_path:sub(1, 1) ~= "/" then
      return nil, "file path is outside project root"
    end
    relative = file_path:sub(2)
  elseif file_path:sub(1, #root + 1) == root .. "/" then
    relative = file_path:sub(#root + 2)
  else
    return nil, "file path is outside project root"
  end

  if relative == "" then
    return nil, "relative file path is empty"
  end

  return relative
end

local function runner_options(opts, cwd)
  local result = {}

  if cwd ~= nil then
    result.cwd = cwd
  end
  if opts.on_stdout ~= nil then
    result.on_stdout = opts.on_stdout
  end
  if opts.on_stderr ~= nil then
    result.on_stderr = opts.on_stderr
  end

  return result
end

function M.upload(file_path, opts)
  local normalized_file_path, path_error = normalize_file_path(file_path)
  if not normalized_file_path then
    return nil, path_error
  end

  local validated_opts, options_error = validate_options(opts)
  if not validated_opts then
    return nil, options_error
  end

  local project = config.detect_project(normalized_file_path)
  if not project then
    return nil, "project not found"
  end

  local relative, relative_error = relative_path(project.root, normalized_file_path)
  if not relative then
    return nil, relative_error
  end

  local argv = {
    "rsync",
    "-rzv",
    "--itemize-changes",
    "--relative",
    "--compress-level=0",
    "--no-perms",
    "--no-owner",
    "--no-group",
    "--omit-dir-times",
    "-e",
    upload_ssh_command,
    "./" .. relative,
    project.host .. ":" .. project.remote,
  }

  return runner.run(argv, runner_options(validated_opts, project.root), validated_opts.on_exit)
end

function M.download(file_path, opts)
  local normalized_file_path, path_error = normalize_file_path(file_path)
  if not normalized_file_path then
    return nil, path_error
  end

  local validated_opts, options_error = validate_options(opts)
  if not validated_opts then
    return nil, options_error
  end

  local project = config.detect_project(normalized_file_path)
  if not project then
    return nil, "project not found"
  end

  local relative, relative_error = relative_path(project.root, normalized_file_path)
  if not relative then
    return nil, relative_error
  end

  local remote_file_path
  if project.remote == "/" then
    remote_file_path = "/" .. relative
  else
    remote_file_path = project.remote .. "/" .. relative
  end

  local argv = {
    "rsync",
    "-az",
    "--compress-level=0",
    "-e",
    download_ssh_command,
    project.host .. ":" .. remote_file_path,
    normalized_file_path,
  }

  return runner.run(argv, runner_options(validated_opts), validated_opts.on_exit)
end

return M
