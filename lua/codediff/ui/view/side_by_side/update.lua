-- Keep the layout-specific module path available to existing callers.
local update = require("codediff.ui.view.update")
local M = {}

function M.update(tabpage, session_config, auto_scroll_to_first_hunk)
  return update.update(tabpage, session_config, auto_scroll_to_first_hunk, false)
end

return M
