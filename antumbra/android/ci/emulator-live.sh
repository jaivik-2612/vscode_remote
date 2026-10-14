#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Antumbra Live: the virtual phone the owner uses in a browser (scenario
# "live"). Runs inside reactivecircus/android-emulator-runner (the live job
# of antumbra-live.yml), after the emulator has booted with its window on
# the virtual display that live-stream.sh shows through the link. Steps:
#   1. As the app lab, up to just before Start (lib/common.sh's session_root
#      and session_prepare): adb root; tcpdump inside the guest on every
#      interface; a clock marker; airplane mode; the module installed with
#      build-module.sh --emulator, its firewall live; tor's STREAM events
#      recorded; mobile data off; then F-Droid and Aptoide installed from
#      the APKs applab.py fetch downloaded and checked on the runner (only a
#      verified APK is installed), before Welcome becomes the device owner:
#      from then on Welcome refuses apps from outside the preinstalled store
#      until a session with Administration on; then Welcome as device owner.
#      The page then says the phone is ready.
#   2. The owner's session. Nothing is pressed or typed on the phone. Once
#      the owner has pressed Start (Welcome's provider says started=1), the
#      virtual Wi-Fi is joined as the app lab joins it (for a session that
#      uses the network), and a store that could not be installed before is
#      installed again if the session has Administration on. The session
#      ends at ANTUMBRA_LIVE_END (epoch seconds), when End session is
#      pressed on the page (the End listener writes end-requested), when
#      the phone restarts (the emulator has no Magisk: the module would not
#      come back), or when the phone stops answering for 2 minutes.
#   3. The link closed (live-stream.sh close), then the evidence
#      (collect_evidence), both captures stopped and pulled. analyse.sh and
#      live.py report judge the session afterwards, by the app lab's rules.
#
#   emulator-live.sh          the above
#   emulator-live.sh finish   in a later step, after the emulator step was
#                             cancelled or timed out: asks a session still
#                             running to end and waits for it; otherwise
#                             collects the evidence itself if the phone still
#                             answers. Does nothing after a normal end.
#
# Environment:
#   ANTUMBRA_CI_OUT, ANTUMBRA_MODULE_ZIP or ANTUMBRA_MODULE_TREE,
#   ANTUMBRA_WELCOME_APK, ANTUMBRA_SERIAL, ANTUMBRA_CAPTURE, ANTUMBRA_CI_IMAGE
#                          as for emulator-apps.sh
#   ANTUMBRA_APPLAB_DL     applab.py fetch's directory for the stores
#                          (downloads.json and the APKs); optional
#   ANTUMBRA_LIVE_DIR      live-stream.sh's private directory (flags, pids)
#   ANTUMBRA_LIVE_WEB      the web root (session.json, the page's state)
#   ANTUMBRA_LIVE_END      when the session ends (epoch seconds)
set -uo pipefail

MODE=${1:-session}
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

ZIP=${ANTUMBRA_MODULE_ZIP:-}
TREE=${ANTUMBRA_MODULE_TREE:-}
APK=${ANTUMBRA_WELCOME_APK:-}
DL=${ANTUMBRA_APPLAB_DL:-}
LIVE=${ANTUMBRA_LIVE_DIR:?set ANTUMBRA_LIVE_DIR}
WEB=${ANTUMBRA_LIVE_WEB:-}
END_AT=${ANTUMBRA_LIVE_END:-}
APPLAB=("${PY[@]}" "$CI_DIR/applab.py")
LIVEPY=("${PY[@]}" "$CI_DIR/live.py")
# shellcheck disable=SC2034 # read by common.sh's wait_bootstrap
BOOTSTRAP_TIMEOUT=600
# Apps send more than the ANTUMBRA scenario's probes: a larger buffer for
# tcpdump inside the guest, so that it drops nothing (as in the app lab).
GCAP_BUFFER_KB=16384
# tor's connections at the end may be the owner's bridges: the log is
# public, so collect_evidence prints how many, not where.
# shellcheck disable=SC2034 # read by common.sh's collect_evidence
QUIET_TOR_CONNS=1
END_REASON=
INTERRUPTED=0
BOOT_ID=
STORES_LEFT=()
STORES_ON=()
STORES_OFF=()

