#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Drives the Antumbra Welcome app over adb: for the CI emulator job, and by
# hand. It works the screen the way a person does (uiautomator finds each
# control by its test tag, then 'input tap'), and checks results through
# the state provider and the system's own dumps.
#
#   welcome-adb.sh [-s SERIAL] COMMAND [ARGS]
#
# Commands:
#   install APK               Install or update (debug builds are testOnly: 'install -t').
#   provision                 Make Welcome the device owner, then wait for its screen.
#                             The device must have no accounts (a fresh emulator has none).
#   wait-welcome [SECONDS]    Wait until the Start button is on screen (default 60).
#   start [OPTIONS]           Make the choices on screen and press Start, then wait
#                             for the status screen and check the provider's row.
#       --tor direct|bridges|offline   Default: direct.
#       --builtin-bridges              With --tor bridges (the default source).
#       --bridges-file FILE            With --tor bridges: type these lines.
#       --keep-mac --admin --unsafe-browser
#       --expect-adb-loss              Without --admin, Start switches USB debugging
#                                      off and adb disconnects: succeed when it does.
#   query                     Print the provider's row (runs as the shell user, uid 2000).
#   expect KEY=VALUE...       Fail unless the row has these values (bridges: give a count,
#                             as bridges=7).
#   check-policies [--admin]  Check the device-owner restrictions, automatic time and
#                             the time zone after Start.
#   screenshot FILE.png       Save the screen.
#   emergency-tile            Add the Emergency off tile, click it, and wait until the
#                             device has restarted (the boot id changes).
#   remove                    Remove the test device owner (testOnly builds only) and the app.
#
# Needs adb and python3 on the host. Exit status 0 means every check passed.

set -euo pipefail

PKG=org.antumbra.welcome
ADMIN=$PKG/.AdminReceiver
TILE=$PKG/.EmergencyTileService
URI=content://org.antumbra.welcome.state/session
UI_DUMP=/data/local/tmp/antumbra-welcome-ui.xml

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
type_line() {
    local line=$1
    [[ "$line" =~ ^[A-Za-z0-9\ .:=/+_,@\[\]-]+$ ]] || die "bridge line has characters this script cannot type: $line"
    a shell input text "'${line// /%s}'"
}

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
    local tor=direct source=builtin file="" keep_mac=false admin=false unsafe=false expect_loss=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --tor) tor=$2; shift ;;
            --builtin-bridges) source=builtin ;;
            --bridges-file) source=custom; file=$2; shift ;;
            --keep-mac) keep_mac=true ;;
            --admin) admin=true ;;
            --unsafe-browser) unsafe=true ;;
            --expect-adb-loss) expect_loss=true ;;
            *) die "start: unknown option $1" ;;
        esac
        shift
    done
    case "$tor" in direct|bridges|offline) ;; *) die "start: --tor must be direct, bridges or offline" ;; esac
    if [ "$admin" = false ] && [ "$expect_loss" = false ]; then
        die "start without --admin switches USB debugging off and adb disconnects; add --admin, or --expect-adb-loss"
    fi

    wait_for start_button 60
    tap "tor_$tor"
    if [ "$tor" = bridges ]; then
        if [ "$source" = custom ]; then
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
        else
            tap bridges_builtin
        fi
    fi
    set_switch switch_mac "$([ "$keep_mac" = true ] && echo false || echo true)"
    set_switch switch_admin "$admin"
    set_switch switch_unsafe_browser "$unsafe"
    tap start_button

    if [ "$expect_loss" = true ]; then
        local end=$((SECONDS + 90))
        while [ $SECONDS -lt $end ]; do
            if ! a shell true >/dev/null 2>&1; then
                say "adb disconnected after Start, as expected without Administration"
                return 0
            fi
            sleep 2
        done
        die "adb still answers 90 s after Start without Administration"
    fi

    wait_for status_title 60
    local expect=(started=1 "tor_mode=$tor" "mac=$([ "$keep_mac" = true ] && echo keep || echo new)"
        "admin=$([ "$admin" = true ] && echo 1 || echo 0)"
        "unsafe_browser=$([ "$unsafe" = true ] && echo 1 || echo 0)" persistent=0)
    if [ "$tor" != bridges ]; then expect+=(bridges=0); fi
    cmd_expect "${expect[@]}"
}

cmd_check_policies() {
    local admin=false
    [ "${1:-}" = --admin ] && admin=true
    local dump key fail=0
    dump=$(sh_ dumpsys user)
    for key in no_safe_boot no_config_tethering no_wifi_direct; do
        grep -qw "$key" <<<"$dump" || { say "missing restriction $key"; fail=1; }
    done
    for key in no_debugging_features no_install_unknown_sources_globally no_bluetooth no_config_location; do
        if [ "$admin" = true ]; then
            ! grep -qw "$key" <<<"$dump" || { say "restriction $key set in an Administration session"; fail=1; }
        else
            grep -qw "$key" <<<"$dump" || { say "missing restriction $key"; fail=1; }
        fi
    done
    [ "$(sh_ settings get global auto_time)" = 0 ] || { say "automatic time is on"; fail=1; }
    [ "$(sh_ settings get global auto_time_zone)" = 0 ] || { say "automatic time zone is on"; fail=1; }
    [ "$(sh_ getprop persist.sys.timezone)" = UTC ] || { say "time zone is not UTC"; fail=1; }
    [ "$(sh_ settings get secure location_mode)" = 0 ] || { say "location is on"; fail=1; }
    [ "$fail" = 0 ] || die "policy checks failed"
    say "policies as expected (administration: $admin)"
}

cmd_emergency_tile() {
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
    die "the device did not restart within 240 s of Emergency off"
}

[ $# -ge 1 ] || { sed -n "4,34p" "$0" | sed 's/^# \{0,1\}//'; exit 2; }
command=$1
shift
case "$command" in
    install)
        [ $# -eq 1 ] || die "usage: install APK"
        a install -r -t "$1"
        ;;
    provision)
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
    screenshot)
        [ $# -eq 1 ] || die "usage: screenshot FILE.png"
        a exec-out screencap -p > "$1"
        ;;
    emergency-tile) cmd_emergency_tile ;;
    remove)
        a shell dpm remove-active-admin "$ADMIN" || true
        a uninstall "$PKG"
        ;;
    *) die "unknown command $command (run without arguments for help)" ;;
esac
