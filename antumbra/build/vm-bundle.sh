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

require_verity_as_built
CMDLINE="$(tr -d '\n' < "${PROFILE_DIR}/cmdline.txt")"
if [ "${ANTUMBRA_VERITY:-1}" != "0" ]; then
    [ -f "${ROUT}/filesystem.squashfs.roothash" ] || die "no root hash (run squashfs.sh, or set ANTUMBRA_VERITY=0)"
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
#   ./run.sh             display window + serial console on this terminal
#   ./run.sh --headless  serial console only (Ctrl-A X quits QEMU)
#   ./run.sh --debug     also antumbra.debug=1: a root shell on the virtio
#                        console, reachable at ./hvc0.sock (the script prints how)
#   ./run.sh --fresh     discard the previous run's disk changes
#
# Needs qemu-system-aarch64, qemu-img and zstd. Uses KVM on arm64 Linux with
# /dev/kvm and Apple's hypervisor on Apple-silicon Macs; anywhere else QEMU
# emulates the CPU (TCG), which takes several minutes to reach the Welcome
# screen.
set -eu
cd "$(dirname "$0")"
HEADLESS=""; DEBUG=""; FRESH=""; EXTRA=""
for a in "$@"; do case "$a" in --headless) HEADLESS=1 ;; --debug) DEBUG=1 ;; --fresh) FRESH=1 ;; *) EXTRA="$EXTRA $a" ;; esac; done
for t in qemu-system-aarch64 qemu-img zstd; do command -v "$t" >/dev/null || { echo "missing $t (see README.md)" >&2; exit 1; }; done
# The unpacked disk belongs to the vm-disk.img.zst it came from; after a newer
# bundle is extracted over an older one, unpack again and drop the overlay.
DISK_ID="$(grep ' vm-disk.img.zst$' SHA256SUMS)"
if [ ! -f vm-disk.img ] || [ "$(cat vm-disk.img.id 2>/dev/null || true)" != "$DISK_ID" ]; then
    echo "decompressing the disk image (4 GiB, sparse)..."
    rm -f vm-disk.img vm-disk.img.id overlay.qcow2
    zstd -q -d -f --sparse vm-disk.img.zst -o vm-disk.img.tmp
    mv vm-disk.img.tmp vm-disk.img
    printf '%s\n' "$DISK_ID" > vm-disk.img.id
fi
[ -z "$FRESH" ] || rm -f overlay.qcow2
[ -f overlay.qcow2 ] || qemu-img create -q -f qcow2 -b vm-disk.img -F raw overlay.qcow2
CMDLINE="$(cat cmdline.txt)"
[ -z "$DEBUG" ] || CMDLINE="$CMDLINE antumbra.debug=1"
ACCEL="tcg,thread=multi"; CPU=cortex-a72
if [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ]; then ACCEL=hvf; CPU=host
elif [ "$(uname -m)" = aarch64 ] && [ -w /dev/kvm ]; then ACCEL=kvm; CPU=host; fi
echo "accelerator: $ACCEL"
rm -f hvc0.sock
set -- -M virt,gic-version=max -cpu "$CPU" -smp 4 -m 4096 -accel "$ACCEL" \
    -kernel Image -initrd initrd.img -append "$CMDLINE" \
    -drive if=none,id=userdata,file=overlay.qcow2,format=qcow2 \
    -device virtio-blk-pci,drive=userdata,logical_block_size=4096,physical_block_size=4096 \
    -device virtio-rng-pci -device virtio-gpu-pci,xres=720,yres=1440 \
    -device virtio-keyboard-pci -device virtio-tablet-pci \
    -device virtio-serial-pci -chardev socket,id=hvc0,path=hvc0.sock,server=on,wait=off \
    -device virtconsole,chardev=hvc0 \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 -no-reboot -serial mon:stdio
[ -z "$DEBUG" ] || echo "debug shell (once booted): socat -,raw,echo=0 unix-connect:$PWD/hvc0.sock"
[ -z "$HEADLESS" ] || set -- "$@" -display none
# shellcheck disable=SC2086  # EXTRA holds several arguments on purpose
exec qemu-system-aarch64 "$@" $EXTRA
RUN
chmod +x "${B}/run.sh"
cat > "${B}/README.md" <<README
# ${NAME}

A test build of Antumbra for QEMU's arm64 virt machine. Not for the phone.

    ./run.sh              # display window + serial console on this terminal
    ./run.sh --headless   # serial console only; Ctrl-A X quits
    ./run.sh --debug      # also a root shell on the virtio console (see run.sh)

Install QEMU first: Debian/Ubuntu \`sudo apt install qemu-system-arm qemu-utils ipxe-qemu zstd\`,
Fedora \`sudo dnf install qemu-system-aarch64 qemu-img zstd\`, macOS \`brew install qemu zstd\`.
On an x86-64 PC QEMU emulates the ARM CPU: expect several minutes to the Welcome screen.
On an Apple-silicon Mac or an arm64 Linux machine with KVM it runs at native speed.

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
