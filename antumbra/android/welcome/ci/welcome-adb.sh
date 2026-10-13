#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Drives the Antumbra Welcome app over adb, by hand or from a test script
# (the CI emulator job has its own driver, antumbra/android/ci/
# emulator-antumbra.sh, with the same test tags, and calls this script only
# for 'check-emergency', 'check-power-menu', 'check-policies --keep-adb' and
# 'check-addon'). It
# works the screen the way a person does (uiautomator finds each control by
# its test tag, then 'input tap'), and checks results through the state
# provider and the system's own dumps.
#
# Welcome switches USB debugging off as soon as it is the device owner, in
# every session. Only a debug (debuggable, testOnly) build honours the test
# hook 'debug.antumbra.keep_adb=1', which leaves adb on; 'provision' sets it
# unless --no-keep-adb is given. With a release build adb goes away at
# 'provision'.
#
#   welcome-adb.sh [-s SERIAL] COMMAND [ARGS]
#
# Commands:
#   install APK               Install or update (debug builds are testOnly: 'install -t').
#   provision [--no-keep-adb] Set the test hook, make Welcome the device owner, then wait
#                             for its screen. The device must have no accounts (a fresh
#                             emulator has none).
#   wait-welcome [SECONDS]    Wait until the Start button is on screen (default 60).
#   start [OPTIONS]           Make the choices on screen and press Start, then wait
#                             for the status screen and check the provider's row.
#       --tor direct|bridges|offline   Default: direct.
#       --bridges-file FILE            With --tor bridges: type these lines (plain
#                                      bridges; v0 refuses obfs4, webtunnel, meek_lite).
#       --keep-mac --admin
#       --expect-adb-loss              Clear the test hook first: Start then switches USB
#                                      debugging off and adb disconnects; succeed when it does.
#   query                     Print the provider's row (runs as the shell user, uid 2000).
#   expect KEY=VALUE...       Fail unless the row has these values (bridges: give a count,
#                             as bridges=2).
#   check-policies [--admin] [--keep-adb] [--wifi-locked]
#                             Check user 0's device-owner restrictions, adb, automatic time
#                             and the time zone after Start. --keep-adb: the test hook is on;
#                             --wifi-locked: an offline session or one without the add-on.
#   check-addon [SECONDS]     Fail unless the status screen's firewall row shows the rules
#                             of antumbra.fw.armed (Welcome could read it). Opens the status
#                             screen and scrolls to the row; gives up after SECONDS (60).
#   check-emergency [--screenshot FILE.png] [--wait SECONDS]
#                             Before Start, with Welcome in its lock task: open the
#                             emergency dialer with Welcome's Emergency call button, then
#                             with 'am start' in a task of its own (as the power menu does);
#                             each time check the dialer is in front, press Back, and check
#                             Welcome is in front and still locked. It never dials: it
#                             touches nothing in the dialer, and no call may be in progress
#                             before it starts or after each opening (a call state it cannot
#                             read fails too). --screenshot saves the dialer's screen;
#                             --wait: how long each screen may take to come up (15).
#   check-power-menu [--screenshot FILE.png] [--wait SECONDS]
#                             Before Start, with Welcome in its lock task (WEL12): the
#                             power menu shows an item labelled Emergency. Presence only,
#                             and only while Android's emergency affordance is off
#                             (force_emergency_affordance and emergency_affordance_needed
#                             unset or 0), when that item is the one that opens the
#                             emergency dial pad; otherwise it refuses, since the item
#                             would call at once. It changes no emergency setting: it
#                             opens the menu with a long press on power
#                             (power_button_long_press=1 meanwhile), finds SystemUI's menu
#                             and its "Emergency" in a uiautomator dump, and closes the
#                             menu (Back, then the screen off and on). It never presses the
#                             item and never dials. The menu is closed and the long-press
#                             setting put back afterwards, also after a failure
#                             ('clear-power-menu-test'), and Welcome must be in front and
#                             still locked.
#   clear-power-menu-test     Undo what check-power-menu may leave: the power menu closed
#                             (Back, then the screen off and on), power_button_long_press as
#                             it was. Checks both.
#   screenshot FILE.png       Save the screen.
#   power-off-tile            Add the Quick power off tile, click it, and wait until the
#                             device has restarted (the boot id changes).
#   remove                    Clear the test hook, remove the test device owner (testOnly
#                             builds only) and the app.
#
# Needs adb and python3 on the host. Exit status 0 means every check passed.

set -euo pipefail

