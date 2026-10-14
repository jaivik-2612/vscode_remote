# shellcheck shell=sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Antumbra module: definitions and functions shared by post-fs-data.sh,
# service.sh and uninstall.sh. This file is sourced, never executed; the
# caller sets MODDIR first.
#
# It must run under three shells: Magisk's and KernelSU's busybox ash in
# "standalone" mode (where every command name is a busybox applet unless it
# is called by its full path), Android's mksh (the CI emulator, where the
# scripts are started by hand), and dash, bash and busybox on Linux for the
# tests. So it is plain POSIX sh, and Android's own tools are always called
# by their full path.

# --- Paths and numbers fixed by the shared contract -------------------------

ANTUMBRA_DIR=/data/adb/antumbra
RUN=$ANTUMBRA_DIR/run          # owned by tor (uid 2950); see "Trust" below
STATE=$ANTUMBRA_DIR/state      # root
LISTS=$ANTUMBRA_DIR/lists      # root
LOGDIR=$ANTUMBRA_DIR/log       # root
TOR_UID=2950
DNS_UID=2951
# Android's AID_INET: kernels with the old "paranoid network" check let a
# process open an Internet socket only when it is in this group.
INET_GID=3003
PROVIDER_URI=content://org.antumbra.welcome.state/session
# shellcheck disable=SC2034 # used by service.sh
WELCOME_PKG=org.antumbra.welcome
FW_PROP=antumbra.fw.armed
# The loopback service ports and their owners: tor's TransPort (TCP) and
# DNSPort (UDP), the DNS filter (UDP and TCP) and its status page (TCP).
TRANS_PORT=9040
TOR_DNS_PORT=9053
FILTER_PORT=5335
STATUS_PORT=5380

# --- Paths of this module (not part of the contract) ------------------------

BIN=$MODDIR/bin
TORRC=$MODDIR/etc/torrc
# Root-only state of the module: process IDs, the session record, the
# firewall's lock and recorded hash. Inside STATE, which is root's.
PRIV=$STATE/module
# The firewall keeps its lock and its recorded hash under its ANTUMBRA_DIR
# (in a root-only state/fw since the v0 fixes; in run/ before). The module
# gives it this root-only directory as ANTUMBRA_DIR (see fw()), so neither
# is ever in the tor-owned RUN; 'antumbra-fw status' run by hand (or by CI)
# must be given the same ANTUMBRA_DIR.
FWDIR=$PRIV/fw
# The arm step runs before the runtime tmpfs exists. It gets a directory in
# /dev, which is in RAM, so that its lock never touches flash.
# shellcheck disable=SC2034 # used by post-fs-data.sh and service.sh
ARMDIR=/dev/antumbra-fw
TB=/system/bin/toybox

# Trust: tor insists on owning the directory of its control socket, so
# RUN belongs to uid 2950. A process running as root must never open, write
# or follow a path inside RUN, because tor could have replaced it with a
# symbolic link to any file. Everything the module does in RUN (reading the
# control cookie, talking to the socket, writing status.json) is done by a
# helper process running as uid 2950 itself, which gains nothing from such a
# link. LOGDIR, STATE and LISTS belong to root and nothing else can write
# them.

# --- Logging -----------------------------------------------------------------

LOG_TAG=${LOG_TAG:-antumbra}

# log MESSAGE: append one line to log/module.log (in RAM). Messages never
# contain bridge lines, session IDs or addresses.
log() {
	_lg_t=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)
	if [ -d "$LOGDIR" ] && [ ! -L "$LOGDIR/module.log" ]; then
		printf '%s %s: %s\n' "$_lg_t" "$LOG_TAG" "$*" >>"$LOGDIR/module.log" 2>/dev/null && return 0
	fi
	printf '%s %s: %s\n' "$_lg_t" "$LOG_TAG" "$*" >&2
}

# --- Small helpers ------------------------------------------------------------

# write_value FILE VALUE: write VALUE to a sysctl or sysfs file if it exists.
write_value() {
	[ -e "$1" ] || return 1
	printf '%s\n' "$2" >"$1" 2>/dev/null
}

# read_value FILE: print the first line of FILE (empty if unreadable).
read_value() {
	_rv=
	[ -r "$1" ] && IFS= read -r _rv <"$1" 2>/dev/null
	printf '%s' "$_rv"
}

# uptime_s: print whole seconds since boot. Schedules use this monotonic
# clock, never the wall clock: network time is off, so the clock is set by
# hand (or by Welcome) for tor, and a clock set back by D seconds would
# delay every check and restart by D.
uptime_s() {
	_us=
	read -r _us _ </proc/uptime 2>/dev/null
	_us=${_us%%.*}
	case $_us in '' | *[!0-9]*) _us=0 ;; esac
	printf '%s\n' "$_us"
}

# is_lineage, is_emulator: what kind of Android this is.
is_lineage() { [ -n "$(getprop ro.lineage.version 2>/dev/null)" ]; }
is_emulator() {
	[ "$(getprop ro.boot.qemu 2>/dev/null)" = 1 ] ||
		[ "$(getprop ro.kernel.qemu 2>/dev/null)" = 1 ] ||
		[ "$(getprop ro.hardware 2>/dev/null)" = ranchu ]
}

# getprop is not a busybox applet, so it is found in /system/bin through
# PATH in every shell. resetprop exists only under Magisk and KernelSU.
have_resetprop() { command -v resetprop >/dev/null 2>&1; }

# prop_set NAME VALUE and prop_clear NAME: set or remove a system property.
# Under Magisk and KernelSU this is 'resetprop -n', which skips init's
# property triggers; plain setprop would deadlock in post-fs-data. The CI
# emulator has no resetprop; there the module's scripts are started by hand
# after boot from adb's root shell, whose SELinux domain (su) is permissive
# on debug builds, so init accepts setprop for this property.
prop_set() {
	if have_resetprop; then
		resetprop -n "$1" "$2"
	else
		setprop "$1" "$2"
	fi
}
prop_clear() {
	if have_resetprop; then
		resetprop --delete "$1" >/dev/null 2>&1
		[ -z "$(getprop "$1" 2>/dev/null)" ] || resetprop -n "$1" ''
	elif [ -n "$(getprop "$1" 2>/dev/null)" ]; then
		setprop "$1" '' 2>/dev/null
	fi
	return 0
}

# --- The firewall ---------------------------------------------------------------

# fw COMMAND: run antumbra-fw (arm, apply, status, flush) with the module's
# file locations. ANTUMBRA_DIR is the firewall's own root-only directory, so
# its lock and recorded hash are never in the tor-owned RUN; the three
# input files are named explicitly. The DoH list in LISTS (an update) wins
# over the copy shipped in the module.
fw() {
	_fw_doh=$MODDIR/lists/doh-ipv4.txt
	[ -f "$LISTS/doh-ipv4.txt" ] && _fw_doh=$LISTS/doh-ipv4.txt
	ANTUMBRA_DIR=$FWDIR \
		ANTUMBRA_FW_EXEMPT=$STATE/fw-exempt.conf \
		ANTUMBRA_FW_RELAYS=$STATE/fw-relays.conf \
		ANTUMBRA_FW_DOH=$_fw_doh \
		"$BIN/antumbra-fw" "$@"
}

# fw_state: print the firewall's state as 'status' reports it (live, armed,
# partial, open), or "open" if it says nothing.
fw_state() {
	_fs=$(fw status 2>/dev/null | sed -n 's/^state=//p')
	printf '%s\n' "${_fs:-open}"
}

# fw_unpublish REASON: remove the property and go back to the armed state.
fw_unpublish() {
	prop_clear "$FW_PROP"
	fw flush >/dev/null 2>>"$LOGDIR/firewall.log"
	log "firewall: back to armed: $1"
}

