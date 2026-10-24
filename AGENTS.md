# Agent Rules

The user's global `AGENTS.md` supplies standing rules. This file adds
project-specific context, not exceptions. Surface conflicts for clarification.

Reflex upstream is a macOS menu-bar app. **On this machine it runs as the Linux
layer**: `reflexd` (Bend) is the whole product — one daemon on `127.0.0.1`, a
normal ask window (tiled by Hyprland), a bar widget, a systemd user service and
two Hyprland chords. `app/` (Swift/AppKit) cannot be built or observed here; `web/` is served
by the daemon for the phone.

Read `linux/README.md` before changing the layer: it is the operating guide.
`linux/TRANSLATION.md` maps each macOS surface to its Omarchy replacement and
lists what is not built yet. `docs/design.md` is the visual language.

## This environment (verified 2026-10-24)

| Piece | Live |
|---|---|
| OS / compositor | Omarchy 4.0.6-1 (Arch), Hyprland 0.56.2 |
| Shell | Quickshell 0.3.2 via `omarchy-shell` (owns layer surfaces, bar, theme) |
| Agents | herdr 0.9.1, socket `~/.config/herdr/herdr.sock`; no saved SSH machines |
| Daemon | `~/.local/lib/reflex/reflexd` on `127.0.0.1:47823`; `/api/health` → `{"ok":true,"service":"reflexd"}` |
| Routing | `~/.local/bin/jev-fabric`; credential resolved by `~/.config/jev-fabric/pi-env.sh`, sourced by the service wrapper |
| Service | user unit `reflexd.service`, enabled and active; `journalctl --user -u reflexd` |
| UI | ask window plugin `reflex` (normal toplevel); embedded terminal, SSH machines and guided setup windows in the same plugin; bar widget `reflex.sessions` (sessions + questions, right bar section in `~/.config/omarchy/shell.json`), including the 6 px right-edge hover rail |
| Session index | user timer `reflex-sessions.timer` / `reflex-sessions.service`; `sessions.tsv` under `~/.local/state/reflex/`; powers `/resume` |
| Machines | `reflex-machines` profiles under `~/.config/reflex/machines/`; transient `reflex-machine-<label>.service` units; `reflex-machines.timer`; sockets and `list` under `~/.local/state/reflex/machines/` |
| Chords | Hyprland reads Lua here: `~/.config/hypr/bindings.lua` → `~/.config/reflex/hypr/reflex.lua`; `SUPER ALT R` bar panel, `SUPER ALT A` ask window |

A live `/api/state` at that check reported `herdr:true`, 27 agents, 6 folders.
Hyprland loads `hyprland.lua` → `bindings.lua` here, so the classic
`bindings.conf` source line is inert and absent; the Lua pair is the live path.

## Where a change goes

| Change | Edit | Apply |
|---|---|---|
| routing, questions, endpoints | `daemon/*.bend` | `linux/build-linux.sh`, `linux/install-omarchy.sh`, `systemctl --user restart reflexd` |
| ask/terminal/machines/setup windows | `linux/omarchy/plugin/*.qml`, `Terminal.js` | reinstall, then `omarchy-restart-shell` |
| bar widget (sessions + questions + edge rail) | `linux/omarchy/panel/*.qml` (installs as `reflex-sessions`) | same |
| earlier-session index | `linux/bin/reflex-sessions`, `linux/systemd/reflex-sessions.*.in` | reinstall; `systemctl --user enable --now reflex-sessions.timer` |
| phone pairing, remote bind, doctor, setup | `linux/bin/reflex-pair`, `linux/bin/reflex-remote`, `linux/bin/reflex-doctor`, `linux/omarchy/plugin/SetupWindow.qml` | reinstall; menu refresh; `reflex-remote off` restores loopback |
| SSH machine profiles/tunnels | `linux/bin/reflex-machines`, `linux/systemd/reflex-machines.*.in` | reinstall; menu refresh; `/machines` or `reflex-machines add` |
| herdr lifecycle | `linux/systemd/herdr.service.in`, `linux/bin/reflex-start-herdr` | reinstall; unit is enabled for the next login |
| chords | `linux/hypr/reflex.lua` (plus `.conf` for the other config style) | reinstall or copy, then `hyprctl reload` |
| service, env, token | `linux/systemd/reflexd.service.in`, `linux/bin/reflexd-service` | reinstall, `systemctl --user daemon-reload`, restart |
| phone page | `web/index.html` | reinstall (the daemon serves it) |
| menu rows (`reflex.ask`, `reflex.questions`, `reflex.pair`, `reflex.doctor`, `reflex.setup`, `reflex.machines`) | `linux/omarchy/extensions/reflex-menu.json` + `linux/bin/reflex-menu.py` | reinstall, then `omarchy menu refresh` |
| agent-facing MCP (read-only) | `linux/mcp/reflex-mcp.ts` | reinstall, then register per harness (`linux/README.md`) |

