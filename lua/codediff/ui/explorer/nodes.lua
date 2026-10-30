-- Node creation and formatting for explorer
-- Handles file/directory nodes, icons, status symbols, and tree structure
local M = {}

local Tree = require("codediff.ui.lib.tree")
local file_tree = require("codediff.ui.lib.file_tree")
local config = require("codediff.config")
local line_layout = require("codediff.ui.explorer.line_layout")
local line_stats = require("codediff.ui.explorer.line_stats")
local default_formatters = require("codediff.ui.explorer.formatters")

-- Merge artifact patterns (created by git mergetool)
local MERGE_ARTIFACT_PATTERNS = {
  "%.orig$", -- file.orig
  "%.BACKUP%.", -- file.BACKUP.xxxxx
  "%.BASE%.", -- file.BASE.xxxxx
  "%.LOCAL%.", -- file.LOCAL.xxxxx
  "%.REMOTE%.", -- file.REMOTE.xxxxx
  "_BACKUP_%d+%.", -- file_BACKUP_xxxxx.ext
  "_BASE_%d+%.", -- file_BASE_xxxxx.ext
  "_LOCAL_%d+%.", -- file_LOCAL_xxxxx.ext
  "_REMOTE_%d+%.", -- file_REMOTE_xxxxx.ext
  "_BACKUP_%d+$", -- file_BACKUP_xxxxx
  "_BASE_%d+$", -- file_BASE_xxxxx
  "_LOCAL_%d+$", -- file_LOCAL_xxxxx
  "_REMOTE_%d+$", -- file_REMOTE_xxxxx
}

-- Status symbols and colors
local STATUS_SYMBOLS = {
  M = { symbol = "M", color = "CodeDiffStatusModified" },
  A = { symbol = "A", color = "CodeDiffStatusAdded" },
  D = { symbol = "D", color = "CodeDiffStatusDeleted" },
  ["??"] = { symbol = "??", color = "CodeDiffStatusUntracked" },
  ["!"] = { symbol = "!", color = "CodeDiffStatusConflict" },
}

-- Check if a file path matches merge artifact patterns
local function is_merge_artifact(path)
  for _, pattern in ipairs(MERGE_ARTIFACT_PATTERNS) do
    if path:match(pattern) then
      return true
    end
  end
  return false
end

-- Filter out merge artifacts from file list
function M.filter_merge_artifacts(files)
  if not config.options.diff.hide_merge_artifacts then
    return files
  end

  local filtered = {}
  for _, file in ipairs(files) do
    if not is_merge_artifact(file.path) then
      table.insert(filtered, file)
    end
  end
  return filtered
end

M.get_file_icon = file_tree.get_file_icon

-- Folder icon (configurable via config, with nerd font defaults)
function M.get_folder_icon(is_open)
  local explorer_config = config.options.explorer or {}
  local icons = explorer_config.icons or {}
  local defaults = config.defaults.explorer.icons
  if is_open then
    return icons.folder_open or defaults.folder_open, "Directory"
  else
    return icons.folder_closed or defaults.folder_closed, "Directory"
  end
end

local function context_stats(stats)
  if not config.options.explorer.line_stats.enabled then
    return nil
  end
  return vim.deepcopy(stats)
end

local function normalize_files(files, group)
  local normalized = {}
  for _, file in ipairs(files or {}) do
    normalized[#normalized + 1] = {
      path = file.path,
      old_path = file.old_path,
      group = group or file.group,
      status = file.status,
      stats = context_stats(file.line_stats),
    }
  end
  return normalized
end

local function file_node(file, git_root, group, text, indent)
  local icon, icon_color = M.get_file_icon(file.path)
  local status = STATUS_SYMBOLS[file.status] or { symbol = file.status, color = "Normal" }
  return Tree.Node({
    text = text or file.path,
    data = {
      path = file.path,
      status = file.status,
      old_path = file.old_path,
      icon = icon,
      icon_color = icon_color,
      status_symbol = status.symbol,
      status_color = status.color,
      git_root = git_root,
      group = group,
      indent_state = indent,
      line_stats = file.line_stats,
    },
  })
