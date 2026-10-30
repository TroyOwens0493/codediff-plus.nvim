-- Accessor functions (getters and setters) for diff sessions
local M = {}

-- Lazy require to avoid circular dependency: init → session → accessors → session
local function get_active_diffs()
  return require("codediff.ui.lifecycle.session").get_active_diffs()
end

-- Check if a revision represents a virtual buffer
local function is_virtual_revision(revision)
  return revision ~= nil and revision ~= "WORKING"
end

local function clear_gutter_signs(sess)
  local gutter_signs = require("codediff.ui.gutter_signs")
  gutter_signs.clear_buffer(sess.original_bufnr)
  gutter_signs.clear_buffer(sess.modified_bufnr)
end

--- Get session
--- @param tabpage number
--- @return table|nil
function M.get_session(tabpage)
  return get_active_diffs()[tabpage]
end

-- Simple accessors share missing-session behavior. Side effects stay explicit below.
for name, field in pairs({
  get_panel = "panel",
  get_layout = "layout",
  get_merge_base_lines = "merge_base_lines",
  get_result_base_lines = "result_base_lines",
  get_conflict_blocks = "conflict_blocks",
}) do
  M[name] = function(tabpage)
    local sess = M.get_session(tabpage)
    return sess and sess[field]
  end
end

-- Paired getters always return two values, including when no session exists.
for name, fields in pairs({
  get_buffers = { "original_bufnr", "modified_bufnr" },
  get_windows = { "original_win", "modified_win" },
  get_paths = { "original", "modified" },
  get_result = { "result_bufnr", "result_win" },
}) do
  M[name] = function(tabpage)
    local sess = M.get_session(tabpage)
    if not sess then
      return nil, nil
    end
    return sess[fields[1]], sess[fields[2]]
  end
end

for name, field in pairs({
  update_suspended = "suspended",
  update_git_root = "git_root",
  set_result_base_lines = "result_base_lines",
  set_merge_base_lines = "merge_base_lines",
  set_conflict_blocks = "conflict_blocks",
}) do
  M[name] = function(tabpage, value)
    local sess = M.get_session(tabpage)
    if not sess then
      return false
    end
    sess[field] = value
    return true
  end
end

-- merge_base_lines is stage :1; result_base_lines is the auto-merged Result seed.
-- Keep them separate: discard uses merge-base coordinates, tracking uses the seed.

-- Paired updates include nested counters and the two paths/revisions.
for name, fields in pairs({
  update_changedtick = { "original", "modified", "changedtick" },
  update_mtime = { "original", "modified", "mtime" },
  update_paths = { "original", "modified" },
  update_revisions = { "original_revision", "modified_revision" },
}) do
  M[name] = function(tabpage, original, modified)
    local sess = M.get_session(tabpage)
    if not sess then
      return false
    end
    local target = fields[3] and sess[fields[3]] or sess
    target[fields[1]], target[fields[2]] = original, modified
    return true
  end
end

--- Name of the session's side panel, or nil for a bare diff
function M.get_panel_name(tabpage)
  local panel = M.get_panel(tabpage)
  return panel and panel.name or nil
end

--- Legacy "mode" string for the public CodeDiffOpen/CodeDiffClose payload.
--- Documented in the README, so it keeps the pre-panel vocabulary even though
--- nothing inside the plugin reads it any more.
--- @param panel table|nil
--- @return "explorer"|"history"|"standalone"
function M.event_mode(panel)
  return panel and panel.name or "standalone"
end

--- Get git context
function M.get_git_context(tabpage)
  local sess = M.get_session(tabpage)
  if not sess then
    return nil
  end

  return {
    git_root = sess.git_root,
    original_revision = sess.original_revision,
    modified_revision = sess.modified_revision,
  }
end

--- Find tabpage containing a buffer
function M.find_tabpage_by_buffer(bufnr)
  local active_diffs = get_active_diffs()
  for tabpage, sess in pairs(active_diffs) do
    if sess.original_bufnr == bufnr or sess.modified_bufnr == bufnr or sess.result_bufnr == bufnr then
      return tabpage
    end
  end
  return nil
