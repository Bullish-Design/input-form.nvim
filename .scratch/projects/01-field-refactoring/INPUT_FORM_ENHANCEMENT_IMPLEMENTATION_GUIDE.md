# input-form.nvim Enhancement Implementation Guide

This guide provides step-by-step implementation instructions for every enhancement described in the concept document. Each step references exact file paths, line numbers, function names, and data structures from the current codebase.

---

## Prerequisites

Before starting, understand these core mechanics:

- **Form state lives in `form.lua`**: The form object (`M`) tracks `_inputs` (list of input objects), `_focus_idx` (currently focused input index), and `_visible`/`_closed` lifecycle flags.
- **Each input is a separate buffer/window**: Created in `show()` (form.lua:207–231), mounted via `input:mount(opts)`, each gets its own `buf` and `win`.
- **Keymaps are buffer-local**: Installed per-input buffer in `_install_keymaps()` (form.lua:757–831) using `vim.keymap.set` with `{ buffer = buf }`.
- **Focus is index-based**: `_focus_idx` is an integer index into `_inputs`. Navigation uses `_next_focusable()` (form.lua:720–733) which skips spacers and non-focusable inputs. The `_focus()` method (form.lua:735–747) updates `_focus_idx` and calls `input:focus()`.
- **No focus change callback exists yet**: `_focus()` simply sets the index and calls `input:focus()`. There is no notification when focus changes.
- **Inputs store their own spec partially**: The factory (`inputs/init.lua:16–33`) calls `impl.new(spec)` which copies only the properties each type knows about. Unknown spec properties (like `keymaps`, `action`, `meta`, etc.) are **not** preserved on the input object.

---

## Tier 1: Core

### Step 1: Preserve New Spec Properties on Input Objects

**Why first**: Every subsequent enhancement depends on field-level properties (`keymaps`, `action`, `on_focus`, `on_blur`, `complete`, `complete_opts`, `meta`) being accessible on the input object. Currently the input factory discards unknown properties.

**File**: `lua/input-form/inputs/init.lua`

**Current code** (lines 16–33):
```lua
function M.build(spec)
  assert(type(spec) == "table", "input spec must be a table")
  local t = spec.type or "text"
  if t ~= "spacer" then
    assert(
      type(spec.name) == "string" and spec.name ~= "",
      "input spec requires a non-empty 'name'"
    )
  end
  local impl = M.types[t]
  assert(impl, "unknown input type: " .. tostring(t))
  local input = impl.new(spec)
  input.validator = spec.validator
  input._touched = false
  input._error = nil
  return input
end
```

**Changes**: After the existing `input.validator = spec.validator` line, copy the new spec properties onto the input object:

```lua
  local input = impl.new(spec)
  input.validator = spec.validator
  input._touched = false
  input._error = nil

  -- Enhancement: preserve per-field extensibility properties
  input.field_keymaps = spec.keymaps     -- per-field keymaps (table of lhs → fn)
  input.action = spec.action             -- per-field action callback
  input.on_focus = spec.on_focus         -- focus gained callback
  input.on_blur = spec.on_blur           -- focus lost callback
  input.complete = spec.complete         -- completion source (fn or table)
  input.complete_opts = spec.complete_opts -- completion options
  input.meta = spec.meta                 -- opaque consumer metadata

  return input
```

**Notes**:
- Use `field_keymaps` instead of `keymaps` to avoid collision with any internal keymap state.
- All properties are optional — `nil` by default — so existing forms are unaffected.

---

### Step 2: Implement `get_focused_field()`

**Why**: Required by per-field keymaps (gated dispatch approach), per-field actions, and useful standalone for consumers.

**File**: `lua/input-form/form.lua`

**Location**: Add after the `results()` method (after line 302).

**Implementation**:

```lua
--- Return the currently focused input's public field descriptor, or `nil` if
--- no input is focused or the form is not visible.
---@return table|nil  { name, type, label, meta, ... }
function M:get_focused_field()
  if not self._visible then
    return nil
  end
  local input = self._inputs[self._focus_idx]
  if not input or not is_focusable(input) then
    return nil
  end
  -- Return the input object directly. Consumers access `.name`, `.type`,
  -- `.label`, `.meta`, `.field_keymaps`, `.action`, `.complete`, etc.
  return input
end
```

