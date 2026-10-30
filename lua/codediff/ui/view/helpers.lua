-- Buffer preparation helpers for diff view
local M = {}

local virtual_file = require("codediff.core.virtual_file")
local path = require("codediff.core.path")

--- True when the panel opens before any file is chosen, so the panes start
--- empty and the panel fills them on first selection.
--- @param session_config SessionConfig
--- @return boolean
function M.is_panel_placeholder(session_config)
  local panel_cfg = session_config.panel
  if not panel_cfg then
    return false
  end
  if panel_cfg.name == "history" then
    return panel_cfg.data ~= nil
  end
  if panel_cfg.name == "explorer" then
    -- Empty paths, or dir mode, which has no git_root but does have panel data.
    return path.is_empty(session_config.original) or (not session_config.git_root and panel_cfg.data ~= nil)
  end
  return false
end

-- Helper: Check if revision is virtual (commit hash or STAGED)
-- Virtual: "STAGED" or commit hash | Real: nil or "WORKING"
function M.is_virtual_revision(revision)
  return revision ~= nil and revision ~= "WORKING"
end

-- Exact buffer name lookup (vim.fn.bufnr uses pattern matching which
-- causes prefix collisions, e.g. "Makefile" matching "Makefile.win")
local function bufnr_exact(name)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) == name then
      return buf
    end
  end
  return -1
end

-- Return a buffer to reuse, or an edit target to load. Mutable Git stages always reload.
---@param is_virtual boolean
---@param git_root string?
---@param revision string?
---@param ref Path `.relative` builds the codediff:// URL; `.absolute` identifies the real file
function M.prepare_buffer(is_virtual, git_root, revision, ref)
  if not is_virtual and ref.absolute == "" then
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    return { bufnr = buf, needs_edit = false }
  end
  local target = is_virtual and virtual_file.create_url(git_root, revision, ref.relative) or ref.absolute
  local existing = bufnr_exact(target)
  -- Index and merge stages can change; commits can reuse their buffer contents.
  local mutable = is_virtual and (revision == ":0" or revision == ":1" or revision == ":2" or revision == ":3")
  local needs_edit = existing == -1 or mutable
  return {
    bufnr = existing ~= -1 and existing or nil,
    target = (is_virtual or needs_edit) and target or nil,
    needs_edit = needs_edit,
  }
end

--- Check this buffer's timestamp before showing it. silent! suppresses E211
--- for files deleted outside Neovim; changed files still reload. Scope checktime
--- to this buffer so it does not reload unrelated files.
---@param win number Window handle
---@param bufnr number Buffer handle backed by a real file on disk
function M.show_real_file_buffer(win, bufnr)
  -- Only normal (file-backed) buffers are timestamp-checked by Neovim; scratch
  -- and codediff:// buffers are skipped, so don't bother them.
  if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].buftype == "" then
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local file = vim.api.nvim_buf_get_name(bufnr)
    -- A clean BufNewFile buffer needs an explicit read when the file appears:
    -- checktime asks W13 instead of reloading it, even with autoread enabled.
    if not vim.bo[bufnr].modified and #lines == 1 and lines[1] == "" and vim.fn.filereadable(file) == 1 then
      vim.api.nvim_buf_call(bufnr, function()
        vim.cmd("silent edit!")
      end)
    else
      pcall(vim.cmd, "silent! checktime " .. bufnr)
    end
  end
  vim.api.nvim_win_set_buf(win, bufnr)
end

--- Load and show a real file. Use :edit for new buffers: bufload followed by
--- display can mark them modified and prevent later reloads. Reuse loaded
--- buffers to handle equivalent path spellings and deleted files without E211.
---@param win number Window handle
---@param target string Absolute path of the file to load
---@return number bufnr
function M.open_real_file(win, target)
  local bufnr = vim.fn.bufadd(target)
  if vim.api.nvim_buf_is_loaded(bufnr) then
    M.show_real_file_buffer(win, bufnr)
    return bufnr
  end

  vim.api.nvim_set_current_win(win)
  vim.cmd("edit " .. vim.fn.fnameescape(target))
  return vim.api.nvim_get_current_buf()
end

-- Replace generated content without changing the buffer's editing permissions.
function M.set_lines(buf, lines)
  if vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines) then
    return
  end
  local modifiable, readonly = vim.bo[buf].modifiable, vim.bo[buf].readonly
  vim.bo[buf].modifiable, vim.bo[buf].readonly = true, false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable, vim.bo[buf].readonly = modifiable, readonly
end

-- Install a resolved input in the existing pane, without reopening the view.
function M.update_content(session, side, input, lines)
  local buf = session[side .. "_bufnr"]
  if not input.path or input.path.absolute == "" then
    return buf
  end
  if not M.is_virtual_revision(input.revision) then
    if vim.bo[buf].buftype ~= "" then
      M.set_lines(buf, lines)
    end
    return buf
  end
  if input.resolved ~= session[side .. "_revision"] then
    local name = virtual_file.create_url(session.git_root, input.resolved, input.path.relative)
    local existing = bufnr_exact(name)
    if existing ~= -1 and vim.api.nvim_buf_is_loaded(existing) then
      buf = existing
    else
      buf = vim.api.nvim_create_buf(false, true)
      if existing == -1 then
        vim.api.nvim_buf_set_name(buf, name)
      end
      vim.bo[buf].buftype = "nowrite"
      vim.bo[buf].bufhidden = "hide"
      vim.bo[buf].swapfile = false
    end
    local win = session[side .. "_win"]
    local hidden = side == "original" and session.layout == "inline" and session.single_side ~= "original"
    if win and vim.api.nvim_win_is_valid(win) and not hidden then
      vim.api.nvim_win_set_buf(win, buf)
      vim.bo[buf].bufhidden = "wipe"
    end
  end
  virtual_file.set_content(buf, lines, input.path.relative)
  session[side .. "_revision"] = input.resolved
  return buf
end

function M.load_visible_side(win, info, is_virtual)
  if is_virtual then
    if info.needs_edit then
      vim.cmd("edit! " .. vim.fn.fnameescape(info.target))
      info.bufnr = vim.api.nvim_get_current_buf()
    else
      vim.api.nvim_win_set_buf(win, info.bufnr)
    end
  elseif info.needs_edit then
    info.bufnr = M.open_real_file(win, info.target)
  else
    M.show_real_file_buffer(win, info.bufnr)
  end
end

return M
