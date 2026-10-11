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
#   ANTUMBRA_CI_IMAGE the system image, as sdkmanager names it without the
#                     'system-images;' prefix (default android-36;default;x86_64),
#                     to record its revision
#
# Each scenario writes, under $ANTUMBRA_CI_OUT/<scenario>/:
#   events.tsv   NAME TAB HOST-TIME TAB DETAIL: what happened when (the leak
#                analyser places these on the captures' time lines)
#   checks.tsv   NAME TAB ok|warn|fail TAB DETAIL
#   guest-links.txt  the guest's 'ip -o link' and 'ip -o addr' (interface
#                names for the capture inside the guest)
#   result       the scenario's exit status
# and puts screenshots in $ANTUMBRA_CI_OUT/screenshots/<scenario>-*.png,
# logs in $ANTUMBRA_CI_OUT/logs/<scenario>-* and the capture inside the
# guest in $ANTUMBRA_CI_OUT/capture/<scenario>-guest.pcap.

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

# user0_unlocked: user 0 is running and unlocked. sys.boot_completed stays
# 1 when build-module.sh restarts the framework, so it cannot tell; device
# owner and credential-encrypted storage need the user unlocked (run 3:
# "User must be running and unlocked" five seconds after the restart).
user0_unlocked() {
	ash 'am get-started-user-state 0' 2>/dev/null | grep -q RUNNING_UNLOCKED ||
		ash 'dumpsys user' 2>/dev/null | grep -q 'State: RUNNING_UNLOCKED'
}

