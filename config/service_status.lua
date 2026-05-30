-- Monitor critical services (GitHub, Claude, Jira, Slack). When any service is
-- degraded, show a floating pill at top-center of the main screen (overlapping
-- the menubar); click it to open the affected service's status page. When a
-- service recovers, show a "back up · was down for Xm · recovered at HH:MM PM"
-- pill that stays until dismissed (× button).

-- ============================================================================
-- CONFIG
-- ============================================================================

-- Each service: `parse(decoded)` returns `indicator, description`.
-- Statuspage indicators: none | minor | major | critical | maintenance.
local function statuspage(d)
  if not d or not d.status then return nil end
  return d.status.indicator or "none", d.status.description or "Unknown"
end

local function slackParser(d)
  if not d or not d.status then return nil end
  if d.status == "ok" or d.status == "active" then return "none", "All Systems Operational" end
  local desc = "Active incident"
  if d.active_incidents and d.active_incidents[1] and d.active_incidents[1].title then
    desc = d.active_incidents[1].title
  end
  return d.status, desc
end

local services = {
  { name = "GitHub", url = "https://www.githubstatus.com/api/v2/status.json", page = "https://www.githubstatus.com", parse = statuspage },
  { name = "Claude", url = "https://status.anthropic.com/api/v2/status.json", page = "https://status.anthropic.com", parse = statuspage },
  { name = "Jira",   url = "https://status.atlassian.com/api/v2/status.json", page = "https://status.atlassian.com", parse = statuspage },
  { name = "Slack",  url = "https://slack-status.com/api/v2.0.0/current",     page = "https://status.slack.com",     parse = slackParser },
}

local pollInterval = 60        -- seconds

local indicators = {
  none        = { red = 0.20, green = 0.78, blue = 0.35 },
  minor       = { red = 1.00, green = 0.80, blue = 0.20 },
  major       = { red = 1.00, green = 0.50, blue = 0.10 },
  critical    = { red = 0.95, green = 0.20, blue = 0.20 },
  maintenance = { red = 0.40, green = 0.60, blue = 0.95 },
}
local recoveredColor = indicators.none

local order = { none = 0, maintenance = 1, minor = 2, major = 3, critical = 4 }

-- ============================================================================
-- STATE
-- ============================================================================

-- name -> {
--   indicator, description, page, updatedAt,
--   downSince  = ts | nil,  -- when this outage began
--   recovered  = { downSince, recoveredAt, lastIndicator, lastDescription } | nil,
-- }
local state = {}
for _, s in ipairs(services) do
  state[s.name] = { indicator = "none", description = "All Systems Operational", page = s.page }
end

-- ----------------------------------------------------------------------------
-- Persistence (hs.settings, NSUserDefaults-backed). Saves only what can't be
-- recomputed: per-service `indicator`, `description`, `downSince`, and any
-- undismissed `recovered` notice. Indicator/description are kept so that on
-- next launch, a healthy poll cleanly transitions wasDown=true → recovered.
-- ----------------------------------------------------------------------------
local SETTINGS_KEY = "serviceStatus.persisted.v1"
local STALE_DOWN_SECS = 24 * 3600   -- drop persisted outage if older than this

local function saveState()
  local snap = {}
  for _, s in ipairs(services) do
    local st = state[s.name]
    snap[s.name] = {
      indicator   = st.indicator,
      description = st.description,
      downSince   = st.downSince,
      recovered   = st.recovered,
    }
  end
  hs.settings.set(SETTINGS_KEY, snap)
end

local function loadState()
  local snap = hs.settings.get(SETTINGS_KEY)
  if type(snap) ~= "table" then return end
  local now = os.time()
  for _, s in ipairs(services) do
    local saved = snap[s.name]
    if type(saved) == "table" then
      local st = state[s.name]
      -- Drop a stale outage entirely; the next poll authoritatively sets state.
      if saved.downSince and (now - saved.downSince) > STALE_DOWN_SECS then
        saved.indicator   = "none"
        saved.description = "All Systems Operational"
        saved.downSince   = nil
      end
      if saved.indicator   then st.indicator   = saved.indicator   end
      if saved.description then st.description = saved.description end
      if saved.downSince   then st.downSince   = saved.downSince   end
      if type(saved.recovered) == "table" then st.recovered = saved.recovered end
    end
  end
end

loadState()

