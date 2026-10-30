#!/bin/sh
# shellcheck source-path=SCRIPTDIR
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Antumbra module: unit tests of the functions in lib/antumbra.sh that take
# no action on the system (parsing and checking).
#
# Usage: tests/unit.sh [SHELL...]
#   Runs the tests under each SHELL (default: sh, plus dash, busybox sh and
#   mksh when they are installed; set MKSH to Android's mksh). Needs no
#   root. Exits 1 if any test fails.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
MODULE=$(cd "$HERE/.." && pwd)

if [ "${1-}" != --inner ]; then
	shells=${*:-}
	if [ -z "$shells" ]; then
		shells='sh'
		command -v dash >/dev/null 2>&1 && shells="$shells dash"
		command -v busybox >/dev/null 2>&1 && shells="$shells busybox"
		if [ -n "${MKSH:-}" ]; then
			shells="$shells $MKSH"
		elif command -v mksh >/dev/null 2>&1; then
			shells="$shells mksh"
		fi
	fi
	rc=0
	for s in $shells; do
		echo "== $s"
		if [ "$s" = busybox ]; then
			busybox sh "$0" --inner || rc=1
		else
			"$s" "$0" --inner || rc=1
		fi
	done
	exit "$rc"
fi

# shellcheck disable=SC2034 # read by lib/antumbra.sh
MODDIR=$MODULE
# shellcheck source=../lib/antumbra.sh
. "$MODULE/lib/antumbra.sh"
LOGDIR=$(mktemp -d)
trap 'rm -rf "$LOGDIR"' EXIT
REAL_TB=$TB

fails=0
# The phone process as phone_proc reports it, "PID:START" ("-": not
# running); a stand-in for the watch's tests (the real phone_proc is tested
# below, on this host's processes).
FAKE_PROC=1234:5678
phone_proc() {
	[ "$FAKE_PROC" != - ] || return 1
	echo "$FAKE_PROC"
}
ok() { printf '  ok    %s\n' "$1"; }
bad() {
	printf '  FAIL  %s\n' "$1"
	fails=$((fails + 1))
}
expect() { # DESCRIPTION EXPECTED ACTUAL
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2], got [$3]"; fi
}

# --- cell_gate_owner_ok: the gate's owner and mode (the real check, with this
# host's stat in place of Android's toybox) -----------------------------------
go() { (TB=; cell_gate_owner_ok "$1") && echo yes || echo no; }
gf=$LOGDIR/gate-owner
printf 'phone\n' >"$gf"
if [ "$(id -u)" = 0 ]; then
	for m in 600 400 644 640 604 4755; do
		chmod "$m" "$gf"
		expect "cell_gate_owner_ok: root's, mode $m" yes "$(go "$gf")"
	done
	for m in 620 602 660 606 666 670 607 2777; do
		chmod "$m" "$gf"
		expect "cell_gate_owner_ok: root's, mode $m (group or others may write)" no "$(go "$gf")"
	done
	chmod 600 "$gf"
	chown 1:0 "$gf"
	expect "cell_gate_owner_ok: another owner" no "$(go "$gf")"
else
	chmod 600 "$gf"
	expect "cell_gate_owner_ok: not root's (this user's)" no "$(go "$gf")"
fi
expect "cell_gate_owner_ok: no file" no "$(go "$LOGDIR/none")"
expect "cell_gate_owner_ok: Android's toybox is the module's stat" "/system/bin/toybox" "$REAL_TB"

# The gate for every test below: a file the tests write, with the owner
# check replaced (FAKE_GATE_OWNER=bad: another owner, or group or others
# may write). Until the WEL8 tests near the end, it allows Phone mode, so
# that the tests of Phone mode (SES_CELL=phone) find it allowed.
CELL_GATE_FILE=$LOGDIR/antumbra-cell
cell_gate_owner_ok() { [ "${FAKE_GATE_OWNER:-ok}" = ok ]; }
CELL_EMULATOR=0
printf 'phone\n' >"$CELL_GATE_FILE"
CELL_GATE=phone SES_GATE=phone CELL_GATE_SEEN=phone

# --- ipv4_port ---------------------------------------------------------------
for a in 1.2.3.4:443 255.255.255.255:65535 10.0.0.1:1; do
	if ipv4_port "$a"; then ok "ipv4_port accepts $a"; else bad "ipv4_port refuses $a"; fi
done
for a in 1.2.3.4 1.2.3:443 1.2.3.4.5:443 256.1.1.1:443 1.2.3.4:0 1.2.3.4:65536 \
	'[::1]:443' 1.2.3.4:44a :443 1.2.3.4: a.b.c.d:1 1.2.3.4:1234567; do
	if ipv4_port "$a"; then bad "ipv4_port accepts $a"; else ok "ipv4_port refuses $a"; fi
done

# --- bridges_check -------------------------------------------------------------
FP=0123456789ABCDEF0123456789abcdef01234567
f=$LOGDIR/bridges
check() { # DESCRIPTION EXPECTED(plain|pt|fail) LINES...
	_d=$1 _e=$2
	shift 2
	printf '%s\n' "$@" >"$f"
	_out=$(bridges_check "$f")
	_rc=$?
	if [ "$_e" = fail ]; then
		if [ "$_rc" -ne 0 ]; then ok "$_d (refused: $_out)"; else bad "$_d: accepted ($_out)"; fi
	else
		expect "$_d" "$_e" "$_out"
	fi
}
check "plain bridge" plain "1.2.3.4:443"
check "plain bridge with fingerprint" plain "1.2.3.4:443 $FP"
check "two plain bridges and a blank line" plain "1.2.3.4:443" "" "5.6.7.8:9001 $FP"
check "obfs4 bridge" pt "obfs4 1.2.3.4:443 $FP cert=abc+/= iat-mode=0"
check "webtunnel bridge" pt "webtunnel [2001:db8::1]:443 $FP url=https://example.org/x ver=0.0.1"
check "meek_lite bridge" pt "meek_lite 192.0.2.2:80 url=https://meek.example/ front=cdn.example"
check "plain then obfs4" pt "1.2.3.4:443" "obfs4 5.6.7.8:443 $FP cert=x iat-mode=0"
check "no bridges" fail ""
check "snowflake" fail "snowflake 192.0.2.3:80 $FP url=https://x/ fronts=a.com,b.com"
check "unknown transport" fail "obfs3 1.2.3.4:443"
check "quote" fail '1.2.3.4:443 "x'
check "backslash" fail '1.2.3.4:443 \x'
check "control character" fail "$(printf '1.2.3.4:443\tx')"
check "non-ASCII" fail "$(printf '1.2.3.4:443 \303\251')"
check "IPv6 plain bridge" fail "[2001:db8::1]:443 $FP"
check "obfs4 without address" fail "obfs4"
check "obfs4 with IPv6 address" fail "obfs4 [2001:db8::1]:443 $FP cert=x"
check "obfs4 without cert" fail "obfs4 1.2.3.4:443 $FP iat-mode=0"
check "webtunnel without url" fail "webtunnel [2001:db8::1]:443 $FP ver=0.0.1"
check "short fingerprint" fail "1.2.3.4:443 0123"
check "bad fingerprint" fail "1.2.3.4:443 0123456789ABCDEF0123456789abcdef0123456Z"
check "double space" fail "1.2.3.4:443  $FP"
check "leading space" fail " 1.2.3.4:443"
check "trailing comma (extra columns)" fail "1.2.3.4:443 $FP, mac=new, admin=0"
long=$(printf '%601s' x | tr ' ' a)
check "too long" fail "1.2.3.4:443 $long"
twenty_one=
i=0
while [ "$i" -lt 21 ]; do
	twenty_one="$twenty_one 10.0.0.$i:443"
	i=$((i + 1))
done
# shellcheck disable=SC2086 # one argument per bridge
check "21 bridges" fail $twenty_one
# shellcheck disable=SC2086
set -- $twenty_one
shift
check "20 bridges" plain "$@"

# --- row_get -------------------------------------------------------------------------
row='Row: 0 started=1, tor_mode=bridges, mac=new, session_id=00ff00ff00ff00ff'
expect "row_get started" 1 "$(row_get "$row" started)"
expect "row_get tor_mode" bridges "$(row_get "$row" tor_mode)"
expect "row_get mac" new "$(row_get "$row" mac)"
expect "row_get last column" 00ff00ff00ff00ff "$(row_get "$row" session_id)"
expect "row_get missing column" "" "$(row_get "$row" admin)"
expect "row_get not a row" "" "$(row_get 'No result found.' started)"
expect "row_get other row" "" "$(row_get 'Row: 1 started=1' started)"
expect "row_get prefix of a name" "" "$(row_get 'Row: 0 xstarted=1' started)"
expect "row_get empty value" "" "$(row_get 'Row: 0 started=, mac=new' started)"

# --- torctl_ok -----------------------------------------------------------------------
CR=$(printf '\r')
r="250 OK$CR
250-version=0.4.9.14$CR
250 OK$CR
250 closing connection$CR"
if torctl_ok "$r" 1; then ok "torctl_ok: auth + GETINFO"; else bad "torctl_ok: auth + GETINFO"; fi
r="250 OK$CR
250 OK$CR"
if torctl_ok "$r" 1; then ok "torctl_ok: without the QUIT reply"; else bad "torctl_ok: without the QUIT reply"; fi
r="515 Authentication failed: Wrong length on authentication cookie.$CR"
if torctl_ok "$r" 1; then bad "torctl_ok: auth failure accepted"; else ok "torctl_ok: auth failure"; fi
r="250 OK$CR
552 Unrecognized option$CR
250 closing connection$CR"
if torctl_ok "$r" 1; then bad "torctl_ok: 552 accepted"; else ok "torctl_ok: 552"; fi
if torctl_ok "" 1; then bad "torctl_ok: empty accepted"; else ok "torctl_ok: empty"; fi
r="250 OK$CR"
if torctl_ok "$r" 1; then bad "torctl_ok: missing command reply accepted"; else ok "torctl_ok: missing command reply"; fi

# --- JSON helpers --------------------------------------------------------------------
expect "json_str" '"abc 1.2"' "$(json_str 'abc 1.2')"
expect "json_str drops quotes and backslashes" '"ab"' "$(json_str 'a"\b')"
expect "json_str empty" null "$(json_str '')"
expect "json_int" 42 "$(json_int 42)"
expect "json_int not a number" null "$(json_int 4x)"
expect "json_bool" true "$(json_bool 1)"
expect "json_bool false" false "$(json_bool 0)"

# --- settings.conf -------------------------------------------------------------------
# A fake 'settings' for settings_apply, and getprop for is_lineage.
mkdir -p "$LOGDIR/bin"
cat >"$LOGDIR/bin/settings" <<'EOF'
#!/bin/sh
echo "$*" >>"$SETTINGS_LOG"
EOF
chmod 0755 "$LOGDIR/bin/settings"
settings_put() { "$LOGDIR/bin/settings" put global "$1" "$2"; }
SETTINGS_LOG=$LOGDIR/settings.log
export SETTINGS_LOG
getprop() {
	case $1 in
	ro.lineage.version) printf '%s' "${FAKE_LINEAGE-}" ;;
	ro.boot.qemu) printf '%s' "${FAKE_QEMU-}" ;;
	esac
}
FAKE_LINEAGE=
FAKE_QEMU=1
settings_apply >/dev/null
logged() { grep -q "$1" "$SETTINGS_LOG"; }
n=$(grep -c '^put global ' "$SETTINGS_LOG")
expect "settings_apply on the emulator: 13 values" 13 "$n"
if logged restricted_networking_mode; then
	bad "restricted_networking_mode set on the emulator"
else
	ok "restricted_networking_mode not set on the emulator"
fi
for kv in 'captive_portal_mode 0' 'ntp_server 127.0.0.1' 'private_dns_mode off' 'tether_offload_disabled 1' \
	'mobile_data 0' 'mobile_data_always_on 0' 'enable_cellular_on_boot 0'; do
	if logged "^put global $kv\$"; then ok "$kv (emulator)"; else bad "$kv (emulator)"; fi
done
if logged airplane_mode_radios; then
	bad "airplane_mode_radios set by settings_apply"
else
	ok "airplane_mode_radios not set by settings_apply (the cell radio's watch narrows it)"
fi
: >"$SETTINGS_LOG"
FAKE_LINEAGE=23.2-20261009-NIGHTLY-hotdog
FAKE_QEMU=
settings_apply >/dev/null
n=$(grep -c '^put global ' "$SETTINGS_LOG")
expect "settings_apply on LineageOS (the phone): 14 values" 14 "$n"
if logged '^put global restricted_networking_mode 1$'; then
	ok "restricted_networking_mode 1 on LineageOS"
else
	bad "restricted_networking_mode 1 on LineageOS"
fi
for kv in 'mobile_data 0' 'mobile_data_always_on 0' 'enable_cellular_on_boot 0'; do
	if logged "^put global $kv\$"; then ok "$kv on the phone"; else bad "$kv on the phone"; fi
done
if logged airplane_mode_radios; then bad "airplane_mode_radios set by settings_apply on the phone"; fi
# The keys uninstall.sh and customize.sh read from settings.conf.
keys=$(sed -n -e 's/^lineage://' -e 's/^phone://' -e 's/^cell://' -e 's/^\([a-z0-9_]*\)=.*/\1/p' "$SETTINGS_CONF" | tr '\n' ' ')
expect "settings.conf keys for settings.orig" \
	"captive_portal_mode captive_portal_detection_enabled ntp_server assisted_gps_enabled wifi_scan_always_enabled ble_scan_always_enabled private_dns_mode network_recommendations_enabled tether_offload_disabled non_persistent_mac_randomization_force_enabled restricted_networking_mode mobile_data mobile_data_always_on enable_cellular_on_boot airplane_mode_radios " \
	"$keys"
expect "the narrowed list in settings.conf is CELL_RADIOS" "$CELL_RADIOS" \
	"$(sed -n 's/^cell:airplane_mode_radios=//p' "$SETTINGS_CONF")"

# --- ports_bad: who holds the service ports (fixtures in PROC_NET) --------------
P=$LOGDIR/net
mkdir -p "$P"
H='  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode'
H6='  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode'
tcp_line() { # LOCAL REMOTE STATE UID
	printf '   0: %s %s %s 00000000:00000000 00:00000000 00000000 %5s        0 1234 1 0000000000000000 100 0 0 10 0\n' "$1" "$2" "$3" "$4"
}
udp_line() { # LOCAL STATE UID
	printf '  100: %s 00000000:0000 %s 00000000:00000000 00:00000000 00000000 %5s        0 4321 2 0000000000000000 0\n' "$1" "$2" "$3"
}
reset_net() {
	printf '%s\n' "$H" >"$P/tcp"
	printf '%s\n' "$H" >"$P/udp"
	printf '%s\n' "$H6" >"$P/tcp6"
	printf '%s\n' "$H6" >"$P/udp6"
}
pb() { PROC_NET=$P ports_bad | sort | tr '\n' ';'; }
reset_net
expect "ports_bad: nothing listening" "" "$(pb)"
# tor and the filter on their ports; an app's connection redirected to
# 9040 (remote port 9040); tor's accepted connection; a TIME_WAIT entry
# (uid 0); the filter's upstream socket; another app on other ports.
{
	tcp_line 0100007F:2350 00000000:0000 0A 2950
	tcp_line 0100007F:14D7 00000000:0000 0A 2951
	tcp_line 0100007F:1504 00000000:0000 0A 2951
	tcp_line 0A00020F:9C40 5DB8D822:0050 01 10100
	tcp_line 0100007F:2350 0100007F:9C41 01 2950
	tcp_line 0100007F:2350 0100007F:9C42 06 0
	tcp_line 0100007F:9C43 0100007F:2350 01 10100
	tcp_line 0100007F:1F90 00000000:0000 0A 10200
} >>"$P/tcp"
{
	udp_line 0100007F:235D 07 2950
	udp_line 0100007F:14D7 07 2951
	udp_line 0100007F:C350 01 2951
} >>"$P/udp"
expect "ports_bad: tor and the filter on their ports" "" "$(pb)"
tcp_line 00000000:2350 00000000:0000 0A 10200 >>"$P/tcp"
expect "ports_bad: an app on 0.0.0.0:9040" "9040/tcp held by uid 10200;" "$(pb)"
reset_net
tcp_line 0100007F:2350 00000000:0000 0A 10200 >>"$P/tcp"
udp_line 0100007F:14D7 07 10200 >>"$P/udp"
tcp_line 0100007F:1504 00000000:0000 0A 0 >>"$P/tcp"
expect "ports_bad: TransPort, filter and status page taken" \
	"5335/udp held by uid 10200;5380/tcp held by uid 0;9040/tcp held by uid 10200;" "$(pb)"
reset_net
tcp_line 00000000000000000000000000000000:2350 00000000000000000000000000000000:0000 0A 10200 >>"$P/tcp6"
udp_line 0000000000000000FFFF00000100007F:235D 07 10300 >>"$P/udp6"
expect "ports_bad: an app on [::]:9040 and [::ffff:127.0.0.1]:9053" \
	"9040/tcp held by uid 10200;9053/udp held by uid 10300;" "$(pb)"
reset_net
# Bound to another address: cannot receive what is sent to 127.0.0.1.
tcp_line 0A00020F:2350 00000000:0000 0A 10200 >>"$P/tcp"
udp_line 0100A8C0:14D7 07 1000 >>"$P/udp"
# A UDP socket on 9040 or 5380: no service uses UDP there.
udp_line 0100007F:2350 07 10200 >>"$P/udp"
expect "ports_bad: other addresses and unused protocols are ignored" "" "$(pb)"
reset_net
# A connected UDP socket on 5335 counts.
udp_line 0100007F:14D7 01 10200 >>"$P/udp"
expect "ports_bad: a connected UDP socket on 5335" "5335/udp held by uid 10200;" "$(pb)"
reset_net
# Android's mDNS (uid 1020) on 0.0.0.0:5353, as the emulator showed it at
# boot: not a service port, so not a squatter.
udp_line 00000000:14E9 07 1020 >>"$P/udp"
expect "ports_bad: Android's mDNS on 0.0.0.0:5353 is not a service port" "" "$(pb)"
rm -f "$P/tcp"
expect "ports_bad: /proc/net/tcp unreadable fails closed" "$P/tcp is unreadable;" "$(pb)"
if PROC_NET=$P listeners_ok; then bad "listeners_ok with tcp unreadable"; else ok "listeners_ok false when unreadable"; fi
reset_net
if PROC_NET=$P listeners_ok; then ok "listeners_ok true with nothing listening"; else bad "listeners_ok: $PORTS_BAD"; fi

# --- start_dnsfilter: the CI's query-log switch, on the emulator only ----------
# A stand-in antumbra-run records its arguments; getprop answers from PROPS.
BIN=$LOGDIR/bin
PRIV=$LOGDIR/priv
mkdir -p "$BIN" "$PRIV"
RUN_ARGS=$LOGDIR/run-args
export RUN_ARGS
# shellcheck disable=SC2016 # expanded by the stand-in, not here
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >"$RUN_ARGS"\n' >"$BIN/antumbra-run"
: >"$BIN/antumbra-dnsfilter"
chmod 755 "$BIN/antumbra-run" "$BIN/antumbra-dnsfilter"
PROPS=
getprop() { printf '%s\n' "$PROPS" | sed -n "s/^$1=//p"; }
sd_flags() { # PROPS: start_dnsfilter's flags after the two list paths
	PROPS=$1
	rm -f "$RUN_ARGS"
	start_dnsfilter
	wait
	sed 's/.*dnsfilter\.list -list [^ ]*dnsfilter\.list *//' "$RUN_ARGS"
}
expect "start_dnsfilter: no query log on a phone, even with the switch" "" \
	"$(sd_flags 'debug.antumbra.log_queries=1')"
expect "start_dnsfilter: no query log on the emulator without the switch" "" "$(sd_flags 'ro.boot.qemu=1')"
expect "start_dnsfilter: the CI switch on the emulator" "-debug-log-queries -status-refresh 0" \
	"$(sd_flags "$(printf 'ro.boot.qemu=1\ndebug.antumbra.log_queries=1')")"

# --- The cell radio: parsers ---------------------------------------------------------
# Dumps shaped like Android 16's (TelecomServiceImpl, CallsManager, Call,
# Analytics; TelephonyRegistry), with nothing but placeholders where a
# number would be.

