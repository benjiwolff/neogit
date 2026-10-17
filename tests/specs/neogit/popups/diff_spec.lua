local eq = assert.are.same
local actions = require("neogit.popups.diff.actions")
local config = require("neogit.config")
local git = require("neogit.lib.git")

describe("diff popup this action", function()
  local original_viewer, original_state, original_integration
  local opened, closed

  before_each(function()
    original_viewer = config.get_diff_viewer
    original_state = git.repo.state
    original_integration = package.loaded["neogit.integrations.diffview"]
    config.get_diff_viewer = function()
      return "diffview"
    end
    git.repo.state = {
      upstream = { ref = "origin/main" },
      pushRemote = { ref = "fork/feature" },
    }
    package.loaded["neogit.integrations.diffview"] = {
      open = function(...)
        opened = { ... }
      end,
    }
    opened, closed = nil, false
  end)

  after_each(function()
    config.get_diff_viewer = original_viewer
    git.repo.state = original_state
    package.loaded["neogit.integrations.diffview"] = original_integration
  end)

  local function diff_this(section, item)
    actions.this {
      close = function()
        closed = true
      end,
      get_env = function(_, key)
        return ({ section = { name = section }, item = { name = item } })[key]
      end,
    }
    eq(true, closed)
  end

  it("diffs all branch changes from the upstream merge base on the section header", function()
    diff_this("upstream_unmerged")
    eq({ "range", "origin/main...HEAD" }, opened)
  end)

  it("uses the push remote on the unpushed section header", function()
    diff_this("pushRemote_unmerged")
    eq({ "range", "fork/feature...HEAD" }, opened)
  end)

  it("still diffs a single commit when a commit is selected", function()
    diff_this("upstream_unmerged", "abc123")
    eq({ "upstream_unmerged", "abc123", { only = true } }, opened)
  end)

  it("still diffs the staged section", function()
    diff_this("staged")
    eq({ "staged", nil, { only = true } }, opened)
  end)
end)
