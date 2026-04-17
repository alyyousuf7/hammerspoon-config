-- Space (desktop) switching via hs.spaces. Uses the proper API instead of
-- synthesizing ⌃→ / ⌃←, which depended on macOS accepting modifier flags while
-- other modifiers were physically held.

local mod = { "ctrl", "alt", "cmd" }

local function moveSpace(offset)
  return function()
    local screen = hs.screen.mainScreen()
    local spaces = hs.spaces.spacesForScreen(screen:getUUID())
    if not spaces or #spaces == 0 then return end
    local current = hs.spaces.focusedSpace()
    local idx
    for i, s in ipairs(spaces) do
      if s == current then idx = i; break end
    end
    if not idx then return end
    local target = spaces[idx + offset]
    if target then hs.spaces.gotoSpace(target) end
  end
end

hs.hotkey.bind(mod, "right", moveSpace(1))
hs.hotkey.bind(mod, "left",  moveSpace(-1))
