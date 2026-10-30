#!/system/bin/sh
# shellcheck disable=SC2016 # wait_until conditions are single-quoted on purpose: eval runs them again on each try
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Antumbra module: the part of tests/e2e-host.sh that runs inside the
# sandbox, as root, in its own mount, network and PID namespaces, chrooted
# into an overlay of the host with Android's toybox and mksh in /system/bin
# and stand-ins for getprop, setprop, resetprop, settings, cmd, content and
# dumpsys.
#
# Usage: e2e-inner.sh SHELL SCENARIO
#   SHELL     busybox: the module's scripts run in busybox ash with
#             ASH_STANDALONE=1 and resetprop on PATH, as under Magisk;
#             mksh: they run in Android's mksh without resetprop, as on the
#             CI emulator
#   SCENARIO  bridges, direct, offline, pt, badbridges, cell, phone or data
#             (see e2e-host.sh)
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

# --- The cell radio's stand-ins ------------------------------------------------
IDLE='0 0 0 0 0 0'
# telecom_set HISTORY [STATE...]: what 'dumpsys telecom' shows: one live
# call per STATE (STATE:voip for a VoIP call), the newest calls (the last
# of them TC@HISTORY), and Analytics entries for calls 1 to HISTORY
# (Telecom numbers its calls TC@1, TC@2, ... within a boot), as Android 16
# prints them: ordinary calls ("isEmergency: false"), but those in
# EM_CALLS, which are emergency calls; the listed calls not ended yet
# ("endTime: 0"), the others ended.
EM_CALLS=
telecom_set() {
	_tl_h=$1
	shift
	_tl_first=$((_tl_h - $# + 1))
	[ "$_tl_first" -ge 1 ] || _tl_first=1
	{
		echo 'CallsManager: '
		echo '  mCalls: '
		_tl_i=$_tl_first
		for _tl_s in "$@"; do
			_tl_v=false
			case $_tl_s in *:voip)
				_tl_v=true
				_tl_s=${_tl_s%:voip}
				;;
			esac
			printf '    [Call id=TC@%s, state=%s, tpac=***, cmgr=null, handle=tel:***, vidst=A, childs(0), has_parent(false), cap=[ hld], prop=[]], voip=%s\n' \
				"$_tl_i" "$_tl_s" "$_tl_v"
			_tl_i=$((_tl_i + 1))
		done
		_tl_last=$((_tl_i - 1))
		echo '  mCallAudioManager: '
		echo 'PhoneAccountRegistrar: '
		echo 'Analytics:'
		_tl_i=1
		while [ "$_tl_i" -le "$_tl_h" ]; do
			_tl_e=false
			case " $EM_CALLS " in *" $_tl_i "*) _tl_e=true ;; esac
			_tl_end=1000000000000
			[ "$_tl_i" -lt "$_tl_first" ] || [ "$_tl_i" -gt "$_tl_last" ] || _tl_end=0
			printf '  Call TC@%s: {\n' "$_tl_i"
			printf '      %s\n' 'startTime: 0' "endTime: $_tl_end" 'direction: OUTGOING' 'isAdditionalCall: false' \
				'isInterrupted: false' "isEmergency: $_tl_e" 'callTechnologies: [IMS ]' 'missedReason: []' \
				'inCallServices: [' ']' 'callProperties: [ HD]' 'callSource: CALL_SOURCE_UNSPECIFIED'
			printf '  }\n  \n'
			_tl_i=$((_tl_i + 1))
		done
		echo '  Hardware Version: '
		echo 'Flag Configurations: '
	} >$T/telecom.new
	mv -f $T/telecom.new $T/telecom
}
# phone_state "CALL RINGING FOREGROUND BACKGROUND ECBM SCBM": the first
# phone's block in 'dumpsys telephony.registry' (mCallState; the precise
# ringing, foreground and background states; the callback-mode durations).
phone_state() {
	# shellcheck disable=SC2086 # six numbers
	set -- $1
	printf '    %s\n' "mCallState=$1" "mRingingCallState=$2" "mForegroundCallState=$3" "mBackgroundCallState=$4" \
		'mCallIncomingNumber=' 'mECBMReason=0' "mECBMDuration=$5" 'mSCBMReason=0' "mSCBMDuration=$6" >$T/registry.0.new
	mv -f $T/registry.0.new $T/registry.0
}
# radio_power 0|1: the radio switched by something other than airplane
# mode (as Android's emergency-call path switches it on).
radio_power() { echo "$1" >$T/radio; }
# phone_start: a stand-in for the phone process, a copy of sleep named
# com.android.phone (toybox pidof finds a process by the name in its
# argv[0], as Android names its app processes), in this PID namespace; its
# pid in $T/phone.pid. phone_restart: another one in its place (a crash).
phone_start() {
	[ -x $T/com.android.phone ] || cp /bin/sleep $T/com.android.phone
	$T/com.android.phone 1000000 </dev/null >/dev/null 2>&1 &
	echo $! >$T/phone.pid
}
phone_restart() {
	kill "$(cat $T/phone.pid)" 2>/dev/null
	sleep 1
	phone_start
}
# person_airplane enable|disable: airplane mode switched by the person
# (Quick Settings), through the stand-in for cmd, logged apart.
person_airplane() { FAKE_CMD_LOG=$T/person.log /system/bin/cmd connectivity airplane-mode "$1"; }
# The module's clock: /proc/uptime is a file the test writes (bound over it
# in this mount namespace): the real time since boot plus a skew that
# clock_jump moves on. A writer rewrites it in place every second (a bind
# mount follows the file, not its name).
U0=$(cut -d. -f1 /proc/uptime)
D0=$(date +%s)
echo 0 >$T/clock-skew
uptime_line() {
	_ul=$((U0 + $(date +%s) - D0 + $(cat $T/clock-skew)))
	printf '%12d.00 %12d.00\n' "$_ul" "$_ul"
}
uptime_line >$T/uptime
# clock_jump SECONDS: the module's clock moves on by SECONDS.
clock_jump() {
	echo $(($(cat $T/clock-skew) + $1)) >$T/clock-skew
	uptime_line 1<>$T/uptime
	sleep 2
}
# mark: from here on, new_cmd, new_log, new_setting, new_word, new_cells
# and no_switch_off_for look only at what follows.
mark() {
	MARK_CMD=$(wc -l <$T/cmd.log)
	MARK_LOG=$(wc -l <$A/log/module.log)
	MARK_SET=$(wc -l <$T/settings.log)
	MARK_WORD=$(words_n)
	MARK_CELLS=$(cells_n)
}
# The module's word on the cell radio to Welcome (WEL8, module_cell), as
# the stand-in for 'content call' recorded it: one line per word, "v:i:1
# gate:s:GATE cell:s:CELL radio:s:RADIO at:l:AT".
cells_n() { if [ -s $T/welcome.cells ]; then grep -c . $T/welcome.cells; else echo 0; fi; }
new_cells() { tail -n +$((MARK_CELLS + 1)) $T/welcome.cells 2>/dev/null; }
# cell_told TEXT: a word on the cell radio holding TEXT was told (ever);
# cell_told_since TEXT: since the mark.
cell_told() { grep -q -F -- "$1" $T/welcome.cells 2>/dev/null; }
cell_told_since() { new_cells | grep -q -F -- "$1"; }
# gate_write VALUE: the Phone-mode gate written as the install's PH3 step
# writes it: root's, 0600, in /data/adb.
gate_write() {
	printf '%s\n' "$1" >/data/adb/antumbra-cell.new
	chmod 0600 /data/adb/antumbra-cell.new
	mv -f /data/adb/antumbra-cell.new /data/adb/antumbra-cell
}
# person_setting KEY VALUE: a Settings.Global value written as the person
# (or an app) writes it, not by the module (so not in settings.log).
person_setting() {
	while ! mkdir $T/settings.lock 2>/dev/null; do sleep 0.1; done
	{
		grep -v -F "$1=" $T/settings
		printf '%s=%s\n' "$1" "$2"
	} >$T/settings.person
	mv -f $T/settings.person $T/settings
	rmdir $T/settings.lock
}
# ims_set: the phone process's dump with IMS registered over the cell
# network (WWAN), as Android 16 prints the parts the module reads.
ims_set() {
	printf '%s\n' 'SERVICE com.android.phone/.TelephonyDebugService 6a1 pid=1234 user=0' '  Client:' \
		'    PhoneFactory:' '      Phone: subId=0' '      ++++++++++++++++++++++++++++++++' '      ImsPhone:' \
		'        mImsMmTelRegistrationState = 2' '       Registration Log:' \
		'        2026-10-15T10:00:01.000 - handleImsRegistered: onImsMmTelConnected imsTransportType=WWAN' \
		'      ++++++++++++++++++++++++++++++++' >$T/ims
}
# new_cmd_before A B: since the mark, the module ran command A before B.
new_cmd_before() {
	_ca=$(tail -n +$((MARK_CMD + 1)) $T/cmd.log | grep -n -x -F "$1" | head -n 1 | cut -d: -f1)
	_cb=$(tail -n +$((MARK_CMD + 1)) $T/cmd.log | grep -n -x -F "$2" | tail -n 1 | cut -d: -f1)
	[ -n "$_ca" ] && [ -n "$_cb" ] && [ "$_ca" -lt "$_cb" ]
}
# The module's word to Welcome (MOD11), as the stand-in for 'content call'
# recorded it: one line per word, "v:i:1 calls:s:KIND at:l:AT until:l:UNTIL
# ims:s:IMS ims_at:l:IMS_AT".
words_n() { if [ -s $T/welcome.words ]; then grep -c . $T/welcome.words; else echo 0; fi; }
new_words() { tail -n +$((MARK_WORD + 1)) $T/welcome.words 2>/dev/null; }
new_word() { new_words | grep -q -F -- "calls:s:$1 "; }
new_words_has() { new_word "$1"; }
# after_none: the words since the mark from the first "none" on.
after_none() { new_words | sed -n '/ calls:s:none /,$p'; }
# last_word_is KIND: the last word told (since the mark or before) is KIND.
last_word_is() { tail -n 1 $T/welcome.words 2>/dev/null | grep -q -F -- "calls:s:$1 "; }
# refused_n: how many words Welcome refused (the stand-in counts them).
refused_n() { if [ -s $T/welcome.refused ]; then grep -c . $T/welcome.refused; else echo 0; fi; }
# word_field LINE NAME: a value from a recorded word.
word_field() { printf '%s\n' "$1" | sed -n "s/.* $2:[a-z]:\\([^ ]*\\).*/\\1/p"; }
# word_since KIND T: since the mark, a word KIND from a look at T or later.
word_since() {
	new_words | grep -F -- "calls:s:$1 " | {
		while IFS= read -r _ws; do
			[ "$(word_field "$_ws" at)" -ge "$2" ] && exit 0
		done
		exit 1
	}
}
# emergency_until_ok: every emergency word since the mark ends 5 minutes
# after its look, or less.
emergency_until_ok() {
	new_words | grep -q -F 'calls:s:emergency ' || return 1
	new_words | grep -F 'calls:s:emergency ' | while IFS= read -r _wu; do
		_wu_at=$(word_field "$_wu" at)
		_wu_un=$(word_field "$_wu" until)
		[ "$_wu_un" -ge "$_wu_at" ] && [ "$_wu_un" -le $((_wu_at + 300)) ] || exit 1
	done
}
new_cmd() { tail -n +$((MARK_CMD + 1)) $T/cmd.log | grep -q -x -F "$1"; }
new_log() { tail -n +$((MARK_LOG + 1)) $A/log/module.log | grep -q -F "$1"; }
new_setting() { tail -n +$((MARK_SET + 1)) $T/settings.log | grep -q -x -F "$1"; }
# new_log_before A B: since the mark, the module logged A before B. The
# module logs a switch-off just after its airplane-mode command, so a check
# that follows switched_off waits for the line (wait_until).
new_log_before() {
	_la=$(tail -n +$((MARK_LOG + 1)) $A/log/module.log | grep -n -F "$1" | head -n 1 | cut -d: -f1)
	_lb=$(tail -n +$((MARK_LOG + 1)) $A/log/module.log | grep -n -F "$2" | head -n 1 | cut -d: -f1)
	[ -n "$_la" ] && [ -n "$_lb" ] && [ "$_la" -lt "$_lb" ]
}
# stored_boot VALUE: enable_cellular_on_boot as Android stores it now.
stored_boot() { grep -q -x -F "enable_cellular_on_boot=$1" $T/settings; }
# no_switch_off_for SECONDS: no airplane mode on and no Bluetooth off since
# the mark, for SECONDS more.
no_switch_off_for() {
	sleep "$1"
	! new_cmd 'connectivity airplane-mode enable' && ! new_cmd 'bluetooth_manager disable'
}
switched_off() { new_cmd 'connectivity airplane-mode enable'; }
# wait_look: until the module has taken a look that began after this call
# (a dump of Telecom and then of the registry), and a second more for what
# it decides.
wait_look() {
	_wk=$(grep -c '^telecom$' $T/dumpsys.log)
	wait_until 70 eval '[ "$(grep -c "^telecom\$" $T/dumpsys.log)" -gt "$_wk" ] && [ "$(tail -n 1 $T/dumpsys.log)" = telephony.registry ]'
	_wk_rc=$?
	sleep 1
	return "$_wk_rc"
}

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

