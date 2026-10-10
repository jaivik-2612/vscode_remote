#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Stop every process whose root directory is the experiment's root filesystem
# (TERM, then KILL), before its mounts are taken down; run as root.
EXP="${ANTUMBRA_EXP:?set ANTUMBRA_EXP to the work directory of the experiment}"
R="${EXP}/root"
for sig in TERM KILL; do
  for p in /proc/[0-9]*; do
    l=$(readlink "$p/root" 2>/dev/null) || continue
    [ "$l" = "$R" ] && kill -"$sig" "${p#/proc/}" 2>/dev/null
  done
  sleep 2
done
n=0; for p in /proc/[0-9]*; do [ "$(readlink "$p/root" 2>/dev/null)" = "$R" ] && n=$((n+1)); done; echo "remaining in chroot: $n"
