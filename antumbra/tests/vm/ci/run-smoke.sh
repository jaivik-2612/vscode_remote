#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Run the qemu-virt smoke test unattended for the daily VM workflow
# (.github/workflows/antumbra-vm.yml) and copy what the run produced into an
# output directory small enough to upload: the harness's PASS/FAIL output
# and report, the screenshots, the serial and debug-console logs, the
# kernel command line, and the packet capture (or only its summary when the
# capture is large).
#
# usage: run-smoke.sh --out DIR [OPTIONS] [-- SMOKE OPTIONS...]
#   --out DIR          the outputs go to DIR/vm/ (DIR is created if missing)
#   --timeout-scale F  the harness's --timeout-scale (default 1)
#   --deadline EPOCH   stop the harness by this time (seconds since the epoch)
#                      at the latest, so that collecting and uploading the
#                      outputs still fit in the job's time limit
#   --max-minutes N    stop the harness after N minutes at the latest (default 150)
#   --dry-run          print what would run, then exit
#   SMOKE OPTIONS      passed to `antumbra_vm.py smoke` (e.g. --through-welcome,
#                      --android, --tour; docs/vm-testing.md)
#
# Exit status: the harness's (0 when every check passed, 1 when one failed),
# 124 when it was stopped at the time limit, 2 for a usage error.
#
# Run it as root in CI (sudo -E): the build leaves the root hash and the
# qemu-virt work directory to root. DIR/vm/ is then handed to the user sudo
# was called by, so that the upload step can read it.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
export ANTUMBRA_DEVICE="${ANTUMBRA_DEVICE:-qemu-virt}"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../../build/lib/common.sh
source build/lib/common.sh
[ "${IMAGE_OUTPUT}" = "vmdisk" ] || die "ANTUMBRA_DEVICE=${ANTUMBRA_DEVICE} is not a VM profile"

usage() { sed -n '10,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

OUTDIR=""; SCALE=1; DEADLINE=""; MAX_MINUTES=150; DRY_RUN=""
while [ $# -gt 0 ]; do
    case "$1" in
        --out|--timeout-scale|--deadline|--max-minutes)
            [ $# -ge 2 ] || { echo "run-smoke.sh: $1 needs a value" >&2; exit 2; }
            case "$1" in
                --out) OUTDIR="$2" ;;
                --timeout-scale) SCALE="$2" ;;
                --deadline) DEADLINE="$2" ;;
                --max-minutes) MAX_MINUTES="$2" ;;
            esac
            shift ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        *) usage >&2; echo "run-smoke.sh: unknown option $1" >&2; exit 2 ;;
    esac
    shift
