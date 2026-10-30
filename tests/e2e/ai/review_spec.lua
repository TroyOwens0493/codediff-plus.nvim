local h = require("tests.support.e2e")
local support = require("tests.support")

for _, layout in ipairs({ "side-by-side", "inline" }) do
  describe("Guided review / " .. layout, function()
    local repo, screen, cache_dir
    before_each(function()
      repo = h.repo("basic")
      repo.replace("a.txt", 2, "working-A")
      repo.replace("b.txt", 2, "working-B")
      screen = h.screen("polling", layout, {
        ai = {
          enabled = true,
          command = { "python3", support.project_root .. "/tests/fixtures/ai/fake_codex.py", "ok" },
        },
      })
      cache_dir = vim.fn.tempname() .. "-review-cache"
      screen:exec("vim.env.XDG_CACHE_HOME = ...", { cache_dir })
      h.open(screen, repo, "CodeDiff", "a.txt")
    end)
    after_each(function()
      if screen then
        screen:close()
        screen = nil
      end
      if repo then
        repo.cleanup()
        repo = nil
      end
      if cache_dir then
        vim.fn.delete(cache_dir, "rf")
      end
    end)

    local function status()
      return screen:exec("return require('codediff').review_status()")
    end
    local function await_status(expected)
      screen:await(function()
        h.assert_no_errors(screen)
        local state = status()
        if state.status ~= expected and (state.status == "error" or state.status == "stale") then
          error(vim.inspect(state))
        end
        return state.status == expected
      end, "review did not become " .. expected)
    end
    local function start()
      screen:command("CodeDiffReview refresh")
      await_status("ready")
    end
    local function text()
      return screen:exec([[
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          local buf = vim.api.nvim_win_get_buf(win)
          if vim.bo[buf].filetype == 'codediff-review' then
            return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
          end
        end
        return ''
      ]])
    end

    local function changes(side)
      return screen:exec(
        [[
        local side = ...
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_get_name(buf):match('codediff%-review://.*/' .. side .. '$') then
            return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
          end
        end
        return ''
      ]],
        { side or "modified" }
      )
    end

    local function focus_code(side, text)
      screen:exec(
        [[
        local side, text = ...
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          local buf = vim.api.nvim_win_get_buf(win)
          if vim.api.nvim_buf_get_name(buf):match('/' .. side .. '$') then
            vim.api.nvim_set_current_win(win)
            for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
              if line == text then
                vim.api.nvim_win_set_cursor(win, { row, 0 })
                return
              end
            end
          end
        end
        error('Missing guided source: ' .. text)
      ]],
        { side, text }
      )
      screen:flush()
    end

    it("opens a named review tab with a stop sidebar, top summary, and scoped CodeDiff panes", function()
      local source = h.panes(screen)
      local count = screen:exec("return #vim.api.nvim_list_tabpages()")
      screen:exec("vim.o.showtabline = 2")
      start()
      assert.equals(count + 1, screen:exec("return #vim.api.nvim_list_tabpages()"))
      assert.equals("Guided Review", screen:exec("return vim.t.tabname"))
      assert.equals("codediff-review-stops", screen:exec("return vim.bo.filetype"))
      assert.equals(source.modified.buf, h.panes(screen).modified.buf)
      assert.same(source.modified.lines, h.panes(screen).modified.lines)
      assert.equals(2, status().count)
      assert.is_truthy(text():find("Review a.txt", 1, true))
      assert.is_nil(text():find("working-A", 1, true))
      assert.is_truthy(changes():find("working-A", 1, true))
      assert.is_nil(changes():find("working-B", 1, true))
      assert.is_truthy(text():find("a.txt:2", 1, true))
      assert.is_true(h.grid_contains(screen, "Guided Review"))
      assert.is_true(screen:exec(
        [[
        local layout = ...
        local namespace = layout == 'inline' and require('codediff.ui.inline').ns_inline or require('codediff.ui.highlights').ns_highlight
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          local buf = vim.api.nvim_win_get_buf(win)
          if vim.api.nvim_buf_get_name(buf):match('/modified$') then
            for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })) do
              if mark[4].hl_group == 'CodeDiffLineInsert' then return true end
            end
          end
        end
        return false
      ]],
        { layout }
      ))
      assert.is_true(screen:exec([[
        local summary, stops, diff
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          local ft = vim.bo[vim.api.nvim_win_get_buf(win)].filetype
          if ft == 'codediff-review' then summary = win
          elseif ft == 'codediff-review-stops' then stops = win
          elseif ft == 'codediff-review-diff' then diff = win end
          assert(ft ~= 'codediff-explorer')
        end
        return summary and stops and diff and vim.api.nvim_win_get_position(summary)[1] < vim.api.nvim_win_get_position(diff)[1]
          and vim.api.nvim_win_get_position(stops)[2] < vim.api.nvim_win_get_position(diff)[2]
          and vim.api.nvim_win_get_height(summary) <= 7
      ]]))
      assert.same(
        { ["]c"] = "Next hunk", ["[c"] = "Previous hunk", [" v"] = "Mark review stop as reviewed" },
        screen:exec([[
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          local buf = vim.api.nvim_win_get_buf(win)
          if vim.bo[buf].filetype == 'codediff-review-stops' then
            local maps = {}
            for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do maps[map.lhs] = map.desc end
            return maps
          end
        end
      ]])
      )
      screen:exec("require('codediff').review_mark_seen()")
      screen:command("CodeDiffReview next")
      screen:await(function()
        return changes():find("working-B", 1, true) ~= nil and changes():find("working-A", 1, true) == nil
      end, "next step did not open b.txt at its excerpt")
      assert.equals(2, status().position)
      assert.is_truthy(status().seen[1])
      screen:command("CodeDiffReview prev")
      screen:await(function()
        return changes():find("working-A", 1, true) ~= nil
      end, "previous step did not restore a.txt")
      assert.equals(1, status().position)
      assert.is_false(screen:exec("return require('codediff').review_prev()"))
      h.assert_no_errors(screen)
    end)

    it("marks the current stop as reviewed from every pane with leader v", function()
      start()
      local wins = screen:exec("return vim.api.nvim_tabpage_list_wins(0)")
      for _, win in ipairs(wins) do
        screen:exec(
          [[
          vim.api.nvim_set_current_win(...)
          require('codediff').review_mark_seen(false)
        ]],
          { win }
        )
        h.feed(screen, "<Space>v")
        assert.is_true(status().seen[1])
        assert.is_nil(status().seen[2])
        assert.equals(1, status().position)
        assert.equals(win, screen:exec("return vim.api.nvim_get_current_win()"))
        assert.is_true(screen:exec([[
          for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            local buf = vim.api.nvim_win_get_buf(win)
            if vim.bo[buf].filetype == 'codediff-review-stops' then
              return vim.api.nvim_buf_get_lines(buf, 3, 4, false)[1]:find('[x]', 1, true) ~= nil
            end
          end
          return false
        ]]))
        h.feed(screen, "<Space>v")
        assert.is_true(status().seen[1])
      end
      screen:command("CodeDiffReview next")
      h.feed(screen, "<Space>v")
      assert.is_true(status().seen[2])
      h.assert_no_errors(screen)
    end)

    it("navigates changed blocks from every review pane and respects hunk cycling", function()
      screen:exec("require('codediff.config').options.ai.command[3] = 'grouped_guide'")
      start()
      local function current_line()
        return screen:exec("return vim.api.nvim_get_current_line()")
      end
      -- Generation leaves focus in the stop list; navigation enters the code pane.
      h.feed(screen, "]c")
      assert.equals("working-A", current_line())
      h.feed(screen, "]c")
      assert.equals("working-B", current_line())
      h.feed(screen, "[c")
      assert.equals("working-A", current_line())
      h.feed(screen, "[c")
      assert.equals("working-B", current_line())
      h.feed(screen, "]c")
      assert.equals("working-A", current_line())
      screen:exec([[
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'codediff-review' then
            vim.api.nvim_set_current_win(win)
            return
          end
        end
      ]])
      h.feed(screen, "]c")
      assert.equals("working-B", current_line())
      screen:exec("require('codediff.config').options.diff.cycle_next_hunk = false")
      h.feed(screen, "]c")
      assert.equals("working-B", current_line())
      assert.is_false(screen:exec("return require('codediff').next_hunk()"))
      assert.is_true(screen:exec("return require('codediff').prev_hunk()"))
      assert.equals("working-A", current_line())
      h.feed(screen, "[c")
      assert.equals("working-A", current_line())
      if layout == "side-by-side" then
        focus_code("original", "base-A")
        h.feed(screen, "]c")
        assert.equals("base-B", current_line())
        h.feed(screen, "[c")
        assert.equals("base-A", current_line())
      end
      assert.equals(1, status().position)
      screen:command("CodeDiffReview close")
      h.focus(screen, "modified", 1)
      assert.is_true(screen:exec("return require('codediff').next_hunk()"))
      h.assert_no_errors(screen)
    end)

    it("navigates separate changes in the same file without changing review stops", function()
      repo.replace("hunks.txt", 1, "working-one")
      repo.replace("hunks.txt", 12, "working-two")
      screen:exec("require('codediff.config').options.ai.command[3] = 'grouped_guide'")
      start()
      focus_code("modified", "working-one")
      h.feed(screen, "]c")
      assert.equals("working-two", screen:exec("return vim.api.nvim_get_current_line()"))
      h.feed(screen, "[c")
      assert.equals("working-one", screen:exec("return vim.api.nvim_get_current_line()"))
      assert.equals(1, status().position)
      h.assert_no_errors(screen)
    end)

    it("uses configured hunk keys and keeps disabled mappings out of review buffers", function()
      screen:exec([[
        local config = require('codediff.config').options
        config.ai.command[3] = 'grouped_guide'
        config.keymaps.view.next_hunk = { ']h', ']j' }
        config.keymaps.view.prev_hunk = false
      ]])
      start()
      assert.same(
        { ["]h"] = true, ["]j"] = true, [" v"] = true },
        screen:exec([[
        local maps = {}
        for _, map in ipairs(vim.api.nvim_buf_get_keymap(0, 'n')) do maps[map.lhs] = true end
        return maps
      ]])
      )
      h.feed(screen, "]h")
      assert.equals("working-A", screen:exec("return vim.api.nvim_get_current_line()"))
      h.feed(screen, "]j")
      assert.equals("working-B", screen:exec("return vim.api.nvim_get_current_line()"))
      screen:command("CodeDiffReview close")
      screen:command("CodeDiffReview start")
      await_status("ready")
      h.feed(screen, "]h")
      assert.equals("working-A", screen:exec("return vim.api.nvim_get_current_line()"))
      h.assert_no_errors(screen)
    end)

    it("navigates added and deleted blocks and does not navigate a stale guide", function()
      repo.command({ "rm", "-f", "a.txt" })
      repo.write_file("new.txt", { "new file content" })
      screen:exec("require('codediff.config').options.ai.command[3] = 'grouped_guide'")
      start()
      -- Unstaged files come before the staged deletion.
      for _, expected in ipairs({ "working-B", "new file content", "", "working-B" }) do
        h.feed(screen, "]c")
        assert.equals(expected, screen:exec("return vim.api.nvim_get_current_line()"))
      end
      if layout == "side-by-side" then
        focus_code("original", "base-A")
        h.feed(screen, "]c")
        assert.equals("base-B", screen:exec("return vim.api.nvim_get_current_line()"))
        h.feed(screen, "]c")
        assert.equals("", screen:exec("return vim.api.nvim_get_current_line()"))
        h.feed(screen, "[c")
        assert.equals("base-B", screen:exec("return vim.api.nvim_get_current_line()"))
      end
      repo.replace("b.txt", 2, "newer-B")
      await_status("stale")
      local cursor = screen:exec("return vim.api.nvim_win_get_cursor(0)")
      h.feed(screen, "]c")
      h.feed(screen, "[c")
      assert.same(cursor, screen:exec("return vim.api.nvim_win_get_cursor(0)"))
      assert.is_false(screen:exec("return require('codediff').next_hunk()"))
      h.assert_no_errors(screen)
    end)

    it("preserves relative numbers and updates the source gutter as the cursor moves", function()
      screen:exec([[
        local session = refresh_session()
        vim.wo[session.modified_win].relativenumber = true
        if session.layout == 'side-by-side' then
          vim.wo[session.original_win].relativenumber = false
        end
        vim.api.nvim_set_current_win(session.panel.view.winid)
      ]])
      start()
      focus_code("modified", "working-A")
      assert.is_true(screen:exec("return vim.wo.relativenumber"))
      local function expect_number(side, text, expected)
        screen:flush()
        local position = screen:exec(
          [[
          local side, text = ...
          for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            local buf = vim.api.nvim_win_get_buf(win)
            if vim.api.nvim_buf_get_name(buf):match('/' .. side .. '$') then
              for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
                if line == text then return vim.fn.screenpos(win, row, 1) end
              end
            end
          end
          error('Missing numbered source: ' .. text)
        ]],
          { side, text }
        )
        assert.equals(string.format("%5s ", expected), screen:text(position.row, position.col - 6, 6))
      end
      expect_number("modified", "working-A", 2)
      expect_number("modified", "context", 1)
      expect_number("modified", "end", 2)
      h.feed(screen, "j")
      expect_number("modified", "working-A", 1)
      expect_number("modified", "context", 3)
      if layout == "side-by-side" then
        expect_number("original", "context", 3)
        focus_code("original", "base-A")
        assert.is_false(screen:exec("return vim.wo.relativenumber"))
        screen:command("setlocal relativenumber")
        expect_number("original", "context", 1)
        expect_number("modified", "context", 3)
        focus_code("modified", "context")
      end
      screen:command("setlocal norelativenumber")
      expect_number("modified", "working-A", 2)
      expect_number("modified", "end", 4)
      screen:command("setlocal relativenumber nonumber")
      expect_number("modified", "context", 0)
      screen:command("CodeDiffReview next")
      focus_code("modified", "working-B")
      expect_number("modified", "working-B", 0)
      expect_number("modified", "end", 1)
      h.assert_no_errors(screen)
    end)

    it("renders source syntax colors in the guided code pane", function()
      repo.replace("sample.lua", 1, "local value = 'working'")
      screen:exec("vim.api.nvim_set_hl(0, '@keyword.lua', { fg = 0xff3366 })")
      start()
      screen:exec([[
        for index, step in ipairs(require('codediff').review_steps()) do
          if step.title == 'Review sample.lua' then
            assert(require('codediff').review_select(index))
            return
          end
        end
        error('No Lua review step')
      ]])
      screen:await(function()
        return changes():find("local value = 'working'", 1, true) ~= nil
      end, "Lua stop did not appear")
      screen:flush()
      local position = screen:exec([[
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          local buf = vim.api.nvim_win_get_buf(win)
          if vim.api.nvim_buf_get_name(buf):match('/modified$') then
            for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
              if line == "local value = 'working'" then return vim.fn.screenpos(win, row, 1) end
            end
          end
        end
      ]])
      assert.equals("local", screen:text(position.row, position.col, 5))
      assert.equals(0xff3366, screen:foreground(position.row, position.col))
      screen:exec([[
        vim.api.nvim_set_hl(0, '@keyword.lua', { fg = 0x33ff66 })
        vim.api.nvim_exec_autocmds('ColorScheme', { pattern = 'review-test' })
      ]])
      screen:flush()
      assert.equals(0x33ff66, screen:foreground(position.row, position.col))
      if layout == "inline" then
        assert.is_true(screen:exec([[
          for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            local buf = vim.api.nvim_win_get_buf(win)
            if vim.api.nvim_buf_get_name(buf):match('/modified$') then
              local ns = require('codediff.ui.inline').ns_inline
              for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
                for _, chunks in ipairs(mark[4].virt_lines or {}) do
                  for _, chunk in ipairs(chunks) do
                    if chunk[1] == 'local' and vim.api.nvim_get_hl(0, { name = chunk[2], link = false }).fg == 0x33ff66 then
                      return true
                    end
                  end
                end
              end
            end
          end
          return false
        ]]))
      end
      h.assert_no_errors(screen)
    end)

    it("saves progress across closing and reopening, and exposes independent copies", function()
      start()
      screen:command("CodeDiffReview step 2")
      screen:await(function()
        return changes():find("working-B", 1, true) ~= nil
      end, "step selection did not finish")
      screen:command("CodeDiffReview seen")
      screen:exec([[
        local steps = require('codediff').review_steps()
        steps[1].title = 'mutated outside'
        assert(require('codediff').review_steps()[1].title ~= 'mutated outside')
      ]])
      screen:command("CodeDiffReview close")
      assert.equals("", text())
      screen:exec("require('codediff.review').close(nil, true)")
      screen:command("CodeDiffReview start")
      await_status("ready")
      assert.equals(2, status().position)
      assert.is_truthy(status().seen[2])
      screen:command("CodeDiffReview unseen")
      assert.is_nil(status().seen[2])
    end)

    it("selects a stop from the sidebar without a custom keyboard mapping", function()
      start()
      screen:exec([[
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'codediff-review-stops' then
            vim.api.nvim_set_current_win(win)
            vim.api.nvim_win_set_cursor(win, { 5, 0 })
            return
          end
        end
      ]])
      screen:await(function()
        return status().position == 2
      end, "sidebar selection did not select stop two")
      assert.is_truthy(changes():find("working-B", 1, true))
      assert.is_nil(changes():find("working-A", 1, true))
    end)

    it("closes the review tab without changing the original comparison", function()
      local source = h.panes(screen)
      local count = screen:exec("return #vim.api.nvim_list_tabpages()")
      local tabline = screen:exec("return vim.o.tabline")
      start()
      screen:command("CodeDiffReview step 2")
      screen:await(function()
        return changes():find("working-B", 1, true) ~= nil
      end, "stop two did not load")
      screen:command("CodeDiffReview close")
      assert.equals(count, screen:exec("return #vim.api.nvim_list_tabpages()"))
      assert.equals(source.tab, screen:exec("return vim.api.nvim_get_current_tabpage()"))
      assert.same(source.original.lines, h.panes(screen).original.lines)
      assert.same(source.modified.lines, h.panes(screen).modified.lines)
      assert.equals(tabline, screen:exec("return vim.o.tabline"))
      h.assert_no_errors(screen)
    end)

    it("answers a question about the active step", function()
      start()
      screen:command("CodeDiffReview ask Why does this change?")
      screen:await(function()
        return text():find("A: Based on the supplied diff: Why does this change?", 1, true) ~= nil
      end, "answer did not appear")
      assert.equals("ready", status().status)
      h.assert_no_errors(screen)
    end)

    it("cleans up the whole review when a review split is closed", function()
      local source_tab = screen:exec("return vim.api.nvim_get_current_tabpage()")
      start()
      screen:exec([[
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'codediff-review' then
            vim.api.nvim_set_current_win(win)
            vim.cmd('close')
            return
          end
        end
      ]])
      screen:await(function()
        return screen:exec("return vim.api.nvim_get_current_tabpage()") == source_tab
      end, "closing a summary split did not close the review")
      assert.is_false(status().open)
      assert.is_true(screen:exec([[
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_get_name(buf):match('^codediff%-review://') then return false end
        end
        return true
      ]]))
      h.assert_no_errors(screen)
    end)

    it("restores a saved guide in a new Neovim process without another AI request", function()
      start()
      screen:command("CodeDiffReview step 2")
      screen:await(function()
        return changes():find("working-B", 1, true) ~= nil
      end, "step selection did not finish")
      screen:command("CodeDiffReview seen")
      screen:close()
      screen = h.screen("polling", layout, {
        ai = {
          enabled = true,
          command = { "python3", support.project_root .. "/tests/fixtures/ai/fake_codex.py", "failed" },
        },
      })
      screen:exec("vim.env.XDG_CACHE_HOME = ...", { cache_dir })
      h.open(screen, repo, "CodeDiff", "a.txt")
      screen:command("CodeDiffReview start")
      await_status("ready")
      assert.equals(2, status().position)
      assert.is_truthy(status().seen[2])
      h.assert_no_errors(screen)
    end)

    it("excludes generated files after generation and after restoring a saved guide", function()
      repo.write_file("package-lock.json", { '{"lockfileVersion": 3}' })
      screen:exec("require('codediff.config').options.ai.command[3] = 'generated_guide'")
      h.expect_panel(screen, "package-lock.json", true)
      start()
      local function assert_source_steps()
        local steps = screen:exec("return require('codediff').review_steps()")
        assert.equals(2, #steps)
        assert.is_nil(vim.inspect(steps):find("package-lock.json", 1, true))
        assert.equals("Review a.txt", steps[1].title)
        assert.equals("Review b.txt", steps[2].title)
      end
      assert_source_steps()
      screen:close()
      screen = h.screen("polling", layout, {
        ai = {
          enabled = true,
          command = { "python3", support.project_root .. "/tests/fixtures/ai/fake_codex.py", "failed" },
        },
      })
      screen:exec("vim.env.XDG_CACHE_HOME = ...", { cache_dir })
      h.open(screen, repo, "CodeDiff", "a.txt")
      screen:command("CodeDiffReview start")
      await_status("ready")
      assert_source_steps()
      h.assert_no_errors(screen)
    end)

    it("marks the guide stale when another file changes and blocks navigation", function()
      start()
      repo.replace("b.txt", 2, "newer-B")
      await_status("stale")
      assert.is_false(screen:exec("return require('codediff').review_next()"))
      assert.is_nil(text():find("2 │ working-A", 1, true))
      screen:command("CodeDiffReview refresh")
      await_status("ready")
      screen:command("CodeDiffReview next")
      screen:await(function()
        return changes():find("newer-B", 1, true) ~= nil
      end, "refreshed guide did not use current code")
    end)

    it("cancels an in-flight guide and does not reopen a closed panel", function()
      screen:exec("require('codediff.config').options.ai.command[3] = 'slow'")
      screen:command("CodeDiffReview refresh")
      assert.equals("loading", status().status)
      screen:command("CodeDiffReview cancel")
      await_status("cancelled")
      screen:command("CodeDiffReview close")
      vim.wait(500)
      assert.equals("", text())
      assert.equals("cancelled", status().status)
      h.assert_no_errors(screen)
    end)

    it("detects a new file while the original comparison tab is suspended", function()
      start()
      repo.write_file("later.txt", { "added after the tour" })
      await_status("stale")
      assert.is_nil(changes():find("working-A", 1, true))
      screen:command("CodeDiffReview refresh")
      await_status("ready")
      assert.equals(3, status().count)
      h.assert_no_errors(screen)
    end)

    it("rejects invalid excerpts and displays provider errors", function()
      for _, scenario in ipairs({ "bad_guide", "failed" }) do
        screen:exec("require('codediff.ai.provider').stop(); require('codediff.config').options.ai.command[3] = ...", { scenario })
        screen:command("CodeDiffReview refresh")
        await_status("error")
        assert.is_truthy(text():find(scenario == "failed" and "Usage limit reached" or "invalid review guide", 1, true))
      end
      h.assert_no_errors(screen)
    end)

    it("discards inference if an unselected file changes, and cleans up when disabled", function()
      screen:exec([[
        require('codediff.config').options.ai.command[3] = 'slow'
        local provider = require('codediff.ai.provider')
        local review = provider.review
        provider.review = function(...)
          refresh_test.guide_requested = true
          return review(...)
        end
      ]])
      screen:command("CodeDiffReview refresh")
      screen:await(function()
        return screen:exec("return refresh_test.guide_requested == true")
      end, "inference never started")
      repo.replace("b.txt", 2, "changed-during-generation")
      await_status("stale")
      screen:exec("require('codediff').setup({ ai = { enabled = false } })")
      assert.equals("idle", status().status)
      assert.equals("", text())
      h.assert_no_errors(screen)
    end)

    it("reviews deleted and added files using the correct source side", function()
      repo.command({ "rm", "-f", "a.txt" })
      repo.write_file("new.txt", { "new file content" })
      h.idle(screen)
      screen:await(function()
        return screen:exec([[
          for _, file in ipairs(refresh_session().panel.data.status_result.unstaged) do
            if file.path == 'new.txt' then return true end
          end
          return false
        ]])
      end, "new file did not appear")
      h.idle(screen)
      start()
      local locations = screen:exec([[
        local locations = {}
        for index, step in ipairs(require('codediff').review_steps()) do
          for _, excerpt in ipairs(step.excerpts) do
            locations[excerpt.path] = { step = index, side = excerpt.side }
          end
        end
        return locations
      ]])
      assert.equals("original", locations["a.txt"].side)
      assert.equals("modified", locations["new.txt"].side)
      screen:command("CodeDiffReview step " .. locations["a.txt"].step)
      screen:await(function()
        return changes("original"):find("delete", 1, true) ~= nil or changes("original"):find("base-A", 1, true) ~= nil
      end, "deleted source was not shown")
      screen:command("CodeDiffReview step " .. locations["new.txt"].step)
      screen:await(function()
        return changes():find("new file content", 1, true) ~= nil
      end, "added file did not open")
      h.assert_no_errors(screen)
    end)
  end)
end
