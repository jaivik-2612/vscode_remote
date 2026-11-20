#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Run a command in the experiment's root filesystem as its user amnesia (uid
# 1000), with a clean environment for phoc's X11 backend on the host's X
# server :5; its output goes to $ANTUMBRA_EXP/logs/LOGNAME.log.
# usage: run-as-user.sh LOGNAME [VAR=value ...] -- COMMAND [ARG ...]
set -eu
EXP="${ANTUMBRA_EXP:?set ANTUMBRA_EXP to the work directory of the experiment}"
R="${EXP}/root"
LOG=$1; shift
EXTRA=""
while [ "$1" != "--" ]; do EXTRA="$EXTRA $1"; shift; done; shift
mkdir -p "$EXP/logs"
# shellcheck disable=SC2086  # EXTRA is a list of VAR=value words
exec chroot --userspec=1000:1000 "$R" /usr/bin/env -i \
  HOME=/home/amnesia USER=amnesia LOGNAME=amnesia SHELL=/bin/bash \
  PATH=/usr/local/bin:/usr/bin:/bin LANG=en_US.UTF-8 \
  XDG_RUNTIME_DIR=/run/user/1000 DISPLAY=:5 \
  WLR_BACKENDS=x11 WLR_RENDERER=pixman $EXTRA \
  "$@" > "$EXP/logs/$LOG.log" 2>&1