# --- The clock the module reads -------------------------------------------------
mount -o bind $T/uptime /proc/uptime || { echo "  FAIL  cannot bind a file over /proc/uptime"; exit 1; }
(
	while :; do
		uptime_line 1<>$T/uptime
		sleep 1
	done
) </dev/null >/dev/null 2>&1 &
up_now() {
	read -r _un _ </proc/uptime
	echo "${_un%%.*}"
}
u1=$(up_now)
clock_jump 100
u2=$(up_now)
check "clock: the test moves the module's clock on ($u1 s, then $u2 s)" test "$((u2 - u1))" -ge 100
check "clock: ... by what it says" test "$((u2 - u1))" -le 105

# --- 1. Installation (Android running) ---------------------------------------
# A Welcome from before WEL8, without the cell column and module_cell.
[ "$SCEN" = direct ] && touch $T/welcome-old
phone_start
check "phone process: the stand-in runs, and toybox pidof finds it" \
	test "$(/system/bin/toybox pidof com.android.phone)" = "$(cat $T/phone.pid)"
touch $T/framework-up
/system/bin/setprop sys.boot_completed 1
if [ "$SCEN" = offline ]; then
	# An update over a version installed before the cell radio work: its
	# record lacks the three keys added since, and holds the values from
	# before that first installation (private_dns_mode was "hostname").
	mkdir -p $MD
	printf '%s\n' captive_portal_mode=null captive_portal_detection_enabled=null ntp_server=time.android.com \
		assisted_gps_enabled=null wifi_scan_always_enabled=null ble_scan_always_enabled=null \
		private_dns_mode=hostname network_recommendations_enabled=null tether_offload_disabled=null \
		non_persistent_mac_randomization_force_enabled=null restricted_networking_mode=null mobile_data=null \
		>$MD/settings.orig