local function fmtDuration(secs)
  if secs < 60 then return secs .. "s" end
  if secs < 3600 then
    local m = math.floor(secs / 60)
    local s = secs % 60
    if s == 0 then return m .. "m" end
    return m .. "m " .. s .. "s"
  end
  if secs < 86400 then
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if m == 0 then return h .. "h" end
    return h .. "h " .. m .. "m"
  end
  local d = math.floor(secs / 86400)
  local h = math.floor((secs % 86400) / 3600)
  if h == 0 then return d .. "d" end
  return d .. "d " .. h .. "h"
end

local function relativeTime(ts)
  if not ts then return "never" end
  local diff = os.time() - ts
  if diff < 5 then return "just now" end
  return fmtDuration(diff) .. " ago"
end

-- ============================================================================
-- MENUBAR-CENTER PILL
-- ----------------------------------------------------------------------------
-- macOS doesn't allow real menubar items in the middle, so this is a canvas
-- overlay positioned at top-center at the menubar's y-coordinate.
-- ============================================================================

-- pills[serviceName] -> hs.canvas
local pills = {}

-- Build the ordered list of pills to show. Down services first (worst first),
-- then undismissed recovery notices (most-recent recovery first).
local function pillTargets()
  local downs, recs = {}, {}
  for _, s in ipairs(services) do
    local st = state[s.name]
    if order[st.indicator] > 0 then
      table.insert(downs, { svc = s, kind = "down", ind = st.indicator })
    elseif st.recovered then
      table.insert(recs, { svc = s, kind = "recovered", ind = "none", recoveredAt = st.recovered.recoveredAt })
    end
  end
  table.sort(downs, function(a, b)
    if order[a.ind] ~= order[b.ind] then return order[a.ind] > order[b.ind] end
    return a.svc.name < b.svc.name
  end)
  table.sort(recs, function(a, b) return a.recoveredAt > b.recoveredAt end)
  for _, r in ipairs(recs) do table.insert(downs, r) end
  return downs
end

local function pillContent(target)
  local svc, kind, ind = target.svc, target.kind, target.ind
  local now = os.time()
  if kind == "down" then
    local st = state[svc.name]
    local downFor = st.downSince and fmtDuration(now - st.downSince) or "?"
    return {
      color    = indicators[ind],
      mainText = string.format("⚠  %s: %s", svc.name, st.description),
      subText  = string.format("down for %s · updated %s", downFor, relativeTime(st.updatedAt)),
      hasClose = false,
    }
  end
  local r = state[svc.name].recovered
  local wasDown = (r.downSince and r.recoveredAt) and fmtDuration(r.recoveredAt - r.downSince) or "?"
  local function clock(ts)
    if not ts then return "?" end
    local s = os.date("%I:%M %p", ts)
    return (s:sub(1,1) == "0") and s:sub(2) or s
  end
  return {
    color    = recoveredColor,
    mainText = string.format("✓  %s is back up", svc.name),
    subText  = string.format("was down for %s between %s – %s", wasDown, clock(r.downSince), clock(r.recoveredAt)),
    hasClose = true,
  }
end

local function measureWidth(text, size)
  local ok, s = pcall(function()
    return hs.drawing.getTextDrawingSize(text, { font = { name = "Helvetica", size = size } })
  end)
  if ok and s and s.w then return s.w end
  return #text * size * 0.6
end

local function buildPill(content, x, y, w, h)
  local color = content.color
  local canvas = hs.canvas.new({ x = x, y = y, w = w, h = h })
  canvas:level(hs.canvas.windowLevels.popUpMenu)
  canvas:behavior({ "canJoinAllSpaces", "stationary" })

  local elements = {
    { type = "rectangle", action = "strokeAndFill",
      fillColor   = { white = 0.08, alpha = 0.85 },
      strokeColor = { red = color.red, green = color.green, blue = color.blue, alpha = 0.5 },
      strokeWidth = 1,
      frame = { x = 0.5, y = 0.5, w = w - 1, h = h - 1 },
      roundedRectRadii = { xRadius = 8, yRadius = 8 } },
    { type = "text", text = content.mainText,
      textColor = { red = color.red, green = color.green, blue = color.blue, alpha = 1 },
      textSize = 13, textAlignment = "center",
      frame = { x = 12, y = 5, w = w - 24, h = 18 } },
    { type = "text", text = content.subText,
      textColor = { white = 0.55, alpha = 1 },
      textSize = 11, textAlignment = "center",
      frame = { x = 12, y = 24, w = w - 24, h = 16 } },
  }
  if content.hasClose then
    table.insert(elements, {
      type = "text", id = "close", text = "×",
      textColor = { white = 0.75, alpha = 1 },
      textSize = 18, textAlignment = "center",
      frame = { x = w - 28, y = 8, w = 22, h = 26 },
      trackMouseUp = true,
    })
  end
  canvas:replaceElements(elements)
  canvas:clickActivating(false)
  return canvas
