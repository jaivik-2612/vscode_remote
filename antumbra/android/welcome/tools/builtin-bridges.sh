#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Writes, or checks, the Welcome app's built-in obfs4 bridges
# (app/src/main/assets/builtin-bridges-obfs4.txt): the obfs4 lines of Tor
# Browser's own list, projects/tor-expert-bundle/pt_config.json in
# tor-browser-build, at the pinned commit below.
#
#   tools/builtin-bridges.sh           rewrite the asset
#   tools/builtin-bridges.sh --check   fail if the asset differs from the pinned source
#
# The file is downloaded over HTTPS and refused unless its SHA-256 matches
# the pin. To update: pick a newer commit that touched pt_config.json, check
# its diff by hand, then change COMMIT and SHA256 together and run this.
# Needs curl, python3 and sha256sum (or shasum).

set -eu

COMMIT=01d3e9d35aabbc52bfad4e33686f1c83edfa3ce3   # 2026-04-09, "Bug 41775: Update STUN Server List ..."
SHA256=6169848125847b9d471de800b7c4278f2fb142e4bffc03e84700aa654d90ae1c
URL="https://gitlab.torproject.org/tpo/applications/tor-browser-build/-/raw/$COMMIT/projects/tor-expert-bundle/pt_config.json"

here=$(cd "$(dirname "$0")/.." && pwd)
asset="$here/app/src/main/assets/builtin-bridges-obfs4.txt"

check=0
case "${1:-}" in
    --check) check=1 ;;
    "") ;;
    *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
mkdir "$work/dl"
curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location --retry 3 \
    --output "$work/dl/pt_config.json" "$URL"
if command -v sha256sum >/dev/null 2>&1; then
    got=$(sha256sum "$work/dl/pt_config.json" | cut -d ' ' -f 1)
else
    got=$(shasum -a 256 "$work/dl/pt_config.json" | cut -d ' ' -f 1)
fi
if [ "$got" != "$SHA256" ]; then
    echo "builtin-bridges: SHA-256 of pt_config.json is $got, expected $SHA256; refusing it" >&2
    exit 1
fi

# -I: isolated mode, so nothing next to the downloaded file is imported.
python3 -I - "$work/dl/pt_config.json" "$COMMIT" > "$work/asset.txt" <<'EOF'
import json, re, sys
path, commit = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    lines = json.load(f)["bridges"]["obfs4"]
pattern = re.compile(r"obfs4 \d{1,3}(\.\d{1,3}){3}:\d{1,5} [0-9A-F]{40} cert=[A-Za-z0-9+/]+ iat-mode=[012]")
for line in lines:
    if not pattern.fullmatch(line):
        sys.exit("builtin-bridges: unexpected obfs4 line: " + line[:80])
print("# Built-in obfs4 bridges, the same as Tor Browser's: the obfs4 lines of")
print("# tor-browser-build projects/tor-expert-bundle/pt_config.json at commit")
print("# " + commit + ".")
print("# Written by tools/builtin-bridges.sh; do not edit by hand.")
for line in lines:
    print(line)
EOF

if [ "$check" = 1 ]; then
    if cmp -s "$work/asset.txt" "$asset"; then
        echo "builtin-bridges: $asset matches the pinned source"
    else
        echo "builtin-bridges: $asset differs from the pinned source; run $0" >&2
        exit 1
    fi
else
    cp "$work/asset.txt" "$asset"
    echo "builtin-bridges: wrote $asset"
fi
