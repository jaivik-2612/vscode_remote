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
CACHE="${ANTUMBRA_CACHE:-${BUILD_DIR}/cache}"   # downloaded, pinned inputs
OUT="${ANTUMBRA_OUT:-${BUILD_DIR}/out}"         # build products
WORK="${ANTUMBRA_WORK:-${BUILD_DIR}/work}"      # scratch space
DEVICE_DIR="${ANTUMBRA_ROOT}/device/oneplus-hotdog"
CONFIG_DIR="${ANTUMBRA_ROOT}/config"
VENDOR_DIR="${ANTUMBRA_ROOT}/vendor"

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

# Build knobs (documented in docs/building.md). Empty means off.
ANTUMBRA_DEBUG="${ANTUMBRA_DEBUG:-}"        # debug initramfs and console; never for releases
ANTUMBRA_MINIMAL="${ANTUMBRA_MINIMAL:-}"    # small root filesystem for pipeline validation
ANTUMBRA_VERITY="${ANTUMBRA_VERITY:-}"      # dm-verity on the root filesystem (experimental)
ANTUMBRA_FIRMWARE_DIR="${ANTUMBRA_FIRMWARE_DIR:-}"  # builder-provided firmware tree

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

# lock_get KEY : read a value from device/oneplus-hotdog/sources.lock
# (format: KEY=VALUE, one per line, '#' comments).
lock_get() {
    local key="$1" lock="${DEVICE_DIR}/sources.lock" value
    value="$(grep -E "^${key}=" "${lock}" | head -n1 | cut -d= -f2-)"
    [ -n "${value}" ] || die "missing ${key} in ${lock}"
    printf '%s\n' "${value}"
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
