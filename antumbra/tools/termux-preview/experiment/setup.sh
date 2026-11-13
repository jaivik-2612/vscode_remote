#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Bind the host's /proc, /sys, /dev, /dev/pts, /dev/shm and X socket directory
# into the experiment's root filesystem and create the user's runtime
# directory; run as root after the overlay is mounted on $ANTUMBRA_EXP/root
# (README.md, "What was run"). Each mount is made only once.
set -eu
EXP="${ANTUMBRA_EXP:?set ANTUMBRA_EXP to the work directory of the experiment}"
R="${EXP}/root"
mountpoint -q "$R/proc" || mount -t proc proc "$R/proc"
mountpoint -q "$R/sys" || mount --bind /sys "$R/sys"
mountpoint -q "$R/dev" || mount --bind /dev "$R/dev"
mountpoint -q "$R/dev/pts" || mount --bind /dev/pts "$R/dev/pts"
if [ -d /dev/shm ] && ! mountpoint -q "$R/dev/shm"; then mount --bind /dev/shm "$R/dev/shm"; fi
mkdir -p /tmp/.X11-unix "$R/tmp/.X11-unix"
mountpoint -q "$R/tmp/.X11-unix" || mount --bind /tmp/.X11-unix "$R/tmp/.X11-unix"
mkdir -p "$R/run/user/1000" && chown 1000:1000 "$R/run/user/1000" && chmod 700 "$R/run/user/1000"
