#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Antumbra CI: the ANTUMBRA scenario. A fresh Android 16 emulator, the
# Antumbra module installed and started the way build-module.sh --emulator
# does it, the Welcome app as device owner and home screen, "Start
# Antumbra", tor, and a tracker lookup.
#
# Runs inside reactivecircus/android-emulator-runner, which has started the
# emulator with '-tcpdump <file>' and waited for sys.boot_completed. Steps:
#   1. adb root; device facts; a clock marker for the leak analyser.
#   2. Airplane mode on and wait until Android has no network. Plain
#      Android's own traffic stops here, so nothing is sent close to the
#      moment the firewall is armed.
#   3. Event "install_start", then build-module.sh --emulator: it installs
#      the module, stops the framework, runs post-fs-data.sh ('antumbra-fw
#      arm' first), starts the framework and service.sh, and waits until
#      antumbra.fw.armed is set (the full rule set is live). The leak
#      analyser counts every packet from install_start on (the arm cutoff
#      is earlier than the real 'arm', never later).
#   4. Airplane mode off: networks come up behind the firewall, as they do
#      on the phone after post-fs-data.
#   5. The Welcome APK; 'dpm set-device-owner'; Welcome as the home app.
#      Screenshots of the Welcome screen.
#   6. The choices, tapped where uiautomator finds them: Tor directly, new
#      Wi-Fi address on, Administration ON (without it Welcome turns USB
#      debugging off and this script loses adb), Unsafe Browser off. Then
#      "Start Antumbra". The provider row must say started=1.
#   7. Wait for tor to bootstrap (the DNS filter's /status, else tor.log).
#      Screenshot of the status screen.
#   8. Tracker test: names on the block list asked of the filter directly
#      (DNS over TCP to 127.0.0.1:5353 through adb forward) and through
#      Android's resolver, plus a control name that must resolve.
#   9. Evidence for the leak analyser: tor's established connections, the
#      consensus tor downloaded, the session's bridges. Checks of the
#      firewall state, the capabilities of tor and the filter, their
#      listening sockets (no SOCKS or control port), the control socket's
#      mode and owner, Wi-Fi's store and the DHCP memory on a tmpfs, and the
#      IPv6 addresses; logs. Then the capture is stopped.
#
# Environment:
#   ANTUMBRA_CI_OUT        report directory (required)
#   ANTUMBRA_MODULE_TREE   the unpacked module zip: bin/<abi>/{tor,
#                          antumbra-dnsfilter,antumbra-run}, lists/ (required)
#   ANTUMBRA_WELCOME_APK   app-debug.apk (required)
#   ANTUMBRA_SERIAL, ANTUMBRA_CAPTURE
#   ANTUMBRA_CI_BOOTSTRAP_TIMEOUT  seconds to wait for tor (default 600)
#   ANTUMBRA_CI_TRACKERS   names that must be blocked
#                          (default "doubleclick.net stats.lineageos.org")
#   ANTUMBRA_CI_CONTROL    a name that must resolve through Tor
#                          (default check.torproject.org)
#   ANTUMBRA_CI_BUILD_MODULE  the module installer (default
#                          ../module/build-module.sh; another one only for a
#                          dry run of this script against a fake adb)
set -uo pipefail

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
scenario_init antumbra

