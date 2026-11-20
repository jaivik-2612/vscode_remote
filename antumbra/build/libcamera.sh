#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Optional step (ANTUMBRA_LIBCAMERA_LOCAL=1): rebuild libcamera 0.7.2 for
# trixie arm64 with the hotdog port's libcamera patches, as a local apt
# repository that rootfs.sh pins above trixie-backports. See docs/camera.md.
#
# Without this step the image takes libcamera 0.7.1 from trixie-backports.
# That release has no sensor data for the phone's IMX471, IMX586, IMX481 and
# S5K3M5 (gain model, black level), no soft-ISP autofocus and not the port's
# 3A changes; the port's patches 0003-0010 add them on top of 0.7.2.
#
# Inputs : device/oneplus-hotdog/sources.lock (LIBCAMERA_*, PORT_LIBCAMERA_BASE_URL,
#          DEBIAN_SUITE, DEBIAN_MIRROR, DEBIAN_SNAPSHOT),
#          device/oneplus-hotdog/libcamera/{patches.list,patches.sha256,antumbra-packaging.diff}
# Outputs: build/cache/libcamera/        the verified source package, port patches and tuning files
#          build/out/libcamera-repo/     arm64 .debs at LIBCAMERA_LOCAL_VERSION (same binary
#                                        package names as Debian's), Packages, Release, inputs-id
#
# How: Debian's 0.7.2-1 source package (hash-pinned .dsc), with
# antumbra-packaging.diff applied, the port's patches appended to its quilt
# series and the port's tuning files added to libcamera-ipa, is built by
# dpkg-buildpackage in a throwaway trixie chroot made by mmdebstrap
# (build/lib/libcamera-chroot.sh does the work inside). On an x86-64 host the
# chroot is amd64 with arm64 as a foreign architecture and the build is a
# cross build (-aarm64, crossbuild-essential-arm64, arm64 build dependencies
# through multiarch): a native arm64 build under qemu-user would take hours.
# On an arm64 host the build is native. The build dependencies are installed
# by apt running outside the chroot with mmdebstrap's configuration, the way
# mmdebstrap installs everything else, so the chroot needs no network setup.
#
# libcamera signs its IPA modules with a key generated during the build and
# checks them against the public key built into libcamera0.7, so
# libcamera0.7 and libcamera-ipa must come from the same build; rootfs.sh
# pins every libcamera package to this repository for that reason. The key
# also makes the packages differ from one build to the next.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_root
require_tools mmdebstrap chroot curl sha256sum
ensure_dirs

LC="${DEVICE_DIR}/libcamera"
SRC="${CACHE}/libcamera"
REPO="${OUT}/libcamera-repo"
CHROOT="${WORK}/libcamera-chroot"
STAGE="${WORK}/libcamera-input"
SUITE="$(lock_get DEBIAN_SUITE)"
MIRROR="$(lock_get DEBIAN_MIRROR)"
SNAPSHOT="$(grep -E '^DEBIAN_SNAPSHOT=' "${DEVICE_DIR}/sources.lock" | cut -d= -f2- || true)"
KEYRING=/usr/share/keyrings/debian-archive-keyring.gpg
[ -f "${KEYRING}" ] || die "install debian-archive-keyring on the build host"
LOCAL_VERSION="$(lock_get LIBCAMERA_LOCAL_VERSION)"
DSC_URL="$(lock_get LIBCAMERA_DSC_URL)"
DSC_SNAPSHOT_URL="$(lock_get LIBCAMERA_DSC_SNAPSHOT_URL)"
DSC_SHA="$(lock_get LIBCAMERA_DSC_SHA256)"
PORT_BASE="$(lock_get PORT_LIBCAMERA_BASE_URL)"
DSC="$(basename "${DSC_URL}")"

# --- Pinned inputs ------------------------------------------------------------
# fetch_one NAME SHA256 URL... : the first URL that yields the pinned file wins.
fetch_one() {
    local name="$1" sha="$2" url
    shift 2
    for url in "$@"; do
        if ( fetch_verified "${url}" "${SRC}/${name}" "${sha}" ); then
            return 0
        fi
        warn "not usable: ${url}"
    done
    die "could not fetch ${name} with SHA-256 ${sha}"
}
mkdir -p "${SRC}/port"
fetch_one "${DSC}" "${DSC_SHA}" "${DSC_URL}" "${DSC_SNAPSHOT_URL}"
# The pinned .dsc pins the tarballs it lists.
TARBALLS=()
while read -r sha _ name; do
    fetch_one "${name}" "${sha}" "$(dirname "${DSC_URL}")/${name}" "$(dirname "${DSC_SNAPSHOT_URL}")/${name}"
    TARBALLS+=("${name}")
done < <(sed -n '/^Checksums-Sha256:/,/^[^ ]/{/^ /p}' "${SRC}/${DSC}")
[ "${#TARBALLS[@]}" -ge 2 ] || die "${DSC} lists no tarballs"
# patches.sha256 (sha256sum format) pins the patches and the tuning files;
# patches.list gives the order of the patches.
while read -r sha name; do
    [ -n "${name}" ] || continue
    fetch_verified "${PORT_BASE}/${name}" "${SRC}/port/${name}" "${sha}"
done < "${LC}/patches.sha256"
while read -r name; do
    [ -n "${name}" ] || continue
    [ -f "${SRC}/port/${name}" ] || die "patch ${name} listed but has no hash in patches.sha256"
done < "${LC}/patches.list"
log "libcamera source package, $(grep -c . "${LC}/patches.list") port patches and the tuning files verified"

