#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Guided flashing of an Antumbra release onto a OnePlus 7T Pro (hotdog).
#
# Mirrors the hardware-validated procedure of the hotdog-linux-bringup port:
# bootloader fastboot for vbmeta_b, dtbo_b and boot_b; fastbootd (userspace
# fastboot) with bounded 128 MiB transfers for userdata; slot B made active.
#
# usage: flash.sh --release DIR [--backup-dir DIR] [--skip-backup] [--dry-run] [--yes]
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
[ "${IMAGE_OUTPUT:-sparse}" = "sparse" ] || die "this step is for the phone profile only (ANTUMBRA_DEVICE=${ANTUMBRA_DEVICE} builds a QEMU disk; see docs/vm-testing.md)"
# shellcheck source=../device/oneplus-hotdog/bootimg.conf
source "${DEVICE_DIR}/bootimg.conf"

usage() {
    cat <<USAGE
usage: flash.sh --release DIR [--backup-dir DIR] [--skip-backup] [--dry-run] [--yes]

  --release DIR     directory with the release files (output of release.sh, or a download)
  --backup-dir DIR  where to store the current boot_b/dtbo_b/vbmeta_b (default: ./antumbra-backup-<date>)
  --skip-backup     do not back up slot B (only if you already have backups)
  --dry-run         print the fastboot commands without running them
  --yes             do not ask for confirmation
USAGE
}

REL='' BACKUP='' SKIP_BACKUP='' DRY='' YES=''
while [ $# -gt 0 ]; do
    case "$1" in
        --release) REL="$2"; shift ;;
        --backup-dir) BACKUP="$2"; shift ;;
        --skip-backup) SKIP_BACKUP=1 ;;
        --dry-run) DRY=1 ;;
        --yes) YES=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "unknown argument: $1" ;;
    esac
    shift
done
[ -n "${REL}" ] || { usage; die "--release is required"; }
require_tools fastboot zstd sha256sum

run() {
    if [ -n "${DRY}" ]; then printf '[dry-run] %s\n' "$*"; else log "+ $*"; "$@"; fi
}
getvar() {
    # fastboot prints "name: value" on stderr
    fastboot getvar "$1" 2>&1 | sed -n "s/^$1: *//p" | head -n1 | tr -d '\r'
}
hex_or_dec() {
    local v="$1"
    case "${v}" in 0x*|0X*) printf '%d\n' "${v}" ;; *) printf '%d\n' "${v}" ;; esac
}

# --- Locate release files ------------------------------------------------------------
first_match() { # first_match GLOB... : print the first existing path, if any
    local f
    for f in "$@"; do [ -e "${f}" ] && { printf '%s\n' "${f}"; return 0; }; done
    return 1
}
BOOT="$(first_match "${REL}"/*-boot.img || true)"
DTBO="$(first_match "${REL}"/*-dtbo.img || true)"
VBMETA="$(first_match "${REL}"/*-vbmeta-disabled.img || true)"
if [ -z "${BOOT}" ] || [ -z "${DTBO}" ] || [ -z "${VBMETA}" ]; then
    die "release directory lacks boot/dtbo/vbmeta images"
fi
if [ -f "${REL}/SHA256SUMS" ]; then
    ( cd "${REL}" && sha256sum --quiet -c SHA256SUMS ) || die "release files do not match SHA256SUMS"
    log "release hashes verified"
