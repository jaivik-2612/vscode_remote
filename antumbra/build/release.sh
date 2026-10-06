#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Package a release set: boot image, sparse userdata image, the port's
# validated DTBO and vbmeta companions, checksums, manifest and an optional
# minisign signature.
#
# Inputs : build/out/boot.img, build/out/userdata.simg, build/cache/device-assets/,
#          build/out/rootfs/{build-flags,firmware.sha256,packages.txt} (rootfs.sh;
#          squashfs.sh adds ANTUMBRA_VERITY to build-flags)
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
require_profile_stamps kernel rootfs
FLAGS="${OUT}/rootfs/build-flags"
[ -z "$(stamp_value "${FLAGS}" ANTUMBRA_DEBUG)" ] || die "refusing to package a debug root filesystem (see ${FLAGS})"
[ "$(stamp_value "${OUT}/kernel/profile" KERNEL_RELEASE)" = "$(stamp_value "${FLAGS}" KERNEL_RELEASE)" ] \
    || die "the root filesystem was built for another kernel than build/out/kernel"
# The manifest says whether the images contain the builder's device firmware:
# a build-flags file that does not record it is refused, not read as "none".
grep -q '^DEVICE_FIRMWARE=' "${FLAGS}" \
    || die "${FLAGS} does not record whether device firmware is in the image; rebuild the rootfs step"
FIRMWARE="$(stamp_value "${FLAGS}" DEVICE_FIRMWARE)"
if [ "${FIRMWARE}" = "1" ]; then
    [ -s "${OUT}/rootfs/firmware.sha256" ] || die "${OUT}/rootfs/firmware.sha256 missing; rebuild the rootfs step"
fi
# rootfs.sh and squashfs.sh delete the images built before them, and
# squashfs.sh records ANTUMBRA_VERITY once the squashfs is complete: with that
# record, the images here were built from the tree build-flags describes.
VERITY="$(stamp_value "${FLAGS}" ANTUMBRA_VERITY)"
case "${VERITY}" in
    0|1) ;;
    *) die "${FLAGS} does not record ANTUMBRA_VERITY: squashfs.sh has not completed on this root filesystem; run it, then image.sh and bootimg.sh" ;;
esac

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
    if [ "${VERITY}" = "1" ]; then
        printf 'dm-verity: on\n\n'
    else
        printf 'dm-verity: off (built with ANTUMBRA_VERITY=0; the root filesystem is not verified at boot)\n\n'
    fi
    # A minimal build (ANTUMBRA_MINIMAL, any value but empty, as rootfs.sh reads it).
    if [ -n "$(stamp_value "${FLAGS}" ANTUMBRA_MINIMAL)" ]; then
        printf '%s\n\n' "This is a minimal build (ANTUMBRA_MINIMAL=$(stamp_value "${FLAGS}" ANTUMBRA_MINIMAL)), made to validate the build pipeline: it has only the base, network and amnesia package lists, and no Phosh, applications or Tor Browser."
    fi
    printf '## Files\n\n'
    # shellcheck disable=SC2016  # backticks are Markdown, not command substitution
    printf -- '- `%s-boot.img`: slot-B boot image (kernel, initramfs, DTB), built by Antumbra.\n' "${NAME}"
    # shellcheck disable=SC2016
    printf -- '- `%s-userdata.simg[.zst]`: sparse userdata image (live partition + empty Persistent Storage partition), built by Antumbra.\n' "${NAME}"
    # shellcheck disable=SC2016
    printf -- '- `%s-dtbo.img`, `%s-vbmeta-disabled.img`: unchanged copies of the hotdog-linux-bringup release assets (%s), pinned by SHA-256 in device/oneplus-hotdog/sources.lock.\n\n' "${NAME}" "${NAME}" "$(lock_get PORT_TAG)"
    if [ "${FIRMWARE}" = "1" ]; then
        printf '%s\n\n' "The userdata image contains proprietary device firmware: the files the builder supplied with ANTUMBRA_FIRMWARE_DIR, listed under \"Device firmware\" below. Qualcomm and OnePlus do not license it for redistribution, so this release is for the builder's own phone only and must not be published (Antumbra's docs/legal.md, \"Firmware\"). See INSTALL.md."
    else
        printf 'The images contain no proprietary device firmware. See INSTALL.md.\n\n'
    fi
    # The port's patched libcamera (ANTUMBRA_LIBCAMERA_LOCAL=1): its source must be offered with it.
    if [ "$(stamp_value "${FLAGS}" ANTUMBRA_LIBCAMERA_LOCAL)" = "1" ]; then
        printf '%s\n\n' "This build includes libcamera $(lock_get LIBCAMERA_LOCAL_VERSION), rebuilt with the hotdog-linux-bringup patches and tuning files (ANTUMBRA_LIBCAMERA_LOCAL=1). Whoever distributes it must also offer that modified source: Antumbra's build/cache/libcamera/ and device/oneplus-hotdog/libcamera/ (docs/legal.md)."
    fi
    # Android apps (ANTUMBRA_ANDROID=1): say so, and list their pins only then.
    pin_filter='^(WAYDROID|FDROID)_'
    if [ "$(stamp_value "${FLAGS}" ANTUMBRA_ANDROID)" = "1" ]; then
        printf '%s\n\n' "This build includes Android apps (Waydroid; off until turned on at the Welcome screen): the LineageOS 20 images from Waydroid's update channel and F-Droid, unmodified and pinned below. Their licences and sources: docs/legal.md, \"Android apps\"."
        pin_filter='^$'
    fi
    printf '## Pinned inputs\n\n```\n'; grep -v '^#' "${DEVICE_DIR}/sources.lock" | grep -v '^$' | grep -v -E "${pin_filter}"; printf '```\n'
    if [ "${FIRMWARE}" = "1" ]; then
        printf '\n## Device firmware (/lib/firmware, %s files, not redistributable)\n\n```\n' "$(wc -l < "${OUT}/rootfs/firmware.sha256")"; cat "${OUT}/rootfs/firmware.sha256"; printf '```\n'
    fi
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
[ "${FIRMWARE}" != "1" ] || warn "this release contains your device firmware: for your own phone only, do not publish it (docs/legal.md)"
log "release in ${REL}:"; ls -la "${REL}"
