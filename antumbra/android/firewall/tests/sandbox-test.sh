#!/usr/bin/env bash
# sandbox-test.sh: test antumbra-fw in two throwaway network namespaces.
#
# Needs root on Linux (a CI runner, or a container with CAP_SYS_ADMIN and
# CAP_NET_ADMIN), iproute2, util-linux (setpriv), python3, sha256sum and
# iptables with its -restore tools. Nothing outside the namespaces changes,
# except four local users it creates and removes again (see below).
#
# Layout:
#
#   namespace "phone" (antumbra-fw runs here)        namespace "upstream"
#   lo: 127.0.0.1, ::1                               lo: 198.51.100.1  ("Internet")
#   afp<pid>: 192.168.77.2/24  <------ veth ------>  afu<pid>: 192.168.77.1/24 (LAN router)
#             2001:db8:77::2/64                                2001:db8:77::1/64
#                                                    lo: 2001:db8:1::1 (IPv6 "Internet")
#
# The phone runs fake services in place of tor (TransPort 9040, DNSPort 9053,
# a pluggable transport on 40000, all as UID 2950), the DNS filter (5353 and
# the status page on 5380, as UID 2951), a TCP "ControlPort" on 9052 that no
# app may reach, tor's ControlSocket (0660, 2950:2950), an exempt app's own
# port 9150 (as UID 10101), another app's listener in the ephemeral range
# (41000, as UID 10100) and a DHCP client port (UDP 68, root). Later, an app
# takes tor's, the filter's and the exempt app's ports while their owners are
# stopped. The upstream namespace runs a LAN router (TCP 80, 5000, 49152,
# DHCP on UDP 67), Internet servers and a DHCP server on a public address.
# Every listener answers
# with its name and, for TCP, the connection's original destination, so a
# probe shows whether it reached its target or was redirected into the fake
# TransPort. The transmit counter of the phone's veth shows whether anything
# left the phone at all.
#
# Probes run with setpriv --reuid/--regid as root (0), the network stack
# (1073), tor (2950), the DNS filter (2951), an app (10100), an exempt app
# (10101) and further app and system UIDs. Each probe prints one PASS, FAIL
# or SKIP line; the script exits 1 if any probe failed, 2 if the sandbox
# could not be built.
#
# Environment:
#   AFW_TEST_BACKEND=auto|legacy|nft  iptables backend (auto: legacy when it
#                                     works, as on Android).
#   AFW_TEST_REQUIRE_IPV6=1           fail, rather than skip, the IPv6 traffic
#                                     probes when the kernel has no IPv6.
#   AFW_TEST_MKSH=/path/to/mksh       mksh to test with (default: mksh on PATH).
#   AFW_TEST_TOYBOX=/path/to/toybox   toybox to test with (default: on PATH).
#   AFW_TEST_REQUIRE_SHELLS="mksh ..." shell variants that must not be skipped:
#                                     bash dash busybox mksh mksh+toybox.
#   AFW_TEST_CREATE_USERS=0           do not create the local users.
#   AFW_TEST_KEEP=1                   keep the temporary directory.

# "check && pass NAME || fail NAME" is safe here: pass always returns 0.
# shellcheck disable=SC2015

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
FW_SRC=$HERE/../antumbra-fw
PROBE_SRC=$HERE/afw_probe.py

PASSES=0
FAILS=0
SKIPS=0
FAILED_NAMES=

pass() {
	echo "PASS $1"
	PASSES=$((PASSES + 1))
}
fail() {
	echo "FAIL $1${2:+ ($2)}"
	FAILS=$((FAILS + 1))
	FAILED_NAMES="$FAILED_NAMES $1"
}
skip() {
	echo "SKIP $1${2:+ ($2)}"
	SKIPS=$((SKIPS + 1))
}
die() {
	echo "ERROR $*" >&2
	exit 2
}

[ "$(id -u)" = 0 ] || die "run as root"
for c in ip setpriv python3 sha256sum unshare; do
	command -v "$c" >/dev/null 2>&1 || die "missing $c"
done

# --- iptables backend ---------------------------------------------------------

BACKEND=${AFW_TEST_BACKEND:-auto}
if [ "$BACKEND" = auto ]; then
	if command -v iptables-legacy >/dev/null 2>&1 && unshare -n iptables-legacy -w -t nat -S >/dev/null 2>&1; then
		BACKEND=legacy
	else
		BACKEND=nft
	fi
fi
IPT4=iptables-$BACKEND
RST4=iptables-$BACKEND-restore
IPT6=ip6tables-$BACKEND
RST6=ip6tables-$BACKEND-restore
HAVE_IPV6=1
[ -d /proc/sys/net/ipv6 ] || HAVE_IPV6=0
if [ "$HAVE_IPV6" = 0 ]; then
	# Without an IPv6 stack, legacy ip6tables cannot even open its tables;
	# the nf_tables ones still load, so the IPv6 rules are still checked for
	# syntax and structure, but no IPv6 packet can be sent.
	if ! unshare -n "$IPT6" -w -t mangle -S >/dev/null 2>&1 && command -v ip6tables-nft >/dev/null 2>&1; then
		IPT6=ip6tables-nft
		RST6=ip6tables-nft-restore
	fi
fi
for c in "$IPT4" "$RST4" "$IPT6" "$RST6"; do
	command -v "$c" >/dev/null 2>&1 || die "missing $c"
done
echo "INFO backend: $IPT4 / $IPT6; IPv6 stack: $([ $HAVE_IPV6 = 1 ] && echo yes || echo no)"

skip_v6() {
	if [ "$HAVE_IPV6" = 1 ]; then return 1; fi
	if [ "${AFW_TEST_REQUIRE_IPV6:-0}" = 1 ]; then
		fail "$1" "the kernel has no IPv6 stack"
	else
		skip "$1" "the kernel has no IPv6 stack"
	fi
	return 0
}

# --- Sandbox --------------------------------------------------------------------

ID=$$
P=afwp$ID
U=afwu$ID
VP=afp$ID
VU=afu$ID
TMP=$(mktemp -d /tmp/afw-test.XXXXXX) || die "mktemp failed"
chmod 755 "$TMP"
AD=$TMP/antumbra
BIN=$TMP/bin
LOGS=$TMP/logs
mkdir -p "$AD/run" "$AD/state" "$AD/lists" "$AD/log" "$BIN" "$LOGS"
chmod 755 "$AD" "$AD/run" "$AD/state" "$AD/lists" "$AD/log" "$BIN"
# As on the phone, run/ belongs to tor; the firewall must not write there.
chown 2950:2950 "$AD/run"
chmod 1777 "$LOGS"
cp "$FW_SRC" "$BIN/antumbra-fw"
cp "$PROBE_SRC" "$BIN/afw_probe.py"
chmod 755 "$BIN/antumbra-fw" "$BIN/afw_probe.py"
printf '#!/bin/sh\ncat >/dev/null\nexit 1\n' >"$BIN/fail-restore"
# iptables that refuses to insert (-I), as an xtables-lock timeout would.
for f in 4 6; do
	if [ $f = 4 ]; then real=$(command -v "$IPT4"); else real=$(command -v "$IPT6"); fi
	cat >"$BIN/ipt$f-noinsert" <<EOF
#!/bin/sh
for a in "\$@"; do [ "\$a" = -I ] && { echo "ipt$f-noinsert: refusing -I" >&2; exit 4; }; done
exec "$real" "\$@"
EOF
done
chmod 755 "$BIN/fail-restore" "$BIN/ipt4-noinsert" "$BIN/ipt6-noinsert"
FW=$BIN/antumbra-fw
PROBE=$BIN/afw_probe.py

