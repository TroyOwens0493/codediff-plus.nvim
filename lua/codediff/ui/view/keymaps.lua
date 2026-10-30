-- Declare view keys here; action handlers use the session context below.
local M = {}

local lifecycle = require("codediff.ui.lifecycle")
local config = require("codediff.config")
local resolve = require("codediff.keymap.resolve")
local navigation = require("codediff.ui.view.navigation")
local compact = require("codediff.ui.view.compact")

local hunk = require("codediff.ui.view.actions.hunk")
local diffget = require("codediff.ui.view.actions.diffget")
local panes = require("codediff.ui.view.actions.panes")
local stage = require("codediff.ui.view.actions.stage")
local move = require("codediff.ui.view.actions.move")

--- @class CodeDiffActionContext
--- @field tabpage number
--- @field original_bufnr number
--- @field modified_bufnr number
--- @field is_explorer_mode boolean
--- @field is_history_mode boolean
--- @field is_inline boolean
--- @field is_conflict boolean Merge view: a result pane exists

-- Scope replacement retires keys from the previous file, layout, or configuration.
function M.setup_all_keymaps(tabpage, original_bufnr, modified_bufnr, is_explorer_mode)
  lifecycle.begin_keymap_scope(tabpage, "view")
  local keymaps = resolve.keymaps_for("view")
  local session = lifecycle.get_session(tabpage)
  local is_history = session and session.panel and session.panel.name == "history"
  local is_inline = session and session.layout == "inline"
  local is_conflict = session and session.merge == true or false
  local ctx = {
    tabpage = tabpage,
    original_bufnr = original_bufnr,
    modified_bufnr = modified_bufnr,
    is_explorer_mode = is_explorer_mode or false,
    is_history_mode = is_history or false,
    is_inline = is_inline or false,
    is_conflict = is_conflict,
  }

  local function bind(name, fn, desc)
    if keymaps[name] then
      lifecycle.set_tab_keymap(tabpage, "n", keymaps[name], fn, { desc = desc })
    end
  end
  local function action(fn)
    return function()
      fn(ctx)
    end
  end

  bind("quit", function()
    lifecycle.close(tabpage)
  end, "Close codediff tab")
  bind("next_hunk", navigation.next_hunk, "Next hunk")
  bind("prev_hunk", navigation.prev_hunk, "Previous hunk")
  if is_explorer_mode then
    bind("toggle_explorer", action(panes.toggle_explorer), "Toggle explorer visibility")
    bind("focus_explorer", action(panes.focus_explorer), "Focus explorer panel")
  end
  -- Conflict mappings replace do/dp without deleting the user's prior mappings.
  if not is_conflict then
    bind("diff_get", action(diffget.diff_get), is_inline and "Revert hunk to original" or "Get change from other buffer")
    bind("diff_put", action(diffget.diff_put), is_inline and "Accept change (no-op in inline)" or "Put change to other buffer")
  end
  bind("open_in_prev_tab", action(panes.open_in_prev_tab), "Open buffer in previous tab")
  bind("toggle_layout", function()
    require("codediff.ui.view").toggle_layout(tabpage)
  end, "Toggle diff layout")
  bind("toggle_compact", function()
    compact.toggle(tabpage)
  end, "Toggle compact mode")

  if is_explorer_mode then
    local toggle_stage = keymaps.toggle_stage
    local explorer_keymaps = resolve.keymaps_for("explorer")
    if not toggle_stage and explorer_keymaps.toggle_stage then
      toggle_stage = explorer_keymaps.toggle_stage
      vim.schedule(function()
        vim.notify("[codediff] keymaps.explorer.toggle_stage is deprecated. Please use keymaps.view.toggle_stage instead.", vim.log.levels.WARN)
      end)
    end
    if toggle_stage then
      lifecycle.set_tab_keymap(tabpage, "n", toggle_stage, action(stage.toggle_stage), { desc = "Toggle stage/unstage" })
    end
    bind("toggle_staged_view", action(stage.toggle_staged_view), "Toggle staged/unstaged view for current file")
  end
  bind("show_help", function()
    local ok, help = pcall(require, "codediff.ui.keymap_help")
    if ok and help then
      help.toggle(tabpage)
    else
      vim.notify_once("[codediff] failed to load codediff.ui.keymap_help: " .. tostring(help), vim.log.levels.WARN)
    end
  end, "Show keymap help")
  if is_explorer_mode or is_history then
    bind("next_file", navigation.next_file, "Next file")
    bind("prev_file", navigation.prev_file, "Previous file")
  end

  -- These keys belong only to diff buffers: S/U have different panel actions.
  local hunk_actions = {
    { "stage_hunk", hunk.stage_hunk, "Stage hunk under cursor" },
    { "unstage_hunk", hunk.unstage_hunk, "Unstage hunk under cursor" },
    { "discard_hunk", hunk.discard_hunk, "Discard hunk under cursor" },
    { "hunk_textobject", hunk.select_hunk, "Hunk textobject", { "o", "x" } },
  }
  for _, bufnr in pairs({ original_bufnr, modified_bufnr }) do
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      for _, entry in ipairs(hunk_actions) do
        if keymaps[entry[1]] then
          lifecycle.set_buf_keymap(tabpage, bufnr, entry[4] or "n", keymaps[entry[1]], action(entry[2]), {
            noremap = true,
            silent = true,
            nowait = true,
            desc = entry[3],
          })
        end
      end
    end
  end
  if not is_inline and config.options.diff.compute_moves then
    bind("align_move", action(move.align_move), "Align moved code block")
  end
  lifecycle.end_keymap_scope(tabpage, "view")
  compact.refresh(tabpage)
end

-- Resolve buffers at call time: file switches must not retain the old original.
function M.reapply(tabpage)
  local session = lifecycle.get_session(tabpage)
  if not session or not session.original_bufnr or not session.modified_bufnr then
    return
  end
  M.setup_all_keymaps(tabpage, session.original_bufnr, session.modified_bufnr, lifecycle.get_panel_name(tabpage) == "explorer")
  if session.merge then
    require("codediff.ui.conflict").setup_keymaps(tabpage)
  end
end

return M
