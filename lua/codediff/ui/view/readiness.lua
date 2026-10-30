-- Waiting for both sides of a diff to arrive. Each side comes on its own
-- schedule -- one from a git fetch, the other from BufReadCmd, either first --
-- so whichever callback runs last has to start the render.

local M = {}

--- Wait for every named side, then run `on_ready` exactly once.
--- An empty list runs it immediately. Reporting a name twice, or one that was
--- never awaited, does nothing, so a duplicated event cannot render twice.
--- @param names string[] Sides to wait for, e.g. { "original", "modified" }
--- @param on_ready function Run once every name has been reported
--- @return table waiter With done(name) and pending()
function M.when_all(names, on_ready)
  local outstanding = {}
  local remaining = 0
  for _, name in ipairs(names) do
    if not outstanding[name] then
      outstanding[name] = true
      remaining = remaining + 1
    end
  end

  -- Reporting a name removes it, so the count can only reach zero once. No
  -- "already ran" flag: nothing can get past that to need one.
  local function fire_if_ready()
    if remaining > 0 then
      return
    end
    on_ready()
  end

  fire_if_ready()

  return {
    --- Report that `name` has arrived.
    --- @param name string
    done = function(name)
      if not outstanding[name] then
        return
      end
      outstanding[name] = nil
      remaining = remaining - 1
      fire_if_ready()
    end,

    --- True while any awaited side is still outstanding.
    --- @return boolean
    pending = function()
      return remaining > 0
    end,
  }
end
-- Register before loading starts. Info tables are read at event time because
-- :edit can replace their buffer handles while an asynchronous read is pending.
function M.when_virtual_loaded(group_name, infos, awaited, render, schedule_empty)
  if #awaited == 0 then
    if schedule_empty then
      vim.schedule(render)
    end
    return
  end
  local group = vim.api.nvim_create_augroup(group_name, { clear = true })
  local ready = M.when_all(awaited, function()
    vim.schedule(render)
    vim.api.nvim_del_augroup_by_id(group)
  end)
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeDiffVirtualFileLoaded",
    callback = function(event)
      local buf = event.data and event.data.buf
      if buf then
        for _, side in ipairs(awaited) do
          if buf == infos[side].bufnr then
            ready.done(side)
          end
        end
      end
    end,
  })
end

return M
