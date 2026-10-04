#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build the userdata image: a GPT with 4096-byte sectors sized to the physical
# partition, holding the read-only live partition and the (unformatted)
# Persistent Storage partition, exported as an Android sparse image whose
# empty regions are "don't care" chunks so fastboot writes only the data.
#
# Inputs : build/out/rootfs/filesystem.squashfs(.verity) (squashfs.sh),
#          build/out/rootfs/packages.txt, device/oneplus-hotdog/bootimg.conf
# Output : build/out/userdata.simg
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools systemd-repart mke2fs img2simg python3
ensure_dirs
# shellcheck source=../device/oneplus-hotdog/bootimg.conf
source "${DEVICE_DIR}/bootimg.conf"
ROUT="${OUT}/rootfs"
SQ="${ROUT}/filesystem.squashfs"
[ -f "${SQ}" ] || die "squashfs missing; run squashfs.sh"

uuid5() { python3 -c "import uuid,sys; print(uuid.uuid5(uuid.NAMESPACE_URL, sys.argv[1]))" "antumbra:${ANTUMBRA_VERSION}:$1"; }
LIVE_FS_UUID="$(uuid5 live-fs)"
LIVE_PART_UUID="$(uuid5 live-part)"
DATA_PART_UUID="$(uuid5 data-part)"
DISK_UUID="$(uuid5 disk)"
# Tails' Persistent Storage partition type, so its tooling recognises the volume.
DATA_TYPE_GUID="8DA63339-0007-60C0-C436-083AC8230908"

# --- Live partition contents ---------------------------------------------------------
LIVE="${WORK}/live"
rm -rf "${LIVE}"
mkdir -p "${LIVE}/live" "${LIVE}/.disk"
cp "${SQ}" "${LIVE}/live/filesystem.squashfs"
[ -f "${SQ}.verity" ] && cp "${SQ}.verity" "${LIVE}/live/filesystem.squashfs.verity"
[ -f "${SQ}.roothash" ] && cp "${SQ}.roothash" "${LIVE}/live/filesystem.squashfs.roothash"
printf 'filesystem.squashfs\n' > "${LIVE}/live/filesystem.module"
{
    printf 'Antumbra %s\n' "${ANTUMBRA_VERSION}"
    printf 'built %s\n' "$(date -u -d "@${SOURCE_DATE_EPOCH}" +%Y-%m-%dT%H:%M:%SZ)"
    printf 'kernel %s\n' "$(cat "${OUT}/kernel/kernel.release" 2>/dev/null || echo unknown)"
    printf 'squashfs sha256 %s\n' "$(cut -d' ' -f1 "${SQ}.sha256")"
} > "${LIVE}/.disk/info"
[ -f "${ROUT}/packages.txt" ] && cp "${ROUT}/packages.txt" "${LIVE}/live/antumbra.manifest"
find "${LIVE}" -exec touch -h -d "@${SOURCE_DATE_EPOCH}" {} +

# ext4, no journal (mounted read-only), sized to content plus slack
CONTENT_BYTES="$(du -sb "${LIVE}" | cut -f1)"
LIVE_MIB=$(( (CONTENT_BYTES / 1048576) + 96 ))
LIVE_EXT4="${WORK}/live.ext4"
rm -f "${LIVE_EXT4}"
E2FSPROGS_FAKE_TIME="${SOURCE_DATE_EPOCH}" mke2fs -q -t ext4 -F -d "${LIVE}" \
    -L ANTUMBRA_LIVE -U "${LIVE_FS_UUID}" -m 0 -O ^has_journal \
    -E lazy_itable_init=0,lazy_journal_init=0,hash_seed="${LIVE_FS_UUID}" \
    "${LIVE_EXT4}" "${LIVE_MIB}M"
log "live partition: ${LIVE_MIB} MiB ext4, label ANTUMBRA_LIVE, UUID ${LIVE_FS_UUID}"

# --- GPT sized to the physical userdata partition --------------------------------
REPART="${WORK}/repart.d"
rm -rf "${REPART}"; mkdir -p "${REPART}"
LIVE_BYTES="$(stat -c %s "${LIVE_EXT4}")"
cat > "${REPART}/10-live.conf" <<CONF
[Partition]
Type=linux-generic
Label=ANTUMBRA_LIVE
UUID=${LIVE_PART_UUID}
CopyBlocks=${LIVE_EXT4}
SizeMinBytes=${LIVE_BYTES}
SizeMaxBytes=${LIVE_BYTES}
CONF
cat > "${REPART}/20-data.conf" <<CONF
[Partition]
Type=${DATA_TYPE_GUID}
Label=ANTUMBRA_DATA
UUID=${DATA_PART_UUID}
SizeMinBytes=1G
CONF
RAW="${WORK}/userdata.img"
rm -f "${RAW}"
systemd-repart --empty=create --size="${USERDATA_PARTITION_SIZE}" --sector-size=4096 \
    --seed="${DISK_UUID}" --definitions="${REPART}" --dry-run=no --offline=yes --no-pager "${RAW}" >/dev/null
[ "$(stat -c %s "${RAW}")" -eq "${USERDATA_PARTITION_SIZE}" ] || die "userdata.img is not ${USERDATA_PARTITION_SIZE} bytes"
log "GPT written: $(systemd-repart --sector-size=4096 --definitions="${REPART}" --dry-run=yes --no-pager "${RAW}" 2>/dev/null | grep -E 'ANTUMBRA_(LIVE|DATA)' | awk '{print $1, $(NF-1), $NF}' | tr '\n' ';')"

# --- Android sparse image: holes become "don't care" --------------------------------
SIMG="${OUT}/userdata.simg"
rm -f "${SIMG}"
img2simg -s "${RAW}" "${SIMG}" 4096
rm -f "${RAW}"
SIMG_SIZE="$(stat -c %s "${SIMG}")"
LIVE_SIZE="$(stat -c %s "${LIVE_EXT4}")"
[ "${SIMG_SIZE}" -lt $((LIVE_SIZE + 64 * 1048576)) ] || die "sparse image unexpectedly large (${SIMG_SIZE} bytes): holes were not preserved"
sha256sum "${SIMG}" > "${SIMG}.sha256"
log "userdata.simg: ${SIMG_SIZE} bytes (sparse; expands to ${USERDATA_PARTITION_SIZE} on the device)"
