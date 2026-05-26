--- Form object: manages a bordered floating window containing multiple inputs.

local config = require("input-form.config")
local inputs_factory = require("input-form.inputs")
local utils = require("input-form.utils")

local M = {}
M.__index = M

--- Create a new form from its spec. Does NOT open any windows — call `:show()`.
---@param spec table { inputs, on_submit, on_cancel?, title?, width? }
---@return table
function M.new(spec)
  assert(type(spec) == "table", "create_form: spec must be a table")
  assert(
    type(spec.inputs) == "table" and #spec.inputs > 0,
    "create_form: spec.inputs must be a non-empty list"
  )

  local self = setmetatable({
    _spec = spec,
    _inputs = {},
    _on_submit = spec.on_submit,
    _on_cancel = spec.on_cancel,
    _title = spec.title,
    _width = spec.width,
    _visible = false,
    _closed = false,
    _parent_win = nil,
    _parent_buf = nil,
    _focus_idx = 1,
  }, M)

  for _, input_spec in ipairs(spec.inputs) do
    table.insert(self._inputs, inputs_factory.build(input_spec))
  end

  return self
end

--- Compute geometry for the parent window and each child input window.
---
--- Each input is a separately-bordered floating window whose label is drawn on
--- its own top border. The parent window contains them all with padding.
---
--- Coordinate reminder: `row`/`col` passed to `nvim_open_win` with a border
--- describe the CONTENT origin; the border is drawn one cell outside that.
function M:_compute_layout()
  local opts = config.options
  -- `width` is the parent's OUTER width (i.e. visible width including border).
  local outer_width = utils.resolve_width(self._width or opts.window.width)

  -- Grow the window to fit the footer hint if the user's configured width
  -- is too narrow. The footer string is " <hint> " so we need at least
  -- #hint + 2 (leading/trailing space) + 2 (corners) cells of outer width.
  local hint = self:_help_hint()
  if hint and hint ~= "" then
    local needed = vim.fn.strdisplaywidth(hint) + 4
    if outer_width < needed then
      outer_width = needed
    end
  end

  outer_width = utils.clamp(outer_width, 20, vim.o.columns - 4)

  local padding = opts.window.padding or 0
  local gap = opts.window.gap or 0
  local pad_h = padding -- horizontal padding inside parent, each side
  local pad_top = padding
  local pad_bottom = padding
  local sep = gap -- blank rows between inputs

  local parent_inner_w = outer_width - 2 -- minus parent border
  local child_outer_w = parent_inner_w - pad_h * 2
  local child_inner_w = child_outer_w - 2 -- minus child border (for bordered inputs)

  -- Extra blank rows rendered above/below a checkbox (borderless input) so
  -- its glyph doesn't butt directly against an adjacent bordered input's
  -- border. Configurable via `style.checkbox.padding`.
  local cb_pad = (opts.style and opts.style.checkbox and opts.style.checkbox.padding) or 0

  local rows = {}
  local inner_h = pad_top
  for i, input in ipairs(self._inputs) do
    local h = input:height()
    -- NB: avoid the `a and b or c` idiom — `is_bordered()` legitimately
    -- returns `false` and that must not get coerced back to the default.
    local bordered = true
    if type(input.is_bordered) == "function" then
      bordered = input:is_bordered()
    end
    -- Only actual checkboxes get the configured blank padding. Spacers are
    -- also borderless but their `height` is the user's exact request.
    local top_pad = (input.type == "checkbox") and cb_pad or 0
    local bot_pad = (input.type == "checkbox") and cb_pad or 0
    local outer_h = bordered and (h + 2) or (h + top_pad + bot_pad)
    -- Editor-row offset from `parent_row` to pass as `nvim_open_win`'s `row`
    -- parameter for this child. `row` refers to the window's OUTER top-left
    -- (i.e. the border origin for bordered windows, the content row for
    -- borderless windows). Parent_row is itself a border origin, so every
    -- child needs a `+1` to clear the parent's top border — matching the
    -- `+1` already applied on the column axis in `show()`.
    local content_offset = inner_h + 1 + top_pad
    table.insert(rows, {
      bordered = bordered,
      content_row_offset = content_offset,
      value_height = h,
    })
    inner_h = inner_h + outer_h
    if i < #self._inputs then
      inner_h = inner_h + sep
    end
  end
  inner_h = inner_h + pad_bottom

  local outer_h = inner_h + 2 -- plus parent border
  local top = math.floor((vim.o.lines - outer_h) / 2)
  local left = math.floor((vim.o.columns - outer_width) / 2)

  -- Parent content origin (pass to nvim_open_win as row/col).
  local parent_row = top + 1
  local parent_col = left + 1

  return {
    outer_width = outer_width,
    outer_height = outer_h,
    parent_row = parent_row,
    parent_col = parent_col,
    parent_inner_w = parent_inner_w,
    parent_inner_h = inner_h,
    child_outer_w = child_outer_w,
    child_inner_w = child_inner_w,
    pad_h = pad_h,
    rows = rows,
  }
