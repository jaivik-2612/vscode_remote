#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck disable=SC2015 # "A && pass || bad" is fine: pass never fails.
#
# Runs welcome-adb.sh against a fake adb: the screen logic (finding
# controls, typing bridge lines), the test hook rule, the provider checks
# and check-policies / check-addon / check-emergency. No device or emulator
# needed.
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

# 6. expect counts bridge lines.
"$script" expect started=1 bridges=2 unsafe_browser=0 2>"$work/err" && pass "expect" || bad "expect: $(cat "$work/err")"

[ "$fail" = 0 ] || exit 1
echo "all welcome-adb.sh cases passed"
