#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Antumbra CI: the ANTUMBRA scenario. A fresh Android 16 emulator, the
# Antumbra module installed and started the way build-module.sh --emulator
# does it, the Welcome app as device owner and home screen, a default
# session (Administration off) started with "Start Antumbra", the phone on
# Wi-Fi only, tor, a tracker lookup, probes, and the firewall's armed state
# with the network up.
#
# Runs inside reactivecircus/android-emulator-runner, which has started the
# emulator with '-tcpdump <file>' (its first network card, eth0) and waited
# for sys.boot_completed. Steps:
#   1. adb root; device facts; tcpdump inside the guest on every interface
#      (lib/common.sh, guest_capture_start: Wi-Fi leaves by a path the
#      emulator's capture does not see); a clock marker for the leak
#      analyser.
#   2. Airplane mode on and wait until Android has no network. Plain
#      Android's own traffic stops here, so nothing is sent close to the
#      moment the firewall is armed.
#   3. The DNS filter's query log switched on for this run
#      (debug.antumbra.log_queries=1, which the module honours on the
#      emulator only). Event "install_start", then build-module.sh
#      --emulator --zip with the module zip itself: it installs the module,
#      stops the framework, runs post-fs-data.sh ('antumbra-fw arm' first),
#      starts the framework and service.sh, and waits until
#      antumbra.fw.armed is set. The property must be the first 16 hex
#      digits of the live rule set's hash. The leak analyser counts every
#      packet from install_start on (the arm cutoff is earlier than the real
#      'arm', never later), and checks the device's clock, read once more
#      here, against the marker. tor's STREAM events are recorded from here
#      on.
#   4. Airplane mode off and mobile data off: the phone has no SIM, so its
#      only network is Wi-Fi, which has no saved network yet.
#   5. The Welcome APK; the debug build's test hook debug.antumbra.keep_adb=1
#      (Welcome then leaves USB debugging on; see welcome/README.md, "Test
#      hook"); 'dpm set-device-owner'; Welcome as the home app.
#   6. The choices, tapped where uiautomator finds them: Tor directly, new
#      Wi-Fi address on, Administration OFF (the default session), Unsafe
#      Browser off. Then "Start Antumbra". adb must still answer; the
#      provider row must say started=1 and tor_mode=direct.
#   7. Wi-Fi joined as a person would ('cmd wifi connect-network AndroidWifi
#      open'); Wi-Fi must become the default network. Welcome's policies and
#      its status screen are checked with welcome/ci/welcome-adb.sh.
#   8. Wait for tor to bootstrap (the DNS filter's /status, else tor.log).
#   9. Tracker test: names on the block list asked of the filter directly
#      (DNS over TCP to 127.0.0.1:5335 through adb forward) and through
#      Android's resolver, plus a control name that must resolve.
#  10. Probes with the full rule set, as root and as an app (Welcome's uid,
#      through run-as): TCP to the emulator host's ports 80, 5000 and 49152
#      (the capture judges whether a SYN left), to 127.0.0.1:9052, and to
#      another app's loopback port, which must never be reached.
#  11. The armed state: service.sh's loop is paused, 'antumbra-fw flush'
#      puts the firewall back to armed with the network up, and traffic is
#      made as root, as an app and as tor's uid (ping, TCP to a relay's
#      ORPort and to 10.0.2.2:80, DNS). Between the events armed_probe_start
#      and armed_probe_end the capture must show nothing from the phone but
#      ARP and DHCP. Then the loop resumes, finds the firewall armed and
#      loads the full rule set again, which must come back live.
#  12. Evidence and checks, also after a failure: tor's established
#      connections, the consensus tor downloaded and the session's bridges
#      (read as tor's uid, never by root, since tor can write there); the
#      firewall live with the property matching; the capabilities of tor
#      and the filter; who listens on the service ports (no SOCKS or
#      control port, no other uid on 9040, 9053, 5335, 5380); the control
#      socket's mode and owner; Wi-Fi's store and NetworkStack's databases
#      on a tmpfs as system_server and NetworkStack see them; IPv6 off on
#      every interface; the device's addresses; the DNS filter's query log
#      and tor's STREAM events; logs; for diagnosis, the firewall's packet
#      counters per rule, conntrack's and the kernel's network counters.
#      Then the capture inside the guest is stopped and pulled, and the
#      emulator's capture is stopped.
#
# Environment:
#   ANTUMBRA_CI_OUT        report directory (required)
#   ANTUMBRA_MODULE_ZIP    the module zip the module job built (installed as
#                          it is with build-module.sh --emulator --zip)
#   ANTUMBRA_MODULE_TREE   the unpacked module zip: bin/<abi>/{tor,
#                          antumbra-dnsfilter,antumbra-run}, lists/; used
#                          when ANTUMBRA_MODULE_ZIP is not set (build-module.sh
#                          then stages the scripts from the checkout)
#   ANTUMBRA_WELCOME_APK   app-debug.apk (required)
#   ANTUMBRA_SERIAL, ANTUMBRA_CAPTURE, ANTUMBRA_CI_IMAGE
#   ANTUMBRA_CI_BOOTSTRAP_TIMEOUT  seconds to wait for tor (default 900)
#   ANTUMBRA_CI_TRACKERS   names that must be blocked
#                          (default "doubleclick.net stats.lineageos.org")
#   ANTUMBRA_CI_CONTROL    a name that must resolve through Tor
#                          (default check.torproject.org)
#   ANTUMBRA_CI_BUILD_MODULE  the module installer (default
#                          ../module/build-module.sh; another one only for a
#                          dry run of this script against a fake adb)
#   ANTUMBRA_CI_WELCOME_ADB   Welcome's adb driver (default
#                          ../welcome/ci/welcome-adb.sh)
set -uo pipefail

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
scenario_init antumbra

