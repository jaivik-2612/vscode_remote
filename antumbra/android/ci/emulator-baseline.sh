#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Antumbra CI: the BASELINE scenario. Plain Android 16 (Google's emulator
# image without Google services), nothing of Antumbra installed: what does
# the phone contact on its own?
#
# Runs inside reactivecircus/android-emulator-runner, which has started the
# emulator with '-tcpdump <file>' (its first network card, eth0, from the
# first moment of boot) and waited for sys.boot_completed. This script:
#   1. adb root, for tcpdump inside the guest on every interface (Wi-Fi
#      included; lib/common.sh), then records the device and a clock
#      marker (see leak_analyser.py);
#   2. leaves the phone alone for ANTUMBRA_CI_BASELINE_WAIT seconds (180);
#   3. takes a screenshot of the home screen;
#   4. records the open TCP connections and the logs, then stops both
#      captures.
# The leak analyser then lists every destination in the capture and says how
# each would be judged once Antumbra's firewall is armed. Nothing here is
# judged a pass or a failure except the capture itself: it must show
# traffic from the phone, or it could not show a leak either.
#
# Environment: ANTUMBRA_CI_OUT (required), ANTUMBRA_SERIAL, ANTUMBRA_CAPTURE,
# ANTUMBRA_CI_BASELINE_WAIT.
set -uo pipefail

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
scenario_init baseline
WAIT=${ANTUMBRA_CI_BASELINE_WAIT:-180}

finish() {
	local rc=$?
	trap - EXIT
	set +e
	proc_net_snapshot
	ash 'dumpsys connectivity' 2>/dev/null | head -n 400 >"$LOGS/$SCEN-connectivity.txt"
	collect_logcat
	guest_capture_stop
	capture_stop
	if [ "$rc" -ne 0 ] || [ "$FAILED" -ne 0 ]; then rc=1; fi
	echo "$rc" >"$SDIR/result"
	say "done (exit $rc)"
	exit "$rc"
}
trap finish EXIT

event boot_completed
if ! wait_system_ready 300; then
	check system_ready fail "the system did not answer within 5 minutes of boot"
	exit 1
fi
check system_ready ok
# Root for tcpdump; plain Android's own traffic does not change with it.
timeout 60 adb -s "$ANTUMBRA_SERIAL" root >/dev/null 2>&1
sleep 3
wait_device 60
if [ "$(ash 'id -u')" = 0 ]; then
	guest_capture_start warn
else
	check guest_capture warn "adb root did not give a root shell: only eth0 is recorded"
fi
device_info
clock_marker

say "leaving the phone alone for $WAIT s"
end=$((SECONDS + WAIT))
while [ $SECONDS -lt "$end" ]; do
	left=$((end - SECONDS))
	sleep $((left < 30 ? left : 30))
	say "$((end - SECONDS > 0 ? end - SECONDS : 0)) s to go; default network: $(default_network)"
done
event wait_over

wake_screen
ash 'input keyevent KEYCODE_HOME' >/dev/null
sleep 3
screenshot home
net=$(default_network)
if [ -n "$net" ] && [ "$net" != none ]; then
	check default_network ok "$net"
else
	check default_network warn "Android had no default network: the capture will show little"
fi
