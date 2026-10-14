#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Antumbra CI: the app lab (scenario "apps"). Real app stores and real apps
# on the virtual phone, under Antumbra, through Tor: what does each one do,
# does it still work, and does anything get past the firewall?
#
# Runs inside reactivecircus/android-emulator-runner (the app-lab job of
# antumbra-android.yml, which gives the emulator more memory and storage),
# after the emulator has booted. Not blocking: nothing here fails the
# workflow. Steps:
#   1. The ANTUMBRA scenario's session (lib/common.sh, "The Antumbra
#      session"): adb root; tcpdump inside the guest on every interface; a
#      clock marker; airplane mode; the module installed with
#      build-module.sh --emulator and the DNS filter's query log on; tor's
#      STREAM events recorded from then on; mobile data off; Welcome as
#      device owner. Then Start with Tor directly, a new Wi-Fi address and
#      Administration ON (Welcome then lifts the restriction that refuses
#      app installs, DISALLOW_INSTALL_UNKNOWN_SOURCES_GLOBALLY); Wi-Fi
#      joined; Welcome's checks for an Administration session; tor's
#      bootstrap; the home screen.
#   2. The stores (F-Droid, Aptoide, TapTap) and then the apps of
#      app-lab.txt, in turn, each in a window of its own: installed with
#      'adb install' from the APK applab.py fetch downloaded and checked on
#      the CI runner (an APK that was not verified is never installed);
#      started from its launcher entry; given its time (a store up to
#      ANTUMBRA_APPLAB_STORE_WAIT seconds for its catalogue to load through
#      Tor, pressing only buttons that dismiss a first-run screen, never one
#      that signs in or agrees; an app ANTUMBRA_APPLAB_APP_WAIT seconds, and
#      nothing pressed); a screenshot once its window has the focus; whether
#      it still runs; then force-stopped. For each window the lab records
#      where tor's STREAM events and the DNS filter's query log stood at its
#      start and end, and keeps the item's logcat and screen. A failure is
#      recorded and the next item goes on. No item starts after
#      ANTUMBRA_APPLAB_BUDGET seconds.
#   3. The app drawer; then the evidence of the ANTUMBRA scenario (the
#      firewall still live, tor's connections, the consensus, the filter's
#      log, IPv6 off, the device's addresses), both captures stopped, and
#      applab.py build: apps.json and apps.md.
# analyse.sh then judges the whole run with the ANTUMBRA rules (anything
# after the arm cutoff that is not to the Tor network is a LEAK), and the
# workflow builds apps.json again with that verdict.
#
# Nothing is ever dialled, no SMS is sent, no account is signed in to and
# nothing is typed into any app. The firewall and the filter are those of a
# normal session: no app is exempted.
#
# Environment:
#   ANTUMBRA_CI_OUT, ANTUMBRA_MODULE_ZIP or ANTUMBRA_MODULE_TREE,
#   ANTUMBRA_WELCOME_APK, ANTUMBRA_SERIAL, ANTUMBRA_CAPTURE, ANTUMBRA_CI_IMAGE
#                          as for emulator-antumbra.sh
#   ANTUMBRA_APPLAB_DL     applab.py fetch's directory (downloads.json and the
#                          APKs); fetched here when it has no downloads.json
#   ANTUMBRA_APPLAB_CATALOGUE  the catalogue (default app-lab.txt)
#   ANTUMBRA_APPLAB_APKSIGNER, ANTUMBRA_APPLAB_AAPT2  for that fetch (default:
#                          build tools 36.0.0 in $ANDROID_HOME)
#   ANTUMBRA_CI_BOOTSTRAP_TIMEOUT  seconds to wait for tor (default 600)
#   ANTUMBRA_APPLAB_STORE_WAIT  seconds a store may take (default 90)
#   ANTUMBRA_APPLAB_APP_WAIT    seconds each app runs (default 45)
#   ANTUMBRA_APPLAB_BUDGET      no store or app starts after this many seconds
#                          of the script (default 1440)
set -uo pipefail

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
scenario_init apps

