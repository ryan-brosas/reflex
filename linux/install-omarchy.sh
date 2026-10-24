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

mkdir -p "$plugin"
install -m 644 "$here/omarchy/plugin/manifest.json" "$plugin/manifest.json"
install -m 644 "$here/omarchy/plugin/Reflex.qml" "$plugin/Reflex.qml"
install -m 644 "$here/omarchy/plugin/Api.qml" "$plugin/Api.qml"
say "plugin: installed $plugin"

if command -v omarchy-shell >/dev/null 2>&1; then
  omarchy-shell -q shell rescanPlugins
  if omarchy-shell shell listPlugins 2>/dev/null | grep -q '"id":"reflex"'; then
    say "plugin: the shell sees reflex"
  else
    say "plugin: not listed yet; run: omarchy-shell shell rescanPlugins"
  fi
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

mkdir -p "$conf/hypr"
install -m 644 "$here/hypr/reflex.conf" "$hyprconf"
if [ -f "$bindings" ]; then
  if ! grep -qF "$hyprconf" "$bindings"; then
    cp "$bindings" "$bindings.bak-reflex-$(date -u +%Y%m%dT%H%M%SZ)"
    printf '\n# Reflex (installed by linux/install-omarchy.sh)\nsource = %s\n' "$hyprconf" >> "$bindings"
    say "keybinds: sourced $hyprconf from $bindings"
  else
    say "keybinds: already sourced"
  fi
  command -v hyprctl >/dev/null 2>&1 && hyprctl reload >/dev/null 2>&1 || true
else
  say "keybinds: no $bindings; add:  source = $hyprconf"
fi

# 6. say what works -----------------------------------------------------------

port=$(sed -n 's/^REFLEX_PORT=//p' "$envfile" | head -1)
say ""
say "Reflex is up on 127.0.0.1:${port:-47823}."
say ""
say "  SUPER ALT R      every session, and every question waiting on you"
say "  SUPER ALT SPACE  the ask bar"
say ""
say "Check it:  curl -s -H \"authorization: Bearer \$(cat $token)\" localhost:${port:-47823}/api/health"
say "Logs:      journalctl --user -u reflexd -f"
say "Undo:      $here/uninstall-omarchy.sh"