PKG=org.antumbra.welcome
ADMIN=$PKG/.AdminReceiver
TILE=$PKG/.QuickPowerOffTileService
WELCOME=$PKG/.WelcomeActivity
# Intent.ACTION_DIAL_EMERGENCY: the system's emergency dial pad.
DIAL_EMERGENCY=android.intent.action.DIAL_EMERGENCY
URI=content://org.antumbra.welcome.state/session
UI_DUMP=/data/local/tmp/antumbra-welcome-ui.xml
HOOK=debug.antumbra.keep_adb
# Where check-power-menu keeps power_button_long_press's earlier value
# ("null" when unset), so that clear-power-menu-test can put it back.
LONG_PRESS_SAVE=/data/local/tmp/antumbra-long-press-saved

adb_args=()
if [ "${1:-}" = "-s" ]; then
    adb_args=(-s "$2")
    shift 2
fi

die() { echo "welcome-adb: $*" >&2; exit 1; }
say() { echo "welcome-adb: $*" >&2; }
a() { adb "${adb_args[@]}" "$@"; }
sh_() { a shell "$@" | tr -d '\r'; }

# The screen's accessibility tree as XML.
dump_ui() {
    a shell uiautomator dump "$UI_DUMP" >/dev/null 2>&1 || return 1
    a exec-out cat "$UI_DUMP"
}

