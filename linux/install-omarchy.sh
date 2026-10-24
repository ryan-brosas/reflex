#!/bin/sh
# Install the Linux/Omarchy layer for Reflex.
#
# Three pieces, all reversible with uninstall-omarchy.sh:
#   1. reflexd (the Bend daemon) into ~/.local/lib/reflex, run as a user service
#   2. the Omarchy shell plugin into ~/.config/omarchy/plugins/reflex
#   3. two Hyprland chords, sourced from your bindings.conf
#
# Nothing here is macOS-specific: reflexd binds 127.0.0.1, reads herdr's own
# socket at ~/.config/herdr/herdr.sock, and the UI is the shell plugin.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)

prefix=${REFLEX_PREFIX:-$HOME/.local/lib/reflex}
config=${XDG_CONFIG_HOME:-$HOME/.config}
state=${XDG_STATE_HOME:-$HOME/.local/state}
conf=$config/reflex
plugin=$config/omarchy/plugins/reflex
unitdir=$config/systemd/user
bindings=$config/hypr/bindings.conf
hyprconf=$conf/hypr/reflex.conf
luaconf=$conf/hypr/reflex.lua
token=$conf/token
envfile=$conf/env

say() { printf '%s\n' "$*"; }

# 1. the daemon ---------------------------------------------------------------

if [ ! -x "$root/build/reflexd" ]; then
  say "reflexd: building"
  "$here/build-linux.sh"
fi

mkdir -p "$prefix/scripts" "$prefix/web"
install -m 755 "$root/build/reflexd" "$prefix/reflexd"
install -m 755 "$here/bin/reflexd-service" "$prefix/reflexd-service"
for s in reflex-scan.sh reflex-fork.sh reflex-remote.sh; do
  [ -f "$root/scripts/$s" ] && install -m 755 "$root/scripts/$s" "$prefix/scripts/$s"
done
cp -R "$root/web/." "$prefix/web/"
# The read-only MCP surface is a thin client of this daemon (linux/mcp/), not a
# second brain; it is installed next to reflexd so a harness registration can
# point at a stable path.
mkdir -p "$prefix/mcp" "$prefix/bin"
install -m 755 "$root/linux/mcp/reflex-mcp.ts" "$prefix/mcp/reflex-mcp.ts"
install -m 755 "$here/bin/reflex-start-herdr" "$prefix/bin/reflex-start-herdr"
install -m 755 "$here/bin/reflex-sessions" "$prefix/bin/reflex-sessions"
install -m 755 "$here/bin/reflex-attach-paste" "$prefix/bin/reflex-attach-paste"
install -m 755 "$here/bin/reflex-pair" "$prefix/bin/reflex-pair"
install -m 755 "$here/bin/reflex-remote" "$prefix/bin/reflex-remote"
install -m 755 "$here/bin/reflex-doctor" "$prefix/bin/reflex-doctor"
install -m 755 "$here/bin/reflex-doctor-ui" "$prefix/bin/reflex-doctor-ui"
install -m 755 "$here/bin/reflex-machines" "$prefix/bin/reflex-machines"
install -m 755 "$here/bin/reflex-settings" "$prefix/bin/reflex-settings"
say "reflexd: installed $prefix/reflexd"
say "mcp: installed $prefix/mcp/reflex-mcp.ts (read-only)"

# 2. token + environment ------------------------------------------------------

mkdir -p "$conf" "$state"
if [ ! -s "$token" ]; then
  head -c 32 /dev/urandom | base64 -w0 | tr '+/' '-_' | cut -c1-43 > "$token"
  chmod 600 "$token"
  say "reflexd: wrote a token to $token"
fi

roots=${REFLEX_ROOTS:-}
if [ -z "$roots" ]; then
  for d in "$HOME/Projects" "$HOME/src" "$HOME/VCS" "$HOME/code"; do
    [ -d "$d" ] && roots=${roots:+$roots:}$d
  done
fi
[ -n "$roots" ] || roots=$HOME

cat > "$envfile" <<EOF
# reflexd environment. Read by systemd (reflexd.service).
REFLEX_PORT=47823
REFLEX_BIND=127.0.0.1
REFLEX_TOKEN=$(cat "$token")
REFLEX_DATA=$state/reflex
REFLEX_WEB=$prefix/web
REFLEX_SCAN=$prefix/scripts/reflex-scan.sh
REFLEX_FORK=$prefix/scripts/reflex-fork.sh
# Where the folder index looks for repositories (colon separated).
REFLEX_ROOTS=$roots
# The agent a new session starts, when the request does not name one.
REFLEX_HARNESS=${REFLEX_HARNESS:-claude}
# reflexd finds its Jev provider through ~/.config/jev-fabric/pi-env.sh, which
# the service wrapper sources; nothing secret is copied into this file.
EOF
chmod 600 "$envfile"
say "reflexd: wrote $envfile"