ZIP=${ANTUMBRA_MODULE_ZIP:-}
TREE=${ANTUMBRA_MODULE_TREE:-}
APK=${ANTUMBRA_WELCOME_APK:?set ANTUMBRA_WELCOME_APK to the Welcome APK}
DL=${ANTUMBRA_APPLAB_DL:?set ANTUMBRA_APPLAB_DL to the directory applab.py fetch writes}
CATALOGUE=${ANTUMBRA_APPLAB_CATALOGUE:-$CI_DIR/app-lab.txt}
SDK_TOOLS=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}/build-tools/36.0.0
APKSIGNER=${ANTUMBRA_APPLAB_APKSIGNER:-$SDK_TOOLS/apksigner}
AAPT2=${ANTUMBRA_APPLAB_AAPT2:-$SDK_TOOLS/aapt2}
BOOTSTRAP_TIMEOUT=${ANTUMBRA_CI_BOOTSTRAP_TIMEOUT:-600}
STORE_WAIT=${ANTUMBRA_APPLAB_STORE_WAIT:-90}
APP_WAIT=${ANTUMBRA_APPLAB_APP_WAIT:-45}
BUDGET=${ANTUMBRA_APPLAB_BUDGET:-1440}
APPLAB=("${PY[@]}" "$CI_DIR/applab.py")
ALOGS=$LOGS/apps
RECORDS=$SDIR/records.jsonl
FILTER_LOG=$RT/log/dnsfilter.log
# Apps send more than the ANTUMBRA scenario's probes: a larger buffer for
# tcpdump inside the guest, so that it drops nothing.
GCAP_BUFFER_KB=16384
T0=$SECONDS
mkdir -p "$ALOGS"
: >"$RECORDS"

# --- The session, with Administration on ----------------------------------

# session_start: Welcome's choices for the lab (Tor directly, a new Wi-Fi
# address, the Unsafe Browser off, Administration ON), then Start. Without
# Administration Android refuses every app install but the preinstalled
# store's. adb survives Start through the debug build's test hook, as in
# ANTUMBRA.
session_start() {
	local row
	ui_wait start_button 120 'Start Antumbra' || {
		screenshot welcome-missing
		abort welcome_screen "the Start Antumbra button did not appear within 2 minutes"
	}
	check welcome_screen ok
	screenshot welcome-1
	ui_tap tor_direct 'Connect to Tor directly' || abort welcome_choice "'Connect to Tor directly' not found"
	ui_set_switch switch_mac true 'New Wi-Fi hardware address' || check welcome_mac warn "could not set the Wi-Fi address switch"
	ui_set_switch switch_unsafe_browser false 'Unsafe Browser' || check welcome_unsafe warn "could not find the Unsafe Browser switch off"
	ui_set_switch switch_admin true 'Administration' || abort welcome_admin "could not switch Administration on"
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
	*admin=1*) check provider_admin ok "Administration on: installs allowed" ;;
	*) check provider_admin fail "the session does not have Administration on: $row" ;;
	esac
}

# device_facts: what the apps run on, for apps.json.
device_facts() {
	json_obj model="$(ash 'getprop ro.product.model')" sdk="$(ash 'getprop ro.build.version.sdk')" \
		release="$(ash 'getprop ro.build.version.release')" abilist="$(ash 'getprop ro.product.cpu.abilist')" \
		native_bridge="$(ash 'getprop ro.dalvik.vm.native.bridge')" \
		mem_mb="$(ash "awk '/^MemTotal:/ { print int(\$2 / 1024) }' /proc/meminfo")" \
		data_free_mb="$(ash "df -k /data | awk 'NR == 2 { print int(\$4 / 1024) }'")" \
		image="${ANTUMBRA_CI_IMAGE:-android-36;default;x86_64}" >"$SDIR/device.json"
	say "device: $(cat "$SDIR/device.json")"
}

# --- One store or app ------------------------------------------------------