# fw_publish: run 'apply', check the result with 'status', and only then
# publish the first 16 hex digits of the rule-set hash as antumbra.fw.armed.
# On any failure the firewall is back in its armed state (no network at
# all) and the property is removed. Prints the hash prefix; returns 0 only
# when the full rule set is live. While another uid holds one of the
# service ports (listeners_ok), the full rule set would send traffic to it,
# so it is not loaded at all, or taken back at once.
fw_publish() {
	if ! listeners_ok; then
		fw_unpublish "$PORTS_BAD"
		return 1
	fi
	_fp_hash=$(fw apply 2>>"$LOGDIR/firewall.log") || {
		log "firewall: apply failed; the network stays closed"
		prop_clear "$FW_PROP"
		return 1
	}
	case $_fp_hash in
	*[!0-9a-f]* | '') _fp_hash=bad ;;
	esac
	case ${#_fp_hash} in
	64) ;;
	*)
		log "firewall: apply printed no hash"
		fw flush >/dev/null 2>>"$LOGDIR/firewall.log"
		prop_clear "$FW_PROP"
		return 1
		;;
	esac
	_fp_status=$(fw status 2>>"$LOGDIR/firewall.log")
	_fp_rc=$?
	_fp_live=$(printf '%s\n' "$_fp_status" | sed -n 's/^hash=//p')
	if [ "$_fp_rc" -ne 0 ] || [ "$_fp_live" != "$_fp_hash" ]; then
		log "firewall: rule set not live after apply (status $_fp_rc); back to armed"
		fw flush >/dev/null 2>>"$LOGDIR/firewall.log"
		prop_clear "$FW_PROP"
		return 1
	fi
	# A port taken while 'apply' ran.
	if ! listeners_ok; then
		fw_unpublish "$PORTS_BAD"
		return 1
	fi
	_fp_prefix=$(printf '%s' "$_fp_hash" | cut -c1-16)
	prop_set "$FW_PROP" "$_fp_prefix" || {
		log "firewall: live, but the property could not be set"
		return 1
	}
	printf '%s\n' "$_fp_prefix"
}

# --- Starting programs as their own users -------------------------------------

# as_user UID [OPTIONS] -- PROGRAM ARGS...: run PROGRAM as UID, with GID
# equal to UID, the Internet group and no capabilities. OPTIONS are
# antumbra-run's -s, -d DIR and -e NAME=VALUE (see helper/antumbra-run.c).
as_user() {
	_au_uid=$1
	shift
	"$BIN/antumbra-run" -u "$_au_uid" -g "$_au_uid" -G "$INET_GID" "$@"
}

# pid_alive PIDFILE UID: true if the process in PIDFILE runs and belongs to
# UID (so a recycled process ID is not mistaken for ours).
pid_alive() {
	_pa_pid=$(read_value "$1")
	case $_pa_pid in '' | *[!0-9]*) return 1 ;; esac
	kill -0 "$_pa_pid" 2>/dev/null || return 1
	_pa_uid=$(sed -n 's/^Uid:[[:space:]]*\([0-9]*\).*/\1/p' "/proc/$_pa_pid/status" 2>/dev/null)
	[ "$_pa_uid" = "$2" ]
}

# --- Who holds the service ports -------------------------------------------------
#
# The firewall sends every app's TCP to 127.0.0.1:9040 and every DNS query
# to 127.0.0.1:5335, and lets apps reach 5380. Only tor (2950) may listen on
# 9040 and 9053, and only the filter (2951) on 5335 and 5380. But tor holds
# no TransPort or DNSPort while its network is off (before Start, in an
# offline session, while it restarts), and the filter's ports are free while
# it restarts: then any app can bind them. The firewall drops the answers
# of a socket that is not the owner's (ANTUMBRA_SQUAT), but cannot stop it
# from receiving: a TCP squatter gets the SYNs, a UDP one every query and
# its name. So the module checks, before it loads the full rule set, at
# every turn of its loop and before tor's network goes on, that each of
# these ports is free or held by its owner. Otherwise it goes back to the
# armed state (no redirect, nothing leaves) until the port is free again.
#
# Sockets that can receive what is sent to 127.0.0.1 count: bound to
# 127.0.0.1, 0.0.0.0, :: or ::ffff:127.0.0.1. TCP in LISTEN (state 0A):
# 9040, 9053, 5335, 5380. UDP in any state: 9053, 5335. /proc/net prints
# addresses and ports in hex, IPv4 addresses in host (little-endian) order.
PROC_NET=${PROC_NET:-/proc/net}

# ports_bad: print "PORT/PROTO held by uid UID" for every such socket that
# is not its owner's, one per line. Prints nothing when all is well.
ports_bad() {
	if [ ! -r "$PROC_NET/tcp" ]; then
		echo "$PROC_NET/tcp is unreadable"
		return 0
	fi
	for _pb_f in tcp tcp6 udp udp6; do
		[ -r "$PROC_NET/$_pb_f" ] || continue
		grep -E ':(2350|235D|14D7|1504) ' "$PROC_NET/$_pb_f" 2>/dev/null |
			while read -r _ _pb_loc _ _pb_st _ _ _ _pb_uid _; do
				case ${_pb_loc%:*} in
				0100007F | 00000000 | 00000000000000000000000000000000 | 0000000000000000FFFF00000100007F) ;;
				*) continue ;;
				esac
				case ${_pb_f%6}:${_pb_loc##*:} in
				tcp:2350) _pb_p=$TRANS_PORT/tcp _pb_want=$TOR_UID ;;
				tcp:235D) _pb_p=$TOR_DNS_PORT/tcp _pb_want=$TOR_UID ;;
				tcp:14D7) _pb_p=$FILTER_PORT/tcp _pb_want=$DNS_UID ;;
				tcp:1504) _pb_p=$STATUS_PORT/tcp _pb_want=$DNS_UID ;;
				udp:235D) _pb_p=$TOR_DNS_PORT/udp _pb_want=$TOR_UID ;;
				udp:14D7) _pb_p=$FILTER_PORT/udp _pb_want=$DNS_UID ;;
				*) continue ;;
				esac
				# TCP: listeners only. Accepted connections are the
				# listener's, and a TIME_WAIT entry shows uid 0.
				case ${_pb_f%6}:$_pb_st in tcp:0A | udp:*) ;; *) continue ;; esac
				[ "$_pb_uid" = "$_pb_want" ] || echo "$_pb_p held by uid $_pb_uid"
			done
	done
}

# listeners_ok: true if no other uid holds a service port. Sets PORTS_BAD
# to what is wrong (empty when all is well).
listeners_ok() {
	PORTS_BAD=$(ports_bad | sort -u | tr '\n' ';' | sed 's/;$//; s/;/; /g')
	[ -z "$PORTS_BAD" ]
}

# start_dnsfilter: start the DNS filter as uid 2951. It takes the first
# list that loads: an updated list in LISTS, else the one in the module. It
# refuses to run as root or with capabilities, and fails closed.
start_dnsfilter() {
	[ -x "$BIN/antumbra-dnsfilter" ] || {
		log "dnsfilter: binary missing; DNS stays off"
		return 1
	}
	set -- -list "$LISTS/dnsfilter.list" -list "$MODDIR/lists/dnsfilter.list"
	# The CI's switch, honoured on the emulator only, never on a phone: log
	# every query name, and show the status page's counters live
	# (ci/README.md, "debug.antumbra.log_queries").
	if is_emulator && [ "$(getprop debug.antumbra.log_queries 2>/dev/null)" = 1 ]; then
		set -- "$@" -debug-log-queries -status-refresh 0
		log "dnsfilter: emulator test mode: query names are logged"
	fi
	# The helper itself is put in the background (not a shell function
	# around it), so that $! is the process ID of the filter: antumbra-run
	# replaces itself with the program.
	"$BIN/antumbra-run" -u "$DNS_UID" -g "$DNS_UID" -G "$INET_GID" -s -- \
		"$BIN/antumbra-dnsfilter" "$@" \
		</dev/null >>"$LOGDIR/dnsfilter.log" 2>&1 &
	echo $! >"$PRIV/dnsfilter.pid"
	log "dnsfilter: started (pid $!)"
}

# start_tor: start tor as uid 2950 with the module's torrc. The torrc keeps
# the network off (DisableNetwork 1) until the module says otherwise over
# the control socket. tor writes its own log, log/tor.log, which root
# creates here so that it is a plain file in a root-owned directory.
start_tor() {
	if [ ! -x "$BIN/tor" ] || [ ! -r "$TORRC" ]; then
		log "tor: binary or torrc missing"
		return 1
	fi
	if [ ! -f "$LOGDIR/tor.log" ] || [ -L "$LOGDIR/tor.log" ]; then
		rm -f "$LOGDIR/tor.log"
		: >"$LOGDIR/tor.log"
	fi
	chown "$TOR_UID:$TOR_UID" "$LOGDIR/tor.log"
	chmod 0600 "$LOGDIR/tor.log"
	"$BIN/antumbra-run" -u "$TOR_UID" -g "$TOR_UID" -G "$INET_GID" -s -d "$STATE/tor" \
		-e "HOME=$STATE/tor" -- "$BIN/tor" -f "$TORRC" \
		</dev/null >>"$LOGDIR/tor.stderr" 2>&1 &
	echo $! >"$PRIV/tor.pid"
	log "tor: started (pid $!)"
}

