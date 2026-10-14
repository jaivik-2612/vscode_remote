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

fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() {
	printf '  FAIL  %s\n' "$1"
	fails=$((fails + 1))
}
expect() { # DESCRIPTION EXPECTED ACTUAL
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2], got [$3]"; fi
}

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
# STATE (STATE:voip for a VoIP call) and Analytics lines for calls 1 to
# HISTORY.
telecom_fixture() {
	_tf_h=$1
	shift
	echo 'CallsManager: '
	echo '  mCalls: '
	_tf_i=0
	for _tf_s in "$@"; do
		_tf_i=$((_tf_i + 1))
		_tf_v=false
		case $_tf_s in *:voip)
			_tf_v=true
			_tf_s=${_tf_s%:voip}
			;;
		esac
		printf '    [Call id=TC@%s, state=%s, tpac=ComponentInfo{com.android.phone/com.android.services.telephony.TelephonyConnectionService}, ***, UserHandle{0}, cmgr=null, handle=tel:***, vidst=A, childs(0), has_parent(false), cap=[ hld mut], prop=[]], voip=%s\n' \
			"$_tf_i" "$_tf_s" "$_tf_v"
	done
	echo '  mCallAudioManager: '
	echo '    [Call id=TC@77, state=ACTIVE] listed by another section'
	echo '  mPendingRedirectedOutgoingCallInfo:'
	echo 'PhoneAccountRegistrar: '
	echo '  mPhoneAccounts:'
	echo 'Analytics:'
	_tf_i=1
	while [ "$_tf_i" -le "$_tf_h" ]; do
		printf '  Call TC@%s: {\n    startTime: 0\n    endTime: 0\n  }\n' "$_tf_i"
		_tf_i=$((_tf_i + 1))
	done
	echo '  Hardware Version: '
	echo '  Past analytics dumps: '
	echo 'Flag Configurations: '
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
expect "telecom_state: no calls, no history" "0 0" "$(ts 0)"
expect "telecom_state: calls 1 to 3 in the past, none now" "0 3" "$(ts 3)"
for st in RINGING DIALING CONNECTING NEW SELECT_PHONE_ACCOUNT ACTIVE ON_HOLD DISCONNECTING AUDIO_PROCESSING; do
	expect "telecom_state: a call in state $st counts" "1 1" "$(ts 1 "$st")"
done
expect "telecom_state: an active and a held call" "2 2" "$(ts 2 ACTIVE ON_HOLD)"
expect "telecom_state: a VoIP call counts" "1 1" "$(ts 1 ACTIVE:voip)"
expect "telecom_state: a call line in another section does not count" "0 0" "$(ts 0)"
expect "telecom_state: the highest number from Analytics" "1 9" "$(ts 9 RINGING)"
# fails DESCRIPTION COMMAND...: the parser refuses the input (unknown).
fails() {
	_fl_d=$1
	shift
	if _fl_out=$("$@"); then bad "$_fl_d: accepted ($_fl_out)"; else ok "$_fl_d: unknown"; fi
}
tel_without() { telecom_fixture 2 RINGING | sed "/^$1\$/d" | telecom_state; }
tel_text() { printf '%s\n' "$1" | telecom_state; }
tel_bignum() { telecom_fixture 0 | sed 's/^  Past analytics dumps: $/  Call TC@12345678901: {/' | telecom_state; }
fails "telecom_state: no mCalls list" tel_without '  mCalls: '
fails "telecom_state: no Analytics" tel_without 'Analytics:'
fails "telecom_state: no CallsManager" tel_without 'CallsManager: '
fails "telecom_state: empty input" tel_text ''
fails "telecom_state: a missing service" tel_text "Can't find service: telecom"
fails "telecom_state: an implausible call number" tel_bignum
r=$(telecom_fixture 1 RINGING | sed 's/id=TC@1,/id=XY-1,/' | telecom_state)
expect "telecom_state: a call with an unusual id still counts" "1 1" "$r"

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
	CL_CALL=$2 CL_CBM=$3 CL_ID=$4 CL_RADIO=$5
	cell_note "$1"
	echo "${CELL_LAST:-none}"
}
cell_fresh() {
	CELL_LAST='' CELL_BUSY=0 CELL_ID='' CELL_RADIO='' CELL_MINE_AT=''
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
# system_server), as in Android 16: ServiceStateTracker reads
# enable_cellular_on_boot (unset: on) and airplane mode once, and keeps the
# radio off unless the first is not 0 and the second is off; PhoneGlobals,
# with cell_on 2 and airplane mode off, switches it on (and stores 1).
phone_restart() {
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
mobile_data_off() { echo "mobile data off" >>"$STEPS"; }
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
	telecom) telecom_fixture "$FAKE_HISTORY" $FAKE_CALLS ;;
	telephony.registry) registry_fixture "$FAKE_RADIO" "$FAKE_PHONE0" "$I" ;;
	esac
}
PROPS='gsm.sim.state=ABSENT,ABSENT'
# watch_reset: a start with the radio off since power-on.
watch_reset() {
	printf 'airplane_mode_on=0\ncell_on=1\nenable_cellular_on_boot=0\nairplane_mode_radios=cell,bluetooth,uwb,wifi,wimax\n' >"$G"
	FAKE_RADIO=0 FAKE_HISTORY=0 FAKE_CALLS='' FAKE_PHONE0=$I FAKE_BROKEN=0 FAKE_NO_SETTINGS=''
	PROPS='gsm.sim.state=ABSENT,ABSENT'
	CELL_AIR='' CELL_AIR_OFF_AT=0 CELL_NARROW=0 CELL_ECM='' CELL_SIM='' CELL_LOOKED='' CELL_LOOK_NEXT=0
	CELL_LAST='' CELL_BUSY=0 CELL_ID='' CELL_RADIO='' CELL_MINE_AT='' CELL_ON_DONE=0 CELL_TRY_AT='' CELL_HELD=''
	CELL_READ='' CELL_CLOCKLESS=0 CL_CALL=unknown CL_CBM=unknown CL_ID='' CL_RADIO=unknown
	RADIOS='' S_STARTED=0 SES_CELL=off S_PROBLEM='' P_CELL=''
	: >"$STEPS"
	: >"$LOGDIR/module.log"
	NOW=1000
}
# turn [SECONDS]: the clock moves on, and the watch takes a turn.
turn() {
	NOW=$((NOW + ${1:-2}))
	cell_step "$NOW"
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

echo "  $fails failed"
[ "$fails" -eq 0 ]