# shot_as STEM: the screen as $SHOTS/STEM.png (applab.py build turns it into
# a JPEG).
shot_as() {
	local f=$SHOTS/$1.png
	timeout 30 adb -s "$ANTUMBRA_SERIAL" exec-out screencap -p >"$f" 2>/dev/null
	if [ "$(head -c 8 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = 89504e470d0a1a0a ]; then
		say "screenshot $(basename "$f")"
	else
		rm -f "$f"
		say "screenshot $1 failed"
	fi
}

# ui_dump_once: one uiautomator dump with a short time limit (an app that
# never goes idle makes uiautomator wait; common.sh's ui_dump tries three
# times for up to 40 s each).
ui_dump_once() {
	timeout 20 adb -s "$ANTUMBRA_SERIAL" shell uiautomator dump "$UI_XML" >/dev/null 2>&1 &&
		timeout 15 adb -s "$ANTUMBRA_SERIAL" exec-out cat "$UI_XML"
}

# focus_on PKG SECONDS: true once PKG's window has the input focus (resumed
# comes before drawn: a screenshot taken earlier shows the window before).
# FOCUS is the focused window either way.
FOCUS=
focus_on() {
	local end=$((SECONDS + $2))
	while :; do
		FOCUS=$(ash 'dumpsys window' | grep -m 1 -o 'mCurrentFocus=.*')
		case $FOCUS in *" $1/"*) return 0 ;; esac
		[ $SECONDS -lt $end ] || return 1
		sleep 1
	done
}

# Where tor's STREAM events (on the host) and the DNS filter's query log (on
# the device) stand: their line counts. applab.py build reads the lines in
# between as the window's.
streams_at() {
	local n
	n=$(wc -l <"$SDIR/tor-streams.txt" 2>/dev/null | tr -dc 0-9)
	echo "${n:-0}"
}
filter_at() {
	local n
	n=$(ash "wc -l < $FILTER_LOG" 2>/dev/null | tr -dc 0-9)
	echo "${n:-0}"
}

# connected_since LINE: tor connected the phone somewhere after line LINE
# of tor's STREAM events: a TransPort stream that the exit's CONNECTED cell
# remapped (REMAP ... SOURCE=EXIT). tor sends SUCCEEDED only to SOCKS
# clients, never for a TransPort stream; the REMAPs of DNSPort lookups
# (CLIENT_PROTOCOL=DNS) do not count.
connected_since() {
	tail -n +"$(($1 + 1))" "$SDIR/tor-streams.txt" 2>/dev/null |
		grep -q -E '^650 STREAM [0-9]+ REMAP [0-9]+ [^ ]+:[1-9][0-9]* SOURCE=EXIT .*CLIENT_PROTOCOL=TRANS( |$)'
}

# store_wait LINE: up to STORE_WAIT seconds for a store's catalogue: the
# screen shows one (applab.py ui-summary counts its texts, and no network
# error) and tor connected the phone since LINE. A button that only
# dismisses a first-run screen (Skip, Not now, Don't allow) is pressed, four
# times at most. Sets TAPS and LOADED.
TAPS=
LOADED=no
store_wait() {
	local from=$1 end=$((SECONDS + STORE_WAIT)) n=0 sum count dx dy dt err
	TAPS='' LOADED=no
	sleep 10
	while [ $SECONDS -lt $end ]; do
		sum=$(ui_dump_once | "${APPLAB[@]}" ui-summary 2>/dev/null)
		IFS=$'\t' read -r count dx dy dt err <<<"${sum:-$'0\t-\t-\t-\t-'}"
		if [ "${dx:--}" != - ] && [ "$n" -lt 4 ]; then
			ash "input tap $dx $dy" >/dev/null
			TAPS="$TAPS${TAPS:+; }$dt"
			n=$((n + 1))
			say "pressed '$dt'"
			sleep 3
			continue
		fi
		if [ "${count:-0}" -ge 12 ] && [ "${err:--}" = - ] && connected_since "$from"; then
			LOADED=yes
			# A moment for the pictures.
			sleep 5
			break
		fi
		sleep 8
	done
}

# record KEY=VALUE...: one line of records.jsonl.
record() {
	json_obj "$@" >>"$RECORDS"
}

