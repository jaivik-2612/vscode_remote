#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck disable=SC2015 # "A && pass || bad" is fine: pass never fails.
#
# Runs welcome-adb.sh against a fake adb: the screen logic (finding
# controls, typing bridge lines), the test hook rule, the provider checks
# and check-policies / check-addon / check-emergency / check-power-menu /
# check-module-word. No device or emulator needed.
#
#   ci/test-welcome-adb.sh        exit status 0 when every case passed
#
# WEL8's check-choices and check-phone run against a fake screen
# (fakeui.py, below) that draws the Welcome and status screens from a state
# file with Welcome's own texts (strings.xml), scrolls as Compose's
# accessibility tree shows a page (cards cut off by an edge list only the
# texts on screen), and applies taps by Welcome's own rules, with switches
# for each fault the checks must catch.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script=$here/welcome-adb.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir "$work/bin"
cat >"$work/bin/adb" <<'FAKE'
#!/usr/bin/env bash
# A fake adb: answers from canned data in $FAKE_DIR, logs what it is asked.
set -u
d=$FAKE_DIR
[ "${1:-}" = -s ] && shift 2
printf '%s\n' "$*" >>"$d/log"
# WEL8: the fake screen, while its state file exists.
if [ -f "$d/ui-state.json" ]; then
    case "$*" in
        "exec-out cat "*) exec python3 -I "$d/fakeui.py" "$d/ui-state.json" dump ;;
        "shell input tap "*) exec python3 -I "$d/fakeui.py" "$d/ui-state.json" tap "$4" "$5" ;;
        "shell input swipe "*) exec python3 -I "$d/fakeui.py" "$d/ui-state.json" swipe "$4" "$5" "$6" "$7" "${8:-300}" ;;
        # WEL10: the screen leaving during a search; a fix from the test
        # provider (latitude first) or the emulator's console (longitude first).
        "shell input keyevent KEYCODE_SLEEP" | "shell input keyevent KEYCODE_HOME") exec python3 -I "$d/fakeui.py" "$d/ui-state.json" leave ;;
        "shell su 2000 cmd location providers set-test-provider-location gps --location "*)
            [ -f "$d/testprovider" ] || { echo "java.lang.IllegalArgumentException: provider doesn't exist: gps"; exit 0; }
            exec python3 -I "$d/fakeui.py" "$d/ui-state.json" fix "${10%,*}" "${10#*,}" "${12:-}" test ;;
        "emu geo fix "*) exec python3 -I "$d/fakeui.py" "$d/ui-state.json" fix "$5" "$4" "" gnss ;;
    esac
fi
case "$*" in
    # WEL10: Android's emergency numbers ($d/ecc, a print; $d/eccfail: the
    # print fails), the card's CI hook ($d/hookstates; $d/hookhang: setting a
    # value hangs), Location's switch ($d/location: 0 off, 3 on), the test
    # provider ($d/testprovider) and the shell's mock-location op
    # ($d/appops), and what check-position looks into: Welcome's window,
    # dumpsys location, its files, its log and the properties (the faults
    # pos_not_secure, pos_fused, pos_stored, pos_logged and pos_property in
    # the fake screen's state).
    "shell cmd phone emergency-number-test-mode -p")
        if [ -f "$d/eccfail" ]; then echo "Exception: getEmergencyNumberListTestMode: not allowed"; exit 0; fi
        cat "$d/ecc" 2>/dev/null || echo "[1234, 5678]" ;;
    "shell cmd phone "*) echo "fake adb: refused: $*" >&2; exit 1 ;;
    "shell setprop debug.antumbra.emergency_states "*)
        v=${!#}; [ "$v" = "''" ] && v=''
        printf '%s' "$v" >"$d/hookstates"
        # The value is set, then the command hangs: a kill now leaves it set unless the check clears it.
        if [ -n "$v" ] && [ -f "$d/hookhang" ]; then /bin/sleep 20; fi ;;
    "shell getprop debug.antumbra.emergency_states") cat "$d/hookstates" 2>/dev/null; echo ;;
    "shell settings get secure location_mode") cat "$d/location" 2>/dev/null || echo 0 ;;
    "shell appops set com.android.shell android:mock_location "*) echo "${!#}" >"$d/appops" ;;
    "shell su 2000 cmd location providers add-test-provider gps")
        if [ -f "$d/noprovider" ]; then echo "java.lang.SecurityException: uid 2000 does not have android:mock_location"; exit 0; fi
        touch "$d/testprovider" ;;
    "shell su 2000 cmd location providers set-test-provider-enabled gps true") exit 0 ;;
    "shell su 2000 cmd location providers remove-test-provider gps")
        [ -f "$d/testprovider" ] || { echo "java.lang.IllegalArgumentException: provider doesn't exist: gps"; exit 0; }
        rm -f "$d/testprovider" ;;
    "emu geo fix "*) echo OK ;;
    "shell dumpsys window windows")
        bugs=$(python3 -I -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1])).get("bugs", [])))' "$d/ui-state.json" 2>/dev/null)
        pos=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pos", "idle"))' "$d/ui-state.json" 2>/dev/null)
        fl="LAYOUT_IN_SCREEN LAYOUT_INSET_DECOR HARDWARE_ACCELERATED"
        if [ "$pos" = found ] && [[ " $bugs " != *" pos_not_secure "* ]]; then fl="LAYOUT_IN_SCREEN SECURE HARDWARE_ACCELERATED"; fi
        printf '%s\n' 'WINDOW MANAGER WINDOWS (dumpsys window windows)' \
            '  Window #2 Window{2a u0 com.android.systemui/StatusBar}:' '    mAttrs={(0,0)(fillx63) ty=STATUS_BAR fl=NOT_FOCUSABLE SECURE}' \
            '  Window #3 Window{1f u0 org.antumbra.welcome/org.antumbra.welcome.WelcomeActivity}:' \
            "    mAttrs={(0,0)(fillxfill) ty=BASE_APPLICATION fl=$fl}" ;;
    "shell dumpsys location")
        bugs=$(python3 -I -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1])).get("bugs", [])))' "$d/ui-state.json" 2>/dev/null)
        pos=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pos", "idle"))' "$d/ui-state.json" 2>/dev/null)
        under=gps
        [[ " $bugs " != *" pos_fused "* ]] || under=fused
        echo 'Location Manager State:'
        for p in passive network fused gps; do
            # The gps provider is the test provider while one is set up.
            if [ "$p" = gps ] && [ -f "$d/testprovider" ]; then echo "  $p provider [mock]:"; else echo "  $p provider:"; fi
            echo "    last location=null"
            if [ "$pos" = looking ] && [ "$p" = "$under" ]; then echo "      Registration[10123/org.antumbra.welcome HIGH_ACCURACY maxUpdates=1]"; fi
        done ;;
    "shell grep -rlF -e 10.12345 -e 140.54321 /data/data/org.antumbra.welcome /data/user_de/0/org.antumbra.welcome 2>/dev/null")
        if grep -q '"pos_stored"' "$d/ui-state.json" 2>/dev/null; then echo /data/user_de/0/org.antumbra.welcome/files/last-position; fi ;;
    "shell pidof org.antumbra.welcome") echo 4242 ;;
    "shell logcat -d --pid=4242")
        echo "10-27 12:00:00.000  4242  4242 I AntumbraPosition: looking"
        if grep -q '"pos_logged"' "$d/ui-state.json" 2>/dev/null; then echo "10-27 12:00:01.000  4242  4242 I AntumbraPosition: fix 10.12345,-140.54321"; fi ;;
    "shell getprop")
        printf '%s\n' '[ro.build.version.sdk]: [36]' '[gsm.sim.state]: [LOADED]'
        if grep -q '"pos_property"' "$d/ui-state.json" 2>/dev/null; then echo '[debug.last.fix]: [10.12345,-140.54321]'; fi ;;
    "shell uiautomator dump "*) exit 0 ;;
    # With $d/screen, what is in front changes: am start opens the status
    # screen at its top, a swipe scrolls it down to the firewall row, which
    # says "Checking…" for one dump before Welcome's first read.
    "exec-out cat "*)
        # check-power-menu: the power menu, or the keyguard's bouncer, over Welcome.
        case $(cat "$d/front" 2>/dev/null) in powermenu | bouncer) cat "$d/ui-$(cat "$d/front").xml"; exit 0 ;; esac
        s=$(cat "$d/screen" 2>/dev/null)
        if [ -z "$s" ]; then cat "$d/ui.xml"; exit 0; fi
        cat "$d/ui-$s.xml"
        if [ "$s" = status-checking ]; then echo status-bottom >"$d/screen"; fi ;;
    "shell am start -n org.antumbra.welcome/.StatusActivity") [ -s "$d/screen" ] && echo status-top >"$d/screen"; exit 0 ;;
    # check-emergency: $d/front says what is in front (welcome or dialer),
    # $d/lock the lock task's state and $d/calls the call state ("none":
    # the dump has no call state); the lock task refuses the dialer opened
    # by $d/refuse (button or am), with $d/stuck Back does not leave the
    # dialer, with $d/droplock 'am start' ends the lock task, with
    # $d/callafter Back finds a call, and with $d/nohandler no activity
    # handles DIAL_EMERGENCY.
    "shell cmd package query-activities --components -a android.intent.action.DIAL_EMERGENCY")
        if [ -f "$d/nohandler" ]; then echo "No activities found"; else echo com.android.phone/.EmergencyDialer; fi ;;
    "shell dumpsys activity activities")
        r=org.antumbra.welcome/.WelcomeActivity
        [ "$(cat "$d/front")" = dialer ] && r=com.android.phone/.EmergencyDialer
        printf '%s\n' "  ResumedActivity: ActivityRecord{1f u0 $r t7}" '' 'ActivityTaskSupervisor state:' \
            '  LockTaskController:' "    mLockTaskModeState=$(cat "$d/lock")" ;;
    "shell dumpsys telephony.registry")
        if [ "$(cat "$d/calls" 2>/dev/null)" = none ]; then echo "Can't find service: telephony.registry"; exit 0; fi
        printf '%s\n' 'last known state:' 'Phone Id=0' "  mCallState=$(cat "$d/calls" 2>/dev/null || echo 0)" \
            "  mRadioPowerState=$(cat "$d/radio" 2>/dev/null || echo 1)" ;;
    "shell getprop gsm.sim.state") cat "$d/simstate" 2>/dev/null || echo LOADED,ABSENT ;;
    # WEL8's check-module-cell, as check-module-word's.
    "shell su 2000 content call --user 0 --uri content://org.antumbra.welcome.state --method module_cell "*)
        if [ -f "$d/cellshelltakes" ]; then echo 'Result: Bundle[{v=1}]'; else
            echo 'Error while accessing provider:org.antumbra.welcome.state'
            echo 'java.lang.SecurityException: uid 2000 may not call module_cell'
        fi ;;
    "shell content call --user 0 --uri content://org.antumbra.welcome.state --method module_cell --extra v:i:2 "*)
        if [ -f "$d/cellmalformedtaken" ]; then echo 'Result: Bundle[{v=1}]'; else
            echo 'Error while accessing provider:org.antumbra.welcome.state'
            echo 'java.lang.IllegalArgumentException: Malformed word'
        fi ;;
    "shell content call --user 0 --uri content://org.antumbra.welcome.state --method module_cell --extra v:i:1 --extra gate:s:off --extra cell:s:none --extra radio:s:unknown --extra at:l:0")
        if [ -f "$d/cellrootrefused" ]; then echo 'Error while accessing provider:org.antumbra.welcome.state'; else
            echo 'Result: Bundle[{v=1}]'
        fi ;;
    "shell am start -n com.android.phone/.EmergencyDialer -a android.intent.action.DIAL_EMERGENCY")
        if [ "$(cat "$d/refuse" 2>/dev/null)" = am ]; then echo "Error: Activity not started"; exit 0; fi
        if [ -f "$d/droplock" ]; then echo NONE >"$d/lock"; fi
        echo dialer >"$d/front"; echo "Starting: Intent { act=android.intent.action.DIAL_EMERGENCY }" ;;
    "shell input tap "*)
        if [ -f "$d/front" ] && [ "$(cat "$d/refuse" 2>/dev/null)" != button ]; then echo dialer >"$d/front"; fi ;;
    "shell input keyevent KEYCODE_BACK")
        if [ -f "$d/front" ] && [ ! -f "$d/stuck" ]; then echo welcome >"$d/front"; fi
        if [ -f "$d/callafter" ]; then echo 2 >"$d/calls"; fi ;;
    "shell wm dismiss-keyguard") exit 0 ;;
    # check-power-menu: global settings in $d/set/KEY ($d/noput-KEY makes a
    # write do nothing), the saved long-press value in $d/longsave; a long
    # press on power opens the menu ($d/ui-powermenu.xml) only with
    # power_button_long_press=1 and without $d/nomenu (with $d/affordon it
    # also switches the emergency affordance on; with $d/bouncer it shows
    # the keyguard's bouncer instead), and with $d/hang then takes 20 s; the
    # screen going off closes the menu unless $d/menustays ($d/stuck: Back
    # does not).
    "shell settings get global force_emergency_affordance" | "shell settings get global emergency_affordance_needed" | \
        "shell settings get global power_button_long_press") cat "$d/set/$5" 2>/dev/null || echo null ;;
    "shell settings put global power_button_long_press "*) [ -f "$d/noput-$5" ] || echo "$6" >"$d/set/$5" ;;
    "shell settings delete global power_button_long_press") rm -f "$d/set/$5"; echo "Deleted 1 rows" ;;
    "shell cat /data/local/tmp/antumbra-long-press-saved 2>/dev/null") cat "$d/longsave" 2>/dev/null ;;
    "shell echo "*" > /data/local/tmp/antumbra-long-press-saved") v=${2#echo }; echo "${v%% >*}" >"$d/longsave" ;;
    "shell rm -f /data/local/tmp/antumbra-long-press-saved") rm -f "$d/longsave" ;;
    "shell input keyevent --longpress KEYCODE_POWER")
        if [ -f "$d/bouncer" ]; then
            echo bouncer >"$d/front"
        elif [ "$(cat "$d/set/power_button_long_press" 2>/dev/null)" = 1 ] && [ ! -f "$d/nomenu" ]; then
            echo powermenu >"$d/front"
            if [ -f "$d/affordon" ]; then echo 1 >"$d/set/emergency_affordance_needed"; fi
        fi
        if [ -f "$d/hang" ]; then sleep 20; fi ;;
    "shell input keyevent KEYCODE_SLEEP")
        if [ "$(cat "$d/front" 2>/dev/null)" = powermenu ] && [ ! -f "$d/menustays" ]; then echo welcome >"$d/front"; fi ;;
    "exec-out screencap -p") printf '\211PNG\r\n\032\n' ;;
    "shell input swipe "*) [ "$(cat "$d/screen" 2>/dev/null)" = status-top ] && echo status-checking >"$d/screen"; exit 0 ;;
    "shell dumpsys window") echo "  mCurrentFocus=Window{1f u0 com.android.launcher3/com.android.launcher3.uioverride.QuickstepLauncher}" ;;
    "shell getprop antumbra.fw.armed") echo 0123abcd4567ef89 ;;
    # check-module-word: adb as root unless $d/uid says otherwise; Welcome's
    # provider refuses the shell user's word unless $d/shelltakes, a
    # malformed word unless $d/malformedtaken, and root's word with
    # $d/rootrefused.
    "shell id -u") cat "$d/uid" 2>/dev/null || echo 0 ;;
    "shell dpm list-owners") echo "1 owner:"; echo "User  0: admin=org.antumbra.welcome/.AdminReceiver,DeviceOwner" ;;
    "shell su 2000 content call --user 0 --uri content://org.antumbra.welcome.state --method module_word "*)
        if [ -f "$d/shelltakes" ]; then echo 'Result: Bundle[{v=1}]'; else
            echo 'Error while accessing provider:org.antumbra.welcome.state'
            echo 'java.lang.SecurityException: uid 2000 may not call module_word'
        fi ;;
    "shell content call --user 0 --uri content://org.antumbra.welcome.state --method module_word --extra v:i:2 "*)
        if [ -f "$d/malformedtaken" ]; then echo 'Result: Bundle[{v=1}]'; else
            echo 'Error while accessing provider:org.antumbra.welcome.state'
            echo 'java.lang.IllegalArgumentException: Malformed word'
        fi ;;
    "shell content call --user 0 --uri content://org.antumbra.welcome.state --method module_word --extra v:i:1 --extra calls:s:none "*)
        if [ -f "$d/rootrefused" ]; then echo 'Error while accessing provider:org.antumbra.welcome.state'; else
            echo 'Result: Bundle[{v=1}]'
        fi ;;
    "shell wm size") echo "Physical size: 1080x2400" ;;
    # adb goes away once Start ran with the hook cleared.
    "shell true") if [ "$(cat "$d/hook" 2>/dev/null)" = 0 ] && grep -q '^shell input tap' "$d/log"; then exit 1; fi ;;
    "shell input "*) exit 0 ;;
    "shell setprop debug.antumbra.keep_adb "*) echo "${!#}" >"$d/hook" ;;
    "shell getprop debug.antumbra.keep_adb") cat "$d/hook" 2>/dev/null || echo ;;
    "shell getprop ro.build.version.sdk") echo 36 ;;
    "shell getprop persist.sys.timezone") echo UTC ;;
    "shell settings get "*) echo 0 ;;
    "shell cmd wifi status") echo "Wifi is disabled" ;;
    "shell dumpsys user") cat "$d/restrictions" ;;
    "shell content query --uri content://org.antumbra.welcome.state/session --projection bridges")
        # Bridge lines only in a bridges session (the default here).
        if [ "$(cat "$d/tormode" 2>/dev/null || echo bridges)" != bridges ]; then echo 'Row: 0 bridges='; else
            printf 'Row: 0 bridges=192.0.2.7:9001 0123456789ABCDEF0123456789ABCDEF01234567\n[2001:db8::1]:443\n'
        fi ;;
    "shell content query --uri content://org.antumbra.welcome.state/session --projection cell")
        echo "Row: 0 cell=$(cat "$d/cell" 2>/dev/null || echo off)" ;;
    "shell content query --uri content://org.antumbra.welcome.state/session --projection "*)
        echo "Row: 0 started=1, tor_mode=$(cat "$d/tormode" 2>/dev/null || echo bridges), mac=new, admin=1, unsafe_browser=0, persistent=0, session_id=5f0c" ;;
    *) echo "fake adb: unexpected: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$work/bin/adb"

