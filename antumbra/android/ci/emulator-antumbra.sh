#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Antumbra CI: the ANTUMBRA scenario. A fresh Android 16 emulator, the
# Antumbra module installed and started the way build-module.sh --emulator
# does it, the Welcome app as device owner and home screen, a default
# session (Administration off) started with "Start Antumbra", the phone on
# Wi-Fi only, tor, a tracker lookup, probes, and the firewall's armed state
# with the network up.
#
# Runs inside reactivecircus/android-emulator-runner, which has started the
# emulator with '-tcpdump <file>' (its first network card, eth0) and waited
# for sys.boot_completed. Steps:
#   1. adb root; device facts; tcpdump inside the guest on every interface
#      (lib/common.sh, guest_capture_start: Wi-Fi leaves by a path the
#      emulator's capture does not see); a clock marker for the leak
#      analyser.
#   2. Airplane mode on and wait until Android has no network. Plain
#      Android's own traffic stops here, so nothing is sent close to the
#      moment the firewall is armed.
#   3. The DNS filter's query log switched on for this run
#      (debug.antumbra.log_queries=1, which the module honours on the
#      emulator only). Event "install_start", then build-module.sh
#      --emulator --zip with the module zip itself: it installs the module,
#      stops the framework, runs post-fs-data.sh ('antumbra-fw arm' first),
#      starts the framework and service.sh, and waits until
#      antumbra.fw.armed is set. The property must be the first 16 hex
#      digits of the live rule set's hash. The leak analyser counts every
#      packet from install_start on (the arm cutoff is earlier than the real
#      'arm', never later), and checks the device's clock, read once more
#      here, against the marker. tor's STREAM events are recorded from here
#      on.
#   4. Airplane mode off and mobile data off: the phone has no SIM, so its
#      only network is Wi-Fi, which has no saved network yet.
#   5. The Welcome APK; the debug build's test hook debug.antumbra.keep_adb=1
#      (Welcome then leaves USB debugging on; see welcome/README.md, "Test
#      hook"); 'dpm set-device-owner'; Welcome as the home app.
#   6. Before Start, emergency calls from Welcome's lock task (check
#      welcome_emergency_dialer): the emergency dialer opens from Welcome's
#      button and in a task of its own, and Back returns to Welcome, still
#      locked. Nothing is dialled. Then the power menu in the lock task
#      (check welcome_power_menu_emergency, WEL12): opened with a long
#      press on power, an item labelled Emergency found in it while the
#      emergency affordance is off (so it is the item that opens the dial
#      pad), never pressed; the menu closed and the long-press setting put
#      back; a warning until it has passed on CI once. Then WEL10's emergency
#      card (welcome_emergency_card: Android's own number from its list and
#      the radio-off line, read against the device;
#      welcome_emergency_states: each state's text through the debug build's
#      hook debug.antumbra.emergency_states, a screenshot of each) and Show
#      my position with the shell's test provider (welcome_position: the fix
#      on screen in large type, Location off after it, nothing kept;
#      welcome_position_secure, _gnss_only and _leave), then with the
#      emulator's own receiver if time is left (welcome_position_gnss); 7
#      minutes for the checks and 2 to undo one that fails, warnings until
#      they have passed on CI once. Then WEL8's two
#      choices at Start, walked at each level of the Phone-mode gate (the
#      root-only file /data/adb/antumbra-cell, written as root as the
#      install's PH3 step writes it on the phone: none, "phone", "data"):
#      welcome-adb.sh check-choices taps the six attempts (Internet Wi-Fi,
#      mobile data, none; Phone off, calls and texts) and reads the whole
#      page after each (checks welcome_choices_gate_off, _phone, _data, and
#      welcome_radio_line; warnings until they have passed on CI once). Then
#      the choices for the run, the gate at "phone", each row found by its
#      test tag alone (never by a text, which another row's detail may
#      hold) from the top of the page and read back checked: Internet
#      Wi-Fi and Tor directly (the run stops if they cannot be chosen),
#      Phone: calls and texts (the radio on all run, mobile data off; Phone
#      off if Welcome does not offer it within 60 s, welcome_phone_start, a
#      warning; the provider's row after Start says which), new Wi-Fi address on,
#      Administration OFF (the default session), Unsafe Browser off. Then
#      "Start Antumbra". adb must still answer; the provider row must say
#      started=1, tor_mode=direct and its cell.
#   7. Wi-Fi joined as a person would ('cmd wifi connect-network AndroidWifi
#      open'); Wi-Fi must become the default network. Welcome's policies and
#      its status screen are checked with welcome/ci/welcome-adb.sh. Then
#      MOD11: Welcome's provider takes the module's word from root only
#      (welcome-adb.sh check-module-word; only "none" and malformed words
#      are sent; a failure since run 20), and the module's parsers read the
#      emulator's real Telecom, registry and IMS dumps as root and find its
#      phone process (their output only, numbers and words, leaves the
#      device; compared with what the emulator should show: a failure for
#      the parts that passed in run 21, a warning for the phone process
#      until it has passed on CI once). Then WEL8 after Start: the module
#      carries out Phone mode (cell_phone_mode: its session record, its
#      log, the radio on, mobile data off), the status screen's Phone and
#      carrier cards (welcome-adb.sh check-phone), and Welcome's provider
#      takes the module's word on the cell radio from root only
#      (check-module-cell); warnings until they have passed on CI once.
#      Then WEL10 after Start, 4 minutes at most, warnings: the card on the
#      status screen (welcome_emergency_card_session: the VoLTE line, the
#      emulator having no IMS) and Show my position with the network up
#      (welcome_position_session; position_lookups: no name looked up by the
#      DNS filter meanwhile; position_not_in_status).
#   8. Wait for tor to bootstrap (the DNS filter's /status, else tor.log).
#   9. Tracker test: names on the block list asked of the filter directly
#      (DNS over TCP to 127.0.0.1:5335 through adb forward) and through
#      Android's resolver, plus a control name that must resolve.
#  10. Probes with the full rule set, as root and as an app (Welcome's uid,
#      through run-as): TCP to the emulator host's ports 80, 5000 and 49152
#      (the capture judges whether a SYN left), to 127.0.0.1:9052, and to
#      another app's loopback port, which must never be reached.
#  11. The armed state: service.sh's loop is paused, 'antumbra-fw flush'
#      puts the firewall back to armed with the network up, and traffic is
#      made as root, as an app and as tor's uid (ping, TCP to a relay's
#      ORPort and to 10.0.2.2:80, DNS). Between the events armed_probe_start
#      and armed_probe_end the capture must show nothing from the phone but
#      ARP and DHCP. Then the loop resumes, finds the firewall armed and
#      loads the full rule set again, which must come back live.
#  12. Evidence and checks, also after a failure: tor's established
#      connections, the consensus tor downloaded and the session's bridges
#      (read as tor's uid, never by root, since tor can write there); the
#      firewall live with the property matching; the capabilities of tor
#      and the filter; who listens on the service ports (no SOCKS or
#      control port, no other uid on 9040, 9053, 5335, 5380); the control
#      socket's mode and owner; Wi-Fi's store and NetworkStack's databases
#      on a tmpfs as system_server and NetworkStack see them; IPv6 off on
#      every interface; the device's addresses; the DNS filter's query log
#      and tor's STREAM events; logs; for diagnosis, the firewall's packet
#      counters per rule, conntrack's and the kernel's network counters.
#      Then the capture inside the guest is stopped and pulled, and the
#      emulator's capture is stopped.
#
# Environment:
#   ANTUMBRA_CI_OUT        report directory (required)
#   ANTUMBRA_MODULE_ZIP    the module zip the module job built (installed as
#                          it is with build-module.sh --emulator --zip)
#   ANTUMBRA_MODULE_TREE   the unpacked module zip: bin/<abi>/{tor,
#                          antumbra-dnsfilter,antumbra-run}, lists/; used
#                          when ANTUMBRA_MODULE_ZIP is not set (build-module.sh
#                          then stages the scripts from the checkout)
#   ANTUMBRA_WELCOME_APK   app-debug.apk (required)
#   ANTUMBRA_SERIAL, ANTUMBRA_CAPTURE, ANTUMBRA_CI_IMAGE
#   ANTUMBRA_CI_BOOTSTRAP_TIMEOUT  seconds to wait for tor (default 900)
#   ANTUMBRA_CI_TRACKERS   names that must be blocked
#                          (default "doubleclick.net stats.lineageos.org")
#   ANTUMBRA_CI_CONTROL    a name that must resolve through Tor
#                          (default check.torproject.org)
#   ANTUMBRA_CI_BUILD_MODULE  the module installer (default
#                          ../module/build-module.sh; another one only for a
#                          dry run of this script against a fake adb)
#   ANTUMBRA_CI_WELCOME_ADB   Welcome's adb driver (default
#                          ../welcome/ci/welcome-adb.sh)
set -uo pipefail

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
scenario_init antumbra