done
SMOKE_ARGS=("$@")
[ -n "${OUTDIR}" ] || { usage >&2; echo "run-smoke.sh: --out is required" >&2; exit 2; }
[[ "${SCALE}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "run-smoke.sh: --timeout-scale must be a number" >&2; exit 2; }
[[ "${MAX_MINUTES}" =~ ^[1-9][0-9]*$ ]] || { echo "run-smoke.sh: --max-minutes must be a whole number" >&2; exit 2; }
[ -z "${DEADLINE}" ] || [[ "${DEADLINE}" =~ ^[1-9][0-9]*$ ]] || { echo "run-smoke.sh: --deadline must be seconds since the epoch" >&2; exit 2; }

RUN="${WORK}/vm-run"
VMOUT="${OUTDIR}/vm"
# QEMU's sockets live in the run directory, and a UNIX socket's path must
# stay under 108 bytes ("/serial.sock" included): at most 94 for the run
# directory, which has 82 on GitHub's runner.
[ "${#RUN}" -le 94 ] || die "run directory ${RUN} is too long for QEMU's sockets: set ANTUMBRA_WORK to a shorter directory"
# The time limit: --max-minutes, or less when the deadline is nearer.
LIMIT=$((MAX_MINUTES * 60))
if [ -n "${DEADLINE}" ]; then
    left=$((DEADLINE - $(date +%s)))
    [ "${left}" -ge "${LIMIT}" ] || LIMIT="${left}"
fi
HARNESS=(python3 tests/vm/antumbra_vm.py smoke --timeout-scale "${SCALE}" "${SMOKE_ARGS[@]}")

if [ -n "${DRY_RUN}" ]; then
    printf 'run directory: %s\noutputs:       %s\ntime limit:    %s s\nharness:      ' "${RUN}" "${VMOUT}" "${LIMIT}"
    printf ' %q' "${HARNESS[@]}"
    printf '\n'
    exit 0
fi

require_tools python3 qemu-img timeout
mkdir -p "${VMOUT}"
# Under sudo, hand the outputs to the calling user however this script ends.
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_UID:-}" ]; then
    # shellcheck disable=SC2153  # sudo sets SUDO_GID along with SUDO_UID
    trap 'chown -R "${SUDO_UID}:${SUDO_GID:-${SUDO_UID}}" "${VMOUT}" || true' EXIT
fi
# Nothing of an earlier run in this checkout may pass for this one's.
rm -rf "${RUN}/smoke"
started="$(date +%s)"
status=0
if [ "${LIMIT}" -lt 300 ]; then
    msg="only ${LIMIT} s left before the deadline: the smoke test did not start"
    status=124
    : > "${VMOUT}/smoke.log"
else
    log "smoke test, at most ${LIMIT} s: ${HARNESS[*]}"
    # At the limit the harness gets Ctrl-C (it then stops the VM itself),
    # and two minutes later SIGKILL.
    timeout -s INT -k 120 "${LIMIT}" "${HARNESS[@]}" 2>&1 | tee "${VMOUT}/smoke.log" || status="${PIPESTATUS[0]}"
    # 137: the harness ignored the Ctrl-C and timeout sent SIGKILL; also the limit.
    [ "${status}" -ne 137 ] || status=124
    msg="the smoke test was stopped at its time limit (${LIMIT} s)"
fi
ended="$(date +%s)"
# QEMU runs detached: make sure it is gone, whatever the harness did.
build/vm.sh stop >/dev/null 2>&1 || true
if [ "${status}" -eq 124 ]; then
    echo "run-smoke.sh: ${msg}" | tee -a "${VMOUT}/smoke.log"
    [ "${GITHUB_ACTIONS:-}" != true ] || echo "::error title=VM smoke test::${msg}"
fi

# --- Collect ---------------------------------------------------------------------------
# copy_capped SRC DEST MAX: a text file whole, or, above MAX bytes, its first
# quarter and last three quarters of MAX with a marker between them.
copy_capped() {
    local size
    [ -f "$1" ] || return 0
    size="$(stat -c %s "$1")"
    if [ "${size}" -le "$3" ]; then
        cp "$1" "$2"
    else
        { head -c "$(($3 / 4))" "$1"
          printf '\n[... run-smoke.sh: %d bytes cut; the whole file was %d bytes ...]\n' "$((size - $3))" "${size}"
          tail -c "$(($3 * 3 / 4))" "$1"; } > "$2"
    fi
}
MIB=$((1024 * 1024))
: > "${VMOUT}/omitted.txt"
copy_capped "${RUN}/serial.log" "${VMOUT}/serial.log" $((8 * MIB))
copy_capped "${RUN}/hvc0.log" "${VMOUT}/hvc0.log" $((4 * MIB))
copy_capped "${RUN}/cmdline" "${VMOUT}/cmdline" "${MIB}"
# The harness's own outputs: report.json, screenshots, and the logs some
# modes save (Android's, for one).
if [ -d "${RUN}/smoke" ]; then
    mkdir -p "${VMOUT}/smoke"
    for f in "${RUN}"/smoke/*; do
        [ -f "${f}" ] || continue
        case "${f}" in
            *.txt|*.log|*.json) copy_capped "${f}" "${VMOUT}/smoke/$(basename "${f}")" $((4 * MIB)) ;;
            *) if [ "$(stat -c %s "${f}")" -le $((4 * MIB)) ]; then cp "${f}" "${VMOUT}/smoke/"
               else echo "smoke/$(basename "${f}"): $(stat -c %s "${f}") bytes" >> "${VMOUT}/omitted.txt"; fi ;;
        esac
    done
fi
if [ -f "${RUN}/net.pcap" ]; then
    python3 tests/vm/antumbra_vm.py --run-dir "${RUN}" pcap-summary > "${VMOUT}/pcap-summary.txt" 2>&1 || true
    if [ "$(stat -c %s "${RUN}/net.pcap")" -le $((8 * MIB)) ]; then cp "${RUN}/net.pcap" "${VMOUT}/"
    else echo "net.pcap: $(stat -c %s "${RUN}/net.pcap") bytes (pcap-summary.txt summarises it)" >> "${VMOUT}/omitted.txt"; fi
fi
[ -s "${VMOUT}/omitted.txt" ] || rm -f "${VMOUT}/omitted.txt"

# What metrics.py needs to know about this run besides its files.
qemu_version="$("${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}" --version 2>/dev/null | head -n1 || true)"
kvm=false; [ ! -e /dev/kvm ] || kvm=true
python3 -I - "${VMOUT}/harness.json" "${status}" "${LIMIT}" "${started}" "${ended}" "${SCALE}" "${qemu_version}" "${kvm}" \
    "${SMOKE_ARGS[@]}" <<'EOF'
import json, sys
path, status, limit, started, ended, scale, qemu, kvm = sys.argv[1:9]
json.dump({"exit_status": int(status), "timed_out": status == "124", "limit_seconds": int(limit),
           "started": int(started), "ended": int(ended), "seconds": int(ended) - int(started),
           "timeout_scale": float(scale), "smoke_args": sys.argv[9:], "qemu_version": qemu, "kvm": kvm == "true"},
          open(path, "w"), indent=1)
EOF

log "outputs in ${VMOUT} ($(du -sh "${VMOUT}" | cut -f1)); harness exit status ${status}"
exit "${status}"
