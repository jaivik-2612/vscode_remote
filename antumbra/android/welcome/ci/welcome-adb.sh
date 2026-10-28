#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Drives the Antumbra Welcome app over adb, by hand or from a test script
# (the CI emulator job has its own driver, antumbra/android/ci/
# emulator-antumbra.sh, with the same test tags, and calls this script only
# for 'check-emergency', 'check-power-menu', 'check-policies --keep-adb',
# 'check-addon', 'check-module-word', 'check-choices', 'check-phone',
# 'check-module-cell', 'check-emergency-card', 'check-emergency-states',
# 'check-position' and 'clear-position-test'). It
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
#       --internet wifi|mobile|none    Default: wifi. mobile needs the Phone-mode gate
#                                      "data" (the emulator only, until FW9 and CI12).
#       --phone off|calls              Default: off. calls needs the gate "phone" or "data".
#       --tor direct|bridges|offline   Default: direct. offline is --internet none.
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
#   check-choices --gate off|phone|data [--shots DIR]
#                             WEL8, before Start, Welcome in front: the six attempts of
#                             the two choices (Internet wifi, mobile, none; Phone off,
#                             calls; mobile data straight after Phone off), each tapped
#                             by its test tag as a person would, then the whole page
#                             read (a row or card only from a dump that shows it whole,
#                             scrolled into view if no page does): which rows are
#                             checked; rows the gate does not allow disabled, unchecked,
#                             with their reason; Tor's rows exactly when there is
#                             Internet; the "What your carrier sees" card for the choice,
#                             with its key statements; the radio line against the
#                             registry's mRadioPowerState; the SIM line against
#                             gsm.sim.state; no "offline" anywhere. --gate: the gate Welcome should have
#                             been told (the emulator writes /data/adb/antumbra-cell as
#                             root first). Ends with Wi-Fi and Phone off selected.
#                             --shots: a screenshot per attempt, DIR/welcome-choice-I-P.png.
#   check-phone [--internet wifi|mobile|none] --cell off|phone|data
#                             WEL8, after Start: the status screen's session lines, its
#                             Phone card (SIM, radio, VoLTE) and carrier card, read from the
#                             whole page; no "offline" unless there is no Internet, no
#                             Phone and the radio reads off.
#   check-module-cell         WEL8, with adb as root: Welcome's provider takes the module's
#                             word on the cell radio (module_cell) from root only: refused
#                             from the shell user (SecurityException), refused malformed
#                             from root, taken from root. The word sent can only make
#                             Welcome more careful ("gate off, nothing carried out, the
#                             radio not known"); the module's next word replaces it.
#   check-module-word         MOD11, with adb as root ('adb root'): Welcome's provider
#                             takes the module's word from root only. Sent as the shell
#                             user (uid 2000, through su) a word is refused with a
#                             SecurityException; as root a malformed word is refused and
#                             a "none" word taken ("Result: Bundle[{v=1}]"). Only
#                             "none" and malformed words are sent: neither lets Quick
#                             power off skip a wait.
#   check-emergency-card [--screenshot FILE.png]
#                             WEL10, with adb as root, on the Welcome or status screen
#                             (whichever is in front): the emergency card, line by line
#                             (a line counts only from a dump that shows it whole). Each
#                             number it shows (one, or several Android ranks alike, with
#                             their own line) must be one of Android's ('cmd phone
#                             emergency-number-test-mode -p', a print, as root), or the
#                             card says Android lists none exactly when the print has no
#                             number. Its state lines must match the device and WEL8's rows
#                             on the same page: the SIM line against gsm.sim.state, the
#                             radio line exactly when the radio row says Off (that row
#                             against the registry's mRadioPowerState), the VoLTE line
#                             exactly when the VoLTE row says "Not connected for calls yet"
#                             with a SIM unlocked and the radio not off; the other-phone
#                             line exactly when a state line shows; no text says an
#                             emergency call cannot be made. The CI hook must be unset.
#                             Reads only: nothing is tapped, typed or dialled.
#   check-emergency-states [--shots DIR]
#                             WEL10, test builds: debug.antumbra.emergency_states set to
#                             each state alone, then all five, then number_none and
#                             number_unreadable; each time the card must show exactly
#                             those lines, with Welcome's texts (strings.xml). The
#                             property is cleared afterwards whatever happens, and the card
#                             must show its real lines again. A release build ignores the
#                             property: the check then fails and says so. --shots: a
#                             screenshot per case, DIR/emergency-state-CASE.png.
#   check-position [--source test|gnss] [--screenshot FILE.png] [--wait SECONDS]
#                  [--leave sleep|home|none]
#                             WEL10, with adb as root, never during a call: Show my
#                             position. Location must be off before. Source test (the
#                             default): mock location allowed for the shell user, then as
#                             the shell user ('su 2000 cmd location providers'):
#                             add-test-provider gps, set-test-provider-enabled gps true;
#                             after the tap, "Looking" and Location on within 15 s, then
#                             set-test-provider-location gps --location
#                             10.12345,-140.54321 --accuracy 5 every 2 s until the
#                             coordinates show (--wait, 60 s). Source gnss: the emulator's
#                             own receiver, 'adb emu geo fix -140.54321 10.12345'
#                             (longitude first). Then: "10.12345° N", "140.54321° W", the
#                             map line, the accuracy (test), the test-location line
#                             exactly with source test; Location off within 10 s; the
#                             window secure; Welcome's request under the gps provider only
#                             (dumpsys location, read while it looks); the coordinates in
#                             no file under Welcome's data directories, not in its log, in
#                             no property; Hide removes them. Then a second search, left by
#                             switching the screen off (--leave sleep, the Welcome screen's
#                             default) or with Home (--leave home, the status screen's):
#                             Location off within 10 s. Afterwards, also after a failure
#                             ('clear-position-test'): a search still shown is stopped with
#                             its own Stop button, the test provider removed and
#                             mock_location back to its default. Welcome alone switches
#                             Location; this command never writes a location setting.
#   clear-position-test       Undo what check-position may leave: a search stopped with
#                             Welcome's Stop, the test provider removed, mock_location back
#                             to default; fails while Location stays on.
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
# The provider's method for the module's word (MOD11), and a word that
# changes nothing: "none" (Quick power off waits as without a word).
WORD_URI=content://org.antumbra.welcome.state
WORD_NONE=(--extra v:i:1 --extra calls:s:none --extra at:l:0 --extra until:l:0 --extra ims:s:off --extra ims_at:l:0)
# WEL8: the module's word on the cell radio, the most careful one.
CELL_CAREFUL=(--extra v:i:1 --extra gate:s:off --extra cell:s:none --extra radio:s:unknown --extra at:l:0)
# The reasons Welcome gives for a choice it does not offer (strings.xml).
MOBILE_REASON='Not available yet: mobile data through Tor needs checks on this phone first.'
CALLS_REASON='Not available yet: Phone needs checks on this phone first.'
OFF_REASON='Not possible with mobile data'
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

# Prints "x y checked enabled" for the node whose resource-id is $1 (from
# the XML on stdin), or nothing. Compose test tags appear as resource ids
# because the app sets testTagsAsResourceId.
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
        print((x1 + x2) // 2, (y1 + y2) // 2, n.get("checked", "false"), n.get("enabled", "true"))
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
# Prints "x y checked enabled".
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
    local x y _checked _enabled
    read -r x y _checked _enabled < <(locate "$1") || die "control '$1' not found on screen"
    a shell input tap "$x" "$y"
}