end

--- Open the form on screen. No-op if already visible.
function M:show()
  assert(not self._closed, "form has been closed")
  if self._visible then
    return self
  end
  self._visible = true

  -- Lazy: teach known UI plugins (nvim-scrollbar, satellite, ...) to skip
  -- form buffers. Runs once per nvim session.
  utils.register_ui_exclusions()

  -- Apply configured highlight groups (user-configurable via
  -- `setup({ style = { highlights = { ... } } })`).
  self:_apply_highlights()

  local layout = self:_compute_layout()
  self._layout = layout

  -- Parent window: an empty, bordered container that frames the inputs.
  self._parent_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self._parent_buf].buftype = "nofile"
  vim.bo[self._parent_buf].bufhidden = "wipe"
  vim.bo[self._parent_buf].swapfile = false
  utils.mark_form_buffer(self._parent_buf)

  local parent_lines = {}
  for _ = 1, layout.parent_inner_h do
    table.insert(parent_lines, string.rep(" ", layout.parent_inner_w))
  end
  vim.api.nvim_buf_set_lines(self._parent_buf, 0, -1, false, parent_lines)
  vim.bo[self._parent_buf].modifiable = false

  local win_opts = {
    relative = "editor",
    row = layout.parent_row,
    col = layout.parent_col,
    width = layout.parent_inner_w,
    height = layout.parent_inner_h,
    style = "minimal",
    border = config.options.window.border,
    focusable = false,
    zindex = 40,
  }
  if config.options.window.title and vim.fn.has("nvim-0.9") == 1 then
    win_opts.title = self._title or config.options.window.title
    win_opts.title_pos = config.options.window.title_pos
  end
  if vim.fn.has("nvim-0.10") == 1 then
    local footer = self:_help_hint()
    if footer and footer ~= "" then
      win_opts.footer = " " .. footer .. " "
      win_opts.footer_pos = "right"
    end
  end
  self._parent_win = vim.api.nvim_open_win(self._parent_buf, false, win_opts)
  vim.wo[self._parent_win].winblend = config.options.window.winblend
  vim.wo[self._parent_win].winhl = table.concat({
    "NormalFloat:InputFormNormal",
    "FloatBorder:InputFormBorder",
    "FloatTitle:InputFormTitle",
    "FloatFooter:InputFormHelp",
  }, ",")

  -- Mount each input as its own floating window. Bordered inputs get their
  -- own border + label; borderless inputs (e.g. checkbox) render inline but
  -- still align their CONTENT column with the bordered siblings' content
  -- (not their border column) so everything lines up visually.
  local border = config.options.window.border
  for i, input in ipairs(self._inputs) do
    -- Spacers are visual-only; they reserve layout rows but never mount a
    -- window and don't participate in keymaps/validation/focus.
    if input.type == "spacer" then
      goto continue
    end
    local r = layout.rows[i]
    -- Bordered children get `+1` to clear the parent's left border; their
    -- content then sits at `+2`. Borderless children shift an extra column
    -- so their content column lines up with the bordered siblings' content
    -- column (not their border column).
    local col_offset = r.bordered and 1 or 2
    local mount_opts = {
      row = layout.parent_row + r.content_row_offset,
      col = layout.parent_col + layout.pad_h + col_offset,
      width = layout.child_inner_w,
    }
    if r.bordered then
      mount_opts.border = border
    end
    input:mount(mount_opts)
    self:_install_keymaps(input)
    self:_install_validation(input)
    self:_install_auto_complete(input)
    ::continue::
  end

  self:_focus(self:_first_focusable() or 1)
  return self
