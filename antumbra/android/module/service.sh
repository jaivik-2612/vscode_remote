#!/system/bin/sh
# shellcheck source-path=SCRIPTDIR
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Antumbra module: the late_start service stage.
#
# Magisk (and KernelSU) start this script without waiting for it, while
# Android finishes booting. It keeps running until shutdown and looks
# after tor, the DNS filter and the firewall.
#
# Order (shared contract):
#   1. the DNS filter as uid 2951 (first, so that it holds 127.0.0.1:5335
#      before an app can take the port);
#   2. tor as uid 2950, with the network off (DisableNetwork 1);
#   3. 'antumbra-fw apply', checked with 'status' and with who holds the
#      service ports; only then 'resetprop -n antumbra.fw.armed <hash
#      prefix>';
#   4. run/status.json;
#   5. IPv6 off on every interface, again whenever NetworkStack switches it
#      on;
#   6. once boot has completed: the fail-safe Settings, mobile data off;
#      then, at every turn, the cell radio's watch (lib/antumbra.sh, "The
#      cell radio"): enable_cellular_on_boot and mobile_data_always_on 0,
#      airplane mode's radio list narrowed to the cell radio once airplane
#      mode has read off for 30 seconds, and the cell radio switched off
#      (airplane mode) whenever something switched it on, unless a call,
#      emergency callback mode or a call in the last 5 minutes holds it
#      (enable_cellular_on_boot is kept at 1 while that hold lasts);
#   7. wait for the Welcome screen's Start (started=1 in its provider, and
#      Welcome the device owner): offline keeps tor's network off; direct
#      and bridges set the bridges, if any, and DisableNetwork 0 over tor's
#      control socket, once the firewall is live and no other uid holds a
#      service port; a session in Phone mode (WEL8; none yet) has the cell
#      radio switched on at Start, mobile data off first;
#   8. then, until shutdown: at every turn, check who holds 9040, 9053,
#      5335 and 5380 and go back to the armed state while another uid
#      does; restart tor or the filter if they stop; check the firewall
#      every 30 seconds and reload it if it is not live; keep status.json
#      up to date; after any radio switch-on, mobile data off again, and
#      enable_cellular_on_boot 0 again once no hold lasts; at shutdown, put
#      the fail-safe Settings back and store airplane mode off for the next
#      start (unless a call holds it).
#
# Schedules use the time since boot (/proc/uptime), never the clock.

