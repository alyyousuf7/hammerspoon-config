-- Window management: halves, thirds, sixths, resize, maximize.

local M = {}

-- ============================================================================
-- CONFIG
-- ============================================================================

-- Modifier for every shortcut in this file.
local mod = { "ctrl", "alt" }

-- Padding in pixels applied around every placed window.
-- outerGap = space between a window and the screen edge.
-- innerGap = total space between two adjacent windows (each contributes half).
local outerGap = 8
local innerGap = 8

-- Per-action animation durations (seconds). 0 = instant snap.
local placeAnimation  = 0
local resizeAnimation = 0.2

-- Minimum window size in pixels when shrinking via the resize hotkeys.
local minWindowSize = 200

-- Region placements. Each entry: { keys = { list }, rect = { x, y, w, h } in fractions }.
-- `keys` is always a list so one rect can be bound to multiple keys
-- (e.g. Return + numpad Enter for Maximize).
local placements = {
  -- Halves
  { keys = { "home"   }, rect = { 0,   0, 1/2, 1 } },  -- Left Half
  { keys = { "pageup" }, rect = { 1/2, 0, 1/2, 1 } },  -- Right Half
  { keys = { "f14"    }, rect = { 1/4, 0, 1/2, 1 } },  -- Center Half

  -- Thirds (numpad)
  { keys = { "pad4" }, rect = { 0,   0, 1/3, 1 } },  -- First Third
  { keys = { "pad5" }, rect = { 1/3, 0, 1/3, 1 } },  -- Center Third
  { keys = { "pad6" }, rect = { 2/3, 0, 1/3, 1 } },  -- Last Third
  { keys = { "pad0" }, rect = { 0,   0, 2/3, 1 } },  -- First Two Thirds
  { keys = { "pad." }, rect = { 1/3, 0, 2/3, 1 } },  -- Last Two Thirds

  -- Fourths / Quarters
  { keys = { "f13"      }, rect = { 0,   0,   1/4, 1   } },  -- First Fourth
  { keys = { "f15"      }, rect = { 3/4, 0,   1/4, 1   } },  -- Last Fourth
  { keys = { "end"      }, rect = { 0,   1/2, 1/2, 1/2 } },  -- Bottom Left Quarter
  { keys = { "pagedown" }, rect = { 1/2, 1/2, 1/2, 1/2 } },  -- Bottom Right Quarter

  -- Sixths (numpad)
  { keys = { "pad7" }, rect = { 0,   0,   1/3, 1/2 } },  -- Top Left Sixth
  { keys = { "pad8" }, rect = { 1/3, 0,   1/3, 1/2 } },  -- Top Center Sixth
  { keys = { "pad9" }, rect = { 2/3, 0,   1/3, 1/2 } },  -- Top Right Sixth
  { keys = { "pad1" }, rect = { 0,   1/2, 1/3, 1/2 } },  -- Bottom Left Sixth
  { keys = { "pad2" }, rect = { 1/3, 1/2, 1/3, 1/2 } },  -- Bottom Center Sixth
  { keys = { "pad3" }, rect = { 2/3, 1/2, 1/3, 1/2 } },  -- Bottom Right Sixth

  -- Maximize (main Return + numpad Enter)
  { keys = { "return", "padenter" }, rect = { 0, 0, 1, 1 } },
}

-- Resize bindings: grow/shrink focused window around its center by `delta`
-- fraction of the screen per press.
local resizes = {
  { key = "pad+", delta =  0.05 },  -- Make Larger
  { key = "pad-", delta = -0.05 },  -- Make Smaller
}

-- ============================================================================
-- LOGIC
-- ============================================================================

-- Move/resize a given window into a fractional region of its screen's usable
-- frame. outerGap padding on edges touching screen bounds, innerGap/2 on inner
-- edges (so two adjacent tiles sum to innerGap between them).
function M.placeWindow(win, x, y, w, h)
  if not win then return end
  local f = win:screen():frame()
  local eps = 1e-6
  local function pad(touchesEdge) return touchesEdge and outerGap or innerGap / 2 end
  local left   = pad(x         < eps)
  local top    = pad(y         < eps)
  local right  = pad(x + w > 1 - eps)
  local bottom = pad(y + h > 1 - eps)
  win:setFrame({
    x = f.x + f.w * x + left,
    y = f.y + f.h * y + top,
    w = f.w * w - left - right,
    h = f.h * h - top  - bottom,
  }, placeAnimation)
end

-- Hotkey callback: place the focused window into a fractional region.
local function placeFocused(x, y, w, h)
  return function() M.placeWindow(hs.window.focusedWindow(), x, y, w, h) end
end

-- Hotkey callback: grow/shrink focused window around its center by a fractional delta.
-- Clamps to the screen frame minus outerGap on every side so resizing stops at
-- the same edge padding that placement uses.
local function resizeFocused(delta)
  return function()
    local win = hs.window.focusedWindow()
    if not win then return end
    local s = win:screen():frame()
    local f = win:frame()
    local dx, dy = s.w * delta, s.h * delta
    f.x, f.y = f.x - dx/2, f.y - dy/2
    f.w, f.h = f.w + dx,   f.h + dy
    if f.w < minWindowSize then f.w = minWindowSize end
    if f.h < minWindowSize then f.h = minWindowSize end
    local minX, minY = s.x + outerGap,           s.y + outerGap
    local maxX, maxY = s.x + s.w - outerGap,     s.y + s.h - outerGap
    if f.x < minX then f.x = minX end
    if f.y < minY then f.y = minY end
    if f.x + f.w > maxX then f.w = maxX - f.x end
    if f.y + f.h > maxY then f.h = maxY - f.y end
    win:setFrame(f, resizeAnimation)
  end
end

-- ============================================================================
-- WIRING
-- ============================================================================

for _, p in ipairs(placements) do
  local action = placeFocused(p.rect[1], p.rect[2], p.rect[3], p.rect[4])
  for _, k in ipairs(p.keys) do hs.hotkey.bind(mod, k, action) end
end

for _, r in ipairs(resizes) do
  hs.hotkey.bind(mod, r.key, resizeFocused(r.delta))
end

return M
