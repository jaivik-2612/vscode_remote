# shellcheck shell=sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Antumbra CI: record tor's STREAM events, for the leak report's list of
# names and destinations reached through Tor. Runs ON THE EMULATOR, as
# tor's own uid (2950): emulator-antumbra.sh pushes it to
# /data/local/tmp/antumbra-ci-streams.sh and starts it through the module's
# antumbra-run, so that root never opens the control cookie or socket in
# tor's directory (the module's rule; see module/lib/torctl.sh, which talks
# to tor the same way). Standard output (tor's replies and events) goes
# back to the CI host through adb.
#
# Usage: sh antumbra-ci-streams.sh [RUN_DIR]   (default /data/adb/antumbra/run)
#
# Each connection starts with a line "ANTUMBRA-CI-STREAMS connect UPTIME",
# then AUTHENTICATE (the cookie as hex) and SETEVENTS STREAM. A harmless
# GETINFO every 5 seconds keeps the writing side alive and notices when
# tor has gone (the write fails); the loop then connects again, so a tor
# restarted by the module is followed. emulator-antumbra.sh stops it with
# 'pkill -f antumbra-ci-streams'.
set -u
TB=/system/bin/toybox
RUN=${1:-/data/adb/antumbra/run}
COOKIE=$RUN/tor-control.authcookie
SOCK=$RUN/tor-control.sock

while :; do
	cookie=
	if [ -S "$SOCK" ]; then
		cookie=$($TB od -An -v -tx1 -N 32 "$COOKIE" 2>/dev/null | $TB tr -d ' \n')
	fi
	case $cookie in
	*[!0-9a-f]*) cookie= ;;
	esac
	if [ "${#cookie}" -eq 64 ]; then
		read -r up _ </proc/uptime
		echo "ANTUMBRA-CI-STREAMS connect $up"
		{
			printf 'AUTHENTICATE %s\r\nSETEVENTS STREAM\r\n' "$cookie"
			while sleep 5; do
				printf 'GETINFO version\r\n' || exit 0
			done
		} | $TB nc -U "$SOCK"
	fi
	sleep 3
done