# 3. user service -------------------------------------------------------------

mkdir -p "$unitdir"
sed -e "s#@PREFIX@#$prefix#g" -e "s#@ENVFILE@#$envfile#g" \
  "$here/systemd/reflexd.service.in" > "$unitdir/reflexd.service"
systemctl --user daemon-reload
systemctl --user enable reflexd.service >/dev/null 2>&1 || true
systemctl --user restart reflexd.service
say "reflexd: service enabled and started"

# reflexd reads earlier sessions from sessions.tsv; the Mac app wrote it. The
# Linux layer indexes the same Claude/pi/Codex files on a timer and drops
# sessions that are live in herdr, so resume and Jev can see past work.
sed -e "s#@PREFIX@#$prefix#g" -e "s#@STATE@#$state#g" \
  "$here/systemd/reflex-sessions.service.in" > "$unitdir/reflex-sessions.service"
sed -e "s#@PREFIX@#$prefix#g" -e "s#@STATE@#$state#g" \
  "$here/systemd/reflex-sessions.timer.in" > "$unitdir/reflex-sessions.timer"
systemctl --user daemon-reload
systemctl --user enable --now reflex-sessions.timer >/dev/null 2>&1 || true
systemctl --user start reflex-sessions.service >/dev/null 2>&1 || true
say "sessions: earlier-session index enabled"

# Machine tunnels are per-profile SSH forwarders; the timer only reconciles
# them. With no profiles it writes an empty machines/list and starts nothing.
sed -e "s#@PREFIX@#$prefix#g" \
  "$here/systemd/reflex-machines.service.in" > "$unitdir/reflex-machines.service"
sed -e "s#@PREFIX@#$prefix#g" \
  "$here/systemd/reflex-machines.timer.in" > "$unitdir/reflex-machines.timer"
systemctl --user daemon-reload
systemctl --user enable --now reflex-machines.timer >/dev/null 2>&1 || true
systemctl --user start reflex-machines.service >/dev/null 2>&1 || true
say "machines: SSH tunnel reconciler enabled"

# herdr is a dependency, not a child: keep its server alive headlessly rather
# than in a terminal. A service the user already wrote is left alone. Enabling
# it takes effect at the next login; a running terminal-owned server is not
# touched, because stopping it would kill every pane.
herdr_bin=$(command -v herdr || true)
if [ -n "$herdr_bin" ]; then
  if [ ! -e "$unitdir/herdr.service" ]; then
    sed "s#@HERDR@#$herdr_bin#g" "$here/systemd/herdr.service.in" > "$unitdir/herdr.service"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    systemctl --user enable herdr.service >/dev/null 2>&1 || true
    say "herdr: installed a headless user service (starts at login)"
    if ! "$herdr_bin" workspace list >/dev/null 2>&1; then
      systemctl --user start herdr.service >/dev/null 2>&1 || true
      say "herdr: started the headless server now"
    fi
  else
    say "herdr: kept the existing user service"
  fi
fi

# 4. the Omarchy shell plugin -------------------------------------------------

# Two plugins, because the shell routes a plugin id to one surface: "reflex" is
# the summonable overlay (sessions + ask), "reflex.sessions" is the bar widget
# that carries the counts. Both talk to reflexd through the same Api.qml.
overlay=$config/omarchy/plugins/reflex
barwidget=$config/omarchy/plugins/reflex-sessions

mkdir -p "$overlay" "$barwidget"
install -m 644 "$here/omarchy/plugin/manifest.json" "$overlay/manifest.json"
install -m 644 "$here/omarchy/plugin/Reflex.qml" "$overlay/Reflex.qml"
install -m 644 "$here/omarchy/plugin/TerminalWindow.qml" "$overlay/TerminalWindow.qml"
install -m 644 "$here/omarchy/plugin/MachinesWindow.qml" "$overlay/MachinesWindow.qml"
install -m 644 "$here/omarchy/plugin/SetupWindow.qml" "$overlay/SetupWindow.qml"
install -m 644 "$here/omarchy/plugin/SettingsWindow.qml" "$overlay/SettingsWindow.qml"
install -m 644 "$here/omarchy/plugin/Terminal.js" "$overlay/Terminal.js"
install -m 644 "$here/omarchy/panel/manifest.json" "$barwidget/manifest.json"
install -m 644 "$here/omarchy/panel/Bar.qml" "$barwidget/Bar.qml"
install -m 644 "$here/omarchy/plugin/Api.qml" "$overlay/Api.qml"
install -m 644 "$here/omarchy/plugin/Api.qml" "$barwidget/Api.qml"
say "plugin: installed $overlay and $barwidget"

