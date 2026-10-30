-- Vimdiff-style do/dp. Inline do reverts a hunk; inline dp has no edit to make.
local M = {}
local lifecycle = require("codediff.ui.lifecycle")
local refresh = require("codediff.ui.refresh")
local hunk_actions = require("codediff.ui.view.actions.hunk")

local function transfer_hunk(ctx, put)
  if not lifecycle.get_session(ctx.tabpage) then
    return
  end
  if ctx.is_inline and put then
    vim.notify("Buffer already contains the modified version. Use 'do' to revert to original.", vim.log.levels.INFO)
    return
  end

  local current = vim.api.nvim_get_current_buf()
  local side = current == ctx.original_bufnr and "original" or "modified"
  local other = side == "original" and "modified" or "original"
  local source, target, source_side, target_side
  if ctx.is_inline then
    source, target = ctx.original_bufnr, ctx.modified_bufnr
    source_side, target_side = "original", "modified"
  elseif put then
    source, target = current, ctx[other .. "_bufnr"]
    source_side, target_side = side, other
  else
    source, target = ctx[other .. "_bufnr"], current
    source_side, target_side = other, side
  end
  if not vim.bo[target].modifiable then
    vim.notify(put and "Target buffer is not modifiable" or "Buffer is not modifiable", vim.log.levels.WARN)
    return
  end
  local hunk, index = hunk_actions.find_hunk_at_cursor(ctx)
  if not hunk then
    vim.notify("No hunk at cursor position", vim.log.levels.WARN)
    return
  end

  local source_range, target_range = hunk[source_side], hunk[target_side]
  local lines = vim.api.nvim_buf_get_lines(source, source_range.start_line - 1, source_range.end_line - 1, false)
  vim.api.nvim_buf_set_lines(target, target_range.start_line - 1, target_range.end_line - 1, false, lines)
  refresh.buffer_changed(target)
  local message = ctx.is_inline and "Reverted hunk %d" or put and "Put hunk %d" or "Obtained hunk %d"
  vim.api.nvim_echo({ { string.format(message, index), "None" } }, false, {})
end

function M.diff_get(ctx)
  transfer_hunk(ctx, false)
end

function M.diff_put(ctx)
  transfer_hunk(ctx, true)
end

return M
