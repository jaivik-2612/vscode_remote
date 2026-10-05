#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Package a release set: boot image, sparse userdata image, the port's
# validated DTBO and vbmeta companions, checksums, manifest and an optional
# minisign signature.
#
# Inputs : build/out/boot.img, build/out/userdata.simg, build/cache/device-assets/
# Output : build/out/release/antumbra-<version>-oneplus-hotdog/
# Knob   : ANTUMBRA_SIGNING_KEY=path to a minisign secret key (optional)
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
[ "${IMAGE_OUTPUT:-sparse}" = "sparse" ] || die "this step is for the phone profile only (ANTUMBRA_DEVICE=${ANTUMBRA_DEVICE} builds a QEMU disk; see docs/vm-testing.md)"

require_tools zstd split sha256sum
ensure_dirs
NAME="antumbra-${ANTUMBRA_VERSION}-oneplus-hotdog"
REL="${OUT}/release/${NAME}"
rm -rf "${REL}"; mkdir -p "${REL}"

for f in "${OUT}/boot.img" "${OUT}/userdata.simg" "${CACHE}/device-assets/dtbo.img" "${CACHE}/device-assets/vbmeta-disabled.img"; do
    [ -f "${f}" ] || die "missing ${f}"
done
if [ -n "${ANTUMBRA_DEBUG}" ]; then
    die "refusing to package a debug build (ANTUMBRA_DEBUG is set)"
fi

cp "${OUT}/boot.img" "${REL}/${NAME}-boot.img"
cp "${CACHE}/device-assets/dtbo.img" "${REL}/${NAME}-dtbo.img"
cp "${CACHE}/device-assets/vbmeta-disabled.img" "${REL}/${NAME}-vbmeta-disabled.img"
zstd -q -T0 -19 "${OUT}/userdata.simg" -o "${REL}/${NAME}-userdata.simg.zst"
# GitHub release assets must stay under 2 GiB.
if [ "$(stat -c %s "${REL}/${NAME}-userdata.simg.zst")" -gt $((1900 * 1048576)) ]; then
    ( cd "${REL}" && split -b 1900M -d -a 3 "${NAME}-userdata.simg.zst" "${NAME}-userdata.simg.zst.part" && rm "${NAME}-userdata.simg.zst" )
fi
cp "${ANTUMBRA_ROOT}/docs/flashing.md" "${REL}/INSTALL.md"
{
    printf '# Antumbra %s for the OnePlus 7T Pro (hotdog)\n\n' "${ANTUMBRA_VERSION}"
    printf 'Built %s from commit %s.\n\n' "$(date -u -d "@${SOURCE_DATE_EPOCH}" +%Y-%m-%dT%H:%M:%SZ)" "$(git -C "${ANTUMBRA_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    printf 'Kernel release: %s\n\n' "$(cat "${OUT}/kernel/kernel.release")"
    printf '## Files\n\n'
    # shellcheck disable=SC2016  # backticks are Markdown, not command substitution
    printf -- '- `%s-boot.img`: slot-B boot image (kernel, initramfs, DTB), built by Antumbra.\n' "${NAME}"
    # shellcheck disable=SC2016
    printf -- '- `%s-userdata.simg[.zst]`: sparse userdata image (live partition + empty Persistent Storage partition), built by Antumbra.\n' "${NAME}"
    # shellcheck disable=SC2016
    printf -- '- `%s-dtbo.img`, `%s-vbmeta-disabled.img`: unchanged copies of the hotdog-linux-bringup release assets (%s), pinned by SHA-256 in device/oneplus-hotdog/sources.lock.\n\n' "${NAME}" "${NAME}" "$(lock_get PORT_TAG)"
    printf 'The images contain no proprietary device firmware. See INSTALL.md.\n\n'
    printf '## Pinned inputs\n\n```\n'; grep -v '^#' "${DEVICE_DIR}/sources.lock" | grep -v '^$'; printf '```\n'
    if [ -f "${OUT}/rootfs/packages.txt" ]; then
        printf '\n## Packages (%s)\n\n```\n' "$(wc -l < "${OUT}/rootfs/packages.txt")"; cat "${OUT}/rootfs/packages.txt"; printf '```\n'
    fi
} > "${REL}/MANIFEST.md"
( cd "${REL}" && sha256sum -- * > SHA256SUMS )
if [ -n "${ANTUMBRA_SIGNING_KEY:-}" ]; then
    require_tools minisign
    minisign -S -s "${ANTUMBRA_SIGNING_KEY}" -m "${REL}/SHA256SUMS" -t "Antumbra ${ANTUMBRA_VERSION}"
    log "SHA256SUMS signed"
else
    warn "ANTUMBRA_SIGNING_KEY unset: release is unsigned"
fi
log "release in ${REL}:"; ls -la "${REL}"
