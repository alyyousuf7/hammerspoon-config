-- Composable, on-the-fly layouts driven entirely by the arrow keys.
--
-- State is three values:
--   focus ∈ {1,2,3}   — the cursor slot (what ,/. retarget, what's highlighted)
--   h     ∈ ℤ         — horizontal pan within the current row (+ toward slot 1)
--   v     ∈ {-1,0,1,2}— vertical row = the middle slot's size:
--                        -1 half(1,3) [middle gone] · 0 thirds · 1 mid-emph · 2 full(2)
--
-- Geometry is derived purely from (v, h) — see G / stateKey() below. The result
-- is one of 12 named shapes; the slot rects are handed to config/layouts.lua via
-- applyDynamic(), which does all the hide/raise/focus/placement work.
--
-- Keys (all ⌃⌥⌘):
--   ← / →  walk the cursor across the visible slots; at the edge, pan the
--          geometry one notch (revealing/emphasising a side). Middle-present
--          panning collapses onto the thirds row.
--   ↑ / ↓  grow / shrink the middle slot (recentering horizontally first).
--   , / .  cycle the focused slot's source (prev / next, incl. an empty stop;
--          sources already shown in another slot are skipped).
--   S      save the current arrangement to a preset; 1–9 recall.

local layouts = require("config.layouts")
local wm = require("config.window_management")

local M = {}

-- ============================================================================
-- CONFIG
-- ============================================================================

local mod = { "ctrl", "alt", "cmd" }

-- Pickable catalog. Each: { name, app, launch?, stack? }. A slot stacks ALL of
-- its app's windows; the frontmost shows and Cmd-` cycles them.
local sources = {
  { name = "Code",              app = "Code" },
  { name = "Ghostty",           app = "Ghostty" },
  { name = "Claude",            app = "Claude", launch = true },
  { name = "Chrome",            app = "Google Chrome" },
  { name = "Chrome for Testing",app = "Google Chrome for Testing", stack = "vertical" },
  { name = "Notion",            app = "Notion" },
  { name = "Meet",              app = "Google Meet", launch = true },
}

-- Geometry table. Each entry is { slot1, slot2, slot3 } where a slot is either
-- false (hidden) or { x, w } fractions (y = 0, height = 1 for all).
local G = {
  thirds      = { { 0, 1/3 }, { 1/3, 1/3 }, { 2/3, 1/3 } },
  half12      = { { 0, 1/2 }, { 1/2, 1/2 }, false },
  leftEmph12  = { { 0, 2/3 }, { 2/3, 1/3 }, false },
  full1       = { { 0, 1 },   false,        false },
  half23      = { false, { 0, 1/2 }, { 1/2, 1/2 } },
  rightEmph23 = { false, { 0, 1/3 }, { 1/3, 2/3 } },
  full3       = { false, false,      { 0, 1 } },
  midEmph     = { { 0, 1/4 }, { 1/4, 1/2 }, { 3/4, 1/4 } },
  full2       = { false, { 0, 1 }, false },
  half13      = { { 0, 1/2 }, false, { 1/2, 1/2 } },
  leftEmph13  = { { 0, 2/3 }, false, { 2/3, 1/3 } },
  rightEmph13 = { { 0, 1/3 }, false, { 1/3, 2/3 } },
}

-- Human-readable names, for the flash label.
local NAMES = {
  thirds = "thirds(1,2,3)", half12 = "half(1,2)", leftEmph12 = "left-emph(1,2)", full1 = "full(1)",
  half23 = "half(2,3)", rightEmph23 = "right-emph(2,3)", full3 = "full(3)",
  midEmph = "mid-emph(1,2,3)", full2 = "full(2)", half13 = "half(1,3)",
  leftEmph13 = "left-emph(1,3)", rightEmph13 = "right-emph(1,3)",
}

-- (v, h) -> geometry key.
local V_CENTER    = { [-1] = "half13", [0] = "thirds", [1] = "midEmph", [2] = "full2" }
local ARM_PRESENT = { [1] = "half12", [2] = "leftEmph12", [3] = "full1",
                      [-1] = "half23", [-2] = "rightEmph23", [-3] = "full3" }
local ARM_GONE    = { [1] = "leftEmph13", [2] = "full1", [-1] = "rightEmph13", [-2] = "full3" }

-- Minimap nodes (the reachable states) as { v, h } pairs. Grid position is
-- derived as col = 4 - h, row = 3 - v.
local MAP_NODES = {
  { 2, 0 }, { 1, 0 },
  { 0, 3 }, { 0, 2 }, { 0, 1 }, { 0, 0 }, { 0, -1 }, { 0, -2 }, { 0, -3 },
  { -1, 2 }, { -1, 1 }, { -1, 0 }, { -1, -1 }, { -1, -2 },
}

local SAVE_SLOTS   = 9
local SETTINGS_KEY = "composer.savedPresets.v2"
local STATE_KEY    = "composer.state.v1"      -- last (v,h,focus,slots), restored on launch
local DYNAMIC_NAME = "__composed"

-- ============================================================================
-- STATE
-- ============================================================================

local focus = 1                 -- 1,2,3
local v, h  = 0, 0
local slots = { false, false, false }  -- source table | false per slot
local savedPresets = hs.settings.get(SETTINGS_KEY) or {}

-- ============================================================================
-- LOGIC
-- ============================================================================

local function resolveSource(name)
  if not name then return nil end
  for _, s in ipairs(sources) do if s.name == name then return s end end
  return nil
end

local function indexOf(list, val)
  for i, x in ipairs(list) do if x == val then return i end end
  return nil
end

local function currentSourceNames()
  local names = {}
  for i = 1, 3 do names[i] = (slots[i] and slots[i].name) or false end
  return names
end

-- Persist the live state so a Hammerspoon restart resumes the same arrangement.
local function persistState()
  hs.settings.set(STATE_KEY, { v = v, h = h, focus = focus, sourceNames = currentSourceNames() })
end

local function stateKey()
  if h == 0 then return V_CENTER[v] end
  return (v == -1 and ARM_GONE or ARM_PRESENT)[h]
end
local function cells()       return G[stateKey()] end
local function hLeftMax()    return v == -1 and 2 or 3 end
local function hRightMax()   return v == -1 and -2 or -3 end

-- Geometry key for an arbitrary (vv, hh) — used by the minimap to render every
-- node, not just the current one.
local function keyFor(vv, hh)
  if hh == 0 then return V_CENTER[vv] end
  return (vv == -1 and ARM_GONE or ARM_PRESENT)[hh]
end

