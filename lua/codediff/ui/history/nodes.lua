-- Node creation and formatting for file history panel
-- Handles commit nodes, file nodes, icons, and tree structure
local M = {}

local Tree = require("codediff.ui.lib.tree")
local file_tree = require("codediff.ui.lib.file_tree")
local Line = require("codediff.ui.lib.line")
local config = require("codediff.config")

-- Status symbols and colors (reuse from explorer)
local STATUS_SYMBOLS = {
  M = { symbol = "M", color = "CodeDiffStatusModified" },
  A = { symbol = "A", color = "CodeDiffStatusAdded" },
  D = { symbol = "D", color = "CodeDiffStatusDeleted" },
  R = { symbol = "R", color = "CodeDiffStatusRenamed" },
}

-- %ar uses Git's relative date; %ai and %ad map to Git's absolute formats.
-- Other values are os.date format strings. Invalid timestamps keep the relative date.
local function format_commit_date(timestamp, date_relative)
  local fmt = (config.options.history and config.options.history.date_format) or "%ar"
  if fmt == "%ar" then
    return date_relative or ""
  end
  if not timestamp or timestamp == "" then
    return date_relative or ""
  end
  local ts = tonumber(timestamp)
  if not ts then
    return date_relative or ""
  end
  if fmt == "%ai" then
    return os.date("%Y-%m-%d %H:%M:%S %z", ts)
  end
  if fmt == "%ad" then
    return os.date("%a %b %e %H:%M:%S %Y %z", ts)
  end
  return os.date(fmt, ts)
end

M.get_file_icon = file_tree.get_file_icon

local function file_node(file, hash, git_root, text, indent, is_last)
  local icon, color = M.get_file_icon(file.path)
  local status = STATUS_SYMBOLS[file.status] or { symbol = file.status, color = "Normal" }
  return Tree.Node({
    id = "file:" .. hash .. ":" .. file.path,
    text = text or file.path,
    data = {
      type = "file",
      path = file.path,
      old_path = file.old_path,
      status = file.status,
      icon = icon,
      icon_color = color,
      status_symbol = status.symbol,
      status_color = status.color,
      git_root = git_root,
      commit_hash = hash,
      is_last = is_last,
      indent_state = indent,
    },
  })
end