# Every control on one screen, as uiautomator lists Compose test tags.
node() { printf '<node resource-id="%s" text="%s" checked="%s" bounds="[0,%d][1080,%d]">%s</node>\n' "$1" "${3:-}" "${2:-false}" "$4" "$(($4 + 100))" "${5:-}"; }
{
    echo '<?xml version="1.0"?><hierarchy>'
    y=0
    for id in start_button internet_wifi internet_mobile internet_none tor_direct tor_bridges bridges_custom \
        bridges_text phone_off phone_calls switch_admin switch_unsafe_browser status_title poweroff_button emergency_call; do
        node "$id" false "" $y
        y=$((y + 100))
    done
    node switch_mac true "" $y
    node row_firewall false "" $((y + 100)) "$(node "" false Firewall 0)$(node "" false "Live (rules 0123abcd4567)" 0)"
    echo '</hierarchy>'
} >"$work/ui.xml"
# 'dumpsys user' as Android 16 prints it, with $@ as user 0's effective
# restrictions. Other parts list restrictions too: the guest's defaults
# (no_config_wifi, as in CI run 4) and a user type's.
users() {
    printf '%s\n' 'Current user: 0' '' 'Users:' '  UserInfo{0:null:4c13} serialNo=0 isPrimary=true' \
        '    State: RUNNING_UNLOCKED' '    Restrictions:' '      no_add_managed_profile' \
        '    Device policy restrictions:' '      no_config_location' '    Effective restrictions:'
    printf '      %s\n' "$@"
    printf '%s\n' '    Can have profile: true' '' 'Device properties:' '  Device policy global restrictions:' \
        '    no_safe_boot' '  Guest restrictions:' '    no_sms' '    no_config_wifi' '    no_outgoing_calls' '' \
        'User types (1 types):' '    android.os.usertype.full.RESTRICTED: ' '        mDefaultRestrictions: ' \
        '            no_debugging_features' '            no_change_wifi_state'
}
always="no_safe_boot no_config_tethering no_wifi_direct disallow_config_private_dns no_near_field_communication_radio"
unless_admin="no_install_unknown_sources_globally no_bluetooth no_config_location"
wifi_lock="no_change_wifi_state no_config_wifi no_add_wifi_config"
# Before Start, an offline session, or no add-on: everything set.
# shellcheck disable=SC2086 # word lists
users $always $unless_admin no_debugging_features $wifi_lock no_add_managed_profile >"$work/restrictions"

export FAKE_DIR=$work PATH="$work/bin:$PATH"
fail=0
pass() { echo "ok: $*"; }
bad() { echo "FAILED: $*" >&2; fail=1; }

# 1. Bridge lines with brackets, '+', '/', '=' are typed; spaces become %s.
printf '%s\n' "192.0.2.7:9001 0123456789ABCDEF0123456789ABCDEF01234567" "" \
    "webtunnel [2001:db8::1]:443 0123456789ABCDEF0123456789ABCDEF01234567 url=https://e.example/x+y ver=0.0.1" >"$work/bridges.txt"
echo 1 >"$work/hook"
: >"$work/log"
if "$script" start --tor bridges --bridges-file "$work/bridges.txt" --admin 2>"$work/err"; then
    grep -qF "shell input text '192.0.2.7:9001%s0123456789ABCDEF0123456789ABCDEF01234567'" "$work/log" &&
        grep -qF "shell input text 'webtunnel%s[2001:db8::1]:443%s" "$work/log" &&
        [ "$(grep -c 'shell input keyevent KEYCODE_ENTER' "$work/log")" = 1 ] &&
        pass "bridge lines typed" || bad "bridge lines not typed as expected: $(cat "$work/log")"
else
    bad "start --bridges-file failed: $(cat "$work/err")"
fi
# The admin switch was off, so it was tapped; the hook was left alone.
[ "$(cat "$work/hook")" = 1 ] && pass "hook kept" || bad "hook changed"

# 2. Characters 'input text' cannot carry are refused, not escaped.
for line in "192.0.2.7:9001;reboot" "obfs4 192.0.2.7:9001 cert='x'" 'a\b' 'a"b'; do
    printf '%s\n' "$line" >"$work/bad.txt"
    if "$script" start --tor bridges --bridges-file "$work/bad.txt" --admin 2>"$work/err"; then
        bad "accepted $line"
    else
        grep -q 'cannot type' "$work/err" && pass "refused $line" || bad "wrong error for $line: $(cat "$work/err")"
    fi