## Check

```sh
linux/build-linux.sh                  # checks Core Route Index Http Model Js, builds build/reflexd
bend daemon/PROOF.bend --check-only   # laws: "ALL PROOFS CHECK"
```

A build is not the layer working. After install, read the live surface:

```sh
curl -s -H "authorization: Bearer $(cat ~/.config/reflex/token)" \
  http://127.0.0.1:47823/api/state
omarchy-shell shell summon reflex '{}'      # sessions and questions
```

Green means the state carries `herdr:true` with your agents and folders, and the
bar panel lists them. `daemon/tests/*.bend` are behavior tests: run them only when
the human asks.

## Project rules

- **The daemon is the only brain.** Routing, ranking and question parsing live in
  `daemon/`; QML calls `/api/*` and maps action kinds (`spawn`, `prompt`,
  `resume`, `press`, `btw`/`fork`). No logic in a `.qml`.
- **Use the desktop's owner, not a copy of it.** Bar slot, layer surface
  (`omarchy-shell shell summon`/`toggle`), theme (`Commons.Color`, `Style`),
  focus (`WlrKeyboardFocus.Exclusive`) and terminal (`xdg-terminal-exec herdr
  agent attach`) already exist in Omarchy.
- **Keep the portability seam.** `daemon/` (Bend plus POSIX `host.c`), `web/` and
  `scripts/` are shared with macOS: nothing platform-specific outside `linux/`,
  and the layer stays reversible so the fork still merges.
- **Installed copies are what runs.** `~/.local/lib/reflex/`,
  `~/.config/omarchy/plugins/` and `~/.config/reflex/` are the live artifacts.
  The shell starts with `QS_DISABLE_FILE_WATCHER=1`, so a QML edit is inert
  until `omarchy-restart-shell`; a daemon edit needs install and a service
  restart.
- **Use the owning skills, not a fresh reading.** `desktop-platform-translation`
  owns this kind of port and `omarchy` (with its `plugins.md`) owns bar,
  surface and plugin mechanics; `runtime-artifact-provenance` and
  `local-service-durability` explain "it doesn't show up"; `herdr --skill` is
  the live herdr CLI authority; `bend-coding-practices` applies inside `daemon/`.
- **Say what is missing.** `linux/TRANSLATION.md` lists what is still absent
  or partial: IME composition with a configured engine and unsupported
  full-screen apps still need `external`; the bar's reply/gist inbox is
  read-only and a battery readout does not apply to this desktop. fcitx5 Pinyin
  is installed as an alternate, and native `foot` and Alacritty terminals showed
  preedit, candidates and a committed CJK character. The ask/terminal TextInput sinks
  never gain a fcitx context, including in a minimal standalone Quickshell
  `TextInput`, so embedded CJK composition is unverified and must use
  `external`. Embedded terminal frames, alternate screen,
  wide characters, mouse, wheel, text input, resize and a read-only `history`
  view, SSH sockets, the remote folder index, `@machine`, pairing, attachments,
  the reserved rail, `reflex-doctor`, Settings and the seven-step guided setup
  exist. Do not stub a missing surface to look finished.

## Traps