ZIP=${ANTUMBRA_MODULE_ZIP:-}
TREE=${ANTUMBRA_MODULE_TREE:-}
APK=${ANTUMBRA_WELCOME_APK:?set ANTUMBRA_WELCOME_APK to the Welcome APK}
# 900 s: tor takes the consensus from one source and starts no second
# download while that one still sends, however slowly; in run 4 a slow
# fallback directory held it at 30% for nine minutes, then moria1 sent the
# whole consensus in about a second.
BOOTSTRAP_TIMEOUT=${ANTUMBRA_CI_BOOTSTRAP_TIMEOUT:-900}
TRACKERS=${ANTUMBRA_CI_TRACKERS:-doubleclick.net stats.lineageos.org}
CONTROL=${ANTUMBRA_CI_CONTROL:-check.torproject.org}
BUILD_MODULE=${ANTUMBRA_CI_BUILD_MODULE:-$ANDROID_DIR/module/build-module.sh}
WELCOME_ADB=${ANTUMBRA_CI_WELCOME_ADB:-$ANDROID_DIR/welcome/ci/welcome-adb.sh}
PKG=org.antumbra.welcome
URI=content://org.antumbra.welcome.state/session
MODDIR=/data/adb/modules/antumbra
RT=/data/adb/antumbra
RUNAS_TOR="$MODDIR/bin/antumbra-run -u 2950 -g 2950 --"
# A uid no app has, standing in for another app (with the inet group, as an
# app with the INTERNET permission has).
OTHER_APP_UID=10998
OTHER_APP_PORT=47000
STREAMS_SCRIPT=/data/local/tmp/antumbra-ci-streams.sh
STREAMS_PID=
SERVICE_PIDS=
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

# --- Steps -----------------------------------------------------------------------

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
	if ! sh "$BUILD_MODULE" "${args[@]}" >"$LOGS/$SCEN-build-module.log" 2>&1; then
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