# Prints "x y checked" for the node whose resource-id is $1 (from the XML
# on stdin), or nothing. Compose test tags appear as resource ids because
# the app sets testTagsAsResourceId.
find_node() {
    python3 -I -c '
import sys, xml.etree.ElementTree as ET
want = sys.argv[1]
try:
    root = ET.fromstring(sys.stdin.read())
except ET.ParseError:
    sys.exit(0)
for n in root.iter("node"):
    if n.get("resource-id") == want:
        b = n.get("bounds", "").replace("][", ",").strip("[]").split(",")
        x1, y1, x2, y2 = (int(v) for v in b)
        print((x1 + x2) // 2, (y1 + y2) // 2, n.get("checked", "false"))
        break
' "$1"
}

# Prints the text of the node whose resource-id is $1 and of everything
# inside it, joined by " | " (from the XML on stdin).
node_text() {
    python3 -I -c '
import sys, xml.etree.ElementTree as ET
want = sys.argv[1]
try:
    root = ET.fromstring(sys.stdin.read())
except ET.ParseError:
    sys.exit(0)
for n in root.iter("node"):
    if n.get("resource-id") == want:
        print(" | ".join(t for t in (m.get("text", "") for m in n.iter("node")) if t))
        break
' "$1"
}

screen_size() {
    sh_ wm size | sed -n 's/.*: \([0-9]*\)x\([0-9]*\).*/\1 \2/p' | tail -n 1
}

# Finds $1 on screen, scrolling down (then up) through the page if needed.
# Prints "x y checked".
locate() {
    local id=$1 node w h i
    read -r w h < <(screen_size)
    for i in 1 2 3 4 5 6 7 8; do
        node=$(dump_ui | find_node "$id" || true)
        if [ -n "$node" ]; then echo "$node"; return 0; fi
        if [ "$i" -le 5 ]; then
            a shell input swipe $((w / 2)) $((h * 6 / 10)) $((w / 2)) $((h * 3 / 10)) 300
        else
            a shell input swipe $((w / 2)) $((h * 3 / 10)) $((w / 2)) $((h * 8 / 10)) 300
        fi
    done
    return 1
}

tap() {
    local x y checked
    read -r x y checked < <(locate "$1") || die "control '$1' not found on screen"
    a shell input tap "$x" "$y"
}

# Sets the switch $1 to $2 (true/false).
set_switch() {
    local x y checked
    read -r x y checked < <(locate "$1") || die "switch '$1' not found on screen"
    [ "$checked" = "$2" ] || a shell input tap "$x" "$y"
}

wait_for() {
    local id=$1 seconds=${2:-60} end=$((SECONDS + ${2:-60}))
    while [ $SECONDS -lt $end ]; do
        if dump_ui | find_node "$id" | grep -q .; then return 0; fi
        sleep 2
    done
    die "'$id' did not appear within $seconds s"
}

# Types one bridge line into the focused field. 'input text' takes %s for
# a space; anything else outside this set is refused rather than escaped.
# (A ']' must come first in a bracket expression; '\]' would end it.)
type_line() {
    local line=$1 re='^[][A-Za-z0-9 .:=/+_,@-]+$'
    [[ $line =~ $re ]] || die "bridge line has characters this script cannot type: $line"
    a shell input text "'${line// /%s}'"
}

hook_on() { [ "$(sh_ getprop "$HOOK")" = 1 ]; }

row() {
    sh_ content query --uri "$URI" --projection started:tor_mode:mac:admin:unsafe_browser:persistent:session_id
}

bridge_count() {
    # One bridge per line after "bridges=" (empty: none).
    sh_ content query --uri "$URI" --projection bridges | sed '1s/^Row: 0 bridges=//' | grep -c . || true
}

value_of() {
    # $1: key; the row on stdin ("Row: 0 started=1, tor_mode=direct, ...").
    sed 's/^Row: 0 //' | tr ',' '\n' | sed 's/^ *//' | sed -n "s/^$1=//p"
}

cmd_expect() {
    local r pair key want got
    r=$(row)
    say "row: $r"
    for pair in "$@"; do
        key=${pair%%=*}
        want=${pair#*=}
        if [ "$key" = bridges ]; then
            got=$(bridge_count)
        else
            got=$(printf '%s\n' "$r" | value_of "$key")
        fi
        [ "$got" = "$want" ] || die "$key is '$got', expected '$want'"
    done
    say "provider row matches: $*"
}

cmd_start() {
    local tor=direct file="" keep_mac=false admin=false expect_loss=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --tor) tor=$2; shift ;;
            --bridges-file) file=$2; shift ;;
            --builtin-bridges) die "start: the built-in (obfs4) bridges need lyrebird and are disabled in v0; use --bridges-file with plain bridges" ;;
            --unsafe-browser) die "start: the Unsafe Browser is disabled in v0 (coming later)" ;;
            --keep-mac) keep_mac=true ;;
            --admin) admin=true ;;
            --expect-adb-loss) expect_loss=true ;;
            *) die "start: unknown option $1" ;;
        esac
        shift
    done
    case "$tor" in direct|bridges|offline) ;; *) die "start: --tor must be direct, bridges or offline" ;; esac
    if [ "$tor" = bridges ] && [ -z "$file" ]; then die "start: --tor bridges needs --bridges-file"; fi
    if [ "$expect_loss" = false ] && ! hook_on; then
        die "the test hook $HOOK is not set: Start would switch USB debugging off and adb would disconnect; run 'provision' (debug build), or add --expect-adb-loss"
    fi

    wait_for start_button 60
    tap "tor_$tor"
    if [ "$tor" = bridges ]; then
        [ -r "$file" ] || die "cannot read $file"
        tap bridges_custom
        tap bridges_text
        local first=1 line
        while IFS= read -r line || [ -n "$line" ]; do
            [ -n "${line// /}" ] || continue
            [ "$first" = 1 ] || a shell input keyevent KEYCODE_ENTER
            type_line "$line"
            first=0
        done < "$file"
        a shell input keyevent KEYCODE_BACK   # close the keyboard
    fi
    set_switch switch_mac "$([ "$keep_mac" = true ] && echo false || echo true)"
    set_switch switch_admin "$admin"
    # Without the hook, Welcome switches debugging off at Start.
    if [ "$expect_loss" = true ]; then a shell setprop "$HOOK" 0; fi
    tap start_button

    if [ "$expect_loss" = true ]; then
        local end=$((SECONDS + 90))
        while [ $SECONDS -lt $end ]; do
            if ! a shell true >/dev/null 2>&1; then
                say "adb disconnected after Start, as expected without the test hook"
                return 0
            fi
            sleep 2
        done
        die "adb still answers 90 s after Start without the test hook"
    fi

    wait_for status_title 60
    local expect=(started=1 "tor_mode=$tor" "mac=$([ "$keep_mac" = true ] && echo keep || echo new)"
        "admin=$([ "$admin" = true ] && echo 1 || echo 0)" unsafe_browser=0 persistent=0)
    if [ "$tor" != bridges ]; then expect+=(bridges=0); fi
    cmd_expect "${expect[@]}"
}