end

--- Return `true` if `input` participates in focus navigation.
local function is_focusable(input)
  if input == nil then
    return false
  end
  return input.focusable ~= false and input.type ~= "spacer"
end

--- Index of the first focusable input, or `nil` if none exist.
function M:_first_focusable()
  for i, input in ipairs(self._inputs) do
    if is_focusable(input) then
      return i
    end
  end
  return nil
end

--- Apply all configured highlight groups. Called from `show()` so live
--- `setup({ style = { highlights = ... } })` edits take effect on the next
--- form open.
function M:_apply_highlights()
  local style = config.options.style or {}
  local hls = style.highlights or {}
  for name, spec in pairs(hls) do
    pcall(vim.api.nvim_set_hl, 0, name, spec)
  end
end

--- Hide the form (close windows) but keep state so `:show()` can reopen it.
function M:hide()
  if not self._visible then
    return
  end
  self:_close_help()
  for _, input in ipairs(self._inputs) do
    input:unmount()
  end
  if self._parent_win and vim.api.nvim_win_is_valid(self._parent_win) then
    vim.api.nvim_win_close(self._parent_win, true)
  end
  if self._parent_buf and vim.api.nvim_buf_is_valid(self._parent_buf) then
    pcall(vim.api.nvim_buf_delete, self._parent_buf, { force = true })
  end
  self._parent_win = nil
  self._parent_buf = nil
  self._visible = false
end

--- Permanently tear down the form.
function M:close()
  self:hide()
  self._closed = true
end

--- Collect current values from all inputs into a { [name] = value } table.
--- Spacers have no name/value and are skipped.
function M:results()
  local out = {}
  for _, input in ipairs(self._inputs) do
    if input.type ~= "spacer" and input.name then
      out[input.name] = input:value()
    end
  end
  return out
end

--- Look up an input by field name.
---@param name string
---@return table|nil
function M:_find_input(name)
  for _, input in ipairs(self._inputs) do
    if input.name == name then
      return input
    end
  end
  return nil
end

--- Get the current value of a single field by name.
---@param name string
---@return any|nil value, or nil if the field does not exist
function M:get_value(name)
  local input = self:_find_input(name)
  if input then
    return input:value()
  end
  return nil
end

--- Set the value of a single field by name.
---@param name string
---@param value any
function M:set_value(name, value)
  local input = self:_find_input(name)
  if input and input.set_value then
    input:set_value(value)
  end
end

--- Re-render the form (re-validate visible fields). Call after set_value()
--- to refresh the display when programmatically changing values from callbacks.
function M:render()
  if not self._visible then
    return
  end
  for _, input in ipairs(self._inputs) do
    if input._touched then
      self:_validate_input(input)
      self:_render_validation(input)
    end
  end
end

--- Return the currently focused input object, or nil if unavailable.
---@return table|nil
function M:get_focused_field()
  if not self._visible then
    return nil
  end
  local input = self._inputs[self._focus_idx]
  if not input or not is_focusable(input) then
    return nil
  end
  return input
end

--- Submit the form: gather values, run validators, and invoke
--- `on_submit(results)` only if everything validates. If any input has an
--- error, submission is blocked, all inputs are force-validated (so the user
--- sees every error, including ones on untouched fields), and focus moves to
--- the first invalid input.
function M:submit()
  if self._visible and self:_validate_all() then
    -- Validation failed — do not close, do not invoke on_submit.
    return
  end
  local results = self:results()
  self:hide()
  if self._on_submit then
    self._on_submit(results)
  end
end