welcome_start() {
	ui_wait start_button 120 'Start Antumbra' || {
		screenshot welcome-missing
		abort welcome_screen "the Start Antumbra button did not appear within 2 minutes"
	}
	check welcome_screen ok
	screenshot welcome-1
	ui_tap tor_direct 'Connect to Tor directly' || abort welcome_choice "'Connect to Tor directly' not found"
	ui_set_switch switch_mac true 'New Wi-Fi hardware address' || check welcome_mac warn "could not set the Wi-Fi address switch"
	ui_set_switch switch_unsafe_browser false 'Unsafe Browser' || check welcome_unsafe warn "could not find the Unsafe Browser switch off"
	# The default session: Administration off. adb survives it only through
	# the debug build's test hook.
	ui_set_switch switch_admin false 'Administration' || abort welcome_admin "could not switch Administration off"
	screenshot welcome-2-choices
	ui_tap start_button 'Start Antumbra' || abort welcome_start "Start Antumbra not found"
	event welcome_start
	sleep 5
	wait_device 60
	[ "$(ash 'id -u')" = 0 ] || abort adb_after_start "adb lost its root shell at Start: Welcome switched USB debugging off (test hook debug.antumbra.keep_adb not honoured?)"
	if ui_wait status_title 90; then
		check status_screen ok
	else
		check status_screen warn "the status screen did not appear within 90 s"
	fi
	screenshot status-1-started
	local row
	row=$(ash "content query --uri $URI")
	printf '%s\n' "$row" >"$SDIR/provider-row.txt"
	case $row in
	*started=1*) check provider_started ok "$row" ;;
	*) check provider_started fail "the provider does not say started=1: $row" ;;
	esac
	case $row in
	*tor_mode=direct*) check provider_mode ok ;;
	*) check provider_mode fail "tor_mode is not direct: $row" ;;
	esac
	case $row in
	*admin=1*) check provider_admin fail "the session has Administration on: $row" ;;
	*) check provider_admin ok "Administration off" ;;
	esac
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
# showing the firewall live.
welcome_checks() {
	if timeout 300 bash "$WELCOME_ADB" -s "$ANTUMBRA_SERIAL" check-policies --keep-adb >"$LOGS/$SCEN-welcome-policies.txt" 2>&1; then
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

tracker_test() {
	local lines=$SDIR/tracker-test.jsonl tmp=$SDIR/.dns-answer.json name out rcode
	: >"$lines"
	event tracker_test
	if dns_port; then
		for name in $TRACKERS; do
			"${CITOOL[@]}" dns-query --port "$DNS_PORT" --name "$name" >"$tmp" 2>/dev/null || true
			printf '{"method":"filter","name":"%s","result":%s}\n' "$name" "$(cat "$tmp" 2>/dev/null || echo null)" >>"$lines"
			rcode=$("${CITOOL[@]}" json-get "$tmp" rcode)
			if [ "$("${CITOOL[@]}" json-get "$tmp" blocked)" = true ]; then
				check "tracker_blocked:$name" ok "the filter answered ${rcode:-?}"
			else
				check "tracker_blocked:$name" fail "the filter did not block it: $(cat "$tmp" 2>/dev/null)"
			fi
		done
		"${CITOOL[@]}" dns-query --port "$DNS_PORT" --name "$CONTROL" >"$tmp" 2>/dev/null || true
		printf '{"method":"filter","name":"%s","control":true,"result":%s}\n' "$CONTROL" "$(cat "$tmp" 2>/dev/null || echo null)" >>"$lines"
		if [ "$("${CITOOL[@]}" json-get "$tmp" rcode)" = NOERROR ] && [ -n "$("${CITOOL[@]}" json-get "$tmp" answers.0)" ]; then
			check "control_resolves:$CONTROL" ok "answered through Tor: $("${CITOOL[@]}" json-get "$tmp" answers)"
		else
			check "control_resolves:$CONTROL" warn "no answer through Tor: $(cat "$tmp" 2>/dev/null)"
		fi
		rm -f "$tmp"
	else
		check tracker_test fail "adb forward to the filter's TCP port 5335 failed"
	fi
	# The same names through Android's own resolver (netd), as root and as
	# the Welcome app's uid: the firewall must send these to the filter too.
	# ping's ICMP itself must be refused; if it left, the capture shows it.
	for name in $TRACKERS "$CONTROL"; do
		out=$(ASH_TIMEOUT=20 ash "ping -c 1 -W 3 $name" 2>&1 | head -n 3)
		json_obj method=system-resolver uid=0 name="$name" output="$out" >>"$lines"
		out=$(ASH_TIMEOUT=20 ash "run-as $PKG ping -c 1 -W 3 $name" 2>&1 | head -n 3)
		json_obj method=system-resolver uid=app name="$name" output="$out" >>"$lines"
	done
	"${PY[@]}" -c 'import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
json.dump({"tests": rows}, open(sys.argv[2], "w"), indent=1, sort_keys=True)' "$lines" "$SDIR/tracker-test.json" &&
		rm -f "$lines"
	sleep 3
	fetch_status "$SDIR/filter-status.json"
}

# probe WHO HOST PORT [udp]: one connection attempt carrying a token, as
# root ("root"), as Welcome's uid ("app", through run-as) or as tor's uid
# ("tor"). Prints nc's output; the capture and the listener judge.
probe() {
	local who=$1 host=$2 port=$3 u=${4:-} cmd
	cmd="echo ANTUMBRA-PROBE | /system/bin/toybox nc ${u:+-u }-w 3 $host $port"
	case $who in
	root) ASH_TIMEOUT=15 ash "$cmd" 2>&1 ;;
	app) ASH_TIMEOUT=15 ash "run-as $PKG sh -c '$cmd'" 2>&1 ;;
	tor) ASH_TIMEOUT=15 ash "$MODDIR/bin/antumbra-run -u 2950 -g 2950 -G 3003 -- /system/bin/sh -c '$cmd'" 2>&1 ;;
	esac
	return 0
}

