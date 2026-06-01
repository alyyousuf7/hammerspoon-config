-- Window-placement engine + centered overlay toggles. Named presets used to
-- live here; they've been replaced by config/composer.lua, which drives this
-- file's apply()/applyDynamic() to place on-the-fly compositions. What remains:
-- the placement/hide/raise/focus machinery, the Slack/Spotify overlays, and the
-- helpers the composer calls (applyDynamic, focusEntry, hideOthers).
-- Config lives at the top; logic in the middle; hotkey wiring at the bottom.

local wm = require("config.window_management")

-- Module table. Returned at the end so `package.loaded["config.layouts"]`
-- keeps references to the watcher and state alive after this chunk finishes.
local M = {}

local currentLayout = nil
local lastFocused = {}
-- Apps for which an async launch-and-place chain is in flight. A second
-- trigger for the same app while one is pending is a no-op.
local pendingLaunches = {}
-- Per-app intra-app window z-order captured right before the app was hidden
-- by a layout switch. Keyed by app name; value is a list of window IDs in
-- front-to-back order. Restored when the app is unhidden by another layout.
-- Stale IDs (after an app relaunch) are ignored during restore.
local savedAppZOrder = {}
-- Layout tables registered at runtime (e.g. by config/composer.lua) that have
-- no static entry in `layouts`. Keyed by a synthetic name so they flow through
-- the same apply()/minimize re-apply/last-focused machinery as named layouts.
local dynamicLayouts = {}

-- ============================================================================
-- CONFIG
-- ============================================================================

-- Modifier for every binding in this file.
local mod = { "ctrl", "alt", "cmd" }

-- Static named layouts have been retired in favour of config/composer.lua, which
-- builds layout tables on the fly and applies them through M.applyDynamic. This
-- table stays empty; getLayout() falls through to the dynamic registry.
--
-- Layout entry format (produced by the composer, consumed by apply()):
--   { app, rect = {x, y, w, h} in fractions, stack?, launch?, prefer? }
--     stack  = "vertical" to tile all of the app's windows down the rect.
--     launch = true to open the app (non-blocking) if it isn't running.
--     prefer = { titlePattern = "..." } — Lua pattern matched against a window's
--              AX title to pick a specific same-app window (e.g. a Chrome
--              profile, whose title ends in " … (Work)"). Lua patterns differ
--              from PCRE: escape ( ) . % + - * ? [ ] ^ $ with a preceding `%`.
local layouts = {}

-- Centered popup overlays. width/height default to 3/5 × 5/6 if omitted.
local overlays = {
  { key = "pad0",   app = "Slack" },
  { key = "padenter", app = "Spotify" },
}

-- Set of app names the minimize toggle (config/minimize_layout) hides. Seeded
-- with the overlay apps here; config/composer.lua adds its source apps at load.
-- Exposed on M so sibling modules don't recompute it.
local handledSet = {}
for _, o in ipairs(overlays) do handledSet[o.app] = true end
M.handledSet = handledSet

-- ============================================================================
-- LOGIC
-- ============================================================================