end

--- Whether another live session still owns this buffer, including hidden tabs.
function M.is_buffer_shared(bufnr, except_tabpage)
  for tabpage, sess in pairs(get_active_diffs()) do
    if tabpage ~= except_tabpage and vim.api.nvim_tabpage_is_valid(tabpage) then
      if sess.original_bufnr == bufnr or sess.modified_bufnr == bufnr or sess.result_bufnr == bufnr then
        return true
      end
    end
  end
  return false
end

--- Check if original buffer is virtual
function M.is_original_virtual(tabpage)
  local sess = M.get_session(tabpage)
  if not sess then
    return false
  end
  return is_virtual_revision(sess.original_revision)
end

--- Check if modified buffer is virtual
function M.is_modified_virtual(tabpage)
  local sess = M.get_session(tabpage)
  if not sess then
    return false
  end
  return is_virtual_revision(sess.modified_revision)
end

--- Check if suspended
function M.is_suspended(tabpage)
  local sess = M.get_session(tabpage)
  return sess and sess.suspended or false
end

--- Get explorer reference (for explorer mode)
function M.get_panel_view(tabpage)
  local sess = M.get_session(tabpage)
  return sess and sess.panel and sess.panel.view
end

--- Get all conflict files for a session
function M.get_conflict_files(tabpage)
  local sess = M.get_session(tabpage)
  if not sess then
    return {}
  end
  return sess.conflict_files or {}
end

