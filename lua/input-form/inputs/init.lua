--- Input type registry and factory.

local M = {}

M.types = {
  text = require("input-form.inputs.text"),
  multiline = require("input-form.inputs.multiline"),
  select = require("input-form.inputs.select"),
  checkbox = require("input-form.inputs.checkbox"),
  spacer = require("input-form.inputs.spacer"),
}

--- Build an input component instance from a user-provided spec.
---@param spec table
---@return table
function M.build(spec)
  assert(type(spec) == "table", "input spec must be a table")
  local t = spec.type or "text"
  -- Spacers are a visual-only faux input and don't require a `name`.
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
  input.field_keymaps = spec.keymaps
  input.action = spec.action
  input.on_focus = spec.on_focus
  input.on_blur = spec.on_blur
  input.complete = spec.complete
  input.complete_opts = spec.complete_opts
  input.meta = spec.meta
  return input
end

return M
