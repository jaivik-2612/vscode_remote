#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Fetch and verify every pinned external input of the build (idempotent).
#
# Inputs : device/oneplus-hotdog/sources.lock, kernel/patches.list,
#          kernel/port-patches.sha256
# Outputs: build/cache/kernel            the sm8150-mainline tree at the pinned commit
#          build/cache/hotdog-patches/   the port's patches and kernel config
#          build/cache/tools/avbtool.py
#          build/cache/device-assets/    dtbo.img, vbmeta-disabled.img from the port's release
#          build/cache/tor-browser/      verified Tor Browser tarball and signature
#
# Proprietary device firmware is deliberately NOT fetched here; see
# fetch-firmware.sh and docs/legal.md.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
    cat <<USAGE
usage: fetch-sources.sh [--skip-kernel] [--skip-tor-browser]

Downloads and verifies the pinned inputs listed in
device/oneplus-hotdog/sources.lock into build/cache/.
USAGE
}

SKIP_KERNEL=''
SKIP_TB=''
for arg in "$@"; do
    case "${arg}" in
        --skip-kernel) SKIP_KERNEL=1 ;;
        --skip-tor-browser) SKIP_TB=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "unknown argument: ${arg}" ;;
    esac
done

require_tools curl git sha256sum python3 base64
ensure_dirs

# ---------------------------------------------------------------------------
# Kernel tree
# ---------------------------------------------------------------------------
fetch_kernel() {
    local ksrc="${CACHE}/kernel" url tag commit got
    url="$(lock_get KERNEL_GIT_URL)"
    tag="$(lock_get KERNEL_GIT_TAG)"
    commit="$(lock_get KERNEL_GIT_COMMIT)"
    if [ -d "${ksrc}/.git" ] && git -C "${ksrc}" cat-file -e "${commit}^{commit}" 2>/dev/null; then
        log "kernel tree already at ${commit}"
    else
        log "fetching kernel ${tag} from ${url} (shallow)"
        mkdir -p "${ksrc}"
        [ -d "${ksrc}/.git" ] || git -C "${ksrc}" init -q
        git -C "${ksrc}" remote get-url origin >/dev/null 2>&1 || git -C "${ksrc}" remote add origin "${url}"
        git -C "${ksrc}" fetch --depth 1 origin "refs/tags/${tag}:refs/tags/${tag}"
        got="$(git -C "${ksrc}" rev-parse "refs/tags/${tag}^{commit}")"
        [ "${got}" = "${commit}" ] || die "tag ${tag} resolves to ${got}, expected ${commit}"
    fi
    git -C "${ksrc}" checkout -q --detach "${commit}"
    log "kernel tree ready: $(git -C "${ksrc}" log -1 --format='%h %s')"
}

# ---------------------------------------------------------------------------
# The port's patches and kernel configuration
# ---------------------------------------------------------------------------
fetch_port_patches() {
    local base dest name sha
    base="$(lock_get PORT_PATCH_BASE_URL)"
    dest="${CACHE}/hotdog-patches"
    mkdir -p "${dest}"
    # port-patches.sha256 is in sha256sum format: "<sha>  <name>"
    while read -r sha name; do
        [ -n "${name}" ] || continue
        fetch_verified "${base}/${name}" "${dest}/${name}" "${sha}"
    done < "${DEVICE_DIR}/kernel/port-patches.sha256"
    # every patch in patches.list must have been verified
    while read -r name; do
        [ -n "${name}" ] || continue
        [ -f "${dest}/${name}" ] || die "patch ${name} listed but has no hash in port-patches.sha256"
    done < "${DEVICE_DIR}/kernel/patches.list"
    log "port patches and config verified ($(wc -l < "${DEVICE_DIR}/kernel/patches.list") patches)"
}

# ---------------------------------------------------------------------------
# avbtool (text served base64-encoded by googlesource)
# ---------------------------------------------------------------------------
fetch_avbtool() {
    local dest="${CACHE}/tools/avbtool.py" sha
    sha="$(lock_get AVBTOOL_SHA256)"
    if [ -f "${dest}" ] && [ "$(sha256sum "${dest}" | cut -d' ' -f1)" = "${sha}" ]; then
        log "cached: avbtool.py"; return 0
    fi
    fetch "$(lock_get AVBTOOL_URL)" "${dest}.b64"
    base64 -d "${dest}.b64" > "${dest}.tmp"
    rm -f "${dest}.b64"
    mv "${dest}.tmp" "${dest}"
    sha256_check "${dest}" "${sha}"
    chmod 0755 "${dest}"
    log "avbtool $(python3 "${dest}" version 2>/dev/null || echo '?')"
}

