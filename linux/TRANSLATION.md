# Translating the macOS app to Omarchy / Wayland

The Swift app is not a client of reflexd; it is a macOS *environment* wrapped
around it. So the port is a translation, not a rewrite: each surface the app
owns has to be handed to the thing on this desktop that already owns it. This
file is that map, with evidence (what each Swift file actually calls) and the
state of each translation.

Two kinds of work show up below. Most rows are **substitutions** — a macOS
facility replaced by the Wayland/Omarchy facility that does the same job, wired
to the same `reflexd` API. A few are **deletions**: the macOS permission model
exists because macOS gates input and screen APIs, and Wayland does not gate the
equivalents, so the onboarding step and the permission prompt simply go away.

## Already translated

| macOS | Where it lives | Wayland / Omarchy | Status |
|---|---|---|---|
| `NSStatusItem` + `NSMenu` (icon, counts, click opens the question, right-click menu) | `ReflexApp.swift` (24 calls) | `bar-widget` plugin in the Omarchy bar: three state dots, a waiting count, popup with questions and sessions, right-click opens the ask bar | **done** — `reflex.sessions`, verified with 27 live sessions |
| `NSPanel` popover beside the icon | `Panels.swift`, `MenuBar.swift` | `qs.Ui.KeyboardPanel` (layer-shell popup anchored to the bar slot) | **done** |
| `NSPanel` ask bar, centered, summonable | `CommandBar.swift` (80 KB) | `overlay` plugin: full-screen scrim + centered card, `WlrKeyboardFocus.Exclusive` | **done** — `reflex` |
| `RegisterEventHotKey` (global hotkeys) | `Hotkey.swift` (Carbon) | Hyprland binds, `o.bind(...)` in `bindings.lua` (or `bindd` in `bindings.conf`) | **done** — installer detects which config style the session reads |
| Daemon lifecycle: spawn `reflexd`, env, token, port, watch, restart, log | `Daemon.swift` | systemd user unit + `EnvironmentFile` + `Restart=on-failure` + journal | **done** |
| Keychain (`SecItemAdd`) for the Jev key | `Settings.swift` | `~/.config/jev-fabric/pi-env.sh` sourced by the service wrapper (`JEV_CREDENTIAL_COMMAND`) | **done**, no secret copied |
| App themes (`Themes.swift`: dark/light palette) | `Themes.swift` | the plugin uses `Commons.Color` / `Style`, so it follows the active Omarchy theme | **done** |
| Keystroke injection into an agent's TUI | `CommandBar.swift` → herdr socket | herdr `pane.send_keys` / `pane.send_text`, already behind `/api/keys` and `/api/text` | **done** (no input injection needed at all) |
| Rendering questions/options parsed from a screen | `Asks.swift` + `daemon/Core.bend` | same daemon code, rendered by the two plugin surfaces | **done** |

## Next, with the route already clear

| macOS | Where it lives | Wayland / Omarchy | Route |
|---|---|---|---|
| `NSPanel` edge tab + rail on the right screen edge, hover to reveal, reserved strip | `EdgeStrip.swift` (63 KB), `EdgeReveal.swift` (`NSScreen`, `CGWindowList` 28 calls) | layer surface on `WlrLayer.Overlay` with `exclusiveZone` for the reserved strip and a 2‑px `HoverHandler` trigger | a third plugin, `panel` kind; the bar widget already carries the same state, so this is presentation only |
| `SwiftTerm` terminal (38 calls in `AgentPopout.swift`) attached through herdr | `AgentPopout.swift` | `xdg-terminal-exec herdr agent attach <pane>` in Alacritty/foot; font and colours come from the terminal theme | one line in the widget's agent action; no renderer to port |
| `NSOpenPanel` + drag-and-drop images (`registerForDraggedTypes`) | `Attachments.swift`, `CommandBar.swift` | `wl-paste --list-types` / `wl-paste -t image/png`; QML `DropArea` for `text/uri-list` | pasted image path → `/api/route` as the app does today |
| `NSWorkspace.open` / activate / hide (reveal in Finder, open URL, focus the app) | `OpenIn.swift`, `AgentPopout.swift` | `xdg-open`, `hyprctl dispatch focuswindow`, `omarchy-launch-or-focus-webapp` | small helpers in the plugin |
| `IOPSGetPowerSourceDescription` + `IOPMAssertion` (battery, keep awake while agents work) | `KeepAwake.swift` (9 calls) | `systemd-inhibit --what=idle` held while state says working; battery from `/sys/class/power_supply` or `omarchy-battery-status` | a `service`-kind plugin, or a `reflexd` side effect |
| Sparkle updater + "newer herdr/jev-fabric" rows | `Updater.swift`, `MenuBar.swift` | `herdr update` and git + `linux/install-omarchy.sh`; surface as bar menu rows | the app's release channel has no Linux artefact to update to |
| Phone pairing QR | `Pairing.swift`, `Tailnet.swift` | the phone page is unchanged; render `/api/pair` as a QR (`qrencode` or a QML QR component) in a popup | reflexd already serves `web/` and `/api/pair` |
| Other Macs: SSH tunnels forwarding each machine's herdr socket into `data/machines/<m>.sock` | `Machines.swift`, `MachineSetup.swift`, `RemoteIndex.swift` | `ssh -N -L` units (or `autossh`), one per saved machine; herdr's own `herdr machine add` is the source of truth | reflexd already speaks `machine:/path` and `machine/pane`, so only the tunnel manager is missing |
| Onboarding flow (66 KB of checks and copy) | `Onboarding.swift` | `linux/install-omarchy.sh` prints the same checks; a `reflex doctor` could report herdr/jev-fabric/token state | deliberately not a GUI |

## Gone, not translated

- **Accessibility permission** (`AXIsProcessTrusted`, `Hotkey.swift`). macOS asks
  for it because global hotkeys and edge detection read other apps' input and
  window geometry. Hyprland binds and `Hyprland.focusedMonitor` need no grant, so
  there is no prompt to design and no `AccessGuide.swift`.
- **`NSApplication` activation policy tricks** (no Dock icon, accessory app,
  menu-bar-only mode). A layer-shell surface is never in the task switcher.
- **Screen recording / window enumeration** (`CGWindowList` in
  `EdgeReveal.swift`, used to know when a terminal is present). Quickshell
  reads Hyprland's own toplevel events instead.

## Rules that keep this translation honest

1. **The daemon stays the only brain.** No routing, ranking or question
   parsing on this side; the plugin calls `/api/…` and renders the answer. When
   `daemon/Model.bend` grows an action, one line in the plugin maps it.
2. **Take the desktop's owner, not a copy of it.** Bar slots, popups, hotkeys,
   themes and terminals already exist here; the layer plugs into them rather
   than reimplementing a Mac inside a window.
3. **Say what is missing.** Every row above is either verified on this machine
   or listed as not built; nothing is stubbed to look finished.
