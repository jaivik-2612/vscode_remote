#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build the Debian root filesystem tree with mmdebstrap, apply the overlay and
# run the build hooks inside the chroot (under qemu-user emulation on x86_64).
#
# Inputs : config/packages/*.list, config/rootfs/ (overlay, staged by
#          stage_overlay in lib/common.sh), config/hooks/*.sh,
#          build/out/kernel/ (kernel.sh), build/cache/tor-browser/ (fetch-sources.sh),
#          ANTUMBRA_FIRMWARE_DIR (optional, fetch-firmware.sh)
# Outputs: build/work/rootfs/            the root filesystem tree (input of squashfs.sh)
#          build/out/rootfs/initrd.img   the initramfs generated inside the chroot
#          build/out/rootfs/packages.txt installed package versions
#          build/out/rootfs/build-flags  what the tree was built with (later steps check it)
#          build/out/rootfs/firmware.sha256  the builder's firmware files, when included
#
# Knobs  : ANTUMBRA_MINIMAL=1  base + network + amnesia lists only (pipeline validation)
#          ANTUMBRA_DEBUG=1    debug console/initramfs (never for releases)
#          ANTUMBRA_LIBCAMERA_LOCAL=1  libcamera from build/out/libcamera-repo (libcamera.sh)
#          ANTUMBRA_ANDROID=1  Android apps: android.list, config/rootfs-android/,
#                              build/cache/waydroid/ and build/cache/f-droid/ (fetch-sources.sh)
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_root
require_tools mmdebstrap chroot tar zstd
ensure_dirs

ROOT="${WORK}/rootfs"
ROUT="${OUT}/rootfs"
KOUT="${OUT}/kernel"
INPUT="${WORK}/build-input"
SUITE="$(lock_get DEBIAN_SUITE)"
MIRROR="$(lock_get DEBIAN_MIRROR)"
SNAPSHOT="$(grep -E '^DEBIAN_SNAPSHOT=' "${DEVICE_DIR}/sources.lock" | cut -d= -f2- || true)"
KEYRING=/usr/share/keyrings/debian-archive-keyring.gpg
[ -f "${KEYRING}" ] || die "install debian-archive-keyring on the build host"

HOSTARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
if [ "${HOSTARCH}" != "arm64" ] && [ "${HOSTARCH}" != "aarch64" ]; then
    require_tools arch-test
    arch-test arm64 >/dev/null 2>&1 || die "arm64 emulation unavailable: install qemu-user-static and binfmt-support"
fi

[ -f "${KOUT}/modules.tar.zst" ] || die "kernel modules missing; run kernel.sh"
require_profile_stamps kernel
[ -f "${KOUT}/kernel.release" ] || die "kernel release missing; run kernel.sh"

# --- Package list ---------------------------------------------------------------
if [ -n "${ANTUMBRA_MINIMAL}" ]; then
    LISTS=(base network amnesia)
else
    LISTS=(base network amnesia session phosh apps)
    # Test tools for the qemu-virt debug build only (docs/vm-testing.md).
    if [ -n "${ANTUMBRA_DEBUG}" ] && [ "${ANTUMBRA_DEVICE}" = "qemu-virt" ]; then
        LISTS+=(vm-debug)
    fi
fi
if [ -n "${ANTUMBRA_ANDROID}" ]; then
    [ -z "${ANTUMBRA_MINIMAL}" ] || die "ANTUMBRA_ANDROID=1 needs the session (the Welcome screen turns Android on); unset ANTUMBRA_MINIMAL"
    LISTS+=(android)
fi
PKGS=()
for l in "${LISTS[@]}"; do
    f="${CONFIG_DIR}/packages/${l}.list"
    [ -f "${f}" ] || die "missing package list ${f}"
    while read -r pkg; do
        pkg="${pkg%%#*}"; pkg="${pkg//[[:space:]]/}"
        [ -n "${pkg}" ] && PKGS+=("${pkg}")
    done < "${f}"
done
INCLUDE="$(IFS=,; printf '%s' "${PKGS[*]}")"
log "${#PKGS[@]} packages from lists: ${LISTS[*]}"

# --- Overlays: root-owned copies with fixed modes (stage_overlay) ----------------
OVERLAY="${WORK}/overlay"
rm -rf "${OVERLAY}"
stage_overlay "${CONFIG_DIR}/rootfs" "${OVERLAY}/rootfs"