# ---------------------------------------------------------------------------
# Hardware-validated slot-B companions from the port's release
# ---------------------------------------------------------------------------
fetch_device_assets() {
    local dest="${CACHE}/device-assets"
    mkdir -p "${dest}"
    fetch_verified "$(lock_get DTBO_URL)" "${dest}/dtbo.img" "$(lock_get DTBO_SHA256)"
    [ "$(stat -c %s "${dest}/dtbo.img")" -eq "$(lock_get DTBO_SIZE)" ] || die "dtbo.img has an unexpected size"
    fetch_verified "$(lock_get VBMETA_URL)" "${dest}/vbmeta-disabled.img" "$(lock_get VBMETA_SHA256)"
    [ "$(stat -c %s "${dest}/vbmeta-disabled.img")" -eq "$(lock_get VBMETA_SIZE)" ] || die "vbmeta-disabled.img has an unexpected size"
    log "device assets verified"
}

# ---------------------------------------------------------------------------
# Tor Browser (alpha channel: the only Linux aarch64 build)
# ---------------------------------------------------------------------------
fetch_tor_browser() {
    local dest="${CACHE}/tor-browser" ver tarball fpr keyurl gnupghome
    ver="$(lock_get TORBROWSER_VERSION)"
    tarball="${dest}/tor-browser-linux-aarch64-${ver}.tar.xz"
    mkdir -p "${dest}"
    fetch_verified "$(lock_get TORBROWSER_URL)" "${tarball}" "$(lock_get TORBROWSER_SHA256)"
    [ -f "${tarball}.asc" ] || fetch "$(lock_get TORBROWSER_SIG_URL)" "${tarball}.asc"
    printf '%s\n' "${ver}" > "${dest}/version"

    # OpenPGP verification against the Tor Browser Developers signing key.
    if command -v gpg >/dev/null 2>&1 && command -v gpgv >/dev/null 2>&1; then
        fpr="$(lock_get TORBROWSER_SIGNING_KEY_FPR)"
        keyurl="$(lock_get TORBROWSER_SIGNING_KEY_URL)"
        # The signing key is vendored (device/oneplus-hotdog/keys/); the URL is
        # only a fallback so the verification does not depend on a keyserver.
        if [ -f "${DEVICE_DIR}/keys/tor-browser-developers.asc" ]; then
            cp "${DEVICE_DIR}/keys/tor-browser-developers.asc" "${dest}/signing-key.asc"
        elif [ ! -f "${dest}/signing-key.asc" ]; then
            fetch "${keyurl}" "${dest}/signing-key.asc"
        fi
        gnupghome="$(mktemp -d)"
        chmod 0700 "${gnupghome}"
        GNUPGHOME="${gnupghome}" gpg -q --batch --import "${dest}/signing-key.asc" 2>/dev/null
        GNUPGHOME="${gnupghome}" gpg --batch --with-colons --fingerprint 2>/dev/null \
            | grep -q "^fpr:::::::::${fpr}:" || die "signing key fingerprint mismatch (expected ${fpr})"
        GNUPGHOME="${gnupghome}" gpg -q --batch --export "${fpr}" > "${dest}/tor-browser.keyring"
        gpgv --keyring "${dest}/tor-browser.keyring" "${tarball}.asc" "${tarball}" 2>/dev/null \
            || die "Tor Browser signature verification failed"
        rm -rf "${gnupghome}"
        log "Tor Browser ${ver}: SHA-256 and OpenPGP signature verified"
    else
        warn "gpg/gpgv not installed: Tor Browser verified by SHA-256 only"
    fi
}

[ -n "${SKIP_KERNEL}" ] || fetch_kernel
fetch_port_patches
fetch_avbtool
fetch_device_assets
[ -n "${SKIP_TB}" ] || fetch_tor_browser
log "all pinned inputs present in ${CACHE}"
