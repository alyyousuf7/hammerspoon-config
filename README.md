# Hammerspoon config

Personal Hammerspoon setup for macOS window management, named layout presets,
centered overlay toggles, and desktop switching.

## Setup

```sh
brew install --cask hammerspoon
git clone https://github.com/alyyousuf7/hammerspoon-config.git ~/.hammerspoon
open -a Hammerspoon
```

Then:
1. Grant **Accessibility** permission when prompted (System Settings → Privacy & Security → Accessibility).
2. Click the menubar hammer icon → *Reload Config* to pick up the cloned files.
3. You should see a "Hammerspoon config loaded" toast.

Auto-reload is on — any subsequent save to a `.lua` file under
`~/.hammerspoon/` will reload the config automatically.

## Layout

```
~/.hammerspoon/
├── init.lua                       # Entry: loads modules, auto-reload watcher
├── config/
│   ├── window_management.lua      # Region placement + grow/shrink hotkeys
│   ├── layouts.lua                # Layout presets + overlay toggles
│   ├── minimize_layout.lua        # F19 toggle: hide current layout, surface the rest
│   └── spaces.lua                 # ⌃⌥⌘ ←/→ desktop switching
└── Spoons/                        # (not used yet; standard Hammerspoon plugin dir)
```

Each `config/*.lua` module is split into **CONFIG → LOGIC → WIRING** sections
so anything you'd normally tweak (hotkeys, sizes, app names) is grouped at the
top of its file.

## Hotkeys

All modifiers below:
- **`⌃⌥`** = `Control + Option`
- **`⌃⌥⌘`** = `Control + Option + Command`

### Window management (⌃⌥)

Instant-snap regions. Numeric keys use the **numpad only** (main-row digits are
reserved for layouts).

| Shortcut         | Action               |
|------------------|----------------------|
| `⌃⌥ Home`        | Left half            |
| `⌃⌥ PageUp`      | Right half           |
| `⌃⌥ F14`         | Center half          |
| `⌃⌥ pad4/5/6`    | First / center / last third |
| `⌃⌥ pad0`        | First two thirds     |
| `⌃⌥ pad.`        | Last two thirds      |
| `⌃⌥ F13 / F15`   | First / last fourth  |
| `⌃⌥ End`         | Bottom left quarter  |
| `⌃⌥ PageDown`    | Bottom right quarter |
| `⌃⌥ pad1..3`     | Bottom left / center / right sixth |
| `⌃⌥ pad7..9`     | Top left / center / right sixth    |
| `⌃⌥ Return`      | Maximize             |
| `⌃⌥ padEnter`    | Maximize             |
| `⌃⌥ pad+`        | Make larger (animated) |
| `⌃⌥ pad-`        | Make smaller (animated) |

### Layout presets (⌃⌥⌘)

Each hotkey arranges a fixed set of apps. Missing apps show a toast; apps
flagged `launch = true` auto-open.

| Shortcut      | Layout    | Arrangement |
|---------------|-----------|-------------|
| `⌃⌥⌘ pad1`    | `dev1`    | VSCode ¹⁄₃ · Ghostty ¹⁄₃ · Chrome for Testing (stacked) ¹⁄₃ |
| `⌃⌥⌘ pad2`    | `dev2`    | VSCode ¹⁄₃ · Google Chrome ¹⁄₃ · Chrome for Testing (stacked) ¹⁄₃ |
| `⌃⌥⌘ pad3`    | `meeting` | Google Chrome (Work profile) ¹⁄₂ · Google Meet ¹⁄₂ (auto-launches) |

Layout behavior:
- **Clean slate**: applying a layout hides every running foreground app that
  isn't in it. Only the layout's apps stay visible. This removes z-order
  competition and gives a consistent workspace every time.
- Multi-instance apps with `stack = "vertical"` tile all their windows vertically.
- Multi-instance apps without `stack` z-stack all their windows at the same rect.
- **Intra-app z-order is preserved** across layout switches — the Chrome window
  that was frontmost in your profile last time stays frontmost next time,
  even when Chrome was hidden by an intermediate layout.
