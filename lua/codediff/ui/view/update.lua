-- File switches share comparison and session publication. Loading stays specific
-- to each layout: inline keeps a hidden snapshot; split views reuse URI buffers.
local M = {}
local lifecycle = require("codediff.ui.lifecycle")
local virtual_file = require("codediff.core.virtual_file")
local config = require("codediff.config")
local layout = require("codediff.ui.layout")
local helpers = require("codediff.ui.view.helpers")
local readiness = require("codediff.ui.view.readiness")
local buffers = require("codediff.ui.view.inline_view.buffers")
local compare = require("codediff.ui.view.compare")
local keymaps = require("codediff.ui.view.keymaps")
local welcome = require("codediff.ui.view.welcome_window")

-- A URI buffer can disappear between preparing and displaying it.
local function reload_side(win, info, virtual)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local valid = info.bufnr and vim.api.nvim_buf_is_valid(info.bufnr)
  if not virtual then
    if info.needs_edit or not valid then
      info.bufnr = helpers.open_real_file(win, info.target)
    else
      helpers.show_real_file_buffer(win, info.bufnr)
    end
  elseif valid then
    vim.api.nvim_win_set_buf(win, info.bufnr)
    if info.needs_edit then
      virtual_file.refresh_buffer(info.bufnr)
    end
  else
    vim.api.nvim_set_current_win(win)
    vim.cmd("edit! " .. vim.fn.fnameescape(info.target))
    info.bufnr = vim.api.nvim_get_current_buf()
  end
end

local function restore_split(ctx)
  local session, wins = ctx.session, ctx.wins
  if not session.single_pane then
    return
  end
  for _, side in ipairs({ "original", "modified" }) do
    if not wins[side] or not vim.api.nvim_win_is_valid(wins[side]) then
      vim.api.nvim_set_current_win(wins[side == "original" and "modified" or "original"])
      local right = (side == "modified") ~= (config.options.diff.original_position == "right")
      vim.cmd(right and "rightbelow vsplit" or "leftabove vsplit")
      wins[side] = vim.api.nvim_get_current_win()
      -- Set this before clearing single_pane, so WinClosed can recognise it.
      vim.w[wins[side]].codediff_restore = 1
      session[side .. "_win"] = wins[side]
    end
  end
  session.single_pane = nil
  layout.arrange(ctx.tabpage)
end

local function fetch(ctx, side, relative, done)
  require("codediff.core.git").get_file_content(ctx.config[side .. "_revision"], ctx.config.git_root, relative, function(err, lines)
    vim.schedule(function()
      if virtual_file.set_content(ctx.infos[side].bufnr, err and {} or lines, relative) then
        done(side)
      end
    end)
  end)
end