local function list_files(files, hash, git_root, indent)
  local nodes = {}
  for i, file in ipairs(files) do
    nodes[#nodes + 1] = file_node(file, hash, git_root, nil, indent and { i == #files } or nil, i == #files)
  end
  return nodes
end

function M.create_commit_node(commit, files, git_root)
  return Tree.Node({
    text = commit.subject,
    id = "commit:" .. commit.hash,
    data = {
      type = "commit",
      hash = commit.hash,
      short_hash = commit.short_hash,
      author = commit.author,
      date = commit.date,
      date_relative = commit.date_relative,
      subject = commit.subject,
      file_count = #files,
      git_root = git_root,
    },
  }, list_files(files, commit.hash, git_root, false))
end

function M.create_list_file_nodes(files, commit_hash, git_root)
  return list_files(files, commit_hash, git_root, true)
end

function M.create_tree_file_nodes(files, commit_hash, git_root)
  return file_tree.build(files, {
    file = function(file, name, indent)
      return file_node(file, commit_hash, git_root, name, indent)
    end,
    directory = function(name, path, indent)
      return {
        id = "dir:" .. commit_hash .. ":" .. path,
        text = name,
        data = {
          type = "directory",
          name = name,
          dir_path = path,
          commit_hash = commit_hash,
          git_root = git_root,
          indent_state = indent,
        },
      }
    end,
  })
end

local function selected_highlight(is_selected)
  local bg = is_selected and vim.api.nvim_get_hl(0, { name = "CodeDiffExplorerSelected", link = false }).bg or nil
  return function(default)
    local base = default or "Normal"
    if not is_selected then
      return base
    end
    local name = "CodeDiffHistorySel_" .. base:gsub("[^%w]", "_")
    local hl = vim.api.nvim_get_hl(0, { name = base, link = false })
    vim.api.nvim_set_hl(0, name, { fg = hl.fg, bg = bg })
    return name
  end
end

-- Prepare node for rendering (format display)
-- Match diffview format: [fold] [file count] | [adds] [dels] | hash subject author, date
function M.prepare_node(node, max_width, selected_commit, selected_file, is_single_file_mode)
  local line = Line()
  local data = node.data or {}
  local is_selected = (data.type == "commit" and data.hash == selected_commit and (is_single_file_mode or not selected_file))
    or (data.type == "file" and data.commit_hash == selected_commit and data.path == selected_file)
  local get_hl = selected_highlight(is_selected)

  if data.type == "title" then
    -- Title node - styled header
    line:append(data.title, "CodeDiffHistoryTitle")
  elseif data.type == "commit" then
    -- Commit node format (diffview style):
    -- [fold icon] N file(s) | +adds -dels | hash subject author, date
    -- In single-file mode, highlight commit when hash matches (no file nodes exist)
    -- In multi-file mode, highlight commit only when no file is selected
    line:append(" ", get_hl("NonText"))

    -- File count (padded to align) - skip in single file mode (when file_path is set)
    if not data.file_path then
      local file_count = data.file_count or data.files_changed or 0
      local file_word = file_count == 1 and "file " or "files"
      local files_width = data.max_files_width or 2
      local file_str = string.format("%" .. files_width .. "d %s ", file_count, file_word)
      line:append(file_str, get_hl("NonText"))
    end

    -- Stats with pipe separators: | <ins> <del> |
    -- One space after |, numbers left-aligned to max width, one space between, one before |
    local insertions = data.insertions or 0
    local deletions = data.deletions or 0
    local ins_width = data.max_ins_width or #tostring(insertions)
    local del_width = data.max_del_width or #tostring(deletions)

    local ins_str = string.format("%-" .. ins_width .. "d", insertions)
    local del_str = string.format("%-" .. del_width .. "d", deletions)

    line:append("| ", get_hl("NonText"))
    line:append(ins_str, get_hl("DiagnosticOk"))
    line:append(" ", get_hl("Normal"))
    line:append(del_str, get_hl("DiagnosticError"))
    line:append(" | ", get_hl("NonText"))

    -- Short hash (8 chars like diffview)
    local hash_display = data.short_hash
    if #hash_display < 8 and data.hash then
      hash_display = data.hash:sub(1, 8)
    end
    line:append(hash_display, get_hl("Identifier"))

    -- Ref names (branches, tags) if present
    if data.ref_names and data.ref_names ~= "" then
      line:append(" (" .. data.ref_names .. ")", get_hl("String"))
    end

    -- Subject (main text, truncated to 72 chars like diffview)
    local subject = data.subject
    if #subject > 72 then
      subject = subject:sub(1, 71) .. "…"
    end
    if subject == "" then
      subject = "[empty message]"
    end
    line:append(" " .. subject, get_hl("Normal"))

    -- Author, date at end (dimmed); date rendering honors history.date_format (#340)
    line:append(" " .. data.author .. ", " .. format_commit_date(data.date, data.date_relative), get_hl("Comment"))
  elseif data.type == "file" then
    -- File node format (diffview style):
    -- [tree char] [status] [icon] [path/]filename
    -- Build tree line characters from indent_state (match explorer: 2-char per level)
    local indent_state = data.indent_state or {}
    line:append(file_tree.indent(indent_state, true), get_hl("Comment"))

    -- Status symbol
    line:append(data.status_symbol .. " ", get_hl(data.status_color))

    -- File icon
    if data.icon then
      line:append(data.icon .. " ", get_hl(data.icon_color))
    end

    -- In tree mode, just show filename; in list mode, show full path
    local filename
    if #indent_state > 1 then
      -- Tree mode: just filename
      filename = data.path:match("([^/]+)$") or data.path
      line:append(filename, get_hl("Normal"))
    else
      -- List mode: show full path with directory dimmed
      local full_path = data.path
      filename = full_path:match("([^/]+)$") or full_path
      local directory = full_path:sub(1, -(#filename + 2))
      if #directory > 0 then
        line:append(directory .. "/", get_hl("Comment"))
      end
      line:append(filename, get_hl("Normal"))
    end
  elseif data.type == "directory" then
    -- Directory node format (tree mode only):
    -- [tree chars] [folder icon] [name]
    -- Build tree line characters from indent_state (match explorer: 2-char per level)
    local indent_state = data.indent_state or {}
    line:append(file_tree.indent(indent_state, true), get_hl("Comment"))

    -- Folder icon
    local explorer_config = config.options.explorer or {}
    local icons = explorer_config.icons or {}
    local is_expanded = node:is_expanded()
    local folder_icon = is_expanded and (icons.folder_open or "") or (icons.folder_closed or "")
    line:append(folder_icon .. " ", get_hl("Directory"))

    -- Directory name
    line:append(data.name, get_hl("Directory"))
  end

  local padding = is_selected and max_width and max_width - #line:content() or 0
  if padding > 0 then
    line:append(string.rep(" ", padding), get_hl("Normal"))
  end
  return line
end

return M
