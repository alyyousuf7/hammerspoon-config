-- Entry point. Each feature lives in its own file under config/.

-- Command-line bridge: lets `hs -c "..."` drive this config from a terminal.
require("hs.ipc")

local modules = {
  "config.window_management",
  "config.screens",
  "config.layouts",
  "config.composer",
  "config.minimize_layout",
  "config.notifier",
  "config.service_status",
  "config.bm_tradein_status",
  "config.otc_codes",
  "config.settings_watch",
}

-- Load each module in isolation so a syntax/runtime error in one doesn't
-- silently kill the rest of the config.
for _, mod in ipairs(modules) do
  local ok, err = xpcall(function() require(mod) end, debug.traceback)
  if not ok then
    hs.alert.show("Failed to load " .. mod, 4)
    print("Failed to load " .. mod .. ":\n" .. err)
  end
end

-- Auto-reload on save. Global because the main chunk has no return cache;
-- a top-level local here would be reclaimed once init.lua finishes running.
configWatcher = hs.pathwatcher.new(os.getenv("HOME") .. "/.hammerspoon/", function(files)
  for _, f in ipairs(files) do
    if f:sub(-4) == ".lua" then hs.reload(); return end
  end
end):start()

hs.alert.show("Hammerspoon config loaded")