# --- tor's control socket --------------------------------------------------------

# torctl: send the control commands on standard input (one per line) to
# tor, after AUTHENTICATE and before QUIT, and print tor's replies. It runs
# lib/torctl.sh as uid 2950, which reads the cookie and connects to the
# socket; root never touches either (see "Trust" above).
torctl() {
	as_user "$TOR_UID" -- /system/bin/sh "$MODDIR/lib/torctl.sh" \
		"$RUN/tor-control.authcookie" "$RUN/tor-control.sock" 2>>"$LOGDIR/module.log"
}

# torctl_ok REPLIES COUNT: true if REPLIES holds COUNT+1 final reply lines
# (AUTHENTICATE plus COUNT commands) and every one is "250". The final
# QUIT reply may be missing if tor closed first; it is not counted.
torctl_ok() {
	_to_codes=$(printf '%s\n' "$1" | tr -d '\r' | sed -n 's/^\([0-9][0-9][0-9]\) .*/\1/p' | head -n "$(($2 + 1))")
	_to_n=0
	for _to_c in $_to_codes; do
		[ "$_to_c" = 250 ] || return 1
		_to_n=$((_to_n + 1))
	done
	[ "$_to_n" -eq $(($2 + 1)) ]
}

# tor_ready: true if tor runs and answers on its control socket now. It
# does not wait: service.sh asks again at its next turn (2 seconds later),
# so that the firewall and port checks never wait behind tor. One call is
# bounded by torctl.sh (at most 5 s after the commands are sent, 10 s in
# all).
tor_ready() {
	pid_alive "$PRIV/tor.pid" "$TOR_UID" || return 1
	_tr_out=$(printf 'GETINFO version\r\n' | torctl)
	torctl_ok "$_tr_out" 1
}

# tor_bootstrap: print "PROGRESS<TAB>SUMMARY" from tor's bootstrap phase.
# The summary is reduced to letters, digits, spaces and a little
# punctuation, so it can go into JSON as it is.
tor_bootstrap() {
	_tb_out=$(printf 'GETINFO status/bootstrap-phase\r\n' | torctl)
	torctl_ok "$_tb_out" 1 || return 1
	_tb_line=$(printf '%s\n' "$_tb_out" | tr -d '\r' | sed -n 's/^250-status\/bootstrap-phase=//p' | head -n 1)
	_tb_p=$(printf '%s\n' "$_tb_line" | sed -n 's/.* PROGRESS=\([0-9]*\).*/\1/p')
	_tb_s=$(printf '%s\n' "$_tb_line" | sed -n 's/.* SUMMARY="\([^"]*\)".*/\1/p' | tr -cd 'A-Za-z0-9 .,:;()/-' | cut -c1-120)
	case $_tb_p in '' | *[!0-9]*) return 1 ;; esac
	printf '%s\t%s\n' "$_tb_p" "$_tb_s"
}

# --- Bridge lines ---------------------------------------------------------------

# bridges_check FILE: check the bridge lines in FILE (one per line, as
# Welcome stores them) before any of them reaches tor's control protocol.
# The rules repeat Welcome's (Bridges.kt): at most 20 lines of at most 600
# printable ASCII characters without '"' or '\'; the first word is a
# transport from PT_TRANSPORTS or an IPv4 address with a port; obfs4 lines
# have an IPv4 address with a port; a fingerprint is 40 hex digits. A word
# ending in ',' is refused: it would mean that the provider sent more
# columns than were asked for. Prints "plain" or "pt"; returns 1 and prints
# the reason on any problem.
bridges_check() {
	_bc_n=0
	_bc_kind=plain
	while IFS= read -r _bc_line || [ -n "$_bc_line" ]; do
		[ -n "$_bc_line" ] || continue
		_bc_n=$((_bc_n + 1))
		[ "$_bc_n" -le 20 ] || {
			echo "more than 20 bridges"
			return 1
		}
		[ "${#_bc_line}" -le 600 ] || {
			echo "bridge $_bc_n is too long"
			return 1
		}
		case $_bc_line in
		*[!\ -~]* | *\"* | *\\* | ' '* | *' ' | *'  '*)
			echo "bridge $_bc_n has characters that are not allowed"
			return 1
			;;
		esac
		set -f
		# shellcheck disable=SC2086 # split the line into words on purpose
		set -- $_bc_line
		set +f
		for _bc_w in "$@"; do
			case $_bc_w in *,)
				echo "bridge $_bc_n is not a single bridge line"
				return 1
				;;
			esac
		done
		# What this line's type needs: an IPv4 address that tor connects
		# to (plain bridges and obfs4), and the argument without which the
		# transport cannot work. webtunnel and meek_lite connect to the
		# server in url=; their address is a placeholder.
		_bc_addr=
		_bc_arg=
		case $1 in
		[0-9]*)
			_bc_addr=$1
			shift
			;;
		obfs4)
			_bc_kind=pt
			_bc_addr=${2-none}
			_bc_arg=cert=
			shift
			[ $# -gt 0 ] && shift
			;;
		webtunnel | meek_lite)
			_bc_kind=pt
			_bc_arg=url=
			shift
			[ $# -gt 0 ] && shift
			;;
		*)
			echo "bridge $_bc_n has an unknown type"
			return 1
			;;
		esac
		if [ -n "$_bc_addr" ]; then
			ipv4_port "$_bc_addr" || {
				echo "bridge $_bc_n needs an IPv4 address with a port"
				return 1
			}
		fi
		if [ -n "$_bc_arg" ]; then
			_bc_found=0
			for _bc_w in "$@"; do
				case $_bc_w in "$_bc_arg"?*) _bc_found=1 ;; esac
			done
			[ "$_bc_found" = 1 ] || {
				echo "bridge $_bc_n lacks ${_bc_arg%=}="
				return 1
			}
		fi
		case ${1-} in
		*=* | '') ;;
		*)
			case $1 in
			*[!0-9A-Fa-f]*)
				echo "bridge $_bc_n has a bad fingerprint"
				return 1
				;;
			esac
			[ "${#1}" -eq 40 ] || {
				echo "bridge $_bc_n has a bad fingerprint"
				return 1
			}
			;;
		esac
	done <"$1"
	[ "$_bc_n" -gt 0 ] || {
		echo "no bridges"
		return 1
	}
	echo "$_bc_kind"
}

# ipv4_port TEXT: true for "a.b.c.d:port" with every part in range.
ipv4_port() {
	_ip_host=${1%:*}
	_ip_port=${1##*:}
	[ "$_ip_host" != "$1" ] || return 1
	case $_ip_port in '' | *[!0-9]* | ??????*) return 1 ;; esac
	[ "$_ip_port" -ge 1 ] && [ "$_ip_port" -le 65535 ] || return 1
	_ip_old=$IFS
	IFS=.
	set -f
	# shellcheck disable=SC2086 # split on dots on purpose
	set -- $_ip_host
	set +f
	IFS=$_ip_old
	[ $# -eq 4 ] || return 1
	for _ip_o in "$@"; do
		case $_ip_o in '' | *[!0-9]* | ????*) return 1 ;; esac
		[ "$_ip_o" -le 255 ] || return 1
	done
}

# --- Welcome's provider ------------------------------------------------------------

# welcome_query PROJECTION: print Welcome's row with the columns named in
# PROJECTION (separated by ':'). 'content' starts a Java process, so this
# takes about a second.
welcome_query() {
	/system/bin/content query --user 0 --uri "$PROVIDER_URI" --projection "$1" 2>/dev/null
}

# welcome_is_owner: true if Welcome (org.antumbra.welcome) is the device
# owner. Any app could declare the provider's authority while Welcome is
# not installed (before it is installed, or if it were ever removed) and
# answer started=1 with bridges of its choosing. A device owner cannot be
# uninstalled, and an authority belongs to one package only, so while
# Welcome is the device owner the authority is Welcome's. The device owner
# is set by the person over adb at installation (docs/install.md); no app
# can make itself one afterwards.
welcome_is_owner() {
	/system/bin/cmd device_policy list-owners 2>/dev/null |
		grep -q '^User  *0: admin=org\.antumbra\.welcome/[^,]*,DeviceOwner'
}