fi
(umask 000 && /system/bin/sh $T/stage/lib/emu-install.sh $T/stage >$T/install.log 2>&1)
check "install: customize.sh accepted this device" grep -q 'Installed in' $T/install.log
check "install: /data/adb/modules is 0755 (umask 0 in the installer's shell)" test "$(owner_mode /data/adb/modules)" = "0:0 755"
check "install: module files 0644, programs 0755" test "$(owner_mode $MD/lib/antumbra.sh)/$(owner_mode $MD/bin/tor)" = "0:0 644/0:0 755"
check "install: early arm script in post-fs-data.d, 0755" test "$(owner_mode /data/adb/post-fs-data.d/antumbra-arm.sh)" = "0:0 755"
check "install: tor kept for this CPU" test -x $MD/bin/tor
check "install: the other CPU's programs removed" test ! -e $MD/bin/x86_64 -a ! -e $MD/bin/arm64-v8a
check "install: settings recorded for uninstall" grep -q '^ntp_server=time.android.com$' $MD/settings.orig
check "install: airplane mode's radio list recorded" grep -q '^airplane_mode_radios=cell,bluetooth,uwb,wifi,wimax$' $MD/settings.orig
check "install: enable_cellular_on_boot recorded as unset" grep -q '^enable_cellular_on_boot=null$' $MD/settings.orig
check "install: the cell radio stored off for the first start" grep -q '^put enable_cellular_on_boot 0$' $T/settings.log
check "install: each key recorded once" test "$(grep -c . $MD/settings.orig)" = 15 -a \
	"$(cut -d= -f1 $MD/settings.orig | sort -u | grep -c .)" = 15
if [ "$SCEN" = offline ]; then
	check "update: the installed version's record kept" grep -q '^private_dns_mode=hostname$' $MD/settings.orig
	check "update: the keys it lacked added: mobile_data_always_on" grep -q '^mobile_data_always_on=null$' $MD/settings.orig
else
	check "install: private_dns_mode recorded" grep -q '^private_dns_mode=opportunistic$' $MD/settings.orig
fi
check "install: customize.sh removed, as Magisk does" test ! -e $MD/customize.sh
: >$T/settings.log

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
# MOD7: Wi-Fi calling and video calling off, in memory only, volte_avail_ovr
# untouched; the values found recorded for uninstall.sh (the phone:
# LineageOS's 1s; the emulator flavour here: wfc 1, vt none).
check "post-fs-data: Wi-Fi calling off (persist.dbg.wfc_avail_ovr 0)" test "$(prop persist.dbg.wfc_avail_ovr)" = 0
check "post-fs-data: video calling off (persist.dbg.vt_avail_ovr 0)" test "$(prop persist.dbg.vt_avail_ovr)" = 0
check "post-fs-data: persist.dbg.volte_avail_ovr untouched" test "$(prop persist.dbg.volte_avail_ovr)" = 1
if [ -n "$(prop ro.lineage.version)" ]; then
	ims_rec=$(printf 'persist.dbg.wfc_avail_ovr=1\npersist.dbg.vt_avail_ovr=1')
else
	ims_rec=$(printf 'persist.dbg.wfc_avail_ovr=1\npersist.dbg.vt_avail_ovr=')
fi
check "post-fs-data: the values found recorded" test "$(cat $A/state/module/ims-off.orig)" = "$ims_rec"
check "post-fs-data: Wi-Fi calling logged" grep -q 'Wi-Fi calling and video calling off' $A/log/module.log
if [ "$SHELLKIND" = busybox ]; then
	check "post-fs-data: set with resetprop -n" grep -q -x -e '-n persist.dbg.wfc_avail_ovr 0' $T/resetprop.log
	check "post-fs-data: nothing stored (no resetprop -p), volte never named" \
		test -z "$(grep -e '-p' -e '-P' -e volte $T/resetprop.log)"
fi

# --- 3. service.sh, before the framework is up ----------------------------------------
# The Phone-mode gate, as the install's PH3 step writes it (WEL8): "data"
# on this LineageOS hotdog (the module stops at "phone" on a phone until
# FW9 and CI12), "data" on the emulator.
case $SCEN in phone | data) gate_write data ;; esac
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
# The module logs this once settings_apply and mobile data off are done;
# only then is every key in settings.log.
check "settings: fail-safe values set" wait_until 30 grep -q 'settings: fail-safe values set' $A/log/module.log
for kv in 'captive_portal_mode 0' 'captive_portal_detection_enabled 0' 'ntp_server 127.0.0.1' 'assisted_gps_enabled 0' \
	'wifi_scan_always_enabled 0' 'ble_scan_always_enabled 0' 'private_dns_mode off' \
	'network_recommendations_enabled 0' 'tether_offload_disabled 1' \
	'non_persistent_mac_randomization_force_enabled 1' 'mobile_data 0' 'mobile_data_always_on 0' \
	'enable_cellular_on_boot 0'; do
	check "settings: $kv" grep -q "^put $kv\$" $T/settings.log
done
check "settings: airplane mode's radio list not narrowed at once" test -z "$(grep airplane_mode_radios $T/settings.log)"
check "cell: the module looks at the call state and the radio" wait_until 10 grep -q '^telephony.registry$' $T/dumpsys.log
if [ -n "$(prop ro.lineage.version)" ]; then
	check "settings: restricted_networking_mode 1 on LineageOS" grep -q '^put restricted_networking_mode 1$' $T/settings.log
else
	check "settings: restricted_networking_mode left alone on plain Android" test -z "$(grep restricted_networking_mode $T/settings.log)"
fi
check "settings: Wi-Fi scanning for location off now" grep -q '^wifi set-scan-always-available disabled$' $T/cmd.log