# run_item KIND NAME PACKAGE LABEL VERIFIED APK NOTE (a line of applab.py
# plan): install, start, wait, screenshot, force-stop, and record.
run_item() {
	local kind=$1 name=$2 pkg=$3 label=$4 ok=$5 apk=$6 note=$7
	local stem t0 s0 f0 dev out install=failed idetail='' launch=skipped ldetail='' comp focus=no running=no pid=''
	if [ "$kind" = store ]; then stem=store-$name; else stem=app-$pkg; fi
	if [ "$ok" != 1 ]; then
		say "$label: not installed ($note)"
		record kind="$kind" name="$name" package="$pkg" label="$label" install=not-verified note="$note"
		return 0
	fi
	if [ $((SECONDS - T0)) -ge "$BUDGET" ]; then
		say "$label: skipped, out of time"
		record kind="$kind" name="$name" package="$pkg" label="$label" install=skipped \
			note="out of time: no item starts after $BUDGET s"
		return 0
	fi
	say "--- $label ($pkg)"
	wake_screen
	t0=$(now)
	s0=$(streams_at)
	f0=$(filter_at)
	dev=$(ash 'date +%s' | tr -dc 0-9)
	event "item_start" "$kind $name"

	apk_install "$pkg" "$apk" "$ALOGS/$stem-install.txt" && install=ok
	idetail=$APK_INSTALL_DETAIL

	if [ "$install" = ok ]; then
		comp=$(ash "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER $pkg" |
			grep / | tail -n 1)
		# Quoted for the device's shell: a launcher alias such as YouTube's
		# .app.honeycomb.Shell$HomeActivity lost "$HomeActivity" unquoted
		# (run 12). Only a component's own characters get this far.
		case $comp in *[!A-Za-z0-9._\$/]*) comp='' ;; esac
		if [ -n "$comp" ]; then
			out=$(ASH_TIMEOUT=60 ash "am start -W -n '$comp'")
			ldetail=$(printf '%s\n' "$out" | grep -E '^(Status|LaunchState|TotalTime|Error)' | tr '\n' ' ')
			case $out in *"Status: ok"* | *Complete*) launch=ok ;; *) launch=failed ;; esac
		else
			out=$(ASH_TIMEOUT=60 ash "monkey -p $pkg -c android.intent.category.LAUNCHER 1")
			ldetail="no launcher activity resolved; monkey: $(printf '%s\n' "$out" | grep -m 1 -E 'Events injected|No activities' | tr -d '\n')"
			case $out in *"Events injected: 1"*) launch=ok ;; *) launch=failed ;; esac
		fi
		if [ "$launch" = ok ]; then
			if [ "$kind" = store ]; then
				store_wait "$s0"
			else
				sleep "$APP_WAIT"
			fi
			focus_on "$pkg" 10 && focus=yes
			sleep 1
			shot_as "$stem"
			ui_dump_once >"$ALOGS/$stem-ui.xml" 2>/dev/null || true
			[ -s "$ALOGS/$stem-ui.xml" ] || rm -f "$ALOGS/$stem-ui.xml"
			pid=$(ash "pidof $pkg" | awk '{ print $1 }')
			[ -n "$pid" ] && running=yes
		fi
		ash "am force-stop $pkg" >/dev/null 2>&1
		ash 'input keyevent KEYCODE_HOME' >/dev/null 2>&1
	fi
	# Stragglers (a lookup still on its way) count for this item.
	sleep 3
	ASH_TIMEOUT=60 ash "logcat -d -v threadtime -b main,system,crash -T '${dev:-0}.000'" 2>/dev/null |
		tail -c 400000 >"$ALOGS/$stem-logcat.txt"
	event "item_end" "$kind $name"
	record kind="$kind" name="$name" package="$pkg" label="$label" \
		install="$install" install_detail="$idetail" launch="$launch" launch_detail="$ldetail" \
		focus="$focus" focus_window="$FOCUS" running="$running" pid="$pid" loaded_early="$LOADED" \
		taps="$TAPS" screenshot="$stem" ui="logs/apps/$stem-ui.xml" logcat="logs/apps/$stem-logcat.txt" \
		t_start="$t0" t_end="$(now)" seconds="$(awk -v a="$(now)" -v b="$t0" 'BEGIN { printf "%.0f", a - b }')" \
		streams_from="${s0:-0}" streams_to="$(streams_at)" filter_from="${f0:-0}" filter_to="$(filter_at)"
	TAPS='' LOADED=no FOCUS=
	say "$label: install $install, start $launch, focus $focus, running $running"
}

