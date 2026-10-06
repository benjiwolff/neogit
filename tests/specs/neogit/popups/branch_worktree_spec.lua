local actions = require("neogit.popups.branch.actions")
local git = require("neogit.lib.git")
local config = require("neogit.config")
local finder = require("neogit.buffers.fuzzy_finder")
local notification = require("neogit.lib.notification")
local event = require("neogit.lib.event")
local eq = assert.are.same

describe("checkout a branch in another worktree", function()
  local base, root, other, selected, answer, prompts, errors, events, saved

  local function run(...)
    local result = vim.system({ "git", "-C", root, ... }, { text = true }):wait()
    eq(0, result.code, result.stderr)
    return vim.trim(result.stdout)
  end

  local function checkout(args)
    actions.checkout_recent_branch {
      get_arguments = function()
        return args or {}
      end,
    }
  end

  before_each(function()
    saved = {
      repo = rawget(git, "repo"),
      config = config.values,
      finder = finder.new,
      recent = git.branch.get_recent_local_branches,
      confirm = vim.fn.confirm,
      info = notification.info,
      error = notification.error,
      event = event.send,
    }
    base = vim.fn.tempname()
    root = base .. "/repo"
    other = base .. "/other worktree"
    vim.fn.mkdir(root, "p")
    root = vim.uv.fs_realpath(root)
    run("init", "-b", "main")
    run(
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.com",
      "commit",
      "--allow-empty",
      "-m",
      "initial"
    )
    run("worktree", "add", "-b", "feature", other)
    git.repo = { worktree_root = root, state = { hooks = {} } }
    config.values = config.get_default_values()
    config.values.fetch_after_checkout = false
    selected, answer, prompts, errors, events = "feature", 1, {}, {}, {}
    git.branch.get_recent_local_branches = function()
      return { "feature", "main" }
    end
    finder.new = function()
      return {
        open_async = function()
          return selected
        end,
      }
    end
    vim.fn.confirm = function(message, choices, default)
      table.insert(prompts, message)
      eq("&Yes\n&No", choices)
      eq(2, default)
      return answer
    end
    notification.info = function() end
    notification.error = function(message)
      table.insert(errors, message)
    end
    event.send = function(name)
      table.insert(events, name)
    end
  end)

  after_each(function()
    git.repo = saved.repo
    config.values = saved.config
    finder.new = saved.finder
    git.branch.get_recent_local_branches = saved.recent
    vim.fn.confirm = saved.confirm
    notification.info = saved.info
    notification.error = saved.error
    event.send = saved.event
    vim.fn.delete(base, "rf")
  end)

  it("removes the linked worktree and checks out the branch after yes", function()
    checkout()
    eq("feature", run("branch", "--show-current"))
    assert.is_nil(vim.uv.fs_stat(other))
    eq(1, #prompts)
    assert.is_truthy(prompts[1]:find(other, 1, true))
    eq({}, errors)
    eq({ "BranchCheckout" }, events)
  end)

  for _, choice in ipairs { 0, 2 } do
    it("leaves both worktrees unchanged on confirmation result " .. choice, function()
      answer = choice
      checkout()
      eq("main", run("branch", "--show-current"))
      assert.is_truthy(vim.uv.fs_stat(other))
      eq(1, #prompts)
      eq({}, events)
    end)
  end

  it("preserves untracked files and aborts checkout when removal fails", function()
    vim.fn.writefile({ "keep me" }, other .. "/untracked.txt")
    checkout()
    eq("main", run("branch", "--show-current"))
    eq({ "keep me" }, vim.fn.readfile(other .. "/untracked.txt"))
    eq(1, #errors)
    eq({}, events)
  end)

  it("preserves a locked worktree", function()
    run("worktree", "lock", other)
    checkout()
    eq("main", run("branch", "--show-current"))
    assert.is_truthy(vim.uv.fs_stat(other))
    eq(1, #errors)
    eq({}, events)
  end)

  it("never offers to remove the main worktree", function()
    git.repo.worktree_root = vim.uv.fs_realpath(other)
    selected = "main"
    checkout()
    eq({}, prompts)
    eq(1, #errors)
    eq({}, events)
    assert.is_truthy(vim.uv.fs_stat(root .. "/.git"))
  end)

  it("does not remove the current worktree", function()
    git.repo.worktree_root = vim.uv.fs_realpath(other)
    checkout()
    eq({}, prompts)
    eq({}, errors)
    assert.is_truthy(vim.uv.fs_stat(other))
  end)

  it("checks out a free branch without prompting", function()
    run("branch", "free")
    selected = "free"
    checkout()
    eq("free", run("branch", "--show-current"))
    eq({}, prompts)
    eq({}, errors)
  end)

  it("does not remove worktrees for detached checkout", function()
    checkout { "--detach" }
    eq("", run("branch", "--show-current"))
    eq({}, prompts)
    eq({}, errors)
    assert.is_truthy(vim.uv.fs_stat(other))
  end)
end)