# --- Up to date? --------------------------------------------------------------
INPUTS_ID="$({ printf '%s\n' "${DSC_SHA}" "${LOCAL_VERSION}" "${SUITE}" "${SNAPSHOT}"
               cat "${LC}/patches.list" "${LC}/patches.sha256" "${LC}/antumbra-packaging.diff" \
                   "${BASH_SOURCE[0]}" "${BUILD_DIR}/lib/libcamera-chroot.sh"; } | sha256sum | cut -d' ' -f1)"
if [ -f "${REPO}/Packages" ] && [ "$(cat "${REPO}/inputs-id" 2>/dev/null)" = "${INPUTS_ID}" ]; then
    log "local libcamera repository is up to date: ${REPO}"
    exit 0
fi

# --- Build host -> chroot layout -------------------------------------------------
PROFILES="nocheck,nodoc,pkg.libcamera.noqt,pkg.libcamera.nopython,pkg.libcamera.nosdl"
HOSTARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
case "${HOSTARCH}" in
    amd64|x86_64)
        CHROOT_ARCHES=amd64,arm64
        INCLUDE=apt-utils,dpkg-dev,crossbuild-essential-arm64
        PROFILES="cross,${PROFILES}"
        ARCH_OPT=-aarm64
        BUILDDEP_ARCH="-a arm64"
        MODE_DESC="cross build on amd64"
        ;;
    arm64|aarch64)
        CHROOT_ARCHES=arm64
        INCLUDE=apt-utils,dpkg-dev
        ARCH_OPT=
        BUILDDEP_ARCH=
        MODE_DESC="native build"
        ;;
    *) die "unsupported build host architecture ${HOSTARCH} (amd64 or arm64)" ;;
esac

# --- Stage the inputs for the chroot ---------------------------------------------
rm -rf "${STAGE}"
mkdir -p "${STAGE}/patches" "${STAGE}/tuning"
cp "${SRC}/${DSC}" "${STAGE}/"
for t in "${TARBALLS[@]}"; do cp "${SRC}/${t}" "${STAGE}/"; done
cp "${LC}/patches.list" "${LC}/antumbra-packaging.diff" "${BUILD_DIR}/lib/libcamera-chroot.sh" "${STAGE}/"
while read -r name; do
    [ -n "${name}" ] && cp "${SRC}/port/${name}" "${STAGE}/patches/"
done < "${LC}/patches.list"
while read -r _ name; do
    case "${name}" in *.yaml) cp "${SRC}/port/${name}" "${STAGE}/tuning/" ;; esac
done < "${LC}/patches.sha256"
CHANGELOG_DATE="$(date -u -R -d "@${SOURCE_DATE_EPOCH}")"
for v in "${DSC}" "${LOCAL_VERSION}" "${SUITE}" "${CHANGELOG_DATE}" "${PROFILES}"; do
    case "${v}" in *"'"*) die "unexpected quote in build parameter: ${v}" ;; esac
done
cat > "${STAGE}/build.env" <<ENV
DSC='${DSC}'
LOCAL_VERSION='${LOCAL_VERSION}'
SUITE='${SUITE}'
CHANGELOG_DATE='${CHANGELOG_DATE}'
PROFILES='${PROFILES}'
ARCH_OPT='${ARCH_OPT}'
JOBS='$(nproc)'
SOURCE_DATE_EPOCH='${SOURCE_DATE_EPOCH}'
ENV

if [ -n "${SNAPSHOT}" ]; then
    APT_SOURCE="deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/${SNAPSHOT}/ ${SUITE} main"
else
    APT_SOURCE="deb ${MIRROR} ${SUITE} main"
fi

# --- Build --------------------------------------------------------------------------
rm -rf "${CHROOT}" "${REPO}.new"
INNER="env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LC_ALL=C.UTF-8 sh -e /build/input/libcamera-chroot.sh"
log "building libcamera ${LOCAL_VERSION} for arm64 (${MODE_DESC}) in ${CHROOT}"
# shellcheck disable=SC2016  # $1 and $MMDEBSTRAP_APT_CONFIG are expanded by mmdebstrap's hook shell
mmdebstrap \
    --mode=root \
    --variant=buildd \
    --architectures="${CHROOT_ARCHES}" \
    --components=main \
    --keyring="${KEYRING}" \
    --include="${INCLUDE}" \
    --aptopt='Acquire::Languages "none"' \
    --aptopt='APT::Install-Recommends "false"' \
    --dpkgopt='path-exclude=/usr/share/doc/*' \
    --dpkgopt='path-exclude=/usr/share/man/*' \
    --dpkgopt='path-exclude=/usr/share/info/*' \
    --customize-hook='mkdir -p "$1/build/input"' \
    --customize-hook="sync-in ${STAGE} /build/input" \
    --customize-hook="chroot \"\$1\" ${INNER} prepare" \
    --customize-hook="APT_CONFIG=\"\$MMDEBSTRAP_APT_CONFIG\" apt-get --yes ${BUILDDEP_ARCH} -P ${PROFILES} build-dep \"\$1/build/src\"" \
    --customize-hook="chroot \"\$1\" ${INNER} build" \
    --customize-hook="sync-out /build/repo ${REPO}.new" \
    "${SUITE}" "${CHROOT}" "${APT_SOURCE}"

for f in Packages Release; do
    [ -f "${REPO}.new/${f}" ] || die "the build produced no repository (${f} missing)"
done
printf '%s\n' "${INPUTS_ID}" > "${REPO}.new/inputs-id"
rm -rf "${REPO}"
mv "${REPO}.new" "${REPO}"
rm -rf "${CHROOT}" "${STAGE}"
log "local libcamera repository ready: ${REPO} ($(grep -c '^Package: ' "${REPO}/Packages") packages at ${LOCAL_VERSION})"
