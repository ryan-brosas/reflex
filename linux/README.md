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

`linux/TRANSLATION.md` maps every surface of the macOS app to the
Omarchy/Wayland thing that replaces it, and says what is still missing.

Verified on Omarchy 4.0.6 / Hyprland 0.56.2 / herdr 0.9.1 (the layer; the daemon builds with the pinned Bend 2.0.39, see Requirements):

- `reflexd` builds and runs as a systemd user service, and talks to this
  machine's herdr over its socket.
- **Bar widget** (the menu-bar icon, translated): one glyph in the Omarchy
  bar with an amber count when questions wait, blue while agents work, dim when
  idle or when herdr is not running. Left-click opens the compact bar panel
  (questions and sessions), right-click is the ask bar. It polls quickly on the
  focused output and slowly on the others, so seven monitors do not ask seven
  times a second. A 6 px rail on the right edge of each output widens to a
  compact summary on hover and opens the same panel. A separate fixed 6 px
  layer reserves the strip, so the hover growth never reflows windows;
  `REFLEX_RAIL_RESERVE=0` opts out.
- **Sessions and questions** (`SUPER ALT R`): the bar widget's own panel, not
  a full-screen surface — every live agent herdr reports, blocked ones first,
  with its state, folder and title. `enter` focuses that pane in herdr;
  `⇧⏎` opens the embedded terminal. Questions wait at the top with `1` `2` `3`
  options, answered through `POST /api/answer`. Claude Code's folder-trust
  prompt and its `AskUserQuestion` cards arrive this way.
- **Ask window** (`SUPER ALT A`, or right-click the bar glyph): a normal
  app window, not a modal layer and not a forced floating window. Hyprland
  tiles it like any other app on the active workspace; toggle floating with
  your usual compositor bind if you want to drag it by its header or resize it
  from the bottom-right grip. It has minimize/maximize/close in its header and
  closes with `esc` or `✕`. Minimize hides it without losing the query;
  `SUPER ALT A` restores the same text. Maximize uses Hyprland's maximize mode,
  not a fake full-screen size. `SUPER ALT A` raises the existing window instead
  of remapping it. It has no scrim and stays open after sending, so the receipt
  is readable. The empty ask list offers `/claude`, `/pi`, `/codex`, `/folder`,
  `/new`, `/resume`, `/btw`, `/paste`, `/pair`, `/doctor`, `/machines`,
  `/settings` and `/setup` as clickable rows; pick one, then type the request. The list shows Jev's ranked destinations with weights (its pick on
  top), and `enter` sends it — `spawn`, `prompt`, `resume`, `press` and
  `btw`/`fork` actions all map to their endpoint. Without a Jev credential the
  same list still appears from reflexd's own candidates and you pick the row.
- **Ask-line commands** are parsed in the window and never sent as literal
  words: `/folder` opens the native Qt folder dialog and starts in the chosen
  directory; `/new` names a folder under `~/Projects` and creates it with
  `enter`; `/resume` lists the local session index and resumes (or forks) the
  chosen session; `/btw` restricts the list to live sessions and sends the
  question through `POST /api/side`; `/pair` opens the phone card; `/doctor`
  opens the readiness report. `@machine` is parsed and forwarded as the
  route's `machine` field; a saved `reflex-machines` profile supplies the
  tunnel and remote folder index. `/settings` opens the control room.
- **Attachments** are local paths sent with the request. Drag files onto
  the ask window, run `/paste` (or `ctrl+shift+v`) for a copied file or image,
  or use `/attach /path`. Image attachments get a thumbnail; click the row to
  remove it. Text clipboards are deliberately not attachments.
- **Phone pairing** (`/pair` or Reflex → Pair a phone) writes a one-time
  code to `pair.txt` (0600), shows a QR with the LAN or running Tailscale
  address, and turns the phone-facing bind on for the pairing. The QR contains
  no token; `/api/pair` trades the code once and wipes it after ten minutes.
  Closing an unscanned card (or the code expiring) restores the loopback bind;
  a successful pair leaves the phone-facing bind on. `reflex-remote off`
  restores loopback at any time.
- **Doctor** (`reflex-doctor`, or Reflex → Run doctor) prints the onboarding
  checks in a normal app window: daemon health, token mode, herdr socket, Jev
  credential, bind, plugins, session timer, pairing prerequisites, saved
  machines, Bend version and battery availability. It never prints a secret.
