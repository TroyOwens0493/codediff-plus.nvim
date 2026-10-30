-- Panel setup shared by the two diff layouts.
local M = {}
local lifecycle = require("codediff.ui.lifecycle")
local config = require("codediff.config")
local layout = require("codediff.ui.layout")

-- Load before scheduled callbacks can change the current directory.
local explorer = require("codediff.ui.explorer")
local history = require("codediff.ui.history")

local function setup(tabpage, session_config, original_win, modified_win, name, module)
  local panel = session_config.panel
  if not (panel and panel.name == name and panel.data) then
    return
  end
  local data = lifecycle.get_panel(tabpage).data
  local view = module.create(data, tabpage)
  lifecycle.set_panel_view(tabpage, view)

  local focus = (config.options[name] or {}).initial_focus or name
  if focus == name and view and view.winid and vim.api.nvim_win_is_valid(view.winid) then
    vim.api.nvim_set_current_win(view.winid)
  elseif focus == "original" and vim.api.nvim_win_is_valid(original_win) then
    vim.api.nvim_set_current_win(original_win)
  elseif focus == "modified" and vim.api.nvim_win_is_valid(modified_win) then
    vim.api.nvim_set_current_win(modified_win)
  end
  layout.arrange(tabpage)
end

function M.setup_explorer(tabpage, session_config, original_win, modified_win)
  setup(tabpage, session_config, original_win, modified_win, "explorer", explorer)
end

function M.setup_history(tabpage, session_config, original_win, modified_win)
  setup(tabpage, session_config, original_win, modified_win, "history", history)
end

return M