**Design decision**: Return the input object itself rather than a copy. This keeps it simple and allows callbacks to read any property. The concept doc's `{ name, type, ... }` is satisfied because every input object already has `name`, `type`, and `label` fields.

**Public API addition**: Also expose this in `lua/input-form/init.lua` if desired, but since consumers interact with the form instance (returned by `create_form`), it's already accessible as `form:get_focused_field()`.

---

### Step 3: Add Focus Change Notifications (on_focus / on_blur)

**Why**: Enables per-field keymaps lifecycle (set/clear on focus change), focus callbacks, and completion state management.

**File**: `lua/input-form/form.lua`

**Current `_focus()` method** (lines 735–747):
```lua
function M:_focus(idx)
  local n = #self._inputs
  if n == 0 then
    return
  end
  idx = ((idx - 1) % n + n) % n + 1
  if not is_focusable(self._inputs[idx]) then
    idx = self:_next_focusable(idx, 1)
  end
  self._focus_idx = idx
  self._inputs[idx]:focus()
end
```

**New implementation**:

```lua
function M:_focus(idx)
  local n = #self._inputs
  if n == 0 then
    return
  end
  idx = ((idx - 1) % n + n) % n + 1
  if not is_focusable(self._inputs[idx]) then
    idx = self:_next_focusable(idx, 1)
  end

  local prev_idx = self._focus_idx
  local prev_input = self._inputs[prev_idx]
  local next_input = self._inputs[idx]

  -- Fire on_blur for the previous field (if different and valid)
  if prev_idx ~= idx and prev_input and is_focusable(prev_input) then
    self:_on_field_blur(prev_input)
  end

  self._focus_idx = idx
  next_input:focus()

  -- Fire on_focus for the new field
  if next_input then
    self:_on_field_focus(next_input)
  end
end
```

**Add the blur/focus dispatch methods** (nearby, after `_focus`):

```lua
--- Called when a field gains focus. Fires the field's on_focus callback,
--- activates per-field keymaps, and sets completion state.
function M:_on_field_focus(input)
  -- Per-field keymaps: activate
  self:_activate_field_keymaps(input)

  -- Completion state: set buffer variable for external engines
  if input.complete and input.buf and vim.api.nvim_buf_is_valid(input.buf) then
    vim.b[input.buf].input_form_field = input.name
  end

  -- User callback
  if input.on_focus then
    input.on_focus(self, input)
  end
end

--- Called when a field loses focus. Fires the field's on_blur callback,
--- deactivates per-field keymaps, and clears completion state.
function M:_on_field_blur(input)
  -- Per-field keymaps: deactivate
  self:_deactivate_field_keymaps(input)

  -- Completion state: clear buffer variable
  if input.buf and vim.api.nvim_buf_is_valid(input.buf) then
    vim.b[input.buf].input_form_field = nil
  end

  -- User callback
  if input.on_blur then
    input.on_blur(self, input)
  end
end
```

**Initial focus on show()**: The initial `_focus()` call at line 233 will fire `on_focus` for the first field. Since `prev_idx` equals `_focus_idx` (both 1 initially), the blur guard `prev_idx ~= idx` prevents a spurious blur on the same field.

**Edge case — single focusable field**: When `prev_idx == idx`, no blur fires, only focus. This is correct.

**Edge case — re-show after hide**: Focus callbacks fire again on re-show since `_focus()` is called from `show()`. This is desirable — it lets consumers re-establish state.

---

### Step 4: Implement Per-Field Keymaps

**Why**: The highest-value enhancement. Enables field-specific behavior like date pickers, file browsers, custom popups.

**File**: `lua/input-form/form.lua`

**Approach**: Use the **gated dispatch** pattern from the concept doc. Register all per-field keymaps at form creation time on every input buffer, but gate each callback with a focus check. This avoids keymap churn (set/delete on every focus change) which can conflict with Neovim's keymap deletion timing.