# row_get ROW COLUMN: the value of COLUMN in a 'content query' row. Only
# for columns whose values never contain ", " (all but bridges).
row_get() {
	printf '%s\n' "$1" | sed -n "1{/^Row: 0 /!d;s/^Row: 0 /, /;s/.*, $2=\\([^,]*\\).*/\\1/p;}"
}

# --- Settings ------------------------------------------------------------------------

# The Settings.Global values are listed, with the reason for each, in
# lib/settings.conf.
SETTINGS_CONF=$MODDIR/lib/settings.conf

settings_put() { /system/bin/settings put global "$1" "$2" >/dev/null 2>&1; }

# settings_apply: set every value in settings.conf; "lineage:" lines only on
# LineageOS, "phone:" lines everywhere but the emulator, "cell:" lines
# never (the cell radio's code sets them when the time is right). Prints the
# keys that could not be set.
settings_apply() {
	_sa_lineage=0
	is_lineage && _sa_lineage=1
	_sa_phone=1
	is_emulator && _sa_phone=0
	while IFS= read -r _sa_line || [ -n "$_sa_line" ]; do
		case $_sa_line in '' | '#'* | cell:*) continue ;; esac
		case $_sa_line in
		lineage:*)
			[ "$_sa_lineage" = 1 ] || continue
			_sa_line=${_sa_line#lineage:}
			;;
		phone:*)
			[ "$_sa_phone" = 1 ] || continue
			_sa_line=${_sa_line#phone:}
			;;
		esac
		settings_put "${_sa_line%%=*}" "${_sa_line#*=}" || printf ' %s' "${_sa_line%%=*}"
	done <"$SETTINGS_CONF"
}

# setting_get KEY: print a Settings.Global value (empty when unset).
# Returns 1 if the settings provider does not answer.
setting_get() {
	_sg=$(/system/bin/settings get global "$1" 2>/dev/null) || return 1
	[ "$_sg" = null ] && _sg=
	printf '%s\n' "$_sg"
}

# mobile_data_off: mobile data off for every SIM Android knows, now and at
# the next start. Android stores the choice per subscription
# (Settings.Global mobile_data<subId> in dual-SIM mode; the hotdog has two
# slots; mobile_data with one; GlobalSettingsHelper in Android 16)
# and reads it when the SIM comes up, so it holds on a start without the
# module too. A SIM Android has never seen has no value yet and starts
# with mobile data on (ro.com.android.mobiledata, default true): that gap
# is in README, "Known gaps"; the cell radio's watch runs this again as
# soon as a SIM's state changes, and before the module switches the radio
# on. 'cmd phone data disable' switches it off now on the default data
# SIM. On the emulator too: CI switches its simulated mobile data off
# itself, and a start without the module must find it stored off there as
# well.
mobile_data_off() {
	_md_ids=$({
		/system/bin/settings list global 2>/dev/null | sed -n 's/^mobile_data\([0-9][0-9]*\)=.*/\1/p'
		/system/bin/content query --uri content://telephony/siminfo --projection _id 2>/dev/null |
			sed -n 's/^Row: [0-9]* _id=\([0-9][0-9]*\)$/\1/p'
	} | sort -u)
	for _md_id in $_md_ids; do
		settings_put "mobile_data$_md_id" 0
	done
	/system/bin/cmd phone data disable >/dev/null 2>&1
	return 0
}

# wifi_off, bluetooth_off: switch them off now (root may do so in any
# state, airplane mode included).
wifi_off() { /system/bin/cmd wifi set-wifi-enabled disabled >/dev/null 2>&1; }
bluetooth_off() { /system/bin/cmd bluetooth_manager disable >/dev/null 2>&1; }

# radios_off_now: the part of the fail-safe that never waits: Wi-Fi off and
# mobile data off. Used only when the firewall cannot be put in place and
# the network may be open. The cell radio and Bluetooth follow in
# cell_step, once no call holds them.
radios_off_now() {
	wifi_off
	mobile_data_off
}

# framework_ready: true once boot has completed and the settings provider
# answers.
framework_ready() {
	[ "$(getprop sys.boot_completed 2>/dev/null)" = 1 ] &&
		/system/bin/settings get global airplane_mode_on >/dev/null 2>&1
}

# --- The cell radio ------------------------------------------------------------------
#
# The cell radio stays off unless the session chose Phone mode (WEL8; until
# then every session keeps it off). It is off from power-on because of
# three stored values: enable_cellular_on_boot=0 (settings.conf), airplane
# mode off and cell_on=1. The phone process reads enable_cellular_on_boot
# once, when it starts, and keeps the radio off ("off by the user"); this
# holds on a start without the module too. Airplane mode is never left on
# across a restart: Wi-Fi copies airplane mode once, when it starts, and
# while that copy says "on", a device owner (Welcome) cannot switch Wi-Fi
# on or off for the whole boot.
#
# At run time the module switches the cell radio off with Android's own
# airplane mode ('cmd connectivity airplane-mode enable'), after narrowing
# airplane_mode_radios to "cell", so that Wi-Fi and Bluetooth stay as they
# are. That is the one way used, because Android's emergency-call path
# undoes it by itself: it switches airplane mode off and the radio on, and
# clears every reason the radio was off for (RadioOnHelper and
# ServiceStateTracker in Android 16). Never used: switching a modem or a
# SIM slot off, SIM power, the multi-SIM setting, stopping the RIL or the
# phone process, modem restarts, 'service call' transaction numbers, or
# anything else the emergency dialer cannot undo.
#
# Holds. No airplane step and no radio-off step (airplane mode on or off,
# the fail-safe's cell radio and Bluetooth, the shutdown reset) while:
#   - Telecom lists a call in any state, or a phone in the telephony
#     registry is not idle (ringing, dialing, active, on hold, ...);
#   - emergency callback mode, for calls or for texts, is on;
#   - less than 5 minutes have passed since the last look that saw either,
#     since Telecom's call counter moved (a call that began and ended
#     between two looks), or since the radio came on or airplane mode went
#     off without the module doing it (an emergency text starts no call);
#   - any of this cannot be read: a hold as if in a call, and 5 more minutes
#     once it can be read again.
# Wi-Fi off and mobile data off never wait. While a hold lasts and the
# radio is not off, enable_cellular_on_boot is kept at 1, not 0: the phone
# process reads it whenever it starts, and if it restarted during a call,
# callback mode or the 5 minutes after (a crash, or a restart of
# system_server), 0 would leave the radio off and no callback could reach
# the phone. It is written 0 again once the hold ends, just before the
# switch-off, and at every boot and shutdown (settings.conf).
#
# What a root shell can read: 'dumpsys telecom' (CallsManager's mCalls, one
# line per call; Analytics, one "Call TC@<n>" line per recent call, n
# counting up within a boot), 'dumpsys telephony.registry' (per phone the
# call states and the callback-mode durations, and the radio power) and the
# property ril.cdma.inecmmode (emergency callback mode, set on both of
# Android 16's paths). The registry also prints the incoming number: the
# dumps go through pipes only, never to a file or the log.

# Seconds the radio stays as it is after a call (Android's callback mode
# lasts 300000 ms; Welcome's CallWatch waits as long).
CELL_AFTER=300
# Seconds airplane mode must read off before the list is narrowed: Wi-Fi
# updates its copy of airplane mode only while the list names Wi-Fi, so it
# must have handled the last airplane-off broadcast first.
CELL_STEADY=30
# Seconds between looks: while the radio is on (or not known to be off), a
# hold lasts or the fail-safe waits; otherwise; and after a look that could
# not read the state.
CELL_LOOK_BUSY=10
CELL_LOOK_IDLE=60
CELL_LOOK_FAILED=30
# The narrowed list (settings.conf's "cell:" line records the old one).
CELL_RADIOS=cell