done

# 3. Without the test hook, start refuses unless adb loss is expected; with
#    --expect-adb-loss it clears the hook before Start.
echo 0 >"$work/hook"
if "$script" start --tor direct 2>"$work/err"; then bad "start ran without the hook"; else
    grep -q 'test hook' "$work/err" && pass "start needs the hook" || bad "wrong error: $(cat "$work/err")"
fi
echo 1 >"$work/hook"
: >"$work/log"
if "$script" start --tor direct --expect-adb-loss 2>"$work/err"; then
    [ "$(cat "$work/hook")" = 0 ] && grep -q 'adb disconnected' "$work/err" &&
        pass "--expect-adb-loss clears the hook and sees adb go" || bad "hook not cleared: $(cat "$work/err")"
else
    bad "start --expect-adb-loss: $(cat "$work/err")"
fi
for opt in --builtin-bridges --unsafe-browser; do
    if "$script" start --tor bridges $opt 2>/dev/null; then bad "accepted $opt"; else pass "refused $opt"; fi
done

# 4. check-addon reads the firewall row's text, and the rules must be
#    the property's (antumbra.fw.armed=0123abcd4567ef89 in the fake).
"$script" check-addon 2>"$work/err" && pass "check-addon" || bad "check-addon: $(cat "$work/err")"

# A status screen: its top (title, no firewall row: below the fold, so
# uiautomator leaves it out), the row with $1 as its value, and a launcher.
status_screens() {
    local s value
    {
        echo '<?xml version="1.0"?><hierarchy>'
        node status_title false "Antumbra is running" 200
        node card_session false "" 1800 "$(node "" false Tor 0)$(node "" false Direct 0)"
        node poweroff_button false "Power off now" 2100
        echo '</hierarchy>'
    } >"$work/ui-status-top.xml"
    for s in checking bottom; do
        value=$1
        [ "$s" = bottom ] || value='Checking…'
        {
            echo '<?xml version="1.0"?><hierarchy>'
            node row_admin false "" 900 "$(node "" false Administration 0)$(node "" false Off 0)"
            node row_firewall false "" 1100 "$(node "" false Firewall 0)$(node "" false "$value" 0)"
            node poweroff_button false "Power off now" 2100
            echo '</hierarchy>'
        } >"$work/ui-status-$s.xml"
    done
    printf '%s\n' '<?xml version="1.0"?><hierarchy>' "$(node "" false Gallery 1500)" '</hierarchy>' >"$work/ui-launcher.xml"
}

# 4a. CI run 4: the launcher in front, the row below the fold. check-addon
#     opens the status screen, scrolls, waits out "Checking…" and reads the
#     row, but fails: the status screen must stay in front after Start.
status_screens "Live (rules 0123abcd4567)"
echo launcher >"$work/screen"
: >"$work/log"
if "$script" check-addon 10 2>"$work/err"; then
    bad "check-addon passed with the launcher in front"
else
    grep -q 'not in front (mCurrentFocus=.*Launcher' "$work/err" &&
        grep -qx 'shell am start -n org.antumbra.welcome/.StatusActivity' "$work/log" &&
        grep -q '^shell input swipe ' "$work/log" &&
        tail -n 1 "$work/err" | grep -q 'sees the firewall, but the status screen was not in front after Start' &&
        pass "check-addon reads the row but fails when the status screen was not in front" || bad "check-addon 4a: $(cat "$work/err")"
fi

# 4a'. The status screen in front, the row below the fold: scroll, pass.
status_screens "Live (rules 0123abcd4567)"
echo status-top >"$work/screen"
: >"$work/log"
if "$script" check-addon 10 2>"$work/err"; then
    grep -q '^shell input swipe ' "$work/log" && grep -q 'sees the firewall: Firewall | Live' "$work/err" &&
        ! grep -q 'am start' "$work/log" &&
        pass "check-addon scrolls to the row on the status screen" || bad "check-addon 4a': $(cat "$work/err")"
else
    bad "check-addon with the status screen in front: $(cat "$work/err")"
fi

# 4b. The row says the firewall is not running, or shows other rules: fail.
for value in "Not running" "Live (rules ffff0000ffff)"; do
    status_screens "$value"
    echo status-top >"$work/screen"
    if "$script" check-addon 10 2>"$work/err"; then bad "check-addon passed with '$value'"; else
        grep -q 'antumbra.fw.armed' "$work/err" && pass "check-addon refuses '$value'" ||
            bad "check-addon with '$value': $(cat "$work/err")"
    fi
done

# 4c. The row never shows (a status screen without a session): give up.
status_screens "Live (rules 0123abcd4567)"
cp "$work/ui-status-top.xml" "$work/ui-status-checking.xml"
cp "$work/ui-status-top.xml" "$work/ui-status-bottom.xml"
echo status-top >"$work/screen"
if "$script" check-addon 3 2>"$work/err"; then bad "check-addon passed without the row"; else
    grep -q 'did not say Live within 3 s (last: not on screen)' "$work/err" && pass "check-addon gives up without the row" ||
        bad "check-addon without the row: $(cat "$work/err")"
fi
rm -f "$work/screen"

# 5. check-policies reads user 0's effective restrictions only.
#    Everything set = offline/no add-on, no hook.
"$script" check-policies --wifi-locked 2>"$work/err" && pass "check-policies --wifi-locked" ||
    bad "check-policies: $(cat "$work/err")"
if "$script" check-policies --admin --keep-adb 2>"$work/err"; then bad "check-policies ignored restrictions"; else
    grep -q 'no_debugging_features is set' "$work/err" && grep -q 'no_bluetooth is set' "$work/err" &&
        grep -q 'no_config_wifi is set' "$work/err" && pass "check-policies reports wrong restrictions" ||
        bad "check-policies output: $(cat "$work/err")"
fi
# 5a. CI run 4: a direct session with the add-on, Administration off, the
#     test hook on. The Wi-Fi lock is lifted; the guest's no_config_wifi
#     and the user type's defaults do not count.
# shellcheck disable=SC2086 # word lists
users $always $unless_admin no_add_managed_profile >"$work/restrictions"
"$script" check-policies --keep-adb 2>"$work/err" && pass "check-policies: network session, guest defaults ignored" ||
    bad "check-policies --keep-adb: $(cat "$work/err")"
# The same lists do not pass for a locked Wi-Fi or without the hook.
if "$script" check-policies --wifi-locked 2>"$work/err"; then bad "guest or user type defaults counted for user 0"; else
    grep -q 'missing restriction no_config_wifi' "$work/err" &&
        grep -q 'missing restriction no_change_wifi_state' "$work/err" &&
        grep -q 'missing restriction no_debugging_features' "$work/err" &&
        pass "check-policies: other users' lists do not count" || bad "check-policies --wifi-locked: $(cat "$work/err")"
fi
# 5b. No user 0 in the dump: fail, not pass.
printf 'Users:\n  UserInfo{10:Guest:4}\n    Effective restrictions:\n      no_safe_boot\n' >"$work/restrictions"
if "$script" check-policies --keep-adb 2>"$work/err"; then bad "check-policies passed without user 0"; else
    grep -q 'no effective restrictions for user 0' "$work/err" && pass "check-policies needs user 0's block" ||
        bad "check-policies without user 0: $(cat "$work/err")"
fi

# 7. check-emergency (WEL7), before Start: the dialer opens from Welcome's
#    button and from 'am start', Back returns to Welcome, still locked, and
#    nothing is dialled.
emergency() { # STATE: lock calls; then the refuse, stuck, droplock, callafter, nohandler files as set by the case
    echo welcome >"$work/front"
    echo "$1" >"$work/lock"
    echo "$2" >"$work/calls"
    rm -f "$work/refuse" "$work/stuck" "$work/droplock" "$work/callafter" "$work/nohandler" "$work/dialer.png"
    : >"$work/log"
}
emergency LOCKED 0
if "$script" check-emergency --screenshot "$work/dialer.png" --wait 2 2>"$work/err"; then
    [ "$(grep -c '^shell input tap ' "$work/log")" = 1 ] &&
        grep -qx 'shell am start -n com.android.phone/.EmergencyDialer -a android.intent.action.DIAL_EMERGENCY' "$work/log" &&
        [ "$(grep -c '^shell input keyevent KEYCODE_BACK$' "$work/log")" = 2 ] &&
        [ "$(cat "$work/front")" = welcome ] &&
        [ "$(head -c 4 "$work/dialer.png" | od -An -c | tr -d ' ')" = '211PNG' ] &&
        grep -q 'nothing was dialled' "$work/err" &&
        pass "check-emergency opens the dialer both ways and returns to Welcome" ||
        bad "check-emergency: $(cat "$work/err"); log: $(cat "$work/log")"
else
    bad "check-emergency failed: $(cat "$work/err")"
fi
# Nothing that could dial: no typed text, no call or digit keys, no number.
if grep -Eq 'input text|KEYCODE_(CALL|ENDCALL|[0-9]|STAR|POUND|NUMPAD)|tel:|CALL_EMERGENCY|cmd phone|emergency-number' "$work/log"; then
    bad "check-emergency sent something that could dial: $(cat "$work/log")"
else
    pass "check-emergency never dials"
fi
# The lock task refuses the dialer: the button, or a task of its own (no
# LOCK_TASK_FEATURE_KEYGUARD).
for way in button am; do
    emergency LOCKED 0
    echo "$way" >"$work/refuse"
    if "$script" check-emergency --wait 2 2>"$work/err"; then bad "check-emergency passed with the $way refused"; else
        how=$([ "$way" = am ] && echo am-start || echo button)
        grep -q "did not come to the front from the lock task ($how; in front: org.antumbra.welcome/.WelcomeActivity; lock task: LOCKED" "$work/err" &&
            pass "check-emergency fails when the lock task refuses the dialer ($how)" || bad "check-emergency, $way refused: $(cat "$work/err")"
    fi
done
# Back does not leave the dialer.
emergency LOCKED 0
touch "$work/stuck"
if "$script" check-emergency --wait 1 2>"$work/err"; then bad "check-emergency passed with the dialer stuck in front"; else
    [ "$(grep -c '^shell input keyevent KEYCODE_BACK$' "$work/log")" = 3 ] &&
        grep -q 'Welcome is not in front after Back from the emergency dialer (in front: com.android.phone/.EmergencyDialer)' "$work/err" &&
        pass "check-emergency fails when Back does not return to Welcome" || bad "check-emergency, stuck: $(cat "$work/err")"
fi
# The lock task ends while the dialer is open (started in a task of its own).
emergency LOCKED 0
touch "$work/droplock"
if "$script" check-emergency --wait 1 2>"$work/err"; then bad "check-emergency passed with the lock task ended"; else
    grep -q "Welcome's lock task ended while the emergency dialer was open (lock task: NONE)" "$work/err" &&
        pass "check-emergency fails when the lock task ends" || bad "check-emergency, lock dropped: $(cat "$work/err")"
fi
# A call appears after the first opening: fail, and never open the dialer again.
emergency LOCKED 0
touch "$work/callafter"
if "$script" check-emergency --wait 1 2>"$work/err"; then bad "check-emergency passed with a call after the check"; else
    grep -q 'a call is in progress after the check (button)' "$work/err" &&
        ! grep -q '^shell am start -n com.android.phone' "$work/log" &&
        pass "check-emergency fails when a call appears, and stops" || bad "check-emergency, call after: $(cat "$work/err")"