ZIP=${ANTUMBRA_MODULE_ZIP:-}
TREE=${ANTUMBRA_MODULE_TREE:-}
APK=${ANTUMBRA_WELCOME_APK:?set ANTUMBRA_WELCOME_APK to the Welcome APK}
# 900 s: tor takes the consensus from one source and starts no second
# download while that one still sends, however slowly; in run 4 a slow
# fallback directory held it at 30% for nine minutes, then moria1 sent the
# whole consensus in about a second.
BOOTSTRAP_TIMEOUT=${ANTUMBRA_CI_BOOTSTRAP_TIMEOUT:-900}
TRACKERS=${ANTUMBRA_CI_TRACKERS:-doubleclick.net stats.lineageos.org}
CONTROL=${ANTUMBRA_CI_CONTROL:-check.torproject.org}
# A uid no app has, standing in for another app (with the inet group, as an
# app with the INTERNET permission has).
OTHER_APP_UID=10998
OTHER_APP_PORT=47000
SERVICE_PIDS=

# The module's installation, Welcome, Wi-Fi, tor's bootstrap, tor's STREAM
# events and the evidence at the end are lib/common.sh's ("The Antumbra
# session"), shared with the app lab (emulator-apps.sh).

# --- Steps -----------------------------------------------------------------------

# welcome_emergency: before Start, with Welcome in its lock task, the
# emergency dialer opens from Welcome's Emergency call button and in a task
# of its own (as the power menu opens it), and Back returns to Welcome, still
# locked (welcome-adb.sh check-emergency; WEL7). Nothing is dialled: the
# check touches nothing in the dialer.
welcome_emergency() {
	if timeout 180 bash "$WELCOME_ADB" -s "$ANTUMBRA_SERIAL" check-emergency \
		--screenshot "$SHOTS/$SCEN-welcome-emergency-dialer.png" >"$LOGS/$SCEN-welcome-emergency.txt" 2>&1; then
		check welcome_emergency_dialer ok "$(tail -n 1 "$LOGS/$SCEN-welcome-emergency.txt")"
	else
		check welcome_emergency_dialer fail "$(grep -v '^$' "$LOGS/$SCEN-welcome-emergency.txt" | tail -n 3 | tr '\n' ';')"
		screenshot welcome-emergency-failed
		# Welcome back in front for the rest of the run, whatever the check
		# left (the dialer still open after Back, the keyguard up, the lock
		# task ended). WelcomeActivity is singleTask: this brings its task to
		# the front and finishes anything stacked above it there, and the
		# locked task's own activity may always start. Nothing in the dialer
		# is touched.
		wake_screen
		ash "am start -n $PKG/.WelcomeActivity" >/dev/null 2>&1
		ui_wait start_button 30 'Start Antumbra' ||
			check welcome_emergency_recover warn "Welcome did not come back after the emergency dialer check"
	fi
	# A failed screen capture leaves an empty file.
	[ -s "$SHOTS/$SCEN-welcome-emergency-dialer.png" ] || rm -f "$SHOTS/$SCEN-welcome-emergency-dialer.png"
}