fi
USERDATA="$(first_match "${REL}"/*-userdata.simg || true)"
if [ -z "${USERDATA}" ]; then
    ZST="$(first_match "${REL}"/*-userdata.simg.zst || true)"
    if [ -z "${ZST}" ] && first_match "${REL}"/*-userdata.simg.zst.part* >/dev/null; then
        ZST="${WORK}/userdata.simg.zst"; mkdir -p "${WORK}"
        cat "${REL}"/*-userdata.simg.zst.part* > "${ZST}"
    fi
    [ -n "${ZST}" ] || die "no userdata image in ${REL}"
    USERDATA="${WORK}/userdata.simg"; mkdir -p "${WORK}"
    log "decompressing userdata image"
    zstd -q -d -f "${ZST}" -o "${USERDATA}"
fi
[ "$(stat -c %s "${BOOT}")" -eq "${BOOT_PARTITION_SIZE}" ] || die "boot image is not ${BOOT_PARTITION_SIZE} bytes"
[ "$(stat -c %s "${DTBO}")" -eq "${DTBO_PARTITION_SIZE}" ] || die "dtbo image is not ${DTBO_PARTITION_SIZE} bytes"
[ "$(stat -c %s "${VBMETA}")" -eq "${VBMETA_PARTITION_SIZE}" ] || die "vbmeta image is not ${VBMETA_PARTITION_SIZE} bytes"

cat <<WARNING

================================================================================
 This will REPLACE the contents of boot_b, dtbo_b, vbmeta_b and the whole
 userdata partition of the connected OnePlus 7T Pro.

 * Everything in userdata is destroyed: Android user data AND any existing
   Antumbra Persistent Storage. Back up first.
 * Slot A keeps its Android boot and recovery, but booting the Android system
   in slot A afterwards will format userdata and erase Antumbra.
 * The bootloader must already be unlocked; the "Orange state" warning at
   boot is expected and cannot be removed.
 * Only the HD1913 (EU) variant has been validated by the mainline port.
================================================================================

WARNING
if [ -z "${YES}" ] && [ -z "${DRY}" ]; then
    read -r -p "Type FLASH to continue: " answer
    [ "${answer}" = "FLASH" ] || die "aborted"
fi

# --- Device checks (bootloader fastboot) -------------------------------------------
if [ -z "${DRY}" ]; then
    COUNT="$(fastboot devices 2>/dev/null | grep -c . || true)"
    [ "${COUNT}" -eq 1 ] || die "expected exactly one device in fastboot mode, found ${COUNT} (boot with Power+Vol-+Vol+ or 'adb reboot bootloader')"
    PRODUCT="$(getvar product)"
    [ "${PRODUCT}" = "${FASTBOOT_PRODUCT}" ] || die "product is '${PRODUCT}', expected ${FASTBOOT_PRODUCT}"
    UNLOCKED="$(getvar unlocked)"
    [ "${UNLOCKED}" = "yes" ] || die "bootloader is not unlocked (unlocked=${UNLOCKED})"
    for p in boot_${SLOT}:${BOOT_PARTITION_SIZE} dtbo_${SLOT}:${DTBO_PARTITION_SIZE} vbmeta_${SLOT}:${VBMETA_PARTITION_SIZE} userdata:${USERDATA_PARTITION_SIZE}; do
        name="${p%%:*}"; want="${p##*:}"
        have="$(hex_or_dec "$(getvar "partition-size:${name}")")"
        [ "${have}" -eq "${want}" ] || die "partition ${name} is ${have} bytes on this device, expected ${want} (unsupported variant?)"
    done
    log "device checks passed (product ${PRODUCT}, unlocked, current slot $(getvar current-slot))"
fi

# --- Backups ----------------------------------------------------------------------------
if [ -z "${SKIP_BACKUP}" ]; then
    BACKUP="${BACKUP:-./antumbra-backup-$(date -u +%Y%m%dT%H%M%SZ)}"
    run mkdir -p "${BACKUP}"
    for part in "boot_${SLOT}" "dtbo_${SLOT}" "vbmeta_${SLOT}"; do
        run fastboot fetch "${part}" "${BACKUP}/${part}.img" || die "could not back up ${part} (bootloader without 'fetch'? use adb/dd from a recovery, then --skip-backup)"
    done
    log "slot ${SLOT} backed up to ${BACKUP}; keep it to restore the previous system"
fi

# --- Flash slot B companions and boot image from the bootloader ---------------------
run fastboot flash "vbmeta_${SLOT}" "${VBMETA}"
run fastboot flash "dtbo_${SLOT}" "${DTBO}"
run fastboot flash "boot_${SLOT}" "${BOOT}"

# --- userdata from fastbootd ------------------------------------------------------------
run fastboot reboot fastboot
if [ -z "${DRY}" ]; then
    sleep 5
    USERSPACE="$(getvar is-userspace)"
    [ "${USERSPACE}" = "yes" ] || die "fastbootd did not start (is-userspace=${USERSPACE}); a compatible recovery is required in the active slot"
fi
run fastboot -S 128M flash userdata "${USERDATA}"
run fastboot reboot bootloader
if [ -z "${DRY}" ]; then sleep 5; fi
run fastboot set_active "${SLOT}"
run fastboot reboot
log "done. First boot takes longer; the Welcome screen appears when the system is up."
