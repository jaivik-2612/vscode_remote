#!/system/bin/sh
# shellcheck disable=SC2016 # wait_until conditions are single-quoted on purpose: eval runs them again on each try
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Antumbra module: the part of tests/e2e-host.sh that runs inside the
# sandbox, as root, in its own mount, network and PID namespaces, chrooted
# into an overlay of the host with Android's toybox and mksh in /system/bin
# and stand-ins for getprop, setprop, resetprop, settings, cmd and content.
#
# Usage: e2e-inner.sh SHELL SCENARIO
#   SHELL     busybox: the module's scripts run in busybox ash with
#             ASH_STANDALONE=1 and resetprop on PATH, as under Magisk;
#             mksh: they run in Android's mksh without resetprop, as on the
#             CI emulator
#   SCENARIO  bridges, direct, offline, pt or badbridges (see e2e-host.sh)
# Prints one line per check; exits 1 if any check failed. The module's
# scripts run with umask 0, as from adb's shell on the CI emulator.
set -u
SHELLKIND=$1
SCEN=$2
T=/antumbra-test
MD=/data/adb/modules/antumbra
A=/data/adb/antumbra
PATH=/system/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
unset ASH_STANDALONE
if [ "$SHELLKIND" = busybox ]; then
	RUNSH="/magisk-bin/busybox sh"
else
	RUNSH=/system/bin/sh
fi
FW_DIR=$A/state/module/fw
SID1=0123456789abcdef0123456789abcdef
SID2=fedcba9876543210fedcba9876543210
FP=0123456789ABCDEF0123456789ABCDEF01234567

fails=0
pass() { printf '  PASS  %s\n' "$*"; }
fail() {
	printf '  FAIL  %s\n' "$*"
	fails=$((fails + 1))
}
check() { # DESCRIPTION COMMAND...
	_d=$1
	shift
	if "$@"; then pass "$_d"; else fail "$_d"; fi
}
# wait_until SECONDS COMMAND...: true once COMMAND succeeds.
wait_until() {
	_w=$1
	shift
	while [ "$_w" -gt 0 ]; do
		"$@" && return 0
		sleep 1
		_w=$((_w - 1))
	done
	"$@"
}
# Run a script the way Magisk (busybox, standalone) or the emulator (mksh)
# would, with umask 0 (the scripts must set their own).
run_module_script() {
	if [ "$SHELLKIND" = busybox ]; then
		(umask 000 && env ASH_STANDALONE=1 PATH="$PATH:/magisk-bin" /magisk-bin/busybox sh "$@")
	else
		(umask 000 && $RUNSH "$@")
	fi
}
start_service() {
	if [ "$SHELLKIND" = busybox ]; then
		(umask 000 && setsid env ASH_STANDALONE=1 PATH="$PATH:/magisk-bin" /magisk-bin/busybox sh "$MD/service.sh" \
			</dev/null >/dev/null 2>&1 &)
	else
		(umask 000 && setsid /system/bin/sh "$MD/service.sh" </dev/null >/dev/null 2>&1 &)
	fi
}
prop() { /system/bin/getprop "$1"; }
fw() { ANTUMBRA_DIR=$FW_DIR /system/bin/sh "$MD/bin/antumbra-fw" "$@"; }
as_app() { /usr/bin/setpriv --reuid 10100 --regid 10100 --clear-groups /usr/bin/python3 -I $T/probe.py "$@"; }
# squat_bg PROTO PORT SECONDS: another app (uid 10200) takes 127.0.0.1:PORT
# in the background ('probe.py squat', output in $T/squat.out); $! is its
# process ID.
squat_bg() {
	(exec /usr/bin/setpriv --reuid 10200 --regid 10200 --clear-groups \
		/usr/bin/python3 -I $T/probe.py squat "$@" >$T/squat.out 2>&1) &
}
fw_rc() { fw status >/dev/null 2>&1; echo $?; }
session_has() { grep -q -x -F "$1" "$A/state/module/session" 2>/dev/null; }
# listening UID PORTHEX: a TCP listener on 127.0.0.1:PORT belongs to UID.
listening() { grep -q "^ *[0-9]*: 0100007F:$2 00000000:0000 0A [^ ]* [^ ]* [^ ]* *$1 " /proc/net/tcp; }
last_setting() { grep "^put $1 " $T/settings.log | tail -n 1; }
tor_pid() { cat "$A/state/module/tor.pid" 2>/dev/null; }
dns_pid() { cat "$A/state/module/dnsfilter.pid" 2>/dev/null; }
proc_field() { sed -n "s/^$2:[[:space:]]*//p" "/proc/$1/status" 2>/dev/null | head -n 1 | sed 's/[[:space:]]*$//'; }
torctl() {
	"$MD/bin/antumbra-run" -u 2950 -g 2950 -- /system/bin/sh "$MD/lib/torctl.sh" \
		"$A/run/tor-control.authcookie" "$A/run/tor-control.sock"
}
# getconf KEY...: tor's answer to GETCONF, without the reply to AUTHENTICATE.
getconf() { printf 'GETCONF %s\r\n' "$*" | torctl | tr -d '\r' | sed '1{/^250 OK$/d;}'; }
status_json() { cat "$A/run/status.json" 2>/dev/null; }
status_has() { status_json | grep -q -F "$1"; }
prop_is_live() {
	_h=$(fw status 2>/dev/null | sed -n 's/^hash=//p' | cut -c1-16)
	[ -n "$_h" ] && [ "$(prop antumbra.fw.armed)" = "$_h" ]
}
is_mountpoint() { /system/bin/toybox mountpoint -q "$1"; }
owner_mode() { /system/bin/toybox stat -c '%u:%g %a' "$1" 2>/dev/null; }
sysctl_is() { [ "$(cat "/proc/sys/net/ipv6/conf/$1/$2")" = "$3" ]; }