# welcome_power_menu: before Start, the power menu opened from Welcome's
# lock task shows an item labelled Emergency (welcome-adb.sh
# check-power-menu; WEL12). Presence only, and only while the emergency
# affordance is off, so that the item is the one that opens the emergency
# dial pad, not the one that calls at once; no emergency setting is
# changed and the item is never pressed. The check closes the menu (Back,
# then the screen off and on) and puts power_button_long_press back
# itself; after a failure clear-power-menu-test does both again before
# Welcome is brought back. WARN, not fail, until the check has passed on
# CI once (then make it fail).
welcome_power_menu() {
	local log=$LOGS/$SCEN-welcome-power-menu.txt
	if timeout 240 bash "$WELCOME_ADB" -s "$ANTUMBRA_SERIAL" check-power-menu \
		--screenshot "$SHOTS/$SCEN-welcome-power-menu.png" >"$log" 2>&1; then
		check welcome_power_menu_emergency ok "$(tail -n 1 "$log")"
	else
		check welcome_power_menu_emergency warn "$(grep -v '^$' "$log" | tail -n 3 | tr '\n' ';')"
		screenshot welcome-power-menu-failed
		timeout 120 bash "$WELCOME_ADB" -s "$ANTUMBRA_SERIAL" clear-power-menu-test >>"$log" 2>&1 ||
			check welcome_power_menu_recover warn "the power menu could not be closed or the long-press setting put back: $(tail -n 1 "$log")"
		# Welcome in front as after the emergency dialer check.
		wake_screen
		ash "am start -n $PKG/.WelcomeActivity" >/dev/null 2>&1
		ui_wait start_button 30 'Start Antumbra' ||
			check welcome_power_menu_recover warn "Welcome did not come back after the power menu check"
	fi
	[ -s "$SHOTS/$SCEN-welcome-power-menu.png" ] || rm -f "$SHOTS/$SCEN-welcome-power-menu.png"
}

# module_word: MOD11 on the emulator. Welcome's provider takes the
# module's word from root only: welcome-adb.sh check-module-word sends a
# word as the shell user (uid 2000, refused), a malformed one as root
# (refused) and a "none" as root (taken); nothing that could let Quick
# power off skip a wait is sent. Then the module's own parsers, run as
# root on the device against the emulator's real dumps (Telecom, the
# telephony registry, the phone process's IMS registration), and its
# phone_proc (the phone process found by name, its pid and start time
# read); only their output, numbers and words, leaves the device, and
# module_parsers_level compares it with what the emulator should show. The
# dumps are taken with the module's own cell_dump and ims_dump, which drop
# dumpsys's stderr ("Broken pipe" when a parser stops reading early, as in
# run 20). welcome_module_word fails since it passed in run 20;
# module_parsers fails since its telecom, registry and ims parts passed in
# run 21 (af748d0), and warns while only the phone part, new since, is not
# as expected (make that fail too once it has passed on CI).
module_word() {
	local log=$LOGS/$SCEN-welcome-module-word.txt out
	if timeout 120 bash "$WELCOME_ADB" -s "$ANTUMBRA_SERIAL" check-module-word >"$log" 2>&1; then
		check welcome_module_word ok "$(tail -n 1 "$log")"
	else
		check welcome_module_word fail "$(grep -v '^$' "$log" | tail -n 3 | tr '\n' ';')"
	fi
	out=$(ASH_TIMEOUT=60 ash "MODDIR=$MODDIR; . \$MODDIR/lib/antumbra.sh; \
		t=\$(cell_dump telecom | telecom_state) || t=unreadable; \
		r=\$(cell_dump telephony.registry | registry_state) || r=unreadable; \
		i=\$(ims_dump | ims_state) || i=unreadable; \
		p=no; phone_proc >/dev/null 2>&1 && p=yes; \
		echo \"telecom=\$t; registry=\$r; ims=\$i; phone=\$p\"")
	printf '%s\n' "$out" >"$SDIR/module-parsers.txt"
	check module_parsers "$(module_parsers_level "$out")" "$out"
}

# module_parsers_level OUT: how the probe's output compares with what the
# emulator should show, as a check level. fail unless it starts with
# exactly the parts run 21 (af748d0) printed and nothing before them: no
# call in this boot ("telecom=0 0 - - 0"), both phones idle with the radio
# on or off ("registry=0 0 on" or "0 0 off"), an IMS word ("ims=cell",
# "wifi", "registered" or "none"); anything else there (another line
# before it, "unreadable", "u" for a call it could not classify, a
# number, the IMS word running on) fails. warn when only what follows is
# not "; phone=yes" (the phone process found, not yet printed on CI); ok
# otherwise.
module_parsers_level() {
	local known='^telecom=0 0 - - 0; registry=0 0 (on|off); ims=(cell|wifi|registered|none)((;|'$'\n'').*)?$'
	if ! [[ $1 =~ $known ]]; then
		echo fail
	elif [ "${BASH_REMATCH[3]}" = '; phone=yes' ]; then
		echo ok
	else
		echo warn
	fi
}

# --- WEL8: the Phone-mode gate and the two choices at Start -----------------------
#
# cell_gate off|phone|data: the Phone-mode gate, as the install's PH3 step
# writes it on the phone: the root-only file /data/adb/antumbra-cell
# (0600), or none for off. The module reads it at every turn and tells
# Welcome (module_cell). Nothing else turns Phone mode on: the module zip
# and the Welcome APK are the ones a release ships; this file is the
# phone's, and the emulator is wiped at every run.
cell_gate() {
	case $1 in
	off) ash 'rm -f /data/adb/antumbra-cell' >/dev/null ;;
	phone | data)
		ash "printf '%s\\n' $1 >/data/adb/antumbra-cell.new && chmod 0600 /data/adb/antumbra-cell.new && chown 0:0 /data/adb/antumbra-cell.new && mv -f /data/adb/antumbra-cell.new /data/adb/antumbra-cell" >/dev/null
		;;
	*) return 1 ;;
	esac
	event cell_gate "$1"
}

# ui_enabled_is ID true|false SECONDS: wait until the row ID (scrolled to)
# shows enabled as wanted: Welcome reads the module's word every 3 s, and
# the module tells it at its next turn after the gate changed.
ui_enabled_is() {
	local id=$1 want=$2 end=$((SECONDS + $3)) _x _y _c e
	while [ $SECONDS -lt $end ]; do
		read -r _x _y _c e < <(ui_locate "$id") || e=
		[ "$e" = "$want" ] && return 0
		sleep 3
	done
	return 1
}

# choices_level NAME: the check's level: warn until it has passed on CI
# once (then fail), as welcome_power_menu_emergency was.
choices_level() { echo warn; }

# ui_top: back to the top of the page (fast swipes down; no dump).
ui_top() {
	local w h
	read -r w h < <(screen_size)
	w=${w:-1080} h=${h:-2400}
	for _ in 1 2 3 4 5 6; do
		ash "input swipe $((w / 2)) $((h * 3 / 10)) $((w / 2)) $((h * 8 / 10)) 150" >/dev/null
	done
	sleep 1
}

