# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Antumbra CI: functions shared by emulator-baseline.sh,
# emulator-antumbra.sh and emulator-apps.sh (the app lab). Sourced, never
# run on its own.
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
# tcpdump's buffer in KiB (-B); the app lab, whose apps send more, sets a
# larger one.
GCAP_BUFFER_KB=${GCAP_BUFFER_KB:-4096}

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
setsid sh -c 'echo \$\$ >$GCAP_PIDFILE; exec $bin -i any ${lt:+-y $lt} -n -s 0 -U -B $GCAP_BUFFER_KB -w $GCAP_DEV' </dev/null >/dev/null 2>$GCAP_ERR &" >/dev/null
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

# --- The Antumbra session (ANTUMBRA and the app lab) -------------------------
#
# Shared by emulator-antumbra.sh and emulator-apps.sh: the module installed
# the way build-module.sh --emulator does it, Welcome as device owner and
# home app, Wi-Fi, tor's bootstrap, tor's STREAM events, and the evidence
# and checks at the end. The scenario sets ZIP (the module zip) or TREE (the
# unpacked module), APK (Welcome's APK) and BOOTSTRAP_TIMEOUT, and reads
# WLAN_MAC_BEFORE (Wi-Fi's hardware address) before the module goes in.

BUILD_MODULE=${ANTUMBRA_CI_BUILD_MODULE:-$ANDROID_DIR/module/build-module.sh}
WELCOME_ADB=${ANTUMBRA_CI_WELCOME_ADB:-$ANDROID_DIR/welcome/ci/welcome-adb.sh}
PKG=org.antumbra.welcome
URI=content://org.antumbra.welcome.state/session
MODDIR=/data/adb/modules/antumbra
RT=/data/adb/antumbra
RUNAS_TOR="$MODDIR/bin/antumbra-run -u 2950 -g 2950 --"
STREAMS_SCRIPT=/data/local/tmp/antumbra-ci-streams.sh
STREAMS_PID=
STATUS_PORT=
DNS_PORT=

abort() {
	check "$1" fail "${2:-}"
	exit 1
}

# --- The DNS filter's status page and DNS port, through adb forward --------

status_port() {
	[ -n "$STATUS_PORT" ] || STATUS_PORT=$(timeout 20 adb -s "$ANTUMBRA_SERIAL" forward tcp:0 tcp:5380 2>/dev/null | tr -d '\r\n')
	[ -n "$STATUS_PORT" ]
}

# fetch_status FILE: GET /status into FILE.
fetch_status() {
	status_port || return 1
	curl -fsS --max-time 8 -o "$1.tmp" "http://127.0.0.1:$STATUS_PORT/status" 2>/dev/null &&
		mv -f "$1.tmp" "$1"
}

dns_port() {
	[ -n "$DNS_PORT" ] || DNS_PORT=$(timeout 20 adb -s "$ANTUMBRA_SERIAL" forward tcp:0 tcp:5335 2>/dev/null | tr -d '\r\n')
	[ -n "$DNS_PORT" ]
}

# --- The firewall, through the module's own directory ------------------------

# fw_status: 'antumbra-fw status' with the module's firewall directory, so
# that the recorded hash is the one the module's 'apply' wrote.
fw_status() {
	ash "ANTUMBRA_DIR=$RT/state/module/fw sh $MODDIR/bin/antumbra-fw status; echo \"exit=\$?\""
}

# fw_live_matches: true when the firewall is live and antumbra.fw.armed is
# the first 16 hex digits of the live rule set's hash, as the contract
# defines it. Sets FW_DETAIL.
FW_DETAIL=
fw_live_matches() {
	local st state hash prop
	st=$(fw_status)
	state=$(printf '%s\n' "$st" | sed -n 's/^state=//p' | head -n 1)
	hash=$(printf '%s\n' "$st" | sed -n 's/^hash=//p' | head -n 1)
	prop=$(ash 'getprop antumbra.fw.armed')
	FW_DETAIL="state=${state:-?} hash=${hash:0:16} antumbra.fw.armed=${prop:-unset}"
	[ "$state" = live ] && [ -n "$prop" ] && [ "${#hash}" -eq 64 ] && [ "$prop" = "${hash:0:16}" ]
}