echo "== scenario $SCEN, module scripts in $SHELLKIND"

# --- The sandbox network: loopback, and a dummy interface with a default
# route, so that sockets can address the Internet and the firewall decides.
ip link set lo up
ip link add d0 type veth peer name d1
ip addr add 10.99.0.2/24 dev d0
ip link set d1 up
ip link set d0 up
ip route add default via 10.99.0.1 dev d0
# Some test hosts boot with ipv6.disable=1; then the IPv6 checks are skipped.
HAVE_IPV6=0
[ -d /proc/sys/net/ipv6 ] && HAVE_IPV6=1
[ "$HAVE_IPV6" = 1 ] || echo "  SKIP  IPv6 checks: this kernel has IPv6 disabled"
ipv6_check() { [ "$HAVE_IPV6" = 1 ] || return 0; check "$@"; }

# --- 1. Installation (Android running) ---------------------------------------
touch $T/framework-up
/system/bin/setprop sys.boot_completed 1
(umask 000 && /system/bin/sh $T/stage/lib/emu-install.sh $T/stage >$T/install.log 2>&1)
check "install: customize.sh accepted this device" grep -q 'Installed in' $T/install.log
check "install: /data/adb/modules is 0755 (umask 0 in the installer's shell)" test "$(owner_mode /data/adb/modules)" = "0:0 755"
check "install: module files 0644, programs 0755" test "$(owner_mode $MD/lib/antumbra.sh)/$(owner_mode $MD/bin/tor)" = "0:0 644/0:0 755"
check "install: early arm script in post-fs-data.d, 0755" test "$(owner_mode /data/adb/post-fs-data.d/antumbra-arm.sh)" = "0:0 755"
check "install: tor kept for this CPU" test -x $MD/bin/tor
check "install: the other CPU's programs removed" test ! -e $MD/bin/x86_64 -a ! -e $MD/bin/arm64-v8a
check "install: settings recorded for uninstall" grep -q '^ntp_server=time.android.com$' $MD/settings.orig
check "install: customize.sh removed, as Magisk does" test ! -e $MD/customize.sh