# ui_choose ID: choose the radio row ID by its test tag alone, from the top
# of the page, and read it back checked; a second try if it does not read
# so. Never by its text: another row's detail may hold it ("Wi-Fi" is in
# None's, whose tap chooses None).
ui_choose() {
	local id=$1 try x y c _e
	for try in 1 2; do
		ui_top
		read -r x y c _e < <(ui_locate "$id") || continue
		[ -n "${x:-}" ] || continue
		if [ "$c" != true ]; then
			ash "input tap $x $y" >/dev/null
			sleep 1
			read -r x y c _e < <(ui_find "$id") || c=
		fi
		if [ "$c" = true ]; then
			say "chose $id (try $try)"
			return 0
		fi
	done
	say "could not choose $id"
	return 1
}

# welcome_choices: before Start, every combination of the two choices at
# each level of the gate (welcome-adb.sh check-choices), with screenshots.
# The walk ends with Wi-Fi and Phone off selected. It is bounded (7 minutes
# a gate, and no gate begun after 15 minutes), so that a slow screen cannot
# make the step run out of time: the leak test never stops for it.
WALK_GATE_S=420
WALK_BUDGET_S=900
welcome_choices() {
	local gate log row want t0=$SECONDS
	for gate in off phone data; do
		log=$LOGS/$SCEN-welcome-choices-$gate.txt
		if [ $((SECONDS - t0)) -ge "$WALK_BUDGET_S" ]; then
			check "welcome_choices_gate_$gate" "$(choices_level)" "not walked: the walk's $WALK_BUDGET_S s were used up"
			continue
		fi
		cell_gate "$gate"
		case $gate in
		off) row=phone_calls want=false ;;
		phone) row=phone_calls want=true ;;
		data) row=internet_mobile want=true ;;
		esac
		if ! ui_enabled_is "$row" "$want" 60; then
			check "welcome_choices_gate_$gate" "$(choices_level)" "$row did not show enabled=$want within 60 s of the gate $gate"
			screenshot "welcome-choices-gate-$gate-failed"
			continue
		fi
		# A screenshot of every attempt at "data", where all six can be made.
		local shots=()
		if [ "$gate" = data ]; then
			mkdir -p "$SHOTS/$SCEN-choices"
			shots=(--shots "$SHOTS/$SCEN-choices")
		fi
		if timeout "$WALK_GATE_S" bash "$WELCOME_ADB" -s "$ANTUMBRA_SERIAL" check-choices --gate "$gate" "${shots[@]}" \
			>"$log" 2>&1; then
			check "welcome_choices_gate_$gate" ok "$(tail -n 1 "$log")"
		else
			check "welcome_choices_gate_$gate" "$(choices_level)" "$(grep -v '^$' "$log" | tail -n 3 | tr '\n' ';')"
			screenshot "welcome-choices-gate-$gate-failed"
		fi
		# The radio line as each attempt read it against the registry.
		if grep -q 'the radio line says' "$log"; then
			check welcome_radio_line "$(choices_level)" "gate $gate: $(grep -m 1 -o 'the radio line says[^;]*' "$log")"
		elif grep -q ': ok: ' "$log"; then
			check welcome_radio_line ok "gate $gate: $(grep -m 1 -o 'radio [^,]*([^)]*)' "$log")"
		fi
		screenshot "welcome-choices-gate-$gate"
	done
}

# WEL8 after Start: the module carries out Phone mode (as root: its session
# record, its log, the registry's radio, mobile data off) when the session
# chose calls and texts; then the status screen's Phone and carrier cards,
# and the module's word on the cell radio from root only.
phone_checks() {
	local log rec radio data
	if [ "$PHONE_CHOICE" = calls ]; then
		rec=$(ash "cat $RT/state/module/session" | tr '\n' ' ')
		radio=$(ash 'dumpsys telephony.registry' | sed -n 's/^ *mRadioPowerState=//p' | head -n 1)
		data=$(ash 'settings list global' | grep -E '^mobile_data[0-9]*=' | tr '\n' ' ')
		if printf '%s' "$rec" | grep -q 'cell=phone gate=phone' &&
			ash "grep -q -E 'Phone mode: (the cell radio on|the radio is already on)' $RT/log/module.log" &&
			[ "$radio" = 1 ] && ! printf '%s' "$data" | grep -q '=1'; then
			check cell_phone_mode ok "session record: $rec; radio $radio; $data"
		else
			check cell_phone_mode "$(choices_level)" "session record: $rec; radio ${radio:-?}; $data"
		fi
	fi
	log=$LOGS/$SCEN-welcome-phone.txt
	if timeout 300 bash "$WELCOME_ADB" -s "$ANTUMBRA_SERIAL" check-phone --internet wifi \
		--cell "$([ "$PHONE_CHOICE" = calls ] && echo phone || echo off)" >"$log" 2>&1; then
		check welcome_phone_status ok "$(tail -n 1 "$log")"
	else
		check welcome_phone_status "$(choices_level)" "$(grep -v '^$' "$log" | tail -n 3 | tr '\n' ';')"
	fi
	screenshot status-phone
	log=$LOGS/$SCEN-welcome-module-cell.txt
	if timeout 120 bash "$WELCOME_ADB" -s "$ANTUMBRA_SERIAL" check-module-cell >"$log" 2>&1; then
		check welcome_module_cell ok "$(tail -n 1 "$log")"
	else
		check welcome_module_cell "$(choices_level)" "$(grep -v '^$' "$log" | tail -n 3 | tr '\n' ';')"
	fi
	welcome_wel10_session
}

# --- WEL10: the emergency card and Show my position -------------------------------
#
# wel10_level: the level of every WEL10 check: warn until it has passed on
# CI once (then fail), as choices_level. Nothing of WEL10 can fail the run
# or hold it up: every step is bounded (WEL10_BEFORE_S before Start,
# WEL10_AFTER_S after it, each call killed when its time is up), and a step
# that does not pass is undone (the hook cleared, a search stopped with
# Welcome's own button, the test provider removed) and Welcome brought back.
# A step not run for lack of time is not undone (it changed nothing).
#
# The bound, undos included. Undos inside the budget use its time. A step
# starts only with a minute of the budget left and is killed 20 s after
# the budget's end at the latest; once the budget is used up no step runs
# and none is undone, so at most one undo runs past it. An undo
# (wel10_undo) is bounded too: a screenshot 30 s, each adb call 15 s,
# clear-position-test 100 s, then Welcome's screen waited for 30 s plus
# one screen read (ui_dump: 3 x 60 s at worst): under a minute normally,
# 7 minutes if every adb call hangs to its limit. So WEL10 takes at most
# its budget + 20 s + one undo: under 8.5 minutes before Start and 5.5
# after it normally, about 14 and 11 if adb hangs throughout.
wel10_level() { echo warn; }
WEL10_BEFORE_S=420
WEL10_AFTER_S=240
WEL10_END=0

