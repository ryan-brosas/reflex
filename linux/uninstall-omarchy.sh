#!/bin/sh
# Remove the Linux/Omarchy layer. Keeps your token, routing memory and index
# unless you pass --purge.
#
#   linux/uninstall-omarchy.sh           # the service, the plugin, the keybinds
#   linux/uninstall-omarchy.sh --purge   # and ~/.config/reflex + ~/.local/state/reflex
set -eu

purge=false
[ "${1:-}" = "--purge" ] && purge=true

config=${XDG_CONFIG_HOME:-$HOME/.config}
state=${XDG_STATE_HOME:-$HOME/.local/state}
prefix=${REFLEX_PREFIX:-$HOME/.local/lib/reflex}
conf=$config/reflex
plugin=$config/omarchy/plugins/reflex
unit=$config/systemd/user/reflexd.service
bindings=$config/hypr/bindings.conf
hyprconf=$conf/hypr/reflex.conf

say() { printf '%s\n' "$*"; }

systemctl --user disable --now reflexd.service >/dev/null 2>&1 || true
rm -f "$unit"
systemctl --user daemon-reload >/dev/null 2>&1 || true
say "reflexd: service removed"

rm -rf "$plugin"
command -v omarchy-shell >/dev/null 2>&1 && omarchy-shell -q shell rescanPlugins || true
say "plugin: removed $plugin"

if [ -f "$bindings" ] && grep -qF "$hyprconf" "$bindings"; then
  cp "$bindings" "$bindings.bak-reflex-$(date -u +%Y%m%dT%H%M%SZ)"
  grep -vF "$hyprconf" "$bindings" | sed -e :a -e '/^\n*$/{$d;N;};/\n$/ba' > "$bindings.tmp"
  mv "$bindings.tmp" "$bindings"
  say "keybinds: removed the source line"
fi
rm -f "$hyprconf"
rmdir "$conf/hypr" 2>/dev/null || true

rm -rf "$prefix"
say "reflexd: removed $prefix"

if $purge; then
  rm -rf "$conf" "$state/reflex"
  say "purged $conf and $state/reflex"
else
  say "kept $conf (token) and $state/reflex (routing memory, index)"
fi

command -v hyprctl >/dev/null 2>&1 && hyprctl reload >/dev/null 2>&1 || true
say "done"