# --- 5. The Welcome screen's Start -------------------------------------------------------------
# welcome MODE MAC SESSION_ID [BRIDGE LINE...]: Welcome's Start, with the
# cell column WCELL (default off).
welcome() {
	_m=$1 _mac=$2 _sid=$3
	shift 3
	printf '%s\n' "$@" >$T/welcome.bridges.new
	printf 'started=1\ntor_mode=%s\nmac=%s\nadmin=0\nunsafe_browser=0\npersistent=0\nsession_id=%s\ncell=%s\n' \
		"$_m" "$_mac" "$_sid" "${WCELL:-off}" >$T/welcome.new
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
	check "module_cell: before Start: no gate, nothing carried out" \
		test "$(head -n 1 $T/welcome.cells | cut -d' ' -f2,3)" = "gate:s:off cell:s:none"
	check "module_cell: after Start: the cell radio off" wait_until 30 cell_told 'gate:s:off cell:s:off '

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
	check "firewall tampered: logged" wait_until 10 grep -q 'no longer live' $A/log/module.log

	# Android shuts down: the fail-safe Settings go back, MAC randomization
	# on again after the "keep" session. (The cell radio's watch ends at
	# shutdown: first its list, 30 s after the framework came up.)
	check "cell: airplane mode's list narrowed before the shutdown" \
		wait_until 45 grep -q '^put airplane_mode_radios cell$' $T/settings.log
	/system/bin/setprop sys.shutdown.requested 0userrequested
	check "shutdown: MAC randomization put back to 1" wait_until 10 eval \
		'test "$(last_setting non_persistent_mac_randomization_force_enabled)" = "put non_persistent_mac_randomization_force_enabled 1"'
	# The log line follows the Settings writes: wait for it too (run 16
	# looked a moment before it was written).
	check "shutdown: logged" wait_until 10 grep -q 'shutdown: fail-safe Settings put back' $A/log/module.log
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

	# MOD7: a 1 written after post-fs-data (stored values are loaded before
	# post-fs-data.sh runs, so only a later write can bring one back), with
	# no call holding the cell radio's steps: service.sh sets 0 again within
	# 30 s, and the record stays post-fs-data.sh's.
	/system/bin/setprop persist.dbg.wfc_avail_ovr 1
	check "Wi-Fi calling: a 1 that came back is set to 0 again" \
		wait_until 45 eval 'test "$(prop persist.dbg.wfc_avail_ovr)" = 0'
	# The log line follows the write: wait for it too.
	check "Wi-Fi calling: logged" wait_until 10 grep -q 'Wi-Fi calling and video calling off again' $A/log/module.log
	check "Wi-Fi calling: volte_avail_ovr still untouched" test "$(prop persist.dbg.volte_avail_ovr)" = 1
	check "Wi-Fi calling: the record is still post-fs-data.sh's" test "$(cat $A/state/module/ims-off.orig)" = "$ims_rec"

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
	check "squat: logged" wait_until 10 grep -q 'ports: free again' $A/log/module.log

	check "start: tor's network on" wait_until 30 status_has '"network":"enabled"'
	check "start: tor holds 127.0.0.1:9040" listening 2950 2350
	r=$(getconf UseBridges DisableNetwork)
	check "start: no bridges, network on" test "$r" = "250-UseBridges=0
250 DisableNetwork=0
250 closing connection"
	check "start: MAC 'new' keeps non-persistent randomization on" test -z "$(grep 'non_persistent_mac_randomization_force_enabled 0' $T/settings.log)"
	# A Welcome from before WEL8: its row read without the cell column.
	check "older Welcome: Start read without the cell column, logged once" \
		test "$(grep -c 'has no cell column (an older one)' $A/log/module.log)" = 1
	check "older Welcome: module_cell refused: logged once" \
		test "$(grep -c "did not take the module's word on the cell radio" $A/log/module.log)" = 1
	# Tried again after 30 s, then after twice as long each time, up to
	# 300 s: never at every turn.
	gaps=$(awk 'NR > 1 { printf "%s ", $2 - t } { t = $2 }' $T/welcome.cells-refused)
	check "older Welcome: module_cell tried again after 30 s, then less often (gaps: ${gaps:-none})" \
		awk 'BEGIN { w = 30 } NR > 1 { if ($2 - t < w - 1) bad = 1; w = w * 2 > 300 ? 300 : w * 2 } { t = $2 } END { exit bad + (NR == 0) }' \
		$T/welcome.cells-refused
	check "older Welcome: no word on the cell radio taken" test ! -s $T/welcome.cells
	;;
offline)
	# Calls and texts chosen, on a phone without the gate (every phone as
	# installed): the cell radio stays off.
	WCELL=phone
	welcome offline new $SID1
	WCELL=
	check "start: the session is read" wait_until 30 status_has '"started":true'
	check "Phone chosen without the gate: logged" \
		wait_until 10 grep -q "the session chose phone; this phone's gate allows off, so the module carries out off" $A/log/module.log
	check "Phone chosen without the gate: module_cell says the cell radio stays off" \
		wait_until 30 cell_told 'gate:s:off cell:s:off '
	sleep 4
	check "start: offline keeps tor's network off" test "$(getconf DisableNetwork)" = "250 DisableNetwork=1
250 closing connection"
	check "start: status shows the network off" status_has '"network":"disabled"'
	check "start: offline recorded" session_has tor_mode=offline
	check "emulator: mobile data stored off too" grep -q '^put mobile_data 0$' $T/settings.log

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

	# The gate written during the session (as the install's step might be
	# run now): nothing changes until the next start.
	gate_write phone
	check "gate raised during the session: seen" wait_until 15 grep -q 'Phone-mode gate now phone' $A/log/module.log
	check "gate raised during the session: module_cell says so, the cell radio still off" \
		wait_until 30 cell_told 'gate:s:phone cell:s:off '

	# Removal. During a boot (post-fs-data) the restore waits for boot.
	check "list narrowed before the removal" wait_until 45 grep -q '^put airplane_mode_radios cell$' $T/settings.log
	svc=$(cat $A/state/module/service.lock/pid)
	/system/bin/setprop sys.boot_completed ''
	run_module_script $MD/uninstall.sh
	check "uninstall in boot: restore script left in service.d" test -x /data/adb/service.d/antumbra-restore.sh
	check "uninstall in boot: nothing put back yet" test -z "$(grep '^delete ' $T/settings.log)"
	check "uninstall in boot: Wi-Fi calling's properties left alone (nothing was stored)" \
		test "$(prop persist.dbg.wfc_avail_ovr) $(prop persist.dbg.vt_avail_ovr)" = "0 0"
	# While Android runs (Magisk itself uninstalled): the module's
	# service.sh, still running, is stopped, and the values are put back
	# at once; nothing writes them again afterwards. The record is the one
	# from the update above: the first installation's, completed.
	/system/bin/setprop sys.boot_completed 1
	mark
	run_module_script $MD/uninstall.sh
	check "uninstall while Android runs: service.sh stopped" wait_until 5 eval \
		'case $(proc_field "$svc" State) in "" | Z*) true ;; *) false ;; esac'
	check "uninstall: ntp_server put back" new_setting 'put ntp_server time.android.com'
	check "uninstall: unset keys deleted" new_setting 'delete captive_portal_mode'
	check "uninstall: private_dns_mode put back (the first installation's value)" new_setting 'put private_dns_mode hostname'
	check "uninstall: airplane mode's radio list put back" \
		new_setting 'put airplane_mode_radios cell,bluetooth,uwb,wifi,wimax'
	check "uninstall: enable_cellular_on_boot deleted (the radio on again from the next start)" \
		new_setting 'delete enable_cellular_on_boot'
	check "uninstall: mobile_data_always_on deleted" new_setting 'delete mobile_data_always_on'
	check "uninstall: the restore script removed itself" test ! -e /data/adb/service.d/antumbra-restore.sh
	check "uninstall: the early arm script removed" test ! -e /data/adb/post-fs-data.d/antumbra-arm.sh
	check "uninstall: the Phone-mode gate removed" test ! -e /data/adb/antumbra-cell
	check "uninstall: Wi-Fi calling's force-on put back as found (1)" test "$(prop persist.dbg.wfc_avail_ovr)" = 1
	check "uninstall: video calling's, which had none, removed" test -z "$(prop persist.dbg.vt_avail_ovr)"
	check "uninstall: persist.dbg.volte_avail_ovr untouched" test "$(prop persist.dbg.volte_avail_ovr)" = 1
	n=$(wc -l <$T/settings.log)
	sleep 12
	check "uninstall: nothing writes the values again afterwards" test "$(wc -l <$T/settings.log)" = "$n"
	;;
pt)
	welcome bridges new $SID1 "obfs4 1.2.3.4:443 $FP cert=AAAA iat-mode=0"
	check "start: the session is read" wait_until 30 status_has '"started":true'
	check "start: status says pluggable transports are missing" wait_until 10 status_has 'pluggable transports'
	check "start: tor's network stays off" test "$(getconf DisableNetwork)" = "250 DisableNetwork=1
