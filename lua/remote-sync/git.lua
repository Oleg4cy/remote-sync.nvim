local config = require("remote-sync.config")
local runner = require("remote-sync.runner")

local M = {}

local function failure_result(message, field, value)
  local result = {
    code = nil,
    signal = nil,
    stdout = "",
    stderr = tostring(message),
    stdout_truncated = false,
    stderr_truncated = false,
    stdout_error = nil,
    stderr_error = nil,
    stdout_callback_error = nil,
    stderr_callback_error = nil,
  }

  if field ~= nil then
    result[field] = value
  end

  return result
end

function M.upload(file_path, opts)
  if type(file_path) ~= "string" or not file_path:match("%S") then
    return nil, "file_path must be a non-whitespace string"
  end

  if opts ~= nil and type(opts) ~= "table" then
    return nil, "opts must be a table"
  end

  opts = opts or {}
  for key, value in pairs(opts) do
    if key ~= "on_stdout" and key ~= "on_stderr" and key ~= "on_exit" then
      return nil, "unknown option: " .. tostring(key)
    end
    if value ~= nil and type(value) ~= "function" then
      return nil, key .. " must be a function"
    end
  end

  local project = config.detect_project(file_path)
  if project == nil then
    return nil, "project not found"
  end

  local pending = ""
  local parse_error
  local expecting_source = false
  local selected = {}
  local selected_set = {}

  local function consume(record)
    if expecting_source then
      expecting_source = false
      if record == "" and parse_error == nil then
        parse_error = "malformed rename or copy source path"
      end
      return
    end

    if #record < 4 or record:sub(3, 3) ~= " " then
      if parse_error == nil then
        parse_error = "malformed git status record"
      end
      return
    end

    local status = record:sub(1, 2)
    local path = record:sub(4)
    if path == "" then
      if parse_error == nil then
        parse_error = "malformed git status path"
      end
      return
    end

    if status:sub(1, 1) == "R" or status:sub(2, 2) == "R"
      or status:sub(1, 1) == "C" or status:sub(2, 2) == "C" then
      expecting_source = true
    end

    if parse_error ~= nil or selected_set[path] then
      return
    end

    local local_path
    if project.root == "/" then
      local_path = "/" .. path
    else
      local_path = project.root .. "/" .. path
    end

    if vim.uv.fs_stat(local_path) ~= nil then
      selected_set[path] = true
      selected[#selected + 1] = path
    end
  end

  local function on_git_stdout(chunk)
    pending = pending .. chunk
    local start = 1
    while true do
      local finish = pending:find("\0", start, true)
      if finish == nil then
        pending = pending:sub(start)
        return
      end
      consume(pending:sub(start, finish - 1))
      start = finish + 1
    end
  end

  local function finish(result)
    if opts.on_exit ~= nil then
      pcall(opts.on_exit, result)
    end
  end

  local function on_git_exit(result)
    if result.code ~= 0 then
      finish(result)
      return
    end

    if result.stdout_error ~= nil then
      finish(failure_result(result.stdout_error, "stdout_error", result.stdout_error))
      return
    end

    if result.stdout_callback_error ~= nil then
      finish(failure_result(result.stdout_callback_error, "stdout_callback_error", result.stdout_callback_error))
      return
    end

    if parse_error ~= nil then
      finish(failure_result(parse_error))
      return
    end

    if expecting_source then
      finish(failure_result("incomplete rename or copy source record"))
      return
    end

    if pending ~= "" then
      finish(failure_result("incomplete git status record"))
      return
    end

    local file_list = table.concat(selected, "\0")
    if #selected > 0 then
      file_list = file_list .. "\0"
    end

    local ssh_command = "ssh -T -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o Compression=no -o ControlMaster=auto -o ControlPersist=30s -o ControlPath=~/.ssh/cm-%C"
    local _, rsync_error = runner.run({
      "rsync",
      "-azv",
      "--itemize-changes",
      "--files-from=-",
      "--from0",
      "--relative",
      "--compress-level=0",
      "-e",
      ssh_command,
      "./",
      project.host .. ":" .. project.remote,
  }, {
    cwd = project.root,
    stdin = file_list,
    on_stdout = opts.on_stdout,
    on_stderr = opts.on_stderr,
  }, opts.on_exit)

    if rsync_error ~= nil then
      finish(failure_result(rsync_error))
    end
  end

  local process, err = runner.run({
    "git",
    "status",
    "--porcelain=v1",
    "-z",
    "--untracked-files=all",
  }, {
    cwd = project.root,
    on_stdout = on_git_stdout,
    on_stderr = opts.on_stderr,
  }, on_git_exit)

  if process == nil then
    return nil, err
  end

  return process
end

return M
