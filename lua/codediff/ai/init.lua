local M = {}
local provider = require("codediff.ai.provider")

local function options()
  return require("codediff.config").options.ai
end

local function notify(message, level)
  vim.notify("CodeDiff AI: " .. message, level or vim.log.levels.INFO)
end

function M.login()
  provider.login(options(), function(err)
    if err then
      notify(err, vim.log.levels.ERROR)
    else
      notify("Signed in with ChatGPT.")
    end
  end)
end

function M.command(action)
  if action == "login" then
    M.login()
  elseif action == "status" then
    provider.account(options(), function(err, account)
      if err then
        notify(err, vim.log.levels.ERROR)
      else
        notify(account and account.type == "chatgpt" and "Signed in with ChatGPT." or "ChatGPT sign-in needed (:CodeDiffAI login).")
      end
    end)
  end
end

function M.setup()
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("CodeDiffAI", { clear = true }),
    callback = provider.stop,
  })
  if not options().enabled then
    provider.stop()
  end
end

return M