# --- 2. Reboot: post-fs-data -----------------------------------------------------
rm -f $T/framework-up
/system/bin/setprop sys.boot_completed ''
# Magisk runs /data/adb/post-fs-data.d first.
run_module_script /data/adb/post-fs-data.d/antumbra-arm.sh
check "early arm: armed before the module's post-fs-data.sh" test "$(iptables -w -S OUTPUT | sed -n '/^-A/{p;q;}')" = "-A OUTPUT -j ANTUMBRA_ARM_OUT"
start=$(date +%s)
run_module_script $MD/post-fs-data.sh
took=$(($(date +%s) - start))
check "post-fs-data: finished in ${took}s (Magisk allows 40)" test "$took" -lt 10
check "post-fs-data: armed, filter OUTPUT" test "$(iptables -w -S OUTPUT | sed -n '/^-A/{p;q;}')" = "-A OUTPUT -j ANTUMBRA_ARM_OUT"
check "post-fs-data: armed, IPv6" test "$(ip6tables -w -S OUTPUT | sed -n '/^-A/{p;q;}')" = "-A OUTPUT -j ANTUMBRA_ARM_OUT"
check "post-fs-data: armed, mangle POSTROUTING" test "$(iptables -w -t mangle -S POSTROUTING | sed -n '/^-A/{p;q;}')" = "-A POSTROUTING -j ANTUMBRA_ARM_POST"
check "post-fs-data: the arm lock is in /dev, not on flash" test -d /dev/antumbra-fw
r=$(/usr/bin/python3 -I $T/probe.py udp 10.99.0.1 53)
check "post-fs-data: root cannot send to the network while armed ($r)" test "$r" = "error 1"
check "post-fs-data: runtime directory is a tmpfs" is_mountpoint $A
check "post-fs-data: run/ belongs to tor, 0751" test "$(owner_mode $A/run)" = "2950:2950 751"
check "post-fs-data: state/ is root's, 0711" test "$(owner_mode $A/state)" = "0:0 711"
check "post-fs-data: state/tor belongs to tor, 0700" test "$(owner_mode $A/state/tor)" = "2950:2950 700"
check "post-fs-data: state/module is root-only" test "$(owner_mode $A/state/module)" = "0:0 700"
check "post-fs-data: log/ is root's" test "$(owner_mode $A/log)" = "0:0 755"
check "post-fs-data: /data/adb is 0711" test "$(owner_mode /data/adb)" = "0:0 711"
check "post-fs-data: Wi-Fi store on a tmpfs" is_mountpoint /data/misc/apexdata/com.android.wifi
check "post-fs-data: Wi-Fi store keeps owner and mode" test "$(owner_mode /data/misc/apexdata/com.android.wifi)" = "0:1000 771"
check "post-fs-data: no saved network in the RAM store" test ! -e /data/misc/apexdata/com.android.wifi/WifiConfigStore.xml
check "post-fs-data: IpMemoryStore on a tmpfs" is_mountpoint /data/user_de/0/com.android.networkstack/databases
check "post-fs-data: IpMemoryStore keeps NetworkStack's owner" test "$(owner_mode /data/user_de/0/com.android.networkstack/databases)" = "1073:1073 771"
check "post-fs-data: no lease memory" test ! -e /data/user_de/0/com.android.networkstack/databases/IpMemoryStoreV2.db
ipv6_check "post-fs-data: IPv6 off (all)" sysctl_is all disable_ipv6 1
ipv6_check "post-fs-data: IPv6 off (default)" sysctl_is default disable_ipv6 1
ipv6_check "post-fs-data: IPv6 off (d0)" sysctl_is d0 disable_ipv6 1
ipv6_check "post-fs-data: IPv6 kept on loopback" sysctl_is lo disable_ipv6 0
ipv6_check "post-fs-data: router advertisements off" sysctl_is d0 accept_ra 0
check "post-fs-data: no firewall property yet" test -z "$(prop antumbra.fw.armed)"
check "post-fs-data: no problem recorded" test ! -s $A/state/module/problem -o "$(cat $A/state/module/problem)" = ""

# --- 3. service.sh, before the framework is up ----------------------------------------
start_service
check "service: firewall property published" wait_until 60 eval 'test -n "$(prop antumbra.fw.armed)"'
check "service: the property is the live rule set's hash" prop_is_live
check "service: firewall status is live" fw status >/dev/null
if [ "$SHELLKIND" = busybox ]; then
	check "service: published with resetprop -n" grep -q "^-n antumbra.fw.armed $(prop antumbra.fw.armed)$" $T/resetprop.log
