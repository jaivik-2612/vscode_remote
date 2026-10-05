#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Assemble the Android boot image for slot B of the OnePlus 7T Pro.
#
# Inputs : build/out/kernel/{Image,sm8150-oneplus-hotdog.dtb}
#          build/out/rootfs/initrd.img            (rootfs.sh)
#          build/out/rootfs/filesystem.squashfs.roothash  (squashfs.sh, unless ANTUMBRA_VERITY=0)
#          device/oneplus-hotdog/{bootimg.conf,cmdline.txt}
#          build/cache/tools/avbtool.py
# Output : build/out/boot.img  (exactly BOOT_PARTITION_SIZE bytes, unsigned AVB footer)
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
[ "${IMAGE_OUTPUT:-sparse}" = "sparse" ] || die "this step is for the phone profile only (ANTUMBRA_DEVICE=${ANTUMBRA_DEVICE} builds a QEMU disk; see docs/vm-testing.md)"

require_tools python3
ensure_dirs
# shellcheck source=../device/oneplus-hotdog/bootimg.conf
source "${DEVICE_DIR}/bootimg.conf"

KOUT="${OUT}/kernel"
ROUT="${OUT}/rootfs"
require_profile_stamps kernel rootfs
[[ "$(cat "${KOUT}/kernel.release")" == *"${KERNEL_LOCALVERSION}" ]] || die "kernel.release does not end with ${KERNEL_LOCALVERSION}"
AVBTOOL="${CACHE}/tools/avbtool.py"
MKBOOTIMG="${CACHE}/tools/mkbootimg.py"
UNPACK_BOOTIMG="${CACHE}/tools/unpack_bootimg.py"
for f in "${KOUT}/Image" "${KOUT}/sm8150-oneplus-hotdog.dtb" "${ROUT}/initrd.img" "${AVBTOOL}" "${MKBOOTIMG}" "${UNPACK_BOOTIMG}"; do
    [ -f "${f}" ] || die "missing input ${f}"
done
[ "$(dd if="${KOUT}/Image" bs=1 skip=56 count=4 2>/dev/null)" = "ARM$(printf '\x64')" ] || die "Image is not a raw arm64 kernel"

# --- Command line ---------------------------------------------------------------
CMDLINE="$(tr -d '\n' < "${DEVICE_DIR}/cmdline.txt")"
if [ "${ANTUMBRA_VERITY:-1}" != "0" ]; then
    [ -f "${ROUT}/filesystem.squashfs.roothash" ] || die "no root hash (run squashfs.sh, or set ANTUMBRA_VERITY=0)"
    ROOTHASH="$(tr -d '\n' < "${ROUT}/filesystem.squashfs.roothash")"
    [[ "${ROOTHASH}" =~ ^[0-9a-f]{64}$ ]] || die "malformed root hash"
    CMDLINE="${CMDLINE} dm-verity-root-hash=filesystem.squashfs:${ROOTHASH} dm-verity-oncorruption=panic"
fi
if [ -n "${ANTUMBRA_DEBUG}" ]; then
    CMDLINE="${CMDLINE} antumbra.debug=1"
    CMDLINE="${CMDLINE/ quiet/}"
fi
[ "${#CMDLINE}" -le "${CMDLINE_MAX}" ] || die "command line is ${#CMDLINE} bytes, limit ${CMDLINE_MAX}"
log "command line (${#CMDLINE} bytes): ${CMDLINE}"

# --- mkbootimg --------------------------------------------------------------------
RAW="${WORK}/boot-raw.img"
python3 "${MKBOOTIMG}" \
    --header_version "${HEADER_VERSION}" \
    --pagesize "${PAGESIZE}" \
    --base "${BASE}" \
    --kernel_offset "${KERNEL_OFFSET}" \
    --ramdisk_offset "${RAMDISK_OFFSET}" \
    --second_offset "${SECOND_OFFSET}" \
    --tags_offset "${TAGS_OFFSET}" \
    --dtb_offset "${DTB_OFFSET}" \
    --kernel "${KOUT}/Image" \
    --ramdisk "${ROUT}/initrd.img" \
    --dtb "${KOUT}/sm8150-oneplus-hotdog.dtb" \
    --cmdline "${CMDLINE}" \
    -o "${RAW}"
RAWSIZE="$(stat -c %s "${RAW}")"
# avbtool needs room for its footer and metadata (a few pages).
[ "${RAWSIZE}" -le $((BOOT_PARTITION_SIZE - 1048576)) ] || die "boot image payload (${RAWSIZE} bytes) too large for the ${BOOT_PARTITION_SIZE}-byte partition"

# --- Unsigned AVB footer, padded to the partition size ------------------------------
OUTIMG="${OUT}/boot.img"
cp "${RAW}" "${OUTIMG}"
SALT="$(printf 'antumbra-%s-%s' "${ANTUMBRA_VERSION}" "$(cat "${KOUT}/kernel.release")" | sha256sum | cut -d' ' -f1)"
python3 "${AVBTOOL}" add_hash_footer --image "${OUTIMG}" --partition_name boot \
    --partition_size "${BOOT_PARTITION_SIZE}" --algorithm NONE --salt "${SALT}"
[ "$(stat -c %s "${OUTIMG}")" -eq "${BOOT_PARTITION_SIZE}" ] || die "boot.img is not exactly ${BOOT_PARTITION_SIZE} bytes"

# --- Verify what we produced -------------------------------------------------------------
INFO="$(python3 "${UNPACK_BOOTIMG}" --boot_img "${OUTIMG}" --out "${WORK}/boot-unpacked" 2>&1)"
echo "${INFO}" | grep -q "boot image header version: ${HEADER_VERSION}" || die "unexpected header version: ${INFO}"
echo "${INFO}" | grep -q "page size: ${PAGESIZE}" || die "unexpected page size"
echo "${INFO}" | grep -q "kernel load address: 0x$(printf '%08x' $((BASE + KERNEL_OFFSET)))" || die "unexpected kernel load address: ${INFO}"
echo "${INFO}" | grep -q "ramdisk load address: 0x$(printf '%08x' $((BASE + RAMDISK_OFFSET)))" || die "unexpected ramdisk load address"
echo "${INFO}" | grep -q "dtb address: 0x$(printf '%016x' $((BASE + DTB_OFFSET)))" || die "unexpected dtb address: ${INFO}"
python3 "${AVBTOOL}" info_image --image "${OUTIMG}" | grep -q 'Partition Name:\s*boot' || die "AVB footer missing"
cmp -s "${WORK}/boot-unpacked/kernel" "${KOUT}/Image" || die "kernel inside boot.img differs"
sha256sum "${OUTIMG}" | tee "${OUTIMG}.sha256"
log "boot.img ready"
