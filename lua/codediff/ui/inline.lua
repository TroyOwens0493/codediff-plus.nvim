-- Inline diff rendering: single-buffer view with virtual line overlays
-- Shows modified buffer with deleted lines as virt_lines extmarks
local M = {}

local config = require("codediff.config")
local highlights = require("codediff.ui.highlights")
local gutter_signs = require("codediff.ui.gutter_signs")
local char_highlights = require("codediff.ui.char_highlights")

-- Dedicated namespace for inline diff (separate from side-by-side namespaces)
M.ns_inline = vim.api.nvim_create_namespace("codediff-inline")

-- Allow deleted-line virt_lines to scroll horizontally with the window
local virt_lines_overflow = vim.fn.has("nvim-0.11") == 1 and "scroll" or nil

-- Cache for merged highlight groups (syntax fg + diff bg)
local merged_hl_cache = {}

-- Syntax highlighting for virt_lines via treesitter

-- Get or create a merged highlight group combining syntax fg with diff bg
-- @param syntax_hl string: treesitter highlight group (e.g., "@keyword")
-- @param diff_hl string: diff background group ("CodeDiffLineDelete" or "CodeDiffCharDelete")
-- @return string: merged highlight group name
local function get_merged_hl(syntax_hl, diff_hl)
  local key = syntax_hl .. "+" .. diff_hl
  if merged_hl_cache[key] then
    return merged_hl_cache[key]
  end

  -- Resolve the actual highlight values
  local syntax_def = vim.api.nvim_get_hl(0, { name = syntax_hl, link = false })
  local diff_def = vim.api.nvim_get_hl(0, { name = diff_hl, link = false })

  if not syntax_def.fg and not syntax_def.bold and not syntax_def.italic then
    -- Syntax group has no useful styling, just use diff highlight
    merged_hl_cache[key] = diff_hl
    return diff_hl
  end

  -- Create merged group: syntax fg/style + diff bg
  local merged_name = "CodeDiffInline_" .. syntax_hl:gsub("[%.@]", "_") .. "_" .. diff_hl
  local merged_def = {
    bg = diff_def.bg,
    fg = syntax_def.fg,
    bold = syntax_def.bold,
    italic = syntax_def.italic,
    underline = syntax_def.underline,
    strikethrough = syntax_def.strikethrough,
  }
  vim.api.nvim_set_hl(0, merged_name, merged_def)
  merged_hl_cache[key] = merged_name
  return merged_name
end

-- Compute treesitter syntax highlights for a set of lines
-- @param lines string[]: source lines
-- @param filetype string: language for treesitter parser
-- @return table: { [1-based-line] = { {start_col, end_col, hl_group}, ... } }
function M.compute_syntax_highlights(lines, filetype)
  if not filetype or filetype == "" or #lines == 0 then
    return {}
  end

  local source = table.concat(lines, "\n")

  -- Try to get a parser for this filetype
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, filetype)
  if not ok or not parser then
    return {}
  end

  local ok2, trees = pcall(parser.parse, parser)
  if not ok2 or not trees or #trees == 0 then
    return {}
  end

  local query_ok, query = pcall(vim.treesitter.query.get, filetype, "highlights")
  if not query_ok or not query then
    return {}
  end

  local result = {}

  for id, node in query:iter_captures(trees[1]:root(), source) do
    local r1, c1, r2, c2 = node:range()
    local hl_group = "@" .. query.captures[id]

    -- Split captures into per-line byte spans, including empty single-line captures.
    for row = r1, r2 do
      local line = row + 1
      result[line] = result[line] or {}
      local first = row == r1 and c1 + 1 or 1
      local last = row == r2 and c2 or #(lines[line] or "")
      if r1 == r2 or last >= first then
        table.insert(result[line], { start_col = first, end_col = last, hl_group = hl_group })
      end
    end
  end

  -- Sort each line's highlights by start_col
  for _, line_hls in pairs(result) do
    table.sort(line_hls, function(a, b)
      return a.start_col < b.start_col
    end)
  end

  return result
end

-- Helper: UTF-16 to byte column conversion (shared with ui/core.lua)

local utf16_col_to_byte_col = char_highlights.byte_column

-- Build virtual line chunks with character-level highlights

