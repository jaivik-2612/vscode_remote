#!/bin/sh
# Device firmware from the builder's own tree (never redistributed).
set -eu
SRC=/run/antumbra-build/firmware
if [ -d "${SRC}" ] && [ -n "$(ls -A "${SRC}" 2>/dev/null)" ]; then
    mkdir -p /lib/firmware
    cp -a "${SRC}/." /lib/firmware/
    rm -f /lib/firmware/MANIFEST.sha256
    echo "firmware installed: $(find "${SRC}" -type f | wc -l) files"
else
    echo "no firmware tree provided: the image has no device firmware" >&2
fi