--- Run every input's validator (marking each as touched first) and render
--- results. Returns `true` if any input has an error.
function M:_validate_all()
  local any_error = false
  local first_bad = nil
  for i, input in ipairs(self._inputs) do
    if input.validator then
      input._touched = true
      local err = input.validator(input:value())
      -- Only strings count as errors; nil / false / other types = no error.
      if type(err) ~= "string" or err == "" then
        err = nil
      end
      input._error = err
      self:_render_validation(input)
      if err and not first_bad then
        first_bad = i
      end
      if err then
        any_error = true
      end
    end
  end
  if first_bad then
    self:_focus(first_bad)
  end
  return any_error
end

--- Cancel the form: close windows, invoke `on_cancel()` if provided.
function M:cancel()
  self:hide()
  if self._on_cancel then
    self._on_cancel()
  end
end

--- Install validation autocmds for an input. No-op if the input has no
--- validator. Validation runs:
---   - on `WinLeave` (blurring the field marks it touched and validates)
---   - on `TextChanged` / `TextChangedI` IF the input is already touched
---
--- For `select` inputs, the user "touches" the field by picking an option;
--- `_render_display`'s `nvim_buf_set_lines` call also fires `TextChanged`
--- so the same path handles re-validation there.
function M:_install_validation(input)
  if not input.validator then
    return
  end
  local buf = input.buf
  if not buf then
    return
  end
  local form = self
  local group = vim.api.nvim_create_augroup("InputFormValidate_" .. tostring(buf), { clear = true })
  input._val_group = group

  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    buffer = buf,
    callback = function()
      input._touched = true
      form:_validate_input(input)
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = buf,
    callback = function()
      if input._touched then
        form:_validate_input(input)
      end
    end,
  })

  -- For `select` inputs, changes happen while the dropdown buffer is current,
  -- so `TextChanged` on the display buffer doesn't fire. The input exposes an
  -- `_on_change` hook that we use to mark it touched and re-validate.
  input._on_change = function()
    input._touched = true
    form:_validate_input(input)
  end
end

--- Run the validator for one input and update its visual error state.
function M:_validate_input(input)
  if not input.validator then
    return
  end
  local err = input.validator(input:value())
  -- Only strings count as errors; nil / false / other types = no error.
  if type(err) ~= "string" or err == "" then
    err = nil
  end
  input._error = err
  self:_render_validation(input)
end

--- Apply/clear the red border, title, and footer error message on an input's
--- floating window based on its current `_error` state.
function M:_render_validation(input)
  local win = input.win
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end

  -- Borderless inputs (checkbox) render the error inline — they already read
  -- `self._error` from their own `_render_display()`.
  local bordered = true
  if type(input.is_bordered) == "function" then
    bordered = input:is_bordered()
  end
  if not bordered then
    if type(input._render_display) == "function" then
      input:_render_display()
    end
    return
  end

  local has_error = input._error ~= nil

  if has_error then
    vim.wo[win].winhl = table.concat({
      "NormalFloat:InputFormField",
      "FloatBorder:InputFormFieldErrorBorder",
      "FloatTitle:InputFormFieldErrorTitle",
      "FloatFooter:InputFormFieldError",
    }, ",")
  else
    vim.wo[win].winhl = table.concat({
      "NormalFloat:InputFormField",
      "FloatBorder:InputFormFieldBorder",
      "FloatTitle:InputFormFieldTitle",
    }, ",")
  end

  -- Footer (error message) requires nvim 0.10+.
  if vim.fn.has("nvim-0.10") == 1 then
    local ok, cfg = pcall(vim.api.nvim_win_get_config, win)
    if ok and cfg and cfg.relative ~= "" then
      if has_error then
        -- Truncate to window width with an ellipsis.
        local max_w = (cfg.width or 0) - 2
        local msg = input._error
        if max_w > 3 and vim.fn.strdisplaywidth(msg) > max_w then
          msg = vim.fn.strcharpart(msg, 0, max_w - 1) .. "…"
        end
        cfg.footer = " " .. msg .. " "
        cfg.footer_pos = "left"
      else
        cfg.footer = ""
      end
      pcall(vim.api.nvim_win_set_config, win, cfg)
    end
  end
end