# --- Reading files that tor's uid can write ---------------------------------

# as_tor_cat FILE: FILE's content, read as uid 2950 through the module's
# antumbra-run, never as root: tor can write in run/ and state/tor/, so a
# link there must not make root read (and this job publish) another file.
as_tor_cat() {
	timeout 60 adb -s "$ANTUMBRA_SERIAL" exec-out "$RUNAS_TOR /system/bin/toybox cat $1" 2>/dev/null
}

# --- tor's STREAM events ------------------------------------------------------

start_stream_recorder() {
	if ! timeout 30 adb -s "$ANTUMBRA_SERIAL" push "$CI_DIR/lib/tor-streams.sh" "$STREAMS_SCRIPT" >/dev/null 2>&1 ||
		! ash "chmod 0644 $STREAMS_SCRIPT" >/dev/null; then
		check tor_streams fail "could not push lib/tor-streams.sh"
		return 1
	fi
	adb -s "$ANTUMBRA_SERIAL" shell "$RUNAS_TOR /system/bin/sh $STREAMS_SCRIPT $RT/run" \
		>"$SDIR/tor-streams.txt" 2>"$LOGS/$SCEN-tor-streams.err" </dev/null &
	STREAMS_PID=$!
	event tor_streams_recording
}

stop_stream_recorder() {
	[ -n "$STREAMS_PID" ] || return 0
	ash "pkill -f antumbra-ci-streams; pkill -f 'toybox nc -U $RT/run/tor-control.sock'" >/dev/null 2>&1
	sleep 1
	kill "$STREAMS_PID" 2>/dev/null
	wait "$STREAMS_PID" 2>/dev/null
	STREAMS_PID=
	if grep -q '^650 STREAM ' "$SDIR/tor-streams.txt" 2>/dev/null; then
		check tor_streams ok "$(grep -c '^650 STREAM ' "$SDIR/tor-streams.txt") STREAM events recorded"
	else
		check tor_streams warn "no STREAM event recorded ($(head -c 300 "$LOGS/$SCEN-tor-streams.err" 2>/dev/null | tr '\n' ' '))"
	fi
}

# --- The session's steps ---------------------------------------------------

quiet_network() {
	ash 'cmd connectivity airplane-mode enable' >/dev/null ||
		ash 'settings put global airplane_mode_on 1; am broadcast -a android.intent.action.AIRPLANE_MODE --ez state true' >/dev/null
	if wait_network down 60; then
		check airplane_mode ok "no default network before the module is installed"
	else
		check airplane_mode warn "Android still had a network ($(default_network)); packets near the arm cutoff may count as leaks"
	fi
	# Let connections that were being torn down finish.
	sleep 10
}

install_module() {
	local args=(--emulator --serial "$ANTUMBRA_SERIAL" --no-overlay) i
	if [ -n "$ZIP" ]; then
		args+=(--zip "$ZIP")
	else
		args+=(--tor "$TREE/bin" --dnsfilter "$TREE/bin" --helper "$TREE/bin" --blocklist "$TREE/lists/dnsfilter.list")
	fi
	# The DNS filter's query log, for the list of names the system looks up
	# (dnsfilter/README.md, -debug-log-queries). The module passes the flag
	# only on the emulator; never on a phone.
	ash 'setprop debug.antumbra.log_queries 1' >/dev/null
	event install_start
	# build-module.sh adds post_fs_data_start, the arm cutoff (analyse.sh).
	if ! ANTUMBRA_EVENTS=$SDIR/events.tsv sh "$BUILD_MODULE" "${args[@]}" >"$LOGS/$SCEN-build-module.log" 2>&1; then
		tail -n 30 "$LOGS/$SCEN-build-module.log" >&2
		abort module_install "build-module.sh --emulator failed (logs/$SCEN-build-module.log)"
	fi
	for i in 1 2 3 4 5 6; do
		fw_live_matches && break
		sleep 5
	done
	event module_live "$FW_DETAIL"
	device_clock
	if fw_live_matches; then
		check module_install ok "$FW_DETAIL"
	else
		abort module_install "the firewall is not live with a matching antumbra.fw.armed after build-module.sh: $FW_DETAIL"
	fi
	wait_system_ready 300 || abort system_ready_after_module "the framework did not come back within 5 minutes"
}

