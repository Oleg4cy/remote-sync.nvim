local M = {}

local projects = {}

local function has_non_whitespace(text)
  return text:find("%S") ~= nil
end

local function trim_trailing_slashes(path)
  while path ~= "/" and path:sub(-1) == "/" do
    path = path:sub(1, -2)
  end
  return path
end

local function normalize_local_path(path)
  path = vim.fn.expand(path)
  path = vim.fn.fnamemodify(path, ":p")
  return trim_trailing_slashes(path)
end

local function normalize_remote_path(path)
  return trim_trailing_slashes(path)
end

local function copy_project(project)
  return {
    root = project.root,
    host = project.host,
    remote = project.remote,
  }
end

function M.set_projects(new_projects)
  if type(new_projects) ~= "table" then
    return nil, "projects must be a table"
  end

  local normalized_projects = {}

  for root, project in pairs(new_projects) do
    if type(root) ~= "string" or root == "" or not has_non_whitespace(root) then
      return nil, "project root must be a non-empty string"
    end
    if type(project) ~= "table" then
      return nil, "project configuration must be a table"
    end
    if type(project.host) ~= "string" or not has_non_whitespace(project.host) then
      return nil, "project host must be a non-empty string"
    end
    if type(project.remote) ~= "string" or not has_non_whitespace(project.remote) then
      return nil, "project remote must be a non-empty string"
    end

    local normalized_root = normalize_local_path(root)
    normalized_projects[normalized_root] = {
      root = normalized_root,
      host = project.host,
      remote = normalize_remote_path(project.remote),
    }
  end

  projects = normalized_projects
  return true
end

function M.get_projects()
  local copy = {}
  for root, project in pairs(projects) do
    copy[root] = copy_project(project)
  end
  return copy
end

function M.detect_project(file_path)
  if type(file_path) ~= "string" or file_path == "" or not has_non_whitespace(file_path) then
    return nil
  end

  local directory = vim.fn.fnamemodify(normalize_local_path(file_path), ":h")

  while true do
    local project = projects[directory]
    if project then
      return copy_project(project)
    end

    local parent = vim.fn.fnamemodify(directory, ":h")
    if parent == directory then
      return nil
    end
    directory = parent
  end
end

return M