# Omarchy owns plugin registration: validate the manifests against the shell's
# schema and enable both through the manager. The files are still copied above,
# because this layer lives in the reflex repository rather than in its own
# plugin repo, so `omarchy plugin add` (a git URL) does not apply.
if command -v omarchy >/dev/null 2>&1; then
  omarchy plugin validate "$here/omarchy/plugin"
  omarchy plugin validate "$here/omarchy/panel"
fi

if command -v omarchy-shell >/dev/null 2>&1; then
  omarchy-shell -q shell rescanPlugins
fi

# The shell scans plugin folders asynchronously, so an enable that runs right
# after the copy can still answer "unknown". Wait for both ids in its catalog.
if command -v omarchy-shell >/dev/null 2>&1; then
  known() { omarchy-shell shell listPlugins 2>/dev/null | grep -q "\"id\":\"$1\""; }
  i=0
  while [ "$i" -lt 20 ]; do
    known reflex && known reflex.sessions && break
    sleep 0.25
    i=$((i + 1))
  done
fi

overlay_ok=false
widget_ok=false
if command -v omarchy >/dev/null 2>&1; then
  omarchy plugin enable reflex >/dev/null 2>&1 && overlay_ok=true
  # Place the widget only when it is absent: moving it again would undo a
  # position the user chose since the last install.
  if command -v omarchy-shell >/dev/null 2>&1 &&
     omarchy-shell shell listShellConfig 2>/dev/null | grep -q '"reflex.sessions"'; then
    widget_ok=true
  else
    omarchy bar put reflex.sessions --section right --after carlotran4.herdr >/dev/null 2>&1 && widget_ok=true
  fi
fi

if $overlay_ok && $widget_ok; then
  say "plugin: enabled through omarchy plugin (overlay; bar widget beside herdr)"
else
  # Older shells, or a manager that does not know these ids yet. Fall back per
  # surface, and never re-place a widget that is already on the bar: that would
  # undo a position the user chose.
  if ! $overlay_ok && command -v omarchy-shell >/dev/null 2>&1; then
    omarchy-shell -q shell enablePlugin reflex '{}'
  fi
  if ! $widget_ok && command -v omarchy-shell >/dev/null 2>&1 &&
     ! omarchy-shell shell listShellConfig 2>/dev/null | grep -q '"reflex.sessions"'; then
    omarchy-shell -q shell enablePlugin reflex.sessions '{"section":"right"}'
  fi
  say "plugin: enabled through omarchy-shell (manager unavailable or already placed)"
fi

if command -v jq >/dev/null 2>&1 &&
   omarchy plugin list --json 2>/dev/null |
     jq -e 'any(.[]; .id == "reflex" and .enabled) and any(.[]; .id == "reflex.sessions" and .enabled)' >/dev/null 2>&1; then
  say "plugin: enabled and listed (overlay + bar widget)"
elif command -v omarchy-shell >/dev/null 2>&1 && omarchy-shell shell listPlugins 2>/dev/null | grep -q '"id":"reflex"'; then
  say "plugin: the shell sees reflex"
else
  say "plugin: not enabled yet; run: omarchy-shell shell rescanPlugins"
fi

# A third-party plugin is inert until shell.json names it: the overlay in
# plugins[], the widget in the bar's layout. The manager above does that.
#
# Omarchy starts the shell with QS_DISABLE_FILE_WATCHER=1, so a plugin file is
# only compiled at startup: without this the overlay stays on whatever version
# was on disk when the session began.
if command -v omarchy-restart-shell >/dev/null 2>&1; then
  omarchy-restart-shell >/dev/null 2>&1 || true
  i=0
  while [ "$i" -lt 20 ]; do
    sleep 1
    omarchy-shell shell ping >/dev/null 2>&1 && break
    i=$((i + 1))
  done
  say "plugin: shell restarted with this build"
fi

# Say it once: the bar glyph is small and the chords are not discoverable from
# a fresh install. The marker keeps a reinstall from becoming a second toast.
welcome=$conf/.welcome-shown
if [ ! -e "$welcome" ] && command -v omarchy >/dev/null 2>&1; then
  body="SUPER ALT A asks · SUPER ALT R answers · click for questions"
  if command -v herdr >/dev/null 2>&1 && ! herdr workspace list >/dev/null 2>&1; then
    body="herdr isn't running yet — start it, then SUPER ALT A asks · SUPER ALT R answers"
  fi
  omarchy notification send --app-name Reflex -u normal \
    "Reflex is running" "$body" \
    --exec omarchy-shell shell summon reflex '{}' >/dev/null 2>&1 || true
  : > "$welcome"