fi
# After Start (no lock task), with a call in progress, with no call state
# to read, or with no emergency dialer: the dialer is never opened.
for state in "NONE 0" "LOCKED 2" "LOCKED none" "LOCKED 0 nohandler"; do
    # shellcheck disable=SC2086 # lock state and call state (a third word is the case's)
    emergency $state
    case $state in *nohandler) touch "$work/nohandler" ;; esac
    if "$script" check-emergency --wait 1 2>"$work/err"; then bad "check-emergency passed with $state"; else
        case $state in
        "NONE 0") want='not in its lock task (lock task: NONE)' ;;
        "LOCKED 2") want='a call is in progress; not opening' ;;
        "LOCKED none") want='cannot read the call state' ;;
        *) want='no activity handles android.intent.action.DIAL_EMERGENCY' ;;
        esac
        grep -qF "$want" "$work/err" &&
            ! grep -Eq '^shell (input tap|am start -n com.android.phone)' "$work/log" &&
            pass "check-emergency refuses to start ($state)" || bad "check-emergency with $state: $(cat "$work/err")"
    fi
done
rm -f "$work/front"

# 8. check-power-menu (WEL12), before Start: with the emergency affordance
#    off, the power menu opened with a long press, its Emergency item seen
#    and never pressed, no emergency setting changed, the menu closed and
#    the long-press setting put back, whatever happened.
menu() { # [with-emergency]: the power menu's nodes, as SystemUI's dialog shows them
    {
        echo '<?xml version="1.0"?><hierarchy>'
        if [ "${1:-}" = with-emergency ]; then
            printf '<node text="Emergency" resource-id="android:id/message" package="com.android.systemui" bounds="[100,800][400,900]" />\n'
        fi
        printf '<node text="Power off" resource-id="android:id/message" package="com.android.systemui" bounds="[500,800][800,900]" />\n'
        printf '<node text="Restart" resource-id="android:id/message" package="com.android.systemui" bounds="[100,1000][400,1100]" />\n'
        echo '</hierarchy>'
    } >"$work/ui-powermenu.xml"
}
powermenu() { # STATE: fresh emulator, Welcome locked, no call, the affordance off
    echo welcome >"$work/front"
    echo LOCKED >"$work/lock"
    echo 0 >"$work/calls"
    rm -rf "$work/set" "$work/longsave" "$work/nomenu" "$work/hang" "$work/stuck" "$work/menustays" \
        "$work/affordon" "$work/bouncer" "$work/menu.png" "$work"/noput-*
    mkdir "$work/set"
    menu with-emergency
    # The keyguard's bouncer: a SystemUI button labelled "Emergency", no power menu.
    printf '%s\n' '<?xml version="1.0"?><hierarchy>' \
        '<node text="Emergency" resource-id="com.android.systemui:id/emergency_call_button" package="com.android.systemui" bounds="[100,2000][400,2100]" />' \
        '</hierarchy>' >"$work/ui-bouncer.xml"
    : >"$work/log"
}
# Put back: the menu closed, no saved value left, the long press as before ($1).
reset_ok() {
    [ "$(cat "$work/front")" != powermenu ] && [ ! -e "$work/longsave" ] &&
        if [ "$1" = null ]; then [ ! -e "$work/set/power_button_long_press" ]; else
            [ "$(cat "$work/set/power_button_long_press")" = "$1" ]; fi
}
# Line number of the first log line matching $1 (999 when none).
at() { grep -n -m 1 -- "$1" "$work/log" | cut -d: -f1 | grep . || echo 999; }
# Nothing that could dial, and no emergency setting or test number touched.
never_dials() {
    ! grep -Eq 'input tap|input text|KEYCODE_(CALL|ENDCALL|[0-9]|STAR|POUND|NUMPAD)|tel:|CALL_EMERGENCY|am start|emergency-number-test-mode|settings (put|delete) global (force_emergency_affordance|emergency_affordance)' "$work/log"
}
powermenu
if "$script" check-power-menu --screenshot "$work/menu.png" --wait 1 2>"$work/err"; then
    [ "$(at 'settings get global force_emergency_affordance')" -lt "$(at 'settings put global power_button_long_press 1')" ] &&
        [ "$(at 'settings get global emergency_affordance_needed')" -lt "$(at 'settings put global power_button_long_press 1')" ] &&
        [ "$(at 'settings put global power_button_long_press 1')" -lt "$(at 'input keyevent --longpress KEYCODE_POWER')" ] &&
        [ "$(at 'input keyevent --longpress')" -lt "$(at 'input keyevent KEYCODE_BACK')" ] &&
        ! grep -q KEYCODE_SLEEP "$work/log" &&
        reset_ok null && [ "$(cat "$work/front")" = welcome ] && [ "$(head -c 4 "$work/menu.png" | od -An -c | tr -d ' ')" = '211PNG' ] &&
        tail -n 1 "$work/err" | grep -q 'the item that opens the emergency dial pad); it was not pressed, nothing was dialled' &&
        pass "check-power-menu sees the Emergency item, presses nothing and puts everything back" ||
        bad "check-power-menu: $(cat "$work/err"); log: $(cat "$work/log")"
else
    bad "check-power-menu failed: $(cat "$work/err")"
fi
never_dials && pass "check-power-menu never dials and changes no emergency setting" ||
    bad "check-power-menu sent something that could dial or changed an emergency setting: $(cat "$work/log")"
# A long-press setting the device had before comes back.
powermenu
echo 5 >"$work/set/power_button_long_press"
"$script" check-power-menu --wait 1 2>"$work/err" && reset_ok 5 &&
    pass "check-power-menu restores power_button_long_press" || bad "power_button_long_press not restored: $(cat "$work/err")"
# Back does not close the menu: the screen off and on does, and the check passes.
powermenu
touch "$work/stuck"
"$script" check-power-menu --wait 1 2>"$work/err" && reset_ok null && [ "$(cat "$work/front")" = welcome ] &&
    [ "$(grep -c 'input keyevent KEYCODE_BACK' "$work/log")" = 3 ] &&
    [ "$(at 'input keyevent KEYCODE_BACK')" -lt "$(at 'input keyevent KEYCODE_SLEEP')" ] && never_dials &&
    pass "check-power-menu closes a menu Back does not close with the screen off and on" ||
    bad "check-power-menu, Back stuck: $(cat "$work/err"); log: $(cat "$work/log")"
# The menu shows no Emergency item: fail, after one long press (the menu's
# items do not change while it is open), and put everything back.
powermenu
menu
if "$script" check-power-menu --wait 1 2>"$work/err"; then bad "check-power-menu passed without an Emergency item"; else
    grep -q 'did not show an Emergency item' "$work/err" &&
        [ "$(grep -c 'input keyevent --longpress KEYCODE_POWER' "$work/log")" = 1 ] &&
        reset_ok null && never_dials &&
        pass "check-power-menu fails without the Emergency item and puts everything back" ||
        bad "check-power-menu, no Emergency item: $(cat "$work/err"); log: $(cat "$work/log")"
fi
# No power menu at all, the keyguard's bouncer (its "Emergency" is not the
# power menu's), the affordance coming on while the menu is open, a
# long-press setting that does not take, and a kill while the menu is
# open: fail, and put everything back (the menu closed first).
for case_ in nomenu bouncer affordon noput hang; do
    powermenu
    case $case_ in
        noput) touch "$work/noput-power_button_long_press" ;;
        *) touch "$work/$case_" ;;
    esac
    if [ "$case_" = hang ]; then
        timeout 6 "$script" check-power-menu --wait 1 2>"$work/err"
    else
        "$script" check-power-menu --wait 1 2>"$work/err"
    fi && { bad "check-power-menu passed with $case_"; continue; }
    case $case_ in
        nomenu | bouncer) want='the power menu did not open' ;;
        affordon) want='the emergency affordance came on during the check' ;;
        noput) want='power_button_long_press did not take' ;;
        hang) want='the power menu is closed and power_button_long_press is as it was' ;;
    esac
    grep -qF "$want" "$work/err" && reset_ok null && never_dials &&
        { [ "$case_" != nomenu ] || [ "$(grep -c 'input keyevent --longpress KEYCODE_POWER' "$work/log")" = 2 ]; } &&
        { [ "$case_" != hang ] || [ "$(at 'input keyevent --longpress')" -lt "$(at 'input keyevent KEYCODE_BACK')" ]; } &&
        pass "check-power-menu puts everything back ($case_)" ||
        bad "check-power-menu with $case_: $(cat "$work/err"); log: $(cat "$work/log")"
done
# A menu that stays open after Back and the screen off and on: fail, the
# long-press setting still put back, and the cleanup says the menu is open.
powermenu
touch "$work/stuck" "$work/menustays"
if "$script" check-power-menu --wait 1 2>"$work/err"; then bad "check-power-menu passed with a menu that stays open"; else
    grep -qF 'the power menu did not close' "$work/err" && grep -qF 'clear-power-menu-test failed' "$work/err" &&
        [ "$(cat "$work/front")" = powermenu ] && [ ! -e "$work/set/power_button_long_press" ] &&
        [ ! -e "$work/longsave" ] && never_dials &&
        pass "check-power-menu fails when the menu stays open, and still restores the long press" ||
        bad "check-power-menu, menu stays open: $(cat "$work/err"); log: $(cat "$work/log")"
fi
# Refused before anything is changed: the emergency affordance forced or
# needed here, or unreadable (the item would call at once), no lock task,
# a call in progress.
for case_ in forced needed unreadable unlocked call; do
    powermenu
    case $case_ in
        forced) echo 1 >"$work/set/force_emergency_affordance"; want='the emergency affordance is on' ;;
        needed) echo 1 >"$work/set/emergency_affordance_needed"; want='the emergency affordance is on' ;;
        unreadable) echo >"$work/set/emergency_affordance_needed"; want='emergency_affordance_needed=unreadable' ;;
        unlocked) echo NONE >"$work/lock"; want='not in its lock task' ;;
        call) echo 2 >"$work/calls"; want='a call is in progress' ;;
    esac
    if "$script" check-power-menu --wait 1 2>"$work/err"; then bad "check-power-menu passed with $case_"; else
        grep -qF "$want" "$work/err" &&
            ! grep -Eq 'settings (put|delete)|KEYCODE_POWER|KEYCODE_BACK|long-press-saved' "$work/log" &&
            pass "check-power-menu refuses and changes nothing ($case_)" ||
            bad "check-power-menu with $case_: $(cat "$work/err"); log: $(cat "$work/log")"
    fi
done
# clear-power-menu-test: an open menu closed and a saved value put back; on
# a clean device it passes and leaves a long-press setting it did not save.
powermenu
echo powermenu >"$work/front"
echo 1 >"$work/set/power_button_long_press"
echo null >"$work/longsave"
"$script" clear-power-menu-test 2>"$work/err" && reset_ok null && never_dials &&
    pass "clear-power-menu-test closes the menu and puts the long press back" ||
    bad "clear-power-menu-test, menu open: $(cat "$work/err"); log: $(cat "$work/log")"
powermenu
echo 5 >"$work/set/power_button_long_press"
"$script" clear-power-menu-test 2>"$work/err" && reset_ok 5 &&
    pass "clear-power-menu-test on a clean device (a long-press setting it did not save stays)" ||
    bad "clear-power-menu-test: $(cat "$work/err")"
rm -f "$work/front"

