local M = {}

local api = vim.api

function M.setup()
  local a = require("neogit.lib.async")
  local status_buffer = require("neogit.buffers.status")
  local git = require("neogit.lib.git")
  local group = require("neogit").autocmd_group

  api.nvim_create_autocmd({ "ColorScheme" }, {
    callback = function()
      local config = require("neogit.config")
      local highlight = require("neogit.lib.hl")

      highlight.setup(config.values)
    end,
    group = group,
  })

  local logger = require("neogit.logger") -- DEBUG-DI
  local autocmd_disabled = false
  api.nvim_create_autocmd({ "BufWritePost", "ShellCmdPost", "VimResume" }, {
    callback = a.void(function(o)
      local ft = api.nvim_get_option_value("filetype", { buf = o.buf }) -- DEBUG-DI
      logger.info(("[DEBUG-DI:upstream-ac] event=%s file=%s disabled=%s is_open=%s ft=%s"):format(o.event, o.file, tostring(autocmd_disabled), tostring(status_buffer.is_open()), ft)) -- DEBUG-DI
      if
        not autocmd_disabled
        and status_buffer.is_open()
        and not api.nvim_get_option_value("filetype", { buf = o.buf }):match("^Neogit")
      then
        local path = git.files.relpath_from_repository(o.file)
        logger.info(("[DEBUG-DI:upstream-ac] relpath_from_repository(%s) = %s (RELATIVE)"):format(o.file, vim.inspect(path))) -- DEBUG-DI
        if path then
          logger.info(("[DEBUG-DI:upstream-ac] dispatch_refresh update_diffs={'*:%s'}"):format(path)) -- DEBUG-DI
          status_buffer
            .instance()
            :dispatch_refresh({ update_diffs = { "*:" .. path } }, string.format("%s:%s", o.event, path))
        end
      else
        logger.info("[DEBUG-DI:upstream-ac] guard FAILED -> no refresh (likely is_open=false in background tab)") -- DEBUG-DI
      end
    end),
    group = group,
  })

  --- vimpgrep creates and deletes lots of buffers so attaching to each one will
  --- waste lots of resource and even slow down vimgrep.
  api.nvim_create_autocmd({ "QuickFixCmdPre", "QuickFixCmdPost" }, {
    group = group,
    pattern = "*vimgrep*",
    callback = function(args)
      autocmd_disabled = args.event == "QuickFixCmdPre"
    end,
  })

  -- Ensure vim buffers are updated
  api.nvim_create_autocmd("User", {
    pattern = "NeogitStatusRefreshed",
    callback = function()
      vim.cmd("set autoread | checktime")
    end,
  })
end

return M