- **Bend is pinned, not global.** Installed `bend` is 2.0.37; `daemon/main.bend`
  needs 2.0.39 for `TCP.send`'s written-byte list. `linux/fetch-bend.sh` installs
  the pinned copy under `build/tools`, and `linux/build-linux.sh` prefers it
  before `$BEND` or PATH. Do not run `bend update` or change the global copy
  without checking other Bend projects. `--check-only` on `PROOF` still passes
  on 2.0.37, but the build gate does not.
- **The port is compiled into the plugins.** `Api.qml` hardcodes
  `http://127.0.0.1:47823`; changing `REFLEX_PORT` without editing it and
  reinstalling leaves the UI talking to nothing.
- **401** means `~/.config/reflex/token` and `REFLEX_TOKEN` in
  `~/.config/reflex/env` disagree. **"Missing provider key"** means the service
  env has no jev-fabric credential.
- **Agents in `/api/state` but an empty panel/window** is a stale compiled plugin:
  `omarchy-restart-shell`.
- `scripts/reflex-scan.sh` must try BSD then GNU `stat` (`mtime()`); a GNU-only
  path reports every folder as age 0 and reorders the index.
- Re-running `install-omarchy.sh` rewrites `~/.config/reflex/env` (token kept).
  Export `REFLEX_ROOTS` and `REFLEX_HARNESS` first or hand edits are lost.
- `uninstall-omarchy.sh` removes both plugin ids through `omarchy plugin
  remove`; when the manager is unavailable it deletes the directories and
  rescans, but a hand-added `shell.json` slot can survive. Check
  `omarchy plugin list --json` after an uninstall.
- **herdr is supervised, but only as its own service.** `herdr.service` is
  installed and enabled; it starts `herdr server` headless at login. A
  terminal-owned server already running is deliberately left alone by install
  and upgrade — stopping it would kill every pane. `uninstall-omarchy.sh`
  removes the Reflex helper but leaves `herdr.service`, because herdr outlives
  Reflex.
- `/api/state` with `herdr:false` means the socket is stale and every list is
  empty. The glyph dims; clicking it runs `reflex-start-herdr`, which starts
  the unit and only falls back to `omarchy-launch-terminal-herdr` if that
  fails. It never starts herdr silently.
- The ask surface is a `FloatingWindow` titled `Reflex`, not a layer, and it
  is deliberately **not floated**: Hyprland tiles it like any other app. There
  is no `o.window({ title = "^Reflex$" ... })` float/move/size rule in
  `reflex.lua`; do not add one unless the user asks for a floating mode. The
  header calls `startSystemMove` and carries minimize/maximize/close, and the
  bottom-right grip calls `startSystemResize`; both only apply when the user
  toggles the window floating with the compositor. Minimize sets the plugin's
  `hidden` flag (Wayland has no minimize request), so the next summon restores
  the query and mode. Maximize runs `hl.dsp.window.fullscreen(1)`;
  Quickshell's `FloatingWindow.maximized` is a no-op on this compositor.
  Re-summoning an open window raises it with
  `hyprctl eval 'hl.dispatch(hl.dsp.focus({ window = "title:^Reflex$" }))'`;
  that is the Lua Hyprland syntax this machine runs.
- `/api/route` is a write unless `"dry": true`. The ask window must request the
  decision with `dry` and then call one of `/api/spawn`, `/api/send`,
  `/api/resume`, `/api/keys` or `/api/side`; a reply carrying `dispatch`
  means the daemon already wrote, so never run it again. The Mac app parses its
  slash tokens client-side; the Linux QML strips `/claude`, `/pi`, `/codex`
  prefixes and sends `harness`, and handles `/new`, `/folder`, `/resume`,
  `/btw`, `/paste`, `/attach`, `/pair`, `/settings` and `/setup` itself.
  `@machine` is forwarded as the route's `machine` field; `reflex-machines`
  supplies the tunnel and remote folder cache, and no machine is saved by
  default.
