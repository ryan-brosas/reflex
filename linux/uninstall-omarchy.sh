#!/bin/sh
# Remove the Linux/Omarchy layer. Keeps your token, routing memory and index
# unless you pass --purge.
#
#   linux/uninstall-omarchy.sh           # the service, the plugin, the keybinds
#   linux/uninstall-omarchy.sh --purge   # and ~/.config/reflex + ~/.local/state/reflex
set -eu

purge=false
[ "${1:-}" = "--purge" ] && purge=true
here=$(cd "$(dirname "$0")" && pwd)

config=${XDG_CONFIG_HOME:-$HOME/.config}
state=${XDG_STATE_HOME:-$HOME/.local/state}
prefix=${REFLEX_PREFIX:-$HOME/.local/lib/reflex}
conf=$config/reflex
plugin=$config/omarchy/plugins/reflex
barwidget=$config/omarchy/plugins/reflex-sessions
unit=$config/systemd/user/reflexd.service
bindings=$config/hypr/bindings.conf
hyprconf=$conf/hypr/reflex.conf
luaconf=$conf/hypr/reflex.lua

say() { printf '%s\n' "$*"; }

systemctl --user disable --now reflexd.service >/dev/null 2>&1 || true
systemctl --user disable --now reflex-sessions.timer >/dev/null 2>&1 || true
systemctl --user stop reflex-sessions.service >/dev/null 2>&1 || true
systemctl --user disable --now reflex-machines.timer >/dev/null 2>&1 || true
systemctl --user stop reflex-machines.service >/dev/null 2>&1 || true
rm -f "$unit" "$config/systemd/user/reflex-sessions.service" "$config/systemd/user/reflex-sessions.timer" "$config/systemd/user/reflex-machines.service" "$config/systemd/user/reflex-machines.timer"
# Transient SSH units are owned by the timer; stop any that are still live.
for unit in $(systemctl --user list-units --type=service --all --no-legend 'reflex-machine-*.service' 2>/dev/null | awk '{print $1}'); do
  systemctl --user stop "$unit" >/dev/null 2>&1 || true
done
systemctl --user daemon-reload >/dev/null 2>&1 || true
say "reflexd: service removed"

# herdr's headless unit is not Reflex's: it keeps the user's agents alive after
# Reflex is gone too. Leave it, and say so instead of silently leaving state.
herdr_unit=$config/systemd/user/herdr.service
if [ -e "$herdr_unit" ]; then
  say "herdr: left $herdr_unit in place (herdr's service, not Reflex's)"
fi

# Both ids, because the shell routes one plugin id to one surface: the overlay
# is "reflex", the bar widget installs as "reflex.sessions" and lives in its own
# folder. The manager removes the shell.json entries too; the rm is a fallback
# for shells that never registered them.
if command -v omarchy >/dev/null 2>&1; then
  omarchy plugin disable reflex >/dev/null 2>&1 || true
  omarchy plugin disable reflex.sessions >/dev/null 2>&1 || true
  omarchy plugin remove reflex --yes >/dev/null 2>&1 || true
  omarchy plugin remove reflex.sessions --yes >/dev/null 2>&1 || true
fi
rm -rf "$plugin" "$barwidget"
command -v omarchy-shell >/dev/null 2>&1 && omarchy-shell -q shell rescanPlugins || true
say "plugin: removed $plugin and $barwidget"

# The Pi extension was installed into Pi's own config by the installer. Remove
# only the file this layer wrote; leave any other extension alone.
piagent=${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}
rm -f "$piagent/extensions/reflex-shells.ts"
rm -f "$prefix/bin/reflex-start-herdr" "$prefix/bin/reflex-attach-paste" "$prefix/bin/reflex-pair" "$prefix/bin/reflex-remote" "$prefix/bin/reflex-doctor" "$prefix/bin/reflex-doctor-ui"
say "pi: removed $piagent/extensions/reflex-shells.ts"
say "helper: removed $prefix/bin/reflex-start-herdr"

bindings_lua=$config/hypr/bindings.lua

if [ -f "$bindings" ] && grep -qF "$hyprconf" "$bindings"; then
  cp "$bindings" "$bindings.bak-reflex-$(date -u +%Y%m%dT%H%M%SZ)"
  grep -vF "$hyprconf" "$bindings" | sed -e :a -e '/^\n*$/{$d;N;};/\n$/ba' > "$bindings.tmp"
  mv "$bindings.tmp" "$bindings"
  say "keybinds: removed the .conf source line"
fi

if [ -f "$bindings_lua" ] && grep -qF 'reflex/hypr/reflex.lua' "$bindings_lua"; then
  cp "$bindings_lua" "$bindings_lua.bak-reflex-$(date -u +%Y%m%dT%H%M%SZ)"
  grep -vF 'reflex/hypr/reflex.lua' "$bindings_lua" > "$bindings_lua.tmp"
  mv "$bindings_lua.tmp" "$bindings_lua"
  say "keybinds: removed the Lua load line"
fi

rm -f "$hyprconf" "$conf/hypr/reflex.lua"
rmdir "$conf/hypr" 2>/dev/null || true

rm -rf "$prefix"
say "reflexd: removed $prefix"

# Menu rows are merged into a user-owned file; remove only the Reflex group,
# keep every other row and the schema comments.
menu_ext=$config/omarchy/extensions/omarchy-menu.jsonc
if command -v python3 >/dev/null 2>&1; then
  python3 -B "$here/bin/reflex-menu.py" remove "$menu_ext"
  command -v omarchy >/dev/null 2>&1 && omarchy menu refresh >/dev/null 2>&1 || true
else
  say "menu: python3 missing; Reflex rows in $menu_ext were left in place"
fi

if $purge; then
  rm -rf "$conf" "$state/reflex"
  say "purged $conf and $state/reflex"
else
  say "kept $conf (token) and $state/reflex (routing memory, index)"
fi

command -v hyprctl >/dev/null 2>&1 && hyprctl reload >/dev/null 2>&1 || true
say "done"