# Sets the switch $1 to $2 (true/false).
set_switch() {
    local x y checked _enabled
    read -r x y checked _enabled < <(locate "$1") || die "switch '$1' not found on screen"
    [ "$checked" = "$2" ] || a shell input tap "$x" "$y"
}

# Scrolls to the top of the page.
to_top() {
    local w h
    read -r w h < <(screen_size)
    for _ in 1 2 3 4 5 6 7 8; do a shell input swipe $((w / 2)) $((h * 3 / 10)) $((w / 2)) $((h * 8 / 10)) 150; done
}

# scan_page FILE: the whole page, from the top down: a dump, then a slow
# scroll (so that it does not fling past what lies between two dumps),
# until a dump shows nothing new (uiautomator lists only what is on
# screen). The dumps go into FILE, separated by "<!-- page -->" lines.
scan_page() {
    local file=$1 w h prev='' cur
    read -r w h < <(screen_size)
    to_top
    : >"$file"
    for _ in $(seq 1 12); do
        cur=$(dump_ui || true)
        [ "$cur" != "$prev" ] || break
        printf '%s\n<!-- page -->\n' "$cur" >>"$file"
        prev=$cur
        a shell input swipe $((w / 2)) $((h * 7 / 10)) $((w / 2)) $((h * 3 / 10)) 1000
    done
}

# The rule for reading a node from a dump (NODE_PY, below): Compose lists
# the children of a node that does not merge them (a card, an info row)
# only as far as they are on screen, and gives the node the bounds of its
# visible part. So a node's text counts only from a dump in which its
# bounds lie wholly inside its scroll view's, never touching an edge, or
# outside any scroll view (pinned). node_pick FILE|- ID prints
# "checked enabled<TAB>text" of the first such occurrence (its text: its
# own and everything inside it, joined by " | "), from a scan's dumps or a
# dump on standard input ("-"); fails with 2 when ID is only ever cut off
# by an edge, 1 when no dump has it. With MOVE=1 and a dump on standard
# input it prints, for a node cut off, "move DY TOP BOTTOM<TAB>..." instead
# and fails with 3: how far to scroll the page up (DY < 0: down) to bring
# it wholly into view, or "tall<TAB>..." when it is taller than the view.
NODE_PY='
import os, re, sys, xml.etree.ElementTree as ET
src, want, move, margin = sys.argv[1], sys.argv[2], os.environ.get("MOVE") == "1", 60
docs = (sys.stdin.read() if src == "-" else open(src, encoding="utf-8").read()).split("<!-- page -->")
def box(n):
    m = re.match(r"^\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]$", n.get("bounds", ""))
    return tuple(int(v) for v in m.groups()) if m else None
seen = False
for doc in docs:
    try:
        root = ET.fromstring(doc.strip())
    except ET.ParseError:
        continue
    parent = {c: p for p in root.iter() for c in p}
    for n in root.iter("node"):
        if n.get("resource-id") != want or box(n) is None:
            continue
        seen = True
        text = " | ".join(x for x in (m.get("text", "") for m in n.iter("node")) if x)
        line = n.get("checked", "false") + " " + n.get("enabled", "true") + "\t" + text
        a = parent.get(n)
        while a is not None and a.get("scrollable") != "true":
            a = parent.get(a)
        if a is None or box(a) is None:
            print(line)
            sys.exit(0)
        top, bottom, vt, vb = box(n)[1], box(n)[3], box(a)[1], box(a)[3]
        if vt < top and bottom < vb:
            print(line)
            sys.exit(0)
        if move:
            if top > vt and top - (vt + margin) > 0:
                print("move %d %d %d\t%s" % (top - (vt + margin), top, bottom, line))
            elif bottom < vb and bottom - (vb - margin) < 0:
                print("move %d %d %d\t%s" % (bottom - (vb - margin), top, bottom, line))
            else:
                print("tall\t" + line)
            sys.exit(3)
        break
sys.exit(2 if seen else 1)
'
node_pick() { python3 -I -c "$NODE_PY" "$@"; }

# scan_get FILE ID: node_pick from a scan's dumps.
scan_get() { node_pick "$1" "$2"; }

# view_row ID: "checked enabled<TAB>text" of node ID from a dump of the
# screen now in which it lies wholly inside its scroll view, scrolling it
# there with slow drags (looking for it as locate does while it is not on
# screen). A page that no longer moves is at its end: the node is whole
# there. Fails when it cannot be shown whole.
view_row() {
    local id=$1 w h out rc prev='' head dy y1 i
    read -r w h < <(screen_size)
    for i in $(seq 1 10); do
        rc=0
        out=$(dump_ui | MOVE=1 node_pick - "$id") || rc=$?
        if [ "$rc" = 0 ]; then printf '%s\n' "$out"; return 0; fi
        [ "$rc" = 3 ] || out=absent
        case $out in
            tall*) return 1 ;;
            move*)
                head=${out%%	*}
                if [ "$head" = "$prev" ]; then printf '%s\n' "${out#*	}"; return 0; fi
                prev=$head
                read -r _ dy _ <<<"$head"
                [ "$dy" -le $((h / 2)) ] || dy=$((h / 2))
                [ "$dy" -ge $((-h / 2)) ] || dy=$((-h / 2))
                if [ "$dy" -gt 0 ]; then y1=$((h * 7 / 10)); else y1=$((h * 3 / 10)); fi
                a shell input swipe $((w / 2)) "$y1" $((w / 2)) $((y1 - dy)) 1000
                sleep 1   # what is left of the scroll settles
                ;;
            *)
                if [ "$i" -le 5 ]; then
                    a shell input swipe $((w / 2)) $((h * 6 / 10)) $((w / 2)) $((h * 3 / 10)) 300
                else
                    a shell input swipe $((w / 2)) $((h * 3 / 10)) $((w / 2)) $((h * 8 / 10)) 300
                fi
                ;;
        esac
    done
    return 1
}

# scan_has FILE ID: a dump in the scan has node ID, whole or cut off.
scan_has() {
    local rc=0
    node_pick "$1" "$2" >/dev/null || rc=$?
    [ "$rc" = 0 ] || [ "$rc" = 2 ]
}

# row_read FILE ID: node ID's "checked enabled<TAB>text", from the scan
# when a dump there has it whole, else from the screen once view_row has
# scrolled it wholly into view. Fails when it is not on the page, or never
# whole.
row_read() {
    local rc=0
    scan_get "$1" "$2" || rc=$?
    case $rc in
        0) return 0 ;;
        2) say "$2 is cut off by an edge on every page of the scan; reading it again once it is wholly on screen"
            view_row "$2" ;;
        *) return 1 ;;
    esac
}

# scan_texts FILE: every text and content description in a scan, one per line.
scan_texts() {
    python3 -I -c '
import sys, xml.etree.ElementTree as ET
for doc in open(sys.argv[1], encoding="utf-8").read().split("<!-- page -->"):
    try:
        root = ET.fromstring(doc.strip())
    except ET.ParseError:
        continue
    for n in root.iter("node"):
        for k in ("text", "content-desc"):
            if n.get(k):
                print(n.get(k))
' "$1"
}