fi

# 4b. pi's background shells --------------------------------------------------
# reflexd reads ~/.pi/agent/reflex/sessions/<pid>.json while pi-fabric's
# background shells run, so a pi agent waiting on one still counts as working.
# The macOS app installs this from Setup; here the installer does, and uninstall
# removes the file it wrote.
piagent=${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}
if [ -d "$piagent" ] && [ -f "$root/integrations/pi/reflex-shells.ts" ]; then
  mkdir -p "$piagent/extensions"
  install -m 644 "$root/integrations/pi/reflex-shells.ts" "$piagent/extensions/reflex-shells.ts"
  say "pi: installed reflex-shells.ts (background shells count as working)"
fi

# 4c. Omarchy menu rows --------------------------------------------------------
# The menu extension is user-owned: it also carries the user's workspan and
# herdr rows. Merge only the Reflex group, preserving the rest and the schema
# comments, so a reinstall is not a menu reset.
menu_ext=$config/omarchy/extensions/omarchy-menu.jsonc
if command -v python3 >/dev/null 2>&1; then
  python3 -B "$here/bin/reflex-menu.py" install "$here/omarchy/extensions/reflex-menu.json" "$menu_ext"
  say "menu: Reflex rows are in $menu_ext (other rows kept)"
  command -v omarchy >/dev/null 2>&1 && omarchy menu refresh >/dev/null 2>&1 || true
else
  say "menu: python3 missing; Reflex rows were not installed"
fi

# 5. keybindings --------------------------------------------------------------

# Two config styles are in the wild: the classic Hyprland .conf tree, and the
# newer Lua one (hyprland.lua with require("hypr.bindings")). When hyprland.lua
# exists, hyprland.conf is not read at all, so a source line there would
# silently do nothing; install into whichever this session actually reads.

mkdir -p "$conf/hypr"
install -m 644 "$here/hypr/reflex.conf" "$hyprconf"
install -m 644 "$here/hypr/reflex.lua" "$luaconf"

bindings_lua=$config/hypr/bindings.lua
hypr_lua=$config/hypr/hyprland.lua
lua_load='dofile((os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")) .. "/reflex/hypr/reflex.lua")'
lua_marker='reflex/hypr/reflex.lua'

backup() { cp "$1" "$1.bak-reflex-$(date -u +%Y%m%dT%H%M%SZ)"; }

reload_hypr() {
  command -v hyprctl >/dev/null 2>&1 && hyprctl reload >/dev/null 2>&1 || true
}

if [ -f "$hypr_lua" ] && [ -f "$bindings_lua" ]; then
  if grep -qF "$lua_marker" "$bindings_lua"; then
    say "keybinds: already loaded from $bindings_lua"
  else
    backup "$bindings_lua"
    printf '\n-- Reflex (installed by linux/install-omarchy.sh)\n%s\n' "$lua_load" >> "$bindings_lua"
    say "keybinds: loaded $luaconf from $bindings_lua"
  fi
  # A stale classic line would double-bind if this session ever read .conf again.
  if [ -f "$bindings" ] && grep -qF "$hyprconf" "$bindings"; then
    backup "$bindings"
    grep -vF "$hyprconf" "$bindings" > "$bindings.tmp" && mv "$bindings.tmp" "$bindings"
    say "keybinds: removed the stale .conf source line"
  fi
  reload_hypr
elif [ -f "$bindings" ]; then
  if grep -qF "$hyprconf" "$bindings"; then
    say "keybinds: already sourced from $bindings"
  else
    backup "$bindings"
    printf '\n# Reflex (installed by linux/install-omarchy.sh)\nsource = %s\n' "$hyprconf" >> "$bindings"
    say "keybinds: sourced $hyprconf from $bindings"
  fi
  reload_hypr
else
  say "keybinds: no Hyprland bindings file found; add one of:"
  say "  source = $hyprconf"
  say "  $lua_load"
fi

# 6. say what works -----------------------------------------------------------

port=$(sed -n 's/^REFLEX_PORT=//p' "$envfile" | head -1)
say ""
say "Reflex is up on 127.0.0.1:${port:-47823}."
say ""
say "  SUPER ALT R      every session, and every question waiting on you"
say "  SUPER ALT A      the ask bar"
say ""
say "Check it:  curl -s -H \"authorization: Bearer \$(cat $token)\" localhost:${port:-47823}/api/health"
say "Logs:      journalctl --user -u reflexd -f"
say "Undo:      $here/uninstall-omarchy.sh"