fi
p=$(tor_pid)
check "service: tor runs as uid 2950" test "$(proc_field "$p" Uid)" = "2950	2950	2950	2950"
check "service: tor has no capabilities" test "$(proc_field "$p" CapEff)/$(proc_field "$p" CapPrm)/$(proc_field "$p" CapBnd)" = "0000000000000000/0000000000000000/0000000000000000"
check "service: tor has no_new_privs" test "$(proc_field "$p" NoNewPrivs)" = 1
check "service: tor is in the inet group" test "$(proc_field "$p" Groups)" = 3003
p=$(dns_pid)
check "service: the DNS filter runs as uid 2951" test "$(proc_field "$p" Uid)" = "2951	2951	2951	2951"
check "service: the DNS filter has no capabilities" test "$(proc_field "$p" CapEff)/$(proc_field "$p" CapBnd)" = "0000000000000000/0000000000000000"
check "service: status.json written" wait_until 10 status_has '"firewall":{"state":"live","hash":"'"$(prop antumbra.fw.armed)"'"}'
check "service: status.json belongs to tor's uid" test "$(owner_mode $A/run/status.json | cut -d' ' -f1)" = 2950:2950
check "service: status says tor runs, offline, not started" status_has '"network":"disabled"'
check "service: status says Welcome has not started" status_has '"welcome":{"started":false}}'
check "service: status holds no session ID and no tor mode" test -z "$(status_json | grep -E 'session_id|"mode"')"
check "umask: module.log, firewall.log, dnsfilter.log, tor.stderr are 0644" test \
	"$(owner_mode $A/log/module.log) $(owner_mode $A/log/firewall.log) $(owner_mode $A/log/dnsfilter.log) $(owner_mode $A/log/tor.stderr)" = \
	"0:0 644 0:0 644 0:0 644 0:0 644"
check "umask: /dev/antumbra-fw is 0755" test "$(owner_mode /dev/antumbra-fw)" = "0:0 755"
check "umask: the firewall's own directory is root's alone" test "$(owner_mode $FW_DIR)" = "0:0 700"
s=$(as_app status 2>&1)
check "service: an app reads the filter's status page with the module part" test -n "$(printf '%s' "$s" | grep -F '"module"' | grep -F '"state":"live"')"
blocked=$(sed -n '/^[a-z0-9]/{p;q;}' $MD/lists/dnsfilter.list)
r=$(as_app dns "$blocked")
check "service: an app's DNS for a tracker ($blocked) is NXDOMAIN ($r)" test "$r" = NXDOMAIN
r=$(as_app dns example.org)
check "service: an app's DNS fails closed while tor is offline ($r)" test "$r" = SERVFAIL
r=$(as_app udp 10.99.0.1 4500)
check "service: an app cannot send other UDP ($r)" test "$r" = "error 1"
check "service: no Settings before the framework is up" test ! -s $T/settings.log
if [ "$HAVE_IPV6" = 1 ]; then
	echo 0 >/proc/sys/net/ipv6/conf/d0/disable_ipv6
	check "service: IPv6 switched off again on d0 after NetworkStack-style re-enable" wait_until 12 sysctl_is d0 disable_ipv6 1
fi
r=$(getconf DisableNetwork)
check "service: tor keeps DisableNetwork=1 before Start ($r)" test "$r" = "250 DisableNetwork=1
250 closing connection"

# --- 4. The framework comes up ---------------------------------------------------------------
touch $T/framework-up
/system/bin/setprop sys.boot_completed 1
check "settings: fail-safe values set" wait_until 20 grep -q '^put captive_portal_mode 0$' $T/settings.log
for kv in 'captive_portal_detection_enabled 0' 'ntp_server 127.0.0.1' 'assisted_gps_enabled 0' \
	'wifi_scan_always_enabled 0' 'ble_scan_always_enabled 0' 'private_dns_mode off' \
	'network_recommendations_enabled 0' 'tether_offload_disabled 1' \
	'non_persistent_mac_randomization_force_enabled 1'; do
	check "settings: $kv" grep -q "^put $kv\$" $T/settings.log
done
if [ -n "$(prop ro.lineage.version)" ]; then
	check "settings: restricted_networking_mode 1 on LineageOS" grep -q '^put restricted_networking_mode 1$' $T/settings.log
