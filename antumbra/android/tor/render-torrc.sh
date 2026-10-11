#!/bin/sh
# Antumbra: write a torrc from torrc.in for a given runtime directory.
#
# Usage: render-torrc.sh [ANTUMBRA_DIR [TEMPLATE]] > torrc
#   ANTUMBRA_DIR  runtime directory (default /data/adb/antumbra)
#   TEMPLATE      template file (default: torrc.in next to this script)
#
# The directory must be an absolute path made only of letters, digits and
# '/', '.', '_', '-', so it cannot change the meaning of a torrc line. The
# control socket path must also fit in a Unix socket address.
set -eu

dir=${1:-/data/adb/antumbra}
here=$(cd "$(dirname "$0")" && pwd)
template=${2:-$here/torrc.in}

case $dir in
  /*) ;;
  *) echo "render-torrc.sh: '$dir' is not an absolute path" >&2; exit 2 ;;
esac
case $dir in
  *[!A-Za-z0-9/._-]*)
    echo "render-torrc.sh: '$dir' contains characters other than A-Z a-z 0-9 / . _ -" >&2
    exit 2 ;;
esac
dir=${dir%/}
# sun_path holds 108 bytes including the final NUL.
sock="$dir/run/tor-control.sock"
if [ "${#sock}" -gt 107 ]; then
  echo "render-torrc.sh: control socket path is ${#sock} bytes; the limit is 107" >&2
  exit 2
fi
[ -r "$template" ] || { echo "render-torrc.sh: cannot read $template" >&2; exit 2; }

sed "s|@ANTUMBRA_DIR@|$dir|g" "$template"
