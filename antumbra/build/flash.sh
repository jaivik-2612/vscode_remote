#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Guided flashing of an Antumbra release onto a OnePlus 7T Pro (hotdog).
#
# Mirrors the hardware-validated procedure of the hotdog-linux-bringup port:
# bootloader fastboot for vbmeta, dtbo and boot of one slot; fastbootd
# (userspace fastboot) with bounded 128 MiB transfers for userdata; that
# slot made active. The slot is the one Android is not running from (slot B
# when Android runs from A, as in the port's tests): OxygenOS 12 updates
# with Virtual A/B, which keeps Android's system only for its current slot,
# so that slot's boot images are Android's way back.
#
# usage: flash.sh --release DIR [--update | --slot a|b] [--backup [--backup-dir DIR]] [--dry-run] [--yes]
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
[ "${IMAGE_OUTPUT:-sparse}" = "sparse" ] || die "this step is for the phone profile only (ANTUMBRA_DEVICE=${ANTUMBRA_DEVICE} builds a QEMU disk; see docs/vm-testing.md)"
# shellcheck source=../device/oneplus-hotdog/bootimg.conf
source "${DEVICE_DIR}/bootimg.conf"

usage() {
    cat <<USAGE
usage: flash.sh --release DIR [--update | --slot a|b] [--backup [--backup-dir DIR]] [--dry-run] [--yes]

  --release DIR     directory with the release files (output of release.sh, or a download)
                    By default the phone runs Android: Antumbra goes into the other slot.
  --update          the phone runs Antumbra (its slot is the current one): replace it there
  --slot a|b        install into this slot; the current slot only with --update
  --backup          first save boot_b/dtbo_b/vbmeta_b with 'fastboot fetch'; the OnePlus
                    7T Pro's bootloader and stock fastbootd do not support it, so this is
                    for bootloaders that do (INSTALL.md says how to go back without it)
  --backup-dir DIR  where --backup stores them (default: ./antumbra-backup-<date>)
  --dry-run         print the fastboot commands without running them
  --yes             do not ask for confirmation
USAGE
}

REL='' BACKUP='' DO_BACKUP='' DRY='' YES='' WANT_SLOT='' UPDATE=''
while [ $# -gt 0 ]; do
    case "$1" in
        --release) REL="$2"; shift ;;
        --backup-dir) BACKUP="$2"; shift ;;
        --slot) WANT_SLOT="$2"; shift
                [[ "${WANT_SLOT}" =~ ^[ab]$ ]] || die "--slot: a or b" ;;
        --update) UPDATE=1 ;;
        --backup) DO_BACKUP=1 ;;
        --skip-backup) ;;  # the default since fetch proved unsupported on this phone
        --dry-run) DRY=1 ;;
        --yes) YES=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "unknown argument: $1" ;;
    esac
    shift
