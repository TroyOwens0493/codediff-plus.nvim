-- Test: ui/inline.lua - Inline diff rendering logic
-- Tests for single-buffer inline diff with virtual line overlays

local inline = require("codediff.ui.inline")
local highlights = require("codediff.ui.highlights")
local diff = require("codediff.core.diff")

describe("Partial-line character highlights", function()
  local config = require("codediff.config")
  local core = require("codediff.ui.core")
  local previous
  local buffers

  before_each(function()
    previous = config.options.highlights.char_whole_line
    config.options.highlights.char_whole_line = false
    buffers = {}
    highlights.setup()
  end)

  after_each(function()
    config.options.highlights.char_whole_line = previous
    for _, buf in ipairs(buffers) do
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  local function render(layout, original, modified, result)
    local function buffer(lines)
      local buf = vim.api.nvim_create_buf(false, true)
      table.insert(buffers, buf)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      return buf
    end

    local left, right = buffer(original), buffer(modified)
    result = result or diff.compute_diff(original, modified)
    local changed = { original = {}, modified = {} }
    local function collect(buf, namespace, side, lines, group)
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })) do
        local details = mark[4]
        if details.hl_group == group then
          assert.equals(mark[2], details.end_row, "Character highlight must stay within a line")
          table.insert(changed[side], lines[mark[2] + 1]:sub(mark[3] + 1, details.end_col))
        end
        for _, chunks in ipairs(details.virt_lines or {}) do
          for _, chunk in ipairs(chunks) do
            if chunk[2] == "CodeDiffCharDelete" then
              table.insert(changed.original, chunk[1])
            end
          end
        end
      end
    end

    if layout == "inline" then
      inline.render_inline_diff(right, result, original, modified)
      collect(right, inline.ns_inline, "modified", modified, "CodeDiffCharInsert")
    else
      core.render_diff(left, right, original, modified, result)
      collect(left, highlights.ns_highlight, "original", original, "CodeDiffCharDelete")
      collect(right, highlights.ns_highlight, "modified", modified, "CodeDiffCharInsert")
    end
    return changed
  end

  for _, layout in ipairs({ "inline", "side-by-side" }) do
    describe(layout, function()
      it("omits character highlights for complete added and deleted lines", function()
        assert.same({ original = {}, modified = {} }, render(layout, { "keep" }, { "keep", "added" }))
        assert.same({ original = {}, modified = {} }, render(layout, { "keep", "deleted" }, { "keep" }))
        assert.same({ original = {}, modified = {} }, render(layout, { "abc" }, { "XYZ" }))
      end)

      it("keeps character highlights for edits within Unicode text", function()
        assert.same({ original = { "1" }, modified = { "2" } }, render(layout, { "😀 café 1" }, { "😀 café 2" }))
      end)

      it("skips full interior lines while keeping partial ends of a multiline change", function()
        local range = { start_line = 1, start_col = 7, end_line = 3, end_col = 4 }
        local result = {
          changes = { {
            original = { start_line = 1, end_line = 4 },
            modified = { start_line = 1, end_line = 4 },
            inner_changes = { { original = range, modified = range } },
          } },
        }
        assert.same(
          { original = { "OLD", "OLD" }, modified = { "NEW", "NEW" } },
          render(layout, { "prefixOLD", "removed😀", "OLDsuffix" }, { "prefixNEW", "added😀", "NEWsuffix" }, result)
        )
      end)

      it("can retain whole-line character highlights with the option enabled", function()
        config.options.highlights.char_whole_line = true
        local changed = render(layout, { "abc" }, { "XYZ" })
        assert.same({ original = { "abc" }, modified = { "XYZ" } }, changed)
      end)
    end)
  end
end)