# Prints user 0's effective restrictions, one per line, from 'dumpsys user'
# on stdin; fails if that block is missing. Only this block counts: the
# dump also lists the guest's default restrictions (no_config_wifi among
# them) and each user type's defaults.
effective_restrictions() {
    awk '
        /^[^ ]/ { user0 = 0 }
        /^  UserInfo\{/ { user0 = ($0 ~ /^  UserInfo\{0:/); inside = 0; next }
        user0 && /^    Effective restrictions:/ { inside = 1; found = 1; next }
        inside && /^      [^ ]/ { print $1; next }
        { inside = 0 }
        END { exit !found }
    '
}

# Fails (fail=1) unless restriction $1 is set ($2 = yes) or not set ($2 = no).
restriction() {
    if [ "$2" = yes ]; then
        grep -qxF "$1" <<<"$dump" || { say "missing restriction $1"; fail=1; }
    else
        ! grep -qxF "$1" <<<"$dump" || { say "restriction $1 is set, but should not be"; fail=1; }
    fi
}

cmd_check_policies() {
    local admin=false keep_adb=false wifi_locked=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --admin) admin=true ;;
            --keep-adb) keep_adb=true ;;
            --wifi-locked) wifi_locked=true ;;
            *) die "check-policies: unknown option $1" ;;
        esac
        shift
    done
    local dump key fail=0 sdk
    dump=$(sh_ dumpsys user | effective_restrictions) || die "no effective restrictions for user 0 in 'dumpsys user'"
    sdk=$(sh_ getprop ro.build.version.sdk)
    for key in no_safe_boot no_config_tethering no_wifi_direct disallow_config_private_dns; do
        restriction "$key" yes
    done
    if [ "${sdk:-0}" -ge 35 ]; then restriction no_near_field_communication_radio yes; fi
    for key in no_install_unknown_sources_globally no_bluetooth no_config_location; do
        restriction "$key" "$([ "$admin" = true ] && echo no || echo yes)"
    done
    # Debugging stays off in every session, Administration included; only
    # the debug-build test hook keeps it.
    restriction no_debugging_features "$([ "$keep_adb" = true ] && echo no || echo yes)"
    for key in no_change_wifi_state no_config_wifi no_add_wifi_config; do
        restriction "$key" "$([ "$wifi_locked" = true ] && echo yes || echo no)"
    done
    if [ "$wifi_locked" = true ]; then
        sh_ cmd wifi status | grep -q 'Wifi is disabled' || { say "Wi-Fi is not off"; fail=1; }
    fi
    [ "$(sh_ settings get global auto_time)" = 0 ] || { say "automatic time is on"; fail=1; }
    [ "$(sh_ settings get global auto_time_zone)" = 0 ] || { say "automatic time zone is on"; fail=1; }
    [ "$(sh_ getprop persist.sys.timezone)" = UTC ] || { say "time zone is not UTC"; fail=1; }
    [ "$(sh_ settings get secure location_mode)" = 0 ] || { say "location is on"; fail=1; }
    [ "$fail" = 0 ] || die "policy checks failed"
    say "policies as expected (administration: $admin, test hook: $keep_adb, Wi-Fi locked: $wifi_locked)"
}

# What has the input focus, for the log.
focus() { sh_ dumpsys window | grep -m 1 -o 'mCurrentFocus=.*' || true; }

# The firewall row is in the "This session" card, below the fold of the
# status screen, and uiautomator lists only what is on screen. So: open the
# status screen (its launcher entry, as a person would) when something else
# is in front, and scroll down until the row shows. Welcome reads the
# property every 2 s; the row says "Checking…" until the first read.
cmd_check_addon() {
    local seconds=${1:-60} end xml text='' w h armed reopened=''
    case $seconds in '' | *[!0-9]*) die "usage: check-addon [SECONDS]" ;; esac
    end=$((SECONDS + seconds))
    armed=$(sh_ getprop antumbra.fw.armed)
    read -r w h < <(screen_size)
    a shell input keyevent KEYCODE_WAKEUP
    while [ $SECONDS -lt $end ]; do
        xml=$(dump_ui || true)
        # "Power off now" is pinned at the bottom of the status screen only.
        if [ -z "$(find_node poweroff_button <<<"$xml")" ]; then
            [ -n "$reopened" ] || reopened=$(focus)
            say "the status screen is not in front ($reopened); opening it"
            a shell am start -n "$PKG/.StatusActivity" >/dev/null
            sleep 2
            continue
        fi
        text=$(node_text row_firewall <<<"$xml")
        # The row shows the first 12 hex digits of the property.
        case $text in
            *"Live (rules ${armed:0:12})"*)
                say "Welcome sees the firewall: $text"
                # Back to the top (Tor's progress) for later screenshots.
                for _ in 1 2 3; do a shell input swipe $((w / 2)) $((h * 3 / 10)) $((w / 2)) $((h * 8 / 10)) 300; done
                # The status screen must stay in front after Start (run 4:
                # Android closed it ten seconds later). Reopening it to read
                # the row is not a pass.
                [ -z "$reopened" ] ||
                    die "Welcome sees the firewall, but the status screen was not in front after Start ($reopened)"
                return 0
                ;;
            *Live*) die "the firewall row does not show antumbra.fw.armed=${armed:-(not set)}: $text" ;;
            *"Not running"*) die "Welcome does not see antumbra.fw.armed=${armed:-(not set)}: $text" ;;
        esac
        # Not on screen, cut off, or not read yet: scroll down and look again.
        a shell input swipe $((w / 2)) $((h * 6 / 10)) $((w / 2)) $((h * 3 / 10)) 300
        sleep 1
    done
    die "the status screen's firewall row did not say Live within $seconds s (last: ${text:-not on screen})"
}

