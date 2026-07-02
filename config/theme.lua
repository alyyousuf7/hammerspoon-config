-- Shared visual design tokens for the config's on-screen HUD surfaces.
--
-- Born from the composer overlays (minimap, preset panel, app switcher) — a
-- translucent charcoal "HUD material" with a hairline top-light edge, a large
-- soft window shadow, SF Pro Text type, and the macOS system accent used as a
-- tint/badge color (never as body-text color). Centralizing it here so the
-- notifier pills and composer panels share one source of truth instead of each
-- re-deriving the same literals.

local T = {}

-- ----------------------------------------------------------------------------
-- Palette
-- ----------------------------------------------------------------------------

T.ACCENT = { red = 0.0, green = 0.478, blue = 1.0, alpha = 1 }   -- #007AFF

function T.withAlpha(co, a)
  return { red = co.red, green = co.green, blue = co.blue, alpha = a }
end

-- Status colors for notices (also fine as accents elsewhere).
T.GREEN = { red = 0.20, green = 0.78, blue = 0.35 }
T.AMBER = { red = 1.00, green = 0.80, blue = 0.20 }
T.ORANGE = { red = 1.00, green = 0.50, blue = 0.10 }
T.RED   = { red = 0.95, green = 0.20, blue = 0.20 }
T.BLUE  = { red = 0.40, green = 0.60, blue = 0.95 }

-- ----------------------------------------------------------------------------
-- HUD material — the charcoal panel background. Use PANEL_FILL/HAIRLINE/SHADOW
-- on a rounded rectangle, leaving MARGIN of empty canvas around it so the
-- shadow has room to render (canvas shadows clip to the canvas bounds).
-- ----------------------------------------------------------------------------

T.PANEL_FILL = { white = 0.10, alpha = 0.92 }
T.HAIRLINE   = { white = 1, alpha = 0.18 }      -- top-light stroke, 1px
T.SHADOW     = { blurRadius = 32, color = { alpha = 0.55 }, offset = { h = -11, w = 0 } }
-- Same look scaled for small surfaces (pills/badges); needs less canvas margin.
T.SHADOW_SM  = { blurRadius = 16, color = { alpha = 0.50 }, offset = { h = -3, w = 0 } }

-- ----------------------------------------------------------------------------
-- Text
-- ----------------------------------------------------------------------------

T.FONT_SEMIBOLD = "SFProText-Semibold"
T.FONT_REGULAR  = "SFProText-Regular"

T.TEXT     = { white = 0.96, alpha = 1 }   -- primary
T.TEXT_DIM = { white = 0.55, alpha = 1 }   -- secondary

-- ----------------------------------------------------------------------------
-- Motion / shape
-- ----------------------------------------------------------------------------

T.FADE_IN  = 0.12
T.FADE_OUT = 0.18

return T