# 5c. check-module-word (MOD11): the shell user's word refused, root's
#     malformed word refused, root's "none" word taken; nothing else is sent.
: >"$work/log"
if "$script" check-module-word 2>"$work/err"; then
    [ "$(grep -c 'content call' "$work/log")" = 3 ] && ! grep 'content call' "$work/log" | grep -qv 'calls:s:none' &&
        pass "check-module-word: only root's word is taken, and only 'none' words are sent" ||
        bad "check-module-word sent other words: $(cat "$work/log")"
else
    bad "check-module-word: $(cat "$work/err")"
fi
for case_ in shelltakes malformedtaken rootrefused uid; do
    if [ "$case_" = uid ]; then echo 2000 >"$work/uid"; else touch "$work/$case_"; fi
    if "$script" check-module-word 2>"$work/err"; then bad "check-module-word passed with $case_"; else
        pass "check-module-word fails with $case_ ($(tail -n 1 "$work/err"))"
    fi
    rm -f "$work/$case_"
done

# 6. expect counts bridge lines.
"$script" expect started=1 bridges=2 unsafe_browser=0 2>"$work/err" && pass "expect" || bad "expect: $(cat "$work/err")"

# 9. WEL8: start with the two choices; cell in the row.
echo 1 >"$work/hook"
: >"$work/log"
echo phone >"$work/cell"
echo offline >"$work/tormode"
if "$script" start --internet none --phone calls --admin 2>"$work/err"; then
    grep -q 'provider row: cell=phone' "$work/err" && grep -q '^shell input tap ' "$work/log" &&
        pass "start --internet none --phone calls: cell=phone in the row" || bad "start, WEL8: $(cat "$work/err")"
else
    bad "start --internet none --phone calls: $(cat "$work/err")"
fi
echo off >"$work/cell"
if "$script" start --internet none --phone calls --admin 2>"$work/err"; then bad "start passed with the wrong cell"; else
    grep -q "cell is 'off', expected 'phone'" "$work/err" && pass "start: a wrong cell fails" || bad "start, wrong cell: $(cat "$work/err")"
fi
rm -f "${work:?}/cell" "${work:?}/tormode"
if "$script" start --internet mobile --phone off 2>"$work/err"; then bad "start took mobile data with Phone off"; else
    grep -q 'mobile data comes with calls and texts' "$work/err" && pass "start: mobile data without calls refused" ||
        bad "start, mobile without calls: $(cat "$work/err")"
fi

# 10. WEL8: check-choices and check-phone against the fake screen, with
#     Welcome's own texts. The fake screen settles at once, so the pauses
#     welcome-adb.sh makes for a device's are skipped here (a sleep that
#     returns at once, for this section only).
export FAKE_STRINGS=$here/../app/src/main/res/values/strings.xml
mkdir "$work/nosleep"
printf '#!/bin/sh\nexit 0\n' >"$work/nosleep/sleep"
chmod +x "$work/nosleep/sleep"
PATH_BEFORE_UI=$PATH
export PATH="$work/nosleep:$PATH"
cat >"$work/fakeui.py" <<'FAKEUI'
# The Welcome and status screens of a fake device, drawn from a state file
# (JSON: screen, gate, internet, phone, cell, radio, sim, offset, and
# "bugs": the faults the checks must catch) with Welcome's own texts
# (strings.xml, FAKE_STRINGS), the way uiautomator dumps Compose's
# accessibility tree: a scroll view from y=100 to y=1900 holding the rows
# (40 px plus 110 px per text, at the state's scroll offset) and the pinned
# buttons below it. Every node has the bounds of its visible part. A row
# that merges its children (a radio or switch row) lists them all while
# any part of it is on screen; a card or an info row lists only the
# children on screen, so a card cut off by an edge shows only some of its
# texts. "tap X Y" applies Welcome's rules to the control at Y; "swipe
# X1 Y1 X2 Y2 MS" scrolls the page by Y1 - Y2, half as far again for a
# fast swipe (under 500 ms: a fling). WEL10: the emergency card on both
# screens, by Welcome's rules (the number from the fake print, the state
# lines from the SIM's slots, the radio row and the VoLTE row, or the CI
# hook's), and Show my position ("pos": idle, looking, found, stopped;
# Location's switch in FAKE_DIR/location), with a fault switch in "bugs"
# for each thing the checks must catch; "leave" is the screen going off or
# Home, "fix LAT LON ACCURACY test|gnss" a position delivered. With the bug "cutcard" a spacer puts
# the carrier card, where it is tall enough (Phone on), where a scan from
# the top, in steps of a slow swipe (960 px), finds it cut off on every
# page; each dump that cuts the card off is counted in FAKE_DIR/cut-served.
import json, os, re, sys
from xml.sax.saxutils import quoteattr

path, what = sys.argv[1], sys.argv[2]
st = json.load(open(path))
bugs = set(st.get("bugs", []))
rank = {"off": 0, "phone": 1, "data": 2}
g = rank[st["gate"]]
cell = "data" if st["internet"] == "mobile" else ("phone" if st["phone"] else "off")
VT, VB, W, TEXT_H, PAD, STEP = 100, 1900, 1080, 110, 40, 960