describe("Inline Diff Rendering", function()
  before_each(function()
    highlights.setup()
  end)

  it("hides deleted rows on re-render while keeping current text and change highlights", function()
    local config = require("codediff.config")
    local previous = config.options.diff.show_deleted_lines
    local buf = vim.api.nvim_create_buf(false, true)
    local original = { "keep", "value = 1", "removed", "end" }
    local modified = { "keep", "value = 2", "end" }
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, modified)
    local result = diff.compute_diff(original, modified)

    config.options.diff.show_deleted_lines = true
    inline.render_inline_diff(buf, result, original, modified)
    config.options.diff.show_deleted_lines = false
    inline.render_inline_diff(buf, result, original, modified)
    config.options.diff.show_deleted_lines = previous

    local marks = vim.api.nvim_buf_get_extmarks(buf, inline.ns_inline, 0, -1, { details = true })
    local has_line_highlight, has_char_highlight = false, false
    for _, mark in ipairs(marks) do
      assert.is_nil(mark[4].virt_lines)
      has_line_highlight = has_line_highlight or mark[4].hl_group == "CodeDiffLineInsert"
      has_char_highlight = has_char_highlight or mark[4].hl_group == "CodeDiffCharInsert"
    end
    assert.is_true(has_line_highlight)
    assert.is_true(has_char_highlight)
    assert.same(modified, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("hides pure deletions at the start and end of a file", function()
    local config = require("codediff.config")
    local previous = config.options.diff.show_deleted_lines
    local buf = vim.api.nvim_create_buf(false, true)
    local original = { "removed first", "keep", "removed last" }
    local modified = { "keep" }
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, modified)

    config.options.diff.show_deleted_lines = false
    inline.render_inline_diff(buf, diff.compute_diff(original, modified), original, modified)
    config.options.diff.show_deleted_lines = previous

    assert.same({}, vim.api.nvim_buf_get_extmarks(buf, inline.ns_inline, 0, -1, { details = true }))
    assert.same(modified, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("marks added and deleted lines when gutter signs are enabled", function()
    local config = require("codediff.config")
    local previous = config.options.diff.gutter_signs
    config.options.diff.gutter_signs = { insert_text = "+", delete_text = "-", highlight_numbers = true }
    local buf = vim.api.nvim_create_buf(false, true)
    local original = { "keep", "removed", "end" }
    local modified = { "keep", "inserted", "end" }
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, modified)

    inline.render_inline_diff(buf, diff.compute_diff(original, modified), original, modified)
    config.options.diff.gutter_signs = previous

    local signs_ns = vim.api.nvim_create_namespace("codediff-gutter-signs")
    local signs = vim.api.nvim_buf_get_extmarks(buf, signs_ns, 0, -1, { details = true })
    assert.equals(1, #signs)
    assert.equals(1, signs[1][2])
    assert.equals("+", vim.trim(signs[1][4].sign_text))
    assert.equals("CodeDiffGutterInsertNumber", signs[1][4].number_hl_group)

    local marks = vim.api.nvim_buf_get_extmarks(buf, inline.ns_inline, 0, -1, { details = true })
    local deleted
    for _, mark in ipairs(marks) do
      if mark[4].virt_lines then
        deleted = mark[4].virt_lines[1]
      end
    end
    assert.same({ "- ", "CodeDiffGutterDelete" }, deleted[1])
    assert.equals("removed", table.concat(vim.tbl_map(function(chunk)
      return chunk[1]
    end, vim.list_slice(deleted, 2))):gsub(" +$", ""))

    inline.clear(buf)
    assert.same({}, vim.api.nvim_buf_get_extmarks(buf, signs_ns, 0, -1, {}))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- Test 1: Added lines get highlight extmarks
  it("highlights added lines on modified buffer", function()
    local buf = vim.api.nvim_create_buf(false, true)

    local original = { "line 1", "line 2" }
    local modified = { "line 1", "line 2", "line 3" }

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    inline.render_inline_diff(buf, lines_diff, original, modified)

    -- Added line should have highlight extmark
    local marks = vim.api.nvim_buf_get_extmarks(buf, inline.ns_inline, 0, -1, { details = true })
    local has_insert_hl = false
    for _, mark in ipairs(marks) do
      local details = mark[4]
      if details.hl_group == "CodeDiffLineInsert" then
        has_insert_hl = true
        break
      end
    end
    assert.is_true(has_insert_hl, "Added line should have CodeDiffLineInsert highlight")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- Test 2: Deleted lines appear as virtual lines
  it("shows deleted lines as virtual lines", function()
    local buf = vim.api.nvim_create_buf(false, true)

    local original = { "line 1", "line 2", "line 3" }
    local modified = { "line 1", "line 3" }

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    inline.render_inline_diff(buf, lines_diff, original, modified)

    -- Should have virt_lines extmark
    local marks = vim.api.nvim_buf_get_extmarks(buf, inline.ns_inline, 0, -1, { details = true })
    local has_virt_lines = false
    for _, mark in ipairs(marks) do
      local details = mark[4]
      if details.virt_lines and #details.virt_lines > 0 then
        has_virt_lines = true
        -- Check that virtual line contains the deleted text
        local virt_text = details.virt_lines[1][1][1]
        assert.equals("line 2", virt_text, "Virtual line should contain deleted text")
        break
      end
    end
    assert.is_true(has_virt_lines, "Deleted line should appear as virtual line")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- Test 3: Modified lines get both virtual lines and highlights
  it("renders modified lines with both delete virt_lines and insert highlights", function()
    local buf = vim.api.nvim_create_buf(false, true)

    local original = { "line 1", "old content", "line 3" }
    local modified = { "line 1", "new content", "line 3" }

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    inline.render_inline_diff(buf, lines_diff, original, modified)

    local marks = vim.api.nvim_buf_get_extmarks(buf, inline.ns_inline, 0, -1, { details = true })

    local has_virt_lines = false
    local has_insert_hl = false

    for _, mark in ipairs(marks) do
      local details = mark[4]
      if details.virt_lines and #details.virt_lines > 0 then
        has_virt_lines = true
      end
      if details.hl_group == "CodeDiffLineInsert" then
        has_insert_hl = true
      end
    end

    assert.is_true(has_virt_lines, "Modified line should have virtual line showing original")
    assert.is_true(has_insert_hl, "Modified line should have insert highlight")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- Test 4: Character-level highlights on modified buffer
  it("applies character-level highlights for inner changes", function()
    local buf = vim.api.nvim_create_buf(false, true)

    local original = { "hello world" }
    local modified = { "hello earth" }

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    inline.render_inline_diff(buf, lines_diff, original, modified)

    local marks = vim.api.nvim_buf_get_extmarks(buf, inline.ns_inline, 0, -1, { details = true })

    local has_char_insert = false
    for _, mark in ipairs(marks) do
      local details = mark[4]
      if details.hl_group == "CodeDiffCharInsert" then
        has_char_insert = true
        break
      end
    end

    assert.is_true(has_char_insert, "Should have character-level insert highlight")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- Test 5: Clear removes all decorations
  it("clear() removes all inline decorations", function()
    local buf = vim.api.nvim_create_buf(false, true)

    local original = { "line 1", "line 2" }
    local modified = { "line 1", "changed", "line 3" }

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    inline.render_inline_diff(buf, lines_diff, original, modified)

    -- Verify marks exist
    local marks_before = vim.api.nvim_buf_get_extmarks(buf, inline.ns_inline, 0, -1, {})
    assert.is_true(#marks_before > 0, "Should have extmarks before clear")

    -- Clear
    inline.clear(buf)

    local marks_after = vim.api.nvim_buf_get_extmarks(buf, inline.ns_inline, 0, -1, {})
    assert.equals(0, #marks_after, "Should have no extmarks after clear")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- Test 6: No changes produces no decorations
  it("identical content produces no decorations", function()
    local buf = vim.api.nvim_create_buf(false, true)

    local content = { "line 1", "line 2", "line 3" }

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)

    local lines_diff = diff.compute_diff(content, content)
    inline.render_inline_diff(buf, lines_diff, content, content)

    local marks = vim.api.nvim_buf_get_extmarks(buf, inline.ns_inline, 0, -1, {})
    assert.equals(0, #marks, "Identical content should produce no extmarks")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- Test 7: Multiple hunks
  it("renders multiple hunks correctly", function()
    local buf = vim.api.nvim_create_buf(false, true)

    local original = { "aaa", "bbb", "ccc", "ddd", "eee" }
    local modified = { "aaa", "BBB", "ccc", "DDD", "eee" }

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    inline.render_inline_diff(buf, lines_diff, original, modified)

    local marks = vim.api.nvim_buf_get_extmarks(buf, inline.ns_inline, 0, -1, { details = true })

    -- Should have at least 2 sets of changes (virt_lines + highlights for each hunk)
    local virt_line_count = 0
    local hl_count = 0
    for _, mark in ipairs(marks) do
      local details = mark[4]
      if details.virt_lines then
        virt_line_count = virt_line_count + 1
      end
      if details.hl_group == "CodeDiffLineInsert" then
        hl_count = hl_count + 1
      end
    end

    assert.is_true(virt_line_count >= 2, "Should have virtual lines for at least 2 hunks")
    assert.is_true(hl_count >= 2, "Should have insert highlights for at least 2 hunks")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- Test 8: Pure deletion at end of file
  it("handles pure deletion at end of file", function()
    local buf = vim.api.nvim_create_buf(false, true)

    local original = { "line 1", "line 2", "line 3" }
    local modified = { "line 1" }

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    inline.render_inline_diff(buf, lines_diff, original, modified)

    local marks = vim.api.nvim_buf_get_extmarks(buf, inline.ns_inline, 0, -1, { details = true })
    local has_virt_lines = false
    for _, mark in ipairs(marks) do
      local details = mark[4]
      if details.virt_lines and #details.virt_lines > 0 then
        has_virt_lines = true
        break
      end
    end

    assert.is_true(has_virt_lines, "Pure deletion should show virtual lines")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- Test 9: Character-level highlights within virtual lines
  it("virtual lines contain char-level delete highlights as separate chunks", function()
    local buf = vim.api.nvim_create_buf(false, true)

    local original = { "hello world" }
    local modified = { "hello earth" }

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    inline.render_inline_diff(buf, lines_diff, original, modified)

    local marks = vim.api.nvim_buf_get_extmarks(buf, inline.ns_inline, 0, -1, { details = true })

    local found_char_delete_in_virt = false
    for _, mark in ipairs(marks) do
      local details = mark[4]
      if details.virt_lines then
        for _, virt_line in ipairs(details.virt_lines) do
          for _, chunk in ipairs(virt_line) do
            if chunk[2] == "CodeDiffCharDelete" then
              found_char_delete_in_virt = true
              break
            end
          end
        end
      end
    end

    assert.is_true(found_char_delete_in_virt, "Virtual lines should contain CodeDiffCharDelete chunks for changed characters")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- Test 10: Re-render clears previous decorations
  it("re-rendering clears previous decorations first", function()
    local buf = vim.api.nvim_create_buf(false, true)

    local original = { "line 1", "line 2" }
    local modified = { "line 1", "line 2", "line 3" }

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, modified)

    local lines_diff = diff.compute_diff(original, modified)
    inline.render_inline_diff(buf, lines_diff, original, modified)

    local marks_first = vim.api.nvim_buf_get_extmarks(buf, inline.ns_inline, 0, -1, {})
    local count_first = #marks_first

    -- Re-render same diff
    inline.render_inline_diff(buf, lines_diff, original, modified)

    local marks_second = vim.api.nvim_buf_get_extmarks(buf, inline.ns_inline, 0, -1, {})
    assert.equals(count_first, #marks_second, "Re-render should produce same number of extmarks (not doubled)")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