# telecom_fixture HISTORY STATE...: 'dumpsys telecom' with one live call per
# STATE and one Analytics entry per call in HISTORY, laid out as Android 16
# prints them (TelecomServiceImpl, CallsManager, Call.toString,
# Analytics.CallInfoImpl.toString under an IndentingPrintWriter).
# HISTORY is N (calls 1 to N, ordinary, ended) or a list of words: N (call
# N, ordinary, ended), N:KIND, or id:ID (an entry whose id is not
# TC@<number>). KIND: e (isEmergency: true), ecall or ecbm (in
# callProperties), missed (missedReason: [emergency] on an ordinary call),
# - (no isEmergency line), x (isEmergency: maybe), np (no callProperties
# line), 2 (two isEmergency lines), gone (no entry), noend (no endTime
# line), badend (endTime: soon), open (an ordinary call not ended yet:
# endTime: 0), or any of them with +open (not ended yet). An entry ends
# (endTime, milliseconds since the epoch) unless it is open. STATE is a
# call state, with :voip (a VoIP call), :ecall or :ecbm (in its prop=) and
# @N (its number; else 1, 2, ... in order).
tf_entry() { # ID KIND
	printf '  Call %s: {\n' "$1"
	echo '      startTime: 0'
	case $2 in
	*open) echo '      endTime: 0' ;;
	noend) ;;
	badend) echo '      endTime: soon' ;;
	*) echo '      endTime: 1000000000000' ;;
	esac
	printf '      %s\n' 'direction: OUTGOING' 'isAdditionalCall: false' 'isInterrupted: false'
	case ${2%+open} in
	e) echo '      isEmergency: true' ;;
	-) ;;
	x) echo '      isEmergency: maybe' ;;
	2) printf '      isEmergency: false\n      isEmergency: false\n' ;;
	*) echo '      isEmergency: false' ;;
	esac
	echo '      callTechnologies: [IMS ]'
	echo '      callTerminationReason: DisconnectCause [ Code: (LOCAL) Label: () Description: () Reason: (LOCAL) Tone: (-1) ]'
	if [ "${2%+open}" = missed ]; then echo '      missedReason: [emergency]'; else echo '      missedReason: []'; fi
	echo '      connectionService: com.android.phone/com.android.services.telephony.TelephonyConnectionService'
	echo '      isVideoCall: false'
	echo '      inCallServices: ['
	echo '          name: ComponentInfo{com.android.dialer/com.android.incallui.InCallServiceImpl} type: 1 is crashed: false service last time in ms: 0'
	echo '      ]'
	case ${2%+open} in
	ecall) echo '      callProperties: [ HD ecall]' ;;
	ecbm) echo '      callProperties: [ ecbm]' ;;
	np) ;;
	*) echo '      callProperties: [ HD]' ;;
	esac
	echo '      callSource: CALL_SOURCE_UNSPECIFIED'
	echo '  }'
	echo '  '
}
telecom_fixture() {
	_tf_h=$1
	shift
	echo 'CallsManager: '
	echo '  mCalls: '
	_tf_i=0
	for _tf_s in "$@"; do
		_tf_i=$((_tf_i + 1))
		_tf_n=$_tf_i
		case $_tf_s in *@*)
			_tf_n=${_tf_s#*@}
			_tf_s=${_tf_s%@*}
			;;
		esac
		_tf_v=false
		_tf_p=
		case $_tf_s in
		*:voip) _tf_v=true ;;
		*:ecall) _tf_p=' HD ecall' ;;
		*:ecbm) _tf_p=' ecbm' ;;
		esac
		_tf_s=${_tf_s%%:*}
		printf '    [Call id=TC@%s, state=%s, tpac=ComponentInfo{com.android.phone/com.android.services.telephony.TelephonyConnectionService}, ***, UserHandle{0}, cmgr=null, handle=tel:***, vidst=A, childs(0), has_parent(false), cap=[ hld mut], prop=[%s]], voip=%s\n' \
			"$_tf_n" "$_tf_s" "$_tf_p" "$_tf_v"
	done
	echo '  mCallAudioManager: '
	echo '    [Call id=TC@77, state=ACTIVE] listed by another section'
	echo '  mPendingRedirectedOutgoingCallInfo:'
	echo 'PhoneAccountRegistrar: '
	echo '  mPhoneAccounts:'
	echo 'Analytics:'
	case $_tf_h in
	*[!0-9]*) _tf_list=$_tf_h ;;
	*)
		_tf_list=
		_tf_i=1
		while [ "$_tf_i" -le "$_tf_h" ]; do
			_tf_list="$_tf_list $_tf_i"
			_tf_i=$((_tf_i + 1))
		done
		;;
	esac
	for _tf_w in $_tf_list; do
		case $_tf_w in
		id:*) tf_entry "${_tf_w#id:}" o ;;
		*:gone) ;;
		*:*) tf_entry "TC@${_tf_w%%:*}" "${_tf_w#*:}" ;;
		*) tf_entry "TC@$_tf_w" o ;;
		esac
	done
	echo '  CSW.aC: 3.50'
	echo '  Hardware Version: '
	echo '  Past analytics dumps: '
	echo 'Flag Configurations: '
	echo 'TransactionManager:'
	echo 'Historical Events:'
	echo '  CallTC@1 [2026-10-15 10:00:00.000](MO - outgoing)'
}

# registry_fixture RADIO PHONE0 [PHONE1]: 'dumpsys telephony.registry' with
# mRadioPowerState=RADIO and, per phone, "CALL RINGING FOREGROUND BACKGROUND
# ECBM SCBM" (the second phone idle unless given; "-" leaves it out).
registry_fixture() {
	_rf_radio=$1
	_rf_p0=$2
	_rf_p1=${3-0 0 0 0 0 0}
	echo 'last known state:'
	_rf_n=0
	for _rf_f in "$_rf_p0" "$_rf_p1"; do
		[ "$_rf_f" = - ] && continue
		# shellcheck disable=SC2086 # six numbers
		set -- $_rf_f
		echo "  Phone Id=$_rf_n"
		echo "    mCallState=$1"
		echo "    mRingingCallState=$2"
		echo "    mForegroundCallState=$3"
		echo "    mBackgroundCallState=$4"
		echo "    mPreciseCallState=Ringing call state: $2, Foreground call state: $3, Background call state: $4, Disconnect cause: -1, Precise disconnect cause: -1"
		echo "    mCallDisconnectCause=-1"
		echo "    mCallIncomingNumber=NUMBER-PLACEHOLDER"
		echo "    mServiceState={mVoiceRegState=1(OUT_OF_SERVICE), mDataRegState=1(OUT_OF_SERVICE)}"
		echo "    mECBMReason=0"
		echo "    mECBMDuration=$5"
		echo "    mSCBMReason=0"
		echo "    mSCBMDuration=$6"
		_rf_n=$((_rf_n + 1))
	done
	echo '  mPhoneCapability=null'
	[ "$_rf_radio" = - ] || echo "  mRadioPowerState=$_rf_radio"
	echo '  mEmergencyNumberList=[]'
	echo 'local logs:'
	echo '  notifyCallState: mCallState=2 mForegroundCallState=1 (after the part that is read)'
	echo '    mCallState=1'
}

ts() { telecom_fixture "$@" | telecom_state; }
expect "telecom_state: no calls, no history" "0 0 - - 0" "$(ts 0)"
expect "telecom_state: calls 1 to 3 in the past, none now" "0 3 o - 0" "$(ts 3)"
for st in RINGING DIALING CONNECTING NEW SELECT_PHONE_ACCOUNT ACTIVE ON_HOLD DISCONNECTING AUDIO_PROCESSING; do
	expect "telecom_state: a call in state $st counts" "1 1 o 1 0" "$(ts 1 "$st")"
done
expect "telecom_state: an active and a held call" "2 2 o 1,2 0" "$(ts 2 ACTIVE ON_HOLD)"
expect "telecom_state: a VoIP call counts" "1 1 o 1 0" "$(ts 1 ACTIVE:voip)"
expect "telecom_state: a call line in another section does not count" "0 0 - - 0" "$(ts 0)"
expect "telecom_state: the highest number from Analytics" "1 9 o 1 0" "$(ts 9 RINGING)"
# fails DESCRIPTION COMMAND...: the parser refuses the input (unknown).
fails() {
	_fl_d=$1
	shift
	if _fl_out=$("$@"); then bad "$_fl_d: accepted ($_fl_out)"; else ok "$_fl_d: unknown"; fi
}
tel_without() { telecom_fixture 2 RINGING | sed "/^$1\$/d" | telecom_state; }
tel_text() { printf '%s\n' "$1" | telecom_state; }
tel_bignum() { telecom_fixture 0 | sed 's/^  Past analytics dumps: $/  Call TC@12345678901: {/' | telecom_state; }
# Android 17 (TelecomServiceImpl on android17-release): no Analytics; the
# event log names calls "CallTC@<n>" without the space.
tel_17() {
	printf '%s\n' 'Init Path:' '  ...' 'CallsManager: ' '  mCalls: ' \
		'    [Call id=TC@1, state=ACTIVE, tpac=***, cmgr=null, handle=tel:***, vidst=A, childs(0), has_parent(false), cap=[ hld], prop=[]], voip=false' \
		'  mCallAudioManager: ' 'PhoneAccountRegistrar: ' 'Flag Configurations (Telecom): ' 'TransactionManager:' \
		'Historical Events:' '  CallTC@1 [2026-10-15 10:00:00.000](MO - outgoing)' | telecom_state "$@"
}
fails "telecom_state: no mCalls list" tel_without '  mCalls: '
fails "telecom_state: no Analytics" tel_without 'Analytics:'
fails "telecom_state: no CallsManager" tel_without 'CallsManager: '
fails "telecom_state: empty input" tel_text ''
fails "telecom_state: a missing service" tel_text "Can't find service: telecom"
fails "telecom_state: an implausible call number" tel_bignum
fails "telecom_state: Android 17 (no Analytics)" tel_17
fails "telecom_state: Android 17, a later look" tel_17 1 1 0
r=$(telecom_fixture 1 RINGING | sed 's/id=TC@1,/id=XY-1,/' | telecom_state)
expect "telecom_state: a call with an unusual id still counts (and cannot be classified)" "1 1 u - 0" "$r"

rs() { registry_fixture "$@" | registry_state; }
I='0 0 0 0 0 0'
expect "registry_state: two idle phones, radio off" "0 0 off" "$(rs 0 "$I")"
expect "registry_state: one phone, radio on" "0 0 on" "$(rs 1 "$I" -)"
expect "registry_state: radio unavailable" "0 0 wait" "$(rs 2 "$I")"
expect "registry_state: ringing (mCallState=1)" "1 0 on" "$(rs 1 '1 5 0 0 0 0')"
expect "registry_state: off-hook (mCallState=2)" "1 0 on" "$(rs 1 '2 0 0 0 0 0')"
expect "registry_state: active (foreground 1)" "1 0 on" "$(rs 1 '0 0 1 0 0 0')"
expect "registry_state: on hold (background 2)" "1 0 on" "$(rs 1 '0 0 0 2 0 0')"
expect "registry_state: dialing (foreground 3)" "1 0 on" "$(rs 1 '0 0 3 0 0 0')"
expect "registry_state: incoming (ringing 5)" "1 0 on" "$(rs 1 '0 5 0 0 0 0')"
expect "registry_state: disconnecting (foreground 8)" "1 0 on" "$(rs 1 '0 0 8 0 0 0')"
expect "registry_state: the second phone busy" "1 0 on" "$(rs 1 "$I" '2 0 1 0 0 0')"
expect "registry_state: disconnected (7) and not valid (-1) are idle" "0 0 on" "$(rs 1 '0 7 -1 7 0 0')"
expect "registry_state: emergency callback mode for calls" "0 1 on" "$(rs 1 '0 0 0 0 300000 0')"
expect "registry_state: emergency callback mode for texts" "0 1 on" "$(rs 1 '0 0 0 0 0 300000')"
reg_second_short() { registry_fixture 0 "$I" "$I" | sed '/Phone Id=1/,$ {/mBackgroundCallState/d;}' | registry_state; }
reg_text() { printf '%s\n' "$1" | registry_state; }
fails "registry_state: no phone" rs 1 - -
fails "registry_state: no mRadioPowerState" rs - "$I"
fails "registry_state: an unknown radio state (3)" rs 3 "$I"
fails "registry_state: a state that is not a number" rs 0 '0 0 x 0 0 0'
fails "registry_state: a field missing for the second phone" reg_second_short
fails "registry_state: empty input" reg_text ''
fails "registry_state: a missing service" reg_text "Can't find service: telephony.registry"
r=$(rs 1 '1 5 0 0 0 0')
case $r in *PLACEHOLDER* | *NUMBER*) bad "registry_state prints the incoming number" ;; *) ok "registry_state never prints the incoming number" ;; esac

expect "ecbm_value true" 1 "$(ecbm_value true)"
expect "ecbm_value false" 0 "$(ecbm_value false)"
expect "ecbm_value unset" 0 "$(ecbm_value '')"
expect "ecbm_value 0" 0 "$(ecbm_value 0)"
expect "ecbm_value 1" 1 "$(ecbm_value 1)"
expect "ecbm_value something else counts as on" 1 "$(ecbm_value maybe)"

# --- phone_proc: the phone process (the real function, on this host's /proc) ---
# A stand-in toybox whose pidof prints FAKE_PIDOF (exits 1 when it is
# empty), and real processes: sleep, and a copy of it whose name holds ") ".
# shellcheck disable=SC2016 # the stand-in's lines, expanded when it runs
printf '%s\n' '#!/bin/sh' '[ "$1 $2" = "pidof com.android.phone" ] || exit 2' \
	'[ -n "${FAKE_PIDOF-}" ] || exit 1' 'echo "$FAKE_PIDOF"' >"$LOGDIR/toybox"
chmod +x "$LOGDIR/toybox"
# pp PIDOF: the library's phone_proc (sourced again in a subshell, over the
# stand-in above) with that answer from pidof; prints what it prints on
# standard output and standard error, then "rc=N", on one line.
pp() {
	(
		_pp_tb=$LOGDIR/toybox
		# The library as sourced above (already checked there), so that
		# this subshell has the real phone_proc and not the stand-in.
		# shellcheck source=/dev/null
		. "$MODULE/lib/antumbra.sh"
		TB=$_pp_tb
		FAKE_PIDOF=$1
		export FAKE_PIDOF
		phone_proc
		echo "rc=$?"
	) 2>&1 | tr '\n' ' ' | sed 's/ $//'
}
# start_of PID: field 22 of /proc/PID/stat (the start time), counted after
# the name.
start_of() { sed 's/.*) //' "/proc/$1/stat" | awk '{ print $20 }'; }
cp /bin/sleep "$LOGDIR/x) 1 2"
sleep 60 &
pp1=$!
"$LOGDIR/x) 1 2" 60 &
pp2=$!
expect "phone_proc: a running process: PID:START (field 22 of its stat)" "$pp1:$(start_of "$pp1") rc=0" "$(pp "$pp1")"
expect "phone_proc: a name with ') ' in it: the fields after the name" "$pp2:$(start_of "$pp2") rc=0" "$(pp "$pp2")"
r=$(pp "$pp1")
case $r in "$pp1:"[1-9]*' rc=0') ok "phone_proc: the start time is a number above 0" ;; *) bad "phone_proc: the start time: [$r]" ;; esac
expect "phone_proc: two processes of that name: not one (rc 1)" "rc=1" "$(pp "$pp1 $pp2")"
expect "phone_proc: not running (pidof exits 1): rc 1" "rc=1" "$(pp '')"
expect "phone_proc: pidof answers something else: rc 1" "rc=1" "$(pp x)"
expect "phone_proc: pidof answers a name /proc has (self): rc 1, not the shell's own" "rc=1" "$(pp self)"
kill "$pp1" "$pp2" 2>/dev/null
wait "$pp1" "$pp2" 2>/dev/null
expect "phone_proc: the process gone before its stat is read: rc 1, nothing on standard error" "rc=1" "$(pp "$pp1")"

# --- The module's word (MOD11): what the calls were ------------------------------------
# tsa SINCE LIVE XN HISTORY STATE...: telecom_state with the last look's
# LASTID, LIVE and XN (empty: the module's first look).
tsa() {
	_ta_s=$1 _ta_l=$2 _ta_x=$3
	shift 3
	telecom_fixture "$@" | telecom_state "$_ta_s" "$_ta_l" "$_ta_x"
}
# hundred FROM TO: the words FROM to TO.
hundred() {
	_hu=$1
	while [ "$_hu" -le "$2" ]; do
		printf '%s ' "$_hu"
		_hu=$((_hu + 1))
	done
}
expect "kind: calls 1 to 3 ordinary, first look" "0 3 o - 0" "$(tsa '' '' '' 3)"
expect "kind: calls 1 to 3 ordinary, all seen at the last look (SINCE 3)" "0 3 - - 0" "$(tsa 3 - 0 3)"
expect "kind: call 4 an emergency call (isEmergency: true)" "0 4 e - 0" "$(tsa 3 - 0 '1 2 3 4:e')"
expect "kind: call 2 an emergency call before the last look, call 4 ordinary" "0 4 o - 0" "$(tsa 3 - 0 '1 2:e 3 4')"
expect "kind: call 4 flagged by the network (ecall in callProperties, isEmergency false)" "0 4 e - 0" \
	"$(tsa 3 - 0 '1 2 3 4:ecall')"
expect "kind: call 4 made in callback mode (ecbm in callProperties)" "0 4 e - 0" "$(tsa 3 - 0 '1 2 3 4:ecbm')"
expect "kind: a live call flagged by the network (prop ecall)" "1 4 e 4 0" "$(tsa 3 - 0 '1 2 3 4' 'ACTIVE:ecall@4')"
expect "kind: a live call in callback mode (prop ecbm)" "1 4 e 4 0" "$(tsa 3 - 0 '1 2 3 4' 'ACTIVE:ecbm@4')"
expect "kind: a live ordinary call, numbered at the last look" "1 4 o 4 0" "$(tsa 4 4 0 '1 2 3 4' 'ON_HOLD@4')"
expect "kind: a live emergency call, numbered at the last look" "1 4 e 4 0" "$(tsa 4 4 0 '1 2 3 4:e' 'ACTIVE@4')"
expect "kind: call 2 listed at the last look, ended, its entry now flagged ecall" "0 3 e - 0" "$(tsa 3 2 0 '1 2:ecall 3')"
expect "kind: call 2 listed at the last look, ended, ordinary" "0 3 o - 0" "$(tsa 3 2 0 3)"
# safety-1: a call first counted at a look (FROM, SINCE] is read again at
# the next; it stays in scope while it is listed or its entry has not
# ended (LIVE carries both), and leaves the scope only once a look sees it
# unlisted and ended. Telecom prints its call list before Analytics,
# without a lock: an entry can be seen while its call is not listed yet.
# tsf SINCE LIVE XN FROM HISTORY STATE...: tsa with the last look's FROM.
tsf() {
	_tf_s=$1 _tf_l=$2 _tf_x=$3 _tf_f=$4
	shift 4
	telecom_fixture "$@" | telecom_state "$_tf_s" "$_tf_l" "$_tf_x" "$_tf_f"
}
expect "scope: look k, call 4 in Analytics only (not listed yet), open: ordinary so far, kept in LIVE" "0 4 o 4 0" \
	"$(tsf 3 - 0 2 '1 2 3 4:open')"
expect "scope: look k+1, call 4 ended, its entry now flagged ecall: emergency" "0 4 e - 0" "$(tsf 4 - 0 3 '1 2 3 4:ecall')"
expect "scope: look k+1, call 4 ended, its entry now isEmergency: true: emergency" "0 4 e - 0" "$(tsf 4 - 0 3 '1 2 3 4:e')"
expect "scope: look k+1, call 4 ended (kept in LIVE), its entry now flagged ecall: emergency" "0 4 e - 0" \
	"$(tsf 4 4 0 3 '1 2 3 4:ecall')"
expect "scope: look k+1, call 4 not listed and still open: unknown, kept" "0 4 u 4 0" "$(tsf 4 4 0 3 '1 2 3 4:open')"
expect "scope: look k+1, call 4 not listed, still open, ecall so far: unknown, kept (read once listed or ended)" \
	"0 4 u 4 0" "$(tsf 4 4 0 3 '1 2 3 4:ecall+open')"
expect "scope: look k+1, call 4 not listed, still open, isEmergency: true so far: unknown, kept" "0 4 u 4 0" \
	"$(tsf 4 4 0 3 '1 2 3 4:e+open')"
expect "scope: look k+1, call 4 ended, ordinary: ordinary" "0 4 o - 0" "$(tsf 4 4 0 3 '1 2 3 4')"
expect "scope: look k+1, call 4 listed now (open): ordinary, in LIVE" "1 4 o 4 0" "$(tsf 4 4 0 3 '1 2 3 4:open' 'ACTIVE@4')"
expect "scope: look k+1, call 4 listed now, isEmergency: true: emergency" "1 4 e 4 0" \
	"$(tsf 4 4 0 3 '1 2 3 4:e+open' 'ACTIVE@4')"
# The finding the scope rule was changed for: the entry open and not
# listed at three looks and more; it must stay in scope until a look reads
# it ended.
expect "scope: look k+2, call 4 below FROM, kept in LIVE, still not listed and open: unknown, kept" "0 4 u 4 0" \
	"$(tsf 4 4 0 4 '1 2 3 4:open')"
expect "scope: look k+3, ... the same: unknown, kept" "0 4 u 4 0" "$(tsf 4 4 0 4 '1 2 3 4:open')"
expect "scope: ... then ended between two looks, flagged ecall: emergency, out of LIVE" "0 4 e - 0" \
	"$(tsf 4 4 0 4 '1 2 3 4:ecall')"
expect "scope: ... or ended, ordinary: ordinary" "0 4 o - 0" "$(tsf 4 4 0 4 '1 2 3 4')"
expect "scope: ... or listed at last: read by its entry, in LIVE" "1 4 e 4 0" "$(tsf 4 4 0 4 '1 2 3 4:ecall+open' 'ACTIVE@4')"
expect "scope: ... a call new at this look beside it: unknown, both kept" "0 5 u 4,5 0" \
	"$(tsf 4 4 0 4 '1 2 3 4:open 5:open')"
expect "scope: a kept call whose entry is gone (Telecom keeps 100): unknown, then no longer kept" "0 5 u - 0" \
	"$(tsf 5 4 0 5 '1 2 3 4:gone 5')"
expect "scope: an open entry below FROM, not kept, not listed: unknown, kept from now on" "0 4 u 3 0" \
	"$(tsf 4 - 0 4 '1 2 3:open 4')"
expect "scope: look k+2, call 4 read after its end at k+1: out of scope" "0 4 - - 0" "$(tsf 4 - 0 4 '1 2 3 4:ecall')"
expect "scope: listed at the last look, not now, still open: unknown, kept" "0 4 u 4 0" "$(tsf 4 4 0 4 '1 2 3 4:open')"
expect "scope: listed at the last look, not now, ended: ordinary" "0 4 o - 0" "$(tsf 4 4 0 4 '1 2 3 4')"
expect "scope: listed at the last look, not now, still open, no FROM given: unknown, kept" "0 4 u 4 0" \
	"$(tsa 4 4 0 '1 2 3 4:open')"
expect "scope: listed now and open: ordinary" "1 4 o 4 0" "$(tsf 4 4 0 4 '1 2 3 4:open' 'ACTIVE@4')"
expect "scope: unknown: an entry in scope without endTime (kept: it may not have ended)" "0 4 u 4 0" \
	"$(tsf 3 - 0 3 '1 2 3 4:noend')"
expect "scope: unknown: an entry in scope with endTime: soon" "0 4 u 4 0" "$(tsf 3 - 0 3 '1 2 3 4:badend')"
# tel_end4 TEXT: calls 1 to 4, call 4's endTime line replaced by TEXT (\n
# for two lines), read with SINCE 3, LIVE -, XN 0, FROM 3.
tel_end4() {
	telecom_fixture '1 2 3 4' | sed "/^  Call TC@4: {\$/,/^  }\$/s/^      endTime: .*\$/      $1/" | telecom_state 3 - 0 3
}
expect "scope: unknown: an entry with two endTime lines" "0 4 u 4 0" "$(tel_end4 'endTime: 1\n      endTime: 1')"
expect "scope: unknown: a negative endTime" "0 4 u 4 0" "$(tel_end4 'endTime: -5')"
expect "scope: unknown: an endTime with a leading 0" "0 4 u 4 0" "$(tel_end4 'endTime: 01')"
expect "scope: unknown: an endTime of digits and more ('1760000000000 (pending)')" "0 4 u 4 0" \
	"$(tel_end4 'endTime: 1760000000000 (pending)')"