S = {}
xml = open(os.environ["FAKE_STRINGS"], encoding="utf-8").read()
for m in re.finditer(r'<string name="([a-z0-9_]+)">([^<]*)</string>', xml):
    S[m.group(1)] = (m.group(2).replace("\\'", "'").replace('\\"', '"')
                     .replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&"))
SEES = [S[k] for k in ("carrier_sees_sim", "carrier_sees_imei", "carrier_sees_cells", "carrier_sees_calls",
                       "carrier_no_tor_calls")]


def data_lines(internet):
    if internet == "mobile":
        return [S["carrier_data_tor"]]
    return [S["carrier_data_off"]] + ([S["carrier_hotspot"]] if internet == "wifi" else [])


def row(rid, texts, merges, checked=False, enabled=True, height=None):
    return {"id": rid, "texts": texts, "merges": merges, "checked": checked, "enabled": enabled,
            "h": height if height is not None else 40 + TEXT_H * len(texts)}


FD = os.environ["FAKE_DIR"]


def fd_read(name, default=""):
    try:
        return open(os.path.join(FD, name)).read().strip()
    except OSError:
        return default


def fd_write(name, value):
    with open(os.path.join(FD, name), "w") as f:
        f.write(value + "\n")


ORDER = ["no_sim", "sim_locked", "sim_unusable", "radio_off", "volte"]


def degrees(v, pos, neg):
    u = int(abs(v) * 100000 + 0.5)
    return S[neg if v < 0 and u else pos].replace("%1$s", "%d.%05d" % (u // 100000, u % 100000))


def signed(v):
    u = int(abs(v) * 100000 + 0.5)
    return ("-" if v < 0 and u else "") + "%d.%05d" % (u // 100000, u % 100000)


def card_rows(screen_name, radio_shown):
    """The emergency card's rows, each line its own node, as Welcome shows them."""
    hook = None if "hook_ignored" in bugs else fd_read("hookstates")
    words = set(w.strip() for w in (hook or "").split(",") if w.strip())
    active = bool(words & (set(ORDER) | {"none", "number_none", "number_unreadable"}))
    if active and "hook_sticks" in bugs:
        fd_write("hookstuck", hook)
    elif not active and "hook_sticks" in bugs and fd_read("hookstuck"):
        words = set(fd_read("hookstuck").split(","))
        active = True
    printed = [n for n in fd_read("ecc", "[1234, 5678]").strip("[]").replace(" ", "").split(",") if n]
    if active:
        states = [w for w in ORDER if w in words]
        reading = "unreadable" if "number_unreadable" in words else ("none" if "number_none" in words else None)
    else:
        slots = [x for x in fd_read("simstate", "LOADED,ABSENT").split(",") if x]
        states = []
        if not slots or any(x in ("LOADED", "READY") for x in slots):
            pass
        elif any(x in ("PIN_REQUIRED", "PUK_REQUIRED", "NETWORK_LOCKED") for x in slots):
            states.append("sim_locked")
        elif any(x in ("CARD_IO_ERROR", "PERM_DISABLED", "CARD_RESTRICTED") for x in slots):
            states.append("sim_unusable")
        elif all(x == "ABSENT" for x in slots):
            states.append("no_sim")
        if radio_shown == "Off":
            states.append("radio_off")
        ready = any(x in ("LOADED", "READY") for x in slots)
        if screen_name == "status" and st.get("cell", "off") != "off" and ready and radio_shown != "Off" and st.get("ims") == "none":
            states.append("volte")
        if "card_no_radio_line" in bugs:
            states = [w for w in states if w != "radio_off"]
        if "card_extra_radio_line" in bugs and "radio_off" not in states:
            states.append("radio_off")
        if "card_no_sim_line" in bugs:
            states = [w for w in states if w not in ("no_sim", "sim_locked", "sim_unusable")]
        states = [w for w in ORDER if w in states]
        reading = None
    # card_several: every number Android printed, as Welcome shows several it
    # ranks alike (its own line); _foreign adds one Android does not list,
    # _detail gives them the line for one number.
    several = any(b.startswith("card_several") for b in bugs)
    if reading is None:
        if "card_says_none" in bugs or not printed:
            reading = "none"
        elif several:
            reading = "\u00a0\u00b7 ".join(printed + (["4321"] if "card_several_foreign" in bugs else []))
        else:
            reading = "4321" if "card_wrong_number" in bugs else printed[0]
    else:
        several = False
    r = [row("", [S["card_emergency"]], False), row("", [S["emergency_numbers_label" if several else "emergency_number_label"]], False)]
    if reading not in ("none", "unreadable"):
        r.append(row("emergency_number_value", [reading], False))
        r.append(row("emergency_number_text", [S["emergency_number_several" if several and "card_several_detail" not in bugs else "emergency_number_detail"]], False))
    else:
        r.append(row("emergency_number_text", [S["emergency_number_" + reading]], False))
    for k, w in enumerate(states):
        text = S["emergency_state_" + w]
        if "card_discouraging" in bugs and k == 0:
            text = "This phone cannot make an emergency call now."
        if "hook_text_changed" in bugs and active:
            text = text.replace("emergency call", "emergency calls")
        r.append(row("emergency_state_" + w, [text], False))
    if (states and "card_no_other_phone" not in bugs) or "card_other_alone" in bugs:
        r.append(row("emergency_other_phone", [S["emergency_other_phone"]], False))
    pos = st.get("pos", "idle")
    loc = fd_read("location", "0")
    if pos == "looking":
        r.append(row("position_status", [S["position_looking"]], False))
        r.append(row("position_stop", [S["position_stop"]], True))
        return r
    if pos == "found":
        lat, lon = st["pos_lat"], st["pos_lon"]
        lat_text = degrees(lat, "position_north", "position_south")
        if "pos_wrong_hemisphere" in bugs:
            lat_text = lat_text.replace(" N", " S")
        r += [row("position_lat_label", [S["position_lat_label"]], False), row("position_lat", [lat_text], False),
              row("position_lon_label", [S["position_lon_label"]], False),
              row("position_lon", [degrees(lon, "position_east", "position_west")], False),
              row("position_map", [S["position_map"].replace("%1$s", signed(lat) + ", " + signed(lon))], False)]
        if st.get("pos_acc"):
            r.append(row("position_accuracy", [S["position_accuracy"].replace("%1$d", str(int(float(st["pos_acc"]) + 0.5)))], False))
        r.append(row("position_age", [S["position_age_now"]], False))
        if st.get("pos_mock") and "pos_no_mock_line" not in bugs:
            r.append(row("position_mock", [S["position_mock"]], False))
    elif pos == "stopped":
        r.append(row("position_status", [S["position_stopped"]], False))
    else:
        r += [row("position_detail", [S["position_detail"]], False), row("position_detail_apps", [S["position_detail_apps"]], False)]
    if pos in ("found", "stopped"):
        r.append(row("position_location", [S["position_off_again"] if loc == "0" else S["position_off_retry"]], False))
    refused = "pos_refused" in bugs
    if refused:
        r.append(row("position_refusal", [S["position_refused_call"]], False))
    if pos == "found":
        r.append(row("position_hide", [S["position_hide"]], True))
    r.append(row("position_button", [S["position_button"]], True, False, not refused))
    return r


def welcome_rows(pad):
    mobile_ok = g >= 2 or "mobile_enabled" in bugs
    calls_ok = g >= 1 or "calls_enabled" in bugs
    i = st["internet"]
    radio = st["radio"]
    if "radio_wrong" in bugs:
        radio = "Off" if radio == "On" else "On"
    r = [row("", [S["welcome_title"], S["welcome_intro"]], False)]
    r += card_rows("welcome", radio)
    r.append(row("internet_wifi", [S["internet_wifi"], S["internet_wifi_detail"]], True, i == "wifi"))
    r.append(row("internet_mobile", [S["internet_mobile"],
                                     S["internet_mobile_detail"] if mobile_ok else S["internet_mobile_unavailable"]],
                 True, i == "mobile", mobile_ok))
    r.append(row("internet_none", [S["internet_none"], S["internet_none_detail"]], True, i == "none"))
    if i != "none" or "tor_always" in bugs:
        r.append(row("tor_direct", [S["tor_direct"], S["tor_direct_detail"]], True, True))
        r.append(row("tor_bridges", [S["tor_bridges"], S["tor_bridges_detail"]], True))
    r.append(row("sim_status_1", [S["row_sim"], st["sim"]], False))
    r.append(row("radio_status", [S["row_radio"], radio], False))
    off_checked, calls_checked = cell == "off", cell != "off"
    if "wrong_checked" in bugs:
        off_checked, calls_checked = calls_checked, off_checked
    if "calls_follow_phone" in bugs:
        # The Phone rows follow the person's own choice, not mobile data's.
        off_checked, calls_checked = not st["phone"], st["phone"]
    r.append(row("phone_off", [S["phone_off"], S["phone_off_mobile"] if i == "mobile" else S["phone_off_detail"]],
                 True, off_checked, i != "mobile"))
    r.append(row("phone_calls", [S["phone_calls"], S["phone_calls_detail"] if calls_ok else S["phone_calls_unavailable"]],
                 True, calls_checked, calls_ok))
    if pad:
        r.append(row("", [], False, height=pad))
    if cell == "off":
        card = [S["carrier_choice_off"]] + ([S["carrier_hotspot"]] if i == "wifi" else [])
    elif "card_wrong" in bugs and i == "none":
        card = [S["carrier_choice_on"]] + data_lines(i)
    else:
        card = [S["carrier_choice_on"]] + SEES + data_lines(i)
    r.append(row("card_carrier_choice", [S["card_carrier"]] + card, False))
    if "offline_text" in bugs:
        r.append(row("", ["Stay offline"], False))
    r.append(row("switch_mac", [S["mac_title"], S["mac_on"]], True, True))
    r.append(row("switch_admin", [S["admin_title"], S["admin_detail"]], True))
    r.append(row("switch_unsafe_browser", [S["unsafe_title"], S["unsafe_detail"]], True, False, False))
    r.append(row("", [S["section_storage"], S["section_additional"]], False, height=700))
    return r


def status_rows():
    i, c, radio = st["internet"], st["cell"], st["radio"]
    if "offline_text" in bugs:
        mode = "Offline: no Internet, and the cellular radio is off."
    elif i == "none":
        mode = {"Off": S["status_mode_none_radio_off"] if c == "off" else S["status_mode_none_radio_off_phone"],
                "On": S["status_mode_none_radio_on"]}.get(radio, S["status_mode_none_radio_unknown"])
    else:
        mode = S["status_mode_direct_mobile" if i == "mobile" else "status_mode_direct_wifi"]
    ims = S["ims_off"] if c == "off" else (S["ims_none"] if st.get("ims") == "none" else S["ims_unknown"])
    if "volte_wrong" in bugs:
        ims = S["ims_registered"] if c == "off" else S["ims_off"]
    if radio == "Off":
        card = [S["carrier_now_off"]] + ([S["carrier_hotspot"]] if i == "wifi" else [])
    else:
        card = [S["carrier_now_on" if radio == "On" else "carrier_now_unknown"]] + SEES + data_lines(i)
    names = {"wifi": S["value_wifi"], "mobile": S["value_mobile"], "none": S["value_none"]}
    return [
        row("status_title", [S["status_title"]], False),
        row("status_mode", [mode], False),
    ] + card_rows("status", radio) + [
        row("sim_status_1", [S["row_sim"], st["sim"]], False),
        row("radio_status", [S["row_radio"], radio], False),
        row("ims_status", [S["row_ims"], ims], False),
        row("card_carrier", [S["card_carrier"]] + card, False),
        row("row_internet", [S["row_internet"], names[i]], False),
        row("row_tor", [S["row_tor"], S["value_tor_unused"] if i == "none" else S["value_direct"]], False),
        row("row_phone", [S["row_phone"], S["value_off"] if c == "off" else S["value_calls"]], False),
    ]


def place(rows):
    """Each row with its content top and bottom; the content's height."""
    y, out = PAD, []
    for r in rows:
        out.append((r, y, y + r["h"]))
        y += r["h"]
    return out, y + PAD


def max_offset(content):
    return max(0, content - (VB - VT))


def cut_pad():
    """The spacer that has a scan from the top find the card cut off on every page."""
    for pad in range(40, 3000, 10):
        placed, content = place(welcome_rows(pad))
        top, bottom = next((VT + a, VT + b) for r, a, b in placed if r["id"] == "card_carrier_choice")
        off, offs = 0, []
        while True:
            offs.append(off)
            if off >= max_offset(content):
                break
            off = min(off + STEP, max_offset(content))
        if all(not (VT < top - o and bottom - o < VB) for o in offs):
            return pad
    return 0


def screen():
    if st.get("screen") == "status":
        return status_rows(), [("poweroff_button", [S["power_off_now"]], 1950, 2250)]
    pad = cut_pad() if "cutcard" in bugs else 0
    return welcome_rows(pad), [("emergency_call", [S["emergency_call"]], 1950, 2250),
                               ("start_button", [S["start"]], 1950, 2250)]


rows, pinned = screen()
placed, content = place(rows)
off = min(max(st.get("offset", 0), 0), max_offset(content))


def visible():
    for r, a, b in placed:
        t, bot = VT + a - off, VT + b - off
        if bot > VT and t < VB:
            yield r, t, bot


if what == "dump":
    out = ['<?xml version="1.0"?><hierarchy>', '<node resource-id="" scrollable="true" bounds="[0,%d][%d,%d]">' % (VT, W, VB)]
    for r, t, bot in visible():
        vt, vb = max(t, VT), min(bot, VB)
        kids = []
        for k, text in enumerate(r["texts"]):
            kt, kb = t + 20 + TEXT_H * k, t + 20 + TEXT_H * (k + 1)
            if not r["merges"] and (kb <= VT or kt >= VB):
                continue
            kids.append('<node text=%s bounds="[0,%d][%d,%d]" />' % (quoteattr(text), min(max(kt, vt), vb), W,
                                                                     max(min(kb, vb), vt)))
        if r["id"] == "card_carrier_choice" and (t < VT or bot > VB):
            with open(os.path.join(os.environ["FAKE_DIR"], "cut-served"), "a") as f:
                f.write("cut\n")
        out.append('<node resource-id=%s checked="%s" enabled="%s" bounds="[0,%d][%d,%d]">%s</node>' % (
            quoteattr(r["id"]), str(r["checked"]).lower(), str(r["enabled"]).lower(), vt, W, vb, "".join(kids)))
    out.append("</node>")
    for k, (rid, texts, t, bot) in enumerate(pinned):
        x0 = 0 if len(pinned) == 1 else k * W // 2
        x1 = W if len(pinned) == 1 else (k + 1) * W // 2
        out.append('<node resource-id=%s checked="false" enabled="true" bounds="[%d,%d][%d,%d]"><node text=%s bounds="[%d,%d][%d,%d]" /></node>' % (
            quoteattr(rid), x0, t, x1, bot, quoteattr(texts[0]), x0, t, x1, bot))
    out.append("</hierarchy>")
    print("".join(out))
elif what == "tap":
    x, y = int(sys.argv[3]), int(sys.argv[4])
    hit = None
    if y >= VB:
        for k, (rid, _, t, bot) in enumerate(pinned):
            if t <= y < bot and (len(pinned) == 1 or k * W // 2 <= x < (k + 1) * W // 2):
                hit = {"id": rid, "enabled": True}
    elif y >= VT:
        hit = next((r for r, t, bot in visible() if max(t, VT) <= y < min(bot, VB)), None)
    if hit and hit["enabled"]:
        rid = hit["id"]
        if rid.startswith("internet_") and "taps_ignored" not in bugs:
            st["internet"] = rid[len("internet_"):]
        elif rid == "phone_off":
            st["phone"] = False
        elif rid == "phone_calls":
            st["phone"] = True
        elif rid == "position_button":
            st["pos"] = "looking"
            if "pos_no_switch_on" not in bugs:
                fd_write("location", "3")
        elif rid == "position_stop":
            st["pos"] = "stopped"
            fd_write("location", "0")
        elif rid == "position_hide" and "pos_hide_ignored" not in bugs:
            st["pos"] = "idle"
elif what == "leave":
    if st.get("pos") == "looking":
        st["pos"] = "stopped"
        if "pos_leave_stays_on" not in bugs:
            fd_write("location", "0")
elif what == "fix":
    if st.get("pos") == "looking" and fd_read("location", "0") != "0":
        st.update(pos="found", pos_lat=float(sys.argv[3]), pos_lon=float(sys.argv[4]), pos_acc=sys.argv[5],
                  pos_mock=sys.argv[6] == "test")
        if "pos_stays_on" not in bugs:
            fd_write("location", "0")
elif what == "swipe":
    y1, y2, ms = int(sys.argv[4]), int(sys.argv[6]), int(sys.argv[7]) if len(sys.argv) > 7 else 300
    st["offset"] = min(max(off + int((y1 - y2) * (1.5 if ms < 500 else 1.0)), 0), max_offset(content))
if what in ("tap", "swipe", "leave", "fix"):
    with open(path, "w") as f:
        json.dump(st, f)
FAKEUI
ui() { # STATE-JSON: the fake screen's state
    printf '%s\n' "$1" >"$work/ui-state.json"
    echo 1 >"$work/radio"
    echo LOADED,ABSENT >"$work/simstate"
    rm -f "$work/cut-served"
    : >"$work/log"
}
welcome_ui() { # GATE [BUGS...]
    local g=$1 b=''
    shift
    [ $# -eq 0 ] || b=$(printf '"%s",' "$@")
    ui "{\"screen\": \"welcome\", \"gate\": \"$g\", \"internet\": \"wifi\", \"phone\": false, \"radio\": \"On\", \"sim\": \"Unlocked\", \"bugs\": [${b%,}]}"
}
for g in off phone data; do
    welcome_ui "$g"
    mkdir -p "$work/shots-$g"
    if "$script" check-choices --gate "$g" --shots "$work/shots-$g" 2>"$work/err"; then
        [ "$(grep -c "gate $g: [a-z]*+[a-z]*: ok:" "$work/err")" = 6 ] &&
            [ "$(find "$work/shots-$g" -name 'welcome-choice-*.png' | wc -l)" = 6 ] &&
            grep -q '"internet": "wifi"' "$work/ui-state.json" && grep -q '"phone": false' "$work/ui-state.json" &&
            pass "check-choices --gate $g: six attempts, six screenshots, Wi-Fi and Phone off again" ||
            bad "check-choices --gate $g: $(cat "$work/err")"
    else
        bad "check-choices --gate $g failed: $(cat "$work/err")"
    fi
done
# What each gate lets the walk choose (the fake screen applies Welcome's
# rules): mobile data straight after Phone off selects calls and texts.
welcome_ui data
"$script" check-choices --gate data 2>"$work/err"
grep -q 'gate data: mobile+off: ok: internet mobile, phone calls' "$work/err" &&
    grep -q 'gate data: none+calls: ok: internet none, phone calls, tor hidden' "$work/err" &&
    [ "$(grep -n 'gate data: wifi+off: ok: internet wifi, phone off' "$work/err" | cut -d: -f1)" -lt \
        "$(grep -n 'gate data: mobile+off: ok' "$work/err" | cut -d: -f1)" ] &&
    pass "check-choices --gate data: mobile data right after Phone off keeps calls; no Tor rows without Internet" ||
    bad "check-choices, data walk: $(cat "$work/err")"
welcome_ui off
"$script" check-choices --gate off 2>"$work/err"
grep -q 'gate off: mobile+calls: ok: internet wifi, phone off' "$work/err" &&
    pass "check-choices --gate off: the refused rows change nothing" || bad "check-choices, off walk: $(cat "$work/err")"
# A carrier card that no page of the scan shows whole (cut off by an edge,
# Compose lists only its texts on screen): read again once scrolled wholly
# into view, never from a cut-off page.
for g in phone data; do
    welcome_ui "$g" cutcard
    if "$script" check-choices --gate "$g" 2>"$work/err"; then
        grep -q 'card_carrier_choice is cut off by an edge on every page of the scan' "$work/err" && [ -s "$work/cut-served" ] &&
            pass "check-choices --gate $g: a card cut off on every page is read whole once in view" ||
            bad "check-choices, cut-off card at $g: did not take the cut-off path: $(cat "$work/err")"
    else
        bad "check-choices with a card cut off on every page ($g): $(cat "$work/err")"
    fi
done
# Each fault the checks must catch.
for case_ in "phone mobile_enabled" "off calls_enabled" "data wrong_checked" "data offline_text" "data radio_wrong" "phone tor_always" \
    "data taps_ignored" "data sim" "told-data checked-as-phone" "data calls_follow_phone" "phone card_wrong"; do
    # shellcheck disable=SC2086 # two words
    set -- $case_
    gate=$1
    case $2 in
        checked-as-phone) welcome_ui data; gate=phone; want='internet_mobile: enabled is true, expected false' ;;
        sim) welcome_ui data; echo PIN_REQUIRED >"$work/simstate"; want='the SIM line says' ;;
        *)
            welcome_ui "$1" "$2"
            case $2 in
                mobile_enabled) want='internet_mobile: enabled is true' ;;
                calls_enabled) want='phone_calls: enabled is true, expected false' ;;
                wrong_checked) want='phone_off: checked is' ;;
                offline_text) want='a text says "offline"' ;;
                radio_wrong) want='the radio line says' ;;
                tor_always) want="Tor's rows are shown without Internet" ;;
                taps_ignored) want='internet_mobile: checked is false, expected true' ;;
                calls_follow_phone) want='gate data: mobile+off: FAILED: phone_off: checked is true, expected false' ;;
                card_wrong) want="card_carrier_choice does not say 'roughly where you are'" ;;
            esac
            ;;
    esac
    if "$script" check-choices --gate "$gate" 2>"$work/err"; then bad "check-choices passed with $case_"; else
        grep -qF "$want" "$work/err" && pass "check-choices fails with $case_" || bad "check-choices with $case_: $(cat "$work/err")"
    fi
