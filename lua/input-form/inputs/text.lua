--- Single-line text input component.

local utils = require("input-form.utils")

local M = {}
M.__index = M

--- Create a new text input from its spec.
---@param spec table { name, label, default? }
---@return table
function M.new(spec)
  return setmetatable({
    type = "text",
    name = spec.name,
    label = spec.label or spec.name,
    _value = spec.default or "",
    buf = nil,
    win = nil,
  }, M)
end

--- Number of content rows (excluding the label line) this input occupies.
function M:height()
  return 1
end

function M:is_bordered()
  return true
end

--- Create the backing buffer and floating window.
---@param layout table { row, col, width }
function M:mount(layout)
  self.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.buf].buftype = "nofile"
  vim.bo[self.buf].bufhidden = "wipe"
  vim.bo[self.buf].swapfile = false
  utils.mark_form_buffer(self.buf)
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, { self._value })

  local win_cfg = {
    relative = "editor",
    row = layout.row,
    col = layout.col,
    width = layout.width,
    height = 1,
    style = "minimal",
    focusable = true,
    zindex = 50,
  }
  if layout.border then
    win_cfg.border = layout.border
    win_cfg.title = " " .. self.label .. " "
    win_cfg.title_pos = "left"
  end
  self.win = vim.api.nvim_open_win(self.buf, false, win_cfg)
  vim.wo[self.win].winhl =
    "NormalFloat:InputFormField,FloatBorder:InputFormFieldBorder,FloatTitle:InputFormFieldTitle"
end

--- Return current value (from the buffer if mounted, otherwise the cached value).
function M:value()
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    local lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
    return lines[1] or ""
  end
  return self._value
end

--- Programmatically set the field value.
---@param v string
function M:set_value(v)
  self._value = v or ""
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, { self._value })
  end
end

--- Close the window and buffer, caching the current value.
function M:unmount()
  self._value = self:value()
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_close(self.win, true)
  end
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    vim.api.nvim_buf_delete(self.buf, { force = true })
  end
  self.win = nil
  self.buf = nil
end

--- Give this input focus and enter insert mode at the end of the line.
function M:focus()
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_set_current_win(self.win)
    local line = self:value()
    vim.api.nvim_win_set_cursor(self.win, { 1, #line })
  end
end

return M
