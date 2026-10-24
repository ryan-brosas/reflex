-- Reflex (linux/omarchy) — loaded from ~/.config/hypr/bindings.lua
--
-- The macOS app listens for a double tap of Option; Hyprland has no multi-tap
-- bindings, so Reflex gets two explicit chords instead. Omarchy already owns
-- SUPER ALT SPACE (apps menu), so ask sits on A.
--
-- Both go through omarchy-shell, which owns the layer surfaces: the overlay
-- lands on the focused output and closes with esc.

o.bind("SUPER + ALT + R", "Reflex sessions", "omarchy-shell shell toggle reflex '{}'")
o.bind("SUPER + ALT + A", "Reflex ask", "omarchy-shell shell summon reflex '{\"mode\":\"ask\"}'")