# wel10_budget SECONDS: WEL10's steps from now on may take SECONDS in all.
wel10_budget() { WEL10_END=$((SECONDS + $1)); }

# wel10_left: seconds left in WEL10's budget (0 when it is used up).
wel10_left() {
	local left=$((WEL10_END - SECONDS))
	[ "$left" -gt 0 ] || left=0
	echo "$left"
}

# wel10_run NAME SECONDS LOG ARGS...: welcome-adb.sh ARGS for SECONDS at
# most, never past the budget (killed 20 s after its time is up), its output
# in LOG; check NAME ok, or the level with the log's last lines. Not run when
# less than a minute of the budget is left. Returns 0 when it passed, 1 when
# it did not (to be undone), 2 when it was not run (nothing to undo).
wel10_run() {
	local name=$1 limit=$2 log=$3 left
	shift 3
	left=$(wel10_left)
	if [ "$left" -lt 60 ]; then
		check "$name" "$(wel10_level)" "not run: WEL10's time was used up"
		return 2
	fi
	[ "$limit" -le "$left" ] || limit=$left
	if timeout -k 20 "$limit" bash "$WELCOME_ADB" -s "$ANTUMBRA_SERIAL" "$@" >"$log" 2>&1; then
		check "$name" ok "$(tail -n 1 "$log")"
		return 0
	fi
	check "$name" "$(wel10_level)" "$(grep -v '^$' "$log" | tail -n 3 | tr '\n' ';')"
	return 1
}

# wel10_undo SCREEN LOG STATUS [SHOT]: after a WEL10 check, given
# wel10_run's STATUS: 2 (not run) changed nothing, so nothing is done.
# Otherwise a screenshot SHOT if named, the card's hook cleared, a search
# stopped with Welcome's Stop and the test provider removed
# (clear-position-test), then Welcome's SCREEN (welcome or status) in front
# again, as after the emergency dialer check. Bounded (above); warnings.
wel10_undo() {
	local screen=$1 log=$2 status=$3 shot=${4:-}
	[ "$status" != 2 ] || return 0
	[ -z "$shot" ] || screenshot "$shot"
	ASH_TIMEOUT=15 ash "setprop debug.antumbra.emergency_states ''" >/dev/null 2>&1
	timeout -k 10 90 bash "$WELCOME_ADB" -s "$ANTUMBRA_SERIAL" clear-position-test >>"$log" 2>&1 ||
		check welcome_position_recover "$(wel10_level)" "the position test could not be undone: $(tail -n 1 "$log")"
	ASH_TIMEOUT=15 wake_screen
	if [ "$screen" = welcome ]; then
		ASH_TIMEOUT=15 ash "am start -n $PKG/.WelcomeActivity" >/dev/null 2>&1
		ui_wait start_button 30 'Start Antumbra' ||
			check welcome_emergency_card_recover "$(wel10_level)" "Welcome did not come back after a WEL10 check"
	else
		ASH_TIMEOUT=15 ash "am start -n $PKG/.StatusActivity" >/dev/null 2>&1
		ui_wait poweroff_button 30 ||
			check welcome_emergency_card_recover "$(wel10_level)" "the status screen did not come back after a WEL10 check"
	fi
}

# wel10_parts LOG: the parts of a check-position log before Start: the
# window secure, Welcome's request under the gps provider alone, and
# Location off when the screen went off during a search.
wel10_parts() {
	local log=$1 line
	line=$(grep -m 1 -o 'secure: [a-z]*' "$log" || true)
	case $line in
	'secure: yes') check welcome_position_secure ok "the position's window has FLAG_SECURE" ;;
	'') check welcome_position_secure "$(wel10_level)" "not reached" ;;
	*) check welcome_position_secure "$(wel10_level)" "$line" ;;
	esac
	line=$(grep -m 1 -o 'gps only: .*' "$log" || true)
	case $line in
	'gps only: yes'*) check welcome_position_gnss_only ok "$line" ;;
	'') check welcome_position_gnss_only "$(wel10_level)" "not reached" ;;
	*) check welcome_position_gnss_only "$(wel10_level)" "$line" ;;
	esac
	line=$(grep -m 1 -o 'leave ([a-z]*): .*' "$log" || true)
	case $line in
	*'Location off within 10 s'*) check welcome_position_leave ok "$line" ;;
	'') check welcome_position_leave "$(wel10_level)" "not reached" ;;
	*) check welcome_position_leave "$(wel10_level)" "$line" ;;
	esac
}

# welcome_wel10: before Start (the network closed, the cellular radio off
# by MOD6), Welcome in its lock task: the emergency card read against the
# device (Android's own number, the radio line; check-emergency-card reads
# only); each state's text through the debug build's hook
# (check-emergency-states, a screenshot of each); Show my position with the
# shell's test provider (check-position --source test: the fix on screen,
# Location off after it, nothing kept, the screen off during a second
# search), then with the emulator's own receiver ('adb emu geo fix') if time
# is left. Nothing is dialled; no location setting is written but Welcome's
# own switch, by Welcome.
welcome_wel10() {
	local log f
	wel10_budget "$WEL10_BEFORE_S"
	log=$LOGS/$SCEN-welcome-emergency-card.txt
	wel10_run welcome_emergency_card 150 "$log" check-emergency-card \
		--screenshot "$SHOTS/$SCEN-welcome-emergency-card.png" || wel10_undo welcome "$log" $? welcome-emergency-card-failed
	mkdir -p "$SHOTS/$SCEN-emergency-states"
	log=$LOGS/$SCEN-welcome-emergency-states.txt
	wel10_run welcome_emergency_states 240 "$log" check-emergency-states \
		--shots "$SHOTS/$SCEN-emergency-states" || wel10_undo welcome "$log" $?
	log=$LOGS/$SCEN-welcome-position.txt
	wel10_run welcome_position 180 "$log" check-position --source test \
		--screenshot "$SHOTS/$SCEN-welcome-position-looking.png" || wel10_undo welcome "$log" $?
	wel10_parts "$log"
	log=$LOGS/$SCEN-welcome-position-gnss.txt
	if [ "$(wel10_left)" -ge 150 ]; then
		wel10_run welcome_position_gnss 150 "$log" check-position --source gnss --leave none || wel10_undo welcome "$log" $?
	else
		check welcome_position_gnss "$(wel10_level)" "not run: less than 150 s of WEL10's time left"
	fi
	for f in "$SHOTS/$SCEN-welcome-emergency-card.png" "$SHOTS/$SCEN-welcome-position-looking.png"; do
		[ -s "$f" ] || rm -f "$f"
	done
	screenshot welcome-after-wel10
}