network_on() {
	ash 'cmd connectivity airplane-mode disable' >/dev/null ||
		ash 'settings put global airplane_mode_on 0; am broadcast -a android.intent.action.AIRPLANE_MODE --ez state false' >/dev/null
	# The phone has no SIM: the emulator's simulated mobile data is switched
	# off, so that Wi-Fi is its only network, as on the phone.
	ash 'svc data disable' >/dev/null 2>&1 || ash 'cmd phone data disable' >/dev/null 2>&1
	event network_on "mobile data off"
	sleep 10
	local t
	t=$(default_transport)
	# A warning: what the run requires is Wi-Fi as the default network
	# (wifi_join), and the capture judges every interface's traffic.
	case $t in
	*CELLULAR*) check mobile_data_off warn "the default network is mobile data after 'svc data disable'" ;;
	*) check mobile_data_off ok "default network after airplane mode off: $t" ;;
	esac
}

install_welcome() {
	local out
	out=$(timeout 180 adb -s "$ANTUMBRA_SERIAL" install -r -t "$APK" 2>&1)
	printf '%s\n' "$out" >"$LOGS/$SCEN-welcome-install.txt"
	printf '%s' "$out" | grep -q Success || abort welcome_install "adb install: $(printf '%s' "$out" | tail -n 1)"
	# The debug build's test hook: Welcome leaves USB debugging on in every
	# session, so that a default session (Administration off) can be
	# checked over adb. A release build never reads it.
	ash 'setprop debug.antumbra.keep_adb 1' >/dev/null
	[ "$(ash 'getprop debug.antumbra.keep_adb')" = 1 ] || abort welcome_test_hook "setprop debug.antumbra.keep_adb 1 did not hold"
	# Device owner needs user 0 unlocked; one retry if the framework was
	# still unlocking it. Android refuses device owner while any account
	# exists, so the accounts are kept for the report when it does.
	local try
	for try in 1 2; do
		wait_system_ready 120 || true
		out=$(ash "dpm set-device-owner $PKG/.AdminReceiver" 2>&1)
		printf 'attempt %s:\n%s\n' "$try" "$out" >>"$LOGS/$SCEN-welcome-install.txt"
		case $out in
		*"running and unlocked"*) sleep 10 ;;
		*accounts*)
			ash 'dumpsys account' >"$LOGS/$SCEN-accounts.txt" 2>&1
			break
			;;
		*) break ;;
		esac
	done
	sleep 3
	wait_device 60
	[ "$(ash 'id -u')" = 0 ] || abort adb_after_device_owner "adb lost its root shell when Welcome became the device owner (is the test hook honoured?)"
	ash 'dpm list-owners' | grep -q "$PKG" || abort device_owner "dpm set-device-owner: $out"
	check device_owner ok
	# Welcome makes itself the home screen as device owner; the role makes
	# sure, and HOME brings it up.
	ash "cmd role add-role-holder --user 0 android.app.role.HOME $PKG" >/dev/null 2>&1 ||
		ash "cmd package set-home-activity --user 0 $PKG/.WelcomeActivity" >/dev/null 2>&1
	ash "am start -W -n $PKG/.WelcomeActivity" >/dev/null 2>&1
	wake_screen
	ash 'input keyevent KEYCODE_HOME' >/dev/null
	event welcome_installed
}

