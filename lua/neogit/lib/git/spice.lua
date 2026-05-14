local config = require("neogit.config")
local notification = require("neogit.lib.notification")
local logger = require("neogit.logger")

---@class NeogitGitSpice
local M = {}

---True when the user opted into the integration AND git-spice can actually
---operate on this repo (binary present and `gs repo init` has been run).
---Probes once per session via a read-only spice command; call `invalidate()`
---to re-check after running `gs repo init` interactively.
---@return boolean
function M.enabled()
  if M._enabled_cache ~= nil then
    return M._enabled_cache
  end
  local cfg = config.values.git_spice
  if not (cfg and cfg.enabled) then
    M._enabled_cache = false
    return false
  end
  M._enabled_cache = run({ "ls" }):success()
  return M._enabled_cache
end

---@return string
local function executable()
  return (config.values.git_spice and config.values.git_spice.executable) or "git-spice"
end

---Methods shared by every git-spice result, mirroring neogit's ProcessResult
---interface so call sites can treat spice and git CLI returns the same way.
local Result = {}
Result.__index = Result

---@return boolean
function Result:success()
  return self.code == 0
end

---@return boolean
function Result:failure()
  return self.code ~= 0
end

---Single-string error suitable for notifications. Prefers stderr.
---@return string
function Result:error_message()
  local function joined(t)
    return vim.trim(table.concat(t, "\n"))
  end
  local err = joined(self.stderr)
  if err == "" then
    err = joined(self.stdout)
  end
  return err
end

local function split_lines(s)
  if s == nil or s == "" then
    return {}
  end
  return vim.split(s, "\n", { plain = true, trimempty = true })
end

---Run a git-spice subcommand synchronously and wrap the output in a
---ProcessResult-compatible object.
---@param argv string[]
---@return ProcessResult
local function run(argv)
  local cmd = { executable() }
  for _, a in ipairs(argv) do
    cmd[#cmd + 1] = a
  end

  logger.debug("[git-spice] " .. table.concat(cmd, " "))
  local res = vim.system(cmd, { text = true }):wait()
  return setmetatable({
    code = res.code or 1,
    stdout = split_lines(res.stdout),
    stderr = split_lines(res.stderr),
    cmd = table.concat(cmd, " "),
  }, Result)
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
  M._enabled_cache = nil
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
---@return ProcessResult
function M.branch_create(name, target)
  local argv = { "branch", "create", "--no-commit", name }
  if target and target ~= "" then
    argv[#argv + 1] = "--target"
    argv[#argv + 1] = target
  end
  return run(argv)
end

---Submit the current branch and every ancestor (downstack) — i.e. its
---dependencies — but leave branches built on top alone.
---@return ProcessResult
function M.downstack_submit()
  return run { "downstack", "submit", "--fill" }
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

---Rename a tracked branch. git-spice updates the local branch, its data
---store entry, every child's parent pointer, and the open PR (if any) on the
---forge so reviewers see the new branch name.
---@param old string
---@param new string
---@return ProcessResult
function M.branch_rename(old, new)
  return run { "branch", "rename", old, new }
end

---Delete a tracked branch. git-spice removes the local branch, the data
---store entry, and re-parents any children onto the deleted branch's parent.
---@param name string
---@param opts? { force?: boolean }
---@return ProcessResult
function M.branch_delete(name, opts)
  opts = opts or {}
  local argv = { "branch", "delete" }
  if opts.force then
    argv[#argv + 1] = "--force"
  end
  argv[#argv + 1] = name
  return run(argv)
end

---Fetch trunk, prune branches whose PRs have been merged, and re-parent any
---descendants onto trunk. Does network IO.
---@return ProcessResult
function M.repo_sync()
  return run { "repo", "sync" }
end

---Rebase the current branch onto its tracked parent. The result also has a
---`changed` field (true when HEAD actually moved) so callers can suppress
---"restacked" messages when nothing happened.
---@return ProcessResult & { changed: boolean }
function M.branch_restack()
  local before = head_sha()
  local result = run { "branch", "restack" }
  local after = head_sha()
  result.changed = result:success() and before ~= nil and after ~= nil and before ~= after
  return result
end

---Convenience: emit a neogit error notification for a failed spice command.
---@param context string
---@param result ProcessResult
function M.notify_failure(context, result)
  local message = ("git-spice %s failed"):format(context)
  local err = result:error_message()
  if err ~= "" then
    message = message .. ":\n" .. err
  end
  notification.error(message)
end

return M