-- Build a single virt_line entry with char-level diff highlighting and syntax colors
-- line_text: the original (deleted) line text
-- char_ranges: sorted list of {start_col, end_col} (1-based, byte positions)
-- syntax_hls: sorted list of {start_col, end_col, hl_group} for this line (optional)
-- Returns: array of {text, hl_group} chunks suitable for virt_lines
local function build_highlighted_virt_line(line_text, char_ranges, syntax_hls, base_hl)
  base_hl = base_hl or "CodeDiffLineDelete"
  -- Build position-to-syntax-hl map for quick lookup
  local syntax_at = {}
  if syntax_hls then
    for _, sh in ipairs(syntax_hls) do
      for col = sh.start_col, sh.end_col do
        syntax_at[col] = sh.hl_group
      end
    end
  end

  -- Determine diff highlight for each byte position
  -- nil = CodeDiffLineDelete, true = CodeDiffCharDelete
  local char_delete_at = {}
  if char_ranges then
    for _, range in ipairs(char_ranges) do
      for col = range.start_col, range.end_col do
        char_delete_at[col] = true
      end
    end
  end

  -- Build chunks by walking through the line, grouping consecutive positions
  -- with the same effective highlight
  if #line_text == 0 then
    return {
      { "", base_hl },
      { string.rep(" ", 300), base_hl },
    }
  end

  local chunks = {}
  local chunk_start = 1
  local prev_hl = nil

  local function get_hl_at(col)
    local diff_hl = char_delete_at[col] and "CodeDiffCharDelete" or base_hl
    local syn_hl = syntax_at[col]
    if syn_hl then
      return get_merged_hl(syn_hl, diff_hl)
    end
    return diff_hl
  end

  prev_hl = get_hl_at(1)

  for col = 2, #line_text + 1 do
    local cur_hl = col <= #line_text and get_hl_at(col) or nil
    if cur_hl ~= prev_hl then
      table.insert(chunks, { line_text:sub(chunk_start, col - 1), prev_hl })
      chunk_start = col
      prev_hl = cur_hl
    end
  end

  -- Last chunk
  if chunk_start <= #line_text then
    table.insert(chunks, { line_text:sub(chunk_start), prev_hl })
  end

  -- Pad for full-width background color (simulates hl_eol for virt_lines)
  table.insert(chunks, { string.rep(" ", 300), base_hl })

  return chunks
end

-- Extract char-level ranges for a specific original line from inner_changes

