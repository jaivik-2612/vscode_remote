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

# --- Wi-Fi calling and video calling off (MOD7) --------------------------------------
#
# Android's ImsManager reads these properties as a force-on only: 1, in the
# per-slot form NAME<slot> or the plain NAME, makes the feature available
# whatever the device and the carrier say; 0 or no value leaves it to the
# device's config_device_wfc_ims_available and config_device_vt_available
# (both false on this phone; LineageOS's overlay sets only the unused
# config_carrier_wfc_ims_available) and the carrier. LineageOS for this
# phone sets wfc, vt and volte to 1 in /system_ext/etc/build.prop. The
# module sets the first two to 0 in memory only (prop_set: resetprop -n,
# never -p), so nothing reaches /data/property and a boot without the
# module is LineageOS's own. persist.dbg.volte_avail_ovr, which VoLTE on
# this phone depends on, is never touched, nor any per-slot form of it.
IMS_OFF_PROPS='persist.dbg.wfc_avail_ovr persist.dbg.vt_avail_ovr'
IMS_OFF_SLOTS='0 1'
# shellcheck disable=SC2034 # used by post-fs-data.sh, service.sh and uninstall.sh
IMS_OFF_RECORD=$PRIV/ims-off.orig

# ims_off_names: the properties ims_off sets, one per line: the two, and
# each per-slot form that has a value now.
ims_off_names() {
	for _io_p in $IMS_OFF_PROPS; do
		printf '%s\n' "$_io_p"
		for _io_s in $IMS_OFF_SLOTS; do
			[ -z "$(getprop "$_io_p$_io_s" 2>/dev/null)" ] || printf '%s\n' "$_io_p$_io_s"
		done
	done
}

# ims_off_due: print each of ims_off_names that does not read 0; return 1
# when there is none (ims_off would write nothing).
ims_off_due() {
	_io_due=1
	for _io_p in $(ims_off_names); do
		[ "$(getprop "$_io_p" 2>/dev/null)" = 0 ] && continue
		printf '%s\n' "$_io_p"
		_io_due=0
	done
	return "$_io_due"
}

# ims_off [RECORD]: set each of ims_off_names to 0 where it does not read 0.
# With RECORD, a file that does not exist yet, first writes NAME=VALUE for
# each (an empty VALUE: none), what uninstall.sh puts back while Android
# runs; an existing record is kept (the first of the boot). Only
# post-fs-data.sh passes RECORD, so a record never holds the module's own
# 0s. Prints each name it set; returns 1 if one still does not read 0.
ims_off() {
	_io_names=$(ims_off_names)
	if [ -n "${1-}" ] && [ ! -e "$1" ]; then
		for _io_p in $_io_names; do
			printf '%s=%s\n' "$_io_p" "$(getprop "$_io_p" 2>/dev/null)"
		done >"$1.new" && mv -f "$1.new" "$1"
	fi
	_io_rc=0
	for _io_p in $_io_names; do
		[ "$(getprop "$_io_p" 2>/dev/null)" = 0 ] && continue
		prop_set "$_io_p" 0 >/dev/null 2>&1
		printf '%s\n' "$_io_p"
		[ "$(getprop "$_io_p" 2>/dev/null)" = 0 ] || _io_rc=1
	done
	return "$_io_rc"
}

# ims_off_restore RECORD: put back the values ims_off recorded (none: the
# property removed). Only the wfc and vt names and their per-slot forms,
# with a value of digits or none, are taken; any other line is skipped.
ims_off_restore() {
	[ -f "$1" ] || return 0
	while IFS= read -r _io_l || [ -n "$_io_l" ]; do
		_io_p=${_io_l%%=*}
		_io_v=${_io_l#*=}
		case $_io_p in
		persist.dbg.wfc_avail_ovr | persist.dbg.wfc_avail_ovr[01] | persist.dbg.vt_avail_ovr | persist.dbg.vt_avail_ovr[01]) ;;
		*) continue ;;
		esac
		case $_io_v in *[!0-9]*) continue ;; esac
		if [ -n "$_io_v" ]; then
			prop_set "$_io_p" "$_io_v" >/dev/null 2>&1
		else
			prop_clear "$_io_p"
		fi
	done <"$1"
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

# welcome_row: Welcome's row with the columns session_read reads
# (WELCOME_COLUMNS, the cell column last). Prints the row and returns 0;
# returns 2, printing nothing, when Welcome answered that it has no "cell"
# column (a Welcome from before WEL8: 'content' prints the provider's
# "IllegalArgumentException: Unknown column: cell" on standard error and
# exits 0); returns 1 for any other answer without a row (Welcome not
# started yet, a Java start that failed): the module then keeps waiting,
# so a passing failure never makes a Phone-mode session keep the radio off.
WELCOME_COLUMNS=started:tor_mode:mac:session_id:cell
welcome_row() {
	/system/bin/content query --user 0 --uri "$PROVIDER_URI" --projection "$WELCOME_COLUMNS" 2>&1 | welcome_row_pick
}

# welcome_row_pick: welcome_row's answer from what 'content' printed
# (standard output and error, on standard input).
welcome_row_pick() {
	_wr=$(cat)
	_wr_row=$(printf '%s\n' "$_wr" | sed -n '/^Row: 0 /{p;q;}')
	if [ -n "$_wr_row" ]; then
		printf '%s\n' "$_wr_row"
		return 0
	fi
	printf '%s\n' "$_wr" | tr -d '\r' | grep -q -x 'java.lang.IllegalArgumentException: Unknown column: cell' && return 2
	return 1
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

# settings_list: every Settings.Global value, "KEY=VALUE" per line.
settings_list() { /system/bin/settings list global 2>/dev/null; }

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
		settings_list | sed -n 's/^mobile_data\([0-9][0-9]*\)=.*/\1/p'
		/system/bin/content query --uri content://telephony/siminfo --projection _id 2>/dev/null |
			sed -n 's/^Row: [0-9]* _id=\([0-9][0-9]*\)$/\1/p'
	} | sort -u)
	for _md_id in $_md_ids; do
		settings_put "mobile_data$_md_id" 0
	done
	/system/bin/cmd phone data disable >/dev/null 2>&1
	# A session whose Internet is mobile data switches it on again
	# (cell_data_step).
	CELL_DATA_ON=0
	return 0
}

