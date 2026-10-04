#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build the Debian root filesystem tree with mmdebstrap, apply the overlay and
# run the build hooks inside the chroot (under qemu-user emulation on x86_64).
#
# Inputs : config/packages/*.list, config/rootfs/ (overlay), config/hooks/*.sh,
#          build/out/kernel/ (kernel.sh), build/cache/tor-browser/ (fetch-sources.sh),
#          ANTUMBRA_FIRMWARE_DIR (optional, fetch-firmware.sh)
# Outputs: build/work/rootfs/            the root filesystem tree (input of squashfs.sh)
#          build/out/rootfs/initrd.img   the initramfs generated inside the chroot
#          build/out/rootfs/packages.txt installed package versions
#
# Knobs  : ANTUMBRA_MINIMAL=1  base + network + amnesia lists only (pipeline validation)
#          ANTUMBRA_DEBUG=1    debug console/initramfs (never for releases)
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
[ -f "${KOUT}/kernel.release" ] || die "kernel release missing; run kernel.sh"

# --- Package list ---------------------------------------------------------------
if [ -n "${ANTUMBRA_MINIMAL}" ]; then
    LISTS=(base network amnesia)
else
    LISTS=(base network amnesia session phosh apps)
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
if [ -n "${ANTUMBRA_FIRMWARE_DIR}" ]; then
    [ -d "${ANTUMBRA_FIRMWARE_DIR}" ] || die "ANTUMBRA_FIRMWARE_DIR does not exist"
    cp -a "${ANTUMBRA_FIRMWARE_DIR}/." "${INPUT}/firmware/"
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
if [ -n "${SNAPSHOT}" ]; then
    APT_SOURCE="deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/${SNAPSHOT}/ ${SUITE} main contrib non-free-firmware"
else
    APT_SOURCE="deb ${MIRROR} ${SUITE} main contrib non-free-firmware"
fi

# --- mmdebstrap --------------------------------------------------------------------------
rm -rf "${ROOT}"
mkdir -p "${ROUT}"
HOOK_ENV="ANTUMBRA_VERSION=${ANTUMBRA_VERSION} SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} ANTUMBRA_DEBUG=${ANTUMBRA_DEBUG} ANTUMBRA_MINIMAL=${ANTUMBRA_MINIMAL} KERNEL_RELEASE=$(cat "${KOUT}/kernel.release")"
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
    --customize-hook="sync-in ${CONFIG_DIR}/rootfs /" \
    --customize-hook='mkdir -p "$1/run/antumbra-build"' \
    --customize-hook="sync-in ${INPUT} /run/antumbra-build" \
    --customize-hook="chroot \"\$1\" env ${HOOK_ENV} /bin/sh -e /run/antumbra-build/run-hooks.sh" \
    --customize-hook='chroot "$1" dpkg-query -W -f "\${Package} \${Version}\n" > '"${ROUT}/packages.txt" \
    --customize-hook='rm -rf "$1/run/antumbra-build"' \
    "${SUITE}" "${ROOT}" "${APT_SOURCE}"

# mmdebstrap removes the resolv.conf and hostname it placed in the chroot;
# Antumbra ships its own, so put them back from the overlay.
install -m 0644 "${CONFIG_DIR}/rootfs/etc/resolv.conf" "${ROOT}/etc/resolv.conf"
install -m 0644 "${CONFIG_DIR}/rootfs/etc/hostname" "${ROOT}/etc/hostname"

# --- Collect the initramfs ----------------------------------------------------------------------
KREL="$(cat "${KOUT}/kernel.release")"
[ -f "${ROOT}/boot/initrd.img-${KREL}" ] || die "initramfs was not generated for ${KREL}"
cp "${ROOT}/boot/initrd.img-${KREL}" "${ROUT}/initrd.img"
log "initramfs: $(stat -c %s "${ROUT}/initrd.img") bytes"
log "root filesystem tree ready at ${ROOT} ($(du -sh "${ROOT}" | cut -f1)), $(wc -l < "${ROUT}/packages.txt") packages"