TREE=${ANTUMBRA_MODULE_TREE:?set ANTUMBRA_MODULE_TREE to the unpacked module zip}
APK=${ANTUMBRA_WELCOME_APK:?set ANTUMBRA_WELCOME_APK to the Welcome APK}
BOOTSTRAP_TIMEOUT=${ANTUMBRA_CI_BOOTSTRAP_TIMEOUT:-600}
TRACKERS=${ANTUMBRA_CI_TRACKERS:-doubleclick.net stats.lineageos.org}
CONTROL=${ANTUMBRA_CI_CONTROL:-check.torproject.org}
BUILD_MODULE=${ANTUMBRA_CI_BUILD_MODULE:-$ANDROID_DIR/module/build-module.sh}
PKG=org.antumbra.welcome
URI=content://org.antumbra.welcome.state/session
MODDIR=/data/adb/modules/antumbra
RT=/data/adb/antumbra
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
	[ -n "$DNS_PORT" ] || DNS_PORT=$(timeout 20 adb -s "$ANTUMBRA_SERIAL" forward tcp:0 tcp:5353 2>/dev/null | tr -d '\r\n')
	[ -n "$DNS_PORT" ]
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
	local armed
	event install_start
	if ! sh "$BUILD_MODULE" --emulator --serial "$ANTUMBRA_SERIAL" \
		--tor "$TREE/bin" --dnsfilter "$TREE/bin" --helper "$TREE/bin" \
		--blocklist "$TREE/lists/dnsfilter.list" >"$LOGS/$SCEN-build-module.log" 2>&1; then
		tail -n 30 "$LOGS/$SCEN-build-module.log" >&2
		abort module_install "build-module.sh --emulator failed (logs/$SCEN-build-module.log)"
	fi
	armed=$(ash 'getprop antumbra.fw.armed')
	event module_live "antumbra.fw.armed=$armed"
	if [ -n "$armed" ]; then
		check module_install ok "antumbra.fw.armed=$armed"
	else
		abort module_install "antumbra.fw.armed is not set after build-module.sh"
	fi
	wait_system_ready 300 || abort system_ready_after_module "the framework did not come back within 5 minutes"
}

network_on() {
	ash 'cmd connectivity airplane-mode disable' >/dev/null ||
		ash 'settings put global airplane_mode_on 0; am broadcast -a android.intent.action.AIRPLANE_MODE --ez state false' >/dev/null
	event network_on
	if wait_network up 120; then
		check network_up ok "default network: $(default_network)"
	else
		check network_up warn "no default network 2 minutes after airplane mode was switched off"
	fi
}

