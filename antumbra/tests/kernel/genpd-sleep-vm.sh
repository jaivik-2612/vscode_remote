#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# VM test of genpd's noirq behaviour against a model of the 0102 sleep gate
# (device/oneplus-hotdog/kernel/patches/0102-*.patch). The module copies the
# gate's flag logic; it does not build or load hotdog-popup-motor.c.
#
# Builds tests/kernel/genpd-sleep against the qemu-virt kernel build, copies
# it into a running debug VM over the hvc0 root console and runs seven
# suspend-to-idle attempts, woken by the RTC (cases 4 and 6 are refused
# before the freeze, on purpose):
#   1 gate=1                 genpd calls power_on in resume_noirq; the gate
#                            turns it into a recorded state change, no motion
#   2 gate=1 active=1        a consumer held active across sleep (a stream):
#                            retracted at PM_SUSPEND_PREPARE, raised after resume
#   3 gate=0                 without the gate the noirq power_on would move the
#                            motor (the defect the patch fixes)
#   4 gate=1 fail_close=1 veto=1
#                            a failed close keeps the domain on, the suspend is
#                            refused after the retract: no raise afterwards
#   5 gate=1 fail_close=1 fail_retract=1
#                            the retract before sleep fails: the reconcile
#                            retracts after resume
#   6, 7                     cases 4 and 5 with legacy=1, the gate as 0102
#                            first had it: they must show its defects
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
        -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

HVC_LOG="${WORK}/vm-run/hvc0.log"
CASE_N=0

# Console input that is still queued when the guest freezes is lost (a command
# sent on the same tty would hang its caller), so the suspend runs from a
# detached job, and the host sends nothing until that job reports in hvc0.log
# that its write to /sys/power/state has returned: after the resume, or at
# once when the suspend was refused. Only then are the results read. The wait
# searches only what hvc0.log gained during this case, for a tag that ends in
# "-end", so a report from an earlier case or run never satisfies it.
run_case() { # run_case PARAM=VALUE... -> P_<name> from the module's parameters, SUSPEND_RC
    local out tag i off report
    CASE_N=$((CASE_N + 1))
    tag="${CASE_N}-$$-${RANDOM}${RANDOM}"
    off="$(stat -c %s "${HVC_LOG}")"
    vmsh "insmod /tmp/genpd_sleep_test.ko $* && \
setsid sh -c 'sleep 2; if command -v rtcwake >/dev/null; then rtcwake -m freeze -s ${SLEEP_S}; \
else echo 0 > /sys/class/rtc/rtc0/wakealarm; echo +${SLEEP_S} > /sys/class/rtc/rtc0/wakealarm; echo freeze > /sys/power/state; fi; \
rc=\$?; echo 0 > /sys/class/rtc/rtc0/wakealarm 2>/dev/null; sleep 1; \
printf \"genpd-sleep-%s-end rc=%s\\n\" ${tag} \$rc' </dev/null >/dev/hvc0 2>&1 &" >/dev/null
    report=""
    for i in $(seq 300); do
        report="$(tail -c +$((off + 1)) "${HVC_LOG}" | grep -ao "genpd-sleep-${tag}-end rc=[0-9]*" || true)"
        [ -z "${report}" ] || break
        [ "${i}" -lt 300 ] || die "the suspend job did not report after 300 s (case ${CASE_N})"
        sleep 1
    done
    SUSPEND_RC="${report##*rc=}"
    out="$(vmsh "cd /sys/module/genpd_sleep_test/parameters && for p in *; do printf 'P_%s=%s\\n' \"\$p\" \"\$(cat \"\$p\")\"; done; \
dmesg | grep 'antumbra-genpd-sleep-test' | tail -n 12; cd /; rmmod genpd_sleep_test")"
    printf '      write to /sys/power/state: rc=%s\n' "${SUSPEND_RC}"
    printf '%s\n' "${out}" | grep -v '^P_' | sed 's/^/      /'
    unset "${!P_@}"
    eval "$(printf '%s\n' "${out}" | grep -E '^P_[a-z_]+=[A-Za-z0-9]+$')"
}

log "case 1: gate=1 active=0 (camera closed, as at most suspends)"
run_case gate=1 active=0
check "genpd calls power_on in resume_noirq" "$([ "${P_noirq_power_on:-0}" -ge 1 ] && echo 1)" "noirq_power_on=${P_noirq_power_on:-?}"
check "gate: no motion in the noirq phases" "$([ "${P_noirq_moves:-1}" -eq 0 ] && echo 1)" "noirq_moves=${P_noirq_moves:-?}"
check "gate: noirq calls only recorded state" "$([ "${P_gated_calls:-0}" -ge 1 ] && echo 1)" "gated_calls=${P_gated_calls:-?}"
check "camera closed after resume" "$([ "${P_raised:-Y}" = N ] && echo 1)" "raised=${P_raised:-?}"
check "no raise after resume without a consumer" "$([ "${P_reconcile_raises:-1}" -eq 0 ] && echo 1)" "reconcile_raises=${P_reconcile_raises:-?}"

