# Reflex on Linux / Omarchy

Reflex is a macOS app with a portable core. This directory is the Linux layer:
it runs the same `reflexd` (Bend) daemon and gives it a Wayland front-end
built as an Omarchy 4 shell plugin, instead of rebuilding the Swift app.

    herdr (agent TUIs)  ←  reflexd (Bend, unchanged)  →  jev-fabric (Jev)
                                 │ HTTP, bearer token on 127.0.0.1
                                 ├── Omarchy shell plugin  (this layer's UI)
                                 └── web/index.html        (phone remote, unchanged)

Nothing in `daemon/` needed a platform port. Its only foreign code is
`daemon/host.c` (POSIX sockets, `poll`, `getppid`), herdr's socket lives at
`~/.config/herdr/herdr.sock` on both systems, and the two scripts it shells out
to are `/bin/sh`. What is not portable is `app/` — 35 Swift files of AppKit,
SwiftTerm and menu-bar code — so this layer replaces it rather than compiling it.

## What works today

Verified on Omarchy 4.0.6 / Hyprland 0.56.2 / herdr 0.9.1 / Bend 2.0.39:

- `reflexd` builds and runs as a systemd user service, and talks to this
  machine's herdr over its socket.
- **Sessions list** (`SUPER ALT R`): every live agent herdr reports, blocked
  ones first, with its state, folder and title. `enter` focuses that pane in
  herdr.
- **Questions** (`1` `2` `3` or `enter` on an option): inbox items that wait on
  you, with their options, answered through `POST /api/answer`. Claude Code's
  folder-trust prompt and its `AskUserQuestion` cards arrive this way.
- **Ask bar** (`SUPER ALT SPACE`): type a request, get Jev's ranked
  destinations with weights (its pick on top), and `enter` sends it —
  `spawn`, `prompt`, `resume`, `press` and `btw`/`fork` actions all map to
  their endpoint. Without a Jev credential the same list still appears from
  reflexd's own candidates and you pick the row.
- **Undo window**: pending dispatches appear with their countdown; `enter`
  cancels one.
- `/claude`, `/pi`, `/new` and the rest of the routing syntax work unchanged,
  because the daemon parses them, not this layer.

A real run: the ask bar routed `add tests to the reflex daemon` to
"new claude in reflex" at 90%, spawned Claude Code in the folder, and the
folder-trust prompt came back as a question card in the same overlay.

## What is not here yet

The macOS app is not a thin client: it also owns the edge rail, the menu-bar
icon, terminals, machine tunnels, pairing and keep-awake. Those are absent, not
stubbed:

| macOS surface | What it needs on Linux | Notes |
|---|---|---|
| Edge tab / rail on the right screen edge | a `bar-widget` plugin with counts, or a layer-shell surface with `WlrLayershell.layer: Top` and an exclusion zone | Hyprland has no hover-reveal reserved edge; the bar widget is the honest equivalent |
| Menu-bar icon with counts | the same bar widget, `omarchy-shell shell enablePlugin reflex.sessions '{"section":"right"}'` | the overlay has the counts today, in its header |
| Embedded terminals (SwiftTerm + herdr attach) | `herdr agent attach <pane>` in the user's terminal (`xdg-terminal-exec`) | `enter` currently focuses herdr's own pane instead |
| ⌥⌥ double-tap | `SUPER ALT SPACE` | Hyprland bindings cannot fire on a multi-tap |
| Phone pairing QR | serve `web/` to the phone (reflexd already does) and show the QR from `/api/pair` | needs Tailscale reachable from the host |
| Other Macs over SSH | `herdr machine add` plus tunnels (the app opened them) | reflexd already understands `machine:/path` and `machine/pane` |
| Keep awake | `systemd-inhibit --what=idle` while agents work | or Hyprland `idle` inhibitors |

## Install

    linux/build-linux.sh                 # reflexd → build/reflexd (Bend, no Swift)
    linux/install-omarchy.sh             # service + plugin + keybinds

`install-omarchy.sh` writes, and `uninstall-omarchy.sh` reverses:

- `~/.local/lib/reflex/` — `reflexd`, the service wrapper, `scripts/`, `web/`
- `~/.config/reflex/env` (0600) — port, roots, harness, token
- `~/.config/reflex/token` (0600) — the bearer token, written once
- `~/.config/systemd/user/reflexd.service` — enabled and started
- `~/.config/omarchy/plugins/reflex/` — the shell plugin
- `~/.config/reflex/hypr/reflex.conf` — sourced from your `bindings.conf`
  (with a timestamped backup)

Then `linux/uninstall-omarchy.sh [--purge]`. `--purge` also deletes the token,
routing memory and the folder index.

The installer restarts the Omarchy shell once, at the end: Omarchy starts it with
`QS_DISABLE_FILE_WATCHER=1`, so a new or edited plugin file is only compiled
after `omarchy-restart-shell` (or a re-login). That also means editing
`~/.config/omarchy/plugins/reflex/*.qml` needs the same restart.

## Requirements

- Omarchy 4 (quickshell 0.3.2 with the Omarchy plugin host), Hyprland.
- herdr 0.9+ running, with its agent integrations installed.
- **Bend 2.0.39 or newer** to build `reflexd`. `scripts/build-app.sh` pins 2.0.37,
  but 2.0.37's `Base` types `TCP.send` without the written-byte list that
  `daemon/main.bend` annotates, so 2.0.37 fails to type-check. This is a Base
  skew between the two releases, not a platform difference.
- For routing: jev-fabric and a System 1 provider. The service wrapper sources
  `~/.config/jev-fabric/pi-env.sh` when it exists, so a
  `JEV_CREDENTIAL_COMMAND` resolver (as Pi writes it) works without copying a
  secret into a unit file. Without one, everything except Jev's ranking works.

## Configuration

`~/.config/reflex/env` is a systemd `EnvironmentFile` — reflexd's own variables,
unchanged from the macOS table in the top-level README. The two worth editing:

    REFLEX_ROOTS=~/Projects:~/src        # where the folder index looks
    REFLEX_HARNESS=claude                # agent for a new session

Apply with `systemctl --user restart reflexd` (the index re-reads on the next
poll; `POST /api/reindex` forces it).

## How the plugin talks to reflexd

`Api.qml` is a small `XMLHttpRequest` client: one engine object per call, the
bearer token read once from `~/.config/reflex/token`, requests tagged so a slow
answer cannot overwrite a newer one, and requests made before the token lands
queued rather than sent with an empty `Bearer`.

`Reflex.qml` is one overlay with two modes (`list`, `ask`) and no routing logic
of its own: it renders `/api/state`, asks `/api/candidates` as you type,
`/api/route` on `enter`, and turns each action in the reply into its endpoint
(`spawn` → `/api/spawn`, `prompt` → `/api/send`, `resume` → `/api/resume`,
`press` → `/api/keys`, `btw`/`fork` → `/api/side`). A new action kind in
`daemon/Model.bend` is one line there.

Summoned by the shell, so the overlay lands on the focused output:

    omarchy-shell shell summon reflex '{}'                     # sessions
    omarchy-shell shell summon reflex '{"mode":"ask"}'          # ask bar
    omarchy-shell shell summon reflex '{"mode":"ask","query":"…"}'  # prefilled

## Changes this layer makes outside `linux/`

- `scripts/reflex-scan.sh`: `stat -f %m` is BSD syntax. On GNU the call failed
  and every non-repository folder reported an age of zero, which reorders the
  index. It now tries BSD then GNU (`mtime()`). This change is worth sending
  upstream as-is.

Everything else is additive: `daemon/`, `web/` and the laws are untouched, so the
fork stays mergeable.

## Troubleshooting

    systemctl --user status reflexd        # the daemon
    journalctl --user -u reflexd -f        # its log (it prints the ready line)
    omarchy-shell shell listPlugins | tr ',' '
' | grep reflex
    omarchy-restart-shell                  # after editing the plugin

- **"http 401"** — the token file and the service env disagree. Re-run the
  installer (it keeps the existing token) or compare
  `~/.config/reflex/token` with `REFLEX_TOKEN` in `~/.config/reflex/env`.
- **"key: Missing provider key"** — jev-fabric has no credential in the service
  environment; see Requirements.
- **Empty list with 26 sessions in `/api/state`** — you are looking at a
  stale compiled plugin: restart the shell.
