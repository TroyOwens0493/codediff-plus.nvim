-- Resolution commands for the conflict under the cursor.
local M = {}
local common = require("codediff.ui.conflict.resolution.common")
local combine = require("codediff.ui.conflict.resolution.combine")

local function accept_input(tabpage, input)
  local session, block = common.at_cursor(tabpage)
  if not session then
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

function M.accept_incoming(tabpage)
  return accept_input(tabpage, 1)
end

function M.accept_current(tabpage)
  return accept_input(tabpage, 2)
end

function M.accept_both(tabpage)
  local session, block, side = common.at_cursor(tabpage)
  if not session or not common.has_result(session) then
    return false
  end
  -- The cursor side comes first, matching VSCode. Concatenate if smart merge fails.
  local first = side == "left" and 1 or 2
  local lines = combine.smart_combine_inputs(session, block, first)
    or combine.dumb_combine_inputs(common.input_lines(session, block, 1), common.input_lines(session, block, 2), first)
  common.apply(session, block, lines)
  common.refresh(session)
  return true
end

function M.discard(tabpage)
  local session, block = common.at_cursor(tabpage, true)
  if not session then
    return false
  end
  local lines = common.base_content(session, block)
  if not lines then
    vim.notify("[codediff] No base lines available", vim.log.levels.ERROR)
    return false
  end
  if not session.result_bufnr then
    vim.notify("[codediff] No result buffer", vim.log.levels.ERROR)
    return false
  end
  -- Tracking searches in the auto-merged seed, not the stage :1 merge base.
  common.apply(session, block, lines, session.result_base_lines or session.merge_base_lines)
  common.refresh(session)
  return true
end

return M
