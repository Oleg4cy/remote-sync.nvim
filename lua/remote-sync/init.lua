local M = {}

local function notify_error(message)
  vim.notify(message, vim.log.levels.ERROR, { title = "remote-sync" })
end

local function echo_line(line, highlight)
  vim.schedule(function()
    pcall(vim.api.nvim_echo, { { line, highlight } }, false, {})
  end)
end

local function echo_chunk(chunk, highlight)
  if type(chunk) ~= "string" or chunk == "" then
    return
  end

  for line in (chunk .. "\n"):gmatch("(.-)\r?\n") do
    if line ~= "" then
      echo_line(line, highlight)
    end
  end
end

local function last_nonempty_line(output)
  if type(output) ~= "string" or output == "" then
    return nil
  end

  local last
  for line in (output .. "\n"):gmatch("(.-)\r?\n") do
    if line ~= "" then
      last = line
    end
  end
  return last
end

local function stream_error(result)
  if type(result) ~= "table" then
    return nil
  end

  local fields = {
    "stdout_error",
    "stderr_error",
    "stdout_callback_error",
    "stderr_callback_error",
  }

  for _, field in ipairs(fields) do
    if result[field] ~= nil then
      return result[field]
    end
  end
  return nil
end

local function operation_callbacks(title, done, on_success)
  return {
    on_stdout = function(chunk)
      echo_chunk(chunk, "None")
    end,
    on_stderr = function(chunk)
      echo_chunk(chunk, "WarningMsg")
    end,
    on_exit = function(result)
      local callback_result = type(result) == "table" and result or {}
      local callback_error = stream_error(callback_result)
      local successful = callback_result.code == 0 and callback_error == nil

      if successful then
        echo_line(done, "MoreMsg")
        if on_success then
          pcall(on_success)
        end
        return
      end

      local message = title .. " error"
      if type(callback_result.code) == "number" then
        message = message .. ". Exit code: " .. tostring(callback_result.code)
      end
      echo_line(message, "ErrorMsg")

      local last = last_nonempty_line(callback_result.stderr)
        or last_nonempty_line(callback_result.stdout)
      if last == nil and callback_error ~= nil then
        last = tostring(callback_error)
      end
      if last ~= nil and last ~= "" then
        echo_line("Last output: " .. last, "ErrorMsg")
      end
    end,
  }
end

local function resolve_file_path(file_path)
  if file_path ~= nil and type(file_path) ~= "string" then
    local message = "file path must be a string"
    notify_error(message)
    return nil, message
  end

  local resolved = file_path
  if resolved == nil then
    resolved = vim.fn.expand("%:p")
  end

  if type(resolved) ~= "string" or not resolved:match("%S") then
    local message = "invalid file path"
    notify_error(message)
    return nil, message
  end
  return resolved
end

local function normalize_buffer_path(path)
  if type(path) ~= "string" then
    return nil
  end

  local expanded = vim.fn.expand(path)
  if type(expanded) ~= "string" then
    return nil
  end

  local absolute = vim.fn.fnamemodify(expanded, ":p")
  if type(absolute) ~= "string" then
    return nil
  end

  if absolute ~= "/" then
    absolute = absolute:gsub("/+$", "")
  end
  return absolute
end

local function start_error(title, err)
  if err == "project not found" then
    notify_error("Project not found")
    return nil, err
  end

  local message = title .. " failed to start: " .. tostring(err)
  notify_error(message)
  return nil, message
end

function M.setup(opts)
  if opts == nil then
    opts = {}
  end
  if type(opts) ~= "table" then
    return nil, "setup options must be a table"
  end

  for key in pairs(opts) do
    if key ~= "projects" then
      return nil, "unknown setup option: " .. tostring(key)
    end
  end

  local projects = opts.projects
  if projects == nil then
    projects = {}
  end

  local ok, err = require("remote-sync.config").set_projects(projects)
  if not ok then
    return nil, err
  end
  return true
end

function M.upload(file_path)
  local resolved, err = resolve_file_path(file_path)
  if not resolved then
    return nil, err
  end

  local system, start_err = require("remote-sync.operations").upload(
    resolved,
    operation_callbacks("Upload", "Upload done")
  )
  if system == nil then
    return start_error("Upload", start_err)
  end

  echo_line("Upload started", "MoreMsg")
  return system
end

function M.upload_current()
  vim.cmd("write")
  return M.upload()
end

function M.download(file_path)
  local resolved, err = resolve_file_path(file_path)
  if not resolved then
    return nil, err
  end

  vim.notify("Download...", vim.log.levels.INFO, { title = "remote-sync" })
  local requested_path = resolved
  local system, start_err = require("remote-sync.operations").download(
    resolved,
    operation_callbacks("Download", "Download done", function()
    vim.schedule(function()
      local current_path = normalize_buffer_path(vim.fn.expand("%:p"))
      local downloaded_path = normalize_buffer_path(requested_path)
      if current_path ~= nil and downloaded_path ~= nil and current_path == downloaded_path then
        pcall(vim.cmd, "edit!")
      end
    end)
end)
  )
  if system == nil then
    return start_error("Download", start_err)
  end

  echo_line("Download started", "MoreMsg")
  return system
end

function M.git_upload(file_path)
  local resolved, err = resolve_file_path(file_path)
  if not resolved then
    return nil, err
  end

  vim.notify("Syncing git changes...", vim.log.levels.INFO, { title = "remote-sync" })
  local system, start_err = require("remote-sync.git").upload(
    resolved,
    operation_callbacks("Git sync", "Git sync done")
  )
  if system == nil then
    return start_error("Git sync", start_err)
  end

  echo_line("Git sync started", "MoreMsg")
  return system
end

return M
