# input-form.nvim Enhancement Refactor Concept

## Context

`input-form.nvim` is a Neovim plugin for building keyboard-navigable floating forms. It currently supports typed fields (text, multiline, select, checkbox, spacer), field validation, Tab/Shift-Tab navigation, and a `create_form` API that returns a form object with `show()`, `hide()`, `get_value()`, `set_value()`, and `render()` methods.

The library works well for basic data entry. This document proposes enhancements that make it suitable for richer use cases — forms where individual fields need custom keymaps, popup integrations, or completion support.

---

## Problem

The current API defines behavior at two levels:

1. **Global** — keymaps like `<Tab>`, `<C-s>`, `<Esc>` apply to the entire form.
2. **Per-type** — `select` fields get `<CR>` to open a dropdown, `checkbox` fields get `<Space>` to toggle.

There is no mechanism for **per-field** behavior. A form consumer cannot say:

> "When the user presses `<C-d>` while focused on the `due` field, open a date picker. But `<C-d>` should do nothing on other fields."

Today, the only way to achieve this is to manage focus tracking and keymaps outside of `input-form.nvim`, which defeats the purpose of having a form library.

The same limitation applies to:

- **Completion sources.** A consumer might want `blink.cmp` or `nvim-cmp` completion on a `tags` field but not on a `title` field.
- **Popup triggers.** A `blocked_by` field might need a floating picker to select from a list of items, distinct from the built-in `select` type.
- **Field-specific actions.** A `color` field might open a color picker. A `file` field might open a file browser.

These are all instances of the same missing primitive: **per-field extensibility**.

---

## Proposed Enhancements

### 1. Per-field keymaps

Allow each field spec to declare keymaps that are active only when that field is focused.

**API:**

```lua
{
  name = "due",
  label = "Due Date",
  type = "text",
  default = "",
  keymaps = {
    ["<C-d>"] = function(form, field)
      -- Open a date picker, then write back:
      -- form:set_value(field.name, selected_date)
      -- form:render()
    end,
    ["<C-t>"] = function(form, field)
      form:set_value(field.name, os.date("%Y-%m-%d"))
      form:render()
    end,
    ["<C-x>"] = function(form, field)
      form:set_value(field.name, "")
      form:render()
    end,
  },
}
```

**Behavior:**

- When the user navigates to the `due` field (via Tab or cursor movement), its keymaps become active.
- When the user leaves the field, those keymaps are torn down.
- Field keymaps take priority over global form keymaps on conflict.
- The callback receives two arguments: the `form` object and a `field` table describing the focused field (at minimum: `{ name = "due" }`).

**Implementation approach:**

Use buffer-local keymaps (`vim.keymap.set` with `{ buffer = bufnr }`) that are set on field focus and cleared on field blur. The form already tracks which field is focused for Tab navigation — hook into that focus tracking to manage keymap lifecycle.

Alternatively, register all field keymaps at form creation time but gate each callback with a focus check:

```lua
vim.keymap.set("n", "<C-d>", function()
  local focused = form:get_focused_field()
  if focused and focused.keymaps and focused.keymaps["<C-d>"] then
    focused.keymaps["<C-d>"](form, focused)
  end
end, { buffer = bufnr })
```

The second approach avoids keymap churn but requires a `get_focused_field()` method (see Enhancement 3).

---

### 2. Per-field actions

A higher-level alternative to keymaps for common patterns. Actions are named behaviors that the form can trigger via a standard keymap (e.g., `<CR>` or a configurable action key).

**API:**

```lua
{
  name = "blocked_by",
  label = "Blocked By",
  type = "text",
  action = function(form, field)
    -- Open a custom picker, then write back:
    -- form:set_value(field.name, selected_items)
    -- form:render()
  end,
}
```

**Behavior:**

- Pressing the action key (default `<CR>`, configurable via global keymaps) on a field with an `action` callback invokes it.
- For `select` fields, the built-in dropdown behavior is the implicit action. A custom `action` overrides it.
- For `text` and `multiline` fields, `<CR>` normally inserts a newline or does nothing. If an `action` is defined, it fires instead.
- The action callback receives the same `(form, field)` signature as keymap callbacks.

This is a convenience. Anything an action can do, a keymap can also do. But actions give consumers a single "activate this field" concept without choosing a specific key.

---

### 3. Focus tracking API

Expose which field is currently focused so consumers can build context-sensitive behavior outside the form spec.

**API:**

```lua
form:get_focused_field()
-- Returns: { name = "due", type = "text", ... } or nil
```

**Also add focus callbacks on the field spec:**

