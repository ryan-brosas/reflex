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

need=2.0.39
have=$(bend version 2>/dev/null | awk '{print $2}')
if [ -z "$have" ]; then
  echo "build-linux: bend is not installed. Install it with:" >&2
  echo "  curl -fsSL https://bend-lang.com/install.sh | sh" >&2
  exit 1
fi
older=$(printf '%s\n%s\n' "$need" "$have" | sort -V | head -1)
if [ "$older" != "$need" ]; then
  echo "build-linux: reflexd needs Bend $need or newer, found $have." >&2
  echo "  Base's TCP.send reports a written-byte list in its error from 2.0.39 on," >&2
  echo "  and daemon/main.bend is written against that. To install it:" >&2
  echo "    curl -fsSL https://bend-lang.com/install.sh | sh" >&2
  exit 1
fi

mkdir -p build
if [ "$mode" != --no-check ]; then
  for m in Core Route Index Http Model Js; do
    printf 'reflexd: checking %s\n' "$m"
    bend "daemon/$m.bend" --check-only >/dev/null
  done
fi

echo "reflexd: building"
bend daemon/main.bend -o build/reflexd
echo "built build/reflexd"