expect "scope: unknown: an endTime with a unit ('5s')" "0 4 u 4 0" "$(tel_end4 'endTime: 5s')"
expect "scope: an endTime of 13 digits: ended, ordinary" "0 4 o - 0" "$(tel_end4 'endTime: 1760000000000')"
expect "scope: an old entry without endTime (it may not have ended): unknown, kept" "0 4 u 2 0" \
	"$(tsf 3 - 0 3 '1 2:noend 3 4')"
expect "scope: unknown: a call first counted at the last look, its entry gone" "0 5 u - 0" "$(tsf 5 - 0 3 '1 2 3 4:gone 5')"
expect "scope: unknown: FROM above SINCE" "0 4 u - 0" "$(tsf 4 - 0 5 '1 2 3 4')"
expect "scope: unknown: FROM not a number" "0 4 u - 0" "$(tsf 4 - 0 x '1 2 3 4')"
expect "scope: unknown: FROM of ten digits" "0 4 u - 0" "$(tsf 4 - 0 1234567890 '1 2 3 4')"
expect "scope: FROM 0 (after the first look): every call read again, ordinary" "0 4 o - 0" "$(tsf 4 - 0 0 '1 2 3 4')"
expect "scope: FROM 0: an old call never ended (dropped before Telecom listed it): unknown, kept" "0 4 u 2 0" \
	"$(tsf 4 - 0 0 '1 2:open 3 4')"
expect "scope: Telecom restarted (SINCE above LASTID): every entry read, unknown" "0 2 u - 0" "$(tsf 9 - 0 7 2)"
expect "scope: call 5 new, call 4 read again: both ordinary, 5 kept" "0 5 o 5 0" "$(tsf 4 - 0 3 '1 2 3 4 5:open')"
expect "scope: call 5 new and emergency, call 4 read again" "0 5 e 5 0" "$(tsf 4 - 0 3 '1 2 3 4 5:e+open')"
expect "kind: a missed call (missedReason: [emergency]) is ordinary" "0 4 o - 0" "$(tsa 3 - 0 '1 2 3 4:missed')"
expect "kind: a VoIP call through Telecom is ordinary" "1 4 o 4 0" "$(tsa 3 - 0 4 'ACTIVE:voip@4')"
expect "kind: unknown: the entry of call 3 is missing (SINCE 2)" "0 4 u - 0" "$(tsa 2 - 0 '1 2 3:gone 4')"
expect "kind: unknown: a live call without an entry" "1 5 u 5 0" "$(tsa 4 - 0 4 'DIALING@5')"
expect "kind: unknown: call 2 listed at the last look, its entry gone" "0 3 u - 0" "$(tsa 3 2 0 '1 2:gone 3')"
expect "kind: unknown: an entry without isEmergency" "0 4 u - 0" "$(tsa 3 - 0 '1 2 3 4:-')"
expect "kind: unknown: isEmergency: maybe" "0 4 u - 0" "$(tsa 3 - 0 '1 2 3 4:x')"
expect "kind: unknown: an entry without callProperties" "0 4 u - 0" "$(tsa 3 - 0 '1 2 3 4:np')"
expect "kind: unknown: two isEmergency lines" "0 4 u - 0" "$(tsa 3 - 0 '1 2 3 4:2')"
expect "kind: emergency beats unknown" "0 5 e - 0" "$(tsa 3 - 0 '1 2 3 4:x 5:e')"
r=$(telecom_fixture 4 'ACTIVE@4' | sed 's/id=TC@4,/id=XY-1,/' | telecom_state 3 - 0)
expect "kind: unknown: a live call whose id is not TC@<number>" "1 4 u - 0" "$r"
r=$(telecom_fixture 4 'ACTIVE@4' | sed 's/ prop=\[\]\]/]/' | telecom_state 3 - 0)
expect "kind: unknown: a live call without prop=" "1 4 u 4 0" "$r"
expect "kind: unknown: Telecom restarted (SINCE 9 above LASTID 3)" "0 3 u - 0" "$(tsa 9 - 0 3)"
expect "kind: unknown: Telecom's Analytics cleared (SINCE 3, no entry)" "0 0 u - 0" "$(tsa 3 - 0 0)"
expect "kind: unknown: first look, 101 calls, 100 entries kept" "0 101 u - 0" "$(tsa '' '' '' "$(hundred 2 101)")"
expect "kind: first look, 100 calls, all kept" "0 100 o - 0" "$(tsa '' '' '' 100)"
expect "kind: unknown: a new entry without a TC@ number (a conference part)" "0 3 u - 1" "$(tsa 3 - 0 '1 2 3 id:TC@2_1')"
expect "kind: the same entry without a number at the next look: ordinary" "0 4 o - 1" "$(tsa 3 - 1 '1 2 3 4 id:TC@2_1')"
expect "kind: unknown: such an entry on the first look" "0 2 u - 1" "$(tsa '' '' '' '1 2 id:com.example.voip@1')"
expect "kind: unknown: such an entry once Telecom keeps 100" "0 101 u - 1" \
	"$(tsa 101 - 1 "$(hundred 3 101) id:com.example.voip@1")"
expect "kind: unknown: a SINCE that is not a number" "0 3 u - 0" "$(tsa x - 0 3)"
# A dump cut short (dumpsys gave up, 'timeout' ended it, Telecom was busy):
# Analytics lists the newest call last, so a cut loses it first. Without
# the end of Analytics the dump is refused (unknown), never "no new call".
# tel_cut ADDRESS: call 4, an emergency call, in Analytics; SINCE 3; the
# dump cut just before the line ADDRESS (a sed address; empty: the whole
# dump).
tel_cut() { telecom_fixture '1 2 3 4:e' | sed "${1:+$1,\$d}" | telecom_state 3 - 0; }
tel_no_end() { telecom_fixture '1 2 3 4:e' | sed '/^  Hardware Version: $/d' | telecom_state 3 - 0; }
expect "kind: the whole dump, call 4 an emergency call (SINCE 3)" "0 4 e - 0" "$(tel_cut '')"
fails "kind: a dump cut between two entries (before call 4's)" tel_cut '/^  Call TC@4: {$/'
fails "kind: a dump cut inside an entry" tel_cut '/^      isEmergency: true$/'
fails "kind: a dump cut just after the last entry's '}'" tel_cut '/^  CSW.aC: /'
fails "kind: a dump without the end of Analytics" tel_no_end
# tel_cut_bytes MARK N: the dump cut N bytes after the start of the line
# MARK (a sed address), with no newline at its end.
tel_cut_bytes() {
	_tb=$(telecom_fixture '1 2 3 4:e' | sed "$1,\$d" | wc -c)
	telecom_fixture '1 2 3 4:e' | head -c $((_tb + $2)) | telecom_state 3 - 0
}
fails "kind: a dump cut inside its end line, without a final newline" tel_cut_bytes '/^  Hardware Version: $/' 10
# The last entry's "  }" and the empty line after it are 4 bytes from CSW.
fails "kind: a dump cut right after the last '}', without its newline" tel_cut_bytes '/^  CSW.aC: /' -4
# tel_timeout ADDRESS: tel_cut ADDRESS, then dumpsys's own line when it
# gives up.
tel_timeout() {
	telecom_fixture '1 2 3 4:e' | sed "$1,\$d" | {
		cat
		printf '\n%s\n\n' "*** SERVICE 'telecom' DUMP TIMEOUT (3000ms) EXPIRED ***"
	} | telecom_state 3 - 0
}
fails "kind: dumpsys gave up between two entries" tel_timeout '/^  Call TC@4: {$/'
fails "kind: dumpsys gave up after Analytics" tel_timeout '/^Flag Configurations: $/'
expect "kind: a dump that ends after Analytics still counts (every entry is in)" "0 4 e - 0" \
	"$(tel_cut '/^Flag Configurations: $/')"
expect "kind: ... ordinary calls likewise" "0 4 o - 0" "$(telecom_fixture 4 | sed '/^  Past analytics dumps: $/,$d' | telecom_state 3 - 0)"
r=$(tsa '' '' '' '1 2:e 3:ecall 4:missed' 'ACTIVE:ecall@4' 'RINGING@5')
case $r in
*tel:* | *[!0-9a-z,\ -]*) bad "kind: the output holds only numbers and letters ($r)" ;;
*) ok "kind: the output holds only numbers and letters" ;;
esac

# --- The cell radio: holds ---------------------------------------------------------------
# hold NOW CALL CBM LAST: cell_hold's answer ("free" when nothing holds).
hold() {
	CL_CALL=$2 CL_CBM=$3 CELL_LAST=$4
	cell_hold "$1" || echo free
}
expect "cell_hold: a call" call "$(hold 1000 1 0 '')"
expect "cell_hold: callback mode" callback "$(hold 1000 0 1 '')"
expect "cell_hold: the call state unknown" unknown "$(hold 1000 unknown 0 '')"
expect "cell_hold: callback mode unknown" unknown "$(hold 1000 0 unknown '')"
expect "cell_hold: no time since boot (NOW 0)" unknown "$(hold 0 0 0 '')"
expect "cell_hold: an event 200 s ago" recent "$(hold 1200 0 0 1000)"
expect "cell_hold: an event 299 s ago" recent "$(hold 1299 0 0 1000)"
expect "cell_hold: an event 300 s ago: released" free "$(hold 1300 0 0 1000)"
expect "cell_hold: the clock below the event" recent "$(hold 900 0 0 1000)"
expect "cell_hold: nothing" free "$(hold 1000 0 0 '')"
expect "cell_hold: unknown before call" unknown "$(hold 1000 unknown 1 1000)"
expect "cell_hold: call before callback" call "$(hold 1000 1 1 1000)"
expect "cell_hold: callback before recent" callback "$(hold 1000 0 1 1000)"

# note NOW CALL CBM ID RADIO: cell_note on a look, then print CELL_LAST.
note() {
	CL_CALL=$2 CL_CBM=$3 CL_ID=$4 CL_RADIO=$5 CL_KIND=- CL_ALONE=0 CL_LIVE=- CL_XN=0 CL_PHONE=$FAKE_PROC
	cell_note "$1"
	echo "${CELL_LAST:-none}"
}
cell_fresh() {
	CELL_LAST='' CELL_BUSY=0 CELL_ID='' CELL_RADIO='' CELL_MINE_AT=''
	CELL_LIVE='' CELL_XN='' CELL_EM_AT='' CELL_UNK_AT='' CELL_EM_SEEN=0 CELL_UNK_SEEN=0
	CELL_FROM='' CELL_PHONE='' FAKE_PROC=1234:5678
}
cell_fresh
expect "cell_note: first look, no call ever" none "$(note 100 0 0 0 off)"
cell_fresh
note 100 0 0 2 off >/dev/null
expect "cell_note: first look, calls earlier in this boot" 100 "$CELL_LAST"
cell_fresh
note 100 0 0 2 off >/dev/null
CELL_LAST=
note 110 0 0 2 off >/dev/null
expect "cell_note: the same call number again" "" "$CELL_LAST"
note 120 0 0 3 off >/dev/null
expect "cell_note: the call number moved up (a short call between looks)" 120 "$CELL_LAST"
note 130 0 0 1 off >/dev/null
expect "cell_note: the call number moved down (Telecom restarted)" 130 "$CELL_LAST"
cell_fresh
note 100 0 0 0 off >/dev/null
note 110 0 0 0 on >/dev/null
expect "cell_note: the radio came on by something else" 110 "$CELL_LAST"
cell_fresh
note 100 0 0 0 off >/dev/null
CELL_MINE_AT=105
note 110 0 0 0 on >/dev/null
expect "cell_note: the radio came on by the module (Phone mode)" "" "$CELL_LAST"
cell_fresh
note 100 1 0 1 on >/dev/null
note 110 1 0 1 on >/dev/null
expect "cell_note: a call: the event is now" 110 "$CELL_LAST"
note 120 0 0 1 on >/dev/null
expect "cell_note: the call is over: its end counts from this look" 120 "$CELL_LAST"
note 130 0 0 1 on >/dev/null
expect "cell_note: no new event after that" 120 "$CELL_LAST"
cell_fresh
note 100 unknown unknown '' unknown >/dev/null
expect "cell_note: nothing readable counts as a call" 100 "$CELL_LAST"
note 140 0 0 0 off >/dev/null
expect "cell_note: readable again: 5 minutes from then" 140 "$CELL_LAST"
# FROM: the last readable look's counter, so that the calls it first
# counted are read once more (safety-1).
cell_fresh
note 100 0 0 3 off >/dev/null
expect "cell_note: FROM after the first look: 0 (every call read again)" 0 "$CELL_FROM"
note 110 0 0 5 off >/dev/null
expect "cell_note: FROM: the counter at the look before" 3 "$CELL_FROM"
note 120 unknown unknown '' unknown >/dev/null
expect "cell_note: FROM: an unreadable look changes nothing" "3/5" "$CELL_FROM/$CELL_ID"
note 130 0 0 5 off >/dev/null
expect "cell_note: FROM: the counter unchanged: nothing read again from then on" 5 "$CELL_FROM"
note 140 0 0 2 off >/dev/null
expect "cell_note: FROM: the counter went down (Telecom restarted): 0" 0 "$CELL_FROM"
# LIVE: a call not over at the last look (listed, or its entry not ended)
# that is over now ended between the two looks: an event (a call listed
# only between two looks, its entry open and unlisted at the looks before).
cell_fresh
note 100 0 0 4 off >/dev/null
CELL_LAST='' CELL_LIVE=4
CL_CALL=0 CL_CBM=0 CL_ID=4 CL_RADIO=off CL_KIND=u CL_ALONE=0 CL_LIVE=4 CL_XN=0 CL_PHONE=$FAKE_PROC
cell_note 110
expect "cell_note: a call still not over (its entry open, not listed): no event" "" "$CELL_LAST"
note 120 0 0 4 off >/dev/null
expect "cell_note: ... over now (its entry read ended, or gone): the event is now" 120 "$CELL_LAST"
expect "cell_note: ... and LIVE as this look printed it" - "$CELL_LIVE"

# --- The module's word (MOD11): the last 5 minutes ----------------------------------
# word NOW CALL CBM KIND ID [RADIO [ALONE]]: a look (CL_*, as cell_look sets
# them) taken into the watch at NOW, the records past their 5 minutes
# forgotten, and the word printed.
word() {
	CL_CALL=$2 CL_CBM=$3 CL_KIND=$4 CL_ID=$5 CL_RADIO=${6:-off} CL_ALONE=${7:-0} CL_LIVE=- CL_XN=0 CL_PHONE=$FAKE_PROC
	cell_note "$1"
	cell_forget "$1"
	cell_word "$1"
}
records() { echo "${CELL_LAST:--}/${CELL_EM_AT:--}/${CELL_UNK_AT:--}"; }
# wx DESCRIPTION EXPECTED NOW CALL CBM KIND ID [RADIO [ALONE]]: word in this
# shell (the watch keeps its state from one look to the next), checked.
wx() {
	_wx_d=$1 _wx_e=$2
	shift 2
	word "$@" >"$LOGDIR/word"
	expect "$_wx_d" "$_wx_e" "$(cat "$LOGDIR/word")"
}
# phone_mode on|off: a Phone-mode session with the module's switch-on done
# (the only place a call can read ordinary), or a session that keeps the
# radio off (every session until WEL8).
phone_mode() {
	if [ "$1" = on ]; then
		S_STARTED=1 SES_CELL=phone CELL_ON_DONE=1 RADIOS=''
	else
		S_STARTED=1 SES_CELL=off CELL_ON_DONE=0 RADIOS=''
	fi
}
phone_mode on
cell_fresh
wx "word: no call in this boot: none" "none 0" 100 0 0 - 0
cell_fresh
word 100 1 0 o 1 >/dev/null
wx "word: ordinary: an ordinary call in progress" "ordinary 0" 110 1 0 o 1
wx "word: ordinary: the call ended (seen at this look)" "ordinary 0" 120 0 0 o 1
wx "word: ordinary: 299 s after the look that saw the end" "ordinary 0" 419 0 0 - 1
wx "word: ordinary: none 300 s after it" "none 0" 420 0 0 - 1
expect "word: ordinary: then nothing is kept about the call" "-/-/-" "$(records)"
cell_fresh
word 100 0 0 - 3 >/dev/null
wx "word: ordinary: a short call between two looks (Telecom's counter moved)" "ordinary 0" 110 0 0 o 4
cell_fresh
wx "word: emergency: an emergency call in progress" "emergency 400" 100 1 0 e 1
wx "word: emergency: still in progress" "emergency 410" 110 1 0 e 1
wx "word: emergency: the call ended (its entry, at this look)" "emergency 420" 120 0 0 e 1
wx "word: emergency: 5 minutes from the look after the end" "emergency 430" 130 0 0 - 1
wx "word: emergency: 299 s after it" "emergency 430" 429 0 0 - 1
wx "word: emergency: none 300 s after it" "none 0" 430 0 0 - 1
expect "word: emergency: then nothing is kept about the call" "-/-/-" "$(records)"
cell_fresh
word 100 0 0 - 0 >/dev/null
wx "word: emergency: callback mode now" "emergency 410" 110 0 1 - 0
wx "word: emergency: callback mode over" "emergency 420" 120 0 0 - 0
wx "word: emergency: 299 s after the look that saw callback mode end" "emergency 420" 419 0 0 - 0
wx "word: emergency: 300 s after it" "none 0" 420 0 0 - 0
cell_fresh
word 100 0 0 - 1 >/dev/null
wx "word: unknown: a call that cannot be classified" "unknown 0" 110 0 0 u 2
wx "word: unknown: the look after it" "unknown 0" 120 0 0 - 2
wx "word: unknown: 299 s after that look" "unknown 0" 419 0 0 - 2
wx "word: unknown: none 300 s after it" "none 0" 420 0 0 - 2
cell_fresh
wx "word: unknown: the call state cannot be read" "unknown 0" 100 unknown unknown unknown ''
wx "word: unknown: readable again, for 5 minutes" "unknown 0" 110 0 0 - 0
wx "word: unknown: ... none after them" "none 0" 410 0 0 - 0
cell_fresh
wx "word: unknown: callback mode cannot be read" "unknown 0" 100 0 unknown - 0
wx "word: unknown: callback mode readable again: the look after" "unknown 0" 110 0 0 - 0
wx "word: unknown: ... 299 s after that look" "unknown 0" 409 0 0 - 0
wx "word: unknown: ... none 300 s after it" "none 0" 410 0 0 - 0
cell_fresh
wx "word: unknown: Telecom cannot be read" "unknown 0" 100 0 0 unknown ''
cell_fresh
word 100 0 0 - 0 off >/dev/null
wx "word: unknown: the radio on by something else, no call (an emergency text)" "unknown 0" 110 0 0 - 0 on
cell_fresh
word 100 0 0 - 0 off >/dev/null
CELL_MINE_AT=105
wx "word: the radio on by the module (Phone mode): none" "none 0" 110 0 0 - 0 on
cell_fresh
wx "word: unknown: a call in the registry that Telecom does not list" "unknown 0" 100 1 0 - 0 off 1
cell_fresh
wx "word: unknown: no time since boot (NOW 0)" "unknown 0" 0 0 0 - 0
cell_fresh
word 100 0 0 - 1 >/dev/null
word 110 0 0 u 2 >/dev/null
wx "word: emergency before unknown" "emergency 420" 120 0 0 e 3
cell_fresh
word 100 0 0 - 1 >/dev/null
word 110 0 0 u 2 >/dev/null
wx "word: unknown before ordinary" "unknown 0" 120 0 0 o 3
wx "word: unknown before ordinary, a later ordinary call" "unknown 0" 300 0 0 o 4
wx "word: unknown before ordinary, 5 minutes after the doubt: still unknown (the later call renewed it)" \
	"unknown 0" 420 0 0 - 4
wx "word: ... until 5 minutes after the later call" "unknown 0" 599 0 0 - 4
wx "word: ... then none, never ordinary" "none 0" 600 0 0 - 4
cell_fresh
word 100 0 0 e 1 >/dev/null
wx "word: an ordinary call during an emergency's 5 minutes: emergency" "emergency 420" 120 0 0 o 2
# android-1 (b): a sign or a doubt still kept lasts until 5 minutes after
# the look that saw the last call end, not 5 minutes after it was seen.
cell_fresh
word 100 0 0 - 0 >/dev/null
wx "word (b): callback mode" "emergency 410" 110 0 1 - 0
wx "word (b): ... over, an ordinary call begins" "emergency 420" 120 1 0 o 1
t=130
while [ "$t" -lt 400 ]; do
	word "$t" 1 0 o 1 >/dev/null
	t=$((t + 10))
done
wx "word (b): ... the call lasts past callback mode's 5 minutes: still emergency, its end moving on" \
	"emergency 700" 400 1 0 o 1
wx "word (b): ... the call ended (this look saw it)" "emergency 710" 410 0 0 o 1
wx "word (b): ... 299 s after the look that saw the end" "emergency 710" 709 0 0 - 1
wx "word (b): ... 300 s after it: none" "none 0" 710 0 0 - 1
cell_fresh
word 100 0 0 - 3 >/dev/null
wx "word (b): a call that cannot be classified" "unknown 0" 110 0 0 u 4
wx "word (b): ... a 6-minute ordinary call begins 200 s later" "unknown 0" 300 1 0 o 5
t=310
while [ "$t" -lt 660 ]; do
	word "$t" 1 0 o 5 >/dev/null
	t=$((t + 10))
