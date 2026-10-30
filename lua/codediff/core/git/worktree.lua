-- Git index and working-tree write operations.
local M = {}

local run_git_async = require("codediff.core.git.runner").run_async

--- Apply a hunk patch to the index or working tree.
---@param git_root string
---@param patch string Unified diff, ending with a newline
---@param opts boolean|table? Legacy reverse flag, or { cached?: boolean, reverse?: boolean }; cached defaults to true
---@param callback fun(err: string?)
function M.apply_patch(git_root, patch, opts, callback)
  -- Support old signature: apply_patch(git_root, patch, reverse, callback)
  if type(opts) == "boolean" then
    opts = { cached = true, reverse = opts }
  end
  opts = opts or {}
  if opts.cached == nil then
    opts.cached = true
  end

  local args = { "apply", "--unidiff-zero", "-" }
  if opts.cached then
    table.insert(args, 2, "--cached")
  end
  if opts.reverse then
    table.insert(args, 2, "--reverse")
  end

  if vim.system then
    if git_root and vim.fn.isdirectory(git_root) == 0 then
      callback("Directory does not exist: " .. git_root)
      return
    end

    vim.system(vim.list_extend({ "git" }, args), {
      cwd = git_root,
      stdin = patch,
      text = true,
    }, function(result)
      vim.schedule(function()
        if result.code == 0 then
          callback(nil)
        else
          callback(result.stderr or "git apply failed")
        end
      end)
    end)
  else
    -- Fallback for older Neovim (< 0.10)
    local stderr_data = {}
    local stdin_pipe = vim.loop.new_pipe(false)
    local stderr_pipe = vim.loop.new_pipe(false)

    local handle
    ---@diagnostic disable-next-line: missing-fields
    handle = vim.loop.spawn("git", {
      args = args,
      cwd = git_root,
      stdio = { stdin_pipe, nil, stderr_pipe },
    }, function(code)
      if stdin_pipe then
        stdin_pipe:close()
      end
      if stderr_pipe then
        stderr_pipe:close()
      end
      if handle then
        handle:close()
      end

      vim.schedule(function()
        if code == 0 then
          callback(nil)
        else
          callback(table.concat(stderr_data) or "git apply failed")
        end
      end)
    end)

    if not handle then
      callback("Failed to spawn git process")
      return
    end

    if stderr_pipe then
      stderr_pipe:read_start(function(err, data)
        if data then
          table.insert(stderr_data, data)
        end
      end)
    end

    -- Write patch to stdin and close
    stdin_pipe:write(patch)
    stdin_pipe:shutdown()
  end
end

-- Share transport and error formatting; each operation keeps its Git arguments.
local function run_write(git_root, args, failure, callback)
  run_git_async(args, { cwd = git_root }, function(err)
    callback(err and (failure .. err) or nil)
  end)
end

function M.stage_file(git_root, rel_path, callback)
  run_write(git_root, { "add", "--", rel_path }, "Failed to stage file: ", callback)
end

function M.unstage_file(git_root, rel_path, callback)
  run_write(git_root, { "reset", "HEAD", "--", rel_path }, "Failed to unstage file: ", callback)
end

function M.stage_all(git_root, callback)
  run_write(git_root, { "add", "-A" }, "Failed to stage all files: ", callback)
end

function M.unstage_all(git_root, callback)
  run_write(git_root, { "reset", "HEAD" }, "Failed to unstage all files: ", callback)
end

-- Restore/discard changes to a file (git checkout -- or git restore)
-- git_root: absolute path to git repository root
-- rel_path: relative path from git root
-- source: optional revision to restore from (e.g. commit hash, "origin/HEAD")
-- callback: function(err)
function M.restore_file(git_root, rel_path, source, callback)
  -- Support old 3-arg signature: restore_file(git_root, rel_path, callback)
  if type(source) == "function" then
    callback = source
    source = nil
  end

  -- git restore is preferred (Git 2.23+), fallback to checkout
  local restore_args = { "restore" }
  if source then
    table.insert(restore_args, "--source=" .. source)
  end
  table.insert(restore_args, "--")
  table.insert(restore_args, rel_path)

  run_git_async(restore_args, { cwd = git_root }, function(err, _)
    if err then
      -- Fallback to git checkout for older git versions
      local checkout_args = { "checkout" }
      if source then
        table.insert(checkout_args, source)
      end
      table.insert(checkout_args, "--")
      table.insert(checkout_args, rel_path)

      run_git_async(checkout_args, { cwd = git_root }, function(err2, _)
        if err2 then
          callback("Failed to restore file: " .. err2)
        else
          callback(nil)
        end
      end)
    else
      callback(nil)
    end
  end)
end

-- Delete untracked file or directory (git clean -fd)
-- git_root: absolute path to git repository root
-- rel_path: relative path from git root
-- callback: function(err)
function M.delete_untracked(git_root, rel_path, callback)
  run_write(git_root, { "clean", "-fd", "--", rel_path }, "Failed to delete untracked file: ", callback)
end

return M
