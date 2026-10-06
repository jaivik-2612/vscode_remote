#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Antumbra build library: sourced by every script in build/.
#
# Provides logging, failure handling, tool checks and the directory layout.
# Scripts that source it must run under `set -euo pipefail`.

# shellcheck disable=SC2034  # variables are consumed by the sourcing scripts

if [ -n "${ANTUMBRA_COMMON_LOADED:-}" ]; then
    return 0
fi
ANTUMBRA_COMMON_LOADED=1

# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------
# ANTUMBRA_ROOT is the antumbra/ directory of the repository.
ANTUMBRA_ROOT="${ANTUMBRA_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
BUILD_DIR="${ANTUMBRA_ROOT}/build"
CACHE="${ANTUMBRA_CACHE:-${BUILD_DIR}/cache}"   # downloaded, pinned inputs (shared by all profiles)
CONFIG_DIR="${ANTUMBRA_ROOT}/config"
VENDOR_DIR="${ANTUMBRA_ROOT}/vendor"

# Device profile. ANTUMBRA_DEVICE selects device/<name>/ (default: the phone).
# A profile's device.conf may name a BASE_DEVICE whose sources.lock, kernel
# patches, hardening fragment, keys and firmware list it reuses; DEVICE_DIR is
# that base and PROFILE_DIR the selected profile (both equal for the phone).
# Profiles other than the default build into build/out/<name> and
# build/work/<name>, so the phone's outputs are never touched by a VM build.
ANTUMBRA_DEVICE="${ANTUMBRA_DEVICE:-oneplus-hotdog}"
PROFILE_DIR="${ANTUMBRA_ROOT}/device/${ANTUMBRA_DEVICE}"
if [ ! -f "${PROFILE_DIR}/device.conf" ]; then
    printf '[%s] error: unknown device profile %s (no %s)\n' "$(basename "${0}")" "${ANTUMBRA_DEVICE}" "${PROFILE_DIR}/device.conf" >&2
    exit 1
fi
# shellcheck source=../../device/oneplus-hotdog/device.conf
source "${PROFILE_DIR}/device.conf"
DEVICE_DIR="${ANTUMBRA_ROOT}/device/${BASE_DEVICE:-${ANTUMBRA_DEVICE}}"
if [ "${ANTUMBRA_DEVICE}" = "oneplus-hotdog" ]; then
    _antumbra_profile_suffix=""
else
    _antumbra_profile_suffix="/${ANTUMBRA_DEVICE}"
fi
# The suffix applies to ANTUMBRA_OUT/ANTUMBRA_WORK overrides too, so a VM build
# can never write into the phone's directories.
OUT="${ANTUMBRA_OUT:-${BUILD_DIR}/out}${_antumbra_profile_suffix}"    # build products
WORK="${ANTUMBRA_WORK:-${BUILD_DIR}/work}${_antumbra_profile_suffix}" # scratch space

# ---------------------------------------------------------------------------
# Version and reproducibility
# ---------------------------------------------------------------------------
ANTUMBRA_VERSION="${ANTUMBRA_VERSION:-$(tr -d '[:space:]' < "${ANTUMBRA_ROOT}/VERSION")}"

if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
    if git -C "${ANTUMBRA_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        SOURCE_DATE_EPOCH="$(git -C "${ANTUMBRA_ROOT}" log -1 --format=%ct)"
    else
        SOURCE_DATE_EPOCH="$(date -u +%s)"
    fi
fi
export SOURCE_DATE_EPOCH

# Build knobs (documented in docs/building.md). Empty means off, except for
# ANTUMBRA_VERITY.
ANTUMBRA_DEBUG="${ANTUMBRA_DEBUG:-}"        # debug initramfs and console; never for releases
ANTUMBRA_MINIMAL="${ANTUMBRA_MINIMAL:-}"    # small root filesystem for pipeline validation
# dm-verity on the root filesystem: on unless ANTUMBRA_VERITY=0 (squashfs.sh,
# bootimg.sh, vm.sh and vm-bundle.sh read it as ${ANTUMBRA_VERITY:-1}).
ANTUMBRA_VERITY="${ANTUMBRA_VERITY:-}"
ANTUMBRA_FIRMWARE_DIR="${ANTUMBRA_FIRMWARE_DIR:-}"  # builder-provided firmware tree
# Android apps (Waydroid, docs/architecture.md "Android apps"): 1 adds the
# Waydroid packages, the pinned Android images and F-Droid, and the Android
# build hook; the user still turns Android on per session at the Welcome
# screen. Unset (or 0) builds an image without any of it.
ANTUMBRA_ANDROID="${ANTUMBRA_ANDROID:-}"
case "${ANTUMBRA_ANDROID}" in
    1) ;;
    ''|0) ANTUMBRA_ANDROID="" ;;
    *) printf '[%s] error: ANTUMBRA_ANDROID must be 1, 0 or empty\n' "$(basename "${0}")" >&2; exit 1 ;;
