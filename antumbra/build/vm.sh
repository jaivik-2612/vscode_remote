#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Run the qemu-virt profile in QEMU (arm64 "virt" machine, TCG or KVM).
#
# usage: vm.sh run   [OPTIONS]   foreground: the serial console is this terminal (Ctrl-A X quits)
#        vm.sh start [OPTIONS]   background: serial, console, monitor sockets in the run directory
#        vm.sh stop | status | powerdown | console | shell CMD... | screenshot FILE
#
# OPTIONS: --debug        antumbra.debug=1 (root shell on hvc0; debug builds only)
#          --vnc N        show the display on VNC :N (default: headless, screenshots still work)
#          --no-net       no network device at all
#          --keep-disk    reuse this run directory's disk overlay (default: fresh copy of vm-disk.img)
#          --memory MiB   guest memory (default 3072)
#          --smp N        virtual CPUs (default 3)
#          --append ARGS  extra kernel command-line arguments
#
# Inputs : build/out/qemu-virt/{kernel/Image,rootfs/initrd.img,rootfs/filesystem.squashfs.roothash,vm-disk.img}
#          device/qemu-virt/cmdline.txt
# Run dir: build/work/qemu-virt/vm-run/ (overlay.qcow2, serial.log, hvc0.log, net.pcap, sockets)
set -euo pipefail
export ANTUMBRA_DEVICE="${ANTUMBRA_DEVICE:-qemu-virt}"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
[ "${IMAGE_OUTPUT}" = "vmdisk" ] || die "ANTUMBRA_DEVICE=${ANTUMBRA_DEVICE} is not a VM profile"

usage() { sed -n '4,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

MODE="${1:-}"; [ $# -gt 0 ] && shift
DEBUG="${ANTUMBRA_DEBUG:-}"; VNC=""; NET=1; KEEP_DISK=""; MEMORY=3072; SMP=3; EXTRA_APPEND=""
while [ $# -gt 0 ]; do
    case "$1" in
        --debug) DEBUG=1 ;;
        --vnc) VNC="$2"; shift ;;
        --no-net) NET="" ;;
        --keep-disk) KEEP_DISK=1 ;;
        --memory) MEMORY="$2"; shift ;;
        --smp) SMP="$2"; shift ;;
        --append) EXTRA_APPEND="$2"; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        *) break ;;
    esac
    shift
done

RUN="${WORK}/vm-run"
HARNESS="${ANTUMBRA_ROOT}/tests/vm/antumbra_vm.py"
KOUT="${OUT}/kernel"; ROUT="${OUT}/rootfs"; DISK="${OUT}/vm-disk.img"
QEMU="${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}"

qemu_pid() { if [ -f "${RUN}/qemu.pid" ]; then cat "${RUN}/qemu.pid" 2>/dev/null || true; fi; }
running() { local pid; pid="$(qemu_pid)"; [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; }

case "${MODE}" in
    run|start) ;;
    status)
        if running; then echo "running (pid $(qemu_pid)), run directory ${RUN}"; else echo "not running"; exit 1; fi; exit 0 ;;
    stop)
        running || { echo "not running"; exit 0; }
        python3 "${HARNESS}" --run-dir "${RUN}" qmp quit >/dev/null 2>&1 || kill "$(qemu_pid)" 2>/dev/null || true
        for _ in $(seq 1 50); do running || break; sleep 0.2; done
        running && kill -9 "$(qemu_pid)" 2>/dev/null; rm -f "${RUN}/qemu.pid"; echo "stopped"; exit 0 ;;
    powerdown) exec python3 "${HARNESS}" --run-dir "${RUN}" qmp system_powerdown ;;
    console)
        running || die "not running (vm.sh start first)"
        if command -v socat >/dev/null; then exec socat -,raw,echo=0,escape=0x1d "unix-connect:${RUN}/serial.sock"; fi
        exec python3 "${HARNESS}" --run-dir "${RUN}" console ;;
    shell) exec python3 "${HARNESS}" --run-dir "${RUN}" shell "$@" ;;
    screenshot) exec python3 "${HARNESS}" --run-dir "${RUN}" screenshot "${1:?usage: vm.sh screenshot FILE}" ;;
    ''|-h|--help) usage; exit 0 ;;
    *) usage; die "unknown mode ${MODE}" ;;
esac

require_tools "${QEMU}" qemu-img python3
for f in "${KOUT}/Image" "${ROUT}/initrd.img" "${DISK}" "${PROFILE_DIR}/cmdline.txt"; do
    [ -f "${f}" ] || die "missing ${f} (build the qemu-virt profile first: make vm-build)"
done
! running || die "already running (pid $(qemu_pid)); vm.sh stop first"