- The Omarchy menu file is user-owned and also carries the schema comments and
  workspan/herdr rows. Install and remove the Reflex group through
  `linux/bin/reflex-menu.py` (the installer does), never by replacing the whole
  file.
- The bar panel is `reflex.sessions`; a toast click opens that panel, not the
  ask window. Keep the two entry points separate.
- **The MCP surface is read-only on purpose.** `linux/mcp/reflex-mcp.ts`
  must not gain `send`/`spawn`/`answer`/`keys`: an agent that can dispatch or
  answer for other agents needs its own decision, not a side effect of reading
  state.
- **The question toast belongs to the focused output.** Every monitor runs its
  own bar widget; only the focused one notifies, and it replaces the previous
  toast rather than stacking. Other monitors record the count silently.
- `/usr/share/omarchy/` is package-owned: read it, never edit it.
- `linux/omarchy/panel/` is the bar widget. Its 6 px right-edge hover rail is
  a `PanelWindow` with `ExclusionMode.Ignore`; a separate `railReserve`
  `PanelWindow` uses `exclusiveZone: 6` and `ExclusionMode.Normal` so the
  strip is reserved once and hover growth cannot reflow windows. Set
  `REFLEX_RAIL_RESERVE=0` to opt out. There is no separate third plugin.
- The embedded terminal is **control-backed + pane input**, not a second PTY:
  `TerminalWindow.qml` runs `herdr terminal session control`, paints its JSON
  frames, and writes `terminal.input` / `terminal.mouse` / `terminal.scroll` /
  `terminal.resize`; named keys use `pane send-keys`, and `history` uses local
  primary-screen rows with a `pane read` fallback before the first scroll. It
  does not pass `--takeover`. `external` remains the native terminal.
  `Terminal.js` is the parser; test it with real frames, not a hand-written
  strip.
- `reflex-machines` is the machine owner: profiles in
  `~/.config/reflex/machines/*.conf`, local sockets and `list` under
  `$REFLEX_DATA/machines/`. The daemon only reads `list` and `<label>.sock`;
  never write agents directly. The timer reconciles transient
  `reflex-machine-<label>.service` units, and a profile needs a live remote
  herdr socket. `reflex-machines index` runs `scripts/reflex-scan.sh` over SSH
  into `machines/<label>.folders`; reflexd merges those folders for
  `/api/folders?machine=` and `@machine`. Optional `SSH_IDENTITY` and
  `SSH_KNOWN_HOSTS` profile fields cover non-default keys and host files.
- Setup, machines and terminal windows each request activation after mapping;
  Hyprland does not focus a fresh toplevel. Their custom close signal is
  `dismissed`, not `closed` (Window already owns `closed`).
- QML object ids are lexical, not properties of `root`: `searchTimer.restart()`
  works, `root.searchTimer.restart()` throws and leaves the previous rows on
  screen. The folder dialog is the native `folderDialog` (no external zenity
  process); pair, terminal, machines and setup are separate `FloatingWindow`s
  with their own focus timers.
- Pairing calls `reflex-remote on` and binds `REFLEX_BIND=0.0.0.0`; the QR
  carries only the one-time code, never the bearer token. `reflex-remote off`
  restores `127.0.0.1`; closing an unscanned card or letting the code expire
  does that automatically, while a successful pair leaves it on. Do not print
  the token or put it in the QR/plugin.
- The other-Mac surfaces are unexercised here (`herdr machine list` is empty),
  and `app/`, `film/`, `scripts/build-app.sh`, `scripts/release.sh` are
  macOS-only.

## Dangerous project operations

- `linux/install-omarchy.sh` restarts the Omarchy shell and `reflexd`, and edits
  `~/.config/hypr/bindings.lua` after a timestamped backup.
- `linux/uninstall-omarchy.sh --purge` deletes `~/.config/reflex` (token) and
  `~/.local/state/reflex` (routing memory, folder index). Without `--purge` both
  are kept.
- The bearer token and the Jev credential are secrets (0600). Never print,
  commit or copy them into a unit file or plugin; the service wrapper sources
  `pi-env.sh` so the credential stays out of the unit.
