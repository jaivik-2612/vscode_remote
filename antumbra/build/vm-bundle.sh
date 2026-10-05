#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Package the qemu-virt build as a self-contained test bundle: kernel,
# initramfs, disk image (zstd), the exact kernel command line and a run
# script that needs only qemu-system-aarch64 and qemu-img.
#
# Inputs : build/out/qemu-virt/{kernel/Image,rootfs/initrd.img,vm-disk.img,
#          rootfs/filesystem.squashfs.roothash}, device/qemu-virt/cmdline.txt
# Output : build/out/qemu-virt/antumbra-<version>-qemu-virt.tar  (+ .sha256)
set -euo pipefail
export ANTUMBRA_DEVICE="${ANTUMBRA_DEVICE:-qemu-virt}"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
[ "${IMAGE_OUTPUT}" = "vmdisk" ] || die "ANTUMBRA_DEVICE=${ANTUMBRA_DEVICE} is not a VM profile"
require_tools zstd tar sha256sum
KOUT="${OUT}/kernel"; ROUT="${OUT}/rootfs"
NAME="antumbra-${ANTUMBRA_VERSION}-qemu-virt"
B="${WORK}/bundle/${NAME}"
rm -rf "${WORK}/bundle"; mkdir -p "${B}"
for f in "${KOUT}/Image" "${ROUT}/initrd.img" "${OUT}/vm-disk.img"; do [ -f "${f}" ] || die "missing ${f}"; done

CMDLINE="$(tr -d '\n' < "${PROFILE_DIR}/cmdline.txt")"
if [ "${ANTUMBRA_VERITY:-1}" != "0" ]; then
    ROOTHASH="$(tr -d '\n' < "${ROUT}/filesystem.squashfs.roothash")"
    CMDLINE="${CMDLINE} dm-verity-root-hash=filesystem.squashfs:${ROOTHASH} dm-verity-oncorruption=panic"
fi
CMDLINE="${CMDLINE} panic=10"
printf '%s\n' "${CMDLINE}" > "${B}/cmdline.txt"
cp "${KOUT}/Image" "${B}/Image"
cp "${ROUT}/initrd.img" "${B}/initrd.img"
zstd -q -T0 -19 --long=27 "${OUT}/vm-disk.img" -o "${B}/vm-disk.img.zst" -f
[ -f "${ROUT}/packages.txt" ] && cp "${ROUT}/packages.txt" "${B}/packages.txt"
cat > "${B}/run.sh" <<'RUN'
#!/bin/sh
# Boot this Antumbra test bundle in QEMU (arm64 "virt" machine).
#
#   ./run.sh            window with the display (needs a graphical QEMU build)
#   ./run.sh --headless serial console on this terminal only (Ctrl-A X quits)
#   ./run.sh --debug    adds antumbra.debug=1: root shell on the serial
#                       console's sibling "hvc0" (debug builds only); in the
#                       window, Ctrl-Alt-2 shows the hvc0 console
#   ./run.sh --fresh    discard the previous run's disk overlay
#
# Needs: qemu-system-aarch64, qemu-img, zstd. KVM is used when the host is
# arm64 with /dev/kvm; otherwise TCG emulation (slow: allow a few minutes).
set -eu
cd "$(dirname "$0")"
HEADLESS=""; DEBUG=""; FRESH=""; EXTRA=""
for a in "$@"; do case "$a" in --headless) HEADLESS=1 ;; --debug) DEBUG=1 ;; --fresh) FRESH=1 ;; *) EXTRA="$EXTRA $a" ;; esac; done
for t in qemu-system-aarch64 qemu-img zstd; do command -v "$t" >/dev/null || { echo "missing $t" >&2; exit 1; }; done
[ -f vm-disk.img ] || zstd -q -d vm-disk.img.zst -o vm-disk.img
[ -z "$FRESH" ] || rm -f overlay.qcow2
[ -f overlay.qcow2 ] || qemu-img create -q -f qcow2 -b vm-disk.img -F raw overlay.qcow2
CMDLINE="$(cat cmdline.txt)"
[ -z "$DEBUG" ] || CMDLINE="$CMDLINE antumbra.debug=1"
ACCEL="tcg,thread=multi"; [ -w /dev/kvm ] && [ "$(uname -m)" = "aarch64" ] && ACCEL=kvm
set -- -M virt,gic-version=3 -cpu cortex-a72 -smp 4 -m 3072 -accel "$ACCEL" \
    -kernel Image -initrd initrd.img -append "$CMDLINE" \
    -drive if=none,id=userdata,file=overlay.qcow2,format=qcow2 \
    -device virtio-blk-pci,drive=userdata,logical_block_size=4096,physical_block_size=4096 \
    -device virtio-rng-pci -device virtio-gpu-pci,xres=720,yres=1440 \
    -device virtio-keyboard-pci -device virtio-tablet-pci \
    -device virtio-serial-pci -device virtconsole,chardev=hvc0 \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 -no-reboot
# shellcheck disable=SC2086  # EXTRA holds several arguments on purpose
if [ -n "$HEADLESS" ]; then
    exec qemu-system-aarch64 "$@" -display none -serial mon:stdio -chardev file,id=hvc0,path=hvc0.log $EXTRA
fi
# shellcheck disable=SC2086
exec qemu-system-aarch64 "$@" -serial stdio -chardev vc,id=hvc0 $EXTRA
RUN
chmod +x "${B}/run.sh"
cat > "${B}/README.md" <<README
# ${NAME}

A test build of Antumbra for QEMU's arm64 virt machine. Not for the phone.

    ./run.sh              # window; ./run.sh --headless for serial only; --debug for a root shell on hvc0

Files: Image (kernel $(cat "${KOUT}/kernel.release")), initrd.img, vm-disk.img.zst
(GPT disk with the "userdata" partition holding the live and Persistent
Storage partitions), cmdline.txt (includes the dm-verity root hash of the
squashfs), packages.txt. Built $(date -u -d "@${SOURCE_DATE_EPOCH}" +%Y-%m-%dT%H:%M:%SZ) from commit $(git -C "${ANTUMBRA_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown).
See docs/vm-testing.md in the repository for what the VM can and cannot show.
README
( cd "${B}" && sha256sum Image initrd.img vm-disk.img.zst cmdline.txt run.sh > SHA256SUMS )
tar -C "${WORK}/bundle" --sort=name --mtime="@${SOURCE_DATE_EPOCH}" --owner=0 --group=0 --numeric-owner -cf "${OUT}/${NAME}.tar" "${NAME}"
sha256sum "${OUT}/${NAME}.tar" > "${OUT}/${NAME}.tar.sha256"
log "bundle: ${OUT}/${NAME}.tar ($(stat -c %s "${OUT}/${NAME}.tar") bytes)"