# mobile_data_on: mobile data on for the default data SIM ('cmd phone data
# enable': the person's switch in Settings, as Android stores it). Only for
# a session whose Internet is mobile data, over a live firewall
# (cell_data_step).
mobile_data_on() { /system/bin/cmd phone data enable >/dev/null 2>&1; }

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
# The cell radio stays off unless the session chose Phone mode at Start and
# this phone's gate allows it (WEL8; "Phone mode and the gate", below). It
# is off from power-on because of three stored values: enable_cellular_on_boot=0 (settings.conf), airplane
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
# line per call; Analytics, one "Call TC@<n>" entry per recent call, n
# counting up within a boot, with "endTime:" (0 until the call is
# disconnected), "isEmergency: true|false", which Telecom sets from
# Android's own emergency-number list, and the call's properties),
# 'dumpsys telephony.registry' (per phone the call states and the
# callback-mode durations, and the radio power), the property
# ril.cdma.inecmmode (emergency callback mode, set on both of Android 16's
# paths) and the phone process's pid and start time (/proc); in a
# Phone-mode session also the phone process's own dump
# (TelephonyDebugService: the IMS registration). The registry also prints
# the incoming number: the dumps go through pipes only, never to a file or
# the log. Android 17 no longer prints Telecom's Analytics.
#
# The module's word to Welcome (MOD11). Welcome cannot tell an emergency
# call from any other, so its Quick power off waits for 5 minutes after any
# call. After each look the module tells Welcome what the calls of the last
# 5 minutes were: "emergency" (Telecom's entry says so, the network said
# so, or callback mode is or was on), "ordinary" (in a Phone-mode session
# only: every call in that time, at every look, had an entry saying it was
# not an emergency call, each read again after it ended, and nothing below
# applies), "unknown" (any call outside Phone mode, where the cell radio is
# off, so a carrier call there is an emergency call, a Wi-Fi call
# (switched off by MOD7 and stopped by the firewall, both unverified on the
# phone) or follows a switch-on by something else, which the module cannot
# tell apart; anything the module cannot read or classify; the radio or
# airplane mode switched by something else; the phone process restarted or
# not running, when Telecom's own emergency check can fail; Android 17) or
# "none" (nothing in the last 5 minutes). Welcome skips its wait only for
# a fresh "ordinary" word that covers the call it saw end; everything else
# waits as before, and "emergency" can only make it wait longer. Outside
# Phone mode (cell_phone_mode: the radio on by the session's choice and
# the gate) the word is never "ordinary". The word goes to Welcome alone: root calls Welcome's
# provider (only uid 0 may), never status.json or a property, which every
# app can read. The module keeps the times of the last emergency sign and
# of the last doubt until 5 minutes after the last call that followed
# them, then forgets them, and its log never names a word.
#
# Phone mode and the gate (WEL8). Welcome's row says what the session
# chose at Start: cell = off, phone (calls and texts: the radio on, mobile
# data off) or data (the radio on and mobile data on, its traffic held to
# tor by the firewall like any other). What the module carries out is the
# lowest of that choice, the gate in force at Start and the gate now
# (cell_effective). After Start a gate can only go down: a gate lowered
# during a session takes effect at once (the radio off with every hold
# above; mobile data off at once) and holds for the rest of the session
# (cell_gate_step), and a gate raised during a session changes nothing
# until the next start, so the radio never comes on in the middle of a
# session started with it refused, or after the gate was taken away.
# The radio comes on at Start only, never before (decision D12). The gate
# is the root-only file /data/adb/antumbra-cell (cell_gate): no file, as
# installed, is "off", and every session keeps the radio off whatever
# Welcome's row says. The install's PH3 step writes "phone" for the
# measurement and keeps it only as PH3 decides (outcome A, or B once FW6
# passes); CI's emulator writes it as root, the same way. "data" counts
# only on the emulator until FW9 and CI12 have passed (CELL_DATA_ON_PHONE,
# which a later queue item sets): on the phone the gate goes no higher
# than "phone", whatever the file says. Nothing else turns the gate on:
# no property, no setting, no build flag; the zip CI tests is the zip a
# release ships. The module tells Welcome the gate, what it carries out and
# the radio as it last read it (module_cell, cell_offer_tell), so that
# Welcome offers only what the module will do; Welcome cannot raise it.
# Emergency calls get nothing new in any case: no call or SMS restriction,
# and no radio step but airplane mode, which the emergency path undoes.

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
# Welcome's provider takes the module's word through a call that only uid
# 0 may make (StateProvider.call); seconds between IMS readings in Phone
# mode.
WORD_URI=content://org.antumbra.welcome.state
WORD_METHOD=module_word
CELL_IMS_EVERY=300
# Seconds between tries while Welcome does not take the word (a Welcome
# without module_word answers "Result: null" every time).
WORD_RETRY=300
# The Phone-mode gate (WEL8): a root-only file (cell_gate).
CELL_GATE_FILE=/data/adb/antumbra-cell
# 1 lets the gate say "data" on a phone. 0 until FW9 (the SIM's mobile data
# through Tor) and CI12 (an emulator run over the emulated radio) have
# passed: until then mobile data through Tor is carried out on the emulator
# only, and a phone's gate stops at "phone".
CELL_DATA_ON_PHONE=0
# Welcome's provider takes the module's word on the cell radio
# (module_cell) from uid 0 only; seconds between words when nothing
# changes, so that Welcome can tell a live reading from an old one.
CELL_OFFER_METHOD=module_cell
CELL_OFFER_EVERY=300
# Seconds from a first refusal of it to the next try; doubled at each
# refusal after that, up to CELL_OFFER_EVERY.
CELL_OFFER_RETRY=30

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
# The module's word to Welcome (MOD11; cell_note, cell_forget, cell_tell).
CELL_LIVE=         # Telecom's numbers of the calls not over at the last look: listed, or not ended ("3,4", "-")
CELL_FROM=         # CELL_ID before the last look: the calls numbered since are read once more
CELL_XN=           # Analytics entries without a TC@ number at the last look
CELL_PHONE=        # the phone process at the last look, "PID:START" ("-": not running; empty: unread)
CELL_EM_AT=        # uptime of the last look that saw an emergency sign, or of the look after (renewed by calls)
CELL_UNK_AT=       # the same for a doubt (something the module could not read or classify)
CELL_EM_SEEN=0     # 1 if the last look saw an emergency sign
CELL_UNK_SEEN=0    # 1 if the last look saw a doubt
CELL_WORD=         # the last word Welcome took, "KIND UNTIL IMS IMS_AT" (empty: none yet)
CELL_WORD_BAD=0    # 1 while Welcome does not take the word (logged once)
CELL_BAD_AT=0      # uptime of the last try Welcome did not take
CELL_BAD_KIND=     # that try's kind
CELL_TOLD_AT=      # uptime of the last word Welcome took
CELL_IMS=off       # IMS registration for Welcome: cell, wifi, registered, none, unknown; off outside Phone mode
CELL_IMS_AT=0      # uptime of that reading (0 with off)
CELL_IMS_NEXT=0    # uptime of the next reading
# The last look: CL_CALL and CL_CBM are 0, 1 or unknown; CL_ID is a number
# or empty; CL_RADIO is on, off, wait or unknown. CL_KIND is telecom_state's
# KIND (e, u, o, -) or unknown; CL_LIVE and CL_XN are its LIVE and XN;
# CL_ALONE is 1 when the registry shows a call that Telecom does not list;
# CL_PHONE is phone_proc's "PID:START", or "-".
CL_CALL=unknown
CL_CBM=unknown
CL_ID=
CL_RADIO=unknown
CL_KIND=unknown
CL_LIVE=
CL_XN=
CL_ALONE=0
CL_PHONE=-
# The session's choice ("off", "phone" or "data"; service.sh's
# session_cell), the gate in force at Start (SES_GATE, service.sh's
# session_read) and the fail-safe's state (service.sh's RADIOS) are read
# from service.sh.
SES_CELL=${SES_CELL:-off}
SES_GATE=${SES_GATE:-off}
RADIOS=${RADIOS:-}
CELL_GATE=off      # the gate now, as cell_gate_step last read it
CELL_GATE_SEEN=    # the gate last logged (empty: not read yet)
CELL_DATA_ON=0     # 1 once the module switched mobile data on (a data session); 0 after any mobile_data_off
CELL_EMULATOR=     # 1 on the emulator, 0 on a phone (empty: not asked yet)
# The module's word on the cell radio to Welcome (module_cell; cell_offer_tell).
CELL_OFFER=        # the last word Welcome took, "GATE CELL RADIO AT" (empty: none yet)
CELL_OFFER_AT=     # uptime when Welcome took it
CELL_OFFER_SID=    # Welcome's session_id then (WELCOME_SID)
CELL_OFFER_BAD=0   # 1 while Welcome does not take it (logged once)
CELL_OFFER_BAD_AT=0
CELL_OFFER_WAIT=30 # seconds from a refusal to the next try (CELL_OFFER_RETRY doubling, up to CELL_OFFER_EVERY)
CELL_OFFER_TOLD=   # uptime of the last try (service.sh checks the ports again after it)
# Welcome's session_id at the last read of its row (session_read): before
# Start a new one means Welcome's process started again, and lost the word.
WELCOME_SID=${WELCOME_SID:-}
# 1 while the module reads Welcome's row without the cell column (an older
# Welcome; service.sh's session_read): its sessions keep the cell radio
# off, so the gate told to Welcome is "off" meanwhile (cell_offer_tell).
WELCOME_OLD=${WELCOME_OLD:-0}
# The cell radio's current problem, for status.json (service.sh).
# shellcheck disable=SC2034 # read by service.sh
P_CELL=
CELL_READ=         # 1 or 0: whether the last look could read the call state
CELL_CLOCKLESS=0   # 1 while the time since boot cannot be read

