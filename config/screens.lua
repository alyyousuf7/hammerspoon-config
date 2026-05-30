-- Move the focused window between physical screens. Screens are sorted
-- left-to-right by frame.x so "right" = visually right display, regardless
-- of the order macOS returns them in.

-- ============================================================================
-- CONFIG
-- ============================================================================

local mod = { "ctrl", "alt", "cmd" }

-- ============================================================================
-- LOGIC
-- ============================================================================

local function screensLeftToRight()
  local screens = hs.screen.allScreens()
  table.sort(screens, function(a, b) return a:frame().x < b:frame().x end)
  return screens
end

local function moveWindow(offset)
  return function()
    local win = hs.window.focusedWindow()
    if not win then return end
    local screens = screensLeftToRight()
    if #screens <= 1 then return end
    local current = win:screen()
    local idx
    for i, s in ipairs(screens) do
      if s:id() == current:id() then idx = i; break end
    end
    if not idx then return end
    local target = screens[idx + offset]
    if target then win:moveToScreen(target) end
  end
end

-- ============================================================================
-- WIRING
-- ============================================================================

hs.hotkey.bind(mod, "right", moveWindow(1))
hs.hotkey.bind(mod, "left",  moveWindow(-1))