-- Find all running apps with an exact name match. Returns a list because some
-- tools (e.g. Playwright-driven browsers) spawn multiple processes that share
-- the same app name, each with its own window. hs.application.find is also
-- substring-based, which conflates "Google Chrome" with "Google Chrome for Testing".
local function findAppsExact(name)
  local matches = {}
  for _, app in ipairs(hs.application.runningApplications()) do
    if app:name() == name then matches[#matches + 1] = app end
  end
  return matches
end

-- Collect all "real" windows across any number of apps. allWindows() is used
-- instead of visibleWindows() because the latter drops windows whose AX subrole
-- isn't AXStandardWindow — which happens with Chromium-based apps.
-- Windows on secondary displays (e.g. iPad via Sidecar) are excluded so the
-- layout never repositions them.
local function windowsOfAll(apps)
  local wins = {}
  for _, app in ipairs(apps) do
    for _, win in ipairs(app:allWindows()) do
      if win:isStandard() and not win:isMinimized() and wm.isOnPrimary(win) then
        wins[#wins + 1] = win
      end
    end
  end
  return wins
end

-- Place windows of one layout entry into its rect. Appends to `placedAcc` if given.
-- `stack = "vertical"` slices the rect vertically across the windows;
-- otherwise every window is placed at the full rect (z-stacked overlap).
-- Resolve a layout table by name from either the static or dynamic registry.
local function getLayout(name)
  return layouts[name] or dynamicLayouts[name]
end

-- Narrow a window list to those whose AX title matches entry.prefer.titlePattern.
-- Returns the original list unchanged if the entry has no prefer pattern, or if
-- nothing matches (so a layout never ends up placing zero windows just because
-- a profile window happens to be closed). This is what lets two same-app
-- entries — e.g. Chrome (Work) and Chrome (Personal) — each claim only their
-- own window instead of fighting over all of the app's windows.
local function filterPreferred(wins, entry)
  if not (entry.prefer and entry.prefer.titlePattern) then return wins end
  local pattern = entry.prefer.titlePattern
  local matched = {}
  for _, win in ipairs(wins) do
    local title = win:title()
    if title and title:find(pattern) then matched[#matched + 1] = win end
  end
  if #matched > 0 then return matched end
  return wins
end

local function placeEntry(wins, entry, placedAcc)
  local x, y, w, h = entry.rect[1], entry.rect[2], entry.rect[3], entry.rect[4]
  local vertical = entry.stack == "vertical"
  local rowH = vertical and h / #wins or h
  for i, win in ipairs(wins) do
    local rowY = vertical and (y + rowH * (i - 1)) or y
    wm.placeWindow(win, x, rowY, w, rowH)
    if placedAcc then placedAcc[#placedAcc + 1] = win end
  end
end

-- Fire-and-forget launch, then poll up to ~6s for the first window to appear
-- and place it. Non-blocking so triggering a layout with a closed app doesn't
-- hang Hammerspoon's main thread. Duplicate triggers for the same app while a
-- chain is in flight are ignored.
local function launchAndPlaceAsync(entry)
  if pendingLaunches[entry.app] then return end
  pendingLaunches[entry.app] = true
  hs.application.open(entry.app)  -- non-blocking
  local attempts = 0
  local function check()
    local wins = windowsOfAll(findAppsExact(entry.app))
    if #wins > 0 then
      placeEntry(wins, entry, nil)
      pendingLaunches[entry.app] = nil
    elseif attempts < 30 then
      attempts = attempts + 1
      hs.timer.doAfter(0.2, check)
    else
      pendingLaunches[entry.app] = nil  -- timed out; allow a fresh attempt next trigger
    end
  end
  hs.timer.doAfter(0.3, check)
end

-- Execute the hide/raise/activate pass that transitions the screen from its
-- current state to the layout's target z-stack. Called only when the top of
-- the stack isn't already correct.
local function reorderForLayout(layout, layoutApps, placed, zIndex, targetFront)
  -- Before hiding, snapshot the intra-app z-order of every app we're about
  -- to hide. macOS doesn't guarantee the order is preserved across hide/unhide,
  -- so we restore it ourselves in apply() next time the app is unhidden.
  local byApp = {}
  for _, win in ipairs(hs.window.orderedWindows()) do
    local wapp = win:application()
    if wapp then
      local name = wapp:name()
      byApp[name] = byApp[name] or {}
      byApp[name][#byApp[name] + 1] = win:id()
    end
  end
  for _, app in ipairs(hs.application.runningApplications()) do
    if app:kind() == 1 and not layoutApps[app:name()] and not app:isHidden()
        and not wm.appHasWindowOnSecondary(app) then
      local ids = byApp[app:name()]
      if ids and #ids > 0 then
        savedAppZOrder[app:name()] = ids
      end
    end
  end

  -- Clean slate: hide every running foreground app that isn't part of this
  -- layout. Apps with any window on a secondary display are left alone — hide
  -- is all-or-nothing and would yank those windows off the secondary screen.
  for _, app in ipairs(hs.application.runningApplications()) do
    if app:kind() == 1 and not layoutApps[app:name()] and not app:isHidden()
        and not wm.appHasWindowOnSecondary(app) then
      app:hide()
    end
  end

  -- Raise placed windows back-to-front so the originally-frontmost window of
  -- each app ends up on top. Within a single app, prefer savedAppZOrder over
  -- the post-unhide orderedBefore zIndex — macOS's unhide doesn't preserve
  -- intra-app z-order, so zIndex for a just-unhidden app is unreliable. Fall
  -- back to zIndex for apps with no saved order or when IDs are stale.
  table.sort(placed, function(a, b)
    local aApp = a:application() and a:application():name()
    local bApp = b:application() and b:application():name()
    if aApp and aApp == bApp then
      local saved = savedAppZOrder[aApp]
      if saved then
        local aPos, bPos
        for i, id in ipairs(saved) do
          if id == a:id() then aPos = i end
          if id == b:id() then bPos = i end
        end
        if aPos and bPos then return aPos > bPos end
      end
    end
    return (zIndex[a:id()] or math.huge) > (zIndex[b:id()] or math.huge)
  end)
  for _, win in ipairs(placed) do win:raise() end

  -- Activate each layout app with the target last. We can't skip the
  -- non-target activations even though it'd reduce jitter: on Electron apps
  -- (VSCode, Chrome, etc.), win:raise()'s intra-app z-order change isn't
  -- "committed" until the app is activated, so skipping causes the wrong
  -- window to come forward when the user later focuses that app. Activating
  -- in order with target last keeps target frontmost cross-app while still
  -- committing each other app's intra-app z-order.
  local seen = {}
  local function activate(appName)
    for _, app in ipairs(findAppsExact(appName)) do
      local pid = app:pid()
      if not seen[pid] then
        seen[pid] = true
        if app:isHidden() then app:unhide() end
        app:activate(true)
      end
    end
  end
  for _, entry in ipairs(layout) do
    if entry.app ~= targetFront then activate(entry.app) end
  end
  activate(targetFront)
end

-- Position a hidden app's target window(s) to the entry rect BEFORE unhiding it,
-- so the window reappears at its destination instead of flashing at its old
-- position for a frame. Bypasses windowsOfAll's isStandard filter (hidden
-- Chromium windows report a non-standard subrole), skips minimized and
-- secondary-display windows, and matches the prefer pattern when present.
-- Best-effort: any failure is swallowed so it can never break apply().
local function preplaceHidden(app, entry)
  local pattern = entry.prefer and entry.prefer.titlePattern
  local primary = hs.screen.primaryScreen()
  for _, win in ipairs(app:allWindows()) do
    if not win:isMinimized() then
      local s = win:screen()
      local onPrimary = (not s) or (primary and s:id() == primary:id())
      local t = win:title()
      if onPrimary and ((not pattern) or (t and t:find(pattern))) then
        pcall(function()
          -- Always instant: the window must reach its rect before the unhide
          -- reveals it, even when the composer is animating other placements.
          wm.placeWindow(win, entry.rect[1], entry.rect[2], entry.rect[3], entry.rect[4], 0)
        end)
      end
    end
  end
end

local function apply(name)
  local layout = getLayout(name)
  if not layout then return end
  local missing = {}
  local placed = {}  -- all windows we positioned, in layout entry order

  -- Unhide layout apps that were hidden by a previous clean-slate or the F19
  -- toggle. Each hidden app's target window is pre-positioned to its rect WHILE
  -- still hidden (preplaceHidden), so it doesn't flash at its old position on
  -- unhide. Intra-app z-order is restored later in the sort comparator, which
  -- uses savedAppZOrder as the source of truth (more reliable than raising
  -- immediately after unhide — those raises don't always stick before we
  -- capture orderedBefore).
  for _, entry in ipairs(layout) do
    for _, app in ipairs(findAppsExact(entry.app)) do
      if app:isHidden() then
        preplaceHidden(app, entry)
        app:unhide()
      end
    end
  end

  -- Snapshot current z-order (front → back). Used for two things: (1) deciding
  -- raise order after placement (originally-frontmost stays on top), and (2)
  -- detecting whether the stack is already in the right shape so we can skip
  -- the raise+activate pass entirely.
  local orderedBefore = hs.window.orderedWindows()
  local zIndex = {}
  for i, win in ipairs(orderedBefore) do zIndex[win:id()] = i end

  for _, entry in ipairs(layout) do
    local wins = filterPreferred(windowsOfAll(findAppsExact(entry.app)), entry)
    if #wins > 0 then
      placeEntry(wins, entry, placed)
    elseif entry.launch then
      -- App isn't running; launch it async and place its window when it appears.
      launchAndPlaceAsync(entry)
    else
      missing[#missing + 1] = entry.app
    end
  end

  -- Decide which layout app should end up frontmost. Priority:
  --   1. Whatever was last focused in this layout (persisted across switches).
  --   2. The current frontmost app, if it's part of this layout.
  --   3. The first entry's app (default).
  local layoutApps = {}
  for _, entry in ipairs(layout) do layoutApps[entry.app] = true end

  local frontApp = hs.application.frontmostApplication()
  local frontName = frontApp and frontApp:name()
  -- Guard lastFocused with layoutApps: for dynamic compositions (config/
  -- composer.lua) every arrangement reuses one layout name, so lastFocused can
  -- name an app the current arrangement no longer contains. Without this guard,
  -- the activate pass would resurrect that app — e.g. a slot you just emptied.
  local targetFront = (lastFocused[name] and layoutApps[lastFocused[name]] and lastFocused[name])
    or (frontName and layoutApps[frontName] and frontName)
    or layout[1].app

  -- Skip raise + activate if the top of the z-stack already matches the layout:
  -- the target app is frontmost AND the top N ordered windows all belong to
  -- layout apps (so nothing non-layout is poking through).
  local topAllLayout = true
  for i = 1, math.min(#placed, #orderedBefore) do
    if not layoutApps[orderedBefore[i]:application():name()] then
      topAllLayout = false
      break
    end
  end
  local frontmostCorrect = frontName == targetFront

  if not (frontmostCorrect and topAllLayout) then
    reorderForLayout(layout, layoutApps, placed, zIndex, targetFront)
  end

  -- Prefer-pass: for entries with `prefer.titlePattern`, raise the first
  -- window whose AX title matches the Lua pattern to the top of its app.
  -- Done last so the normal raise/activate pass doesn't undo it.
  for _, entry in ipairs(layout) do
    if entry.prefer and entry.prefer.titlePattern then
      local pattern = entry.prefer.titlePattern
      for _, app in ipairs(findAppsExact(entry.app)) do
        local found
        for _, win in ipairs(app:allWindows()) do
          local title = win:title()
          if title and title:find(pattern) then
            win:raise()
            found = true
            break
          end
        end
        if found then break end
      end
    end
  end

  currentLayout = name
  if M.onApply then M.onApply(name) end  -- let sibling modules react (e.g. minimize_layout)

  if #missing > 0 then
    hs.alert.show('Layout "' .. name .. '": ' .. table.concat(missing, ", ") .. ' not running')
  end
end

-- Place the first visible window of `appName` centered on screen at the given
-- fractional width/height. Unhides the app if hidden, raises and focuses it.
-- Returns true if placed, false if the app has no windows.
--
-- The unhide happens BEFORE enumerating windows because hidden apps can have
-- non-standard AX subroles on their windows, which windowsOfAll filters out
-- — so if we enumerated first we'd early-return on hidden apps and never
-- reach the unhide.
local function placeAppCentered(appName, width, height)
  local apps = findAppsExact(appName)
  if #apps == 0 then return false end
  if apps[1]:isHidden() then apps[1]:unhide() end
  local wins = windowsOfAll(apps)
  if #wins == 0 then return false end
  wm.placeWindow(wins[1], (1 - width) / 2, (1 - height) / 2, width, height)
  apps[1]:activate(true)
  return true
end

-- Toggle an app as a centered popup overlay. First press: launch if needed,
-- unhide, place centered at the given fractional size, focus. Second press:
-- hide the app, revealing whatever was underneath.
local function toggleOverlay(appName, width, height)
  width  = width  or 3/5
  height = height or 5/6
  local apps = findAppsExact(appName)
  if #apps > 0 and not apps[1]:isHidden() then
    -- Only hide if this app is actually frontmost. If it's running but buried
    -- behind another overlay (e.g. Slack covering Spotify), a press should
    -- raise it rather than hide it — otherwise the user has to press twice.
    local front = hs.application.frontmostApplication()
    if front and front:pid() == apps[1]:pid() then
      apps[1]:hide()
      return
    end
    placeAppCentered(appName, width, height)
    return
  end
  if #apps == 0 then
    hs.application.open(appName)  -- non-blocking
    local attempts = 0
    local function check()
      if placeAppCentered(appName, width, height) then return end
      if attempts < 30 then
        attempts = attempts + 1
        hs.timer.doAfter(0.2, check)
      end
    end
    hs.timer.doAfter(0.3, check)
  else
    placeAppCentered(appName, width, height)
  end
end

-- Remember the last-focused app within the current layout. Any time the user
-- activates an app that belongs to the current layout, record it so returning
-- to this layout later restores focus to the same app. Stored on M so
-- package.loaded holds a persistent reference.
M.layoutFocusWatcher = hs.application.watcher.new(function(appName, eventType)
  if eventType ~= hs.application.watcher.activated then return end
  if not currentLayout then return end
  local layout = getLayout(currentLayout)
  if not layout then return end
  for _, entry in ipairs(layout) do
    if entry.app == appName then
      lastFocused[currentLayout] = appName
      return
    end
  end
end)

-- ============================================================================
-- WIRING
-- ============================================================================

for _, o in ipairs(overlays) do
  hs.hotkey.bind(mod, o.key, function() toggleOverlay(o.app, o.width, o.height) end)
end

M.layoutFocusWatcher:start()

-- Public API for sibling modules (e.g. config/minimize_layout, config/composer).
M.apply          = apply
M.currentLayout  = function() return currentLayout end

-- Shared "F19 minimize-toggle is active" flag. config/minimize_layout owns it
-- (sets true when it surfaces other apps, false when it restores); config/
-- composer reads it to know a focus move must restore the hidden composition.
M.minimized      = false

-- True if an app with this exact name currently has a usable window (standard,
-- non-minimized, on the primary display). Apps the composer merely *hid* still
-- count — hide doesn't drop their windows — so only quit/windowless apps read as
-- absent. Used by the composer to decide whether a slot's app is still there.
M.appHasWindows  = function(name) return #windowsOfAll(findAppsExact(name)) > 0 end

-- Register a runtime-built layout table under `name` and apply it immediately.
-- Used by config/composer.lua for on-the-fly compositions. The registration
-- persists so currentLayout re-apply (minimize toggle) keeps working.
M.applyDynamic = function(name, layoutTable)
  dynamicLayouts[name] = layoutTable
  apply(name)
end

-- Hide every foreground app whose name isn't in `keep` (a set of app names),
-- so empty slots reveal the desktop instead of whatever window happened to sit
-- behind. Skips apps with a window on a secondary display (hide is all-or-nothing).
-- Unlike apply()'s reorder, this is unconditional — it isn't subject to the
-- skip-optimization — which is what the composer wants on every move.
M.hideOthers = function(keep)
  -- Cancel any in-flight clean-slate retry — this call supersedes it, and a stale
  -- retry could otherwise hide an app the new layout wants visible.
  if M._cleanSlateRetry then M._cleanSlateRetry:stop(); M._cleanSlateRetry = nil end
  -- A foreground app (other than Finder, which just backs the desktop) that
  -- should be hidden but isn't yet.
  local function visibleStraggler()
    for _, app in ipairs(hs.application.runningApplications()) do
      local name = app:name()
      if app:kind() == 1 and name ~= "Finder" and not keep[name]
          and not app:isHidden() and not wm.appHasWindowOnSecondary(app) then
        return true
      end
    end
    return false
  end
  local function pass(extraKeep)
    for _, app in ipairs(hs.application.runningApplications()) do
      local name = app:name()
      if app:kind() == 1 and not keep[name] and not (extraKeep and extraKeep[name])
          and not app:isHidden() and not wm.appHasWindowOnSecondary(app) then
        app:hide()
      end
    end
  end

  if next(keep) ~= nil then
    pass()        -- normal move: a slot app stays frontmost, so just hide the rest
    return
  end

  -- Clean slate (nothing kept): KEEP Finder visible as the desktop's backer.
  -- macOS auto-resurfaces a hidden app when no foreground app is left, so hiding
  -- Finder too would flash VSCode/etc back in — keeping Finder up prevents that.
  local needsEscalation = visibleStraggler()   -- snapshot before async hides
  pass({ Finder = true })
  if not needsEscalation then return end        -- already clean → no activate, no flash

  -- A real app was visible and the frontmost one can silently ignore hide() (a
  -- known macOS race). Surface the desktop only if Finder isn't already front
  -- (avoids a redundant activation flash), then re-hide stubborn stragglers until
  -- only Finder remains, capped so we never loop forever.
  local front = hs.application.frontmostApplication()
  if not (front and front:name() == "Finder") then
    local finder = hs.application.get("Finder")
    if finder then finder:activate() end
  end
  local tries = 0
  local function retry()
    tries = tries + 1
    pass({ Finder = true })
    if visibleStraggler() and tries < 6 then
      M._cleanSlateRetry = hs.timer.doAfter(0.1, retry)
    end
  end
  M._cleanSlateRetry = hs.timer.doAfter(0.06, retry)
end

-- Bring an entry's app to the front WITHOUT forcing a specific window, so the
-- window the user left on top (e.g. via Cmd-`) stays on top — apply() has
-- already restored the app's intra-app z-order before this runs.
M.focusEntry = function(entry)
  for _, app in ipairs(findAppsExact(entry.app)) do app:activate(true) end
end

return M