# filter_queries: how many query lines the DNS filter has logged so far (as root).
filter_queries() { ash "grep -c ' query \"' $RT/log/dnsfilter.log" 2>/dev/null | tr -cd '0-9'; }

# welcome_wel10_session: after Start, on the status screen, in the run's
# Phone-mode session (the radio on; the emulator has no IMS, so MOD11's word
# is "none" and the card shows the VoLTE line): the card read against the
# device, then Show my position with the network up. Between the events
# position_start and position_end the DNS filter must log no lookup (any
# names in a warning: an assistance download would show here), and the test
# position must not be in the module's status.json (read as tor's uid, as
# collect_evidence does).
welcome_wel10_session() {
	local log n0 n1 names
	wel10_budget "$WEL10_AFTER_S"
	log=$LOGS/$SCEN-status-emergency-card.txt
	wel10_run welcome_emergency_card_session 120 "$log" check-emergency-card ||
		wel10_undo status "$log" $? status-emergency-card-failed
	log=$LOGS/$SCEN-status-position.txt
	n0=$(filter_queries)
	event position_start
	wel10_run welcome_position_session 180 "$log" check-position --source test --leave home || wel10_undo status "$log" $?
	event position_end
	n1=$(filter_queries)
	if [ -z "$n0" ] || [ -z "$n1" ]; then
		check position_lookups "$(wel10_level)" "the DNS filter's query log could not be read"
	elif [ "$n1" -le "$n0" ]; then
		check position_lookups ok "no name looked up while the position was taken"
	else
		names=$(ash "grep ' query \"' $RT/log/dnsfilter.log | tail -n +$((n0 + 1)) | sed 's/.* query \"\\([^\"]*\\)\".*/\\1/' | sort -u | head -n 10" | tr '\n' ' ')
		check position_lookups "$(wel10_level)" "$((n1 - n0)) lookups while the position was taken: $names"
	fi
	if as_tor_cat "$RT/run/status.json" 2>/dev/null | grep -qF -e 10.12345 -e 140.54321; then
		check position_not_in_status "$(wel10_level)" "the test position is in the module's status.json"
	else
		check position_not_in_status ok "the test position is not in the module's status.json"
	fi
	screenshot status-after-wel10
}

# The session's Phone choice for the run: calls (the radio on all run,
# mobile data off), or off when Welcome did not offer it (welcome_start).
PHONE_CHOICE=off

welcome_start() {
	ui_wait start_button 120 'Start Antumbra' || {
		screenshot welcome-missing
		abort welcome_screen "the Start Antumbra button did not appear within 2 minutes"
	}
	check welcome_screen ok
	screenshot welcome-1
	welcome_emergency
	welcome_power_menu
	welcome_wel10
	welcome_choices
	# The run's session: Wi-Fi, Tor directly, calls and texts with the gate
	# at "phone" (as the install leaves it after PH3's outcome A). Each row
	# by its test tag alone and read back checked, whatever the walk left
	# selected. Internet and Tor are the run's own: it stops without them.
	# Phone is WEL8's: off then, with a warning, never a stop.
	cell_gate phone
	ui_choose internet_wifi || abort welcome_choice "Internet: Wi-Fi (internet_wifi) could not be chosen by its test tag"
	if ui_enabled_is phone_calls true 60 && ui_choose phone_calls; then
		PHONE_CHOICE=calls
		check welcome_phone_start ok "Phone: calls and texts"
	elif ui_choose phone_off; then
		check welcome_phone_start "$(choices_level)" "Welcome did not offer calls and texts within 60 s of the gate phone, or the row did not read checked; the run starts with Phone off"
	else
		check welcome_phone_start "$(choices_level)" "neither Phone row could be chosen; the provider's row after Start says which the run has"
	fi
	ui_choose tor_direct || abort welcome_choice "Connect to Tor directly (tor_direct) could not be chosen by its test tag"
	ui_set_switch switch_mac true 'New Wi-Fi hardware address' || check welcome_mac warn "could not set the Wi-Fi address switch"
	ui_set_switch switch_unsafe_browser false 'Unsafe Browser' || check welcome_unsafe warn "could not find the Unsafe Browser switch off"
	# The default session: Administration off. adb survives it only through
	# the debug build's test hook.
	ui_set_switch switch_admin false 'Administration' || abort welcome_admin "could not switch Administration off"
	screenshot welcome-2-choices
	ui_tap start_button 'Start Antumbra' || abort welcome_start "Start Antumbra not found"
	event welcome_start
	sleep 5
	wait_device 60
	[ "$(ash 'id -u')" = 0 ] || abort adb_after_start "adb lost its root shell at Start: Welcome switched USB debugging off (test hook debug.antumbra.keep_adb not honoured?)"
	if ui_wait status_title 90; then
		check status_screen ok
	else
		check status_screen warn "the status screen did not appear within 90 s"
	fi
	screenshot status-1-started
	local row
	row=$(ash "content query --uri $URI")
	printf '%s\n' "$row" >"$SDIR/provider-row.txt"
	case $row in
	*started=1*) check provider_started ok "$row" ;;
	*) check provider_started fail "the provider does not say started=1: $row" ;;
	esac
	case $row in
	*tor_mode=direct*) check provider_mode ok ;;
	*) check provider_mode fail "tor_mode is not direct: $row" ;;
	esac
	case $row in
	*admin=1*) check provider_admin fail "the session has Administration on: $row" ;;
	*) check provider_admin ok "Administration off" ;;
	esac
	local cell_now
	cell_now=$(printf '%s\n' "$row" | sed -n 's/.*[ ,]cell=\([a-z]*\).*/\1/p' | head -n 1)
	if [ "$cell_now" = "$([ "$PHONE_CHOICE" = calls ] && echo phone || echo off)" ]; then
		check provider_cell ok "$PHONE_CHOICE"
	else
		check provider_cell "$(choices_level)" "the row's cell is not the choice ($PHONE_CHOICE): $row"
		# The checks after Start judge the session the row says it has.
		case $cell_now in phone) PHONE_CHOICE=calls ;; *) PHONE_CHOICE=off ;; esac
	fi
}