- **Earlier sessions** are indexed every five minutes by
  `reflex-sessions.timer`: Claude, pi and Codex session files become the same
  `sessions.tsv` the Mac app wrote, live herdr panes are dropped, and
  `/api/sessions` powers `/resume`.
- **Keeps the session awake** while any visible agent is working:
  the focused output's bar widget holds a `systemd-inhibit --what=idle`
  lock; it releases when nothing is working.
- **Questions reach the desktop**: when the number of waiting questions
  grows, the bar widget raises one replaceable Omarchy notification
  (`omarchy notification send`) whose click action opens the bar panel. It is
  raised by the focused output's widget only and replaced, not stacked, so
  seven monitors do not mean seven toasts.
- **Embedded terminal**: `⇧⏎` on a session opens a terminal window inside
  Reflex. herdr still owns the PTY; the window runs `herdr terminal session
  control`, paints its JSON frames, and sends text, named keys, mouse,
  wheel and resize through `terminal.input` / `terminal.mouse` /
  `terminal.scroll` / `terminal.resize`. The `history` view uses local
  primary-screen rows and falls back to `herdr pane read` before the first
  scroll; `external` opens the native terminal attached to the same pane for
  native IME and full-screen TUIs. No second shell or second PTY is created.
- **SSH machines**: `/machines` or Reflex → SSH machines saves a profile
  (label, SSH target, remote herdr socket, port, optional identity file).
  `reflex-machines` forwards that socket to `$REFLEX_DATA/machines/<label>.sock`
  with `ssh -N -L`, then scans the remote project roots into
  `<label>.folders`. `reflex-machines.timer` reconciles enabled profiles after
  login. reflexd reads `machines/list`, merges those agents into `/api/state`,
  and scopes `@machine` routing and `/api/folders` to the cache. A profile is
  required; no machine is saved by default. `SSH_IDENTITY` and
  `SSH_KNOWN_HOSTS` are optional profile fields for keys and isolated host
  files (`ssh -i`, `UserKnownHostsFile`).
- **Guided setup**: `/setup` or Reflex → Set up Reflex walks seven steps:
  welcome, readiness checks, terminal, project roots, SSH machines, phone
  pairing, and ready. It records completion in
  `~/.config/reflex/onboarded`.
- **Settings**: `/settings`, the bar footer or Reflex → Settings opens the
  nine-pane control room (General, Edge & Rail, Routing, Terminal, Projects,
  Phone, Machines, Setup, About). Each control calls the owning helper or
  systemd unit; theme, wallpaper and terminal appearance stay host-owned.
- **herdr is a dependency, not a child**: `reflexd` only reads herdr's socket.
  The installer enables `herdr.service`, which runs `herdr server` headless so
  the server survives a login instead of dying with a terminal. When herdr is
  not running `/api/state` says `herdr:false`, the glyph dims and says so, and
  clicking it (or `enter` on the offline row) runs
  `~/.local/lib/reflex/bin/reflex-start-herdr`: it starts the user unit, and
  falls back to `omarchy-launch-terminal-herdr` only if the unit cannot start.
  A terminal-owned server is never stopped by the installer or upgrade path,
  because that would kill every pane.
- **The ask window opens on the active workspace**: it is a normal toplevel,
  so Hyprland tiles it where you are working. Focusing another monitor
  afterwards does not move it; the compositor owns its tile. Sessions and
  questions stay in the bar panel.
- **Menu rows**: the Omarchy menu's Reflex group opens either surface
  (`reflex.questions`, `reflex.ask`). The installer merges only the Reflex keys
  from `linux/omarchy/extensions/reflex-menu.json` with
  `linux/bin/reflex-menu.py` into the user-owned
  `~/.config/omarchy/extensions/omarchy-menu.jsonc`; other rows and the schema
  comments are kept, and a backup is made on change. `omarchy menu refresh`
  reloads them.
- **pi's background shells**: the installer puts `reflex-shells.ts` into
  `~/.pi/agent/extensions/`, so a pi agent waiting on a `pi-fabric` background
  shell keeps counting as working instead of looking done.
- **Undo window**: pending dispatches appear with their countdown; `enter`
  cancels one.
