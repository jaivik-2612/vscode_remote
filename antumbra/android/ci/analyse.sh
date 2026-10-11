#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Antumbra CI: run the leak analyser on both scenarios' captures and write
# leak-report.json and leak-report.md, after the emulator has exited.
#
# Inputs (environment):
#   ANTUMBRA_CI_OUT        the report directory the scenarios wrote
#   ANTUMBRA_CAPTURE_DIR   holds baseline.pcap and antumbra.pcap (-tcpdump)
#   ANTUMBRA_MODULE_TREE   optional: the unpacked module, for bin/x86_64/tor
#                          (tor's compiled-in fallback directories)
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

if [ -s "$CAP/baseline.pcap" ]; then
	mkdir -p "$OUT/baseline"
	args=(analyse --scenario baseline --pcap "$CAP/baseline.pcap" --out "$OUT/baseline/analysis.json")
	[ -s "$OUT/baseline/events.tsv" ] && args+=(--events "$OUT/baseline/events.tsv")
	[ -n "$TORBIN" ] && args+=(--tor-binary "$TORBIN")
	"${LA[@]}" "${args[@]}"
	echo $? >"$OUT/baseline/analysis-exit"
	inputs+=(--in "$OUT/baseline/analysis.json")
else
	echo "analyse: no baseline capture at $CAP/baseline.pcap" >&2
fi

A=$OUT/antumbra
if [ -s "$CAP/antumbra.pcap" ]; then
	mkdir -p "$A"
	args=(analyse --scenario antumbra --pcap "$CAP/antumbra.pcap" --out "$A/analysis.json"
		--arm-event install_start --require-tor-traffic)
	[ -s "$A/events.tsv" ] && args+=(--events "$A/events.tsv")
	[ -s "$A/consensus" ] && args+=(--consensus "$A/consensus")
	[ -n "$TORBIN" ] && args+=(--tor-binary "$TORBIN")
	[ -s "$A/bridges.txt" ] && args+=(--bridges "$A/bridges.txt")
	[ -f "$A/tor-connections.txt" ] && args+=(--expect-seen "$A/tor-connections.txt")
	"${LA[@]}" "${args[@]}"
	echo $? >"$A/analysis-exit"
	inputs+=(--in "$A/analysis.json")
else
	echo "analyse: no antumbra capture at $CAP/antumbra.pcap" >&2
fi

if [ ${#inputs[@]} -gt 0 ]; then
	"${LA[@]}" report "${inputs[@]}" --json "$OUT/leak-report.json" --md "$OUT/leak-report.md"
fi

for s in baseline antumbra; do
	[ -s "$CAP/$s.pcap" ] || continue
	"${LA[@]}" slim "$CAP/$s.pcap" "$OUT/capture/$s.slim.pcap" || true
	cp "$CAP/$s.pcap" "$OUT/capture/$s.pcap"
done
if [ -s "$A/consensus" ]; then
	gzip -9 -c "$A/consensus" >"$A/consensus.gz" && rm -f "$A/consensus"
fi
exit 0
