-- Shared HUD / notification stacker.
--
-- The problem this solves: each status tool (service_status, bm_tradein_status,
-- …) used to draw its own canvas pill at top-center of the primary screen, with
-- no awareness of the others — so two active pills rendered on top of each
-- other. This module owns the *placement and rendering* of those pills. Tools
-- stop drawing canvases and instead register a notice; the notifier lays all
-- active notices out in a vertical stack within a zone, so they never collide.
--
-- Usage:
--   local hud = require("config.notifier")
--   hud.register("service:GitHub", {
--     zone  = "top",                       -- placement zone (see ZONES below)
--     build = function()                   -- called on every render; return a
--       if healthy then return nil end     -- content table, or nil to hide
--       return {
--         color    = { red = .95, green = .2, blue = .2 },
--         icon     = "⚠",                  -- glyph in the left margin (optional)
--         mainText = "GitHub: ...",
--         subText  = "down for 4m · updated just now",
--         sort     = 2e12 + 4,             -- higher = nearer the top of the zone
--         hasClose = false,                -- show a × dismiss button
--         onClick  = function() ... end,   -- row click (anywhere but a button/×)
--         onClose  = function() ... end,   -- × click; caller mutates its state
--         buttons  = {                     -- explicit right-aligned tap targets;
--           { text = "Ack", onClick = fn,  -- a primary action that must NOT fire
--             color = theme.ACCENT },      -- from an accidental body click
--         },
--       }
--     end,
--   })
--   hud.refresh()        -- re-render now (after a poll changes state)
--   hud.unregister(id)   -- remove a notice entirely
--
-- `build` reads the caller's live state, so the notifier can re-render on its
-- own cadence (to keep "down for Xm" fresh) and on screen-config changes without
-- the caller pushing new content each time.

local theme = require("config.theme")

local M = {}

-- ============================================================================
-- SHARED TIME HELPERS
-- ----------------------------------------------------------------------------
-- Exported so consumers build their pill text consistently instead of each
-- module carrying its own copy (they previously did, verbatim).
-- ============================================================================

function M.fmtDuration(secs)
  if secs < 0 then secs = 0 end
  if secs < 60 then return secs .. "s" end
  if secs < 3600 then
    local m = math.floor(secs / 60)
    return (secs % 60 == 0) and (m .. "m") or (m .. "m " .. (secs % 60) .. "s")
  end
  if secs < 86400 then
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    return (m == 0) and (h .. "h") or (h .. "h " .. m .. "m")
  end
  local d = math.floor(secs / 86400)
  local h = math.floor((secs % 86400) / 3600)
  return (h == 0) and (d .. "d") or (d .. "d " .. h .. "h")
end

function M.relativeTime(ts)
  if not ts then return "never" end
  local diff = os.time() - ts
  if diff < 5 then return "just now" end
  return M.fmtDuration(diff) .. " ago"
end

-- 12-hour clock with no leading zero (e.g. "3:07 PM").
function M.clock(ts)
  if not ts then return "?" end
  local s = os.date("%I:%M %p", ts)
  return (s:sub(1, 1) == "0") and s:sub(2) or s
end

-- ============================================================================
-- PILL GEOMETRY / RENDERING
-- ============================================================================

-- Composer-style "HUD material" pill: a translucent charcoal row with a hairline
-- top-light edge and a soft drop shadow (see config.theme). A rounded status
-- badge on the left carries the icon in the status color; the title (SF Pro
-- Semibold) and subtext (SF Pro Regular) are left-aligned beside it. The content
-- row is laid out left-to-right:
--   [LPAD] [badge] [BGAP] [ title / subtext ] [buttons] [RPAD]   (× overhangs corner)
-- A dismissable pill also gets a small round × overhanging the top-right corner
-- (native-notification style) — an overlay, so it costs no content column.
--
-- The shadow needs empty canvas around the row to render (it clips to canvas
-- bounds), so each pill's canvas is the row inset by MARGIN on every side. Zone
-- layout works in INNER-row coordinates; buildPill expands the canvas.

