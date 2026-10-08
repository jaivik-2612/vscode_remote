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
#          with ANTUMBRA_ANDROID=1 only:
#          build/cache/waydroid/<variant>/ Waydroid's system and vendor zips and images
#          build/cache/f-droid/          verified F-Droid APK and signature
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
    local dest="${CACHE}/tor-browser" ver tarball fpr keyurl gnupghome archive sha
    ver="$(lock_get TORBROWSER_VERSION)"
    tarball="${dest}/tor-browser-linux-aarch64-${ver}.tar.xz"
    # dist.torproject.org keeps only the current releases; every release
    # stays on archive.torproject.org. The SHA-256 pin decides either way.
    archive="https://archive.torproject.org/tor-package-archive/torbrowser/${ver}/$(basename "${tarball}")"
    sha="$(lock_get TORBROWSER_SHA256)"
    mkdir -p "${dest}"
    if [ -f "${tarball}" ] && [ "$(sha256sum "${tarball}" | cut -d' ' -f1)" = "${sha}" ]; then
        log "cached: $(basename "${tarball}")"
    else
        fetch_first "${tarball}" "$(lock_get TORBROWSER_URL)" "${archive}"
        sha256_check "${tarball}" "${sha}"
    fi
    [ -f "${tarball}.asc" ] || fetch_first "${tarball}.asc" "$(lock_get TORBROWSER_SIG_URL)" "${archive}.asc"
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

# ---------------------------------------------------------------------------
# mkbootimg / unpack_bootimg (base64 text from googlesource, like avbtool)
# ---------------------------------------------------------------------------
fetch_b64_tool() { # fetch_b64_tool LOCKKEY DEST
    local key="$1" dest="$2" sha
    sha="$(lock_get "${key}_SHA256")"
    if [ -f "${dest}" ] && [ "$(sha256sum "${dest}" | cut -d' ' -f1)" = "${sha}" ]; then
        log "cached: $(basename "${dest}")"; return 0
    fi
    fetch "$(lock_get "${key}_URL")" "${dest}.b64"
    base64 -d "${dest}.b64" > "${dest}.tmp"
    rm -f "${dest}.b64"
    mv "${dest}.tmp" "${dest}"
    sha256_check "${dest}" "${sha}"
    chmod 0755 "${dest}"
}
fetch_bootimg_tools() {
    mkdir -p "${CACHE}/tools/gki"
    fetch_b64_tool MKBOOTIMG "${CACHE}/tools/mkbootimg.py"
    fetch_b64_tool UNPACK_BOOTIMG "${CACHE}/tools/unpack_bootimg.py"
    fetch_b64_tool GKI_CERT "${CACHE}/tools/gki/generate_gki_certificate.py"
    : > "${CACHE}/tools/gki/__init__.py"
    log "mkbootimg tools verified"
}

# ---------------------------------------------------------------------------
# Android apps (ANTUMBRA_ANDROID=1): Waydroid's images and F-Droid
# ---------------------------------------------------------------------------
# Waydroid's system and vendor images for the profile's variant, extracted
# from the pinned zips, so that "waydroid init" finds them preinstalled and
# never downloads anything. Every extracted image is pinned by SHA-256 too
# and checked on every run, cached or not: a cached image changed in place
# (an ext4 image mounted read-write for a look changes without changing
# size) is extracted again. Writes images.sha256 for the build hook, which
# checks the copies in the root filesystem against it.
fetch_waydroid() {
    local variant="${WAYDROID_IMAGE_VARIANT}" key dest kind img zip entries want_crc got sha pinned
    key="WAYDROID_$(printf '%s' "${variant}" | tr '[:lower:]' '[:upper:]')"
    dest="${CACHE}/waydroid/${variant}"
    require_tools unzip
    mkdir -p "${dest}"
    : > "${dest}/images.sha256.new"
    for kind in SYSTEM VENDOR; do
        img="$(printf '%s' "${kind}" | tr '[:upper:]' '[:lower:]').img"
        zip="${dest}/${img%.img}.zip"
        fetch_verified "$(lock_get "${key}_${kind}_URL")" "${zip}" "$(lock_get "${key}_${kind}_SHA256")"
        [ "$(stat -c %s "${zip}")" -eq "$(lock_get "${key}_${kind}_SIZE")" ] || die "${zip} has an unexpected size"
        # The zip holds exactly this image, with the size and CRC-32 pinned
        # for it; unzip checks the CRC-32 again while extracting.
        entries="$(unzip -Z1 "${zip}")" || die "${zip}: unreadable zip"
        [ "${entries}" = "${img}" ] || die "${zip}: expected only ${img}, found: ${entries}"
        want_crc="$(lock_get "${key}_${kind}_IMG_CRC32")"
        got="$(unzip -lv "${zip}" | awk -v n="${img}" '$NF == n {print $1, $7}')"
        [ "${got}" = "$(lock_get "${key}_${kind}_IMG_SIZE") ${want_crc}" ] || die "${zip}: ${img} is not the pinned image (size and CRC-32: ${got})"
        pinned="$(lock_get "${key}_${kind}_IMG_SHA256")"
        sha=""
        if [ -f "${dest}/${img}" ] && [ "$(cat "${dest}/${img}.from" 2>/dev/null)" = "$(lock_get "${key}_${kind}_SHA256")" ] \
           && [ "$(stat -c %s "${dest}/${img}")" -eq "$(lock_get "${key}_${kind}_IMG_SIZE")" ]; then
            sha="$(sha256sum "${dest}/${img}" | cut -d' ' -f1)"
            if [ "${sha}" = "${pinned}" ]; then
                log "cached: ${variant}/${img}"
            else
                warn "${variant}/${img}: the cached image changed (SHA-256 ${sha}); extracting it again"
                sha=""
            fi
        fi
        if [ -z "${sha}" ]; then
            rm -rf "${dest:?}/${img}" "${dest}/${img}.from" "${dest}/extract"
            unzip -q -o "${zip}" "${img}" -d "${dest}/extract" || die "${zip}: extraction failed (CRC error?)"
            mv "${dest}/extract/${img}" "${dest}/${img}"
            rmdir "${dest}/extract"
            sha="$(sha256sum "${dest}/${img}" | cut -d' ' -f1)"
            [ "${sha}" = "${pinned}" ] || die "${variant}/${img}: SHA-256 ${sha}, pinned ${pinned}"
            lock_get "${key}_${kind}_SHA256" > "${dest}/${img}.from"
        fi
        printf '%s  %s\n' "${sha}" "${img}" >> "${dest}/images.sha256.new"
    done
    mv "${dest}/images.sha256.new" "${dest}/images.sha256"
    log "Waydroid ${variant} images verified (zip SHA-256 and size, image size, CRC-32 and SHA-256)"
}

