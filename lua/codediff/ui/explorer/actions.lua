-- User actions for explorer (navigation, toggle, etc.)
local M = {}

local config = require("codediff.config")
local git = require("codediff.core.git")
local tree_module = require("codediff.ui.explorer.tree")
local layout = require("codediff.ui.layout")

local function notify_error(err)
  if err then
    vim.schedule(function()
      vim.notify(err, vim.log.levels.ERROR)
    end)
  end
end

-- Find line number for a file node by scanning the tree
-- Returns the line number or nil if not found
local function find_node_line(explorer, path, group)
  local line_count = vim.api.nvim_buf_line_count(explorer.bufnr)
  for line = 1, line_count do
    local node = explorer.tree:get_node(line)
    if node and node.data and node.data.path == path and node.data.group == group then
      return line
    end
  end
  return nil
end

local function navigate(explorer, direction)
  local files = tree_module.get_all_files(explorer.tree)
  if #files == 0 then
    vim.notify("No files in explorer", vim.log.levels.WARN)
    return
  end
  local path, group = explorer.data.current_file_path, explorer.data.current_file_group
  if not path then
    explorer.on_file_select(files[direction > 0 and 1 or #files].data)
    return
  end
  local index = 0
  for i, file in ipairs(files) do
    if file.data.path == path and file.data.group == group then
      index = i
      break
    end
  end
  if not config.options.diff.cycle_next_file and (direction > 0 and index >= #files or direction < 0 and index <= 1) then
    local message = direction > 0 and string.format("Last file (%d of %d)", #files, #files) or string.format("First file (1 of %d)", #files)
    vim.api.nvim_echo({ { message, "WarningMsg" } }, false, {})
    return
  end
  vim.api.nvim_echo({}, false, {})
  local file = files[(index - 1 + direction) % #files + 1]
  local current_win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_is_valid(explorer.winid) then
    local line = find_node_line(explorer, file.data.path, file.data.group)
    if line then
      vim.api.nvim_set_current_win(explorer.winid)
      vim.api.nvim_win_set_cursor(explorer.winid, { line, 0 })
      vim.api.nvim_set_current_win(current_win)
    end
  end
  explorer.on_file_select(file.data)
end

function M.navigate_next(explorer)
  navigate(explorer, 1)
end

function M.navigate_prev(explorer)
  navigate(explorer, -1)
end

-- Toggle explorer visibility (hide/show)
function M.toggle_visibility(explorer)
  if not explorer or not explorer.split then
    return
  end

  local tabpage = vim.api.nvim_get_current_tabpage()

  if explorer.is_hidden then
    explorer.split:show()
    explorer.winid = explorer.split.winid
    require("codediff.ui.refresh").request(explorer.tabpage, { full = true })
  else
    explorer.split:hide()
  end
  explorer.is_hidden = not explorer.is_hidden
  vim.schedule(function()
    layout.arrange(tabpage)
  end)
end

-- Toggle view mode between 'list' and 'tree'
function M.toggle_view_mode(explorer)
  if not explorer then
    return
  end

  local explorer_config = config.options.explorer or {}
  local current_mode = explorer_config.view_mode or "list"
  local new_mode = (current_mode == "list") and "tree" or "list"

  -- Update config
  config.options.explorer.view_mode = new_mode

  -- Presentation changes render the current data without requesting Git.
  tree_module.rebuild(explorer)

  vim.notify("Explorer view: " .. new_mode, vim.log.levels.INFO)
end

--- Swap to the staged/unstaged entry for the current path. Available only in
--- Status Mode; revision, directory, and staged-only views have no counterpart.
---@return boolean swapped
function M.toggle_staged_view(explorer)
  if not explorer then
    return false
  end
  if not explorer.data.git_root then
    vim.notify("Toggle staged view only available in git mode", vim.log.levels.WARN)
    return false
  end
  -- Status Mode is the only mode with distinct staged/unstaged groups.
  if explorer.data.base_revision or explorer.data.target_revision then
    vim.notify("Toggle staged view only available in Status Mode (:CodeDiff with no revision)", vim.log.levels.WARN)
    return false
  end

  local current_path = explorer.data.current_file_path
  local current_group = explorer.data.current_file_group

  if not current_path or not current_group then
    vim.notify("No file selected", vim.log.levels.WARN)
    return false
  end
  if current_group ~= "staged" and current_group ~= "unstaged" then
    vim.notify("Current file has no staged/unstaged counterpart", vim.log.levels.WARN)
    return false
  end

  local target_group = (current_group == "staged") and "unstaged" or "staged"
  local status_result = explorer.data.status_result or {}
  local target_list = status_result[target_group] or {}

  local target_file
  for _, f in ipairs(target_list) do
    if f.path == current_path then
      target_file = f
      break
    end
  end

  if not target_file then
    local label = (target_group == "staged") and "staged" or "unstaged"
    vim.notify(string.format("No %s changes for %s", label, current_path), vim.log.levels.INFO)
    return false
  end

  -- Move cursor to the sibling entry in the tree so `]f`/`[f` and refresh
  -- have a consistent anchor (matches navigate_next/prev behavior).
  if explorer.winid and vim.api.nvim_win_is_valid(explorer.winid) then
    local line = find_node_line(explorer, target_file.path, target_group)
    if line then
      local current_win = vim.api.nvim_get_current_win()
      vim.api.nvim_set_current_win(explorer.winid)
      vim.api.nvim_win_set_cursor(explorer.winid, { line, 0 })
      if current_win ~= explorer.winid and vim.api.nvim_win_is_valid(current_win) then
        vim.api.nvim_set_current_win(current_win)
      end
    end
  end

  explorer.on_file_select({
    path = target_file.path,
    old_path = target_file.old_path,
    status = target_file.status,
    git_root = explorer.data.git_root,
    group = target_group,
  })
  return true
end

-- Toggle visibility of a group (staged/unstaged/conflicts)
function M.toggle_group(explorer, group_name)
  if not explorer or not explorer.visible_groups then
    return
  end

  explorer.visible_groups[group_name] = not explorer.visible_groups[group_name]
  -- Keep the tree and navigation in sync without refreshing repository data.
  tree_module.rebuild(explorer)

  local state = explorer.visible_groups[group_name] and "shown" or "hidden"
  local label = ({ staged = "Staged Changes", unstaged = "Changes", conflicts = "Merge Changes" })[group_name] or group_name
  vim.notify(label .. ": " .. state, vim.log.levels.INFO)
end

-- Stage/unstage a file by path and group (lower-level function)
-- This can be called from anywhere with explicit path and group
-- @param git_root: git repository root
-- @param file_path: relative path to file
-- @param group: "staged", "unstaged", or "conflicts"
-- @return boolean: true if operation was initiated
function M.toggle_stage_file(git_root, file_path, group)
  if not git_root then
    vim.notify("Stage/unstage only available in git mode", vim.log.levels.WARN)
    return false
  end

  if not file_path or not group then
    return false
  end

  -- Guard: only stageable groups
  if group ~= "staged" and group ~= "unstaged" and group ~= "conflicts" then
    return false
  end

  local operation = group == "staged" and git.unstage_file or git.stage_file
  operation(git_root, file_path, notify_error)

  return true
end

-- Stage/unstage all files under a directory
-- @param git_root: git repository root
-- @param dir_path: relative directory path
-- @param group: "staged" or "unstaged"
local function toggle_stage_directory(git_root, dir_path, group)
  if group == "staged" or group == "unstaged" then
    M.toggle_stage_file(git_root, dir_path, group)
  end
end

-- Stage/unstage toggle for the selected entry in explorer (file or directory)
function M.toggle_stage_entry(explorer, tree)
  if not explorer or not explorer.data.git_root then
    vim.notify("Stage/unstage only available in git mode", vim.log.levels.WARN)
    return
  end

  local node = tree:get_node()
  if not node or not node.data or node.data.type == "group" then
    return
  end

  local entry_type = node.data.type
  local group = node.data.group

  if entry_type == "directory" then
    -- Directory uses dir_path, not path
    local dir_path = node.data.dir_path
    if dir_path then
      toggle_stage_directory(explorer.data.git_root, dir_path, group)
    end
  else
    -- File uses path
    local path = node.data.path
    if path then
      M.toggle_stage_file(explorer.data.git_root, path, group)
    end
  end
end

-- Stage all files
function M.stage_all(explorer)
  if not explorer or not explorer.data.git_root then
    vim.notify("Stage all only available in git mode", vim.log.levels.WARN)
    return
  end

  git.stage_all(explorer.data.git_root, function(err)
    if err then
      vim.schedule(function()
        vim.notify(err, vim.log.levels.ERROR)
      end)
    end
  end)
end

-- Unstage all files
function M.unstage_all(explorer)
  if not explorer or not explorer.data.git_root then
    vim.notify("Unstage all only available in git mode", vim.log.levels.WARN)
    return
  end

  git.unstage_all(explorer.data.git_root, function(err)
    if err then
      vim.schedule(function()
        vim.notify(err, vim.log.levels.ERROR)
      end)
    end
  end)
end

-- Restore/discard changes to the selected file or directory
function M.restore_entry(explorer, tree)
  if not explorer or not explorer.data.git_root then
    vim.notify("Restore only available in git mode", vim.log.levels.WARN)
    return
  end

  local node = tree:get_node()
  if not node or not node.data or node.data.type == "group" then
    return
  end

  local entry_type = node.data.type
  local is_directory = entry_type == "directory"
  local entry_path = is_directory and node.data.dir_path or node.data.path
  local group = node.data.group
  local status = node.data.status

  if not entry_path then
    return
  end

  -- Only restore unstaged changes (working tree changes)
  if group ~= "unstaged" then
    vim.notify("Can only restore unstaged changes", vim.log.levels.WARN)
    return
  end

  -- For directories, we don't have a single status, so assume mixed
  -- For files, check if untracked
  local is_untracked = not is_directory and status == "??"
  local display_name = entry_path .. (is_directory and "/" or "")

  -- Confirmation prompt
  local action_word = is_directory and "Discard all changes in " or (is_untracked and "Delete " or "Discard changes to ")
  local prompt = action_word .. display_name .. "?"
  local choice = vim.fn.confirm(prompt, "&Discard\n&Cancel", 2, "Warning")

  if choice == 1 then
    if is_untracked then
      -- Delete untracked file/directory
      git.delete_untracked(explorer.data.git_root, entry_path, function(err)
        if err then
          vim.schedule(function()
            vim.notify(err, vim.log.levels.ERROR)
          end)
        end
      end)
    elseif is_directory then
      -- Directory may contain both tracked and untracked files
      -- Run git restore for tracked changes, then git clean for untracked
      git.restore_file(explorer.data.git_root, entry_path, explorer.data.base_revision, function(restore_err)
        git.delete_untracked(explorer.data.git_root, entry_path, function(clean_err)
          if restore_err and clean_err then
            vim.schedule(function()
              vim.notify("Failed to restore: " .. restore_err, vim.log.levels.ERROR)
            end)
          end
        end)
      end)
    else
      -- Restore tracked file
      git.restore_file(explorer.data.git_root, entry_path, explorer.data.base_revision, function(err)
        if err then
          vim.schedule(function()
            vim.notify(err, vim.log.levels.ERROR)
          end)
        end
      end)
    end
  end
  vim.cmd("echo ''") -- Clear prompt
end

return M