# probes_live: with the full rule set. TCP to the emulator host's ports
# (on the phone, the router's web page, UPnP and the like) is passed into
# tor, which refuses private addresses, so no SYN to 10.0.2.2 may appear in
# the capture. Another app's loopback listener must never be reached, and
# nothing answers on tor's control port 9052.
probes_live() {
	local who target lid out hex
	event probes_live
	adb -s "$ANTUMBRA_SERIAL" shell "$MODDIR/bin/antumbra-run -u $OTHER_APP_UID -g $OTHER_APP_UID -G 3003 -- \
/system/bin/toybox timeout 30 /system/bin/toybox nc -l -s 127.0.0.1 -p $OTHER_APP_PORT" \
		>"$SDIR/.other-app-listener.out" 2>&1 </dev/null &
	lid=$!
	sleep 3
	hex=$(printf '%04X' "$OTHER_APP_PORT")
	if ash 'cat /proc/net/tcp' | awk -v p=":$hex" -v u="$OTHER_APP_UID" '$2 ~ p"$" && $4 == "0A" && $8 == u { f = 1 } END { exit !f }'; then
		check other_app_listener ok "uid $OTHER_APP_UID listens on 127.0.0.1:$OTHER_APP_PORT"
	else
		check other_app_listener warn "the stand-in app's listener did not start; the loopback probe proves nothing"
	fi
	{
		for who in root app; do
			for target in "10.0.2.2 80" "10.0.2.2 5000" "10.0.2.2 49152" "127.0.0.1 9052" "127.0.0.1 $OTHER_APP_PORT"; do
				# shellcheck disable=SC2086 # host and port
				out=$(probe "$who" $target | head -n 3 | tr '\n' ' ')
				printf '%s\t%s\t%s\n' "$who" "${target/ /:}" "$out"
			done
		done
	} >"$SDIR/probes-live.tsv"
	sleep 3
	ash "pkill -f 'nc -l -s 127.0.0.1 -p $OTHER_APP_PORT'" >/dev/null 2>&1
	kill "$lid" 2>/dev/null
	wait "$lid" 2>/dev/null
	if grep -q ANTUMBRA-PROBE "$SDIR/.other-app-listener.out" 2>/dev/null; then
		check other_app_port fail "a probe reached another app's loopback port 127.0.0.1:$OTHER_APP_PORT"
	else
		check other_app_port ok "no probe reached another app's loopback port"
	fi
	rm -f "$SDIR/.other-app-listener.out"
	event probes_live_end
}

