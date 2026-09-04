local M = {}

function M.check()
  vim.health.start("remote-sync.nvim")

  if type(vim.system) == "function" then
    vim.health.ok("vim.system() is available")
  else
    vim.health.error("vim.system() is required")
  end

  if vim.fn.executable("rsync") == 1 then
    vim.health.ok("rsync is available")
  else
    vim.health.error("rsync is not available")
  end

  if vim.fn.executable("ssh") == 1 then
    vim.health.ok("ssh is available")
  else
    vim.health.error("ssh is not available")
  end

  if vim.fn.executable("git") == 1 then
    vim.health.ok("git is available")
  else
    vim.health.warn("git is not available; git_upload() will not work")
  end

  local ok, config = pcall(require, "remote-sync.config")
  if not ok then
    vim.health.error("Failed to load remote-sync configuration: " .. tostring(config))
    return
  end

  local projects = config.get_projects()
  local count = 0
  for _ in pairs(projects) do
    count = count + 1
  end

  if count > 0 then
    vim.health.ok("Configured projects: " .. tostring(count))
  else
    vim.health.info("No remote-sync projects are currently configured")
  end
end

return M