else
	check "settings: restricted_networking_mode left alone on plain Android" test -z "$(grep restricted_networking_mode $T/settings.log)"
fi
check "settings: Wi-Fi scanning for location off now" grep -q '^wifi set-scan-always-available disabled$' $T/cmd.log

# --- 5. The Welcome screen's Start -------------------------------------------------------------
welcome() { # MODE MAC SESSION_ID [BRIDGE LINE...]
	_m=$1 _mac=$2 _sid=$3
	shift 3
	printf '%s\n' "$@" >$T/welcome.bridges.new
	printf 'started=1\ntor_mode=%s\nmac=%s\nadmin=0\nunsafe_browser=0\npersistent=0\nsession_id=%s\n' \
		"$_m" "$_mac" "$_sid" >$T/welcome.new
	mv -f $T/welcome.bridges.new $T/welcome.bridges
	mv -f $T/welcome.new $T/welcome
}
case $SCEN in
bridges)
	welcome bridges keep $SID1 "1.2.3.4:443 $FP" "5.6.7.8:9001"
	check "start: tor's network on" wait_until 30 status_has '"network":"enabled"'
	check "start: status shows that the session started" status_has '"welcome":{"started":true}}'
	check "start: the session is recorded in root's state" session_has "session_id=$SID1"
	check "start: the session record is 0600" test "$(owner_mode $A/state/module/session)" = "0:0 600"
	check "start: tor holds 127.0.0.1:9040" listening 2950 2350
	r=$(getconf UseBridges Bridge DisableNetwork)
	check "start: tor has both bridges and the network on" test "$r" = "250-UseBridges=1
250-Bridge=1.2.3.4:443 $FP
250-Bridge=5.6.7.8:9001
250 DisableNetwork=0
250 closing connection"
	check "start: MAC 'keep' sets non-persistent randomization off" grep -q '^put non_persistent_mac_randomization_force_enabled 0$' $T/settings.log
	check "start: no bridge line in the module log" test -z "$(grep -F '1.2.3.4' $A/log/module.log)"

	# Welcome's process restarts with a new, unstarted session: ignored.
	printf 'started=0\ntor_mode=offline\nmac=new\nsession_id=%s\n' $SID2 >$T/welcome
	sleep 6
	check "restart of Welcome: the first session is kept" session_has "session_id=$SID1"
	check "restart of Welcome: still one session" test "$(grep -c 'session started' $A/log/module.log)" = 1

	old=$(tor_pid)
	kill -9 "$old"
	check "tor killed: restarted" wait_until 30 eval 'test -n "$(tor_pid)" -a "$(tor_pid)" != "$old"'
	check "tor killed: the session's bridges and network are applied again" wait_until 40 eval \
		'test "$(getconf UseBridges DisableNetwork)" = "250-UseBridges=1
250 DisableNetwork=0
250 closing connection"'

	old=$(dns_pid)
	kill -9 "$old"
	check "filter killed: restarted" wait_until 30 eval 'test -n "$(dns_pid)" -a "$(dns_pid)" != "$old"'
	r=$(as_app dns "$blocked")
	check "filter killed: blocking again ($r)" test "$r" = NXDOMAIN

	iptables -w -D OUTPUT 1
	check "firewall tampered: status is no longer live" test "$(fw status >/dev/null 2>&1; echo $?)" != 0
	check "firewall tampered: reloaded within 70 s" wait_until 70 fw status
	check "firewall tampered: the property is the live hash again" wait_until 10 prop_is_live
	check "firewall tampered: logged" grep -q 'no longer live' $A/log/module.log

	# Android shuts down: the fail-safe Settings go back, MAC randomization
	# on again after the "keep" session.
	/system/bin/setprop sys.shutdown.requested 0userrequested
	check "shutdown: MAC randomization put back to 1" wait_until 10 eval \
		'test "$(last_setting non_persistent_mac_randomization_force_enabled)" = "put non_persistent_mac_randomization_force_enabled 1"'
	check "shutdown: logged" grep -q 'shutdown: fail-safe Settings put back' $A/log/module.log
	;;
