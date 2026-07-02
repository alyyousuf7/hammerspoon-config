-- Runtime enable/disable for layout management (config/layouts + composer +
-- minimize_layout). Flips a persisted setting and reloads, so those modules are
-- genuinely loaded/unloaded — see init.lua, which reads the setting to decide
-- whether to require them. This tears down their hotkeys, watchers, taps and the
-- composer's auto-snap window filter as a group, with no per-object bookkeeping.
--
-- The window-management snap shortcuts (config/window_management) are NOT part
-- of this toggle — they stay live whether layout management is on or off.

-- Modifier matches the layout-management bindings (⌃⌥⌘). Esc is otherwise unused
-- with this modifier (macOS's Force Quit is ⌘⌥Esc, without ctrl).
local mod = { "ctrl", "alt", "cmd" }
local key = "escape"

hs.hotkey.bind(mod, key, function()
  local enabled = hs.settings.get("layoutManagementEnabled")
  if enabled == nil then enabled = true end  -- default on, matches init.lua
  hs.settings.set("layoutManagementEnabled", not enabled)
  -- Reload applies the change: the pathwatcher-style in-process reload re-runs
  -- init.lua, which now (un)loads the layout modules per the new setting. The
  -- post-reload state is announced by init.lua's load alert.
  hs.reload()
end)

return {}