**However**, there's a subtlety: keymaps are buffer-local, and each input has its own buffer. A keymap registered on the `due` field's buffer is only active when that buffer's window is focused. Since `input:focus()` calls `vim.api.nvim_set_current_win(self.win)`, the user is always in the focused field's buffer. This means **buffer-local keymaps on each input's buffer are inherently focus-gated** — no need for explicit focus checks or keymap activation/deactivation.

**Revised approach**: Register per-field keymaps once during `_install_keymaps()`. Since they're buffer-local and each field is a separate buffer, they only fire when that field is focused. This is simpler and more robust.

**Modify `_install_keymaps()`** (form.lua:757–831):

Add the following block at the end of the function, before the final `end`:

```lua
  -- Per-field keymaps: registered on this input's buffer, so they are
  -- inherently active only when this field is focused (since each field
  -- is its own buffer/window).
  if input.field_keymaps then
    local form = self
    for lhs, fn in pairs(input.field_keymaps) do
      -- Register in both normal and insert modes so the keymap works
      -- regardless of current mode.
      for _, mode in ipairs({ "n", "i" }) do
        vim.keymap.set(mode, lhs, function()
          fn(form, input)
        end, { buffer = buf, nowait = true, silent = true })
      end
    end
  end
```

**Key behavior**:
- Field keymaps **automatically override** global form keymaps on the same buffer because `vim.keymap.set` with `{ buffer = buf }` replaces any existing buffer-local mapping for the same lhs+mode.
- Since per-field keymaps are installed **after** global keymaps (same function, later in execution), they win on conflict.
- Field keymaps are inactive on other fields because they're only registered on this field's buffer.

**Wait — ordering concern**: Global keymaps are installed first (lines 777–800), then type-specific keymaps (lines 802–830). Per-field keymaps should be installed last so they take highest priority. Append the block above **after** the type-specific section (after line 830, before the closing `end`).

**Simplification**: With this approach, `_activate_field_keymaps` and `_deactivate_field_keymaps` from Step 3 become **no-ops** (stubs). They can be left as empty functions for now, or removed if we decide the gated approach isn't needed. Keep them as stubs for forward compatibility:

```lua
function M:_activate_field_keymaps(_input)
  -- No-op: per-field keymaps are buffer-local and inherently focus-gated.
end

function M:_deactivate_field_keymaps(_input)
  -- No-op: per-field keymaps are buffer-local and inherently focus-gated.
end
```

**Help popup integration**: Per-field keymaps should optionally appear in the help popup when the field is focused. This is a nice-to-have and can be deferred. For now, the help popup shows only global keymaps.

---

### Step 5: Implement Per-Field Actions

**Why**: Provides a standard "activate this field" concept without requiring consumers to choose a specific key.

**File**: `lua/input-form/form.lua`

**Approach**: In `_install_keymaps()`, when a field has an `action` property, bind the action key (default `<CR>`) to fire that callback. This must integrate with existing type-specific `<CR>` behavior:

- **Text fields**: `<CR>` in insert mode currently does `stopinsert` (form.lua:827–829). If an action is defined, it should fire instead.
- **Select fields**: `<CR>` in normal mode opens the dropdown (form.lua:803–805). If an action is defined, it should override the dropdown.
- **Checkbox fields**: No `<CR>` conflict (toggle is `<Space>`).
- **Multiline fields**: `<CR>` inserts a newline. If an action is defined, it should fire in **normal mode** only (preserve newline insertion in insert mode).

**Modify `_install_keymaps()`**: Add action handling in the type-specific section.

Replace the type-specific block (form.lua:802–830) with:

```lua
  if input.type == "select" then
    if input.action then
      -- Custom action overrides the built-in dropdown
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
      -- Action fires on <CR> in both modes instead of stopinsert
      local form = self
      map("i", "<CR>", function()
        vim.cmd("stopinsert")
        input.action(form, input)
      end)
      map("n", "<CR>", function()
        input.action(form, input)
      end)
    else
      map("i", "<CR>", function()
        vim.cmd("stopinsert")
      end)
    end
  elseif input.type == "multiline" then
    if input.action then
      -- Action fires on <CR> in normal mode only; insert mode keeps newline
      local form = self
      map("n", "<CR>", function()
        input.action(form, input)
      end)
    end
  end
```

