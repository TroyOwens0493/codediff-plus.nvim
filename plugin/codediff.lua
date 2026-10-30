-- Plugin entry point - auto-loaded by Neovim
-- Only loads lightweight modules at startup; heavy modules (UI, diff engine,
-- explorer, history) are deferred until first :CodeDiff invocation.
if vim.g.loaded_codediff then
  return
end
vim.g.loaded_codediff = 1

-- Lightweight startup: highlights (~0.3ms) + virtual file scheme (~0.1ms)
local highlights = require("codediff.ui.highlights")
local virtual_file = require("codediff.core.virtual_file")

virtual_file.setup()
highlights.setup()

-- Re-apply highlights on ColorScheme change
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("CodeDiffHighlights", { clear = true }),
  callback = function()
    highlights.setup()
  end,
})

-- Completion is derived from the argparse command tree (see commands.complete).

vim.api.nvim_create_user_command("CodeDiff", function(opts)
  require("codediff.commands").vscode_diff(opts)
end, {
  nargs = "*",
  bang = true,
  range = true,
  complete = function(arg_lead, cmd_line)
    return require("codediff.commands").complete(arg_lead, cmd_line)
  end,
  desc = "Live code review workspace for Neovim",
})

vim.api.nvim_create_user_command("CodeDiffAI", function(opts)
  local action = opts.args == "" and "status" or opts.args
  if not vim.tbl_contains({ "login", "status" }, action) then
    vim.notify("Usage: :CodeDiffAI [login|status]", vim.log.levels.ERROR)
    return
  end
  require("codediff.ai").command(action)
end, {
  nargs = "?",
  complete = function(lead)
    return vim.tbl_filter(function(action)
      return action:sub(1, #lead) == lead
    end, { "login", "status" })
  end,
  desc = "ChatGPT sign-in and account status",
})

vim.api.nvim_create_user_command("CodeDiffReview", function(opts)
  require("codediff.review").command(opts.fargs)
end, {
  nargs = "*",
  complete = function(lead, line)
    if #vim.split(line, "%s+") > 2 then
      return {}
    end
    return vim.tbl_filter(function(action)
      return action:sub(1, #lead) == lead
    end, { "start", "refresh", "next", "prev", "step", "excerpt", "file", "seen", "unseen", "ask", "status", "cancel", "close" })
  end,
  desc = "Generate and navigate an AI-guided review of the comparison",
})
