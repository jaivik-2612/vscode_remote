#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck disable=SC2015 # "A && pass || bad" is fine: pass never fails.
#
# Runs welcome-adb.sh against a fake adb: the screen logic (finding
# controls, typing bridge lines), the test hook rule, the provider checks
# and check-policies / check-addon. No device or emulator needed.
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
    "exec-out cat "*) cat "$d/ui.xml" ;;
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
        switch_unsafe_browser status_title; do
        node "$id" false "" $y
        y=$((y + 100))
    done
    node switch_mac true "" $y
    node row_firewall false "" $((y + 100)) "$(node "" false Firewall 0)$(node "" false "Live (rules 0123abcd4567)" 0)"
    echo '</hierarchy>'
} >"$work/ui.xml"
cat >"$work/restrictions" <<'R'
  Device policy global restrictions:
    null
  Device policy local restrictions:
    no_safe_boot no_config_tethering no_wifi_direct disallow_config_private_dns
    no_near_field_communication_radio no_debugging_features no_change_wifi_state
    no_config_wifi no_add_wifi_config no_install_unknown_sources_globally no_bluetooth
    no_config_location
R

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

# 4. check-addon reads the firewall row's text.
"$script" check-addon 2>"$work/err" && pass "check-addon" || bad "check-addon: $(cat "$work/err")"

# 5. check-policies: all restrictions present = offline/no add-on, no hook.
"$script" check-policies --wifi-locked 2>"$work/err" && pass "check-policies --wifi-locked" ||
    bad "check-policies: $(cat "$work/err")"
if "$script" check-policies --admin --keep-adb 2>"$work/err"; then bad "check-policies ignored restrictions"; else
    grep -q 'no_debugging_features is set' "$work/err" && grep -q 'no_bluetooth is set' "$work/err" &&
        grep -q 'no_config_wifi is set' "$work/err" && pass "check-policies reports wrong restrictions" ||
        bad "check-policies output: $(cat "$work/err")"
fi

# 6. expect counts bridge lines.
"$script" expect started=1 bridges=2 unsafe_browser=0 2>"$work/err" && pass "expect" || bad "expect: $(cat "$work/err")"

[ "$fail" = 0 ] || exit 1
echo "all welcome-adb.sh cases passed"
