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
#   1. the DNS filter as uid 2951 (first, so that it holds 127.0.0.1:5353
#      before Android's mDNS can take the port);
#   2. tor as uid 2950, with the network off (DisableNetwork 1);
#   3. 'antumbra-fw apply', checked with 'status'; only then
#      'resetprop -n antumbra.fw.armed <hash prefix>';
#   4. run/status.json;
#   5. IPv6 off on every interface, again whenever NetworkStack switches it
#      on;
#   6. once boot has completed: the fail-safe Settings;
#   7. wait for the Welcome screen's Start (started=1 in its provider):
#      offline keeps tor's network off; direct and bridges set the bridges,
#      if any, and DisableNetwork 0 over tor's control socket;
#   8. then, until shutdown: restart tor or the filter if they stop, check
#      the firewall every 30 seconds and reload it if it is not live, and
#      keep status.json up to date.

MODDIR=${0%/*}
LOG_TAG=service
# shellcheck source=lib/antumbra.sh
. "$MODDIR/lib/antumbra.sh"

# Status shown in run/status.json (status_write).
S_VERSION=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)
S_PROBLEM=
S_FW_STATE=armed
S_FW_HASH=
S_TOR_RUNNING=0
S_TOR_MODE=pending
S_TOR_NETWORK=disabled
S_TOR_BOOTSTRAP=
S_TOR_SUMMARY=
S_TOR_ERROR=
S_DNS_RUNNING=0
S_STARTED=0
S_SESSION_ID=

# The session, once read from Welcome (session_read).
SES_MODE=
SES_MAC=
SES_KIND=
# pending: the network is to be opened when tor and the firewall are ready;
# open: opened (or nothing to do: offline); failed: this session's bridges
# cannot work.
SES_NET=

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

# firewall_up: load and publish the full rule set (fw_publish).
firewall_up() {
	if S_FW_HASH=$(fw_publish); then
		S_FW_STATE=live
		log "firewall: live, antumbra.fw.armed=$S_FW_HASH"
		return 0
	fi
	S_FW_STATE=failed
	S_FW_HASH=
	return 1
}

# apply_settings: the fail-safe Settings.Global values (lib/settings.conf,
# which gives the reason for each), and Wi-Fi scanning for location off
# now, in Wi-Fi's own store (in RAM); the Settings value is what Wi-Fi
# copies at the next boot.
apply_settings() {
	_as_bad=$(settings_apply)
	/system/bin/cmd wifi set-scan-always-available disabled >/dev/null 2>&1
	if [ -n "$_as_bad" ]; then
		log "settings: could not set:$_as_bad"
	else
		log "settings: fail-safe values set"
	fi
}

# session_read: read Welcome's row. Returns 0 once started=1 has been read
# with valid values, and keeps that session (SES_*) for the rest of the
# boot: Welcome starts a new, unstarted session if its process dies, and
# that must not change what was chosen.
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
	S_STARTED=1
	S_SESSION_ID=$_sr_sid
	S_TOR_MODE=$_sr_mode
	log "welcome: session started (tor $SES_MODE, MAC $SES_MAC)"
	return 0
}

# session_network: carry out the session's tor choice. Called when the
# session starts and again whenever tor has been restarted.
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
	# Only over a live firewall; until then tor keeps the network off.
	if [ "$S_FW_STATE" != live ] || ! tor_ready; then
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
	# settings again cannot help, so this session's network has failed. Any
	# other failure (no answer, the control socket gone while tor restarts)
	# is tried again. tor's reason is shown without quoted values, so it
	# names no bridge.
	_sn_err=$(printf '%s\n' "$_sn_out" | tr -d '\r' | sed -n 's/^5[0-9][0-9][ -]//p' | head -n 1 |
		sed 's/"[^"]*"//g' | cut -c1-100)
	if printf '%s\n' "$_sn_out" | tr -d '\r' | grep -q '^55[0-9][ -]'; then
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

start_dnsfilter
start_tor
firewall_up || log "firewall: the network stays closed; trying again every 30 seconds"
sleep 1
pid_alive "$PRIV/dnsfilter.pid" "$DNS_UID" && S_DNS_RUNNING=1
refresh_tor
status_write
ipv6_guard </dev/null >/dev/null 2>&1 &

# --- 6-8. The loop ------------------------------------------------------------------------
#
# Every 2 seconds while something is changing (before Start, while tor's
# network waits to be switched on, while tor connects, while a program is
# down), else every 5. Schedules are in seconds of the clock.

SETTINGS_DONE=0
TOR_FAILS=0
DNS_FAILS=0
TOR_NEXT=0
DNS_NEXT=0
ASK_NEXT=0
FW_NEXT=$(($(date +%s) + 30))
while :; do
	NOW=$(date +%s)

	# 6. Settings, once the framework answers.
	if [ "$SETTINGS_DONE" = 0 ] && framework_ready; then
		apply_settings
		SETTINGS_DONE=1
	fi

	# 7. The Welcome screen, until Start.
	if [ "$SETTINGS_DONE" = 1 ] && [ "$S_STARTED" = 0 ] && session_read; then
		if [ "$SES_MAC" = keep ]; then
			settings_put non_persistent_mac_randomization_force_enabled 0
		fi
		session_network
	elif [ "$S_STARTED" = 1 ] && [ "$SES_NET" = pending ]; then
		session_network
	fi

	# 8a. The DNS filter, restarted after a pause that doubles from 2 to 64
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

	# 8b. tor, restarted the same way. A new tor starts with the network
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

	# 8c. The firewall, every 30 seconds. If it is no longer live, the
	# property goes at once, then the rule set is loaded again ('apply'
	# arms first, so nothing leaves meanwhile). If that fails, it stays
	# armed and is tried again 30 seconds later.
	if [ "$NOW" -ge "$FW_NEXT" ]; then
		FW_NEXT=$((NOW + 30))
		if [ "$S_FW_STATE" = live ]; then
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

	status_write
	if [ "$S_STARTED" = 0 ] || [ "$SES_NET" = pending ] || [ "$S_FW_STATE" != live ] ||
		[ "$S_TOR_RUNNING" = 0 ] || [ "$S_DNS_RUNNING" = 0 ] ||
		{ [ "$S_TOR_NETWORK" = enabled ] && [ "${S_TOR_BOOTSTRAP:-0}" != 100 ]; }; then
		sleep 2
	else
		sleep 5
	fi
done