# F-Droid: pinned by SHA-256, F-Droid's OpenPGP signature over it, and the
# certificate in the APK's own signature block (what Android checks updates
# against).
fetch_fdroid() {
    local dest="${CACHE}/f-droid" apk sig fpr gnupghome sigs cert
    require_tools gpg gpgv unzip openssl
    apk="${dest}/F-Droid.apk"
    # The signature is cached under its own (versioned) name, so that a new
    # APK pin never meets the previous version's signature.
    sig="${dest}/$(basename "$(lock_get FDROID_SIG_URL)")"
    mkdir -p "${dest}"
    fetch_verified "$(lock_get FDROID_APK_URL)" "${apk}" "$(lock_get FDROID_APK_SHA256)"
    [ "$(stat -c %s "${apk}")" -eq "$(lock_get FDROID_APK_SIZE)" ] || die "F-Droid.apk has an unexpected size"
    [ -f "${sig}" ] || fetch "$(lock_get FDROID_SIG_URL)" "${sig}"
    fpr="$(lock_get FDROID_SIGNING_KEY_FPR)"
    if [ -f "${DEVICE_DIR}/keys/f-droid.asc" ]; then
        cp "${DEVICE_DIR}/keys/f-droid.asc" "${dest}/signing-key.asc"
    elif [ ! -f "${dest}/signing-key.asc" ]; then
        fetch "$(lock_get FDROID_SIGNING_KEY_URL)" "${dest}/signing-key.asc"
    fi
    gnupghome="$(mktemp -d)"
    chmod 0700 "${gnupghome}"
    GNUPGHOME="${gnupghome}" gpg -q --batch --import "${dest}/signing-key.asc" 2>/dev/null
    GNUPGHOME="${gnupghome}" gpg --batch --with-colons --fingerprint 2>/dev/null \
        | grep -q "^fpr:::::::::${fpr}:" || die "F-Droid signing key fingerprint mismatch (expected ${fpr})"
    GNUPGHOME="${gnupghome}" gpg -q --batch --export "${fpr}" > "${dest}/f-droid.keyring"
    gpgv --keyring "${dest}/f-droid.keyring" "${sig}" "${apk}" 2>/dev/null || die "F-Droid signature verification failed"
    rm -rf "${gnupghome}"
    sigs="$(unzip -Z1 "${apk}" | grep -E '^META-INF/[^/]+\.(RSA|DSA|EC)$' || true)"
    if [ -z "${sigs}" ] || [ "$(printf '%s\n' "${sigs}" | wc -l)" -ne 1 ]; then
        die "F-Droid.apk: expected one signature block, found: ${sigs:-none}"
    fi
    cert="$(unzip -p "${apk}" "${sigs}" | openssl pkcs7 -inform DER -print_certs | openssl x509 -outform DER | sha256sum | cut -d' ' -f1)" \
        || die "F-Droid.apk: cannot read the signing certificate"
    [ "${cert}" = "$(lock_get FDROID_APK_CERT_SHA256)" ] || die "F-Droid.apk is signed by an unexpected certificate (SHA-256 ${cert})"
    log "F-Droid: SHA-256, OpenPGP signature and signing certificate verified"
}

[ -n "${SKIP_KERNEL}" ] || fetch_kernel
fetch_port_patches
fetch_avbtool
fetch_bootimg_tools
fetch_device_assets
[ -n "${SKIP_TB}" ] || fetch_tor_browser
if [ -n "${ANTUMBRA_ANDROID}" ]; then
    fetch_waydroid
    fetch_fdroid
fi
log "all pinned inputs present in ${CACHE}"
