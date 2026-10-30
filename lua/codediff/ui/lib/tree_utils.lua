local M = {}

function M.find_foldable_node(node, tree)
  if node:is_foldable() then
    return node
  end

  if node._parent_id then
    local parent = tree:get_node(node._parent_id)
    if parent and parent:is_foldable() then
      return parent
    end
  end
  return nil
end

function M.find_foldable_at_cursor(tree)
  local node = tree:get_node()
  if not node then
    return nil
  end
  return M.find_foldable_node(node, tree)
end

function M.get_root_node(tree)
  local node = tree:get_node()
  if not node then
    return
  end

  local function find_root(n)
    if not n._parent_id then
      return n
    end
    local parent = tree:get_node(n._parent_id)
    if parent then
      return find_root(parent)
    else
      return n
    end
  end
  return find_root(node)
end

-- Setup all fold-related keymaps on a tree buffer.
-- @param opts table { tree, keymaps, bufnr, tabpage }
function M.setup_fold_keymaps(opts)
  local tree = opts.tree
  local keymaps = opts.keymaps
  local bufnr = opts.bufnr
  local tabpage = opts.tabpage

  local function update_tree_view(node)
    tree:render()
    local winid = vim.fn.bufwinid(bufnr)
    if node._line and winid ~= -1 then
      vim.api.nvim_win_set_cursor(winid, { node._line, 0 })
    end
  end

  -- Bind the operation and its target together instead of repeating each handler.
  local fold_bindings = {
    { key = "fold_open", method = "expand", desc = "Open fold" },
    { key = "fold_open_recursive", method = "expand_recursively", desc = "Open fold recursively" },
    { key = "fold_close", method = "collapse", desc = "Close fold" },
    { key = "fold_close_recursive", method = "collapse_recursively", desc = "Close fold recursively" },
    { key = "fold_toggle", toggle = true, desc = "Toggle fold" },
    { key = "fold_toggle_recursive", toggle = true, recursive = true, desc = "Toggle fold recursively" },
    { key = "fold_open_all", method = "expand_recursively", root = true, desc = "Open all folds" },
    { key = "fold_close_all", method = "collapse_recursively", root = true, desc = "Close all folds" },
  }
  local map_options = { noremap = true, silent = true, nowait = true }
  local lifecycle = require("codediff.ui.lifecycle")
  for _, binding in ipairs(fold_bindings) do
    local key = keymaps[binding.key]
    if key then
      -- Tree panels are codediff-owned scratch buffers: their mappings cannot
      -- leak elsewhere, so they stay installed across tab switches.
      lifecycle.set_buf_keymap(tabpage, bufnr, "n", key, function()
        local node = binding.root and M.get_root_node(tree) or M.find_foldable_at_cursor(tree)
        if not node then
          return
        end
        local method = binding.method
        if binding.toggle then
          method = node:is_expanded() and "collapse" or "expand"
          method = method .. (binding.recursive and "_recursively" or "")
        end
        node[method](node)
        update_tree_view(node)
      end, vim.tbl_extend("force", map_options, { desc = binding.desc }), { suspendable = false })
    end
  end
end

return M
