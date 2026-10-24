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
| `NSStatusItem` + `NSMenu` (icon, counts, click opens the question, right-click menu) | `ReflexApp.swift` (24 calls) | `bar-widget` plugin in the Omarchy bar: the bolt glyph and waiting count, popup with questions and sessions, right-click opens the ask bar | **done** — `reflex.sessions`, verified live; per-agent dots live in the rail |
| `InboxView` replies and gists | `InboxView.swift` | bar panel lists questions, updates and sessions; a selected update shows a cleaned gist and, for a `ready` item, the last assistant reply from its session file | **done** — gist and reply helper exercised live; read-only and answered/opened through the daemon |
| `NSPanel` popover beside the icon | `Panels.swift`, `MenuBar.swift` | `qs.Ui.KeyboardPanel` in `linux/omarchy/panel/Bar.qml` (layer-shell popup anchored to the bar slot) | **done** |
| `NSPanel` ask bar, summonable | `CommandBar.swift` (80 KB) | normal tiled `FloatingWindow` titled `Reflex`; `SUPER ALT A` | **done** — no scrim, no exclusive keyboard grab; header controls |
| SettingsView (General, Edge & Rail, Terminal, Routing, Projects, Phone, Machines, Setup, About) | `SettingsView.swift`, `Settings.swift` | `SettingsWindow.qml` opened from `/settings`, the bar footer or the menu; every row calls the owning helper, daemon or systemd | **done** — nine-pane window; General, Terminal, Projects, Machines and About exercised live, with focus and section payloads |
| `RegisterEventHotKey` (global hotkeys) | `Hotkey.swift` (Carbon) | Hyprland binds, `o.bind(...)` in `bindings.lua` (or `bindd` in `bindings.conf`) | **done** — `linux/install-omarchy.sh` detects which config style the session reads |
| Daemon lifecycle: spawn `reflexd`, env, token, port, watch, restart, log | `Daemon.swift` | systemd user unit + `EnvironmentFile` + `Restart=on-failure` + journal | **done** |
| Keychain (`SecItemAdd`) for the Jev key | `Settings.swift` | `~/.config/jev-fabric/pi-env.sh` sourced by `linux/bin/reflexd-service` (`JEV_CREDENTIAL_COMMAND`) | **done**, no secret copied |
| App themes (`Themes.swift`: dark/light palette) | `Themes.swift` | the plugin uses `Commons.Color` / `Style`, so it follows the active Omarchy theme | **done** |
| Keystroke injection into an agent's TUI | `CommandBar.swift` → herdr socket | herdr `pane.send_keys` / `pane.send_text`, already behind `/api/keys` and `/api/text` | **done** (no input injection needed at all) |
| Rendering questions/options parsed from a screen | `Asks.swift` + `daemon/Core.bend` | same daemon code, rendered by the two plugin surfaces | **done** |
| `sessions.tsv` written by the Mac app (earlier sessions for resume) | the Mac app's state directory | `reflex-sessions.service` + timer indexes Claude/pi/Codex session files on the cadence in `reflex-sessions.timer` and drops live herdr panes; `/api/sessions` serves the same table to the ask line | **done** — `reflex-sessions.timer` active |
| Phone pairing QR (`Pairing.swift`) | `Pairing.swift`, `Tailnet.swift` | separate pair `FloatingWindow`; `reflex-pair` writes a one-time code, `reflex-remote on` opens the phone bind, `qrencode` renders the LAN or running-Tailscale URL; `/api/pair` trades and wipes it | **done** — QR decoded live; the QR carries no token |
| `SwiftTerm` terminal (38 calls in `AgentPopout.swift`) attached through herdr | `AgentPopout.swift` | `TerminalWindow.qml` runs `herdr terminal session control`, paints its JSON frames and sends `terminal.input` / `terminal.mouse` / `terminal.scroll` / `terminal.resize`; alternate screen, wide cells and application cursor keys are parsed; `history` uses local primary-screen rows and falls back to `herdr pane read`; `external` opens a native attached terminal | **done** — frames, text, Return, named keys, resize, mouse click, btop, less, nvim, yazi and fzf full-screen entry/exit, application-cursor arrows, local history and wide-character rendering exercised; TextInput composition sink exists but is non-functional; fcitx5 Pinyin is installed but Quickshell's TextInput surfaces (including a minimal standalone TextInput) do not receive a fcitx input context, so CJK composition remains external; native `foot` and Alacritty showed Pinyin preedit, candidates and a committed CJK character through `external` |
| Other Macs: SSH tunnels forwarding each machine's herdr socket into `data/machines/<m>.sock` | `Machines.swift`, `MachineSetup.swift`, `RemoteIndex.swift` | `reflex-machines` profile + `ssh -N -L` transient unit, with `reflex-machines.timer` reconciling; `MachinesWindow.qml` adds/connects/removes; optional `SSH_IDENTITY` and `SSH_KNOWN_HOSTS` | **partial** — agents, tunnel, remote folder scan and `/api/folders?machine=` exercised against a disposable loopback sshd; a real SSH host is not verified and no remote machine is saved on this box |
| Onboarding flow (66 KB of checks and copy) | `Onboarding.swift` | `reflex-doctor` readiness window plus `SetupWindow.qml` seven steps (welcome, checks, terminal, projects, machines, phone, ready); menu row `/setup` | **done** — steps and doctor render live; Mac copy is not reproduced word-for-word |
| Client-side slash tokens (`/new`, `/folder`, `/resume`, `/btw`, `/paste`, `/pair`, `/doctor`, `/machines`, `/settings`, `/setup`, `@machine`) | `CommandBar.swift` (`Token`, `apply`) | the ask line parses the tokens before the dry route: `/new` names a folder under `~/Projects`, `/folder` opens the native Qt folder dialog, `/resume` lists the local session index, `/btw` sends `/api/side`, `/paste` reads a copied file/image, `/pair` opens the QR card, `/doctor` opens readiness, `/machines` manages SSH profiles, `/settings` opens Settings, `/setup` starts setup; `@machine` is sent as the route's `machine` field | **done** — `@machine` routes to a saved profile; remote folders appear after `reflex-machines up` |
| `NSOpenPanel` + drag-and-drop images | `Attachments.swift`, `CommandBar.swift` | QML `DropArea`, `/attach` and `reflex-attach-paste` append local paths; image rows show a thumbnail and click-to-remove | **done** for local files/images; text clipboards are not attachments |
| `NSPanel` edge tab + rail on the right screen edge, hover to reveal | `EdgeStrip.swift` (63 KB), `EdgeReveal.swift` | 6 px hover `PanelWindow` in `Bar.qml`, widening to 286 px; a separate `railReserve` `PanelWindow` with `exclusiveZone: 6` and `ExclusionMode.Normal` reserves the strip | **done** — `REFLEX_RAIL_RESERVE=0` opts out |
| `IOPSGetPowerSourceDescription` + `IOPMAssertion` (battery, keep awake while agents work) | `KeepAwake.swift` (9 calls) | `systemd-inhibit --what=idle` held by the focused output's bar widget while any agent is working | **partial** — inhibition works; no battery readout implemented |

## Still to wire

| macOS | Where it lives | Wayland / Omarchy | Route |
|---|---|---|---|
| `NSWorkspace.open` / activate / hide (reveal in Finder, open URL, focus the app) | `OpenIn.swift`, `AgentPopout.swift` | `xdg-open`, `hyprctl dispatch focuswindow`, `omarchy-launch-or-focus-webapp` | small helpers in the plugin |
| Sparkle updater + "newer herdr/jev-fabric" rows | `Updater.swift`, `MenuBar.swift` | `herdr update` and git + `linux/install-omarchy.sh`; surface as bar menu rows | the app's release channel has no Linux artefact to update to |

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
3. **Say what is missing.** Every row above is verified on this machine, marked
   **partial** with its verified boundary and remaining gap, or listed as not
   built; nothing is stubbed to look finished.