done
# Nothing that could dial, and no setting written.
if grep -Eq 'input text|KEYCODE_(CALL|ENDCALL|[0-9])|settings put|cmd phone|am start' "$work/log"; then
    bad "check-choices sent something it should not: $(cat "$work/log")"
else
    pass "check-choices only taps, scrolls, dumps and reads"
fi
status_ui() { # INTERNET CELL RADIO [BUGS...]
    local i=$1 c=$2 r=$3 b=''
    shift 3
    [ $# -eq 0 ] || b=$(printf '"%s",' "$@")
    ui "{\"screen\": \"status\", \"gate\": \"phone\", \"internet\": \"$i\", \"phone\": true, \"cell\": \"$c\", \"radio\": \"$r\", \"sim\": \"Unlocked\", \"bugs\": [${b%,}]}"
    case $r in On) echo 1 ;; Off) echo 0 ;; *) echo 2 ;; esac >"$work/radio"
}
status_ui wifi phone On
"$script" check-phone --internet wifi --cell phone 2>"$work/err" && grep -q 'VoLTE Not known yet' "$work/err" &&
    pass "check-phone: Wi-Fi with calls and texts, the radio on" || bad "check-phone: $(cat "$work/err")"
status_ui none off Off
"$script" check-phone --internet none --cell off 2>"$work/err" &&
    pass "check-phone: no Internet, Phone off, the radio off: Offline said, and allowed" || bad "check-phone, offline: $(cat "$work/err")"
status_ui none phone Off
"$script" check-phone --internet none --cell phone 2>"$work/err" &&
    pass "check-phone: no Internet, calls and texts, the radio off for now: no Offline" || bad "check-phone, none+calls: $(cat "$work/err")"
for case_ in "wifi phone On offline_text" "none off On offline_text" "none phone Off offline_text" "wifi off On volte_wrong" \
    "wifi phone On volte_wrong"; do
    # shellcheck disable=SC2086 # four words
    set -- $case_
    status_ui "$@"
    if "$script" check-phone --internet "$1" --cell "$2" 2>"$work/err"; then bad "check-phone passed with $case_"; else
        pass "check-phone fails with $case_ ($(tail -n 1 "$work/err" | cut -c1-120))"
    fi
done
status_ui wifi phone On
if "$script" check-phone --internet mobile --cell phone 2>"$work/err"; then bad "check-phone passed the wrong Internet"; else
    grep -q "row_internet does not say 'Internet | Mobile data'" "$work/err" && pass "check-phone: the wrong Internet line fails" ||
        bad "check-phone, wrong Internet: $(cat "$work/err")"
fi
# 12. WEL10: the emergency card, its CI hook and Show my position, on the
#     fake screen (which draws the card by Welcome's rules). Each check
#     passes as it should, and fails with each fault it must catch; none
#     taps, types or dials anything it should not, and each puts back what
#     it changed, also after a failure.
wel10_reset() {
    rm -f "$work/ecc" "$work/eccfail" "$work/hookstates" "$work/hookhang" "$work/hookstuck" "$work/location" \
        "$work/testprovider" "$work/noprovider" "$work/appops" "$work/uid"
    echo 0 >"$work/calls"
}
card_ui() { # SCREEN RADIO SIMSTATE IMS [BUGS...]: the Welcome screen before Start, or the status screen in a Phone-mode session
    local screen=$1 r=$2 sims=$3 ims=$4 b='' sim
    shift 4
    [ $# -eq 0 ] || b=$(printf '"%s",' "$@")
    case ${sims%%,*} in
        LOADED) sim=Unlocked ;;
        ABSENT) sim='None in the phone' ;;
        PIN_REQUIRED) sim='Locked: needs its PIN' ;;
        *) sim='Not ready' ;;
    esac
    wel10_reset
    if [ "$screen" = welcome ]; then
        ui "{\"screen\": \"welcome\", \"gate\": \"phone\", \"internet\": \"wifi\", \"phone\": false, \"radio\": \"$r\", \"sim\": \"$sim\", \"bugs\": [${b%,}]}"
    else
        ui "{\"screen\": \"status\", \"gate\": \"phone\", \"internet\": \"wifi\", \"phone\": true, \"cell\": \"phone\", \"radio\": \"$r\", \"sim\": \"$sim\", \"ims\": \"$ims\", \"bugs\": [${b%,}]}"
    fi
    echo "$sims" >"$work/simstate"
    case $r in On) echo 1 ;; Off) echo 0 ;; *) echo 2 ;; esac >"$work/radio"
}
# Nothing that could dial, no text typed, and Android's list only printed.
reads_only() {
    ! grep -Eq 'input tap|input text|KEYCODE_(CALL|ENDCALL|[0-9]|STAR|POUND)|tel:|CALL_EMERGENCY|settings put' "$work/log" &&
        ! grep 'emergency-number-test-mode' "$work/log" | grep -qvx 'shell cmd phone emergency-number-test-mode -p'
}
# check-emergency-card: the cases that must pass, with the lines they must read
# (after "|", quotes and all; only the words before it are split).
# shellcheck disable=SC2089
for case_ in "welcome Off LOADED unknown|state lines 'radio_off'" "welcome Off ABSENT unknown|state lines 'no_sim radio_off'" \
    "welcome Off PIN_REQUIRED unknown|state lines 'sim_locked radio_off'" "welcome On LOADED unknown|state lines 'none'" \
    "status On LOADED none|state lines 'volte'" "status Off LOADED none|state lines 'radio_off'" "status On LOADED unknown|state lines 'none'"; do
    want=${case_#*|}
    # shellcheck disable=SC2086,SC2090 # four words
    card_ui ${case_%|*}
    if "$script" check-emergency-card 2>"$work/err"; then
        grep -qF "$want" "$work/err" && grep -q 'number 1234 (2 listed by Android)' "$work/err" && reads_only &&
            pass "check-emergency-card: ${case_%|*}: $want, the number Android's, nothing tapped" ||
            bad "check-emergency-card ${case_%|*}: $(cat "$work/err"); log: $(cat "$work/log")"
    else
        bad "check-emergency-card ${case_%|*} failed: $(cat "$work/err")"
    fi
done
# Several numbers Android ranks alike: each Android's, with their own line.
card_ui welcome Off ABSENT unknown card_several
echo '[000, 08, 112]' >"$work/ecc"
"$script" check-emergency-card 2>"$work/err" && grep -q 'number 000 08 112 (3 listed by Android)' "$work/err" && reads_only &&
    pass "check-emergency-card: several numbers ranked alike, each Android's, with their line" || bad "check-emergency-card, several: $(cat "$work/err")"
# Android lists no number: the card says so, and passes.
card_ui welcome Off LOADED unknown
echo '[]' >"$work/ecc"
"$script" check-emergency-card 2>"$work/err" && grep -q 'number none (0 listed by Android)' "$work/err" &&
    pass "check-emergency-card: no number listed, and the card says so" || bad "check-emergency-card, none listed: $(cat "$work/err")"
# Each fault it must catch.
# shellcheck disable=SC2089 # quotes in the messages wanted
for case_ in "Off LOADED card_wrong_number|is not one Android lists" "Off LOADED card_says_none|the card shows no number" \
    "Off LOADED card_several_foreign|the card's number 4321 is not one Android lists" \
    "Off LOADED card_several_detail|the card shows several numbers, but its line is not the one for several" \
    "Off LOADED card_no_radio_line|state lines ''" "On LOADED card_extra_radio_line|state lines 'radio_off', expected ''" \
    "Off ABSENT card_no_sim_line|state lines 'radio_off', expected 'no_sim radio_off'" \
    "Off PIN_REQUIRED card_no_sim_line|expected 'sim_locked radio_off'" "Off LOADED card_no_other_phone|the other-phone line is missing" \
    "On LOADED card_other_alone|the other-phone line shows without a state line" "Off LOADED card_discouraging|discourages an emergency call" \
    "Off LOADED eccfail|could not be printed" "Off LOADED notroot|needs adb as root" "Off LOADED hookset|the test hook debug.antumbra.emergency_states is set"; do
    want=${case_#*|}
    # shellcheck disable=SC2086,SC2090 # three words
    set -- ${case_%|*}
    case $3 in
        eccfail) card_ui welcome "$1" "$2" unknown; touch "$work/eccfail" ;;
        notroot) card_ui welcome "$1" "$2" unknown; echo 2000 >"$work/uid" ;;
        hookset) card_ui welcome "$1" "$2" unknown; printf no_sim >"$work/hookstates" ;;
        *) card_ui welcome "$1" "$2" unknown "$3" ;;
    esac
    if "$script" check-emergency-card 2>"$work/err"; then bad "check-emergency-card passed with $3"; else
        grep -qF "$want" "$work/err" && reads_only && pass "check-emergency-card fails with $3" ||
            bad "check-emergency-card with $3: $(cat "$work/err")"
    fi