--- Check if any conflict files have unsaved changes
--- Returns list of unsaved file paths
function M.get_unsaved_conflict_files(tabpage)
  local sess = M.get_session(tabpage)
  if not sess or not sess.conflict_files then
    return {}
  end

  local unsaved = {}
  for file_path, _ in pairs(sess.conflict_files) do
    -- Find buffer for this file
    local bufnr = vim.fn.bufnr(file_path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
      if vim.bo[bufnr].modified then
        table.insert(unsaved, file_path)
      end
    end
  end
  return unsaved
end

--- Update session layout
function M.update_layout(tabpage, layout)
  local sess = M.get_session(tabpage)
  if not sess then
    return false
  end

  sess.layout = layout
  if layout == "inline" then
    clear_gutter_signs(sess)
  end
  return true
end

--- Update diff result (cached)
function M.update_diff_result(tabpage, diff_lines)
  local sess = M.get_session(tabpage)
  if not sess then
    return false
  end

  sess.stored_diff_result = diff_lines
  if diff_lines then
    require("codediff.ui.refresh").ready(tabpage)
  end
  return true
end

--- Update buffer numbers (for file switching/sync when buffers change)
--- Also updates buffer states (for suspend/resume to work correctly)
function M.update_buffers(tabpage, original_bufnr, modified_bufnr)
  local sess = M.get_session(tabpage)
  if not sess then
    return false
  end

  local state = require("codediff.ui.lifecycle.state")
  local gutter_signs = require("codediff.ui.gutter_signs")

  if sess.original_bufnr ~= original_bufnr and sess.original_bufnr ~= modified_bufnr and not M.is_buffer_shared(sess.original_bufnr, tabpage) then
    gutter_signs.clear_buffer(sess.original_bufnr)
    state.restore_buffer_state(sess.original_bufnr, sess.original_state)
  end
  if sess.modified_bufnr ~= original_bufnr and sess.modified_bufnr ~= modified_bufnr and not M.is_buffer_shared(sess.modified_bufnr, tabpage) then
    gutter_signs.clear_buffer(sess.modified_bufnr)
    state.restore_buffer_state(sess.modified_bufnr, sess.modified_state)
  end

  -- Hand mappings back to any buffer that is leaving the session. Without this
  -- the previous file keeps codediff's keys until the tab is closed.
  if sess.keymaps then
    local keep = {}
    local panel_view = sess.panel and sess.panel.view
    for _, buf in pairs({ original_bufnr, modified_bufnr, panel_view and panel_view.bufnr, sess.result_bufnr }) do
      if buf then
        keep[buf] = true
      end
    end
    sess.keymaps:detach_buffers_except(keep)
  end

  local saved = { [sess.original_bufnr] = sess.original_state, [sess.modified_bufnr] = sess.modified_state }
  local original_state = saved[original_bufnr] or state.save_buffer_state(original_bufnr)
  local modified_state = saved[modified_bufnr] or state.save_buffer_state(modified_bufnr)
  sess.original_bufnr = original_bufnr
  sess.modified_bufnr = modified_bufnr

  -- Keep the user's original settings when only the other pane changes.
  sess.original_state, sess.modified_state = original_state, modified_state
  if require("codediff.config").options.diff.disable_inlay_hints and vim.lsp.inlay_hint then
    vim.lsp.inlay_hint.enable(false, { bufnr = original_bufnr })
    vim.lsp.inlay_hint.enable(false, { bufnr = modified_bufnr })
  end

  return true
end

--- Set explorer reference (for explorer mode)
function M.set_panel_view(tabpage, view)
  local sess = M.get_session(tabpage)
  if not sess then
    return false
  end

  sess.panel = sess.panel or {}
  sess.panel.view = view
  if sess.reapply_keymaps then
    sess.reapply_keymaps()
  end
  return true
end

--- Set whether this session is a 3-way merge view.
--- Fixed for a given file, but view.update can retarget a session between a
--- conflicted file and an ordinary one, so it has to follow.
--- @param tabpage number
--- @param merge boolean|nil
--- @return boolean success
function M.update_merge(tabpage, merge)
  local sess = M.get_session(tabpage)
  if not sess then
    return false
  end
  sess.merge = merge or nil
  return true
end

--- Set result buffer and window (for conflict mode)
function M.set_result(tabpage, result_bufnr, result_win)
  local sess = M.get_session(tabpage)
  if not sess then
    return false
  end

  -- Leaving conflict mode: retire the conflict mappings so do/dp and the
  -- ordinary view mappings can be claimed again on the next setup pass.
  if result_bufnr == nil and sess.result_bufnr ~= nil then
    if sess.keymaps then
      sess.keymaps:release_scope("conflict")
    end
    require("codediff.ui.conflict").teardown_gutter(tabpage)
    sess.conflict_blocks = nil
    sess.result_base_lines = nil
    sess.merge_base_lines = nil
  end

  sess.result_bufnr = result_bufnr
  sess.result_win = result_win

  -- Mark result window with restore flag
  if result_win and vim.api.nvim_win_is_valid(result_win) then
    vim.w[result_win].codediff_restore = 1
  end
  if result_win then
    clear_gutter_signs(sess)
  end

  return true
end

--- Track a file opened in conflict mode (for unsaved warning)
function M.track_conflict_file(tabpage, file_path)
  local sess = M.get_session(tabpage)
  if not sess then
    return false
  end

  sess.conflict_files = sess.conflict_files or {}
  sess.conflict_files[file_path] = true
  return true
end

--- Prompt user about unsaved conflict files before closing
--- Returns true if user confirms close, false if cancelled
function M.confirm_close_with_unsaved(tabpage)
  local unsaved = M.get_unsaved_conflict_files(tabpage)
  if #unsaved == 0 then
    return true -- No unsaved files, proceed
  end

  -- Build message
  local msg = "The following merge result files have unsaved changes:\n\n"
  for _, path in ipairs(unsaved) do
    -- Show just filename for readability
    local filename = vim.fn.fnamemodify(path, ":t")
    msg = msg .. "  • " .. filename .. "\n"
  end
  msg = msg .. "\nDiscard changes and close?"

  -- Show confirmation dialog
  local choice = vim.fn.confirm(msg, "&Discard\n&Cancel", 2, "Warning")

  if choice == 1 then
    -- Discard: reload buffers from disk to restore original content (with conflict markers)
    for _, path in ipairs(unsaved) do
      local bufnr = vim.fn.bufnr(path)
      if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
        -- Reload from disk to restore original file content
        vim.api.nvim_buf_call(bufnr, function()
          vim.cmd("edit!")
        end)
      end
    end
    return true
  else
    -- Cancel
    return false
  end
end

return M