tracker_test() {
	local lines=$SDIR/tracker-test.jsonl tmp=$SDIR/.dns-answer.json name out rcode
	: >"$lines"
	event tracker_test
	if dns_port; then
		for name in $TRACKERS; do
			"${CITOOL[@]}" dns-query --port "$DNS_PORT" --name "$name" >"$tmp" 2>/dev/null || true
			printf '{"method":"filter","name":"%s","result":%s}\n' "$name" "$(cat "$tmp" 2>/dev/null || echo null)" >>"$lines"
			rcode=$("${CITOOL[@]}" json-get "$tmp" rcode)
			if [ "$("${CITOOL[@]}" json-get "$tmp" blocked)" = true ]; then
				check "tracker_blocked:$name" ok "the filter answered ${rcode:-?}"
			else
				check "tracker_blocked:$name" fail "the filter did not block it: $(cat "$tmp" 2>/dev/null)"
			fi
		done
		"${CITOOL[@]}" dns-query --port "$DNS_PORT" --name "$CONTROL" >"$tmp" 2>/dev/null || true
		printf '{"method":"filter","name":"%s","control":true,"result":%s}\n' "$CONTROL" "$(cat "$tmp" 2>/dev/null || echo null)" >>"$lines"
		if [ "$("${CITOOL[@]}" json-get "$tmp" rcode)" = NOERROR ] && [ -n "$("${CITOOL[@]}" json-get "$tmp" answers.0)" ]; then
			check "control_resolves:$CONTROL" ok "answered through Tor: $("${CITOOL[@]}" json-get "$tmp" answers)"
		else
			check "control_resolves:$CONTROL" warn "no answer through Tor: $(cat "$tmp" 2>/dev/null)"
		fi
		rm -f "$tmp"
	else
		check tracker_test fail "adb forward to the filter's TCP port 5335 failed"
	fi
	# The same names through Android's own resolver (netd), as root and as
	# the Welcome app's uid: the firewall must send these to the filter too.
	# ping's ICMP itself must be refused; if it left, the capture shows it.
	for name in $TRACKERS "$CONTROL"; do
		out=$(ASH_TIMEOUT=20 ash "ping -c 1 -W 3 $name" 2>&1 | head -n 3)
		json_obj method=system-resolver uid=0 name="$name" output="$out" >>"$lines"
		out=$(ASH_TIMEOUT=20 ash "run-as $PKG ping -c 1 -W 3 $name" 2>&1 | head -n 3)
		json_obj method=system-resolver uid=app name="$name" output="$out" >>"$lines"
	done
	"${PY[@]}" -c 'import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
json.dump({"tests": rows}, open(sys.argv[2], "w"), indent=1, sort_keys=True)' "$lines" "$SDIR/tracker-test.json" &&
		rm -f "$lines"
	sleep 3
	fetch_status "$SDIR/filter-status.json"
}

# probe WHO HOST PORT [udp]: one connection attempt carrying a token, as
# root ("root"), as Welcome's uid ("app", through run-as) or as tor's uid
# ("tor"). Prints nc's output; the capture and the listener judge.
probe() {
	local who=$1 host=$2 port=$3 u=${4:-} cmd
	cmd="echo ANTUMBRA-PROBE | /system/bin/toybox nc ${u:+-u }-w 3 $host $port"
	case $who in
	root) ASH_TIMEOUT=15 ash "$cmd" 2>&1 ;;
	app) ASH_TIMEOUT=15 ash "run-as $PKG sh -c '$cmd'" 2>&1 ;;
	tor) ASH_TIMEOUT=15 ash "$MODDIR/bin/antumbra-run -u 2950 -g 2950 -G 3003 -- /system/bin/sh -c '$cmd'" 2>&1 ;;
	esac
	return 0
}

# probes_live: with the full rule set. TCP to the emulator host's ports
# (on the phone, the router's web page, UPnP and the like) is passed into
# tor, which refuses private addresses, so no SYN to 10.0.2.2 may appear in
# the capture. Another app's loopback listener must never be reached, and
# nothing answers on tor's control port 9052.
probes_live() {
	local who target lid out hex
	event probes_live
	adb -s "$ANTUMBRA_SERIAL" shell "$MODDIR/bin/antumbra-run -u $OTHER_APP_UID -g $OTHER_APP_UID -G 3003 -- \
/system/bin/toybox timeout 30 /system/bin/toybox nc -l -s 127.0.0.1 -p $OTHER_APP_PORT" \
		>"$SDIR/.other-app-listener.out" 2>&1 </dev/null &
	lid=$!
	sleep 3
	hex=$(printf '%04X' "$OTHER_APP_PORT")
	if ash 'cat /proc/net/tcp' | awk -v p=":$hex" -v u="$OTHER_APP_UID" '$2 ~ p"$" && $4 == "0A" && $8 == u { f = 1 } END { exit !f }'; then
		check other_app_listener ok "uid $OTHER_APP_UID listens on 127.0.0.1:$OTHER_APP_PORT"
	else
		check other_app_listener warn "the stand-in app's listener did not start; the loopback probe proves nothing"
	fi
	{
		for who in root app; do
			for target in "10.0.2.2 80" "10.0.2.2 5000" "10.0.2.2 49152" "127.0.0.1 9052" "127.0.0.1 $OTHER_APP_PORT"; do
				# shellcheck disable=SC2086 # host and port
				out=$(probe "$who" $target | head -n 3 | tr '\n' ' ')
				printf '%s\t%s\t%s\n' "$who" "${target/ /:}" "$out"
			done
		done
	} >"$SDIR/probes-live.tsv"
	sleep 3
	ash "pkill -f 'nc -l -s 127.0.0.1 -p $OTHER_APP_PORT'" >/dev/null 2>&1
	kill "$lid" 2>/dev/null
	wait "$lid" 2>/dev/null
	if grep -q ANTUMBRA-PROBE "$SDIR/.other-app-listener.out" 2>/dev/null; then
		check other_app_port fail "a probe reached another app's loopback port 127.0.0.1:$OTHER_APP_PORT"
	else
		check other_app_port ok "no probe reached another app's loopback port"
	fi
	rm -f "$SDIR/.other-app-listener.out"
	event probes_live_end
}