-- Given inner_changes and a 1-based original line number, extract byte-position
-- ranges on that line that have character-level deletions.
-- Returns: sorted list of {start_col, end_col} in byte positions
local function get_char_ranges_for_orig_line(inner_changes, orig_line_1based, original_lines)
  if not inner_changes then
    return nil
  end

  local ranges = {}
  local line_text = original_lines[orig_line_1based]
  if not line_text then
    return nil
  end

  if config.options.highlights.char_whole_line == false then
    for _, inner in ipairs(inner_changes) do
      char_highlights.each_partial_range(inner.original, original_lines, function(_, start_col, end_col)
        table.insert(ranges, { start_col = start_col + 1, end_col = end_col })
      end, orig_line_1based)
    end
    return #ranges > 0 and ranges or nil
  end

  for _, inner in ipairs(inner_changes) do
    local orig = inner.original
    if not orig then
      goto continue
    end

    -- Check if this inner change touches our line
    if orig.start_line <= orig_line_1based and orig.end_line >= orig_line_1based then
      -- Empty range check
      if orig.start_line == orig.end_line and orig.start_col == orig.end_col then
        goto continue
      end

      local start_col, end_col

      if orig.start_line == orig_line_1based then
        start_col = utf16_col_to_byte_col(line_text, orig.start_col)
      else
        start_col = 1
      end

      if orig.end_line == orig_line_1based then
        end_col = utf16_col_to_byte_col(line_text, orig.end_col) - 1
        end_col = math.max(end_col, start_col) -- ensure valid range
      else
        end_col = #line_text
      end

      -- Clamp to line length
      start_col = math.max(1, math.min(start_col, #line_text + 1))
      end_col = math.min(end_col, #line_text)

      if end_col >= start_col then
        table.insert(ranges, { start_col = start_col, end_col = end_col })
      end
    end

    ::continue::
  end

  -- Sort by start_col
  table.sort(ranges, function(a, b)
    return a.start_col < b.start_col
  end)

  return #ranges > 0 and ranges or nil
end

-- Apply char-level highlights on modified buffer lines

local function apply_modified_char_highlights(bufnr, inner_changes, modified_lines)
  for _, inner in ipairs(inner_changes or {}) do
    char_highlights.apply(bufnr, M.ns_inline, inner.modified, "CodeDiffCharInsert", modified_lines)
  end
end

-- Main Rendering Function

-- Render inline diff on a single buffer (the modified buffer)
-- Deleted lines appear as virtual lines above the corresponding modified position
-- Added/changed lines get highlight extmarks on the real buffer text
--
-- @param bufnr number: The modified buffer to render on
-- @param diff_result table: The diff result from core/diff.compute_diff
-- @param original_lines string[]: Lines from the original (reference) content
-- @param modified_lines string[]: Lines from the modified buffer
-- @param opts? table: { filetype?: string, syntax_highlights?: table } for syntax highlighting on virt_lines
function M.render_inline_diff(bufnr, diff_result, original_lines, modified_lines, opts)
  -- Clear previous inline decorations
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns_inline, 0, -1)
  gutter_signs.clear_buffer(bufnr)
  -- Clear merged highlight cache on re-render (colorscheme may have changed)
  merged_hl_cache = {}

  if not diff_result or not diff_result.changes then
    return
  end

  -- Virtual deleted rows cannot carry native signs; mark them in their text below.
  gutter_signs.set_changed_ranges(nil, bufnr, diff_result.changes)
  local sign_options = config.options.diff.gutter_signs

  -- Compute syntax highlights for original lines (for virt_line coloring)
  local show_deleted_lines = config.options.diff.show_deleted_lines
  local syntax_hls = {}
  if show_deleted_lines then
    local filetype = opts and opts.filetype or (vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype or nil)
    syntax_hls = opts and opts.syntax_highlights or M.compute_syntax_highlights(original_lines, filetype)
  end

  local buf_line_count = vim.api.nvim_buf_line_count(bufnr)
  local highlight_priority = config.options.diff.highlight_priority

  for _, mapping in ipairs(diff_result.changes) do
    local orig_start = mapping.original.start_line
    local orig_end = mapping.original.end_line
    local mod_start = mapping.modified.start_line
    local mod_end = mapping.modified.end_line

    local orig_count = orig_end - orig_start
    local mod_count = mod_end - mod_start
    local has_original = orig_count > 0
    local has_modified = mod_count > 0

    -- Step 1: Show deleted/original lines as virtual lines
    if has_original and show_deleted_lines then
      local virt_lines = {}

      for orig_line = orig_start, orig_end - 1 do
        local line_text = original_lines[orig_line] or ""
        local char_ranges = get_char_ranges_for_orig_line(mapping.inner_changes, orig_line, original_lines)
        local line_syntax = syntax_hls[orig_line]
        local chunks = build_highlighted_virt_line(line_text, char_ranges, line_syntax)
        if type(sign_options) == "table" then
          table.insert(chunks, 1, { (sign_options.delete_text or "－") .. " ", "CodeDiffGutterDelete" })
        end
        table.insert(virt_lines, chunks)
      end

      -- Anchor: place virtual lines above mod_start (or at end if pure deletion past buffer)
      local anchor_line
      if has_modified then
        anchor_line = mod_start - 1 -- 0-indexed, virt_lines_above places above this line
      else
        -- Pure deletion: anchor at the line where content was deleted
        -- mod_start points to the line AFTER the deletion point
        anchor_line = math.min(mod_start - 1, buf_line_count - 1)
        anchor_line = math.max(anchor_line, 0)
      end

      pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns_inline, anchor_line, 0, {
        virt_lines = virt_lines,
        virt_lines_above = true,
        virt_lines_overflow = virt_lines_overflow,
        priority = highlight_priority,
      })
    end

    -- Step 2: Highlight added/modified lines on the real buffer
    if has_modified then
      local hl_group = "CodeDiffLineInsert"

      for line = mod_start, mod_end - 1 do
        if line > buf_line_count then
          break
        end

        local line_idx = line - 1
        pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns_inline, line_idx, 0, {
          end_line = line_idx + 1,
          end_col = 0,
          hl_group = hl_group,
          hl_eol = true,
          priority = highlight_priority,
        })
      end
    end

    -- Step 3: Character-level highlights on modified buffer lines
    if has_modified and mapping.inner_changes then
      apply_modified_char_highlights(bufnr, mapping.inner_changes, modified_lines)
    end
  end
end

-- Clear inline diff decorations

function M.clear(bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns_inline, 0, -1)
    gutter_signs.clear_buffer(bufnr)
  end
end

return M
