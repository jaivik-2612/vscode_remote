# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Antumbra CI: functions shared by emulator-baseline.sh and
# emulator-antumbra.sh. Sourced, never run on its own.
#
# Environment:
#   ANTUMBRA_CI_OUT   the report directory (the artifact's root); required
#   ANTUMBRA_SERIAL   adb serial of the emulator (default emulator-5554)
#   ANTUMBRA_CAPTURE  the emulator's -tcpdump file, for 'network capture stop'
#
# Each scenario writes, under $ANTUMBRA_CI_OUT/<scenario>/:
#   events.tsv   NAME TAB HOST-TIME TAB DETAIL: what happened when (the leak
#                analyser places these on the capture's time line)
#   checks.tsv   NAME TAB ok|warn|fail TAB DETAIL
#   result       the scenario's exit status
# and puts screenshots in $ANTUMBRA_CI_OUT/screenshots/<scenario>-*.png and
# logs in $ANTUMBRA_CI_OUT/logs/<scenario>-*.

# Several of these are used only by the scripts that source this file.
# shellcheck disable=SC2034
CI_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC2034
ANDROID_DIR=$(cd "$CI_DIR/.." && pwd)
: "${ANTUMBRA_SERIAL:=emulator-5554}"
: "${ANTUMBRA_CI_OUT:?set ANTUMBRA_CI_OUT to the report directory}"
PY=(python3 -B -I)
CITOOL=("${PY[@]}" "$CI_DIR/citool.py")
SHOTS=$ANTUMBRA_CI_OUT/screenshots
LOGS=$ANTUMBRA_CI_OUT/logs
SCEN=
SDIR=
FAILED=0
UI_XML=/data/local/tmp/antumbra-ci-ui.xml

scenario_init() {
	SCEN=$1
	SDIR=$ANTUMBRA_CI_OUT/$SCEN
	mkdir -p "$SDIR" "$SHOTS" "$LOGS"
	: >"$SDIR/events.tsv"
	: >"$SDIR/checks.tsv"
	rm -f "$SDIR/result"
}

say() { printf '[%s %s] %s\n' "$SCEN" "$(date -u +%H:%M:%S)" "$*" >&2; }
now() { date +%s.%N; }

# event NAME [DETAIL]: record the host time of something that happened.
event() {
	printf '%s\t%s\t%s\n' "$1" "$(now)" "${2:-}" >>"$SDIR/events.tsv"
	say "event $1${2:+ ($2)}"
}

# check NAME ok|warn|fail [DETAIL]
check() {
	printf '%s\t%s\t%s\n' "$1" "$2" "$(printf '%s' "${3:-}" | tr '\t\n\r' '   ' | cut -c1-500)" >>"$SDIR/checks.tsv"
	say "check $1: $2${3:+ - $3}"
	# shellcheck disable=SC2034 # read by the scenario scripts
	if [ "$2" = fail ]; then FAILED=1; fi
	return 0
}

adb_() { adb -s "$ANTUMBRA_SERIAL" "$@"; }

# ash 'COMMAND': run a shell command on the device, with a time limit, and
# strip carriage returns. The exit status is the device command's (adb's
# shell protocol, Android 7 and later, passes it on), or 124 on time-out.
ash() {
	timeout "${ASH_TIMEOUT:-60}" adb -s "$ANTUMBRA_SERIAL" shell "$1" 2>&1 | tr -d '\r'
	return "${PIPESTATUS[0]}"
}

wait_device() {
	timeout "${1:-120}" adb -s "$ANTUMBRA_SERIAL" wait-for-device
}

# wait_system_ready SECONDS: the package manager and connectivity service
# answer (after boot, or after build-module.sh restarted the framework).
wait_system_ready() {
	local end=$((SECONDS + ${1:-180}))
	wait_device "${1:-180}" || return 1
	while [ $SECONDS -lt $end ]; do
		if [ "$(ash 'getprop sys.boot_completed' 2>/dev/null)" = 1 ] &&
			ash 'pm path android' >/dev/null 2>&1 &&
			ash 'cmd connectivity airplane-mode' >/dev/null 2>&1 &&
			[ "$(ash 'getprop init.svc.bootanim' 2>/dev/null)" != running ]; then
			return 0
		fi
		sleep 3
	done
	return 1
}