umask 022
MODDIR=${0%/*}
LOG_TAG=service
# shellcheck source=lib/antumbra.sh
. "$MODDIR/lib/antumbra.sh"

# Status shown in run/status.json (status_write).
S_VERSION=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)
S_PROBLEM=
S_NOW_PROBLEM=
S_FW_STATE=armed
S_FW_HASH=
S_TOR_RUNNING=0
S_TOR_NETWORK=disabled
S_TOR_BOOTSTRAP=
S_TOR_SUMMARY=
S_TOR_ERROR=
S_DNS_RUNNING=0
S_STARTED=0

# The session, once read from Welcome (session_read).
SES_MODE=
SES_MAC=
SES_KIND=
# off, or phone (calls and texts: the cell radio on after Start, mobile data
# off); session_cell decides it.
SES_CELL=off
# pending: the network is to be opened when tor and the firewall are ready;
# open: opened (or nothing to do: offline); failed: this session's bridges
# cannot work.
SES_NET=
# Current problems, joined into S_NOW_PROBLEM for status.json (with
# P_CELL, which cell_step keeps).
P_PORTS=
P_WELCOME=
# wanted: the firewall could not even be armed, so Wi-Fi and mobile data
# off as soon as the framework answers; waiting: done, and the cell radio
# and Bluetooth go off as soon as no call holds them; switched: all done.
RADIOS=

# --- 0. The runtime directory and a single copy of this script --------------

if ! runtime_ready; then
	# post-fs-data.sh did not run (it timed out, or the module was enabled
	# without a reboot). Close the network now and carry on, but say so:
	# saved Wi-Fi networks and the DHCP memory are not protected this boot.
	mkdir -p "$ARMDIR"
	ANTUMBRA_DIR=$ARMDIR "$BIN/antumbra-fw" arm >/dev/null 2>&1
	runtime_setup || {
		echo "antumbra: cannot set up $ANTUMBRA_DIR" >&2
		exit 1
	}
	chmod 0711 /data/adb
	S_PROBLEM="post-fs-data did not run in this boot"
	log "PROBLEM: $S_PROBLEM"
fi
_p=$(read_value "$PRIV/problem")
[ -n "$_p" ] && S_PROBLEM=${S_PROBLEM:+$S_PROBLEM; }$_p

if ! mkdir "$PRIV/service.lock" 2>/dev/null; then
	_other=$(read_value "$PRIV/service.lock/pid")
	if [ -n "$_other" ] && kill -0 "$_other" 2>/dev/null; then
		log "already running (pid $_other)"
		exit 0
	fi
fi
echo $$ >"$PRIV/service.lock/pid"
log "starting (module ${S_VERSION:-unknown})"

# --- Pieces of the loop below ----------------------------------------------------

# refresh_tor [ask]: update S_TOR_RUNNING; with "ask", also ask tor for
# its bootstrap progress (S_TOR_BOOTSTRAP, S_TOR_SUMMARY). Returns 1 if tor
# is not running.
refresh_tor() {
	if ! pid_alive "$PRIV/tor.pid" "$TOR_UID"; then
		S_TOR_RUNNING=0
		S_TOR_BOOTSTRAP=
		S_TOR_SUMMARY=
		return 1
	fi
	S_TOR_RUNNING=1
	if [ "${1-}" = ask ] && _rt=$(tor_bootstrap); then
		S_TOR_BOOTSTRAP=${_rt%%	*}
		S_TOR_SUMMARY=${_rt#*	}
	fi
	return 0
}

# firewall_closed: the full rule set is not live (taken back, or it could
# not be loaded). S_FW_STATE becomes "failed" if the arm set is in place
# (or a partial set: its egress gates let out nothing but what they mark).
# Otherwise one more 'flush' (back to armed); if even that leaves the
# network open, S_FW_STATE becomes "open" and Wi-Fi and mobile data go
# off as soon as the framework answers, the cell radio and Bluetooth when
# no call holds them (the second line of defence).
firewall_closed() {
	S_FW_HASH=
	case $(fw_state) in
	armed | partial)
		S_FW_STATE=failed
		return 0
		;;
	esac
	fw flush >/dev/null 2>>"$LOGDIR/firewall.log"
	case $(fw_state) in
	armed | partial)
		S_FW_STATE=failed
		return 0
		;;
	esac
	[ "$S_FW_STATE" = open ] ||
		log "firewall: OPEN: not even the arm set could be loaded; the radios go off"
	S_FW_STATE=open
	case $RADIOS in waiting | switched) ;; *) RADIOS=wanted ;; esac
	return 1
}

# firewall_up: load and publish the full rule set (fw_publish).
firewall_up() {
	if S_FW_HASH=$(fw_publish); then
		S_FW_STATE=live
		log "firewall: live, antumbra.fw.armed=$S_FW_HASH"
		return 0
	fi
	firewall_closed
	return 1
}

# apply_settings: the fail-safe Settings.Global values (lib/settings.conf,
# which gives the reason for each; among them the cell radio's
# enable_cellular_on_boot=0), mobile data off for every SIM, and Wi-Fi
# scanning for location off now, in Wi-Fi's own store (in RAM); the
# Settings value is what Wi-Fi copies at the next boot.
apply_settings() {
	_as_bad=$(settings_apply)
	mobile_data_off
	/system/bin/cmd wifi set-scan-always-available disabled >/dev/null 2>&1
	if [ -n "$_as_bad" ]; then
		log "settings: could not set:$_as_bad"
	else
		log "settings: fail-safe values set"
	fi
}

# shutdown_check: once Android has begun to shut down
# (sys.shutdown.requested, set by ShutdownThread before anything else),
# put the fail-safe Settings back, so that a start without the module
# finds them: a new MAC address for every connection even after a "keep"
# session, mobile data off even if it was switched on in this session, and
# the cell radio off at the next start (enable_cellular_on_boot=0, also
# when the watch kept it at 1 for a hold: a restart is a new power-on, the
# phone process is not restarted before it, and an emergency call still
# switches the radio on at the next start). Then,
# if airplane mode is on (the module's run-time switch-off), store it off
# and cell_on=1 without a broadcast, unless a call holds it (cell_shutdown):
# the next start then has the radio off and Wi-Fi under Welcome's control.
# Best effort: the framework may be gone before this runs, and a crash or
# a forced power-off skips it. Returns 0 if Android is shutting down.
SHUTDOWN_DONE=0
shutdown_check() {
	[ "$SHUTDOWN_DONE" = 0 ] || return 0
	[ -n "$(getprop sys.shutdown.requested 2>/dev/null)" ] || return 1
	SHUTDOWN_DONE=1
	settings_apply >/dev/null
	mobile_data_off
	log "shutdown: fail-safe Settings put back"
	[ "$SETTINGS_DONE" = 1 ] && cell_shutdown "$(uptime_s)"
	return 0
}

# nap SECONDS: sleep, a second at a time, watching for shutdown.
nap() {
	_np=$1
	while [ "$_np" -gt 0 ]; do
		sleep 1
		_np=$((_np - 1))
		[ "$SHUTDOWN_DONE" = 0 ] && shutdown_check && return 0
	done
}

# session_cell ROW: the session's choice for the cell radio: "off", or
# "phone" (calls and texts: the radio on after Start, mobile data off).
# Welcome's row has no such column yet: WEL8 adds "cell" to the shared
# contract (design section 3, Welcome's StateProvider, session_read's
# projection and the e2e tests, changed together) and reads it here, with
# a check of its value. Until then every session keeps the cell radio off.
# This is the only place that decides it.
session_cell() { echo off; }

# session_read: read Welcome's row. Returns 0 once started=1 has been read
# with valid values from Welcome as the device owner, and keeps that
# session (SES_*) for the rest of the boot: Welcome starts a new, unstarted
# session if its process dies, and that must not change what was chosen.
session_read() {
	_sr_row=$(welcome_query started:tor_mode:mac:session_id) || return 1
	[ "$(row_get "$_sr_row" started)" = 1 ] || return 1
	_sr_mode=$(row_get "$_sr_row" tor_mode)
	_sr_mac=$(row_get "$_sr_row" mac)
	_sr_sid=$(row_get "$_sr_row" session_id)
	_sr_bad=
	case $_sr_mode in direct | bridges | offline) ;; *) _sr_bad=tor_mode ;; esac
	case $_sr_mac in new | keep) ;; *) _sr_bad=mac ;; esac
	case $_sr_sid in '' | *[!0-9a-f]*) _sr_bad=session_id ;; esac
	[ "${#_sr_sid}" -ge 8 ] && [ "${#_sr_sid}" -le 64 ] || _sr_bad=session_id
	if [ -n "$_sr_bad" ]; then
		log "welcome: the row has an invalid $_sr_bad; still waiting"
		return 1
	fi
	# Only Welcome's answer counts, and Welcome's only while it is the
	# device owner (welcome_is_owner).
	if ! welcome_is_owner; then
		if [ -z "$P_WELCOME" ]; then
			P_WELCOME="$WELCOME_PKG is not the device owner: Start is not trusted"
			log "welcome: $P_WELCOME; still waiting"
		fi
		return 1
	fi
	P_WELCOME=
	SES_KIND=
	if [ "$_sr_mode" = bridges ]; then
		# One query for the bridges, with the session ID in front: the
		# bridge lines are the rest of the output, and the ID shows that
		# they belong to the session read above.
		welcome_query session_id:bridges >"$PRIV/bridges.raw" || return 1
		_sr_pre="Row: 0 session_id=$_sr_sid, bridges="
		if [ "$(head -n 1 "$PRIV/bridges.raw" | cut -c1-${#_sr_pre})" != "$_sr_pre" ]; then
			log "welcome: the bridges row is not for this session; still waiting"
			return 1
		fi
		sed "1s/^Row: 0 session_id=$_sr_sid, bridges=//" "$PRIV/bridges.raw" >"$PRIV/bridges"
		rm -f "$PRIV/bridges.raw"
		if ! SES_KIND=$(bridges_check "$PRIV/bridges"); then
			S_TOR_ERROR="bridges refused: $SES_KIND"
			log "welcome: $S_TOR_ERROR"
			SES_KIND=bad
		fi
	fi
	SES_MODE=$_sr_mode
	SES_MAC=$_sr_mac
	SES_CELL=$(session_cell "$_sr_row")
	S_STARTED=1
	# The session record stays in the root-only state directory; status.json,
	# which every app can read, says only that a session started.
	printf 'session_id=%s\ntor_mode=%s\nmac=%s\ncell=%s\n' "$_sr_sid" "$SES_MODE" "$SES_MAC" "$SES_CELL" \
		>"$PRIV/session"
	chmod 0600 "$PRIV/session"
	log "welcome: session started (tor $SES_MODE, MAC $SES_MAC, cell radio $SES_CELL)"
	return 0
}

# session_network: carry out the session's tor choice. Called when the
# session starts, and again at every turn while it is pending (tor
# restarted, the firewall not live, a service port taken).
session_network() {
	case $SES_MODE in
	offline)
		SES_NET=open
		S_TOR_NETWORK=disabled
		log "tor: offline session; the network stays off"
		return 0
		;;
	esac
	if [ "$SES_KIND" = bad ]; then
		SES_NET=failed
		return 1
	fi
	if [ "$SES_KIND" = pt ] && [ ! -x "$BIN/lyrebird" ]; then
		SES_NET=failed
		S_TOR_ERROR="these bridges need pluggable transports, which this module does not include"
		log "tor: $S_TOR_ERROR"
		return 1
	fi
	# Only over a live firewall, and only while no other uid holds tor's
	# ports (tor could not bind them, and the squatter would get the
	# traffic); until then tor keeps the network off.
	if [ "$S_FW_STATE" != live ] || ! listeners_ok || ! tor_ready; then
		SES_NET=pending
		return 1
	fi
	_sn_cmd='SETCONF'
	if [ "$SES_MODE" = bridges ]; then
		_sn_cmd="$_sn_cmd UseBridges=1"
		if [ "$SES_KIND" = pt ]; then
			_sn_cmd="$_sn_cmd ClientTransportPlugin=\"meek_lite,obfs4,webtunnel exec $BIN/lyrebird\""
		fi
		while IFS= read -r _sn_line || [ -n "$_sn_line" ]; do
			[ -n "$_sn_line" ] && _sn_cmd="$_sn_cmd Bridge=\"$_sn_line\""
		done <"$PRIV/bridges"
	fi
	_sn_cmd="$_sn_cmd DisableNetwork=0"
	_sn_out=$(printf '%s\r\n' "$_sn_cmd" | torctl)
	if torctl_ok "$_sn_out" 1; then
		SES_NET=open
		S_TOR_NETWORK=enabled
		S_TOR_ERROR=
		log "tor: network on ($SES_MODE)"
		return 0
	fi
	# tor refused the whole SETCONF (55x: an option or value it cannot
	# use): nothing changed, the network stays off, and sending the same
	# settings again cannot help, so this session's network has failed,
	# unless tor could not bind a listener port (553 "Failed to bind"),
	# which works once the port is free. Any other failure (no answer, the
	# control socket gone while tor restarts) is tried again. tor's reason
	# is shown without quoted values, so it names no bridge.
	_sn_err=$(printf '%s\n' "$_sn_out" | tr -d '\r' | sed -n 's/^5[0-9][0-9][ -]//p' | head -n 1 |
		sed 's/"[^"]*"//g' | cut -c1-100)
	if printf '%s\n' "$_sn_out" | tr -d '\r' | grep -q '^55[0-9][ -]' &&
		! printf '%s\n' "$_sn_out" | grep -q -i 'bind'; then
		SES_NET=failed
	else
		SES_NET=pending
	fi
	_sn_err=${_sn_err:-tor did not answer}
	if [ "$_sn_err" != "$S_TOR_ERROR" ]; then
		S_TOR_ERROR=$_sn_err
		log "tor: could not switch the network on: $S_TOR_ERROR"
	fi
	return 1
}

# ports_check: who holds the service ports. While another uid holds one,
# the property goes, the firewall goes back to armed (no redirect: the
# squatter is sent nothing), and tor's network is not switched on; once
# the ports are free, the full rule set is loaded again at once (FW_NEXT).
ports_check() {
	if listeners_ok; then
		if [ -n "$PORTS_LOGGED" ]; then
			log "ports: free again"
			PORTS_LOGGED=
			FW_NEXT=0
		fi
		P_PORTS=
	else
		P_PORTS="service port taken: $PORTS_BAD"
		if [ "$PORTS_BAD" != "$PORTS_LOGGED" ]; then
			log "ports: $PORTS_BAD"
			PORTS_LOGGED=$PORTS_BAD
		fi
		if [ "$S_FW_STATE" = live ]; then
			fw_unpublish "$PORTS_BAD"
			firewall_closed
		fi
	fi
}

# ipv6_guard: switch IPv6 off at once whenever an interface or address
# changes (ip monitor), and every 10 seconds in any case.
ipv6_guard() {
	ipv6_sweep
	if [ -x /system/bin/ip ]; then
		/system/bin/ip -o monitor link address 2>/dev/null | while read -r _ig_line; do
			ipv6_sweep
		done &
	fi
	while :; do
		sleep 10
		ipv6_sweep
	done
}

# --- 1-5. Filter, tor, firewall, status, IPv6 ---------------------------------------

# What post-fs-data.sh left: armed, unless arming failed.
_st=$(fw_state)
case $_st in
armed) S_FW_STATE=armed ;;
live | partial)
	S_FW_STATE=armed
	log "firewall: '$_st' at start; loading the full rule set again"
	;;
*)
	S_FW_STATE=open
	log "firewall: OPEN at start (state '$_st'): the arm set is not in place"
	;;
esac

start_dnsfilter
start_tor
firewall_up || log "firewall: the network stays closed; trying again every 30 seconds"
# A port taken already: the loop loads the rule set as soon as it is free.
PORTS_LOGGED=
listeners_ok || PORTS_LOGGED=$PORTS_BAD
sleep 1
pid_alive "$PRIV/dnsfilter.pid" "$DNS_UID" && S_DNS_RUNNING=1
refresh_tor
status_write
ipv6_guard </dev/null >/dev/null 2>&1 &

# --- 6-8. The loop ------------------------------------------------------------------------
#
# Every 2 seconds while something is changing (before Start, while tor's
# network waits to be switched on, while tor connects, while a program is
# down, while a port is taken), else every 5. Welcome's provider is asked
# every 2 seconds for the first 3 minutes after the framework answers,
# then every 5 ('content' starts a Java process each time).

SETTINGS_DONE=0
SETTINGS_AT=0
TOR_FAILS=0
DNS_FAILS=0
TOR_NEXT=0
DNS_NEXT=0
ASK_NEXT=0
WELCOME_NEXT=0
FW_NEXT=$(($(uptime_s) + 30))
while :; do
	NOW=$(uptime_s)
	shutdown_check

	# 8a. Who holds the service ports, at every turn (ports_check).
	ports_check

	# 8b. The firewall, every 30 seconds (and at once when the ports are
	# free again). If it is no longer live, the property goes at once, then
	# the rule set is loaded again ('apply' arms first, so nothing leaves
	# meanwhile). If that fails, it stays armed and is tried again 30
	# seconds later. While a port is taken, only that it is still armed is
	# checked.
	if [ "$NOW" -ge "$FW_NEXT" ]; then
		FW_NEXT=$((NOW + 30))
		if [ -n "$P_PORTS" ]; then
			firewall_closed
		elif [ "$S_FW_STATE" = live ]; then
			_st=$(fw status 2>/dev/null)
			_rc=$?
			_live=$(printf '%s\n' "$_st" | sed -n 's/^hash=//p' | cut -c1-16)
			if [ "$_rc" -ne 0 ] || [ "$_live" != "$S_FW_HASH" ]; then
				prop_clear "$FW_PROP"
				log "firewall: no longer live (status $_rc); loading it again"
				firewall_up
			fi
		else
			firewall_up
		fi
	fi

	# 6. Settings, once the framework answers.
	if [ "$SETTINGS_DONE" = 0 ] && framework_ready; then
		apply_settings
		SETTINGS_DONE=1
		SETTINGS_AT=$NOW
	fi

	# 7. The Welcome screen, until Start.
	if [ "$SETTINGS_DONE" = 1 ] && [ "$S_STARTED" = 0 ]; then
		if [ "$NOW" -ge "$WELCOME_NEXT" ]; then
			if [ $((NOW - SETTINGS_AT)) -lt 180 ]; then
				WELCOME_NEXT=$((NOW + 2))
			else
				WELCOME_NEXT=$((NOW + 5))
			fi
			if session_read; then
				if [ "$SES_MAC" = keep ]; then
					settings_put non_persistent_mac_randomization_force_enabled 0
				fi
				session_network
			fi
		fi
	elif [ "$S_STARTED" = 1 ] && [ "$SES_NET" = pending ]; then
		session_network
	fi

	# 6 (continued). The cell radio's watch, and the radios if the firewall
	# is open: after Start has been read, so that a Phone-mode session's
	# switch-on follows it in the same turn. It ends when Android begins to
	# shut down (shutdown_check has stored what the next start needs). A
	# turn in which it looked (two dumps, up to 8 s) checks the ports again
	# at once, so that the look's time is not added to the next turn's wait.
	if [ "$SETTINGS_DONE" = 1 ] && [ "$SHUTDOWN_DONE" = 0 ]; then
		cell_step "$NOW"
		[ "$CELL_LOOKED" = "$NOW" ] && ports_check
	fi

	# 8c. The DNS filter, restarted after a pause that doubles from 2 to 64
	# seconds. DNS fails (closed) while it is down.
	if pid_alive "$PRIV/dnsfilter.pid" "$DNS_UID"; then
		S_DNS_RUNNING=1
		DNS_FAILS=0
	else
		S_DNS_RUNNING=0
		if [ "$NOW" -ge "$DNS_NEXT" ]; then
			[ "$DNS_FAILS" -lt 6 ] && DNS_FAILS=$((DNS_FAILS + 1))
			DNS_NEXT=$((NOW + (1 << DNS_FAILS)))
			log "dnsfilter: not running; restarting"
			start_dnsfilter
		fi
	fi

	# 8d. tor, restarted the same way. A new tor starts with the network
	# off, and the session's choice is applied to it again. Its progress is
	# asked at every turn while it connects, else every 30 seconds.
	_ask=
	if { [ "$S_TOR_NETWORK" = enabled ] && [ "${S_TOR_BOOTSTRAP:-0}" != 100 ]; } || [ "$NOW" -ge "$ASK_NEXT" ]; then
		_ask=ask
		ASK_NEXT=$((NOW + 30))
	fi
	if refresh_tor "$_ask"; then
		TOR_FAILS=0
	else
		S_TOR_NETWORK=disabled
		if [ "$NOW" -ge "$TOR_NEXT" ]; then
			[ "$TOR_FAILS" -lt 6 ] && TOR_FAILS=$((TOR_FAILS + 1))
			TOR_NEXT=$((NOW + (1 << TOR_FAILS)))
			log "tor: not running; restarting"
			start_tor
			[ "$S_STARTED" = 1 ] && [ "$SES_NET" != failed ] && SES_NET=pending
		fi
	fi

	S_NOW_PROBLEM=$P_PORTS
	[ -z "$P_WELCOME" ] || S_NOW_PROBLEM=${S_NOW_PROBLEM:+$S_NOW_PROBLEM; }$P_WELCOME
	[ -z "$P_CELL" ] || S_NOW_PROBLEM=${S_NOW_PROBLEM:+$S_NOW_PROBLEM; }$P_CELL
	status_write
	if [ "$S_STARTED" = 0 ] || [ "$SES_NET" = pending ] || [ "$S_FW_STATE" != live ] ||
		[ "$S_TOR_RUNNING" = 0 ] || [ "$S_DNS_RUNNING" = 0 ] || [ -n "$P_PORTS" ] ||
		{ [ "$S_TOR_NETWORK" = enabled ] && [ "${S_TOR_BOOTSTRAP:-0}" != 100 ]; }; then
		nap 2
	else
		nap 5
	fi
done