# What the cell radio's watch keeps (service.sh's loop; cell_step).
CELL_AIR=          # airplane_mode_on as last read: 1, 0, or empty (unread)
CELL_AIR_OFF_AT=0  # uptime since which airplane mode reads off
CELL_NARROW=0      # 1 once airplane_mode_radios reads "cell"
CELL_ECM=          # ril.cdma.inecmmode as last read
CELL_SIM=          # gsm.sim.state as last read
CELL_BOOT=unread   # enable_cellular_on_boot as last read or written (empty: unset)
CELL_LOOKED=       # uptime of the last look (empty: none yet)
CELL_LOOK_NEXT=0   # uptime of the next look
CELL_LAST=         # uptime of the last call-like event (empty: none)
CELL_BUSY=0        # 1 if the last look saw a call, callback mode or nothing readable
CELL_ID=           # Telecom's highest call number at the last look
CELL_RADIO=        # radio power at the last look: on, off, wait, unknown
CELL_MINE_AT=      # uptime of the module's own switch-on (Phone mode)
CELL_ON_DONE=0     # 1 once Phone mode's switch-on is done
CELL_TRY_AT=       # uptime of the last step taken (one try per 10 s)
CELL_HELD=         # the hold last logged
# The last look: CL_CALL and CL_CBM are 0, 1 or unknown; CL_ID is a number
# or empty; CL_RADIO is on, off, wait or unknown.
CL_CALL=unknown
CL_CBM=unknown
CL_ID=
CL_RADIO=unknown
# The session's choice ("off" or "phone"; service.sh's session_cell) and
# the fail-safe's state (service.sh's RADIOS) are read from service.sh.
SES_CELL=${SES_CELL:-off}
RADIOS=${RADIOS:-}
# The cell radio's current problem, for status.json (service.sh).
# shellcheck disable=SC2034 # read by service.sh
P_CELL=
CELL_READ=         # 1 or 0: whether the last look could read the call state
CELL_CLOCKLESS=0   # 1 while the time since boot cannot be read

# telecom_state: read 'dumpsys telecom' on standard input and print
# "CALLS LASTID": the calls Telecom lists now, in any state (VoIP calls
# too), and the highest call number seen (0 if none). Returns 1 when the
# dump lacks CallsManager, its mCalls list or Analytics (Telecom not
# ready, a timeout, a format this does not know).
telecom_state() {
	# The call lines first: the substitutions below change the line that
	# starts their range.
	sed -n -e '/^  mCalls: *$/,/^ \{0,2\}[^ ]/{/^    \[Call id=/p;}' \
		-e 's/^\(CallsManager:\) *$/\1/p' -e 's/^\(Analytics:\) *$/\1/p' \
		-e 's/^  \(mCalls:\) *$/\1/p' \
		-e 's/^ *\(Call TC@[0-9][0-9]*\): .*/\1/p' |
		{
			_ts_have=
			_ts_n=0
			_ts_last=0
			while IFS= read -r _ts_line; do
				_ts_id=
				case $_ts_line in
				CallsManager: | mCalls: | Analytics:) _ts_have="$_ts_have${_ts_line%:}," ;;
				'    [Call id='*)
					_ts_n=$((_ts_n + 1))
					case $_ts_line in *'[Call id=TC@'[0-9]*)
						_ts_id=${_ts_line#*id=TC@}
						_ts_id=${_ts_id%%[!0-9]*}
						;;
					esac
					;;
				'Call TC@'*) _ts_id=${_ts_line#Call TC@} ;;
				esac
				[ -n "$_ts_id" ] || continue
				# Shell arithmetic may be 32 bits (mksh).
				[ "${#_ts_id}" -le 9 ] || exit 1
				[ "$_ts_id" -le "$_ts_last" ] || _ts_last=$_ts_id
			done
			case $_ts_have in *CallsManager,*) ;; *) exit 1 ;; esac
			case $_ts_have in *mCalls,*) ;; *) exit 1 ;; esac
			case $_ts_have in *Analytics,*) ;; *) exit 1 ;; esac
			echo "$_ts_n $_ts_last"
		}
}

# registry_state: read 'dumpsys telephony.registry' on standard input and
# print "BUSY CBM RADIO": BUSY 1 if any phone is not idle (mCallState not
# 0, or a precise state other than idle (0), disconnected (7) or not valid
# (-1): ringing, dialing, alerting, active, on hold, incoming, waiting,
# disconnecting); CBM 1 if emergency callback mode for calls or texts lasts
# (a duration other than 0); RADIO on, off or wait (unavailable). Returns 1
# unless there is at least one phone and every phone has the six numbers,
# and mRadioPowerState is 0, 1 or 2. Only the "last known state" part is
# read; mCallIncomingNumber is read past and never printed.
registry_state() {
	_rs_in=0
	_rs_phones=0
	_rs_n=0
	_rs_busy=0
	_rs_cbm=0
	_rs_radio=
	while IFS= read -r _rs_l; do
		case $_rs_l in
		'last known state:')
			_rs_in=1
			continue
			;;
		'local logs:') break ;;
		esac
		[ "$_rs_in" = 1 ] || continue
		_rs_l=${_rs_l#"${_rs_l%%[! ]*}"}
		case $_rs_l in
		'Phone Id='*)
			[ "$_rs_phones" = 0 ] || [ "$_rs_n" = 6 ] || return 1
			_rs_phones=$((_rs_phones + 1))
			_rs_n=0
			;;
		mCallState=* | mRingingCallState=* | mForegroundCallState=* | mBackgroundCallState=* | \
			mECBMDuration=* | mSCBMDuration=*)
			[ "$_rs_phones" -gt 0 ] || return 1
			_rs_k=${_rs_l%%=*}
			_rs_v=${_rs_l#*=}
			case ${_rs_v#-} in '' | *[!0-9]*) return 1 ;; esac
			case $_rs_k in
			mCallState) [ "$_rs_v" = 0 ] || _rs_busy=1 ;;
			*CallState) case $_rs_v in 0 | 7 | -1) ;; *) _rs_busy=1 ;; esac ;;
			*) [ "$_rs_v" = 0 ] || _rs_cbm=1 ;;
			esac
			_rs_n=$((_rs_n + 1))
			;;
		mRadioPowerState=*)
			case ${_rs_l#*=} in
			0) _rs_radio=off ;;
			1) _rs_radio=on ;;
			2) _rs_radio='wait' ;;
			*) return 1 ;;
			esac
			;;
		esac
	done
	[ "$_rs_phones" -gt 0 ] && [ "$_rs_n" = 6 ] && [ -n "$_rs_radio" ] || return 1
	echo "$_rs_busy $_rs_cbm $_rs_radio"
}

# ecbm_value VALUE: 1 if ril.cdma.inecmmode says emergency callback mode
# ("true"), 0 for false, 0 or unset; anything else counts as on.
ecbm_value() {
	case $1 in '' | false | 0) echo 0 ;; *) echo 1 ;; esac
}

# cell_dump SERVICE: Android's dumpsys of SERVICE, bounded: dumpsys gives
# the service 3 seconds, and the whole call ends after 4 (a look, two
# dumps, takes at most 8). A dump cut short reads as unknown: a hold.
cell_dump() { $TB timeout 4 /system/bin/dumpsys -t 3 "$1" 2>/dev/null; }

# airplane_get: print airplane mode, 1 or 0; returns 1 if it cannot be read.
airplane_get() {
	_ag=$(setting_get airplane_mode_on) || return 1
	case $_ag in
	1) echo 1 ;;
	0 | '') echo 0 ;;
	*) return 1 ;;
	esac
}

# airplane_set enable|disable: Android's own airplane-mode switch (setting
# and broadcast, as Quick Settings does it).
airplane_set() { /system/bin/cmd connectivity airplane-mode "$1" >/dev/null 2>&1; }

# cell_look: one look at the call state and the radio (sets CL_*).
cell_look() {
	CL_CALL=unknown
	CL_CBM=unknown
	CL_ID=
	CL_RADIO=unknown
	_cl_t=$(cell_dump telecom | telecom_state) || _cl_t=
	_cl_r=$(cell_dump telephony.registry | registry_state) || _cl_r=
	if _cl_e=$(getprop ril.cdma.inecmmode 2>/dev/null); then
		_cl_e=$(ecbm_value "$_cl_e")
	else
		_cl_e=unknown
	fi
	if [ -n "$_cl_r" ]; then
		set -f
		# shellcheck disable=SC2086 # three words on purpose
		set -- $_cl_r
		set +f
		CL_CBM=$2
		case $_cl_e in 0) ;; 1) CL_CBM=1 ;; *) CL_CBM=unknown ;; esac
		CL_RADIO=$3
		if [ -n "$_cl_t" ]; then
			CL_ID=${_cl_t#* }
			CL_CALL=$1
			[ "${_cl_t%% *}" = 0 ] || CL_CALL=1
		fi
	fi
}

