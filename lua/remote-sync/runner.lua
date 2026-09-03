local M = {}

local DEFAULT_MAX_OUTPUT_BYTES = 64 * 1024

local SUPPORTED_OPTIONS = {
  cwd = true,
  env = true,
  max_output_bytes = true,
  on_stdout = true,
  on_stderr = true,
}

local function valid_array(argv)
  if type(argv) ~= "table" then
    return false
  end

  local length = #argv
  if length == 0 then
    return false
  end

  for index = 1, length do
    if type(argv[index]) ~= "string" or argv[index] == "" then
      return false
    end
  end

  for key in pairs(argv) do
    if type(key) ~= "number"
      or key < 1
      or key > length
      or key ~= math.floor(key)
    then
      return false
    end
  end

  return true
end

local function valid_max_output_bytes(value)
  return type(value) == "number"
    and value >= 0
    and value ~= math.huge
    and value == math.floor(value)
end

local function capture_stream(limit)
  local chunks = {}
  local size = 0
  local truncated = false

  local function append(chunk)
    local remaining = limit - size
    local chunk_size = #chunk

    if chunk_size <= remaining then
      if chunk_size > 0 then
        chunks[#chunks + 1] = chunk
        size = size + chunk_size
      end
    else
      truncated = true
      if remaining > 0 then
        chunks[#chunks + 1] = string.sub(chunk, 1, remaining)
        size = limit
      end
    end
  end

  return append, function()
    return table.concat(chunks), truncated
  end
end

function M.run(argv, opts, on_exit)
  if not valid_array(argv) then
    return nil, "argv must be a non-empty dense array of non-empty strings"
  end

  if opts ~= nil and type(opts) ~= "table" then
    return nil, "opts must be a table or nil"
  end

  if on_exit ~= nil and type(on_exit) ~= "function" then
    return nil, "on_exit must be a function or nil"
  end

  if opts ~= nil then
    for key in pairs(opts) do
      if not SUPPORTED_OPTIONS[key] then
        return nil, "unsupported option: " .. tostring(key)
      end
    end
  end

  local cwd = opts and opts.cwd
  if cwd ~= nil and (type(cwd) ~= "string" or cwd == "") then
    return nil, "opts.cwd must be a non-empty string or nil"
  end

  local env = opts and opts.env
  if env ~= nil and type(env) ~= "table" then
    return nil, "opts.env must be a table or nil"
  end

  local max_output_bytes = opts and opts.max_output_bytes
  if max_output_bytes == nil then
    max_output_bytes = DEFAULT_MAX_OUTPUT_BYTES
  elseif not valid_max_output_bytes(max_output_bytes) then
    return nil, "opts.max_output_bytes must be a non-negative integer or nil"
  end

  local on_stdout = opts and opts.on_stdout
  if on_stdout ~= nil and type(on_stdout) ~= "function" then
    return nil, "opts.on_stdout must be a function or nil"
  end

  local on_stderr = opts and opts.on_stderr
  if on_stderr ~= nil and type(on_stderr) ~= "function" then
    return nil, "opts.on_stderr must be a function or nil"
  end

  local capture_stdout, get_stdout = capture_stream(max_output_bytes)
  local capture_stderr, get_stderr = capture_stream(max_output_bytes)
  local stdout_callback_error
  local stderr_callback_error

  local stdout_error = nil
  local stderr_error = nil

  local function handle_stdout(err, chunk)
    if err ~= nil and stdout_error == nil then
      stdout_error = tostring(err)
    end

    if chunk == nil or chunk == "" then
      return
    end

    capture_stdout(chunk)
    if on_stdout and not stdout_callback_error then
      local ok, err = pcall(on_stdout, chunk)
      if not ok then
        stdout_callback_error = tostring(err)
        on_stdout = nil
      end
    end
  end

  local function handle_stderr(err, chunk)
    if err ~= nil and stderr_error == nil then
      stderr_error = tostring(err)
    end

    if chunk == nil or chunk == "" then
      return
    end

    capture_stderr(chunk)
    if on_stderr and not stderr_callback_error then
      local ok, err = pcall(on_stderr, chunk)
      if not ok then
        stderr_callback_error = tostring(err)
        on_stderr = nil
      end
    end
  end

  local system_opts = {
    text = true,
    stdout = handle_stdout,
    stderr = handle_stderr,
  }
  if cwd ~= nil then
    system_opts.cwd = cwd
  end
  if env ~= nil then
    system_opts.env = env
  end

  local function handle_exit(raw_result)
    local stdout, stdout_truncated = get_stdout()
    local stderr, stderr_truncated = get_stderr()
    local result = {
      code = raw_result.code,
      signal = raw_result.signal,
      stdout = stdout,
      stderr = stderr,
      stdout_truncated = stdout_truncated,
      stderr_truncated = stderr_truncated,
      stdout_error = stdout_error,
      stderr_error = stderr_error,
      stdout_callback_error = stdout_callback_error,
      stderr_callback_error = stderr_callback_error,
    }

    if on_exit then
      pcall(on_exit, result)
    end
  end

  local ok, process = pcall(vim.system, argv, system_opts, handle_exit)
  if not ok then
    return nil, tostring(process)
  end

  return process
end

return M
