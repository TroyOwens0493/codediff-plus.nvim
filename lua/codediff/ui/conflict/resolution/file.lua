-- Resolve a whole file from the bottom up so edits cannot shift later blocks.
local M = {}
local common = require("codediff.ui.conflict.resolution.common")
local tracking = require("codediff.ui.conflict.tracking")
local combine = require("codediff.ui.conflict.resolution.combine")

local function resolve_all(tabpage, content, message, include_resolved)
  local session = common.session(tabpage)
  if not session or not common.has_conflicts(session) or not common.has_result(session) then
    return false
  end
  local count = 0
  vim.api.nvim_buf_call(session.result_bufnr, function()
    for i = #session.conflict_blocks, 1, -1 do
      local block = session.conflict_blocks[i]
      if include_resolved or tracking.is_block_active(session, block) then
        if count > 0 then
          pcall(vim.cmd, "undojoin")
        end
        common.apply(session, block, content(session, block))
        count = count + 1
      end
    end
  end)
  common.refresh(session)
  vim.notify(string.format(message, count), vim.log.levels.INFO)
  return count > 0
end

function M.accept_all_incoming(tabpage)
  return resolve_all(tabpage, function(session, block)
    return common.input_lines(session, block, 1)
  end, "[codediff] Accepted %d incoming change(s)")
end

function M.accept_all_current(tabpage)
  return resolve_all(tabpage, function(session, block)
    return common.input_lines(session, block, 2)
  end, "[codediff] Accepted %d current change(s)")
end

function M.accept_all_both(tabpage, first_input)
  return resolve_all(tabpage, function(session, block)
    -- Whole-file acceptance concatenates; only single-block acceptance uses smart merge.
    return combine.dumb_combine_inputs(common.input_lines(session, block, 1), common.input_lines(session, block, 2), first_input or 1)
  end, "[codediff] Accepted %d combined change(s)")
end

function M.discard_all(tabpage)
  -- Reset resolved blocks too. The written slice uses the true merge base.
  return resolve_all(tabpage, common.base_content, "[codediff] Reset %d conflict(s) to base", true)
end

return M
