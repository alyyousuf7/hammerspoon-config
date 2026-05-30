-- Minimize-layout toggle. First press: hide every app in the current layout
-- (and any overlays), surfacing the "other" apps you normally keep out of
-- sight — Mail, Calendar, Notion, etc. Second press: re-apply the last layout
-- to restore state.

local layouts = require("config.layouts")
local wm = require("config.window_management")

local M = {}

-- Toggle state. Kept module-level and exposed on M below so the application
-- watcher and the hook registered on layouts aren't garbage-collected.
local minimized = false
-- Name of the last-focused non-layout app while minimized, so subsequent
-- toggles restore the same top-of-stack.
local lastFocused = nil

-- ============================================================================
-- CONFIG
-- ============================================================================

local mod = { "ctrl", "alt", "cmd" }
local hotkey = "f19"

-- ============================================================================
-- LOGIC
-- ============================================================================

local function hideHandled()
  local handledSet = layouts.handledSet
  for _, app in ipairs(hs.application.runningApplications()) do
    -- Skip apps with any window on a secondary display: app:hide() would
    -- yank those windows off the secondary screen along with the primary ones.
    if handledSet[app:name()] and not wm.appHasWindowOnSecondary(app) then
      app:hide()
    end
  end
end

-- True if the app has at least one "real" (user-visible) window. Accepts two
-- AX subroles: AXStandardWindow (most apps) and AXDialog (Calendar, Finder,
-- etc. — yes, their main windows use the dialog subrole on macOS). Filters
-- out AXDesktop (Finder's desktop entry), AXSystemFloatingWindow (menu
-- extras), and other helper windows that would activate the app without
-- surfacing anything visible.
local function hasRealWindow(app)
  for _, win in ipairs(app:allWindows()) do
    if not win:isMinimized() then
      local subrole = win:subrole()
      if subrole == "AXStandardWindow" or subrole == "AXDialog" then
        return true
      end
    end
  end
  return false
end

local function surfaceOthers()
  local handledSet = layouts.handledSet

  -- First hide pass. `app:hide()` on the currently-frontmost app can silently
  -- race with focus transitions on modern macOS, which is why a second pass
  -- runs below after focus has moved elsewhere.
  hideHandled()

  -- Collect non-handled foreground apps that have at least one real window.
  local apps = {}
  for _, app in ipairs(hs.application.runningApplications()) do
    if app:kind() == 1 and not handledSet[app:name()]
        and hasRealWindow(app) then
      apps[#apps + 1] = app
    end
  end

  -- Decide target: remembered last-focused app if still present, otherwise
  -- alphabetically first.
  local target
  if lastFocused then
    for _, app in ipairs(apps) do
      if app:name() == lastFocused then target = app; break end
    end
  end
  if not target then
    table.sort(apps, function(a, b) return a:name() < b:name() end)
    target = apps[1]
  end

  -- Unhide every non-handled app so its windows become visible, but DON'T
  -- activate each one — activating N apps in sequence makes macOS animate N
  -- menu-bar transitions, which is the main source of jitter. A single
  -- activate on the target is enough.
  for _, app in ipairs(apps) do
    if app:isHidden() then app:unhide() end
  end
  if target then target:activate(true) end

  -- Second hide pass catches any handled app that resisted hiding on the first
  -- pass because it was the frontmost. By now focus has moved to the target,
  -- so the straggler can be safely hidden.
  hideHandled()
end

local function toggle()
  if minimized then
    local current = layouts.currentLayout()
    if current then layouts.apply(current) end
    minimized = false
  else
    surfaceOthers()
    minimized = true
  end
end

-- Track the most recently focused non-layout app while minimized, so we can
-- restore the same top-of-stack on subsequent toggles.
M.focusWatcher = hs.application.watcher.new(function(appName, eventType)
  if eventType ~= hs.application.watcher.activated then return end
  if minimized and not layouts.handledSet[appName] then
    lastFocused = appName
  end
end)

-- A direct layout trigger exits minimized mode so the next toggle starts fresh.
layouts.onApply = function()
  minimized = false
end

-- ============================================================================
-- WIRING
-- ============================================================================

hs.hotkey.bind(mod, hotkey, toggle)
M.focusWatcher:start()

return M