done
wx "word (b): ... more than 5 minutes after the doubt, during the call: unknown" "unknown 0" 660 1 0 o 5
wx "word (b): ... the call ended: unknown" "unknown 0" 670 0 0 o 5
wx "word (b): ... 299 s after the look that saw the end: unknown" "unknown 0" 969 0 0 - 5
wx "word (b): ... 300 s after it: none, never ordinary" "none 0" 970 0 0 - 5
cell_fresh
word 100 0 0 u 1 >/dev/null
word 110 0 0 - 1 >/dev/null
wx "word (b): a doubt with no call after it: none 5 minutes after the look after it" "none 0" 410 0 0 - 1
wx "word (b): ... a later ordinary call is not covered by the old doubt: ordinary" "ordinary 0" 420 0 0 o 2
# The same without a look in between: cell_note forgets a record past its 5
# minutes before the event could renew it.
cell_fresh
word 100 0 0 u 1 >/dev/null
word 110 0 0 - 1 >/dev/null
wx "word (b): a doubt past its 5 minutes at the next look, which sees a new call: not renewed, ordinary" \
	"ordinary 0" 420 0 0 o 2
# android-1 (a): outside Phone mode the cell radio is off by design, so a
# carrier call there is an emergency call, a Wi-Fi call (switched off by
# MOD7 and stopped by the firewall, both unverified on the phone) or
# follows a switch-on by something else, which the module cannot tell
# apart: every call reads unknown.
for m in 'S_STARTED=0' 'SES_CELL=off' 'RADIOS=waiting' 'RADIOS=switched' 'CELL_ON_DONE=0'; do
	cell_fresh
	phone_mode on
	eval "$m"
	word 100 0 0 - 3 >/dev/null
	wx "word (a): outside Phone mode ($m): a short ordinary call: unknown" "unknown 0" 110 0 0 o 4
done
phone_mode off
cell_fresh
word 100 0 0 - 0 >/dev/null
wx "word (a): outside Phone mode: an ordinary call in progress: unknown" "unknown 0" 110 1 0 o 1
wx "word (a): ... the call ended: unknown" "unknown 0" 120 0 0 o 1
wx "word (a): ... the look after the end: unknown" "unknown 0" 130 0 0 - 1
wx "word (a): ... 299 s after it: unknown" "unknown 0" 429 0 0 - 1
wx "word (a): ... then none" "none 0" 430 0 0 - 1
cell_fresh
word 100 0 0 - 1 >/dev/null
wx "word (a): outside Phone mode: an emergency call still reads emergency" "emergency 410" 110 0 0 e 2
cell_fresh
wx "word (a): outside Phone mode: no call: none" "none 0" 100 0 0 - 0
phone_mode on
# android-1 (c): the phone process not running, or another one than at the
# last look: Telecom's emergency check can fail then.
cell_fresh
wx "word (c): the phone process at the first look of the boot: none" "none 0" 100 0 0 - 0
FAKE_PROC=999:1
wx "word (c): another phone process (restarted), no call: unknown" "unknown 0" 110 0 0 - 0
expect "word (c): ... not a call-like event (nothing for MOD6 to hold)" "-/-/110" "$(records)"
wx "word (c): ... the same one at the next look: still unknown (the look after)" "unknown 0" 120 0 0 - 0
wx "word (c): ... 299 s after that look" "unknown 0" 419 0 0 - 0
wx "word (c): ... 300 s after it: none" "none 0" 420 0 0 - 0
expect "word (c): ... then nothing is kept" "-/-/-" "$(records)"
cell_fresh
word 100 0 0 - 0 >/dev/null
FAKE_PROC=1234:9999
wx "word (c): the same pid, another start time (a new process): unknown" "unknown 0" 110 0 0 - 0
cell_fresh
word 100 0 0 - 0 >/dev/null
FAKE_PROC=-
wx "word (c): the phone process not running: unknown" "unknown 0" 110 0 0 - 0
cell_fresh
FAKE_PROC=-
wx "word (c): ... not running at the first look of the boot: unknown" "unknown 0" 100 0 0 - 0
cell_fresh
CELL_RADIO=on
word 100 0 0 - 3 on >/dev/null
FAKE_PROC=999:1
word 110 0 0 - 3 on >/dev/null
wx "word (c)+(b): a restart, then an ordinary call 200 s later: unknown" "unknown 0" 300 1 0 o 4 on
t=310
while [ "$t" -lt 670 ]; do
	word "$t" 1 0 o 4 on >/dev/null
	t=$((t + 10))
done
wx "word (c)+(b): ... the call ended 6 minutes later: unknown" "unknown 0" 670 0 0 o 4 on
wx "word (c)+(b): ... 299 s after the look that saw the end: unknown" "unknown 0" 969 0 0 - 4 on
wx "word (c)+(b): ... 300 s after it: none, never ordinary" "none 0" 970 0 0 - 4 on
FAKE_PROC=1234:5678
cell_fresh
word 100 1 0 e 1 >/dev/null
CELL_EM_AT=0 CELL_EM_SEEN=0
expect "word: a clock below the record clears nothing" "emergency 300" "$(CELL_LAST=500; cell_forget 0; cell_word 1)"

# decide NOW AIR OFF_FOR NARROW LOOK_AGE CALL RADIO [WANT]: cell_decide in a
# given state (WANT: off, phone (started), failsafe).
decide() {
	CELL_AIR=$2 CELL_AIR_OFF_AT=$(($1 - $3)) CELL_NARROW=$4 CELL_LOOKED=$(($1 - $5))
	CL_CALL=$6 CL_CBM=0 CL_RADIO=$7 CELL_LAST='' CELL_TRY_AT='' CELL_ON_DONE=0
	RADIOS='' S_STARTED=0 SES_CELL=off
	case ${8:-off} in
	phone) S_STARTED=1 SES_CELL=phone ;;
	failsafe) RADIOS=waiting ;;
	esac
	cell_decide "$1"
}
expect "cell_decide: airplane mode unreadable" none "$(decide 1000 '' 100 1 0 0 on)"
expect "cell_decide: the radio on, list not narrowed, airplane off 5 s" "wait narrow" "$(decide 1000 0 5 0 0 0 on)"
expect "cell_decide: airplane off 30 s: narrow first" narrow "$(decide 1000 0 30 0 0 0 on)"
expect "cell_decide: narrowed, radio on, nothing holds, fresh look" off "$(decide 1000 0 100 1 0 0 on)"
expect "cell_decide: ... a look 3 s old: look again first" look "$(decide 1000 0 100 1 3 0 on)"
expect "cell_decide: ... a look 2 s old (the turn before): look again first" look "$(decide 1000 0 100 1 2 0 on)"
expect "cell_decide: ... a look 1 s old: look again first" look "$(decide 1000 0 100 1 1 0 on)"
expect "cell_decide: ... the fail-safe with a look from the turn before: look again first" look \
	"$(decide 1000 0 100 1 2 0 on failsafe)"
expect "cell_decide: ... Phone mode's switch-on with a look from the turn before: look again first" look \
	"$(decide 1000 0 100 1 2 0 off phone)"
expect "cell_decide: ... during a call" "held call" "$(decide 1000 0 100 1 0 1 on)"
expect "cell_decide: ... during a call, an old look: held (no new look needed)" "held call" "$(decide 1000 0 100 1 9 1 on)"
expect "cell_decide: radio off" none "$(decide 1000 0 100 1 0 0 off)"
expect "cell_decide: radio unavailable" none "$(decide 1000 0 100 1 0 0 wait)"
expect "cell_decide: radio unknown" "held unknown" "$(decide 1000 0 100 1 0 unknown unknown)"
expect "cell_decide: airplane mode on" none "$(decide 1000 1 0 1 0 0 off)"
expect "cell_decide: Phone mode, airplane on, list not narrowed: power" power "$(decide 1000 1 0 0 0 0 off phone)"
expect "cell_decide: Phone mode, airplane off 5 s, not narrowed" "wait narrow" "$(decide 1000 0 5 0 0 0 off phone)"
expect "cell_decide: Phone mode, narrowed, radio off" power "$(decide 1000 0 100 1 0 0 off phone)"
expect "cell_decide: Phone mode, radio already on" keys "$(decide 1000 0 100 1 0 0 on phone)"
expect "cell_decide: fail-safe before the list is narrowed" failsafe "$(decide 1000 0 5 0 0 0 off failsafe)"
expect "cell_decide: fail-safe during a call" "held call" "$(decide 1000 0 5 0 0 1 on failsafe)"
CELL_LOOKED=''
expect "cell_decide: no look yet" look "$(CELL_AIR=0 cell_decide 1000)"

# --- The cell radio: the watch, turn by turn ----------------------------------------
# Stand-ins for Android: the Settings.Global store (a file), airplane mode
# as ConnectivityService and the phone process (PhoneGlobals) handle it,
# the dumps from variables, and every action recorded in STEPS.
G=$LOGDIR/global
STEPS=$LOGDIR/steps
settings_put() {
	echo "put $1 $2" >>"$STEPS"
	{
		grep -v "^$1=" "$G"
		printf '%s=%s\n' "$1" "$2"
	} >"$G.new"
	mv -f "$G.new" "$G"
}
setting_get() {
	[ -z "${FAKE_NO_SETTINGS-}" ] || return 1
	sed -n "s/^$1=//p" "$G"
}
fake_set() { # KEY VALUE, as Android itself writes it (not recorded)
	{
		grep -v "^$1=" "$G"
		printf '%s=%s\n' "$1" "$2"
	} >"$G.new"
	mv -f "$G.new" "$G"
}
airplane_set() {
	echo "airplane $1" >>"$STEPS"
	_as_cell=$(setting_get cell_on)
	_as_list=$(setting_get airplane_mode_radios)
	case $1 in
	enable)
		fake_set airplane_mode_on 1
		case $_as_list in '' | *cell*)
			if [ "${_as_cell:-1}" = 1 ]; then
				fake_set cell_on 2
				fake_set enable_cellular_on_boot 0
				FAKE_RADIO=0
			fi
			;;
		esac
		;;
	disable)
		fake_set airplane_mode_on 0
		if [ "$_as_cell" = 2 ]; then
			fake_set cell_on 1
			fake_set enable_cellular_on_boot 1
			FAKE_RADIO=1
		fi
		;;
	esac
}
# phone_restart: the phone process starts again (a crash, or a restart of
# system_server), as in Android 16: a new process (pid and start time);
# ServiceStateTracker reads enable_cellular_on_boot (unset: on) and
# airplane mode once, and keeps the radio off unless the first is not 0
# and the second is off; PhoneGlobals, with cell_on 2 and airplane mode
# off, switches it on (and stores 1).
phone_restart() {
	FAKE_PROC=$((${FAKE_PROC%%:*} + 1)):$((${FAKE_PROC#*:} + 100))
	_pr_boot=$(setting_get enable_cellular_on_boot)
	_pr_air=$(setting_get airplane_mode_on)
	FAKE_RADIO=0
	if [ "${_pr_boot:-1}" != 0 ] && [ "$_pr_air" != 1 ]; then FAKE_RADIO=1; fi
	if [ "$(setting_get cell_on)" = 2 ] && [ "$_pr_air" != 1 ]; then
		fake_set cell_on 1
		fake_set enable_cellular_on_boot 1
		FAKE_RADIO=1
	fi
}
# As the real one does, it marks that mobile data is no longer the
# module's on (cell_data_step).
mobile_data_off() {
	echo "mobile data off" >>"$STEPS"
	CELL_DATA_ON=0
}
mobile_data_on() { echo "data enable" >>"$STEPS"; }
settings_list() { cat "$G"; }
framework_ready() { [ -z "${FAKE_NO_SETTINGS-}" ]; }
wifi_off() { echo "wifi off" >>"$STEPS"; }
bluetooth_off() { echo "bluetooth off" >>"$STEPS"; }
cell_dump() {
	if [ "${FAKE_BROKEN:-0}" = 1 ]; then
		echo "Can't find service: $1"
		return 1
	fi
	# shellcheck disable=SC2086 # one word per call
	case $1 in
	telecom) telecom_fixture "$FAKE_HISTORY" $FAKE_CALLS | sed "${FAKE_CUT:+$FAKE_CUT,\$d}" ;;
	telephony.registry) registry_fixture "$FAKE_RADIO" "$FAKE_PHONE0" "$I" ;;
	esac
}
# FAKE_CUT: a sed address; Telecom's dump ends just before it (cut short).
FAKE_CUT=
PROPS='gsm.sim.state=ABSENT,ABSENT'
# watch_reset: a start with the radio off since power-on.
watch_reset() {
	printf 'airplane_mode_on=0\ncell_on=1\nenable_cellular_on_boot=0\nairplane_mode_radios=cell,bluetooth,uwb,wifi,wimax\n' >"$G"
	FAKE_RADIO=0 FAKE_HISTORY=0 FAKE_CALLS='' FAKE_PHONE0=$I FAKE_BROKEN=0 FAKE_NO_SETTINGS='' FAKE_CUT=''
	PROPS='gsm.sim.state=ABSENT,ABSENT'
	CELL_AIR='' CELL_AIR_OFF_AT=0 CELL_NARROW=0 CELL_ECM='' CELL_SIM='' CELL_LOOKED='' CELL_LOOK_NEXT=0
	CELL_LAST='' CELL_BUSY=0 CELL_ID='' CELL_RADIO='' CELL_MINE_AT='' CELL_ON_DONE=0 CELL_TRY_AT='' CELL_HELD=''
	CELL_READ='' CELL_CLOCKLESS=0 CL_CALL=unknown CL_CBM=unknown CL_ID='' CL_RADIO=unknown
	CELL_LIVE='' CELL_XN='' CELL_EM_AT='' CELL_UNK_AT='' CELL_EM_SEEN=0 CELL_UNK_SEEN=0
	CELL_FROM='' CELL_PHONE='' CL_PHONE=- FAKE_PROC=1234:5678
	CELL_WORD='' CELL_WORD_BAD=0 CELL_BAD_AT=0 CELL_BAD_KIND='' CELL_TOLD_AT='' CELL_IMS=off CELL_IMS_AT=0 CELL_IMS_NEXT=0
	CL_KIND=unknown CL_LIVE='' CL_XN='' CL_ALONE=0
	RADIOS='' S_STARTED=0 SES_CELL=off S_PROBLEM='' P_CELL=''
	: >"$STEPS"
	: >"$LOGDIR/module.log"
	NOW=1000
}
# turn [SECONDS]: the clock moves on, and the watch takes a turn (with
# TELL=1 followed by the word to Welcome, as service.sh does).
turn() {
	NOW=$((NOW + ${1:-2}))
	cell_step "$NOW"
	[ "${TELL:-0}" = 0 ] || cell_tell "$NOW"
}
# run_for SECONDS [STEP]: turns STEP seconds apart (default 2); the last
# one ends exactly SECONDS later.
run_for() {
	_rf_end=$((NOW + $1))
	while [ "$NOW" -lt "$_rf_end" ]; do
		_rf_s=${2:-2}
		[ $((_rf_end - NOW)) -ge "$_rf_s" ] || _rf_s=$((_rf_end - NOW))
		turn "$_rf_s"
	done
}
did() { grep -q -x -F "$1" "$STEPS"; }
did_not() { ! grep -q -x -F "$1" "$STEPS"; }
said() { grep -q -F "$1" "$LOGDIR/module.log"; }
said_last() { tail -n 1 "$LOGDIR/module.log" | grep -q -F "$1"; }
steps_empty() { [ ! -s "$STEPS" ]; }
# before A B: the first step A came before the first step B.
before() {
	_bf_a=$(grep -n -x -F "$1" "$STEPS" | head -n 1 | cut -d: -f1)
	_bf_b=$(grep -n -x -F "$2" "$STEPS" | head -n 1 | cut -d: -f1)
	[ -n "$_bf_a" ] && [ -n "$_bf_b" ] && [ "$_bf_a" -lt "$_bf_b" ]
}
# airplane_steps: the airplane-mode steps taken, joined with commas.
airplane_steps() { grep '^airplane ' "$STEPS" | tr '\n' ,; }
step_check() { # DESCRIPTION COMMAND...
	_sc_d=$1
	shift
	if "$@"; then ok "$_sc_d"; else bad "$_sc_d"; fi
}
# radio_up: the watch with the list narrowed and the radio switched on by
# something else; the hold that this starts has just begun.
radio_up() {
	watch_reset
	run_for 32
	FAKE_RADIO=1
	: >"$STEPS"
	: >"$LOGDIR/module.log"
	turn 60
}

watch_reset
turn 0
step_check "watch: the first turn looks, and leaves an idle radio alone" did_not "airplane enable"
step_check "watch: no narrowing in the first 29 s of airplane mode off" eval 'run_for 28; did_not "put airplane_mode_radios cell"'
turn 2
step_check "watch: the list narrowed after 30 s of airplane mode off" did "put airplane_mode_radios cell"
step_check "watch: an idle radio is never switched" eval 'run_for 400 10; did_not "airplane enable" && did_not "airplane disable"'

watch_reset
fake_set airplane_mode_on 1
run_for 120 10
step_check "watch: never narrowed while airplane mode is on" did_not "put airplane_mode_radios cell"
fake_set airplane_mode_on 0
turn 2
step_check "watch: airplane mode switched off by something else holds the radio" said "airplane mode switched off by something else"
FAKE_RADIO=1
turn 2
step_check "watch: off waits for the narrowed list" eval 'run_for 26; did_not "airplane enable"'
run_for 320 10
step_check "watch: 5 minutes after airplane mode went off, the radio is switched off" did "airplane enable"
step_check "watch: ... after the list was narrowed" before "put airplane_mode_radios cell" "airplane enable"

# android-1 (c): a restart of the phone process is a doubt for the word
# only, not a call-like event: 200 s after the radio came on, it does not
# hold the radio past the 5 minutes that the switch-on started.
radio_up
run_for 200 10
FAKE_PROC=4321:9
run_for 90 10
run_for 8
step_check "hold (c): the phone process restarted 200 s after the radio came on: still held at 298 s" did_not "airplane enable"
turn 2
step_check "hold (c): ... released at 300 s, as without the restart" did "airplane enable"
FAKE_PROC=1234:5678

# Held: the radio switched on by something else (an emergency text, or
# the emergency-call path), with airplane mode already off.
radio_up
step_check "hold: the radio on by something else: held (recent)" said "held: recent"
step_check "hold: the radio on: mobile data off again" did "mobile data off"
step_check "hold: the radio on: enable_cellular_on_boot 1 while held" did "put enable_cellular_on_boot 1"
step_check "hold: ... not 0" did_not "put enable_cellular_on_boot 0"
run_for 290 10
run_for 8
step_check "hold: still held 298 s after it was seen" did_not "airplane enable"
step_check "hold: enable_cellular_on_boot still 1 at 298 s" did_not "put enable_cellular_on_boot 0"
turn 2
step_check "hold: released at 300 s: the radio off by airplane mode" did "airplane enable"
step_check "hold: release logged" said "the cell radio off (airplane mode"
step_check "hold: released: enable_cellular_on_boot 0 just before the switch-off" before \
	"put enable_cellular_on_boot 0" "airplane enable"

# The look a switch-off uses is taken in the same turn: a call that begins
# to ring between two turns, right after a look, stops the release.
radio_up
run_for 230 10
turn 10
CELL_LAST=$((NOW - CELL_AFTER + 1))
: >"$STEPS"
FAKE_CALLS=RINGING FAKE_HISTORY=1 FAKE_PHONE0='1 5 0 0 0 0'
turn 2
step_check "hold: a call ringing since the last turn's look: no switch-off" did_not "airplane enable"
step_check "hold: ... a look was taken in this turn" test "$CELL_LOOKED" = "$NOW"
step_check "hold: ... held (call)" said_last "held: call"

# Switched on again right after the module's switch-off, before its next
# turn (an emergency text, the person): still an event.
radio_up
run_for 300 10
step_check "hold: (the radio off after the hold)" did "airplane enable"
fake_set airplane_mode_on 0
fake_set cell_on 1
FAKE_RADIO=1
: >"$STEPS"
: >"$LOGDIR/module.log"
turn 2
step_check "hold: airplane mode off again right after the switch-off: seen" said "switched off by something else"
run_for 290 10
step_check "hold: ... held 5 minutes" did_not "airplane enable"
run_for 20
step_check "hold: ... then released" did "airplane enable"

for c in RINGING DIALING ACTIVE ON_HOLD CONNECTING; do
	radio_up
	FAKE_CALLS=$c FAKE_HISTORY=1
	run_for 12
	step_check "hold: a call $c in Telecom: held (call)" said "held: call"
	run_for 400 10
	step_check "hold: a call $c: still held after 400 s" did_not "airplane enable"
done
for p in '1 5 0 0 0 0' '2 0 1 0 0 0' '2 0 0 2 0 0'; do
	radio_up
	FAKE_PHONE0=$p
	run_for 400 10
	step_check "hold: the registry alone shows a call ($p): held" eval 'said "held: call" && did_not "airplane enable"'
done

radio_up
FAKE_CALLS=ACTIVE FAKE_HISTORY=1
run_for 400 10
FAKE_CALLS=''
run_for 10
step_check "hold: the call ended: held (recent)" said_last "held: recent"
run_for 280 10
run_for 6
step_check "hold: still held just under 5 minutes after the end" did_not "airplane enable"
run_for 14
step_check "hold: released once 5 minutes have passed since the end" did "airplane enable"

radio_up
PROPS='gsm.sim.state=ABSENT,ABSENT
ril.cdma.inecmmode=true'
turn 2
step_check "hold: emergency callback mode (the property): held (callback)" said "held: callback"
run_for 400 10
step_check "hold: callback mode: still held after 400 s" did_not "airplane enable"
PROPS='gsm.sim.state=ABSENT,ABSENT
ril.cdma.inecmmode=false'
run_for 290 10
step_check "hold: callback mode over: held for 5 more minutes" did_not "airplane enable"
run_for 30
step_check "hold: callback mode over: released after 5 minutes" did "airplane enable"

for p in '0 0 0 0 300000 0' '0 0 0 0 0 300000'; do
	radio_up
	FAKE_PHONE0=$p
	run_for 400 10
	step_check "hold: callback mode in the registry ($p): held" eval 'said "held: callback" && did_not "airplane enable"'
	FAKE_PHONE0=$I
	run_for 290 10
	step_check "hold: callback mode in the registry over: held 5 more minutes" did_not "airplane enable"
	run_for 30
	step_check "hold: callback mode in the registry over: released" did "airplane enable"
done

radio_up
FAKE_BROKEN=1
run_for 40
step_check "hold: the state cannot be read: held (unknown)" said "held: unknown"
run_for 400 10
step_check "hold: unknown: still held after 400 s" did_not "airplane enable"
FAKE_BROKEN=0
run_for 40
step_check "hold: readable again: logged" said "can be read again"
run_for 250 10
step_check "hold: readable again: held for 5 more minutes" did_not "airplane enable"
run_for 50
step_check "hold: readable again: released after 5 minutes" did "airplane enable"

radio_up
run_for 250 10
FAKE_HISTORY=9
run_for 12
run_for 50 10
step_check "hold: a call that began and ended between two looks: held" did_not "airplane enable"
run_for 250 10
step_check "hold: released 5 minutes after the call number moved" did "airplane enable"

radio_up
NOW=0
FAKE_RADIO=1
CELL_LAST=''
cell_step 0
cell_step 0
step_check "hold: no time since boot: held (unknown)" did_not "airplane enable"
NOW=5000
run_for 290 10
step_check "hold: the time since boot readable again: held 5 more minutes" did_not "airplane enable"
run_for 20
step_check "hold: ... then released" did "airplane enable"

# getprop failing for the callback-mode property: held as unknown.
radio_up
# shellcheck disable=SC2317 # called by cell_look
getprop() { return 127; }
run_for 12
step_check "hold: the callback-mode property cannot be read: held (unknown)" said "held: unknown"
getprop() { printf '%s\n' "$PROPS" | sed -n "s/^$1=//p"; }

# Allowed during a hold: mobile data off; enable_cellular_on_boot is kept
# at 1, so that a restart of the phone process does not switch the radio
# off (it would read 0).
radio_up
FAKE_CALLS=ACTIVE FAKE_HISTORY=1
turn 2
: >"$STEPS"
fake_set enable_cellular_on_boot 0
turn 2
step_check "during a call: enable_cellular_on_boot 1 again" did "put enable_cellular_on_boot 1"
step_check "during a call: no airplane step" did_not "airplane enable"
FAKE_RADIO=0
phone_restart
expect "during a call: a restart of the phone process keeps the radio on" 1 "$FAKE_RADIO"

# The module switched the radio off; then an emergency call: Android's
# path switches airplane mode off and the radio on, and stores
# enable_cellular_on_boot=1. Mobile data off again, and 1 kept through the
# call, callback mode and the 5 minutes after, even across a restart of
# the phone process; then 0 again and the radio off.
radio_up
run_for 300 10
step_check "emergency call: (the radio off after the hold)" did "airplane enable"
: >"$STEPS"
: >"$LOGDIR/module.log"
fake_set airplane_mode_on 0
fake_set cell_on 1
fake_set enable_cellular_on_boot 1
FAKE_RADIO=1 FAKE_CALLS=ACTIVE FAKE_HISTORY=2 FAKE_PHONE0='2 0 1 0 0 0'
turn 2
step_check "emergency call: enable_cellular_on_boot set by a switch-on: mobile data off again" eval \
	'said "changed to 1 by something else" && did "mobile data off"'
step_check "emergency call: enable_cellular_on_boot left at 1" did_not "put enable_cellular_on_boot 0"
run_for 60 10
FAKE_CALLS='' FAKE_PHONE0=$I
PROPS='gsm.sim.state=ABSENT,ABSENT
ril.cdma.inecmmode=true'
run_for 60 10
phone_restart
expect "emergency callback mode: a restart of the phone process keeps the radio on" 1 "$FAKE_RADIO"
run_for 200 10
step_check "emergency callback mode: no switch-off, enable_cellular_on_boot still 1" eval \
	'did_not "airplane enable" && did_not "put enable_cellular_on_boot 0"'
PROPS='gsm.sim.state=ABSENT,ABSENT
ril.cdma.inecmmode=false'
run_for 290 10
phone_restart
expect "callback mode over 290 s ago: a restart of the phone process keeps the radio on" 1 "$FAKE_RADIO"
step_check "callback mode over 290 s ago: still no switch-off" did_not "airplane enable"
run_for 20
step_check "callback mode over 5 minutes ago: enable_cellular_on_boot 0, then the radio off" before \
	"put enable_cellular_on_boot 0" "airplane enable"

# The radio off since power-on (enable_cellular_on_boot=0 stored); an
# emergency call switches it on without changing any setting. The watch
# stores 1 while the call and callback mode last.
watch_reset
run_for 40
: >"$STEPS"
FAKE_RADIO=1 FAKE_CALLS=DIALING FAKE_HISTORY=1 FAKE_PHONE0='2 0 3 0 0 0'
run_for 70
step_check "radio on for a call from power-on: enable_cellular_on_boot 1" did "put enable_cellular_on_boot 1"
FAKE_CALLS='' FAKE_PHONE0='0 0 0 0 300000 0'
run_for 30 10
phone_restart
expect "radio on for a call from power-on, callback mode: a restart keeps it on" 1 "$FAKE_RADIO"

# A VoIP call with the cell radio off: nothing to keep on.
watch_reset
run_for 40
: >"$STEPS"
FAKE_CALLS=ACTIVE:voip FAKE_HISTORY=1
run_for 70
expect "VoIP call, the cell radio off: the call is seen" 1 "$CL_CALL"
step_check "VoIP call, the cell radio off: enable_cellular_on_boot stays 0" did_not "put enable_cellular_on_boot 1"
: >"$STEPS"
PROPS='gsm.sim.state=LOADED,ABSENT'
turn 2
step_check "a SIM's state changed: mobile data off" did "mobile data off"

# The fail-safe during a call: Wi-Fi and mobile data at once, the cell
# radio and Bluetooth after the hold.
radio_up
FAKE_CALLS=ACTIVE FAKE_HISTORY=1
turn 2
: >"$STEPS"
RADIOS=wanted
turn 2
step_check "fail-safe: Wi-Fi off at once during a call" did "wifi off"
step_check "fail-safe: mobile data off at once during a call" did "mobile data off"
step_check "fail-safe: no airplane step during a call" did_not "airplane enable"
step_check "fail-safe: no Bluetooth off during a call" did_not "bluetooth off"
expect "fail-safe: waiting" waiting "$RADIOS"
expect "fail-safe: status says the rest follows, not why" "cellular radio and Bluetooth off shortly" "$P_CELL"
case $S_PROBLEM$P_CELL in *call*) bad "fail-safe: status mentions a call" ;; *) ok "fail-safe: status says nothing of a call" ;; esac
run_for 400 10
step_check "fail-safe: still waiting while the call lasts" did_not "airplane enable"
FAKE_CALLS=''
run_for 290 10
step_check "fail-safe: waiting 5 minutes after the call" did_not "airplane enable"
run_for 30
step_check "fail-safe: the cell radio off after the hold" did "airplane enable"
step_check "fail-safe: Bluetooth off after the hold" did "bluetooth off"
expect "fail-safe: switched" switched "$RADIOS"
expect "fail-safe: nothing waits any more" "" "$P_CELL"