# telecom_state [SINCE [LIVE [XN [FROM]]]]: read 'dumpsys telecom' on
# standard input and print "CALLS LASTID KIND LIVE XN": the calls Telecom
# lists now, in any state (VoIP calls too); the highest call number seen (0
# if none); what the calls in scope were (KIND, below); the numbers of the
# calls not over, the next look's LIVE: those listed now and those whose
# entry has not ended ("3,4", or "-"); and how many Analytics entries have
# an id that is not TC@<number> (conference parts, calls from other
# devices, some VoIP calls). Returns 1 when the dump lacks CallsManager,
# its mCalls list or Analytics (Telecom not ready, a timeout, a format this
# does not know: Android 17 prints no Analytics), when it lacks the end of
# Analytics ("Hardware Version:", which Telecom prints after the last
# entry), and when dumpsys says it gave up ("DUMP TIMEOUT"). Telecom prints
# the entries oldest first, so a dump cut short (by dumpsys, by 'timeout',
# or a busy Telecom) loses the newest calls first and would otherwise look
# complete.
#
# In scope: the calls listed now; the calls not over at the last look
# (LIVE, as printed then); the calls numbered above SINCE (LASTID at the
# last look; every call on the module's first look, SINCE empty); the
# calls numbered above FROM up to SINCE, those first counted at the last
# look (FROM is the LASTID of the look before it; empty: none); and every
# call whose entry has not ended ("endTime: 0": Telecom writes the end
# only when the call is disconnected). A call read again (not numbered
# above SINCE) that is not listed now must have an entry that says it
# ended; until it does, it reads u at every look, whatever its entry says
# so far. So every call is read at the look that first counts it and at
# the next, stays in scope while it is listed or its entry has not ended,
# and leaves the scope only after a look that read it not listed and its
# entry ended: its last reading is of its final entry. (Telecom prints
# its call list before Analytics, without a lock, so a look can see an
# entry whose call is not listed yet; the network's "ecall" and a new
# handle's isEmergency can come later in the call; a call Telecom drops
# before listing it, with no account to place it, never ends: u until its
# entry leaves Telecom's last 100.) XN is the last look's. KIND is
#   e  one of them was an emergency call: its entry says "isEmergency:
#      true", or "ecall" (the network said so) or "ecbm" (made in callback
#      mode) is among its callProperties or, for a call listed now, its
#      prop=;
#   u  else one cannot be told: a call listed with another id than
#      TC@<number>, or without prop=; a call in scope without an entry, or
#      whose entry lacks exactly one "endTime: <number>", one
#      "isEmergency: true|false" and one "callProperties: [...]" line; a
#      call read again that is not listed now and whose entry has not
#      ended (still being set up, waiting for the person to confirm, or
#      dropped before Telecom listed it: the module cannot tell which); not
#      one entry for each number above FROM, or above SINCE without FROM
#      (Telecom keeps the last 100 calls); SINCE above LASTID (Telecom
#      restarted: the calls before it cannot be checked); FROM not a number
#      or above SINCE; XN changed, or above 0 on the first look or once
#      Telecom keeps 100 entries (an entry the numbers do not cover);
#   o  else every call in scope was an ordinary call;
#   -  no call in scope.
# Only exact keys and whole words count: "missedReason: [emergency]" (a call
# missed because of an emergency call) and disconnect reasons are not read.
# Nothing but numbers and these letters is printed.
telecom_state() {
	_ts_since=${1-}
	_ts_prev=${2-}
	_ts_xprev=${3-}
	_ts_from=${4-}
	# The call lines first: the substitutions below change the line that
	# starts their range.
	sed -n -e '/^  mCalls: *$/,/^ \{0,2\}[^ ]/{/^    \[Call id=/p;}' \
		-e 's/^\(CallsManager:\) *$/\1/p' -e 's/^\(Analytics:\) *$/\1/p' \
		-e 's/^  \(mCalls:\) *$/\1/p' -e 's/^\*\*\* .*DUMP TIMEOUT.*$/DUMP TIMEOUT/p' \
		-e '/^Analytics: *$/,/^[^ ]/{s/^ *\(Call [^ ]*\): { *$/\1 {/p;s/^ *\(endTime:.*\)$/\1/p;s/^ *\(isEmergency:.*\)$/\1/p;s/^ *\(callProperties:.*\)$/\1/p;s/^ *} *$/}/p;s/^ *\(Hardware Version:\).*$/\1/p;}' |
		{
			_ts_have=
			_ts_n=0
			_ts_last=0
			_ts_live=
			_ts_ents=,
			_ts_open=,
			_ts_tot=0
			_ts_xn=0
			_ts_e=0
			_ts_u=0
			_ts_cur=
			_ts_cn=0
			_ts_ce=0
			_ts_cp=0
			while IFS= read -r _ts_line; do
				_ts_id=
				case $_ts_line in
				CallsManager: | mCalls: | Analytics:)
					_ts_have="$_ts_have${_ts_line%:},"
					continue
					;;
				'Hardware Version:')
					_ts_have="${_ts_have}end,"
					continue
					;;
				'DUMP TIMEOUT') exit 1 ;;
				'    [Call id='*)
					_ts_n=$((_ts_n + 1))
					case $_ts_line in *'[Call id=TC@'[0-9]*)
						_ts_id=${_ts_line#*id=TC@}
						_ts_id=${_ts_id%%[!0-9]*}
						;;
					esac
					# Classified only with an exact TC@<number> and its prop=.
					_ts_x=${_ts_line#'    [Call id='}
					_ts_x=${_ts_x%%,*}
					if [ -n "$_ts_id" ] && [ "$_ts_x" = "TC@$_ts_id" ]; then
						_ts_live=${_ts_live:+$_ts_live,}$_ts_id
					else
						_ts_u=1
					fi
					case $_ts_line in
					*' prop=['*']'*)
						_ts_p=${_ts_line##*' prop=['}
						_ts_p=${_ts_p%%']'*}
						case " $_ts_p " in *' ecall '* | *' ecbm '*) _ts_e=1 ;; esac
						;;
					*) _ts_u=1 ;;
					esac
					;;
				'Call '*' {')
					[ -z "$_ts_cur" ] || _ts_u=1
					_ts_tot=$((_ts_tot + 1))
					_ts_x=${_ts_line#Call }
					_ts_x=${_ts_x% \{}
					_ts_cur=x
					case $_ts_x in TC@[0-9]*)
						_ts_v=${_ts_x#TC@}
						case $_ts_v in *[!0-9]*) ;; *) _ts_cur=$_ts_v ;; esac
						;;
					esac
					if [ "$_ts_cur" = x ]; then
						_ts_xn=$((_ts_xn + 1))
					else
						_ts_id=$_ts_cur
					fi
					_ts_ce=0
					_ts_ct=0
					_ts_cev=
					_ts_cp=0
					_ts_cpv=
					_ts_cn=0
					_ts_cnv=
					;;
				endTime:*)
					[ -n "$_ts_cur" ] || _ts_u=1
					_ts_cn=$((_ts_cn + 1))
					_ts_cnv=${_ts_line#endTime:}
					_ts_cnv=${_ts_cnv# }
					;;
				isEmergency:*)
					[ -n "$_ts_cur" ] || _ts_u=1
					_ts_ce=$((_ts_ce + 1))
					_ts_cev=${_ts_line#isEmergency:}
					_ts_cev=${_ts_cev# }
					[ "$_ts_cev" != true ] || _ts_ct=1
					;;
				callProperties:*)
					[ -n "$_ts_cur" ] || _ts_u=1
					_ts_cp=$((_ts_cp + 1))
					_ts_cpv=${_ts_line#callProperties:}
					;;
				'}')
					case $_ts_cur in
					'') _ts_u=1 ;;
					x) ;;
					*)
						_ts_k=o
						[ "$_ts_ce" = 1 ] && [ "$_ts_cp" = 1 ] || _ts_k=u
						case $_ts_cev in true | false) ;; *) _ts_k=u ;; esac
						case $_ts_cpv in
						' ['*']')
							_ts_p=${_ts_cpv#' ['}
							_ts_p=${_ts_p%']'}
							case " $_ts_p " in *' ecall '* | *' ecbm '*) _ts_ct=1 ;; esac
							;;
						*) _ts_k=u ;;
						esac
						# Ended: one endTime of digits, not 0 (milliseconds
						# since the epoch, compared as text: 13 digits do not
						# fit mksh's arithmetic). 0: not yet (open); anything
						# else cannot be read: unknown, and open.
						_ts_o=1
						if [ "$_ts_cn" = 1 ]; then
							case $_ts_cnv in
							0) ;;
							[1-9]*) case $_ts_cnv in *[!0-9]*) _ts_k=u ;; *) _ts_o=0 ;; esac ;;
							*) _ts_k=u ;;
							esac
						else
							_ts_k=u
						fi
						[ "$_ts_ct" = 0 ] || _ts_k=e
						[ "$_ts_o" = 0 ] || _ts_open="$_ts_open$_ts_cur,"
						_ts_ents="$_ts_ents$_ts_cur:$_ts_k,"
						;;
					esac
					_ts_cur=
					;;
				esac
				[ -n "$_ts_id" ] || continue
				# Shell arithmetic may be 32 bits (mksh).
				[ "${#_ts_id}" -le 9 ] || exit 1
				[ "$_ts_id" -le "$_ts_last" ] || _ts_last=$_ts_id
			done
			case $_ts_have in *CallsManager,*) ;; *) exit 1 ;; esac
			case $_ts_have in *mCalls,*) ;; *) exit 1 ;; esac
			# Analytics to its end, which follows every entry.
			case $_ts_have in *Analytics,*end,*) ;; *) exit 1 ;; esac
			[ -z "$_ts_cur" ] || _ts_u=1
			# The scope.
			_ts_s=$_ts_since
			case $_ts_s in
			'') _ts_s=0 ;;
			*[!0-9]* | ??????????*)
				_ts_s=0
				_ts_u=1
				;;
			esac
			# The calls first counted at the last look: above FROM, up to
			# SINCE (FROM empty: none).
			_ts_f=$_ts_from
			case $_ts_f in
			'') _ts_f=$_ts_s ;;
			*[!0-9]* | ??????????*)
				_ts_f=$_ts_s
				_ts_u=1
				;;
			esac
			if [ "$_ts_f" -gt "$_ts_s" ]; then
				_ts_f=$_ts_s
				_ts_u=1
			fi
			if [ "$_ts_s" -gt "$_ts_last" ]; then
				_ts_s=0
				_ts_f=0
				_ts_u=1
			fi
			_ts_in=0
			_ts_c=0
			_ts_cf=0
			_ts_keep=$_ts_live
			_ts_r=${_ts_ents#,}
			while [ -n "$_ts_r" ]; do
				_ts_one=${_ts_r%%,*}
				_ts_r=${_ts_r#*,}
				_ts_v=${_ts_one%:*}
				_ts_k=${_ts_one#*:}
				# Not listed now and not ended: read again at the next look.
				case ,$_ts_live,:$_ts_open in
				*",$_ts_v,"*:*) ;;
				*:*",$_ts_v,"*) _ts_keep=${_ts_keep:+$_ts_keep,}$_ts_v ;;
				esac
				if [ "$_ts_v" -gt "$_ts_s" ]; then
					_ts_c=$((_ts_c + 1))
				else
					[ "$_ts_v" -le "$_ts_f" ] || _ts_cf=$((_ts_cf + 1))
					# Read again: a call not listed now must have ended,
					# else unknown, whatever its entry says so far. Ended,
					# it stays in scope only above FROM (or in LIVE, below).
					case ,$_ts_live,:$_ts_open in
					*",$_ts_v,"*:*) ;;
					*:*",$_ts_v,"*) _ts_k=u ;;
					*) [ "$_ts_v" -gt "$_ts_f" ] || continue ;;
					esac
				fi
				_ts_in=1
				case $_ts_k in e) _ts_e=1 ;; u) _ts_u=1 ;; esac
			done
			[ "$_ts_c" = $((_ts_last - _ts_s)) ] || _ts_u=1
			[ "$_ts_cf" = $((_ts_s - _ts_f)) ] || _ts_u=1
			# The calls not over at the last look (LIVE) and those listed
			# now, by their entries.
			case $_ts_prev in '' | -) _ts_r= ;; *) _ts_r=$_ts_prev ;; esac
			_ts_r=$_ts_r${_ts_live:+,$_ts_live}
			_ts_r=${_ts_r#,}
			while [ -n "$_ts_r" ]; do
				_ts_one=${_ts_r%%,*}
				case $_ts_r in *,*) _ts_r=${_ts_r#*,} ;; *) _ts_r= ;; esac
				_ts_in=1
				case $_ts_one in '' | *[!0-9]*)
					_ts_u=1
					continue
					;;
				esac
				case $_ts_ents in
				*",$_ts_one:"*)
					_ts_k=${_ts_ents#*",$_ts_one:"}
					_ts_k=${_ts_k%%,*}
					# Not listed now: it must have ended.
					case ,$_ts_live,:$_ts_open in
					*",$_ts_one,"*:*) ;;
					*:*",$_ts_one,"*) _ts_k=u ;;
					esac
					case $_ts_k in e) _ts_e=1 ;; u) _ts_u=1 ;; esac
					;;
				*) _ts_u=1 ;;
				esac
			done
			[ "$_ts_n" = 0 ] || _ts_in=1
			# Entries the numbers do not cover.
			if [ -n "$_ts_xprev" ]; then
				[ "$_ts_xn" = "$_ts_xprev" ] || _ts_u=1
			else
				[ "$_ts_xn" = 0 ] || _ts_u=1
			fi
			[ "$_ts_tot" -lt 100 ] || [ "$_ts_xn" = 0 ] || _ts_u=1
			if [ "$_ts_e" = 1 ]; then
				_ts_kind=e
			elif [ "$_ts_u" = 1 ]; then
				_ts_kind=u
			elif [ "$_ts_in" = 1 ]; then
				_ts_kind=o
			else
				_ts_kind=-
			fi
			echo "$_ts_n $_ts_last $_ts_kind ${_ts_keep:--} $_ts_xn"
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
# dumps, takes at most 8). A dump cut short reads as unknown: a hold
# (telecom_state needs the end of Analytics, registry_state the radio
# power, which each dump prints after everything they read).
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

