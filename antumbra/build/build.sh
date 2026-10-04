#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Antumbra build orchestrator.
#
# usage: build.sh [STEP...]
#   steps: fetch kernel rootfs squashfs image bootimg release   (default: all but release)
# Environment knobs are documented in docs/building.md:
#   ANTUMBRA_MINIMAL=1  ANTUMBRA_DEBUG=1  ANTUMBRA_VERITY=0  ANTUMBRA_FIRMWARE_DIR=...
#   ANTUMBRA_KERNEL_TOOLCHAIN=llvm|gcc  ANTUMBRA_SIGNING_KEY=...
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

STEPS=("$@")
[ "${#STEPS[@]}" -gt 0 ] || STEPS=(fetch kernel rootfs squashfs image bootimg)
START="$(date +%s)"
for step in "${STEPS[@]}"; do
    case "${step}" in
        fetch)    "${BUILD_DIR}/fetch-sources.sh" ;;
        kernel)   "${BUILD_DIR}/kernel.sh" ;;
        rootfs)   "${BUILD_DIR}/rootfs.sh" ;;
        squashfs) "${BUILD_DIR}/squashfs.sh" ;;
        image)    "${BUILD_DIR}/image.sh" ;;
        bootimg)  "${BUILD_DIR}/bootimg.sh" ;;
        release)  "${BUILD_DIR}/release.sh" ;;
        *) die "unknown step '${step}' (fetch kernel rootfs squashfs image bootimg release)" ;;
    esac
    log "step ${step} done ($(( $(date +%s) - START ))s elapsed)"
done
PRODUCTS=()
for f in "${OUT}"/*.img "${OUT}"/*.simg; do [ -e "${f}" ] && PRODUCTS+=("${f}"); done
log "build finished: ${PRODUCTS[*]:-no images yet}"
