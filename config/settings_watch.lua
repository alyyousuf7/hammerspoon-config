-- Watch the telemetry env in ~/.claude/settings.json and nag until acknowledged.
--
-- Claude Code ships its OpenTelemetry config as plain env vars in settings.json
-- (endpoint, auth header, what content gets logged). A silent edit there — by an
-- update, a synced dotfile, a teammate's snippet, or a stray paste — can quietly
-- redirect telemetry or start exporting tool details / prompts. This module makes
-- any such change loud: it diffs the watched keys against the last *acknowledged*
-- snapshot and floats a pill via the shared HUD until you accept the new values.
--
-- Interaction:
--   • Click the "Ack" button → the current values become the new baseline; the
--                              pill clears and won't return until something
--                              changes again. It's an explicit button (not a body
--                              click) so it can't be acknowledged by accident.
--   • Click the × (close)    → SNOOZE: hide for REAPPEAR_SECS (30m); it comes back
--                              on its own afterwards if still unacknowledged.
-- The baseline and snooze deadline persist (hs.settings), so the nag survives a
-- config reload or a Hammerspoon restart and keeps its 30-minute cadence.
--
-- Self-clearing: if an edit is reverted back to the acknowledged values, the diff
-- is empty and the pill disappears with no action needed.

local hud = require("config.notifier")
local theme = require("config.theme")

-- ============================================================================
-- CONFIG
-- ============================================================================

local SETTINGS_PATH = os.getenv("HOME") .. "/.claude/settings.json"
local REAPPEAR_SECS = 30 * 60          -- snooze (× / close) duration before it nags again
local PERSIST_KEY   = "claudeSettingsWatch.v1"

-- Which env keys to watch. A key matches if this returns true; matching by
-- pattern (not a fixed list) means a newly-added OTEL_* key is itself flagged as
-- a change rather than silently ignored.
local function isWatched(key)
  return key == "CLAUDE_CODE_ENABLE_TELEMETRY" or key:match("^OTEL_") ~= nil
end

-- ============================================================================
-- STATE
-- ============================================================================

-- key -> value (strings), for the watched env keys only.
local current  = {}     -- what's in settings.json right now
local baseline = {}     -- last acknowledged snapshot
local snoozedUntil = nil

-- ----------------------------------------------------------------------------
-- Persistence
-- ----------------------------------------------------------------------------

local function persist()
  hs.settings.set(PERSIST_KEY, { baseline = baseline, snoozedUntil = snoozedUntil })
end

local function loadPersisted()
  local saved = hs.settings.get(PERSIST_KEY)
  if type(saved) ~= "table" then return false end
  if type(saved.baseline) == "table" then baseline = saved.baseline end
  if type(saved.snoozedUntil) == "number" then snoozedUntil = saved.snoozedUntil end
  return true
end

-- ----------------------------------------------------------------------------
-- Reading the file
-- ----------------------------------------------------------------------------

-- Read settings.json and return a table of the watched env keys. Returns nil if
-- the file is missing or mid-write (so a transient bad read never wipes state).
local function readWatched()
  local f = io.open(SETTINGS_PATH, "r")
  if not f then return nil end
  local body = f:read("*a")
  f:close()
  if not body or body == "" then return nil end

  local ok, decoded = pcall(hs.json.decode, body)
  if not ok or type(decoded) ~= "table" or type(decoded.env) ~= "table" then return nil end

  local snap = {}
  for k, v in pairs(decoded.env) do
    if isWatched(k) then snap[k] = tostring(v) end
  end
  return snap
end

-- ----------------------------------------------------------------------------
-- Diffing
-- ----------------------------------------------------------------------------