direct)
	# On the phone (not the emulator): mobile data off for every SIM
	# Android knows (1 and 3 from the telephony provider, 2 from an older
	# setting), now and stored.
	check "phone: mobile_data 0" grep -q '^put mobile_data 0$' $T/settings.log
	for k in 1 2 3; do
		check "phone: mobile_data$k 0" grep -q "^put mobile_data$k 0\$" $T/settings.log
	done
	check "phone: mobile data switched off now" grep -q '^phone data disable$' $T/cmd.log

	# An app takes tor's TransPort port while tor's network is off (before
	# Start): the module goes back to armed, so nothing is redirected to it.
	squat_bg tcp 9040 60
	sq=$!
	check "squat: an app bound 127.0.0.1:9040" wait_until 5 grep -q '^bound$' $T/squat.out
	check "squat: the firewall goes back to armed" wait_until 15 eval 'test "$(fw_rc)" = 1'
	check "squat: the property is removed" test -z "$(prop antumbra.fw.armed)"
	check "squat: status names the port and the uid" wait_until 10 status_has '9040/tcp held by uid 10200'
	check "squat: status says the firewall failed" status_has '"firewall":{"state":"failed"'
	r=$(as_app tcp 93.184.216.34 80)
	check "squat: an app's TCP is not passed on ($r)" test "$r" != connected
	check "squat: the squatter accepted no connection" test -z "$(grep accepted $T/squat.out)"
	welcome direct new $SID1
	check "squat: Start is read" wait_until 30 status_has '"started":true'
	sleep 4
	check "squat: tor's network stays off while the port is taken" test "$(getconf DisableNetwork)" = "250 DisableNetwork=1
250 closing connection"
	kill "$sq"
	wait "$sq" 2>/dev/null
	check "squat: the firewall is live again once the port is free" wait_until 15 prop_is_live
	check "squat: logged" grep -q 'ports: free again' $A/log/module.log

	check "start: tor's network on" wait_until 30 status_has '"network":"enabled"'
	check "start: tor holds 127.0.0.1:9040" listening 2950 2350
	r=$(getconf UseBridges DisableNetwork)
	check "start: no bridges, network on" test "$r" = "250-UseBridges=0
250 DisableNetwork=0
250 closing connection"
	check "start: MAC 'new' keeps non-persistent randomization on" test -z "$(grep 'non_persistent_mac_randomization_force_enabled 0' $T/settings.log)"
	;;
offline)
	welcome offline new $SID1
	check "start: the session is read" wait_until 30 status_has '"started":true'
	sleep 4
	check "start: offline keeps tor's network off" test "$(getconf DisableNetwork)" = "250 DisableNetwork=1
250 closing connection"
	check "start: status shows the network off" status_has '"network":"disabled"'
	check "start: offline recorded" session_has tor_mode=offline
	check "emulator: mobile data left alone" test -z "$(grep mobile_data $T/settings.log)"

	# An app takes the filter's port while the filter restarts. service.sh
	# is paused meanwhile, so that the app gets there first.
	svc=$(cat $A/state/module/service.lock/pid)
	kill -STOP "$svc"
	old=$(dns_pid)
	kill -9 "$old"
	sleep 1
	squat_bg udp 5335 60
	sq=$!
	wait_until 5 grep -q '^bound$' $T/squat.out
	kill -CONT "$svc"
	check "filter's port taken: an app bound 127.0.0.1:5335" grep -q '^bound$' $T/squat.out
	check "filter's port taken: the firewall goes back to armed" wait_until 15 eval 'test "$(fw_rc)" = 1'
	check "filter's port taken: status names the port and the uid" wait_until 10 status_has '5335/udp held by uid 10200'
	r=$(as_app dns example.org)
	check "filter's port taken: an app's query is not passed on ($r)" test "$r" != NOERROR
	check "filter's port taken: the squatter received no query" test -z "$(grep received $T/squat.out)"
	kill "$sq"
	wait "$sq" 2>/dev/null
	check "filter's port free: the filter runs again" wait_until 70 eval 'test "$(proc_field "$(dns_pid)" Uid)" = "2951	2951	2951	2951"'
	check "filter's port free: the firewall is live again" wait_until 40 prop_is_live
	r=$(as_app dns "$blocked")
	check "filter's port free: blocking again ($r)" test "$r" = NXDOMAIN

	# Removal: during a boot (post-fs-data) the restore waits for boot.
	/system/bin/setprop sys.boot_completed ''
	run_module_script $MD/uninstall.sh
	check "uninstall in boot: restore script left in service.d" test -x /data/adb/service.d/antumbra-restore.sh
	/system/bin/setprop sys.boot_completed 1
	: >$T/settings.log
	/magisk-bin/busybox sh /data/adb/service.d/antumbra-restore.sh
	check "uninstall: ntp_server put back" grep -q '^put ntp_server time.android.com$' $T/settings.log
	check "uninstall: unset keys deleted" grep -q '^delete captive_portal_mode$' $T/settings.log
	check "uninstall: private_dns_mode put back" grep -q '^put private_dns_mode opportunistic$' $T/settings.log
	check "uninstall: the restore script removed itself" test ! -e /data/adb/service.d/antumbra-restore.sh
	check "uninstall: the early arm script removed" test ! -e /data/adb/post-fs-data.d/antumbra-arm.sh
	;;