install_welcome() {
	local out
	out=$(timeout 180 adb -s "$ANTUMBRA_SERIAL" install -r -t "$APK" 2>&1)
	printf '%s\n' "$out" >"$LOGS/$SCEN-welcome-install.txt"
	printf '%s' "$out" | grep -q Success || abort welcome_install "adb install: $(printf '%s' "$out" | tail -n 1)"
	out=$(ash "dpm set-device-owner $PKG/.AdminReceiver")
	printf '%s\n' "$out" >>"$LOGS/$SCEN-welcome-install.txt"
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
	ui_set_switch switch_unsafe_browser false 'Unsafe Browser' || check welcome_unsafe warn "could not find the Unsafe Browser switch"
	ui_set_switch switch_admin true 'Administration' || abort welcome_admin "could not switch Administration on (needed to keep adb)"
	screenshot welcome-2-choices
	ui_tap start_button 'Start Antumbra' || abort welcome_start "Start Antumbra not found"
	event welcome_start
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
		check tracker_test fail "adb forward to the filter's TCP port 5353 failed"
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

# --- Evidence and checks, also after a failure ----------------------------

collect_evidence() {
	local out caps st
	proc_net_snapshot
	"${PY[@]}" "$CI_DIR/leak_analyser.py" tor-conns "$SDIR/proc-net-tcp.txt" >"$SDIR/tor-connections.txt" 2>/dev/null
	say "tor's connections: $(tr '\n' ' ' <"$SDIR/tor-connections.txt")"
	for f in cached-microdesc-consensus cached-consensus; do
		if ash "test -s $RT/state/tor/$f" >/dev/null 2>&1; then
			timeout 60 adb -s "$ANTUMBRA_SERIAL" exec-out cat "$RT/state/tor/$f" >"$SDIR/consensus" 2>/dev/null
			say "consensus: $f ($(wc -c <"$SDIR/consensus") bytes)"
			break
		fi
	done
	ash "content query --uri $URI --projection bridges" 2>/dev/null |
		sed -e '1s/^Row: [0-9]* bridges=//' -e '/^No result found/d' -e 's/^bridges=NULL$//' >"$SDIR/bridges.txt"

	# The firewall.
	{
		echo "# getprop antumbra.fw.armed"
		ash 'getprop antumbra.fw.armed'
		echo "# antumbra-fw status"
		ash "ANTUMBRA_DIR=$RT/state/module/fw sh $MODDIR/bin/antumbra-fw status"
		echo "# exit $?"
		echo "# iptables-save"
		ash 'iptables-save'
		echo "# ip6tables-save"
		ash 'ip6tables-save'
	} >"$LOGS/$SCEN-firewall-state.txt" 2>&1
	st=$(sed -n 's/^state=//p' "$LOGS/$SCEN-firewall-state.txt" | head -n 1)
	case $st in
	live) check firewall_live ok "antumbra-fw status: state=live" ;;
	armed | partial) check firewall_live warn "antumbra-fw status: state=$st" ;;
	*) check firewall_live fail "antumbra-fw status: state=${st:-unknown}" ;;
	esac

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
	# on 127.0.0.1:5353 (UDP and TCP) and TCP 127.0.0.1:5380; no SOCKSPort
	# or ControlPort on any port, for any uid.
	{
		"${PY[@]}" "$CI_DIR/leak_analyser.py" listeners --proto tcp "$SDIR/proc-net-tcp.txt"
		"${PY[@]}" "$CI_DIR/leak_analyser.py" listeners --proto udp "$SDIR/proc-net-udp.txt"
	} >"$SDIR/listeners.txt" 2>/dev/null
	out=$(awk '
		$1 == "tcp" && ($4 == 9050 || $4 == 9051 || $4 == 9052 || $4 == 9150 || $4 == 9151) { print; next }
		$2 != 2950 && $2 != 2951 { next }
		$3 != "127.0.0.1" { print; next }
		$1 == "tcp" && $2 == 2950 && $4 != 9040 { print; next }
		$1 == "udp" && $2 == 2950 && $4 != 9053 { print; next }
		$1 == "tcp" && $2 == 2951 && $4 != 5353 && $4 != 5380 { print }
	' "$SDIR/listeners.txt")
	if [ -n "$out" ]; then
		check listeners fail "sockets outside the contract: $(printf '%s' "$out" | tr '\n' ';')"
	else
		check listeners ok "tor and the filter listen on their loopback ports only; no SOCKS or control port"
	fi
	for want in "tcp 2950 127.0.0.1 9040" "udp 2950 127.0.0.1 9053" "tcp 2951 127.0.0.1 5353" \
		"udp 2951 127.0.0.1 5353" "tcp 2951 127.0.0.1 5380"; do
		grep -qx "$want" "$SDIR/listeners.txt" || check "listener:${want// /:}" warn "not listening"
	done
	st=$(ash "stat -c '%a %u %g' $RT/run/tor-control.sock" 2>&1)
	if [ "$st" = "660 2950 2950" ]; then
		check control_socket ok "tor-control.sock 0660 2950:2950"
	else
		check control_socket fail "tor-control.sock: $st (want 660 2950 2950)"
	fi

	# Saved Wi-Fi networks and the DHCP lease memory live in RAM only.
	out=$(ash "grep ' /data/misc/apexdata/com.android.wifi ' /proc/mounts")
	if [ "$(printf '%s\n' "$out" | awk '{ t = $3 } END { print t }')" = tmpfs ]; then
		check wifi_store_in_ram ok "$out"
	else
		check wifi_store_in_ram fail "Wi-Fi's store is not on a tmpfs: ${out:-not a mount point}"
	fi
	out=$(ash "grep -E 'networkstack[^ ]*/databases ' /proc/mounts")
	if [ "$(printf '%s\n' "$out" | awk '{ t = $3 } END { print t }')" = tmpfs ]; then
		check dhcp_memory_in_ram ok "$out"
	else
		check dhcp_memory_in_ram warn "NetworkStack's databases are not on a tmpfs: ${out:-not a mount point}"
	fi

	# IPv6: no address that names the network (global, site-local, ULA).
	ash 'ip -6 addr' >"$LOGS/$SCEN-ipv6.txt" 2>&1
	# shellcheck disable=SC2016 # expanded on the device
	ash 'for f in /proc/sys/net/ipv6/conf/*/disable_ipv6; do echo "$f $(cat "$f")"; done' >>"$LOGS/$SCEN-ipv6.txt" 2>&1
	out=$(grep -E '^\s*inet6 ' "$LOGS/$SCEN-ipv6.txt" | grep -v -E 'inet6 (::1/|fe80:)' || true)
	if [ -n "$out" ]; then
		check ipv6_addresses fail "IPv6 addresses beyond loopback and link-local: $(printf '%s' "$out" | tr '\n' ';')"
	elif grep -qE '^\s*inet6 fe80:' "$LOGS/$SCEN-ipv6.txt"; then
		check ipv6_addresses warn "link-local IPv6 addresses remain on some interfaces"
	else
		check ipv6_addresses ok "no IPv6 address except loopback"
	fi

	# The module's own logs.
	for f in tor.log module.log firewall.log dnsfilter.log; do
		timeout 30 adb -s "$ANTUMBRA_SERIAL" exec-out cat "$RT/log/$f" 2>/dev/null | tail -c 1000000 >"$LOGS/$SCEN-$f"
		[ -s "$LOGS/$SCEN-$f" ] || rm -f "$LOGS/$SCEN-$f"
	done
	ash "cat $RT/run/status.json" >"$LOGS/$SCEN-module-status.json" 2>&1
	ash 'dumpsys connectivity' 2>/dev/null | head -n 400 >"$LOGS/$SCEN-connectivity.txt"
	ash 'dumpsys user' 2>/dev/null | head -n 200 >"$LOGS/$SCEN-users.txt"
	fetch_status "$SDIR/filter-status.json"
}

