#!/bin/sh
# The live user, as in Tails: amnesia, UID/GID 1000, no password (the Welcome
# screen may set one), member of the device-access groups.
set -eu
getent group amnesia >/dev/null || addgroup --quiet --gid 1000 amnesia
getent passwd amnesia >/dev/null || adduser --quiet --uid 1000 --gid 1000 --disabled-password --gecos "" amnesia
for g in audio video render input plugdev netdev dip; do
    if getent group "$g" >/dev/null; then adduser --quiet amnesia "$g"; fi
done
mkdir -p /home/amnesia/Persistent
chown amnesia:amnesia /home/amnesia/Persistent