end

function M.create_file_nodes(files, git_root, group)
  local nodes = {}
  for _, file in ipairs(files) do
    nodes[#nodes + 1] = file_node(file, git_root, group)
  end
  return nodes
end

function M.create_tree_file_nodes(files, git_root, group)
  return file_tree.build(files, {
    flatten = (config.options.explorer or {}).flatten_dirs ~= false,
    file = function(file, name, indent)
      return file_node(file, git_root, group, name, indent)
    end,
    directory = function(name, path, indent, entries)
      return {
        text = name,
        data = {
          type = "directory",
          name = name,
          dir_path = path,
          group = group,
          indent_state = indent,
          file_count = #entries,
          stats = line_stats.sum(entries),
          files = entries,
        },
      }
    end,
  })
end

local function get_indent(node, data, explorer_config)
  local use_indent_markers = explorer_config.indent_markers ~= false
  if explorer_config.view_mode == "tree" and data.indent_state then
    return file_tree.indent(data.indent_state, use_indent_markers), use_indent_markers and "NeoTreeIndentMarker" or "Normal"
  end
  return string.rep("  ", node:get_depth() - 1), "Normal"
end

local function group_context(node, data)
  return {
    name = data.name,
    label = data.label,
    file_count = data.file_count,
    stats = context_stats(data.stats),
    files = normalize_files(data.files, data.name),
    expanded = node:is_expanded(),
  }
end

local function folder_context(node, data, explorer_config)
  local indent, indent_hl = get_indent(node, data, explorer_config)
  local icon, icon_hl = M.get_folder_icon(node:is_expanded())
  return {
    name = data.name,
    path = data.dir_path,
    group = data.group,
    file_count = data.file_count,
    stats = context_stats(data.stats),
    files = normalize_files(data.files, data.group),
    indent = indent,
    indent_hl = indent_hl,
    icon = icon,
    icon_hl = icon_hl,
    expanded = node:is_expanded(),
  }
end

local function file_context(node, data, explorer_config)
  local indent, indent_hl = get_indent(node, data, explorer_config)
  local full_path = data.path or node.text
  local filename = full_path:match("([^/]+)$") or full_path
  local directory = explorer_config.view_mode == "tree" and "" or full_path:sub(1, -(#filename + 1))
  return {
    path = full_path,
    filename = filename,
    directory = directory,
    old_path = data.old_path,
    group = data.group,
    stats = context_stats(data.line_stats),
    status = data.status_symbol or "",
    status_hl = data.status_color,
    status_right_margin = math.max(0, explorer_config.status_right_margin or 1),
    indent = indent,
    indent_hl = indent_hl,
    icon = data.icon or "",
    icon_hl = data.icon_color,
  }
end

local function selected_background(is_selected)
  if not is_selected then
    return nil
  end
  return vim.api.nvim_get_hl(0, { name = "CodeDiffExplorerSelected", link = false }).bg
end

-- Prepare node for rendering (format display)
function M.prepare_node(node, max_width, selected_path, selected_group)
  local data = node.data or {}
  local explorer_config = config.options.explorer
  -- Formatters are pluggable per node type; nil in config means "use the
  -- built-in default" (see `default_formatters` at the top of this file).
  local user_formatters = explorer_config.formatters or {}
  if data.type == "group" then
    local fmt = user_formatters.group or default_formatters.group
    return line_layout.render(fmt(group_context(node, data)), max_width, nil, explorer_config.ellipsis)
  end
  if data.type == "directory" then
    local fmt = user_formatters.folder or default_formatters.folder
    return line_layout.render(fmt(folder_context(node, data, explorer_config)), max_width, nil, explorer_config.ellipsis)
  end

  local is_selected = data.path == selected_path and data.group == selected_group
  local fmt = user_formatters.file or default_formatters.file
  local ctx = file_context(node, data, explorer_config)
  return line_layout.render(fmt(ctx), max_width, selected_background(is_selected), explorer_config.ellipsis)
end

return M
