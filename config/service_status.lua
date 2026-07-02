-- Monitor critical services (GitHub, Claude, Jira, Slack). When any service is
-- degraded, show a floating pill at top-center of the main screen (overlapping
-- the menubar); click it to open the affected service's status page. When a
-- service recovers, show a "back up · was down for Xm · recovered at HH:MM PM"
-- pill that stays until dismissed (× button).
--
-- Rendering/placement is delegated to config.notifier (the shared HUD), which
-- stacks this module's pills together with any other tool's so they never
-- overlap. This file owns only the polling, state, and persistence.

local hud = require("config.notifier")

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

-- Alphabetical rank per service (A=1). Folded into the pill `sort` weight so
-- that, among equally-severe outages, pills order by name — matching the
-- pre-HUD behavior, where the notifier otherwise breaks ties by registration.
local alphaRank = {}
do
  local names = {}
  for _, s in ipairs(services) do table.insert(names, s.name) end
  table.sort(names)
  for i, n in ipairs(names) do alphaRank[n] = i end
end

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
local SNOOZE_SECS = 30 * 60         -- × on an outage hides it for this long

local function saveState()
  local snap = {}
  for _, s in ipairs(services) do
    local st = state[s.name]
    snap[s.name] = {
      indicator    = st.indicator,
      description  = st.description,
      downSince    = st.downSince,
      recovered    = st.recovered,
      snoozedUntil = st.snoozedUntil,
      snoozedOrder = st.snoozedOrder,
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
        saved.indicator    = "none"
        saved.description  = "All Systems Operational"
        saved.downSince    = nil
        saved.snoozedUntil = nil
        saved.snoozedOrder = nil
      end
      if saved.indicator   then st.indicator   = saved.indicator   end
      if saved.description then st.description = saved.description end
      if saved.downSince   then st.downSince   = saved.downSince   end
      if type(saved.recovered) == "table" then st.recovered = saved.recovered end
      if saved.snoozedUntil then st.snoozedUntil = saved.snoozedUntil end
      if saved.snoozedOrder then st.snoozedOrder = saved.snoozedOrder end
    end
  end
end

loadState()

-- ============================================================================
-- HUD NOTICES
-- ----------------------------------------------------------------------------
-- One notice per service. `build` reads live state and returns the pill content
-- (or nil when the service is healthy with no undismissed recovery notice).
-- The HUD calls build on every render, so relative-time text stays fresh.
-- ============================================================================

local function buildContent(s)
  local st = state[s.name]
  local now = os.time()

  if order[st.indicator] > 0 then
    -- Snoozed (× pressed): hide until the deadline, then the HUD's refresh timer
    -- brings it back if still down. A fresh or worse outage clears the snooze
    -- (see applyResult), so escalations always resurface.
    if st.snoozedUntil and now < st.snoozedUntil then return nil end
    local downFor = st.downSince and hud.fmtDuration(now - st.downSince) or "?"
    return {
      color    = indicators[st.indicator],
      icon     = "⚠",
      mainText = string.format("%s: %s", s.name, st.description),
      subText  = string.format("down for %s · updated %s", downFor, hud.relativeTime(st.updatedAt)),
      hasClose = true,
      -- Worst outage nearest the top; equal severity ordered by name (alphaRank).
      sort     = 2e12 + order[st.indicator] * 1000 - alphaRank[s.name],
      onClick  = function() hs.urlevent.openURL(s.page) end,
      onClose  = function()
        st.snoozedUntil = os.time() + SNOOZE_SECS
        st.snoozedOrder = order[st.indicator]   -- so a worse severity un-snoozes
        saveState()
      end,
    }
  end

  if st.recovered then
    local r = st.recovered
    local wasDown = (r.downSince and r.recoveredAt) and hud.fmtDuration(r.recoveredAt - r.downSince) or "?"
    return {
      color    = recoveredColor,
      icon     = "✓",
      mainText = string.format("%s is back up", s.name),
      subText  = string.format("was down for %s between %s – %s", wasDown, hud.clock(r.downSince), hud.clock(r.recoveredAt)),
      hasClose = true,
      -- Below all outages; most-recent recovery highest.
      sort     = 1e12 + (r.recoveredAt or 0),
      onClick  = function() hs.urlevent.openURL(s.page) end,
      onClose  = function() st.recovered = nil; saveState() end,
    }
  end

  return nil
end

for _, s in ipairs(services) do
  hud.register("service:" .. s.name, { zone = "top", build = function() return buildContent(s) end })
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
    if not st.downSince then
      st.downSince = now
      -- Fresh outage episode: clear any leftover snooze from a previous one.
      st.snoozedUntil = nil
      st.snoozedOrder = nil
    end
    -- Escalation un-snoozes: a worse severity than when snoozed resurfaces now.
    if st.snoozedUntil and st.snoozedOrder and order[indicator] > st.snoozedOrder then
      st.snoozedUntil = nil
      st.snoozedOrder = nil
    end
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
    -- Recovered: drop the snooze so a future outage isn't pre-silenced.
    st.snoozedUntil = nil
    st.snoozedOrder = nil
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
      hud.refresh()
    end)
  end
end

-- Globals: top-level locals get reclaimed once `require` returns (see comment
-- in init.lua about configWatcher). hs.timer / hs.caffeinate.watcher need a
-- live reference to keep firing. (Relative-time text is refreshed by the HUD's
-- own central timer, so this module no longer needs its own refresh timer.)
serviceStatusPollTimer    = hs.timer.new(pollInterval, poll)
serviceStatusPollTimer:start()
poll()

-- Timers pause during system sleep, so re-poll immediately on wake.
serviceStatusWakeWatcher = hs.caffeinate.watcher.new(function(event)
  local w = hs.caffeinate.watcher
  if event == w.systemDidWake or event == w.screensDidUnlock or event == w.screensDidWake then
    poll()
  end
end)
serviceStatusWakeWatcher:start()
