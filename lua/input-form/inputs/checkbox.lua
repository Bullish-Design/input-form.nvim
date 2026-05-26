--- Boolean checkbox input component.
---
--- Unlike text/multiline/select, the checkbox is borderless and renders
--- inline: the label sits next to the glyph, and any validation error is
--- appended to the same line (`☑ Label (must be checked)`). The error
--- portion is highlighted with `InputFormFieldError`.
---
--- Toggles via the configured `keymaps.toggle` key (default `<Space>`) and
--- also the `keymaps.open_select` key, so users get a consistent
--- "interact with this field" key.
--- `value()` returns a boolean.

local config = require("input-form.config")
local utils = require("input-form.utils")

local M = {}
M.__index = M

--- Create a new checkbox from its spec.
---@param spec table { name, label, default? }
---@return table
function M.new(spec)
  return setmetatable({
    type = "checkbox",
    name = spec.name,
    label = spec.label or spec.name,
    _value = spec.default == true,
    buf = nil,
    win = nil,
  }, M)
end

function M:height()
  return 1
end

--- Checkboxes are rendered without a surrounding border/title so the form's
--- layout packs them more tightly than the other input types.
function M:is_bordered()
  return false
end

local NS = vim.api.nvim_create_namespace("input-form-checkbox")

local function glyph_for(checked)
  local style = config.options.style or {}
  local cb = style.checkbox or {}
  if checked then
    return cb.checked or "☑"
  end
  return cb.unchecked or "☐"
end

function M:_render_display()
  if not (self.buf and vim.api.nvim_buf_is_valid(self.buf)) then
    return
  end
  local glyph = glyph_for(self._value)
  local base = glyph
  if self.label and self.label ~= "" then
    base = glyph .. " " .. self.label
  end
  local err = (self._error and self._error ~= "") and self._error or nil
  local line = err and (base .. " " .. err) or base

  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, { line })
  vim.bo[self.buf].modifiable = false

  -- Highlight the error suffix (if any).
  vim.api.nvim_buf_clear_namespace(self.buf, NS, 0, -1)
  if err then
    local err_start = #base + 1 -- byte offset of the space before the error
    pcall(vim.api.nvim_buf_set_extmark, self.buf, NS, 0, err_start, {
      end_col = #line,
      hl_group = "InputFormFieldError",
    })
  end
end

function M:mount(layout)
  self._width = layout.width
  self.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.buf].buftype = "nofile"
  vim.bo[self.buf].bufhidden = "wipe"
  vim.bo[self.buf].swapfile = false
  utils.mark_form_buffer(self.buf)

  self.win = vim.api.nvim_open_win(self.buf, false, {
    relative = "editor",
    row = layout.row,
    col = layout.col,
    width = layout.width,
    height = 1,
    style = "minimal",
    focusable = true,
    zindex = 50,
  })
  vim.wo[self.win].winhl = "NormalFloat:InputFormField"

  self:_render_display()
end

function M:value()
  return self._value
end

function M:unmount()
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_close(self.win, true)
  end
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    vim.api.nvim_buf_delete(self.buf, { force = true })
  end
  self.win = nil
  self.buf = nil
end

function M:focus()
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_set_current_win(self.win)
    pcall(vim.api.nvim_win_set_cursor, self.win, { 1, 0 })
  end
end

--- Toggle the checkbox state. Notifies the form (for validation) if an
--- `_on_change` hook has been installed.
function M:toggle()
  self._value = not self._value
  self:_render_display()
  if self._on_change then
    self._on_change()
  end
end

--- Programmatically set the checkbox value.
---@param v any Truthy for checked, falsey for unchecked.
function M:set(v)
  local new = v and true or false
  if new == self._value then
    return
  end
  self._value = new
  self:_render_display()
  if self._on_change then
    self._on_change()
  end
end

--- Programmatically set the checkbox value (alias for :set()).
---@param v any Truthy for checked, falsey for unchecked.
function M:set_value(v)
  self:set(v)
end

return M