**Note**: For text fields with an action, `<CR>` in insert mode does `stopinsert` first, then fires the action. This ensures the user is in normal mode when the action callback runs (which may open pickers, etc.).

---

### Step 6: Implement Field Metadata (`meta`)

**Why**: Trivial to implement and immediately useful for consumers.

**Already done**: Step 1 preserves `spec.meta` on the input object as `input.meta`. No further implementation is needed.

**Verification**: Confirm that `meta` is accessible in all callback signatures:
- `keymaps[lhs](form, field)` → `field.meta` ✓ (field is the input object)
- `action(form, field)` → `field.meta` ✓
- `on_focus(form, field)` → `field.meta` ✓
- `on_blur(form, field)` → `field.meta` ✓
- `complete(context)` → `context.field.meta` ✓ (implemented in Step 7)
- `validator(value)` → Does NOT receive the field object. This is an existing limitation. The concept doc lists `meta` as accessible in validators, but changing the validator signature would break existing code. Leave validators as-is; consumers can close over `meta` in the validator function if needed.

---

## Tier 2: Completion + Convenience

### Step 7: Add `complete` Keymap to Config Defaults

**File**: `lua/input-form/config.lua`

**Add to `keymaps`** (after line 49, before the closing `}`):

```lua
    --- Trigger per-field completion when the focused field has a `complete`
    --- property. Does nothing on fields without completion.
    complete = "<C-Space>",
```

This makes `<C-Space>` the default trigger. Users can override it via `setup()`.

---

### Step 8: Implement Per-Field Completion

**File**: `lua/input-form/form.lua`

This is the most complex enhancement. Break it into sub-steps.

#### Step 8a: Add `_trigger_completion()` Method

Add after the `_on_field_blur` method:

```lua
--- Trigger completion on the currently focused field. No-op if the field
--- has no `complete` property or yields no items.
function M:_trigger_completion()
  local input = self._inputs[self._focus_idx]
  if not input or not input.complete then
    return
  end
  local buf = input.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  -- Resolve completion items
  local complete = input.complete
  local items
  if type(complete) == "function" then
    items = complete({
      value = input:value(),
      cursor = vim.api.nvim_win_get_cursor(0),
      field = input,
      form = self,
    })
  elseif type(complete) == "table" then
    items = complete
  end

  if not items or #items == 0 then
    return
  end

  -- Determine the completion prefix for filtering and column positioning
  local opts = input.complete_opts or {}
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]  -- 0-indexed byte column
  local prefix, start_col

  if opts.separator then
    -- Separator-aware: find the segment the cursor is in
    prefix, start_col = self:_completion_segment(line, col, opts.separator)
  else
    -- Simple: use text from start of line to cursor
    local before = line:sub(1, col)
    -- Find the start of the current word (last whitespace boundary)
    local word_start = before:match(".*%s()%S*$") or 1
    prefix = before:sub(word_start)
    start_col = word_start  -- 1-indexed
  end

  -- Normalize items to vim.fn.complete() format and filter by prefix
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
    -- Prefix filter (case-insensitive)
    if prefix_lower == "" or word:lower():sub(1, #prefix_lower) == prefix_lower then
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

  -- Trigger Neovim's built-in completion. vim.fn.complete() requires
  -- insert mode, so enter it first if needed.
  local mode = vim.api.nvim_get_mode().mode
  if mode ~= "i" and mode ~= "ic" then
    vim.cmd("startinsert")
    -- Recompute column after entering insert mode
    col = vim.api.nvim_win_get_cursor(0)[2]
  end

  vim.fn.complete(start_col, words)
end

--- Given a line, cursor column (0-indexed byte), and separator character,
--- find the segment the cursor is in. Returns (prefix, start_col) where
--- prefix is the trimmed text of the current segment up to the cursor,
--- and start_col is the 1-indexed byte column where the segment begins
--- (for vim.fn.complete()).
function M:_completion_segment(line, col, sep)
  local before = line:sub(1, col)
  -- Find the last separator before the cursor
  local seg_start = 1
  local last_sep = before:reverse():find(vim.pesc(sep))
  if last_sep then
    seg_start = #before - last_sep + 2  -- byte after the separator
  end
  -- Trim leading whitespace from the segment
  local segment = before:sub(seg_start)
  local trimmed = segment:match("^%s*(.*)$") or segment
  local trim_offset = #segment - #trimmed
  local start_col = seg_start + trim_offset  -- 1-indexed

  return trimmed, start_col
end
```

