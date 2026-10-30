-- View creation keeps loading rules for the two layouts explicit, then shares
-- session registration, rendering, panels, and public event payloads.
local M = {}
local lifecycle = require("codediff.ui.lifecycle")
local config = require("codediff.config")
local helpers = require("codediff.ui.view.helpers")
local buffers = require("codediff.ui.view.inline_view.buffers")
local readiness = require("codediff.ui.view.readiness")
local compare = require("codediff.ui.view.compare")
local keymaps = require("codediff.ui.view.keymaps")
local panel = require("codediff.ui.view.panel")
local welcome = require("codediff.ui.view.welcome_window")

local function split()
  vim.cmd(config.options.diff.original_position == "right" and "leftabove vsplit" or "rightbelow vsplit")
  return vim.api.nvim_get_current_win()
end

local function open_panes(ctx, placeholder)
  local infos, wins, virtual = ctx.infos, ctx.wins, ctx.virtual
  wins.original = vim.api.nvim_get_current_win()
  if placeholder then
    if ctx.inline then
      wins.modified = wins.original
      infos.modified = { bufnr = buffers.new_scratch() }
      pcall(vim.api.nvim_buf_set_name, infos.modified.bufnr, "CodeDiff " .. ctx.tabpage .. ".inline")
      vim.api.nvim_win_set_buf(wins.modified, infos.modified.bufnr)
      welcome.sync(wins.modified)
      infos.original = { bufnr = buffers.new_scratch() }
    else
      wins.modified = split()
      for i, side in ipairs({ "original", "modified" }) do
        infos[side] = { bufnr = buffers.new_scratch() }
        pcall(vim.api.nvim_buf_set_name, infos[side].bufnr, "CodeDiff " .. ctx.tabpage .. "." .. i)
        vim.api.nvim_win_set_buf(wins[side], infos[side].bufnr)
        welcome.sync(wins[side])
      end
    end
    return
  end
  for _, side in ipairs({ "original", "modified" }) do
    infos[side] = helpers.prepare_buffer(virtual[side], ctx.config.git_root, ctx.config[side .. "_revision"], ctx.config[side])
  end
  if ctx.inline then
    wins.modified = wins.original
    helpers.load_visible_side(wins.modified, infos.modified, virtual.modified)
    welcome.sync(wins.modified)
    -- A hidden codediff:// buffer would wipe itself without a window.
    if virtual.original and infos.original.needs_edit then
      infos.original.bufnr = buffers.new_scratch()
    elseif infos.original.needs_edit then
      infos.original.bufnr = vim.fn.bufadd(infos.original.target)
      vim.fn.bufload(infos.original.bufnr)
    end
  else
    helpers.load_visible_side(wins.original, infos.original, virtual.original)
    wins.modified = split()
    helpers.load_visible_side(wins.modified, infos.modified, virtual.modified)
    welcome.sync(wins.original)
    welcome.sync(wins.modified)
  end
end

local function register(ctx, diff)
  lifecycle.create_session(ctx.tabpage, ctx.config, {
    original_bufnr = ctx.infos.original.bufnr,
    modified_bufnr = ctx.infos.modified.bufnr,
    original_win = ctx.wins.original,
    modified_win = ctx.wins.modified,
    lines_diff = diff,
    reapply_keymaps = function()
      keymaps.reapply(ctx.tabpage)
    end,
  })
  if ctx.inline then
    lifecycle.update_layout(ctx.tabpage, "inline")
  end
end