# The fail-safe with nothing holding it: all at once, even before the list
# is narrowed (Wi-Fi goes off with airplane mode then, as wanted here).
watch_reset
turn 0
RADIOS=wanted
turn 2
step_check "fail-safe, no call: Wi-Fi off" did "wifi off"
step_check "fail-safe, no call: airplane mode on" did "airplane enable"
step_check "fail-safe, no call: Bluetooth off" did "bluetooth off"

# Phone mode (WEL8 supplies the choice; session_cell says "off" today).
watch_reset
SES_CELL=phone
run_for 60
step_check "Phone mode: nothing before Start (D12)" did_not "airplane disable"
S_STARTED=1
turn 2
step_check "Phone mode: switched on at Start" did "airplane disable"
step_check "Phone mode: mobile data off before the switch-on" before "mobile data off" "airplane enable"
step_check "Phone mode: mobile_data_always_on 0 before the switch-on" before "put mobile_data_always_on 0" "airplane enable"
expect "Phone mode: enable then disable (the radio was off since power-on)" "airplane enable,airplane disable," \
	"$(airplane_steps)"
: >"$STEPS"
turn 2
step_check "Phone mode: enable_cellular_on_boot 0 again after the switch-on" did "put enable_cellular_on_boot 0"
step_check "Phone mode: mobile data off again after the switch-on" did "mobile data off"
run_for 600 10
step_check "Phone mode: the module's own switch-on is not switched off" did_not "airplane enable"
FAKE_RADIO=0
: >"$STEPS"
run_for 20
step_check "Phone mode: the phone process restarted (radio off): on again" did "airplane disable"
run_for 20
fake_set airplane_mode_on 1
fake_set cell_on 2
FAKE_RADIO=0
: >"$STEPS"
run_for 400 10
step_check "Phone mode: airplane mode switched on by the person is left alone" eval 'did_not "airplane disable"'

watch_reset
SES_CELL=phone
fake_set airplane_mode_on 1
fake_set cell_on 2
run_for 10
S_STARTED=1
turn 2
expect "Phone mode, airplane mode on: only 'disable'" "airplane disable," "$(airplane_steps)"

watch_reset
SES_CELL=phone
run_for 40
FAKE_CALLS=ACTIVE:voip FAKE_HISTORY=1
S_STARTED=1
run_for 100 10
step_check "Phone mode: the switch-on (enable and disable) waits during a call" eval \
	'did_not "airplane enable" && did_not "airplane disable"'
step_check "Phone mode: ... logged" said "held: call"

watch_reset
SES_CELL=phone
FAKE_RADIO=1
run_for 40
S_STARTED=1
: >"$STEPS"
turn 2
step_check "Phone mode, the radio already on: no airplane step" eval 'did_not "airplane enable" && did_not "airplane disable"'
step_check "Phone mode, the radio already on: mobile data off" did "mobile data off"

watch_reset
SES_CELL=off
S_STARTED=1
run_for 60
step_check "session off: no switch-on after Start" did_not "airplane disable"

# The module's files gone (Magisk itself uninstalled while the loop still
# runs) after uninstall.sh's restore: the watch writes nothing more.
watch_reset
run_for 40
: >"$STEPS"
{
	grep -v -e '^enable_cellular_on_boot=' -e '^airplane_mode_radios=' "$G"
	echo 'airplane_mode_radios=cell,bluetooth,uwb,wifi,wimax'
} >"$G.new"
mv -f "$G.new" "$G"
FAKE_RADIO=1
conf_kept=$SETTINGS_CONF
SETTINGS_CONF=$LOGDIR/removed/settings.conf
run_for 120 10
SETTINGS_CONF=$conf_kept
step_check "module removed: the restored values are left alone" steps_empty

# Shutdown: airplane mode stored off without a broadcast, unless held.
watch_reset
fake_set airplane_mode_on 1
fake_set cell_on 2
run_for 400 10
: >"$STEPS"
cell_shutdown "$NOW"
expect "shutdown: cell_on 1, then airplane mode 0, no airplane step" "put cell_on 1,put airplane_mode_on 0," \
	"$(tr '\n' , <"$STEPS")"
watch_reset
fake_set airplane_mode_on 1
fake_set cell_on 2
FAKE_CALLS=ACTIVE:voip FAKE_HISTORY=1
run_for 20
: >"$STEPS"
cell_shutdown "$NOW"
step_check "shutdown during a call: airplane mode left as it is" eval 'did_not "put airplane_mode_on 0" && did_not "put cell_on 1"'
step_check "shutdown during a call: logged" said "shutdown: airplane mode left as it is, held: call"
watch_reset
fake_set airplane_mode_on 1
fake_set cell_on 2
run_for 20
FAKE_BROKEN=1
: >"$STEPS"
cell_shutdown "$NOW"
step_check "shutdown, the state unreadable: airplane mode left as it is" did_not "put airplane_mode_on 0"
watch_reset
run_for 20
: >"$STEPS"
cell_shutdown "$NOW"
step_check "shutdown, airplane mode off and cell_on 1: nothing to store" steps_empty

# --- The module's word (MOD11): telling Welcome ---------------------------------------
# Stand-ins: the device owner (FAKE_OWNER) and 'content call' (word_send),
# which records its arguments in WORDS and prints FAKE_ANSWER, or nothing
# (the real tool prints a refusal on standard error and exits 0).
WORDS=$LOGDIR/words
FAKE_OWNER=1
OK_ANSWER='Result: Bundle[{v=1}]'
FAKE_ANSWER=$OK_ANSWER
welcome_is_owner() { [ "$FAKE_OWNER" = 1 ]; }
word_send() {
	echo "$*" >>"$WORDS"
	[ -z "$FAKE_ANSWER" ] || printf '%s\n' "$FAKE_ANSWER"
	return 0
}
words_n() { grep -c "${1:-.}" "$WORDS"; }
last_word() { tail -n 1 "$WORDS"; }
# told KIND UNTIL [IMS IMS_AT]: the arguments of a word told after the look
# taken now.
told() {
	echo "--extra v:i:1 --extra calls:s:$1 --extra at:l:$CELL_LOOKED --extra until:l:$2 --extra ims:s:${3:-off} --extra ims_at:l:${4:-0}"
}
FAKE_ANSWER=$OK_ANSWER
if welcome_tell ordinary 1234 0 off 0; then ok "welcome_tell: true on Welcome's answer"; else bad "welcome_tell: refused Welcome's answer"; fi
expect "welcome_tell: the arguments" \
	"--extra v:i:1 --extra calls:s:ordinary --extra at:l:1234 --extra until:l:0 --extra ims:s:off --extra ims_at:l:0" "$(last_word)"
for a in '' 'Result: Bundle[{v=2}]' 'Result: null' "$OK_ANSWER
$OK_ANSWER" "Error while accessing provider:org.antumbra.welcome.state"; do
	FAKE_ANSWER=$a
	d=$(printf '%s' "$a" | tr '\n' '|')
	if welcome_tell none 1 0 off 0; then bad "welcome_tell: took [$d] as Welcome's answer"; else ok "welcome_tell: false on [$d]"; fi
done
FAKE_ANSWER=$OK_ANSWER

TELL=1
# last_kind, last_at: the calls word and the look's time of the last word
# told; words_since N: the words told after the first N.
last_kind() { last_word | sed -n 's/.* calls:s:\([a-z]*\) .*/\1/p'; }
last_at() { last_word | sed -n 's/.* at:l:\([0-9]*\) .*/\1/p'; }
words_since() { tail -n +$(($1 + 1)) "$WORDS"; }
# The phone process's IMS dump in a Phone-mode session: nothing here (read
# as unknown); the IMS section below has its own.
# shellcheck disable=SC2317 # called by ims_step
ims_dump() { :; }
watch_reset
: >"$WORDS"
turn 0
expect "tell: the first turn tells Welcome 'none' (replacing an earlier run's word)" "$(told none 0)" "$(last_word)"
run_for 400 10
expect "tell: nothing more while nothing happens" 1 "$(words_n)"
# android-1 (a): an ordinary call outside Phone mode (every session until
# WEL8; a VoIP call through Telecom, or a call on a radio the module did
# not switch on): unknown while it lasts and for 5 minutes after it,
# told once, never ordinary.
FAKE_CALLS=ACTIVE FAKE_HISTORY='1:open' FAKE_PHONE0='2 0 1 0 0 0'
began=$NOW
run_for 70 10
expect "tell (a): outside Phone mode, during an ordinary call: unknown" unknown "$(last_kind)"
step_check "tell (a): ... from a look during the call" test "$(last_at)" -gt "$began"
n=$(words_n)
run_for 100 10
expect "tell (a): ... told once while it lasts" "$n" "$(words_n)"
FAKE_CALLS='' FAKE_HISTORY=1 FAKE_PHONE0=$I
run_for 10 10
end=$CELL_LOOKED
run_for 280 10
expect "tell (a): ... 280 s after the end: still unknown" unknown "$(last_kind)"
# The doubt counts from the look after the end; the radio, released by
# then, is looked at every 60 s.
run_for 90 10
expect "tell (a): ... 5 minutes after the look after the end: none" none "$(last_kind)"
n=$(words_n)
run_for 600 10
expect "tell (a): then no word at all" "$n" "$(words_n)"
expect "tell (a): then nothing is kept about the call" "-/-/-" "$(records)"
expect "tell (a): never ordinary" 0 "$(words_n calls:s:ordinary)"
step_check "tell (a): (the end was seen)" test "$end" -gt 0
# A VoIP call (Telecom lists it, voip=true) outside Phone mode: the same.
watch_reset
: >"$WORDS"
turn 0
FAKE_CALLS=ACTIVE:voip FAKE_HISTORY='1:open'
run_for 70 10
FAKE_CALLS='' FAKE_HISTORY=1
run_for 400 10
expect "tell (a): a VoIP call outside Phone mode: unknown, then none, never ordinary" "unknown,none,0" \
	"$(words_since 1 | sed -n 's/.* calls:s:\([a-z]*\) .*/\1/p' | tr '\n' ,)$(words_n calls:s:ordinary)"

# Emergency callback mode (the registry): emergency, until 5 minutes after
# the look; the radio stays as MOD6 holds it.
watch_reset
: >"$WORDS"
turn 0
FAKE_PHONE0='0 0 0 0 300000 0'
run_for 70 10
expect "tell: callback mode: emergency until 5 minutes after the look" \
	"$(told emergency $((CELL_LOOKED + 300)))" "$(last_word)"
FAKE_PHONE0=$I
run_for 20 10
em_at=$CELL_EM_AT
run_for 200 10
expect "tell: callback mode over: still emergency, until 5 minutes after the look that saw it end" \
	"$(told emergency $((em_at + 300)))" "$(last_word)"
run_for 100 10
expect "tell: callback mode over 5 minutes ago: none" "$(told none 0)" "$(last_word)"

# An emergency call between two looks (Telecom's entry).
watch_reset
: >"$WORDS"
turn 0
FAKE_HISTORY='1:e'
run_for 70 10
expect "tell: an emergency call between two looks: emergency" "$(told emergency $((CELL_EM_AT + 300)))" "$(last_word)"
step_check "tell: ... the radio left alone (no switch-on, no switch-off)" did_not "airplane enable"

# The state cannot be read: unknown, told once while it lasts.
watch_reset
: >"$WORDS"
turn 0
FAKE_BROKEN=1
run_for 120 10
case $(last_word) in
*' calls:s:unknown '*' until:l:0 '*) ok "tell: the state cannot be read: unknown" ;;
*) bad "tell: the state cannot be read: unknown: got [$(last_word)]" ;;
esac
expect "tell: unknown is told once while it lasts" 1 "$(words_n calls:s:unknown)"

# Not the device owner: nothing is sent, until Welcome is.
watch_reset
: >"$WORDS"
FAKE_OWNER=0
turn 0
FAKE_CALLS=ACTIVE FAKE_HISTORY='1:open'
run_for 100 10
step_check "tell: nothing sent while Welcome is not the device owner" test ! -s "$WORDS"
FAKE_OWNER=1
run_for 10 10
expect "tell: Welcome the device owner: the word is sent" "$(told unknown 0)" "$(last_word)"

# Welcome refuses (one without module_word answers "Result: null"): logged
# once; tried again every 300 s, not after each look, but at once for a
# word of another kind or an emergency word; logged once when it takes
# the word again. The log never names a word.
watch_reset
: >"$WORDS"
FAKE_ANSWER='Result: null'
turn 0
expect "tell: Welcome refuses: logged once" 1 "$(grep -c "did not take the module's word" "$LOGDIR/module.log")"
run_for 600 10
expect "tell (r-2): Welcome refuses: tried again every 300 s, not after each look (3 tries in 600 s)" 3 "$(words_n)"
n=$(words_n)
FAKE_CALLS=ACTIVE FAKE_HISTORY='1:open' FAKE_PHONE0='2 0 1 0 0 0'
run_for 60 10
expect "tell (r-2): ... a word of another kind: tried at once (the next look)" "$((n + 1)) unknown" "$(words_n) $(last_kind)"
run_for 60 10
expect "tell (r-2): ... not again while it stays the same" "$((n + 1))" "$(words_n)"
FAKE_CALLS='' FAKE_HISTORY=1 FAKE_PHONE0='0 0 0 0 300000 0'
run_for 30 10
expect "tell (r-2): ... an emergency word: tried after each look" "$((n + 4)) emergency" "$(words_n) $(last_kind)"
FAKE_PHONE0=$I
FAKE_ANSWER=$OK_ANSWER
run_for 10 10
expect "tell: Welcome takes it again: logged once" 1 "$(grep -c "takes the module's word again" "$LOGDIR/module.log")"
expect "tell: ... the refusal logged once in all" 1 "$(grep -c "did not take the module's word" "$LOGDIR/module.log")"
step_check "tell: the log names no word" test -z "$(grep -E 'ordinary|calls:|until:|ims:|ims=' "$LOGDIR/module.log")"
FAKE_CALLS='' FAKE_HISTORY=0

# Phone mode (WEL8 supplies the choice; session_cell says "off" today):
# the only place a call can read ordinary.
# phone_on: a Phone-mode session after Start, the module's switch-on done,
# nothing going on (the IMS reading, unknown here, is told every 300 s).
phone_on() {
	watch_reset
	: >"$WORDS"
	S_STARTED=1 SES_CELL=phone
	turn 0
	run_for 100 10
	: >"$STEPS"
	: >"$LOGDIR/module.log"
}
phone_on
step_check "tell: Phone mode on (the switch-on done, the radio on)" test "$CELL_ON_DONE$FAKE_RADIO" = 11
expect "tell: Phone mode on: none" none "$(last_kind)"
n=$(words_n)
FAKE_CALLS=ACTIVE FAKE_HISTORY='1:open' FAKE_PHONE0='2 0 1 0 0 0'
run_for 120 10
expect "tell: Phone mode, during an ordinary call: ordinary" ordinary "$(last_kind)"
expect "tell (r-2): ... one word during the call (it changed once), not one per look" 1 "$(words_since "$n" | grep -c .)"
FAKE_CALLS='' FAKE_HISTORY=1 FAKE_PHONE0=$I
run_for 10 10
end=$CELL_LOOKED
expect "tell: the call ended: ordinary, from the look that saw the end" "ordinary $end" "$(last_kind) $(last_at)"
n=$(words_n)
run_for 50 10
expect "tell (r-2): after the call: a word after each look again" 5 "$(words_since "$n" | grep -c 'calls:s:ordinary ')"
run_for 230 10
expect "tell: 280 s after the end: still ordinary" ordinary "$(last_kind)"
run_for 30 10
expect "tell: 5 minutes after the end: none" none "$(last_kind)"
n=$(words_n)
run_for 600 10
expect "tell: then nothing but none (the IMS reading every 300 s)" 0 "$(words_since "$n" | grep -c -v 'calls:s:none ')"
expect "tell: then nothing is kept about the call" "-/-/-" "$(records)"
# An emergency call in Phone mode: emergency after each look (its end moves on).
phone_on
n=$(words_n)
FAKE_CALLS=ACTIVE FAKE_HISTORY='1:e+open' FAKE_PHONE0='2 0 1 0 0 0'
run_for 60 10
expect "tell (r-2): an emergency call: a word after each look, its end moving on" "6 $((CELL_LOOKED + 300))" \
	"$(words_since "$n" | grep -c 'calls:s:emergency ') $(last_word | sed -n 's/.* until:l:\([0-9]*\) .*/\1/p')"