#### Step 8b: Bind the Complete Keymap

**File**: `lua/input-form/form.lua`, inside `_install_keymaps()`.

Add to the global keymaps section (after the help keymap block, around line 800):

```lua
  -- Completion trigger — only useful on fields that define `complete`.
  if input.complete then
    local form = self
    map("i", km.complete, function()
      form:_trigger_completion()
    end)
    map("n", km.complete, function()
      form:_trigger_completion()
    end)
  end
```

#### Step 8c: Implement Auto-Trigger Completion

For fields with `complete_opts.auto = true`, completion triggers automatically as the user types.

**File**: `lua/input-form/form.lua`

**Add a new method for installing auto-completion**:

```lua
--- Set up auto-trigger completion for an input that has complete_opts.auto = true.
--- Creates a TextChangedI autocmd with optional debouncing.
function M:_install_auto_complete(input)
  local opts = input.complete_opts
  if not opts or not opts.auto then
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
      -- Cancel any pending debounced trigger
      if timer then
        timer:stop()
        timer = nil
      end

      -- Check minimum character count
      local line = vim.api.nvim_get_current_line()
      local col = vim.api.nvim_win_get_cursor(0)[2]
      local before = line:sub(1, col)

      -- For separator-aware completion, check the current segment length
      local check_text = before
      if opts.separator then
        local seg = form:_completion_segment(line, col, opts.separator)
        check_text = seg
      end

      if #check_text < min_chars then
        return
      end

      -- Debounce the completion trigger
      if debounce_ms > 0 then
        timer = vim.uv.new_timer()
        timer:start(debounce_ms, 0, vim.schedule_wrap(function()
          timer = nil
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
```

**Call it from `show()`**: In the input mounting loop (form.lua:207–231), after `_install_validation(input)`, add:

```lua
    self:_install_auto_complete(input)
```

So the loop body becomes:

```lua
    input:mount(mount_opts)
    self:_install_keymaps(input)
    self:_install_validation(input)
    self:_install_auto_complete(input)
```

#### Step 8d: Handle Completion Item Insertion with Separator

When using `vim.fn.complete()`, Neovim handles insertion automatically — it replaces text from the `start_col` position with the selected word. The `start_col` computation in `_trigger_completion()` already accounts for separators, so separator-aware insertion works out of the box.

**One detail**: After a separator-aware completion, the user may want an automatic separator + space appended. This is a UX decision. For the initial implementation, **do not auto-append separators**. The user types the separator themselves. This is simpler and matches how most completion systems work.

#### Step 8e: Completion on Select/Checkbox Fields

Completion doesn't make sense on `select` or `checkbox` fields (they're read-only). The keymap binding in Step 8b already gates on `input.complete`, so if a consumer doesn't set `complete` on a select field, no completion keymap is registered. If they do set it (unusual but possible), it will attempt to complete in the display buffer. Since select buffers are non-modifiable, `vim.fn.complete()` will be a no-op. This is acceptable behavior.

---

### Step 9: Update Help Popup to Show Per-Field Keymaps

**File**: `lua/input-form/form.lua`

**Modify `_help_entries()`** (form.lua:512–549) to include per-field keymaps for the currently focused field:

After the existing entries (before `return entries`), add:

```lua
  -- Per-field keymaps for the currently focused input.
  local focused = self._inputs[self._focus_idx]
  if focused and focused.field_keymaps then
    for lhs, _ in pairs(focused.field_keymaps) do
      table.insert(entries, { lhs, focused.name .. " action" })
    end
  end

  -- Show complete keymap if focused field has completion
  if focused and focused.complete then
    add(km.complete, "complete")
  end
```

**Note**: The help popup is non-focused (`focusable = false`) so it doesn't interfere with field keymaps. However, since it's built once when opened, it won't update as the user navigates between fields. For a future enhancement, the help popup could auto-refresh on focus change, but this is out of scope for the initial implementation.

