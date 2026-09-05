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

do
  local saved_config = package.loaded["remote-sync.config"]
  local saved_runner = package.loaded["remote-sync.runner"]
  local saved_git = package.loaded["remote-sync.git"]
  local saved_uv = vim.uv

  local existing = {}
  local stat_paths = {}
  local detected = {}
  local calls = {}
  local project = { root = "/project", host = "deploy@example.com", remote = "/var/www/project" }
  local git_process = {}
  local rsync_process = {}
  local public_stdout = function() end
  local public_stderr = function() end
  local public_exit = function() end

  vim.uv = {
    fs_stat = function(path)
      stat_paths[#stat_paths + 1] = path
      if existing[path] then return { type = "file" } end
      return nil
    end,
  }

  local fake_config = {
    detect_project = function(file_path)
      detected[#detected + 1] = file_path
      return project
    end,
  }
  local fake_runner = {
    run = function(argv, opts, on_exit)
      calls[#calls + 1] = { argv = argv, opts = opts, on_exit = on_exit }
      if #calls == 1 then return git_process end
      return rsync_process
    end,
  }
  package.loaded["remote-sync.config"] = fake_config
  package.loaded["remote-sync.runner"] = fake_runner
  package.loaded["remote-sync.git"] = nil
  local git = require("remote-sync.git")

  local function success_result()
    return {
      code = 0, signal = 0, stdout = "", stderr = "",
      stdout_truncated = false, stderr_truncated = false,
      stdout_error = nil, stderr_error = nil,
      stdout_callback_error = nil, stderr_callback_error = nil,
    }
  end

  local function reset(root, host, remote, paths)
    calls, detected, stat_paths = {}, {}, {}
    existing = {}
    for _, path in ipairs(paths or {}) do existing[path] = true end
    project = { root = root or "/project", host = host or "deploy@example.com", remote = remote or "/var/www/project" }
    git_process, rsync_process = {}, {}
  end

  local function eq(actual, expected)
    assert(actual == expected, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
  local function argv_eq(actual, expected)
    eq(#actual, #expected)
    for i = 1, #expected do eq(actual[i], expected[i]) end
  end
  local function upload(stream, opts, chunks)
    local process = git.upload("/project/current.php", opts or {
      on_stdout = public_stdout, on_stderr = public_stderr, on_exit = public_exit,
    })
    eq(process, git_process)
    local first = calls[1]
    if chunks then
      for _, chunk in ipairs(chunks) do first.opts.on_stdout(chunk) end
    else
      first.opts.on_stdout(stream)
    end
    first.on_exit(success_result())
    eq(#calls, 2)
    return calls[1], calls[2]
  end

  reset("/project", "deploy@example.com", "/var/www/project", {
    "/project/modified.php", "/project/staged.php", "/project/new file.php",
  })
  local first, second = upload(" M modified.php\0M  staged.php\0?? new file.php\0")
  eq(detected[1], "/project/current.php")
  argv_eq(first.argv, { "git", "status", "--porcelain=v1", "-z", "--untracked-files=all" })
  eq(first.opts.cwd, "/project")
  assert(type(first.opts.on_stdout) == "function")
  assert(first.opts.on_stdout ~= public_stdout)
  eq(first.opts.on_stderr, public_stderr)
  assert(type(first.on_exit) == "function")
  argv_eq(second.argv, {
    "rsync", "-azv", "--itemize-changes", "--files-from=-", "--from0", "--relative",
    "--compress-level=0", "-e",
    "ssh -T -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o Compression=no -o ControlMaster=auto -o ControlPersist=30s -o ControlPath=~/.ssh/cm-%C",
    "./", "deploy@example.com:/var/www/project",
  })
  eq(second.opts.cwd, "/project")
  eq(second.opts.stdin, "modified.php\0staged.php\0new file.php\0")
  eq(second.opts.on_stdout, public_stdout)
  eq(second.opts.on_stderr, public_stderr)
  eq(second.on_exit, public_exit)
  assert(second.opts.on_exit == nil and second.opts.env == nil and second.opts.max_output_bytes == nil)

  reset("/project", "deploy@example.com", "/var/www/project", { "/project/exists.php", "/project/new.php" })
  _, second = upload(" M exists.php\0 M deleted.php\0?? new.php\0")
  eq(second.opts.stdin, "exists.php\0new.php\0")

  reset("/", "root-host", "/remote", { "/dir/file.php" })
  _, second = upload(" M dir/file.php\0")
  eq(stat_paths[1], "/dir/file.php")
  assert(stat_paths[1] ~= "//dir/file.php")
  eq(second.opts.cwd, "/")
  eq(second.argv[#second.argv], "root-host:/remote")

  reset("/project", "deploy@example.com", "/var/www/project", {})
  _, second = upload(" M deleted.php\0")
  eq(second.opts.stdin, "")

  reset("/project", "deploy@example.com", "/var/www/project", { "/project/dup.php" })
  _, second = upload(" M dup.php\0M  dup.php\0?? dup.php\0")
  eq(second.opts.stdin, "dup.php\0")

  local names = { "dir/file with spaces.php", "dir/tab\tname.php", "dir/quote\"name.php", "dir/back\\slash.php", "dir/new\nline.php" }
  local stream, expected = "", ""
  reset("/project", "deploy@example.com", "/var/www/project", {})
  for _, name in ipairs(names) do
    existing["/project/" .. name] = true
    stream = stream .. " M " .. name .. "\0"
    expected = expected .. name .. "\0"
  end
  _, second = upload(stream)
  eq(second.opts.stdin, expected)

  reset("/project", "deploy@example.com", "/var/www/project", { "/project/alpha.php", "/project/beta file.php" })
  _, second = upload(nil, nil, { " M", " alpha", ".php\0?? beta file.php", "\0" })
  eq(second.opts.stdin, "alpha.php\0beta file.php\0")

  reset("/project", "deploy@example.com", "/var/www/project", { "/project/new/name.php", "/project/new2.php", "/project/copy-new.php", "/project/copy-new2.php" })
  _, second = upload("R  new/name.php\0old name.php\0 R new2.php\0old2.php\0C  copy-new.php\0copy old.php\0 C copy-new2.php\0copy-old2.php\0")
  eq(second.opts.stdin, "new/name.php\0new2.php\0copy-new.php\0copy-new2.php\0")
  assert(not (function()
    for _, p in ipairs(stat_paths) do if p == "/project/old name.php" then return true end end
  end)())

  reset("/project", "deploy@example.com", "/var/www/project", {
    "/project/modified.php", "/project/new/name.php", "/project/new.php", "/project/copy.php", "/project/another.php",
  })
  _, second = upload(" M modified.php\0R  new/name.php\0old name.php\0?? new.php\0C  copy.php\0old\\source.php\0 M another.php\0")
  eq(second.opts.stdin, "modified.php\0new/name.php\0new.php\0copy.php\0another.php\0")

  package.loaded["remote-sync.config"] = saved_config
  package.loaded["remote-sync.runner"] = saved_runner
  package.loaded["remote-sync.git"] = saved_git
  vim.uv = saved_uv
end

do
  local saved_config = package.loaded["remote-sync.config"]
  local saved_runner = package.loaded["remote-sync.runner"]
  local saved_git = package.loaded["remote-sync.git"]
  local saved_stat = vim.uv.fs_stat
  local calls, detected, stat_paths = {}, {}, {}
  local existing = {}
  local project = {
    root = "/project",
    host = "deploy@example.com",
    remote = "/var/www/project",
  }
  local git_process, rsync_process = {}, {}
  local git
  local git_start_error, rsync_start_error, project_not_found
  local exit_count, exit_value

  local function check(value, message)
    assert(value, message or "assertion failed")
  end
  local function eq(actual, expected, message)
    assert(actual == expected, message or (tostring(actual) .. " ~= " .. tostring(expected)))
  end
  local function reset()
    calls, detected, stat_paths = {}, {}, {}
    existing, project_not_found = {}, nil
    git_start_error, rsync_start_error = nil, nil
    exit_count, exit_value = 0, nil
  end
  local function success_result()
    return {
      code = 0, signal = 0, stdout = "", stderr = "",
      stdout_truncated = false, stderr_truncated = false,
      stdout_error = nil, stderr_error = nil,
      stdout_callback_error = nil, stderr_callback_error = nil,
    }
  end
  local function public_exit(result)
    exit_count, exit_value = exit_count + 1, result
  end
  local function reject(file_path, opts)
    reset()
    local ok, a, b = pcall(git.upload, file_path, opts)
    check(ok)
    eq(a, nil)
    check(type(b) == "string" and b ~= "")
    eq(#detected, 0)
    eq(#calls, 0)
  end
  local function start(stdout, result, opts)
    reset()
    local process = git.upload("/project/current.php", opts or { on_exit = public_exit })
    eq(process, git_process)
    eq(#detected, 1)
    eq(#calls, 1)
    if stdout then calls[1].opts.on_stdout(stdout) end
    calls[1].on_exit(result or success_result())
    return calls[1]
  end
  local function parser_failure(stdout, message)
    local call = start(stdout, success_result())
    eq(#calls, 1)
    eq(exit_count, 1)
    eq(exit_value.stderr, message)
    return call
  end

  package.loaded["remote-sync.config"] = {
    detect_project = function(path)
      detected[#detected + 1] = path
      if project_not_found then return nil end
      return project
    end,
  }
  package.loaded["remote-sync.runner"] = {
    run = function(argv, opts, on_exit)
      calls[#calls + 1] = { argv = argv, opts = opts, on_exit = on_exit }
      if #calls == 1 and git_start_error then return nil, git_start_error end
      if #calls == 2 and rsync_start_error then return nil, rsync_start_error end
      return (#calls == 1) and git_process or rsync_process
    end,
  }
  package.loaded["remote-sync.git"] = nil
  git = require("remote-sync.git")
  vim.uv.fs_stat = function(path)
    stat_paths[#stat_paths + 1] = path
    return existing[path] and { type = "file" } or nil
  end

  reject(nil, nil)
  for _, value in ipairs({ false, 123, {}, "", "   " }) do reject(value, nil) end
  for _, value in ipairs({ false, 123, "bad" }) do reject("/project/current.php", value) end
  reject("/project/current.php", { unknown = true })
  reject("/project/current.php", { cwd = "/tmp" })
  reject("/project/current.php", { on_stdout = true })
  reject("/project/current.php", { on_stderr = "bad" })
  reject("/project/current.php", { on_exit = 123 })

  reset()
  eq(git.upload("/project/current.php", nil), git_process)
  eq(#detected, 1)
  eq(#calls, 1)

  reset(); project_not_found = true
  local ok, value, err = pcall(git.upload, "/project/current.php", nil)
  check(ok); eq(value, nil); eq(err, "project not found"); eq(#detected, 1)
  eq(detected[1], "/project/current.php"); eq(#calls, 0)

  reset(); git_start_error = "git start failure"
  ok, value, err = pcall(git.upload, "/project/current.php", { on_exit = public_exit })
  check(ok); eq(value, nil); eq(err, "git start failure"); eq(#calls, 1); eq(exit_count, 0)

  local failure = { code = 1, signal = 0, stdout = "", stderr = "git failed",
    stdout_truncated = false, stderr_truncated = false, stdout_error = nil,
    stderr_error = nil, stdout_callback_error = nil, stderr_callback_error = nil }
  start(nil, failure); eq(#calls, 1); eq(exit_value, failure)
  reset(); local throwing_exit = function() error("public exit failure", 0) end
  local first = git.upload("/project/current.php", { on_exit = throwing_exit }); eq(first, git_process)
  calls[1].on_exit(failure); eq(#calls, 1)

  local function stream_failure(field, message)
    local result = success_result(); result[field] = message
    start(nil, result)
    eq(#calls, 1); eq(exit_count, 1); eq(exit_value.code, nil); eq(exit_value.signal, nil)
    eq(exit_value.stdout, ""); eq(exit_value.stderr, message)
    eq(exit_value.stdout_truncated, false); eq(exit_value.stderr_truncated, false)
    eq(exit_value[field], message)
    for _, key in ipairs({ "stderr_error", "stdout_callback_error", "stderr_callback_error" }) do
      if key ~= field then eq(exit_value[key], nil) end
    end
  end
  stream_failure("stdout_error", "git stdout read failure")
  stream_failure("stdout_callback_error", "parser callback failure")

  parser_failure("M\0", "malformed git status record")
  parser_failure(" Mxfile.php\0", "malformed git status record")
  parser_failure("\0", "malformed git status record")
  parser_failure(" M incomplete.php", "incomplete git status record")
  reset(); local partial = git.upload("/project/current.php", { on_exit = public_exit }); eq(partial, git_process)
  calls[1].opts.on_stdout(" M partial"); calls[1].opts.on_stdout("-name.php"); calls[1].on_exit(success_result())
  eq(#calls, 1); eq(exit_count, 1); eq(exit_value.stderr, "incomplete git status record")
  parser_failure("R  new.php\0", "incomplete rename or copy source record")
  parser_failure("C  copied.php\0", "incomplete rename or copy source record")
  parser_failure("R  new.php\0\0", "malformed rename or copy source path")
  parser_failure("C  copied.php\0\0", "malformed rename or copy source path")

  reset()
  existing["/project/file.php"] = true
  rsync_start_error = "rsync start failure"

  local rsync_initial_process = git.upload("/project/current.php", {
    on_exit = public_exit,
  })

  eq(rsync_initial_process, git_process)
  eq(#calls, 1)
  eq(exit_count, 0)

  calls[1].opts.on_stdout(" M file.php\0")
  calls[1].on_exit(success_result())

  eq(#calls, 2)
  eq(exit_count, 1)
  eq(exit_value.stderr, "rsync start failure")
  eq(exit_value.code, nil)
  eq(exit_value.signal, nil)
  eq(exit_value.stdout, "")
  eq(exit_value.stdout_truncated, false)
  eq(exit_value.stderr_truncated, false)
  eq(exit_value.stdout_error, nil)
  eq(exit_value.stderr_error, nil)
  eq(exit_value.stdout_callback_error, nil)
  eq(exit_value.stderr_callback_error, nil)

  reset(); existing["/project/file.php"] = true
  local held = git.upload("/project/current.php", { on_exit = public_exit }); eq(held, git_process)
  calls[1].opts.on_stdout("M\0")
  local precedence = success_result(); precedence.stdout_error = "stream failed"; calls[1].on_exit(precedence)
  eq(exit_value.stderr, "stream failed"); eq(exit_value.stdout_error, "stream failed"); eq(#calls, 1)
  reset(); local held2 = git.upload("/project/current.php", { on_exit = public_exit }); eq(held2, git_process)
  calls[1].opts.on_stdout("M\0"); precedence = success_result(); precedence.stdout_callback_error = "callback failed"; calls[1].on_exit(precedence)
  eq(exit_value.stderr, "callback failed"); eq(exit_value.stdout_callback_error, "callback failed"); eq(#calls, 1)

  reset()

  local precedence_exit_count = 0
  local precedence_exit_value

  local precedence_process = git.upload("/project/current.php", {
    on_exit = function(result)
      precedence_exit_count = precedence_exit_count + 1
      precedence_exit_value = result
    end,
  })

  eq(precedence_process, git_process)
  eq(#calls, 1)

  local nonzero_with_stream_error = success_result()
  nonzero_with_stream_error.code = 1
  nonzero_with_stream_error.stderr = "git failed"
  nonzero_with_stream_error.stdout_error = "read failure"

  calls[1].on_exit(nonzero_with_stream_error)

  eq(#calls, 1)
  eq(precedence_exit_count, 1)
  eq(precedence_exit_value, nonzero_with_stream_error)

  reset()

  local parser_process = git.upload("/project/current.php", {
    on_exit = public_exit,
  })

  eq(parser_process, git_process)
  eq(#calls, 1)

  calls[1].opts.on_stdout("M\0")
  calls[1].on_exit(success_result())

  eq(#calls, 1)
  eq(exit_count, 1)
  eq(exit_value.code, nil)
  eq(exit_value.signal, nil)
  eq(exit_value.stdout, "")
  eq(exit_value.stderr, "malformed git status record")
  eq(exit_value.stdout_truncated, false)
  eq(exit_value.stderr_truncated, false)
  eq(exit_value.stdout_error, nil)
  eq(exit_value.stderr_error, nil)
  eq(exit_value.stdout_callback_error, nil)
  eq(exit_value.stderr_callback_error, nil)

  local allowed_failure_fields = {
    code = true,
    signal = true,
    stdout = true,
    stderr = true,
    stdout_truncated = true,
    stderr_truncated = true,
    stdout_error = true,
    stderr_error = true,
    stdout_callback_error = true,
    stderr_callback_error = true,
  }

  for key in pairs(exit_value) do
    check(allowed_failure_fields[key], "unexpected parser failure field: " .. tostring(key))
  end

  reset()

  existing["/project/file.php"] = true
  rsync_start_error = "rsync start failure"

  local protected_exit_count = 0

  local protected_process = git.upload("/project/current.php", {
    on_exit = function()
      protected_exit_count = protected_exit_count + 1
      error("public rsync exit failure", 0)
    end,
  })

  eq(protected_process, git_process)
  eq(#calls, 1)

  calls[1].opts.on_stdout(" M file.php\0")

  local protected_ok, protected_error = pcall(function()
    calls[1].on_exit(success_result())
  end)

  check(protected_ok, "rsync start failure escaped public on_exit: " .. tostring(protected_error))

  eq(#calls, 2)
  eq(protected_exit_count, 1)

  reset()

  existing["/project/file.php"] = true

  local successful_exit_count = 0

  local successful_process = git.upload("/project/current.php", {
    on_exit = function()
      successful_exit_count = successful_exit_count + 1
    end,
  })

  eq(successful_process, git_process)
  eq(#calls, 1)
  eq(successful_exit_count, 0)

  calls[1].opts.on_stdout(" M file.php\0")
  calls[1].on_exit(success_result())

  eq(#calls, 2)
  eq(successful_exit_count, 0)
  check(type(calls[2].on_exit) == "function")

  calls[2].on_exit(success_result())

  eq(successful_exit_count, 1)

package.loaded["remote-sync.config"] = saved_config
package.loaded["remote-sync.runner"] = saved_runner
package.loaded["remote-sync.git"] = saved_git
end

-- 4.8.3a: standalone tests for the public remote-sync API.
do
  local saved_config = package.loaded["remote-sync.config"]
  local saved_operations = package.loaded["remote-sync.operations"]
  local saved_git = package.loaded["remote-sync.git"]
  local saved_init = package.loaded["remote-sync.init"]

  package.loaded["remote-sync.config"] = nil
  package.loaded["remote-sync.operations"] = nil
  package.loaded["remote-sync.git"] = nil
  package.loaded["remote-sync.init"] = nil

  local notifications = {}
  local scheduled = {}
  local echoes = {}
  local cmd_calls = {}
  local current_buffer_path = "/project/current.php"

  local fake_vim = {
    log = { levels = { ERROR = "ERROR", INFO = "INFO" } },
    fn = {},
    api = {},
  }

  fake_vim.fn.expand = function(path)
    if path == "%:p" then
      return current_buffer_path
    end
    return path
  end

  fake_vim.fn.fnamemodify = function(path, modifier)
    assert(modifier == ":p")
    if path:sub(1, 1) == "/" then
      return path:gsub("/+$", "")
    end
    return path
  end

  fake_vim.notify = function(message, level, opts)
    notifications[#notifications + 1] = { message = message, level = level, opts = opts }
  end
  fake_vim.schedule = function(fn)
    scheduled[#scheduled + 1] = fn
  end
  fake_vim.api.nvim_echo = function(chunks, history, opts)
    echoes[#echoes + 1] = {
      line = chunks[1][1],
      highlight = chunks[1][2],
      history = history,
      opts = opts,
    }
  end
  fake_vim.cmd = function(command)
    cmd_calls[#cmd_calls + 1] = command
  end

  local function flush_scheduled()
    while #scheduled > 0 do
      local fn = table.remove(scheduled, 1)
      fn()
    end
  end

  local upload_process, download_process, git_process = {}, {}, {}
  local upload_calls, download_calls, git_calls = {}, {}, {}
  local upload_result, download_result, git_result = upload_process, download_process, git_process

local function clear_array(values)
  for index = #values, 1, -1 do
    values[index] = nil
  end
end

local function reset_state()
    notifications = {}
    scheduled = {}
    echoes = {}
    cmd_calls = {}
  clear_array(upload_calls)
  clear_array(download_calls)
  clear_array(git_calls)
    upload_result = upload_process
    download_result = download_process
    git_result = git_process
  end

  local remote_sync = load_with_fake_vim(repo_file("lua/remote-sync/init.lua"), fake_vim)

  local public_keys = {}
  for key in pairs(remote_sync) do
    public_keys[key] = true
  end
  assert(public_keys.setup and public_keys.upload and public_keys.upload_current and public_keys.download and public_keys.git_upload)
  local public_key_count = 0
  for _ in pairs(public_keys) do public_key_count = public_key_count + 1 end
  assert(public_key_count == 5)
  assert(type(remote_sync.setup) == "function")
  assert(type(remote_sync.upload) == "function")
  assert(type(remote_sync.upload_current) == "function")
  assert(type(remote_sync.download) == "function")
  assert(type(remote_sync.git_upload) == "function")
  assert(package.loaded["remote-sync.config"] == nil)
  assert(package.loaded["remote-sync.operations"] == nil)
  assert(package.loaded["remote-sync.git"] == nil)

  local set_projects_calls = {}
  local config_failure
  package.loaded["remote-sync.config"] = {
    set_projects = function(projects)
      set_projects_calls[#set_projects_calls + 1] = projects
      if config_failure then return nil, config_failure end
      return true
    end,
  }

  local function assert_no_ui()
    assert(#notifications == 0)
    assert(#scheduled == 0)
  end
  local function assert_notification(index, message, level)
    local notification = notifications[index]
    assert(notification and notification.message == message)
    assert(notification.level == level)
    assert(notification.opts and notification.opts.title == "remote-sync")
  end
  local function assert_no_echo(line)
    for _, echo in ipairs(echoes) do assert(echo.line ~= line) end
  end
  local function assert_callbacks(callbacks)
    assert(type(callbacks) == "table")
    assert(type(callbacks.on_stdout) == "function")
    assert(type(callbacks.on_stderr) == "function")
    assert(type(callbacks.on_exit) == "function")
  end

  assert(remote_sync.setup(nil) == true)
  assert(#set_projects_calls == 1 and type(set_projects_calls[1]) == "table")
  assert(next(set_projects_calls[1]) == nil)
  assert_no_ui()

  set_projects_calls = {}
  assert(remote_sync.setup({}) == true)
  assert(#set_projects_calls == 1 and next(set_projects_calls[1]) == nil)

  local projects = { ["/project"] = { host = "host", remote = "/remote" } }
  set_projects_calls = {}
  assert(remote_sync.setup({ projects = projects }) == true)
  assert(set_projects_calls[1] == projects)

  for _, value in ipairs({ false, 123, "bad" }) do
    set_projects_calls = {}
    reset_state()
    local result, err = remote_sync.setup(value)
    assert(result == nil and type(err) == "string" and #err > 0)
    assert(#set_projects_calls == 0)
    assert_no_ui()
  end
  set_projects_calls = {}
  reset_state()
  local result, err = remote_sync.setup({ unknown = true })
  assert(result == nil and type(err) == "string" and #err > 0)
  assert(#set_projects_calls == 0)
  assert_no_ui()

  for _, invalid_options in ipairs({ { keymaps = {} }, { default_mappings = false } }) do
    set_projects_calls = {}
    reset_state()
    result, err = remote_sync.setup(invalid_options)
    assert(result == nil and err:match("^unknown setup option:"))
    assert(#set_projects_calls == 0)
    assert_no_ui()
  end

  config_failure = "config failure"
  set_projects_calls = {}
  reset_state()
  result, err = remote_sync.setup({ projects = {} })
  assert(result == nil and err == "config failure")
  assert(#set_projects_calls == 1)
  assert_no_ui()
  config_failure = nil

  local fake_operations = {
    upload = function(path, callbacks)
      upload_calls[#upload_calls + 1] = { file_path = path, opts = callbacks }
      return upload_result
    end,
    download = function(path, callbacks)
      download_calls[#download_calls + 1] = { file_path = path, opts = callbacks }
      return download_result
    end,
  }
  local fake_git = {
    upload = function(path, callbacks)
      git_calls[#git_calls + 1] = { file_path = path, opts = callbacks }
      return git_result
    end,
  }
  package.loaded["remote-sync.operations"] = fake_operations
  package.loaded["remote-sync.git"] = fake_git

  local function start_success(fn, path, calls, process, started)
    reset_state()
    local actual = fn(path)
    assert(actual == process)
    assert(#calls == 1 and calls[1].file_path == path)
    assert_callbacks(calls[1].opts)
    assert(#echoes == 0)
    assert(#cmd_calls == 0)
    flush_scheduled()
    assert(echoes[1] and echoes[1].line == started and echoes[1].highlight == "MoreMsg")
  end

  start_success(remote_sync.upload, "/project/file.php", upload_calls, upload_process, "Upload started")
  reset_state(); local process = remote_sync.upload(); assert(process == upload_process and upload_calls[1].file_path == current_buffer_path)
  do
    local events = {}
    local saved_cmd = fake_vim.cmd
    fake_vim.cmd = function(command)
      cmd_calls[#cmd_calls + 1] = command
      if command == "write" then events[#events + 1] = "write" end
    end
    fake_operations.upload = function(path, callbacks)
      events[#events + 1] = "upload"
      upload_calls[#upload_calls + 1] = { file_path = path, opts = callbacks }
      return upload_result
    end
    reset_state()
    assert(remote_sync.upload_current() == upload_process)
    assert(#cmd_calls == 1 and cmd_calls[1] == "write")
    assert(events[1] == "write" and events[2] == "upload")
    assert(#upload_calls == 1 and upload_calls[1].file_path == current_buffer_path)
    assert(#scheduled == 1)

    local write_error = "write failed"
    fake_vim.cmd = function(command)
      if command == "write" then error(write_error, 0) end
      return saved_cmd(command)
    end
    reset_state()
    local ok, failure = pcall(remote_sync.upload_current)
    assert(not ok and failure == write_error)
    assert(#upload_calls == 0 and #notifications == 0 and #scheduled == 0)
    fake_vim.cmd = saved_cmd
    fake_operations.upload = function(path, callbacks)
      upload_calls[#upload_calls + 1] = { file_path = path, opts = callbacks }
      return upload_result
    end
  end
  start_success(remote_sync.download, "/project/download.php", download_calls, download_process, "Download started")
  reset_state(); process = remote_sync.download(); assert(process == download_process and download_calls[1].file_path == current_buffer_path)
  start_success(remote_sync.git_upload, "/project/changed.php", git_calls, git_process, "Git sync started")
  reset_state(); process = remote_sync.git_upload(); assert(process == git_process and git_calls[1].file_path == current_buffer_path)

  local operation_specs = {
    { remote_sync.upload, fake_operations, "upload", upload_calls },
    { remote_sync.download, fake_operations, "download", download_calls },
    { remote_sync.git_upload, fake_git, "upload", git_calls },
  }
  for _, spec in ipairs(operation_specs) do
    for _, path in ipairs({ false, 123, {} }) do
      reset_state(); local value, message = spec[1](path)
      assert(value == nil and message == "file path must be a string")
      assert_notification(1, message, fake_vim.log.levels.ERROR)
      assert(#spec[4] == 0)
    end
    for _, path in ipairs({ "", "   " }) do
      reset_state(); local value, message = spec[1](path)
      assert(value == nil and message == "invalid file path")
      assert_notification(1, message, fake_vim.log.levels.ERROR)
      assert(#spec[4] == 0)
    end
  end
  reset_state(); result, err = remote_sync.upload({}); assert(result == nil and err == "file path must be a string")
  assert_notification(1, err, fake_vim.log.levels.ERROR); assert(#upload_calls == 0)
  current_buffer_path = ""
  for _, spec in ipairs(operation_specs) do
    reset_state(); result, err = spec[1](); assert(result == nil and err == "invalid file path")
    assert_notification(1, err, fake_vim.log.levels.ERROR); assert(#spec[4] == 0)
  end
  current_buffer_path = "/project/current.php"

  reset_state(); assert(remote_sync.download("/project/file.php") == download_process); assert_notification(1, "Download...", fake_vim.log.levels.INFO); flush_scheduled(); assert(echoes[1].line == "Download started")
  reset_state(); assert(remote_sync.git_upload("/project/file.php") == git_process); assert_notification(1, "Syncing git changes...", fake_vim.log.levels.INFO); flush_scheduled(); assert(echoes[1].line == "Git sync started")

  local error_specs = {
    { remote_sync.upload, "upload", fake_operations, upload_calls, "Upload", "Upload failed to start: " },
    { remote_sync.download, "download", fake_operations, download_calls, "Download", "Download failed to start: " },
    { remote_sync.git_upload, "upload", fake_git, git_calls, "Git sync", "Git sync failed to start: " },
  }
  for _, spec in ipairs(error_specs) do
    for _, start_error in ipairs({ "project not found", "rsync unavailable" }) do
      reset_state(); spec[3][spec[2]] = function() return nil, start_error end
      result, err = spec[1]("/project/file.php")
      local expected = start_error == "project not found" and "Project not found" or spec[5] .. " failed to start: " .. start_error
      local returned = start_error == "project not found" and start_error or spec[6] .. start_error
      assert(result == nil and err == returned)
    if spec[2] == "download" then
      assert_notification(1, "Download...", fake_vim.log.levels.INFO)
    elseif spec[5] == "Git sync" then
      assert_notification(1, "Syncing git changes...", fake_vim.log.levels.INFO)
    end

    local notification_index =
      (spec[2] == "download" or spec[5] == "Git sync") and 2 or 1
    assert_notification(notification_index, expected, fake_vim.log.levels.ERROR)
    assert(#scheduled == 0, spec[5] .. " start failure scheduled output")
    assert_no_echo(spec[5] .. " started")
    end
  end
  fake_operations.upload = function() return nil, 123 end
  reset_state(); result, err = remote_sync.upload("/project/file.php")
  assert(result == nil and err == "Upload failed to start: 123")
  assert_notification(1, err, fake_vim.log.levels.ERROR)

  -- 4.8.3b callback and asynchronous reload coverage.
  fake_operations.upload = function(path, callbacks)
    upload_calls[#upload_calls + 1] = { file_path = path, opts = callbacks }
    return upload_result
  end
  fake_operations.download = function(path, callbacks)
    download_calls[#download_calls + 1] = { file_path = path, opts = callbacks }
    return download_result
  end
  fake_git.upload = function(path, callbacks)
    git_calls[#git_calls + 1] = { file_path = path, opts = callbacks }
    return git_result
  end

  local function operation_result(overrides)
    local result = { code = 0, signal = 0, stdout = "", stderr = "",
      stdout_truncated = false, stderr_truncated = false }
    if overrides then for key, value in pairs(overrides) do result[key] = value end end
    return result
  end
  local function echo_at(index, line, highlight)
    assert(echoes[index] and echoes[index].line == line and echoes[index].highlight == highlight,
      "unexpected echo at " .. tostring(index))
  end
  local function no_echo(line)
    for _, item in ipairs(echoes) do assert(item.line ~= line) end
  end
  local function upload_callbacks()
    reset_state()
    assert(remote_sync.upload("/project/file.php") == upload_process)
    flush_scheduled(); echoes = {}
    return upload_calls[1].opts
  end
  local function download_callbacks(path)
    reset_state(); current_buffer_path = path
    assert(remote_sync.download(path) == download_process)
    flush_scheduled(); echoes = {}; cmd_calls = {}; scheduled = {}
    return download_calls[1].opts
  end

  do
    local callbacks = upload_callbacks()
    callbacks.on_stdout("first line\nsecond line"); assert(#echoes == 0); flush_scheduled()
    assert(#echoes == 2); echo_at(1, "first line", "None"); echo_at(2, "second line", "None")
    callbacks = upload_callbacks(); callbacks.on_stderr("warning one\nwarning two")
    assert(#echoes == 0); flush_scheduled(); assert(#echoes == 2)
    echo_at(1, "warning one", "WarningMsg"); echo_at(2, "warning two", "WarningMsg")
    callbacks = upload_callbacks(); callbacks.on_stdout("one\r\n\r\ntwo\n\nthree")
    flush_scheduled(); assert(#echoes == 3); echo_at(1, "one", "None"); echo_at(2, "two", "None"); echo_at(3, "three", "None")
    callbacks = upload_callbacks(); local ok = pcall(function()
      callbacks.on_stdout(nil); callbacks.on_stdout(""); callbacks.on_stdout(false)
      callbacks.on_stderr(nil); callbacks.on_stderr(""); callbacks.on_stderr(false)
    end)
    assert(ok and #scheduled == 0 and #echoes == 0)
    callbacks.on_stdout("par"); callbacks.on_stdout("tial"); flush_scheduled()
    assert(#echoes == 2); echo_at(1, "par", "None"); echo_at(2, "tial", "None")
  end

  do
    local callbacks = upload_callbacks(); callbacks.on_exit(operation_result())
    assert(#echoes == 0 and #cmd_calls == 0); flush_scheduled(); echo_at(1, "Upload done", "MoreMsg")
    reset_state(); remote_sync.git_upload("/project/file.php"); flush_scheduled(); echoes = {}
    git_calls[1].opts.on_exit(operation_result()); flush_scheduled(); echo_at(1, "Git sync done", "MoreMsg"); assert(#cmd_calls == 0)
    callbacks = download_callbacks("/project/file.php"); current_buffer_path = "/different/file.php"
    callbacks.on_exit(operation_result())
    assert(#echoes == 0 and #cmd_calls == 0); flush_scheduled(); echo_at(1, "Download done", "MoreMsg"); assert(#cmd_calls == 0)
    current_buffer_path = "/project/current.php"
  end

  local function failed_upload(result, first, last)
    local callbacks = upload_callbacks(); callbacks.on_exit(result); assert(#echoes == 0); flush_scheduled()
    echo_at(1, first, "ErrorMsg"); if last then echo_at(2, "Last output: " .. last, "ErrorMsg") end; no_echo("Upload done")
  end
  failed_upload(operation_result({ code = 23 }), "Upload error. Exit code: 23")
  failed_upload({ signal = 0, stdout = "", stderr = "", stdout_truncated = false, stderr_truncated = false }, "Upload error")
  failed_upload(operation_result({ code = 7, stdout = "stdout first\nstdout last", stderr = "stderr first\nstderr last" }), "Upload error. Exit code: 7", "stderr last")
  failed_upload(operation_result({ code = 3, stdout = "first\n\nlast" }), "Upload error. Exit code: 3", "last")
  failed_upload(operation_result({ code = 4, stderr = "first\r\nsecond\r\n" }), "Upload error. Exit code: 4", "second")
  for field, message in pairs({ stdout_error = "stdout stream failure", stderr_error = "stderr stream failure",
    stdout_callback_error = "stdout callback failure", stderr_callback_error = "stderr callback failure" }) do
    failed_upload(operation_result({ [field] = message }), "Upload error. Exit code: 0", message)
  end
  failed_upload(operation_result({ stdout_error = "stdout error", stderr_error = "stderr error",
    stdout_callback_error = "stdout callback error", stderr_callback_error = "stderr callback error" }), "Upload error. Exit code: 0", "stdout error")
  failed_upload(operation_result({ stderr = "real stderr", stdout = "real stdout", stdout_error = "stream error" }), "Upload error. Exit code: 0", "real stderr")
  failed_upload(operation_result({ stdout = "real stdout", stdout_error = "stream error" }), "Upload error. Exit code: 0", "real stdout")

  do
    local callbacks = download_callbacks("/project/file.php")
    callbacks.on_exit(operation_result({
      code = 10,
    }))
    assert(#echoes == 0)
    flush_scheduled()
    echo_at(1, "Download error. Exit code: 10", "ErrorMsg")
    no_echo("Download done")
    assert(#cmd_calls == 0)

    reset_state()
    assert(remote_sync.git_upload("/project/file.php") == git_process)
    flush_scheduled()
    echoes = {}
    scheduled = {}
    git_calls[1].opts.on_exit(operation_result({
      code = 11,
    }))
    assert(#echoes == 0)
    flush_scheduled()
    echo_at(1, "Git sync error. Exit code: 11", "ErrorMsg")
    no_echo("Git sync done")
    assert(#cmd_calls == 0)
  end

  do
    local in_async_callback = false
    local expand, fnamemodify, cmd = fake_vim.fn.expand, fake_vim.fn.fnamemodify, fake_vim.cmd
    fake_vim.fn.expand = function(...) if in_async_callback then error("unsafe editor-state access in async callback", 0) end; return expand(...) end
    fake_vim.fn.fnamemodify = function(...) if in_async_callback then error("unsafe editor-state access in async callback", 0) end; return fnamemodify(...) end
    fake_vim.cmd = function(...) if in_async_callback then error("unsafe editor-state access in async callback", 0) end; return cmd(...) end
    local callbacks = download_callbacks("/project/file.php")
    in_async_callback = true; local ok, err = pcall(function() callbacks.on_exit(operation_result()) end); in_async_callback = false
    assert(ok, "download on_exit accessed editor state before scheduling: " .. tostring(err)); assert(#cmd_calls == 0)
    flush_scheduled(); echo_at(1, "Download done", "MoreMsg"); assert(#cmd_calls == 1 and cmd_calls[1] == "edit!")
    callbacks = download_callbacks("/project/file.php"); in_async_callback = true; assert(pcall(function() callbacks.on_exit(operation_result()) end)); in_async_callback = false
    current_buffer_path = "/project/other.php"; flush_scheduled(); echo_at(1, "Download done", "MoreMsg"); assert(#cmd_calls == 0)
    callbacks = download_callbacks("/project/current.php"); callbacks.on_exit(operation_result({ code = 23, stderr = "download failed" })); flush_scheduled()
    assert(#cmd_calls == 0); echo_at(1, "Download error. Exit code: 23", "ErrorMsg"); no_echo("Download done")
    fake_vim.fn.expand, fake_vim.fn.fnamemodify, fake_vim.cmd = expand, fnamemodify, cmd
    current_buffer_path = "/project/current.php"
  end

  package.loaded["remote-sync.config"] = saved_config
  package.loaded["remote-sync.operations"] = saved_operations
  package.loaded["remote-sync.git"] = saved_git
  package.loaded["remote-sync.init"] = saved_init
end

-- 4.8.4: standalone plugin and lazy integration coverage.
do
  local saved_remote_sync = package.loaded["remote-sync"]
  local saved_plugin = package.loaded["remote-sync.plugin"]

  package.loaded["remote-sync"] = nil
  local commands, plugin_vim = {}, { g = {}, api = {} }
  plugin_vim.api.nvim_create_user_command = function(name, callback, opts)
    commands[#commands + 1] = { name = name, callback = callback, opts = opts }
  end
  load_with_fake_vim(repo_file("plugin/remote-sync.lua"), plugin_vim)
  assert(#commands == 3)
  assert(commands[1].name == "SyncUpload")
  assert(commands[2].name == "SyncDownload")
  assert(commands[3].name == "SyncGitUpload")
  assert(package.loaded["remote-sync"] == nil)

  local action_calls = { upload = 0, upload_current = 0, download = 0, git_upload = 0 }
  package.loaded["remote-sync"] = {
    upload = function() action_calls.upload = action_calls.upload + 1 end,
    upload_current = function() action_calls.upload_current = action_calls.upload_current + 1 end,
    download = function() action_calls.download = action_calls.download + 1 end,
    git_upload = function() action_calls.git_upload = action_calls.git_upload + 1 end,
  }
  commands[1].callback(); commands[2].callback(); commands[3].callback()
  assert(action_calls.upload == 1 and action_calls.upload_current == 0)
  assert(action_calls.download == 1 and action_calls.git_upload == 1)
  local command_count = #commands
  load_with_fake_vim(repo_file("plugin/remote-sync.lua"), plugin_vim)
  assert(plugin_vim.g.loaded_remote_sync == true and #commands == command_count)

  local function lazy_scenario(hasmapto, maparg)
    package.loaded["remote-sync"] = nil
    local mappings, autocmds, has_calls, arg_calls = {}, {}, {}, {}
    local lazy_vim = { fn = {}, api = {} }
    lazy_vim.keymap = {}
    lazy_vim.keymap.set = function(mode, lhs, rhs, opts)
      assert(mode == "n")
      mappings[#mappings + 1] = { lhs = lhs, rhs = rhs, opts = opts }
    end
    lazy_vim.api.nvim_create_autocmd = function(event, opts)
      autocmds[#autocmds + 1] = { event = event, opts = opts }
    end
    lazy_vim.fn.hasmapto = function(plug, mode)
      assert(mode == "n")
      has_calls[#has_calls + 1] = plug
      return hasmapto[plug] or 0
    end
    lazy_vim.fn.maparg = function(lhs, mode)
      assert(mode == "n")
      arg_calls[#arg_calls + 1] = lhs
      return maparg[lhs] or ""
    end
    local package_specs = load_with_fake_vim(repo_file("lazy.lua"), lazy_vim)
    assert(type(package_specs) == "table")
    assert(#package_specs == 1)
    local spec = package_specs[1]
    assert(spec[1] == "Oleg4cy/remote-sync.nvim")
    assert(#spec.cmd == 3 and spec.cmd[1] == "SyncUpload" and spec.cmd[2] == "SyncDownload" and spec.cmd[3] == "SyncGitUpload")
    assert(type(spec.init) == "function")
    spec.init()
    assert(package.loaded["remote-sync"] == nil)
    assert(#mappings == 3)
    local plugs = {
      ["<Plug>(RemoteSyncUpload)"] = true,
      ["<Plug>(RemoteSyncDownload)"] = true,
      ["<Plug>(RemoteSyncGitUpload)"] = true,
    }
    for _, mapping in ipairs(mappings) do
      assert(plugs[mapping.lhs] and type(mapping.rhs) == "function")
      assert(mapping.opts.silent == true and mapping.opts.desc:match("^Remote Sync:"))
    end
    local seen_defaults = { ["<leader>ru"] = true, ["<leader>rd"] = true, ["<leader>rg"] = true }
    for _, mapping in ipairs(mappings) do assert(not seen_defaults[mapping.lhs]) end
    assert(#autocmds == 1 and autocmds[1].event == "VimEnter")
    assert(autocmds[1].opts.once == true and type(autocmds[1].opts.callback) == "function")
    assert(#has_calls == 0 and #arg_calls == 0)

    local callbacks = {}
    for _, mapping in ipairs(mappings) do callbacks[mapping.lhs] = mapping.rhs end
    local callback_calls = { upload_current = 0, download = 0, git_upload = 0 }
    package.loaded["remote-sync"] = {
      upload_current = function() callback_calls.upload_current = callback_calls.upload_current + 1 end,
      download = function() callback_calls.download = callback_calls.download + 1 end,
      git_upload = function() callback_calls.git_upload = callback_calls.git_upload + 1 end,
    }
    callbacks["<Plug>(RemoteSyncUpload)"]()
    callbacks["<Plug>(RemoteSyncDownload)"]()
    callbacks["<Plug>(RemoteSyncGitUpload)"]()
    assert(callback_calls.upload_current == 1 and callback_calls.download == 1 and callback_calls.git_upload == 1)
    autocmds[1].opts.callback()
    return mappings, has_calls, arg_calls
  end

  local mappings = lazy_scenario({}, {})
  assert(#mappings == 6)
  local defaults = { ["<leader>ru"] = "<Plug>(RemoteSyncUpload)", ["<leader>rd"] = "<Plug>(RemoteSyncDownload)", ["<leader>rg"] = "<Plug>(RemoteSyncGitUpload)" }
  for index = 4, 6 do assert(defaults[mappings[index].lhs] == mappings[index].rhs) end

  mappings = lazy_scenario({ ["<Plug>(RemoteSyncUpload)"] = 1 }, {})
  assert(#mappings == 5)
  for _, mapping in ipairs(mappings) do assert(mapping.lhs ~= "<leader>ru") end
  mappings = lazy_scenario({ ["<Plug>(RemoteSyncDownload)"] = 1 }, {})
  assert(#mappings == 5)
  for _, mapping in ipairs(mappings) do assert(mapping.lhs ~= "<leader>rd") end

  mappings = lazy_scenario({}, { ["<leader>ru"] = "existing" })
  assert(#mappings == 5)
  for _, mapping in ipairs(mappings) do assert(mapping.lhs ~= "<leader>ru") end
  mappings = lazy_scenario({}, { ["<leader>rd"] = "existing" })
  assert(#mappings == 5)
  for _, mapping in ipairs(mappings) do assert(mapping.lhs ~= "<leader>rd") end

  package.loaded["remote-sync"] = saved_remote_sync
  package.loaded["remote-sync.plugin"] = saved_plugin
end

do
  local remote_sync = require("remote-sync")
  local config_module = require("remote-sync.config")
  local original_loadfile = _G.loadfile
  local original_set_projects = config_module.set_projects
  local original_isabsolutepath = vim.fn.isabsolutepath
  local original_stdpath = vim.fn.stdpath
  local projects = {}
  local set_calls, set_error, last_set_value, load_calls, chunk_calls = 0, nil, nil, {}, 0
  local absolute_calls, stdpath_calls = {}, {}
  local loaded_chunk

  local function reset()
    set_calls, last_set_value, load_calls, chunk_calls = 0, nil, {}, 0
    absolute_calls, stdpath_calls = {}, {}
  end

  local function install(chunk, load_error)
    loaded_chunk = chunk
    _G.loadfile = function(path)
      load_calls[#load_calls + 1] = path
      if load_error then
        return nil, load_error
      end
      return function()
        chunk_calls = chunk_calls + 1
        return loaded_chunk()
      end
    end
  end

  local function setup(opts)
    reset()
    return remote_sync.setup(opts)
  end

  vim.fn.isabsolutepath = function(path)
    absolute_calls[#absolute_calls + 1] = path
    return path:sub(1, 1) == "/" and 1 or 0
  end
  vim.fn.stdpath = function(kind)
    stdpath_calls[#stdpath_calls + 1] = kind
    return "/home/test/.config/nvim"
  end
	config_module.set_projects = function(value)
		set_calls = set_calls + 1
		last_set_value = value
		if set_error ~= nil then
			return nil, set_error
		end
		return true
	end

  local result, err = setup({ projects = projects })
  assert(result == true and err == nil)
  assert(set_calls == 1 and last_set_value == projects)
  assert(#load_calls == 0 and #absolute_calls == 0 and #stdpath_calls == 0)

  result, err = setup({ projects = {}, config = "remote-sync.lua" })
  assert(result == nil and err == "projects and config cannot be used together")
  assert(#load_calls == 0 and set_calls == 0)

  for _, value in ipairs({ false, 123, {}, "", "   " }) do
    result, err = setup({ config = value })
    assert(result == nil and err == "config must be a non-empty path")
    assert(#load_calls == 0 and set_calls == 0)
  end

  install(function() return { projects = projects } end)
  result, err = setup({ config = "lua/config/remote-sync.lua" })
  assert(result == true and err == nil)
  assert(absolute_calls[1] == "lua/config/remote-sync.lua")
  assert(stdpath_calls[1] == "config")
  assert(load_calls[1] == "/home/test/.config/nvim/lua/config/remote-sync.lua")
  assert(chunk_calls == 1 and set_calls == 1 and last_set_value == projects)

  install(function() return { projects = projects } end)
  result, err = setup({ config = "/tmp/remote-sync.lua" })
  assert(result == true and err == nil)
  assert(absolute_calls[1] == "/tmp/remote-sync.lua" and #stdpath_calls == 0)
  assert(load_calls[1] == "/tmp/remote-sync.lua" and chunk_calls == 1 and set_calls == 1)
  assert(last_set_value == projects)

  install(function() return {} end)
  result, err = setup({ config = "/tmp/remote-sync.lua" })
  assert(result == true and err == nil and set_calls == 1 and chunk_calls == 1)
  assert(type(last_set_value) == "table" and next(last_set_value) == nil)

  local invalid_chunks = {
    function() return nil end,
    function() return false end,
    function() return 123 end,
    function() return "bad" end,
    function() return function() end end,
  }
  for _, chunk in ipairs(invalid_chunks) do
    install(chunk)
    result, err = setup({ config = "/invalid/remote-sync.lua" })
    assert(result == nil and err == "invalid config file: config file must return a table")
    assert(set_calls == 0 and #load_calls == 1 and chunk_calls == 1)
  end

  install(function() return { unknown = true } end)
  result, err = setup({ config = "/invalid/remote-sync.lua" })
  assert(result == nil and err == "invalid config file: unknown setup option: unknown" and set_calls == 0)

  install(function() return { config = "another.lua" } end)
  result, err = setup({ config = "/invalid/remote-sync.lua" })
  assert(result == nil and err == "invalid config file: unknown setup option: config")
  assert(#load_calls == 1 and chunk_calls == 1 and set_calls == 0)

  install(nil, "cannot open file")
  result, err = setup({ config = "/missing/remote-sync.lua" })
  assert(result == nil and err == "failed to load config file: /missing/remote-sync.lua: cannot open file")
  assert(chunk_calls == 0 and set_calls == 0)

  install(function() error("config runtime failure", 0) end)
  result, err = setup({ config = "/broken/remote-sync.lua" })
  assert(result == nil and err == "error executing config file: /broken/remote-sync.lua: config runtime failure")
  assert(chunk_calls == 1 and set_calls == 0)

  set_error = "config failure"
  install(function() return { projects = projects } end)
  result, err = setup({ config = "/tmp/remote-sync.lua" })
  assert(result == nil and err == "config failure")
  assert(#load_calls == 1 and chunk_calls == 1 and set_calls == 1)
  assert(last_set_value == projects)

  for _, key in ipairs({ "keymaps", "default_mappings", "arbitrary_unknown" }) do
    result, err = setup({ [key] = true })
    assert(result == nil and err == "unknown setup option: " .. key)
    assert(#load_calls == 0 and set_calls == 0)
  end

  for _, value in ipairs({ false, 123, "bad" }) do
    result, err = setup(value)
    assert(result == nil)
    assert(#load_calls == 0 and set_calls == 0)
  end

  _G.loadfile = original_loadfile
  config_module.set_projects = original_set_projects
  vim.fn.isabsolutepath = original_isabsolutepath
  vim.fn.stdpath = original_stdpath
end

print("remote-sync tests: OK")
