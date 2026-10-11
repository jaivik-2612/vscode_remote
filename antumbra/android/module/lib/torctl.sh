# shellcheck shell=sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Antumbra module: send commands to tor's control socket.
#
# Usage: torctl.sh COOKIE_FILE SOCKET
#   Control commands on standard input, one per line, each ending in CRLF;
#   tor's replies on standard output.
#
# It runs as uid 2950, tor's own uid, started by torctl() in antumbra.sh
# through antumbra-run, so neither the cookie nor the socket is ever
# opened by root (the directory holding them belongs to tor). The socket
# has mode 0660 and owner 2950:2950, so this uid may use it; the cookie is
# readable only by its owner.
#
# It sends AUTHENTICATE with the cookie as hex, then the commands, then
# QUIT. If authentication fails, tor answers 515 and closes the
# connection, so no command after it runs. Android's toybox netcat (0.8.12
# in Android 16) speaks to Unix sockets with -U; after the end of its input
# it half-closes the connection and keeps reading until tor closes it, at
# most 10 seconds of silence (-q 10); 'timeout 20' bounds the whole call.
set -u
TB=/system/bin/toybox

cookie=$($TB od -An -v -tx1 -N 32 "$1" 2>/dev/null | $TB tr -d ' \n')
case $cookie in
'' | *[!0-9a-f]*)
	echo "torctl: cannot read the control cookie" >&2
	exit 2
	;;
esac
if [ "${#cookie}" -ne 64 ]; then
	echo "torctl: the control cookie is not 32 bytes long" >&2
	exit 2
fi
if [ ! -S "$2" ]; then
	echo "torctl: no control socket" >&2
	exit 2
fi

{
	printf 'AUTHENTICATE %s\r\n' "$cookie"
	$TB cat
	printf 'QUIT\r\n'
} | $TB timeout 20 $TB nc -q 10 -U "$2"
