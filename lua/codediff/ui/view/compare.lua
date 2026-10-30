-- Compute a comparison once its buffers are loaded. Creation and file switches
-- use the same renderer; the caller decides how to publish the result.
local M = {}
local render = require("codediff.ui.view.render")
local inline_render = require("codediff.ui.view.inline_view.render")
local conflict_view = require("codediff.ui.conflict.view")

function M.valid(ctx)
  if ctx.session and not require("codediff.ui.refresh").is_current(ctx.tabpage, ctx.session, ctx.generation) then
    return false
  end
  for _, side in ipairs({ "original", "modified" }) do
    local win, info = ctx.wins[side], ctx.infos[side]
    if not win or not vim.api.nvim_win_is_valid(win) or not info.bufnr or not vim.api.nvim_buf_is_valid(info.bufnr) then
      return false
    end
  end
  return true
end

function M.run(ctx, jump, done)
  if not M.valid(ctx) then
    return
  end
  local original, modified = ctx.infos.original.bufnr, ctx.infos.modified.bufnr
  local original_lines = vim.api.nvim_buf_get_lines(original, 0, -1, false)
  local modified_lines = vim.api.nvim_buf_get_lines(modified, 0, -1, false)
  if ctx.config.conflict and not ctx.inline then
    require("codediff.core.git").get_file_content(":1", ctx.config.git_root, ctx.config.original.relative, function(err, base)
      vim.schedule(function()
        if not M.valid(ctx) then
          return
        end
        -- Add/add conflicts have no merge base.
        base = err and {} or base
        local diffs = conflict_view.compute_and_render_conflict(original, modified, base, original_lines, modified_lines, ctx.wins.original, ctx.wins.modified, jump)
        if diffs then
          done(diffs.base_to_modified_diff, diffs, base)
        end
      end)
    end)
    return
  end
  local diff
  if ctx.inline then
    diff = inline_render.compute_and_render_inline(modified, original, original_lines, modified_lines, ctx.virtual.original, ctx.virtual.modified, ctx.wins.modified, jump)
  else
    diff = render.compute_and_render(
      original,
      modified,
      original_lines,
      modified_lines,
      ctx.virtual.original,
      ctx.virtual.modified,
      ctx.wins.original,
      ctx.wins.modified,
      jump,
      ctx.line_range
    )
  end
  if diff then
    done(diff)
  end
end

-- Keep the session update order shared by ordinary and conflict comparisons.
function M.store(ctx, diff)
  local lifecycle = require("codediff.ui.lifecycle")
  local original, modified = ctx.infos.original.bufnr, ctx.infos.modified.bufnr
  lifecycle.update_buffers(ctx.tabpage, original, modified)
  lifecycle.update_git_root(ctx.tabpage, ctx.config.git_root)
  lifecycle.update_revisions(ctx.tabpage, ctx.config.original_revision, ctx.config.modified_revision)
  lifecycle.update_diff_result(ctx.tabpage, diff)
  lifecycle.update_changedtick(ctx.tabpage, vim.api.nvim_buf_get_changedtick(original), vim.api.nvim_buf_get_changedtick(modified))
end

return M
