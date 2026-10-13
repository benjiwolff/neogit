local M = {}

function M.available()
  if vim.fn.executable("difft") ~= 1 then
    return false
  end

  local ok, viewer = pcall(require, "difftastic-nvim")
  return ok and type(viewer.open) == "function"
end

function M.supports(section)
  return section == "commit"
    or section == "log"
    or section == "recent"
    or section == "range"
    or (section ~= nil and section:match("unmerged$") ~= nil)
end

-- Return false to let the caller use its configured diff viewer.
function M.open(section, item)
  if not M.supports(section) or not item or not M.available() then
    return false
  end

  local revision = item
  if type(item) == "table" then
    if #item == 0 then
      return false
    elseif #item == 1 then
      revision = item[1]
    else
      local oldest, newest = item[1], item[#item]
      if not require("neogit.lib.git").log.is_ancestor(oldest, newest) then
        oldest, newest = newest, oldest
      end
      revision = oldest .. "^.." .. newest
    end
  elseif section ~= "range" and section ~= "commit" then
    revision = item:match("[a-f0-9]+")
  end

  local viewer = require("difftastic-nvim")
  -- The plugin defaults to jj; Neogit always supplies Git revisions.
  local vcs = viewer.config.vcs
  viewer.config.vcs = "git"
  local ok, err = pcall(viewer.open, revision)
  viewer.config.vcs = vcs
  if not ok then
    error(err)
  end
  return true
end

return M
