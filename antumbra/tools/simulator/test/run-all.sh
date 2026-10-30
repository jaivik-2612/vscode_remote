#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Rebuild the page, syntax-check its script, run the full flow at iPhone size and on a desktop in
# parallel, then the regression checks for the review findings (fixes.js).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
SIM=$(dirname "$HERE")
# The cloud container's Node.js and Playwright unless NODE and NODE_PATH name others;
# screenshots go to SIM_SHOTS (default: shots/ next to the page).
NODE="${NODE:-/opt/node22/bin/node}"
export NODE_PATH="${NODE_PATH:-/opt/node22/lib/node_modules}"
SHOTS="${SIM_SHOTS:-$SIM/shots}"
python3 "$SIM/build.py"
python3 - "$SIM/antumbra-simulator.html" "$HERE/.page-script.js" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
scripts = re.findall(r'<script>(.*?)</script>', s, re.S)
assert len(scripts) == 1, len(scripts)
open(sys.argv[2], 'w').write(scripts[0])
PY
"$NODE" --check "$HERE/.page-script.js" && echo "page script parses"
rm -f "$SHOTS"/*.png "$SHOTS"/results.json
"$NODE" "$HERE/flow.js" iphone > "$HERE/log-iphone.txt" 2>&1 & P1=$!
"$NODE" "$HERE/flow.js" desktop > "$HERE/log-desktop.txt" 2>&1 & P2=$!
S1=0; S2=0
wait $P1 || S1=$?
wait $P2 || S2=$?
S3=0
"$NODE" "$HERE/fixes.js" > "$HERE/log-fixes.txt" 2>&1 || S3=$?
cat "$HERE/log-iphone.txt" "$HERE/log-desktop.txt"
grep -v '^PASS' "$HERE/log-fixes.txt" | grep -v '^---' || true
tail -1 "$HERE/log-fixes.txt"
python3 - "$SIM/antumbra-simulator.html" <<'PY'
import os, re, sys
s = open(sys.argv[1]).read()
ext = re.findall(r'(?:href|src)=["\x27](https?://[^"\x27]+)', s)
print('page:', os.path.getsize(sys.argv[1]), 'bytes; external references:', ext)
PY
echo "exit: iphone=$S1 desktop=$S2 fixes=$S3"
[ $S1 -eq 0 ] && [ $S2 -eq 0 ] && [ $S3 -eq 0 ]
