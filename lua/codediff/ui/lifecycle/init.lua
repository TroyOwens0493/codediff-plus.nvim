-- Public session API. State and cleanup expose only the entries listed here.
local state = require("codediff.ui.lifecycle.state")
local session = require("codediff.ui.lifecycle.session")
local cleanup = require("codediff.ui.lifecycle.cleanup")
local M = {
  clear_highlights = state.clear_buffer_highlights,
  create_session = session.create_session,
  setup_autocmds = cleanup.setup_autocmds,
  cleanup = cleanup.cleanup,
  close = cleanup.close,
  cleanup_all = cleanup.cleanup_all,
  setup = cleanup.setup,
}

for _, module in ipairs({ "accessors", "keymaps" }) do
  for name, fn in pairs(require("codediff.ui.lifecycle." .. module)) do
    M[name] = fn
  end
end

return M