# The cellular radio as the telephony registry says it now
# (mRadioPowerState: 0 off, 1 on, 2 unavailable), in Welcome's words; "?"
# when it cannot be read.
registry_radio() {
    case $(sh_ dumpsys telephony.registry | sed -n 's/^ *mRadioPowerState=//p' | head -n 1) in
        0) echo Off ;;
        1) echo On ;;
        2) echo 'Not known' ;;
        *) echo '?' ;;
    esac
}

# The first SIM slot's state as gsm.sim.state says it, in Welcome's words;
# "?" for a state without a fixed text.
sim_text() {
    case $(sh_ getprop gsm.sim.state | cut -d, -f1) in
        LOADED | READY) echo Unlocked ;;
        ABSENT) echo 'None in the phone' ;;
        PIN_REQUIRED) echo 'Locked: needs its PIN' ;;
        PUK_REQUIRED) echo 'Blocked: needs its PUK code' ;;
        NETWORK_LOCKED) echo 'Locked to another network' ;;
        *) echo '?' ;;
    esac
}

# check_lines FILE [offline-ok]: in a scan, the radio line against the
# registry (read before the scan into radio_before and after it: a change
# in between skips the comparison), the SIM line against gsm.sim.state,
# and no "offline" anywhere (unless offline-ok). Adds to problems, and
# puts what it read in lines_read (not a subshell: problems must stay).
radio_before=
lines_read=
check_lines() {
    local file=$1 allow=${2:-} line after sim want
    line=$(row_read "$file" radio_status | cut -f2) || line='(none)'
    after=$(registry_radio)
    if [ "$radio_before" = "$after" ] && [ "$after" != '?' ]; then
        case $line in *"| $after") ;; *) problems+=("the radio line says '$line', the registry $after") ;; esac
    fi
    sim=$(row_read "$file" sim_status_1 | cut -f2) || sim='(none)'
    want=$(sim_text)
    if [ "$want" != '?' ]; then
        case $sim in *"| $want") ;; *) problems+=("the SIM line says '$sim', gsm.sim.state $(sh_ getprop gsm.sim.state)") ;; esac
    fi
    if [ "$allow" != offline-ok ] && scan_texts "$file" | grep -qi offline; then
        problems+=("a text says \"offline\": $(scan_texts "$file" | grep -i offline | head -n 1)")
    fi
    lines_read="radio ${line##*| } (registry $after), SIM ${sim##*| }"
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

row_cell() {
    sh_ content query --uri "$URI" --projection cell | sed -n 's/^Row: 0 cell=//p'
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
    local tor=direct file="" keep_mac=false admin=false expect_loss=false internet=wifi phone=off
    while [ $# -gt 0 ]; do
        case "$1" in
            --internet) internet=$2; shift ;;
            --phone) phone=$2; shift ;;
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
    case "$internet" in wifi|mobile|none) ;; *) die "start: --internet must be wifi, mobile or none" ;; esac
    case "$phone" in off|calls) ;; *) die "start: --phone must be off or calls" ;; esac
    if [ "$tor" = offline ]; then internet=none; fi
    if [ "$internet" = none ]; then tor=offline; fi
    if [ "$internet" = mobile ] && [ "$phone" = off ]; then die "start: mobile data comes with calls and texts (--phone calls)"; fi
    if [ "$tor" = bridges ] && [ -z "$file" ]; then die "start: --tor bridges needs --bridges-file"; fi
    if [ "$expect_loss" = false ] && ! hook_on; then
        die "the test hook $HOOK is not set: Start would switch USB debugging off and adb would disconnect; run 'provision' (debug build), or add --expect-adb-loss"
    fi

    wait_for start_button 60
    tap "internet_$internet"
    if [ "$tor" != offline ]; then tap "tor_$tor"; fi
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
    tap "phone_$phone"
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
    local want_cell=off got
    [ "$phone" = off ] || want_cell=phone
    [ "$internet" != mobile ] || want_cell=data
    got=$(row_cell)
    [ "$got" = "$want_cell" ] || die "cell is '$got', expected '$want_cell'"
    say "provider row: cell=$got"
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
    for key in no_install_unknown_sources_globally no_bluetooth; do
        restriction "$key" "$([ "$admin" = true ] && echo no || echo yes)"
    done
    # Location stays off in every session (WEL8): Administration no longer lifts it.
    restriction no_config_location yes
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

# word_call [PREFIX...] -- EXTRA...: 'content call' with the module_word
# method and these extras, run after PREFIX on the device (su 2000 for the
# shell user); prints what the tool prints, standard error included.
word_call() {
    local prefix=()
    while [ $# -gt 0 ] && [ "$1" != -- ]; do prefix+=("$1"); shift; done
    shift
    sh_ "${prefix[@]}" content call --user 0 --uri "$WORD_URI" --method module_word "$@" 2>&1 || true
}

cmd_check_module_word() {
    local out
    [ "$(sh_ id -u)" = 0 ] || die "check-module-word needs adb as root ('adb root')"
    sh_ dpm list-owners | grep -q "$PKG" || die "Welcome is not the device owner"
    out=$(word_call su 2000 -- "${WORD_NONE[@]}")
    case $out in
        *'Result:'*) die "the shell user (uid 2000) gave Welcome a word: $out" ;;
        *SecurityException*) say "the shell user's word refused (SecurityException)" ;;
        *) die "the shell user's word was not refused as expected: $out" ;;
    esac
    out=$(word_call -- --extra v:i:2 --extra calls:s:none --extra at:l:0 --extra until:l:0 \
        --extra ims:s:off --extra ims_at:l:0)
    case $out in
        *'Result:'*) die "root's malformed word was taken: $out" ;;
        *IllegalArgumentException*) say "root's malformed word refused" ;;
        *) die "root's malformed word was not refused as expected: $out" ;;
    esac
    out=$(word_call -- "${WORD_NONE[@]}")
    [ "$out" = 'Result: Bundle[{v=1}]' ] || die "root's word was not taken: $out"
    say "root's word taken: $out"
}

# --- WEL8: the two choices at Start, the Phone card, the module's word on the cell radio ---

# gate_rank off|phone|data: 0, 1, 2.
gate_rank() { case $1 in phone) echo 1 ;; data) echo 2 ;; *) echo 0 ;; esac; }

# expect_row FILE ID CHECKED ENABLED [TEXT]: in a scan, the row ID is
# (not) checked and (not) enabled, and its text holds TEXT; adds to
# problems otherwise. "-" for CHECKED or ENABLED: not compared.
expect_row() {
    local got state text
    got=$(row_read "$1" "$2") || { problems+=("no row $2 wholly on the page"); return 0; }
    state=${got%%	*}
    text=${got#*	}
    if [ "$3" != - ] && [ "${state%% *}" != "$3" ]; then problems+=("$2: checked is ${state%% *}, expected $3"); fi
    if [ "$4" != - ] && [ "${state#* }" != "$4" ]; then problems+=("$2: enabled is ${state#* }, expected $4"); fi
    if [ -n "${5:-}" ]; then
        case $text in *"$5"*) ;; *) problems+=("$2 does not say '$5': $text") ;; esac
    fi
}

# expect_says WHAT TEXT WANT...: TEXT (a row's or a card's, as row_read
# gave it) holds each WANT; adds to problems otherwise. "!WANT": does not
# hold it.
expect_says() {
    local what=$1 text=$2 w
    shift 2
    for w in "$@"; do
        case $w in
            '!'*) case $text in *"${w#!}"*) problems+=("$what says '${w#!}', which it must not: $text") ;; esac ;;
            *) case $text in *"$w"*) ;; *) problems+=("$what does not say '$w': $text") ;; esac ;;
        esac
    done
}