```lua
{
  name = "due",
  label = "Due Date",
  type = "text",
  on_focus = function(form, field)
    -- Field gained focus
  end,
  on_blur = function(form, field)
    -- Field lost focus
  end,
}
```

**Use cases:**

- Show contextual help text in a status line or floating window when a field gains focus.
- Enable/disable buffer-local completion sources based on focused field.
- Update external UI (e.g., a preview pane) when focus changes.

---

### 4. Per-field completion

Allow each field to provide its own completion items directly via a callback. The form library owns the completion trigger and popup — consumer plugins just supply the items.

This is the critical design decision: **completion lives in the form, not in an external engine.** A consumer plugin should be able to say "this field completes from these items" without configuring blink.cmp, nvim-cmp, or any other external completion plugin. The form handles the rest.

**API:**

```lua
{
  name = "tags",
  label = "Tags",
  type = "text",
  complete = function(context)
    -- context.value: current field value (string)
    -- context.cursor: cursor position within the field
    -- context.field: the field spec table
    -- context.form: the form object
    --
    -- Return a list of completion items.
    -- Each item is either a string or a table with label/value.
    return { "bug", "feature", "docs", "refactor", "test" }
  end,
}
```

**Item format:**

Items can be simple strings or structured tables:

```lua
-- Simple: label and inserted value are the same
return { "bug", "feature", "docs" }

-- Structured: label for display, value for insertion, optional description
return {
  { label = "bug", value = "bug", description = "Bug fix" },
  { label = "feat", value = "feature", description = "New feature" },
  { label = "docs", value = "docs" },
}
```

**Static shorthand:**

For fields with a fixed set of completions, allow a plain table instead of a function:

```lua
{
  name = "tags",
  label = "Tags",
  type = "text",
  complete = { "bug", "feature", "docs", "refactor", "test" },
}
```

When `complete` is a table, the form wraps it in a function internally. This covers the common case where completion items are known at form creation time.

**Trigger behavior:**

The form triggers completion in response to a configurable keymap (default `<C-Space>`). Add to the global keymaps config:

```lua
keymaps = {
  -- ... existing keymaps ...
  complete = "<C-Space>",   -- trigger completion on focused field
}
```

When the user presses the trigger key:

1. Check if the focused field has a `complete` property.
2. If not, do nothing.
3. If yes, call the function (or use the static list) to get items.
4. Filter items against the current field value (prefix matching).
5. Show a completion menu using `vim.fn.complete()` or a floating window.
6. On selection, insert the chosen value into the field and re-render.

**Auto-trigger (optional):**

Fields can opt into auto-triggering completion as the user types:

```lua
{
  name = "tags",
  label = "Tags",
  type = "text",
  complete = { "bug", "feature", "docs" },
  complete_opts = {
    auto = true,           -- trigger on typing (default: false)
    min_chars = 1,         -- minimum characters before auto-trigger
    debounce_ms = 150,     -- debounce delay for auto-trigger
  },
}
```

When `auto = false` (the default), completion only fires on the trigger key. This keeps the form responsive and predictable.

**Separator-aware completion:**

Many form fields contain comma-separated values (tags, contexts, etc.). The completion system should support a separator so it completes individual items within a list:

```lua
{
  name = "tags",
  label = "Tags",
  type = "text",
  complete = { "bug", "feature", "docs" },
  complete_opts = {
    separator = ",",  -- complete individual items in a CSV field
  },
}
```

When `separator` is set:

1. Split the field value by the separator.
2. Identify which segment the cursor is in.
3. Use that segment as the completion prefix.
4. On selection, replace only that segment (preserving the rest of the list).
5. Trim whitespace around the separator.

Example: field value is `"bug, fe|"` (cursor at `|`). The completion prefix is `"fe"`. Selecting `"feature"` produces `"bug, feature"`.

**Implementation approach:**

Use `vim.fn.complete()` for the completion popup. This is Neovim's built-in completion mechanism — it handles the floating menu, selection, scrolling, and insertion. No external plugin dependency.

```lua
-- Simplified internal flow
local function trigger_completion(form, field)
  local complete = field.complete
  if not complete then return end

  -- Resolve items
  local items
  if type(complete) == "function" then
    items = complete({
      value = form:get_value(field.name),
      cursor = vim.api.nvim_win_get_cursor(0),
      field = field,
      form = form,
    })
  elseif type(complete) == "table" then
    items = complete
  end

  if not items or #items == 0 then return end

  -- Normalize to strings for vim.fn.complete()
  local words = {}
  for _, item in ipairs(items) do
    if type(item) == "string" then
      table.insert(words, item)
    elseif type(item) == "table" then
      table.insert(words, {
        word = item.value or item.label,
        abbr = item.label,
        info = item.description,
      })
    end
  end

  -- Trigger Neovim's built-in completion
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  vim.fn.complete(col, words)
end
```