# The activity in front, as "package/.Class", from 'dumpsys activity
# activities' ("  ResumedActivity: ActivityRecord{1f u0 pkg/.Class t12}").
resumed() {
    sh_ dumpsys activity activities |
        sed -n 's/^ *ResumedActivity: ActivityRecord{[^ ]* u[0-9]* \([^ ]*\) .*/\1/p' | sed -n 1p || true
}

# LOCKED while Welcome holds its lock task (LockTaskController's dump).
lock_state() {
    sh_ dumpsys activity activities | sed -n 's/^ *mLockTaskModeState=//p' | sed -n 1p || true
}

# True while no phone has a call (TelephonyRegistry's mCallState, 0 = idle).
# Fails closed: a dump without any call state (no service, a failed dump, a
# renamed field) stops the check instead of counting as idle.
calls_idle() {
    local states
    states=$(sh_ dumpsys telephony.registry | grep -o 'mCallState=[0-9]*' || true)
    [ -n "$states" ] || die "cannot read the call state (no mCallState in dumpsys telephony.registry)"
    ! grep -qv '^mCallState=0$' <<<"$states"
}

# Waits until $1 is the activity in front; gives up after $2 seconds.
wait_resumed() {
    local want=$1 end=$((SECONDS + $2))
    while [ $SECONDS -lt $end ]; do
        [ "$(resumed)" = "$want" ] && return 0
        sleep 1
    done
    return 1
}

# Presses Back until Welcome is in front again (the dialer may need more
# than one), waiting up to $1 seconds after each, then checks that its lock
# task held.
back_to_welcome() {
    local i
    for i in 1 2 3; do
        a shell input keyevent KEYCODE_BACK
        wait_resumed "$WELCOME" "$1" && break
    done
    [ "$(resumed)" = "$WELCOME" ] || die "Welcome is not in front after Back from the emergency dialer (in front: $(resumed))"
    [ "$(lock_state)" = LOCKED ] || die "Welcome's lock task ended while the emergency dialer was open (lock task: $(lock_state))"
}

# WEL7. Never dials: nothing in the dialer is touched, no number is typed,
# and the call state must be idle before and after.
cmd_check_emergency() {
    local shot='' wait=15 dialers first how out='' end now
    while [ $# -gt 0 ]; do
        case "$1" in
            --screenshot) shot=$2; shift ;;
            --wait) wait=$2; shift ;;
            *) die "check-emergency: unknown option $1" ;;
        esac
        shift
    done
    case $wait in '' | *[!0-9]*) die "check-emergency: --wait takes a number of seconds" ;; esac
    dialers=$(sh_ cmd package query-activities --components -a "$DIAL_EMERGENCY" | grep / || true)
    [ -n "$dialers" ] || die "no activity handles $DIAL_EMERGENCY"
    first=$(head -n 1 <<<"$dialers")
    # The keyguard may be up (LOCK_TASK_FEATURE_KEYGUARD lets it show).
    a shell input keyevent KEYCODE_WAKEUP
    a shell wm dismiss-keyguard >/dev/null 2>&1 || true
    wait_for start_button 60
    [ "$(resumed)" = "$WELCOME" ] || die "Welcome is not in front (in front: $(resumed))"
    [ "$(lock_state)" = LOCKED ] || die "Welcome is not in its lock task (lock task: $(lock_state)); this check needs the state before Start"
    calls_idle || die "a call is in progress; not opening the emergency dialer"
    for how in button am-start; do
        if [ "$how" = button ]; then
            tap emergency_call
        else
            # A task of its own, as the power menu starts it: the lock task lets
            # it in only with LOCK_TASK_FEATURE_KEYGUARD.
            out=$(sh_ am start -n "$first" -a "$DIAL_EMERGENCY" 2>&1 || true)
        fi
        end=$((SECONDS + wait))
        while [ $SECONDS -lt $end ]; do
            now=$(resumed)
            grep -qxF "$now" <<<"$dialers" && break
            sleep 1
        done
        grep -qxF "$now" <<<"$dialers" ||
            die "the emergency dialer did not come to the front from the lock task ($how; in front: ${now:-nothing}; lock task: $(lock_state)${out:+; am: $(tr '\n' ' ' <<<"$out")})"
        say "the emergency dialer $now is in front ($how)"
        if [ -n "$shot" ] && [ "$how" = button ]; then
            # Resumed comes before drawn: wait for the dialer's window to
            # take the focus, then a moment for its first frame (run 9's
            # screenshot still showed Welcome).
            end=$((SECONDS + wait))
            while [ $SECONDS -lt $end ]; do
                case $(focus) in *"${now%%/*}"*"${now##*.}"*) break ;; esac
                sleep 1
            done
            sleep 1
            a exec-out screencap -p >"$shot" || true
        fi
        back_to_welcome "$wait"
        say "Welcome is in front again and still locked"
        # Never open the dialer again after a call appeared.
        calls_idle || die "a call is in progress after the check ($how)"
    done
    say "the emergency dialer opens from Welcome's lock task (its button, and a task of its own); nothing was dialled"
}

