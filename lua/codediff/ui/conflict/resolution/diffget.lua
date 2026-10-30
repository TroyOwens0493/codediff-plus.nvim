-- Vimdiff-style numbered diffget, restricted to the Result buffer.
local M = {}
local common = require("codediff.ui.conflict.resolution.common")
local tracking = require("codediff.ui.conflict.tracking")

local function diffget(tabpage, input)
  local session = common.session(tabpage)
  if not session then
    return false
  end
  if vim.api.nvim_get_current_buf() ~= session.result_bufnr then
    vim.notify("[codediff] " .. (input == 1 and "2do" or "3do") .. " only works from result buffer", vim.log.levels.INFO)
    return false
  end
  if not common.has_conflicts(session) then
    return false
  end
  local block = tracking.find_conflict_at_cursor_in_result(session, vim.api.nvim_win_get_cursor(0)[1])
  if not block then
    vim.notify("[codediff] No active conflict at cursor position", vim.log.levels.INFO)
    return false
  end
  local lines = common.input_lines(session, block, input)
  if not common.has_result(session) then
    return false
  end
  common.apply(session, block, lines)
  common.refresh(session)
  return true
end

function M.diffget_incoming(tabpage)
  return diffget(tabpage, 1)
end

function M.diffget_current(tabpage)
  return diffget(tabpage, 2)
end

return M