--- Format a keymap value (string or list of strings) for display. Returns
--- `nil` if the value is effectively empty / disabled.
local function format_keys(val)
  if not val or val == false or val == "" then
    return nil
  end
  if type(val) == "table" then
    local parts = {}
    for _, k in ipairs(val) do
      if k and k ~= false and k ~= "" then
        table.insert(parts, k)
      end
    end
    if #parts == 0 then
      return nil
    end
    return table.concat(parts, " / ")
  end
  return tostring(val)
end

--- Short footer hint shown on the form's bottom border (e.g. `"? help"`).
--- Returns `nil` if the help keymap is disabled.
function M:_help_hint()
  local key = format_keys(config.options.keymaps.help)
  if not key then
    return nil
  end
  return key .. " help"
end

--- Collect `{ keys, description }` pairs for every active keymap, filtered
--- to what this form actually uses. Consumed by the help popup.
function M:_help_entries()
  local km = config.options.keymaps
  local entries = {}
  local function add(keys, desc)
    local display = format_keys(keys)
    if display then
      table.insert(entries, { display, desc })
    end
  end
  local nxt, prv = format_keys(km.next), format_keys(km.prev)
  local nav
  if nxt and prv then
    nav = nxt .. " / " .. prv
  else
    nav = nxt or prv
  end
  if nav then
    table.insert(entries, { nav, "navigate fields" })
  end
  -- Only advertise type-specific keys if the form actually has such an input.
  local has_select, has_checkbox = false, false
  for _, input in ipairs(self._inputs) do
    if input.type == "select" then
      has_select = true
    elseif input.type == "checkbox" then
      has_checkbox = true
    end
  end
  if has_select then
    add(km.open_select, "open dropdown")
  end
  if has_checkbox then
    add(km.toggle, "toggle checkbox")
  end
  local focused = self._inputs[self._focus_idx]
  if focused and focused.field_keymaps then
    for lhs, _ in pairs(focused.field_keymaps) do
      table.insert(entries, { lhs, focused.name .. " action" })
    end
  end
  if focused and focused.complete then
    add(km.complete, "complete")
  end
  add(km.submit, "submit form")
  add(km.cancel, "cancel form")
  add(km.help, "toggle this help")
  return entries
end