FAKE_CALLS='' FAKE_HISTORY=0 FAKE_PHONE0=$I
# safety-1 in the watch: call 1 seen in Analytics only (not listed yet,
# open) at one look; flagged by the network and ended before the next.
phone_on
FAKE_HISTORY='1:open'
run_for 10 10
expect "tell (safety-1): a call in Analytics only, not listed, open: ordinary so far" ordinary "$(last_kind)"
FAKE_HISTORY='1:ecall'
run_for 10 10
expect "tell (safety-1): ... flagged ecall and ended by the next look: emergency" emergency "$(last_kind)"
phone_on
FAKE_HISTORY='1:open'
run_for 10 10
run_for 10 10
expect "tell (safety-1): ... still unlisted and open at the next look: unknown" unknown "$(last_kind)"
FAKE_HISTORY=1
run_for 400 10
expect "tell (safety-1): ... never ordinary after the doubt" 1 "$(words_n calls:s:ordinary)"
FAKE_HISTORY=0
# The entry open and not listed at many looks (Telecom's timing; the third
# review's case): the call stays in scope, unknown at every look, until a
# look reads its entry ended. Here it is listed only between two looks,
# flagged ecall by the network and ended there; an ordinary call follows
# between two later looks. Emergency, never ordinary, from the look that
# read the end until 5 minutes after the later call.
phone_on
FAKE_HISTORY='1:open'
run_for 10 10
expect "tell (safety-1): a call in Analytics only, not listed, open: ordinary so far" ordinary "$(last_kind)"
n=$(words_n)
run_for 150 10
expect "tell (safety-1): ... open and not listed at 15 more looks: unknown" unknown "$(last_kind)"
expect "tell (safety-1): ... still read at every look (kept in LIVE)" "1 1" "$CELL_LIVE $CELL_ID"
FAKE_HISTORY='1:ecall'
run_for 10 10
end=$CELL_LOOKED
expect "tell (safety-1): ... listed, flagged ecall and ended between two looks: emergency, 5 minutes from the look" \
	"emergency $end $((end + 300))" "$(last_kind) $(last_at) $(last_word | sed -n 's/.* until:l:\([0-9]*\) .*/\1/p')"
expect "tell (safety-1): ... the look that read the end is a call-like event" "$end" "$CELL_LAST"
run_for 250 10
FAKE_HISTORY='1:ecall 2'
run_for 20 10
expect "tell (safety-1): ... an ordinary call 260 s after: still emergency" emergency "$(last_kind)"
run_for 600 10
expect "tell (safety-1): ... then none, never ordinary after the first look" "none 0" \
	"$(last_kind) $(words_since "$n" | grep -c 'calls:s:ordinary ')"
FAKE_HISTORY=0
# The same turn by turn, with the call in the registry while it is listed:
# call 1's entry open and not listed from 1110 to 1260, the call listed
# from 1262 to 1268 only (between two looks), flagged ecall by the network
# at 1265 and ended at 1268; an ordinary call 2 listed from 1522 to 1528,
# between two looks too (Welcome would see it end at 1528). Emergency from
# the look at 1270 until 5 minutes after the look that saw call 2 end,
# never ordinary.
phone_on
FAKE_HISTORY='1:open'
run_for 10 10
n=$(words_n)
run_for 150 10
FAKE_CALLS=DIALING@1 FAKE_PHONE0='2 0 1 0 0 0'
turn 2
FAKE_HISTORY='1:ecall+open' FAKE_CALLS=ACTIVE:ecall@1
turn 3
FAKE_HISTORY='1:ecall' FAKE_CALLS='' FAKE_PHONE0=$I
turn 3
expect "tell (safety-1, turn by turn): ... no look while call 1 was listed" 1260 "$CELL_LOOKED"
turn 2
expect "tell (safety-1, turn by turn): ... the look after call 1's end: emergency" "emergency 1270" "$(last_kind) $(last_at)"
run_for 250 10
FAKE_HISTORY='1:ecall 2:open' FAKE_CALLS=ACTIVE@2 FAKE_PHONE0='2 0 1 0 0 0'
turn 2
FAKE_HISTORY='1:ecall 2' FAKE_CALLS='' FAKE_PHONE0=$I
turn 6
turn 2
expect "tell (safety-1, turn by turn): ... the look after call 2's end: emergency, 5 minutes from it" \
	"emergency 1530 1830" "$(last_kind) $(last_at) $(last_word | sed -n 's/.* until:l:\([0-9]*\) .*/\1/p')"
run_for 600 10
expect "tell (safety-1, turn by turn): ... then none, never ordinary after the first look" "none 0" \
	"$(last_kind) $(words_since "$n" | grep -c 'calls:s:ordinary ')"
FAKE_HISTORY=0
# A call Telecom dropped before listing it (no account to place it): its
# entry never ends, so in Phone mode the word stays unknown while Telecom
# keeps that entry, an ordinary call after it included.
phone_on
FAKE_HISTORY='1:open'
run_for 10 10
n=$(words_n)
run_for 600 10
expect "tell (safety-1): a call dropped before Telecom listed it: unknown, 10 minutes later too" unknown "$(last_kind)"
FAKE_HISTORY='1:open 2'
run_for 400 10
expect "tell (safety-1): ... an ordinary call after it: unknown, never ordinary after the first look" "unknown 0" \
	"$(last_kind) $(words_since "$n" | grep -c 'calls:s:ordinary ')"
FAKE_HISTORY=0
# Telecom's dump cut short (dumpsys gave up, or Telecom was busy) after an
# ordinary call: Analytics lists the newest call last, so the cut loses
# it, here an emergency call. Unknown, never ordinary; then emergency once
# the whole dump is read.
phone_on
FAKE_HISTORY=1
run_for 10 10
expect "tell: an ordinary call between two looks: ordinary" ordinary "$(last_kind)"
n=$(words_n)
FAKE_HISTORY='1 2:e' FAKE_CUT='/^  Call TC@2: {$/'
run_for 10 10
expect "tell: Telecom's dump cut before the newest entry: unknown" unknown "$(last_kind)"
FAKE_CUT=''
run_for 30 10
expect "tell: the whole dump again: emergency" emergency "$(last_kind)"
step_check "tell: no ordinary word once the dump was cut" test -z "$(words_since "$n" | grep -F 'calls:s:ordinary ')"
FAKE_HISTORY=0
# android-1 (c): the phone process restarted (Telecom's emergency check
# fails while it does): unknown for 5 minutes, no radio step and no hold
# for it; then (b): a 6-minute call that follows keeps it unknown until 5
# minutes after its end.
phone_on
FAKE_PROC=4321:9
run_for 10 10
expect "tell (c): the phone process restarted: unknown" unknown "$(last_kind)"
step_check "tell (c): ... no radio step" steps_empty
step_check "tell (c): ... nothing logged" test ! -s "$LOGDIR/module.log"
run_for 100 10
FAKE_CALLS=ACTIVE FAKE_HISTORY='1:open' FAKE_PHONE0='2 0 1 0 0 0'
run_for 360 10
FAKE_CALLS='' FAKE_HISTORY=1 FAKE_PHONE0=$I
n=$(words_n)
run_for 10 10
end=$CELL_LOOKED
run_for 290 10
expect "tell (c)+(b): ... 290 s after the end of a 6-minute call that followed: still unknown" unknown "$(last_kind)"
run_for 300 10
expect "tell (c)+(b): ... then none" none "$(last_kind)"
expect "tell (c)+(b): ... never ordinary" 0 "$(words_since "$n" | grep -c 'calls:s:ordinary ')"
phone_on
FAKE_PROC=-
run_for 10 10
expect "tell (c): the phone process not running: unknown" unknown "$(last_kind)"
phone_on
phone_restart
run_for 10 10
expect "tell (c): MOD6's stand-in restart of the phone process: unknown" unknown "$(last_kind)"
FAKE_CALLS='' FAKE_HISTORY=0 FAKE_PROC=1234:5678
S_STARTED=0 SES_CELL=off

# service.sh: a turn that looked tells Welcome the word, then checks the
# ports again at once, so that neither the look nor the word (up to 10 s)
# is added to the next turn's wait (regressions-3).
# line_of PATTERN: the number of the one line of service.sh that is
# exactly PATTERN (a fixed string, the indentation included).
line_of() { grep -n -x -F "$1" "$MODULE/service.sh" | sed 's/:.*//'; }
# shellcheck disable=SC2016 # lines of service.sh, not expanded here
r="$(line_of '		cell_step "$NOW"') $(line_of '		cell_tell "$NOW"') $(line_of '		cell_offer_tell "$NOW"')"
# shellcheck disable=SC2016 # a line of service.sh, not expanded here
r="$r $(line_of '		{ [ "$CELL_LOOKED" = "$NOW" ] || [ "$CELL_OFFER_TOLD" = "$NOW" ]; } && ports_check')"
case $r in
[0-9]*' '[0-9]*' '[0-9]*' '[0-9]*)
	# shellcheck disable=SC2086 # four line numbers
	set -- $r
	step_check "service.sh: look, word, word on the cell radio, then the port check, one after the other ($r)" \
		test "$2" = $(($1 + 1)) -a "$3" = $(($2 + 1)) -a "$4" = $(($3 + 1))
	;;
*) bad "service.sh: look, words, then the port check: lines not found ($r)" ;;
esac


# A call in the registry that Telecom does not list (it began between the
# two dumps, or Telecom missed it): unknown while it lasts and for the 5
# minutes after, never ordinary.
watch_reset
: >"$WORDS"
turn 0
FAKE_PHONE0='2 0 1 0 0 0'
run_for 70 10
expect "tell: a call in the registry that Telecom does not list: unknown" unknown "$(last_kind)"
FAKE_PHONE0=$I
run_for 10 10
end=$CELL_LOOKED
run_for 280 10
expect "tell: ... 280 s after its end: still unknown" unknown "$(last_kind)"
run_for 30 10
expect "tell: ... 5 minutes after its end: none" "$(told none 0)" "$(last_word)"
expect "tell: ... never ordinary" 0 "$(words_n calls:s:ordinary)"
step_check "tell: ... (its end was seen)" test "$end" -gt 0

# Airplane mode switched off by something else (the emergency path, an
# emergency text), the radio still off: unknown for 5 minutes, never
# ordinary.
watch_reset
: >"$WORDS"
turn 0
fake_set airplane_mode_on 1
run_for 70 10
fake_set airplane_mode_on 0
turn 2
step_check "tell: (airplane mode off by something else, seen)" said "airplane mode switched off by something else"
run_for 10 10
expect "tell: airplane mode off by something else, the radio still off: unknown" unknown "$(last_kind)"
run_for 280 10
expect "tell: ... 290 s after it: still unknown" unknown "$(last_kind)"
run_for 30 10
expect "tell: ... 5 minutes after it: none" "$(told none 0)" "$(last_word)"
expect "tell: ... never ordinary" 0 "$(words_n calls:s:ordinary)"
step_check "tell: ... (the radio stayed off)" test "$FAKE_RADIO" = 0
# The same during an emergency sign's 5 minutes: airplane mode switched off
# by something else is a call-like event, so it renews the sign.
watch_reset
: >"$WORDS"
turn 0
fake_set airplane_mode_on 1
run_for 70 10
FAKE_PHONE0='0 0 0 0 300000 0'
run_for 70 10
FAKE_PHONE0=$I
run_for 20 10
em_at=$CELL_EM_AT
run_for 200 10
fake_set airplane_mode_on 0
turn 2
off_at=$NOW
expect "tell: callback mode, then airplane mode off by something else: emergency, 5 minutes from then" \
	"$(told emergency $((off_at + 300)))" "$(last_word)"
run_for 150 10
expect "tell: ... past callback mode's 5 minutes: still emergency" "emergency 1" \
	"$(last_kind) $(test "$NOW" -gt $((em_at + 300)) && echo 1)"

# The time since boot unreadable, then readable again: unknown for the 5
# minutes from then, never ordinary.
watch_reset
: >"$WORDS"
turn 0
run_for 70 10
NOW=0
cell_step 0
cell_tell 0
cell_step 0
cell_tell 0
NOW=5000
turn 0
expect "tell: the time since boot readable again: unknown" unknown "$(last_kind)"
run_for 290 10
expect "tell: ... 290 s later: still unknown" unknown "$(last_kind)"
run_for 20 10
expect "tell: ... 5 minutes later: none" "$(told none 0)" "$(last_word)"
expect "tell: ... never ordinary" 0 "$(words_n calls:s:ordinary)"
TELL=0
FAKE_CALLS='' FAKE_HISTORY=0

# --- The module's word (MOD11): IMS registration -------------------------------------
# ims_fixture PHONE...: the phone process's dump (DebugService, PhoneFactory,
# Phone and ImsPhone as Android 16 prints them) with one phone per PHONE:
# STATE[:LAST] (STATE 0, 1, 2 or anything; LAST: WWAN, WLAN, reg (registering),
# unreg (unregistered)), "-" (no ImsPhone), "nostate", "twostates", or
# 17:STATE[:LAST] (Android 17: an emergency registration line, state 2).
ims_fixture() {
	echo 'SERVICE com.android.phone/.TelephonyDebugService 6a1 pid=1234 user=0'
	echo '  Client:'
	echo '    PhoneFactory:'
	echo '     sMadeDefaults=true'
	_if_i=0
	for _if_p in "$@"; do
		echo "      Phone: subId=$_if_i"
		echo '       isInEmergencyCall()=false'
		echo '       isInEcm()=false'
		echo '      ++++++++++++++++++++++++++++++++'
		if [ "$_if_p" != - ]; then
			echo '      ImsPhone extends:'
			echo '       isInEmergencyCall()=false'
			echo '      ++++++++++++++++++++++++++++++++'
			echo '      ImsPhone:'
			echo '        mDefaultPhone = Handler (com.android.internal.telephony.GsmCdmaPhone) {1a2b}'
			echo '        mIsPhoneInEcmState = false'
			_if_st=${_if_p#17:}
			_if_last=
			case $_if_st in *:*)
				_if_last=${_if_st#*:}
				_if_st=${_if_st%%:*}
				;;
			esac
			case $_if_st in
			nostate) ;;
			twostates) printf '        mImsMmTelRegistrationState = 2\n        mImsMmTelRegistrationState = 2\n' ;;
			*) echo "        mImsMmTelRegistrationState = $_if_st" ;;
			esac
			case $_if_p in 17:*) echo '        mImsMmTelEmergencyRegistrationState = 2' ;; esac
			echo '        mLastKnownRoamingState = 0'
			echo '       Registration Log:'
			echo '        2026-10-15T10:00:00.000 - handleImsRegistering: onImsMmTelProgressing imsRadioTech=LTE'
			case $_if_last in
			WWAN | WLAN) echo "        2026-10-15T10:00:01.000 - handleImsRegistered: onImsMmTelConnected imsTransportType=$_if_last" ;;
			reg) echo '        2026-10-15T10:00:02.000 - handleImsRegistering: onImsMmTelProgressing imsRadioTech=LTE' ;;
			unreg) echo '        2026-10-15T10:00:02.000 - handleImsUnregistered: onImsMmTelDisconnected imsRadioTech=LTE reason=0' ;;
			esac
			echo '      ++++++++++++++++++++++++++++++++'
		fi
		_if_i=$((_if_i + 1))
	done
	echo '    UiccController:'
	echo '    ++++++++++++++++++++++++++++++++'
}
ims() { ims_fixture "$@" | ims_state; }
expect "ims_state: registered over the cell network (WWAN)" cell "$(ims 2:WWAN)"
expect "ims_state: registered over Wi-Fi (WLAN: Wi-Fi calling)" wifi "$(ims 2:WLAN)"
expect "ims_state: registered, no registration line in the log" registered "$(ims 2)"
expect "ims_state: registered, the log's last line not a registration" registered "$(ims 2:reg)"
expect "ims_state: not registered (0)" none "$(ims 0:unreg)"
expect "ims_state: registering (1)" none "$(ims 1:reg)"
expect "ims_state: two phones, one registered over the cell network" cell "$(ims 0 2:WWAN)"
expect "ims_state: two phones on different bearers" registered "$(ims 2:WWAN 2:WLAN)"
expect "ims_state: one phone without IMS" none "$(ims 0 -)"
expect "ims_state: Android 17's emergency registration is not read" none "$(ims 17:0)"
expect "ims_state: Android 17, registered" cell "$(ims 17:2:WWAN)"
ims_text() { printf '%s\n' "$1" | ims_state; }
fails "ims_state: a block without the state line" ims nostate
fails "ims_state: two state lines in a block" ims twostates
fails "ims_state: a state that is not 0, 1 or 2" ims x
fails "ims_state: state 3" ims 3
fails "ims_state: no ImsPhone block" ims - -
fails "ims_state: the service not running" ims_text 'No services match: com.android.phone/com.android.phone.TelephonyDebugService'
fails "ims_state: empty input" ims_text ''

# ims_step, with a stand-in dump.
FAKE_IMS=$(ims_fixture 2:WWAN)
ims_dump() {
	echo "ims dump" >>"$STEPS"
	printf '%s\n' "$FAKE_IMS"
}
ims_at() { # NOW STARTED CELL ON_DONE RADIO CALL: ims_step in that state
	: >"$STEPS"
	S_STARTED=$2 SES_CELL=$3 CELL_ON_DONE=$4 CL_RADIO=$5 CL_CALL=$6 CL_CBM=0 CELL_LAST='' CELL_LOOKED=$1
	ims_step "$1"
}
CELL_IMS=cell CELL_IMS_AT=500 CELL_IMS_NEXT=0
ims_at 1000 1 off 1 on 0
expect "ims_step: outside Phone mode: off" "off 0" "$CELL_IMS $CELL_IMS_AT"
step_check "ims_step: outside Phone mode: no dump" steps_empty
ims_at 1000 0 phone 0 off 0
step_check "ims_step: Phone mode before Start: no dump" steps_empty
ims_at 1000 1 phone 1 on 1
step_check "ims_step: during a call: no dump" steps_empty
ims_at 1000 1 phone 0 off 0
step_check "ims_step: before the module's switch-on: no dump" steps_empty
ims_at 1000 1 phone 1 on 0
expect "ims_step: Phone mode, the radio on, nothing holding: read" "cell 1000" "$CELL_IMS $CELL_IMS_AT"
ims_at 1290 1 phone 1 on 0
step_check "ims_step: not again within 300 s" steps_empty
FAKE_IMS='No services match'
ims_at 1300 1 phone 1 on 0
expect "ims_step: an unreadable dump: unknown" "unknown 1300" "$CELL_IMS $CELL_IMS_AT"
# The word in Phone mode carries the IMS reading, told when it changes and
# every 300 s.
: >"$WORDS"
CELL_WORD='' CELL_WORD_BAD=0 CELL_TOLD_AT='' CELL_EM_AT='' CELL_UNK_AT='' CL_CALL=0 CL_CBM=0
CELL_IMS=cell CELL_IMS_AT=1300
CELL_LOOKED=1310
cell_tell 1310
expect "tell: Phone mode: the IMS reading goes with the word" "$(told none 0 cell 1300)" "$(last_word)"
CELL_LOOKED=1400
cell_tell 1400
expect "tell: Phone mode: not again before 300 s" 1 "$(words_n)"
CELL_LOOKED=1610
cell_tell 1610
expect "tell: Phone mode: again 300 s later" 2 "$(words_n)"
CELL_IMS=wifi CELL_IMS_AT=1615 CELL_LOOKED=1620
cell_tell 1620
expect "tell: Phone mode: at once when the reading changes" "$(told none 0 wifi 1615)" "$(last_word)"
CELL_IMS=off CELL_IMS_AT=0 S_STARTED=0 SES_CELL=off

# --- WEL8: the Phone-mode gate --------------------------------------------------------
# cell_gate reads the gate file (CELL_GATE_FILE, the tests' own) with the
# owner check replaced (FAKE_GATE_OWNER).
gate_of() {
	printf '%b' "$1" >"$CELL_GATE_FILE"
	cell_gate
}
rm -f "$CELL_GATE_FILE"
expect "cell_gate: no file (as installed): off" off "$(cell_gate)"
CELL_EMULATOR=0
expect "cell_gate: phone" phone "$(gate_of 'phone\n')"
expect "cell_gate: phone without a newline" phone "$(gate_of 'phone')"
expect "cell_gate: data on a phone: phone (until FW9 and CI12)" phone "$(gate_of 'data\n')"
expect "cell_gate: data on a phone with CELL_DATA_ON_PHONE=1: data" data "$(CELL_DATA_ON_PHONE=1; gate_of 'data\n')"
CELL_EMULATOR=1
expect "cell_gate: data on the emulator" data "$(gate_of 'data\n')"
expect "cell_gate: the first line only" data "$(gate_of 'data\nphone\n')"
for c in 'PHONE\n' 'Phone\n' 'phone data\n' 'phone \n' ' phone\n' '\n' '' 'phone\r\n' 'off\n' 'calls\n' \
	'\nphone\n' 'phone\tx\n' 'dat\n' 'datas\n'; do
	expect "cell_gate: only the exact words count: [$c]" off "$(gate_of "$c")"
done
printf 'phone\n' >"$CELL_GATE_FILE"
expect "cell_gate: another owner, or group or others may write: off" off "$(FAKE_GATE_OWNER=bad cell_gate)"
mv "$CELL_GATE_FILE" "$LOGDIR/gate-target"
ln -s "$LOGDIR/gate-target" "$CELL_GATE_FILE"
expect "cell_gate: a link: off" off "$(cell_gate)"
rm -f "$CELL_GATE_FILE"
mkdir "$CELL_GATE_FILE"
expect "cell_gate: a directory: off" off "$(cell_gate)"
rmdir "$CELL_GATE_FILE"
expect "cell_gate: the file is the contract's" /data/adb/antumbra-cell \
	"$(sed -n 's/^CELL_GATE_FILE=//p' "$MODULE/lib/antumbra.sh")"