250 closing connection"

	# A call on the cell radio (switched on by something else) when
	# iptables stops working: neither the full rule set nor the arm set
	# can be loaded or checked. The module reports the firewall open and
	# switches Wi-Fi and mobile data off at once; the cell radio (airplane
	# mode) and Bluetooth wait for the call and 5 minutes after it.
	check "list narrowed before the call" wait_until 45 grep -q '^put airplane_mode_radios cell$' $T/settings.log
	telecom_set 1 ACTIVE
	phone_state '2 0 1 0 0 0'
	radio_power 1
	clock_jump 61
	check "a call on the cell radio: held (call)" wait_until 20 grep -q 'held: call' $A/log/module.log
	mark
	for t in iptables ip6tables iptables-restore ip6tables-restore iptables-save ip6tables-save; do
		mv /system/bin/$t /system/bin/$t.real
		printf '#!/system/bin/sh\nexit 1\n' >/system/bin/$t
		chmod 0755 /system/bin/$t
	done
	check "firewall broken: status says open" wait_until 45 status_has '"firewall":{"state":"open"'
	check "firewall broken: the property is removed" test -z "$(prop antumbra.fw.armed)"
	check "firewall broken during a call: Wi-Fi off at once" wait_until 10 new_cmd 'wifi set-wifi-enabled disabled'
	check "firewall broken during a call: mobile data off at once" wait_until 5 new_cmd 'phone data disable'
	check "firewall broken during a call: status says the cell radio follows" \
		wait_until 10 status_has 'cellular radio and Bluetooth off shortly'
	check "firewall broken during a call: status says nothing of the call" test -z "$(status_json | grep -i call)"
	check "firewall broken during a call: no airplane mode, no Bluetooth off" no_switch_off_for 8
	mark
	telecom_set 1
	phone_state "$IDLE"
	check "the call ended: held 5 minutes more (recent)" wait_until 20 new_log 'held: recent'
	clock_jump 270
	check "the call ended 270 s ago: still no airplane mode, no Bluetooth off" no_switch_off_for 8
	clock_jump 30
	check "5 minutes after the call: the cell radio off (airplane mode)" wait_until 15 switched_off
	check "5 minutes after the call: Bluetooth off" wait_until 5 new_cmd 'bluetooth_manager disable'
	check "5 minutes after the call: status says so" wait_until 10 eval \
		'status_has "cellular radio and Bluetooth off" && ! status_has shortly'
	for t in iptables ip6tables iptables-restore ip6tables-restore iptables-save ip6tables-save; do
		mv -f /system/bin/$t.real /system/bin/$t
	done
	check "firewall repaired: live again" wait_until 45 prop_is_live
	# Shutdown with airplane mode on and no call: airplane mode and cell_on
	# stored for the next start, without a broadcast.
	mark
	/system/bin/setprop sys.shutdown.requested 0userrequested
	check "shutdown: cell_on 1 stored" wait_until 20 new_setting 'put cell_on 1'
	check "shutdown: airplane mode stored off" wait_until 5 new_setting 'put airplane_mode_on 0'
	check "shutdown: no airplane-mode command" eval \
		'! new_cmd "connectivity airplane-mode enable" && ! new_cmd "connectivity airplane-mode disable"'
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
cell)
	# The cell radio on a LineageOS hotdog (two SIM slots), in a session
	# that keeps it off. Something switches it on; the module switches it
	# off again with airplane mode only when no hold applies. Each hold is
	# shown, then its release.
	welcome offline new $SID1
	check "start: the session is read" wait_until 30 status_has '"started":true'
	check "start: the session keeps the cell radio off (cell=off)" session_has cell=off
	check "start: airplane mode's list narrowed once airplane mode has been off 30 s" \
		wait_until 45 grep -q '^put airplane_mode_radios cell$' $T/settings.log
	check "start: nothing switched: the radio has been off since power-on" test -z "$(grep airplane-mode $T/cmd.log)"

	# 1. The radio on with airplane mode off and no call (as an emergency
	# text, or the emergency-call path, switches it on).
	check "word: the first turn told Welcome 'none'" test "$(head -n 1 $T/welcome.words | cut -d' ' -f2)" = calls:s:none
	mark
	radio_power 1
	clock_jump 61
	check "radio on by something else: held 5 minutes (recent)" wait_until 20 new_log 'held: recent'
	check "word: the radio on by something else, no call: unknown" wait_until 10 new_word unknown
	check "radio on by something else: mobile data off again" new_cmd 'phone data disable'
	check "radio on by something else: enable_cellular_on_boot 1 while held" wait_until 5 stored_boot 1
	clock_jump 270
	check "radio on by something else, 270 s later: still on" no_switch_off_for 8
	check "radio on by something else, 270 s later: enable_cellular_on_boot still 1" stored_boot 1
	clock_jump 30
	check "radio on by something else, 5 minutes later: off (airplane mode)" wait_until 15 switched_off
	check "radio on by something else: it is off" wait_until 5 eval 'test "$(cat $T/radio)" = 0'
	check "radio on by something else: enable_cellular_on_boot 0 again before the switch-off" \
		wait_until 10 new_log_before 'enable_cellular_on_boot 0 again' 'the cell radio off (airplane mode'

	# 2. The person switches airplane mode off; a call rings, is answered,
	# is put on hold, ends.
	mark
	person_airplane disable
	check "airplane mode off by the person: held (recent)" wait_until 20 new_log 'held: recent'
	check "airplane mode off by the person: mobile data off again for each SIM" new_setting 'put mobile_data1 0'
	check "airplane mode off by the person: enable_cellular_on_boot left at 1 while held" eval \
		'stored_boot 1 && ! new_setting "put enable_cellular_on_boot 0"'
	mark
	telecom_set 1 RINGING
	phone_state '1 5 0 0 0 0'
	check "ringing call: held (call)" wait_until 20 new_log 'held: call'
	clock_jump 400
	check "ringing call, 400 s later: still on" no_switch_off_for 8
	telecom_set 1 ACTIVE
	phone_state '2 0 1 0 0 0'
	check "active call: looked at" wait_look
	clock_jump 400
	check "active call, 400 s later: still on" no_switch_off_for 8
	telecom_set 1 ON_HOLD
	phone_state '2 0 0 2 0 0'
	check "call on hold: looked at" wait_look
	clock_jump 400
	check "call on hold, 400 s later: still on" no_switch_off_for 8
	# Outside Phone mode (every session until WEL8) the cell radio is off
	# by design, so a carrier call there is an emergency call, a Wi-Fi call
	# or follows a switch-on by something else: unknown.
	check "word: during the call: unknown (outside Phone mode), never ordinary" eval \
		'last_word_is unknown && ! new_word ordinary'
	mark
	telecom_set 1
	phone_state "$IDLE"
	check "call ended: held 5 minutes more (recent)" wait_until 20 new_log 'held: recent'
	check "call ended: looked at again" wait_look
	check "word: the call ended: still unknown" eval 'last_word_is unknown && ! new_word ordinary'
	clock_jump 270
	check "call ended 270 s ago: still on" no_switch_off_for 8
	check "word: the call ended 270 s ago: still unknown" eval 'last_word_is unknown && ! new_word ordinary'
	mark
	clock_jump 30
	check "call ended 5 minutes ago: off" wait_until 15 switched_off
	check "call ended 5 minutes ago: enable_cellular_on_boot 0 again before the switch-off" \
		wait_until 10 new_log_before 'enable_cellular_on_boot 0 again' 'the cell radio off (airplane mode'
	check "word: 5 minutes after the look after the end: none" wait_until 30 new_word none
	sleep 12
	check "word: then one 'none' and no other word" test "$(after_none | grep -c .)" = 1

	# 3. Emergency callback mode, from the property (both of Android's
	# paths set it).
	mark
	person_airplane disable
	check "radio on again: held (recent)" wait_until 20 new_log 'held: recent'
	/system/bin/setprop ril.cdma.inecmmode true
	check "callback mode (property): held (callback)" wait_until 15 new_log 'held: callback'
	check "word: callback mode: emergency" wait_until 10 new_word emergency
	check "word: callback mode: until at most 5 minutes after the look" emergency_until_ok
	check "callback mode: enable_cellular_on_boot 1 (a restart of the phone process keeps the radio on)" \
		stored_boot 1
	clock_jump 400
	check "callback mode, 400 s later: still on" no_switch_off_for 8
	mark
	/system/bin/setprop ril.cdma.inecmmode false
	check "callback mode over: held 5 minutes more (recent)" wait_until 15 new_log 'held: recent'
	clock_jump 270
	check "callback mode over 270 s ago: still on" no_switch_off_for 8
	clock_jump 30
	check "callback mode over 5 minutes ago: off" wait_until 15 switched_off

	# 4. Emergency callback mode in the registry: for calls, then for texts.
	# Welcome refuses the word meanwhile (as a missing or replaced Welcome
	# would).
	mark
	person_airplane disable
	check "radio on again: held" wait_until 20 new_log 'held: recent'
	touch $T/welcome-refuses
	phone_state '0 0 0 0 300000 0'
	check "callback mode for calls (registry): held (callback)" wait_until 20 new_log 'held: callback'
	check "word: Welcome refuses it: logged" wait_until 20 new_log "Welcome did not take the module's word"
	check "word: Welcome refuses an emergency word: tried again at the next looks" wait_until 30 eval \
		'[ "$(refused_n)" -ge 2 ]'
	rm -f $T/welcome-refuses
	check "word: callback mode for calls (registry): emergency" wait_until 20 new_word emergency
	check "word: Welcome takes it again: logged" wait_until 5 new_log "Welcome takes the module's word again"
	clock_jump 400
	check "callback mode for calls, 400 s later: still on" no_switch_off_for 8
	phone_state '0 0 0 0 0 300000'
	check "callback mode for texts (registry): looked at" wait_look
	clock_jump 400
	check "callback mode for texts, 400 s later: still on" no_switch_off_for 8
	mark
	phone_state "$IDLE"
	check "callback mode over: held 5 minutes more (recent)" wait_until 20 new_log 'held: recent'
	clock_jump 270
	check "callback mode over 270 s ago: still on" no_switch_off_for 8
	clock_jump 30
	check "callback mode over 5 minutes ago: off" wait_until 15 switched_off

	# 5. The state cannot be read: held as if in a call.
	mark
	person_airplane disable
	check "radio on again: held" wait_until 20 new_log 'held: recent'
	touch $T/dumpsys-broken
	check "state unreadable: held (unknown)" wait_until 20 new_log 'held: unknown'
	check "word: the state unreadable: unknown" wait_until 10 new_word unknown
	clock_jump 400
	check "state unreadable, 400 s later: still on" no_switch_off_for 8
	mark
	rm -f $T/dumpsys-broken
	check "readable again: held 5 minutes more (recent)" wait_until 40 new_log 'held: recent'
	check "word: readable again: still unknown (no other word)" test -z "$(new_words | grep -v -F 'calls:s:unknown ')"
	clock_jump 270
	check "readable again 270 s ago: still on" no_switch_off_for 8
	clock_jump 30
	check "readable again 5 minutes ago: off" wait_until 15 switched_off

	# 6. A call that began and ended between two looks: only Telecom's call
	# counter shows it, and its entry, an ordinary call.
	mark
	person_airplane disable
	check "radio on again: held" wait_until 20 new_log 'held: recent'
	clock_jump 270
	telecom_set 9
	check "a short call between two looks: looked at" wait_look
	mark
	clock_jump 30
	check "5 minutes after the switch-on but not after the short call: still on" no_switch_off_for 8
	check "word: the short call (outside Phone mode): unknown, never ordinary" eval \
		'last_word_is unknown && ! new_word ordinary'
	clock_jump 270
	check "5 minutes after the short call: off" wait_until 15 switched_off

	# 6b. An emergency call that began and ended between two looks, with
	# airplane mode switched off for it (as Android's emergency path does):
	# its entry says so. Emergency for 5 minutes, then one "none"; the
	# radio held exactly as for any call.
	mark
	EM_CALLS=10
	telecom_set 10
	person_airplane disable
	check "emergency call between two looks: held (recent)" wait_until 20 new_log 'held: recent'
	check "word: an emergency call between two looks: emergency" wait_until 20 new_word emergency
	check "word: emergency: until at most 5 minutes after the look" emergency_until_ok
	# The call is read again at the next look (it was first counted at
	# this one), and the 5 minutes count from the look after that.
	check "emergency call between two looks: looked at again" wait_look
	check "emergency call between two looks: looked at once more" wait_look
	clock_jump 255
	check "emergency call 275 s ago: still on" no_switch_off_for 8
	check "word: the emergency call 275 s ago: still emergency" wait_until 20 word_since emergency "$(($(up_now) - 5))"
	mark
	clock_jump 30
	check "emergency call 5 minutes ago: off" wait_until 15 switched_off
	check "word: the emergency call's 5 minutes over: none" wait_until 30 new_word none
	sleep 12
	check "word: then one 'none' and no other word" test "$(after_none | grep -c .)" = 1

	# 6c. Telecom's dump cut short (dumpsys gave up, or Telecom was busy)
	# right after an ordinary call: Analytics lists the newest call last,
	# so the cut loses it (here an emergency call, 12). Refused (the word
	# is unknown already, after call 11, so the log shows the refusal),
	# never ordinary.
	mark
	telecom_set 11
	clock_jump 61
	check "an ordinary call between two looks (outside Phone mode): unknown" wait_until 20 new_word unknown
	mark
	EM_CALLS='10 12'
	telecom_set 12
	sed '/^  Call TC@12: {$/,$d' $T/telecom >$T/telecom.cut
	mv -f $T/telecom.cut $T/telecom
	clock_jump 11
	check "Telecom's dump cut before the newest entry: looked at" wait_look
	check "Telecom's dump cut before the newest entry: refused (the call state cannot be read)" \
		new_log 'the call state cannot be read'
	check "Telecom's dump cut before the newest entry: unknown (no other word)" eval \
		'last_word_is unknown && test -z "$(new_words | grep -v -F "calls:s:unknown ")"'
	telecom_set 12
	# After a look that could not read the state the next comes 30 s later.
	clock_jump 31
	check "the whole dump again: emergency" wait_until 20 new_word emergency
	check "the whole dump again: read (the call state can be read again)" new_log 'the call state can be read again'
	check "the whole dump again: looked at again" wait_look
	check "the whole dump again: looked at once more" wait_look
	mark
	clock_jump 310
	check "word: the emergency call's 5 minutes over: none" wait_until 30 new_word none

	# 6d. android-1 (a): a VoIP call listed by Telecom (an ordinary call's
	# entry, isEmergency: false), the radio off, no earlier sign or doubt:
	# outside Phone mode it reads unknown, never ordinary; then one none.
	mark
	telecom_set 13 ACTIVE:voip
	clock_jump 61
	check "a VoIP call outside Phone mode: unknown" wait_until 20 new_word unknown
	telecom_set 13
	check "the VoIP call ended: looked at" wait_look
	check "the VoIP call ended: looked at again" wait_look
	clock_jump 310
	check "word: 5 minutes after the VoIP call: none" wait_until 30 new_word none
	check "word: the VoIP call: never ordinary" test -z "$(new_words | grep -F 'calls:s:ordinary ')"

	# 6e. android-1 (c): the phone process restarts (a crash): Telecom's own
	# emergency check fails while it does, so unknown for 5 minutes, then
	# one none. (No hold for it: 6g, with the radio on.)
	mark
	phone_restart
	clock_jump 61
	check "word (c): the phone process restarted: unknown" wait_until 20 new_word unknown
	clock_jump 61
	check "word (c): ... looked at again" wait_look
	clock_jump 310
	check "word (c): ... 5 minutes later: none" wait_until 20 new_word none
	clock_jump 61
	check "word (c): ... looked at once more" wait_look
	check "word (c): then one 'none' and no other word" test "$(after_none | grep -c .)" = 1

	# 6f. regressions-2: Welcome refusing a word that is not an emergency
	# word (as a Welcome without module_word does): tried once, not again
	# after each look; taken again at the first try 300 s later.
	mark
	touch $T/welcome-refuses
	r0=$(refused_n)
	phone_restart
	clock_jump 61
	check "Welcome refuses (r-2): the new word tried once" wait_until 20 eval '[ "$(refused_n)" = $((r0 + 1)) ]'
	clock_jump 61
	check "Welcome refuses (r-2): looked at" wait_look
	clock_jump 61
	check "Welcome refuses (r-2): looked at again" wait_look
	check "Welcome refuses (r-2): not tried again after each look" test "$(refused_n)" = $((r0 + 1))
	rm -f $T/welcome-refuses
	clock_jump 61
	check "Welcome refuses (r-2): looked at once more" wait_look
	check "Welcome refuses (r-2): no word before 300 s have passed" test "$(words_n)" = "$MARK_WORD"
	clock_jump 120
	check "Welcome refuses (r-2): tried again 300 s later, taken: logged" \
		wait_until 20 new_log "Welcome takes the module's word again"
	check "Welcome refuses (r-2): ... the word told" wait_until 5 new_word unknown

	# 6g. android-1 (c) with the radio on: a restart of the phone process is
	# a doubt for the word only, no call: it holds nothing. The radio,
	# switched on by something else 200 s before, goes off 5 minutes after
	# that, not 5 minutes after the restart.
	mark
	person_airplane disable
	check "radio on again: held (recent)" wait_until 20 new_log 'held: recent'
	clock_jump 200
	phone_restart
	check "the phone process restarted 200 s after the radio came on: looked at" wait_look
	check "... still on" no_switch_off_for 2
	clock_jump 90
	check "... off 5 minutes after the radio came on, not held for the restart" wait_until 15 switched_off

	# 7. Shutdown during a call (a VoIP call over Wi-Fi, airplane mode on):
	# the fail-safe Settings go back, airplane mode stays as it is.
	mark
	telecom_set 11 ACTIVE:voip
	clock_jump 61
	check "VoIP call with airplane mode on: looked at" wait_look
	/system/bin/setprop sys.shutdown.requested 0userrequested
	check "shutdown during a call: logged" wait_until 20 new_log 'shutdown: airplane mode left as it is, held: call'
	check "shutdown during a call: enable_cellular_on_boot 0 stored" new_setting 'put enable_cellular_on_boot 0'
	check "shutdown during a call: mobile data off stored" new_setting 'put mobile_data 0'
	check "shutdown during a call: airplane mode not stored off" eval \
		'! new_setting "put airplane_mode_on 0" && ! new_setting "put cell_on 1"'
	check "shutdown during a call: no airplane-mode command" eval \
		'! new_cmd "connectivity airplane-mode enable" && ! new_cmd "connectivity airplane-mode disable"'
	;;