local PILL_H   = 48
local MARGIN   = 14      -- transparent canvas border for the drop shadow
local GAP      = 14      -- vertical gap between rows (>= MARGIN so a row's shadow
                         -- canvas never overlaps a neighbor's interactive area)
local MIN_W    = 200     -- floor so a 1-word pill isn't tiny; most pills exceed it
local MAX_W    = 560     -- capped further to screen width at layout time
local RADIUS   = 13      -- pill corner radius

local LPAD, RPAD       = 12, 14
local BADGE, BADGE_RAD = 26, 8
local BGAP             = 10     -- gap between badge and text
-- Dismiss button: a small round × that floats on / overhangs the top-right corner
-- (like a native macOS notification). Because it overhangs into the shadow margin
-- rather than sitting inline, it needs no horizontal reserve in the content row —
-- the normal RPAD already keeps a full-width title clear of it.
local CLOSE_R = 9

-- Action buttons: optional pill-shaped tap targets on the right of the row
-- (content.buttons = { { text, onClick, color?, textColor? }, ... }), right-
-- aligned and left of the corner ×. Explicit hit targets, so a primary action
-- (e.g. "Ack") can't be triggered by an accidental click on the body.
local BTN_H    = 26
local BTN_PADX = 12     -- horizontal text padding inside a button
local BTN_GAP  = 8      -- gap between adjacent buttons
local BTN_LEAD = 12     -- gap between the text block and the first button
local BTN_RAD  = 7
local BTN_SIZE = 12     -- button label font size

local function measureWidth(text, size, font)
  local ok, s = pcall(function()
    local st = hs.styledtext.new(text, { font = { name = font, size = size } })
    return hs.drawing.getTextDrawingSize(st)
  end)
  if ok and s and s.w then return s.w end
  return #text * size * 0.62
end

-- Horizontal extents reserved beside the text, given the content.
local function badgeArea(content) return content.icon and (BADGE + BGAP) or 0 end

-- Measure each action button and the total horizontal span they occupy: button
-- widths + inter-button gaps + the lead gap to the text block. Returns the
-- per-button list (with computed widths and original indices, used to map clicks
-- back to handlers) and that total; empty / zero when no buttons are defined.
local function buttonList(content)
  if type(content.buttons) ~= "table" or #content.buttons == 0 then return {}, 0 end
  local list, total = {}, 0
  for i, b in ipairs(content.buttons) do
    local w = math.ceil(measureWidth(b.text, BTN_SIZE, theme.FONT_SEMIBOLD)) + 2 * BTN_PADX
    list[i] = { text = b.text, w = w, color = b.color, textColor = b.textColor, index = i }
    total = total + w
  end
  total = total + BTN_GAP * (#list - 1) + BTN_LEAD
  return list, total
end

-- Build a pill canvas for the given INNER row frame. The canvas itself is grown
-- by MARGIN on each side so the shadow has room.
local function buildPill(content, frame)
  local w, h = frame.w, frame.h
  local cv = hs.canvas.new({
    x = frame.x - MARGIN, y = frame.y - MARGIN, w = w + 2 * MARGIN, h = h + 2 * MARGIN,
  })
  cv:level(hs.canvas.windowLevels.popUpMenu)
  cv:behavior({ "canJoinAllSpaces", "stationary" })

  local ox, oy = MARGIN, MARGIN                 -- inner row origin within canvas
  local btns, btnsW = buttonList(content)
  local textX  = ox + LPAD + badgeArea(content)
  -- The corner × overhangs the margin (no inline reserve); RPAD alone clears it.
  local textW  = w - LPAD - badgeArea(content) - btnsW - RPAD

  local els = {
    -- Row background: charcoal HUD material + hairline + soft shadow.
    { type = "rectangle", action = "strokeAndFill", id = "body",
      fillColor = theme.PANEL_FILL, strokeColor = theme.HAIRLINE, strokeWidth = 1,
      shadow = theme.SHADOW_SM,
      frame = { x = ox, y = oy, w = w, h = h },
      roundedRectRadii = { xRadius = RADIUS, yRadius = RADIUS } },
    -- Title + subtext, left-aligned beside the badge. truncateTail so an
    -- over-long line fills its frame and ends in "…" — the default (wordWrap) on a
    -- single-line frame truncates at the last whole word, leaving a ragged gap.
    { type = "text", text = content.mainText, textLineBreak = "truncateTail",
      textColor = theme.TEXT, textFont = theme.FONT_SEMIBOLD, textSize = 13,
      textAlignment = "left",
      frame = { x = textX, y = oy + 8, w = textW, h = 18 } },
    { type = "text", text = content.subText, textLineBreak = "truncateTail",
      textColor = theme.TEXT_DIM, textFont = theme.FONT_REGULAR, textSize = 11,
      textAlignment = "left",
      frame = { x = textX, y = oy + 27, w = textW, h = 15 } },
  }

  -- Status badge (rounded square in the status color) with a white glyph — the
  -- same badge treatment as composer's preset number badges. Giving the glyph a
  -- fixed box sidesteps the per-glyph centering issues of a bare icon.
  if content.icon then
    local bx, by = ox + LPAD, oy + (h - BADGE) / 2
    els[#els + 1] = { type = "rectangle", action = "fill", fillColor = content.color,
      frame = { x = bx, y = by, w = BADGE, h = BADGE },
      roundedRectRadii = { xRadius = BADGE_RAD, yRadius = BADGE_RAD } }
    els[#els + 1] = { type = "text", text = content.icon,
      textColor = { white = 1, alpha = 1 }, textFont = theme.FONT_SEMIBOLD, textSize = 14,
      textAlignment = "center",
      frame = { x = bx, y = by + 4, w = BADGE, h = 18 } }
  end

  -- (Action buttons are rendered last — see below — so they sit on top of the
  -- hover rectangle and can own their own enter/exit for a hover highlight.)

  -- Dismiss control: a small round × floating on the top-right corner, overhanging
  -- outside the pill like a native macOS notification's close button (the canvas is
  -- grown by MARGIN on every side for the shadow, which gives the overhang room to
  -- draw). A frosted-dark fill + hairline rim let it read over both the pill and
  -- the wallpaper it overhangs. It starts hidden (action "skip") and fades in while
  -- hovered. Hover and click are split across two invisible elements:
  --   • a single hover rectangle covering the entire pill + corner overhang, so
  --     hovering anywhere reveals the × with NO gaps to flicker through (one
  --     rectangle, not a union of body + box + circle). It tracks enter/exit only,
  --     so clicks fall through it to the body / buttons / the × hit box below.
  --   • a small corner hit box (trackMouseUp) that owns the dismiss click, kept
  --     just right of the button row so it never steals a button click.
  local closeIdx
  if content.hasClose then
    local cx, cy = ox + w - 2, oy + 2

    -- Hover region: ONE rectangle covering the entire pill plus the top/right corner
    -- overhang. Because it's a single contiguous shape (not a union of body + box +
    -- circle), there are no internal edges to cross, so the × can't flicker as the
    -- cursor moves anywhere over the pill or up to the corner — it only hides when
    -- the cursor leaves this whole region. enter/exit only, so clicks fall through
    -- it to the body / buttons / the × hit box below.
    els[#els + 1] = { type = "rectangle", action = "fill",
      fillColor = { alpha = 0 },
      frame = { x = ox, y = oy - 8, w = w + 8, h = h + 8 },
      trackMouseEnterExit = true }

    -- Dismiss hit target over the × (click only; hover handled above).
    els[#els + 1] = { type = "rectangle", action = "fill", id = "close",
      fillColor = { alpha = 0 },
      frame = { x = ox + w - 13, y = oy - 12, w = 25, h = 28 },
      trackMouseUp = true }

    els[#els + 1] = { type = "circle", action = "skip",     -- visual only; revealed on hover
      fillColor = { white = CLOSE_FILL_W, alpha = 0 },
      strokeColor = { white = 1, alpha = 0 }, strokeWidth = 1,
      center = { x = cx, y = cy }, radius = CLOSE_R }
    local circleIdx = #els
    els[#els + 1] = { type = "text", action = "skip", text = "×",
      textColor = { white = CLOSE_TEXT_W, alpha = 1 }, textFont = theme.FONT_REGULAR, textSize = 13,
      textAlignment = "center",
      frame = { x = cx - CLOSE_R, y = cy - 8, w = 2 * CLOSE_R, h = 16 } }
    closeIdx = { circle = circleIdx, text = #els }
  end

  -- Action buttons, rendered last so they sit on top of the hover rectangle and
  -- own their own enter/exit (for the hover highlight). Right-aligned, left of the
  -- corner ×. The rounded fill (id "btn:N") is the hit + hover target; the centered
  -- label on top is click-through. Canvas text is top-aligned, so the label y
  -- offset optically centers a BTN_SIZE line within BTN_H.
  if #btns > 0 then
    local buttonsOnlyW = btnsW - BTN_LEAD
    local bx2 = ox + w - RPAD - buttonsOnlyW
    local by2 = oy + (h - BTN_H) / 2
    for _, b in ipairs(btns) do
      els[#els + 1] = { type = "rectangle", action = "fill", id = "btn:" .. b.index,
        fillColor = b.color or { white = 1, alpha = 0.16 },
        frame = { x = bx2, y = by2, w = b.w, h = BTN_H },
        roundedRectRadii = { xRadius = BTN_RAD, yRadius = BTN_RAD },
        trackMouseUp = true, trackMouseEnterExit = true }
      els[#els + 1] = { type = "text", action = "fill", text = b.text,
        textColor = b.textColor or theme.TEXT,
        textFont = theme.FONT_SEMIBOLD, textSize = BTN_SIZE, textAlignment = "center",
        frame = { x = bx2, y = by2 + 7, w = b.w, h = BTN_SIZE + 4 } }
      bx2 = bx2 + b.w + BTN_GAP
    end
  end

  cv:replaceElements(els)
  cv:clickActivating(false)
  return cv, closeIdx
end

-- Inner-row width from the content, clamped to the zone's bounds.
local function pillWidth(content, maxW)
  local _, btnsW = buttonList(content)
  local textW = math.max(measureWidth(content.mainText, 13, theme.FONT_SEMIBOLD),
                         measureWidth(content.subText, 11, theme.FONT_REGULAR))
  local w = LPAD + badgeArea(content) + math.ceil(textW) + btnsW + RPAD
  return math.max(MIN_W, math.min(maxW, w))
end

-- ============================================================================
-- ZONES
-- ----------------------------------------------------------------------------
-- A zone places a vertically-ordered list of pills. `frame(i, w, screen)`
-- returns the INNER-row frame for the i-th pill (widths can differ per pill);
-- buildPill expands the canvas by MARGIN around it for the shadow. Only "top"
-- exists today; add others (e.g. "bottom-right") here and notices opt in via
-- their `zone` field.
-- ============================================================================

local ZONES = {
  top = {
    maxW  = function(s) return math.min(MAX_W, s.w - 40) end,
    frame = function(i, w, screen)
      return {
        x = screen.x + (screen.w - w) / 2,
        -- First row inset by MARGIN so its shadow canvas starts at the screen top.
        y = screen.y + MARGIN + (i - 1) * (PILL_H + GAP),
        w = w,
        h = PILL_H,
      }
    end,
  },
}

-- ============================================================================
-- REGISTRY + RENDER
-- ============================================================================

-- id -> { zone, build, seq }
local notices = {}
local seqCounter = 0
-- id -> hs.canvas currently on screen
local canvases = {}

-- Use the primary (menu-bar) screen, never mainScreen: mainScreen follows the
-- focused window, so the stack would jump to a secondary display when a window
-- there gains focus.
local function primaryFrame()
  return hs.screen.primaryScreen():fullFrame()
end

-- Fade the dismiss × in/out on hover instead of popping it. hs.canvas can only
-- fade a whole canvas, so we step the circle-fill and ×-text alpha over
-- theme.FADE_IN with a short timer. One timer per id (re-entry cancels the prior
-- run); pcall-guarded since a render() rebuild can delete the canvas mid-fade.
-- Floating corner × styling: a frosted-dark circle (so it reads over both the
-- pill and the wallpaper it overhangs) with a light glyph and a hairline rim.
local CLOSE_FILL_W   = 0.22        -- circle fill white level
local CLOSE_FILL_A   = 0.95        -- circle fill alpha when fully shown
local CLOSE_STROKE_A = 0.25        -- rim hairline alpha when fully shown
local CLOSE_TEXT_W   = 0.95        -- × glyph white level
local closeAnim  = {}              -- id -> hs.timer (fade in/out)
local closeShown = {}             -- id -> bool: is the × currently revealed (position-based)
local closeHideTimer = {}          -- id -> hs.timer (debounced hide; see makeMouseCallback)

-- Lighten a button fill for its hover state: nudge a white-keyed fill more opaque,
-- or blend an rgb fill toward white.
local function brighten(c)
  if c.white ~= nil then
    return { white = c.white, alpha = math.min(1, (c.alpha or 1) + 0.14) }
  end
  return { red = c.red + (1 - c.red) * 0.2, green = c.green + (1 - c.green) * 0.2,
           blue = c.blue + (1 - c.blue) * 0.2, alpha = c.alpha or 1 }
end

-- Set the fillColor of the element carrying the given id (elements are addressed
-- by index, so scan — a pill has only a handful of elements).
local function setFillById(canvas, elId, color)
  for i = 1, canvas:elementCount() do
    if canvas:elementAttribute(i, "id") == elId then
      canvas:elementAttribute(i, "fillColor", color); return
    end
  end
end

local function stopCloseAnim(id)
  if closeAnim[id] then closeAnim[id]:stop(); closeAnim[id] = nil end
  if closeHideTimer[id] then closeHideTimer[id]:stop(); closeHideTimer[id] = nil end
end

local function fadeClose(id, canvas, closeIdx, show)
  if not closeIdx then return end
  stopCloseAnim(id)
  canvas:elementAttribute(closeIdx.circle, "action", "strokeAndFill")
  canvas:elementAttribute(closeIdx.text, "action", "fill")
  -- Start a reveal from fully transparent so the first frame doesn't flash at
  -- full opacity (the built element still carries its solid alpha).
  if show then
    canvas:elementAttribute(closeIdx.circle, "fillColor", { white = CLOSE_FILL_W, alpha = 0 })
    canvas:elementAttribute(closeIdx.circle, "strokeColor", { white = 1, alpha = 0 })
    canvas:elementAttribute(closeIdx.text, "textColor", { white = CLOSE_TEXT_W, alpha = 0 })
  end
  local steps, i = 8, 0
  local timer
  timer = hs.timer.doEvery(theme.FADE_IN / 8, function()
    i = i + 1
    local f = show and (i / steps) or (1 - i / steps)
    local ok = pcall(function()
      canvas:elementAttribute(closeIdx.circle, "fillColor", { white = CLOSE_FILL_W, alpha = CLOSE_FILL_A * f })
      canvas:elementAttribute(closeIdx.circle, "strokeColor", { white = 1, alpha = CLOSE_STROKE_A * f })
      canvas:elementAttribute(closeIdx.text, "textColor", { white = CLOSE_TEXT_W, alpha = f })
    end)
    if (not ok) or i >= steps then
      timer:stop()
      if closeAnim[id] == timer then closeAnim[id] = nil end
      -- When fully hidden, skip drawing/hit-testing so a stray corner click
      -- isn't treated as a dismiss.
      if not show then
        pcall(function()
          canvas:elementAttribute(closeIdx.circle, "action", "skip")
          canvas:elementAttribute(closeIdx.text, "action", "skip")
        end)
      end
    end
  end)
  closeAnim[id] = timer
end

-- Show the × immediately at full opacity, no fade. Used when a canvas is rebuilt
-- (the 5s relative-time refresh) while the cursor is already over the pill — a
-- fadeClose here would re-animate the fade-in every rebuild and read as a flash.
local function showCloseInstant(id, canvas, closeIdx)
  if not closeIdx then return end
  stopCloseAnim(id)
  pcall(function()
    canvas:elementAttribute(closeIdx.circle, "action", "strokeAndFill")
    canvas:elementAttribute(closeIdx.circle, "fillColor", { white = CLOSE_FILL_W, alpha = CLOSE_FILL_A })
    canvas:elementAttribute(closeIdx.circle, "strokeColor", { white = 1, alpha = CLOSE_STROKE_A })
    canvas:elementAttribute(closeIdx.text, "action", "fill")
    canvas:elementAttribute(closeIdx.text, "textColor", { white = CLOSE_TEXT_W, alpha = 1 })
  end)
end

-- Is the cursor within a pill's hover region (the pill + corner overhang)? Derived
-- from the live canvas frame so it matches the hover rectangle's bounds (canvas
-- inset by MARGIN, then the rect's +8 right / -8 top overhang).
local function mouseInHoverRegion(canvas)
  local f = canvas:frame()
  local m = hs.mouse.absolutePosition()
  return m.x >= f.x + MARGIN and m.x <= f.x + f.w - MARGIN + 8
     and m.y >= f.y + MARGIN - 8 and m.y <= f.y + f.h - MARGIN
end

local function makeMouseCallback(id, closeIdx)
  return function(canvas, evt, elementId)
    -- Reveal the × while the cursor is over the pill / corner. Determined by the
    -- cursor's actual POSITION (not a ref-count): on any boundary event from the
    -- hover rect or a button, re-check whether it's inside the hover region. This
    -- is immune to which element fired and to the 5s canvas rebuild (a ref-count
    -- would desync there — the prior cause of a flash on the first move after a
    -- rebuild). fadeClose(show) resets opacity to 0 and fades up, so only call it
    -- on a genuine hidden→shown edge; closeShown tracks that.
    local isBtn = type(elementId) == "string" and elementId:match("^btn:%d+$") ~= nil
    if evt == "mouseEnter" or evt == "mouseExit" then
      local inside = mouseInHoverRegion(canvas)
      if inside and not closeShown[id] then
        closeShown[id] = true
        if closeHideTimer[id] then closeHideTimer[id]:stop(); closeHideTimer[id] = nil end
        fadeClose(id, canvas, closeIdx, true)
      elseif (not inside) and closeShown[id] then
        if closeHideTimer[id] then closeHideTimer[id]:stop() end
        closeHideTimer[id] = hs.timer.doAfter(0.06, function()
          closeHideTimer[id] = nil
          if not mouseInHoverRegion(canvas) then
            closeShown[id] = false
            fadeClose(id, canvas, closeIdx, false)
          end
        end)
      end
      -- Button hover highlight: brighten on enter, restore its base fill on exit.
      if isBtn then
        local n = notices[id]
        local content = n and n.build()
        local idx = tonumber(elementId:match("^btn:(%d+)$"))
        local base = (content and content.buttons and content.buttons[idx] and content.buttons[idx].color)
                     or { white = 1, alpha = 0.16 }
        setFillById(canvas, elementId, (evt == "mouseEnter") and brighten(base) or base)
      end
      return
    end
    if evt ~= "mouseUp" then return end
    -- Re-read content at click time; state may have changed since render.
    local n = notices[id]
    if not n then return end
    local content = n.build()
    if not content then return end
    if elementId == "close" then
      if content.onClose then content.onClose() end
      M.render()
    elseif type(elementId) == "string" and elementId:match("^btn:%d+$") then
      -- Index into the live content's buttons (built this click), so a handler
      -- that mutates state and a follow-up render reflect it immediately.
      local idx = tonumber(elementId:match("^btn:(%d+)$"))
      local b = idx and content.buttons and content.buttons[idx]
      if b and b.onClick then b.onClick(); M.render() end
    elseif content.onClick then
      content.onClick()
    end
  end
end

function M.render()
  local screen = primaryFrame()

  -- Collect active notices per zone.
  local byZone = {}
  for id, n in pairs(notices) do
    local content = n.build()
    if content then
      local z = ZONES[n.zone] and n.zone or "top"
      byZone[z] = byZone[z] or {}
      table.insert(byZone[z], { id = id, seq = n.seq, content = content })
    end
  end

  local live = {}   -- ids that should remain on screen this pass

  for zoneName, items in pairs(byZone) do
    local zone = ZONES[zoneName]
    local maxW = zone.maxW(screen)
    -- Higher `sort` sits nearer the top; ties fall back to registration order
    -- so ordering is stable frame-to-frame.
    table.sort(items, function(a, b)
      local sa, sb = a.content.sort or 0, b.content.sort or 0
      if sa ~= sb then return sa > sb end
      return a.seq < b.seq
    end)
    for i, item in ipairs(items) do
      local w = pillWidth(item.content, maxW)
      local frame = zone.frame(i, w, screen)
      -- Rebuild the canvas each pass (cheap, few pills) so geometry/content
      -- always reflect current state; delete the previous one to avoid leaks.
      if canvases[item.id] then stopCloseAnim(item.id); canvases[item.id]:delete() end
      local canvas, closeIdx = buildPill(item.content, frame)
      canvas:mouseCallback(makeMouseCallback(item.id, closeIdx))
      canvas:canvasMouseEvents(true, true)
      canvas:show()
      canvases[item.id] = canvas
      -- A fresh canvas starts with the × hidden and no live enter events yet. If
      -- the cursor is already within the hover region (e.g. the 5s refresh rebuilt
      -- the canvas mid-hover), pre-reveal it instantly so it neither blinks off nor
      -- re-animates a fade; otherwise leave it hidden.
      closeShown[item.id] = false
      if item.content.hasClose and closeIdx and mouseInHoverRegion(canvas) then
        closeShown[item.id] = true
        showCloseInstant(item.id, canvas, closeIdx)   -- instant, not faded, to avoid a per-rebuild flash
      end
      live[item.id] = true
    end
  end

  -- Drop canvases for notices that are no longer active.
  for id, canvas in pairs(canvases) do
    if not live[id] then stopCloseAnim(id); closeShown[id] = nil; canvas:delete(); canvases[id] = nil end
  end
end

-- Public alias; callers say hud.refresh() after a poll changes their state.
M.refresh = M.render

-- Introspection: the frames of the pills currently on screen, sorted top-down.
-- Handy when debugging a new notice or confirming pills stack without overlap.
function M.debugSnapshot()
  local out = {}
  for id, canvas in pairs(canvases) do
    local f = canvas:frame()
    -- Report the inner row, not the shadow-margin canvas.
    table.insert(out, { id = id, x = f.x + MARGIN, y = f.y + MARGIN,
                        w = f.w - 2 * MARGIN, h = f.h - 2 * MARGIN })
  end
  table.sort(out, function(a, b) return a.y < b.y end)
  return out
end

-- ----------------------------------------------------------------------------
-- Registration
-- ----------------------------------------------------------------------------

-- opts = { zone = "top", build = function() return content|nil end }
function M.register(id, opts)
  assert(type(id) == "string", "notifier.register: id must be a string")
  assert(type(opts) == "table" and type(opts.build) == "function",
         "notifier.register: opts.build must be a function")
  if notices[id] then
    -- Re-registering (e.g. config reload) keeps the original ordering slot.
    notices[id].zone  = opts.zone or "top"
    notices[id].build = opts.build
  else
    seqCounter = seqCounter + 1
    notices[id] = { zone = opts.zone or "top", build = opts.build, seq = seqCounter }
  end
  M.render()
end

function M.unregister(id)
  notices[id] = nil
  stopCloseAnim(id)
  closeShown[id] = nil
  if canvases[id] then canvases[id]:delete(); canvases[id] = nil end
  M.render()
end

-- ----------------------------------------------------------------------------
-- Self-test
-- ----------------------------------------------------------------------------

-- Fire three sample pills — a failure and a recovery (both dismissable) plus a
-- click-only pill with no × — to eyeball the HUD: styling, the badge, the ×, and
-- that notices stack instead of overlapping. They auto-clear after `secs`
-- (default 6); the × dismisses one early. Trigger from a terminal:
--   hs -c 'require("config.notifier").test()'
-- or bind a hotkey to require("config.notifier").test.
function M.test(secs)
  secs = secs or 6

  M.register("__test:fail", { zone = "top", build = function()
    return {
      color    = theme.RED,
      icon     = "⚠",
      mainText = "Test notification (failure)",
      subText  = "explicit buttons + body click + × dismiss",
      sort     = 9e12,   -- above any real notice, so the test sits on top
      hasClose = true,
      onClick  = function() hs.alert.show("notifier test: BODY clicked") end,
      onClose  = function() M.unregister("__test:fail") end,
      buttons  = {
        { text = "Ack",  color = theme.ACCENT,
          onClick = function() hs.alert.show("notifier test: ACK button") end },
        { text = "Later",
          onClick = function() hs.alert.show("notifier test: LATER button") end },
      },
    }
  end })

  M.register("__test:ok", { zone = "top", build = function()
    return {
      color    = theme.GREEN,
      icon     = "✓",
      mainText = "Test notification (recovered)",
      subText  = "second pill — confirms vertical stacking",
      sort     = 8e12,
      hasClose = true,
      onClose  = function() M.unregister("__test:ok") end,
    }
  end })

  M.register("__test:noclose", { zone = "top", build = function()
    return {
      color    = theme.AMBER,
      icon     = "⚠",
      mainText = "Test notification (no dismiss)",
      subText  = "click-only pill · no × button",
      sort     = 7e12,
      hasClose = false,
      onClick  = function() hs.alert.show("notifier test: pill clicked") end,
    }
  end })

  -- Module-scoped so a re-run cancels the prior auto-clear instead of leaking
  -- a timer; doAfter also keeps it alive until it fires.
  if M._testTimer then M._testTimer:stop() end
  M._testTimer = hs.timer.doAfter(secs, function()
    M.unregister("__test:fail")
    M.unregister("__test:ok")
    M.unregister("__test:noclose")
  end)
end

-- ============================================================================
-- CENTRAL TIMERS / WATCHERS
-- ----------------------------------------------------------------------------
-- One refresh timer for ALL notices (replaces each module's own). Keeps
-- relative-time text ("down for Xm", "last run Xm ago") current. Re-render on
-- screen-config changes so the stack re-centers when displays change.
--
-- Globals so they survive past require() (see init.lua note on configWatcher):
-- a top-level local would be reclaimed once this module finishes loading. On
-- reload we stop the prior instances first to avoid duplicate timers.
-- ============================================================================

if notifierRefreshTimer then notifierRefreshTimer:stop() end
notifierRefreshTimer = hs.timer.doEvery(5, M.render)

if notifierScreenWatcher then notifierScreenWatcher:stop() end
notifierScreenWatcher = hs.screen.watcher.new(M.render)
notifierScreenWatcher:start()

return M