# Prints "x y" for the first node in package $1 whose text is one of $2...
# (from the XML on stdin), or nothing.
find_text() {
    python3 -I -c '
import sys, xml.etree.ElementTree as ET
package, texts = sys.argv[1], sys.argv[2:]
try:
    root = ET.fromstring(sys.stdin.read())
except ET.ParseError:
    sys.exit(0)
for n in root.iter("node"):
    if n.get("text") in texts and n.get("package") == package:
        b = n.get("bounds", "").replace("][", ",").strip("[]").split(",")
        x1, y1, x2, y2 = (int(v) for v in b)
        print((x1 + x2) // 2, (y1 + y2) // 2)
        break
' "$@"
}

# The power menu in a dump (XML on stdin): SystemUI's "Power off",
# "Restart", or "Power" when the menu groups those two under one item. Its
# "Emergency" alone is not enough: the keyguard's bouncer has a SystemUI
# button with that label too (lockscreen_emergency_call).
power_menu_in() { find_text com.android.systemui "Power off" Restart Power | grep -q .; }

# A global setting's value ("null" when unset).
setting() { sh_ settings get global "$1"; }

# "off" while Android's emergency affordance is off: then the power menu's
# Emergency item is SystemUI's EmergencyDialerAction, which opens the
# emergency dial pad and dials nothing. Otherwise the two settings that
# switch it on (EmergencyAffordanceManager.needsEmergencyAffordance): the
# test setting force_emergency_affordance, and emergency_affordance_needed,
# which Android sets from the SIM's and the network's country. With either
# on, the item is EmergencyAffordanceAction, which calls at once. Both items
# are labelled "Emergency", so a dump cannot tell them apart; these settings
# can.
affordance_state() {
    local force needed
    force=$(setting force_emergency_affordance || true)
    needed=$(setting emergency_affordance_needed || true)
    case $force/$needed in
        null/null | null/0 | 0/null | 0/0) echo off ;;
        *) echo "force_emergency_affordance=${force:-unreadable}, emergency_affordance_needed=${needed:-unreadable}" ;;
    esac
}

# power_button_long_press's value from before check-power-menu ("null"
# when it was unset), or nothing when none is saved.
saved_long_press() { sh_ "cat $LONG_PRESS_SAVE 2>/dev/null" || true; }

# True while the power menu is open, or may be: a dump shows it, or the
# dump fails.
power_menu_open() {
    local xml
    xml=$(dump_ui) || return 0
    power_menu_in <<<"$xml"
}

# Closes the power menu if it is open, touching nothing in it: Back, then,
# while a dump still shows it (or cannot be read), the screen off and on
# (SystemUI's GlobalActionsDialogLite closes on ACTION_SCREEN_OFF). Fails
# when it still shows.
close_power_menu() {
    local try
    for try in 1 2 3; do
        power_menu_open || return 0
        a shell input keyevent KEYCODE_BACK || true
        sleep 1
    done
    power_menu_open || return 0
    a shell input keyevent KEYCODE_SLEEP || true
    sleep 2
    a shell input keyevent KEYCODE_WAKEUP || true
    a shell wm dismiss-keyguard >/dev/null 2>&1 || true
    sleep 2
    power_menu_open || return 0
    say "the power menu is still open (after Back, and the screen off and on)"
    return 1
}

