-- Highlight setup for diff rendering
local M = {}
local config = require("codediff.config")

-- Namespaces for highlights and fillers
M.ns_highlight = vim.api.nvim_create_namespace("codediff-highlight")
M.ns_filler = vim.api.nvim_create_namespace("codediff-filler")
M.ns_conflict = vim.api.nvim_create_namespace("codediff-conflict")

-- Helper function to adjust color brightness
local function adjust_brightness(color, factor)
  if not color then
    return nil
  end
  local r = math.floor(color / 65536) % 256
  local g = math.floor(color / 256) % 256
  local b = color % 256

  -- Apply factor and clamp to 0-255
  r = math.min(255, math.floor(r * factor))
  g = math.min(255, math.floor(g * factor))
  b = math.min(255, math.floor(b * factor))

  return r * 65536 + g * 256 + b
end

-- Read the effective background color of a highlight group as Neovim's renderer
-- would resolve it. Some colorschemes (e.g. built-in `sorbet`) define DiffAdd /
-- DiffDelete using `fg` plus `reverse = true`; Neovim's renderer swaps fg<->bg
-- at draw time, so the visually-correct "background" comes from `fg`. Just
-- reading `hl.bg` produces black/default for those schemes (issue #366).
-- Returns gui_bg, cterm_bg (either may be nil if neither side is defined).
local function effective_bg(hl)
  if not hl then
    return nil, nil
  end
  local gui = (hl.reverse and hl.fg) or hl.bg
  local cterm_reverse = (hl.cterm and hl.cterm.reverse) or hl.reverse
  local cterm = (cterm_reverse and hl.ctermfg) or hl.ctermbg
  return gui, cterm
end

-- Resolve color from config value (supports highlight group name or direct color)
-- Returns a table suitable for nvim_set_hl (e.g., { bg = 0x2ea043 })
local function resolve_color(value, fallback_gui, fallback_cterm)
  if not value then
    return { bg = fallback_gui, ctermbg = fallback_cterm }
  end

  -- If it's a string, check if it's a hex color or highlight group name
  if type(value) == "string" then
    -- Check if it's a hex color (#RRGGBB or #RGB)
    local hex = value:match("^#(%x%x%x%x%x%x)$")
    local short = value:match("^#(%x%x%x)$")
    if hex or short then
      if short then
        hex = short:gsub(".", "%0%0")
      end
      return { bg = tonumber(hex, 16), ctermbg = fallback_cterm }
    else
      -- Assume it's a highlight group name
      local hl = vim.api.nvim_get_hl(0, { name = value, link = false })
      local gui, cterm = effective_bg(hl)
      return {
        bg = gui or fallback_gui,
        ctermbg = cterm or fallback_cterm,
      }
    end
  elseif type(value) == "number" then
    -- Direct color number (e.g., 0x2ea043 or a base256 index)
    return { bg = value, ctermbg = value }
  end

  return { bg = fallback_gui, ctermbg = fallback_cterm }
end

local function is_highlight_group(value)
  return type(value) == "string" and not value:match("^#%x%x%x%x%x%x$") and not value:match("^#%x%x%x$")
end

local function effective_colors(fg, bg, reverse, fallback_bg)
  if reverse then
    return bg, fg or fallback_bg
  end
  return fg, bg or fallback_bg
end

-- Unlike line highlights, configured character groups retain all attributes; fallbacks only fill missing backgrounds.
local function resolve_char_highlight(configured_value, fallback_bg, fallback_cterm_bg)
  if not is_highlight_group(configured_value) then
    return resolve_color(configured_value, fallback_bg, fallback_cterm_bg)
  end

  local source = vim.api.nvim_get_hl(0, { name = configured_value, link = false })
  local result = vim.deepcopy(source)
  local cterm_reverse = (source.cterm and source.cterm.reverse) or source.reverse

  result.fg, result.bg = effective_colors(source.fg, source.bg, source.reverse, fallback_bg)
  result.ctermfg, result.ctermbg = effective_colors(source.ctermfg, source.ctermbg, cterm_reverse, fallback_cterm_bg)

  result.reverse = nil
  if result.cterm then
    result.cterm.reverse = nil
  end

  return result
end

-- Returns the base 256 color palette index of rgb color cube where r, g, b are 0-5 inclusive.
local function base256_color(r, g, b)
  return 16 + r * 36 + g * 6 + b
end

-- Returns the base 256 color palette index of greyscale shade where the shade is 0-23 inclusive.
local function base256_greyscale(shade)
  return 232 + shade
end

-- Setup VSCode-style highlight groups
function M.setup()
  local opts = config.options.highlights

  -- Line-level highlights
  local line_insert_color = resolve_color(opts.line_insert, 0x1d3042, base256_color(0, 1, 0))
  local line_delete_color = resolve_color(opts.line_delete, 0x351d2b, base256_color(1, 0, 0))

  vim.api.nvim_set_hl(0, "CodeDiffLineInsert", line_insert_color)
  vim.api.nvim_set_hl(0, "CodeDiffLineDelete", line_delete_color)

  -- Character-level highlights: use explicit values if provided, otherwise derive from line highlights
  local brightness = opts.char_brightness or (vim.o.background == "light" and 0.92 or 1.4)
  local function character_color(value, line, fallback, cterm)
    if value then
      return resolve_char_highlight(value, fallback, cterm)
    end
    return { bg = adjust_brightness(line.bg, brightness) or fallback, ctermbg = cterm }
  end
  local char_insert_color = character_color(opts.char_insert, line_insert_color, 0x2a4556, base256_color(0, 2, 0))
  local char_delete_color = character_color(opts.char_delete, line_delete_color, 0x4b2a3d, base256_color(2, 0, 0))

  vim.api.nvim_set_hl(0, "CodeDiffCharInsert", char_insert_color)
  vim.api.nvim_set_hl(0, "CodeDiffCharDelete", char_delete_color)

  vim.api.nvim_set_hl(0, "CodeDiffGutterInsert", { link = "CodeDiffLineInsert", default = true })
  vim.api.nvim_set_hl(0, "CodeDiffGutterDelete", { link = "CodeDiffLineDelete", default = true })

  -- Neovim applies number_hl_group to virtual lines anchored to the same buffer line.
  -- Keep these groups foreground-only so filler rows do not inherit a colored number-column background.
  vim.api.nvim_set_hl(0, "CodeDiffGutterInsertNumber", {
    fg = char_insert_color.bg,
    ctermfg = char_insert_color.ctermbg,
    default = true,
  })
  vim.api.nvim_set_hl(0, "CodeDiffGutterDeleteNumber", {
    fg = char_delete_color.bg,
    ctermfg = char_delete_color.ctermbg,
    default = true,
  })

  -- Moved code highlights (derived from DiffChange — the standard "changed" color)
  local diff_change_hl = vim.api.nvim_get_hl(0, { name = "DiffChange", link = false })
  local move_fallback = effective_bg(diff_change_hl) or 0x4f5258
  local line_move_color = resolve_color(opts.line_move, move_fallback, base256_color(0, 0, 2))
  vim.api.nvim_set_hl(0, "CodeDiffLineMove", line_move_color)

  local char_move_color = {
    bg = adjust_brightness(line_move_color.bg, brightness) or 0x2a4f7a,
    ctermbg = base256_color(0, 0, 3),
  }
  vim.api.nvim_set_hl(0, "CodeDiffCharMove", char_move_color)

  vim.api.nvim_set_hl(0, "CodeDiffMoveFrom", {
    fg = 0x6699cc,
    ctermfg = base256_color(1, 2, 4),
    default = true,
  })
  vim.api.nvim_set_hl(0, "CodeDiffMoveTo", {
    fg = 0x6699cc,
    ctermfg = base256_color(1, 2, 4),
    default = true,
  })

  -- Filler lines (no highlight, inherits editor default background)
  vim.api.nvim_set_hl(0, "CodeDiffFiller", {
    fg = "#444444", -- Subtle gray for the slash character
    ctermfg = base256_greyscale(8),
    default = true,
  })

  -- These are defaults so user-defined groups retain their settings.
  for name, link in pairs({
    ExplorerDirectorySmall = "Comment",
    CodeDiffExplorerSelected = "Visual",
    NeoTreeIndentMarker = "Comment",
    CodeDiffExplorerTreeGroup = "Directory",
    CodeDiffStatusAdded = "DiagnosticOk",
    CodeDiffStatusModified = "DiagnosticWarn",
    CodeDiffStatusDeleted = "DiagnosticError",
    CodeDiffStatusRenamed = "DiagnosticInfo",
    CodeDiffStatusUntracked = "DiagnosticInfo",
    CodeDiffStatusConflict = "DiagnosticError",
  }) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end

  -- Helper to check if a highlight group exists and has foreground color
  local function hl_exists(name)
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    return ok and hl and (hl.fg or hl.foreground)
  end

  local insertion_highlight = hl_exists("Added") and "Added" or "DiagnosticOk"
  local deletion_highlight = hl_exists("Removed") and "Removed" or "DiagnosticError"
  vim.api.nvim_set_hl(0, "CodeDiffExplorerStatFiles", { link = "Number", default = true })
  vim.api.nvim_set_hl(0, "CodeDiffExplorerStatInsertions", { link = insertion_highlight, default = true })
  vim.api.nvim_set_hl(0, "CodeDiffExplorerStatDeletions", { link = deletion_highlight, default = true })
  vim.api.nvim_set_hl(0, "CodeDiffExplorerStatBinary", { link = "NonText", default = true })

  -- Helper to set conflict sign highlight with user config as priority 0
  -- @param hl_name string The highlight group name to set
  -- @param user_value string|nil User config value (highlight group or hex color)
  -- @param fallbacks table List of fallback highlight groups to try
  -- @param default_hex string Default hex color if all fallbacks fail
  local function set_conflict_sign_hl(hl_name, user_value, fallbacks, default_hex)
    local style = { fg = default_hex, default = true }
    if user_value then
      style = user_value:match("^#%x%x%x%x%x%x$") and { fg = user_value, default = true } or { link = user_value, default = true }
    else
      for _, fallback in ipairs(fallbacks) do
        if hl_exists(fallback) then
          style = { link = fallback, default = true }
          break
        end
      end
    end
    vim.api.nvim_set_hl(0, hl_name, style)
  end

  -- Sign color priority: user config, first available group, then the hex color.
  for _, sign in ipairs({
    { "CodeDiffConflictSign", "conflict_sign", { "DiagnosticSignWarn" }, "#f0883e" },
    { "CodeDiffConflictSignResolved", "conflict_sign_resolved", { "Comment" }, "#6e7681" },
    { "CodeDiffConflictSignAccepted", "conflict_sign_accepted", { "GitSignsAdd", "DiagnosticSignOk" }, "#3fb950" },
    { "CodeDiffConflictSignRejected", "conflict_sign_rejected", { "GitSignsDelete", "DiagnosticSignError" }, "#f85149" },
  }) do
    set_conflict_sign_hl(sign[1], opts[sign[2]], sign[3], sign[4])
  end

  -- History panel title (bold, slightly dimmed)
  vim.api.nvim_set_hl(0, "CodeDiffHistoryTitle", {
    bold = true,
    link = "FloatTitle",
    default = true,
  })

  -- Re-derive when the user switches colorscheme at runtime. Without this, the
  -- CodeDiffLineInsert/Delete colors are frozen to whatever scheme was active
  -- at first setup() and look wrong under any later :colorscheme change.
  if not M._colorscheme_autocmd_installed then
    vim.api.nvim_create_autocmd("ColorScheme", {
      group = vim.api.nvim_create_augroup("codediff_highlights", { clear = true }),
      callback = function()
        M.setup()
      end,
    })
    M._colorscheme_autocmd_installed = true
  end
end

return M
