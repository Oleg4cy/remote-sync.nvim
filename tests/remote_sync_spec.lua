local real_vim = vim
local repo_root = real_vim.fn.getcwd()

local function repo_file(path)
  return repo_root .. "/" .. path
end

local function load_with_fake_vim(path, fake_vim)
  local chunk = assert(loadfile(path))
  local env = setmetatable({ vim = fake_vim }, { __index = _G })
  setfenv(chunk, env)
  return chunk()
end

local function fail(message) error(message or "assertion failed", 2) end
local function equal(actual, expected, message)
  if actual ~= expected then
    fail((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end
local function truthy(value, message) if not value then fail(message or "expected truthy") end end
local function is_table(value) if type(value) ~= "table" then fail("expected table") end end
local function nonempty_string(value, message)
  if type(value) ~= "string" or value == "" then fail(message or "expected non-empty string") end
end
local function no_throw(fn, message)
  local ok, a, b = pcall(fn)
  if not ok then fail((message or "call threw") .. ": " .. tostring(a)) end
  return a, b
end
local function rejects(fn, message)
  local value, err = no_throw(fn, message)
  equal(value, nil, message or "expected rejection")
  nonempty_string(err, message or "expected rejection error")
end

local expand_calls = {}
local function fnamemodify(path, modifier)
  if modifier == ":p" then
    if path == "/" then return "/" end
    return (path:sub(1, 1) == "/" and "" or "/") .. path:gsub("/+", "/"):gsub("/$", "")
  end
  if modifier == ":h" then
    if path == "/" then return "/" end
    local clean = path:gsub("/+$", "")
    local parent = clean:match("^(.*)/[^/]*$")

    if parent == nil or parent == "" then
      return "/"
    end

    return parent
  end
  return path
end
local config_vim = { fn = {
  expand = function(path)
    expand_calls[#expand_calls + 1] = path
    if path == "~/project" or path == "~/project/" then return "/home/test/project" end
    return path
  end,
  fnamemodify = fnamemodify,
} }
local config = load_with_fake_vim(repo_file("lua/remote-sync/config.lua"), config_vim)

local initial = config.get_projects(); is_table(initial); equal(next(initial), nil)
equal(no_throw(function() return config.detect_project("/project/file.php") end), nil)

local invalid = {
  1, { [1] = { host = "h", remote = "/r" } }, { [""] = { host = "h", remote = "/r" } },
  { ["   "] = { host = "h", remote = "/r" } }, { ["/r"] = 1 }, { ["/r"] = { remote = "/r" } },
  { ["/r"] = { host = 1, remote = "/r" } }, { ["/r"] = { host = "   ", remote = "/r" } },
  { ["/r"] = { host = "h" } }, { ["/r"] = { host = "h", remote = 1 } },
  { ["/r"] = { host = "h", remote = "   " } },
}
for _, value in ipairs(invalid) do rejects(function() return config.set_projects(value) end) end
rejects(function() return config.set_projects(false) end)

local valid = { ["~/project/"] = { host = " host ", remote = "/var/www/project/" } }
equal(config.set_projects(valid), true)
local stored = config.get_projects()
equal(stored["/home/test/project"].host, " host "); equal(stored["/home/test/project"].remote, "/var/www/project")
equal(stored["/home/test/project"].root, "/home/test/project")
rejects(function() return config.set_projects({ ["/bad"] = { host = "h" } }) end)
equal(config.get_projects()["/home/test/project"].host, " host "); equal(config.get_projects()["/home/test/project"].remote, "/var/www/project")
valid["~/project/"].host = "changed"; valid["~/project/"].remote = "changed"; valid["/new"] = { host = "new", remote = "/new" }
equal(config.get_projects()["/home/test/project"].host, " host "); equal(config.get_projects()["/new"], nil)
local returned = config.get_projects(); returned["/home/test/project"].host = "changed"; returned["/new"] = {}
equal(config.get_projects()["/home/test/project"].host, " host "); equal(config.get_projects()["/new"], nil)
truthy(#expand_calls >= 1)

local expand_count_before = #expand_calls
equal(config.set_projects({ ["/"] = { host = "h", remote = "~/remote/" } }), true)
local root_project = config.get_projects()["/"]
equal(root_project.root, "/")
equal(root_project.remote, "~/remote")
local root_was_expanded = false
local remote_was_expanded = false
for index = expand_count_before + 1, #expand_calls do
  root_was_expanded = root_was_expanded or expand_calls[index] == "/"
  remote_was_expanded = remote_was_expanded or expand_calls[index] == "~/remote/"
end
truthy(root_was_expanded)
equal(remote_was_expanded, false)
equal(config.set_projects({ ["/work/project"] = { host = "parent", remote = "/parent" }, ["/work/project/subproject"] = { host = "nested", remote = "/nested" } }), true)
equal(config.detect_project("/work/project/file.php").host, "parent")
equal(config.detect_project("/work/project/src/deep/file.php").host, "parent")
equal(config.detect_project("/work/project/subproject/file.php").host, "nested")
equal(config.detect_project("/work/project/subproject/src/file.php").host, "nested")
equal(config.detect_project("/outside/file.php"), nil)
for _, value in ipairs({ false, 123, {}, "", "   " }) do equal(no_throw(function() return config.detect_project(value) end), nil) end
equal(no_throw(function() return config.detect_project(nil) end), nil)
local detected = config.detect_project("/work/project/file.php"); detected.host = "x"; detected.remote = "y"; detected.root = "z"
local detected_again = config.detect_project("/work/project/file.php")
equal(detected_again.host, "parent"); equal(detected_again.remote, "/parent"); equal(detected_again.root, "/work/project")
equal(config.set_projects({ ["/"] = { host = "root", remote = "/" } }), true)
equal(config.detect_project("/outside/file.php").host, "root")

local calls, system_error, fake_object = {}, nil, {}
local runner_vim = { system = function(argv, opts, on_exit)
  if system_error then error(system_error) end
  calls[#calls + 1] = { argv = argv, opts = opts, on_exit = on_exit }; return fake_object
end }
local runner = load_with_fake_vim(repo_file("lua/remote-sync/runner.lua"), runner_vim)
local function run_reject(argv, opts, on_exit)
  rejects(function() return runner.run(argv, opts, on_exit) end); equal(#calls, 0)
end
for _, argv in ipairs({ false, {}, { [2] = "cmd" }, { [1] = "cmd", x = "y" }, { [0] = "cmd" }, { [1.5] = "cmd" }, { [1] = 1 }, { [1] = "" } }) do run_reject(argv, {}) end
run_reject({ "cmd" }, { text = true }); run_reject({ "cmd" }, false); run_reject({ "cmd" }, { on_exit = function() end }); run_reject({ "cmd" }, {}, 123)
for _, key in ipairs({ "cwd", "env", "on_stdout", "on_stderr", "stdin" }) do run_reject({ "cmd" }, { [key] = false }) end
for _, value in ipairs({ -1, 1.5, "10", false, math.huge }) do run_reject({ "cmd" }, { max_output_bytes = value }) end

local nil_opts_result = no_throw(function() return runner.run({ "cmd" }, nil) end)
equal(nil_opts_result, fake_object)
equal(calls[#calls].opts.text, true)
truthy(type(calls[#calls].on_exit) == "function")
equal(no_throw(function() return runner.run({ "cmd" }, {}, nil) end), fake_object)
local empty_stdin_result = runner.run({ "cmd" }, { stdin = "" })
equal(empty_stdin_result, fake_object)
equal(calls[#calls].opts.stdin, "")

local events, exit_value = {}, nil
equal(runner.run({ "git", "status" }, { cwd = "/tmp", env = { X = "1" }, stdin = "one\0two\0", max_output_bytes = 2,
  on_stdout = function(chunk) events[#events + 1] = { "out", chunk } end,
  on_stderr = function(chunk) events[#events + 1] = { "err", chunk } end,
}, function(value) exit_value = value end), fake_object)
local call = calls[#calls]; equal(call.argv[1], "git"); equal(call.argv[2], "status"); equal(call.opts.text, true); equal(call.opts.cwd, "/tmp"); equal(call.opts.env.X, "1"); equal(call.opts.stdin, "one\0two\0")
call.opts.stdout(nil, "abcdef"); call.opts.stderr(nil, "warning"); call.on_exit({ code = 7, signal = 15 })
equal(exit_value.code, 7); equal(exit_value.signal, 15); equal(exit_value.stdout, "ab"); equal(exit_value.stderr, "wa"); equal(exit_value.stdout_truncated, true); equal(exit_value.stderr_truncated, true); equal(events[1][2], "abcdef"); equal(events[2][2], "warning")
local allowed = { code = true, signal = true, stdout = true, stderr = true, stdout_truncated = true, stderr_truncated = true, stdout_error = true, stderr_error = true, stdout_callback_error = true, stderr_callback_error = true }
for key in pairs(exit_value) do truthy(allowed[key], "unexpected result field " .. tostring(key)) end

local function bounded(stream, chunks, limit, expected, was_truncated)
  local seen, result = {}, nil
  runner.run({ "cmd" }, { max_output_bytes = limit, [stream == "stdout" and "on_stdout" or "on_stderr"] = function(chunk) seen[#seen + 1] = chunk end }, function(value) result = value end)
  local c = calls[#calls]; for _, chunk in ipairs(chunks) do c.opts[stream](nil, chunk) end; c.on_exit({ code = 0, signal = 0 })
  equal(result[stream], expected); equal(result[stream .. "_truncated"], was_truncated); return seen
end
bounded("stdout", { "a", "b" }, 2, "ab", false); bounded("stdout", { "abc" }, 2, "ab", true); bounded("stderr", { "x", "y" }, 2, "xy", false); bounded("stderr", { "xyz" }, 2, "xy", true); bounded("stdout", { "abc" }, 0, "", true)
local seen = bounded("stdout", { "abcdef" }, 2, "ab", true); equal(seen[1], "abcdef"); seen = bounded("stderr", { "abcdef" }, 2, "ab", true); equal(seen[1], "abcdef")

local default_result
runner.run({ "cmd" }, {}, function(value) default_result = value end)
local default_call = calls[#calls]
default_call.opts.stdout(nil, string.rep("a", 64 * 1024))
default_call.on_exit({ code = 0, signal = 0 })
equal(#default_result.stdout, 64 * 1024); equal(default_result.stdout_truncated, false)
runner.run({ "cmd" }, {}, function(value) default_result = value end)
default_call = calls[#calls]
default_call.opts.stdout(nil, string.rep("b", 64 * 1024 + 1))
default_call.on_exit({ code = 0, signal = 0 })
equal(#default_result.stdout, 64 * 1024); equal(default_result.stdout_truncated, true)

local independent_result
runner.run({ "cmd" }, { max_output_bytes = 2 }, function(value) independent_result = value end)
local independent = calls[#calls]
independent.opts.stdout(nil, "abcd"); independent.opts.stderr(nil, "xy"); independent.on_exit({ code = 0, signal = 0 })
equal(independent_result.stdout, "ab"); equal(independent_result.stdout_truncated, true)
equal(independent_result.stderr, "xy"); equal(independent_result.stderr_truncated, false)
runner.run({ "cmd" }, { max_output_bytes = 2 }, function(value) independent_result = value end)
independent = calls[#calls]
independent.opts.stdout(nil, "xy"); independent.opts.stderr(nil, "abcd"); independent.on_exit({ code = 0, signal = 0 })
equal(independent_result.stdout, "xy"); equal(independent_result.stdout_truncated, false)
equal(independent_result.stderr, "ab"); equal(independent_result.stderr_truncated, true)

local empty_calls, empty_result = 0, nil
runner.run({ "cmd" }, { on_stdout = function() empty_calls = empty_calls + 1 end, on_stderr = function() empty_calls = empty_calls + 1 end }, function(value) empty_result = value end)
local empty = calls[#calls]; empty.opts.stdout(nil, nil); empty.opts.stdout(nil, ""); empty.opts.stderr(nil, nil); empty.opts.stderr(nil, ""); empty.on_exit({ code = 0, signal = 0 })
equal(empty_calls, 0); equal(empty_result.stdout, ""); equal(empty_result.stderr, ""); equal(empty_result.stdout_truncated, false); equal(empty_result.stderr_truncated, false)

local out_n, err_n, callback_result = 0, 0, nil
  runner.run({ "cmd" }, { max_output_bytes = 10, on_stdout = function() out_n = out_n + 1; error("out failure", 0) end, on_stderr = function() err_n = err_n + 1; error("err failure", 0) end }, function(value) callback_result = value end)
local failing = calls[#calls]; failing.opts.stdout(nil, "a"); failing.opts.stdout(nil, "b"); failing.opts.stderr(nil, "x"); failing.opts.stderr(nil, "y"); failing.on_exit({ code = 0, signal = 0 })
equal(out_n, 1); equal(err_n, 1); equal(callback_result.stdout_callback_error, "out failure"); equal(callback_result.stderr_callback_error, "err failure"); equal(callback_result.stdout, "ab"); equal(callback_result.stderr, "xy")

local only_out_n, only_err_n, only_one_result = 0, 0, nil
  runner.run({ "cmd" }, { on_stdout = function() only_out_n = only_out_n + 1; error("only out failure", 0) end, on_stderr = function() only_err_n = only_err_n + 1 end }, function(value) only_one_result = value end)
local only_out = calls[#calls]
only_out.opts.stdout(nil, "a"); only_out.opts.stdout(nil, "b"); only_out.opts.stderr(nil, "x"); only_out.opts.stderr(nil, "y"); only_out.on_exit({ code = 0, signal = 0 })
equal(only_out_n, 1); equal(only_one_result.stdout_callback_error, "only out failure"); equal(only_one_result.stdout, "ab")
equal(only_err_n, 2); equal(only_one_result.stderr_callback_error, nil); equal(only_one_result.stderr, "xy")

local stream_result
runner.run({ "cmd" }, { on_stdout = function() end, on_stderr = function() end }, function(value) stream_result = value end)
local stream = calls[#calls]; stream.opts.stdout("read error", "abc"); stream.opts.stdout("second", nil); stream.opts.stderr("err", "xy"); stream.opts.stderr("second stderr", nil); stream.on_exit({ code = 0, signal = 0 })
equal(stream_result.stdout_error, "read error"); equal(stream_result.stdout, "abc"); equal(stream_result.stderr_error, "err"); equal(stream_result.stderr, "xy")

local exit_count = 0
runner.run({ "cmd" }, {}, function() exit_count = exit_count + 1; error("exit failure") end); calls[#calls].on_exit({ code = 1, signal = 2 }); equal(exit_count, 1)
system_error = "system failure"; local value, err = no_throw(function() return runner.run({ "cmd" }, {}) end); equal(value, nil); nonempty_string(err); equal(exit_count, 1)

-- 4.8.2a: standalone coverage for the production operations module.
do
  local vim_ref = _G.vim
  local old_expand = vim_ref.fn.expand
  local old_fnamemodify = vim_ref.fn.fnamemodify
  local old_config = package.loaded["remote-sync.config"]
  local old_runner = package.loaded["remote-sync.runner"]

  local calls = {}
  local detected_paths = {}
  local fake_process = {}
  local detect_result = {
    root = "/project",
    host = "deploy@example.com",
    remote = "/var/www/project",
  }
  local runner_result = fake_process
  local runner_error

  local fake_config = {
    detect_project = function(file_path)
      detected_paths[#detected_paths + 1] = file_path
      return detect_result
    end,
  }
  local fake_runner = {
    run = function(argv, opts, on_exit)
      calls[#calls + 1] = { argv = argv, opts = opts, on_exit = on_exit }
      return runner_result, runner_error
    end,
  }

  local function reset(result)
    calls = {}
    detected_paths = {}
    detect_result = result or {
      root = "/project",
      host = "deploy@example.com",
      remote = "/var/www/project",
    }
    runner_result = fake_process
    runner_error = nil
  end

  local function array_equal(actual, expected)
    assert(#actual == #expected, "argv length mismatch")
    for i = 1, #expected do
      assert(actual[i] == expected[i], "argv item mismatch at " .. i)
    end
  end

  local function no_unexpected_opts(opts, expected)
    for key in pairs(opts) do
      assert(expected[key], "unexpected runner option: " .. key)
    end
  end

  local function rejected(call, message)
    local ok, a, b = pcall(call)
    assert(ok, message .. " threw")
    assert(a == nil and type(b) == "string" and b ~= "", message .. " was not rejected")
  end

  local function assert_not_called(message)
    assert(#calls == 0, message .. " called runner")
    assert(#detected_paths == 0, message .. " called config")
  end

  vim_ref.fn.expand = function(path) return path end
  vim_ref.fn.fnamemodify = function(path, modifier)
    assert(modifier == ":p")
    if path == "/" then return path end
    return (path:gsub("/+$", ""))
  end

  package.loaded["remote-sync.config"] = fake_config
  package.loaded["remote-sync.runner"] = fake_runner
  package.loaded["remote-sync.operations"] = nil
  local operations = require("remote-sync.operations")

  local stdout_cb = function() end
  local stderr_cb = function() end
  local exit_cb = function() end
  reset()
  local process = operations.upload("/project/dir/file.php", {
    on_stdout = stdout_cb, on_stderr = stderr_cb, on_exit = exit_cb,
  })
  assert(process == fake_process)
  assert(detected_paths[1] == "/project/dir/file.php")
  array_equal(calls[1].argv, {
    "rsync", "-rzv", "--itemize-changes", "--relative", "--compress-level=0",
    "--no-perms", "--no-owner", "--no-group", "--omit-dir-times", "-e",
    "ssh -T -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o Compression=no -o ControlMaster=auto -o ControlPersist=30s -o ControlPath=~/.ssh/cm-%C",
    "./dir/file.php", "deploy@example.com:/var/www/project",
  })
  assert(calls[1].opts.cwd == "/project")
  assert(calls[1].opts.on_stdout == stdout_cb and calls[1].opts.on_stderr == stderr_cb)
  assert(calls[1].opts.on_exit == nil and calls[1].on_exit == exit_cb)
  no_unexpected_opts(calls[1].opts, { cwd = true, on_stdout = true, on_stderr = true })

  reset(); runner_result, runner_error = nil, "start failure"
  local upload_process, upload_error = operations.upload("/project/dir/file.php", nil)
  assert(upload_process == nil and upload_error == "start failure")

  reset(); runner_result, runner_error = nil, "download start failure"
  local download_process, download_error = operations.download("/project/dir/file.php", nil)
  assert(download_process == nil and download_error == "download start failure")

  reset({ root = "/", host = "root-host", remote = "/remote" })
  operations.upload("/dir/file.php", nil)
  array_equal(calls[1].argv, {
    "rsync", "-rzv", "--itemize-changes", "--relative", "--compress-level=0",
    "--no-perms", "--no-owner", "--no-group", "--omit-dir-times", "-e",
    "ssh -T -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o Compression=no -o ControlMaster=auto -o ControlPersist=30s -o ControlPath=~/.ssh/cm-%C",
    "./dir/file.php", "root-host:/remote",
  })
  assert(calls[1].opts.cwd == "/")

  reset()
  process = operations.download("/project/dir/file.php", {
    on_stdout = stdout_cb, on_stderr = stderr_cb, on_exit = exit_cb,
  })
  assert(process == fake_process)
  array_equal(calls[1].argv, {
    "rsync", "-az", "--compress-level=0", "-e",
    "ssh -T -o Compression=no -o ControlMaster=auto -o ControlPersist=30s -o ControlPath=~/.ssh/cm-%C",
    "deploy@example.com:/var/www/project/dir/file.php", "/project/dir/file.php",
  })
  assert(not calls[1].argv[5]:find("BatchMode=yes", 1, true))
  assert(not calls[1].argv[5]:find("ConnectTimeout=10", 1, true))
  assert(calls[1].opts.on_stdout == stdout_cb and calls[1].opts.on_stderr == stderr_cb)
  assert(calls[1].opts.cwd == nil and calls[1].opts.on_exit == nil and calls[1].on_exit == exit_cb)
  no_unexpected_opts(calls[1].opts, { on_stdout = true, on_stderr = true })

  reset({ root = "/project", host = "deploy@example.com", remote = "/" })
  operations.download("/project/dir/file.php", nil)
  assert(calls[1].argv[6] == "deploy@example.com:/dir/file.php")
  reset({ root = "/", host = "root-host", remote = "/remote" })
  operations.download("/dir/file.php", nil)
  assert(calls[1].argv[6] == "root-host:/remote/dir/file.php" and calls[1].argv[7] == "/dir/file.php")

  reset({ root = "/project/", host = "host", remote = "/remote" })
  operations.upload("/project/dir/file.php", nil)
  assert(calls[1].argv[12] == "./dir/file.php" and calls[1].opts.cwd == "/project/")

  reset()
  rejected(function() return operations.upload(nil, nil) end, "nil upload path")
  assert_not_called("nil upload path")
  reset()
  rejected(function() return operations.download(nil, nil) end, "nil download path")
  assert_not_called("nil download path")

  local invalid_paths = { false, 123, {}, "", "   " }
  for _, path in ipairs(invalid_paths) do
    reset()
    rejected(function() return operations.upload(path, nil) end, "invalid upload path")
    assert_not_called("invalid upload path")
    reset()
    rejected(function() return operations.download(path, nil) end, "invalid download path")
    assert_not_called("invalid download path")
  end

  local invalid_opts = {
    false, "bad", { unknown = true }, { on_stdout = true },
    { on_stderr = "bad" }, { on_exit = 123 },
  }
  for _, opts in ipairs(invalid_opts) do
    reset(); rejected(function() return operations.upload("/project/file.php", opts) end, "invalid upload opts"); assert_not_called("invalid upload opts")
    reset(); rejected(function() return operations.download("/project/file.php", opts) end, "invalid download opts"); assert_not_called("invalid download opts")
  end

  reset(); detect_result = nil
  local result, err = operations.upload("/project/file.php", nil)
  assert(result == nil and err == "project not found"); assert(#calls == 0)
  reset(); detect_result = nil
  result, err = operations.download("/project/file.php", nil)
  assert(result == nil and err == "project not found"); assert(#calls == 0)

for _, method in ipairs({ "upload", "download" }) do
  reset({ root = "/different-project", host = "host", remote = "/remote" })
  rejected(function() return operations[method]("/project/file.php", nil) end, "outside project root")
  assert(#calls == 0, "outside project root called runner")
  assert(#detected_paths == 1, "outside project root config call count mismatch")
  assert(detected_paths[1] == "/project/file.php", "outside project root config path mismatch")

  reset({ root = "/project", host = "host", remote = "/remote" })
  rejected(function() return operations[method]("/project", nil) end, "project root file")
  assert(#calls == 0, "project root file called runner")
  assert(#detected_paths == 1, "project root file config call count mismatch")
  assert(detected_paths[1] == "/project", "project root file config path mismatch")
end

  package.loaded["remote-sync.operations"] = nil
  package.loaded["remote-sync.config"] = old_config
  package.loaded["remote-sync.runner"] = old_runner
  vim_ref.fn.expand = old_expand
  vim_ref.fn.fnamemodify = old_fnamemodify
end

print("remote-sync tests: OK")