--- Build the wrapped lines of the help popup given a maximum width (the
--- popup's content width). Each keymap occupies its own row formatted as
--- `"<keys>  <description>"` with keys right-padded to a common column so
--- descriptions line up. If an entry exceeds `max_w` the description wraps
--- onto a hanging indent.
function M:_help_lines(max_w)
  local entries = self:_help_entries()
  if #entries == 0 then
    return {}
  end
  -- Cap the key column so a single oversized key doesn't eat the whole row.
  local max_key_w = 0
  for _, e in ipairs(entries) do
    local w = vim.fn.strdisplaywidth(e[1])
    if w > max_key_w then
      max_key_w = w
    end
  end
  max_key_w = math.min(max_key_w, math.max(4, math.floor(max_w / 2)))

  local gap = "  "
  local gap_w = vim.fn.strdisplaywidth(gap)
  local indent = string.rep(" ", max_key_w + gap_w)

  local lines = {}
  for _, e in ipairs(entries) do
    local keys, desc = e[1], e[2]
    local key_w = vim.fn.strdisplaywidth(keys)
    local pad = string.rep(" ", math.max(0, max_key_w - key_w))
    local prefix = keys .. pad .. gap
    -- Wrap the description into the remaining width. `avail` is the
    -- width available for description text (max_w minus key column).
    local avail = math.max(1, max_w - vim.fn.strdisplaywidth(prefix))
    local chunks = M._wrap_text(desc, avail)
    table.insert(lines, prefix .. (chunks[1] or ""))
    for i = 2, #chunks do
      table.insert(lines, indent .. chunks[i])
    end
  end
  return lines
end

--- Word-wrap `text` to rows no wider than `width` display cells. Falls back
--- to a hard character cut for a single token longer than `width`.
function M._wrap_text(text, width)
  if width <= 0 then
    return { text }
  end
  if vim.fn.strdisplaywidth(text) <= width then
    return { text }
  end
  local out = {}
  local line = ""
  for word in string.gmatch(text, "%S+") do
    if line == "" then
      line = word
    else
      local candidate = line .. " " .. word
      if vim.fn.strdisplaywidth(candidate) <= width then
        line = candidate
      else
        table.insert(out, line)
        line = word
      end
    end
    -- Single word wider than width: hard-cut on character boundaries.
    while vim.fn.strdisplaywidth(line) > width do
      local cut = vim.fn.strcharpart(line, 0, width)
      table.insert(out, cut)
      line = vim.fn.strcharpart(line, vim.fn.strchars(cut))
    end
  end
  if line ~= "" then
    table.insert(out, line)
  end
  return out
end

--- Open the help popup directly below the form window. No-op if already
--- open or if the form is not visible.
function M:_open_help()
  if not self._visible or not self._layout then
    return
  end
  if self._help_win and vim.api.nvim_win_is_valid(self._help_win) then
    return
  end
  local layout = self._layout
  -- Match the parent's outer width so borders align vertically.
  local content_w = layout.parent_inner_w
  local lines = self:_help_lines(content_w)
  if #lines == 0 then
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  utils.mark_form_buffer(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  -- Parent's outer bottom-border row = parent_row + parent_inner_h + 1
  -- (parent_row is the border origin). The help popup's top border sits
  -- one row below that.
  local help_row = layout.parent_row + layout.parent_inner_h + 2
  local help_col = layout.parent_col

  -- If the popup would overflow the editor below the form, flip it above.
  local outer_h = #lines + 2
  local max_row = vim.o.lines - outer_h - 2
  if help_row > max_row then
    local above = layout.parent_row - outer_h
    if above >= 0 then
      help_row = above
    else
      help_row = math.max(0, max_row)
    end
  end

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = help_row,
    col = help_col,
    width = content_w,
    height = #lines,
    style = "minimal",
    border = config.options.window.border,
    focusable = false,
    zindex = 60,
    title = " Help ",
    title_pos = "left",
  })
  vim.wo[win].winblend = config.options.window.winblend
  vim.wo[win].winhl = table.concat({
    "NormalFloat:InputFormNormal",
    "FloatBorder:InputFormBorder",
    "FloatTitle:InputFormTitle",
  }, ",")
  self._help_win = win
  self._help_buf = buf
end

--- Close the help popup. No-op if not open.
function M:_close_help()
  if self._help_win and vim.api.nvim_win_is_valid(self._help_win) then
    pcall(vim.api.nvim_win_close, self._help_win, true)
  end
  if self._help_buf and vim.api.nvim_buf_is_valid(self._help_buf) then
    pcall(vim.api.nvim_buf_delete, self._help_buf, { force = true })
  end
  self._help_win = nil
  self._help_buf = nil
end

--- Toggle the help popup.
function M:toggle_help()
  if self._help_win and vim.api.nvim_win_is_valid(self._help_win) then
    self:_close_help()
  else
    self:_open_help()
  end
end

--- Advance from `start` by `step` (+1 or -1), wrapping, until a focusable
--- input is found. Returns the new index, or `start` if no input is
--- focusable.
function M:_next_focusable(start, step)
  local n = #self._inputs
  if n == 0 then
    return start
  end
  local idx = ((start - 1) % n + n) % n + 1
  for _ = 1, n do
    if is_focusable(self._inputs[idx]) then
      return idx
    end
    idx = ((idx - 1 + step) % n + n) % n + 1
  end
  return start
end

function M:_focus(idx)
  local n = #self._inputs
  if n == 0 then
    return
  end
  idx = ((idx - 1) % n + n) % n + 1
  -- If the requested index isn't focusable, advance forward to the next one.
  if not is_focusable(self._inputs[idx]) then
    idx = self:_next_focusable(idx, 1)
  end
  local prev_idx = self._focus_idx
  local prev_input = self._inputs[prev_idx]
  local next_input = self._inputs[idx]

  if prev_idx ~= idx and prev_input and is_focusable(prev_input) then
    self:_on_field_blur(prev_input)
  end

  self._focus_idx = idx
  next_input:focus()

  if next_input then
    self:_on_field_focus(next_input)
  end
