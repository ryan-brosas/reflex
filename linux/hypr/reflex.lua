-- Reflex (linux/omarchy) — loaded from ~/.config/hypr/bindings.lua
--
-- The macOS app listens for a double tap of Option; Hyprland has no multi-tap
-- bindings, so Reflex gets two explicit chords instead. Omarchy already owns
-- SUPER ALT SPACE (apps menu), so ask sits on A.
--
-- Sessions open in the bar widget's own panel slot, so they never cover the
-- screen or take the keyboard away from your work. The ask window is a normal
-- tiled toplevel on the active workspace, closed with esc or the ✕ button.

o.bind("SUPER + ALT + R", "Reflex sessions and questions", "omarchy-shell shell toggle reflex.sessions '{}'")
o.bind("SUPER + ALT + A", "Reflex ask", "omarchy-shell shell summon reflex '{\"mode\":\"ask\"}'")

-- The ask surface is a normal toplevel and is deliberately NOT floated: it
-- tiles like every other app. Toggle floating with the usual Hyprland bind if
-- you want to drag it; the header drag and resize grip only apply then.
