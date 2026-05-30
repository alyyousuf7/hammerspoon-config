-- Floating panel that lists recent one-time codes (OTCs) from the local
-- `email_tokens` table. Polls every few seconds, shows up to 10 codes from
-- the last 30 minutes, click a row to copy the code to the clipboard.
-- Hides itself entirely when there are no recent codes.

local secrets = require("config.secrets")
local m = secrets.mysql

-- ============================================================================
-- CONFIG
-- ============================================================================

local NODE_BIN    = os.getenv("HOME") .. "/.local/share/fnm/aliases/default/bin/node"
local QUERY_JS    = os.getenv("HOME") .. "/.hammerspoon/helpers/otc_query/query.js"
local POLL_SECS   = 5
local REFRESH_SECS = 5     -- re-render relative timestamps without re-querying
local MAX_ROWS    = 10
local PANEL_W     = 360
local ROW_H       = 52
local HEADER_H    = 26
local PADDING     = 8
local CORNER_GAP  = 8      -- distance from screen edges

-- ============================================================================
-- STATE
-- ============================================================================

local rawRows = {}         -- list of { token, email, created_ts } from DB
local canvas = nil
local lastFlash = nil      -- { token, until_ts } — show "Copied!" briefly

-- Dismissed tokens persist across reloads so a row stays hidden as long as it
-- might still show up in DB results. Map: token -> expiry_ts (when we'll
-- purge it). We keep dismissals for 1h — well past the 30m query window.
local DISMISS_KEY  = "otcCodes.dismissed.v1"
local DISMISS_TTL  = 3600
local dismissed = hs.settings.get(DISMISS_KEY) or {}

local function purgeStaleDismissals()
  local now, changed = os.time(), false
  for token, expiry in pairs(dismissed) do
    if type(expiry) ~= "number" or expiry < now then
      dismissed[token] = nil; changed = true
    end
  end
  if changed then hs.settings.set(DISMISS_KEY, dismissed) end
end

local function visibleRows()
  local out = {}
  for _, r in ipairs(rawRows) do
    if not dismissed[r.token] then table.insert(out, r) end
  end
  return out
end

-- ============================================================================
-- HELPERS
-- ============================================================================

local function fmtAgo(ts)
  local diff = os.time() - ts
  if diff < 5 then return "just now" end
  if diff < 60 then return diff .. "s ago" end
  if diff < 3600 then
    local mn = math.floor(diff / 60)
    local s  = diff % 60
    if s == 0 or mn >= 10 then return mn .. "m ago" end
    return mn .. "m " .. s .. "s ago"
  end
  local h = math.floor(diff / 3600)
  local mn = math.floor((diff % 3600) / 60)
  if mn == 0 then return h .. "h ago" end
  return h .. "h " .. mn .. "m ago"
end

-- ============================================================================
-- RENDER
-- ============================================================================

