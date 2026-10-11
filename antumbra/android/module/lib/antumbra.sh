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
FILTER_PORT=5353
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
# to 127.0.0.1:5353, and lets apps reach 5380. Only tor (2950) may listen on
# 9040 and 9053, and only the filter (2951) on 5353 and 5380. But tor holds
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
# 9040, 9053, 5353, 5380. UDP in any state: 9053, 5353. /proc/net prints
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
		grep -E ':(2350|235D|14E9|1504) ' "$PROC_NET/$_pb_f" 2>/dev/null |
			while read -r _ _pb_loc _ _pb_st _ _ _ _pb_uid _; do
				case ${_pb_loc%:*} in
				0100007F | 00000000 | 00000000000000000000000000000000 | 0000000000000000FFFF00000100007F) ;;
				*) continue ;;
				esac
				case ${_pb_f%6}:${_pb_loc##*:} in
				tcp:2350) _pb_p=$TRANS_PORT/tcp _pb_want=$TOR_UID ;;
				tcp:235D) _pb_p=$TOR_DNS_PORT/tcp _pb_want=$TOR_UID ;;
				tcp:14E9) _pb_p=$FILTER_PORT/tcp _pb_want=$DNS_UID ;;
				tcp:1504) _pb_p=$STATUS_PORT/tcp _pb_want=$DNS_UID ;;
				udp:235D) _pb_p=$TOR_DNS_PORT/udp _pb_want=$TOR_UID ;;
				udp:14E9) _pb_p=$FILTER_PORT/udp _pb_want=$DNS_UID ;;
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
# LineageOS, "phone:" lines everywhere but the emulator. Prints the keys
# that could not be set.
settings_apply() {
	_sa_lineage=0
	is_lineage && _sa_lineage=1
	_sa_phone=1
	is_emulator && _sa_phone=0
	while IFS= read -r _sa_line || [ -n "$_sa_line" ]; do
		case $_sa_line in '' | '#'*) continue ;; esac
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

# mobile_data_off: mobile data off for every SIM Android knows, now and at
# the next start. Android stores the choice per subscription
# (Settings.Global mobile_data<subId> in dual-SIM mode; the hotdog has two
# slots; mobile_data with one; GlobalSettingsHelper in Android 16)
# and reads it when the SIM comes up, so it holds on a start without the
# module too. A SIM Android has never seen has no value yet and starts
# with mobile data on (ro.com.android.mobiledata, default true): that gap
# is in README, "Known gaps". 'cmd phone data disable' switches it off now
# on the default data SIM. Not on the emulator, whose only network in CI
# is its simulated mobile data.
mobile_data_off() {
	is_emulator && return 0
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

# radios_off: airplane mode on and Wi-Fi off. Used only when the firewall
# cannot be put in place and the network may be open.
radios_off() {
	/system/bin/cmd connectivity airplane-mode enable >/dev/null 2>&1
	/system/bin/cmd wifi set-wifi-enabled disabled >/dev/null 2>&1
}

# framework_ready: true once boot has completed and the settings provider
# answers.
framework_ready() {
	[ "$(getprop sys.boot_completed 2>/dev/null)" = 1 ] &&
		/system/bin/settings get global airplane_mode_on >/dev/null 2>&1
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