# page_state STATE [NOTE]: the landing page's state (session.json), and the
# line under it.
page_state() {
	if [ -n "$WEB" ] && [ -d "$WEB" ]; then
		"${LIVEPY[@]}" state --web "$WEB" --set "state=$1" ${2+--set "note=$2"} >/dev/null 2>&1
	fi
	return 0
}

# stores_note: one line for the page on F-Droid and Aptoide.
stores_note() {
	local n out='' labels=()
	if [ ${#STORES_ON[@]} -gt 0 ]; then out="On the phone: $(printf '%s, ' "${STORES_ON[@]}")"; out="${out%, }. "; fi
	if [ ${#STORES_LEFT[@]} -gt 0 ]; then
		for n in "${STORES_LEFT[@]}"; do labels+=("$(store_line "$n" | cut -f 4)"); done
		out="${out}Not installed yet, installed after Start if Administration is on: $(printf '%s, ' "${labels[@]}")"
		out="${out%, }. "
	fi
	if [ ${#STORES_OFF[@]} -gt 0 ]; then
		out="${out}Not on the phone (its download could not be checked on GitHub's side): $(printf '%s, ' "${STORES_OFF[@]}")"
		out="${out%, }."
	fi
	printf '%s' "${out% }"
}

# --- The stores ------------------------------------------------------------

# store_line NAME: the store's line of applab.py plan.
store_line() {
	awk -F '\t' -v n="$1" '$1 == "store" && $2 == n' "$SDIR/plan.tsv" 2>/dev/null | head -n 1
}

# install_store NAME WHEN: one store from its verified APK.
install_store() {
	local kind name pkg label ok apk note
	IFS=$'\t' read -r kind name pkg label ok apk note < <(store_line "$1")
	[ "${kind:-}" = store ] || return 1
	if [ "$ok" != 1 ]; then
		check "store_$name" warn "$label was not verified on the runner, so it is not on the phone: $note"
		STORES_OFF+=("$label")
		return 0
	fi
	if apk_install "$pkg" "$apk" "$LOGS/live-store-$name-install.txt"; then
		event store_installed "$name $2"
		check "store_$name" ok "$label ($pkg) installed $2"
		STORES_ON+=("$label")
	else
		check "store_$name" warn "$label could not be installed $2: $APK_INSTALL_DETAIL"
		return 1
	fi
}

# before_welcome: session_prepare's hook, once tor's STREAM events are
# recorded and the network is on: the recorder's pid for 'finish', then the
# stores.
before_welcome() {
	echo "${STREAMS_PID:-}" >"$LIVE/streams.pid"
	install_stores
}

install_stores() {
	local kind name _rest
	if [ -z "$DL" ] || [ ! -s "$DL/downloads.json" ]; then
		check stores warn "no store downloads: F-Droid and Aptoide are not on the phone"
		STORES_OFF+=(F-Droid Aptoide)
		return 0
	fi
	cp "$DL/downloads.json" "$SDIR/downloads.json"
	if ! "${APPLAB[@]}" plan "$DL/downloads.json" >"$SDIR/plan.tsv"; then
		check stores warn "applab.py plan could not read the downloads"
		return 0
	fi
	while IFS=$'\t' read -r kind name _rest <&3; do
		[ "$kind" = store ] || continue
		install_store "$name" "before Start" || STORES_LEFT+=("$name")
	done 3<"$SDIR/plan.tsv"
}

# --- After Start -----------------------------------------------------------

# after_start ROW: Welcome's provider row once the owner pressed Start.
after_start() {
	local row=$1 mode admin name left=() words=off
	mode=$(printf '%s' "$row" | sed -n 's/.*tor_mode=\([a-z]*\).*/\1/p')
	admin=$(printf '%s' "$row" | sed -n 's/.*admin=\([01]\).*/\1/p')
	if [ "$admin" = 1 ]; then words=on; fi
	event live_started "tor_mode=${mode:-?} admin=${admin:-?}"
	check session_started ok "Start pressed: Tor ${mode:-?}, Administration $words"
	page_state started
	case $mode in
	direct | bridges) wifi_join ;;
	*) say "a session without the network: Wi-Fi stays off" ;;
	esac
	if [ "$admin" = 1 ] && [ ${#STORES_LEFT[@]} -gt 0 ]; then
		for name in "${STORES_LEFT[@]}"; do
			install_store "$name" "after Start (Administration on)" || left+=("$name")
		done
		STORES_LEFT=("${left[@]}")
		page_state started "$(stores_note)"
	fi
}

# --- The session -------------------------------------------------------------

boot_id() {
	ASH_TIMEOUT=20 ash 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null | head -n 1
}

session_loop() {
	local started=0 row now next_row=0 next_health=0 gone=0 id
	while :; do
		now=$(date +%s)
		if [ "$now" -ge "$END_AT" ]; then
			END_REASON="time"
			break
		fi
		if [ -e "$LIVE/end-cancelled" ]; then
			END_REASON=cancelled
			break
		fi
		if [ -e "$LIVE/end-requested" ]; then
			END_REASON=page
			break
		fi
		if [ "$now" -ge "$next_health" ]; then
			next_health=$((now + 15))
			if [ "$(timeout 20 adb -s "$ANTUMBRA_SERIAL" get-state 2>/dev/null)" = device ]; then
				gone=0
				id=$(boot_id)
				if [ -n "$id" ] && [ -n "$BOOT_ID" ] && [ "$id" != "$BOOT_ID" ]; then
					check phone_restarted fail "the phone restarted during the session: without Magisk the module does not start again, and the capture inside the phone stopped"
					END_REASON=restarted
					break
				fi
			else
				gone=$((gone + 1))
				if [ "$gone" -ge 8 ]; then
					END_REASON=gone
					break
				fi
			fi
		fi
		if [ "$started" = 0 ] && [ "$now" -ge "$next_row" ] && [ "$gone" = 0 ]; then
			next_row=$((now + 10))
			row=$(ASH_TIMEOUT=20 ash "content query --uri $URI --projection started:tor_mode:admin" 2>/dev/null)
			case $row in
			*started=1*)
				started=1
				printf '%s\n' "$row" >"$SDIR/provider-row.txt"
				after_start "$row"
				;;
			esac
		fi
		sleep 5
	done
	say "the session ends: $END_REASON"
}

# --- The end -----------------------------------------------------------------

# finish_session: the link closed, then the evidence and both captures.
finish_session() {
	local rc=${1:-0}
	set +e
	page_state ending
	bash "$CI_DIR/live-stream.sh" close >/dev/null 2>&1
	if [ "$(timeout 20 adb -s "$ANTUMBRA_SERIAL" get-state 2>/dev/null)" = device ]; then
		if [ "$(ash 'id -u' 2>/dev/null)" = 0 ]; then
			collect_evidence
		else
			stop_stream_recorder
			check evidence fail "no root shell at the end: tor's connections, the consensus and the logs were not collected"
		fi
		collect_logcat
		guest_capture_stop
		capture_stop
		timeout 10 adb -s "$ANTUMBRA_SERIAL" forward --remove-all >/dev/null 2>&1
	else
		stop_stream_recorder
		check evidence fail "the phone did not answer at the end: its own capture and the evidence were not collected (only the emulator's capture of eth0 is judged)"
		printf 'capture_stop\t%s\tnot confirmed (the phone was gone)\n' "$(now)" >>"$SDIR/events.tsv"
	fi
	if [ "$rc" -ne 0 ] || [ "$FAILED" -ne 0 ]; then rc=1; fi
	echo "$rc" >"$SDIR/result"
	if [ "$END_REASON" = failed ]; then page_state failed; else page_state ended; fi
	say "done (exit $rc)"
	return "$rc"
}

on_exit() {
	local rc=$?
	trap - EXIT INT TERM
	if [ "$INTERRUPTED" = 1 ]; then
		# Cancelled or timed out: the workflow's next step ('finish')
		# collects the evidence while the emulator still runs.
		say "interrupted: the next step collects the evidence"
		exit "$rc"
	fi
	[ -n "$END_REASON" ] || END_REASON=failed
	event live_end "$END_REASON"
	finish_session "$rc"
	exit $?
}

# --- finish: after a cancel ----------------------------------------------------

finish_mode() {
	local pid i
	SCEN=live
	SDIR=$ANTUMBRA_CI_OUT/live
	mkdir -p "$SDIR" "$SHOTS" "$LOGS"
	if [ -s "$SDIR/result" ]; then
		say "the session ended by itself; nothing to do"
		return 0
	fi
	pid=$(cat "$LIVE/session.pid" 2>/dev/null)
	if [ -n "$pid" ] && grep -q -a emulator-live "/proc/$pid/cmdline" 2>/dev/null; then
		say "the session's script still runs: asking it to end"
		echo cancelled >"$LIVE/end-cancelled"
		for i in $(seq 1 144); do
			[ -s "$SDIR/result" ] && break
			kill -0 "$pid" 2>/dev/null || break
			sleep 5
		done
		if [ -s "$SDIR/result" ]; then
			say "the session ended"
			timeout 20 adb -s "$ANTUMBRA_SERIAL" emu kill >/dev/null 2>&1
			return 0
		fi
		kill -TERM "$pid" 2>/dev/null
		sleep 5
	fi
	say "collecting the evidence here"
	if ! grep -q "^live_end$(printf '\t')" "$SDIR/events.tsv" 2>/dev/null; then
		END_REASON=cancelled
		event live_end cancelled
	fi
	GCAP_PID=$(ASH_TIMEOUT=20 ash "cat $GCAP_PIDFILE 2>/dev/null" | head -n 1 | tr -dc 0-9)
	pid=$(cat "$LIVE/streams.pid" 2>/dev/null)
	if [ -n "$pid" ] && grep -q -a adb "/proc/$pid/cmdline" 2>/dev/null; then STREAMS_PID=$pid; fi
	finish_session 0
	timeout 20 adb -s "$ANTUMBRA_SERIAL" emu kill >/dev/null 2>&1
	return 0
}

if [ "$MODE" = finish ]; then
	finish_mode
	exit $?
fi
[ "$MODE" = session ] || {
	echo "usage: emulator-live.sh [finish]" >&2
	exit 2
}

# --- The session's script ------------------------------------------------------

scenario_init live
mkdir -p "$LIVE"
rm -f "$LIVE/end-requested" "$LIVE/end-cancelled"
echo $$ >"$LIVE/session.pid"
trap on_exit EXIT
trap 'INTERRUPTED=1; exit 130' INT TERM

case $END_AT in '' | *[!0-9]*) abort inputs "ANTUMBRA_LIVE_END is not a time (epoch seconds)" ;; esac
if [ -n "$ZIP" ]; then
	[ -f "$ZIP" ] || abort inputs "no module zip at $ZIP"
else
	[ -d "${TREE:-/nonexistent}/bin/x86_64" ] || abort inputs "set ANTUMBRA_MODULE_ZIP, or ANTUMBRA_MODULE_TREE to the unpacked zip"
fi
if [ -z "$APK" ] || [ ! -f "$APK" ]; then abort inputs "no Welcome APK (ANTUMBRA_WELCOME_APK)"; fi

session_root
PREPARE_HOOK=before_welcome
session_prepare
# The job gives the phone a hardware keyboard (enable-hw-keyboard), so
# that keys typed in the browser reach Android; Android's own keyboard
# should still come up on a text field (the action turns that off).
ash 'settings put secure show_ime_with_hard_keyboard 1' >/dev/null 2>&1
BOOT_ID=$(boot_id)
wake_screen
event live_ready
check phone_ready ok "the module live, Welcome the device owner; ${#STORES_LEFT[@]} store(s) left to install after Start"
page_state ready "$(stores_note)"
say "the phone is ready; the session ends at $(date -u -d "@$END_AT" '+%H:%M UTC')"
session_loop
