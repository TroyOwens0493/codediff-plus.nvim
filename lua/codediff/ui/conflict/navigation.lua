-- Navigate active conflicts using the current buffer's projected line numbers.
local M = {}
local lifecycle = require("codediff.ui.lifecycle")
local tracking = require("codediff.ui.conflict.tracking")

local function navigate(tabpage, direction)
  local session = lifecycle.get_session(tabpage)
  if not session or not session.conflict_blocks then
    return
  end
  local active = {}
  for _, block in ipairs(session.conflict_blocks) do
    if tracking.is_block_active(session, block) then
      active[#active + 1] = block
    end
  end
  if #active == 0 then
    vim.notify("No active conflicts", vim.log.levels.INFO)
    return
  end

  local buf = vim.api.nvim_get_current_buf()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local first, last = 1, #active
  if direction < 0 then
    first, last = last, first
  end
  local target, index
  for i = first, last, direction do
    local line = tracking.get_block_start_line(session, active[i], buf)
    if line and (line - cursor_line) * direction > 0 then
      target, index = line, i
      break
    end
  end
  if not target then
    target, index = tracking.get_block_start_line(session, active[first], buf), first
    -- A single conflict at the cursor does not wrap to itself.
    if not target or (target - cursor_line) * direction >= 0 then
      return
    end
  end
  vim.api.nvim_win_set_cursor(0, { target, 0 })
  vim.cmd("normal! zz")
  vim.api.nvim_echo({ { string.format("Conflict %d of %d", index, #active), "None" } }, false, {})
end

function M.navigate_next_conflict(tabpage)
  navigate(tabpage, 1)
end

function M.navigate_prev_conflict(tabpage)
  navigate(tabpage, -1)
end

return M