esac
# Which Waydroid image build the profile uses (device.conf): arm64 carries
# the 32-bit ABI too; arm64_only runs without AArch32 (KVM or HVF hosts).
WAYDROID_IMAGE_VARIANT="${WAYDROID_IMAGE_VARIANT:-arm64}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
_antumbra_script_name="$(basename "${0}")"

log()  { printf '[%s] %s\n' "${_antumbra_script_name}" "$*" >&2; }
warn() { printf '[%s] warning: %s\n' "${_antumbra_script_name}" "$*" >&2; }
die()  { printf '[%s] error: %s\n' "${_antumbra_script_name}" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# require_tools NAME... : fail with a clear message if a tool is missing.
require_tools() {
    local missing=() tool
    for tool in "$@"; do
        command -v "${tool}" >/dev/null 2>&1 || missing+=("${tool}")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        die "missing tools: ${missing[*]} (see docs/building.md)"
    fi
}

# require_root : most image steps need real root (loop devices, chroots).
require_root() {
    [ "$(id -u)" -eq 0 ] || die "this step must run as root"
}

# ensure_dirs : create the layout directories.
ensure_dirs() {
    mkdir -p "${CACHE}" "${OUT}" "${WORK}"
}

# sha256_check FILE EXPECTED : verify a file's SHA-256.
sha256_check() {
    local file="$1" expected="$2" actual
    actual="$(sha256sum "${file}" | cut -d' ' -f1)"
    [ "${actual}" = "${expected}" ] || die "SHA-256 mismatch for ${file}: got ${actual}, expected ${expected}"
}

# lock_get KEY : read a value from the base device's sources.lock
# (format: KEY=VALUE, one per line, '#' comments).
lock_get() {
    local key="$1" lock="${DEVICE_DIR}/sources.lock" value
    value="$(grep -E "^${key}=" "${lock}" | head -n1 | cut -d= -f2-)"
    [ -n "${value}" ] || die "missing ${key} in ${lock}"
    printf '%s\n' "${value}"
}

# Build stamps. kernel.sh writes OUT/kernel/profile, rootfs.sh writes
# OUT/rootfs/build-flags; later steps refuse inputs built for another profile.
stamp_value() { # stamp_value FILE KEY
    sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n1
}
require_profile_stamps() { # require_profile_stamps [kernel] [rootfs]
    local what f dev
    for what in "$@"; do
        case "${what}" in
            kernel) f="${OUT}/kernel/profile" ;;
            rootfs) f="${OUT}/rootfs/build-flags" ;;
            *) die "require_profile_stamps: unknown stamp ${what}" ;;
        esac
        [ -f "${f}" ] || die "${f} missing: rebuild the ${what} step for ANTUMBRA_DEVICE=${ANTUMBRA_DEVICE}"
        dev="$(stamp_value "${f}" ANTUMBRA_DEVICE)"
        [ "${dev}" = "${ANTUMBRA_DEVICE}" ] || die "${f} was built for ${dev:-an unknown profile}, not ${ANTUMBRA_DEVICE}"
    done
}

# fetch URL DEST : download with curl, atomically, following redirects.
fetch() {
    local url="$1" dest="$2"
    require_tools curl
    mkdir -p "$(dirname "${dest}")"
    curl -fsSL --retry 3 --retry-delay 2 -o "${dest}.part" "${url}" || die "download failed: ${url}"
    mv "${dest}.part" "${dest}"
}

# fetch_verified URL DEST SHA256 : download unless the verified file exists.
fetch_verified() {
    local url="$1" dest="$2" sha="$3"
    if [ -f "${dest}" ] && [ "$(sha256sum "${dest}" | cut -d' ' -f1)" = "${sha}" ]; then
        log "cached: $(basename "${dest}")"
        return 0
    fi
    fetch "${url}" "${dest}"
    sha256_check "${dest}" "${sha}"
}
