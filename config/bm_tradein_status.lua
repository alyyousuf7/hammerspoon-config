-- Watch the BackMarket Trade-In optimizer's run reports. The launchd job
-- (com.aliyousuf.bm-tradein) runs hourly and writes a `*_run-report.md` into
-- ~/code/backmarket-tradein-optimizer/runs/ with a `**Status:** SUCCESS|FAILED`
-- line. When the newest report is FAILED — or no fresh report has appeared in
-- well over a run interval (job didn't run / machine asleep) — show a red pill
-- at top-center (same style as service_status) with the last error and its
-- time; click it to open the report. When runs recover, show a dismissable
-- green notice.
--
-- Rendering/placement is delegated to config.notifier (the shared HUD), which
-- stacks this pill together with service_status's so they never overlap. This
-- file owns only the polling, parsing, state, and persistence.

local hud = require("config.notifier")
local theme = require("config.theme")

-- ============================================================================
-- CONFIG
-- ============================================================================

local RUNS_DIR     = os.getenv("HOME") .. "/code/backmarket-tradein-optimizer/runs"
local pollInterval = 300              -- seconds (5 min); cheap dir scan
local STALE_SECS   = 3 * 3600         -- job runs hourly; >3h with no new report (~3 missed) = stale
local SNOOZE_SECS  = 30 * 60          -- × on the failure pill hides it for this long

local failColor      = { red = 0.95, green = 0.20, blue = 0.20 }
local staleColor     = { red = 1.00, green = 0.80, blue = 0.20 }
local recoveredColor = { red = 0.20, green = 0.78, blue = 0.35 }

-- ============================================================================
-- STATE  (persisted via hs.settings so transitions survive a reload)
-- ----------------------------------------------------------------------------
-- processedFile : filename of the newest report we've already applied
-- status        : "SUCCESS" | "FAILED"
-- downSince      : epoch of the run that began the current failing streak | nil
-- failTime      : epoch of the most recent failing run | nil
-- failReason    : first line of that run's ## Reason block | nil
-- reportPath    : abs path of the most recent report (for click-to-open)
-- recovered     : { downSince, recoveredAt } | nil  (undismissed recovery notice)
-- snoozedUntil  : epoch until which the failure pill is hidden (× pressed) | nil
-- ============================================================================

local SETTINGS_KEY = "bmTradein.persisted.v1"
local state = {
  processedFile = nil, status = nil, downSince = nil,
  failTime = nil, failReason = nil, reportPath = nil, recovered = nil,
}

local function saveState() hs.settings.set(SETTINGS_KEY, state) end
local function loadState()
  local snap = hs.settings.get(SETTINGS_KEY)
  if type(snap) == "table" then
    for k, v in pairs(snap) do state[k] = v end
  end
end
loadState()

-- ============================================================================
-- REPORT SCANNING / PARSING
-- ============================================================================

-- Report filenames sort lexicographically by time: YYYY-MM-DD_HH-MM-SS_run-report.md
local function newestReport()
  local best
  local ok, iter, dirObj = pcall(hs.fs.dir, RUNS_DIR)
  if not ok or not iter then return nil end
  for f in iter, dirObj do
    if f:match("_run%-report%.md$") then
      if not best or f > best then best = f end
    end
  end
  return best
end

local function epochFromName(name)
  local y, mo, d, h, mi, s =
    name:match("^(%d+)-(%d+)-(%d+)_(%d+)-(%d+)-(%d+)_run%-report%.md$")
  if not y then return nil end
  return os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s })
end

-- Returns status ("SUCCESS"/"FAILED"/nil) and the first line of the Reason block.
local function parseReport(path)
  local fh = io.open(path, "r")
  if not fh then return nil, nil end
  local body = fh:read("*a")
  fh:close()
  local status = body:match("%*%*Status:%*%*%s*([%u]+)")
  local reason
  local reasonBlock = body:match("##%s*Reason%s*\n(.-)\n```") or body:match("##%s*Reason%s*\n(.+)")
  if reasonBlock then
    for line in reasonBlock:gmatch("[^\n]+") do
      local trimmed = line:match("^%s*(.-)%s*$")
      if trimmed ~= "" and not trimmed:match("^```") then reason = trimmed; break end
    end
  end
  return status, reason
end

local function truncate(s, n)
  if not s then return "" end
  if #s <= n then return s end
  return s:sub(1, n - 1) .. "…"
end

-- Retry: kick an immediate run of the loaded launchd job (same hourly job, run
-- now), then re-poll once it should have finished so the pill clears without
-- waiting for the 5-min cycle. Best-effort — if the failure was expired cookies
-- (bot-need-challenge) the run will just fail again until they're refreshed.
local function runNow()
  hs.alert.show("BM Trade-In: retrying…")
  hs.execute("launchctl kickstart -k gui/$(id -u)/com.aliyousuf.bm-tradein", true)
  hs.timer.doAfter(160, function()
    if bmTradeinPollTimer then bmTradeinPollTimer:fire() end
  end)