# phone_proc: print the phone process (com.android.phone) as "PID:START":
# its pid and its start time (clock ticks since boot, field 22 of
# /proc/PID/stat, read after the name, so a new process that got the old
# pid still differs). Returns 1 if it is not running, runs twice or cannot
# be read. toybox pidof matches the name Android gives the process
# (argv[0]); root sees every process. Telecom's own emergency-number check
# asks this process, and records "not an emergency call" when it cannot
# (the process missing, not ready yet, or dying), while Telephony checks
# again and places the call as an emergency call: a new or missing
# process is a doubt (cell_note).
phone_proc() {
	_pp=$($TB pidof com.android.phone 2>/dev/null) || return 1
	case $_pp in '' | *[!0-9]*) return 1 ;; esac
	read -r _pp_s 2>/dev/null <"/proc/$_pp/stat" || return 1
	_pp_s=${_pp_s##*') '}
	set -f
	# shellcheck disable=SC2086 # the fields after the name, on purpose
	set -- $_pp_s
	set +f
	[ "$#" -ge 20 ] || return 1
	shift 19
	case $1 in '' | *[!0-9]*) return 1 ;; esac
	echo "$_pp:$1"
}

# cell_gate_owner_ok FILE: FILE belongs to root and neither its group nor
# others may write it. (The unit tests replace this one check.)
cell_gate_owner_ok() {
	_go=$($TB stat -c '%u %a' "$1" 2>/dev/null) || return 1
	case $_go in '0 '*) ;; *) return 1 ;; esac
	_go=${_go#0 }
	case $_go in '' | *[!0-7]*) return 1 ;; esac
	# The last two octal digits are the group's and the others': neither
	# may include write (2).
	case $_go in *[2367][0-7] | *[2367]) return 1 ;; esac
	return 0
}

