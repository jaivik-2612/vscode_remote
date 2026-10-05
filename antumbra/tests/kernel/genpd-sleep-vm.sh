#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# VM test for the system-sleep gate of the pop-up motor patch
# (device/oneplus-hotdog/kernel/patches/0102-*.patch).
#
# Builds tests/kernel/genpd-sleep against the qemu-virt kernel build, copies
# it into a running debug VM over the hvc0 root console and runs three
# suspend-to-idle cycles, each woken by the RTC:
#   gate=1 active=0  genpd calls power_on in resume_noirq; the gate turns it
#                    into a recorded state change, no motion
#   gate=1 active=1  a consumer held active across sleep (a stream): retracted
#                    at PM_SUSPEND_PREPARE, raised again after resume
#   gate=0 active=0  without the gate the noirq power_on would move the motor
#                    (the defect the patch fixes)
#
# usage: tests/kernel/genpd-sleep-vm.sh [--ko FILE] [--sleep SECONDS]
# Needs: a debug VM image (make vm-build) running with the debug console
#        (make vm-start, or build/vm.sh start --debug), and, without --ko,
#        the qemu-virt kernel build tree (build/work/qemu-virt/kernel-build)
#        with build/cache/kernel still holding the sources it was built from.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
export ANTUMBRA_DEVICE=qemu-virt
# shellcheck source-path=SCRIPTDIR/../..
# shellcheck source=build/lib/common.sh
source build/lib/common.sh

KO=""
SLEEP_S=5
while [ $# -gt 0 ]; do
    case "$1" in
        --ko) KO="$2"; shift ;;
        --sleep) SLEEP_S="$2"; shift ;;
        -h|--help) sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

build/vm.sh status >/dev/null || die "the VM is not running (make vm-start, a debug build)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

vmsh() { build/vm.sh shell --timeout 300 "$1"; }

# --- Build ---------------------------------------------------------------------------
if [ -z "${KO}" ]; then
    require_tools make clang ld.lld llvm-strip
    KBUILD_OUT="${WORK}/kernel-build"
    [ -f "${KBUILD_OUT}/Module.symvers" ] || die "no ${KBUILD_OUT}/Module.symvers (make vm-build first)"
    make -s -C "${CACHE}/kernel" O="${KBUILD_OUT}" ARCH=arm64 LLVM=1 \
        LOCALVERSION="${KERNEL_LOCALVERSION}" \
        M="${ANTUMBRA_ROOT}/tests/kernel/genpd-sleep" MO="${TMP}/build" modules
    KO="${TMP}/build/genpd_sleep_test.ko"
fi
[ -f "${KO}" ] || die "module not found: ${KO}"
cp "${KO}" "${TMP}/m.ko"
llvm-strip --strip-debug "${TMP}/m.ko" 2>/dev/null || true
SUM="$(sha256sum "${TMP}/m.ko" | cut -d' ' -f1)"

# --- Copy into the VM through the console (lines stay under the tty limit) -------------
log "copying the module into the VM ($(stat -c %s "${TMP}/m.ko") bytes)"
vmsh 'rm -f /tmp/genpd_sleep_test.ko /tmp/genpd_sleep_test.b64; rmmod genpd_sleep_test 2>/dev/null; true' >/dev/null
base64 -w 3000 "${TMP}/m.ko" > "${TMP}/m.b64"
while IFS= read -r line; do
    vmsh "printf '%s\\n' '${line}' >> /tmp/genpd_sleep_test.b64" >/dev/null
done < "${TMP}/m.b64"
got="$(vmsh 'base64 -d /tmp/genpd_sleep_test.b64 > /tmp/genpd_sleep_test.ko && sha256sum /tmp/genpd_sleep_test.ko' | tail -n 1 | cut -d' ' -f1)"
[ "${got}" = "${SUM}" ] || die "module copy corrupted (${got} != ${SUM})"