- `prefer = { titlePattern = "..." }` picks a specific window of an app by
  AX-title Lua pattern — used in `meeting` to pull the Work-profile Chrome
  window forward (Chrome's AX title ends with `" - Ali (Work)"` / `"(Personal)"`).
- Focus is restored to the last-focused app of the layout across switches
  (e.g. leave `dev1` with Ghostty focused → come back → Ghostty is frontmost).
- If current frontmost is a layout app, it stays focused; otherwise first entry wins.
- No flicker on back-to-back triggers (z-order check skips redundant raises).

### Minimize layout (⌃⌥⌘)

| Shortcut      | Action |
|---------------|--------|
| `⌃⌥⌘ F19`     | Hide the current layout's apps and surface everything else (Mail, Calendar, Notion, etc.) so you can check on the stuff you normally keep out of sight. Press again to restore the layout. |

Notes:
- Remembers the last-focused app in "surfaced" mode — next toggle restores
  the same top-of-stack.
- Apps with only non-window entries (Finder's desktop, menu extras, floating
  panels) are skipped so activation always surfaces a visible window.

### Overlay toggles (⌃⌥⌘)

Centered "popup" — first press brings the app forward, second press hides it.

| Shortcut      | App    |
|---------------|--------|
| `⌃⌥⌘ pad0`    | Slack  |

Default size: 60% width × 83% height, centered.

### Space switching (⌃⌥⌘)

| Shortcut        | Action                |
|-----------------|------------------------|
| `⌃⌥⌘ →`         | Next desktop           |
| `⌃⌥⌘ ←`         | Previous desktop       |

Uses `hs.spaces.gotoSpace` (not keystroke synthesis).

## Customizing

**Add a layout**: edit `config/layouts.lua`, add a key to the `layouts` table
and a matching entry in `layoutBinds`. Entry fields: `rect` (required),
`stack`, `launch`, `prefer` (all optional — see inline doc above `layouts`).

```lua
local layouts = {
  -- ...existing...
  writing = {
    { app = "Obsidian",      rect = { 0,   0, 2/3, 1 } },
    { app = "Google Chrome", rect = { 2/3, 0, 1/3, 1 },
      prefer = { titlePattern = "%(Personal%)$" } },  -- pick Personal profile
  },
}

local layoutBinds = {
  -- ...existing...
  { key = "pad4", layout = "writing" },
}
```

**Add an overlay**: append to `overlays` in `config/layouts.lua`.

```lua
local overlays = {
  { key = "pad0", app = "Slack" },
  { key = "pad7", app = "Fantastical", width = 2/3, height = 3/4 },
}
```

**Tune spacing / animation**: top of `config/window_management.lua`.

```lua
local outerGap        = 8     -- window ↔ screen edge
local innerGap        = 8     -- between two adjacent windows
local placeAnimation  = 0     -- instant snap for region placement
local resizeAnimation = 0.2   -- animated grow/shrink
local minWindowSize   = 200   -- floor when shrinking
```

## Conventions

- App identifiers are **exact** `app:name()` matches, not substrings — this
  matters for distinguishing `Google Chrome` from `Google Chrome for Testing`.
  Find an app's exact name via:
  ```sh
  defaults read "/Applications/<name>.app/Contents/Info" CFBundleName
  ```
- `wm.placeWindow(win, x, y, w, h)` is the one primitive for positioning —
  takes fractional coords, applies gap padding, calls `setFrame` with the
  configured placement animation.
- Watchers must stay referenced or Lua GC reclaims them. `layouts.lua`
  returns a module table holding its watcher (persists via `package.loaded`);
  `init.lua` uses a global because the main chunk has no return cache.

## Reload / debugging

- **Auto-reload** on saving any `.lua` file under `~/.hammerspoon/`.
- **Manual reload**: menubar icon → *Reload Config*.
- **Console for errors**: menubar icon → *Console…*.