end

function M:_on_field_focus(input)
  self:_activate_field_keymaps(input)
  if input.complete and input.buf and vim.api.nvim_buf_is_valid(input.buf) then
    vim.b[input.buf].input_form_field = input.name
  end
  if input.on_focus then
    input.on_focus(self, input)
  end
end

function M:_on_field_blur(input)
  self:_deactivate_field_keymaps(input)
  if input.buf and vim.api.nvim_buf_is_valid(input.buf) then
    vim.b[input.buf].input_form_field = nil
  end
  if input.on_blur then
    input.on_blur(self, input)
  end
end

function M:_activate_field_keymaps(_input) end

function M:_deactivate_field_keymaps(_input) end

function M:_completion_segment(line, col, sep)
  local before = line:sub(1, col)
  local seg_start = 1
  local last_sep = before:reverse():find(vim.pesc(sep))
  if last_sep then
    seg_start = #before - last_sep + 2
  end
  local segment = before:sub(seg_start)
  local trimmed = segment:match("^%s*(.*)$") or segment
  local trim_offset = #segment - #trimmed
  local start_col = seg_start + trim_offset
  return trimmed, start_col
end

function M:_trigger_completion()
  local input = self._inputs[self._focus_idx]
  if not input or not input.complete then
    return
  end
  local buf = input.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local items
  if type(input.complete) == "function" then
    items = input.complete({
      value = input:value(),
      cursor = vim.api.nvim_win_get_cursor(0),
      field = input,
      form = self,
    })
  elseif type(input.complete) == "table" then
    items = input.complete
  end
  if not items or #items == 0 then
    return
  end

  local opts = input.complete_opts or {}
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local prefix, start_col
  if opts.separator then
    prefix, start_col = self:_completion_segment(line, col, opts.separator)
  else
    local before = line:sub(1, col)
    local word_start = before:match(".*%s()%S*$") or 1
    prefix = before:sub(word_start)
    start_col = word_start
  end

  local words = {}
  local prefix_lower = prefix:lower()
  for _, item in ipairs(items) do
    local word, abbr, info
    if type(item) == "string" then
      word = item
      abbr = item
    elseif type(item) == "table" then
      word = item.value or item.label
      abbr = item.label or word
      info = item.description
    end
    if word and (prefix_lower == "" or word:lower():sub(1, #prefix_lower) == prefix_lower) then
      local entry = { word = word, abbr = abbr }
      if info then
        entry.info = info
      end
      table.insert(words, entry)
    end
  end
  if #words == 0 then
    return
  end

  local mode = vim.api.nvim_get_mode().mode
  if mode ~= "i" and mode ~= "ic" then
    vim.cmd("startinsert")
  end
  vim.fn.complete(start_col, words)
end

function M:_install_auto_complete(input)
  local opts = input.complete_opts
  if not (input.complete and opts and opts.auto) then
    return
  end
  local buf = input.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local form = self
  local min_chars = opts.min_chars or 1
  local debounce_ms = opts.debounce_ms or 150
  local timer = nil
  local group = vim.api.nvim_create_augroup("InputFormComplete_" .. tostring(buf), { clear = true })
  vim.api.nvim_create_autocmd("TextChangedI", {
    group = group,
    buffer = buf,
    callback = function()
      if timer then
        timer:stop()
        timer:close()
        timer = nil
      end
      local line = vim.api.nvim_get_current_line()
      local col = vim.api.nvim_win_get_cursor(0)[2]
      local before = line:sub(1, col)
      local check_text = before
      if opts.separator then
        local segment = form:_completion_segment(line, col, opts.separator)
        check_text = segment
      end
      if #check_text < min_chars then
        return
      end
      if debounce_ms > 0 then
        timer = vim.uv.new_timer()
        timer:start(debounce_ms, 0, vim.schedule_wrap(function()
          if timer then
            timer:stop()
            timer:close()
            timer = nil
          end
          if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_get_mode().mode == "i" then
            form:_trigger_completion()
          end
        end))
      else
        form:_trigger_completion()
      end
    end,
  })
end

function M:focus_next()
  self:_focus(self:_next_focusable(self._focus_idx + 1, 1))
end

function M:focus_prev()
  self:_focus(self:_next_focusable(self._focus_idx - 1, -1))
end

function M:_install_keymaps(input)
  local km = config.options.keymaps
  local buf = input.buf
  if not buf then
    return
  end
  -- `lhs` may be a single key string or a list of keys. All listed keys
  -- are bound to the same callback.
  local function map(mode, lhs, fn)
    if not lhs or lhs == false or lhs == "" then
      return
    end
    local keys = type(lhs) == "table" and lhs or { lhs }
    for _, k in ipairs(keys) do
      if k and k ~= false and k ~= "" then
        vim.keymap.set(mode, k, fn, { buffer = buf, nowait = true, silent = true })
      end
    end
  end

  local modes = { "n", "i" }
  for _, mode in ipairs(modes) do
    map(mode, km.next, function()
      self:focus_next()
    end)
    -- Don't rebind <S-Tab> in insert for multiline to allow natural editing — still useful here.
    map(mode, km.prev, function()
      self:focus_prev()
    end)
    map(mode, km.submit, function()
      self:submit()
    end)
  end

  -- Cancel only in normal mode to avoid clobbering <Esc> used to leave insert mode.
  map("n", km.cancel, function()
    self:cancel()
  end)

  -- Help popup toggle (normal mode only so `?` stays usable inside text/
  -- multiline inputs during insert).
  map("n", km.help, function()
    self:toggle_help()
  end)

  if input.complete then
    local form = self
    map("i", km.complete, function()
      form:_trigger_completion()
    end)
    map("n", km.complete, function()
      form:_trigger_completion()
    end)
  end

  if input.type == "select" then
    if input.action then
      local form = self
      map("n", km.open_select, function()
        input.action(form, input)
      end)
    else
      map("n", km.open_select, function()
        input:open_dropdown()
      end)
    end
    -- Block insert mode on the select display buffer.
    vim.keymap.set("n", "i", "<Nop>", { buffer = buf, nowait = true, silent = true })
    vim.keymap.set("n", "a", "<Nop>", { buffer = buf, nowait = true, silent = true })
  elseif input.type == "checkbox" then
    -- Toggle on the configured toggle key AND on open_select so users who
    -- prefer <CR> for all interactions get a single key for every field.
    map("n", km.toggle, function()
      input:toggle()
    end)
    if km.open_select and km.open_select ~= km.toggle then
      if input.action then
        local form = self
        map("n", km.open_select, function()
          input.action(form, input)
        end)
      else
        map("n", km.open_select, function()
          input:toggle()
        end)
      end
    end
    -- Block insert mode on the checkbox display buffer.
    vim.keymap.set("n", "i", "<Nop>", { buffer = buf, nowait = true, silent = true })
    vim.keymap.set("n", "a", "<Nop>", { buffer = buf, nowait = true, silent = true })
  elseif input.type == "text" then
    if input.action then
      local form = self
      map("i", "<CR>", function()
        vim.cmd("stopinsert")
        input.action(form, input)
      end)
      map("n", "<CR>", function()
        input.action(form, input)
      end)
    else
      -- Single-line text inputs must never contain newlines. <CR> in insert
      -- mode just exits insert mode (accepting the value) rather than inserting
      -- a line break. Multiline inputs intentionally keep <CR> for newline entry.
      map("i", "<CR>", function()
        vim.cmd("stopinsert")
      end)
    end
  elseif input.type == "multiline" then
    if input.action then
      local form = self
      map("n", "<CR>", function()
        input.action(form, input)
      end)
    end
  end

  if input.field_keymaps then
    local form = self
    for lhs, fn in pairs(input.field_keymaps) do
      for _, mode in ipairs({ "n", "i" }) do
        vim.keymap.set(mode, lhs, function()
          fn(form, input)
        end, { buffer = buf, nowait = true, silent = true })
      end
    end
  end
end

return M