- `/claude`, `/pi`, `/codex` and the other harness names work as a prefix on
  the ask line: the plugin strips the token, sends `harness` to reflexd, and a
  new session uses that agent. The other client-side flows are described under
  "Ask-line commands" above; `@machine` needs a saved machine profile whose
  tunnel is up.

A real run: the ask bar routed `add tests to the reflex daemon` to
"new claude in reflex" at 90%, spawned Claude Code in the folder, and the
folder-trust prompt came back as a question card through the same inbox.

## What is not here yet

The macOS app is not a thin client. Full-screen TUIs exercised in the embedded
terminal — `btop`, `less`, `nvim`, `yazi` and `fzf` — enter and leave the
alternate screen, and `nvim` handled application-cursor arrows and resize;
unsupported TUIs and IME composition with a configured engine still need
`external`. The embedded terminal handles alternate screen, wide characters,
mouse, wheel, text and resize through herdr's control channel, and the ask bar
and terminal have TextInput composition sinks. fcitx5 Pinyin is installed, but
Quickshell's TextInput surfaces received keys as plain text and never gained a
fcitx input context, so CJK composition remains external until the shell's
text-input path supports it. A minimal standalone Quickshell `TextInput` showed
the same behavior, so this is not specific to Reflex's hidden sink. The
`external` path was verified in native `foot` and Alacritty: fcitx showed a
`nihao` preedit, the candidate list, and committed a CJK character. The bar's reply/gist inbox is read-only, and a battery readout
does not apply to this desktop. `@machine` works when a
machine profile has a live tunnel; the tunnel and remote folder scan were
exercised against a disposable loopback sshd, but no remote machine is saved on
this box. The edge rail reserves a fixed 6 px strip (`REFLEX_RAIL_RESERVE=0`
opts out), and attachments support dropped files, copied images and thumbnails.
Unbuilt surfaces are not stubbed:

| macOS surface | What it needs on Linux | Notes |
|---|---|---|
| Inbox replies and gists | the bar panel lists questions, updates and sessions; a selected update shows a cleaned gist and, for a `ready` item, the last assistant reply from its session file | replies and gists are read-only views; opening an item still routes through its agent |
| Native terminal fidelity | embedded window handles ANSI frames, alternate screen, wide characters, text, named keys, mouse, wheel, resize and a `history` view through `herdr terminal session control`; `btop`, `less`, `nvim`, `yazi` and `fzf` were exercised full-screen; Pinyin is installed but Quickshell's TextInput surfaces do not receive a fcitx context, so IME and unsupported TUIs still need `external` | use the native terminal when IME or unsupported full-screen fidelity matters |
| Battery readout | this desktop has no battery; `reflex-doctor` says so | keep-awake is already wired to `systemd-inhibit` |
| ⌥⌥ double-tap | `SUPER ALT A` | Hyprland bindings cannot fire on a multi-tap |
| Client-side slash tokens (`/new`, `/folder`, `/resume`, `/btw`, `/paste`, `/pair`, `/doctor`, `/machines`, `/settings`, `/setup`, `@machine`) | Mac `CommandBar` token grammar | all are handled; `@machine` needs a live machine profile | partial |

## Install

    linux/fetch-bend.sh                  # pinned Bend 2.0.39 → build/tools (once)
    linux/build-linux.sh                 # reflexd → build/reflexd (Bend, no Swift)
    linux/install-omarchy.sh             # service + plugin + menu + keybinds

`install-omarchy.sh` writes, and `uninstall-omarchy.sh` reverses:

- `~/.local/lib/reflex/` — `reflexd`, the service wrapper, `scripts/`, `web/`
- `~/.config/reflex/env` (0600) — port, roots, harness, token
- `~/.config/reflex/token` (0600) — the bearer token, written once
- `~/.config/systemd/user/reflexd.service` — enabled and started
- `~/.config/systemd/user/reflex-machines.timer` — reconciles SSH machine
  profiles; with no profiles it writes an empty `machines/list`
- `~/.config/omarchy/plugins/reflex/` — the ask window plugin
- `~/.config/omarchy/plugins/reflex-sessions/` — the bar widget
- `~/.config/omarchy/extensions/omarchy-menu.jsonc` — the Reflex group, merged
  in with the user's other rows and comments kept (backup on change)
- `~/.config/reflex/hypr/reflex.conf` **or** `reflex.lua` — whichever config
  style the session reads (see Keybinds), loaded from `bindings.conf` or
  `bindings.lua` with a timestamped backup