pt)
	welcome bridges new $SID1 "obfs4 1.2.3.4:443 $FP cert=AAAA iat-mode=0"
	check "start: the session is read" wait_until 30 status_has '"started":true'
	check "start: status says pluggable transports are missing" wait_until 10 status_has 'pluggable transports'
	check "start: tor's network stays off" test "$(getconf DisableNetwork)" = "250 DisableNetwork=1
250 closing connection"

	# iptables stops working: neither the full rule set nor the arm set can
	# be loaded or checked. The module reports the firewall open and
	# switches airplane mode on and Wi-Fi off.
	for t in iptables ip6tables iptables-restore ip6tables-restore iptables-save ip6tables-save; do
		mv /system/bin/$t /system/bin/$t.real
		printf '#!/system/bin/sh\nexit 1\n' >/system/bin/$t
		chmod 0755 /system/bin/$t
	done
	check "firewall broken: status says open" wait_until 45 status_has '"firewall":{"state":"open"'
	check "firewall broken: the property is removed" test -z "$(prop antumbra.fw.armed)"
	check "firewall broken: airplane mode on" wait_until 10 grep -q '^connectivity airplane-mode enable$' $T/cmd.log
	check "firewall broken: Wi-Fi off" grep -q '^wifi set-wifi-enabled disabled$' $T/cmd.log
	check "firewall broken: status says why" status_has 'airplane mode on'
	for t in iptables ip6tables iptables-restore ip6tables-restore iptables-save ip6tables-save; do
		mv -f /system/bin/$t.real /system/bin/$t
	done
	check "firewall repaired: live again" wait_until 45 prop_is_live
	;;
badbridges)
	# Another app answers for Welcome's provider while Welcome is not the
	# device owner: its Start is not trusted.
	printf 'User  0: admin=com.example.other/.Admin,DeviceOwner\n' >$T/owners
	welcome bridges new $SID1 '1.2.3.4:443 "x' "5.6.7.8:9001"
	sleep 6
	check "not the device owner: Start ignored" status_has '"welcome":{"started":false}}'
	check "not the device owner: status says why" status_has 'is not the device owner'
	printf 'User  0: admin=org.antumbra.welcome/.AdminReceiver,DeviceOwner,Affiliated\n' >$T/owners
	check "start: the session is read" wait_until 30 status_has '"started":true'
	check "start: status says the bridges were refused" wait_until 10 status_has 'bridges refused'
	check "start: tor's network stays off" test "$(getconf DisableNetwork)" = "250 DisableNetwork=1
250 closing connection"
	;;
esac

check "module log has no shell errors" test -z "$(grep -i -E 'not found|syntax error|bad substitution|unexpected' $A/log/module.log)"
echo "-- module.log --"
sed 's/^/   /' $A/log/module.log
for f in firewall.log tor.stderr dnsfilter.log; do
	echo "-- $f (last 15 lines) --"
	tail -n 15 "$A/log/$f" 2>/dev/null | sed 's/^/   /'
done
echo "-- status.json --"
sed 's/^/   /' $A/run/status.json
echo "== $fails failed"
[ "$fails" -eq 0 ]