run_items() {
	local kind name pkg label ok apk note
	if ! "${APPLAB[@]}" plan "$DL/downloads.json" >"$SDIR/plan.tsv"; then
		check applab_plan fail "applab.py plan could not read $DL/downloads.json"
		return 1
	fi
	check applab_downloads ok "$(awk -F '\t' '$5 == 1' "$SDIR/plan.tsv" | wc -l) of $(wc -l <"$SDIR/plan.tsv") verified on the runner"
	# Read from descriptor 3: adb would otherwise take the list as its input.
	while IFS=$'\t' read -r kind name pkg label ok apk note <&3; do
		run_item "$kind" "$name" "$pkg" "$label" "$ok" "$apk" "$note"
	done 3<"$SDIR/plan.tsv"
}

# The downloads, on the CI runner (the workflow fetches them before the
# emulator starts; by hand they are fetched here). apksigner and aapt2 check
# every APK: without them nothing would be verified.
downloads() {
	if [ ! -s "$DL/downloads.json" ]; then
		if [ ! -x "$APKSIGNER" ] || [ ! -x "$AAPT2" ]; then
			abort applab_tools "no apksigner or aapt2 at $APKSIGNER, $AAPT2 (build tools 36.0.0; or set ANTUMBRA_APPLAB_APKSIGNER and ANTUMBRA_APPLAB_AAPT2)"
		fi
		say "fetching the stores and apps into $DL"
		"${APPLAB[@]}" fetch --catalogue "$CATALOGUE" --out "$DL" --abi x86_64 --sdk 36 --budget 420 \
			--apksigner "$APKSIGNER" --aapt2 "$AAPT2" ||
			abort applab_fetch "applab.py fetch failed (is $CATALOGUE well formed?)"
	fi
	cp "$DL/downloads.json" "$SDIR/downloads.json"
}

home_and_drawer() {
	local w h
	ash 'input keyevent KEYCODE_HOME' >/dev/null
	sleep 2
	read -r w h < <(screen_size)
	w=${w:-1080} h=${h:-2400}
	ash "input swipe $((w / 2)) $((h * 9 / 10)) $((w / 2)) $((h * 2 / 10)) 400" >/dev/null
	sleep 3
	screenshot drawer
	ash 'input keyevent KEYCODE_HOME' >/dev/null
}

finish() {
	local rc=$?
	trap - EXIT
	set +e
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
	"${APPLAB[@]}" build "$ANTUMBRA_CI_OUT" --jpeg-width 0 --downloads "$DL/downloads.json" >/dev/null ||
		check applab_build warn "applab.py build failed"
	if [ "$rc" -ne 0 ] || [ "$FAILED" -ne 0 ]; then rc=1; fi
	echo "$rc" >"$SDIR/result"
	say "done (exit $rc, $((SECONDS - T0)) s)"
	exit "$rc"
}
trap finish EXIT

if [ -n "$ZIP" ]; then
	[ -f "$ZIP" ] || abort inputs "no module zip at $ZIP"
else
	[ -d "${TREE:-/nonexistent}/bin/x86_64" ] || abort inputs "set ANTUMBRA_MODULE_ZIP, or ANTUMBRA_MODULE_TREE to the unpacked zip"
fi
[ -f "$APK" ] || abort inputs "no Welcome APK at $APK"
downloads

# adb as root; the device's facts; then, in common.sh's session_prepare, room
# in logcat for a chatty app's 45 seconds, a screen that stays on for the
# screenshots, the capture inside the guest, the clock marker, the module,
# tor's STREAM events, the network and Welcome.
session_root
device_facts
session_prepare
session_start
wifi_join
welcome_checks --admin
if wait_bootstrap; then
	screenshot status-2-bootstrapped
else
	screenshot status-2-no-bootstrap
	check applab_tor warn "the stores and apps run without Tor connected: they cannot reach anything"
fi
# The phone's own home screen, as a person sees it after Start.
ash 'input keyevent KEYCODE_HOME' >/dev/null
sleep 3
screenshot home
run_items
home_and_drawer