---

### Step 10: Set `vim.b.input_form_field` for External Engine Integration

**Already done in Step 3**: The `_on_field_focus` and `_on_field_blur` methods set and clear `vim.b[input.buf].input_form_field` when the field has a `complete` property.

**Note on buffer variable scope**: `vim.b` is buffer-local. Since each field is its own buffer, the variable is set on the correct buffer. External engines (blink.cmp, nvim-cmp) can check `vim.b.input_form_field` in the current buffer to determine if they should provide completions for this field, and use the form's focus API to get the completion source.

---

## File Change Summary

### `lua/input-form/inputs/init.lua`
- **Modify `build()`**: Copy `keymaps`, `action`, `on_focus`, `on_blur`, `complete`, `complete_opts`, `meta` from spec to input object.

### `lua/input-form/config.lua`
- **Add `complete` keymap**: `complete = "<C-Space>"` in `keymaps` defaults.

### `lua/input-form/form.lua`
- **Add `get_focused_field()`**: New public method returning the focused input object.
- **Modify `_focus()`**: Add blur/focus lifecycle notifications.
- **Add `_on_field_focus()`**: Fires focus callback, sets completion buffer variable.
- **Add `_on_field_blur()`**: Fires blur callback, clears completion buffer variable.
- **Add `_activate_field_keymaps()`**: No-op stub (keymaps are inherently buffer-gated).
- **Add `_deactivate_field_keymaps()`**: No-op stub.
- **Modify `_install_keymaps()`**: Add per-field keymaps block. Refactor type-specific section for action support. Add completion keymap binding.
- **Add `_trigger_completion()`**: Core completion logic using `vim.fn.complete()`.
- **Add `_completion_segment()`**: Helper for separator-aware completion prefix extraction.
- **Add `_install_auto_complete()`**: Auto-trigger completion via TextChangedI autocmd with debouncing.
- **Modify `show()`**: Call `_install_auto_complete()` after validation setup.
- **Modify `_help_entries()`**: Include per-field keymaps and completion keymap.

### No changes required:
- `lua/input-form/init.lua` — `create_form` already delegates to `Form.new`, which will inherit all changes.
- `lua/input-form/inputs/text.lua` — No changes needed.
- `lua/input-form/inputs/multiline.lua` — No changes needed.
- `lua/input-form/inputs/select.lua` — No changes needed.
- `lua/input-form/inputs/checkbox.lua` — No changes needed.
- `lua/input-form/inputs/spacer.lua` — No changes needed.
- `lua/input-form/utils.lua` — No changes needed.
- `lua/input-form/validators.lua` — No changes needed.

---

## Testing Plan

### Test File: `tests/test_field_enhancements.lua`

Tests should use the existing MiniTest infrastructure in `tests/helpers.lua`.

#### Per-Field Keymaps

