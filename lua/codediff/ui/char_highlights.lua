local M = {}
local compat = require("codediff.core.compat")

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

return M