done
# The status screen's VoLTE line missing in a Phone-mode session with IMS not registered.
card_ui status On LOADED none card_no_other_phone
if "$script" check-emergency-card 2>"$work/err"; then bad "check-emergency-card passed without the other-phone line after Start"; else
    grep -qF 'the other-phone line is missing' "$work/err" && pass "check-emergency-card after Start: the VoLTE line needs the other-phone line" ||
        bad "check-emergency-card after Start: $(cat "$work/err")"
fi

# check-emergency-states: each case through the hook, the hook cleared afterwards whatever happens.
# The property empty, and its last write the clearing one.
hook_cleared() {
    [ -z "$(cat "$work/hookstates" 2>/dev/null)" ] &&
        [ "$(grep '^shell setprop debug.antumbra.emergency_states ' "$work/log" | tail -n 1)" = "shell setprop debug.antumbra.emergency_states ''" ]
}
card_ui welcome Off LOADED unknown
mkdir -p "$work/states"
if "$script" check-emergency-states --shots "$work/states" 2>"$work/err"; then
    [ "$(grep -c '^welcome-adb: case [a-z_]*: ok' "$work/err")" = 8 ] &&
        [ "$(find "$work/states" -name 'emergency-state-*.png' | wc -l)" = 8 ] &&
        grep -qx 'shell setprop debug.antumbra.emergency_states no_sim,sim_locked,sim_unusable,radio_off,volte' "$work/log" &&
        grep -qx 'shell setprop debug.antumbra.emergency_states number_unreadable' "$work/log" &&
        grep -q "case all: ok: lines 'no_sim sim_locked sim_unusable radio_off volte'" "$work/err" &&
        hook_cleared && reads_only &&
        pass "check-emergency-states: every state's text, all five, both number lines; the hook cleared and the real lines back" ||
        bad "check-emergency-states: $(cat "$work/err"); log: $(cat "$work/log")"
else
    bad "check-emergency-states failed: $(cat "$work/err")"
fi
for case_ in "hook_ignored|a release build ignores debug.antumbra.emergency_states" "hook_text_changed|emergency_state_no_sim says" \
    "hook_sticks|did not show its real lines again"; do
    card_ui welcome Off LOADED unknown "${case_%|*}"
    if "$script" check-emergency-states 2>"$work/err"; then bad "check-emergency-states passed with ${case_%|*}"; else
        grep -qF "${case_#*|}" "$work/err" && hook_cleared &&
            { [ "${case_%|*}" != hook_ignored ] || ! grep -q 'setprop debug.antumbra.emergency_states sim_locked' "$work/log"; } &&
            pass "check-emergency-states fails with ${case_%|*}, and clears the hook" ||
            bad "check-emergency-states with ${case_%|*}: $(cat "$work/err"); log: $(cat "$work/log")"
    fi
done
# Killed while the hook is set: still cleared.
card_ui welcome Off LOADED unknown
touch "$work/hookhang"
timeout 6 "$script" check-emergency-states 2>"$work/err" && bad "check-emergency-states was not killed" ||
    { grep -qx 'shell setprop debug.antumbra.emergency_states no_sim' "$work/log" && [ -z "$(cat "$work/hookstates" 2>/dev/null)" ] &&
        pass "check-emergency-states clears the hook when it is killed" ||
        bad "the hook stayed set after a kill: $(cat "$work/hookstates"); $(cat "$work/err")"; }

# check-position: the test provider's fix (and the emulator's receiver) on screen, then nothing left behind.
undone() { [ ! -e "$work/testprovider" ] && [ "$(cat "$work/appops" 2>/dev/null)" = default ] && grep -q 'remove-test-provider gps' "$work/log"; }
never_writes() { ! grep -Eq 'settings put|settings delete|set-location-enabled|input text|tel:|KEYCODE_CALL|assisted_gps|pm revoke|pm grant|appops set org.antumbra' "$work/log"; }
at() { grep -n -m 1 -- "$1" "$work/log" | cut -d: -f1 | grep . || echo 999; }
for case_ in "welcome test KEYCODE_SLEEP" "status test KEYCODE_HOME" "welcome gnss KEYCODE_SLEEP"; do
    # shellcheck disable=SC2086 # three words
    set -- $case_
    card_ui "$1" Off LOADED none
    if "$script" check-position --source "$2" --screenshot "$work/looking.png" 2>"$work/err"; then
        [ "$(cat "$work/location")" = 0 ] && undone && never_writes && grep -qx "shell input keyevent $3" "$work/log" &&
            grep -q 'secure: yes' "$work/err" && grep -q 'gps only: yes' "$work/err" && grep -q 'Location off within 10 s' "$work/err" &&
            if [ "$2" = test ]; then
                [ "$(at 'appops set com.android.shell android:mock_location allow')" -lt "$(at 'add-test-provider gps')" ] &&
                    grep -q 'set-test-provider-location gps --location 10.12345,-140.54321 --accuracy 5' "$work/log"
            else
                grep -qx 'emu geo fix -140.54321 10.12345' "$work/log" && ! grep -q 'add-test-provider' "$work/log"
            fi &&
            [ "$(head -c 4 "$work/looking.png" | od -An -c | tr -d ' ')" = '211PNG' ] &&
            pass "check-position: $1, $2: the position on screen as written, Location off, nothing kept, left with $3" ||
            bad "check-position $case_: $(cat "$work/err"); log: $(cat "$work/log")"
    else
        bad "check-position $case_ failed: $(cat "$work/err")"
    fi
done
for case_ in "pos_no_switch_on|Location did not come on within 15 s" "pos_stays_on|Location stayed on after the position was found" \
    "pos_leave_stays_on|Location stayed on after leaving the screen" "pos_wrong_hemisphere|the latitude reads '10.12345° S'" \
    "pos_no_mock_line|no line says the position comes from a test location" "pos_not_secure|is not secure" \
    "pos_stored|the coordinates are in Welcome's files" "pos_logged|the coordinates are in Welcome's log" \
    "pos_property|the coordinates are in a property" "pos_fused|not the gps provider's alone: fused" \
    "pos_hide_ignored|Hide position left the coordinates on screen" "pos_refused|Show my position is not offered" \
    "noprovider|the test provider could not be set up"; do
    if [ "${case_%|*}" = noprovider ]; then card_ui welcome Off LOADED none; touch "$work/noprovider"; else card_ui welcome Off LOADED none "${case_%|*}"; fi
    if "$script" check-position 2>"$work/err"; then bad "check-position passed with ${case_%|*}"; else
        grep -qF "${case_#*|}" "$work/err" && [ "$(cat "$work/appops" 2>/dev/null)" = default ] && [ ! -e "$work/testprovider" ] && never_writes &&
            pass "check-position fails with ${case_%|*}, and undoes the test" ||
            bad "check-position with ${case_%|*}: $(cat "$work/err"); log: $(cat "$work/log")"
    fi
done
# Refused before anything is changed: a call in progress, Location already on, no root.
for case_ in "call|a call is in progress; Show my position is not pressed" "locationon|Location is on before the check" "notroot|needs adb as root"; do
    card_ui welcome Off LOADED none
    case ${case_%|*} in call) echo 2 >"$work/calls" ;; locationon) echo 3 >"$work/location" ;; notroot) echo 2000 >"$work/uid" ;; esac
    if "$script" check-position 2>"$work/err"; then bad "check-position passed with ${case_%|*}"; else
        grep -qF "${case_#*|}" "$work/err" && ! grep -Eq 'input tap|appops|location providers|emu ' "$work/log" &&
            pass "check-position refuses and changes nothing (${case_%|*})" || bad "check-position with ${case_%|*}: $(cat "$work/err"); log: $(cat "$work/log")"
    fi
done
# clear-position-test: a search left running is stopped with Welcome's own Stop.
card_ui welcome Off LOADED none
python3 -I -c 'import json,sys; p=sys.argv[1]; s=json.load(open(p)); s["pos"]="looking"; json.dump(s, open(p, "w"))' "$work/ui-state.json"
echo 3 >"$work/location"
touch "$work/testprovider"
"$script" clear-position-test 2>"$work/err" && [ "$(cat "$work/location")" = 0 ] && undone && grep -q "stopped with Welcome's Stop" "$work/err" &&
    never_writes && pass "clear-position-test stops a search with Welcome's Stop and removes the test provider" ||
    bad "clear-position-test: $(cat "$work/err"); log: $(cat "$work/log")"
wel10_reset

rm -f "${work:?}/ui-state.json"
export PATH="$PATH_BEFORE_UI"

# 11. WEL8: check-module-cell, as check-module-word.
: >"$work/log"
if "$script" check-module-cell 2>"$work/err"; then
    [ "$(grep -c 'method module_cell' "$work/log")" = 3 ] &&
        ! grep 'method module_cell --extra v:i:1' "$work/log" | grep -qv 'gate:s:off --extra cell:s:none --extra radio:s:unknown' &&
        pass "check-module-cell: only root's word is taken, and only the most careful word is sent" ||
        bad "check-module-cell sent other words: $(cat "$work/log")"
else
    bad "check-module-cell: $(cat "$work/err")"
fi
for case_ in cellshelltakes cellmalformedtaken cellrootrefused uid; do
    if [ "$case_" = uid ]; then echo 2000 >"$work/uid"; else touch "$work/$case_"; fi
    if "$script" check-module-cell 2>"$work/err"; then bad "check-module-cell passed with $case_"; else
        pass "check-module-cell fails with $case_ ($(tail -n 1 "$work/err"))"
    fi
    rm -f "${work:?}/${case_:?}" "${work:?}/uid"
done

[ "$fail" = 0 ] || exit 1
echo "all welcome-adb.sh cases passed"
