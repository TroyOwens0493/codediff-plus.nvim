-- Directory structure shared by the Explorer and History panels.
local M = {}
local Tree = require("codediff.ui.lib.tree")

function M.get_file_icon(path)
  local ok, devicons = pcall(require, "nvim-web-devicons")
  if ok then
    local icon, color = devicons.get_icon(path, nil, { default = true })
    return icon or "", color
  end
  return "", nil
end

function M.indent(state, markers)
  state = state or {}
  if not markers then
    return string.rep("  ", #state)
  end
  local parts = {}
  for i, last in ipairs(state) do
    if i == #state then
      parts[i] = last and "└ " or "├ "
    else
      parts[i] = last and "  " or "│ "
    end
  end
  return table.concat(parts)
end

local function flatten(tree)
  for name, item in pairs(tree) do
    if item.children then
      flatten(item.children)
      local child_name, child = next(item.children)
      if child and child.children and next(item.children, child_name) == nil then
        tree[name .. "/" .. child_name], tree[name] = child, nil
      end
    end
  end
end

-- Callbacks supply panel-specific node IDs and data; hierarchy and ordering stay shared.
function M.build(files, opts)
  local root = {}
  for _, file in ipairs(files) do
    local parts = vim.split(file.path, "/", { trimempty = true })
    local current = root
    for i = 1, #parts - 1 do
      local name = parts[i]
      current[name] = current[name] or { children = {}, files = {} }
      local dir = current[name]
      dir.files[#dir.files + 1] = file
      current = dir.children
    end
    current[parts[#parts]] = { file = file }
  end
  if opts.flatten then
    flatten(root)
  end

  local function build(subtree, parent, indent)
    local keys = vim.tbl_keys(subtree)
    table.sort(keys, function(a, b)
      local a_dir, b_dir = subtree[a].children ~= nil, subtree[b].children ~= nil
      if a_dir ~= b_dir then
        return a_dir
      end
      return a < b
    end)
    local nodes = {}
    for i, name in ipairs(keys) do
      local item = subtree[name]
      local path = parent ~= "" and (parent .. "/" .. name) or name
      local state = vim.list_extend({}, indent)
      state[#state + 1] = i == #keys
      if item.children then
        local children = build(item.children, path, state)
        nodes[#nodes + 1] = Tree.Node(opts.directory(name, path, state, item.files), children)
      else
        nodes[#nodes + 1] = opts.file(item.file, name, state)
      end
    end
    return nodes
  end
  return build(root, "", {})
end

return M
