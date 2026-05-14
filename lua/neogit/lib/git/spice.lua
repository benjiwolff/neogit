local config = require("neogit.config")
local notification = require("neogit.lib.notification")
local logger = require("neogit.logger")

---@class NeogitGitSpice
local M = {}

---@return boolean
function M.enabled()
  local cfg = config.values.git_spice
  return cfg ~= nil and cfg.enabled == true
end

---@return string
local function executable()
  return (config.values.git_spice and config.values.git_spice.executable) or "git-spice"
end

---Run a git-spice subcommand synchronously.
---@param argv string[]
---@return { code: integer, stdout: string, stderr: string }
local function run(argv)
  local cmd = { executable() }
  for _, a in ipairs(argv) do
    cmd[#cmd + 1] = a
  end

  logger.debug("[git-spice] " .. table.concat(cmd, " "))
  local res = vim.system(cmd, { text = true }):wait()
  return {
    code = res.code or 1,
    stdout = res.stdout or "",
    stderr = res.stderr or "",
  }
end

---Trunk branch tracked by git-spice for this repo, or nil if not initialized.
---@return string|nil
function M.trunk()
  if M._trunk_cache ~= nil then
    return M._trunk_cache or nil
  end

  local res = run({ "trunk" })
  if res.code ~= 0 then
    M._trunk_cache = false
    return nil
  end

  local name = vim.trim(res.stdout)
  M._trunk_cache = (name ~= "" and name) or false
  return M._trunk_cache or nil
end

---Invalidate cached repo-scoped state. Call after `gs repo init` or branch ops
---that might rename the trunk.
function M.invalidate()
  M._trunk_cache = nil
end

---@param branch string
---@return boolean
function M.is_trunk(branch)
  local trunk = M.trunk()
  return trunk ~= nil and trunk == branch
end

---Create a new branch and check it out, tracking the parent relationship in
---git-spice's data store. When `target` is provided, git-spice uses it as the
---parent without first switching to it.
---@param name string
---@param target string|nil
---@return boolean ok
---@return string? err
function M.branch_create(name, target)
  local argv = { "branch", "create", name }
  if target and target ~= "" then
    argv[#argv + 1] = "--target"
    argv[#argv + 1] = target
  end

  local res = run(argv)
  if res.code ~= 0 then
    return false, vim.trim(res.stderr ~= "" and res.stderr or res.stdout)
  end
  return true, nil
end

---Submit the entire stack containing the current branch (creates/updates PRs
---for every non-trunk branch in the chain).
---@return boolean ok
---@return string? err
function M.stack_submit()
  local res = run({ "stack", "submit" })
  if res.code ~= 0 then
    return false, vim.trim(res.stderr ~= "" and res.stderr or res.stdout)
  end
  return true, nil
end

---Notify the user that git-spice is unavailable and they may need to run
---`gs repo init`. Used as a fallback path when a spice command fails because
---the repo isn't initialized.
---@param context string
---@param err string?
function M.notify_failure(context, err)
  local message = ("git-spice %s failed"):format(context)
  if err and err ~= "" then
    message = message .. ":\n" .. err
  end
  notification.error(message)
end

return M