# The network Android uses by default ("none" when there is none).
default_network() {
	ash 'dumpsys connectivity' 2>/dev/null | sed -n 's/^ *Active default network: *//p' | head -n 1
}

# wait_network up|down SECONDS
wait_network() {
	local want=$1 end=$((SECONDS + $2)) n
	while [ $SECONDS -lt $end ]; do
		n=$(default_network)
		case $want:$n in
		down:none | down:) return 0 ;;
		up:none | up:) ;;
		up:*) return 0 ;;
		esac
		sleep 2
	done
	return 1
}

# screenshot NAME: $SHOTS/<scenario>-NAME.png
screenshot() {
	local f=$SHOTS/$SCEN-$1.png
	timeout 30 adb -s "$ANTUMBRA_SERIAL" exec-out screencap -p >"$f" 2>/dev/null
	if [ "$(head -c 8 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = 89504e470d0a1a0a ]; then
		say "screenshot $(basename "$f")"
	else
		rm -f "$f"
		say "screenshot $1 failed"
	fi
}

wake_screen() {
	ash 'input keyevent KEYCODE_WAKEUP' >/dev/null 2>&1
	ash 'wm dismiss-keyguard' >/dev/null 2>&1
	sleep 1
}

# --- The screen, through uiautomator --------------------------------------

ui_dump() {
	local i
	for i in 1 2 3; do
		if timeout 40 adb -s "$ANTUMBRA_SERIAL" shell uiautomator dump "$UI_XML" >/dev/null 2>&1; then
			timeout 20 adb -s "$ANTUMBRA_SERIAL" exec-out cat "$UI_XML" && return 0
		fi
		sleep 2
	done
	return 1
}

# ui_find ID [TEXT-REGEX]: prints "X Y CHECKED ENABLED" for the control on
# screen now, found by its test tag or, failing that, its text.
ui_find() {
	local xml
	xml=$(ui_dump) || return 1
	printf '%s' "$xml" | "${CITOOL[@]}" ui-find --id "$1" ${2:+--text "$2"}
}

screen_size() {
	ash 'wm size' | sed -n 's/.*: *\([0-9][0-9]*\)x\([0-9][0-9]*\).*/\1 \2/p' | tail -n 1
}

# ui_locate ID [TEXT]: like ui_find, scrolling down (then back up) through
# the page until the control is on screen.
ui_locate() {
	local w h i node
	read -r w h < <(screen_size)
	w=${w:-1080} h=${h:-2400}
	for i in 1 2 3 4 5 6 7 8 9; do
		if node=$(ui_find "$@") && [ -n "$node" ]; then
			echo "$node"
			return 0
		fi
		if [ "$i" -le 5 ]; then
			ash "input swipe $((w / 2)) $((h * 6 / 10)) $((w / 2)) $((h * 3 / 10)) 300" >/dev/null
		else
			ash "input swipe $((w / 2)) $((h * 3 / 10)) $((w / 2)) $((h * 8 / 10)) 300" >/dev/null
		fi
		sleep 1
	done
	return 1
}

# ui_tap ID [TEXT]
ui_tap() {
	local x y _c _e
	read -r x y _c _e < <(ui_locate "$@") || return 1
	[ -n "${x:-}" ] || return 1
	ash "input tap $x $y" >/dev/null
	say "tapped $1 at $x,$y"
}

# ui_set_switch ID true|false [TEXT]
ui_set_switch() {
	local id=$1 want=$2 x y checked _e
	shift 2
	read -r x y checked _e < <(ui_locate "$id" "$@") || return 1
	[ -n "${x:-}" ] || return 1
	if [ "$checked" != "$want" ]; then
		ash "input tap $x $y" >/dev/null
		sleep 1
		read -r x y checked _e < <(ui_find "$id" "$@")
		say "switch $id is now $checked"
		[ "$checked" = "$want" ]
	else
		say "switch $id already $want"
	fi
}

# ui_wait ID SECONDS [TEXT]
ui_wait() {
	local id=$1 end=$((SECONDS + $2))
	shift 2
	while [ $SECONDS -lt $end ]; do
		if ui_find "$id" "$@" | grep -q .; then return 0; fi
		sleep 3
	done
	return 1
}

# --- Evidence ------------------------------------------------------------

# clock_marker: one UDP datagram "ANTUMBRA-CLOCK <nonce>" to the emulator
# host alias's discard port, between two host time stamps, so that the leak
# analyser can line up the capture's clock with events.tsv. Sent only
# before the module is installed.
clock_marker() {
	local nonce
	nonce=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
	event clock_marker_before "$nonce"
	ash "echo 'ANTUMBRA-CLOCK $nonce' | toybox nc -u -w 1 10.0.2.2 9" >/dev/null 2>&1 ||
		ash "echo 'ANTUMBRA-CLOCK $nonce' | nc -u -w 1 10.0.2.2 9" >/dev/null 2>&1
	event clock_marker_after "$nonce"
}

device_info() {
	{
		echo "# getprop (selected)"
		ash 'getprop' | grep -E '^\[(ro\.build\.(fingerprint|version\.(release|sdk|security_patch|incremental)|type|tags)|ro\.product\.(model|cpu\.abi)|ro\.kernel\.qemu|ro\.boot\.qemu[^]]*|ro\.hardware|ro\.debuggable|persist\.sys\.timezone)\]'
		echo "# uname"
		ash 'uname -a'
		echo "# emulator on the host"
		"${ANDROID_HOME:-/usr/local/lib/android/sdk}/emulator/emulator" -version 2>/dev/null | head -n 2
		echo "# interfaces"
		ash 'ip addr'
	} >"$LOGS/$SCEN-device.txt" 2>&1
}

collect_logcat() {
	timeout 60 adb -s "$ANTUMBRA_SERIAL" logcat -d -v threadtime -b main,system,crash 2>/dev/null | tr -d '\r' |
		grep -E -i 'antumbra|welcome|AndroidRuntime|FATAL|NetworkMonitor|ConnectivityService|DnsResolver|netd|WifiService|WifiClientModeImpl|DhcpClient|IpClient|NetworkStack|DevicePolicy|tor\b' |
		tail -c 1500000 >"$LOGS/$SCEN-logcat.txt"
}

proc_net_snapshot() {
	ash 'cat /proc/net/tcp /proc/net/tcp6' >"$SDIR/proc-net-tcp.txt" 2>&1
	ash 'cat /proc/net/udp /proc/net/udp6' >"$SDIR/proc-net-udp.txt" 2>&1
}

# capture_stop: close the emulator's packet capture (it is flushed when the
# emulator exits in any case). The console wants the capture's file name.
capture_stop() {
	local out
	event capture_stop
	out=$(timeout 20 adb -s "$ANTUMBRA_SERIAL" emu network capture stop 2>&1)
	if ! printf '%s' "$out" | grep -q '^OK' && [ -n "${ANTUMBRA_CAPTURE:-}" ]; then
		out="$out
$(timeout 20 adb -s "$ANTUMBRA_SERIAL" emu network capture stop "$(basename "$ANTUMBRA_CAPTURE")" 2>&1)"
	fi
	printf '%s\n' "$out" >"$LOGS/$SCEN-capture-stop.txt"
}

# json_obj KEY=VALUE...: one JSON object of strings, on one line.
json_obj() {
	"${PY[@]}" -c 'import json, sys
print(json.dumps(dict(a.split("=", 1) for a in sys.argv[1:]), sort_keys=True))' "$@"
}