PIDS=
CREATED_USERS=
# shellcheck disable=SC2317 # called from the EXIT trap
cleanup() {
	for pid in $PIDS; do kill "$pid" 2>/dev/null; done
	wait 2>/dev/null
	ip netns del "$P" 2>/dev/null
	ip netns del "$U" 2>/dev/null
	for u in $CREATED_USERS; do
		userdel "$u" 2>/dev/null
		groupdel "$u" 2>/dev/null
	done
	if [ "${AFW_TEST_KEEP:-0}" = 1 ]; then echo "INFO kept $TMP"; else rm -rf "$TMP"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Local users, as the test plan asks; the probes themselves use numeric IDs.
if [ "${AFW_TEST_CREATE_USERS:-1}" = 1 ] && command -v useradd >/dev/null 2>&1; then
	for spec in afw-tor:2950 afw-dns:2951 afw-app:10100 afw-exempt:10101; do
		name=${spec%%:*}
		uid=${spec#*:}
		if getent passwd "$uid" >/dev/null 2>&1; then continue; fi
		groupadd -g "$uid" "$name" 2>/dev/null
		if useradd -M -N -g "$uid" -u "$uid" -s /usr/sbin/nologin "$name" 2>/dev/null; then
			CREATED_USERS="$CREATED_USERS $name"
		else
			groupdel "$name" 2>/dev/null
		fi
	done
fi

inp() { ip netns exec "$P" "$@"; }
inu() { ip netns exec "$U" "$@"; }

ip netns add "$P" || die "cannot create network namespaces"
ip netns add "$U" || die "cannot create network namespaces"
ip link add "$VP" type veth peer name "$VU" || die "cannot create a veth pair"
ip link set "$VP" netns "$P"
ip link set "$VU" netns "$U"
inp ip link set lo up
inu ip link set lo up
inp sh -c "echo 0 >/proc/sys/net/ipv4/ip_unprivileged_port_start" || die "cannot set ip_unprivileged_port_start"
# As on Android, every UID may open an ICMP echo ("ping") socket.
inp sh -c "echo '0 2147483647' >/proc/sys/net/ipv4/ping_group_range" || die "cannot set ping_group_range"
if [ "$HAVE_IPV6" = 1 ]; then
	for ns in "$P:$VP" "$U:$VU"; do
		ip netns exec "${ns%%:*}" sh -c "
			for k in accept_ra autoconf accept_dad dad_transmits router_solicitations; do
				echo 0 >/proc/sys/net/ipv6/conf/${ns#*:}/\$k
			done"
		ip netns exec "${ns%%:*}" ip link set "${ns#*:}" addrgenmode none
	done
fi
inp ip link set "$VP" up
inu ip link set "$VU" up
inp ip addr add 192.168.77.2/24 dev "$VP"
inu ip addr add 192.168.77.1/24 dev "$VU"
inu ip addr add 198.51.100.1/32 dev lo
inp ip route add default via 192.168.77.1
MAC_P=$(inp cat "/sys/class/net/$VP/address")
MAC_U=$(inu cat "/sys/class/net/$VU/address")
# Static neighbours: no ARP or neighbour discovery noise in the counters.
inp ip neigh replace 192.168.77.1 lladdr "$MAC_U" dev "$VP" nud permanent
inu ip neigh replace 192.168.77.2 lladdr "$MAC_P" dev "$VU" nud permanent
if [ "$HAVE_IPV6" = 1 ]; then
	inp ip -6 addr add 2001:db8:77::2/64 dev "$VP" nodad
	inu ip -6 addr add 2001:db8:77::1/64 dev "$VU" nodad
	inu ip -6 addr add 2001:db8:1::1/128 dev lo
	inp ip -6 route add default via 2001:db8:77::1 dev "$VP"
	inp ip -6 neigh replace 2001:db8:77::1 lladdr "$MAC_U" dev "$VP" nud permanent
	inu ip -6 neigh replace 2001:db8:77::2 lladdr "$MAC_P" dev "$VU" nud permanent
fi

# --- Listeners ------------------------------------------------------------------

declare -A SERVE_PID
start_serve() { # start_serve NS UID NAME SPEC...
	ns=$1
	uid=$2
	name=$3
	shift 3
	rm -f "$LOGS/$name.ready"
	ip netns exec "$ns" setpriv --reuid="$uid" --regid="$uid" --clear-groups -- \
		python3 -I -B "$PROBE" serve --log "$LOGS/$name.log" --ready "$LOGS/$name.ready" "$@" \
		>"$LOGS/$name.out" 2>&1 &
	PIDS="$PIDS $!"
	SERVE_PID[$name]=$!
	READY="${READY:-} $name"
}
stop_serve() { # stop_serve NAME: stop a listener and wait until its ports are free
	kill "${SERVE_PID[$1]}" 2>/dev/null
	wait "${SERVE_PID[$1]}" 2>/dev/null
	unset "SERVE_PID[$1]"
}
wait_ready() { # wait_ready: every listener started since the last call is bound
	for _ in $(seq 1 100); do
		missing=0
		for name in $READY; do [ -f "$LOGS/$name.ready" ] || missing=1; done
		[ $missing = 0 ] && break
		sleep 0.1
	done
	for name in $READY; do
		[ -f "$LOGS/$name.ready" ] || die "listener $name did not start: $(cat "$LOGS/$name.out")"
	done
	READY=
}
# The fake tor and DNS filter, started again after the squatting probes.
start_tor() {
	start_serve "$P" 2950 phone-tor tcp:transport:127.0.0.1:9040 tcp:tor-dnsport-tcp:127.0.0.1:9053 \
		udp:tor-dnsport:127.0.0.1:9053 tcp:tor-pt:127.0.0.1:40000
}
start_dnsfilter() {
	start_serve "$P" 2951 phone-dns tcp:dnsfilter-tcp:127.0.0.1:5353 udp:dnsfilter:127.0.0.1:5353 tcp:status:127.0.0.1:5380
}

V6_PHONE=
V6_UP=
if [ "$HAVE_IPV6" = 1 ]; then
	V6_PHONE='tcp:sys-v6:[::1]:9999'
	V6_UP='tcp:net6-443:[2001:db8:1::1]:443 udp:net6-53:[2001:db8:1::1]:53'
fi
start_tor
start_dnsfilter
start_serve "$P" 10101 phone-exempt tcp:exempt-own:127.0.0.1:9150
start_serve "$P" 10100 phone-app tcp:app-ephemeral:127.0.0.1:41000
# shellcheck disable=SC2086
start_serve "$P" 0 phone-root tcp:fake-controlport:127.0.0.1:9052 tcp:phone-service:0.0.0.0:8080 \
	udp:phone-udp:0.0.0.0:8081 udp:dhcp-client:0.0.0.0:68 \
	"unix:tor-control:$AD/run/tor-control.sock:2950:2950:0660" $V6_PHONE
# shellcheck disable=SC2086
start_serve "$U" 0 upstream tcp:lan-80:192.168.77.1:80 tcp:lan-5000:192.168.77.1:5000 \
	tcp:lan-49152:192.168.77.1:49152 udp:dhcp-server:192.168.77.1:67 tcp:net-443:198.51.100.1:443 \
	tcp:net-9001:198.51.100.1:9001 tcp:net-853:198.51.100.1:853 tcp:net-53-tcp:198.51.100.1:53 \
	udp:net-53:198.51.100.1:53 udp:net-123:198.51.100.1:123 udp:net-443-udp:198.51.100.1:443 \
	udp:dhcp-public:198.51.100.1:67 $V6_UP
wait_ready

# --- Probe helpers ----------------------------------------------------------------

FW_ENV=(ANTUMBRA_DIR="$AD" ANTUMBRA_FW_IPTABLES="$IPT4" ANTUMBRA_FW_IPTABLES_RESTORE="$RST4"
	ANTUMBRA_FW_IP6TABLES="$IPT6" ANTUMBRA_FW_IP6TABLES_RESTORE="$RST6")
FW_SHELL=(sh)

# fw [VAR=value...] COMMAND: run antumbra-fw in the phone namespace.
fw() {
	inp env "${FW_ENV[@]}" "${FW_EXTRA_ENV[@]}" "${FW_SHELL[@]}" "$FW" "$@"
}
FW_EXTRA_ENV=()

# probe UID tcp|udp|unix ARGS...: one probe as UID in the phone namespace.
probe() {
	uid=$1
	shift
	inp setpriv --reuid="$uid" --regid="$uid" --clear-groups -- python3 -I -B "$PROBE" "$@" 2>&1 | tail -n 1
}
probe_up() { inu python3 -I -B "$PROBE" "$@" 2>&1 | tail -n 1; }

TOKEN_N=0
token() {
	TOKEN_N=$((TOKEN_N + 1))
	TOK=t$TOKEN_N-$1
}

# expect NAME REGEX UID PROBE-ARGS... (the token is added as the third probe
# argument after kind, host/path and port).
expect() {
	name=$1
	re=$2
	uid=$3
	kind=$4
	shift 4
	token "$name"
	if [ "$kind" = unix ] || [ "$kind" = ping ]; then
		out=$(probe "$uid" "$kind" "$1" "$TOK" "${@:2}")
	else
		out=$(probe "$uid" "$kind" "$1" "$2" "$TOK" "${@:3}")
	fi
	if [[ $out =~ $re ]]; then pass "$name"; else fail "$name" "got '$out', want /$re/"; fi
}

expect_up() {
	name=$1
	re=$2
	kind=$3
	shift 3
	token "$name"
	out=$(probe_up "$kind" "$1" "$2" "$TOK" "${@:3}")
	if [[ $out =~ $re ]]; then pass "$name"; else fail "$name" "got '$out', want /$re/"; fi
}

reached() { cat "$LOGS"/*.log 2>/dev/null | grep -F "\"token\": \"$TOK\"" | grep -q -F "\"name\": \"$1\""; }
# not_logged NAME LISTENER: the last probe's token never reached LISTENER.
not_logged() {
	if reached "$2"; then fail "$1" "the probe reached $2"; else pass "$1"; fi
}
# logged NAME LISTENER: the last probe's token reached LISTENER.
logged() {
	if reached "$2"; then pass "$1"; else fail "$1" "the probe did not reach $2"; fi
}

tx() { inp cat "/sys/class/net/$VP/statistics/tx_packets"; }

check_rc() { # check_rc NAME WANT GOT
	if [ "$3" = "$2" ]; then pass "$1"; else fail "$1" "exit status $3, want $2"; fi
}

status_field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

count_jumps() { # count_jumps FAMILY TABLE CHAIN-TARGET
	if [ "$1" = 4 ]; then t=$IPT4; else t=$IPT6; fi
	inp "$t" -w -t "$2" -S | grep -c -e "-j $3\$"
}

# --- Phase 0: no firewall: the sandbox itself works --------------------------------

echo "== phase 0: no firewall (sandbox check)"
tx0=$(tx)
expect base-app-reaches-lan '^ok lan-80 ' 10100 tcp 192.168.77.1 80
expect base-app-udp-reaches-net '^ok net-123$' 10100 udp 198.51.100.1 123
expect base-tor-reaches-net '^ok net-443 ' 2950 tcp 198.51.100.1 443
expect base-app-ping '^ok echo-reply$' 10100 ping 198.51.100.1
expect_up base-inbound-reaches-phone '^ok phone-service ' tcp 192.168.77.2 8080
expect base-tor-reaches-app-listener '^ok app-ephemeral ' 2950 tcp 127.0.0.1 41000
expect base-netstack-reaches-public-dhcp '^ok dhcp-public$' 1073 udp 198.51.100.1 67 --sport 68
start_serve "$P" 0 phone-dhcpc udp:dhcp-client:192.168.77.2:68
wait_ready
token base-inbound-dhcp-public
probe_up udp 192.168.77.2 68 "$TOK" --sport 67 --bind 198.51.100.1 --timeout 0.5 >/dev/null
logged base-inbound-dhcp-public dhcp-client
stop_serve phone-dhcpc
if ! skip_v6 base-app-ipv6; then
	expect base-app-ipv6 '^ok net6-443 ' 10100 tcp 2001:db8:1::1 443
fi
if [ "$(tx)" -gt "$tx0" ]; then pass base-tx-counter-moves; else fail base-tx-counter-moves; fi
if [ "$FAILS" -gt 0 ]; then
	echo "ERROR the sandbox does not work without the firewall; stopping" >&2
	exit 2
fi

# --- Phase 1: arm -------------------------------------------------------------------

echo "== phase 1: arm"
fw arm 2>"$TMP/err"
check_rc arm-exit 0 $?
out=$(fw status 2>/dev/null)
check_rc arm-status-exit 1 $?
[ "$(status_field "$out" state)" = armed ] && pass arm-status-armed || fail arm-status-armed "$out"
ARMED_HASH=$(status_field "$out" hash)
fw arm 2>/dev/null
check_rc arm-again-exit 0 $?
for f in 4 6; do
	n=$(count_jumps $f filter ANTUMBRA_ARM_OUT)$(count_jumps $f mangle ANTUMBRA_ARM_IN)$(count_jumps $f mangle ANTUMBRA_ARM_POST)
	[ "$n" = 111 ] && pass "arm-idempotent-ipv$f" || fail "arm-idempotent-ipv$f" "jump counts $n"
done
out=$(fw status 2>/dev/null)
[ "$(status_field "$out" hash)" = "$ARMED_HASH" ] && pass arm-again-same-hash || fail arm-again-same-hash

tx0=$(tx)
expect armed-app-lan-blocked '^err ' 10100 tcp 192.168.77.1 80 --timeout 1
not_logged armed-app-lan-not-reached lan-80
expect armed-tor-blocked '^err ' 2950 tcp 198.51.100.1 443 --timeout 1
not_logged armed-tor-not-reached net-443
expect armed-root-udp-blocked '^err ' 0 udp 198.51.100.1 123 --timeout 1
expect armed-dhcp-blocked '^err ' 1073 udp 192.168.77.1 67 --sport 68 --timeout 1
expect_up armed-inbound-blocked '^err ' tcp 192.168.77.2 8080 --timeout 1
if ! skip_v6 armed-ipv6-blocked; then
	expect armed-ipv6-blocked '^err ' 10100 tcp 2001:db8:1::1 443 --timeout 1
fi
tx1=$(tx)
[ "$tx1" = "$tx0" ] && pass armed-nothing-left-the-phone || fail armed-nothing-left-the-phone "$((tx1 - tx0)) packets sent"
# No arm rule uses conntrack, so the kernel may not track this connection and
# the listener may not know its original destination ("-").
expect armed-loopback-works '^ok transport orig=(127\.0\.0\.1:9040|-)$' 10100 tcp 127.0.0.1 9040

# --- Phase 2: apply -------------------------------------------------------------------

echo "== phase 2: apply"
HASH=$(fw apply 2>"$TMP/err")
check_rc apply-exit 0 $?
[[ $HASH =~ ^[0-9a-f]{64}$ ]] && pass apply-prints-hash || fail apply-prints-hash "got '$HASH'"
out=$(fw status 2>/dev/null)
check_rc apply-status-exit 0 $?
[ "$(status_field "$out" state)" = live ] && pass apply-status-live || fail apply-status-live "$out"
[ "$(status_field "$out" hash)" = "$HASH" ] && pass apply-status-hash || fail apply-status-hash "$out"
H2=$(fw apply 2>/dev/null)
[ "$H2" = "$HASH" ] && pass apply-again-same-hash || fail apply-again-same-hash "$H2"
n=$(count_jumps 4 filter ANTUMBRA_OUT)$(count_jumps 4 nat ANTUMBRA_NAT)$(count_jumps 4 mangle ANTUMBRA_IN)$(count_jumps 4 mangle ANTUMBRA_POST)$(count_jumps 6 filter ANTUMBRA_OUT)$(count_jumps 6 mangle ANTUMBRA_POST)
[ "$n" = 111111 ] && pass apply-idempotent || fail apply-idempotent "jump counts $n"
n=$(count_jumps 4 filter ANTUMBRA_ARM_OUT)$(count_jumps 4 mangle ANTUMBRA_ARM_POST)$(count_jumps 6 mangle ANTUMBRA_ARM_POST)
[ "$n" = 000 ] && pass apply-removed-arm-jumps || fail apply-removed-arm-jumps "jump counts $n"

echo "-- an app (10100), the DNS filter (2951), root and inbound: nothing may leave the phone"
tx0=$(tx)
for port in 80 5000 49152; do
	expect "app-lan-$port-redirected" "^ok transport orig=192\\.168\\.77\\.1:$port\$" 10100 tcp 192.168.77.1 $port
	not_logged "app-lan-$port-not-reached" "lan-$port"
done
expect app-net-redirected '^ok transport orig=198\.51\.100\.1:443$' 10100 tcp 198.51.100.1 443
not_logged app-net-not-reached-directly net-443
expect app-own-address-redirected '^ok transport orig=192\.168\.77\.2:8080$' 10100 tcp 192.168.77.2 8080
expect app-tcp-controlport-redirected '^ok transport orig=127\.0\.0\.1:9052$' 10100 tcp 127.0.0.1 9052
not_logged app-tcp-controlport-not-reached fake-controlport
expect app-dnsport-tcp-redirected '^ok transport orig=127\.0\.0\.1:9053$' 10100 tcp 127.0.0.1 9053
not_logged app-dnsport-tcp-not-reached tor-dnsport-tcp
expect app-dnsport-udp-refused '^err ' 10100 udp 127.0.0.1 9053
not_logged app-dnsport-udp-not-reached tor-dnsport
expect app-control-socket-denied '^err EACCES$' 10100 unix "$AD/run/tor-control.sock"
expect app-pt-port-redirected '^ok transport orig=127\.0\.0\.1:40000$' 10100 tcp 127.0.0.1 40000
expect app-other-apps-port-redirected '^ok transport orig=127\.0\.0\.1:9150$' 10100 tcp 127.0.0.1 9150
expect app-status-page '^ok status ' 10100 tcp 127.0.0.1 5380
expect app-transport-direct '^ok transport orig=127\.0\.0\.1:9040$' 10100 tcp 127.0.0.1 9040
expect app-dns-udp-to-filter '^ok dnsfilter$' 10100 udp 198.51.100.1 53
not_logged app-dns-udp-not-reached net-53
expect app-dns-tcp-to-filter '^ok dnsfilter-tcp orig=198\.51\.100\.1:53$' 10100 tcp 198.51.100.1 53
expect app-dns-lan-to-filter '^ok dnsfilter$' 10100 udp 192.168.77.1 53
expect app-dns-filter-direct '^ok dnsfilter$' 10100 udp 127.0.0.1 5353
expect app-udp-ntp-refused '^err ' 10100 udp 198.51.100.1 123
not_logged app-udp-ntp-not-reached net-123
expect app-udp-quic-refused '^err ' 10100 udp 198.51.100.1 443
expect app-udp-multicast-refused '^err ' 10100 udp 224.0.0.251 5353
expect app-udp-lan-refused '^err ' 10100 udp 192.168.77.1 5000
expect app-dhcp-refused '^err ' 10100 udp 192.168.77.1 67 --sport 68
not_logged app-dhcp-not-reached dhcp-server
expect app-dot-refused '^err ECONNREFUSED$' 10100 tcp 198.51.100.1 853
not_logged app-dot-not-redirected transport
expect app-ping-refused '^err ' 10100 ping 198.51.100.1
expect app-ping-lan-refused '^err ' 10100 ping 192.168.77.1
if ! skip_v6 app-ipv6; then
	# An IPv6 socket to an IPv4-mapped address sends IPv4: still into Tor.
	expect app-v4-mapped-redirected '^ok transport orig=198\.51\.100\.1:443$' 10100 tcp ::ffff:198.51.100.1 443
	not_logged app-v4-mapped-not-reached net-443
	expect app-v4-mapped-loopback-redirected '^ok transport orig=127\.0\.0\.1:9052$' 10100 tcp ::ffff:127.0.0.1 9052
	expect app-ipv6-tcp-refused '^err ' 10100 tcp 2001:db8:1::1 443
	not_logged app-ipv6-tcp-not-reached net6-443
	expect app-ipv6-udp-refused '^err ' 10100 udp 2001:db8:1::1 53
	expect app-ipv6-loopback-refused '^err ' 10100 tcp ::1 9999
fi
expect dnsf-dnsport-udp '^ok tor-dnsport$' 2951 udp 127.0.0.1 9053
expect dnsf-dnsport-tcp '^ok tor-dnsport-tcp ' 2951 tcp 127.0.0.1 9053
expect dnsf-net-refused '^err ECONNREFUSED$' 2951 tcp 198.51.100.1 443
expect dnsf-dns-out-refused '^err ' 2951 udp 198.51.100.1 53
expect dnsf-transport-refused '^err ECONNREFUSED$' 2951 tcp 127.0.0.1 9040
expect dnsf-control-socket-denied '^err EACCES$' 2951 unix "$AD/run/tor-control.sock"
expect root-tcp-redirected '^ok transport orig=198\.51\.100\.1:443$' 0 tcp 198.51.100.1 443
expect root-udp-refused '^err ' 0 udp 198.51.100.1 123
expect root-ping-refused '^err ' 0 ping 198.51.100.1
expect root-control-socket '^ok tor-control$' 0 unix "$AD/run/tor-control.sock"
expect system-uid-tcp-redirected '^ok transport orig=192\.168\.77\.1:80$' 1000 tcp 192.168.77.1 80
expect netstack-other-udp-refused '^err ' 1073 udp 198.51.100.1 123
if ! skip_v6 root-ipv6; then
	expect root-ipv6-loopback-allowed '^ok sys-v6 ' 0 tcp ::1 9999
	expect root-ipv6-net-refused '^err ' 0 tcp 2001:db8:1::1 443
	expect tor-ipv6-loopback-refused '^err ' 2950 tcp ::1 9999
fi
expect_up inbound-tcp-dropped '^err ' tcp 192.168.77.2 8080 --timeout 1
not_logged inbound-tcp-not-reached phone-service
expect_up inbound-udp-dropped '^err ' udp 192.168.77.2 8081 --timeout 1
not_logged inbound-udp-not-reached phone-udp
tx1=$(tx)
[ "$tx1" = "$tx0" ] && pass only-tor-leaves-the-phone || fail only-tor-leaves-the-phone "$((tx1 - tx0)) packets sent"

echo "-- tor (2950) and the network stack's DHCP (1073)"
tx0=$(tx)
expect tor-net-tcp '^ok net-443 ' 2950 tcp 198.51.100.1 443
expect tor-net-udp '^ok net-123$' 2950 udp 198.51.100.1 123
expect tor-net-ping '^ok echo-reply$' 2950 ping 198.51.100.1
[ "$(tx)" -gt "$tx0" ] && pass tor-traffic-leaves || fail tor-traffic-leaves
expect tor-lan-refused '^err ECONNREFUSED$' 2950 tcp 192.168.77.1 80
not_logged tor-lan-not-reached lan-80
expect tor-lan-dns-refused '^err ' 2950 udp 192.168.77.1 53
expect tor-multicast-refused '^err ' 2950 udp 224.0.0.251 5353
expect tor-own-address-refused '^err ECONNREFUSED$' 2950 tcp 192.168.77.2 8080
expect tor-status-page-refused '^err ECONNREFUSED$' 2950 tcp 127.0.0.1 5380
expect tor-dns-filter-refused '^err ' 2950 udp 127.0.0.1 5353
expect tor-controlport-refused '^err ECONNREFUSED$' 2950 tcp 127.0.0.1 9052
expect tor-pluggable-transport '^ok tor-pt ' 2950 tcp 127.0.0.1 40000
expect tor-control-socket '^ok tor-control$' 2950 unix "$AD/run/tor-control.sock"
expect netstack-dhcp-renewal '^ok dhcp-server$' 1073 udp 192.168.77.1 67 --sport 68
tx0=$(tx)
expect netstack-dhcp-broadcast-sent '^err ETIMEDOUT$' 1073 udp 255.255.255.255 67 --sport 68 --broadcast --timeout 0.5
[ "$(tx)" -gt "$tx0" ] && pass netstack-dhcp-broadcast-left || fail netstack-dhcp-broadcast-left
tx0=$(tx)
expect netstack-dhcp-public-refused '^err ' 1073 udp 198.51.100.1 67 --sport 68 --timeout 1
not_logged netstack-dhcp-public-not-reached dhcp-public
expect app-dhcp-broadcast-refused '^err ' 10100 udp 255.255.255.255 67 --sport 68 --broadcast --timeout 1
[ "$(tx)" = "$tx0" ] && pass dhcp-public-nothing-left || fail dhcp-public-nothing-left "$(($(tx) - tx0)) packets sent"
start_serve "$P" 0 phone-dhcpc udp:dhcp-client:192.168.77.2:68
wait_ready
token inbound-dhcp-from-lan
probe_up udp 192.168.77.2 68 "$TOK" --sport 67 --bind 192.168.77.1 --timeout 0.5 >/dev/null
logged inbound-dhcp-from-lan dhcp-client
token inbound-dhcp-from-public
probe_up udp 192.168.77.2 68 "$TOK" --sport 67 --bind 198.51.100.1 --timeout 0.5 >/dev/null
not_logged inbound-dhcp-from-public-dropped dhcp-client
stop_serve phone-dhcpc
# tor may reach its pluggable transports (uid 2950) in the ephemeral range,
# but not another uid's listener there: the handshake is never completed.
expect tor-other-uid-ephemeral-refused '^err ETIMEDOUT$' 2950 tcp 127.0.0.1 41000 --timeout 1
not_logged tor-other-uid-ephemeral-not-served app-ephemeral
expect tor-pluggable-transport-again '^ok tor-pt ' 2950 tcp 127.0.0.1 40000

echo "-- tor and the DNS filter stopped: an app holding their ports answers no one"
stop_serve phone-tor
stop_serve phone-dns
start_serve "$P" 10100 phone-squat tcp:squat-transport:127.0.0.1:9040 tcp:squat-dnsport-tcp:127.0.0.1:9053 \
	udp:squat-dnsport:127.0.0.1:9053 tcp:squat-filter-tcp:127.0.0.1:5353 udp:squat-filter:127.0.0.1:5353 \
	tcp:squat-status:127.0.0.1:5380
wait_ready
tx0=$(tx)
expect squat-app-tcp-no-handshake '^err ETIMEDOUT$' 10200 tcp 198.51.100.1 443 --timeout 1
not_logged squat-app-tcp-not-served squat-transport
expect squat-root-tcp-no-handshake '^err ETIMEDOUT$' 0 tcp 198.51.100.1 443 --timeout 1
not_logged squat-root-tcp-not-served squat-transport
expect squat-transport-direct-no-handshake '^err ETIMEDOUT$' 10200 tcp 127.0.0.1 9040 --timeout 1
expect squat-own-uid-no-handshake '^err ETIMEDOUT$' 10100 tcp 127.0.0.1 9040 --timeout 1
expect squat-app-dns-no-answer '^err ' 10200 udp 198.51.100.1 53 --timeout 1
# The query itself still reaches the squatting socket: iptables cannot see
# which socket receives a datagram. Only its answer is stopped.
logged squat-app-dns-query-received squat-filter
expect squat-app-dns-tcp-no-handshake '^err ETIMEDOUT$' 10200 tcp 198.51.100.1 53 --timeout 1
not_logged squat-app-dns-tcp-not-served squat-filter-tcp
expect squat-filter-direct-no-answer '^err ' 10200 udp 127.0.0.1 5353 --timeout 1
expect squat-status-no-handshake '^err ETIMEDOUT$' 10200 tcp 127.0.0.1 5380 --timeout 1
not_logged squat-status-not-served squat-status
expect squat-dnsport-no-answer '^err ' 2951 udp 127.0.0.1 9053 --timeout 1
expect squat-dnsport-tcp-no-handshake '^err ETIMEDOUT$' 2951 tcp 127.0.0.1 9053 --timeout 1
not_logged squat-dnsport-tcp-not-served squat-dnsport-tcp
tx1=$(tx)
[ "$tx1" = "$tx0" ] && pass squat-nothing-left-the-phone || fail squat-nothing-left-the-phone "$((tx1 - tx0)) packets sent"
stop_serve phone-squat
start_tor
start_dnsfilter
wait_ready
expect squat-gone-transport-back '^ok transport orig=198\.51\.100\.1:443$' 10200 tcp 198.51.100.1 443
expect squat-gone-dns-back '^ok dnsfilter$' 10200 udp 198.51.100.1 53
expect squat-gone-status-back '^ok status ' 10200 tcp 127.0.0.1 5380
expect squat-gone-dnsport-back '^ok tor-dnsport$' 2951 udp 127.0.0.1 9053

echo "-- netd starting after the firewall"
# What netd's Controllers::initChildChains does: append its chains to
# filter OUTPUT and mangle POSTROUTING, flush filter INPUT and FORWARD,
# mangle INPUT and OUTPUT and nat PREROUTING and POSTROUTING, and save the
# fwmark's low 20 bits into the connection mark.
inp "$RST4" -w --noflush <<'EOF'
*filter
:INPUT -
-F INPUT
:FORWARD -
-F FORWARD
:fw_OUTPUT - [0:0]
:bw_INPUT - [0:0]
-A OUTPUT -j fw_OUTPUT
-A INPUT -j bw_INPUT
COMMIT
*mangle
:INPUT -
-F INPUT
:OUTPUT -
-F OUTPUT
:connmark_mangle_OUTPUT - [0:0]
:connmark_mangle_INPUT - [0:0]
:bw_mangle_POSTROUTING - [0:0]
-A OUTPUT -j MARK --set-xmark 0x10064/0xfffff
-A OUTPUT -j connmark_mangle_OUTPUT
-A INPUT -j connmark_mangle_INPUT
-A POSTROUTING -j bw_mangle_POSTROUTING
-A connmark_mangle_OUTPUT -m connmark --mark 0x0/0xfffff -j CONNMARK --save-mark --nfmask 0xfffff --ctmask 0xfffff
-A connmark_mangle_INPUT -m connmark --mark 0x0/0xfffff -j CONNMARK --save-mark --nfmask 0xfffff --ctmask 0xfffff
COMMIT
*nat
:PREROUTING -
-F PREROUTING
:POSTROUTING -
-F POSTROUTING
COMMIT
EOF
out=$(fw status 2>/dev/null)
check_rc netd-start-still-live 0 $?
expect netd-tor-still-works '^ok net-443 ' 2950 tcp 198.51.100.1 443
expect netd-app-still-redirected '^ok transport orig=192\.168\.77\.1:80$' 10100 tcp 192.168.77.1 80

echo "-- tampering"
inp "$IPT4" -w -t mangle -I ANTUMBRA_POST 1 -j RETURN
out=$(fw status 2>/dev/null)
check_rc tamper-rule-not-live 2 $?
[ "$(status_field "$out" state)" = partial ] && pass tamper-rule-partial || fail tamper-rule-partial "$out"
fw apply >/dev/null 2>&1
out=$(fw status 2>/dev/null)
check_rc tamper-rule-repaired 0 $?
inp "$IPT4" -w -t mangle -D POSTROUTING -j ANTUMBRA_POST
out=$(fw status 2>/dev/null)
check_rc tamper-gate-open 3 $?
H2=$(fw apply 2>/dev/null)
[ "$H2" = "$HASH" ] && pass tamper-gate-repaired-same-hash || fail tamper-gate-repaired-same-hash "$H2"

echo "-- print needs no root"
out=$(inp setpriv --reuid=10100 --regid=10100 --clear-groups -- env ANTUMBRA_DIR="$AD" sh "$FW" print 2>&1)
case $out in *'-A ANTUMBRA_NAT -p tcp -j REDIRECT --to-ports 9040'*) pass print-as-app ;; *) fail print-as-app ;; esac

# --- Phase 3: an app with its own tor -------------------------------------------------

echo "== phase 3: exemptions, relays and DNS-over-HTTPS servers"
cat >"$AD/state/fw-exempt.conf" <<'EOF'
# Tor Browser in this session, with its own tor's SOCKS port (and, for the
# test, the fake pluggable transport's port, which tor's uid holds).
10101 9150,40000
10102 9053
1000 9150
2950
1010100 1:2,3:4,5:6,7:8,9:10,11:12,13:14,15:16
10103 9040
10104 9150,5353
10105 5380
10106 1000
10107 32000:33000
10108 9000:9100
10109 1024:65535
10110 59050
10111 2000:3000
not a line
EOF
cat >"$AD/state/fw-relays.conf" <<'EOF'
198.51.100.1 9001
999.1.1.1 443
198.51.100.1 9001
192.168.77.1 5000
EOF
# Single addresses only: the /24 is ignored as invalid, the /32 is taken.
printf '%s\n' 198.51.100.77 198.51.100.78/32 203.0.113.0/24 >"$AD/lists/doh-ipv4.txt"
chmod 644 "$AD/state/fw-exempt.conf" "$AD/state/fw-relays.conf" "$AD/lists/doh-ipv4.txt"
fw apply >/dev/null 2>"$TMP/err"
check_rc exempt-apply-exit 0 $?
grep -q 'ignored invalid line: 10102 9053' "$TMP/err" && grep -q 'ignored invalid line: 1000 9150' "$TMP/err" &&
	grep -q 'ignored invalid line: 2950' "$TMP/err" && grep -q 'ignored invalid line: 1010100' "$TMP/err" &&
	grep -q 'fw-relays.conf: ignored 1 invalid' "$TMP/err" && pass exempt-invalid-lines-reported ||
	fail exempt-invalid-lines-reported "$(cat "$TMP/err")"
grep -q 'doh-ipv4.txt: ignored 1 invalid' "$TMP/err" && pass doh-prefix-refused || fail doh-prefix-refused "$(cat "$TMP/err")"
n=$(inp "$IPT4" -w -t filter -S ANTUMBRA_DOH | grep -c -e '--ctorigdst ')
[ "$n" = 2 ] && pass doh-single-addresses-loaded || fail doh-single-addresses-loaded "$n rules"
# tor's and the filter's ports, ports below 1024 and ranges into the
# ephemeral range are never an app's own; a single high port is.
for line in '10103 9040' '10104 9150,5353' '10105 5380' '10106 1000' '10107 32000:33000' '10108 9000:9100' \
	'10109 1024:65535'; do
	grep -q "ignored invalid line: $line\$" "$TMP/err" && pass "exempt-refused-${line// /-}" ||
		fail "exempt-refused-${line// /-}" "$(cat "$TMP/err")"
done
for uid in 10110 10111; do
	n=$(inp "$IPT4" -w -t nat -S ANTUMBRA_NAT | grep -c -e "--uid-owner $uid ")
	[ "$n" = 2 ] && pass "exempt-accepted-$uid" || fail "exempt-accepted-$uid" "$n nat rules"
done
# Another app's own loopback connection from a listed port (10110's 59050,
# which the kernel can pick as an ephemeral source port while nothing listens
# there) is not an answer on that port: it works as usual.
expect exempt-port-as-client-source '^ok status ' 10100 tcp 127.0.0.1 5380 --sport 59050
[ "$(fw status 2>/dev/null | sed -n 's/^state=//p')" = live ] && pass exempt-status-live || fail exempt-status-live
expect exempt-own-port '^ok exempt-own ' 10101 tcp 127.0.0.1 9150
expect exempt-port-not-for-others '^ok transport orig=127\.0\.0\.1:9150$' 10100 tcp 127.0.0.1 9150
tx0=$(tx)
expect exempt-relay-direct '^ok net-9001 ' 10101 tcp 198.51.100.1 9001
[ "$(tx)" -gt "$tx0" ] && pass exempt-relay-left-directly || fail exempt-relay-left-directly
expect exempt-relay-not-for-others '^ok transport orig=198\.51\.100\.1:9001$' 10100 tcp 198.51.100.1 9001
expect exempt-non-relay-redirected '^ok transport orig=198\.51\.100\.1:443$' 10101 tcp 198.51.100.1 443
expect exempt-lan-redirected '^ok transport orig=192\.168\.77\.1:80$' 10101 tcp 192.168.77.1 80
expect exempt-lan-relay-refused '^err ECONNREFUSED$' 10101 tcp 192.168.77.1 5000
not_logged exempt-lan-relay-not-reached lan-5000
expect exempt-udp-refused '^err ' 10101 udp 198.51.100.1 123
expect exempt-dnsport-never '^ok transport orig=127\.0\.0\.1:9053$' 10102 tcp 127.0.0.1 9053
expect exempt-system-uid-never '^ok transport orig=127\.0\.0\.1:9150$' 1000 tcp 127.0.0.1 9150
expect exempt-tor-uid-never '^err ECONNREFUSED$' 2950 tcp 127.0.0.1 9150
# A listed port held by another uid (here tor's) answers neither the app...
expect exempt-port-of-other-uid-no-handshake '^err ETIMEDOUT$' 10101 tcp 127.0.0.1 40000 --timeout 1
# ...while tor's own connection to that port still works.
expect exempt-port-tor-pt-still-works '^ok tor-pt ' 2950 tcp 127.0.0.1 40000
# The exempt app's own port taken by another app while the app's tor is down.
stop_serve phone-exempt
start_serve "$P" 10100 phone-squat-exempt tcp:squat-exempt:127.0.0.1:9150
wait_ready
expect exempt-own-port-squatted '^err ETIMEDOUT$' 10101 tcp 127.0.0.1 9150 --timeout 1
not_logged exempt-own-port-squat-not-served squat-exempt
stop_serve phone-squat-exempt
start_serve "$P" 10101 phone-exempt tcp:exempt-own:127.0.0.1:9150
wait_ready
expect exempt-own-port-back '^ok exempt-own ' 10101 tcp 127.0.0.1 9150
expect doh-server-refused '^err ECONNREFUSED$' 10100 tcp 198.51.100.77 443
not_logged doh-server-not-redirected transport

FW_EXTRA_ENV=(ANTUMBRA_FW_NFLOG_GROUP=29)
fw apply >/dev/null 2>&1
check_rc nflog-apply-exit 0 $?
FW_EXTRA_ENV=()
n=$(inp "$IPT4" -w -t nat -S ANTUMBRA_NAT | grep -c 'NFLOG --nflog-prefix')
[ "$n" -ge 1 ] && pass nflog-rules-loaded || fail nflog-rules-loaded
expect nflog-relay-still-direct '^ok net-9001 ' 10101 tcp 198.51.100.1 9001

rm -f "$AD/state/fw-exempt.conf" "$AD/state/fw-relays.conf" "$AD/lists/doh-ipv4.txt"
H4=$(fw apply 2>/dev/null)
[ "$H4" = "$HASH" ] && pass lists-removed-same-hash-as-before || fail lists-removed-same-hash-as-before "$H4"

# --- Phase 4: flush -------------------------------------------------------------------

echo "== phase 4: flush"
fw flush 2>/dev/null
check_rc flush-exit 0 $?
out=$(fw status 2>/dev/null)
check_rc flush-status-exit 1 $?
[ "$(status_field "$out" state)" = armed ] && pass flush-status-armed || fail flush-status-armed "$out"
[ "$(status_field "$out" hash)" = "$ARMED_HASH" ] && pass flush-same-hash-as-arm || fail flush-same-hash-as-arm "$out"
[ "$(status_field "$out" recorded)" = none ] && pass flush-forgets-hash || fail flush-forgets-hash "$out"
n=$( (inp "$IPT4" -w -S; inp "$IPT4" -w -t nat -S; inp "$IPT4" -w -t mangle -S; inp "$IPT6" -w -S; inp "$IPT6" -w -t mangle -S) |
	grep -v ANTUMBRA_ARM_ | grep -c ANTUMBRA_)
[ "$n" = 0 ] && pass flush-removed-applied-chains || fail flush-removed-applied-chains "$n lines left"
tx0=$(tx)
expect flushed-tor-blocked '^err ' 2950 tcp 198.51.100.1 443 --timeout 1
expect flushed-tor-udp-blocked '^err ' 2950 udp 198.51.100.1 123 --timeout 1
expect flushed-app-blocked '^err ' 10100 tcp 192.168.77.1 80 --timeout 1
expect flushed-root-blocked '^err ' 0 udp 198.51.100.1 53 --timeout 1
expect flushed-dhcp-blocked '^err ' 1073 udp 192.168.77.1 67 --sport 68 --timeout 1
expect_up flushed-inbound-blocked '^err ' tcp 192.168.77.2 8080 --timeout 1
if ! skip_v6 flushed-ipv6-blocked; then
	expect flushed-ipv6-blocked '^err ' 2950 tcp 2001:db8:1::1 443 --timeout 1
fi
tx1=$(tx)
[ "$tx1" = "$tx0" ] && pass flushed-nothing-left-the-phone || fail flushed-nothing-left-the-phone "$((tx1 - tx0)) packets sent"
expect flushed-loopback-works '^ok transport orig=127\.0\.0\.1:9040$' 10100 tcp 127.0.0.1 9040

# --- Phase 5: failures leave the phone closed ------------------------------------------

echo "== phase 5: failure paths"
fw apply >/dev/null 2>&1
FW_EXTRA_ENV=(ANTUMBRA_FW_IPTABLES_RESTORE="$BIN/fail-restore")
fw apply >/dev/null 2>&1
rc=$?
FW_EXTRA_ENV=()
[ "$rc" != 0 ] && pass failed-apply-exits-nonzero || fail failed-apply-exits-nonzero
out=$(fw status 2>/dev/null)
check_rc failed-apply-leaves-armed 1 $?
[ "$(status_field "$out" recorded)" = none ] && pass failed-apply-no-hash || fail failed-apply-no-hash "$out"
tx0=$(tx)
expect failed-apply-tor-blocked '^err ' 2950 tcp 198.51.100.1 443 --timeout 1
[ "$(tx)" = "$tx0" ] && pass failed-apply-nothing-left || fail failed-apply-nothing-left

# flush from the live state when iptables-restore fails and the arm jumps
# cannot be inserted either (an xtables-lock timeout): the applied rules
# must stay, nothing may open.
fw apply >/dev/null 2>&1
FAIL_BOTH=(ANTUMBRA_FW_IPTABLES_RESTORE="$BIN/fail-restore" ANTUMBRA_FW_IP6TABLES_RESTORE="$BIN/fail-restore")
FW_EXTRA_ENV=("${FAIL_BOTH[@]}" ANTUMBRA_FW_IPTABLES="$BIN/ipt4-noinsert" ANTUMBRA_FW_IP6TABLES="$BIN/ipt6-noinsert")
fw flush 2>"$TMP/err"
rc=$?
FW_EXTRA_ENV=()
[ "$rc" != 0 ] && pass failed-flush-exits-nonzero || fail failed-flush-exits-nonzero
out=$(fw status 2>/dev/null)
rc=$?
[ "$rc" != 3 ] && [ "$(status_field "$out" state)" != open ] && pass failed-flush-not-open ||
	fail failed-flush-not-open "$out; $(head -c 300 "$TMP/err")"
n=$(count_jumps 4 filter ANTUMBRA_OUT)$(count_jumps 4 nat ANTUMBRA_NAT)$(count_jumps 4 mangle ANTUMBRA_IN)$(count_jumps 4 mangle ANTUMBRA_POST)$(count_jumps 6 filter ANTUMBRA_OUT)$(count_jumps 6 mangle ANTUMBRA_POST)
[ "$n" = 111111 ] && pass failed-flush-kept-the-rules || fail failed-flush-kept-the-rules "jump counts $n"
tx0=$(tx)
expect failed-flush-app-udp-refused '^err ' 10100 udp 198.51.100.1 123 --timeout 1
expect failed-flush-app-tcp-not-direct '^(ok transport |err )' 10100 tcp 198.51.100.1 443 --timeout 1
not_logged failed-flush-app-tcp-not-reached net-443
expect failed-flush-root-udp-refused '^err ' 0 udp 198.51.100.1 123 --timeout 1
expect failed-flush-app-lan-not-direct '^(ok transport |err )' 10100 tcp 192.168.77.1 80 --timeout 1
not_logged failed-flush-app-lan-not-reached lan-80
tx1=$(tx)
[ "$tx1" = "$tx0" ] && pass failed-flush-nothing-left || fail failed-flush-nothing-left "$((tx1 - tx0)) packets sent"

# flush when only iptables-restore fails: one command at a time, armed.
FW_EXTRA_ENV=("${FAIL_BOTH[@]}")
fw flush 2>/dev/null
rc=$?
FW_EXTRA_ENV=()
check_rc flush-fallback-exit 0 $rc
out=$(fw status 2>/dev/null)
check_rc flush-fallback-armed 1 $?
n=$(count_jumps 4 filter ANTUMBRA_OUT)$(count_jumps 4 nat ANTUMBRA_NAT)$(count_jumps 4 mangle ANTUMBRA_POST)$(count_jumps 6 filter ANTUMBRA_OUT)$(count_jumps 6 mangle ANTUMBRA_POST)
[ "$n" = 00000 ] && pass flush-fallback-unreferenced || fail flush-fallback-unreferenced "jump counts $n"
fw flush 2>/dev/null
out=$(fw status 2>/dev/null)
[ "$(status_field "$out" hash)" = "$ARMED_HASH" ] && pass flush-after-fallback-same-hash-as-arm ||
	fail flush-after-fallback-same-hash-as-arm "$out"

# An arm chain someone changed is rebuilt one command at a time, closed at
# every step.
inp "$IPT4" -w -t mangle -I ANTUMBRA_ARM_POST 1 -j RETURN
out=$(fw status 2>/dev/null)
[ "$(status_field "$out" state)" != armed ] && pass tampered-arm-chain-noticed || fail tampered-arm-chain-noticed "$out"
FW_EXTRA_ENV=("${FAIL_BOTH[@]}")
fw arm 2>/dev/null
check_rc tampered-arm-chain-rebuilt-exit 0 $?
FW_EXTRA_ENV=()
out=$(fw status 2>/dev/null)
check_rc tampered-arm-chain-rebuilt 1 $?
[ "$(status_field "$out" hash)" = "$ARMED_HASH" ] && pass tampered-arm-chain-same-rules ||
	fail tampered-arm-chain-same-rules "$out"

# fresh_boot: no rules at all, as before post-fs-data.
fresh_boot() {
	for f in 4 6; do
		if [ $f = 4 ]; then t=$IPT4; tabs="filter nat mangle"; else t=$IPT6; tabs="filter mangle"; fi
		for tab in $tabs; do inp "$t" -w -t "$tab" -F; inp "$t" -w -t "$tab" -X; done
		inp "$t" -w -P FORWARD ACCEPT
	done
}

# A fresh boot where iptables-restore does not work: arm falls back to single
# commands.
fresh_boot
out=$(fw status 2>/dev/null)
check_rc fresh-boot-open 3 $?
FW_EXTRA_ENV=("${FAIL_BOTH[@]}")
fw arm 2>/dev/null
check_rc arm-fallback-exit 0 $?
FW_EXTRA_ENV=()
out=$(fw status 2>/dev/null)
check_rc arm-fallback-armed 1 $?
[ "$(status_field "$out" hash)" = "$ARMED_HASH" ] && pass arm-fallback-same-rules || fail arm-fallback-same-rules "$out"
tx0=$(tx)
expect arm-fallback-tor-blocked '^err ' 2950 tcp 198.51.100.1 443 --timeout 1
[ "$(tx)" = "$tx0" ] && pass arm-fallback-nothing-left || fail arm-fallback-nothing-left

# A missing -restore tool: arm uses single commands.
fresh_boot
FW_EXTRA_ENV=(ANTUMBRA_FW_IPTABLES_RESTORE=/nonexistent/iptables-restore ANTUMBRA_FW_IP6TABLES_RESTORE=/nonexistent/ip6tables-restore)
fw arm 2>/dev/null
check_rc missing-restore-arm-exit 0 $?
FW_EXTRA_ENV=()
out=$(fw status 2>/dev/null)
check_rc missing-restore-armed 1 $?

# A missing ip6tables: IPv4 is still armed, and arm fails loudly.
fresh_boot
FW_EXTRA_ENV=(ANTUMBRA_FW_IP6TABLES=/nonexistent/ip6tables)
fw arm 2>/dev/null
rc=$?
FW_EXTRA_ENV=()
[ "$rc" != 0 ] && pass missing-tool-arm-fails || fail missing-tool-arm-fails
out=$(fw status 2>/dev/null)
[ "$(status_field "$out" ipv4)" = armed ] && pass missing-ip6tables-ipv4-armed || fail missing-ip6tables-ipv4-armed "$out"
fw arm 2>/dev/null

# The firewall's own directory: root's alone, never tor's run/.
echo "-- the lock and the recorded hash"
fw apply >/dev/null 2>&1
[ -f "$AD/state/fw/fw.hash" ] && pass fwdir-hash-in-state || fail fwdir-hash-in-state "$(ls -la "$AD/state" "$AD/state/fw" 2>&1)"
left=$(find "$AD/run" -name 'fw.*')
[ -z "$left" ] && pass fwdir-nothing-in-run || fail fwdir-nothing-in-run "$left"
echo keep >"$TMP/victim"
ln -sf "$TMP/victim" "$AD/state/fw/fw.hash.tmp"
fw apply >/dev/null 2>&1
check_rc fwdir-planted-link-apply 0 $?
[ "$(cat "$TMP/victim")" = keep ] && pass fwdir-planted-link-not-followed || fail fwdir-planted-link-not-followed
mkdir -p "$TMP/elsewhere" "$TMP/appdir/fw"
ln -s "$TMP/elsewhere" "$TMP/fwlink"
chown 10100:10100 "$TMP/appdir/fw"
for case in "link:$TMP/fwlink" "app-owned:$TMP/appdir/fw"; do
	name=${case%%:*}
	dir=${case#*:}
	FW_EXTRA_ENV=(ANTUMBRA_FW_DIR="$dir")
	fw apply >/dev/null 2>&1
	rc=$?
	out=$(fw status 2>/dev/null)
	FW_EXTRA_ENV=()
	check_rc "fwdir-$name-refused" 1 $rc
	[ -z "$(ls -A "$dir")" ] && pass "fwdir-$name-nothing-written" || fail "fwdir-$name-nothing-written" "$(ls -A "$dir")"
	[ "$(status_field "$out" recorded)" = none ] && pass "fwdir-$name-not-read" || fail "fwdir-$name-not-read" "$out"
done
out=$(fw status 2>/dev/null)
check_rc fwdir-default-still-live 0 $?

# --- Phase 6: the same rules from every shell and userland --------------------------------

echo "== phase 6: shells"
MKSH=${AFW_TEST_MKSH:-$(command -v mksh 2>/dev/null)}
TOYBOX=${AFW_TEST_TOYBOX:-$(command -v toybox 2>/dev/null)}
BUSYBOX=$(command -v busybox 2>/dev/null)
TOOLS="cat chmod cut date dirname env grep head id ls mkdir mv printf rm sed sha256sum sleep sort tail"
applet_dir() { # applet_dir DIR MULTICALL-BINARY: symlinks for the tools it has
	mkdir -p "$1"
	# busybox --list prints one applet per line; toybox alone prints them all.
	applets=$({ "$2" --list 2>/dev/null || "$2" 2>/dev/null; } | tr -s ' \t' '\n')
	for tool in $TOOLS; do
		if printf '%s\n' "$applets" | grep -qx "$tool"; then ln -sf "$2" "$1/$tool"; fi
	done
}
required() { case " ${AFW_TEST_REQUIRE_SHELLS:-} " in *" $1 "*) return 0 ;; esac; return 1; }
shell_case() { # shell_case NAME PATH-PREFIX SHELL-COMMAND...
	name=$1
	prefix=$2
	shift 2
	saved=("${FW_SHELL[@]}")
	FW_SHELL=(env "PATH=${prefix:+$prefix:}$PATH" "$@")
	h=$(fw apply 2>"$TMP/err")
	rc1=$?
	fw status >/dev/null 2>&1
	rc2=$?
	fw flush 2>>"$TMP/err"
	rc3=$?
	a=$(fw status 2>/dev/null)
	rc4=$?
	# The single-command paths and the directory checks, in this shell too.
	fw apply >/dev/null 2>&1
	FW_EXTRA_ENV=("${FAIL_BOTH[@]}")
	fw flush 2>/dev/null
	rc5=$?
	FW_EXTRA_ENV=()
	fw status >/dev/null 2>&1
	rc6=$?
	fw flush 2>/dev/null
	FW_EXTRA_ENV=(ANTUMBRA_FW_DIR="$TMP/fwlink")
	fw apply >/dev/null 2>&1
	rc7=$?
	FW_EXTRA_ENV=(ANTUMBRA_FW_DIR="$TMP/appdir/fw")
	fw apply >/dev/null 2>&1
	rc8=$?
	FW_EXTRA_ENV=()
	ln -sf "$TMP/victim" "$AD/state/fw/fw.hash.tmp"
	h2=$(fw apply 2>/dev/null)
	v=$(cat "$TMP/victim")
	fw flush 2>/dev/null
	FW_SHELL=("${saved[@]}")
	if [ $rc1 = 0 ] && [ "$h" = "$HASH" ] && [ $rc2 = 0 ] && [ $rc3 = 0 ] && [ $rc4 = 1 ] &&
		[ "$(status_field "$a" hash)" = "$ARMED_HASH" ] && [ $rc5 = 0 ] && [ $rc6 = 1 ] && [ $rc7 = 1 ] &&
		[ $rc8 = 1 ] && [ "$h2" = "$HASH" ] && [ "$v" = keep ]; then
		pass "shell-$name"
	else
		fail "shell-$name" "apply $rc1 status $rc2 flush $rc3 status $rc4 fallback-flush $rc5 status $rc6 link-dir $rc7 app-dir $rc8 victim '$v'; $(head -c 300 "$TMP/err")"
	fi
}
shell_case bash '' bash
if command -v dash >/dev/null 2>&1; then shell_case dash '' dash; elif required dash; then fail shell-dash "dash not found"; else skip shell-dash "dash not found"; fi
if [ -n "$BUSYBOX" ]; then
	applet_dir "$TMP/bb" "$BUSYBOX"
	shell_case busybox "$TMP/bb" "$BUSYBOX" sh
elif required busybox; then fail shell-busybox "busybox not found"; else skip shell-busybox "busybox not found"; fi
if [ -n "$MKSH" ]; then
	shell_case mksh '' "$MKSH"
	if [ -n "$TOYBOX" ]; then
		applet_dir "$TMP/toy" "$TOYBOX"
		shell_case mksh+toybox "$TMP/toy" "$MKSH"
	elif required mksh+toybox; then fail shell-mksh+toybox "toybox not found"; else skip shell-mksh+toybox "toybox not found"; fi
else
	if required mksh; then fail shell-mksh "mksh not found"; else skip shell-mksh "mksh not found"; fi
	if required mksh+toybox; then fail shell-mksh+toybox "mksh not found"; else skip shell-mksh+toybox "mksh not found"; fi
fi

# --- Phase 7: a full relay list ---------------------------------------------------------

echo "== phase 7: 8000 relays"
echo "10101" >"$AD/state/fw-exempt.conf"
python3 -I -c '
for i in range(8000):
    print("203.0.%d.%d %d" % (i // 250, i % 250 + 1, 443 if i % 2 else 9001))
' >"$AD/state/fw-relays.conf"
chmod 644 "$AD/state/fw-exempt.conf" "$AD/state/fw-relays.conf"
start=$(date +%s.%N)
fw apply >/dev/null 2>"$TMP/err"
rc=$?
end=$(date +%s.%N)
check_rc relays-8000-apply 0 $rc
echo "INFO apply with 8000 relays took $(python3 -I -c "print(round($end - $start, 2))") s"
n=$(inp "$IPT4" -w -t nat -S ANTUMBRA_RELAYS | grep -c '^-A ')
[ "$n" = 8000 ] && pass relays-8000-loaded || fail relays-8000-loaded "$n rules"
rm -f "$AD/state/fw-exempt.conf" "$AD/state/fw-relays.conf"
fw flush >/dev/null 2>&1

# --- Summary --------------------------------------------------------------------------------

echo "== $PASSES passed, $FAILS failed, $SKIPS skipped"
if [ "$FAILS" -gt 0 ]; then
	echo "failed:$FAILED_NAMES"
	exit 1
fi
exit 0