# armed_phase: the firewall's armed rule set with the network up (see
# step 11 above).
armed_phase() {
	local relay rhost rport out i
	proc_net_snapshot
	relay=$("${PY[@]}" "$CI_DIR/leak_analyser.py" tor-conns "$SDIR/proc-net-tcp.txt" 2>/dev/null | grep -v '^\[' | head -n 1)
	rhost=${relay%:*} rport=${relay##*:}
	[ -n "$relay" ] || { rhost=198.51.100.1 rport=443; }
	SERVICE_PIDS=$(ash "pgrep -f '^sh $MODDIR/service.sh'" | tr '\n' ' ')
	SERVICE_PIDS=${SERVICE_PIDS% }
	if [ -z "$SERVICE_PIDS" ]; then
		check armed_phase fail "service.sh is not running"
		return 1
	fi
	# Pause the module's loop, which would otherwise load the rule set again
	# within 30 seconds.
	ash "kill -STOP $SERVICE_PIDS" >/dev/null
	event armed_flush "service.sh paused ($SERVICE_PIDS)"
	out=$(ash "ANTUMBRA_DIR=$RT/state/module/fw sh $MODDIR/bin/antumbra-fw flush; echo \"exit=\$?\"")
	printf '# antumbra-fw flush\n%s\n' "$out" >"$LOGS/$SCEN-armed-phase.txt"
	fw_status >>"$LOGS/$SCEN-armed-phase.txt"
	if ! fw_status | grep -qx 'state=armed'; then
		ash "kill -CONT $SERVICE_PIDS" >/dev/null
		SERVICE_PIDS=
		check armed_phase fail "antumbra-fw flush did not leave the firewall armed: $(tr '\n' ' ' <"$LOGS/$SCEN-armed-phase.txt" | cut -c1-300)"
		return 1
	fi
	# Nothing may claim the full rule set while only the arm set is loaded.
	ash "setprop antumbra.fw.armed ''" >/dev/null
	sleep 2
	event armed_probe_start "relay $rhost:$rport"
	sleep 2
	{
		echo "# as root"
		ASH_TIMEOUT=15 ash 'ping -c 2 -W 2 10.0.2.2' 2>&1
		ASH_TIMEOUT=15 ash 'ping -c 1 -W 2 1.1.1.1' 2>&1
		ASH_TIMEOUT=15 ash "ping -c 1 -W 2 $CONTROL" 2>&1
		probe root "$rhost" "$rport"
		probe root 10.0.2.2 80
		probe root 10.0.2.2 9 udp
		probe root 10.0.2.3 53 udp
		echo "# as an app (uid of $PKG)"
		ASH_TIMEOUT=15 ash "run-as $PKG ping -c 1 -W 2 10.0.2.2" 2>&1
		ASH_TIMEOUT=15 ash "run-as $PKG ping -c 1 -W 2 $CONTROL" 2>&1
		probe app "$rhost" "$rport"
		probe app 10.0.2.2 80
		echo "# as tor's uid"
		probe tor "$rhost" "$rport"
	} >>"$LOGS/$SCEN-armed-phase.txt" 2>&1
	sleep 4
	event armed_probe_end
	fw_status >>"$LOGS/$SCEN-armed-phase.txt"
	if fw_status | grep -qx 'state=armed'; then
		check armed_state_held ok "the firewall stayed armed during the probes"
	else
		check armed_state_held fail "the firewall left the armed state during the probes: $(fw_status | tr '\n' ' ')"
	fi
	# The loop resumes, finds the firewall armed and loads the rule set again.
	ash "kill -CONT $SERVICE_PIDS" >/dev/null
	SERVICE_PIDS=
	for i in $(seq 1 30); do
		fw_live_matches && break
		sleep 3
	done
	if fw_live_matches; then
		event armed_reapplied "$FW_DETAIL"
		check armed_phase ok "armed with the network up, then live again: $FW_DETAIL"
	else
		check armed_phase fail "the module did not load the full rule set again within 90 s: $FW_DETAIL"
	fi
}

finish() {
	local rc=$?
	trap - EXIT
	set +e
	if [ -n "$SERVICE_PIDS" ]; then
		ash "kill -CONT $SERVICE_PIDS" >/dev/null 2>&1
	fi
	stop_stream_recorder
	if [ "$rc" -ne 0 ] || [ "$FAILED" -ne 0 ]; then
		wake_screen
		screenshot final
	fi
	if [ "$(ash 'id -u' 2>/dev/null)" = 0 ]; then
		collect_evidence
	else
		check evidence fail "no root shell at the end: tor's connections, the consensus and the logs were not collected"
	fi
	collect_logcat
	guest_capture_stop
	capture_stop
	timeout 10 adb -s "$ANTUMBRA_SERIAL" forward --remove-all >/dev/null 2>&1
	if [ "$rc" -ne 0 ] || [ "$FAILED" -ne 0 ]; then rc=1; fi
	echo "$rc" >"$SDIR/result"
	say "done (exit $rc)"
	exit "$rc"
}
trap finish EXIT

if [ -n "$ZIP" ]; then
	[ -f "$ZIP" ] || abort inputs "no module zip at $ZIP"
else
	[ -d "${TREE:-/nonexistent}/bin/x86_64" ] || abort inputs "set ANTUMBRA_MODULE_ZIP, or ANTUMBRA_MODULE_TREE to the unpacked zip"
fi
[ -f "$APK" ] || abort inputs "no Welcome APK at $APK"

event boot_completed
wait_system_ready 300 || abort system_ready "the system did not answer within 5 minutes of boot"
timeout 60 adb -s "$ANTUMBRA_SERIAL" root >/dev/null 2>&1
sleep 3
wait_device 60
[ "$(ash 'id -u')" = 0 ] || abort adb_root "adb root did not give a root shell"
check adb_root ok
device_info
WLAN_MAC_BEFORE=$(ash 'cat /sys/class/net/wlan0/address' 2>/dev/null)
guest_capture_start fail
clock_marker

quiet_network
install_module
start_stream_recorder
network_on
install_welcome
welcome_start
wifi_join
# shellcheck disable=SC2119 # a default session: check-policies without --admin
welcome_checks
module_word
phone_checks
if wait_bootstrap; then
	screenshot status-2-bootstrapped
	tracker_test
	screenshot status-3-after-tracker-test
else
	screenshot status-2-no-bootstrap
fi
probes_live
armed_phase
# Let tor settle on the reloaded rule set before the evidence is taken.
sleep 20