# install.md's commands for the gate, as adb and su carry them out. 'adb
# shell' joins its arguments with spaces and quotes nothing (as ssh does);
# the phone's shell, as the shell user, parses that line, and a
# redirection in it runs there, before su, where /data/adb cannot be
# written. Played here: each documented line runs in this shell with a
# stand-in adb that keeps the joined line; that line runs in a shell to
# which /data/adb does not exist (the shell user cannot create or read
# anything in it); the stand-in su joins its arguments after -c, as
# Magisk's does, and runs them where /data/adb exists (root). A command
# that would fail on the phone fails here too (the control: the form the
# guide gave first).
AS=$LOGDIR/adbsim
mkdir -p "$AS/bin" "$AS/root/data/adb"
cat >"$AS/bin/adb" <<'FAKE'
#!/bin/sh
[ "$1" = shell ] || exit 2
shift
printf '%s\n' "$*" >"$AS_LINE"
FAKE
cat >"$AS/bin/su" <<'FAKE'
#!/bin/sh
[ "$1" = -c ] || exit 2
shift
echo "su -c $*" >>"$AS_SU_LOG"
exec /bin/sh -c "$(printf '%s\n' "$*" | sed "s|$AS_SHELL|$AS_ROOT|g")"
FAKE
chmod +x "$AS/bin/adb" "$AS/bin/su"
# as_phone LINE: LINE typed on the host; prints what the phone's shell
# prints (and its errors). Both run in /bin/sh: busybox's own sh would run
# its su applet rather than the stand-in.
as_phone() {
	rm -f "$AS/line"
	env AS_LINE="$AS/line" PATH="$AS/bin:$PATH" /bin/sh -c "$1" || return 1
	[ -s "$AS/line" ] || return 1
	env AS_SHELL="$AS/shell" AS_ROOT="$AS/root" AS_SU_LOG="$AS/su.log" PATH="$AS/bin:$PATH" \
		/bin/sh -c "$(sed "s|/data/adb|$AS/shell/data/adb|g" "$AS/line")" 2>&1
}
# gate_shown: the check command shows the file 0600, saying phone.
gate_shown() {
	_gs=$(as_phone "$(gate_cmd 'ls -l')")
	printf '%s\n' "$_gs" | grep -q '^-rw------- ' && printf '%s\n' "$_gs" | grep -q -x phone
}
INSTALL_MD=$MODULE/../docs/install.md
# shellcheck disable=SC2016 # Markdown's backticks, not the shell's
gate_cmds=$(sed -n -e 's/^ *\(adb shell .*antumbra-cell.*\)$/\1/p' \
	-e 's/.*`\(adb shell [^`]*antumbra-cell[^`]*\)`.*/\1/p' "$INSTALL_MD")
gate_cmd() { printf '%s\n' "$gate_cmds" | grep -F -- "$1"; }
expect "install.md: three commands for the gate (write, check, delete)" "3 1 1 1" \
	"$(printf '%s\n' "$gate_cmds" | grep -c .) $(gate_cmd '> /data/adb/antumbra-cell' | grep -c .) \
$(gate_cmd 'ls -l' | grep -c .) $(gate_cmd 'rm -f' | grep -c .)"
: >"$AS/su.log"
as_phone "$(gate_cmd '> /data/adb/antumbra-cell')" >"$AS/out" 2>&1
expect "install.md: the gate written as root, 0600, saying phone" "600 phone" \
	"$(stat -c %a "$AS/root/data/adb/antumbra-cell" 2>/dev/null) $(cat "$AS/root/data/adb/antumbra-cell" 2>/dev/null)"
expect "install.md: ... read as the gate" phone "$(CELL_GATE_FILE=$AS/root/data/adb/antumbra-cell cell_gate)"
step_check "install.md: ... the redirection ran in su" grep -q -F "su -c echo phone > " "$AS/su.log"
step_check "install.md: the check shows the file's mode and its word" gate_shown
as_phone "$(gate_cmd 'rm -f')" >/dev/null 2>&1
step_check "install.md: the gate deleted" test ! -e "$AS/root/data/adb/antumbra-cell"
# shellcheck disable=SC2016 # the guide's first form, as typed on the host
as_phone 'adb shell su -c "printf '\''phone\n'\'' > /data/adb/antumbra-cell && chmod 0600 /data/adb/antumbra-cell"' >/dev/null 2>&1
step_check "install.md control: a redirection outside su's one argument writes nothing" \
	test ! -e "$AS/root/data/adb/antumbra-cell"
expect "cell_gate: mobile data through Tor is the emulator's only, until FW9 and CI12" 0 \
	"$(sed -n 's/^CELL_DATA_ON_PHONE=//p' "$MODULE/lib/antumbra.sh")"
CELL_EMULATOR=0

# cell_effective: the lowest of the choice, the gate at Start and the gate now.
S_STARTED=0 SES_CELL=data SES_GATE=data CELL_GATE=data
expect "cell_effective: before Start: none" none "$(cell_effective)"
S_STARTED=1
for c in off phone data; do
	for g0 in off phone data; do
		for g in off phone data; do
			e=$c
			[ "$(cell_rank "$g0")" -ge "$(cell_rank "$e")" ] || e=$g0
			[ "$(cell_rank "$g")" -ge "$(cell_rank "$e")" ] || e=$g
			expect "cell_effective: choice $c, gate at Start $g0, gate now $g" "$e" \
				"$(SES_CELL=$c SES_GATE=$g0 CELL_GATE=$g cell_effective)"
		done
	done
done
expect "cell_effective: a gate raised during the session changes nothing" off \
	"$(SES_CELL=phone SES_GATE=off CELL_GATE=data cell_effective)"
expect "cell_effective: a gate lowered during the session counts at once" phone \
	"$(SES_CELL=data SES_GATE=data CELL_GATE=phone cell_effective)"
expect "cell_rank: anything else is off" 0 "$(cell_rank Phone)"
S_STARTED=0 SES_CELL=off SES_GATE=phone CELL_GATE=phone

# --- WEL8: the cell radio and mobile data per session, turn by turn ---------------------
# wel8_reset GATE CHOICE: a start with the radio off since power-on, the
# gate file saying GATE ("-": no file), the session's choice CHOICE (not
# started yet), the firewall live, nothing told to Welcome yet.
wel8_reset() {
	watch_reset
	if [ "$1" = - ]; then rm -f "$CELL_GATE_FILE"; else printf '%s\n' "$1" >"$CELL_GATE_FILE"; fi
	FAKE_GATE_OWNER=ok CELL_GATE=off CELL_GATE_SEEN='' SES_GATE=off SES_CELL=$2 S_FW_STATE=live CELL_DATA_ON=0
	CELL_OFFER='' CELL_OFFER_AT='' CELL_OFFER_SID='' CELL_OFFER_BAD=0 CELL_OFFER_BAD_AT=0 CELL_OFFER_TOLD=''
	WELCOME_SID=0123456789abcdef
}
# wel8_start: the session starts as session_read starts it (the gate in
# force latched).
wel8_start() {
	SES_GATE=$(cell_gate)
	CELL_GATE=$SES_GATE
	S_STARTED=1
}
count() { grep -c -x -F "$1" "$STEPS"; }
# before_last A B: the last step A came before the last step B.
before_last() {
	_bl_a=$(grep -n -x -F "$1" "$STEPS" | tail -n 1 | cut -d: -f1)
	_bl_b=$(grep -n -x -F "$2" "$STEPS" | tail -n 1 | cut -d: -f1)
	[ -n "$_bl_a" ] && [ -n "$_bl_b" ] && [ "$_bl_a" -lt "$_bl_b" ]
}

# 1. Calls and texts chosen, no gate (every phone as installed): the radio
# stays off, before and after Start.
wel8_reset - phone
run_for 60
wel8_start
run_for 600 10
step_check "gate off: Phone chosen: the radio never switched on" did_not "airplane disable"
step_check "gate off: Phone chosen: logged" said "this phone's Phone-mode gate: off"
step_check "gate off: not Phone mode" eval '! cell_phone_mode'
expect "gate off: ims off" "off 0" "$CELL_IMS $CELL_IMS_AT"

# 2. The gate raised during a session started without it: nothing changes
# until the next start.
printf 'phone\n' >"$CELL_GATE_FILE"
run_for 600 10
step_check "gate raised during the session: logged" said "Phone-mode gate now phone"
step_check "gate raised during the session: the radio still off" did_not "airplane disable"

# 3. Calls and texts with the gate: switched on at Start only (D12).
wel8_reset phone phone
run_for 60
step_check "gate phone: nothing before Start (D12)" did_not "airplane disable"
wel8_start
turn 2
step_check "gate phone: switched on at Start" did "airplane disable"
run_for 60 10
step_check "gate phone: Phone mode" cell_phone_mode
step_check "gate phone: mobile data never switched on" did_not "data enable"
# The gate taken away during the session, no call: off at the next look.
: >"$STEPS"
rm -f "$CELL_GATE_FILE"
run_for 20 10
step_check "gate removed during a Phone session, no call: the radio off" did "airplane enable"
step_check "gate removed: no longer Phone mode" eval '! cell_phone_mode'
step_check "gate removed: logged" said "Phone-mode gate now off"
step_check "gate removed: the session keeps it: logged" said "the Phone-mode gate went down to off; it stays so for this session"
# The gate written again in the same session: the lower gate holds until
# the next start, also when airplane mode then reads off with the radio
# off (as after a phone-process restart), where Phone mode would switch
# the radio on.
: >"$STEPS"
: >"$LOGDIR/module.log"
printf 'phone\n' >"$CELL_GATE_FILE"
run_for 30 10
step_check "gate removed, then written again: seen" said "Phone-mode gate now phone"
expect "gate removed, then written again: the session keeps off (gate, carried out, wanted)" "off off off" \
	"$SES_GATE $(cell_effective) $(cell_want)"
step_check "gate removed, then written again: not Phone mode" eval '! cell_phone_mode'
fake_set airplane_mode_on 0
fake_set cell_on 1
FAKE_RADIO=0
run_for 600 10
step_check "gate removed, then written again: the radio never switched on again" did_not "airplane disable"
expect "gate removed, then written again: no second lowering logged" 0 \
	"$(grep -c 'it stays so for this session' "$LOGDIR/module.log")"
# The same after a call: held for 5 minutes after it.
wel8_reset phone phone
run_for 40
wel8_start
run_for 60 10
FAKE_CALLS=ACTIVE FAKE_HISTORY=1 FAKE_PHONE0='2 0 1 0 0 0'
run_for 30 10
FAKE_CALLS='' FAKE_PHONE0=$I
run_for 10 10
: >"$STEPS"
rm -f "$CELL_GATE_FILE"
run_for 280 10
step_check "gate removed right after a call: held (5 minutes after the call)" did_not "airplane enable"
step_check "gate removed right after a call: ... logged" said "held: recent"
run_for 30 10
step_check "gate removed right after a call: off 5 minutes after it" did "airplane enable"

# 4. Mobile data through Tor (the emulator: the gate may say data).
CELL_EMULATOR=1
wel8_reset data data
run_for 60
step_check "data: nothing before Start" eval 'did_not "airplane disable" && did_not "data enable"'
wel8_start
turn 2
step_check "data: the radio switched on at Start" did "airplane disable"
step_check "data: mobile data not yet (the radio not read on yet)" did_not "data enable"
turn 2
step_check "data: mobile data on once the radio reads on" did "data enable"
step_check "data: ... after the switch-on" before "airplane disable" "data enable"
step_check "data: ... and after the switch-on's own mobile data off" before_last "mobile data off" "data enable"
step_check "data: logged" said "mobile data on (the session's Internet is mobile data)"
run_for 120 10
expect "data: once" 1 "$(count "data enable")"
step_check "data: Phone mode (calls and texts come with it)" cell_phone_mode
# A SIM's state changes: mobile data off for every SIM, then on again for
# the session; not held by a call.
FAKE_CALLS=ACTIVE FAKE_HISTORY=1 FAKE_PHONE0='2 0 1 0 0 0'
run_for 20 10
: >"$STEPS"
PROPS='gsm.sim.state=LOADED,ABSENT'
run_for 20 10
step_check "data: a SIM change: mobile data off, then on again (a call does not hold it)" \
	before "mobile data off" "data enable"
FAKE_CALLS='' FAKE_PHONE0=$I
# The person switches airplane mode on, then off: the radio and mobile data
# come back.
run_for 10 10
: >"$STEPS"
fake_set airplane_mode_on 1
fake_set cell_on 2
FAKE_RADIO=0
run_for 30 10
step_check "data: airplane mode on by the person: left alone" eval 'did_not "airplane disable" && did_not "data enable"'
fake_set airplane_mode_on 0
fake_set cell_on 1
fake_set enable_cellular_on_boot 1
FAKE_RADIO=1
run_for 30 10
step_check "data: airplane mode off again: mobile data off, then on again" before_last "mobile data off" "data enable"
# The gate lowered to phone: mobile data off at once, the radio stays on.
: >"$STEPS"
printf 'phone\n' >"$CELL_GATE_FILE"
turn 2
step_check "data, the gate lowered to phone: mobile data off at once" did "mobile data off"
step_check "data, the gate lowered to phone: logged" said "mobile data off (this phone's gate no longer allows it)"
run_for 400 10
step_check "data, the gate lowered to phone: the radio stays on, mobile data stays off" eval \
	'did_not "airplane enable" && did_not "data enable"'
step_check "data, the gate lowered to phone: still Phone mode" cell_phone_mode
# Written back to data in the same session: mobile data stays off until
# the next start.
: >"$STEPS"
printf 'data\n' >"$CELL_GATE_FILE"
run_for 60 10
step_check "data, the gate lowered to phone, then data again: mobile data stays off" did_not "data enable"
expect "data, the gate lowered to phone, then data again: phone carried out" "phone phone" "$SES_GATE $(cell_effective)"

# Not before the firewall is live; never while the fail-safe holds the radios.
wel8_reset data data
run_for 40
S_FW_STATE=armed
wel8_start
run_for 60 10
step_check "data: not while the firewall is not live" did_not "data enable"
S_FW_STATE=live
run_for 10 10
step_check "data: ... on once it is live" did "data enable"
wel8_reset data data
run_for 40
wel8_start
RADIOS=switched
run_for 60 10
step_check "data: never once the fail-safe switched the radios off" did_not "data enable"
RADIOS=''
CELL_EMULATOR=0

# 5. Mobile data kept off in every session that did not choose it.
wel8_reset phone phone
run_for 40
wel8_start
run_for 60 10
: >"$STEPS"
fake_set mobile_data1 1
run_for 10 10
step_check "Phone session: mobile data switched on in Settings: off again" did "mobile data off"
step_check "Phone session: ... logged" said "mobile data was switched on; off again"
fake_set mobile_data1 0
: >"$STEPS"
run_for 60 10
step_check "Phone session: nothing more once it is off" did_not "mobile data off"
wel8_reset phone off
FAKE_RADIO=1
run_for 20 10
: >"$STEPS"
fake_set mobile_data 1
run_for 10 10
step_check "before Start, the radio on by something else: mobile data off again" did "mobile data off"
fake_set mobile_data 0
wel8_reset - off
run_for 40
wel8_start
run_for 60 10
fake_set mobile_data2 1
: >"$STEPS"
run_for 120 10
step_check "Phone off, the radio read off: nothing read or written" did_not "mobile data off"
fake_set mobile_data2 0

# 6. MOD11's "ordinary" in a mobile-data session (Phone mode), and IMS.
CELL_EMULATOR=1
wel8_reset data data
TELL=1
: >"$WORDS"
run_for 40
wel8_start
run_for 60 10
FAKE_CALLS=ACTIVE FAKE_HISTORY='1:open' FAKE_PHONE0='2 0 1 0 0 0'
run_for 40 10
expect "data session: an ordinary call reads ordinary (Phone mode)" ordinary "$(last_kind)"
FAKE_CALLS='' FAKE_HISTORY=1 FAKE_PHONE0=$I
run_for 20 10
expect "data session: the call ended: ordinary" ordinary "$(last_kind)"
printf 'off\n' >"$CELL_GATE_FILE"
run_for 10 10
step_check "data session, the gate taken away: not Phone mode" eval '! cell_phone_mode'
expect "data session, the gate taken away: IMS off" "off 0" "$CELL_IMS $CELL_IMS_AT"
TELL=0
CELL_EMULATOR=0

# --- WEL8: the module's word on the cell radio (module_cell) ------------------------------
CELLS=$LOGDIR/cells
FAKE_CELL_ANSWER=$OK_ANSWER
cell_send() {
	echo "$*" >>"$CELLS"
	[ -z "$FAKE_CELL_ANSWER" ] || printf '%s\n' "$FAKE_CELL_ANSWER"
	return 0
}
cells_n() { if [ -s "$CELLS" ]; then grep -c . "$CELLS"; else echo 0; fi; }
last_cell() { tail -n 1 "$CELLS"; }
cell_args() { echo "--extra v:i:1 --extra gate:s:$1 --extra cell:s:$2 --extra radio:s:$3 --extra at:l:$4"; }
# offer_for SECONDS: turns 10 s apart, each followed by the word on the
# cell radio, as in service.sh's loop.
offer_for() {
	_of_end=$((NOW + $1))
	while [ "$NOW" -lt "$_of_end" ]; do
		turn 10
		cell_offer_tell "$NOW"
	done
}
wel8_reset phone phone
: >"$CELLS"
turn 0
cell_offer_tell "$NOW"
expect "module_cell: the first turn: the gate, nothing carried out yet, the radio as looked at" \
	"$(cell_args phone none off 1000)" "$(last_cell)"
expect "module_cell: ... the try noted for the port check" 1000 "$CELL_OFFER_TOLD"
offer_for 290
expect "module_cell: nothing more while nothing changes" 1 "$(cells_n)"
offer_for 10
expect "module_cell: again every 300 s, with the last look's time" "2 $(cell_args phone none off "$CELL_LOOKED")" \
	"$(cells_n) $(last_cell)"
WELCOME_SID=fedcba9876543210
offer_for 10
expect "module_cell: Welcome's process started again (a new session ID): told again" 3 "$(cells_n)"
printf 'data\n' >"$CELL_GATE_FILE"
offer_for 10
expect "module_cell: data on a phone is still phone: nothing new" 3 "$(cells_n)"
CELL_EMULATOR=1
offer_for 10
expect "module_cell: the gate changed: told" "$(cell_args data none off "$CELL_LOOKED")" "$(last_cell)"
CELL_EMULATOR=0
printf 'phone\n' >"$CELL_GATE_FILE"
offer_for 10
wel8_start
n=$(cells_n)
offer_for 10
expect "module_cell: at Start: what the module carries out" "phone" \
	"$(last_cell | sed -n 's/.*cell:s:\([a-z]*\) .*/\1/p')"
offer_for 20
no_at() { sed 's/ --extra at:l:[0-9]*$//'; }
expect "module_cell: the radio read on after the switch-on: told" "$(cell_args phone phone on 0 | no_at)" \
	"$(last_cell | no_at)"
step_check "module_cell: one word per change" test "$(cells_n)" -le $((n + 3))
FAKE_OWNER=0
n=$(cells_n)
rm -f "$CELL_GATE_FILE"
offer_for 400
expect "module_cell: never while Welcome is not the device owner" "$n" "$(cells_n)"
FAKE_OWNER=1
offer_for 10
expect "module_cell: ... told once it is (the gate gone: the radio off)" "$(cell_args off off off "$CELL_LOOKED")" \
	"$(last_cell)"
# Welcome refuses it (a Welcome from before WEL8: "Unknown method").
: >"$LOGDIR/module.log"
FAKE_CELL_ANSWER=''
printf 'phone\n' >"$CELL_GATE_FILE"
n=$(cells_n)
offer_for 10
expect "module_cell: Welcome refuses it: tried" $((n + 1)) "$(cells_n)"
# Again after 30 s, then after twice as long each time, up to 300 s.
k=1
for wait in 30 60 120 240 300 300; do
	offer_for $((wait - 10))
	expect "module_cell: Welcome refuses it: not again before $wait s" $((n + k)) "$(cells_n)"
	offer_for 10
	k=$((k + 1))
	expect "module_cell: Welcome refuses it: tried again after $wait s" $((n + k)) "$(cells_n)"
done
expect "module_cell: the refusal logged once" 1 "$(grep -c 'did not take the module.s word on the cell radio' "$LOGDIR/module.log")"
FAKE_CELL_ANSWER=$OK_ANSWER
offer_for 310
expect "module_cell: taken again: logged once" 1 "$(grep -c "takes the module's word on the cell radio again" "$LOGDIR/module.log")"
step_check "module_cell: the log names no word" test -z "$(grep -E 'gate:s|cell:s|radio:s|at:l' "$LOGDIR/module.log")"
# While the module reads Welcome's row without the cell column (an older
# Welcome, WELCOME_OLD), it carries out nothing above off for it: the gate
# told is off, whatever the file says; the real gate again once the row is
# read with the column.
last_gate() { last_cell | sed -n 's/.*gate:s:\([a-z]*\) .*/\1/p'; }
wel8_reset phone off
: >"$CELLS"
offer_for 10
expect "module_cell: the gate file says phone: told phone" phone "$(last_gate)"
WELCOME_OLD=1
offer_for 10
expect "module_cell: Welcome's row read without the cell column: the gate told is off" off "$(last_gate)"
offer_for 300
step_check "module_cell: ... and stays off while it is" test -z "$(grep -v -F 'gate:s:off' "$CELLS" | sed 1d)"
WELCOME_OLD=0
offer_for 10
expect "module_cell: the row read with the column again: the gate told is phone" phone "$(last_gate)"
step_check "module_cell: status.json holds nothing of it" test -z "$(sed -n '/^status_write() {$/,/^}$/p' \
	"$MODULE/lib/antumbra.sh" | grep -E 'GATE|SES_CELL|CL_RADIO|CELL_|SIM|sim')"
expect "module_cell: the method and the provider" "module_cell content://org.antumbra.welcome.state" \
	"$CELL_OFFER_METHOD $WORD_URI"

