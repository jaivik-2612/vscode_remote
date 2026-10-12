#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Antumbra CI: run the leak analyser on the scenarios' captures and write
# leak-report.json and leak-report.md, after the emulator has exited: BASELINE
# and ANTUMBRA in the emulator job, the app lab's scenario (apps) in the
# app-lab job. A scenario without a capture is left out.
#
# Inputs (environment):
#   ANTUMBRA_CI_OUT        the report directory the scenarios wrote; its
#                          capture/<scenario>-guest.pcap is the capture
#                          inside the guest (tcpdump -i any), and
#                          <scenario>/guest-links.txt names its interfaces
#   ANTUMBRA_CAPTURE_DIR   holds baseline.pcap and antumbra.pcap, or apps.pcap
#                          (-tcpdump: the emulator's first network card, eth0)
#   ANTUMBRA_MODULE_TREE   optional: the unpacked module, for bin/x86_64/tor
#                          (tor's compiled-in fallback directories)
#   ANTUMBRA_CI_DESTINATIONS  learning (default) or strict: whether a name or
#                          destination reached through Tor that is not in
#                          expected-destinations.txt only shows in the report
#                          or fails the run
#
# Writes <scenario>/analysis.json and analysis-exit for each scenario that
# has a capture, leak-report.json, leak-report.md, and capture/: a copy of
# each capture cut to 256 bytes per frame (headers, DNS names, TLS server
# names), plus the full captures, which the packing step drops first when
# the artifact would be too large. Never fails: summary.py --verdict judges.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${ANTUMBRA_CI_OUT:?}
CAP=${ANTUMBRA_CAPTURE_DIR:?}
TREE=${ANTUMBRA_MODULE_TREE:-}
LA=(python3 -B -I "$HERE/leak_analyser.py")
TORBIN=
[ -n "$TREE" ] && [ -f "$TREE/bin/x86_64/tor" ] && TORBIN=$TREE/bin/x86_64/tor

mkdir -p "$OUT/capture"
inputs=()

# captures SCENARIO: the arguments naming the scenario's captures (the
# emulator's, of eth0, and the one inside the guest) into the array args.
captures() {
	[ -s "$CAP/$1.pcap" ] && args+=(--pcap "$CAP/$1.pcap" --pcap-iface eth0)
	[ -s "$OUT/capture/$1-guest.pcap" ] && args+=(--guest-pcap "$OUT/capture/$1-guest.pcap")
	[ -s "$OUT/$1/guest-links.txt" ] && args+=(--guest-links "$OUT/$1/guest-links.txt")
	[ -s "$OUT/$1/events.tsv" ] && args+=(--events "$OUT/$1/events.tsv")
	[ -n "$TORBIN" ] && args+=(--tor-binary "$TORBIN")
	return 0
}

if [ -s "$CAP/baseline.pcap" ] || [ -s "$OUT/capture/baseline-guest.pcap" ]; then
	mkdir -p "$OUT/baseline"
	args=(analyse --scenario baseline --out "$OUT/baseline/analysis.json")
	captures baseline
	"${LA[@]}" "${args[@]}"
	echo $? >"$OUT/baseline/analysis-exit"
	inputs+=(--in "$OUT/baseline/analysis.json")
else
	echo "analyse: no baseline capture" >&2
fi

A=$OUT/antumbra
# A second run (by hand) finds the consensus already compressed.
if [ ! -s "$A/consensus" ] && [ -s "$A/consensus.gz" ]; then
	gzip -dc "$A/consensus.gz" >"$A/consensus" || rm -f "$A/consensus"