# armed_phase: the firewall's armed rule set with the network up (see
# step 11 above).
armed_phase() {
	local relay rhost rport out i
	proc_net_snapshot
	relay=$("${PY[@]}" "$CI_DIR/leak_analyser.py" tor-conns "$SDIR/proc-net-tcp.txt" 2>/dev/null | grep -v '^\[' | head -n 1)
	rhost=${relay%:*} rport=${relay##*:}
	[ -n "$relay" ] || { rhost=198.51.100.1 rport=443; }
	SERVICE_PIDS=$(ash "pgrep -f '^sh $MODDIR/service.sh'" | tr '\n' ' ')
	SERVICE_PIDS=${SERVICE_PIDS% }
	if [ -z "$SERVICE_PIDS" ]; then
		check armed_phase fail "service.sh is not running"
		return 1
	fi
	# Pause the module's loop, which would otherwise load the rule set again
	# within 30 seconds.
	ash "kill -STOP $SERVICE_PIDS" >/dev/null
	event armed_flush "service.sh paused ($SERVICE_PIDS)"
	out=$(ash "ANTUMBRA_DIR=$RT/state/module/fw sh $MODDIR/bin/antumbra-fw flush; echo \"exit=\$?\"")
	printf '# antumbra-fw flush\n%s\n' "$out" >"$LOGS/$SCEN-armed-phase.txt"
	fw_status >>"$LOGS/$SCEN-armed-phase.txt"
	if ! fw_status | grep -qx 'state=armed'; then
		ash "kill -CONT $SERVICE_PIDS" >/dev/null
		SERVICE_PIDS=
		check armed_phase fail "antumbra-fw flush did not leave the firewall armed: $(tr '\n' ' ' <"$LOGS/$SCEN-armed-phase.txt" | cut -c1-300)"
		return 1
	fi
	# Nothing may claim the full rule set while only the arm set is loaded.
	ash "setprop antumbra.fw.armed ''" >/dev/null
	sleep 2
	event armed_probe_start "relay $rhost:$rport"
	sleep 2
	{
		echo "# as root"
		ASH_TIMEOUT=15 ash 'ping -c 2 -W 2 10.0.2.2' 2>&1
		ASH_TIMEOUT=15 ash 'ping -c 1 -W 2 1.1.1.1' 2>&1
		ASH_TIMEOUT=15 ash "ping -c 1 -W 2 $CONTROL" 2>&1
		probe root "$rhost" "$rport"
		probe root 10.0.2.2 80
		probe root 10.0.2.2 9 udp
		probe root 10.0.2.3 53 udp
		echo "# as an app (uid of $PKG)"
		ASH_TIMEOUT=15 ash "run-as $PKG ping -c 1 -W 2 10.0.2.2" 2>&1
		ASH_TIMEOUT=15 ash "run-as $PKG ping -c 1 -W 2 $CONTROL" 2>&1
		probe app "$rhost" "$rport"
		probe app 10.0.2.2 80
		echo "# as tor's uid"
		probe tor "$rhost" "$rport"
	} >>"$LOGS/$SCEN-armed-phase.txt" 2>&1
	sleep 4
	event armed_probe_end
	fw_status >>"$LOGS/$SCEN-armed-phase.txt"
	if fw_status | grep -qx 'state=armed'; then
		check armed_state_held ok "the firewall stayed armed during the probes"
	else
		check armed_state_held fail "the firewall left the armed state during the probes: $(fw_status | tr '\n' ' ')"
	fi
	# The loop resumes, finds the firewall armed and loads the rule set again.
	ash "kill -CONT $SERVICE_PIDS" >/dev/null
	SERVICE_PIDS=
	for i in $(seq 1 30); do
		fw_live_matches && break
		sleep 3
	done
	if fw_live_matches; then
		event armed_reapplied "$FW_DETAIL"
		check armed_phase ok "armed with the network up, then live again: $FW_DETAIL"
	else
		check armed_phase fail "the module did not load the full rule set again within 90 s: $FW_DETAIL"
	fi
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

finish() {
	local rc=$?
	trap - EXIT
	set +e
	if [ -n "$SERVICE_PIDS" ]; then
		ash "kill -CONT $SERVICE_PIDS" >/dev/null 2>&1
	fi
	stop_stream_recorder
	if [ "$rc" -ne 0 ] || [ "$FAILED" -ne 0 ]; then
		wake_screen
		screenshot final
	fi
	if [ "$(ash 'id -u' 2>/dev/null)" = 0 ]; then
		collect_evidence
	else
		check evidence fail "no root shell at the end: tor's connections, the consensus and the logs were not collected"
	fi
	collect_logcat
	guest_capture_stop
	capture_stop
	timeout 10 adb -s "$ANTUMBRA_SERIAL" forward --remove-all >/dev/null 2>&1
	if [ "$rc" -ne 0 ] || [ "$FAILED" -ne 0 ]; then rc=1; fi
	echo "$rc" >"$SDIR/result"
	say "done (exit $rc)"
	exit "$rc"
}
trap finish EXIT

if [ -n "$ZIP" ]; then
	[ -f "$ZIP" ] || abort inputs "no module zip at $ZIP"
else
	[ -d "${TREE:-/nonexistent}/bin/x86_64" ] || abort inputs "set ANTUMBRA_MODULE_ZIP, or ANTUMBRA_MODULE_TREE to the unpacked zip"
fi
[ -f "$APK" ] || abort inputs "no Welcome APK at $APK"

event boot_completed
wait_system_ready 300 || abort system_ready "the system did not answer within 5 minutes of boot"
timeout 60 adb -s "$ANTUMBRA_SERIAL" root >/dev/null 2>&1
sleep 3
wait_device 60
[ "$(ash 'id -u')" = 0 ] || abort adb_root "adb root did not give a root shell"
check adb_root ok
device_info
WLAN_MAC_BEFORE=$(ash 'cat /sys/class/net/wlan0/address' 2>/dev/null)
guest_capture_start fail
clock_marker

quiet_network
install_module
start_stream_recorder
network_on
install_welcome
welcome_start
wifi_join
welcome_checks
if wait_bootstrap; then
	screenshot status-2-bootstrapped
	tracker_test
	screenshot status-3-after-tracker-test
else
	screenshot status-2-no-bootstrap
fi
probes_live
armed_phase
# Let tor settle on the reloaded rule set before the evidence is taken.
sleep 20