# clear-power-menu-test: the power menu closed, then
# power_button_long_press as it was before check-power-menu. Idempotent.
clear_power_menu_test() {
    local fail=0 saved
    close_power_menu || fail=1
    saved=$(saved_long_press)
    case $saved in
        '') ;;
        [0-9] | [0-9][0-9]) a shell settings put global power_button_long_press "$saved" >/dev/null 2>&1 || true ;;
        *) [ "$saved" = null ] || say "unexpected saved power_button_long_press '$saved'; removing the setting"
            saved=null
            a shell settings delete global power_button_long_press >/dev/null 2>&1 || true ;;
    esac
    if [ -n "$saved" ]; then
        if [ "$(setting power_button_long_press || true)" = "$saved" ]; then
            a shell rm -f "$LONG_PRESS_SAVE" || true
        else
            say "power_button_long_press is not back to '$saved'"
            fail=1
        fi
    fi
    [ "$fail" = 0 ] || return 1
    say "the power menu is closed and power_button_long_press is as it was"
}

# WEL12, presence only: the power menu's Emergency item before Start, with
# Welcome in its lock task. Only while the emergency affordance is off, so
# that the menu this check opens has no item that calls at once; it
# changes no emergency setting and never presses the item.
cmd_check_power_menu() {
    local shot='' wait=15 xy='' menu='' xml try saved state
    while [ $# -gt 0 ]; do
        case "$1" in
            --screenshot) shot=$2; shift ;;
            --wait) wait=$2; shift ;;
            *) die "check-power-menu: unknown option $1" ;;
        esac
        shift
    done
    case $wait in '' | *[!0-9]*) die "check-power-menu: --wait takes a number of seconds" ;; esac
    # Nothing is changed before these hold.
    a shell input keyevent KEYCODE_WAKEUP
    a shell wm dismiss-keyguard >/dev/null 2>&1 || true
    wait_for start_button 60
    [ "$(resumed)" = "$WELCOME" ] || die "Welcome is not in front (in front: $(resumed))"
    [ "$(lock_state)" = LOCKED ] || die "Welcome is not in its lock task (lock task: $(lock_state)); this check needs the state before Start"
    calls_idle || die "a call is in progress; not touching the power menu"
    state=$(affordance_state)
    [ "$state" = off ] ||
        die "the emergency affordance is on or unreadable ($state): the power menu's Emergency item would call at once, so this check does not open the menu (PH4 covers that item, on the phone); nothing was changed"

    # From here on, whatever happens, the menu is closed and the setting put back.
    trap 'clear_power_menu_test || say "clear-power-menu-test failed; run it again"' EXIT
    trap 'exit 1' INT TERM HUP
    # AOSP's long press on power starts the assistant (config_longPressOnPowerBehavior
    # 5); power_button_long_press=1 makes it the power menu for this check.
    # Its value now is saved on the device first (kept if an earlier run
    # left one), for clear-power-menu-test.
    saved=$(saved_long_press)
    if [ -z "$saved" ]; then
        saved=$(setting power_button_long_press | tr -cd 'a-z0-9')
        [ -n "$saved" ] || die "cannot read power_button_long_press"
        a shell "echo $saved > $LONG_PRESS_SAVE"
        [ "$(saved_long_press)" = "$saved" ] || die "cannot save power_button_long_press"
    fi
    a shell settings put global power_button_long_press 1 >/dev/null || true
    [ "$(setting power_button_long_press)" = 1 ] || die "power_button_long_press did not take"
    sleep 1
    for try in 1 2; do
        a shell input keyevent --longpress KEYCODE_POWER
        for _ in $(seq "$wait"); do
            xml=$(dump_ui || true)
            if power_menu_in <<<"$xml"; then
                menu=1
                xy=$(find_text com.android.systemui Emergency <<<"$xml")
                [ -z "$xy" ] || break
            fi
            sleep 1
        done
        # A menu without the item stays as it is (the items are built when it opens).
        if [ -n "$xy" ] || [ -n "$menu" ]; then break; fi
        # A press taken as a short one switches the screen off.
        [ "$try" = 2 ] || { a shell input keyevent KEYCODE_WAKEUP; a shell wm dismiss-keyguard >/dev/null 2>&1 || true; sleep 2; }
    done
    if [ -n "$xy" ]; then
        say "the power menu shows an item labelled Emergency in Welcome's lock task (not pressed)"
        [ -z "$shot" ] || a exec-out screencap -p >"$shot" || true
    fi
    close_power_menu || die "the power menu did not close (after Back, and the screen off and on)"
    if ! wait_resumed "$WELCOME" "$wait"; then
        a shell input keyevent KEYCODE_WAKEUP
        a shell wm dismiss-keyguard >/dev/null 2>&1 || true
        wait_resumed "$WELCOME" "$wait" || die "Welcome is not in front after the power menu (in front: $(resumed))"
    fi
    [ "$(lock_state)" = LOCKED ] || die "Welcome's lock task ended during the power menu check (lock task: $(lock_state))"
    calls_idle || die "a call is in progress after the power menu check"
    [ -n "$menu" ] || die "the power menu did not open in Welcome's lock task within ${wait} s (twice)"
    [ -n "$xy" ] || die "the power menu opened in Welcome's lock task but did not show an Emergency item within ${wait} s"
    state=$(affordance_state)
    [ "$state" = off ] || die "the emergency affordance came on during the check ($state): the Emergency item seen may have been the one that calls at once"
    trap - EXIT INT TERM HUP
    clear_power_menu_test || die "the power menu showed its Emergency item, but it could not be closed or power_button_long_press put back"
    say "the power menu shows its Emergency item in Welcome's lock task before Start (with the emergency affordance off, the item that opens the emergency dial pad); it was not pressed, nothing was dialled, and the menu and the long-press setting are back as they were"
}