-- Ordered list of human-readable change lines between baseline and current.
local function diffLines()
  local lines = {}
  local seen = {}
  -- Changed / removed (iterate baseline first for stable-ish ordering).
  local keys = {}
  for k in pairs(baseline) do keys[#keys + 1] = k end
  for k in pairs(current) do if not baseline[k] then keys[#keys + 1] = k end end
  table.sort(keys)

  for _, k in ipairs(keys) do
    if seen[k] then goto continue end
    seen[k] = true
    local b, c = baseline[k], current[k]
    if b and not c then
      lines[#lines + 1] = "removed " .. k
    elseif c and not b then
      lines[#lines + 1] = "added " .. k .. "=" .. c
    elseif b ~= c then
      lines[#lines + 1] = k .. ": " .. b .. " → " .. c
    end
    ::continue::
  end
  return lines
end

local function hasChange()
  return #diffLines() > 0
end

-- ============================================================================
-- HUD NOTICE
-- ============================================================================

local function ack()
  -- Snapshot what's on disk *now* as the new acknowledged baseline.
  baseline = current
  snoozedUntil = nil
  persist()
  hud.refresh()
end

local function snooze()
  snoozedUntil = os.time() + REAPPEAR_SECS
  persist()
  -- The notifier re-renders after onClose; build() then returns nil while snoozed.
end

-- Open the settings file in VS Code. `open -a` needs no `code` CLI on PATH, and
-- focuses an existing VS Code window if one is already open.
local function openInEditor()
  hs.execute(string.format('open -a "Visual Studio Code" %q', SETTINGS_PATH))
end

local function buildContent()
  local lines = diffLines()
  if #lines == 0 then return nil end                       -- nothing pending → hidden
  if snoozedUntil and os.time() < snoozedUntil then return nil end  -- snoozed → hidden

  local sub = lines[1]
  if #lines > 1 then sub = sub .. string.format("  (+%d more)", #lines - 1) end

  return {
    color    = theme.AMBER,
    icon     = "⚙",
    mainText = "Claude telemetry settings changed",
    subText  = sub,
    sort     = 5e12,                  -- prominent: above service-status pills
    hasClose = true,
    onClose  = snooze,
    -- Body click opens the settings file in VS Code to inspect/edit the change.
    onClick  = openInEditor,
    -- Explicit Ack button so a stray click on the pill can't acknowledge a change.
    buttons  = {
      { text = "Ack", color = theme.ACCENT, onClick = ack },
    },
  }
end

hud.register("claude:settingsWatch", { zone = "top", build = buildContent })

-- ============================================================================
-- WATCHER
-- ----------------------------------------------------------------------------
-- FSEvents watches the file's directory and reports changes to it. Each event
-- re-reads, updates `current`, and refreshes the HUD; the build() above decides
-- whether a pill is warranted. Globals (see init.lua note on configWatcher):
-- a top-level local would be reclaimed once require() returns, stopping the
-- watcher. On reload we stop the prior instance first to avoid duplicates.
-- ============================================================================

local function refreshFromDisk()
  local snap = readWatched()
  if snap then current = snap end
  hud.refresh()
end

-- Seed state. On the very first run (no persisted baseline) the current on-disk
-- values become the baseline silently — you implicitly acknowledge what's there
-- when the watcher is installed; only *future* edits nag.
do
  current = readWatched() or {}
  local hadBaseline = loadPersisted()
  if not hadBaseline then
    baseline = current
    persist()
  end
end

if claudeSettingsWatcher then claudeSettingsWatcher:stop() end
claudeSettingsWatcher = hs.pathwatcher.new(SETTINGS_PATH, refreshFromDisk)
claudeSettingsWatcher:start()

-- Timers (and thus the HUD's snooze-expiry re-render) pause during sleep; re-read
-- on wake so a change made while asleep surfaces promptly.
if claudeSettingsWakeWatcher then claudeSettingsWakeWatcher:stop() end
claudeSettingsWakeWatcher = hs.caffeinate.watcher.new(function(event)
  local w = hs.caffeinate.watcher
  if event == w.systemDidWake or event == w.screensDidUnlock then refreshFromDisk() end
end)
claudeSettingsWakeWatcher:start()

local M = {}

-- Introspection / manual control from a terminal:
--   hs -c 'require("config.settings_watch").status()'
function M.status()
  return {
    current      = current,
    baseline     = baseline,
    pending      = diffLines(),
    snoozedUntil = snoozedUntil,
  }
end

-- Force-acknowledge the current on-disk values (same as clicking the pill).
M.ack = function() refreshFromDisk(); ack() end

return M
