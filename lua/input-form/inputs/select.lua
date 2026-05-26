--- Dropdown / select input component.
---
--- The value returned by `:value()` is the `id` of the selected option, not
--- its label. Opening the dropdown shows all options in a child floating
--- window; j/k/arrows navigate, <CR> confirms, <Esc> cancels.

local config = require("input-form.config")
local utils = require("input-form.utils")

local M = {}
M.__index = M

--- Create a new select input from its spec.
---@param spec table { name, label, options, default? }
---@return table
function M.new(spec)
  assert(
    type(spec.options) == "table" and #spec.options > 0,
    "select input requires non-empty options"
  )
  local selected_id = spec.default
  if selected_id == nil then
    selected_id = spec.options[1].id
  end
  return setmetatable({
    type = "select",
    name = spec.name,
    label = spec.label or spec.name,
    options = spec.options,
    _selected_id = selected_id,
    buf = nil,
    win = nil,
    dropdown_buf = nil,
    dropdown_win = nil,
  }, M)
end

function M:height()
  return 1
end

function M:is_bordered()
  return true
end

local function label_for(options, id)
  for _, opt in ipairs(options) do
    if opt.id == id then
      return opt.label
    end
  end
  return ""
end

-- Fallbacks in case the config module has been mutated to a malformed state.
local DEFAULT_CHEVRON_CLOSED = "⌄"
local DEFAULT_CHEVRON_OPEN = "⌃"

local function chevron_for(open)
  local style = config.options.style or {}
  local chev = style.chevron or {}
  if open then
    return chev.open or DEFAULT_CHEVRON_OPEN
  end
  return chev.closed or DEFAULT_CHEVRON_CLOSED
end

local function format_display(options, id, width, open)
  local label = label_for(options, id)
  local chevron = chevron_for(open)
  if not width or width <= 0 then
    return label .. chevron
  end
  local label_w = vim.fn.strdisplaywidth(label)
  local chev_w = vim.fn.strdisplaywidth(chevron)
  local pad = width - label_w - chev_w
  if pad < 1 then
    pad = 1
  end
  return label .. string.rep(" ", pad) .. chevron
end

function M:_render_display()
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    local line = format_display(self.options, self._selected_id, self._width, self._open)
    vim.bo[self.buf].modifiable = true
    vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, { line })
    vim.bo[self.buf].modifiable = false
  end
end

function M:mount(layout)
  self._width = layout.width
  self.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.buf].buftype = "nofile"
  vim.bo[self.buf].bufhidden = "wipe"
  vim.bo[self.buf].swapfile = false
  utils.mark_form_buffer(self.buf)
  vim.api.nvim_buf_set_lines(
    self.buf,
    0,
    -1,
    false,
    { format_display(self.options, self._selected_id, self._width, self._open) }
  )
  vim.bo[self.buf].modifiable = false

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
  self._layout = layout
end

function M:value()
  return self._selected_id
end

function M:unmount()
  self:close_dropdown()
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
    -- Park the cursor at col 0 so the terminal cursor block sits on the label
    -- (clean state) or on the dirty-shifted chevron's left neighbour (dirty
    -- state), never on top of the chevron itself.
    pcall(vim.api.nvim_win_set_cursor, self.win, { 1, 0 })
  end
end

--- Open the dropdown list as a child floating window anchored below the input.
function M:open_dropdown()
  if self.dropdown_win and vim.api.nvim_win_is_valid(self.dropdown_win) then
    return
  end

  local lines = {}
  local init_idx = 1
  for i, opt in ipairs(self.options) do
    table.insert(lines, "  " .. opt.label)
    if opt.id == self._selected_id then
      init_idx = i
    end
  end

  self.dropdown_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.dropdown_buf].buftype = "nofile"
  vim.bo[self.dropdown_buf].bufhidden = "wipe"
  utils.mark_form_buffer(self.dropdown_buf)
  vim.api.nvim_buf_set_lines(self.dropdown_buf, 0, -1, false, lines)
  vim.bo[self.dropdown_buf].modifiable = false

  local max_h = config.options.select.max_height
  local height = math.min(#lines, max_h)

  -- Prefer stitching the dropdown's top border into the select's bottom
  -- border for a compact, merged look:
  --
  --   ╭─ Label ─────╮
  --   │ Option 1  ⌃ │
  --   ├─────────────┤   <- shared row (dropdown's top border with T-junction
  --   │ Option 1    │      connectors, overlaid on the select's bottom)
  --   │ Option 2    │
  --   ╰─────────────╯
  --
  -- The dropdown is positioned so its top border row coincides with the
  -- select's bottom border row. With a higher zindex, the dropdown's top
  -- border (├─┤ / ╠═╣) wins, producing the visible T-junctions.
  local cfg_border = config.options.window.border
  local merged_border = utils.merged_top_border(cfg_border)
  local dropdown_row, dropdown_border
  if merged_border then
    dropdown_row = self._layout.row + 2
    dropdown_border = merged_border
  else
    -- Fallback for unmergeable borders (`"none"`, `"shadow"`, ...): keep the
    -- dropdown on its own, one row below the select.
    dropdown_row = self._layout.row + 3
    dropdown_border = cfg_border
  end

  self.dropdown_win = vim.api.nvim_open_win(self.dropdown_buf, true, {
    relative = "editor",
    row = dropdown_row,
    col = self._layout.col,
    width = self._layout.width,
    height = height,
    style = "minimal",
    border = dropdown_border,
    focusable = true,
    zindex = 100,
  })
  self._open = true
  self:_render_display()
  vim.wo[self.dropdown_win].cursorline = true
  vim.wo[self.dropdown_win].winhl =
    "NormalFloat:InputFormDropdown,CursorLine:InputFormDropdownActive"
  vim.api.nvim_win_set_cursor(self.dropdown_win, { init_idx, 0 })

  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = self.dropdown_buf, nowait = true, silent = true })
  end
  local function confirm()
    local row = vim.api.nvim_win_get_cursor(self.dropdown_win)[1]
    local new_id = self.options[row].id
    local changed = new_id ~= self._selected_id
    self._selected_id = new_id
    self:_render_display()
    self:close_dropdown()
    if changed and self._on_change then
      self._on_change()
    end
  end
  map("<CR>", confirm)
  map("<Esc>", function()
    self:close_dropdown()
  end)
  map("q", function()
    self:close_dropdown()
  end)
end

function M:close_dropdown()
  if self.dropdown_win and vim.api.nvim_win_is_valid(self.dropdown_win) then
    vim.api.nvim_win_close(self.dropdown_win, true)
  end
  if self.dropdown_buf and vim.api.nvim_buf_is_valid(self.dropdown_buf) then
    pcall(vim.api.nvim_buf_delete, self.dropdown_buf, { force = true })
  end
  self.dropdown_win = nil
  self.dropdown_buf = nil
  self._open = false
  self:_render_display()
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_set_current_win(self.win)
  end
end

--- Programmatically set the selected option by id (used in tests & external callers).
function M:select_id(id)
  local changed = id ~= self._selected_id
  for _, opt in ipairs(self.options) do
    if opt.id == id then
      self._selected_id = id
      self:_render_display()
      if changed and self._on_change then
        self._on_change()
      end
      return true
    end
  end
  return false
end

--- Programmatically set the selected value by option id.
---@param v any Option id to select.
function M:set_value(v)
  self:select_id(v)
end

return M