# The "What your carrier sees" card's key statements (strings.xml): with
# the radio on, the SIM, the phone and roughly where you are, and calls
# never through Tor; with Phone off, the radio off, and what an emergency
# call shows the carrier all the same.
CARD_SEES=('your carrier sees:' 'your SIM card' '(its IMEI)' 'roughly where you are' 'never go through Tor')
CARD_OFF=('With Phone off, the cellular radio stays off' 'emergency call; your carrier then sees this phone, its SIM card and roughly where you are' '!your carrier sees:')

# WEL8, before Start: the six attempts of the two choices, as a person
# makes them (Internet first, then Phone), checked against what Welcome
# must do with the gate the module told it. Welcome's rules, played here
# too: an Internet or Phone row the gate does not allow cannot be chosen
# (its tap does nothing); Phone off cannot be chosen with mobile data,
# which comes with calls and texts. Mobile data comes straight after an
# attempt with Phone off, so that the walk sees it select calls and texts
# by itself. Each attempt starts from the top of the page.
cmd_check_choices() {
    local gate='' shots='' g internet=wifi phone=off i p eff scan summary fail=0 attempt r card rows
    while [ $# -gt 0 ]; do
        case "$1" in
            --gate) gate=$2; shift ;;
            --shots) shots=$2; shift ;;
            *) die "check-choices: unknown option $1" ;;
        esac
        shift
    done
    case $gate in off|phone|data) ;; *) die "usage: check-choices --gate off|phone|data [--shots DIR]" ;; esac
    g=$(gate_rank "$gate")
    a shell input keyevent KEYCODE_WAKEUP
    a shell wm dismiss-keyguard >/dev/null 2>&1 || true
    wait_for start_button 60
    scan=$(mktemp)
    # shellcheck disable=SC2064 # the file's name now
    trap "rm -f '$scan'" RETURN
    # Start from the defaults: Wi-Fi, Phone off.
    to_top
    tap internet_wifi
    tap phone_off
    for attempt in wifi:off mobile:off mobile:calls wifi:calls none:off none:calls; do
        i=${attempt%%:*}
        p=${attempt#*:}
        problems=()
        to_top
        tap "internet_$i"
        if [ "$i" != mobile ] || [ "$g" -ge 2 ]; then internet=$i; fi
        tap "phone_$p"
        case $p in
            off) [ "$internet" = mobile ] || phone=off ;;
            calls) [ "$g" -lt 1 ] || phone=calls ;;
        esac
        eff=$phone
        [ "$internet" != mobile ] || eff=calls
        [ -z "$shots" ] || a exec-out screencap -p >"$shots/welcome-choice-$i-$p.png" || true
        # Welcome reads its state every 3 s; then the whole page.
        sleep 1
        radio_before=$(registry_radio)
        scan_page "$scan"
        for r in wifi mobile none; do
            expect_row "$scan" "internet_$r" "$([ "$r" = "$internet" ] && echo true || echo false)" -
        done
        if [ "$g" -ge 2 ]; then
            expect_row "$scan" internet_mobile - true
        else
            expect_row "$scan" internet_mobile false false "$MOBILE_REASON"
        fi
        expect_row "$scan" phone_off "$([ "$eff" = off ] && echo true || echo false)" \
            "$([ "$internet" = mobile ] && echo false || echo true)" "$([ "$internet" = mobile ] && echo "$OFF_REASON")"
        if [ "$g" -ge 1 ]; then
            expect_row "$scan" phone_calls "$([ "$eff" = calls ] && echo true || echo false)" true
        else
            expect_row "$scan" phone_calls false false "$CALLS_REASON"
        fi
        if [ "$internet" = none ]; then
            ! scan_has "$scan" tor_direct || problems+=("Tor's rows are shown without Internet")
        else
            scan_has "$scan" tor_direct || problems+=("Tor's rows are missing with Internet $internet")
        fi
        # The carrier card, read once (wholly on screen) for all its statements.
        if card=$(row_read "$scan" card_carrier_choice | cut -f2); then
            if [ "$eff" = calls ]; then
                expect_says card_carrier_choice "$card" 'With Phone on, the cellular radio is on from Start.' "${CARD_SEES[@]}" \
                    "$([ "$internet" = mobile ] && echo 'Mobile data goes through Tor' || echo 'Mobile data is off')"
            else
                expect_says card_carrier_choice "$card" "${CARD_OFF[@]}"
            fi
        else
            problems+=("no card_carrier_choice wholly on the page")
        fi
        check_lines "$scan"
        summary=$lines_read
        rows="internet $internet, phone $eff, tor $([ "$internet" = none ] && echo hidden || echo shown)"
        if [ "${#problems[@]}" -eq 0 ]; then
            say "gate $gate: $i+$p: ok: $rows; $summary"
        else
            say "gate $gate: $i+$p: FAILED: ${problems[*]}"
            fail=1
        fi
    done
    to_top
    tap internet_wifi
    tap phone_off
    [ "$fail" = 0 ] || die "check-choices --gate $gate failed (see above)"
    say "check-choices --gate $gate: the six attempts as expected; Wi-Fi and Phone off selected again"
}

# WEL8, after Start: the status screen's session lines, Phone card and
# carrier card, for the session's Internet and cell choice.
cmd_check_phone() {
    local internet=wifi cell='' scan line want radio summary card
    while [ $# -gt 0 ]; do
        case "$1" in
            --internet) internet=$2; shift ;;
            --cell) cell=$2; shift ;;
            *) die "check-phone: unknown option $1" ;;
        esac
        shift
    done
    case $cell in off|phone|data) ;; *) die "usage: check-phone [--internet wifi|mobile|none] --cell off|phone|data" ;; esac
    case $internet in wifi|mobile|none) ;; *) die "check-phone: --internet must be wifi, mobile or none" ;; esac
    a shell input keyevent KEYCODE_WAKEUP
    if [ -z "$(dump_ui | find_node poweroff_button)" ]; then
        a shell am start -n "$PKG/.StatusActivity" >/dev/null
        sleep 2
    fi
    wait_for status_title 30
    scan=$(mktemp)
    # shellcheck disable=SC2064 # the file's name now
    trap "rm -f '$scan'" RETURN
    problems=()
    sleep 2
    radio_before=$(registry_radio)
    scan_page "$scan"
    case $internet in wifi) want=Wi-Fi ;; mobile) want='Mobile data' ;; none) want=None ;; esac
    expect_row "$scan" row_internet - - "Internet | $want"
    expect_row "$scan" row_tor - - "$([ "$internet" = none ] && echo 'Tor | Not used' || echo 'Tor | ')"
    expect_row "$scan" row_phone - - "$([ "$cell" = off ] && echo 'Phone | Off' || echo 'Phone | Calls and texts')"
    line=$(row_read "$scan" ims_status | cut -f2) || line=
    if [ "$cell" = off ]; then
        case $line in *'| Not checked: Phone is off in this session') ;; *) problems+=("the VoLTE line is not 'Not checked: Phone is off in this session': $line") ;; esac
    else
        case $line in
            *'| Ready, over the cellular network' | *'| Ready' | *'| Ready over Wi-Fi calling'* | *'| Not connected for calls yet'* | *'| Not known yet') ;;
            *) problems+=("the VoLTE line is not one of its readings: $line") ;;
        esac
    fi
    radio=$(row_read "$scan" radio_status | cut -f2) || radio=
    if card=$(row_read "$scan" card_carrier | cut -f2); then
        case $radio in
            *'| On') expect_says card_carrier "$card" 'The cellular radio is on.' "${CARD_SEES[@]}" ;;
            *'| Off') expect_says card_carrier "$card" 'The cellular radio is off.' '!your carrier sees:' ;;
            *) expect_says card_carrier "$card" 'does not know yet whether the cellular radio is on' "${CARD_SEES[@]}" ;;
        esac
    else
        problems+=("no card_carrier wholly on the page")
    fi
    # "Offline" only without Internet and Phone, with the radio off.
    if [ "$internet" = none ] && [ "$cell" = off ] && [ "${radio##*| }" = Off ]; then
        check_lines "$scan" offline-ok
    else
        check_lines "$scan"
    fi
    summary=$lines_read
    to_top
    [ "${#problems[@]}" -eq 0 ] || die "check-phone: ${problems[*]}"
    say "check-phone: Internet $want, cell $cell: session lines, Phone card and carrier card as expected; $summary; VoLTE ${line##*| }"
}

