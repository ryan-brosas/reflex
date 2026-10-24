#!/bin/sh
# Install the Bend version this repository pins into build/tools, without
# touching the user's global ~/.bend or any other project.
#
#   linux/fetch-bend.sh [destination]
#
# The official installer verifies the release archive; BEND_HOME keeps it
# local. build-linux.sh prefers this copy over whatever `bend` is on PATH.
set -eu
cd "$(dirname "$0")/.."
root=$PWD
version=$(cat linux/bend-version)
dest=${1:-$root/build/tools/bend-$version}

if [ -x "$dest/bin/bend" ]; then
  echo "bend $version already at $dest"
  exit 0
fi

mkdir -p "$dest"
echo "installing Bend $version into $dest"
BEND_HOME="$dest" sh -c 'curl -fsSL https://bend-lang.com/install.sh | sh'

have=$("$dest/bin/bend" version 2>/dev/null | awk '{print $2}')
if [ "$have" != "$version" ]; then
  echo "fetch-bend: expected $version, got ${have:-nothing}" >&2
  exit 1
fi
echo "bend $version ready"
