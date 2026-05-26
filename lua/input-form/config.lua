local utils = require("input-form.utils")

local M = {}

--- Default configuration for |input-form|.
---
---@tag input-form.config
---
--- Default values:
---@eval return MiniDoc.afterlines_to_code(MiniDoc.current.eval_section)
M.defaults = {
  --- Floating window appearance.
  window = {
    --- Border style passed to `nvim_open_win`. One of `none`, `single`,
    --- `double`, `rounded`, `solid`, `shadow`, or a custom 8-element list.
    border = "rounded",
    --- Window width in columns. Numbers <= 1 are treated as a ratio of
    --- `vim.o.columns` (e.g. `0.6` = 60% of editor width).
    width = 60,
    --- Window title string. Set to `nil` to omit.
    title = " Form ",
    --- Title alignment: `"left"`, `"center"`, or `"right"`.
    title_pos = "center",
    --- Pseudo-transparency (0-100).
    winblend = 0,
    --- Padding (in cells) between the parent border and the inputs. Applied to
    --- all four sides.
    padding = 0,
    --- Blank rows rendered between adjacent inputs.
    gap = 0,
  },
  --- Keymaps used inside the form. Set any value to `false` to disable.
  keymaps = {
    --- Focus the next input (wraps).
    next = "<Tab>",
    --- Focus the previous input (wraps).
    prev = "<S-Tab>",
    --- Submit the form and invoke `on_submit(results)`.
    submit = "<C-s>",
    --- Cancel the form and invoke `on_cancel()` if provided. Accepts a
    --- single key string or a list of keys — all listed keys trigger cancel.
    cancel = { "<Esc>", "q" },
    --- Open the dropdown when focused on a `select` input.
    open_select = "<CR>",
    --- Toggle the value of a `checkbox` input.
    toggle = "<Space>",
    --- Toggle a help popup listing every active keymap. The popup opens
    --- directly below the form window and closes on the same key.
    help = "?",
    --- Trigger completion for fields that define a completion source.
    complete = "<C-Space>",
  },
  --- Options for `select` inputs.
  select = {
    --- Maximum number of visible rows in the dropdown before scrolling.
    max_height = 10,
  },
  --- Default height (in rows) for `multiline` inputs that do not specify one.
  multiline = {
    height = 5,
  },
  --- Visual styling
  style = {
    --- Chevron glyphs shown on the right side of `select` inputs to indicate
    --- the dropdown state. Override either to taste (e.g. `"v"`/`"^"` for
    --- ASCII, or extra spacing for wider icons).
    chevron = {
      --- Glyph shown when the dropdown is closed.
      closed = "⌄",
      --- Glyph shown when the dropdown is open.
      open = "⌃",
    },
    --- Glyphs shown in `checkbox` inputs.
    checkbox = {
      --- Shown when the box is checked.
      checked = "☑",
      --- Shown when the box is unchecked.
      unchecked = "☐",
      --- Blank rows rendered above and below a checkbox to visually separate
      --- it from adjacent bordered inputs. Set to `0` to pack tightly.
      padding = 1,
    },
    --- Highlight groups applied on every `form:show()`. Each entry is passed
    --- directly to `vim.api.nvim_set_hl(0, name, spec)`, so any option that
    --- `nvim_set_hl` accepts (`fg`, `bg`, `link`, `bold`, `italic`,
    --- `default`, ...) is valid. User overrides fully replace the default
    --- spec for the matching group (they are NOT deep-merged field by field).
    highlights = {
      -- Parent form window
      InputFormNormal = { link = "NormalFloat", default = true },
      InputFormBorder = { link = "FloatBorder", default = true },
      InputFormTitle = { link = "FloatTitle", default = true },
      InputFormHelp = { fg = "Cyan", default = true },
      -- Individual input fields
      InputFormField = { link = "NormalFloat", default = true },
      InputFormFieldBorder = { link = "FloatBorder", default = true },
      InputFormFieldTitle = { link = "FloatTitle", default = true },
      -- Error state for individual input fields
      InputFormFieldError = { fg = "Red", default = true },
      InputFormFieldErrorBorder = { fg = "Red", default = true },
      InputFormFieldErrorTitle = { fg = "Red", default = true },
      -- Select dropdown list
      InputFormDropdown = { link = "NormalFloat", default = true },
      InputFormDropdownActive = { link = "PmenuSel", default = true },
    },
  },
}

M.options = vim.deepcopy(M.defaults)

--- Merge user options over defaults and store them on the module.
---@tag input-form.config.setup
---@param user_opts table|nil
---@return table
function M.setup(user_opts)
  local merged = utils.merge(vim.deepcopy(M.defaults), user_opts or {})
  -- Highlight specs must be replaced per-group, not deep-merged, so a user
  -- override like `{ fg = "#ff5555" }` doesn't inherit the default's
  -- `default = true` flag (which would let a colorscheme clobber it).
  if user_opts and user_opts.style and user_opts.style.highlights then
    for name, spec in pairs(user_opts.style.highlights) do
      merged.style.highlights[name] = spec
    end
  end
  M.options = merged
  return M.options
end

return M
