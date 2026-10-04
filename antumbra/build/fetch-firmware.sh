#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Assemble the proprietary device firmware tree for the builder's OWN device.
#
# Antumbra never redistributes this firmware (docs/legal.md). This script
# fetches the community mirror the hotdog port uses, at a pinned commit, and
# verifies every file against device/oneplus-hotdog/firmware/firmware-files.sha256,
# then lays the files out as /lib/firmware expects. The result is used by
# rootfs.sh only when ANTUMBRA_FIRMWARE_DIR points at it.
#
# Output: build/cache/firmware/   (print its path for ANTUMBRA_FIRMWARE_DIR)
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

if [ "${ANTUMBRA_ACCEPT_PROPRIETARY_FIRMWARE:-}" != "1" ]; then
    cat >&2 <<NOTICE
This fetches proprietary firmware (GPU, Wi-Fi, Bluetooth, DSP, modem, video)
owned by Qualcomm and OnePlus, from a community mirror without a licence.
It may be used on the device it was extracted for; it must not be
redistributed. Read docs/legal.md, then re-run with
    ANTUMBRA_ACCEPT_PROPRIETARY_FIRMWARE=1
NOTICE
    exit 2
fi

require_tools git sha256sum
ensure_dirs

REPO="${CACHE}/firmware-src/repo"
COMMIT="$(lock_get FIRMWARE_GIT_COMMIT)"
URL="$(lock_get FIRMWARE_GIT_URL)"
if [ -d "${REPO}/.git" ] && [ "$(git -C "${REPO}" rev-parse HEAD 2>/dev/null)" = "${COMMIT}" ]; then
    log "firmware mirror already at ${COMMIT}"
else
    rm -rf "${REPO}"; mkdir -p "${REPO}"
    git -C "${REPO}" init -q
    git -C "${REPO}" remote add origin "${URL}"
    git -C "${REPO}" fetch -q --depth 1 origin "${COMMIT}"
    git -C "${REPO}" checkout -q FETCH_HEAD
    [ "$(git -C "${REPO}" rev-parse HEAD)" = "${COMMIT}" ] || die "firmware mirror did not check out ${COMMIT}"
fi
( cd "${REPO}" && sha256sum --quiet -c "${DEVICE_DIR}/firmware/firmware-files.sha256" ) || die "firmware file hashes do not match the pinned list"

FW="${CACHE}/firmware"
rm -rf "${FW}"
HOTDOG="${FW}/qcom/sm8150/oneplus/hotdog"
install -D -m 0644 "${REPO}/a630_sqe.fw"   "${FW}/qcom/a630_sqe.fw"
install -D -m 0644 "${REPO}/a640_gmu.bin"  "${FW}/qcom/a640_gmu.bin"
for f in a640_zap.mbn adsp.mbn cdsp.mbn modem.mbn venus.mbn wlanmdsp.mbn; do
    install -D -m 0644 "${REPO}/${f}" "${HOTDOG}/${f}"
done
install -D -m 0644 "${REPO}/firmware-5.bin" "${FW}/ath10k/WCN3990/hw1.0/firmware-5.bin"
install -D -m 0644 "${REPO}/board-2.bin"    "${FW}/ath10k/WCN3990/hw1.0/board-2.bin"
# Bluetooth firmware is installed for the opt-in Bluetooth session; the
# driver stays blocklisted by default.
install -D -m 0644 "${REPO}/crbtfw21.tlv" "${FW}/qca/crbtfw21.tlv"
install -D -m 0644 "${REPO}/crnv21.bin"   "${FW}/qca/crnv21.bin"
# Deliberately not installed: slpi.mbn (sensor DSP disabled), the
# userspace pd-mapper maps (the kernel pd-mapper is used), pn553 NFC config
# (NFC disabled).

( cd "${FW}" && find . -type f | sort | xargs sha256sum ) > "${FW}/MANIFEST.sha256"
log "firmware tree ready: ${FW} ($(find "${FW}" -type f | wc -l) files)"
log "use it with: ANTUMBRA_FIRMWARE_DIR=${FW} ./build/rootfs.sh"