local function render()
  -- Drop the "Copied!" flash once expired.
  if lastFlash and os.time() > lastFlash.until_ts then lastFlash = nil end

  local rows = visibleRows()
  if #rows == 0 then
    if canvas then canvas:delete(); canvas = nil end
    return
  end

  local n = math.min(#rows, MAX_ROWS)
  local h = HEADER_H + n * ROW_H + PADDING * 2
  -- Anchor to the bottom-right of the primary screen's usable area (fullFrame
  -- includes menubar/dock; use frame() to stay above the dock).
  local screen = hs.screen.primaryScreen():frame()
  local x = screen.x + screen.w - PANEL_W - CORNER_GAP
  local y = screen.y + screen.h - h - CORNER_GAP

  if canvas then canvas:delete() end
  canvas = hs.canvas.new({ x = x, y = y, w = PANEL_W, h = h })
  canvas:level(hs.canvas.windowLevels.popUpMenu)
  canvas:behavior({ "canJoinAllSpaces", "stationary" })
  canvas:clickActivating(false)

  local elements = {
    -- Background
    { type = "rectangle", action = "strokeAndFill",
      fillColor   = { white = 0.08, alpha = 0.90 },
      strokeColor = { red = 0.20, green = 0.78, blue = 0.35, alpha = 0.45 },
      strokeWidth = 1,
      frame = { x = 0.5, y = 0.5, w = PANEL_W - 1, h = h - 1 },
      roundedRectRadii = { xRadius = 10, yRadius = 10 } },
    -- Header
    { type = "text",
      text = string.format("Recent OTC codes  ·  %d", #rows),
      textColor = { red = 0.20, green = 0.78, blue = 0.35, alpha = 1 },
      textSize = 11, textAlignment = "left",
      frame = { x = PADDING + 4, y = PADDING, w = PANEL_W - PADDING * 2 - 8, h = HEADER_H - 4 } },
  }

  for i = 1, n do
    local row = rows[i]
    local top = PADDING + HEADER_H + (i - 1) * ROW_H
    local flashing = lastFlash and lastFlash.token == row.token

    -- Row background (clickable area). id so click handler can identify.
    table.insert(elements, {
      type = "rectangle", id = "row-" .. i, action = "fill",
      fillColor = flashing
        and { red = 0.20, green = 0.78, blue = 0.35, alpha = 0.18 }
        or  { white = 0.16, alpha = 0.55 },
      frame = { x = PADDING, y = top, w = PANEL_W - PADDING * 2, h = ROW_H - 4 },
      roundedRectRadii = { xRadius = 6, yRadius = 6 },
      trackMouseUp = true,
    })

    -- Code (left, monospace, large). Position is fixed regardless of flash
    -- state so "Copied" never shifts the digits.
    table.insert(elements, {
      type = "text", text = row.token,
      textColor = flashing
        and { red = 0.20, green = 0.78, blue = 0.35, alpha = 1 }
        or  { white = 1.0, alpha = 1 },
      textFont = "Menlo", textSize = 18, textAlignment = "left",
      frame = { x = PADDING + 10, y = top + 4, w = PANEL_W - PADDING * 2 - 20, h = 22 },
    })

    -- Email (bottom-left)
    table.insert(elements, {
      type = "text", text = row.email,
      textColor = { white = 0.68, alpha = 1 },
      textSize = 10, textAlignment = "left",
      frame = { x = PADDING + 10, y = top + 28, w = PANEL_W - PADDING * 2 - 110, h = 14 },
    })

    -- Bottom-right: "Copied" while flashing, otherwise "Xm ago". Same slot so
    -- neither one shifts the other.
    table.insert(elements, {
      type = "text",
      text = flashing and "Copied" or fmtAgo(row.created_ts),
      textColor = flashing
        and { red = 0.20, green = 0.78, blue = 0.35, alpha = 1 }
        or  { white = 0.55, alpha = 1 },
      textSize = 10, textAlignment = "right",
      frame = { x = PADDING + 10, y = top + 28, w = PANEL_W - PADDING * 2 - 20, h = 14 },
    })

    -- × dismiss button (top-right of row). trackMouseUp on its own id so the
    -- row click handler can distinguish "copy" from "dismiss".
    table.insert(elements, {
      type = "text", id = "x-" .. i, text = "×",
      textColor = { white = 0.55, alpha = 1 },
      textSize = 18, textAlignment = "center",
      frame = { x = PANEL_W - PADDING - 28, y = top + 2, w = 22, h = 22 },
      trackMouseUp = true,
    })
  end

  canvas:replaceElements(elements)
  canvas:mouseCallback(function(_, evt, id)
    if evt ~= "mouseUp" then return end
    local s = tostring(id)
    local xIdx = tonumber(s:match("^x%-(%d+)$"))
    if xIdx then
      local row = rows[xIdx]; if not row then return end
      dismissed[row.token] = os.time() + DISMISS_TTL
      hs.settings.set(DISMISS_KEY, dismissed)
      render()
      return
    end
    local idx = tonumber(s:match("^row%-(%d+)$"))
    if not idx then return end
    local row = rows[idx]; if not row then return end
    hs.pasteboard.setContents(row.token)
    lastFlash = { token = row.token, until_ts = os.time() + 1 }
    render()
  end)
  canvas:canvasMouseEvents(true, true)
  canvas:show()
end

-- ============================================================================
-- POLLING
-- ----------------------------------------------------------------------------
-- The helper is launched ONCE as a long-lived process; it queries MySQL on
-- its own POLL_SECS interval and prints one JSON line per result. We consume
-- those lines via streamingCallback. Earlier versions forked node every 5s
-- (~17k spawns/day), which caused multi-GB heap growth in Hammerspoon over
-- weeks of uptime.
-- ============================================================================

local function applyLine(line)
  if not line or line == "" then return end
  local ok, decoded = pcall(hs.json.decode, line)
  if not ok or type(decoded) ~= "table" or not decoded.ok then return end
  local new = {}
  for _, r in ipairs(decoded.rows or {}) do
    local ts = tonumber(r.created_ts)   -- mysql2 may return decimal as string
    if r.token and r.email and ts then
      table.insert(new, { token = tostring(r.token), email = tostring(r.email), created_ts = math.floor(ts) })
    end
  end
  rawRows = new
  purgeStaleDismissals()
  render()
end

-- Stream buffer: node may flush partial lines; accumulate until we see \n.
local stdoutBuf = ""

local function onStdout(_, chunk)
  if not chunk or chunk == "" then return true end
  stdoutBuf = stdoutBuf .. chunk
  while true do
    local nl = stdoutBuf:find("\n", 1, true)
    if not nl then break end
    local line = stdoutBuf:sub(1, nl - 1)
    stdoutBuf = stdoutBuf:sub(nl + 1)
    applyLine(line)
  end
  return true  -- keep the stream open
end

local otcTask = nil

local function startHelper()
  if otcTask and otcTask:isRunning() then return end
  stdoutBuf = ""
  otcTask = hs.task.new(NODE_BIN, function(_exit, _out, _err)
    -- Exit callback: helper died. Don't auto-restart in a tight loop — let
    -- the wake watcher or next reload bring it back. Most exits here are
    -- intentional (Hammerspoon reload sends SIGTERM).
    otcTask = nil
  end, onStdout, { QUERY_JS })
  otcTask:setEnvironment({
    PATH          = "/usr/bin:/bin:/usr/local/bin",
    MYSQL_HOST    = m.host, MYSQL_PORT = m.port, MYSQL_USER = m.user,
    MYSQL_PASS    = m.pass, MYSQL_DB   = m.db,
    OTC_POLL_SECS = tostring(POLL_SECS),
  })
  otcTask:start()
end

-- Globals: see init.lua / service_status.lua for why top-level locals would
-- be reclaimed and break the timers.
otcCodesRefreshTimer = hs.timer.doEvery(REFRESH_SECS, render)
otcCodesWakeWatcher  = hs.caffeinate.watcher.new(function(event)
  local w = hs.caffeinate.watcher
  if event == w.systemDidWake or event == w.screensDidUnlock or event == w.screensDidWake then
    -- Helper's setInterval pauses during sleep on some macOS versions;
    -- restart it on wake to guarantee fresh data.
    if otcTask then otcTask:terminate() end
    otcTask = nil
    startHelper()
  end
end)
otcCodesWakeWatcher:start()
startHelper()
