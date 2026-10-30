-- Shared loading and publication for one-sided previews.
local M = {}
local lifecycle = require("codediff.ui.lifecycle")
local path = require("codediff.core.path")

function M.load_virtual(git_root, revision, file_path)
  local url = require("codediff.core.virtual_file").create_url(git_root, revision, file_path)
  local bufnr = vim.fn.bufadd(url)
  vim.fn.bufload(bufnr)
  return bufnr
end

-- Publish before drawing: refresh and keymaps must see the new buffer pair.
function M.publish(tabpage, opts)
  local session = lifecycle.get_session(tabpage)
  local empty = vim.api.nvim_create_buf(false, true)
  vim.bo[empty].buftype = "nofile"
  local original = opts.keep == "original" and opts.load_bufnr or empty
  local modified = opts.keep == "modified" and opts.load_bufnr or empty
  lifecycle.update_buffers(tabpage, original, modified)
  lifecycle.update_paths(
    tabpage,
    path.make_ref(opts.original_path or "", opts.git_root or session.git_root),
    path.make_ref(opts.modified_path or "", opts.git_root or session.git_root)
  )
  lifecycle.update_revisions(tabpage, opts.original_revision, opts.modified_revision)
  lifecycle.update_diff_result(tabpage, { changes = {}, moves = {} })
  session.single_side = opts.highlight ~= false and opts.keep or nil
  if session.single_side then
    require("codediff.ui.core").render_whole_file(opts.load_bufnr, session.single_side)
  end
  require("codediff.ui.view.keymaps").setup_all_keymaps(tabpage, original, modified, lifecycle.get_panel_name(tabpage) == "explorer")
end

return M