# --- Kernel command line (same construction as bootimg.sh) ----------------------------
CMDLINE="$(tr -d '\n' < "${PROFILE_DIR}/cmdline.txt")"
if [ "${ANTUMBRA_VERITY:-1}" != "0" ]; then
    [ -f "${ROUT}/filesystem.squashfs.roothash" ] || die "no root hash (run squashfs.sh, or set ANTUMBRA_VERITY=0)"
    ROOTHASH="$(tr -d '\n' < "${ROUT}/filesystem.squashfs.roothash")"
    [[ "${ROOTHASH}" =~ ^[0-9a-f]{64}$ ]] || die "malformed root hash"
    CMDLINE="${CMDLINE} dm-verity-root-hash=filesystem.squashfs:${ROOTHASH} dm-verity-oncorruption=panic"
fi
# Debug: the hvc0 root shell (debug builds only) and the journal on the serial console.
[ -z "${DEBUG}" ] || CMDLINE="${CMDLINE} antumbra.debug=1 systemd.journald.forward_to_console=1 systemd.journald.max_level_console=info"
# A panic in the initramfs reboots after ten seconds; with -no-reboot QEMU
# exits instead, which is the failure signal the harness looks for.
CMDLINE="${CMDLINE} panic=10"
[ -z "${EXTRA_APPEND}" ] || CMDLINE="${CMDLINE} ${EXTRA_APPEND}"

# --- Run directory and disk overlay ----------------------------------------------------
mkdir -p "${RUN}"
if [ -z "${KEEP_DISK}" ] || [ ! -f "${RUN}/overlay.qcow2" ]; then
    rm -f "${RUN}/overlay.qcow2"
    qemu-img create -q -f qcow2 -b "${DISK}" -F raw "${RUN}/overlay.qcow2"
fi
rm -f "${RUN}/serial.sock" "${RUN}/hvc0.sock" "${RUN}/qmp.sock" "${RUN}/qemu.pid"
: > "${RUN}/serial.log"; : > "${RUN}/hvc0.log"; rm -f "${RUN}/net.pcap"
printf '%s\n' "${CMDLINE}" > "${RUN}/cmdline"

ACCEL=(-accel "tcg,thread=multi")
[ -w /dev/kvm ] && [ "$(uname -m)" = "aarch64" ] && ACCEL=(-accel kvm)
ARGS=(
    -M "virt,gic-version=3" -cpu cortex-a72 -smp "${SMP}" -m "${MEMORY}" "${ACCEL[@]}"
    -kernel "${KOUT}/Image" -initrd "${ROUT}/initrd.img" -append "${CMDLINE}"
    # The disk: the only partition is "userdata", 4096-byte sectors like the phone's UFS.
    -drive "if=none,id=userdata,file=${RUN}/overlay.qcow2,format=qcow2,cache=writeback,discard=unmap"
    -device "virtio-blk-pci,drive=userdata,logical_block_size=4096,physical_block_size=4096"
    -device virtio-rng-pci
    # A phone-shaped display: 720x1440 at scale 2 (etc/antumbra/phoc.ini, output Virtual-1).
    -device "virtio-gpu-pci,xres=720,yres=1440" -device virtio-keyboard-pci -device virtio-tablet-pci
    # hvc0: the debug console (a getty only in debug builds with antumbra.debug=1).
    -device virtio-serial-pci
    -chardev "socket,id=hvc0,path=${RUN}/hvc0.sock,server=on,wait=off,logfile=${RUN}/hvc0.log"
    -device "virtconsole,chardev=hvc0"
    -qmp "unix:${RUN}/qmp.sock,server=on,wait=off"
    -no-reboot
)
if [ -n "${NET}" ]; then
    # User-mode networking: the guest sees 10.0.2.0/24, a gateway and a DNS
    # forwarder at 10.0.2.3 (a leak target the firewall must block). Every
    # frame is captured for the smoke test's egress analysis.
    ARGS+=(-netdev "user,id=net0" -device "virtio-net-pci,netdev=net0,mac=52:54:00:a1:7b:01"
           -object "filter-dump,id=dump0,netdev=net0,file=${RUN}/net.pcap")
else
    ARGS+=(-nic none)
fi
if [ -n "${VNC}" ]; then ARGS+=(-vnc ":${VNC}"); else ARGS+=(-display none); fi

log "qemu-virt: ${MEMORY} MiB, ${SMP} CPUs, ${ACCEL[1]}, $( [ -n "${NET}" ] && echo "user network + pcap" || echo "no network" ), $( [ -n "${DEBUG}" ] && echo "debug console" || echo "no debug console" )"
if [ "${MODE}" = "run" ]; then
    log "serial console on this terminal; Ctrl-A X quits, Ctrl-A C is the QEMU monitor"
    exec "${QEMU}" "${ARGS[@]}" -serial mon:stdio
fi
ARGS+=(-chardev "socket,id=ser0,path=${RUN}/serial.sock,server=on,wait=off,logfile=${RUN}/serial.log" -serial chardev:ser0
       -daemonize -pidfile "${RUN}/qemu.pid")
"${QEMU}" "${ARGS[@]}"
log "started (pid $(qemu_pid)); serial log ${RUN}/serial.log; 'vm.sh console' attaches, 'vm.sh stop' ends it"