cmd_power_off_tile() {
    local before after end
    before=$(sh_ cat /proc/sys/kernel/random/boot_id)
    a shell cmd statusbar add-tile "$TILE" >/dev/null
    a shell cmd statusbar click-tile "$TILE" >/dev/null || true
    end=$((SECONDS + 240))
    sleep 5
    while [ $SECONDS -lt $end ]; do
        after=$(timeout 10 adb "${adb_args[@]}" shell cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '\r' || true)
        if [ -n "$after" ] && [ "$after" != "$before" ]; then
            say "the device restarted (boot id $before -> $after)"
            return 0
        fi
        sleep 3
    done
    die "the device did not restart within 240 s of Quick power off"
}

[ $# -ge 1 ] || { sed -n "4,79p" "$0" | sed 's/^# \{0,1\}//'; exit 2; }
command=$1
shift
case "$command" in
    install)
        [ $# -eq 1 ] || die "usage: install APK"
        a install -r -t "$1"
        ;;
    provision)
        case "${1:-}" in
            "") a shell setprop "$HOOK" 1
                sh_ dumpsys package "$PKG" | grep -q 'flags=.*DEBUGGABLE' ||
                    say "warning: not a debuggable build; it ignores $HOOK and adb goes away now" ;;
            --no-keep-adb) a shell setprop "$HOOK" 0 ;;
            *) die "provision: unknown option $1" ;;
        esac
        a shell dpm set-device-owner "$ADMIN"
        sh_ dpm list-owners | grep -q "$PKG" || die "Welcome is not the device owner"
        # Welcome opens itself on DEVICE_OWNER_CHANGED; open it anyway in
        # case that broadcast is late.
        a shell am start -n "$PKG/.WelcomeActivity" >/dev/null
        wait_for start_button 60
        say "Welcome is the device owner and on screen"
        ;;
    wait-welcome) wait_for start_button "${1:-60}" ;;
    start) cmd_start "$@" ;;
    query) sh_ content query --uri "$URI" ;;
    expect) cmd_expect "$@" ;;
    check-policies) cmd_check_policies "$@" ;;
    check-addon) cmd_check_addon "$@" ;;
    check-emergency) cmd_check_emergency "$@" ;;
    check-power-menu) cmd_check_power_menu "$@" ;;
    clear-power-menu-test) clear_power_menu_test || die "the power menu is not closed or power_button_long_press is not as it was" ;;
    screenshot)
        [ $# -eq 1 ] || die "usage: screenshot FILE.png"
        a exec-out screencap -p > "$1"
        ;;
    power-off-tile) cmd_power_off_tile ;;
    remove)
        a shell setprop "$HOOK" 0 || true
        a shell dpm remove-active-admin "$ADMIN" || true
        a uninstall "$PKG"
        ;;
    *) die "unknown command $command (run without arguments for help)" ;;
esac