local function wait_for_content(ctx, draw)
  if not ctx.inline then
    local awaited = {}
    for _, side in ipairs({ "original", "modified" }) do
      if ctx.virtual[side] then
        awaited[#awaited + 1] = side
      end
    end
    readiness.when_virtual_loaded("CodeDiffVirtualFileHighlight_" .. ctx.tabpage, ctx.infos, awaited, draw, true)
    return
  end
  local function modified_ready()
    if ctx.virtual.modified then
      readiness.when_virtual_loaded("CodeDiffInlineVirtualLoad_" .. ctx.tabpage, ctx.infos, { "modified" }, draw)
    else
      draw()
    end
  end
  if ctx.virtual.original then
    require("codediff.core.git").get_file_content(ctx.config.original_revision, ctx.config.git_root, ctx.config.original.relative, function(err, lines)
      vim.schedule(function()
        if buffers.set_scratch_lines(ctx.infos.original.bufnr, err and {} or lines) then
          modified_ready()
        end
      end)
    end)
  elseif ctx.virtual.modified then
    modified_ready()
  else
    vim.schedule(draw)
  end
end

function M.create(session_config, filetype, on_ready, inline)
  vim.cmd("tabnew")
  local initial = vim.api.nvim_get_current_buf()
  local ctx = { tabpage = vim.api.nvim_get_current_tabpage(), config = session_config, inline = inline, infos = {}, wins = {}, virtual = {} }
  for _, side in ipairs({ "original", "modified" }) do
    ctx.virtual[side] = helpers.is_virtual_revision(session_config[side .. "_revision"])
  end
  local placeholder = helpers.is_panel_placeholder(session_config)
  open_panes(ctx, placeholder)
  if vim.api.nvim_buf_is_valid(initial) and initial ~= ctx.infos.original.bufnr and initial ~= ctx.infos.modified.bufnr then
    pcall(vim.api.nvim_buf_delete, initial, { force = true })
  end
  if inline then
    vim.wo[ctx.wins.modified].cursorline, vim.wo[ctx.wins.modified].wrap = true, false
  else
    for option, value in pairs({ cursorline = true, wrap = false, list = false }) do
      vim.wo[ctx.wins.original][option], vim.wo[ctx.wins.modified][option] = value, value
    end
  end

  if placeholder then
    register(ctx, {})
  else
    wait_for_content(ctx, function()
      if not compare.valid(ctx) then
        return
      end
      -- Native scrollbind acts on the current tab.
      if not inline and vim.api.nvim_get_current_tabpage() ~= ctx.tabpage then
        vim.api.nvim_set_current_tabpage(ctx.tabpage)
      end
      compare.run(ctx, config.options.diff.jump_to_first_change, function(diff, conflict_diffs, base)
        register(ctx, diff)
        if conflict_diffs then
          if require("codediff.ui.conflict.view").setup_conflict_result_window(ctx.tabpage, session_config, ctx.wins.original, ctx.wins.modified, base, conflict_diffs, false) then
            keymaps.reapply(ctx.tabpage)
          end
        else
          keymaps.setup_all_keymaps(ctx.tabpage, ctx.infos.original.bufnr, ctx.infos.modified.bufnr, inline and lifecycle.get_panel_name(ctx.tabpage) == "explorer" or false)
          require("codediff.ui.follow_working_file").enable(ctx.tabpage, ctx.virtual.original, ctx.virtual.modified)
        end
        if on_ready then
          on_ready()
        end
      end)
    end)
  end

  panel.setup_explorer(ctx.tabpage, session_config, ctx.wins.original, ctx.wins.modified)
  panel.setup_history(ctx.tabpage, session_config, ctx.wins.original, ctx.wins.modified)
  if inline then
    require("codediff.ui.layout").arrange(ctx.tabpage)
  end
  vim.api.nvim_exec_autocmds("User", {
    pattern = "CodeDiffOpen",
    modeline = false,
    data = { tabpage = ctx.tabpage, mode = lifecycle.event_mode(session_config.panel), layout = inline and "inline" or nil },
  })
  return {
    original_buf = ctx.infos.original.bufnr,
    modified_buf = ctx.infos.modified.bufnr,
    modified_win = ctx.wins.modified,
    original_win = not inline and ctx.wins.original or nil,
  }
end

return M