local function load_inline(ctx, render)
  local infos, cfg = ctx.infos, ctx.config
  infos.original = { bufnr = buffers.new_scratch() }
  if ctx.virtual.modified then
    infos.modified = { bufnr = buffers.new_scratch() }
    vim.bo[infos.modified.bufnr].modifiable = true
    vim.api.nvim_win_set_buf(ctx.wins.modified, infos.modified.bufnr)
  else
    infos.modified = helpers.prepare_buffer(false, cfg.git_root, nil, cfg.modified)
    reload_side(ctx.wins.modified, infos.modified, false)
  end
  welcome.sync(ctx.wins.modified)
  local awaited = {}
  for _, side in ipairs({ "original", "modified" }) do
    if ctx.virtual[side] then
      awaited[#awaited + 1] = side
    end
  end
  local ready = readiness.when_all(awaited, function()
    vim.schedule(render)
  end)
  if ctx.virtual.original then
    -- Added files can have an empty original path.
    local relative = cfg.original.relative ~= "" and cfg.original.relative or cfg.modified.relative
    fetch(ctx, "original", relative, ready.done)
  elseif cfg.original.absolute and cfg.original.absolute ~= "" then
    local real = vim.fn.bufadd(cfg.original.absolute)
    vim.fn.bufload(real)
    buffers.set_scratch_lines(infos.original.bufnr, vim.api.nvim_buf_get_lines(real, 0, -1, false))
  end
  if ctx.virtual.modified then
    fetch(ctx, "modified", cfg.modified.relative, ready.done)
  end
end

local function load_split(ctx, old_buffers, render)
  restore_split(ctx)
  local awaited = {}
  for _, side in ipairs({ "original", "modified" }) do
    local info = helpers.prepare_buffer(ctx.virtual[side], ctx.config.git_root, ctx.config[side .. "_revision"], ctx.config[side])
    ctx.infos[side] = info
    if ctx.virtual[side] and info.needs_edit then
      awaited[#awaited + 1] = side
    end
  end
  readiness.when_virtual_loaded("CodeDiffVirtualFileUpdate_" .. ctx.tabpage, ctx.infos, awaited, render, false)
  for _, side in ipairs({ "original", "modified" }) do
    reload_side(ctx.wins[side], ctx.infos[side], ctx.virtual[side])
    welcome.sync(ctx.wins[side])
  end
  lifecycle.update_paths(ctx.tabpage, ctx.config.original, ctx.config.modified)
  for _, side in ipairs({ "original", "modified" }) do
    local old = old_buffers[side]
    if
      lifecycle["is_" .. side .. "_virtual"](ctx.tabpage)
      and old ~= ctx.infos.original.bufnr
      and old ~= ctx.infos.modified.bufnr
      and not lifecycle.is_buffer_shared(old, ctx.tabpage)
    then
      pcall(vim.api.nvim_buf_delete, old, { force = true })
    end
  end
  if #awaited == 0 then
    vim.schedule(render)
  end
end

function M.update(tabpage, session_config, auto_scroll_to_first_hunk, inline)
  local saved_win = vim.api.nvim_get_current_win()
  local session = lifecycle.get_session(tabpage)
  if not session then
    return false
  end
  local ctx = {
    tabpage = tabpage,
    config = session_config,
    session = session,
    inline = inline,
    generation = session.refresh and session.refresh.generation,
    wins = { original = session.original_win, modified = session.modified_win },
    infos = {},
    virtual = {},
    line_range = session_config.line_range,
  }
  local old_buffers = { original = session.original_bufnr, modified = session.modified_bufnr }
  if inline then
    if not ctx.wins.modified or not vim.api.nvim_win_is_valid(ctx.wins.modified) then
      return false
    end
    ctx.wins.original = ctx.wins.modified
    buffers.clear_highlights(session)
  else
    session.single_side = nil
    if not old_buffers.original or not old_buffers.modified or not (ctx.wins.original or ctx.wins.modified) then
      return false
    end
    if session.result_bufnr then
      require("codediff.ui.conflict").teardown_gutter(tabpage)
    end
    lifecycle.clear_highlights(old_buffers.original)
    lifecycle.clear_highlights(old_buffers.modified)
  end
  session.single_side = nil
  lifecycle.update_diff_result(tabpage, nil)
  lifecycle.update_merge(tabpage, session_config.conflict)
  if not inline and not session_config.conflict and session.result_win and vim.api.nvim_win_is_valid(session.result_win) then
    vim.api.nvim_win_close(session.result_win, false)
    lifecycle.set_result(tabpage, nil, nil)
  end
  for _, side in ipairs({ "original", "modified" }) do
    ctx.virtual[side] = helpers.is_virtual_revision(session_config[side .. "_revision"])
  end

  local function render()
    compare.run(ctx, auto_scroll_to_first_hunk == true, function(diff, conflict_diffs, base)
      compare.store(ctx, diff)
      if inline then
        lifecycle.update_paths(tabpage, session_config.original, session_config.modified)
      end
      if conflict_diffs then
        if require("codediff.ui.conflict.view").setup_conflict_result_window(tabpage, session_config, ctx.wins.original, ctx.wins.modified, base, conflict_diffs, true) then
          keymaps.reapply(tabpage)
        end
        return
      end
      keymaps.setup_all_keymaps(tabpage, ctx.infos.original.bufnr, ctx.infos.modified.bufnr, lifecycle.get_panel_name(tabpage) == "explorer")
      if inline then
        layout.arrange(tabpage)
      end
      if vim.api.nvim_win_is_valid(saved_win) then
        vim.api.nvim_set_current_win(saved_win)
      end
    end)
  end
  if inline then
    load_inline(ctx, render)
  else
    load_split(ctx, old_buffers, render)
  end
  return true
end

return M