# wifi_join: join the emulator's Wi-Fi network the way a person would, once
# Welcome has switched Wi-Fi on, and require Wi-Fi as the default network.
wifi_join() {
	local i out t=''
	for i in $(seq 1 20); do
		ash 'cmd wifi status' | grep -q 'Wifi is enabled' && break
		sleep 3
	done
	ash 'cmd wifi status' >"$LOGS/$SCEN-wifi.txt" 2>&1
	out=$(ash 'cmd wifi connect-network AndroidWifi open' 2>&1)
	printf '# cmd wifi connect-network AndroidWifi open\n%s\n' "$out" >>"$LOGS/$SCEN-wifi.txt"
	event wifi_join
	for i in $(seq 1 40); do
		t=$(default_transport)
		case $t in *WIFI*) break ;; esac
		sleep 3
	done
	{
		echo "# default network: $t"
		ash 'cmd wifi status'
		ash 'ip addr show wlan0'
		echo "# non_persistent_mac_randomization_force_enabled"
		ash 'settings get global non_persistent_mac_randomization_force_enabled'
	} >>"$LOGS/$SCEN-wifi.txt" 2>&1
	guest_links wifi_join
	case $t in
	*WIFI*)
		event wifi_default "$t"
		check wifi_default ok "the default network is Wi-Fi ($t)"
		;;
	*) check wifi_default fail "Wi-Fi did not become the default network within 2 minutes (default: $t; logs/$SCEN-wifi.txt)" ;;
	esac
	# mac = new: Wi-Fi's hardware address differs from the one before the
	# module (a warning only: the module's part, judged on the phone).
	local now
	now=$(ash 'cat /sys/class/net/wlan0/address' 2>/dev/null)
	if [ -n "$now" ] && [ -n "${WLAN_MAC_BEFORE:-}" ] && [ "$now" != "$WLAN_MAC_BEFORE" ]; then
		check wifi_mac_new ok "wlan0 $WLAN_MAC_BEFORE before the module, $now now"
	else
		check wifi_mac_new warn "wlan0 ${WLAN_MAC_BEFORE:-?} before the module, ${now:-?} now"
	fi
}

# Welcome's own checks after Start, with its adb driver: the device-owner
# restrictions of a default session (Administration off, the test hook on,
# Wi-Fi unlocked since the add-on is present), and the status screen
# showing the firewall live. Arguments go to check-policies ('--admin' for
# a session with Administration on, the app lab's).
welcome_checks() {
	if timeout 300 bash "$WELCOME_ADB" -s "$ANTUMBRA_SERIAL" check-policies --keep-adb "$@" >"$LOGS/$SCEN-welcome-policies.txt" 2>&1; then
		check welcome_policies ok "$(tail -n 1 "$LOGS/$SCEN-welcome-policies.txt")"
	else
		check welcome_policies fail "$(grep -v '^$' "$LOGS/$SCEN-welcome-policies.txt" | tail -n 5 | tr '\n' ';')"
	fi
	if timeout 300 bash "$WELCOME_ADB" -s "$ANTUMBRA_SERIAL" check-addon >"$LOGS/$SCEN-welcome-addon.txt" 2>&1; then
		check welcome_addon ok "$(tail -n 1 "$LOGS/$SCEN-welcome-addon.txt")"
	else
		check welcome_addon fail "$(grep -v '^$' "$LOGS/$SCEN-welcome-addon.txt" | tail -n 3 | tr '\n' ';')"
	fi
}

wait_bootstrap() {
	local end=$((SECONDS + BOOTSTRAP_TIMEOUT)) b='' s='' n='' last='' t0=$SECONDS
	printf 'host_time\tbootstrap\tnetwork\tsummary\n' >"$SDIR/bootstrap-progress.tsv"
	while [ $SECONDS -lt $end ]; do
		if fetch_status "$SDIR/filter-status.json"; then
			b=$("${CITOOL[@]}" json-get "$SDIR/filter-status.json" module.tor.bootstrap)
			n=$("${CITOOL[@]}" json-get "$SDIR/filter-status.json" module.tor.network)
			s=$("${CITOOL[@]}" json-get "$SDIR/filter-status.json" module.tor.summary)
			if [ "$b|$n|$s" != "$last" ]; then
				printf '%s\t%s\t%s\t%s\n' "$(now)" "$b" "$n" "$s" >>"$SDIR/bootstrap-progress.tsv"
				say "tor: ${b:-?}% ${n:+($n) }$s"
				last="$b|$n|$s"
			fi
			if [ "$b" = 100 ]; then
				event tor_bootstrapped "$((SECONDS - t0)) s, from /status"
				check tor_bootstrap ok "100% after $((SECONDS - t0)) s (status page)"
				return 0
			fi
		fi
		if ash "grep -q 'Bootstrapped 100%' $RT/log/tor.log" >/dev/null 2>&1; then
			event tor_bootstrapped "$((SECONDS - t0)) s, from tor.log"
			check tor_bootstrap ok "100% after $((SECONDS - t0)) s (tor.log)"
			return 0
		fi
		sleep 5
	done
	check tor_bootstrap fail "tor did not reach 100% within $BOOTSTRAP_TIMEOUT s (last: ${b:-?}% $s)"
	return 1
}