local function visibleSlots()
  local c, out = cells(), {}
  for i = 1, 3 do if c[i] then out[#out + 1] = i end end
  return out
end

-- Walk the cursor one visible slot in dir (-1/+1). Snaps onto a visible slot if
-- the focused slot is currently hidden. Returns false when already at the edge.
local function moveFocus(dir)
  local vis = visibleSlots()
  if #vis == 0 then return false end
  local p = indexOf(vis, focus)
  if not p then
    local cand = {}
    for _, i in ipairs(vis) do
      if (dir < 0 and i < focus) or (dir > 0 and i > focus) then cand[#cand + 1] = i end
    end
    if #cand > 0 then focus = dir < 0 and cand[#cand] or cand[1]
    else focus = dir < 0 and vis[1] or vis[#vis] end
    return true
  end
  if dir < 0 and p > 1     then focus = vis[p - 1]; return true end
  if dir > 0 and p < #vis  then focus = vis[p + 1]; return true end
  return false
end

-- Snap focus onto a visible slot after a geometry change.
local function reclampFocus(dir)
  local vis = visibleSlots()
  if #vis == 0 or indexOf(vis, focus) then return end
  if dir < 0 then focus = vis[1]
  elseif dir > 0 then focus = vis[#vis]
  else
    local best, bd = vis[1], math.huge
    for _, i in ipairs(vis) do local d = math.abs(i - focus); if d < bd then best, bd = i, d end end
    focus = best
  end
end


-- ---------------------------------------------------------------------------
-- Minimap: a bottom-center navigator. Each node is a mini slot-diagram
-- (boxes + numbers) for that state; the current state is highlighted, and
-- within it the focused slot is marked. Auto-fades like the flash.
-- ---------------------------------------------------------------------------
local ACCENT = { red = 0.0, green = 0.478, blue = 1.0, alpha = 1 }   -- macOS system accent blue (#007AFF)
local function withAlpha(co, a) return { red = co.red, green = co.green, blue = co.blue, alpha = a } end

-- Fade durations (seconds) for the three overlays. Fades happen only on
-- first-appear / disappear; a redraw of an already-visible overlay reuses its
-- canvas (instant content swap) so rapid nav/cycle never flickers.
local FADE_IN, FADE_OUT = 0.12, 0.18

-- Shared mini layout-node renderer, used by both the minimap and the preset
-- panel so the two show the *same* slot-diagram visual. Draws the node container
-- box (padded by opt.pad) plus the slot boxes (and numbers) for geometry `key`,
-- spanning layW × slotH at (x, y). opt.styleFor(s) -> fillColor, numColor
-- (numColor nil → no number). opt.box = { fill, stroke, strokeW, rad } for the
-- container.
local function appendLayoutNode(els, key, x, y, layW, slotH, opt)
  local geo = G[key]
  if not geo then return end
  local pad  = opt.pad or 0
  local box  = opt.box
  if box then
    els[#els + 1] = { type = "rectangle", action = "strokeAndFill",
      fillColor   = box.fill    or { white = 1, alpha = 0.04 },
      strokeColor = box.stroke  or { white = 1, alpha = 0 },
      strokeWidth = box.strokeW or 0,
      frame = { x = x - pad, y = y - pad, w = layW + 2 * pad, h = slotH + 2 * pad },
      roundedRectRadii = { xRadius = box.rad or 8, yRadius = box.rad or 8 } }
  end
  local sgap = opt.sgap or 2
  local rad  = opt.rad or 8
  local font = opt.font or "SFProText-Semibold"
  local fsize = opt.fsize or 13
  local numH = opt.numH or (fsize + 3)
  local eps = 1e-6
  for s = 1, 3 do
    local cell = geo[s]
    if cell then
      -- Inset half a gap only on edges shared with another slot; the outer edges
      -- sit flush against the layW region so the box's padding is equal all round.
      local x0, x1 = cell[1], cell[1] + cell[2]
      local leftGap  = (x0 > eps) and (sgap / 2) or 0
      local rightGap = (x1 < 1 - eps) and (sgap / 2) or 0
      local sx = x + x0 * layW + leftGap
      local sw = (x1 - x0) * layW - leftGap - rightGap
      local fill, numColor = opt.styleFor(s)
      els[#els + 1] = { type = "rectangle", action = "fill", fillColor = fill,
        frame = { x = sx, y = y, w = sw, h = slotH }, roundedRectRadii = { xRadius = rad, yRadius = rad } }
      if numColor then
        els[#els + 1] = { type = "text", text = tostring(s), textColor = numColor,
          textFont = font, textSize = fsize, textAlignment = "center",
          frame = { x = sx, y = y + (slotH - numH) / 2, w = sw, h = numH } }
      end
    end
  end
end

-- pinned: when true (opened via the 'm' toggle), the minimap stays up with no
-- auto-fade. Any normal redraw (arrow nav) passes pinned=false and restores the
-- usual timed fade.
local function drawMinimap(pinned)
  if M.mapTimer then M.mapTimer:stop(); M.mapTimer = nil end
  local accent = ACCENT
  local f = hs.screen.primaryScreen():frame()

  -- Slot unit borrowed from the preset badges: each slot is SLOT_H tall (the
  -- badge size) with the badge corner radius; its width scales by the fraction of
  -- the layout it occupies, so a full layout spans LAYW. The panel sits inside a
  -- MARGIN so its drop shadow has room to render (shadows clip to canvas bounds).
  local SLOT_H, LAYW, RAD = 26, 88, 8
  local NP, SGAP = 6, 2          -- node inner padding; gap between slot boxes
  local GAP, PAD, MARGIN = 10, 20, 30
  -- Numerals: the macOS system font (preset-badge size). numH is the line box we
  -- vertically center within each slot (a fixed approximation — measuring via the
  -- deprecated getTextDrawingSize logs a spurious canvas warning).
  local NUMFONT, NUMSIZE = "SFProText-Semibold", 13
  local numH = NUMSIZE + 3
  local NODE_W, NODE_H = LAYW + 2 * NP, SLOT_H + 2 * NP
  local gridW = 7 * NODE_W + 6 * GAP
  local gridH = 4 * NODE_H + 3 * GAP
  local panelW = PAD * 2 + gridW
  local panelH = PAD * 2 + gridH
  local W, H = panelW + MARGIN * 2, panelH + MARGIN * 2
  local ox = f.x + (f.w - W) / 2
  local oy = f.y + f.h - H - 8

  local gx, gy = MARGIN + PAD, MARGIN + PAD   -- grid origin inside the panel
  local function nodeXY(nv, nh)
    return gx + (4 - nh - 1) * (NODE_W + GAP), gy + (3 - nv - 1) * (NODE_H + GAP)
  end

  -- Panel: modeled on the Cmd-Tab switcher — a big-radius, generously-padded
  -- translucent dark "HUD" material with a large soft window shadow and a hairline
  -- top-light edge. (hs.canvas can't truly backdrop-blur, so the wallpaper
  -- bleed-through is a tasteful translucency rather than real vibrancy.)
  local panelFill = { white = 0.10, alpha = 0.92 }   -- Cmd-Tab charcoal vibrancy
  local els = { { type = "rectangle", action = "strokeAndFill",
    fillColor = panelFill,
    strokeColor = { white = 1, alpha = 0.18 }, strokeWidth = 1,
    shadow = { blurRadius = 32, color = { alpha = 0.55 }, offset = { h = -11, w = 0 } },
    frame = { x = MARGIN, y = MARGIN, w = panelW, h = panelH },
    roundedRectRadii = { xRadius = 22, yRadius = 22 } } }

  -- Each node is one layout. The current layout takes the switcher's selected-tile
  -- treatment (accent tint + accent border); the focused slot inside it takes the
  -- preset-badge treatment (solid accent + white numeral). Everything else is a
  -- quiet neutral gray. While F19-minimized the current layout isn't actually on
  -- screen, so its highlight is shown MUTED (neutral gray, no accent).
  local muted = layouts.minimized
  for _, node in ipairs(MAP_NODES) do
    local nv, nh = node[1], node[2]
    local nx, ny = nodeXY(nv, nh)
    local cur = nv == v and nh == h
    appendLayoutNode(els, keyFor(nv, nh), nx + NP, ny + NP, LAYW, SLOT_H, {
      pad = NP, sgap = SGAP, rad = RAD, font = NUMFONT, fsize = NUMSIZE, numH = numH,
      box = {
        fill    = cur and (muted and { white = 1, alpha = 0.10 } or withAlpha(accent, 0.30))
                       or { white = 1, alpha = 0.04 },
        stroke  = cur and (muted and { white = 1, alpha = 0.22 } or accent)
                       or { white = 1, alpha = 0 },
        strokeW = cur and 2 or 0,
        rad     = RAD + NP,   -- concentric with the slots inside (slot radius + gap)
      },
      styleFor = function(s)
        if cur and s == focus then
          if muted then return { white = 0.55, alpha = 1 }, { white = 1, alpha = 1 } end
          return accent, { white = 1, alpha = 1 }        -- focused slot: preset-badge accent
        end
        return { white = 1, alpha = 0.05 },              -- preset row tile
               cur and { white = 0.95, alpha = 1 } or { white = 0.6, alpha = 1 }
      end,
    })
  end

  if M.map then
    M.map:replaceElements(els)               -- reuse: instant swap, no re-fade
  else
    local c = hs.canvas.new({ x = ox, y = oy, w = W, h = H })
    c:level(hs.canvas.windowLevels.popUpMenu)
    c:behavior({ "canJoinAllSpaces", "stationary" })
    c:clickActivating(false)
    c:replaceElements(els)
    c:show(FADE_IN)
    M.map = c
  end
  if not pinned then
    M.mapTimer = hs.timer.doAfter(2.0, function()
      if M.map then M.map:delete(FADE_OUT); M.map = nil end
      M.mapTimer = nil
    end)
  end
end

-- Toggle the minimap open (pinned, no auto-fade). Pressing 'm' again — or any
-- arrow-nav redraw — dismisses or un-pins it.
local function toggleMinimap()
  if M.map then
    if M.mapTimer then M.mapTimer:stop(); M.mapTimer = nil end
    M.map:delete(FADE_OUT); M.map = nil
  else
    drawMinimap(true)
  end
end

-- ---------------------------------------------------------------------------
-- App switcher: a Cmd-Tab-style centered strip shown while cycling a slot's
-- source. Each option is an app icon; the chosen one is highlighted (accent) and
-- its name shown below. Auto-fades like the other overlays.
-- ---------------------------------------------------------------------------
local function appIcon(appName)
  local app = hs.application.get(appName)
  local bid = app and app:bundleID()
  if bid then return hs.image.imageFromAppBundle(bid) end
  return nil
end

local function drawAppSwitcher(list, chosenName, disabled)
  if M.swTimer then M.swTimer:stop(); M.swTimer = nil end
  disabled = disabled or {}
  local accent = ACCENT
  local f = hs.screen.primaryScreen():frame()
  local ICON, TILE, TGAP, PAD, GAPL, LABELH, MARGIN = 40, 56, 10, 18, 12, 18, 24
  local n = #list
  local rowW = n * TILE + (n - 1) * TGAP
  local panelW = PAD * 2 + rowW
  local panelH = PAD * 2 + TILE + GAPL + LABELH
  local W, H = panelW + MARGIN * 2, panelH + MARGIN * 2
  -- Center horizontally on the slot being switched (full-height slots → the
  -- vertical center is just the screen center). Clamp so a wide strip on a narrow
  -- slot still stays fully on-screen.
  local cell = cells()[focus]
  local slotCx = cell and (f.x + f.w * (cell[1] + cell[2] / 2)) or (f.x + f.w / 2)
  local ox = math.max(f.x + 8, math.min(slotCx - W / 2, f.x + f.w - W - 8))
  local oy = f.y + (f.h - H) / 2

  local els = { { type = "rectangle", action = "strokeAndFill",
    fillColor = { white = 0.10, alpha = 0.92 },
    strokeColor = { white = 1, alpha = 0.18 }, strokeWidth = 1,
    shadow = { blurRadius = 32, color = { alpha = 0.55 }, offset = { h = -11, w = 0 } },
    frame = { x = MARGIN, y = MARGIN, w = panelW, h = panelH },
    roundedRectRadii = { xRadius = 20, yRadius = 20 } } }

  local gx, gy = MARGIN + PAD, MARGIN + PAD
  local chosenLabel = "Empty"
  for k, s in ipairs(list) do
    local cx = gx + (k - 1) * (TILE + TGAP)
    local dis = s and disabled[s.name] or false   -- in another slot → shown but disabled
    local selected = not dis and ((s and s.name) or nil) == chosenName
    if selected then
      els[#els + 1] = { type = "rectangle", action = "fill", fillColor = withAlpha(accent, 0.30),
        frame = { x = cx, y = gy, w = TILE, h = TILE }, roundedRectRadii = { xRadius = 12, yRadius = 12 } }
      els[#els + 1] = { type = "rectangle", action = "stroke", strokeColor = accent, strokeWidth = 2,
        frame = { x = cx, y = gy, w = TILE, h = TILE }, roundedRectRadii = { xRadius = 12, yRadius = 12 } }
      if s then chosenLabel = s.name end
    end
    if s then
      local img = appIcon(s.app)
      if img then
        local io = (TILE - ICON) / 2
        els[#els + 1] = { type = "image", image = img, imageScaling = "scaleProportionally",
          imageAlpha = dis and 0.28 or 1.0,
          frame = { x = cx + io, y = gy + io, w = ICON, h = ICON } }
      else
        els[#els + 1] = { type = "text", text = s.name:sub(1, 1),
          textFont = "SFProText-Semibold", textSize = 20, textColor = { white = dis and 0.35 or 0.9, alpha = 1 },
          textAlignment = "center", frame = { x = cx, y = gy + TILE / 2 - 14, w = TILE, h = 28 } }
      end
    else
      els[#els + 1] = { type = "text", text = "—",
        textFont = "SFProText-Semibold", textSize = 24, textColor = { white = 0.7, alpha = 1 },
        textAlignment = "center", frame = { x = cx, y = gy + TILE / 2 - 17, w = TILE, h = 34 } }
    end
  end

  els[#els + 1] = { type = "text", text = chosenLabel,
    textFont = "SFProText-Semibold", textSize = 12.5, textColor = { white = 0.95, alpha = 1 },
    textAlignment = "center", frame = { x = MARGIN, y = gy + TILE + GAPL, w = panelW, h = LABELH } }

  if M.sw then
    M.sw:frame({ x = ox, y = oy, w = W, h = H })   -- reuse: resize/move, no re-fade
    M.sw:replaceElements(els)
  else
    local c = hs.canvas.new({ x = ox, y = oy, w = W, h = H })
    c:level(hs.canvas.windowLevels.popUpMenu)
    c:behavior({ "canJoinAllSpaces", "stationary" })
    c:clickActivating(false)
    c:replaceElements(els)
    c:show(FADE_IN)
    M.sw = c
  end
  M.swTimer = hs.timer.doAfter(1.5, function()
    if M.sw then M.sw:delete(FADE_OUT); M.sw = nil end
    M.swTimer = nil
  end)
end

-- ---------------------------------------------------------------------------
-- Slot-bounds flash: on a SHAPE change, briefly outline each slot's on-screen
-- rect (even empty ones) and fade it out — so layout changes are visible even
-- when slots hold no window. Rects mirror window_management's placement padding.
-- ---------------------------------------------------------------------------
-- onlyFocus: outline just the focused slot (for focus-only moves) rather than
-- every slot (for shape changes).
local function flashSlotBounds(onlyFocus)
  -- Instant-kill any prior flash — whether it's still holding OR mid fade-out —
  -- so a quick sequence of shape changes never leaves the old shape's boxes
  -- lingering on screen. (The fade-out keeps M.bounds referenced precisely so it
  -- can be cancelled here.)
  if M.boundsTimer then M.boundsTimer:stop(); M.boundsTimer = nil end
  if M.boundsFade then M.boundsFade:stop(); M.boundsFade = nil end
  if M.bounds then M.bounds:delete(); M.bounds = nil end
  local accent = ACCENT
  local f = hs.screen.primaryScreen():frame()
  local outerGap, innerGap, eps = 8, 8, 1e-6
  local function pad(touchesEdge) return touchesEdge and outerGap or innerGap / 2 end
  local c = cells()
  local els = {}
  for i = 1, 3 do
    local cell = c[i]
    if cell and (not onlyFocus or i == focus) then
      local x, w = cell[1], cell[2]
      local left  = pad(x < eps)
      local right = pad(x + w > 1 - eps)
      local top, bottom = outerGap, outerGap            -- slots are full-height
      -- Frames are relative to the canvas, which is pinned to the screen frame.
      local rx = f.w * x + left
      local rw = f.w * w - left - right
      local ry = top
      local rh = f.h - top - bottom
      -- The focused slot gets the full accent; the rest are dimmed.
      local focused = i == focus
      local fillA   = focused and 0.10 or 0.04
      local strokeA = focused and 0.95 or 0.35
      els[#els + 1] = { type = "rectangle", action = "fill",
        fillColor = withAlpha(accent, fillA),
        frame = { x = rx, y = ry, w = rw, h = rh }, roundedRectRadii = { xRadius = 14, yRadius = 14 } }
      els[#els + 1] = { type = "rectangle", action = "stroke",
        strokeColor = withAlpha(accent, strokeA), strokeWidth = focused and 3 or 2,
        frame = { x = rx, y = ry, w = rw, h = rh }, roundedRectRadii = { xRadius = 14, yRadius = 14 } }
    end
  end
  if #els == 0 then return end
  local cv = hs.canvas.new({ x = f.x, y = f.y, w = f.w, h = f.h })
  -- Sit just below the other overlays (minimap / app-switcher / preset panel all
  -- use popUpMenu) so the bounds flash renders UNDER them, not over them.
  cv:level(hs.canvas.windowLevels.popUpMenu - 1)
  cv:behavior({ "canJoinAllSpaces", "stationary" })
  cv:clickActivating(false)
  cv:replaceElements(els)
  cv:show(0.08)
  M.bounds = cv
  -- Hold briefly, then fade away over a longer beat so the change reads clearly.
  -- Fade with hide() (not delete) so M.bounds stays valid during the fade and a
  -- new flash can snap it away; a follow-up timer destroys it once invisible.
  M.boundsTimer = hs.timer.doAfter(0.15, function()
    M.boundsTimer = nil
    if M.bounds then M.bounds:hide(0.45) end
    M.boundsFade = hs.timer.doAfter(0.45, function()
      M.boundsFade = nil
      if M.bounds then M.bounds:delete(); M.bounds = nil end
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- Spotlight (focus mode): dim the whole screen except the focused slot so the
-- focused app stands out. Toggled with ⌃⌥⌘+F; while on, the hole follows the
-- focus cursor (redrawn from commit/recall/newLayout). One reused canvas, sits
-- just below the other overlays, and has no mouse callback so it's fully
-- click-through — the dimmed apps stay usable, it's purely visual.
-- ---------------------------------------------------------------------------
local SPOT_DIM = 0.5      -- darkness of the dimmed area (black alpha)

local function clearSpotlight()
  if M.spotlight then M.spotlight:delete(FADE_OUT); M.spotlight = nil end
end

local function drawSpotlight()
  if layouts.minimized then clearSpotlight(); return end   -- composition not on screen
  local cell = cells()[focus]
  if not cell then clearSpotlight(); return end
  local f = hs.screen.primaryScreen():frame()
  local outerGap, innerGap, eps = 8, 8, 1e-6
  local function pad(touchesEdge) return touchesEdge and outerGap or innerGap / 2 end
  local x, w = cell[1], cell[2]
  local rx = f.w * x + pad(x < eps)
  local rw = f.w * w - pad(x < eps) - pad(x + w > 1 - eps)
  local ry, rh = outerGap, f.h - outerGap * 2
  local accent = ACCENT
  local els = {
    -- Dim the whole screen.
    { type = "rectangle", action = "fill", fillColor = { white = 0, alpha = SPOT_DIM },
      frame = { x = 0, y = 0, w = f.w, h = f.h } },
    -- Punch a transparent hole over the focused slot.
    { type = "rectangle", action = "fill", fillColor = { white = 1, alpha = 1 },
      compositeRule = "clear",
      frame = { x = rx, y = ry, w = rw, h = rh }, roundedRectRadii = { xRadius = 14, yRadius = 14 } },
    -- Accent rim around the hole.
    { type = "rectangle", action = "stroke", strokeColor = withAlpha(accent, 0.9), strokeWidth = 3,
      frame = { x = rx, y = ry, w = rw, h = rh }, roundedRectRadii = { xRadius = 14, yRadius = 14 } },
  }
  if M.spotlight then
    M.spotlight:replaceElements(els)          -- reuse: instant move, no re-fade
  else
    local cv = hs.canvas.new({ x = f.x, y = f.y, w = f.w, h = f.h })
    cv:level(hs.canvas.windowLevels.popUpMenu - 2)   -- above windows, below the other overlays
    cv:behavior({ "canJoinAllSpaces", "stationary" })
    cv:clickActivating(false)                 -- no mouse callback → click-through
    cv:replaceElements(els)
    cv:show(FADE_IN)
    M.spotlight = cv
  end
end

-- Whether the dim is currently suppressed because focus is on something that
-- isn't a composed slot — another app, or a floating panel like Ghostty's
-- quick-terminal (an AXFloatingWindow). Tracked apart from M.spotlightOn (the
-- armed mode): the mode stays on; only the dim's visibility flips.
local spotHidden = false

-- Hide or restore the dim from whatever window has focus RIGHT NOW. Driven by the
-- activation watcher (instant on app switches) and a low-rate poll (catches focus
-- changes that fire no app-activation event — notably opening the quick-terminal
-- while Ghostty is already frontmost). Only flips visibility; the hole's slot is
-- the focus cursor (kept current by the watcher), so this never fights nav.
local function refreshSpotlight()
  if not M.spotlightOn or layouts.minimized then return end
  local fw = hs.window.focusedWindow()
  local app = fw and fw:application() and fw:application():name()
  local onSlot = false
  if fw and fw:isStandard() and app then
    for i = 1, 3 do
      if cells()[i] and slots[i] and slots[i].app == app then onSlot = true; break end
    end
  end
  if onSlot and spotHidden then
    spotHidden = false; drawSpotlight()
  elseif (not onSlot) and not spotHidden then
    spotHidden = true; clearSpotlight()
  end
end

local function toggleSpotlight()
  if layouts.minimized then return end   -- focus mode is disallowed while F19-minimized
  M.spotlightOn = not M.spotlightOn
  spotHidden = false
  if M.spotlightOn then drawSpotlight() else clearSpotlight() end
end

-- ---------------------------------------------------------------------------
-- Apply the current (v, h, slots) to the screen.
-- ---------------------------------------------------------------------------

-- Collapse to empty any slot whose app no longer has a window — so we never
-- resurrect an app the user quit. Apps the composer hid still have windows, so
-- only genuinely-closed apps are dropped.
local function pruneDeadSlots()
  for i = 1, 3 do
    if slots[i] and not layouts.appHasWindows(slots[i].app) then slots[i] = false end
  end
end

-- allowLaunch: only true on preset recall — the one path permitted to open a
-- closed app (its launch=true sources). Everywhere else (resume, navigation,
-- focus, cycling) we never launch and instead prune slots whose app is gone.
local function applyComposition(allowLaunch)
  if not allowLaunch then pruneDeadSlots() end
  local c = cells()
  local lt, visibleApps = {}, {}
  for i = 1, 3 do
    local cell, s = c[i], slots[i]
    if cell and s then
      -- A slot shows ALL of its app's windows stacked in the rect; the frontmost
      -- shows, the rest sit behind it. Cmd-` cycles them, and layouts.apply
      -- preserves the per-app z-order across hide/show — so the window left on
      -- top comes back on top (same for multiple VSCode / Chrome windows).
      local launch = allowLaunch and s.launch or nil
      lt[#lt + 1] = { app = s.app, rect = { cell[1], 0, cell[2], 1 }, stack = s.stack, launch = launch }
      visibleApps[s.app] = true
    end
  end
  -- Clean slate: hide every app not in the (currently visible) composition.
  layouts.hideOthers(visibleApps)
  if #lt == 0 then return end       -- no visible+filled slot to place
  layouts.applyDynamic(DYNAMIC_NAME, lt)
end



-- Every catalog app that has a window, plus an empty stop. Apps already shown in
-- ANOTHER slot are still listed (so the user sees them) but flagged in the
-- returned `disabled` set — the switcher dims them and cycleSource skips them.
-- Shared by cycleSource and the focus-nav switcher.
local function slotCycleList(i)
  local disabled = {}
  for j = 1, 3 do if j ~= i and slots[j] then disabled[slots[j].name] = true end end
  local list = {}
  for _, s in ipairs(sources) do
    if layouts.appHasWindows(s.app) then list[#list + 1] = s end
  end
  list[#list + 1] = false                       -- empty stop
  return list, disabled
end

-- App-name set of the currently visible+filled slots (for the focus-move clean
-- slate, which hides intruders without re-tiling).
local function currentVisibleApps()
  local c, vis = cells(), {}
  for i = 1, 3 do if c[i] and slots[i] then vis[slots[i].app] = true end end
  return vis
end

local dismissPresetPanel   -- forward decl; assigned in the preset-panel section

-- Geometry change (or F19 restore): re-apply the whole composition. Focus-only
-- move: DON'T re-apply — apply() would unhide every slot app and reorder, which
-- fights apps that self-hide on focus loss (e.g. the Meet PWA). But still run the
-- clean-slate hide pass so an app you Cmd-Tabbed to the front gets hidden again.
-- hideOthers only HIDES non-composition apps; it never unhides/retiles the slot
-- apps, so it's flicker-free.
-- focusFlashOnly: flash only the focused slot's bounds even on a shape change
-- (used by rotate, where the geometry is unchanged but assignments move).
local function commit(changed, focusFlashOnly)
  if M.presetPanel then dismissPresetPanel() end   -- a composer move closes the preset panel
  if changed or layouts.minimized then
    applyComposition()
  else
    pruneDeadSlots()
    layouts.hideOthers(currentVisibleApps())
  end
  local src = slots[focus]
  if cells()[focus] and src then
    layouts.focusEntry({ app = src.app, prefer = src.prefer })
  end
  -- Show the app switcher for the focused slot (its current app highlighted),
  -- the same overlay cycling uses — richer than a bare name flash.
  local cyList, cyDisabled = slotCycleList(focus)
  drawAppSwitcher(cyList, src and src.name or nil, cyDisabled)
  -- Outline the new shape's slots on a shape change, or just the focused slot on
  -- a focus-only move (or when the caller forces it) — then fade.
  flashSlotBounds(focusFlashOnly or not changed)
  drawMinimap()
  if M.spotlightOn and not spotHidden then drawSpotlight() end
  persistState()
end

-- While F19-minimized, the FIRST focus/layout/cycle action is swallowed to just
-- restore the pre-F19 composition — like pressing F19 again — instead of acting.
-- commit(false) re-applies the current composition, whose onApply hook clears
-- layouts.minimized. Returns true when it consumed the action.
local function restoreIfMinimized()
  if not layouts.minimized then return false end
  commit(false)
  return true
end

-- ---------------------------------------------------------------------------
-- Navigation
-- ---------------------------------------------------------------------------
local function navLeft()
  if restoreIfMinimized() then return end
  local before = stateKey()
  if not moveFocus(-1) then
    h = math.min(h + 1, hLeftMax())
    if v > 0 then v = 0 end          -- collapse middle-present arms onto the thirds row
    reclampFocus(-1)
  end
  commit(stateKey() ~= before)
end

local function navRight()
  if restoreIfMinimized() then return end
  local before = stateKey()
  if not moveFocus(1) then
    h = math.max(h - 1, hRightMax())
    if v > 0 then v = 0 end
    reclampFocus(1)
  end
  commit(stateKey() ~= before)
end

local function navUp()
  if restoreIfMinimized() then return end
  local before = stateKey()
  if h ~= 0 then h = h + (h > 0 and -1 or 1)   -- recenter horizontally first
  else v = math.min(v + 1, 2) end              -- grow the middle
  reclampFocus(0)
  commit(stateKey() ~= before)
end

local function navDown()
  if restoreIfMinimized() then return end
  local before = stateKey()
  if h ~= 0 then h = h + (h > 0 and -1 or 1)
  else v = math.max(v - 1, -1) end             -- shrink / remove the middle
  reclampFocus(0)
  commit(stateKey() ~= before)
end

-- Rotate every slot's source one position, wrapping (the geometry is unchanged).
-- dir > 0 (default) rotates right: [1][2][3] → [3][1][2] → [2][3][1] → [1][2][3].
-- dir < 0 rotates left. The focus cursor stays put, now pointing at whatever
-- rotated into that position.
local function rotateSlots(dir)
  if restoreIfMinimized() then return end
  if dir and dir < 0 then
    slots[1], slots[2], slots[3] = slots[2], slots[3], slots[1]   -- left
  else
    slots[1], slots[2], slots[3] = slots[3], slots[1], slots[2]   -- right
  end
  commit(true, true)   -- re-tile to the new assignment; flash only the focused slot
end

-- Reverse the slot order — [1][2][3] → [3][2][1] (ends swap, middle stays). This
-- is the one rearrangement rotation can't reach. Bound to a HOLD of the rotate
-- key (a tap rotates).
local function reverseSlots()
  if restoreIfMinimized() then return end
  slots[1], slots[3] = slots[3], slots[1]
  commit(true, true)
end

-- ---------------------------------------------------------------------------
-- Source cycling on the focused slot
-- ---------------------------------------------------------------------------
local function cycleSource(dir)
  if layouts.minimized then return end   -- in F19 mode, source cycling is a no-op
  local i = focus
  -- Only offer apps that actually have a window — cycling never launches, so a
  -- closed app would just show an empty slot. Apps in other slots are listed but
  -- disabled (skipped here).
  local list, disabled = slotCycleList(i)
  -- nil (not false) when the slot is empty, so it matches the empty stop below —
  -- otherwise curIdx falls back to 1 and the cycle gets stuck on empty.
  local curName = nil
  if slots[i] then curName = slots[i].name end
  local curIdx
  for k, s in ipairs(list) do if (s and s.name or nil) == curName then curIdx = k; break end end
  local n = #list
  -- Step in `dir`, skipping disabled (other-slot) entries; at most n hops.
  local idx = curIdx or 1
  for _ = 1, n do
    idx = ((idx - 1 + dir) % n) + 1
    local s = list[idx]
    if not (s and disabled[s.name]) then break end
  end
  slots[i] = list[idx] or false
  applyComposition()
  if slots[i] then layouts.focusEntry({ app = slots[i].app, prefer = slots[i].prefer }) end
  -- No minimap here: switching the app in a slot isn't a layout change — the app
  -- switcher is the relevant overlay.
  drawAppSwitcher(list, slots[i] and slots[i].name or nil, disabled)
  persistState()
end

-- ---------------------------------------------------------------------------
-- Preset panel + recall
-- ---------------------------------------------------------------------------
-- A self-drawn picker (the native hs.chooser bakes in ⌘N row badges that can't
-- be removed). Mirrors recall: the panel lists the 9 preset slots — arm one with
-- 1–9 (or ↑↓), then 's' saves / ↵ switches / ⌫ clears; Esc or the save key again
-- dismisses.
-- App names for a preset (the shape itself is shown as a mini diagram on the
-- right of the row). nil for an empty preset.
local function presetSummary(id)
  local p = savedPresets[id]
  if not p then return nil end
  local parts = {}
  for _, name in ipairs(p.sourceNames or {}) do parts[#parts + 1] = name or "—" end
  return table.concat(parts, " · ")
end

-- Styled app-name list for a preset row: a name whose slot the preset's shape
-- hides (e.g. the middle of half(1,3)) is dimmed, like an empty slot, since it
-- won't actually show when the preset is recalled. nil for an empty preset.
local function presetSummaryStyled(id)
  local p = savedPresets[id]
  if not p then return nil end
  local geo = G[keyFor(p.v or 0, p.h or 0)] or {}
  local font = { name = "SFProText-Regular", size = 11 }
  local visC, dimC = { white = 0.6, alpha = 1 }, { white = 0.4, alpha = 1 }
  local out
  for j = 1, 3 do
    local name = (p.sourceNames or {})[j]
    local shown = geo[j] and geo[j] ~= false           -- slot is part of this shape
    local seg = hs.styledtext.new(name or "—",
      { font = font, color = (name and shown) and visC or dimC })
    out = out and (out .. hs.styledtext.new(" · ", { font = font, color = dimC }) .. seg) or seg
  end
  return out
end

-- The panel is driven by a keyDown eventtap (M.keyTap, created below) that
-- consumes EVERY key while it's open, so nothing leaks to the focused app.
local saveSel = nil       -- currently-armed preset id (string) while the panel is up
local switchToArmed       -- forward decl; assigned after recall() is in scope

dismissPresetPanel = function()   -- assigns the upvalue forward-declared above
  if M.presetPanel then M.presetPanel:delete(FADE_OUT); M.presetPanel = nil end
  if M.clickTap then M.clickTap:stop() end
  if M.keyTap then M.keyTap:stop() end
  saveSel = nil
end

-- sel: the armed preset id (string) to highlight, or nil for none.
local function drawPresetPanel(sel)
  local accent = ACCENT
  local f = hs.screen.primaryScreen():frame()
  local MARGIN, PAD = 24, 16
  local ROW_H, ROW_GAP, BADGE = 44, 6, 26
  local RPAD = (ROW_H - BADGE) / 2   -- uniform inner padding (== badge's vertical inset)
  local BADGE_RAD = 8
  local ROW_RAD = RPAD + BADGE_RAD   -- concentric with the badge: outer = inner + gap
  local HEADERH, HINTH, HGAP, NEW_GAP = 22, 18, 10, 12
  local panelW = 460
  local panelH = PAD + HEADERH + HGAP
                 + SAVE_SLOTS * ROW_H + (SAVE_SLOTS - 1) * ROW_GAP
                 + NEW_GAP + ROW_H            -- the "New layout" row
                 + HGAP + HINTH + PAD
  local W, H = panelW + MARGIN * 2, panelH + MARGIN * 2
  local ox = f.x + (f.w - W) / 2
  local oy = f.y + (f.h - H) / 2

  local els = { { type = "rectangle", action = "strokeAndFill",
    fillColor = { white = 0.10, alpha = 0.92 },
    strokeColor = { white = 1, alpha = 0.18 }, strokeWidth = 1,
    shadow = { blurRadius = 32, color = { alpha = 0.55 }, offset = { h = -11, w = 0 } },
    frame = { x = MARGIN, y = MARGIN, w = panelW, h = panelH },
    roundedRectRadii = { xRadius = 20, yRadius = 20 } } }

  local cx = MARGIN + PAD
  local contentW = panelW - PAD * 2
  els[#els + 1] = { type = "text", text = "Layout Presets",
    textFont = "SFProText-Semibold", textSize = 14, textColor = { white = 0.96, alpha = 1 },
    textAlignment = "left", frame = { x = cx, y = MARGIN + PAD, w = contentW, h = HEADERH } }

  local rowY0 = MARGIN + PAD + HEADERH + HGAP
  for i = 1, SAVE_SLOTS do
    local id = tostring(i)
    local ry = rowY0 + (i - 1) * (ROW_H + ROW_GAP)
    local armed = sel == id
    -- Row tile — armed row gets a brighter fill + accent border.
    els[#els + 1] = { type = "rectangle", action = "strokeAndFill",
      fillColor   = armed and withAlpha(accent, 0.18) or { white = 1, alpha = 0.05 },
      strokeColor = armed and accent or { white = 1, alpha = 0 },
      strokeWidth = armed and 2 or 0,
      frame = { x = cx, y = ry, w = contentW, h = ROW_H }, roundedRectRadii = { xRadius = ROW_RAD, yRadius = ROW_RAD } }
    -- Number badge — full accent when armed, dimmed otherwise.
    local by = ry + (ROW_H - BADGE) / 2
    els[#els + 1] = { type = "rectangle", action = "fill",
      fillColor = withAlpha(accent, armed and 1.0 or 0.85),
      frame = { x = cx + RPAD, y = by, w = BADGE, h = BADGE }, roundedRectRadii = { xRadius = BADGE_RAD, yRadius = BADGE_RAD } }
    els[#els + 1] = { type = "text", text = id,
      textFont = "SFProText-Semibold", textSize = 13, textColor = { white = 1, alpha = 1 },
      textAlignment = "center", frame = { x = cx + RPAD, y = by + (BADGE - 17) / 2, w = BADGE, h = 17 } }
    -- Mini layout diagram on the right — the same node visual as the minimap
    -- (container box + translucent slots); occupied slots get a bright numeral,
    -- empty slots a dim one.
    local VIZW, VIZH, VIZPAD = 72, 20, 4
    local vizX = cx + contentW - RPAD - VIZW - VIZPAD
    local boxLeft = vizX - VIZPAD
    local p = savedPresets[id]
    if p then
      appendLayoutNode(els, keyFor(p.v or 0, p.h or 0), vizX, ry + (ROW_H - VIZH) / 2, VIZW, VIZH, {
        pad = VIZPAD, sgap = 1.5, rad = 5, font = "SFProText-Semibold", fsize = 10, numH = 12,
        box = { fill = { white = 1, alpha = 0.04 }, rad = 5 + VIZPAD },   -- concentric with slots
        styleFor = function(s)
          local occ = p.sourceNames and p.sourceNames[s]
          return { white = 1, alpha = 0.05 },
                 occ and { white = 0.95, alpha = 1 } or { white = 0.4, alpha = 1 }
        end,
      })
    end
    -- Title + app names (the shape is shown by the diagram, not as text).
    local tx = cx + RPAD + BADGE + 12   -- RPAD edge + 12 gap badge↔text
    local tw = boxLeft - 12 - tx
    els[#els + 1] = { type = "text", text = "Preset " .. id,
      textFont = "SFProText-Semibold", textSize = 13, textColor = { white = 0.96, alpha = 1 },
      textAlignment = "left", frame = { x = tx, y = ry + 7, w = tw, h = 17 } }
    els[#els + 1] = { type = "text", text = presetSummaryStyled(id) or "empty",
      textFont = "SFProText-Regular", textSize = 11,
      textColor = { white = 0.4, alpha = 1 },   -- used only for the plain "empty" fallback
      textAlignment = "left", frame = { x = tx, y = ry + 24, w = tw, h = 15 } }
  end

  -- "New layout" action row — a fresh empty thirds to build up from scratch.
  -- Armable like a preset (sel == "new"): gets the accent tile/border/badge.
  local newArmed = sel == "new"
  local nry = rowY0 + SAVE_SLOTS * ROW_H + (SAVE_SLOTS - 1) * ROW_GAP + NEW_GAP
  els[#els + 1] = { type = "rectangle", action = "strokeAndFill",
    fillColor   = newArmed and withAlpha(accent, 0.18) or { white = 1, alpha = 0.05 },
    strokeColor = newArmed and accent or { white = 1, alpha = 0 },
    strokeWidth = newArmed and 2 or 0,
    frame = { x = cx, y = nry, w = contentW, h = ROW_H }, roundedRectRadii = { xRadius = ROW_RAD, yRadius = ROW_RAD } }
  local nby = nry + (ROW_H - BADGE) / 2
  if newArmed then
    els[#els + 1] = { type = "rectangle", action = "fill", fillColor = accent,
      frame = { x = cx + RPAD, y = nby, w = BADGE, h = BADGE }, roundedRectRadii = { xRadius = BADGE_RAD, yRadius = BADGE_RAD } }
  else
    els[#els + 1] = { type = "rectangle", action = "stroke", strokeColor = { white = 0.7, alpha = 0.9 }, strokeWidth = 1.5,
      frame = { x = cx + RPAD, y = nby, w = BADGE, h = BADGE }, roundedRectRadii = { xRadius = BADGE_RAD, yRadius = BADGE_RAD } }
  end
  els[#els + 1] = { type = "text", text = "N",
    textFont = "SFProText-Semibold", textSize = 13, textColor = { white = newArmed and 1 or 0.9, alpha = 1 },
    textAlignment = "center", frame = { x = cx + RPAD, y = nby + (BADGE - 17) / 2, w = BADGE, h = 17 } }
  local ntx = cx + RPAD + BADGE + 12
  local ntw = contentW - RPAD - (BADGE + 12) - RPAD
  els[#els + 1] = { type = "text", text = "Empty preset",
    textFont = "SFProText-Semibold", textSize = 13, textColor = { white = 0.96, alpha = 1 },
    textAlignment = "left", frame = { x = ntx, y = nry + 7, w = ntw, h = 17 } }
  els[#els + 1] = { type = "text", text = "fresh thirds · empty slots",
    textFont = "SFProText-Regular", textSize = 11, textColor = { white = 0.6, alpha = 1 },
    textAlignment = "left", frame = { x = ntx, y = nry + 24, w = ntw, h = 15 } }

  -- Hint adapts to the stage: pick a slot first, then confirm/clear.
  -- Empty armed slots can only be saved into — hide switch/clear for them.
  -- Saving is disabled while F19-minimized (the layout isn't on screen).
  local save = layouts.minimized and "" or "s save · "
  local hint
  if not sel then
    hint = "↑↓ navigate · 1–9 / n select · esc close"
  elseif sel == "new" then
    hint = "↵ start empty preset · esc close"
  elseif presetSummary(sel) then
    hint = sel .. "/↵ switch to · " .. save .. "⌫ clear · esc close"
  else
    hint = layouts.minimized and "esc close" or "s save · esc close"
  end
  local hintY = nry + ROW_H + HGAP
  els[#els + 1] = { type = "text", text = hint,
    textFont = "SFProText-Regular", textSize = 11, textColor = { white = 0.5, alpha = 1 },
    textAlignment = "left", frame = { x = cx, y = hintY, w = contentW, h = HINTH } }

  if M.presetPanel then
    M.presetPanel:replaceElements(els)           -- reuse on arm/redraw: no re-fade
  else
    local c = hs.canvas.new({ x = ox, y = oy, w = W, h = H })
    c:level(hs.canvas.windowLevels.popUpMenu)
    c:behavior({ "canJoinAllSpaces", "stationary" })
    c:clickActivating(false)
    c:replaceElements(els)
    c:show(FADE_IN)
    M.presetPanel = c
  end
  -- Visible panel rect (inset from the canvas by MARGIN), for click-away hit-test.
  M.presetPanelRect = { x = ox + MARGIN, y = oy + MARGIN, w = panelW, h = panelH }
end

local function doSave(id)
  savedPresets[id] = { v = v, h = h, sourceNames = currentSourceNames(), spotlight = M.spotlightOn or false }
  hs.settings.set(SETTINGS_KEY, savedPresets)
  dismissPresetPanel()
  hs.alert.show("Saved as Preset " .. id)
end

-- Arm a preset on first press; a second press of the same key switches to it.
local function selectOrSwitch(id)
  if saveSel == id then switchToArmed() else saveSel = id; drawPresetPanel(id) end
end

-- Move the armed selection up/down the list (wraps). Targets are presets
-- 1..SAVE_SLOTS then the "New layout" row (position SAVE_SLOTS+1). With nothing
-- armed, down arms the first preset and up arms "new".
local function armDelta(d)
  local total = SAVE_SLOTS + 1
  local idx = (saveSel == "new") and total or tonumber(saveSel)
  if not idx then idx = d > 0 and 0 or (total + 1) end
  local n = idx + d
  if n < 1 then n = total elseif n > total then n = 1 end
  saveSel = (n == total) and "new" or tostring(n)
  drawPresetPanel(saveSel)
end

local function saveArmed()
  -- In F19-minimized mode the composed layout isn't on screen, so saving would be
  -- misleading — silently do nothing (the hint already omits "s save").
  if layouts.minimized then return end
  if saveSel and saveSel ~= "new" then doSave(saveSel) end
end

-- Start fresh: a clean thirds with all slots empty, so the user can populate it
-- (via cycle / cmd-tab) and later save it as a preset through the normal flow.
local function newLayout()
  v, h, focus = 0, 0, 1
  for i = 1, 3 do slots[i] = false end
  dismissPresetPanel()
  applyComposition()   -- empty slots → clean slate (hides everything)
  flashSlotBounds()    -- show the fresh thirds even though all slots are empty
  drawMinimap()
  if M.spotlightOn and not spotHidden then drawSpotlight() end
  persistState()
end

-- 'n': arm the "New layout" row first; a second 'n' (or ↵) starts it.
local function selectOrNew()
  if saveSel == "new" then newLayout() else saveSel = "new"; drawPresetPanel("new") end
end

local function clearArmed()
  if not saveSel or not savedPresets[saveSel] then return end   -- nothing armed / already empty
  savedPresets[saveSel] = nil
  hs.settings.set(SETTINGS_KEY, savedPresets)
  drawPresetPanel(saveSel)   -- keep it armed so the now-empty slot is visible
end

-- Click-away dismiss: a non-consuming tap that closes the panel when a mouse
-- press lands outside its visible rect (the click still reaches whatever's under
-- it). Active only while the panel is open.
M.clickTap = hs.eventtap.new(
  { hs.eventtap.event.types.leftMouseDown, hs.eventtap.event.types.rightMouseDown },
  function(e)
    if not M.presetPanel or not M.presetPanelRect then return false end
    local p, r = e:location(), M.presetPanelRect
    if p.x < r.x or p.x > r.x + r.w or p.y < r.y or p.y > r.y + r.h then
      dismissPresetPanel()
    end
    return false
  end)

-- The saved preset id whose (v, h, sources) matches the current arrangement, or
-- nil when the current layout doesn't correspond to any saved preset.
local function currentPresetId()
  local cur = currentSourceNames()
  for i = 1, SAVE_SLOTS do
    local id = tostring(i)
    local p = savedPresets[id]
    if p and (p.v or 0) == v and (p.h or 0) == h then
      local names, match = p.sourceNames or {}, true
      for j = 1, 3 do
        if (names[j] or false) ~= (cur[j] or false) then match = false; break end
      end
      if match then return id end
    end
  end
  return nil
end

local function saveCurrent()
  -- Toggle: pressing the save key again while the panel is up dismisses it.
  if M.presetPanel then dismissPresetPanel(); return end
  -- Pre-arm the matching preset if the current layout IS a saved preset.
  saveSel = currentPresetId()
  drawPresetPanel(saveSel)
  M.keyTap:start()
  M.clickTap:start()
end

-- silent: skip the minimap (used when switching from the preset panel, which
-- already showed the layout — no need to flash the minimap on top).
local function recall(id, silent)
  local p = savedPresets[id]
  if not p then hs.alert.show("Preset " .. id .. " is empty"); return end
  if M.presetPanel then dismissPresetPanel() end   -- close the panel on a successful switch
  v, h = p.v or 0, p.h or 0
  for i = 1, 3 do slots[i] = (p.sourceNames and resolveSource(p.sourceNames[i])) or false end
  reclampFocus(0)
  applyComposition(true)   -- preset recall is the only path allowed to launch closed apps
  local src = slots[focus]
  if cells()[focus] and src then layouts.focusEntry({ app = src.app, prefer = src.prefer }) end
  -- Restore the preset's focus-mode (spotlight) state.
  M.spotlightOn = p.spotlight or false
  spotHidden = false
  if M.spotlightOn then drawSpotlight() else clearSpotlight() end
  flashSlotBounds()        -- always outline the applied layout, even if the shape is unchanged
  if not silent then drawMinimap() end
  if M.spotlightOn and not spotHidden then drawSpotlight() end
  persistState()
end

-- Switch to (recall) the armed preset. Assigns the forward-declared upvalue so
-- selectOrSwitch() above can reach it, now that recall() is in scope.
switchToArmed = function()
  if saveSel == "new" then newLayout(); return end
  local id = saveSel
  if not id or not savedPresets[id] then return end   -- nothing armed / empty slot
  dismissPresetPanel()
  recall(id, true)   -- silent: no minimap — the panel already showed the layout
end

-- Key handler: drives the panel AND consumes every *plain* key while it's open,
-- so no keystroke leaks to the focused app. Modified combos (⌃⌥⌘) pass through so
-- the global hotkeys still work — the ⌃⌥⌘+/ toggle, numpad recall, etc. Auto-
-- repeat keyDowns make press-and-hold on the arrows work for free.
M.keyTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
  local f = e:getFlags()
  if f.cmd or f.ctrl or f.alt then return false end   -- let modified shortcuts work
  local name = hs.keycodes.map[e:getKeyCode()]
  if name == "escape" then dismissPresetPanel()
  elseif name == "return" or name == "padenter" then switchToArmed()
  elseif name == "up" then armDelta(-1)
  elseif name == "down" then armDelta(1)
  elseif name == "s" then saveArmed()
  elseif name == "n" then selectOrNew()
  elseif name == "delete" or name == "forwarddelete" then clearArmed()
  else
    local digit = name and (name:match("^pad(%d)$") or name:match("^(%d)$"))
    local d = digit and tonumber(digit)
    if d and d >= 1 and d <= SAVE_SLOTS then selectOrSwitch(tostring(d)) end
  end
  return true   -- consume every plain key while the panel is open
end)

-- ============================================================================
-- WIRING
-- ============================================================================

hs.hotkey.bind(mod, "left",  navLeft)
hs.hotkey.bind(mod, "right", navRight)
hs.hotkey.bind(mod, "up",    navUp)
hs.hotkey.bind(mod, "down",  navDown)
hs.hotkey.bind(mod, ",", function() cycleSource(-1) end)
hs.hotkey.bind(mod, ".", function() cycleSource(1) end)

-- Space: TAP rotates the slots one position; HOLD (>0.3s) reverses them. On
-- press we arm a hold-timer that fires the reverse; on release, if that timer
-- hasn't fired yet, it was a tap → rotate.
local SPACE_HOLD = 0.3
local spaceReversed = false
hs.hotkey.bind(mod, "space",
  function()   -- pressed
    spaceReversed = false
    M.spaceTimer = hs.timer.doAfter(SPACE_HOLD, function()
      M.spaceTimer = nil
      spaceReversed = true
      reverseSlots()
    end)
  end,
  function()   -- released
    if M.spaceTimer then M.spaceTimer:stop(); M.spaceTimer = nil end
    if not spaceReversed then rotateSlots(1) end   -- quick tap → rotate
  end)

-- Repurpose the mouse's two side buttons (MX Master back/forward = buttons 3/4):
-- swallow their default back/forward and rotate the slots instead — forward
-- rotates right, back rotates left. Active globally.
M.mouseSideTap = hs.eventtap.new(
  { hs.eventtap.event.types.otherMouseDown, hs.eventtap.event.types.otherMouseUp },
  function(e)
    local btn = e:getProperty(hs.eventtap.event.properties.mouseEventButtonNumber)
    if btn == 3 or btn == 4 then
      if e:getType() == hs.eventtap.event.types.otherMouseDown then
        rotateSlots(btn == 4 and 1 or -1)   -- forward (4) → right, back (3) → left
      end
      return true   -- consume so it never acts as back/forward
    end
    return false
  end)
M.mouseSideTap:start()

-- Auto-retile: when a window OPENS or CLOSES for an app that's assigned to a
-- currently VISIBLE slot, re-tile that slot from the app's live window list — so a
-- window opened after the layout was applied joins its slot's stack instead of
-- floating, and a closed window lets the survivors re-slice to fill the gap
-- (matters most for the vertical-stack slot, e.g. Chrome for Testing). Pure
-- placement: it only re-tiles, never touching focus/state/overlays. Skipped while
-- F19-minimized (the composition isn't on screen) and for hidden slots (no
-- on-screen rect — the window is tiled when the geometry next reveals the slot).
-- Re-tiling targets the SAME rect the composer's own apply/launch would, so any
-- overlap (e.g. a preset recall launching the app) is an invisible no-op. Standard
-- + primary-display filtering falls out of windowsOfAll inside retileApp, and the
-- last window closing leaves zero windows → retileApp no-ops (the now-empty slot
-- collapses on the next composer action via pruneDeadSlots).
local function slotForApp(appName)
  for i = 1, 3 do
    if slots[i] and slots[i].app == appName then return i end
  end
  return nil
end

local function retileSlotForApp(_, appName)
  if layouts.minimized then return end
  local i = slotForApp(appName)
  if not i then return end
  local c = cells()[i]
  if not c then return end   -- slot hidden by the current geometry → leave the windows
  layouts.retileApp({ app = slots[i].app, rect = { c[1], 0, c[2], 1 }, stack = slots[i].stack })
end

local watchedApps = {}
for _, s in ipairs(sources) do watchedApps[#watchedApps + 1] = s.app end
M.newWindowFilter = hs.window.filter.new(watchedApps)
M.newWindowFilter:subscribe(
  { hs.window.filter.windowCreated, hs.window.filter.windowDestroyed },
  retileSlotForApp)

-- Pin/unpin the minimap (stays up until 'm' again or an arrow nav un-pins it).
hs.hotkey.bind(mod, "m", toggleMinimap)

-- Spotlight/focus mode: dim everything but the focused slot.
hs.hotkey.bind(mod, "f", toggleSpotlight)

-- Keep the focus cursor in sync with MANUAL focus changes: when you click or
-- Cmd-Tab to an app that lives in a visible slot, move the cursor there — so
-- ⌃⌥⌘←/→ and the spotlight navigate from where you actually are, not from
-- wherever the composer last parked the cursor. The composer's own moves always
-- activate the focused slot's app LAST, so this stays consistent during nav too;
-- activating a non-slot app is ignored (the cursor stays put).
M.focusSyncWatcher = hs.application.watcher.new(function(appName, eventType)
  if eventType ~= hs.application.watcher.activated then return end
  local slot
  for i = 1, 3 do
    if cells()[i] and slots[i] and slots[i].app == appName then slot = i; break end
  end
  if slot then focus = slot end          -- keep the nav cursor on the focused slot
  if not M.spotlightOn then return end
  if slot then
    spotHidden = false; drawSpotlight()  -- move/show the hole onto the activated slot
  else
    spotHidden = true; clearSpotlight()  -- activated a non-slot app → hide the dim
  end
end)
M.focusSyncWatcher:start()

-- Low-rate poll so the dim reacts to focus changes that emit NO app-activation
-- event — chiefly opening Ghostty's quick-terminal (a floating window inside the
-- already-frontmost Ghostty). No-ops instantly while focus mode is off.
M.spotlightPoll = hs.timer.doEvery(0.3, refreshSpotlight)

-- Jump straight to a fresh empty thirds (same as the panel's "New layout" row).
hs.hotkey.bind(mod, "n", newLayout)

-- Save: main-keyboard "/".
hs.hotkey.bind(mod, "/", saveCurrent)
-- Recall preset i with the numpad (padi).
for i = 1, SAVE_SLOTS do
  local id = tostring(i)
  hs.hotkey.bind(mod, "pad" .. i, function() recall(id) end)
end

-- Make minimize_layout aware of every source's app so the F19 toggle hides them.
for _, s in ipairs(sources) do
  layouts.handledSet[s.app] = true
end

-- Restore the last (v,h,focus,slots) from disk and re-apply it shortly after
-- load, so a Hammerspoon restart resumes the arrangement. The delay gives apps
-- still coming up at login a moment to register their windows before we decide
-- which slots are dead. Resume never launches — a slot whose app the user quit
-- collapses to empty (only preset recall opens closed apps).
local function resume()
  local st = hs.settings.get(STATE_KEY)
  if type(st) ~= "table" then return end
  v, h, focus = st.v or 0, st.h or 0, st.focus or 1
  for i = 1, 3 do slots[i] = (st.sourceNames and resolveSource(st.sourceNames[i])) or false end
  reclampFocus(0)
  M.resumeTimer = hs.timer.doAfter(0.6, function() applyComposition() end)
end
resume()

return M