# cell_emulator: true on the Android emulator (asked once; read-only
# properties set at boot).
cell_emulator() {
	if [ -z "$CELL_EMULATOR" ]; then
		CELL_EMULATOR=0
		is_emulator && CELL_EMULATOR=1
	fi
	[ "$CELL_EMULATOR" = 1 ]
}

# cell_gate: print the Phone-mode gate in force on this phone now: "off",
# "phone" or "data". It is "phone" or "data" only when CELL_GATE_FILE is a
# regular file (not a link) that belongs to root, that neither group nor
# others may write, and whose first line is exactly that word; anything
# else, or no file, is "off". /data/adb is root's alone (0711 since
# post-fs-data.sh, 0700 as Magisk makes it), so no app can write the file.
# "data" counts only on the emulator unless CELL_DATA_ON_PHONE is 1; on a
# phone it is "phone" until then.
cell_gate() {
	_cg=off
	if [ -f "$CELL_GATE_FILE" ] && [ ! -L "$CELL_GATE_FILE" ] && cell_gate_owner_ok "$CELL_GATE_FILE"; then
		case $(read_value "$CELL_GATE_FILE") in
		phone) _cg=phone ;;
		data) _cg=data ;;
		esac
	fi
	if [ "$_cg" = data ] && [ "$CELL_DATA_ON_PHONE" != 1 ] && ! cell_emulator; then
		_cg=phone
	fi
	echo "$_cg"
}

# cell_rank LEVEL: 0 for off (and anything else), 1 for phone, 2 for data.
cell_rank() {
	case $1 in
	phone) echo 1 ;;
	data) echo 2 ;;
	*) echo 0 ;;
	esac
}

# cell_effective: what the module carries out for the cell radio: "none"
# before Start; then the lowest of the session's choice (SES_CELL), the
# gate at Start (SES_GATE) and the gate now (CELL_GATE), in the order off,
# phone, data.
cell_effective() {
	if [ "${S_STARTED:-0}" != 1 ]; then
		echo none
		return 0
	fi
	_ce=$SES_CELL
	[ "$(cell_rank "$SES_GATE")" -ge "$(cell_rank "$_ce")" ] || _ce=$SES_GATE
	[ "$(cell_rank "$CELL_GATE")" -ge "$(cell_rank "$_ce")" ] || _ce=$CELL_GATE
	case $_ce in phone | data) echo "$_ce" ;; *) echo off ;; esac
}

# cell_gate_step: read the gate at every turn (a stat and a read, no Java
# start); a change is logged once. After Start a gate can only go down: a
# gate lowered during a session takes effect through cell_effective, and
# SES_GATE takes it, so that it holds for the rest of the session (logged
# once); raised again, it counts only from the next start.
cell_gate_step() {
	# Asked here, outside cell_gate's subshell, so that it is asked once.
	cell_emulator || :
	CELL_GATE=$(cell_gate)
	if [ "${S_STARTED:-0}" = 1 ] && [ "$(cell_rank "$CELL_GATE")" -lt "$(cell_rank "$SES_GATE")" ]; then
		SES_GATE=$CELL_GATE
		log "cell: the Phone-mode gate went down to $SES_GATE; it stays so for this session, until the next start"
	fi
	[ "$CELL_GATE" != "$CELL_GATE_SEEN" ] || return 0
	if [ -z "$CELL_GATE_SEEN" ]; then
		log "cell: this phone's Phone-mode gate: $CELL_GATE"
	else
		log "cell: Phone-mode gate now $CELL_GATE"
	fi
	CELL_GATE_SEEN=$CELL_GATE
}

# cell_phone_mode: true in a Phone-mode session (cell_effective "phone" or
# "data") once the module's switch-on is done and the fail-safe holds no
# radio: the only time the cell radio is on on purpose. Otherwise it is off
# by design (before Start, outside Phone mode, a gate that does not allow
# it, before the switch-on). Telephony refuses an ordinary call while the
# phone's voice service reads powered off (TelephonyConnectionService:
# POWER_OFF; an emergency number switches the radio on), but that state
# counts IMS registered over Wi-Fi as in service (GsmCdmaPhone's
# mergeVoiceServiceStates), so a carrier call there is an emergency call, a
# Wi-Fi call (switched off by MOD7 and stopped by the firewall, both
# unverified on the phone) or follows a switch-on by something else: the
# module cannot tell which.
cell_phone_mode() {
	case $(cell_effective) in phone | data) ;; *) return 1 ;; esac
	[ -z "$RADIOS" ] && [ "$CELL_ON_DONE" = 1 ]
}