phone)
	# Calls and texts on a LineageOS hotdog whose gate file says "data" (it
	# counts as "phone" on a phone until FW9 and CI12). Nothing before
	# Start (D12).
	check "phone: module_cell before Start: the gate stops at phone on a phone" \
		wait_until 30 cell_told 'gate:s:phone cell:s:none '
	check "phone: logged" grep -q "this phone's Phone-mode gate: phone" $A/log/module.log
	check "phone: nothing switched before Start (D12)" test -z "$(grep airplane-mode $T/cmd.log)"
	check "phone: no IMS reading before Start" test -z "$(grep -F 'ims:s:' $T/welcome.words | grep -v -F 'ims:s:off ')"
	ims_set
	mark
	WCELL=phone
	welcome offline new $SID1
	WCELL=
	check "phone: the session is read" wait_until 30 status_has '"started":true'
	check "phone: recorded: cell=phone, gate=phone" eval 'session_has cell=phone && session_has gate=phone'
	check "phone: the radio switched on at Start (once the list is narrowed)" \
		wait_until 45 new_cmd 'connectivity airplane-mode disable'
	check "phone: mobile data off first" new_cmd_before 'phone data disable' 'connectivity airplane-mode enable'
	check "phone: enable, then disable (the radio was off since power-on)" \
		new_cmd_before 'connectivity airplane-mode enable' 'connectivity airplane-mode disable'
	check "phone: the radio is on" wait_until 10 eval 'test "$(cat $T/radio)" = 1'
	check "phone: logged" wait_until 5 new_log 'Phone mode: the cell radio on, mobile data off'
	check "phone: module_cell: phone carried out, the radio on" wait_until 30 cell_told_since 'cell:s:phone radio:s:on '
	check "phone: IMS read, registered over the cell network (the VoLTE line)" \
		wait_until 30 eval 'new_words | grep -q -F "ims:s:cell "'
	check "phone: mobile data never switched on" eval '! new_cmd "phone data enable"'
	# An ordinary call (MOD11's "ordinary", in Phone mode only).
	mark
	telecom_set 1 ACTIVE
	phone_state '2 0 1 0 0 0'
	check "phone: an ordinary call: looked at" wait_look
	check "phone: an ordinary call in Phone mode: ordinary" wait_until 20 new_word ordinary
	telecom_set 1
	phone_state "$IDLE"
	check "phone: the call ended: looked at" wait_look
	check "phone: the call ended: looked at again" wait_look
	check "phone: the call ended: still ordinary, never unknown" eval 'last_word_is ordinary && ! new_word unknown'
	check "phone: the call held nothing: no switch-off" eval '! switched_off'
	# Mobile data switched on in Settings: off again at the next look.
	mark
	person_setting mobile_data1 1
	clock_jump 11
	check "phone: mobile data switched on in Settings: off again" wait_until 20 new_setting 'put mobile_data1 0'
	check "phone: ... logged" wait_until 5 new_log 'mobile data was switched on; off again'
	# The gate taken away right after the call: the radio off only 5
	# minutes after the call.
	mark
	rm -f /data/adb/antumbra-cell
	check "phone: the gate removed: seen" wait_until 15 new_log 'Phone-mode gate now off'
	check "phone: the gate removed right after a call: held (recent)" wait_until 20 new_log 'held: recent'
	check "phone: ... still on" no_switch_off_for 8
	check "phone: module_cell: nothing carried out any more, the radio still on" \
		wait_until 30 cell_told_since 'gate:s:off cell:s:off radio:s:on '
	clock_jump 300
	check "phone: 5 minutes after the call: off (airplane mode)" wait_until 20 switched_off
	check "phone: IMS no longer read" wait_until 30 eval 'tail -n 1 $T/welcome.words | grep -q -F "ims:s:off ims_at:l:0"'
	# The gate written again in the same session: the lower gate holds
	# until the next start, also when the person then switches airplane
	# mode off (the radio comes back on; Phone mode would keep it so).
	mark
	gate_write phone
	check "phone: the gate written again: seen" wait_until 15 new_log 'Phone-mode gate now phone'
	check "phone: ... the session keeps off: module_cell says so" wait_until 30 cell_told_since 'gate:s:phone cell:s:off '
	mark
	person_airplane disable
	check "phone: ... airplane mode off by the person: looked at" wait_look
	clock_jump 300
	check "phone: ... the radio off again after the hold (no Phone mode until the next start)" wait_until 30 switched_off
	check "phone: ... never switched on by the module" eval '! new_cmd "connectivity airplane-mode disable"'
	mark
	/system/bin/setprop sys.shutdown.requested 0userrequested
	check "phone: shutdown: enable_cellular_on_boot 0 stored" wait_until 20 new_setting 'put enable_cellular_on_boot 0'
	check "phone: shutdown: mobile data off stored" new_setting 'put mobile_data1 0'
	check "phone: shutdown: airplane mode stored off, cell_on 1 (no call holds it)" wait_until 10 eval \
		'new_setting "put cell_on 1" && new_setting "put airplane_mode_on 0"'
	;;
