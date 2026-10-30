-- Test: layout.lua - Centralized window layout manager
-- Exhaustive tests for all layout cases validating window widths/heights

local layout = require("codediff.ui.layout")
local lifecycle = require("codediff.ui.lifecycle")
local config = require("codediff.config")
local highlights = require("codediff.ui.highlights")
local path = require("codediff.core.path")

-- Tolerance for width assertions (Neovim may round or add separators)
local WIDTH_TOLERANCE = 2

local function assert_width_near(expected, actual, msg)
  assert.is_true(math.abs(expected - actual) <= WIDTH_TOLERANCE, (msg or "") .. " expected ~" .. expected .. " got " .. actual)
end

local function assert_whole_file_highlight(bufnr, expected_group)
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, highlights.ns_highlight, 0, -1, { details = true })
  assert.are.equal(1, #marks, "Buffer should have one whole-file highlight")
  assert.are.equal(expected_group, marks[1][4].hl_group)
end

-- Create a mock session in lifecycle so layout.arrange() can read it
local function create_mock_session(tabpage, opts)
  -- Directly inject into lifecycle's active_diffs
  local session_mod = require("codediff.ui.lifecycle.session")
  local active_diffs = session_mod.get_active_diffs()
  active_diffs[tabpage] = {
    panel = opts.panel and vim.tbl_extend("force", opts.panel, { view = opts.panel_obj }) or nil,
    original_win = opts.original_win,
    modified_win = opts.modified_win,
    result_win = opts.result_win,
    original_bufnr = opts.original_bufnr,
    modified_bufnr = opts.modified_bufnr,
  }
end

local function cleanup_mock_session(tabpage)
  local session_mod = require("codediff.ui.lifecycle.session")
  local active_diffs = session_mod.get_active_diffs()
  active_diffs[tabpage] = nil
end

-- Keep geometry setup in one place; assertions below describe each layout.
local function open_panes()
  vim.cmd("tabnew")
  local tabpage = vim.api.nvim_get_current_tabpage()
  local original_win, original_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  vim.cmd("vsplit")
  return tabpage, original_win, original_buf, vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
end

-- Create a panel-like object mimicking explorer/history split
local function create_panel_split(position, size)
  local Split = require("codediff.ui.lib.split")
  local split = Split({
    position = position,
    size = size,
    buf_options = { modifiable = false, readonly = true },
    win_options = { number = false, signcolumn = "no" },
  })
  split:mount()
  return {
    winid = split.winid,
    split = split,
    is_hidden = false,
  }
end

describe("Layout Manager", function()
  local saved_config, saved_lines, temporary_files

  before_each(function()
    -- Save and reset config to defaults
    saved_config = vim.deepcopy(config.options)
    saved_lines = vim.o.lines
    temporary_files = {}
  end)

  after_each(function()
    -- Restore config
    config.options = saved_config
    vim.o.lines = saved_lines
    for _, file in ipairs(temporary_files) do
      vim.fn.delete(file)
    end
    -- Close all extra tabs
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose!")
    end
    -- Close all extra windows in remaining tab
    while vim.fn.winnr("$") > 1 do
      vim.cmd("only!")
    end
  end)

  -- Each row retains a named scenario; only pane construction and common
  -- dimension checks are shared. Custom ratios and result heights stay explicit.
  local layouts = {
    {
      name = "Case 1: Two panes without panel get equal widths",
    },
    {
      name = "Case 1b: Standalone + result bottom — diff panes equal, result height set",
      result = "bottom",
      height = 25,
    },
    {
      name = "Case 1c: Standalone + result center — 3 panes follow ratio, no panel",
      result = "center",
    },
    {
      name = "Case 2: Explorer left — panel gets configured width, diff panes split remainder",
      panel = "explorer",
      position = "left",
      size = 35,
    },
    {
      name = "Case 3: Explorer bottom — panel gets configured height, diff panes split full width",
      panel = "explorer",
      position = "bottom",
      size = 12,
    },
    {
      name = "Case 4: History left — panel gets configured width, diff panes split remainder",
      panel = "history",
      position = "left",
      size = 30,
    },
    {
      name = "Case 5: History bottom — panel gets configured height, diff panes split full width",
      panel = "history",
      position = "bottom",
      size = 10,
    },
    {
      name = "Case 6: Explorer left + result bottom — panel width preserved, diff panes equal",
      panel = "explorer",
      position = "left",
      size = 35,
      result = "bottom",
      height = 30,
    },
    {
      name = "Case 7: Explorer left + result center — panel width preserved, 3 panes follow ratio",
      panel = "explorer",
      position = "left",
      size = 35,
      result = "center",
    },
    {
      name = "Case 7b: Explorer left + result center — custom ratio 1:2:1 honored",
      panel = "explorer",
      position = "left",
      size = 35,
      result = "center",
      ratio = { 1, 2, 1 },
    },
    {
      name = "Case 8: Explorer bottom + result bottom — both heights correct, diff panes equal",
      panel = "explorer",
      position = "bottom",
      size = 12,
      result = "bottom",
      height = 25,
    },
    {
      name = "Case 9: Explorer bottom + result center — panel height preserved, 3 panes follow ratio",
      panel = "explorer",
      position = "bottom",
      size = 12,
      result = "center",
    },
  }
  for _, case in ipairs(layouts) do
    it(case.name, function()
      -- Leave room for two stacked panels and the percentage-sized Result.
      if case.position == "bottom" and case.result == "bottom" then
        vim.o.lines = math.max(vim.o.lines, 64)
      end
      if case.panel then
        config.options[case.panel] = {
          position = case.position,
          width = case.position == "left" and case.size or nil,
          height = case.position == "bottom" and case.size or nil,
        }
      end
      if case.result then
        config.options.diff.conflict_result_position = case.result
        config.options.diff.conflict_result_height = case.height or 25
        config.options.diff.conflict_result_width_ratio = case.ratio or { 1, 1, 1 }
      end
      local tabpage, orig_win, orig_buf, mod_win, mod_buf = open_panes()
      local panel = case.panel and create_panel_split(case.position, case.size) or nil
      if panel and case.panel == "explorer" then
        -- Match the real Explorer split's fixed-size options.
        vim.wo[panel.winid].winfixheight, vim.wo[panel.winid].winfixwidth = true, true
      end
      local result_win
      if case.result == "bottom" then
        result_win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, { split = "below", win = mod_win })
        vim.fn.win_splitmove(orig_win, mod_win, { vertical = true, rightbelow = false })
      elseif case.result == "center" then
        vim.api.nvim_set_current_win(orig_win)
        vim.cmd("vsplit")
        result_win = vim.api.nvim_get_current_win()
      end
      create_mock_session(tabpage, {
        panel = case.panel and { name = case.panel } or nil,
        panel_obj = panel,
        original_win = orig_win,
        modified_win = mod_win,
        original_bufnr = orig_buf,
        modified_bufnr = mod_buf,
        result_win = result_win,
      })
      -- Start out of balance so the checks require arrange(), even when the
      -- split defaults happen to match the requested ratio.
      vim.api.nvim_win_set_width(orig_win, 5)
      layout.arrange(tabpage)

      if panel then
        local dimension = case.position == "left" and vim.api.nvim_win_get_width or vim.api.nvim_win_get_height
        assert.are.equal(case.size, dimension(panel.winid), "Panel should keep its configured size")
      end
      local original, modified = vim.api.nvim_win_get_width(orig_win), vim.api.nvim_win_get_width(mod_win)
      if case.result == "center" and not case.ratio then
        local result = vim.api.nvim_win_get_width(result_win)
        assert_width_near(original, result, "Original and Result should have equal widths:")
        assert_width_near(result, modified, "Result and modified should have equal widths:")
      else
        assert_width_near(original, modified, "Diff panes should have equal widths:")
        if case.ratio then
          assert.is_true(vim.api.nvim_win_get_width(result_win) >= original * 1.5, "Result should be about twice a side pane")
        end
      end
      if case.result == "bottom" then
        assert_width_near(math.floor(vim.o.lines * case.height / 100), vim.api.nvim_win_get_height(result_win), "Result height should match configured percentage:")
      end
      cleanup_mock_session(tabpage)
    end)
  end

  it("Idempotent: calling arrange twice produces same widths", function()
    local panel_width = 35
    config.options.explorer = { position = "left", width = panel_width }
    config.options.diff.conflict_result_position = "center"
    config.options.diff.conflict_result_width_ratio = { 1, 2, 1 }

    local tabpage, orig_win, orig_buf, mod_win, mod_buf = open_panes()

    local panel = create_panel_split("left", panel_width)

    vim.api.nvim_set_current_win(orig_win)
    vim.cmd("vsplit")
    local result_win = vim.api.nvim_get_current_win()

    create_mock_session(tabpage, {
      panel = { name = "explorer" },
      original_win = orig_win,
      modified_win = mod_win,
      original_bufnr = orig_buf,
      modified_bufnr = mod_buf,
      result_win = result_win,
      panel_obj = panel,
    })

    layout.arrange(tabpage)

    local first_panel_w = vim.api.nvim_win_get_width(panel.winid)
    local first_orig_w = vim.api.nvim_win_get_width(orig_win)
    local first_result_w = vim.api.nvim_win_get_width(result_win)
    local first_mod_w = vim.api.nvim_win_get_width(mod_win)

    layout.arrange(tabpage)

    local second_panel_w = vim.api.nvim_win_get_width(panel.winid)
    local second_orig_w = vim.api.nvim_win_get_width(orig_win)
    local second_result_w = vim.api.nvim_win_get_width(result_win)
    local second_mod_w = vim.api.nvim_win_get_width(mod_win)

    assert.are.equal(first_panel_w, second_panel_w, "Panel width should be stable")
    assert.are.equal(first_orig_w, second_orig_w, "Original width should be stable")
    assert.are.equal(first_result_w, second_result_w, "Result width should be stable")
    assert.are.equal(first_mod_w, second_mod_w, "Modified width should be stable")

    cleanup_mock_session(tabpage)
  end)

  it("No-op when no session exists for tabpage", function()
    local tabpage = vim.api.nvim_get_current_tabpage()
    -- Should not error
    layout.arrange(tabpage)
  end)

  it("Hidden panel: diff panes use full width when panel is hidden", function()
    local panel_width = 35
    config.options.explorer = { position = "left", width = panel_width }

    local tabpage, orig_win, orig_buf, mod_win, mod_buf = open_panes()

    local panel = create_panel_split("left", panel_width)
    -- Hide the panel
    panel.split:hide()
    panel.is_hidden = true

    create_mock_session(tabpage, {
      panel = { name = "explorer" },
      original_win = orig_win,
      modified_win = mod_win,
      original_bufnr = orig_buf,
      modified_bufnr = mod_buf,
      panel_obj = panel,
    })

    layout.arrange(tabpage)

    local orig_w = vim.api.nvim_win_get_width(orig_win)
    local mod_w = vim.api.nvim_win_get_width(mod_win)

    assert_width_near(orig_w, mod_w, "Diff panes should be equal when panel hidden:")
    -- With panel hidden, each pane should be roughly half of total columns
    local expected_half = math.floor(vim.o.columns / 2)
    assert_width_near(expected_half, orig_w, "Each pane should be ~half of total width:")

    cleanup_mock_session(tabpage)
  end)

  it("Hidden panel + center result: 3 panes use full width when panel is hidden", function()
    local panel_width = 35
    config.options.explorer = { position = "left", width = panel_width }
    config.options.diff.conflict_result_position = "center"
    config.options.diff.conflict_result_width_ratio = { 1, 1, 1 }

    local tabpage, orig_win, orig_buf, mod_win, mod_buf = open_panes()

    local panel = create_panel_split("left", panel_width)
    panel.split:hide()
    panel.is_hidden = true

    vim.api.nvim_set_current_win(orig_win)
    vim.cmd("vsplit")
    local result_win = vim.api.nvim_get_current_win()

    create_mock_session(tabpage, {
      panel = { name = "explorer" },
      original_win = orig_win,
      modified_win = mod_win,
      original_bufnr = orig_buf,
      modified_bufnr = mod_buf,
      result_win = result_win,
      panel_obj = panel,
    })

    layout.arrange(tabpage)

    local orig_w = vim.api.nvim_win_get_width(orig_win)
    local result_w = vim.api.nvim_win_get_width(result_win)
    local mod_w = vim.api.nvim_win_get_width(mod_win)

    -- All three should be ~1/3 of total columns
    assert_width_near(orig_w, result_w, "All three panes equal (1:1:1):")
    assert_width_near(result_w, mod_w, "All three panes equal (1:1:1):")
    local expected_third = math.floor(vim.o.columns / 3)
    assert_width_near(expected_third, orig_w, "Each pane should be ~1/3 of total:")

    cleanup_mock_session(tabpage)
  end)

  it("Case 10: Single-pane without panel — sole window fills full width", function()
    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local mod_win = vim.api.nvim_get_current_win()
    local mod_buf = vim.api.nvim_get_current_buf()

    -- original_win points to a closed (invalid) window ID
    create_mock_session(tabpage, {
      original_win = 99999, -- invalid window
      modified_win = mod_win,
      original_bufnr = mod_buf,
      modified_bufnr = mod_buf,
    })
    local session_mod = require("codediff.ui.lifecycle.session")
    session_mod.get_active_diffs()[tabpage].single_pane = true

    layout.arrange(tabpage)

    local mod_w = vim.api.nvim_win_get_width(mod_win)
    -- Single window should take all available columns (minus border/separator)
    assert_width_near(vim.o.columns, mod_w, "Single pane should fill full width:")

    cleanup_mock_session(tabpage)
  end)

  it("Case 11: Single-pane with explorer left — panel pinned, sole diff pane fills remainder", function()
    local panel_width = 35
    config.options.explorer = { position = "left", width = panel_width }

    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local mod_win = vim.api.nvim_get_current_win()
    local mod_buf = vim.api.nvim_get_current_buf()

    local panel = create_panel_split("left", panel_width)

    create_mock_session(tabpage, {
      panel = { name = "explorer" },
      original_win = 99999, -- invalid window (was closed)
      modified_win = mod_win,
      original_bufnr = mod_buf,
      modified_bufnr = mod_buf,
      panel_obj = panel,
    })
    local session_mod = require("codediff.ui.lifecycle.session")
    session_mod.get_active_diffs()[tabpage].single_pane = true

    layout.arrange(tabpage)

    local panel_w = vim.api.nvim_win_get_width(panel.winid)
    local mod_w = vim.api.nvim_win_get_width(mod_win)

    assert.are.equal(panel_width, panel_w, "Panel should be configured width")
    -- Diff pane should fill the rest: columns - panel_width - 1 separator
    local expected_diff = vim.o.columns - panel_width - 1
    assert_width_near(expected_diff, mod_w, "Single diff pane should fill remainder:")

    cleanup_mock_session(tabpage)
  end)

  it("Case 12: Single-pane deleted with explorer left — panel pinned, sole diff pane fills remainder", function()
    local panel_width = 35
    config.options.explorer = { position = "left", width = panel_width }

    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local orig_win = vim.api.nvim_get_current_win()
    local orig_buf = vim.api.nvim_get_current_buf()

    local panel = create_panel_split("left", panel_width)

    create_mock_session(tabpage, {
      panel = { name = "explorer" },
      original_win = orig_win,
      modified_win = 99999, -- invalid window (was closed)
      original_bufnr = orig_buf,
      modified_bufnr = orig_buf,
      panel_obj = panel,
    })
    local session_mod = require("codediff.ui.lifecycle.session")
    session_mod.get_active_diffs()[tabpage].single_pane = true

    layout.arrange(tabpage)

    local panel_w = vim.api.nvim_win_get_width(panel.winid)
    local orig_w = vim.api.nvim_win_get_width(orig_win)

    assert.are.equal(panel_width, panel_w, "Panel should be configured width")
    local expected_diff = vim.o.columns - panel_width - 1
    assert_width_near(expected_diff, orig_w, "Single diff pane should fill remainder:")

    cleanup_mock_session(tabpage)
  end)

  it("Case 13: Single-pane with explorer bottom — panel height pinned, diff pane fills width", function()
    local panel_height = 12
    config.options.explorer = { position = "bottom", height = panel_height }

    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local mod_win = vim.api.nvim_get_current_win()
    local mod_buf = vim.api.nvim_get_current_buf()

    local panel = create_panel_split("bottom", panel_height)

    create_mock_session(tabpage, {
      panel = { name = "explorer" },
      original_win = 99999,
      modified_win = mod_win,
      original_bufnr = mod_buf,
      modified_bufnr = mod_buf,
      panel_obj = panel,
    })
    local session_mod = require("codediff.ui.lifecycle.session")
    session_mod.get_active_diffs()[tabpage].single_pane = true

    layout.arrange(tabpage)

    local panel_h = vim.api.nvim_win_get_height(panel.winid)
    local mod_w = vim.api.nvim_win_get_width(mod_win)

    assert.are.equal(panel_height, panel_h, "Panel height should be preserved")
    assert_width_near(vim.o.columns, mod_w, "Single diff pane should fill full width:")

    cleanup_mock_session(tabpage)
  end)

  -- The four one-sided entry points share geometry, highlighting, and state checks.
  local one_sided_cases = {
    { name = "Case 14: show_untracked_file — closes orig, single-pane, diff pane fills remainder", method = "show_untracked_file", side = "modified", virtual = false },
    { name = "Case 15: show_deleted_file — closes mod, single-pane, diff pane fills remainder", method = "show_deleted_file", side = "original", virtual = false },
    { name = "Case 16: show_added_virtual_file — closes orig, single-pane, insert highlight", method = "show_added_virtual_file", side = "modified", virtual = true },
    { name = "Case 17: show_deleted_virtual_file — closes mod, single-pane, delete highlight", method = "show_deleted_virtual_file", side = "original", virtual = true },
  }
  for _, case in ipairs(one_sided_cases) do
    it(case.name, function()
      local panel_width = 35
      config.options.explorer = { position = "left", width = panel_width }
      config.options.diff.highlight_added_deleted_files = true
      local tabpage, orig_win, orig_buf, mod_win, mod_buf = open_panes()
      local panel = create_panel_split("left", panel_width)
      local session_mod = require("codediff.ui.lifecycle.session")
      local state = require("codediff.ui.lifecycle.state")
      session_mod.get_active_diffs()[tabpage] = {
        panel = { name = "explorer", view = panel },
        git_root = "/tmp",
        original = path.empty(),
        modified = path.empty(),
        original_revision = case.virtual and "abc123" or nil,
        modified_revision = case.virtual and "def456" or nil,
        original_bufnr = orig_buf,
        modified_bufnr = mod_buf,
        original_win = orig_win,
        modified_win = mod_win,
        stored_diff_result = {},
        changedtick = { original = 0, modified = 0 },
        mtime = {},
        original_state = state.save_buffer_state(orig_buf),
        modified_state = state.save_buffer_state(mod_buf),
        suspended = false,
      }
      vim.w[orig_win].codediff_restore, vim.w[mod_win].codediff_restore = 1, 1

      local view = require("codediff.ui.view.side_by_side")
      local temp_file
      if case.method == "show_untracked_file" then
        temp_file = vim.fn.tempname() .. "_untracked_layout.txt"
        temporary_files[#temporary_files + 1] = temp_file
        vim.fn.writefile({ "content" }, temp_file)
        view.show_untracked_file(tabpage, temp_file)
      elseif case.method == "show_deleted_file" then
        view.show_deleted_file(tabpage, "/tmp", "test.txt", "/tmp/test.txt", "unstaged")
      else
        local name = case.side == "original" and "deleted.txt" or "added.txt"
        view[case.method](tabpage, "/tmp", name, case.side == "original" and "abc123" or "def456")
      end

      local session = session_mod.get_active_diffs()[tabpage]
      local kept = case.side == "original" and orig_win or mod_win
      local closed = case.side == "original" and mod_win or orig_win
      assert.is_true(session.single_pane == true, "single_pane should be true")
      assert.is_false(vim.api.nvim_win_is_valid(closed), "Unused pane should be closed")
      assert.is_true(vim.api.nvim_win_is_valid(kept), "File pane should remain valid")
      local buf = session[case.side .. "_bufnr"]
      assert_whole_file_highlight(buf, case.side == "original" and "CodeDiffLineDelete" or "CodeDiffLineInsert")
      assert.are.equal(0, #vim.api.nvim_buf_get_extmarks(buf, highlights.ns_filler, 0, -1, {}), "No filler highlights should remain")
      assert.are.equal(panel_width, vim.api.nvim_win_get_width(panel.winid), "Panel should be configured width")
      assert_width_near(vim.o.columns - panel_width - 1, vim.api.nvim_win_get_width(kept), "Diff pane should fill remainder:")
      assert.is_truthy(session.stored_diff_result, "Should have diff result")
      assert.same({}, session.stored_diff_result.changes, "Should have no changes")
      cleanup_mock_session(tabpage)
    end)
  end

  it("Case 18: Empty file content — both panes remain, no single-pane", function()
    local tabpage, orig_win, orig_buf, mod_win, mod_buf = open_panes()

    -- Both buffers have empty content (simulating empty files)
    vim.api.nvim_buf_set_lines(orig_buf, 0, -1, false, { "" })
    vim.api.nvim_buf_set_lines(mod_buf, 0, -1, false, { "" })

    create_mock_session(tabpage, {
      original_win = orig_win,
      modified_win = mod_win,
      original_bufnr = orig_buf,
      modified_bufnr = mod_buf,
    })

    layout.arrange(tabpage)

    -- Both windows should remain valid and approximately equal
    assert.is_true(vim.api.nvim_win_is_valid(orig_win), "Original window should be valid")
    assert.is_true(vim.api.nvim_win_is_valid(mod_win), "Modified window should be valid")

    local orig_w = vim.api.nvim_win_get_width(orig_win)
    local mod_w = vim.api.nvim_win_get_width(mod_win)
    assert_width_near(orig_w, mod_w, "Both panes should be equal width for empty files:")

    local session = require("codediff.ui.lifecycle.session").get_active_diffs()[tabpage]
    assert.is_nil(session.single_pane, "single_pane should NOT be set for empty files")

    cleanup_mock_session(tabpage)
  end)

  -- Regression test: #346 — panel width should be re-applied on VimResized
  it("re-pins panel width on VimResized (regression: #346)", function()
    local panel_width = 28
    local panel = create_panel_split("left", panel_width)
    vim.cmd("vsplit")
    local orig_win = vim.api.nvim_get_current_win()
    vim.cmd("vsplit")
    local mod_win = vim.api.nvim_get_current_win()
    local orig_buf = vim.api.nvim_create_buf(false, true)
    local mod_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(orig_win, orig_buf)
    vim.api.nvim_win_set_buf(mod_win, mod_buf)

    local tabpage = vim.api.nvim_get_current_tabpage()
    local session_mod = require("codediff.ui.lifecycle.session")
    config.options.explorer = config.options.explorer or {}
    config.options.explorer.width = panel_width
    session_mod.create_session(tabpage, {
      panel = { name = "explorer" },
      git_root = "/tmp",
      original = "",
      modified = "",
    }, {
      original_bufnr = orig_buf,
      modified_bufnr = mod_buf,
      original_win = orig_win,
      modified_win = mod_win,
      lines_diff = {},
    })
    local accessors = require("codediff.ui.lifecycle.accessors")
    accessors.set_panel_view(tabpage, panel)

    -- The VimResized autocmd is installed by lifecycle.setup() (once-guarded by
    -- view.create()). This test creates the session directly, bypassing view.create(),
    -- so we install the autocmds explicitly to exercise the resize path.
    require("codediff.ui.lifecycle.cleanup").setup_autocmds()

    -- Pin the configured width first, then sabotage it (simulating what a real
    -- terminal resize does to the layout) and confirm VimResized re-pins it.
    layout.arrange(tabpage)
    local initial = vim.api.nvim_win_get_width(panel.winid)
    assert_width_near(panel_width, initial, "Initial panel width should match config:")

    vim.api.nvim_win_set_width(panel.winid, 90) -- sabotage
    vim.cmd("doautocmd VimResized")
    vim.wait(50)

    local restored = vim.api.nvim_win_get_width(panel.winid)
    assert_width_near(panel_width, restored, "VimResized should re-pin panel width:")

    cleanup_mock_session(tabpage)
    pcall(panel.split.unmount, panel.split)
  end)
end)