done
[ -n "${REL}" ] || { usage; die "--release is required"; }
require_tools fastboot sha256sum

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
# An image above 1900 MiB comes in parts (release.sh), joined in name order.
if [ -z "${USERDATA}" ] && first_match "${REL}"/*-userdata.simg.part* >/dev/null; then
    USERDATA="${WORK}/userdata.simg"; mkdir -p "${WORK}"
    log "joining the userdata image's parts"
    cat "${REL}"/*-userdata.simg.part* > "${USERDATA}"
fi
# Releases up to 0.1.0-alpha.1 shipped it zstd-compressed (.simg.zst[.partNNN]).
if [ -z "${USERDATA}" ]; then
    require_tools zstd
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
 This will REPLACE the boot, dtbo and vbmeta images of the slot Android is
 not running from, and the whole userdata partition of the connected
 OnePlus 7T Pro.

 * Everything in userdata is destroyed: Android user data AND any existing
   Antumbra Persistent Storage. Back up first.
 * Android's own slot is not written, but booting Android afterwards will
   format userdata and erase Antumbra.
 * If Antumbra's slot fails to boot, do not count on the bootloader falling
   back to Android's slot: select a slot yourself from fastboot (INSTALL.md).
 * The bootloader must already be unlocked; the unlocked-bootloader warning
   at every boot is expected and cannot be removed.
 * Only the HD1913 (EU) variant has been validated by the mainline port, and
   Antumbra itself has not yet been booted on a phone.
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
    CURRENT="$(getvar current-slot)"; CURRENT="${CURRENT#_}"
    case "${CURRENT}" in
        a) OTHER=b ;;
        b) OTHER=a ;;
        *) die "cannot read the current slot (current-slot=${CURRENT})" ;;
    esac
    # A first install starts from Android: Antumbra goes into the other slot.
    # An update starts from Antumbra, whose slot is then the current one.
    if [ -n "${UPDATE}" ]; then SLOT="${CURRENT}"; else SLOT="${OTHER}"; fi
    if [ -n "${WANT_SLOT}" ]; then
        [ "${WANT_SLOT}" != "${CURRENT}" ] || [ -n "${UPDATE}" ] \
            || die "slot ${CURRENT} is the current one, Android's on a first install: use --update if the phone runs Antumbra"
        SLOT="${WANT_SLOT}"
    fi
    for p in boot_${SLOT}:${BOOT_PARTITION_SIZE} dtbo_${SLOT}:${DTBO_PARTITION_SIZE} vbmeta_${SLOT}:${VBMETA_PARTITION_SIZE} userdata:${USERDATA_PARTITION_SIZE}; do
        name="${p%%:*}"; want="${p##*:}"
        have="$(hex_or_dec "$(getvar "partition-size:${name}")")"
        [ "${have}" -eq "${want}" ] || die "partition ${name} is ${have} bytes on this device, expected ${want} (unsupported variant?)"
    done
    if [ -n "${UPDATE}" ]; then
        log "device checks passed (product ${PRODUCT}, unlocked); updating Antumbra in slot ${SLOT} (current slot ${CURRENT})"
    else
        log "device checks passed (product ${PRODUCT}, unlocked); Android runs from slot ${CURRENT}, Antumbra goes into slot ${SLOT}"
    fi
else
    SLOT="${WANT_SLOT:-${SLOT}}"
    log "dry run: assuming Android runs from the other slot, Antumbra goes into slot ${SLOT}"
fi

# --- fastbootd works, and no OxygenOS update is pending -----------------------------
# Checked before anything is written: userdata can only be flashed from
# fastbootd (recovery's userspace fastboot), and while a Virtual A/B update
# is pending its target is the very slot Antumbra would overwrite.
fastbootd_ready() {
    [ -z "${DRY}" ] || return 0
    sleep 5
    local userspace snapshot
    userspace="$(getvar is-userspace)"
    [ "${userspace}" = "yes" ] || die "fastbootd did not start (is-userspace=${userspace}); a recovery with fastbootd is required in the active slot"
    snapshot="$(getvar snapshot-update-status)"
    case "${snapshot}" in
        snapshotted|merging) die "an OxygenOS update is still being applied (snapshot-update-status=${snapshot}): 'fastboot reboot' to Android, wait until the update has finished, restart Android once, then run this again" ;;
    esac
}
run fastboot reboot fastboot
fastbootd_ready
run fastboot reboot bootloader
[ -n "${DRY}" ] || sleep 5

# --- Backups ----------------------------------------------------------------------------
# The phone's bootloader and stock fastbootd refuse 'fastboot fetch' (the
# hotdog port's docs/release-install.md; AOSP builds fetch only into
# debuggable fastbootd, for vendor_boot). Android's own slot is not written
# (INSTALL.md, "Going back to Android").
if [ -n "${DO_BACKUP}" ]; then
    BACKUP="${BACKUP:-./antumbra-backup-$(date -u +%Y%m%dT%H%M%SZ)}"
    run mkdir -p "${BACKUP}"
    for part in "boot_${SLOT}" "dtbo_${SLOT}" "vbmeta_${SLOT}"; do
        run fastboot fetch "${part}" "${BACKUP}/${part}.img" || die "could not back up ${part}: this bootloader has no 'fetch' (run without --backup)"
    done
    log "slot ${SLOT} backed up to ${BACKUP}; keep it to restore the previous system"
fi

# --- The slot's companions and boot image, from the bootloader ----------------------
run fastboot flash "vbmeta_${SLOT}" "${VBMETA}"
run fastboot flash "dtbo_${SLOT}" "${DTBO}"
run fastboot flash "boot_${SLOT}" "${BOOT}"

# --- userdata from fastbootd ------------------------------------------------------------
run fastboot reboot fastboot
fastbootd_ready
run fastboot -S 128M flash userdata "${USERDATA}"
run fastboot reboot bootloader
if [ -z "${DRY}" ]; then sleep 5; fi
run fastboot set_active "${SLOT}"
run fastboot reboot
log "done. First boot takes longer; the Welcome screen appears when the system is up."