fi
if [ -s "$CAP/antumbra.pcap" ] || [ -s "$OUT/capture/antumbra-guest.pcap" ]; then
	mkdir -p "$A"
	# The arm cutoff: post_fs_data_start (build-module.sh, just before the
	# step that arms the firewall), else the earlier install_start.
	arm_event=install_start
	grep -q "^post_fs_data_start$(printf '\t')" "$A/events.tsv" 2>/dev/null && arm_event=post_fs_data_start
	args=(analyse --scenario antumbra --out "$A/analysis.json"
		--arm-event "$arm_event" --require-tor-traffic
		--armed-window armed_probe_start:armed_probe_end --require-armed-window
		--expected-destinations "$HERE/expected-destinations.txt"
		--destinations-mode "${ANTUMBRA_CI_DESTINATIONS:-learning}"
		--tor-streams "$A/tor-streams.txt" --filter-log "$A/dnsfilter.log")
	captures antumbra
	[ -s "$A/consensus" ] && args+=(--consensus "$A/consensus")
	[ -s "$A/bridges.txt" ] && args+=(--bridges "$A/bridges.txt")
	[ -f "$A/tor-connections.txt" ] && args+=(--expect-seen "$A/tor-connections.txt")
	[ -s "$A/device-ipv4.txt" ] && args+=(--expect-guest "$A/device-ipv4.txt")
	[ -s "$OUT/logs/antumbra-module.log" ] && args+=(--module-log "$OUT/logs/antumbra-module.log")
	"${LA[@]}" "${args[@]}"
	echo $? >"$A/analysis-exit"
	inputs+=(--in "$A/analysis.json")
else
	echo "analyse: no antumbra capture" >&2
fi

# The app lab: real apps under Antumbra, judged by the same rules as
# ANTUMBRA (anything after the arm cutoff that is not Tor or link-level is a
# LEAK), without an armed window. Its apps reach names and destinations no
# list expects: always listed, never failing (learning).
P=$OUT/apps
if [ ! -s "$P/consensus" ] && [ -s "$P/consensus.gz" ]; then
	gzip -dc "$P/consensus.gz" >"$P/consensus" || rm -f "$P/consensus"
fi
if [ -s "$CAP/apps.pcap" ] || [ -s "$OUT/capture/apps-guest.pcap" ]; then
	arm_event=install_start
	grep -q "^post_fs_data_start$(printf '\t')" "$P/events.tsv" 2>/dev/null && arm_event=post_fs_data_start
	args=(analyse --scenario apps --out "$P/analysis.json"
		--arm-event "$arm_event" --require-tor-traffic
		--expected-destinations "$HERE/expected-destinations.txt" --destinations-mode learning
		--tor-streams "$P/tor-streams.txt" --filter-log "$P/dnsfilter.log")
	captures apps
	[ -s "$P/consensus" ] && args+=(--consensus "$P/consensus")
	[ -s "$P/bridges.txt" ] && args+=(--bridges "$P/bridges.txt")
	[ -f "$P/tor-connections.txt" ] && args+=(--expect-seen "$P/tor-connections.txt")
	[ -s "$P/device-ipv4.txt" ] && args+=(--expect-guest "$P/device-ipv4.txt")
	[ -s "$OUT/logs/apps-module.log" ] && args+=(--module-log "$OUT/logs/apps-module.log")
	"${LA[@]}" "${args[@]}"
	echo $? >"$P/analysis-exit"
	inputs+=(--in "$P/analysis.json")
fi

if [ ${#inputs[@]} -gt 0 ]; then
	"${LA[@]}" report "${inputs[@]}" --json "$OUT/leak-report.json" --md "$OUT/leak-report.md"
fi

for s in baseline antumbra apps; do
	if [ -s "$CAP/$s.pcap" ]; then
		"${LA[@]}" slim "$CAP/$s.pcap" "$OUT/capture/$s.slim.pcap" || true
		cp "$CAP/$s.pcap" "$OUT/capture/$s.pcap"
	fi
	if [ -s "$OUT/capture/$s-guest.pcap" ]; then
		"${LA[@]}" slim "$OUT/capture/$s-guest.pcap" "$OUT/capture/$s-guest.slim.pcap" || true
	fi
done
for d in "$A" "$P"; do
	if [ -s "$d/consensus" ]; then
		gzip -9 -c "$d/consensus" >"$d/consensus.gz" && rm -f "$d/consensus"
	fi
done
exit 0
