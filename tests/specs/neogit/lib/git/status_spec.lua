local git = require("neogit.lib.git")
local Repo = require("neogit.lib.git.repository")
local Status = require("neogit.buffers.status")
local actions = require("neogit.buffers.status.actions")

describe("status refresh scope", function()
  local root, cwd, repo
  local subdir = "sub dir[1]"

  local function command(...)
    local result = vim.system({ "git", "-C", root, ... }, { text = true }):wait()
    assert.are.equal(0, result.code, result.stderr)
  end

  local function refresh(full_refresh)
    local done = false
    repo:dispatch_refresh {
      full_refresh = full_refresh,
      source = "test",
      callback = function()
        done = true
      end,
    }
    assert.is_true(vim.wait(10000, function()
      return done
    end))
  end

  local function names(section)
    return vim.tbl_map(function(item)
      return item.name
    end, repo.state[section].items)
  end

  before_each(function()
    cwd = vim.fn.getcwd()
    root = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(root .. "/" .. subdir, "p")
    command("init")
    command("config", "user.name", "Neogit Test")
    command("config", "user.email", "test@neogit-test.test")
    for _, prefix in ipairs { "", subdir .. "/" } do
      for _, name in ipairs { "staged.txt", "unstaged.txt" } do
        vim.fn.writefile({ "initial" }, root .. "/" .. prefix .. name)
      end
    end
    command("add", ".")
    command("commit", "-m", "initial")
    for _, prefix in ipairs { "", subdir .. "/" } do
      for _, name in ipairs { "staged.txt", "unstaged.txt", "untracked.txt" } do
        vim.fn.writefile({ "changed" }, root .. "/" .. prefix .. name)
      end
      command("add", "--", prefix .. "staged.txt")
    end
    vim.api.nvim_set_current_dir(root .. "/" .. subdir)
    require("neogit").setup {}
    repo = Repo.instance(vim.fn.getcwd())
    refresh()
  end)

  after_each(function()
    vim.api.nvim_set_current_dir(cwd)
    Repo.instance(cwd)
    vim.fn.delete(root, "rf")
  end)

  it("limits staged, unstaged and untracked files to the opening directory", function()
    assert.are.same({ subdir .. "/staged.txt" }, names("staged"))
    assert.are.same({ subdir .. "/unstaged.txt" }, names("unstaged"))
    assert.are.same({ subdir .. "/untracked.txt" }, names("untracked"))
    assert.are.equal(root, git.repo.worktree_root)
  end)

  it("refreshes the entire repository through the refresh buffer action", function()
    local done = false
    local status = setmetatable({
      redraw = function()
        done = true
      end,
    }, { __index = Status })
    actions.n_refresh_buffer(status)()
    assert.is_true(vim.wait(10000, function()
      return done
    end))
    assert.are.same({ "staged.txt", subdir .. "/staged.txt" }, names("staged"))
    assert.are.same({ subdir .. "/unstaged.txt", "unstaged.txt" }, names("unstaged"))
    assert.are.same({ subdir .. "/untracked.txt", "untracked.txt" }, names("untracked"))

    refresh()
    assert.are.same({ subdir .. "/staged.txt" }, names("staged"))
    assert.are.same({ subdir .. "/unstaged.txt" }, names("unstaged"))
    assert.are.same({ subdir .. "/untracked.txt" }, names("untracked"))
  end)

  it("includes the entire repository when opened at its root", function()
    repo = Repo.instance(root)
    refresh()
    assert.are.same({ "staged.txt", subdir .. "/staged.txt" }, names("staged"))
    assert.are.same({ subdir .. "/unstaged.txt", "unstaged.txt" }, names("unstaged"))
    assert.are.same({ subdir .. "/untracked.txt", "untracked.txt" }, names("untracked"))
  end)
end)
