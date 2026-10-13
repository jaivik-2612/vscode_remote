#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck disable=SC2015 # "A && pass || bad" is fine: pass never fails.
#
# Runs welcome-adb.sh against a fake adb: the screen logic (finding
# controls, typing bridge lines), the test hook rule, the provider checks
# and check-policies / check-addon / check-emergency / check-power-menu. No
# device or emulator needed.
#
#   ci/test-welcome-adb.sh        exit status 0 when every case passed

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
case "$*" in
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
        if [ "$(cat "$d/calls")" = none ]; then echo "Can't find service: telephony.registry"; exit 0; fi
        printf '%s\n' 'last known state:' 'Phone Id=0' "  mCallState=$(cat "$d/calls")" ;;
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
        printf 'Row: 0 bridges=192.0.2.7:9001 0123456789ABCDEF0123456789ABCDEF01234567\n[2001:db8::1]:443\n' ;;
    "shell content query --uri content://org.antumbra.welcome.state/session --projection "*)
        echo "Row: 0 started=1, tor_mode=bridges, mac=new, admin=1, unsafe_browser=0, persistent=0, session_id=5f0c" ;;
    *) echo "fake adb: unexpected: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$work/bin/adb"

# Every control on one screen, as uiautomator lists Compose test tags.
node() { printf '<node resource-id="%s" text="%s" checked="%s" bounds="[0,%d][1080,%d]">%s</node>\n' "$1" "${3:-}" "${2:-false}" "$4" "$(($4 + 100))" "${5:-}"; }
{
    echo '<?xml version="1.0"?><hierarchy>'
    y=0
    for id in start_button tor_direct tor_bridges tor_offline bridges_custom bridges_text switch_admin \
        switch_unsafe_browser status_title poweroff_button emergency_call; do
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

# 6. expect counts bridge lines.
"$script" expect started=1 bridges=2 unsafe_browser=0 2>"$work/err" && pass "expect" || bad "expect: $(cat "$work/err")"

[ "$fail" = 0 ] || exit 1
echo "all welcome-adb.sh cases passed"