# cell_call [PREFIX...] -- EXTRA...: 'content call' with the module_cell
# method, as word_call does for module_word.
cell_call() {
    local prefix=()
    while [ $# -gt 0 ] && [ "$1" != -- ]; do prefix+=("$1"); shift; done
    shift
    sh_ "${prefix[@]}" content call --user 0 --uri "$WORD_URI" --method module_cell "$@" 2>&1 || true
}

cmd_check_module_cell() {
    local out
    [ "$(sh_ id -u)" = 0 ] || die "check-module-cell needs adb as root ('adb root')"
    sh_ dpm list-owners | grep -q "$PKG" || die "Welcome is not the device owner"
    out=$(cell_call su 2000 -- "${CELL_CAREFUL[@]}")
    case $out in
        *'Result:'*) die "the shell user (uid 2000) gave Welcome a word on the cell radio: $out" ;;
        *SecurityException*) say "the shell user's word on the cell radio refused (SecurityException)" ;;
        *) die "the shell user's word on the cell radio was not refused as expected: $out" ;;
    esac
    out=$(cell_call -- --extra v:i:2 --extra gate:s:off --extra cell:s:none --extra radio:s:unknown --extra at:l:0)
    case $out in
        *'Result:'*) die "root's malformed word on the cell radio was taken: $out" ;;
        *IllegalArgumentException*) say "root's malformed word on the cell radio refused" ;;
        *) die "root's malformed word on the cell radio was not refused as expected: $out" ;;
    esac
    out=$(cell_call -- "${CELL_CAREFUL[@]}")
    [ "$out" = 'Result: Bundle[{v=1}]' ] || die "root's word on the cell radio was not taken: $out"
    say "root's word on the cell radio taken: $out"
}

# --- WEL10: the emergency card and Show my position ------------------------------

# The CI hook for the card's state lines (test builds only), its words, and
# where Welcome's own texts are (the checkout this script is in).
STATES_HOOK=debug.antumbra.emergency_states
STATE_WORDS=(no_sim sim_locked sim_unusable radio_off volte)
STRINGS=${WELCOME_STRINGS:-$(cd "$(dirname "$0")" && pwd)/../app/src/main/res/values/strings.xml}
# The test position: open ocean, no place. The shell takes latitude first,
# the emulator's console longitude first.
TEST_LAT=10.12345
TEST_LON=-140.54321
# Texts that would discourage an emergency call; no card text may match.
DISCOURAGING="(cannot|can't|can not|unable to|not possible to) (make|place|call)|no emergency call|do not call"

# str NAME: Welcome's text NAME (strings.xml), as the screen shows it.
STR_PY='
import re, sys
xml = open(sys.argv[1], encoding="utf-8").read()
m = re.search("<string name=\"" + re.escape(sys.argv[2]) + "\">([^<]*)</string>", xml)
if not m:
    sys.exit(1)
t = m.group(1).replace(chr(92) + chr(39), chr(39)).replace(chr(92) + chr(34), chr(34))
print(t.replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&"))
'
str() { python3 -I -c "$STR_PY" "$STRINGS" "$1" || die "no text $1 in $STRINGS"; }

# front_screen: "welcome" or "status", whichever is in front (10 s at most).
front_screen() {
    local xml end=$((SECONDS + 10))
    while [ $SECONDS -lt $end ]; do
        xml=$(dump_ui || true)
        if [ -n "$(find_node start_button <<<"$xml")" ]; then echo welcome; return 0; fi
        if [ -n "$(find_node poweroff_button <<<"$xml")" ]; then echo status; return 0; fi
        sleep 2
    done
    return 1
}

# android_numbers: Android's emergency numbers, one per line, from 'cmd phone
# emergency-number-test-mode -p' (a print of every phone's list, as root; it
# changes nothing). Fails when the print cannot be read.
android_numbers() {
    local out
    out=$(sh_ cmd phone emergency-number-test-mode -p 2>&1 || true)
    case $out in
        '['*']') tr -d '[] ' <<<"$out" | tr ',' '\n' | grep -E '^[0-9*#+]+$' || true ;;
        *) say "cannot read Android's emergency numbers: $out"; return 1 ;;
    esac
}

# sim_expect: the card's SIM line by Welcome's rule, from gsm.sim.state's
# slots: none (a SIM unlocked), sim_locked, sim_unusable, no_sim (every slot
# empty), or "?" (a slot starting, or nothing to read: not compared).
sim_expect() {
    local s n=0 ready=0 locked=0 unusable=0 absent=0
    for s in $(sh_ getprop gsm.sim.state | tr ',' ' '); do
        n=$((n + 1))
        case $s in
            LOADED | READY) ready=1 ;;
            PIN_REQUIRED | PUK_REQUIRED | NETWORK_LOCKED) locked=1 ;;
            CARD_IO_ERROR | PERM_DISABLED | CARD_RESTRICTED) unusable=1 ;;
            ABSENT) absent=$((absent + 1)) ;;
        esac
    done
    if [ "$n" = 0 ]; then echo '?'
    elif [ "$ready" = 1 ]; then echo none
    elif [ "$locked" = 1 ]; then echo sim_locked
    elif [ "$unusable" = 1 ]; then echo sim_unusable
    elif [ "$absent" = "$n" ]; then echo no_sim
    else echo '?'; fi
}

# scan_card FILE: like scan_page, but only from the top down to the dump
# that shows the end of the emergency card (Show my position) whole.
scan_card() {
    local file=$1 w h prev='' cur
    read -r w h < <(screen_size)
    to_top
    : >"$file"
    for _ in $(seq 1 8); do
        cur=$(dump_ui || true)
        [ "$cur" != "$prev" ] || break
        printf '%s\n<!-- page -->\n' "$cur" >>"$file"
        prev=$cur
        node_pick - position_button <<<"$cur" >/dev/null 2>&1 && break
        a shell input swipe $((w / 2)) $((h * 7 / 10)) $((w / 2)) $((h * 3 / 10)) 1000
    done
}