1. **Keymap fires on correct field**: Create a form with two text fields. Field A has `keymaps = { ["<C-d>"] = fn }`. Focus field A, press `<C-d>` → fn fires. Focus field B, press `<C-d>` → nothing happens (no mapping on field B's buffer).

2. **Field keymap overrides global keymap**: Create a form with a text field that has `keymaps = { ["<Tab>"] = fn }`. Focus that field, press `<Tab>` → fn fires (not focus_next). Focus a different field, press `<Tab>` → focus_next fires normally.

3. **Multiple keymaps on one field**: Field with `keymaps = { ["<C-d>"] = fn1, ["<C-t>"] = fn2 }`. Both fire correctly when focused.

#### Focus Tracking

4. **`get_focused_field()` returns correct field**: Create form, show it. `form:get_focused_field().name` equals the first focusable field's name. Tab to next field → returns that field's name.

5. **`get_focused_field()` returns nil when not visible**: Hide form → returns nil.

6. **`on_focus` fires on navigation**: Field with `on_focus = fn`. Show form (fn fires for initial focus). Tab away, tab back → fn fires again.

7. **`on_blur` fires on navigation**: Field with `on_blur = fn`. Show form, tab to next field → fn fires for the first field.

8. **`on_blur` does not fire on initial focus**: On `show()`, the first field gets `on_focus` but no field gets `on_blur` (nothing was previously focused).

#### Actions

9. **Action fires on action key**: Text field with `action = fn`. Focus it, press `<CR>` → fn fires.

10. **Action overrides select dropdown**: Select field with `action = fn`. Focus it, press `<CR>` → fn fires (dropdown does NOT open).

11. **No action = default behavior**: Text field without action. `<CR>` in insert mode does `stopinsert`. Select field without action: `<CR>` opens dropdown.

#### Completion

12. **Static completion list**: Field with `complete = { "a", "b", "c" }`. Focus it, press `<C-Space>` → completion popup appears.

13. **Dynamic completion function**: Field with `complete = function(ctx) ... end`. Context table has `value`, `cursor`, `field`, `form`.

14. **No completion = no-op**: Field without `complete`. Press `<C-Space>` → nothing happens.

15. **Prefix filtering**: Field value is "fe", press `<C-Space>` with items `{ "foo", "feature", "bar" }` → only "feature" shown.

16. **Separator-aware completion**: Field value is `"bug, fe"`, separator is `","`. Completion prefix is `"fe"`. Items filtered against `"fe"`.

17. **Auto-trigger**: Field with `complete_opts = { auto = true, min_chars = 2 }`. Type 1 char → no completion. Type 2 chars → completion triggers after debounce.

#### Metadata

18. **Meta accessible in callbacks**: Field with `meta = { x = 1 }`. Keymap callback receives `field.meta.x == 1`. Action callback same. Focus callback same.

#### Backwards Compatibility

19. **Existing forms unchanged**: A form spec with no new properties behaves identically to before. All existing tests pass.

---

## Implementation Order (Recommended)

Execute the steps in this exact order to minimize risk and enable incremental testing:

1. **Step 1** — Preserve spec properties (inputs/init.lua). Run existing tests to confirm no regression.
2. **Step 2** — `get_focused_field()`. Write test #4, #5.
3. **Step 3** — Focus change notifications. Write tests #6, #7, #8.
4. **Step 4** — Per-field keymaps. Write tests #1, #2, #3.
5. **Step 5** — Per-field actions. Write tests #9, #10, #11.
6. **Step 6** — Metadata (already done in Step 1). Write test #18.
7. **Step 7** — Complete keymap in config.
8. **Step 8a–8b** — Basic completion. Write tests #12, #13, #14, #15.
9. **Step 8c** — Auto-trigger completion. Write test #17.
10. **Step 8d–8e** — Separator completion. Write test #16.
11. **Step 9** — Help popup update.
12. **Step 10** — Already done in Step 3.
13. **Test #19** — Run full existing test suite to confirm backwards compatibility.

---

## Edge Cases and Gotchas

### Keymap Conflicts
- Per-field keymaps installed **after** global keymaps in `_install_keymaps()`, so they win on conflict.
- If two enhancement features bind the same key (e.g., `<CR>` for both action and completion), action takes priority since it's registered in the type-specific block and completion is registered separately.

### Form Re-Show
- `hide()` unmounts all inputs (destroys buffers/windows). `show()` recreates everything from scratch. Per-field keymaps, actions, and completion are re-installed on each `show()`. Focus callbacks fire again.

### Select Dropdown Interaction
- When a select dropdown is open, the user is in the dropdown buffer, not the select field's buffer. Per-field keymaps on the select field won't fire while the dropdown is open. This is correct behavior.

### Completion in Read-Only Fields
- `vim.fn.complete()` requires an editable buffer. Select and checkbox buffers are non-modifiable. If a consumer sets `complete` on a select field, the completion call will fail silently. This is acceptable.

### Timer Cleanup
- Auto-completion timers (Step 8c) are created per-buffer via autocmds in an augroup. When the buffer is wiped (on `hide()`), the augroup's autocmds are automatically cleaned up. The `vim.uv.timer` may fire after buffer destruction — the callback guards against this with `vim.api.nvim_buf_is_valid(buf)`.

### Mode Transitions
- `_trigger_completion()` enters insert mode if not already in it (required by `vim.fn.complete()`). This means pressing the completion trigger in normal mode will switch to insert mode. This matches standard Vim completion behavior (`<C-x><C-o>` etc.).
