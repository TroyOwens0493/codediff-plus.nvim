-- Immutable code and context for one file comparison.
local M = {}

local function slice(lines, first, last)
  local result = {}
  for line = math.max(1, first), math.min(#lines, last) do
    result[#result + 1] = lines[line]
  end
  return result
end

local function side(lines, range, context_lines)
  local first = math.max(1, range.start_line - context_lines)
  return {
    start_line = range.start_line,
    end_line = range.end_line,
    lines = slice(lines, range.start_line, range.end_line - 1),
    context_start_line = first,
    context = slice(lines, first, range.end_line - 1 + context_lines),
  }
end

function M.changes(original, modified, opts)
  local result = require("codediff.core.diff").compute_diff(original, modified, require("codediff.ui.view.render").diff_options())
  if not result or result.hit_timeout then
    return nil, "The diff could not be fully computed."
  end
  local changes = {}
  for id, change in ipairs(result.changes) do
    changes[id] = {
      id = id,
      original = side(original, change.original, opts.context_lines),
      modified = side(modified, change.modified, opts.context_lines),
    }
  end
  return changes
end

function M.capture(session, opts)
  if session.merge then
    return nil, "guided review are not available in merge conflict views yet."
  end
  for _, buf in ipairs({ session.original_bufnr, session.modified_bufnr }) do
    if not buf or not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
      return nil, "The diff is still loading."
    end
  end
  local original = vim.api.nvim_buf_get_lines(session.original_bufnr, 0, -1, false)
  local modified = vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false)
  local changes, err = M.changes(original, modified, opts)
  if not changes then
    return nil, err
  end
  local path = session.modified
  if not path or (not path.relative or path.relative == "") and (not path.absolute or path.absolute == "") then
    path = session.original or {}
  end
  local file = path.relative and path.relative ~= "" and path.relative or path.absolute or "[comparison]"
  local payload = vim.json.encode({ file = file, changes = changes })
  if #payload > opts.max_input_bytes then
    return nil, "This file's changes are too large for guided review (limit: " .. opts.max_input_bytes .. " bytes)."
  end
  return {
    file = file,
    changes = changes,
    payload = payload,
    key = vim.fn.sha256(vim.json.encode({ file, original, modified, opts.model or "", opts.effort, opts.context_lines })),
    original_bufnr = session.original_bufnr,
    modified_bufnr = session.modified_bufnr,
    original_tick = vim.api.nvim_buf_get_changedtick(session.original_bufnr),
    modified_tick = vim.api.nvim_buf_get_changedtick(session.modified_bufnr),
    original_revision = session.original_revision,
    modified_revision = session.modified_revision,
  }
end

function M.is_current(snapshot, session)
  for buf, tick in pairs(snapshot.comparison_ticks or {}) do
    if not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_buf_get_changedtick(buf) ~= tick then
      return false
    end
  end
  return session
    and session.original_revision == snapshot.original_revision
    and session.modified_revision == snapshot.modified_revision
    and session.original_bufnr == snapshot.original_bufnr
    and session.modified_bufnr == snapshot.modified_bufnr
    and vim.api.nvim_buf_is_valid(snapshot.original_bufnr)
    and vim.api.nvim_buf_is_valid(snapshot.modified_bufnr)
    and vim.api.nvim_buf_get_changedtick(snapshot.original_bufnr) == snapshot.original_tick
    and vim.api.nvim_buf_get_changedtick(snapshot.modified_bufnr) == snapshot.modified_tick
end

return M