data)
	# Mobile data through Tor, on the emulator (gate "data").
	check "data: module_cell before Start: gate data" wait_until 30 cell_told 'gate:s:data cell:s:none '
	# An offline row asking for mobile data: refused, still waiting.
	WCELL=data
	welcome offline new $SID1
	check "data: offline with mobile data: refused (still waiting)" \
		wait_until 20 grep -q 'the row has an invalid cell; still waiting' $A/log/module.log
	check "data: ... not started" status_has '"welcome":{"started":false}}'
	mark
	welcome direct new $SID1
	WCELL=
	check "data: the session is read" wait_until 30 status_has '"started":true'
	check "data: recorded: cell=data, gate=data" eval 'session_has cell=data && session_has gate=data'
	check "data: the radio switched on at Start" wait_until 45 new_cmd 'connectivity airplane-mode disable'
	check "data: mobile data on for the session" wait_until 30 new_cmd 'phone data enable'
	check "data: ... after the switch-on and its own mobile data off" eval \
		'new_cmd_before "connectivity airplane-mode disable" "phone data enable" && new_cmd_before "phone data disable" "phone data enable"'
	check "data: ... over the live firewall" prop_is_live
	check "data: logged" new_log "mobile data on (the session's Internet is mobile data)"
	check "data: the default data SIM's mobile data stored on" grep -q '^mobile_data1=1$' $T/settings
	check "data: tor's network on" wait_until 30 status_has '"network":"enabled"'
	check "data: module_cell: data carried out, the radio on" wait_until 30 cell_told_since 'gate:s:data cell:s:data radio:s:on '
	# The person switches airplane mode on, then off: mobile data off, then
	# on again once the radio is back.
	person_airplane enable
	clock_jump 11
	check "data: airplane mode on by the person: looked at" wait_look
	mark
	person_airplane disable
	check "data: airplane mode off again: mobile data off, then on again" wait_until 30 eval \
		'new_cmd_before "phone data disable" "phone data enable"'
	# The gate lowered to phone: mobile data off at once, the radio stays on.
	mark
	gate_write phone
	check "data: the gate lowered to phone: mobile data off at once" wait_until 15 new_cmd 'phone data disable'
	check "data: ... logged" wait_until 5 new_log "mobile data off (this phone's gate no longer allows it)"
	check "data: ... the radio stays on" no_switch_off_for 8
	check "data: ... mobile data not switched on again" eval '! new_cmd "phone data enable"'
	check "data: module_cell: phone carried out" wait_until 30 cell_told_since 'gate:s:phone cell:s:phone '
	mark
	/system/bin/setprop sys.shutdown.requested 0userrequested
	check "data: shutdown: mobile data stored off" wait_until 20 new_setting 'put mobile_data1 0'
	check "data: shutdown: mobile data not switched on again" eval 'sleep 6; ! new_cmd "phone data enable"'
	;;