# cell_look: one look at the call state, the radio and the phone process
# (sets CL_*). The calls in scope for CL_KIND follow the last readable look
# (CELL_ID, CELL_LIVE, CELL_XN, CELL_FROM).
cell_look() {
	CL_CALL=unknown
	CL_CBM=unknown
	CL_ID=
	CL_RADIO=unknown
	CL_KIND=unknown
	CL_LIVE=
	CL_XN=
	CL_ALONE=0
	CL_PHONE=$(phone_proc) || CL_PHONE=-
	_cl_t=$(cell_dump telecom | telecom_state "$CELL_ID" "$CELL_LIVE" "$CELL_XN" "$CELL_FROM") || _cl_t=
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
			CL_CALL=$1
			set -f
			# shellcheck disable=SC2086 # five words on purpose
			set -- $_cl_t
			set +f
			CL_ID=$2
			CL_KIND=$3
			CL_LIVE=$4
			CL_XN=$5
			if [ "$1" != 0 ]; then
				CL_CALL=1
			elif [ "$CL_CALL" = 1 ]; then
				CL_ALONE=1
			fi
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
# call has happened in this boot), when a call not over at the last look
# (CELL_LIVE: listed, or its entry not ended) is over now (a call listed
# only between two looks ends there), and when the radio came on without
# the module doing it.
#
# For the module's word (MOD11): CELL_EM_AT becomes NOW when the look sees
# an emergency sign (an emergency call in scope, callback mode) and at the
# look after one; CELL_UNK_AT likewise for a doubt: a call in scope that
# cannot be classified; an ordinary call outside Phone mode (cell_phone_mode:
# with the cell radio off a carrier call may be an emergency call, a Wi-Fi
# call or follow a switch-on by something else, and the dump cannot tell a
# carrier call from a VoIP call at every moment); a state that cannot be
# read; a call in the registry that Telecom does not list; the radio on
# without the module (an emergency text switches it on and starts no
# call); the phone process not running, or another one than at the last
# look (phone_proc). A sign or a doubt still kept is renewed by every
# call-like event (those that set CELL_LAST, here and in cell_step: the
# clock readable again, airplane mode switched off by something else), so
# it lasts until 5 minutes after the look that saw the last call end,
# however long the calls go on; records already past their 5 minutes are
# forgotten first and not renewed. CELL_FROM becomes the last readable
# look's CELL_ID (0 on the first, or when the counter went down):
# telecom_state reads the calls it first counted once more.
cell_note() {
	cell_forget "$1"
	_cn_busy=0
	[ "$CL_CALL" = 0 ] || _cn_busy=1
	[ "$CL_CBM" = 0 ] || _cn_busy=1
	_cn_event=$_cn_busy
	[ "$CELL_BUSY" = 0 ] || _cn_event=1
	_cn_em=0
	_cn_unk=0
	case $CL_KIND in
	e) _cn_em=1 ;;
	-) ;;
	o) cell_phone_mode || _cn_unk=1 ;;
	*) _cn_unk=1 ;;
	esac
	case $CL_CBM in 0) ;; 1) _cn_em=1 ;; *) _cn_unk=1 ;; esac
	[ "$CL_ALONE" = 0 ] || _cn_unk=1
	if [ "$CL_PHONE" = - ] || { [ -n "$CELL_PHONE" ] && [ "$CL_PHONE" != "$CELL_PHONE" ]; }; then
		_cn_unk=1
	fi
	CELL_PHONE=$CL_PHONE
	if [ -n "$CL_ID" ]; then
		if [ -z "$CELL_ID" ]; then
			[ "$CL_ID" = 0 ] || _cn_event=1
		elif [ "$CL_ID" != "$CELL_ID" ]; then
			_cn_event=1
		fi
		if [ -z "$CELL_ID" ] || [ "$CL_ID" -lt "$CELL_ID" ]; then
			CELL_FROM=0
		else
			CELL_FROM=$CELL_ID
		fi
		# A call not over at the last look (listed, or its entry not
		# ended) that is over now: its end counts from this look.
		case $CELL_LIVE in '' | -) _cn_r= ;; *) _cn_r=$CELL_LIVE ;; esac
		while [ -n "$_cn_r" ]; do
			_cn_one=${_cn_r%%,*}
			case $_cn_r in *,*) _cn_r=${_cn_r#*,} ;; *) _cn_r= ;; esac
			case ,$CL_LIVE, in *",$_cn_one,"*) ;; *) _cn_event=1 ;; esac
		done
		CELL_ID=$CL_ID
		CELL_LIVE=$CL_LIVE
		CELL_XN=$CL_XN
	fi
	if [ "$CL_RADIO" = on ] && [ "$CELL_RADIO" != on ] && ! cell_mine "$1"; then
		_cn_event=1
		_cn_unk=1
	fi
	CELL_BUSY=$_cn_busy
	CELL_RADIO=$CL_RADIO
	[ "$_cn_event" = 0 ] || CELL_LAST=$1
	[ "$_cn_em" = 0 ] && [ "$CELL_EM_SEEN" = 0 ] || CELL_EM_AT=$1
	[ "$_cn_unk" = 0 ] && [ "$CELL_UNK_SEEN" = 0 ] || CELL_UNK_AT=$1
	if [ "$_cn_event" = 1 ]; then
		[ -z "$CELL_EM_AT" ] || CELL_EM_AT=$1
		[ -z "$CELL_UNK_AT" ] || CELL_UNK_AT=$1
	fi
	CELL_EM_SEEN=$_cn_em
	CELL_UNK_SEEN=$_cn_unk
}

# cell_forget NOW: 5 minutes after the last look that saw a call, a sign or
# a doubt (cell_note renews a sign or a doubt at every call-like event),
# the watch forgets it (CELL_LAST, CELL_EM_AT, CELL_UNK_AT): from then on
# the module keeps nothing about those calls but Telecom's own counter
# (CELL_ID, CELL_FROM) and the phone process's pid and start time
# (CELL_PHONE). cell_hold answers the same with or without them. A clock
# below a time, or none (NOW 0), clears nothing.
cell_forget() {
	if [ -n "$CELL_LAST" ] && [ "$1" -ge "$CELL_LAST" ] && [ $(($1 - CELL_LAST)) -ge "$CELL_AFTER" ]; then
		CELL_LAST=
	fi
	if [ -n "$CELL_EM_AT" ] && [ "$1" -ge "$CELL_EM_AT" ] && [ $(($1 - CELL_EM_AT)) -ge "$CELL_AFTER" ]; then
		CELL_EM_AT=
	fi
	if [ -n "$CELL_UNK_AT" ] && [ "$1" -ge "$CELL_UNK_AT" ] && [ $(($1 - CELL_UNK_AT)) -ge "$CELL_AFTER" ]; then
		CELL_UNK_AT=
	fi
}

# cell_word NOW: the module's word on the calls of the last 5 minutes,
# "KIND UNTIL": "emergency END" (END: when Welcome may stop waiting for
# it, 5 minutes after the look that saw the sign or its end, or the last
# call-like event since); "unknown 0" (no time since boot, the last look
# could not read the state, or a doubt kept: cell_note); "ordinary 0" (a
# call-like event in the last 5 minutes, every call classified as an
# ordinary call in a Phone-mode session); "none 0". In this order:
# emergency, unknown, ordinary, none.
cell_word() {
	if [ "$1" -le 0 ]; then
		echo "unknown 0"
	elif [ -n "$CELL_EM_AT" ]; then
		echo "emergency $((CELL_EM_AT + CELL_AFTER))"
	elif [ -n "$CELL_UNK_AT" ]; then
		echo "unknown 0"
	else
		case $CL_CALL:$CL_CBM in
		[01]:[01])
			if [ -n "$CELL_LAST" ]; then echo "ordinary 0"; else echo "none 0"; fi
			;;
		*) echo "unknown 0" ;;
		esac
	fi
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
# waits to switch it off; "on" in a Phone-mode session (cell_effective
# "phone" or "data": after Start only, decision D12, and only as far as
# the gate allows), "leave" there once the fail-safe has switched the
# radios off (the person decides from then on); "off" otherwise.
cell_want() {
	case $RADIOS in wanted | waiting)
		echo failsafe
		return 0
		;;
	esac
	case $(cell_effective) in phone | data)
		if [ -z "$RADIOS" ]; then echo on; else echo leave; fi
		return 0
		;;
	esac
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

# cell_data_step NOW: mobile data for the session's Internet (WEL8). In a
# session whose Internet is mobile data (cell_effective "data"): on for
# the default data SIM (mobile_data_on), once the module's switch-on is
# done, the last look read the radio on, the firewall is live and the
# fail-safe holds no radio; again after each of the module's own
# mobile-data-off writes (a radio switch-on, a SIM change: CELL_DATA_ON
# back to 0). Not a radio step: no hold applies, and it never waits for
# one. The person switching mobile data off in Settings is respected until
# the module's next own write. In every other session: off at once if the
# module had switched it on (the gate was lowered), and off again whenever
# a look that did not read the radio off finds it stored on
# (cell_data_check): Internet is a choice made at Start.
cell_data_step() {
	if [ "$(cell_effective)" = data ]; then
		[ "$CELL_DATA_ON" = 0 ] || return 0
		[ "$CELL_ON_DONE" = 1 ] && [ "$CL_RADIO" = on ] && [ "${S_FW_STATE:-}" = live ] && [ -z "$RADIOS" ] ||
			return 0
		mobile_data_on || return 0
		CELL_DATA_ON=1
		log "cell: mobile data on (the session's Internet is mobile data)"
		return 0
	fi
	if [ "$CELL_DATA_ON" = 1 ]; then
		mobile_data_off
		log "cell: mobile data off (this phone's gate no longer allows it)"
	fi
	[ "$CELL_LOOKED" = "$1" ] && [ "$CL_RADIO" != off ] || return 0
	cell_data_check
}

# cell_data_check: mobile data stored on for any SIM (mobile_data or
# mobile_data<subId> = 1: the person in Settings, an app allowed to, a new
# SIM's default) is switched off again. 'settings' is native (no Java
# start), so this is cheap.
cell_data_check() {
	settings_list | grep -q -E '^mobile_data[0-9]*=1$' || return 0
	mobile_data_off
	log "cell: mobile data was switched on; off again (this session's Internet is not mobile data)"
}

