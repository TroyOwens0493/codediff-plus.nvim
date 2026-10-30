-- Public layout entry point; creation shares its session and rendering flow.
local create = require("codediff.ui.view.create")
local M = {}

function M.create(session_config, filetype, on_ready)
  return create.create(session_config, filetype, on_ready, false)
end

return M
