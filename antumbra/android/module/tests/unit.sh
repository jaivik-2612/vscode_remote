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
expect "settings_apply on the emulator: 10 values" 10 "$n"
if logged restricted_networking_mode; then
	bad "restricted_networking_mode set on the emulator"
else
	ok "restricted_networking_mode not set on the emulator"
fi
if logged mobile_data; then
	bad "mobile data switched off on the emulator"
else
	ok "mobile data left alone on the emulator"
fi
for kv in 'captive_portal_mode 0' 'ntp_server 127.0.0.1' 'private_dns_mode off' 'tether_offload_disabled 1'; do
	if logged "^put global $kv\$"; then ok "$kv"; else bad "$kv"; fi
done
: >"$SETTINGS_LOG"
FAKE_LINEAGE=23.2-20261009-NIGHTLY-hotdog
FAKE_QEMU=
settings_apply >/dev/null
n=$(grep -c '^put global ' "$SETTINGS_LOG")
expect "settings_apply on LineageOS (the phone): 12 values" 12 "$n"
if logged '^put global restricted_networking_mode 1$'; then
	ok "restricted_networking_mode 1 on LineageOS"
else
	bad "restricted_networking_mode 1 on LineageOS"
fi
if logged '^put global mobile_data 0$'; then
	ok "mobile_data 0 on the phone"
else
	bad "mobile_data 0 on the phone"
fi
# The keys uninstall.sh and customize.sh read from settings.conf.
keys=$(sed -n -e 's/^lineage://' -e 's/^phone://' -e 's/^\([a-z0-9_]*\)=.*/\1/p' "$SETTINGS_CONF" | tr '\n' ' ')
expect "settings.conf keys for settings.orig" \
	"captive_portal_mode captive_portal_detection_enabled ntp_server assisted_gps_enabled wifi_scan_always_enabled ble_scan_always_enabled private_dns_mode network_recommendations_enabled tether_offload_disabled non_persistent_mac_randomization_force_enabled restricted_networking_mode mobile_data " \
	"$keys"

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
	tcp_line 0100007F:14E9 00000000:0000 0A 2951
	tcp_line 0100007F:1504 00000000:0000 0A 2951
	tcp_line 0A00020F:9C40 5DB8D822:0050 01 10100
	tcp_line 0100007F:2350 0100007F:9C41 01 2950
	tcp_line 0100007F:2350 0100007F:9C42 06 0
	tcp_line 0100007F:9C43 0100007F:2350 01 10100
	tcp_line 0100007F:1F90 00000000:0000 0A 10200
} >>"$P/tcp"
{
	udp_line 0100007F:235D 07 2950
	udp_line 0100007F:14E9 07 2951
	udp_line 0100007F:C350 01 2951
} >>"$P/udp"
expect "ports_bad: tor and the filter on their ports" "" "$(pb)"
tcp_line 00000000:2350 00000000:0000 0A 10200 >>"$P/tcp"
expect "ports_bad: an app on 0.0.0.0:9040" "9040/tcp held by uid 10200;" "$(pb)"
reset_net
tcp_line 0100007F:2350 00000000:0000 0A 10200 >>"$P/tcp"
udp_line 0100007F:14E9 07 10200 >>"$P/udp"
tcp_line 0100007F:1504 00000000:0000 0A 0 >>"$P/tcp"
expect "ports_bad: TransPort, filter and status page taken" \
	"5353/udp held by uid 10200;5380/tcp held by uid 0;9040/tcp held by uid 10200;" "$(pb)"
reset_net
tcp_line 00000000000000000000000000000000:2350 00000000000000000000000000000000:0000 0A 10200 >>"$P/tcp6"
udp_line 0000000000000000FFFF00000100007F:235D 07 10300 >>"$P/udp6"
expect "ports_bad: an app on [::]:9040 and [::ffff:127.0.0.1]:9053" \
	"9040/tcp held by uid 10200;9053/udp held by uid 10300;" "$(pb)"
reset_net
# Bound to another address: cannot receive what is sent to 127.0.0.1.
tcp_line 0A00020F:2350 00000000:0000 0A 10200 >>"$P/tcp"
udp_line 0100A8C0:14E9 07 1000 >>"$P/udp"
# A UDP socket on 9040 or 5380: no service uses UDP there.
udp_line 0100007F:2350 07 10200 >>"$P/udp"
expect "ports_bad: other addresses and unused protocols are ignored" "" "$(pb)"
reset_net
# A connected UDP socket on 5353 counts.
udp_line 0100007F:14E9 01 10200 >>"$P/udp"
expect "ports_bad: a connected UDP socket on 5353" "5353/udp held by uid 10200;" "$(pb)"
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

echo "  $fails failed"
[ "$fails" -eq 0 ]