# cell_step NOW: one turn of the cell radio's watch (service.sh, at every
# turn once the framework has answered).
cell_step() {
	_cs_now=$1
	# The module's files are gone (Magisk itself uninstalled while this
	# loop still runs): the stored values are uninstall.sh's from now on.
	[ -f "$SETTINGS_CONF" ] || return 0
	cell_gate_step
	# Without the time since boot every step is held (cell_hold); once it
	# can be read again, the 5 minutes start from then.
	if [ "$_cs_now" -le 0 ]; then
		CELL_CLOCKLESS=1
	elif [ "$CELL_CLOCKLESS" = 1 ]; then
		CELL_CLOCKLESS=0
		CELL_LAST=$_cs_now
		CELL_UNK_AT=$_cs_now
		[ -z "$CELL_EM_AT" ] || CELL_EM_AT=$_cs_now
	fi
	# Cheap reads at every turn; a change brings the next look forward.
	_cs_v=$(airplane_get) || _cs_v=
	if [ "$_cs_v" != "$CELL_AIR" ]; then
		if [ "$CELL_AIR" = 1 ] && [ "$_cs_v" = 0 ] && ! cell_mine "$_cs_now"; then
			CELL_LAST=$_cs_now
			CELL_UNK_AT=$_cs_now
			[ -z "$CELL_EM_AT" ] || CELL_EM_AT=$_cs_now
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
	cell_data_step "$_cs_now"
	ims_step "$_cs_now"
	cell_forget "$_cs_now"
}

# --- The module's word to Welcome (MOD11) -------------------------------------------
#
# After a look, root calls Welcome's provider:
#   content call --user 0 --uri content://org.antumbra.welcome.state \
#     --method module_word --extra v:i:1 --extra calls:s:KIND \
#     --extra at:l:AT --extra until:l:UNTIL --extra ims:s:IMS --extra ims_at:l:IMS_AT
# Welcome takes it only from uid 0 (the binder's uid, which no app can
# fake), keeps it in memory, answers "Result: Bundle[{v=1}]" and offers no
# way to read it back. AT is the look's time since boot (/proc/uptime,
# which is Welcome's elapsedRealtime clock). Nothing of it is written to a
# file, status.json, a property or the log; no other app sees root's
# command line (/proc is mounted hidepid=2).

# word_send EXTRA...: 'content call' to Welcome's provider with the
# module_word method and these --extra arguments; prints what the tool
# prints on standard output. Bounded at 10 s ('content' starts a Java
# process, about a second).
word_send() {
	$TB timeout 10 /system/bin/content call --user 0 --uri "$WORD_URI" --method "$WORD_METHOD" "$@" 2>/dev/null
}

# welcome_tell KIND AT UNTIL IMS IMS_AT: give Welcome the word. True only if
# Welcome answered exactly "Result: Bundle[{v=1}]": 'content' reports a
# refusal or a missing provider on standard error and exits 0.
welcome_tell() {
	_wt=$(word_send --extra v:i:1 --extra "calls:s:$1" --extra "at:l:$2" --extra "until:l:$3" \
		--extra "ims:s:$4" --extra "ims_at:l:$5")
	[ "$_wt" = 'Result: Bundle[{v=1}]' ]
}

# cell_tell NOW: in a turn that took a look, tell Welcome the word: when it
# changed (the first turn included, which replaces a word an earlier run
# left); after every look while it is "emergency" (its end moves on);
# after every look while it is "ordinary" outside a call (Welcome uses an
# ordinary word for 30 s only, and its process may have restarted); every
# CELL_IMS_EVERY seconds while there is an IMS reading. During a call an
# unchanged "ordinary" is not told again: Welcome waits during a call
# whatever the word says, and a word from a look before the call's end
# covers nothing; the first look after the call tells it again. While
# Welcome does not take the word (a Welcome without module_word answers
# "Result: null"), once every WORD_RETRY seconds, and at once for an
# emergency word or a word of another kind than the last try (Welcome may
# still hold an earlier word: an ordinary one counts for 30 s). Each word
# Welcome skips only makes it wait as it would without the module. Only
# while Welcome is the device owner (the authority is then Welcome's).
# Logs that telling failed and that it works again, never the word.
cell_tell() {
	_ct_now=$1
	[ "$CELL_LOOKED" = "$_ct_now" ] || return 0
	_ct_w=$(cell_word "$_ct_now")
	_ct_k=${_ct_w%% *}
	_ct_new="$_ct_w $CELL_IMS $CELL_IMS_AT"
	_ct_go=0
	if [ "$CELL_WORD_BAD" = 1 ]; then
		[ "$_ct_k" != emergency ] || _ct_go=1
		[ "$_ct_k" = "$CELL_BAD_KIND" ] || _ct_go=1
		if [ "$_ct_now" -lt "$CELL_BAD_AT" ] || [ $((_ct_now - CELL_BAD_AT)) -ge "$WORD_RETRY" ]; then
			_ct_go=1
		fi
	else
		[ "$_ct_new" = "$CELL_WORD" ] || _ct_go=1
		case $_ct_k in
		emergency) _ct_go=1 ;;
		ordinary) [ "$CL_CALL" = 1 ] || _ct_go=1 ;;
		esac
		if [ "$CELL_IMS" != off ] && { [ -z "$CELL_TOLD_AT" ] || [ $((_ct_now - CELL_TOLD_AT)) -ge "$CELL_IMS_EVERY" ]; }; then
			_ct_go=1
		fi
	fi
	[ "$_ct_go" = 1 ] || return 0
	welcome_is_owner || return 0
	if welcome_tell "$_ct_k" "$_ct_now" "${_ct_w#* }" "$CELL_IMS" "$CELL_IMS_AT"; then
		CELL_WORD=$_ct_new
		CELL_TOLD_AT=$_ct_now
		if [ "$CELL_WORD_BAD" = 1 ]; then
			CELL_WORD_BAD=0
			log "cell: Welcome takes the module's word again"
		fi
	else
		CELL_BAD_AT=$_ct_now
		CELL_BAD_KIND=$_ct_k
		if [ "$CELL_WORD_BAD" = 0 ]; then
			CELL_WORD_BAD=1
			log "cell: Welcome did not take the module's word; Quick power off waits as it would without it"
		fi
	fi
}

# --- The module's word on the cell radio to Welcome (WEL8) ---------------------------
#
# Root calls Welcome's provider, as for the word on the calls:
#   content call --user 0 --uri content://org.antumbra.welcome.state \
#     --method module_cell --extra v:i:1 --extra gate:s:GATE \
#     --extra cell:s:CELL --extra radio:s:RADIO --extra at:l:AT
# GATE is this phone's gate now (cell_gate: off, phone, data); CELL what
# the module carries out (cell_effective: none before Start, then off,
# phone or data); RADIO the radio at the last look (on, off, wait for
# unavailable, unknown) and AT that look's time since boot (0 before the
# first look). Welcome offers Phone and mobile data only as far as GATE
# allows, and shows RADIO as the cellular radio's line. Welcome takes it
# from uid 0 only and keeps it in memory; nothing of it goes into a file,
# status.json, a property or the log (none of it is about calls, but every
# app can read status.json and properties, and the SIM's state and the
# radio are the person's business).

# cell_send EXTRA...: 'content call' to Welcome's provider with the
# module_cell method; prints what the tool prints on standard output.
# Bounded at 10 s.
cell_send() {
	$TB timeout 10 /system/bin/content call --user 0 --uri "$WORD_URI" --method "$CELL_OFFER_METHOD" "$@" 2>/dev/null
}