# wait_system_ready SECONDS: the package manager and connectivity service
# answer and user 0 is unlocked (after boot, or after build-module.sh
# restarted the framework).
wait_system_ready() {
	local end=$((SECONDS + ${1:-180}))
	wait_device "${1:-180}" || return 1
	while [ $SECONDS -lt $end ]; do
		if [ "$(ash 'getprop sys.boot_completed' 2>/dev/null)" = 1 ] &&
			ash 'pm path android' >/dev/null 2>&1 &&
			ash 'cmd connectivity airplane-mode' >/dev/null 2>&1 &&
			[ "$(ash 'getprop init.svc.bootanim' 2>/dev/null)" != running ] &&
			user0_unlocked; then
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

# The transports of the default network (WIFI, CELLULAR, ...; "none" when
# there is none), from the NetworkAgentInfo line that names it.
default_transport() {
	local d n t
	d=$(ash 'dumpsys connectivity' 2>/dev/null)
	n=$(printf '%s\n' "$d" | sed -n 's/^ *Active default network: *//p' | head -n 1)
	case $n in '' | none) echo none; return 0 ;; esac
	t=$(printf '%s\n' "$d" | grep -F "network{$n}" | grep -o 'Transports: [A-Z_|]*' | head -n 1)
	if [ -z "$t" ]; then
		t=$(printf '%s\n' "$d" | grep -F "network{$n}" | grep -o 'ni{[A-Z_]*' | head -n 1)
	fi
	t=${t#Transports: }
	t=${t#ni\{}
	echo "${t:-unknown}"
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

# clock_marker: between two host time stamps, one adb call reads the
# device's clock and sends the clock marker: an ICMP echo request to the
# emulator host alias 10.0.2.2 from each interface with an IPv4 address
# (ping -I; its data holds "ANTUMBRA" and the nonce, ping -p), so that the
# emulator's capture (eth0) and the capture inside the guest (every
# interface) each hold one, and a UDP datagram "ANTUMBRA-CLOCK <nonce>" to
# 10.0.2.2:9 by the default route. The leak analyser lines up each
# capture's clock with events.tsv from them. Every command has a time
# limit: toybox nc -u never exits by itself (-w only limits the connect),
# and run 4's two 60 s time-outs made the stamps 120 s apart. Sent only
# before the module is installed.
clock_marker() {
	local nonce out
	nonce=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
	event clock_marker_before "$nonce"
	out=$(ASH_TIMEOUT=15 ash "date +%s.%N
echo 'ANTUMBRA-CLOCK $nonce' | toybox timeout 1 toybox nc -u 10.0.2.2 9 >/dev/null 2>&1 &
for i in \$(ip -o -4 addr show | awk '\$2 != \"lo\" { sub(\"@.*\", \"\", \$2); print \$2 }' | sort -u); do
	echo \"iface \$i\"
	toybox timeout 2 ping -c 1 -W 1 -I \"\$i\" -p 414e54554d425241$nonce 10.0.2.2 >/dev/null 2>&1 &
done
wait")
	event clock_marker_after "$nonce device=$(printf '%s\n' "$out" | head -n 1) ifaces=$(printf '%s\n' "$out" | sed -n 's/^iface //p' | paste -sd, -)"
}

# device_clock: one reading of the device's clock between two host time
# stamps (event device_clock, "device=SECONDS host_after=SECONDS"). The
# capture inside the guest runs on that clock; the leak analyser checks
# that it stayed where the clock marker put it.
device_clock() {
	local t d
	t=$(now)
	d=$(ASH_TIMEOUT=15 ash 'date +%s.%N' | head -n 1)
	printf 'device_clock\t%s\tdevice=%s host_after=%s\n' "$t" "$d" "$(now)" >>"$SDIR/events.tsv"
	say "device clock $d"
}

# --- The capture inside the guest ------------------------------------------
#
# The emulator's -tcpdump records only its first network card (the guest's
# eth0, the emulated radio); Wi-Fi leaves by another path (run 4: wlan0's
# 10.0.2.16 and all five of tor's connections were missing). tcpdump runs
# inside the guest as root on every interface ('-i any', which also takes
# in interfaces that appear later, as wlan0 does). A frame leaving an
# interface is recorded after netfilter, so it is what left the phone. The
# emulator's capture stays as a second, independent view of eth0.

GCAP_DEV=/data/local/tmp/antumbra-ci-guest.pcap
GCAP_ERR=/data/local/tmp/antumbra-ci-guest.err
GCAP_PIDFILE=/data/local/tmp/antumbra-ci-guest.pid
GCAP_PID=
GCAP_LEVEL=fail

# guest_links NOTE: the guest's interfaces (index, name, hardware address)
# and addresses, appended to <scenario>/guest-links.txt, for the analyser
# to name each frame's interface. Taken when the capture starts, after
# Wi-Fi is joined and at the end: Wi-Fi's interface comes and goes, and its
# hardware address changes.
guest_links() {
	{
		printf '# %s %s\n' "$1" "$(now)"
		ash 'ip -o link; ip -o addr'
	} >>"$SDIR/guest-links.txt" 2>&1
}

# guest_capture_start fail|warn: start tcpdump in the guest (whole frames,
# each written as it comes; Linux cooked v2 headers, which carry the
# interface's index, else v1). setsid: it outlives this adb shell and a
# restart of adbd. The check's level when tcpdump is missing or will not
# start: fail for ANTUMBRA, warn for the baseline (not judged).
guest_capture_start() {
	local level=$1 bin lt
	GCAP_LEVEL=$level
	guest_links capture_start
	bin=$(ash 'command -v tcpdump' | head -n 1)
	case $bin in
	/*) ;;
	*)
		check guest_capture "$level" "no tcpdump in the guest ('command -v tcpdump'): only eth0 is recorded. Userdebug images normally carry /system/bin/tcpdump; without it, a static x86_64 tcpdump must be pushed to /data/local/tmp"
		return 1
		;;
	esac
	for lt in LINUX_SLL2 ''; do
		ash "rm -f $GCAP_DEV $GCAP_ERR $GCAP_PIDFILE
setsid sh -c 'echo \$\$ >$GCAP_PIDFILE; exec $bin -i any ${lt:+-y $lt} -n -s 0 -U -B 4096 -w $GCAP_DEV' </dev/null >/dev/null 2>$GCAP_ERR &" >/dev/null
		sleep 3
		GCAP_PID=$(ash "cat $GCAP_PIDFILE 2>/dev/null")
		if [ -n "$GCAP_PID" ] && ash "grep -q tcpdump /proc/$GCAP_PID/cmdline && grep -q 'listening on' $GCAP_ERR" >/dev/null 2>&1; then
			event guest_capture_start "$bin $(ash "grep -o 'link-type [^ ]*' $GCAP_ERR" | head -n 1)"
			check guest_capture ok "$bin -i any${lt:+ -y $lt}, pid $GCAP_PID"
			return 0
		fi
		say "tcpdump ${lt:+-y $lt }did not start: $(ash "cat $GCAP_ERR" | tr '\n' ' ' | cut -c1-200)"
		GCAP_PID=
	done
	check guest_capture "$level" "tcpdump did not start in the guest: $(ash "cat $GCAP_ERR" | tr '\n' ' ' | cut -c1-300)"
	return 1
}

# guest_capture_stop: stop tcpdump with SIGTERM (a background job of a
# non-interactive shell may start with SIGINT ignored), on which it writes
# its counters; record them in the event guest_capture_stop ("captured=N
# received=N dropped=N", or why not; the analyser judges them), and pull
# the file into capture/<scenario>-guest.pcap. The process is known by its
# command line, not only by its number, which another process may reuse.
guest_capture_stop() {
	[ -n "$GCAP_PID" ] || return 0
	local t out st n f size got
	device_clock
	guest_links capture_stop
	t=$(now)
	out=$(ASH_TIMEOUT=30 ash "running() { grep -q tcpdump /proc/$GCAP_PID/cmdline 2>/dev/null; }
if running; then
	kill -TERM $GCAP_PID
	for i in 1 2 3 4 5 6 7 8 9 10; do running || break; sleep 1; done
	if running; then echo 'antumbra-ci: still running'; else echo 'antumbra-ci: stopped'; fi
else
	echo 'antumbra-ci: not running'
fi
cat $GCAP_ERR")
	printf '%s\n' "$out" >"$LOGS/$SCEN-guest-capture.txt"
	case $(printf '%s\n' "$out" | sed -n 's/^antumbra-ci: //p' | head -n 1) in
	stopped)
		st=
		for n in captured 'received by filter' 'dropped by kernel'; do
			f=$(printf '%s\n' "$out" | sed -n "s/^\([0-9][0-9]*\) packets\{0,1\} $n\$/\1/p" | tail -n 1)
			st="$st ${n%% *}=${f:-?}"
		done
		st=${st# }
		case $st in *'=?'*) st="$st (tcpdump's counters incomplete)" ;; esac
		;;
	'still running') st="still running: tcpdump did not stop on SIGTERM" ;;
	'not running') st="not running: tcpdump stopped before the end" ;;
	*) st="unknown: no answer from the device" ;;
	esac
	printf 'guest_capture_stop\t%s\t%s\n' "$t" "$st" >>"$SDIR/events.tsv"
	mkdir -p "$ANTUMBRA_CI_OUT/capture"
	f=$ANTUMBRA_CI_OUT/capture/$SCEN-guest.pcap
	timeout 600 adb -s "$ANTUMBRA_SERIAL" exec-out cat "$GCAP_DEV" >"$f" 2>/dev/null
	size=$(ash "stat -c %s $GCAP_DEV" | head -n 1)
	got=$(wc -c <"$f" | tr -d ' ')
	if [ "$size" = "$got" ] && [ "$got" -gt 24 ]; then
		check guest_capture_pulled ok "$got bytes; $st"
	else
		check guest_capture_pulled "$GCAP_LEVEL" "capture/$SCEN-guest.pcap: $got of ${size:-?} bytes; $st"
	fi
	GCAP_PID=
	say "guest capture stopped ($st)"
}

device_info() {
	{
		echo "# getprop (selected)"
		ash 'getprop' | grep -E '^\[(ro\.build\.(fingerprint|version\.(release|sdk|security_patch|incremental)|type|tags)|ro\.product\.(model|cpu\.abi)|ro\.kernel\.qemu|ro\.boot\.qemu[^]]*|ro\.hardware|ro\.debuggable|persist\.sys\.timezone)\]'
		echo "# uname"
		ash 'uname -a'
		echo "# emulator on the host"
		"${ANDROID_HOME:-/usr/local/lib/android/sdk}/emulator/emulator" -version 2>/dev/null | head -n 2
		echo "# system image on the host (${ANTUMBRA_CI_IMAGE:-android-36;default;x86_64})"
		grep -E '^(Pkg\.Revision|SystemImage\.TagId|AndroidVersion\.ApiLevel|AndroidVersion\.ExtensionLevel)=' \
			"${ANDROID_HOME:-/usr/local/lib/android/sdk}/system-images/$(printf '%s' "${ANTUMBRA_CI_IMAGE:-android-36;default;x86_64}" | tr ';' '/')/source.properties" 2>/dev/null
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
# The event is taken before the console is asked, so that the leak
# analyser can tell whether the capture's last frame lies long before it
# (frames lost at the end). Its detail says whether the console confirmed.
capture_stop() {
	local out t
	t=$(now)
	out=$(timeout 20 adb -s "$ANTUMBRA_SERIAL" emu network capture stop 2>&1)
	if ! printf '%s' "$out" | grep -q '^OK' && [ -n "${ANTUMBRA_CAPTURE:-}" ]; then
		out="$out
$(timeout 20 adb -s "$ANTUMBRA_SERIAL" emu network capture stop "$(basename "$ANTUMBRA_CAPTURE")" 2>&1)"
	fi
	printf '%s\n' "$out" >"$LOGS/$SCEN-capture-stop.txt"
	if printf '%s' "$out" | grep -q '^OK'; then
		printf 'capture_stop\t%s\tconfirmed\n' "$t" >>"$SDIR/events.tsv"
	else
		printf 'capture_stop\t%s\tnot confirmed (the file is closed when the emulator exits)\n' "$t" >>"$SDIR/events.tsv"
	fi
	say "capture stopped"
}

# json_obj KEY=VALUE...: one JSON object of strings, on one line.
json_obj() {
	"${PY[@]}" -c 'import json, sys
print(json.dumps(dict(a.split("=", 1) for a in sys.argv[1:]), sort_keys=True))' "$@"
}
