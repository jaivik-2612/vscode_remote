#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Antumbra build orchestrator.
#
# usage: build.sh [STEP...]
#   steps: fetch kernel libcamera rootfs squashfs image bootimg release
#          (default: all but release; libcamera only with ANTUMBRA_LIBCAMERA_LOCAL=1;
#          no bootimg for VM profiles)
# Environment knobs are documented in docs/building.md:
#   ANTUMBRA_DEVICE=qemu-virt (VM profile, see docs/vm-testing.md)
#   ANTUMBRA_MINIMAL=1  ANTUMBRA_DEBUG=1  ANTUMBRA_VERITY=0  ANTUMBRA_FIRMWARE_DIR=...
#   ANTUMBRA_KERNEL_TOOLCHAIN=llvm|gcc  ANTUMBRA_SIGNING_KEY=...
#   ANTUMBRA_LIBCAMERA_LOCAL=1 (the port's patched libcamera, see docs/camera.md)
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

STEPS=("$@")
if [ "${#STEPS[@]}" -eq 0 ]; then
    STEPS=(fetch kernel)
    # The patched libcamera is optional and only for images with applications.
    if [ -n "${ANTUMBRA_LIBCAMERA_LOCAL:-}" ] && [ -z "${ANTUMBRA_MINIMAL}" ]; then
        STEPS+=(libcamera)
    fi
    STEPS+=(rootfs squashfs image)
    [ "${IMAGE_OUTPUT}" = "vmdisk" ] || STEPS+=(bootimg)
fi
START="$(date +%s)"
for step in "${STEPS[@]}"; do
    case "${step}" in
        fetch)    "${BUILD_DIR}/fetch-sources.sh" ;;
        kernel)   "${BUILD_DIR}/kernel.sh" ;;
        libcamera) "${BUILD_DIR}/libcamera.sh" ;;
        rootfs)   "${BUILD_DIR}/rootfs.sh" ;;
        squashfs) "${BUILD_DIR}/squashfs.sh" ;;
        image)    "${BUILD_DIR}/image.sh" ;;
        bootimg)  "${BUILD_DIR}/bootimg.sh" ;;
        release)  "${BUILD_DIR}/release.sh" ;;
        *) die "unknown step '${step}' (fetch kernel libcamera rootfs squashfs image bootimg release)" ;;
    esac
    log "step ${step} done ($(( $(date +%s) - START ))s elapsed)"
done
PRODUCTS=()
for f in "${OUT}"/*.img "${OUT}"/*.simg; do [ -e "${f}" ] && PRODUCTS+=("${f}"); done || true
log "build finished: ${PRODUCTS[*]:-no images yet}"