**External engine integration (optional, not required):**

For users who want blink.cmp or nvim-cmp to handle the popup instead of `vim.fn.complete()`, the form exposes enough state for external engines to hook in:

- `form:get_focused_field()` returns the field spec (including `complete` and `meta`).
- `vim.b.input_form_field` is set to the focused field name when the field has `complete` defined.
- External engines can check this buffer variable and call the field's `complete` function themselves.

This is an **opt-in optimization**, not the primary path. The default `vim.fn.complete()` path works without any external plugins.

---

### 5. Field metadata

Allow arbitrary metadata on field specs that passes through to callbacks. This lets consumers attach domain-specific information without polluting the field type system.

**API:**

```lua
{
  name = "due",
  label = "Due Date",
  type = "text",
  meta = {
    field_type = "date",
    format = "YYYY-MM-DD",
    picker = "datepicker",
  },
}
```

**Behavior:**

- `meta` is stored on the field and passed to all callbacks (`keymaps`, `action`, `on_focus`, `on_blur`, `validator`).
- `input-form.nvim` does not read or interpret `meta`. It is opaque to the library.
- Accessible via `form:get_focused_field().meta` or `field.meta` in callbacks.

This is the escape hatch. If a consumer needs to attach information that doesn't fit into the existing field properties, `meta` is the place. It keeps the core API surface small while supporting unforeseen use cases.

---

## Summary of New Field Spec Properties

```lua
{
  -- Existing properties (unchanged)
  name = "field_name",
  label = "Display Label",
  type = "text",
  default = "initial value",
  placeholder = "hint",
  options = { ... },          -- select type
  validator = function(value) end,
  height = 5,                 -- multiline type

  -- New properties
  keymaps = {                 -- per-field keymaps (active when focused)
    ["<C-d>"] = function(form, field) end,
  },
  action = function(form, field) end,  -- triggered by action key
  on_focus = function(form, field) end,
  on_blur = function(form, field) end,
  complete = function(context) end,    -- completion callback (or static table)
  complete_opts = {                    -- completion behavior options
    auto = false,                      -- auto-trigger on typing
    min_chars = 1,                     -- chars before auto-trigger
    debounce_ms = 150,                 -- auto-trigger debounce
    separator = nil,                   -- CSV-aware completion separator
  },
  meta = {},                  -- opaque consumer metadata
}
```

## Summary of New Form Methods

```lua
form:get_focused_field()  -- returns field table or nil
```

## Summary of New Global Keymaps

```lua
keymaps = {
  -- ... existing ...
  complete = "<C-Space>",    -- trigger completion on focused field
}
```

---

## Non-Goals

These are explicitly out of scope for this enhancement:

- **New field types.** The existing types (text, multiline, select, checkbox, spacer) are sufficient. Per-field keymaps and actions cover cases that would otherwise require custom types.
- **Built-in date picker.** Date picking is a consumer concern, not a form library concern. The form provides the keymap hook; the consumer provides the picker.
- **Custom completion UI.** The form uses `vim.fn.complete()` for completion popups. Building a custom floating completion menu is out of scope. External engines (blink.cmp, nvim-cmp) can optionally replace the popup by hooking into the form's focus tracking API.
- **Layout system.** Field arrangement remains vertical and sequential. Multi-column or grid layouts are a separate concern.
- **Theming per field.** Highlight customization remains global. Per-field highlight overrides add complexity without clear demand.

---

## Implementation Priority

Ordered by value and dependency:

### Tier 1 — Core (implement first)

1. **Per-field keymaps** — highest value, unblocks the most consumer use cases
2. **Focus tracking API** (`get_focused_field`) — required by keymap implementation and useful standalone

### Tier 2 — Completion + Convenience (implement second)

3. **Per-field completion** — high value for consumer plugins; uses `vim.fn.complete()` so no external deps needed
4. **Per-field actions** — simplifies common "activate this field" patterns
5. **Field metadata** (`meta`) — trivial to implement, useful immediately
6. **Focus callbacks** (`on_focus`, `on_blur`) — small addition, enables external UI sync and completion engine integration

---

## Acceptance Criteria

The enhancement is complete when:

```
Per-field keymaps:
  A text field with keymaps = { ["<C-d>"] = fn } calls fn only when that field is focused
  A text field with keymaps does not interfere with global form keymaps on non-conflicting keys
  Field keymaps override global keymaps on conflict (field wins)
  Field keymaps are inactive when a different field is focused

Focus tracking:
  form:get_focused_field() returns the correct field table
  form:get_focused_field() returns nil when no field is focused
  on_focus fires when Tab navigates to a field
  on_blur fires when Tab navigates away from a field

Actions:
  action callback fires on action key press when field is focused
  action callback does not fire on fields without an action defined

Completion:
  <C-Space> on a field with complete = { ... } opens a completion menu
  <C-Space> on a field without complete does nothing
  complete function receives context with value, cursor, field, form
  Static complete table (list of strings) works the same as a function
  Selecting a completion item inserts the value and re-renders the field
  separator option completes individual items within a CSV field
  auto = true triggers completion as the user types (after min_chars)
  auto = false (default) only triggers on the complete keymap
  vim.b.input_form_field is set when a completable field is focused

General:
  meta table is accessible in keymap, action, on_focus, on_blur, and complete callbacks
  Existing form behavior is unchanged when no new properties are used
  All existing tests pass
```

---

## Example: Date Field With Picker

This example shows how a consumer would use the enhanced API. The form library itself has no knowledge of dates or pickers.

```lua
local input_form = require("input-form")

local form = input_form.create_form({
  title = "New Event",
  inputs = {
    {
      name = "title",
      label = "Event Title",
      type = "text",
      validator = require("input-form").validators.non_empty(),
    },
    {
      name = "date",
      label = "Event Date",
      type = "text",
      default = "",
      placeholder = "YYYY-MM-DD",
      meta = { field_type = "date" },
      validator = function(value)
        if value == "" then return end
        if not value:match("^%d%d%d%d%-%d%d%-%d%d$") then
          return "Must be YYYY-MM-DD"
        end
      end,
      keymaps = {
        ["<C-d>"] = function(form, field)
          -- Consumer-provided date picker integration
          require("my-date-picker").open({
            initial = form:get_value(field.name),
            on_select = function(date)
              form:set_value(field.name, date)
              form:render()
            end,
          })
        end,
        ["<C-t>"] = function(form, field)
          form:set_value(field.name, os.date("%Y-%m-%d"))
          form:render()
        end,
      },
    },
    {
      name = "tags",
      label = "Tags",
      type = "text",
      complete = { "bug", "feature", "docs", "refactor", "test" },
      complete_opts = { separator = ",", auto = true, min_chars = 1 },
    },
    {
      name = "notes",
      label = "Notes",
      type = "multiline",
      height = 8,
    },
  },
  on_submit = function(results)
    vim.print(results)
  end,
})

form:show()
```

## Example: Field With Custom Popup Action

```lua
{
  name = "assignee",
  label = "Assignee",
  type = "text",
  action = function(form, field)
    -- Open a user picker (Telescope, fzf-lua, Snacks, etc.)
    vim.ui.select({ "Alice", "Bob", "Charlie" }, {
      prompt = "Select assignee:",
    }, function(choice)
      if choice then
        form:set_value(field.name, choice)
        form:render()
      end
    end)
  end,
}
```

## Example: Per-Field Completion (Static List)

A tag field that auto-completes from a known set, with CSV-aware insertion:

```lua
{
  name = "labels",
  label = "Labels",
  type = "text",
  complete = { "bug", "feature", "docs", "refactor", "test", "ci", "deps" },
  complete_opts = {
    separator = ",",     -- complete individual items in CSV
    auto = true,         -- trigger as user types
    min_chars = 1,       -- start after 1 character
  },
}
```

Typing `"bug, fe"` and pressing `<C-Space>` (or auto-triggered) shows `"feature"`. Selecting it produces `"bug, feature"`.

## Example: Per-Field Completion (Dynamic)

A field that fetches completion items from an external source:

```lua
{
  name = "assignee",
  label = "Assignee",
  type = "text",
  complete = function(context)
    -- Fetch from an external source (API, database, file, etc.)
    local users = my_api.get_team_members()

    -- Return structured items with descriptions
    return vim.tbl_map(function(user)
      return {
        label = user.name,
        value = user.handle,
        description = user.role,
      }
    end, users)
  end,
}
```

## Example: Focus-Aware Help Text

```lua
{
  name = "priority",
  label = "Priority",
  type = "select",
  options = {
    { id = "low", label = "Low" },
    { id = "normal", label = "Normal" },
    { id = "high", label = "High" },
  },
  on_focus = function(form, field)
    vim.api.nvim_echo({{ "Priority affects task ordering. High = appears first.", "Comment" }}, false, {})
  end,
  on_blur = function(form, field)
    vim.api.nvim_echo({{ "", "" }}, false, {})
  end,
}
```