# --- Evidence and checks, also after a failure ----------------------------

collect_evidence() {
	local out caps st f pid
	stop_stream_recorder
	proc_net_snapshot
	"${PY[@]}" "$CI_DIR/leak_analyser.py" tor-conns "$SDIR/proc-net-tcp.txt" >"$SDIR/tor-connections.txt" 2>/dev/null
	say "tor's connections: $(tr '\n' ' ' <"$SDIR/tor-connections.txt")"
	# tor's DataDirectory belongs to uid 2950: read as that uid.
	for f in cached-microdesc-consensus cached-consensus; do
		as_tor_cat "$RT/state/tor/$f" >"$SDIR/consensus"
		if [ -s "$SDIR/consensus" ]; then
			say "consensus: $f ($(wc -c <"$SDIR/consensus") bytes)"
			break
		fi
		rm -f "$SDIR/consensus"
	done
	ash "content query --uri $URI --projection bridges" 2>/dev/null |
		sed -e '1s/^Row: [0-9]* bridges=//' -e '/^No result found/d' -e 's/^NULL$//' >"$SDIR/bridges.txt"

	# The firewall: live, and the property is the live rule set's hash.
	{
		echo "# getprop antumbra.fw.armed"
		ash 'getprop antumbra.fw.armed'
		echo "# antumbra-fw status"
		fw_status
		echo "# iptables-save"
		ash 'iptables-save'
		echo "# ip6tables-save"
		ash 'ip6tables-save'
	} >"$LOGS/$SCEN-firewall-state.txt" 2>&1
	if fw_live_matches; then
		check firewall_live ok "$FW_DETAIL"
	else
		check firewall_live fail "$FW_DETAIL"
	fi

	# tor and the filter run with no capabilities (pivot checks).
	# shellcheck disable=SC2016 # expanded on the device
	caps=$(ash 'for s in /proc/[0-9]*/status; do
		u=$(sed -n "s/^Uid:[[:space:]]*\([0-9]*\).*/\1/p" "$s" 2>/dev/null)
		case $u in 2950|2951)
			printf "%s %s %s %s\n" "$u" "$(sed -n "s/^Name:[[:space:]]*//p" "$s")" \
				"$(sed -n "s/^CapEff:[[:space:]]*//p" "$s")" "$(sed -n "s/^CapPrm:[[:space:]]*//p" "$s")";;
		esac
	done')
	printf '%s\n' "$caps" >"$LOGS/$SCEN-process-caps.txt"
	for u in 2950 2951; do
		out=$(printf '%s\n' "$caps" | grep "^$u " || true)
		if [ -z "$out" ]; then
			check "process_uid_$u" fail "no process runs as uid $u"
		elif printf '%s\n' "$out" | grep -qv " 0000000000000000 0000000000000000$"; then
			check "process_caps_$u" fail "capabilities left: $(printf '%s' "$out" | tr '\n' ';')"
		else
			check "process_caps_$u" ok "$(printf '%s' "$out" | tr '\n' ';')"
		fi
	done

	# The contract's sockets: tor (2950) listens only on TCP 127.0.0.1:9040
	# (TransPort) and UDP 127.0.0.1:9053 (DNSPort), the filter (2951) only
	# on 127.0.0.1:5335 (UDP and TCP) and TCP 127.0.0.1:5380; no SOCKSPort
	# or ControlPort on any port, for any uid; and no other uid holds one of
	# the service ports, on any address (a squatter would receive what the
	# firewall redirects there).
	{
		"${PY[@]}" "$CI_DIR/leak_analyser.py" listeners --proto tcp "$SDIR/proc-net-tcp.txt"
		"${PY[@]}" "$CI_DIR/leak_analyser.py" listeners --proto udp "$SDIR/proc-net-udp.txt"
	} >"$SDIR/listeners.txt" 2>/dev/null
	out=$(awk '
		$1 == "tcp" && ($4 == 9050 || $4 == 9051 || $4 == 9052 || $4 == 9150 || $4 == 9151) { print; next }
		($4 == 9040 || $4 == 9053) && $2 != 2950 { print "port held by another uid: " $0; next }
		($4 == 5335 || $4 == 5380) && $2 != 2951 { print "port held by another uid: " $0; next }
		$2 != 2950 && $2 != 2951 { next }
		$3 != "127.0.0.1" { print; next }
		$1 == "tcp" && $2 == 2950 && $4 != 9040 { print; next }
		$1 == "udp" && $2 == 2950 && $4 != 9053 { print; next }
		$1 == "tcp" && $2 == 2951 && $4 != 5335 && $4 != 5380 { print; next }
		$1 == "udp" && $2 == 2951 && $4 != 5335 { print }
	' "$SDIR/listeners.txt")
	if [ -n "$out" ]; then
		check listeners fail "sockets outside the contract: $(printf '%s' "$out" | tr '\n' ';')"
	else
		check listeners ok "tor and the filter listen on their loopback ports only, and only they do; no SOCKS or control port"
	fi
	for want in "tcp 2950 127.0.0.1 9040" "udp 2950 127.0.0.1 9053" "tcp 2951 127.0.0.1 5335" \
		"udp 2951 127.0.0.1 5335" "tcp 2951 127.0.0.1 5380"; do
		grep -qx "$want" "$SDIR/listeners.txt" || check "listener:${want// /:}" warn "not listening"
	done
	st=$(ash "if [ -S $RT/run/tor-control.sock ]; then stat -c '%a %u %g' $RT/run/tor-control.sock; else echo 'not a socket'; fi" 2>&1)
	if [ "$st" = "660 2950 2950" ]; then
		check control_socket ok "tor-control.sock 0660 2950:2950"
	else
		check control_socket fail "tor-control.sock: $st (want a socket, 660 2950 2950)"
	fi

	# Saved Wi-Fi networks and the DHCP lease memory live in RAM only, as
	# the processes that write them see their mounts: system_server
	# (WifiConfigStore) and NetworkStack (IpMemoryStore), each in its own
	# mount namespace.
	pid=$(ash 'pidof system_server' | awk '{ print $1 }')
	ash "cat /proc/$pid/mountinfo" >"$LOGS/$SCEN-mountinfo-system_server.txt" 2>&1
	out=$(awk '{ for (i = 7; i <= NF; i++) if ($i == "-") { print $5, $(i + 1); break } }' \
		"$LOGS/$SCEN-mountinfo-system_server.txt" | awk '$1 == "/data/misc/apexdata/com.android.wifi" { t = $2 } END { print t }')
	if [ "$out" = tmpfs ]; then
		check wifi_store_in_ram ok "/data/misc/apexdata/com.android.wifi is a tmpfs in system_server's mount namespace (pid $pid)"
	else
		check wifi_store_in_ram fail "Wi-Fi's store is not on a tmpfs in system_server's mount namespace (pid ${pid:-?}): ${out:-not a mount point}"
	fi
	pid=$(ash 'pidof com.android.networkstack.process com.google.android.networkstack.process' | awk '{ print $1 }')
	[ -n "$pid" ] || pid=$(ash 'pidof system_server' | awk '{ print $1 }')
	ash "cat /proc/$pid/mountinfo" >"$LOGS/$SCEN-mountinfo-networkstack.txt" 2>&1
	out=$(awk '{ for (i = 7; i <= NF; i++) if ($i == "-") { print $5, $(i + 1); break } }' \
		"$LOGS/$SCEN-mountinfo-networkstack.txt" | awk '$1 ~ /networkstack[^ ]*\/databases$/ { t = $1 " " $2 } END { print t }')
	if [ "${out##* }" = tmpfs ]; then
		check dhcp_memory_in_ram ok "$out (pid $pid)"
	else
		check dhcp_memory_in_ram warn "NetworkStack's databases are not on a tmpfs in its mount namespace (pid ${pid:-?}): ${out:-not a mount point}"
	fi

	# IPv6 off on every interface but loopback: no address at all, and
	# disable_ipv6=1 everywhere else (all, default and each interface).
	ash 'ip -6 addr' >"$LOGS/$SCEN-ipv6.txt" 2>&1
	# shellcheck disable=SC2016 # expanded on the device
	ash 'for f in /proc/sys/net/ipv6/conf/*/disable_ipv6; do echo "$f $(cat "$f")"; done' >"$SDIR/disable-ipv6.txt" 2>&1
	cat "$SDIR/disable-ipv6.txt" >>"$LOGS/$SCEN-ipv6.txt"
	out=$(awk '/^[0-9]+: / { i = $2; sub(":$", "", i); sub("@.*", "", i) } /^ *inet6 / && i != "lo" { print i " " $2 }' "$LOGS/$SCEN-ipv6.txt")
	st=$(awk '$1 ~ /\/disable_ipv6$/ && $1 !~ /\/conf\/lo\// && $2 != 1 { split($1, p, "/"); print p[7] "=" $2 }' "$SDIR/disable-ipv6.txt")
	if [ -n "$out" ] || [ -n "$st" ]; then
		check ipv6_off fail "IPv6 is not off: addresses: $(printf '%s' "${out:-none}" | tr '\n' ';'); disable_ipv6=0 on: $(printf '%s' "${st:-none}" | tr '\n' ' ')"
	else
		check ipv6_off ok "no IPv6 address but loopback's; disable_ipv6=1 on every interface but lo"
	fi

	# The device's addresses: each must appear in the capture as a sender.
	ash 'ip -4 addr' >"$SDIR/device-ipv4.txt" 2>&1

	# The module's own logs. The log directory is root's; tor.log is the
	# only file there that tor's uid may write, and it cannot be replaced
	# by a link in that directory.
	for f in tor.log module.log firewall.log dnsfilter.log; do
		timeout 30 adb -s "$ANTUMBRA_SERIAL" exec-out cat "$RT/log/$f" 2>/dev/null | tail -c 1000000 >"$LOGS/$SCEN-$f"
		[ -s "$LOGS/$SCEN-$f" ] || rm -f "$LOGS/$SCEN-$f"
	done
	# The filter's whole log, with its query lines, for the leak report.
	timeout 60 adb -s "$ANTUMBRA_SERIAL" exec-out cat "$RT/log/dnsfilter.log" 2>/dev/null | head -c 8000000 >"$SDIR/dnsfilter.log"
	if grep -q 'debug mode: query names will be logged' "$SDIR/dnsfilter.log"; then
		check filter_query_log ok "$(grep -c ' query "' "$SDIR/dnsfilter.log") queries logged"
	else
		check filter_query_log warn "the DNS filter did not run with -debug-log-queries: the module did not honour debug.antumbra.log_queries"
	fi
	# status.json is in run/, which tor's uid can write: read as that uid.
	as_tor_cat "$RT/run/status.json" >"$LOGS/$SCEN-module-status.json"
	ash 'dumpsys connectivity' 2>/dev/null | head -n 400 >"$LOGS/$SCEN-connectivity.txt"
	ash 'dumpsys user' 2>/dev/null | head -n 200 >"$LOGS/$SCEN-users.txt"
	fetch_status "$SDIR/filter-status.json"
	netfilter_counters
}

# netfilter_counters: for diagnosis only, at the very end: the packet and
# byte counters of every rule (which drop rules were hit, for example while
# tor bootstrapped), conntrack's statistics, and the kernel's protocol
# counters (TCP retransmissions, UDP errors).
netfilter_counters() {
	{
		echo "# iptables-save -c"
		ash 'iptables-save -c'
		echo "# ip6tables-save -c"
		ash 'ip6tables-save -c'
		echo "# /proc/net/stat/nf_conntrack, nf_conntrack_count, nf_conntrack_max"
		ash 'cat /proc/net/stat/nf_conntrack /proc/sys/net/netfilter/nf_conntrack_count /proc/sys/net/netfilter/nf_conntrack_max'
		if ash 'command -v nstat' >/dev/null 2>&1; then
			echo "# nstat -asz"
			ash 'nstat -asz'
		else
			echo "# /proc/net/netstat (no nstat)"
			ash 'cat /proc/net/netstat'
		fi
		echo "# /proc/net/snmp"
		ash 'cat /proc/net/snmp'
	} >"$LOGS/$SCEN-netfilter-counters.txt" 2>&1
}