# card_read FILE: the card's lines in a scan: card_states (the state words
# shown, in the card's order), card_other (1 with the other-phone line),
# card_value (the number or numbers shown, as written, or empty), card_text
# (the number's line), and card_bad (lines whose text is not Welcome's).
card_read() {
    local file=$1 w got
    card_states='' card_other=0 card_value='' card_text='' card_bad=()
    for w in "${STATE_WORDS[@]}"; do
        scan_has "$file" "emergency_state_$w" || continue
        card_states=$card_states${card_states:+ }$w
        got=$(row_read "$file" "emergency_state_$w" | cut -f2) || got='(never whole)'
        [ "$got" = "$(str "emergency_state_$w")" ] || card_bad+=("emergency_state_$w says '$got'")
    done
    if scan_has "$file" emergency_other_phone; then
        card_other=1
        got=$(row_read "$file" emergency_other_phone | cut -f2) || got='(never whole)'
        [ "$got" = "$(str emergency_other_phone)" ] || card_bad+=("emergency_other_phone says '$got'")
    fi
    card_value=$(row_read "$file" emergency_number_value | cut -f2) || card_value=''
    card_text=$(row_read "$file" emergency_number_text | cut -f2) || card_text=''
}

# WEL10: the card's number and lines against the device. Reads only.
cmd_check_emergency_card() {
    local shot='' screen scan nums shown want_sim sim_row radio_row ims_row expect=() w radio_off=0 have
    while [ $# -gt 0 ]; do
        case "$1" in
            --screenshot) shot=$2; shift ;;
            *) die "check-emergency-card: unknown option $1" ;;
        esac
        shift
    done
    [ "$(sh_ id -u)" = 0 ] || die "check-emergency-card needs adb as root ('adb root'): only the shell and root may print Android's emergency numbers"
    [ -z "$(sh_ getprop "$STATES_HOOK")" ] || die "the test hook $STATES_HOOK is set: the card does not show its real lines (clear it first)"
    a shell input keyevent KEYCODE_WAKEUP
    a shell wm dismiss-keyguard >/dev/null 2>&1 || true
    screen=$(front_screen) || die "neither the Welcome nor the status screen is in front"
    nums=$(android_numbers) || die "Android's emergency numbers could not be printed"
    scan=$(mktemp)
    # shellcheck disable=SC2064 # the file's name now
    trap "rm -f '$scan'" RETURN
    problems=()
    sleep 1
    radio_before=$(registry_radio)
    scan_page "$scan"
    card_read "$scan"
    problems+=("${card_bad[@]}")
    # The numbers: each one of Android's, with the line for one or for
    # several; or "lists none" exactly when the print has none.
    shown=$(tr -c '0-9\n' '\n' <<<"$card_value" | grep . || true)
    if [ -n "$nums" ]; then
        if [ -z "$shown" ]; then
            problems+=("the card shows no number, while Android lists $(tr '\n' ' ' <<<"$nums")(its line: $card_text)")
        fi
        for w in $shown; do
            grep -qxF "$w" <<<"$nums" || problems+=("the card's number $w is not one Android lists ($(tr '\n' ' ' <<<"$nums"))")
        done
        if [ "$(grep -c . <<<"$shown")" -gt 1 ]; then
            [ "$card_text" = "$(str emergency_number_several)" ] || problems+=("the card shows several numbers, but its line is not the one for several: '$card_text'")
        else
            [ "$card_text" = "$(str emergency_number_detail)" ] || problems+=("the number's line is not the detail: '$card_text'")
        fi
    else
        [ -z "$card_value" ] || problems+=("the card shows $card_value, while Android lists no number")
        case $card_text in
            "$(str emergency_number_none)" | "$(str emergency_number_unreadable)") ;;
            *) problems+=("Android lists no number, but the card's line says '$card_text'") ;;
        esac
    fi
    # The state lines, from WEL8's rows on the same page and the device.
    want_sim=$(sim_expect)
    sim_row=$(row_read "$scan" sim_status_1 | cut -f2) || sim_row=''
    radio_row=$(row_read "$scan" radio_status | cut -f2) || radio_row=''
    ims_row=$(row_read "$scan" ims_status | cut -f2) || ims_row=''
    case $want_sim in no_sim | sim_locked | sim_unusable) expect+=("$want_sim") ;; esac
    case $radio_row in *"| $(str radio_off)") radio_off=1; expect+=(radio_off) ;; esac
    case $ims_row in
        *'| Not connected for calls yet'*)
            case $sim_row in *"| $(str sim_ready)") [ "$radio_off" = 1 ] || expect+=(volte) ;; esac ;;
    esac
    have=$card_states
    # A SIM still starting: its line is not compared.
    if [ "$want_sim" = '?' ]; then
        have=$(tr ' ' '\n' <<<"$have" | grep -vxE 'no_sim|sim_locked|sim_unusable' | tr '\n' ' ' | sed 's/ *$//')
    fi
    [ "$have" = "${expect[*]}" ] || problems+=("state lines '$have', expected '${expect[*]}' (SIM $want_sim, ${radio_row:-no radio row}, ${ims_row:-no VoLTE row})")
    if [ -n "$card_states" ] && [ "$card_other" != 1 ]; then problems+=("the other-phone line is missing"); fi
    if [ -z "$card_states" ] && [ "$card_other" = 1 ]; then problems+=("the other-phone line shows without a state line"); fi
    # WEL8's rows against the device (the radio row against the registry, the SIM row against gsm.sim.state).
    check_lines "$scan" offline-ok
    if scan_texts "$scan" | grep -qiE "$DISCOURAGING"; then
        problems+=("a text discourages an emergency call: $(scan_texts "$scan" | grep -iE "$DISCOURAGING" | head -n 1)")
    fi
    if [ -n "$shot" ]; then
        to_top
        view_row emergency_number_text >/dev/null || true
        a exec-out screencap -p >"$shot" || true
    fi
    to_top
    [ "${#problems[@]}" -eq 0 ] || die "check-emergency-card ($screen): ${problems[*]}"
    say "check-emergency-card ($screen): number $([ -n "$shown" ] && tr '\n' ' ' <<<"$shown" | sed 's/ $//' || echo none) ($(grep -c . <<<"$nums" || true) listed by Android), state lines '${card_states:-none}', other phone $([ "$card_other" = 1 ] && echo shown || echo not shown); $lines_read; nothing tapped or dialled"
}

# hook_set VALUE: the card's CI hook ('' clears it).
hook_set() {
    local v=${1:-}
    [ -n "$v" ] || v="''"
    a shell setprop "$STATES_HOOK" "$v" >/dev/null
}

# hook_clear: the hook cleared, and checked to be.
hook_clear() {
    hook_set ''
    [ -z "$(sh_ getprop "$STATES_HOOK")" ] || { say "$STATES_HOOK is still set"; return 1; }
}