# cell_mine NOW: true if the module itself switched the radio on in the
# last 60 seconds (Phone mode).
cell_mine() {
	[ -n "$CELL_MINE_AT" ] && [ "$1" -ge "$CELL_MINE_AT" ] && [ $(($1 - CELL_MINE_AT)) -le 60 ]
}

# cell_note NOW: take the last look into the watch: CELL_LAST becomes NOW
# when the look sees a call, callback mode or nothing readable, when the
# one before did (so the 5 minutes count from when the end was seen, not
# from the last look that still saw the call), when Telecom's call counter
# moved (up, or down after Telecom restarted; on the first look, when any
# call has happened in this boot), and when the radio came on without the
# module doing it.
cell_note() {
	_cn_busy=0
	[ "$CL_CALL" = 0 ] || _cn_busy=1
	[ "$CL_CBM" = 0 ] || _cn_busy=1
	_cn_event=$_cn_busy
	[ "$CELL_BUSY" = 0 ] || _cn_event=1
	if [ -n "$CL_ID" ]; then
		if [ -z "$CELL_ID" ]; then
			[ "$CL_ID" = 0 ] || _cn_event=1
		elif [ "$CL_ID" != "$CELL_ID" ]; then
			_cn_event=1
		fi
		CELL_ID=$CL_ID
	fi
	if [ "$CL_RADIO" = on ] && [ "$CELL_RADIO" != on ] && ! cell_mine "$1"; then
		_cn_event=1
	fi
	CELL_BUSY=$_cn_busy
	CELL_RADIO=$CL_RADIO
	[ "$_cn_event" = 0 ] || CELL_LAST=$1
}

# cell_hold NOW: print why a radio-off or airplane step must wait, and
# return 0; return 1 when nothing holds it. In this order: unknown (the
# state cannot be read, or the time since boot cannot: NOW 0), call,
# callback, recent (less than CELL_AFTER seconds since CELL_LAST).
cell_hold() {
	case $CL_CALL:$CL_CBM in [01]:[01]) ;; *)
		echo unknown
		return 0
		;;
	esac
	if [ "$1" -le 0 ]; then
		echo unknown
		return 0
	fi
	if [ "$CL_CALL" = 1 ]; then
		echo call
		return 0
	fi
	if [ "$CL_CBM" = 1 ]; then
		echo callback
		return 0
	fi
	if [ -n "$CELL_LAST" ] && { [ "$1" -lt "$CELL_LAST" ] || [ $(($1 - CELL_LAST)) -lt "$CELL_AFTER" ]; }; then
		echo recent
		return 0
	fi
	return 1
}

# cell_hold_text REASON: the hold in words, for the module's log (never in
# status.json, which every app can read: a call is nobody's business).
cell_hold_text() {
	case $1 in
	unknown) echo "the call state cannot be read" ;;
	call) echo "a call is ringing, being set up, active or on hold" ;;
	callback) echo "emergency callback mode" ;;
	recent) echo "less than 5 minutes after a call, callback mode or a switch-on by something else" ;;
	esac
}

# cell_boot_value NOW: the enable_cellular_on_boot the watch keeps: 1 while
# cell_hold holds and the last look did not read the radio off (a restart
# of the phone process then keeps the radio on), 0 otherwise.
cell_boot_value() {
	if [ "$CL_RADIO" != off ] && cell_hold "$1" >/dev/null; then echo 1; else echo 0; fi
}

# cell_want: what the cell radio should be: "failsafe" while the fail-safe
# waits to switch it off; "on" in a Phone-mode session (after Start only,
# decision D12), "leave" there once the fail-safe has switched the radios
# off (the person decides from then on); "off" otherwise.
cell_want() {
	case $RADIOS in wanted | waiting)
		echo failsafe
		return 0
		;;
	esac
	if [ "${S_STARTED:-0}" = 1 ] && [ "$SES_CELL" = phone ]; then
		if [ -z "$RADIOS" ]; then echo on; else echo leave; fi
		return 0
	fi
	echo off
}

# cell_decide NOW: print the cell radio's next step: none; look (a step
# that nothing holds by the last look needs a look taken in this turn,
# whose NOW is the look's time, before it is taken); narrow (the
# list to the cell radio, once airplane mode has read off for CELL_STEADY
# seconds; before that, "wait narrow" for steps that need it); keys (Phone
# mode, the radio already on); off, power (Phone mode's switch-on) or
# failsafe, or "held REASON" while cell_hold holds them.
cell_decide() {
	_cd_now=$1
	case $CELL_AIR in 0 | 1) ;; *)
		echo none
		return 0
		;;
	esac
	if [ -z "$CELL_LOOKED" ]; then
		echo look
		return 0
	fi
	_cd_step=none
	case $(cell_want) in
	failsafe) _cd_step=failsafe ;;
	off)
		if [ "$CELL_AIR" = 0 ]; then
			case $CL_RADIO in off | wait) ;; *) _cd_step=off ;; esac
		fi
		;;
	on)
		if [ "$CELL_ON_DONE" = 0 ]; then
			if [ "$CL_RADIO" = on ]; then _cd_step=keys; else _cd_step=power; fi
		elif [ "$CELL_AIR" = 0 ] && [ "$CL_RADIO" = off ]; then
			# The phone process restarted and read enable_cellular_on_boot=0.
			_cd_step=power
		fi
		;;
	esac
	if [ "$CELL_NARROW" != 1 ] && [ "$CELL_AIR" = 0 ]; then
		if [ "$_cd_now" -ge "$CELL_AIR_OFF_AT" ] && [ $((_cd_now - CELL_AIR_OFF_AT)) -ge "$CELL_STEADY" ]; then
			echo narrow
			return 0
		fi
		case $_cd_step in off | power)
			echo "wait narrow"
			return 0
			;;
		esac
	fi
	case $_cd_step in none | keys)
		echo "$_cd_step"
		return 0
		;;
	esac
	# Held by the last look: only a later look (at its time) or the clock
	# can end it. Free by the last look: one try per 10 seconds, and a
	# look taken in this turn decides. A look from an earlier turn is never
	# used: NOW is read once, at the start of a turn, so even one that reads
	# a second or two old can be several seconds old, and a call could have
	# begun to ring since.
	if _cd_why=$(cell_hold "$_cd_now"); then
		echo "held $_cd_why"
		return 0
	fi
	if [ -n "$CELL_TRY_AT" ] && [ "$_cd_now" -ge "$CELL_TRY_AT" ] && [ $((_cd_now - CELL_TRY_AT)) -lt 10 ]; then
		echo none
		return 0
	fi
	if [ "$CELL_LOOKED" != "$_cd_now" ]; then
		echo look
		return 0
	fi
	echo "$_cd_step"
}

# cell_keys: mobile data off again after a switch-on, for every SIM Android
# knows (a SIM it had not seen gets its key), and mobile_data_always_on 0.
# No radio is switched: allowed during a hold. (enable_cellular_on_boot is
# cell_step's, which keeps it by cell_boot_value.)
cell_keys() {
	settings_put mobile_data_always_on 0
	mobile_data_off
}

# cell_narrow: airplane mode switches the cell radio only.
cell_narrow() { settings_put airplane_mode_radios "$CELL_RADIOS"; }

# cell_off: the cell radio off, through airplane mode. Callers check the
# hold first, and that the list is narrowed (or, for the fail-safe, that
# Wi-Fi going off too is wanted).
cell_off() { airplane_set enable; }

# cell_power: Phone mode's switch-on (after Start only). Mobile data off
# first, for every SIM Android knows; then Android's airplane-mode path:
# with airplane mode on, 'disable' (the phone process switches the radio
# on); with it off, 'enable' then 'disable' (the radio has been off since
# power-on, which the phone process only undoes on an airplane-mode
# change). enable_cellular_on_boot, which that path sets to 1, is put back
# to 0 by cell_step at its next turn (unless a hold has begun meanwhile).
cell_power() {
	settings_put mobile_data_always_on 0
	mobile_data_off
	if [ "$CELL_AIR" = 0 ]; then
		airplane_set enable || return 1
	fi
	airplane_set disable
}