end

local function renderCenterPill()
  local targets = pillTargets()
  -- Primary (menu-bar) screen, not mainScreen — mainScreen follows the focused
  -- window, so the pill would jump to a secondary display (e.g. iPad) when a
  -- window there gains focus.
  local screen = hs.screen.primaryScreen():fullFrame()
  local h, gap = 44, 4
  local minW, maxW = 240, math.min(520, screen.w - 40)
  local hPad = 24      -- text inset on each side combined
  local closePad = 24  -- extra room for × button

  local seen = {}
  for i, t in ipairs(targets) do
    local content = pillContent(t)
    local textW = math.max(measureWidth(content.mainText, 13),
                           measureWidth(content.subText, 11))
    local w = math.ceil(textW) + hPad + (content.hasClose and closePad or 0)
    if w < minW then w = minW end
    if w > maxW then w = maxW end
    local x = screen.x + (screen.w - w) / 2
    local y = screen.y + gap + (i - 1) * (h + gap)
    if pills[t.svc.name] then pills[t.svc.name]:delete() end
    local canvas = buildPill(content, x, y, w, h)
    canvas:mouseCallback(function(_, evt, id)
      if evt ~= "mouseUp" then return end
      if id == "close" then
        state[t.svc.name].recovered = nil
        saveState()
        renderCenterPill()
      else
        hs.urlevent.openURL(t.svc.page)
      end
    end)
    canvas:canvasMouseEvents(true, true)
    canvas:show()
    pills[t.svc.name] = canvas
    seen[t.svc.name] = true
  end
  -- Drop pills for services that no longer have a notice.
  for name, canvas in pairs(pills) do
    if not seen[name] then canvas:delete(); pills[name] = nil end
  end
end


-- ============================================================================
-- POLLING
-- ============================================================================

local function applyResult(s, indicator, description)
  local st = state[s.name]
  local wasDown = order[st.indicator] > 0
  local nowDown = order[indicator] > 0
  local now = os.time()

  st.indicator   = indicator
  st.description = description
  st.updatedAt   = now

  if nowDown then
    if not st.downSince then st.downSince = now end
    -- New outage cancels any prior undismissed recovery notice for this svc.
    st.recovered = nil
  else
    if wasDown and st.downSince then
      st.recovered = {
        downSince       = st.downSince,
        recoveredAt     = now,
        lastIndicator   = st.indicator,  -- already overwritten to "none"; ok
        lastDescription = description,
      }
    end
    st.downSince = nil
  end
end

local function poll()
  for _, s in ipairs(services) do
    hs.http.asyncGet(s.url, nil, function(status, body)
      if status ~= 200 or not body then return end
      local ok, decoded = pcall(hs.json.decode, body)
      if not ok then return end
      local indicator, description = s.parse(decoded)
      if not indicator then return end
      applyResult(s, indicator, description)
      saveState()
      renderCenterPill()
    end)
  end
end

-- Globals: top-level locals get reclaimed once `require` returns (see comment
-- in init.lua about configWatcher). hs.timer / hs.caffeinate.watcher need a
-- live reference to keep firing.
serviceStatusPollTimer    = hs.timer.new(pollInterval, poll)
serviceStatusPollTimer:start()
poll()

-- Re-render every 5s so "down for Xm Ys" / "recovered Xm ago" stays fresh.
serviceStatusRefreshTimer = hs.timer.doEvery(5, renderCenterPill)

-- Timers pause during system sleep, so re-poll immediately on wake.
serviceStatusWakeWatcher = hs.caffeinate.watcher.new(function(event)
  local w = hs.caffeinate.watcher
  if event == w.systemDidWake or event == w.screensDidUnlock or event == w.screensDidWake then
    poll()
  end
end)
serviceStatusWakeWatcher:start()