# cell_offer_tell NOW: tell Welcome the gate, what the module carries out
# and the radio as the last look read it: when any of them changed (the
# first turn included), when Welcome's process started again before Start
# (its session_id changed: the new process holds no word), and every
# CELL_OFFER_EVERY seconds, so that Welcome can tell a live reading from an
# old one. While Welcome does not take it, again after 30 s, then after
# twice as long each time, up to CELL_OFFER_EVERY: a passing failure (a
# Java start that took longer than 10 s) costs half a minute, a Welcome
# from before WEL8 (it answers "Unknown method") one try every 5 minutes.
# The refusal and the recovery are logged once each, never the word. Only
# while Welcome is the device owner. The gate told is "off" while the
# module reads Welcome's row without the cell column (WELCOME_OLD): it
# carries out nothing above off for such a Welcome's sessions, so a newer
# Welcome must not offer more until the module reads its row with the
# column. Sets CELL_OFFER_TOLD to NOW when it tried (service.sh then checks
# the ports again).
cell_offer_tell() {
	_co_now=$1
	_co_gate=$CELL_GATE
	[ "$WELCOME_OLD" != 1 ] || _co_gate=off
	_co_cell=$(cell_effective)
	_co_at=${CELL_LOOKED:-0}
	case $_co_at in '' | *[!0-9]*) _co_at=0 ;; esac
	# Only the four words Welcome takes: anything else reads "unknown".
	_co_radio=$CL_RADIO
	case $_co_radio in on | off | wait) ;; *) _co_radio=unknown ;; esac
	_co_new="$_co_gate $_co_cell $_co_radio $_co_at"
	_co_go=0
	if [ "$CELL_OFFER_BAD" = 1 ]; then
		if [ "$_co_now" -lt "$CELL_OFFER_BAD_AT" ] || [ $((_co_now - CELL_OFFER_BAD_AT)) -ge "$CELL_OFFER_WAIT" ]; then
			_co_go=1
		fi
	else
		# A new look alone (AT) is no change: the word goes again when its
		# gate, cell or radio changed.
		[ "${_co_new% *}" = "${CELL_OFFER% *}" ] || _co_go=1
		[ "$WELCOME_SID" = "$CELL_OFFER_SID" ] || _co_go=1
		if [ -z "$CELL_OFFER_AT" ] || [ "$_co_now" -lt "$CELL_OFFER_AT" ] ||
			[ $((_co_now - CELL_OFFER_AT)) -ge "$CELL_OFFER_EVERY" ]; then
			_co_go=1
		fi
	fi
	[ "$_co_go" = 1 ] || return 0
	welcome_is_owner || return 0
	# shellcheck disable=SC2034 # read by service.sh
	CELL_OFFER_TOLD=$_co_now
	_co_out=$(cell_send --extra v:i:1 --extra "gate:s:$_co_gate" --extra "cell:s:$_co_cell" \
		--extra "radio:s:$_co_radio" --extra "at:l:$_co_at")
	if [ "$_co_out" = 'Result: Bundle[{v=1}]' ]; then
		CELL_OFFER=$_co_new
		CELL_OFFER_AT=$_co_now
		CELL_OFFER_SID=$WELCOME_SID
		if [ "$CELL_OFFER_BAD" = 1 ]; then
			CELL_OFFER_BAD=0
			log "cell: Welcome takes the module's word on the cell radio again"
		fi
	else
		CELL_OFFER_BAD_AT=$_co_now
		if [ "$CELL_OFFER_BAD" = 1 ]; then
			CELL_OFFER_WAIT=$((CELL_OFFER_WAIT * 2))
			[ "$CELL_OFFER_WAIT" -le "$CELL_OFFER_EVERY" ] || CELL_OFFER_WAIT=$CELL_OFFER_EVERY
		else
			CELL_OFFER_BAD=1
			CELL_OFFER_WAIT=$CELL_OFFER_RETRY
			log "cell: Welcome did not take the module's word on the cell radio (an older Welcome?); it offers no Phone mode then"
		fi
	fi
}

# ims_dump: the phone process's own dump (TelephonyDebugService, which
# PhoneGlobals starts with the phone process), bounded at 8 s. It is large
# (every phone, local logs): read through a pipe only.
ims_dump() {
	$TB timeout 8 /system/bin/dumpsys -t 6 activity service com.android.phone/com.android.phone.TelephonyDebugService 2>/dev/null
}

# ims_block_end: ims_state's helper, at the end of an ImsPhone block.
ims_block_end() {
	[ "$_im_in" = 1 ] || return 0
	_im_in=0
	[ "$_im_n" = 1 ] || return 1
	case $_im_st in
	0 | 1) ;;
	2)
		case $_im_last in
		WWAN) _im_b=cell ;;
		WLAN) _im_b=wifi ;;
		*) _im_b=registered ;;
		esac
		if [ -z "$_im_bear" ]; then
			_im_bear=$_im_b
		elif [ "$_im_bear" != "$_im_b" ]; then
			_im_bear=registered
		fi
		;;
	*) return 1 ;;
	esac
}

# ims_state: read ims_dump's output on standard input and print the IMS
# (VoLTE) registration: "cell" (registered over the cell network, WWAN),
# "wifi" (over Wi-Fi, WLAN: Wi-Fi calling), "registered" (the bearer not
# known, or two phones on different ones) or "none" (no phone registered).
# Returns 1 unless there is at least one "ImsPhone:" block and each has
# exactly one "mImsMmTelRegistrationState = 0|1|2" (not registered,
# registering, registered; Android 17's emergency registration line is
# another key and is not read). The bearer is that of the block's last
# handleIms... line in its Registration Log.
ims_state() {
	_im_in=0
	_im_blocks=0
	_im_bear=
	while IFS= read -r _im_l; do
		_im_l=${_im_l#"${_im_l%%[! ]*}"}
		case $_im_l in
		ImsPhone:)
			ims_block_end || return 1
			_im_in=1
			_im_blocks=$((_im_blocks + 1))
			_im_n=0
			_im_st=
			_im_last=
			;;
		'++++'*) ims_block_end || return 1 ;;
		'mImsMmTelRegistrationState = '*)
			[ "$_im_in" = 1 ] || return 1
			_im_n=$((_im_n + 1))
			_im_st=${_im_l#*= }
			;;
		*'handleImsRegistered: '*'imsTransportType='*)
			[ "$_im_in" = 0 ] || _im_last=${_im_l##*imsTransportType=}
			;;
		*'handleImsRegistering: '* | *'handleImsUnregistered: '*)
			[ "$_im_in" = 0 ] || _im_last=-
			;;
		esac
	done
	ims_block_end || return 1
	[ "$_im_blocks" -gt 0 ] || return 1
	echo "${_im_bear:-none}"
}

# ims_step NOW: the IMS registration for Welcome (WEL8's VoLTE line). In a
# Phone-mode session only, after a look taken in this turn, once the
# module's switch-on is done, with the radio on and nothing holding it (no
# heavy dump of the phone process during a call, callback mode or the 5
# minutes after), at most every CELL_IMS_EVERY seconds; an unreadable dump
# gives "unknown". Outside Phone mode (cell_effective neither "phone" nor
# "data": before Start, Phone off, or a gate that does not allow it) "off".
ims_step() {
	case $(cell_effective) in
	phone | data) ;;
	*)
		CELL_IMS=off
		CELL_IMS_AT=0
		return 0
		;;
	esac
	[ "$CELL_LOOKED" = "$1" ] && [ "$CELL_ON_DONE" = 1 ] && [ "$CL_RADIO" = on ] || return 0
	[ "$1" -ge "$CELL_IMS_NEXT" ] || return 0
	! cell_hold "$1" >/dev/null || return 0
	CELL_IMS_NEXT=$(($1 + CELL_IMS_EVERY))
	CELL_IMS=$(ims_dump | ims_state) || CELL_IMS=unknown
	CELL_IMS_AT=$1
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
# bridges (tor.error can say so, when bridges were refused), and nothing
# about calls, callback mode or IMS registration (the cell radio's holds
# and the module's word to Welcome stay out of it).
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