- `~/.pi/agent/extensions/reflex-shells.ts`, when `~/.pi/agent` exists — pi's
  background shells keep a session counted as working (removed by uninstall)
- `~/.local/lib/reflex/bin/` — `reflex-pair`, `reflex-remote`, `reflex-doctor`,
  `reflex-doctor-ui`, `reflex-sessions`, `reflex-machines` and the host helpers
- `~/.local/lib/reflex/mcp/reflex-mcp.ts` — the read-only MCP surface (below)

Then `linux/uninstall-omarchy.sh [--purge]`. It removes the Reflex menu
group and leaves the other menu rows; `--purge` also deletes the token,
routing memory and the folder index.

The installer restarts the Omarchy shell once, at the end: Omarchy starts it with
`QS_DISABLE_FILE_WATCHER=1`, so a new or edited plugin file is only compiled
after `omarchy-restart-shell` (or a re-login). That also means editing
`~/.config/omarchy/plugins/reflex/*.qml` needs the same restart.

## Keybinds

Hyprland can be configured two ways, and the installer checks which one this
session uses: with `~/.config/hypr/hyprland.lua` present, `hyprland.conf` is not
read at all, so a `source` line there silently does nothing. It loads
`reflex.lua` from `bindings.lua` in that case, and appends a `source` line to
`bindings.conf` otherwise.

    SUPER ALT R    bar panel: sessions + questions   o.bind("SUPER + ALT + R", …)
    SUPER ALT A    ask window (tiled; float to drag)   o.bind("SUPER + ALT + A", …)

`SUPER ALT SPACE` was the first choice for ask and is taken (Omarchy's apps
menu), which is why it moved to A. A binding cannot fire on a double tap of
Option, which is what the macOS app listens for.

## Requirements

- Omarchy 4 (quickshell 0.3.2 with the Omarchy plugin host), Hyprland.
- herdr 0.9+ running, with its agent integrations installed.
- OpenSSH (`ssh`) and `systemd-run` for machine profiles; no SSH server is
  installed or started by this layer.
- **Bend 2.0.39 or newer** to build `reflexd`. `linux/fetch-bend.sh` installs the
  pinned copy under `build/tools` without touching the global `bend`; `build-linux.sh`
  prefers it, then `$BEND`, then PATH. 2.0.37's `Base` types `TCP.send` without
  the written-byte list that `daemon/main.bend` annotates, so 2.0.37 fails to
  type-check. This is a Base skew between the two releases, not a platform
  difference.
- `qrencode` for the phone pairing QR (`reflex-pair` says so when it is missing).
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

`Reflex.qml` is one normal window with two modes (`list`, `ask`) and no routing logic
of its own: it renders `/api/state`, asks `/api/candidates` as you type,
`/api/route` with `dry:true` on `enter`, then turns exactly one action in the
reply into its endpoint
(`spawn` → `/api/spawn`, `prompt` → `/api/send`, `resume` → `/api/resume`,
`press` → `/api/keys`, `btw`/`fork` → `/api/side`). A new action kind in
`daemon/Model.bend` is one line there.

Summoned by the shell; it is a normal toplevel, so Hyprland opens it on the
active workspace:

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

## MCP (read-only)

`linux/mcp/reflex-mcp.ts` is a stdio MCP server over the same `/api/*`
endpoints: `reflex_state`, `reflex_candidates`, `reflex_route` (always a dry
run), `reflex_folders` and `reflex_explain`. It reads the bearer token from
`~/.config/reflex/token` per call and never calls a write endpoint. Routing,
ranking and question parsing stay in `reflexd`; this is a client, not a second
brain.

Register the installed copy once per harness:

    # pi: ~/.pi/agent/mcp.json, under mcpServers
    "reflex": {
      "enabled": true,
      "exposure": "codemode",
      "description": "Read Reflex state, candidates and Jev's dry routing for this machine.",
      "command": "bun",
      "args": ["/home/you/.local/lib/reflex/mcp/reflex-mcp.ts"]
    }

    # claude
    claude mcp add --scope user reflex -- bun "$HOME/.local/lib/reflex/mcp/reflex-mcp.ts"

The installer writes the server but does not edit a harness's config; those
files belong to the harness. Uninstall removes the server and leaves any
registration pointing at a path you can delete yourself.

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
