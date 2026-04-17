-- Named layout presets and centered overlay toggles.
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

-- ============================================================================
-- CONFIG
-- ============================================================================

-- Modifier for every binding in this file.
local mod = { "ctrl", "alt", "cmd" }

-- Layout definitions. Each entry: { app, rect = {x, y, w, h} in fractions, stack?, launch?, prefer? }
--   stack   = "vertical" to tile all windows of the app vertically in the rect.
--   launch  = true to open the app (non-blocking) if not already running.
--   prefer  = { titlePattern = "..." } — Lua pattern matched against each
--             window's AX title to pick a specific same-app window. For
--             Chrome, the AX title ends with the profile suffix (e.g.
--             " - Ali (Work)"), so `"%(Work%)$"` picks the Work-profile
--             window. Lua patterns differ from PCRE: escape magic chars
--             ( ) . % + - * ? [ ] ^ $ with a preceding `%`.
local layouts = {
  dev1 = {
    { app = "Code",                      rect = { 0,   0, 1/3, 1 } },
    { app = "Ghostty",                   rect = { 1/3, 0, 1/3, 1 } },
    { app = "Google Chrome for Testing", rect = { 2/3, 0, 1/3, 1 }, stack = "vertical" },
  },
  dev2 = {
    { app = "Code",                      rect = { 0,   0, 1/3, 1 } },
    { app = "Google Chrome",             rect = { 1/3, 0, 1/3, 1 } },
    { app = "Google Chrome for Testing", rect = { 2/3, 0, 1/3, 1 }, stack = "vertical" },
  },
  meeting = {
    { app = "Google Chrome", rect = { 0, 0, 1/2, 1 }, prefer = { titlePattern = "%(Work%)$" } },
    { app = "Google Meet",   rect = { 1/2, 0, 1/2, 1 }, launch = true },
  },
}

-- Layout hotkey bindings.
local layoutBinds = {
  { key = "pad1", layout = "dev1" },
  { key = "pad2", layout = "dev2" },
  { key = "pad3", layout = "meeting" },
}

-- Centered popup overlays. width/height default to 3/5 × 5/6 if omitted.
local overlays = {
  { key = "pad0", app = "Slack" },
}

-- Precomputed set of app names covered by any layout or overlay. Exposed on
-- M so sibling modules (e.g. minimize_layout) don't need to recompute it.
local handledSet = {}
for _, layout in pairs(layouts) do
  for _, entry in ipairs(layout) do handledSet[entry.app] = true end
end
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
local function windowsOfAll(apps)
  local wins = {}
  for _, app in ipairs(apps) do
    for _, win in ipairs(app:allWindows()) do
      if win:isStandard() and not win:isMinimized() then
        wins[#wins + 1] = win
      end
    end
  end
  return wins
end

-- Place windows of one layout entry into its rect. Appends to `placedAcc` if given.
-- `stack = "vertical"` slices the rect vertically across the windows;
-- otherwise every window is placed at the full rect (z-stacked overlap).
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
    if app:kind() == 1 and not layoutApps[app:name()] and not app:isHidden() then
      local ids = byApp[app:name()]
      if ids and #ids > 0 then
        savedAppZOrder[app:name()] = ids
      end
    end
  end

  -- Clean slate: hide every running foreground app that isn't part of this
  -- layout. Leaves only layout apps visible.
  for _, app in ipairs(hs.application.runningApplications()) do
    if app:kind() == 1 and not layoutApps[app:name()] and not app:isHidden() then
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

  -- Activate layout apps so their windows sit above non-layout apps. Activate
  -- the target app LAST so it ends up frontmost (regardless of its position
  -- in the layout array).
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

local function apply(name)
  local layout = layouts[name]
  if not layout then return end
  local missing = {}
  local placed = {}  -- all windows we positioned, in layout entry order

  -- Unhide layout apps that were hidden by a previous clean-slate or the F19
  -- toggle. Intra-app z-order is restored later in the sort comparator, which
  -- uses savedAppZOrder as the source of truth (more reliable than raising
  -- immediately after unhide — those raises don't always stick before we
  -- capture orderedBefore).
  for _, entry in ipairs(layout) do
    for _, app in ipairs(findAppsExact(entry.app)) do
      if app:isHidden() then app:unhide() end
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
    local wins = windowsOfAll(findAppsExact(entry.app))
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
  local targetFront = lastFocused[name]
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
    apps[1]:hide()
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
  local layout = layouts[currentLayout]
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

for _, b in ipairs(layoutBinds) do
  hs.hotkey.bind(mod, b.key, function() apply(b.layout) end)
end

for _, o in ipairs(overlays) do
  hs.hotkey.bind(mod, o.key, function() toggleOverlay(o.app, o.width, o.height) end)
end

M.layoutFocusWatcher:start()

-- Public API for sibling modules (e.g. config/minimize_layout).
M.apply          = apply
M.currentLayout  = function() return currentLayout end

return M
