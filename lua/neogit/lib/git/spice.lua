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

---Try locally-known remote HEAD via `git symbolic-ref`. Returns nil when the
---ref isn't set (i.e. `git remote set-head` was never run for this remote).
---@param remote string
---@return string|nil
local function local_remote_head(remote)
  local res = vim
    .system({ "git", "symbolic-ref", "--short", "refs/remotes/" .. remote .. "/HEAD" }, { text = true })
    :wait()
  if res.code ~= 0 then
    return nil
  end
  local ref = vim.trim(res.stdout or "")
  if ref == "" then
    return nil
  end
  return ref:match("^[^/]+/(.+)$") or ref
end

---Ask the remote directly which branch HEAD points to. Reliable but does
---network IO, so we only use it as a fallback when the local ref isn't set.
---@param remote string
---@return string|nil
local function ls_remote_head(remote)
  local res = vim.system({ "git", "ls-remote", "--symref", remote, "HEAD" }, { text = true }):wait()
  if res.code ~= 0 then
    return nil
  end
  -- Output starts with:  "ref: refs/heads/<name>\tHEAD"
  local name = (res.stdout or ""):match("ref:%s+refs/heads/(%S+)%s+HEAD")
  if name and name ~= "" then
    return name
  end
  return nil
end

---Trunk branch for this repo. We deliberately do **not** call `gs trunk`,
---which is a checkout command (it switches HEAD), not a query. Instead we
---iterate every configured remote, prefer the cheap local lookup, and only
---fall back to a network ls-remote when nothing local resolves.
---@return string|nil
function M.trunk()
  if M._trunk_cache ~= nil then
    return M._trunk_cache or nil
  end

  local git = require("neogit.lib.git")
  local remotes = git.remote.list()

  for _, remote in ipairs(remotes) do
    local name = local_remote_head(remote)
    if name then
      M._trunk_cache = name
      return name
    end
  end

  for _, remote in ipairs(remotes) do
    local name = ls_remote_head(remote)
    if name then
      M._trunk_cache = name
      return name
    end
  end

  M._trunk_cache = false
  return nil
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
  local argv = { "branch", "create", "--no-commit", name }
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

---Submit the current branch and every ancestor (downstack) — i.e. its
---dependencies — but leave branches built on top alone.
---@return boolean ok
---@return string? err
function M.downstack_submit()
  local res = run { "downstack", "submit", "--fill" }
  if res.code ~= 0 then
    return false, vim.trim(res.stderr ~= "" and res.stderr or res.stdout)
  end
  return true, nil
end

---Read the current HEAD commit SHA (or nil if detached/empty/error).
---@return string|nil
local function head_sha()
  local res = vim.system({ "git", "rev-parse", "HEAD" }, { text = true }):wait()
  if res.code ~= 0 then
    return nil
  end
  local sha = vim.trim(res.stdout or "")
  return sha ~= "" and sha or nil
end

---Fetch trunk, prune branches whose PRs have been merged, and re-parent any
---descendants onto trunk. Does network IO.
---@return boolean ok
---@return string? err
function M.repo_sync()
  local res = run { "repo", "sync" }
  if res.code ~= 0 then
    return false, vim.trim(res.stderr ~= "" and res.stderr or res.stdout)
  end
  return true, nil
end

---Rebase the current branch onto its tracked parent. Returns a third value
---`changed` indicating whether HEAD actually moved, so callers can suppress
---"restacked" messages when nothing happened.
---@return boolean ok
---@return string? err
---@return boolean changed
function M.branch_restack()
  local before = head_sha()
  local res = run { "branch", "restack" }
  if res.code ~= 0 then
    return false, vim.trim(res.stderr ~= "" and res.stderr or res.stdout), false
  end
  local after = head_sha()
  local changed = before ~= nil and after ~= nil and before ~= after
  return true, nil, changed
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
