local M = {}
local compat = require("codediff.core.compat")
local config = require("codediff.config")

-- Visit only changed spans that leave some text unchanged on the same line.
-- Diff columns use UTF-16; the callback receives zero-based byte positions.
function M.each_partial_range(range, lines, visit, line_number)
  if not range then
    return
  end

  local first = math.max(1, range.start_line, line_number or 1)
  local last = math.min(#lines, range.end_line, line_number or #lines)
  for line = first, last do
    local text = lines[line]
    local start_col, end_col = 0, #text
    if line == range.start_line then
      local ok, column = pcall(compat.str_byteindex_utf16, text, range.start_col - 1)
      if not ok then
        goto continue
      end
      start_col = column
    end
    if line == range.end_line then
      local ok, column = pcall(compat.str_byteindex_utf16, text, range.end_col - 1)
      if not ok then
        goto continue
      end
      end_col = column
    end

    if end_col > start_col and (start_col > 0 or end_col < #text) then
      visit(line - 1, start_col, end_col)
    end
    ::continue::
  end
end

-- Diff columns are one-based UTF-16 positions; Neovim needs byte positions.
function M.byte_column(line, column)
  if not line or column <= 1 then
    return column
  end
  local ok, byte = pcall(compat.str_byteindex_utf16, line, column - 1)
  return ok and byte + 1 or column
end

function M.apply(bufnr, namespace, range, group, lines)
  if not range then
    return
  end
  local function mark(row, column, opts)
    opts.hl_group, opts.priority = group, 200
    pcall(vim.api.nvim_buf_set_extmark, bufnr, namespace, row, column, opts)
  end
  if config.options.highlights.char_whole_line == false then
    M.each_partial_range(range, lines, function(row, first, last)
      mark(row, first, { end_col = last })
    end)
    return
  end

  local first, last = range.start_line, range.end_line
  if first == last and range.start_col == range.end_col then
    return
  end
  local count = vim.api.nvim_buf_line_count(bufnr)
  if first > count or last > count then
    return
  end
  local start_col, end_col = range.start_col, range.end_col
  if first >= 1 and first <= #lines then
    start_col = M.byte_column(lines[first], start_col)
  end
  if last >= 1 and last <= #lines then
    end_col = math.min(M.byte_column(lines[last], end_col), #lines[last] + 1)
  end
  for line = first, last do
    if line >= 1 then
      local opts = { end_col = line == last and end_col - 1 or 0 }
      if line < last then
        opts.end_line = line
      end
      mark(line - 1, line == first and start_col - 1 or 0, opts)
    end
  end
end

return M