# --- Cases -----------------------------------------------------------------------------
fail=0
check() { # check NAME OK DETAIL
    if [ "$2" = 1 ]; then printf 'PASS  %s\n' "$1"; else printf 'FAIL  %s (%s)\n' "$1" "$3"; fail=1; fi
}

run_case() { # run_case GATE ACTIVE -> sets P_<name> from the module's result parameters
    local out
    out="$(vmsh "insmod /tmp/genpd_sleep_test.ko gate=$1 active=$2 && \
if command -v rtcwake >/dev/null; then rtcwake -m freeze -s ${SLEEP_S} >/dev/null; \
else echo 0 > /sys/class/rtc/rtc0/wakealarm; echo +${SLEEP_S} > /sys/class/rtc/rtc0/wakealarm; echo freeze > /sys/power/state; fi; \
sleep 3; cd /sys/module/genpd_sleep_test/parameters && for p in *; do printf 'P_%s=%s\\n' \"\$p\" \"\$(cat \"\$p\")\"; done; \
dmesg | grep 'antumbra-genpd-sleep-test' | tail -n 12; cd /; rmmod genpd_sleep_test")"
    printf '%s\n' "${out}" | grep -v '^P_' | sed 's/^/      /'
    unset P_noirq_power_on P_noirq_power_off P_noirq_moves P_gated_calls P_prepare_retracts P_reconcile_raises P_raised P_domain_on
    eval "$(printf '%s\n' "${out}" | grep -E '^P_[a-z_]+=[A-Za-z0-9]+$')"
}

log "case 1: gate=1 active=0 (camera closed, as at most suspends)"
run_case 1 0
check "genpd calls power_on in resume_noirq" "$([ "${P_noirq_power_on:-0}" -ge 1 ] && echo 1)" "noirq_power_on=${P_noirq_power_on:-?}"
check "gate: no motion in the noirq phases" "$([ "${P_noirq_moves:-1}" -eq 0 ] && echo 1)" "noirq_moves=${P_noirq_moves:-?}"
check "gate: noirq calls only recorded state" "$([ "${P_gated_calls:-0}" -ge 1 ] && echo 1)" "gated_calls=${P_gated_calls:-?}"
check "camera closed after resume" "$([ "${P_raised:-Y}" = N ] && echo 1)" "raised=${P_raised:-?}"
check "no raise after resume without a consumer" "$([ "${P_reconcile_raises:-1}" -eq 0 ] && echo 1)" "reconcile_raises=${P_reconcile_raises:-?}"

log "case 2: gate=1 active=1 (a stream held across sleep)"
run_case 1 1
check "retracted at PM_SUSPEND_PREPARE" "$([ "${P_prepare_retracts:-0}" -eq 1 ] && echo 1)" "prepare_retracts=${P_prepare_retracts:-?}"
check "genpd calls power_off in suspend_noirq" "$([ "${P_noirq_power_off:-0}" -ge 1 ] && echo 1)" "noirq_power_off=${P_noirq_power_off:-?}"
check "gate: no motion in the noirq phases" "$([ "${P_noirq_moves:-1}" -eq 0 ] && echo 1)" "noirq_moves=${P_noirq_moves:-?}"
check "raised again after resume for the stream" "$([ "${P_reconcile_raises:-0}" -eq 1 ] && [ "${P_raised:-N}" = Y ] && echo 1)" "reconcile_raises=${P_reconcile_raises:-?} raised=${P_raised:-?}"

log "case 3: gate=0 active=0 (the unpatched driver)"
run_case 0 0
check "without the gate, noirq power_on would move the motor" "$([ "${P_noirq_moves:-0}" -ge 1 ] && echo 1)" "noirq_moves=${P_noirq_moves:-?}"

vmsh 'rm -f /tmp/genpd_sleep_test.ko /tmp/genpd_sleep_test.b64' >/dev/null
if [ "${fail}" -ne 0 ]; then echo "genpd sleep test FAILED"; exit 1; fi
echo "genpd sleep test passed"