# cell_reset: at shutdown only: airplane mode stored off, so that Wi-Fi
# starts with its copy off at the next start, and cell_on stored as "on"
# (1), so that the phone process, which reads it with airplane mode at its
# start, does not switch the radio on (it would with 2, "off for airplane
# mode"). No broadcast: nothing switches now; with
# enable_cellular_on_boot=0 the next start has the radio off.
cell_reset() {
	settings_put cell_on 1
	settings_put airplane_mode_on 0
}

# cell_update NOW: a look, taken into the watch.
cell_update() {
	_cu_was=$CELL_RADIO
	cell_look
	cell_note "$1"
	CELL_LOOKED=$1
	if _cu_v=$(setting_get airplane_mode_radios); then
		if [ "$_cu_v" = "$CELL_RADIOS" ]; then CELL_NARROW=1; else CELL_NARROW=0; fi
	fi
	_cu_v=1
	[ "$CL_CALL" != unknown ] || _cu_v=0
	if [ "$_cu_v" != "$CELL_READ" ]; then
		if [ "$_cu_v" = 0 ]; then
			log "cell: the call state cannot be read; nothing switches the radio off until it can, and for 5 minutes after"
		elif [ -n "$CELL_READ" ]; then
			log "cell: the call state can be read again"
		fi
		CELL_READ=$_cu_v
	fi
	if [ "$CL_RADIO" != "$_cu_was" ]; then
		case $CL_RADIO in
		on)
			log "cell: the cell radio is on; mobile data off again"
			cell_keys
			;;
		off) log "cell: the cell radio is off" ;;
		esac
	fi
	if [ "$CL_CALL" = unknown ]; then
		CELL_LOOK_NEXT=$(($1 + CELL_LOOK_FAILED))
	elif [ "$CL_RADIO" = off ] && [ "$RADIOS" != waiting ] && ! cell_hold "$1" >/dev/null; then
		CELL_LOOK_NEXT=$(($1 + CELL_LOOK_IDLE))
	else
		CELL_LOOK_NEXT=$(($1 + CELL_LOOK_BUSY))
	fi
}

# cell_step NOW: one turn of the cell radio's watch (service.sh, at every
# turn once the framework has answered).
cell_step() {
	_cs_now=$1
	# The module's files are gone (Magisk itself uninstalled while this
	# loop still runs): the stored values are uninstall.sh's from now on.
	[ -f "$SETTINGS_CONF" ] || return 0
	# Without the time since boot every step is held (cell_hold); once it
	# can be read again, the 5 minutes start from then.
	if [ "$_cs_now" -le 0 ]; then
		CELL_CLOCKLESS=1
	elif [ "$CELL_CLOCKLESS" = 1 ]; then
		CELL_CLOCKLESS=0
		CELL_LAST=$_cs_now
	fi
	# Cheap reads at every turn; a change brings the next look forward.
	_cs_v=$(airplane_get) || _cs_v=
	if [ "$_cs_v" != "$CELL_AIR" ]; then
		if [ "$CELL_AIR" = 1 ] && [ "$_cs_v" = 0 ] && ! cell_mine "$_cs_now"; then
			CELL_LAST=$_cs_now
			log "cell: airplane mode switched off by something else; the radio stays on for at least 5 minutes"
		fi
		[ "$_cs_v" = 0 ] && CELL_AIR_OFF_AT=$_cs_now
		CELL_AIR=$_cs_v
		CELL_LOOK_NEXT=0
	fi
	# enable_cellular_on_boot set to something else than the watch left
	# (Android's airplane-mode path writes 1 whenever it switches the radio
	# on): mobile data off again, and a look. What the watch keeps there is
	# decided below, once the look is in.
	if _cs_boot=$(setting_get enable_cellular_on_boot); then
		if [ "$CELL_BOOT" != unread ] && [ "$_cs_boot" != "$CELL_BOOT" ] && [ "$_cs_boot" != 0 ]; then
			cell_keys
			CELL_LOOK_NEXT=0
			log "cell: enable_cellular_on_boot changed to ${_cs_boot:-unset} by something else (a switch-on); mobile data off again"
		fi
		CELL_BOOT=$_cs_boot
	else
		_cs_boot=unread
	fi
	_cs_v=$(getprop ril.cdma.inecmmode 2>/dev/null)
	if [ "$_cs_v" != "$CELL_ECM" ]; then
		CELL_ECM=$_cs_v
		CELL_LOOK_NEXT=0
	fi
	_cs_v=$(getprop gsm.sim.state 2>/dev/null)
	if [ "$_cs_v" != "$CELL_SIM" ]; then
		# A SIM came, went or was unlocked: mobile data off for it before
		# its radio may come on. (The first reading follows apply_settings,
		# which has just done it.)
		if [ -n "$CELL_SIM" ]; then
			log "cell: a SIM's state changed; mobile data off for every SIM"
			mobile_data_off
		fi
		CELL_SIM=$_cs_v
		CELL_LOOK_NEXT=0
	fi
	[ "$_cs_now" -lt "$CELL_LOOK_NEXT" ] || cell_update "$_cs_now"

	# The fail-safe: Wi-Fi and mobile data off at once (as soon as the
	# framework answers); the cell radio and Bluetooth when nothing holds
	# them.
	if [ "$RADIOS" = wanted ] && framework_ready; then
		radios_off_now
		RADIOS=waiting
		S_PROBLEM="${S_PROBLEM:+$S_PROBLEM; }the firewall could not be loaded: Wi-Fi off"
		log "radios: Wi-Fi and mobile data off; the cell radio and Bluetooth follow when no call holds them"
	fi

	_cs_looked=0
	while :; do
		_cs_do=$(cell_decide "$_cs_now")
		[ "$_cs_do" = look ] || break
		[ "$_cs_looked" = 0 ] || break
		cell_update "$_cs_now"
		_cs_looked=1
	done
	case $_cs_do in
	'held '*)
		_cs_v=${_cs_do#held }
		if [ "$_cs_v" != "$CELL_HELD" ]; then
			CELL_HELD=$_cs_v
			log "cell: switching the radio waits, held: $_cs_v ($(cell_hold_text "$_cs_v"))"
		fi
		;;
	*) CELL_HELD= ;;
	esac
	# enable_cellular_on_boot, by the look just taken: 1 while a hold lasts
	# and the radio is not off, so that a restart of the phone process does
	# not switch it off then; 0 otherwise, so before any switch-off below.
	if [ "$_cs_boot" != unread ]; then
		_cs_v=$(cell_boot_value "$_cs_now")
		if [ "$_cs_boot" != "$_cs_v" ] && settings_put enable_cellular_on_boot "$_cs_v"; then
			CELL_BOOT=$_cs_v
			if [ "$_cs_v" = 1 ]; then
				log "cell: enable_cellular_on_boot 1 while the hold lasts (a restart of the phone process keeps the radio on)"
			else
				log "cell: enable_cellular_on_boot 0 again (the radio off from the next start)"
			fi
		fi
	fi
	# After an airplane step, the watch takes the airplane mode it asked for
	# as the last reading: if airplane mode then reads otherwise, something
	# else changed it (the emergency path right after the step, the person),
	# and that counts as an event even when it happens before the next turn.
	# The radio takes a few seconds to power down: the next look waits.
	case $_cs_do in
	narrow)
		cell_narrow
		CELL_NARROW=1
		log "cell: airplane mode's radio list narrowed to the cell radio"
		;;
	keys)
		cell_keys
		CELL_ON_DONE=1
		log "cell: Phone mode: the radio is already on; mobile data off"
		;;
	off)
		CELL_TRY_AT=$_cs_now
		cell_off
		CELL_AIR=1
		CELL_LOOK_NEXT=$((_cs_now + CELL_LOOK_BUSY))
		log "cell: the cell radio off (airplane mode, for the cell radio only)"
		;;
	power)
		CELL_TRY_AT=$_cs_now
		CELL_MINE_AT=$_cs_now
		cell_power
		[ "$CELL_AIR" = 0 ] || CELL_AIR_OFF_AT=$_cs_now
		CELL_AIR=0
		CELL_RADIO=on
		CELL_ON_DONE=1
		CELL_LOOK_NEXT=0
		log "cell: Phone mode: the cell radio on, mobile data off"
		;;
	failsafe)
		CELL_TRY_AT=$_cs_now
		if [ "$CELL_AIR" != 1 ]; then
			cell_off
			CELL_AIR=1
			CELL_LOOK_NEXT=$((_cs_now + CELL_LOOK_BUSY))
		fi
		bluetooth_off
		RADIOS=switched
		S_PROBLEM="${S_PROBLEM:+$S_PROBLEM; }the firewall could not be loaded: cellular radio and Bluetooth off"
		log "radios: the cell radio (airplane mode) and Bluetooth off"
		;;
	esac
	# shellcheck disable=SC2034 # read by service.sh
	if [ "$RADIOS" = waiting ]; then
		P_CELL="cellular radio and Bluetooth off shortly"
	else
		P_CELL=
	fi
}

