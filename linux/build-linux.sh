#!/bin/sh
# Build reflexd on Linux.
#
# The macOS build (scripts/build-app.sh) also builds Reflex.app in Swift; this
# layer has no Swift and no AppKit. reflexd is the whole product here: the
# Omarchy shell plugin in linux/omarchy/ and the phone remote in web/ both
# reach it over HTTP.
#
#   linux/build-linux.sh            # check the pure modules, then build
#   linux/build-linux.sh --no-check # skip the per-module check
set -eu
cd "$(dirname "$0")/.."
root=$PWD

mode=${1:-daemon}

export BEND_NO_TELEMETRY=1
# Bend's code generator runs on Bun's JavaScriptCore; capping the heap keeps its
# footprint in RAM instead of swap (see docs/bend-build-speed.md).
export BUN_JSC_forceRAMSize=${BUN_JSC_forceRAMSize:-4294967296}

need=$(tr -d '[:space:]' < linux/bend-version)
pinned=$root/build/tools/bend-$need/bin/bend
if [ -n "${BEND:-}" ]; then
  bend_bin=$BEND
elif [ -x "$pinned" ]; then
  bend_bin=$pinned
else
  bend_bin=$(command -v bend || true)
fi
if [ -z "$bend_bin" ] || [ ! -x "$bend_bin" ]; then
  echo "build-linux: Bend $need is not available." >&2
  echo "  linux/fetch-bend.sh installs the pinned copy in build/tools." >&2
  exit 1
fi
have=$("$bend_bin" version 2>/dev/null | awk '{print $2}')
if [ -z "$have" ]; then
  echo "build-linux: $bend_bin is not a working Bend executable." >&2
  exit 1
fi
older=$(printf '%s\n%s\n' "$need" "$have" | sort -V | head -1)
if [ "$older" != "$need" ]; then
  echo "build-linux: reflexd needs Bend $need or newer, found $have at $bend_bin." >&2
  echo "  Run linux/fetch-bend.sh, or set BEND to a $need+ binary." >&2
  exit 1
fi

mkdir -p build
if [ "$mode" != --no-check ]; then
  for m in Core Route Index Http Model Js; do
    printf 'reflexd: checking %s\n' "$m"
    "$bend_bin" "daemon/$m.bend" --check-only >/dev/null
  done
fi

echo "reflexd: building with Bend $have"
"$bend_bin" daemon/main.bend -o build/reflexd
echo "built build/reflexd"