finish() {
	local rc=$?
	trap - EXIT
	set +e
	if [ "$rc" -ne 0 ] || [ "$FAILED" -ne 0 ]; then
		wake_screen
		screenshot final
	fi
	if [ "$(ash 'id -u' 2>/dev/null)" = 0 ]; then
		collect_evidence
	else
		check evidence warn "no root shell at the end: tor's connections, the consensus and the logs were not collected"
	fi
	collect_logcat
	capture_stop
	timeout 10 adb -s "$ANTUMBRA_SERIAL" forward --remove-all >/dev/null 2>&1
	if [ "$rc" -ne 0 ] || [ "$FAILED" -ne 0 ]; then rc=1; fi
	echo "$rc" >"$SDIR/result"
	say "done (exit $rc)"
	exit "$rc"
}
trap finish EXIT

[ -d "$TREE/bin/x86_64" ] || abort inputs "$TREE/bin/x86_64 is missing (unpack the module zip there)"
[ -f "$APK" ] || abort inputs "no Welcome APK at $APK"

event boot_completed
wait_system_ready 300 || abort system_ready "the system did not answer within 5 minutes of boot"
timeout 60 adb -s "$ANTUMBRA_SERIAL" root >/dev/null 2>&1
sleep 3
wait_device 60
[ "$(ash 'id -u')" = 0 ] || abort adb_root "adb root did not give a root shell"
check adb_root ok
device_info
clock_marker

quiet_network
install_module
network_on
install_welcome
welcome_start
if wait_bootstrap; then
	screenshot status-2-bootstrapped
	tracker_test
	screenshot status-3-after-tracker-test
else
	screenshot status-2-no-bootstrap
fi