# cell_shutdown NOW: once Android has begun to shut down, store airplane
# mode off and cell_on=1 for the next start (cell_reset), unless a call,
# callback mode or a recent call holds it, or the state cannot be read
# (then the next start keeps airplane mode on, and Wi-Fi's copy with it).
cell_shutdown() {
	_cx_air=$(airplane_get) || return 0
	_cx_on=$(setting_get cell_on) || return 0
	if [ "$_cx_air" = 0 ] && { [ -z "$_cx_on" ] || [ "$_cx_on" = 1 ]; }; then
		return 0
	fi
	cell_update "$1"
	if _cx_why=$(cell_hold "$1"); then
		log "shutdown: airplane mode left as it is, held: $_cx_why ($(cell_hold_text "$_cx_why"))"
		return 0
	fi
	cell_reset
	log "shutdown: airplane mode stored off and cell_on 1, without a broadcast; the radio stays off at the next start"
}

# --- IPv6 off, per interface ----------------------------------------------------------

# ipv6_sweep: switch IPv6 off and router advertisements off on every
# interface except loopback (Android needs ::1). Android's NetworkStack
# switches IPv6 back on for each network it brings up, so this runs again
# whenever an interface or address changes (ipv6_guard).
ipv6_sweep() {
	for _is_d in /proc/sys/net/ipv6/conf/*; do
		_is_i=${_is_d##*/}
		[ "$_is_i" = lo ] && continue
		[ -w "$_is_d/disable_ipv6" ] || continue
		_is_v=$(read_value "$_is_d/accept_ra")
		[ "$_is_v" = 0 ] || write_value "$_is_d/accept_ra" 0
		_is_v=$(read_value "$_is_d/autoconf")
		[ "$_is_v" = 0 ] || write_value "$_is_d/autoconf" 0
		_is_v=$(read_value "$_is_d/disable_ipv6")
		if [ "$_is_v" != 1 ]; then
			write_value "$_is_d/disable_ipv6" 1
			[ "$_is_i" = all ] || [ "$_is_i" = default ] || log "ipv6: switched off again on $_is_i"
		fi
	done
	# Writing 1 to "all" also switches loopback off; switch it back on.
	[ "$(read_value /proc/sys/net/ipv6/conf/lo/disable_ipv6)" = 0 ] ||
		write_value /proc/sys/net/ipv6/conf/lo/disable_ipv6 0
	return 0
}

# --- Runtime directory ------------------------------------------------------------------

# runtime_ready: true if post-fs-data.sh has set up the runtime tmpfs.
runtime_ready() {
	[ -f "$PRIV/prepared" ] && $TB mountpoint -q "$ANTUMBRA_DIR" 2>/dev/null
}

# make_dir PATH UID GID MODE: create a directory with that owner and mode.
make_dir() {
	mkdir -p "$1" && chown "$2:$3" "$1" && chmod "$4" "$1"
}

# runtime_setup: mount a fresh tmpfs over ANTUMBRA_DIR and lay it out.
# Nothing in it ever reaches flash: tor's state, logs, the session record
# and status all disappear at power-off.
runtime_setup() {
	mkdir -p "$ANTUMBRA_DIR" || return 1
	if ! $TB mountpoint -q "$ANTUMBRA_DIR" 2>/dev/null; then
		mount -t tmpfs -o mode=0711,uid=0,gid=0,nosuid,nodev,noexec,size=128m \
			antumbra "$ANTUMBRA_DIR" || return 1
	fi
	chown 0:0 "$ANTUMBRA_DIR" && chmod 0711 "$ANTUMBRA_DIR" &&
		make_dir "$RUN" "$TOR_UID" "$TOR_UID" 0751 &&
		make_dir "$STATE" 0 0 0711 &&
		make_dir "$STATE/tor" "$TOR_UID" "$TOR_UID" 0700 &&
		make_dir "$PRIV" 0 0 0700 &&
		make_dir "$FWDIR" 0 0 0700 &&
		make_dir "$LISTS" 0 0 0755 &&
		make_dir "$LOGDIR" 0 0 0755 || return 1
	: >"$PRIV/prepared"
}

# --- Status ---------------------------------------------------------------------------------

# json_str VALUE: VALUE as a JSON string, or null when empty. Values are
# checked or reduced to safe characters before they get here; this also
# drops anything else.
json_str() {
	if [ -z "$1" ]; then
		printf 'null'
	else
		printf '"%s"' "$(printf '%s' "$1" | tr -cd 'A-Za-z0-9 ._:;,()/=+-')"
	fi
}
json_bool() { if [ "$1" = 1 ]; then printf 'true'; else printf 'false'; fi; }
json_int() {
	case $1 in '' | *[!0-9]*) printf 'null' ;; *) printf '%s' "$1" ;; esac
}

# status_write: write run/status.json from the S_* variables (service.sh
# keeps them). The filter serves it on 127.0.0.1:5380/status under
# "module", and Welcome shows firewall.state, firewall.hash, tor.bootstrap,
# tor.summary, tor.network and tor.error. It is display only: tor's uid can
# write the file too, so nothing may trust it for a decision (the
# firewall's word is the property antumbra.fw.armed, which only root can
# set). Every app can read the status page, so the file holds nothing
# Welcome does not show: not the session ID, not whether the session uses
# bridges (tor.error can say so, when bridges were refused).
# module.problem joins the boot's problems (S_PROBLEM) and the current ones
# (S_NOW_PROBLEM).
status_write() {
	_sw_problem=$S_PROBLEM
	[ -z "${S_NOW_PROBLEM-}" ] || _sw_problem=${_sw_problem:+$_sw_problem; }$S_NOW_PROBLEM
	_sw_body=$(
		printf '"problem":%s},' "$(json_str "$_sw_problem")"
		printf '"firewall":{"state":%s,"hash":%s},' "$(json_str "$S_FW_STATE")" "$(json_str "$S_FW_HASH")"
		printf '"tor":{"running":%s,"network":%s,"bootstrap":%s,"summary":%s,"error":%s},' \
			"$(json_bool "$S_TOR_RUNNING")" "$(json_str "$S_TOR_NETWORK")" \
			"$(json_int "$S_TOR_BOOTSTRAP")" "$(json_str "$S_TOR_SUMMARY")" "$(json_str "$S_TOR_ERROR")"
		printf '"dnsfilter":{"running":%s},' "$(json_bool "$S_DNS_RUNNING")"
		printf '"welcome":{"started":%s}}' "$(json_bool "$S_STARTED")"
	)
	_sw_now=$(uptime_s)
	# Written when something changed, and at least once a minute, so that
	# "updated" shows whether service.sh is still running.
	if [ "$_sw_body" = "${S_LAST_BODY-}" ] && [ $((_sw_now - ${S_LAST_WRITE:-0})) -lt 60 ]; then
		return 0
	fi
	_sw_json=$(
		printf '{"schema":1,'
		printf '"module":{"version":%s,"updated":%s,' \
			"$(json_str "$S_VERSION")" "$(json_str "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")"
		printf '%s' "$_sw_body"
	)
	# The writer runs as uid 2950: it creates a new file next to the old
	# one and renames it over, so the filter never reads half a file.
	# shellcheck disable=SC2016 # expanded by the writer's shell
	printf '%s\n' "$_sw_json" | as_user "$TOR_UID" -- /system/bin/sh -c \
		'umask 022; t=$1/.status.json.new; cat >"$t" && mv -f "$t" "$1/status.json"' \
		sh "$RUN" 2>>"$LOGDIR/module.log" || return 1
	S_LAST_BODY=$_sw_body
	S_LAST_WRITE=$_sw_now
}
