#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Pack the root filesystem tree into a reproducible squashfs and compute its
# dm-verity hash tree.
#
# Inputs : build/work/rootfs (rootfs.sh), config/squashfs-excludes
# Outputs: build/out/rootfs/filesystem.squashfs
#          build/out/rootfs/filesystem.squashfs.verity   (unless ANTUMBRA_VERITY=0)
#          build/out/rootfs/filesystem.squashfs.roothash
#          ANTUMBRA_VERITY=1 or 0 added to build/out/rootfs/build-flags
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_root
require_tools mksquashfs
ensure_dirs
ROOT="${WORK}/rootfs"
require_profile_stamps rootfs
ROUT="${OUT}/rootfs"
[ -d "${ROOT}/usr" ] || die "root filesystem tree missing; run rootfs.sh"
mkdir -p "${ROUT}"

SQ="${ROUT}/filesystem.squashfs"
rm -f "${SQ}" "${SQ}.verity" "${SQ}.roothash"
sed -i '/^ANTUMBRA_VERITY=/d' "${ROUT}/build-flags"
log "building squashfs (xz, arm BCJ, 1 MiB blocks)"
# squashfs-tools >= 4.6 reads SOURCE_DATE_EPOCH itself and refuses the
# explicit -mkfs-time/-all-time we pass for older versions; keep the flags.
env -u SOURCE_DATE_EPOCH mksquashfs "${ROOT}" "${SQ}" \
    -mem "${ANTUMBRA_SQUASHFS_MEM:-1G}" \
    -comp xz -Xbcj arm -Xdict-size 1M -b 1M \
    -noappend -no-recovery -no-progress \
    -xattrs \
    -mkfs-time "${SOURCE_DATE_EPOCH}" -all-time "${SOURCE_DATE_EPOCH}" \
    -processors "$(nproc)" \
    -wildcards -ef "${CONFIG_DIR}/squashfs-excludes" >/dev/null
log "squashfs: $(stat -c %s "${SQ}") bytes"

if [ "${ANTUMBRA_VERITY:-1}" != "0" ]; then
    require_tools veritysetup python3
    SALT="$(printf 'antumbra-verity-%s-%s' "${ANTUMBRA_VERSION}" "${SOURCE_DATE_EPOCH}" | sha256sum | cut -d' ' -f1)"
    VUUID="$(python3 -c "import uuid,sys; print(uuid.uuid5(uuid.NAMESPACE_URL, 'antumbra:${ANTUMBRA_VERSION}:verity'))")"
    veritysetup format --data-block-size=4096 --hash-block-size=4096 \
        --salt="${SALT}" --uuid="${VUUID}" \
        --root-hash-file="${SQ}.roothash" "${SQ}" "${SQ}.verity" >/dev/null
    veritysetup verify --root-hash-file="${SQ}.roothash" "${SQ}" "${SQ}.verity" >/dev/null \
        || die "verity self-verification failed"
    log "dm-verity root hash: $(cat "${SQ}.roothash")"
fi
sha256sum "${SQ}" > "${SQ}.sha256"
# Recorded with the tree's other flags once the squashfs is complete.
if [ "${ANTUMBRA_VERITY:-1}" != "0" ]; then VERITY_FLAG=1; else VERITY_FLAG=0; fi
printf 'ANTUMBRA_VERITY=%s\n' "${VERITY_FLAG}" >> "${ROUT}/build-flags"