# WEL10, test builds: each state's text on screen through the hook.
cmd_check_emergency_states() {
    local shots='' wait=20 scan real case_ value want text end ok fail=0 applied=0 now
    while [ $# -gt 0 ]; do
        case "$1" in
            --shots) shots=$2; shift ;;
            --wait) wait=$2; shift ;;
            *) die "check-emergency-states: unknown option $1" ;;
        esac
        shift
    done
    case $wait in '' | *[!0-9]*) die "check-emergency-states: --wait takes a number of seconds" ;; esac
    a shell input keyevent KEYCODE_WAKEUP
    a shell wm dismiss-keyguard >/dev/null 2>&1 || true
    front_screen >/dev/null || die "neither the Welcome nor the status screen is in front"
    scan=$(mktemp)
    # From here on, whatever happens, the hook is cleared.
    # shellcheck disable=SC2064 # the file's name now
    trap "rm -f '$scan'; hook_clear || say 'clear the hook with: adb shell setprop $STATES_HOOK \"\"'" EXIT
    trap 'exit 1' INT TERM HUP
    hook_clear || die "the hook could not be cleared before the check"
    sleep 4
    scan_card "$scan"
    card_read "$scan"
    real="$card_states/$card_other/$card_value/$card_text"
    for case_ in "${STATE_WORDS[@]}" all number_none number_unreadable; do
        want=$case_ text=''
        value=$case_
        case $case_ in
            all) value=$(IFS=,; echo "${STATE_WORDS[*]}"); want="${STATE_WORDS[*]}" ;;
            number_none) want=''; text=$(str emergency_number_none) ;;
            number_unreadable) want=''; text=$(str emergency_number_unreadable) ;;
        esac
        hook_set "$value"
        ok=0
        end=$((SECONDS + wait))
        while :; do
            sleep 2
            scan_card "$scan"
            card_read "$scan"
            problems=("${card_bad[@]}")
            [ "$card_states" = "$want" ] || problems+=("state lines '$card_states', expected '$want'")
            [ "$card_other" = "$([ -n "$want" ] && echo 1 || echo 0)" ] ||
                problems+=("the other-phone line is $([ "$card_other" = 1 ] && echo shown || echo missing)")
            if [ -n "$text" ]; then
                [ "$card_text" = "$text" ] || problems+=("the number's line says '$card_text'")
                [ -z "$card_value" ] || problems+=("a number is shown ($card_value)")
            fi
            if [ "${#problems[@]}" -eq 0 ]; then ok=1; break; fi
            [ $SECONDS -lt "$end" ] || break
        done
        if [ -n "$shots" ]; then
            to_top
            view_row emergency_number_text >/dev/null || true
            a exec-out screencap -p >"$shots/emergency-state-$case_.png" || true
        fi
        if [ "$ok" = 1 ]; then
            applied=1
            say "case $case_: ok: lines '${card_states:-none}'${text:+, number line as written}"
        else
            say "case $case_: FAILED: ${problems[*]}"
            fail=1
            # The first case never applied: the build does not read the hook.
            [ "$applied" = 1 ] || break
        fi
    done
    hook_clear || fail=1
    end=$((SECONDS + wait))
    while :; do
        sleep 2
        scan_card "$scan"
        card_read "$scan"
        now="$card_states/$card_other/$card_value/$card_text"
        [ "$now" != "$real" ] || break
        if [ $SECONDS -ge "$end" ]; then say "the card did not show its real lines again: '$now', before '$real'"; fail=1; break; fi
    done
    to_top
    trap - EXIT INT TERM HUP
    rm -f "$scan"
    [ "$applied" = 1 ] ||
        die "Welcome did not show the hook's lines: a release build ignores $STATES_HOOK (only debuggable or testOnly builds read it); the hook is cleared"
    [ "$fail" = 0 ] || die "check-emergency-states failed (see above); the hook is cleared"
    say "check-emergency-states: each state's text, all five, and both number lines shown as written; the hook cleared and the card's real lines back"
}

location_mode() { sh_ settings get secure location_mode; }

# wait_location on|off SECONDS: Location's switch as wanted within SECONDS (read only).
wait_location() {
    local end=$((SECONDS + $2)) m
    while :; do
        m=$(location_mode)
        case $1:$m in off:0 | on:[1-9]) return 0 ;; esac
        [ $SECONDS -lt "$end" ] || return 1
        sleep 1
    done
}

# test_provider ARGS: 'cmd location providers ARGS' as the shell user, whose
# mock-location app op the test provider needs; prints what it prints.
test_provider() { sh_ su 2000 cmd location providers "$@" 2>&1 || true; }

# on_screen ID: node ID is on the screen now (one dump, no scrolling).
on_screen() { dump_ui | find_node "$1" | grep -q .; }

# request_providers: the providers under which 'dumpsys location' lists a
# registration of Welcome's ("gps", ...), space-separated; empty when it
# lists none (or the dump's format is not the one read here).
request_providers() {
    sh_ dumpsys location | python3 -I -c '
import re, sys
cur, seen = None, set()
for line in sys.stdin:
    m = re.match(r"^\s*(\w+) provider(?: \[mock\])?:\s*$", line)
    if m:
        cur = m.group(1)
    elif cur and "org.antumbra.welcome" in line:
        seen.add(cur)
print(" ".join(sorted(seen)))
'
}

# window_secure: "yes" when Welcome's window has FLAG_SECURE ('dumpsys window
# windows'), "no" when it has not, "unreadable" when no window of Welcome's
# is listed.
window_secure() {
    sh_ dumpsys window windows | python3 -I -c '
import re, sys
blocks = re.split(r"\n(?=  Window #)", sys.stdin.read())
mine = [b for b in blocks if "org.antumbra.welcome/" in b.split("\n", 1)[0]]
if not mine:
    print("unreadable")
elif any(re.search(r"\bfl=[^\n]*\bSECURE\b", b) or "isSecure=true" in b for b in mine):
    print("yes")
else:
    print("no")
'
}

# clear-position-test: a search still on screen stopped with its own Stop
# button, the test provider removed, mock_location back to its default;
# fails while Location stays on. Idempotent; writes no location setting.
clear_position_test() {
    local fail=0 x y _c _e
    # A search always has Location on: only then is there a Stop to look for.
    if [ "$(location_mode)" != 0 ] && read -r x y _c _e < <(locate position_stop 2>/dev/null); then
        a shell input tap "$x" "$y" || true
        say "a search was still running: stopped with Welcome's Stop"
    fi
    test_provider remove-test-provider gps >/dev/null
    a shell appops set com.android.shell android:mock_location default >/dev/null 2>&1 || true
    if ! wait_location off 15; then
        say "Location is still on ($(location_mode)): Welcome did not switch it off"
        fail=1
    fi
    [ "$fail" = 0 ] || return 1
    say "the test provider is removed, mock_location is back to its default and Location is off"
}