log "case 2: gate=1 active=1 (a stream held across sleep)"
run_case gate=1 active=1
check "retracted at PM_SUSPEND_PREPARE" "$([ "${P_prepare_retracts:-0}" -eq 1 ] && echo 1)" "prepare_retracts=${P_prepare_retracts:-?}"
check "genpd calls power_off in suspend_noirq" "$([ "${P_noirq_power_off:-0}" -ge 1 ] && echo 1)" "noirq_power_off=${P_noirq_power_off:-?}"
check "gate: no motion in the noirq phases" "$([ "${P_noirq_moves:-1}" -eq 0 ] && echo 1)" "noirq_moves=${P_noirq_moves:-?}"
check "raised again after resume for the stream" "$([ "${P_reconcile_raises:-0}" -eq 1 ] && [ "${P_raised:-N}" = Y ] && echo 1)" "reconcile_raises=${P_reconcile_raises:-?} raised=${P_raised:-?}"

log "case 3: gate=0 active=0 (the unpatched driver)"
run_case gate=0 active=0
check "without the gate, noirq power_on would move the motor" "$([ "${P_noirq_moves:-0}" -ge 1 ] && echo 1)" "noirq_moves=${P_noirq_moves:-?}"

log "case 4: gate=1 fail_close=1 veto=1 (a suspend aborted while a failed close keeps the domain on)"
run_case gate=1 fail_close=1 veto=1
check "setup: a failed close left the camera raised and the domain on" "$([ "${P_failed_closes:-0}" -eq 1 ] && [ "${P_domain_on:-N}" = Y ] && echo 1)" "failed_closes=${P_failed_closes:-?} domain_on=${P_domain_on:-?}"
check "the suspend was refused at PM_SUSPEND_PREPARE" "$([ "${P_vetoes:-0}" -eq 1 ] && [ "${SUSPEND_RC:-0}" != 0 ] && echo 1)" "vetoes=${P_vetoes:-?} rc=${SUSPEND_RC:-?}"
check "no noirq phase ran" "$([ "${P_noirq_power_on:-1}" -eq 0 ] && [ "${P_noirq_power_off:-1}" -eq 0 ] && echo 1)" "noirq_power_on=${P_noirq_power_on:-?} noirq_power_off=${P_noirq_power_off:-?}"
check "retracted at PM_SUSPEND_PREPARE" "$([ "${P_prepare_retracts:-0}" -eq 1 ] && echo 1)" "prepare_retracts=${P_prepare_retracts:-?}"
check "the reconcile ran after the abort" "$([ "${P_reconcile_runs:-0}" -ge 1 ] && echo 1)" "reconcile_runs=${P_reconcile_runs:-?}"
check "no raise after the abort without a consumer" "$([ "${P_reconcile_raises:-1}" -eq 0 ] && [ "${P_raised:-Y}" = N ] && echo 1)" "reconcile_raises=${P_reconcile_raises:-?} raised=${P_raised:-?}"

log "case 5: gate=1 fail_close=1 fail_retract=1 (the retract before sleep fails)"
run_case gate=1 fail_close=1 fail_retract=1
check "setup: the camera was raised with no consumer" "$([ "${P_failed_closes:-0}" -eq 1 ] && echo 1)" "failed_closes=${P_failed_closes:-?}"
check "the retract at PM_SUSPEND_PREPARE failed" "$([ "${P_failed_retracts:-0}" -eq 1 ] && [ "${P_prepare_retracts:-1}" -eq 0 ] && echo 1)" "failed_retracts=${P_failed_retracts:-?} prepare_retracts=${P_prepare_retracts:-?}"
check "genpd calls power_off in suspend_noirq" "$([ "${P_noirq_power_off:-0}" -ge 1 ] && echo 1)" "noirq_power_off=${P_noirq_power_off:-?}"
check "gate: no motion in the noirq phases" "$([ "${P_noirq_moves:-1}" -eq 0 ] && echo 1)" "noirq_moves=${P_noirq_moves:-?}"
check "the reconcile retracted after resume" "$([ "${P_reconcile_retracts:-0}" -eq 1 ] && [ "${P_raised:-Y}" = N ] && echo 1)" "reconcile_retracts=${P_reconcile_retracts:-?} raised=${P_raised:-?}"
check "no raise after resume without a consumer" "$([ "${P_reconcile_raises:-1}" -eq 0 ] && echo 1)" "reconcile_raises=${P_reconcile_raises:-?}"

log "case 6: case 4 with legacy=1 (the gate as 0102 first had it)"
run_case gate=1 legacy=1 fail_close=1 veto=1
check "first gate: raises the camera with no consumer after the abort (what case 4 catches)" "$([ "${P_vetoes:-0}" -eq 1 ] && [ "${P_reconcile_raises:-0}" -eq 1 ] && [ "${P_raised:-N}" = Y ] && echo 1)" "vetoes=${P_vetoes:-?} reconcile_raises=${P_reconcile_raises:-?} raised=${P_raised:-?}"

log "case 7: case 5 with legacy=1 (the gate as 0102 first had it)"
run_case gate=1 legacy=1 fail_close=1 fail_retract=1
check "first gate: leaves the camera raised after resume (what case 5 catches)" "$([ "${P_failed_retracts:-0}" -eq 1 ] && [ "${P_reconcile_retracts:-1}" -eq 0 ] && [ "${P_raised:-N}" = Y ] && echo 1)" "failed_retracts=${P_failed_retracts:-?} reconcile_retracts=${P_reconcile_retracts:-?} raised=${P_raised:-?}"

vmsh 'rm -f /tmp/genpd_sleep_test.ko /tmp/genpd_sleep_test.b64' >/dev/null
if [ "${fail}" -ne 0 ]; then echo "genpd sleep test FAILED"; exit 1; fi
echo "genpd sleep test passed"