esac

# Every scenario: the cell radio's watch.
check "cell: airplane mode's list narrowed to the cell radio" \
	wait_until 45 grep -q '^put airplane_mode_radios cell$' $T/settings.log
case $SCEN in
pt | cell | phone | data) ;;
*)
	check "cell: the radio stayed off: no airplane-mode command" test -z "$(grep airplane-mode $T/cmd.log)"
	check "cell: no Bluetooth command" test -z "$(grep bluetooth $T/cmd.log)"
	;;
esac
case $SCEN in
phone | data) ;;
*)
	check "cell: the module never switched the radio on" test -z "$(grep -x 'connectivity airplane-mode disable' $T/cmd.log)"
	check "cell: mobile data never switched on" test -z "$(grep -x 'phone data enable' $T/cmd.log)"
	;;
esac
if [ -s $A/state/module/session ]; then
	case $SCEN in
	phone) want='cell=phone gate=phone' ;;
	data) want='cell=data gate=data' ;;
	offline) want='cell=phone gate=off' ;;
	*) want='cell=off gate=off' ;;
	esac
	check "cell: the session record says $want" eval 'session_has "${want% *}" && session_has "${want#* }"'
fi
case $SCEN in
offline | phone | data) ;;
*) check "cell: no Phone-mode gate: nothing writes one" test ! -e /data/adb/antumbra-cell ;;
esac
check "cell: no number and no dump in the module's log" test -z "$(grep -E 'mCall|TC@|Phone Id|tel:' $A/log/module.log)"
# Every scenario: the module's word to Welcome (MOD11) went to Welcome's
# provider alone, holds nothing but its six fields, and neither status.json
# (which every app can read) nor the module's log names a word.
check "word: Welcome was told (at least the first turn's 'none')" wait_until 70 grep -q 'calls:s:none ' $T/welcome.words
case $SCEN in
phone | data) ims='(off|cell|wifi|registered|none|unknown) ims_at:l:[0-9]+' ;;
*) ims='off ims_at:l:0' ;;
esac
check "word: nothing but the six fields" test -z "$(grep -v -E \
	"^v:i:1 calls:s:(emergency|ordinary|unknown|none) at:l:[0-9]+ until:l:[0-9]+ ims:s:$ims\$" $T/welcome.words)"
check "word: status.json says nothing of calls or IMS" test -z "$(status_json | grep -i -E 'ordinary|emergency|"calls"|"ims"|until|callback')"
check "word: the module's log names no word" test -z "$(grep -E 'ordinary|calls:|until:|ims:|ims=' $A/log/module.log)"
# Outside Phone mode the word is never ordinary (the phone scenario has an
# ordinary call in Phone mode).
case $SCEN in
phone) ;;
*) check "word: never 'ordinary' outside Phone mode" test -z "$(grep -F 'calls:s:ordinary ' $T/welcome.words)" ;;
esac
check "word: no word in a file of the module" test -z "$(grep -r -l -F 'calls:s:' $A 2>/dev/null)"
case $SCEN in
pt | cell | phone | data) ;;
*) check "word: no call in this scenario: one word, 'none'" test "$(words_n)" = 1 ;;
esac
# Every scenario: the module's word on the cell radio (WEL8) went to
# Welcome's provider alone, holds nothing but its five fields, and neither
# status.json nor the module's log holds it.
case $SCEN in
direct) ;;
*) check "module_cell: Welcome was told" test -s $T/welcome.cells ;;
esac
check "module_cell: nothing but the five fields" test -z "$(grep -v -E \
	'^v:i:1 gate:s:(off|phone|data) cell:s:(none|off|phone|data) radio:s:(on|off|wait|unknown) at:l:[0-9]+$' \
	$T/welcome.cells 2>/dev/null)"
check "module_cell: status.json says nothing of the gate, the cell choice or the radio" \
	test -z "$(status_json | grep -E '"gate"|"cell"|"radio"|gate:|phone_mode|"sim')"
check "module_cell: the module's log names no word" test -z "$(grep -E 'gate:s|cell:s:|radio:s:' $A/log/module.log)"

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