# WEL10: Show my position, with the test provider or the emulator's receiver.
cmd_check_position() {
    local source=test shot='' wait=60 leave='' screen out x y _c en end got lat lon map acc mock loc pid hits
    local secure providers left='' t0
    while [ $# -gt 0 ]; do
        case "$1" in
            --source) source=$2; shift ;;
            --screenshot) shot=$2; shift ;;
            --wait) wait=$2; shift ;;
            --leave) leave=$2; shift ;;
            *) die "check-position: unknown option $1" ;;
        esac
        shift
    done
    case $source in test | gnss) ;; *) die "check-position: --source must be test or gnss" ;; esac
    case $wait in '' | *[!0-9]*) die "check-position: --wait takes a number of seconds" ;; esac
    case $leave in '' | sleep | home | none) ;; *) die "check-position: --leave must be sleep, home or none" ;; esac
    # Nothing is changed before these hold.
    [ "$(sh_ id -u)" = 0 ] || die "check-position needs adb as root ('adb root')"
    a shell input keyevent KEYCODE_WAKEUP
    a shell wm dismiss-keyguard >/dev/null 2>&1 || true
    screen=$(front_screen) || die "neither the Welcome nor the status screen is in front"
    [ -n "$leave" ] || leave=$([ "$screen" = welcome ] && echo sleep || echo home)
    calls_idle || die "a call is in progress; Show my position is not pressed"
    wait_location off 5 || die "Location is on before the check (location_mode $(location_mode)); it must be off"
    problems=()
    # From here on, whatever happens, the test is undone.
    trap 'clear_position_test || say "clear-position-test failed; run it again"' EXIT
    trap 'exit 1' INT TERM HUP
    if [ "$source" = test ]; then
        a shell appops set com.android.shell android:mock_location allow >/dev/null
        for out in "$(test_provider add-test-provider gps)" "$(test_provider set-test-provider-enabled gps true)"; do
            case $out in *Exception* | *Error* | *rror:* | *nknown*) die "the test provider could not be set up: $out" ;; esac
        done
    else
        a emu geo fix "$TEST_LON" "$TEST_LAT" >/dev/null || die "'adb emu geo fix' failed (the emulator only)"
    fi
    read -r x y _c en < <(locate position_button) || die "no Show my position button on the $screen screen"
    if [ "$en" != true ]; then
        die "Show my position is not offered: $(view_row position_refusal | cut -f2)"
    fi
    a shell input tap "$x" "$y"
    t0=$SECONDS
    end=$((SECONDS + 15))
    until [ "$(dump_ui | node_text position_status)" = "$(str position_looking)" ]; do
        [ $SECONDS -lt "$end" ] || die "Welcome did not say it is looking within 15 s: $(view_row position_status | cut -f2)"
        sleep 1
    done
    wait_location on 15 || die "Location did not come on within 15 s of Show my position"
    say "looking, Location on ($((SECONDS - t0)) s)"
    [ -z "$shot" ] || a exec-out screencap -p >"$shot" || true
    # Welcome's request, read while it looks: the gps provider only.
    providers=$(request_providers || true)
    case $providers in
        '') say "gps only: unreadable (dumpsys location lists no request of Welcome's)" ;;
        gps) say "gps only: yes (Welcome's request is under the gps provider alone)" ;;
        *) say "gps only: no (Welcome's request is under: $providers)"; problems+=("Welcome's request is not the gps provider's alone: $providers") ;;
    esac
    end=$((SECONDS + wait))
    until on_screen position_lat; do
        if [ $SECONDS -ge "$end" ]; then
            on_screen position_lat || locate position_lat >/dev/null ||
                die "no position on screen within $wait s ($(view_row position_status | cut -f2))"
            break
        fi
        if [ "$source" = test ]; then
            test_provider set-test-provider-location gps --location "$TEST_LAT,$TEST_LON" --accuracy 5 >/dev/null
        else
            a emu geo fix "$TEST_LON" "$TEST_LAT" >/dev/null || true
        fi
        sleep 2
    done
    say "a position on screen ($((SECONDS - t0)) s after the press)"
    lat=$(view_row position_lat | cut -f2) || lat=''
    lon=$(view_row position_lon | cut -f2) || lon=''
    map=$(view_row position_map | cut -f2) || map=''
    [ "$lat" = "10.12345° N" ] || problems+=("the latitude reads '$lat', not the test position's")
    [ "$lon" = "140.54321° W" ] || problems+=("the longitude reads '$lon', not the test position's")
    [ "$map" = "On a map: $TEST_LAT, $TEST_LON" ] || problems+=("the map line reads '$map'")
    acc=$(view_row position_accuracy | cut -f2) || acc=''
    mock=$(view_row position_mock | cut -f2) || mock=''
    if [ "$source" = test ]; then
        [ "$acc" = "Accurate to about 5 m." ] || problems+=("the accuracy line reads '$acc'")
        [ "$mock" = "$(str position_mock)" ] || problems+=("no line says the position comes from a test location")
    elif [ -n "$mock" ]; then
        problems+=("the emulator's receiver's position is said to be a test location")
    fi
    if wait_location off 10; then
        loc=$(view_row position_location | cut -f2) || loc=''
        [ "$loc" = "$(str position_off_again)" ] || problems+=("the card does not say Location is off again: '$loc'")
    else
        problems+=("Location stayed on after the position was found")
    fi
    secure=$(window_secure || echo unreadable)
    say "secure: $secure"
    [ "$secure" != no ] || problems+=("the position's window is not secure (FLAG_SECURE)")
    # Shown on screen only: in no file of Welcome's, not in its log, in no property.
    hits=$(sh_ "grep -rlF -e 10.12345 -e 140.54321 /data/data/$PKG /data/user_de/0/$PKG 2>/dev/null" || true)
    [ -z "$hits" ] || problems+=("the coordinates are in Welcome's files: $hits")
    pid=$(sh_ pidof "$PKG" || true)
    if [ -n "$pid" ]; then
        ! sh_ logcat -d --pid="$pid" | grep -qF -e 10.12345 -e 140.54321 || problems+=("the coordinates are in Welcome's log")
    else
        problems+=("Welcome's process was not found")
    fi
    ! sh_ getprop | grep -qF -e 10.12345 -e 140.54321 || problems+=("the coordinates are in a property")
    # Hide.
    if read -r x y _c _e < <(locate position_hide); then
        a shell input tap "$x" "$y"
        sleep 1
        ! on_screen position_lat || problems+=("Hide position left the coordinates on screen")
    else
        problems+=("no Hide position button")
    fi
    # A second search, left: Location off within 10 s.
    if [ "$leave" != none ]; then
        if read -r x y _c en < <(locate position_button) && [ "$en" = true ]; then
            a shell input tap "$x" "$y"
            if wait_location on 15; then
                if [ "$leave" = sleep ]; then a shell input keyevent KEYCODE_SLEEP; else a shell input keyevent KEYCODE_HOME; fi
                if wait_location off 10; then left="Location off within 10 s"; else left="Location stayed on"; problems+=("Location stayed on after leaving the screen during a search ($leave)"); fi
                a shell input keyevent KEYCODE_WAKEUP
                a shell wm dismiss-keyguard >/dev/null 2>&1 || true
                [ "$leave" != home ] || a shell am start -n "$PKG/.StatusActivity" >/dev/null
                sleep 2
                got=$(view_row position_status | cut -f2) || got=''
                [ "$got" = "$(str position_stopped)" ] || problems+=("after leaving, the card does not say Stopped: '$got'")
            else
                left="Location did not come on"
                problems+=("Location did not come on for the second search")
            fi
        else
            left="no second search"
            problems+=("Show my position was not offered again")
        fi
        say "leave ($leave): $left"
    fi
    to_top
    trap - EXIT INT TERM HUP
    clear_position_test || problems+=("the test could not be undone")
    [ "${#problems[@]}" -eq 0 ] || die "check-position ($source, $screen): ${problems[*]}"
    say "check-position ($source, $screen): the test position on screen as written, Location off after it, the window secure ($secure), nothing in Welcome's files, log or properties, Hide works; ${left:-not left}"
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

[ $# -ge 1 ] || { sed -n "4,173p" "$0" | sed 's/^# \{0,1\}//'; exit 2; }
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
    check-module-word) cmd_check_module_word ;;
    check-choices) cmd_check_choices "$@" ;;
    check-phone) cmd_check_phone "$@" ;;
    check-module-cell) cmd_check_module_cell ;;
    check-emergency-card) cmd_check_emergency_card "$@" ;;
    check-emergency-states) cmd_check_emergency_states "$@" ;;
    check-position) cmd_check_position "$@" ;;
    clear-position-test) clear_position_test || die "a search is still running, the test provider is still there, or Location is still on" ;;
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