# --- Build input staged into the chroot at /run/antumbra-build ------------------
rm -rf "${INPUT}"
mkdir -p "${INPUT}/hooks" "${INPUT}/kernel" "${INPUT}/tor-browser" "${INPUT}/firmware"
cp "${CONFIG_DIR}"/hooks/*.sh "${INPUT}/hooks/"
cp "${KOUT}/modules.tar.zst" "${KOUT}/kernel.release" "${KOUT}/config" "${KOUT}/mmap-rnd-bits" "${INPUT}/kernel/"
# The initramfs only accepts the live partition carrying this UUID; image.sh
# derives the same value for the filesystem it builds.
require_tools python3
python3 -c "import uuid; print(uuid.uuid5(uuid.NAMESPACE_URL, 'antumbra:${ANTUMBRA_VERSION}:live-fs'))" > "${INPUT}/kernel/live-fs-uuid"
if [ -z "${ANTUMBRA_MINIMAL}" ]; then
    [ -f "${CACHE}/tor-browser/version" ] || die "Tor Browser not fetched; run fetch-sources.sh"
    cp "${CACHE}"/tor-browser/tor-browser-linux-aarch64-*.tar.xz "${CACHE}/tor-browser/version" "${INPUT}/tor-browser/"
fi
# Android apps: the Android-only overlay, F-Droid and the image checksums go
# through the build input; the two images (about 2 GB) are copied straight
# into the tree by a customize hook below instead.
ANDROID_HOOKS=()
if [ -n "${ANTUMBRA_ANDROID}" ]; then
    WD="${CACHE}/waydroid/${WAYDROID_IMAGE_VARIANT}"
    for f in "${WD}/system.img" "${WD}/vendor.img" "${WD}/images.sha256" "${CACHE}/f-droid/F-Droid.apk"; do
        [ -f "${f}" ] || die "${f} missing; run fetch-sources.sh with ANTUMBRA_ANDROID=1"
    done
    mkdir -p "${INPUT}/android"
    cp "${WD}/images.sha256" "${CACHE}/f-droid/F-Droid.apk" "${INPUT}/android/"
    printf '%s\n' "${WAYDROID_IMAGE_VARIANT}" > "${INPUT}/android/variant"
    lock_get FDROID_APK_SHA256 > "${INPUT}/android/F-Droid.apk.sha256"
    stage_overlay "${CONFIG_DIR}/rootfs-android" "${OVERLAY}/rootfs-android"
    # shellcheck disable=SC2016  # $1 is expanded by mmdebstrap, not here
    ANDROID_HOOKS=(--customize-hook="sync-in ${OVERLAY}/rootfs-android /"
                   --customize-hook='mkdir -p "$1/usr/share/waydroid-extra/images"'
                   --customize-hook="install -m 0644 '${WD}/system.img' '${WD}/vendor.img' \"\$1/usr/share/waydroid-extra/images/\"")
    log "Android apps: Waydroid ${WAYDROID_IMAGE_VARIANT} images and F-Droid included"
fi
if [ -n "${ANTUMBRA_FIRMWARE_DIR}" ]; then
    [ -d "${ANTUMBRA_FIRMWARE_DIR}" ] || die "ANTUMBRA_FIRMWARE_DIR does not exist"
    copy_as_root "${ANTUMBRA_FIRMWARE_DIR}" "${INPUT}/firmware"
    log "firmware tree included from ${ANTUMBRA_FIRMWARE_DIR}"
else
    warn "no ANTUMBRA_FIRMWARE_DIR: the image will have no device firmware (display, Wi-Fi and audio will not work)"
fi
cat > "${INPUT}/run-hooks.sh" <<'RUNHOOKS'
#!/bin/sh
# Runs inside the chroot: execute every build hook in lexical order.
set -eu
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8
for hook in /run/antumbra-build/hooks/*.sh; do
    [ -f "${hook}" ] || continue
    echo "[hook] $(basename "${hook}")"
    sh -e "${hook}"
done
RUNHOOKS

# --- apt sources -------------------------------------------------------------------
# trixie, plus trixie-backports for the few packages pinned in
# config/rootfs/etc/apt/preferences.d/antumbra-backports (backports' own
# priority is 100, so nothing else is taken from it).
BACKPORTS="$(lock_get DEBIAN_BACKPORTS)"
if [ -n "${SNAPSHOT}" ]; then
    SNAP="https://snapshot.debian.org/archive/debian/${SNAPSHOT}/"
    APT_SOURCES=("deb [check-valid-until=no] ${SNAP} ${SUITE} main contrib non-free-firmware"
                 "deb [check-valid-until=no] ${SNAP} ${BACKPORTS} main")
else
    APT_SOURCES=("deb ${MIRROR} ${SUITE} main contrib non-free-firmware"
                 "deb ${MIRROR} ${BACKPORTS} main")
fi
PREFS="${OVERLAY}/rootfs/etc/apt/preferences.d/antumbra-backports"
[ -f "${PREFS}" ] || die "missing ${PREFS}"

# Optional patched libcamera (build/libcamera.sh, ANTUMBRA_LIBCAMERA_LOCAL=1):
# its local repository is added for the installation only, every libcamera
# package pinned to it above trixie-backports (libcamera0.7 and libcamera-ipa
# must come from the same build), and both files are removed again before the
# hooks run, so the image's apt configuration is the same as without it.
# copy:// rather than file:// because apt runs outside the chroot and dpkg
# inside it would not see the host path.
LIBCAMERA_HOOKS=()
LIBCAMERA_VERSION=''
if [ -n "${ANTUMBRA_LIBCAMERA_LOCAL:-}" ] && [ -z "${ANTUMBRA_MINIMAL}" ]; then
    LCREPO="${OUT}/libcamera-repo"
    [ -f "${LCREPO}/Packages" ] || die "ANTUMBRA_LIBCAMERA_LOCAL=1 but ${LCREPO} holds no packages; run build/libcamera.sh"
    LIBCAMERA_VERSION="$(lock_get LIBCAMERA_LOCAL_VERSION)"
    LCAPT="${WORK}/libcamera-apt"
    rm -rf "${LCAPT}"; mkdir -p "${LCAPT}"
    printf 'deb [trusted=yes] copy://%s ./\n' "${LCREPO}" > "${LCAPT}/antumbra-libcamera-local.list"
    cat > "${LCAPT}/antumbra-libcamera-local" <<'PIN'
Package: libcamera* gstreamer1.0-libcamera
Pin: release o=Antumbra,l=antumbra-libcamera
Pin-Priority: 990
PIN
    # shellcheck disable=SC2016  # $1 is expanded by mmdebstrap
    LIBCAMERA_HOOKS=(
        --setup-hook='mkdir -p "$1/etc/apt/sources.list.d"'
        --setup-hook="copy-in ${LCAPT}/antumbra-libcamera-local.list /etc/apt/sources.list.d"
        --setup-hook="copy-in ${LCAPT}/antumbra-libcamera-local /etc/apt/preferences.d"
        --customize-hook='rm -f "$1/etc/apt/sources.list.d/antumbra-libcamera-local.list" "$1/etc/apt/preferences.d/antumbra-libcamera-local"'
    )
    log "libcamera ${LIBCAMERA_VERSION} from the local repository ${LCREPO}"
fi

# --- mmdebstrap --------------------------------------------------------------------------
rm -rf "${ROOT}"
mkdir -p "${ROUT}"
# No stamps from an earlier tree: if this run fails, later steps refuse to go on.
rm -f "${ROUT}/build-flags" "${ROUT}/firmware.sha256"
HOOK_ENV="ANTUMBRA_VERSION=${ANTUMBRA_VERSION} ANTUMBRA_DEVICE=${ANTUMBRA_DEVICE} SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} ANTUMBRA_DEBUG=${ANTUMBRA_DEBUG} ANTUMBRA_MINIMAL=${ANTUMBRA_MINIMAL} ANTUMBRA_ANDROID=${ANTUMBRA_ANDROID} KERNEL_RELEASE=$(cat "${KOUT}/kernel.release")"
log "running mmdebstrap (${SUITE}, arm64) into ${ROOT}"
# shellcheck disable=SC2016  # $1 is expanded by mmdebstrap, not here
mmdebstrap \
    --mode=root \
    --variant=minbase \
    --architectures=arm64 \
    --components=main,contrib,non-free-firmware \
    --keyring="${KEYRING}" \
    --include="${INCLUDE}" \
    --aptopt='Acquire::Languages "none"' \
    --aptopt='APT::Install-Recommends "false"' \
    --dpkgopt='path-exclude=/usr/share/doc/*' \
    --dpkgopt='path-include=/usr/share/doc/*/copyright' \
    --dpkgopt='path-exclude=/usr/share/info/*' \
    --setup-hook='mkdir -p "$1/etc/apt/preferences.d"' \
    --setup-hook="copy-in ${PREFS} /etc/apt/preferences.d" \
    "${LIBCAMERA_HOOKS[@]}" \
    --customize-hook="sync-in ${OVERLAY}/rootfs /" \
    "${ANDROID_HOOKS[@]}" \
    --customize-hook='mkdir -p "$1/run/antumbra-build"' \
    --customize-hook="sync-in ${INPUT} /run/antumbra-build" \
    --customize-hook="chroot \"\$1\" env ${HOOK_ENV} /bin/sh -e /run/antumbra-build/run-hooks.sh" \
    --customize-hook='chroot "$1" dpkg-query -W -f "\${Package} \${Version}\n" > '"${ROUT}/packages.txt" \
    --customize-hook='rm -rf "$1/run/antumbra-build"' \
    "${SUITE}" "${ROOT}" "${APT_SOURCES[@]}"

# mmdebstrap removes the resolv.conf and hostname it placed in the chroot;
# Antumbra ships its own, so put them back from the overlay.
install -m 0644 "${CONFIG_DIR}/rootfs/etc/resolv.conf" "${ROOT}/etc/resolv.conf"
install -m 0644 "${CONFIG_DIR}/rootfs/etc/hostname" "${ROOT}/etc/hostname"
if [ -n "${LIBCAMERA_VERSION}" ]; then
    grep -qxF "libcamera0.7 ${LIBCAMERA_VERSION}" "${ROUT}/packages.txt" \
        || die "libcamera0.7 ${LIBCAMERA_VERSION} was not installed from the local repository"
fi

# The builder's device firmware, as hook 60 copied it into /lib/firmware:
# release.sh names it in the manifest (docs/legal.md, "Firmware").
DEVICE_FIRMWARE=''
if [ -n "$(cd "${INPUT}/firmware" && find . ! -type d ! -path ./MANIFEST.sha256 -print -quit)" ]; then
    DEVICE_FIRMWARE=1
    ( cd "${INPUT}/firmware" && find . -type f ! -path ./MANIFEST.sha256 -print0 | sort -z | xargs -0 -r sha256sum ) > "${ROUT}/firmware.sha256"
fi

# What this tree is: later steps (squashfs, image, bootimg, release) check it.
# ANTUMBRA_LIBCAMERA_LOCAL=1 when the local libcamera was installed (never in
# minimal builds), DEVICE_FIRMWARE=1 when the builder's firmware was; both
# are empty otherwise. squashfs.sh adds ANTUMBRA_VERITY (1 or 0).
printf 'ANTUMBRA_DEVICE=%s\nANTUMBRA_DEBUG=%s\nANTUMBRA_MINIMAL=%s\nANTUMBRA_ANDROID=%s\nANTUMBRA_LIBCAMERA_LOCAL=%s\nDEVICE_FIRMWARE=%s\nKERNEL_RELEASE=%s\n' \
    "${ANTUMBRA_DEVICE}" "${ANTUMBRA_DEBUG}" "${ANTUMBRA_MINIMAL}" "${ANTUMBRA_ANDROID}" "${LIBCAMERA_VERSION:+1}" "${DEVICE_FIRMWARE}" \
    "$(cat "${KOUT}/kernel.release")" > "${ROUT}/build-flags"

# --- Collect the initramfs ----------------------------------------------------------------------
KREL="$(cat "${KOUT}/kernel.release")"
[ -f "${ROOT}/boot/initrd.img-${KREL}" ] || die "initramfs was not generated for ${KREL}"
cp "${ROOT}/boot/initrd.img-${KREL}" "${ROUT}/initrd.img"
log "initramfs: $(stat -c %s "${ROUT}/initrd.img") bytes"
log "root filesystem tree ready at ${ROOT} ($(du -sh "${ROOT}" | cut -f1)), $(wc -l < "${ROUT}/packages.txt") packages"
