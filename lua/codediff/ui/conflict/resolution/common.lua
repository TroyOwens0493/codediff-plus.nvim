-- Shared checks and writes for conflict actions. Keep the merge base and Result seed distinct.
local M = {}
local lifecycle = require("codediff.ui.lifecycle")
local tracking = require("codediff.ui.conflict.tracking")

function M.session(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session then
    vim.notify("[codediff] No active session", vim.log.levels.WARN)
  end
  return session
end

function M.has_conflicts(session)
  if not session.conflict_blocks or #session.conflict_blocks == 0 then
    vim.notify("[codediff] No conflicts in this session", vim.log.levels.WARN)
    return false
  end
  return true
end

function M.has_result(session)
  if not session.result_bufnr or not session.result_base_lines then
    vim.notify("[codediff] No result buffer or base lines", vim.log.levels.ERROR)
    return false
  end
  return true
end

function M.at_cursor(tabpage, allow_resolved)
  local session = M.session(tabpage)
  if not session or not M.has_conflicts(session) then
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local side
  if buf == session.original_bufnr then
    side = "left"
  elseif buf == session.modified_bufnr then
    side = "right"
  else
    vim.notify("[codediff] Cursor not in diff buffer", vim.log.levels.WARN)
    return
  end
  local block = tracking.find_conflict_at_cursor(session, vim.api.nvim_win_get_cursor(0)[1], side, allow_resolved or false)
  if not block then
    vim.notify(allow_resolved and "[codediff] No conflict at cursor position" or "[codediff] No active conflict at cursor position", vim.log.levels.INFO)
    return
  end
  return session, block, side
end

function M.input_lines(session, block, input)
  local range = block[input == 1 and "output1_range" or "output2_range"]
  return tracking.get_lines_for_range(session[input == 1 and "original_bufnr" or "modified_bufnr"], range.start_line, range.end_line)
end

function M.base_content(session, block)
  local base = session.merge_base_lines or session.result_base_lines
  if not base then
    return nil
  end
  local lines = {}
  for i = block.base_range.start_line, block.base_range.end_line - 1 do
    lines[#lines + 1] = base[i] or ""
  end
  return lines
end

function M.apply(session, block, lines, seed)
  require("codediff.ui.conflict.resolution.replace").apply_to_result(session.result_bufnr, block, lines, seed or session.result_base_lines)
end

function M.refresh(session)
  require("codediff.ui.conflict.gutter").refresh(session)
  require("codediff.ui.refresh").refresh_result_now(session.result_bufnr)
end

return M
