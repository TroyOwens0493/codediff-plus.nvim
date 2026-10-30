-- Displays one-sided files and welcome content in inline views.
local M = {}
local lifecycle = require("codediff.ui.lifecycle")
local layout = require("codediff.ui.layout")
local welcome = require("codediff.ui.view.welcome_window")
local helpers = require("codediff.ui.view.helpers")
local buffers = require("codediff.ui.view.inline_view.buffers")
local single = require("codediff.ui.view.single_file")

local function show(tabpage, file_path, opts)
  local session = lifecycle.get_session(tabpage)
  if not session then
    return
  end
  lifecycle.update_layout(tabpage, "inline")
  local win = session.modified_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  buffers.clear_highlights(session)
  if opts.highlight == false then
    session.single_side = nil
  end
  local bufnr = opts.load_bufnr
  if bufnr then
    vim.api.nvim_win_set_buf(win, bufnr)
  elseif opts.revision and opts.git_root then
    -- Reusing the URI keeps the buffer stable across repeated selections.
    bufnr = single.load_virtual(opts.git_root, opts.revision, opts.rel_path or file_path)
    vim.api.nvim_win_set_buf(win, bufnr)
  else
    bufnr = helpers.open_real_file(win, file_path)
  end
  welcome.sync(win)
  local side = opts.side or "modified"
  local preview = { keep = side, load_bufnr = bufnr, highlight = opts.highlight, git_root = opts.git_root }
  preview[side .. "_path"] = (opts.revision and opts.rel_path) and opts.rel_path or file_path
  preview[side .. "_revision"] = opts.revision
  single.publish(tabpage, preview)
  layout.arrange(tabpage)
  welcome.sync_later(win)
end

---@param opts? { revision: string?, git_root: string?, rel_path: string?, side: "original"|"modified"? }
function M.show_single_file(tabpage, file_path, opts)
  show(tabpage, file_path, opts or {})
end

function M.show_welcome(tabpage, load_bufnr)
  show(tabpage, "", { load_bufnr = load_bufnr, highlight = false })
end

return M
