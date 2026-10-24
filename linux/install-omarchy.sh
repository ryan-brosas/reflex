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
say "reflexd: installed $prefix/reflexd"

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

# 4. the Omarchy shell plugin -------------------------------------------------

# Two plugins, because the shell routes a plugin id to one surface: "reflex" is
# the summonable overlay (sessions + ask), "reflex.sessions" is the bar widget
# that carries the counts. Both talk to reflexd through the same Api.qml.
overlay=$config/omarchy/plugins/reflex
barwidget=$config/omarchy/plugins/reflex-sessions

mkdir -p "$overlay" "$barwidget"
install -m 644 "$here/omarchy/plugin/manifest.json" "$overlay/manifest.json"
install -m 644 "$here/omarchy/plugin/Reflex.qml" "$overlay/Reflex.qml"
install -m 644 "$here/omarchy/panel/manifest.json" "$barwidget/manifest.json"
install -m 644 "$here/omarchy/panel/Bar.qml" "$barwidget/Bar.qml"
install -m 644 "$here/omarchy/plugin/Api.qml" "$overlay/Api.qml"
install -m 644 "$here/omarchy/plugin/Api.qml" "$barwidget/Api.qml"
say "plugin: installed $overlay and $barwidget"

if command -v omarchy-shell >/dev/null 2>&1; then
  omarchy-shell -q shell rescanPlugins
  if omarchy-shell shell listPlugins 2>/dev/null | grep -q '"id":"reflex"'; then
    say "plugin: the shell sees reflex"
  else
    say "plugin: not listed yet; run: omarchy-shell shell rescanPlugins"
  fi
  # A third-party plugin is inert until shell.json names it: the overlay in
  # plugins[], the widget in the bar's layout.
  omarchy-shell -q shell enablePlugin reflex '{}'
  omarchy-shell -q shell enablePlugin reflex.sessions '{"section":"right"}'
  say "plugin: enabled the overlay and the bar widget (right section)"
  # Omarchy starts the shell with QS_DISABLE_FILE_WATCHER=1, so a plugin file is
  # only compiled at startup: without this the overlay stays on whatever
  # version was on disk when the session began.
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
