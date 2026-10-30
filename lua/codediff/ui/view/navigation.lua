-- Navigation module - provides public API for navigating hunks and files
local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local config = require("codediff.config")
local cursor_util = require("codediff.ui.view.cursor")

-- Select the adjacent file and request its first/last hunk. The render path
-- consumes pending_cursor_landing once loading finishes.
local function hop_to_adjacent_file(direction)
  local tabpage = vim.api.nvim_get_current_tabpage()
  local panel_obj = lifecycle.get_panel_view(tabpage)
  if not panel_obj then
    -- Cross-file cycling only makes sense in explorer/history mode.
    return false
  end

  local session = lifecycle.get_session(tabpage)
  if session then
    -- "next" → land on first hunk of the next file (the natural forward walk)
    -- "prev" → land on last hunk of the previous file (the natural backward walk)
    session.pending_cursor_landing = direction == "next" and "first" or "last"
  end

  if direction == "next" then
    return M.next_file()
  else
    return M.prev_file()
  end
end

-- Both directions share focus, clamping, cross-file cycling, and status messages.
local function navigate_hunk(direction)
  local tabpage = vim.api.nvim_get_current_tabpage()
  local session = lifecycle.get_session(tabpage)
  if not session then
    return require("codediff.review").navigate_hunk(direction)
  end
  if not session.stored_diff_result then
    return false
  end
  local name = direction > 0 and "next" or "prev"
  local changes = session.stored_diff_result.changes
  if not changes or #changes == 0 then
    return config.options.diff.cycle_hunks_across_files and hop_to_adjacent_file(name)
  end

  local buf = vim.api.nvim_get_current_buf()
  local original = buf == session.original_bufnr
  if session.layout == "inline" or buf == session.result_bufnr then
    original = false
  elseif not original and buf ~= session.modified_bufnr then
    local win = session.modified_win
    if not win or not vim.api.nvim_win_is_valid(win) then
      return false
    end
    vim.api.nvim_set_current_win(win)
  end
  local side = original and "original" or "modified"
  local current_line = vim.api.nvim_win_get_cursor(0)[1]
  local function line_at(index)
    return cursor_util.clamp_line(vim.api.nvim_get_current_buf(), changes[index][side].start_line)
  end
  local function jump(index)
    pcall(vim.api.nvim_win_set_cursor, 0, { line_at(index), 0 })
    vim.cmd("normal! zz")
    vim.api.nvim_echo({ { string.format("Hunk %d of %d", index, #changes), "None" } }, false, {})
    return true
  end

  local first, last = 1, #changes
  if direction < 0 then
    first, last = last, first
  end
  for i = first, last, direction do
    if (line_at(i) - current_line) * direction > 0 then
      return jump(i)
    end
  end
  if config.options.diff.cycle_hunks_across_files and hop_to_adjacent_file(name) then
    return true
  end
  if config.options.diff.cycle_next_hunk then
    return jump(first)
  end
  local message = direction > 0 and string.format("Last hunk (%d of %d)", #changes, #changes) or string.format("First hunk (1 of %d)", #changes)
  vim.api.nvim_echo({ { message, "WarningMsg" } }, false, {})
  return false
end

function M.next_hunk()
  return navigate_hunk(1)
end

function M.prev_hunk()
  return navigate_hunk(-1)
end

local function navigate_file(direction)
  local panel = lifecycle.get_panel(vim.api.nvim_get_current_tabpage())
  if not (panel and panel.view) then
    return false
  end
  local module = require(panel.name == "history" and "codediff.ui.history" or "codediff.ui.explorer")
  local action = "navigate_" .. direction
  if panel.name == "history" and panel.view.is_single_file_mode then
    action = action .. "_commit"
  end
  module[action](panel.view)
  return true
end

function M.next_file()
  return navigate_file("next")
end

function M.prev_file()
  return navigate_file("prev")
end

return M