# --- WEL8: session_read and session_cell (service.sh, cut out of it) ------------------------
eval "$(sed -n '/^session_cell() {$/,/^}$/p' "$MODULE/service.sh")"
eval "$(sed -n '/^session_row() {$/,/^}$/p' "$MODULE/service.sh")"
eval "$(sed -n '/^session_read() {$/,/^}$/p' "$MODULE/service.sh")"
PRIV=$LOGDIR/priv
mkdir -p "$PRIV"
SID=0123456789abcdef0123456789abcdef
# FAKE_ROW_OUT: what 'content query' prints (output and error) for the new
# projection; FAKE_OLD_ROW: its row for the old one.
welcome_row() { printf '%s\n' "$FAKE_ROW_OUT" | welcome_row_pick; }
welcome_query() {
	echo "query $1" >>"$STEPS"
	[ -n "$FAKE_OLD_ROW" ] || return 1
	printf '%s\n' "$FAKE_OLD_ROW"
}
row_of() { echo "Row: 0 started=$1, tor_mode=$2, mac=new, session_id=$SID, cell=$3"; }
# shellcheck disable=SC2016 # a stack trace, as the tool prints it
UNKNOWN_CELL='Error while accessing provider:org.antumbra.welcome.state
java.lang.IllegalArgumentException: Unknown column: cell
	at org.antumbra.welcome.StateRow.columns(StateProvider.kt:96)
	at android.content.ContentProvider$Transport.query(ContentProvider.java:285)'
sr_reset() {
	# shellcheck disable=SC2034 # read by session_read
	S_STARTED=0 WELCOME_OLD=0 WELCOME_OLD_SID='' SES_CELL=off SES_GATE=off FAKE_OLD_ROW='' P_WELCOME='' FAKE_OWNER=1
	: >"$LOGDIR/module.log"
	: >"$STEPS"
	rm -f "$PRIV/session"
}
sr() { if session_read >/dev/null 2>&1; then echo started; else echo waiting; fi; }
expect "session_cell: off" off "$(session_cell "$(row_of 1 direct off)")"
expect "session_cell: phone" phone "$(session_cell "$(row_of 1 offline phone)")"
expect "session_cell: data" data "$(session_cell "$(row_of 1 bridges data)")"
for c in '' Phone 'phone ' calls none; do
	if session_cell "$(row_of 1 direct "$c")" >/dev/null; then bad "session_cell: took [$c]"; else ok "session_cell: refuses [$c]"; fi
done
if session_cell "$(row_of 1 offline data)" >/dev/null; then bad "session_cell: took data with offline"; else
	ok "session_cell: refuses data in an offline session"
fi
expect "welcome_row_pick: a row (after a line on standard error)" "$(row_of 0 offline off)" \
	"$(printf 'WARNING: linker: something\n%s\n' "$(row_of 0 offline off)" | welcome_row_pick)"
expect "welcome_row_pick: an older Welcome" 2 "$(printf '%s\n' "$UNKNOWN_CELL" | welcome_row_pick; echo $?)"
expect "welcome_row_pick: nothing" 1 "$(printf '' | welcome_row_pick; echo $?)"
for e in 'Error while accessing provider:org.antumbra.welcome.state' \
	'java.lang.IllegalArgumentException: Unknown column: cellular' \
	'java.lang.SecurityException: uid 2000 may not read the Antumbra session' 'No result found.'; do
	expect "welcome_row_pick: [$e]: still waiting" 1 "$(printf '%s\n' "$e" | welcome_row_pick; echo $?)"
done
sr_reset
printf 'phone\n' >"$CELL_GATE_FILE"
FAKE_ROW_OUT=$(row_of 0 offline off)
WELCOME_SID=''
expect "session_read: not started: waiting" waiting "$(sr)"
session_read >/dev/null 2>&1
expect "session_read: before Start the session ID is noted (a new Welcome process)" "$SID" "$WELCOME_SID"
FAKE_ROW_OUT=$(row_of 1 direct phone)
session_read >/dev/null 2>&1
expect "session_read: Phone with the gate: the choice and the gate latched" "1 phone phone" \
	"$S_STARTED $SES_CELL $SES_GATE"
expect "session_read: the root-only record has the cell and the gate" \
	"session_id=$SID tor_mode=direct mac=new cell=phone gate=phone" "$(tr '\n' ' ' <"$PRIV/session" | sed 's/ $//')"
step_check "session_read: logged" said "session started (tor direct, MAC new, cell radio phone, gate phone)"
sr_reset
rm -f "$CELL_GATE_FILE"
FAKE_ROW_OUT=$(row_of 1 offline phone)
session_read >/dev/null 2>&1
expect "session_read: Phone without the gate: the choice kept, the gate off" "1 phone off off" \
	"$S_STARTED $SES_CELL $SES_GATE $(cell_effective)"
step_check "session_read: ... logged" said "the session chose phone; this phone's gate allows off, so the module carries out off"
for c in Phone '' calls; do
	sr_reset
	FAKE_ROW_OUT=$(row_of 1 direct "$c")
	expect "session_read: cell [$c]: still waiting" waiting "$(sr)"
	session_read >/dev/null 2>&1
	step_check "session_read: cell [$c]: logged" said "the row has an invalid cell; still waiting"
done
sr_reset
FAKE_ROW_OUT=$(row_of 1 offline data)
expect "session_read: data in an offline session: still waiting" waiting "$(sr)"
# An older Welcome: read without the cell column; the radio stays off.
sr_reset
printf 'phone\n' >"$CELL_GATE_FILE"
FAKE_ROW_OUT=$UNKNOWN_CELL
FAKE_OLD_ROW="Row: 0 started=1, tor_mode=direct, mac=new, session_id=$SID"
session_read >/dev/null 2>&1
expect "session_read: an older Welcome: started, cell off" "1 off 1" "$S_STARTED $SES_CELL $WELCOME_OLD"
step_check "session_read: an older Welcome: logged" said "this Welcome has no cell column (an older one)"
step_check "session_read: an older Welcome: the old columns asked" did "query started:tor_mode:mac:session_id"
S_STARTED=0
session_read >/dev/null 2>&1
expect "session_read: an older Welcome: logged once" 1 "$(grep -c 'has no cell column' "$LOGDIR/module.log")"
# Before Start, the same Welcome process is read without the column; a new
# one (a new session ID: an updated Welcome perhaps) with it again.
sr_reset
FAKE_ROW_OUT=$UNKNOWN_CELL
FAKE_OLD_ROW="Row: 0 started=0, tor_mode=offline, mac=new, session_id=$SID"
session_read >/dev/null 2>&1
expect "session_read: an older Welcome before Start: latched with its session" "0 1 $SID" \
	"$S_STARTED $WELCOME_OLD $WELCOME_OLD_SID"
: >"$STEPS"
session_read >/dev/null 2>&1
step_check "session_read: the same Welcome process: still read without the column" did "query started:tor_mode:mac:session_id"
expect "session_read: the same Welcome process: still an older one, logged once" "1 1" \
	"$WELCOME_OLD $(grep -c 'has no cell column' "$LOGDIR/module.log")"
SID_OLD=$SID
SID=fedcba9876543210fedcba9876543210
FAKE_OLD_ROW="Row: 0 started=1, tor_mode=direct, mac=new, session_id=$SID"
FAKE_ROW_OUT=$(row_of 1 direct phone)
session_read >/dev/null 2>&1
expect "session_read: a new Welcome process with the column: read with it, Phone kept" "1 0 phone phone" \
	"$S_STARTED $WELCOME_OLD $SES_CELL $SES_GATE"
step_check "session_read: ... logged" said "Welcome started again (a new session); its row is read with the cell column again"
expect "session_read: ... its session ID noted" "$SID" "$WELCOME_SID"
# A new process of an older Welcome again: latched again, with its session.
sr_reset
SID=$SID_OLD
FAKE_ROW_OUT=$UNKNOWN_CELL
FAKE_OLD_ROW="Row: 0 started=0, tor_mode=offline, mac=new, session_id=$SID"
session_read >/dev/null 2>&1
SID=fedcba9876543210fedcba9876543210
FAKE_OLD_ROW="Row: 0 started=0, tor_mode=offline, mac=new, session_id=$SID"
session_read >/dev/null 2>&1
expect "session_read: a new process of an older Welcome: latched again with its session" "1 $SID" \
	"$WELCOME_OLD $WELCOME_OLD_SID"
SID=$SID_OLD
# Latched while its row without the column could not be read: the next row
# is that process's, not a new one (latched and logged once).
sr_reset
FAKE_ROW_OUT=$UNKNOWN_CELL
FAKE_OLD_ROW=''
session_read >/dev/null 2>&1
FAKE_OLD_ROW="Row: 0 started=0, tor_mode=offline, mac=new, session_id=$SID"
session_read >/dev/null 2>&1
expect "session_read: latched before its first row was read: that process's, logged once" "1 $SID 1" \
	"$WELCOME_OLD $WELCOME_OLD_SID $(grep -c 'has no cell column' "$LOGDIR/module.log")"
# The same answer from a provider while Welcome is not the device owner:
# not taken for an older Welcome.
sr_reset
FAKE_ROW_OUT=$UNKNOWN_CELL
FAKE_OLD_ROW="Row: 0 started=1, tor_mode=direct, mac=new, session_id=$SID"
FAKE_OWNER=0
expect "session_read: 'Unknown column' while Welcome is not the device owner: waiting" waiting "$(sr)"
# Not in a subshell, so that what it sets can be seen.
session_read >/dev/null 2>&1
expect "session_read: ... not taken for an older Welcome" "0 0" "$S_STARTED $WELCOME_OLD"
FAKE_OWNER=1
# A passing failure (no answer at all) is not an older Welcome.
sr_reset
FAKE_ROW_OUT=''
expect "session_read: no answer: waiting" waiting "$(sr)"
session_read >/dev/null 2>&1
expect "session_read: no answer: not an older Welcome" "0 0" "$S_STARTED $WELCOME_OLD"
step_check "session_read: no answer: the old columns not asked" did_not "query started:tor_mode:mac:session_id"
sr_reset
S_STARTED=0 SES_CELL=off SES_GATE=phone CELL_GATE=phone
printf 'phone\n' >"$CELL_GATE_FILE"

# --- MOD7: Wi-Fi calling and video calling off (ims_off, ims_off_restore) -------------
# Stand-ins on PATH: getprop and setprop over a file of NAME=VALUE lines,
# and Magisk's resetprop (in a directory of its own, left off PATH for the
# emulator, which has none), which logs its arguments. The real prop_set
# and prop_clear are used.
unset -f getprop 2>/dev/null
PB=$LOGDIR/propbin
MB=$LOGDIR/magiskbin
mkdir -p "$PB" "$MB"
PROPS_FILE=$LOGDIR/props
RESETPROP_LOG=$LOGDIR/resetprop.log
export PROPS_FILE RESETPROP_LOG
# shellcheck disable=SC2016 # the stand-in's lines, expanded when it runs
printf '%s\n' '#!/bin/sh' \
	'awk -v n="$1" '\''index($0, n "=") == 1 { v = substr($0, length(n) + 2) } END { print v }'\'' "$PROPS_FILE"' \
	>"$PB/getprop"
# shellcheck disable=SC2016 # the stand-in's lines, expanded when it runs
printf '%s\n' '#!/bin/sh' \
	'[ "${FAKE_SET_FAILS-}" = 1 ] && exit 1' \
	'awk -v n="$1" '\''index($0, n "=") != 1'\'' "$PROPS_FILE" >"$PROPS_FILE.new"' \
	'[ -n "$2" ] && printf '\''%s=%s\n'\'' "$1" "$2" >>"$PROPS_FILE.new"' \
	'mv -f "$PROPS_FILE.new" "$PROPS_FILE"' \
	>"$PB/setprop"
# shellcheck disable=SC2016 # the stand-in's lines, expanded when it runs
printf '%s\n' '#!/bin/sh' \
	'echo "$*" >>"$RESETPROP_LOG"' \
	'del=' \
	'while :; do' \
	'	case ${1-} in' \
	'	-n | -p) shift ;;' \
	'	-d | --delete) del=1; shift ;;' \
	'	*) break ;;' \
	'	esac' \
	'done' \
	'[ -n "$del" ] && exec setprop "$1" '\'\''' \
	'exec setprop "$1" "$2"' \
	>"$MB/resetprop"
chmod 0755 "$PB/getprop" "$PB/setprop" "$MB/resetprop"
OLD_PATH=$PATH
REC=$LOGDIR/ims-off.orig
props() {
	printf '%s\n' "$@" >"$PROPS_FILE"
	: >"$RESETPROP_LOG"
	rm -f "$REC"
}
pv() { "$PB/getprop" "$1"; }
oneline() { tr '\n' ' ' | sed 's/ $//'; }
rlog() { tr '\n' '|' <"$RESETPROP_LOG" | sed 's/|$//'; }
W=persist.dbg.wfc_avail_ovr
V=persist.dbg.vt_avail_ovr
L=persist.dbg.volte_avail_ovr

# On the phone, under Magisk: LineageOS's three 1s from its build.prop.
PATH=$MB:$PB:$OLD_PATH
props "$L=1" "$V=1" "$W=1" 'ro.lineage.version=23.2'
out=$(ims_off "$REC")
rc=$?
expect "ims_off (phone): sets wfc and vt" "$W $V" "$(printf '%s\n' "$out" | oneline)"
expect "ims_off (phone): succeeds" 0 "$rc"
expect "ims_off (phone): wfc 0, vt 0, volte still 1" "0 0 1" "$(pv $W) $(pv $V) $(pv $L)"
expect "ims_off (phone): with resetprop -n, in memory only" "-n $W 0|-n $V 0" "$(rlog)"
expect "ims_off (phone): the values found recorded" "$W=1 $V=1" "$(oneline <"$REC")"
if grep -q -e ' -p' -e ' -P' -e '^-p' -e '^-P' "$RESETPROP_LOG"; then
	bad "ims_off: resetprop -p or -P used (stored)"
else
	ok "ims_off: nothing stored (no resetprop -p)"
fi
if grep -q volte "$RESETPROP_LOG"; then bad "ims_off: volte_avail_ovr touched"; else ok "ims_off: volte_avail_ovr never touched"; fi
# Again in the same boot: nothing to do, the record kept.
: >"$RESETPROP_LOG"
out=$(ims_off "$REC")
expect "ims_off again: nothing set" "" "$out"
expect "ims_off again: no resetprop call" 0 "$(wc -l <"$RESETPROP_LOG" | tr -d ' ')"
# A 1 written after post-fs-data (stored values are loaded before it runs,
# so only a later write): set again, the first record kept.
"$PB/setprop" "$W" 1
out=$(ims_off "$REC")
expect "ims_off after a stored 1 came back: wfc set again" "$W" "$out"
expect "ims_off after a stored 1 came back: wfc 0" 0 "$(pv $W)"
expect "ims_off after a stored 1 came back: the first record kept" "$W=1 $V=1" "$(oneline <"$REC")"
# The per-slot forms Android reads first (NAME<slot>), where present; never
# volte's.
props "$L=1" "$V=1" "$W=1" "${W}0=1" "${V}1=1" "${L}0=1" "${L}1=1"
out=$(ims_off "$REC")
expect "ims_off: per-slot forms set too" "$W ${W}0 $V ${V}1" "$(printf '%s\n' "$out" | oneline)"
expect "ims_off: per-slot wfc0 and vt1 now 0" "0 0" "$(pv ${W}0) $(pv ${V}1)"
expect "ims_off: per-slot volte forms untouched" "1 1 1" "$(pv $L) $(pv ${L}0) $(pv ${L}1)"
expect "ims_off: per-slot forms recorded" "$W=1 ${W}0=1 $V=1 ${V}1=1" "$(oneline <"$REC")"
# A set that does not take: a failure.
props "$L=1" "$V=1" "$W=1"
FAKE_SET_FAILS=1
export FAKE_SET_FAILS
ims_off "$REC" >/dev/null
rc=$?
FAKE_SET_FAILS=
expect "ims_off: a set that does not take fails" 1 "$rc"
# Put back (uninstall.sh while Android runs).
props "$L=1" "$V=0" "$W=0"
printf '%s\n' "$W=1" "$V=1" >"$REC"
ims_off_restore "$REC"
expect "ims_off_restore: wfc and vt back to 1, volte 1" "1 1 1" "$(pv $W) $(pv $V) $(pv $L)"
expect "ims_off_restore: with resetprop -n" "-n $W 1|-n $V 1" "$(rlog)"
# None before: removed.
props "$L=1" "$V=0" "$W=0"
printf '%s\n' "$W=" "$V=" >"$REC"
ims_off_restore "$REC"
expect "ims_off_restore: a property that had no value removed" "||1" "$(pv $W)|$(pv $V)|$(pv $L)"
# Only the wfc and vt names, digits or nothing: a record line naming volte
# or another property, or with another value, is skipped.
props "$L=1" "$V=0" "$W=0" 'persist.sys.x=5'
printf '%s\n' "$L=0" "${L}0=0" 'persist.sys.x=1' "$W=1;reboot" "${W}2=1" "x$V=1" "$V" >"$REC"
ims_off_restore "$REC"
expect "ims_off_restore: forged lines skipped" "0 0 1 5" "$(pv $W) $(pv $V) $(pv $L) $(pv persist.sys.x)"
expect "ims_off_restore: no property written for them" 0 "$(wc -l <"$RESETPROP_LOG" | tr -d ' ')"
rm -f "$REC"
ims_off_restore "$REC"
expect "ims_off_restore: no record, nothing done" "0 0" "$? $(wc -l <"$RESETPROP_LOG" | tr -d ' ')"
# On the CI emulator: no resetprop (setprop from adb's root shell), and
# the image sets none of them.
PATH=$PB:$OLD_PATH
props 'ro.boot.qemu=1'
out=$(ims_off "$REC")
expect "ims_off (emulator): wfc and vt set with setprop, volte not" "$W $V|0 0|" \
	"$(printf '%s\n' "$out" | oneline)|$(pv $W) $(pv $V)|$(pv $L)"
expect "ims_off (emulator): recorded as none" "$W= $V=" "$(oneline <"$REC")"
ims_off_restore "$REC"
expect "ims_off_restore (emulator): none again" "|" "$(pv $W)|$(pv $V)"
PATH=$OLD_PATH
# service.sh's ims_guard (cut out of it): no record; nothing due, nothing
# done; a due write waits while the cell radio's watch holds (a call,
# callback mode, the 5 minutes after a call, a state not read), the hold
# logged once, and is made at the first turn after the hold ends.
eval "$(sed -n '/^ims_guard() {$/,/^}$/p' "$MODULE/service.sh")"
PATH=$MB:$PB:$OLD_PATH
# The record's place, here: ims_guard must never write it.
# shellcheck disable=SC2034 # read by ims_guard, cut out of service.sh
IMS_OFF_RECORD=$REC
guard_reset() {
	# shellcheck disable=SC2034 # read by ims_guard, cut out of service.sh
	IMS_NEXT=0 IMS_LOGGED=0 IMS_HOLD_LOGGED=0
	CL_CALL=0 CL_CBM=0 CELL_LAST=
	: >"$LOGDIR/module.log"
}
held_n() { grep -c 'Wi-Fi calling: setting 0 again waits' "$LOGDIR/module.log"; }
props "$L=1" "$V=0" "$W=0"
guard_reset
ims_guard 100
expect "ims_guard: nothing due, nothing written or logged" "0|0" "$(wc -l <"$RESETPROP_LOG" | tr -d ' ')|$(wc -l <"$LOGDIR/module.log" | tr -d ' ')"
expect "ims_guard: next look in 30 s" 130 "$IMS_NEXT"
# A 1 written during a call: not written back while the call lasts.
"$PB/setprop" "$W" 1
CL_CALL=1
ims_guard 130
ims_guard 132
expect "ims_guard: a 1 written during a call is left while the call lasts" 1 "$(pv $W)"
expect "ims_guard: the hold logged once" 1 "$(held_n)"
if grep -q 'held: call (a call is ringing' "$LOGDIR/module.log"; then ok "ims_guard: the hold's reason logged"; else bad "ims_guard: the hold's reason logged"; fi
# Callback mode, then the 5 minutes after the call, then a state not read.
CL_CALL=0 CL_CBM=1
ims_guard 140
expect "ims_guard: left in callback mode" 1 "$(pv $W)"
CL_CBM=0 CELL_LAST=140
ims_guard 300
ims_guard 439
expect "ims_guard: left in the 5 minutes after the call" 1 "$(pv $W)"
CL_CALL=unknown
ims_guard 500
expect "ims_guard: left while the call state cannot be read" 1 "$(pv $W)"
expect "ims_guard: no resetprop call during the hold" 0 "$(wc -l <"$RESETPROP_LOG" | tr -d ' ')"
expect "ims_guard: still logged once" 1 "$(held_n)"
# The hold ends: written back at that turn, with resetprop -n, no record.
CL_CALL=0
ims_guard 502
expect "ims_guard: written back once the hold ends" 0 "$(pv $W)"
expect "ims_guard: with resetprop -n" "-n $W 0" "$(rlog)"
expect "ims_guard: no record written (only post-fs-data.sh records)" no "$([ -e "$REC" ] && echo yes || echo no)"
if grep -q 'Wi-Fi calling and video calling off again (set to 0: persist.dbg.wfc_avail_ovr)' "$LOGDIR/module.log"; then
	ok "ims_guard: the write logged"
else
	bad "ims_guard: the write logged"
fi
# Without the time since boot (NOW 0) a due write waits too.
guard_reset
"$PB/setprop" "$V" 1
ims_guard 0
expect "ims_guard: no time since boot: left" 1 "$(pv $V)"
PATH=$OLD_PATH
# No module script names volte_avail_ovr outside a comment, or stores a
# property (resetprop -p or -P).
v=$(grep -n -E '^[^#]*volte_avail_ovr' "$MODULE"/*.sh "$MODULE"/lib/*.sh \
	"$MODULE/META-INF/com/google/android/update-binary" 2>/dev/null)
expect "no module script touches volte_avail_ovr" "" "$v"
v=$(grep -n -E '^[^#]*resetprop[^#]*[[:space:]]-[a-zA-Z]*[pP]' "$MODULE"/*.sh "$MODULE"/lib/*.sh 2>/dev/null)
expect "no module script stores a property (resetprop -p)" "" "$v"

echo "  $fails failed"
[ "$fails" -eq 0 ]