end

-- ============================================================================
-- HUD NOTICE
-- ----------------------------------------------------------------------------
-- A single notice. `build` decides what (if anything) to show from live state;
-- returns nil to hide, else the pill content. The HUD calls it on every render.
-- ============================================================================

local function buildContent()
  local now = os.time()

  if state.status == "FAILED" then
    -- Snoozed (× pressed): hide until the deadline, then the HUD's refresh timer
    -- brings it back if still failing. A fresh failure episode clears the snooze
    -- (see poll), so a new failure always resurfaces.
    if state.snoozedUntil and now < state.snoozedUntil then return nil end
    return {
      color    = failColor,
      icon     = "⚠",
      mainText = "BM Trade-In failed: " .. truncate(state.failReason or "unknown error", 60),
      subText  = string.format("failing since %s · last run %s",
                   hud.clock(state.downSince or state.failTime), hud.relativeTime(state.failTime)),
      hasClose = true,
      sort     = 2e12 + 500,   -- among service outages, near the top
      onClick  = function()
        if state.reportPath then hs.execute("open '" .. state.reportPath .. "'") end
      end,
      onClose  = function()
        state.snoozedUntil = os.time() + SNOOZE_SECS
        saveState()
      end,
      buttons  = {
        { text = "Retry", color = theme.ACCENT, textColor = { white = 1 }, onClick = runNow },
      },
    }
  end

  -- Stale: latest report (or none) is older than a run interval+.
  if state.failTime == nil and state.status == "SUCCESS" and state.lastRunTime
     and (now - state.lastRunTime) > STALE_SECS then
    return {
      color    = staleColor,
      icon     = "⚠",
      mainText = "BM Trade-In: no run in " .. hud.fmtDuration(now - state.lastRunTime),
      subText  = "last run " .. hud.clock(state.lastRunTime) .. " · job may not be running",
      hasClose = true,
      sort     = 1.5e12,       -- below hard failures, above recoveries
      onClick  = function()
        if state.reportPath then hs.execute("open '" .. state.reportPath .. "'") end
      end,
      onClose  = function()
        -- Dismissing a stale notice: suppress until a newer run appears.
        if state.status == "SUCCESS" then state.staleDismissedAt = os.time() end
        saveState()
      end,
    }
  end

  if state.recovered then
    local r = state.recovered
    local wasDown = (r.downSince and r.recoveredAt) and hud.fmtDuration(r.recoveredAt - r.downSince) or "?"
    return {
      color    = recoveredColor,
      icon     = "✓",
      mainText = "BM Trade-In runs recovered",
      subText  = string.format("was failing for %s · recovered at %s", wasDown, hud.clock(r.recoveredAt)),
      hasClose = true,
      sort     = 1e12 + (r.recoveredAt or 0),
      onClose  = function() state.recovered = nil; saveState() end,
    }
  end

  return nil
end

hud.register("bm-tradein", { zone = "top", build = buildContent })

-- ============================================================================
-- POLLING
-- ============================================================================

local function poll()
  local name = newestReport()
  if not name then return end
  local path = RUNS_DIR .. "/" .. name
  local runEpoch = epochFromName(name)
  state.reportPath = path
  state.lastRunTime = runEpoch

  -- Only re-apply transitions when a *new* report appears.
  if name ~= state.processedFile then
    local status, reason = parseReport(path)
    if status then
      local wasFailed = state.status == "FAILED"
      if status == "FAILED" then
        if not wasFailed then
          state.downSince = runEpoch       -- streak began here
          state.snoozedUntil = nil         -- fresh failure episode clears any old snooze
        end
        state.failTime   = runEpoch
        state.failReason = reason or "unknown error"
        state.recovered  = nil
      else -- SUCCESS
        if wasFailed and state.downSince then
          state.recovered = { downSince = state.downSince, recoveredAt = runEpoch }
        end
        state.downSince = nil
        state.failTime  = nil
        state.failReason = nil
        state.snoozedUntil = nil           -- recovered: don't pre-silence next failure
      end
      state.status        = status
      state.processedFile = name
      state.staleDismissedAt = nil   -- new run clears any stale dismissal
      saveState()
    end
  end
  hud.refresh()
end

-- Globals so timers/watchers aren't reclaimed when require() returns
-- (see init.lua note on configWatcher / service_status). Relative-time text is
-- kept fresh by the HUD's central timer, so no per-module refresh timer here.
bmTradeinPollTimer = hs.timer.new(pollInterval, poll)
bmTradeinPollTimer:start()
poll()

-- Timers pause during sleep; re-check on wake.
bmTradeinWakeWatcher = hs.caffeinate.watcher.new(function(event)
  local w = hs.caffeinate.watcher
  if event == w.systemDidWake or event == w.screensDidUnlock or event == w.screensDidWake then
    poll()
  end
end)
bmTradeinWakeWatcher:start()
