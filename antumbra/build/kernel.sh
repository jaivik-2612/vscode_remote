#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build the Antumbra kernel for the OnePlus 7T Pro.
#
# Inputs : build/cache/kernel (fetch-sources.sh), build/cache/hotdog-patches,
#          device/oneplus-hotdog/kernel/{patches.list,patches/,antumbra.config,
#          antumbra-dts-overrides.dtsi}
# Outputs: build/out/kernel/Image                 raw arm64 kernel (what the ABL boots)
#          build/out/kernel/sm8150-oneplus-hotdog.dtb
#          build/out/kernel/modules.tar.zst       /lib/modules/<release>, stripped
#          build/out/kernel/config, kernel.release, mmap-rnd-bits
#
# Toolchain: LLVM by default (the port's validated recipe); set
# ANTUMBRA_KERNEL_TOOLCHAIN=gcc for the Debian cross GCC (experimental).
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
    cat <<USAGE
usage: kernel.sh [--configure-only] [-j N]

Applies the port's patches and Antumbra's own, merges the configuration
fragment, builds Image + modules + DTB and packs the results into build/out/kernel/.
USAGE
}

CONFIGURE_ONLY=''
JOBS="$(nproc)"
while [ $# -gt 0 ]; do
    case "$1" in
        --configure-only) CONFIGURE_ONLY=1 ;;
        -j) JOBS="$2"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "unknown argument: $1" ;;
    esac
    shift
done

require_tools make bc bison flex python3 patch git tar zstd
ensure_dirs

TOOLCHAIN="${ANTUMBRA_KERNEL_TOOLCHAIN:-llvm}"
case "${TOOLCHAIN}" in
    llvm)
        require_tools clang ld.lld llvm-objcopy llvm-ar llvm-nm llvm-strip
        MAKE_TC=(LLVM=1 LLVM_IAS=1)
        ;;
    gcc)
        require_tools aarch64-linux-gnu-gcc
        MAKE_TC=(CROSS_COMPILE=aarch64-linux-gnu-)
        ;;
    *) die "ANTUMBRA_KERNEL_TOOLCHAIN must be llvm or gcc" ;;
esac

KSRC="${CACHE}/kernel"
O="${WORK}/kernel-build"
KOUT="${OUT}/kernel"
PATCHES="${CACHE}/hotdog-patches"
COMMIT="$(lock_get KERNEL_GIT_COMMIT)"
DTS="arch/arm64/boot/dts/qcom/sm8150-oneplus-hotdog.dts"

[ -d "${KSRC}/.git" ] || die "kernel tree missing; run fetch-sources.sh"
[ "$(git -C "${KSRC}" rev-parse HEAD)" = "${COMMIT}" ] || die "kernel tree is not at ${COMMIT}"

# --- Reset the tree and apply the patch series --------------------------------
log "resetting kernel tree to ${COMMIT}"
git -C "${KSRC}" checkout -q -- .
git -C "${KSRC}" clean -qfd
mapfile -t PORT_PATCHES < <(grep -v '^\s*$' "${DEVICE_DIR}/kernel/patches.list")
for p in "${PORT_PATCHES[@]}"; do
    [ -f "${PATCHES}/${p}" ] || die "missing port patch ${p}; run fetch-sources.sh"
    patch -d "${KSRC}" -p1 -s --no-backup-if-mismatch -N < "${PATCHES}/${p}" || die "port patch failed: ${p}"
done
log "applied ${#PORT_PATCHES[@]} port patches"
for p in "${DEVICE_DIR}"/kernel/patches/*.patch; do
    [ -f "${p}" ] || continue
    patch -d "${KSRC}" -p1 -s --no-backup-if-mismatch -N < "${p}" || die "Antumbra patch failed: $(basename "${p}")"
    log "applied $(basename "${p}")"
done

# --- Device-tree overrides ----------------------------------------------------
[ -f "${KSRC}/${DTS}" ] || die "${DTS} not found after patching"
grep -q 'remoteproc_slpi:' "${KSRC}/arch/arm64/boot/dts/qcom/sm8150.dtsi" || die "label remoteproc_slpi missing"
grep -rq '\bramoops:' "${KSRC}/arch/arm64/boot/dts/qcom/sm8150-oneplus-hotdog.dts" "${KSRC}/arch/arm64/boot/dts/qcom/sm8150-oneplus-common.dtsi" || die "label ramoops missing"
{ printf '\n'; cat "${DEVICE_DIR}/kernel/antumbra-dts-overrides.dtsi"; } >> "${KSRC}/${DTS}"
log "appended device-tree overrides to ${DTS}"

# --- Configuration ------------------------------------------------------------
mkdir -p "${O}"
PORT_CONFIG="${PATCHES}/$(lock_get PORT_KERNEL_CONFIG)"
sha256_check "${PORT_CONFIG}" "$(lock_get PORT_KERNEL_CONFIG_SHA256)"
cp "${PORT_CONFIG}" "${O}/.config"
# merge_config.sh needs to run from the source tree; -O selects the output dir.
( cd "${KSRC}" && env ARCH=arm64 "${MAKE_TC[@]}" \
    scripts/kconfig/merge_config.sh -O "${O}" -m "${O}/.config" "${DEVICE_DIR}/kernel/antumbra.config" >/dev/null )
make -C "${KSRC}" O="${O}" ARCH=arm64 "${MAKE_TC[@]}" olddefconfig >/dev/null

# Every fragment line must be honoured in the final configuration.
check_fragment() {
    local line key val fail=0
    while IFS= read -r line; do
        case "${line}" in
            ''|'#'*)
                if [[ "${line}" =~ ^#\ (CONFIG_[A-Z0-9_]+)\ is\ not\ set$ ]]; then
                    key="${BASH_REMATCH[1]}"
                    if grep -q "^${key}=" "${O}/.config"; then
                        warn "fragment wants ${key} unset but .config has $(grep "^${key}=" "${O}/.config")"; fail=1
                    fi
                fi
                ;;
            CONFIG_*=*)
                key="${line%%=*}"; val="${line#*=}"
                if ! grep -qxF "${key}=${val}" "${O}/.config"; then
                    warn "fragment line not honoured: ${line} (have: $(grep "^${key}[= ]" "${O}/.config" || echo 'absent'))"; fail=1
                fi
                ;;
        esac
    done < "${DEVICE_DIR}/kernel/antumbra.config"
    return "${fail}"
}
if ! check_fragment; then
    if [ "${ANTUMBRA_KERNEL_ALLOW_CONFIG_DRIFT:-}" = "1" ]; then
        warn "continuing despite configuration drift (ANTUMBRA_KERNEL_ALLOW_CONFIG_DRIFT=1)"
    else
        die "configuration fragment not fully applied; see warnings above"
    fi
fi
log "configuration merged and verified"

mkdir -p "${KOUT}"
cp "${O}/.config" "${KOUT}/config"
{
    grep -E '^CONFIG_ARCH_MMAP_RND_BITS_MAX=' "${O}/.config" | sed 's/CONFIG_ARCH_MMAP_RND_BITS_MAX=/vm.mmap_rnd_bits=/'
    grep -E '^CONFIG_ARCH_MMAP_RND_COMPAT_BITS_MAX=' "${O}/.config" | sed 's/CONFIG_ARCH_MMAP_RND_COMPAT_BITS_MAX=/vm.mmap_rnd_compat_bits=/'
} > "${KOUT}/mmap-rnd-bits"
[ -z "${CONFIGURE_ONLY}" ] || { log "configure-only: stopping"; exit 0; }

# --- Build --------------------------------------------------------------------
export KBUILD_BUILD_TIMESTAMP KBUILD_BUILD_USER=antumbra KBUILD_BUILD_HOST=antumbra
KBUILD_BUILD_TIMESTAMP="$(date -u -d "@${SOURCE_DATE_EPOCH}" '+%a %b %e %H:%M:%S UTC %Y')"
log "building Image, modules and DTB with ${TOOLCHAIN} (-j${JOBS})"
make -C "${KSRC}" O="${O}" ARCH=arm64 "${MAKE_TC[@]}" -j"${JOBS}" Image modules dtbs

IMAGE="${O}/arch/arm64/boot/Image"
DTB="${O}/arch/arm64/boot/dts/qcom/sm8150-oneplus-hotdog.dtb"
[ -f "${IMAGE}" ] || die "Image was not produced"
[ -f "${DTB}" ] || die "DTB was not produced"
# The ABL needs the raw arm64 Image: magic "ARM\x64" at offset 0x38.
[ "$(dd if="${IMAGE}" bs=1 skip=56 count=4 2>/dev/null)" = "ARM$(printf '\x64')" ] || die "Image lacks the arm64 header magic"

KREL="$(cat "${O}/include/config/kernel.release")"
MODDIR="${WORK}/kernel-modules"
rm -rf "${MODDIR}"
make -C "${KSRC}" O="${O}" ARCH=arm64 "${MAKE_TC[@]}" INSTALL_MOD_PATH="${MODDIR}" INSTALL_MOD_STRIP=1 modules_install >/dev/null
rm -f "${MODDIR}/lib/modules/${KREL}/build" "${MODDIR}/lib/modules/${KREL}/source"
tar -C "${MODDIR}" --sort=name --mtime="@${SOURCE_DATE_EPOCH}" --owner=0 --group=0 --numeric-owner -cf - lib \
    | zstd -q -T0 -19 -o "${KOUT}/modules.tar.zst" -f
cp "${IMAGE}" "${KOUT}/Image"
cp "${DTB}" "${KOUT}/sm8150-oneplus-hotdog.dtb"
printf '%s\n' "${KREL}" > "${KOUT}/kernel.release"
log "kernel ${KREL}: Image $(stat -c %s "${KOUT}/Image") bytes, modules $(stat -c %s "${KOUT}/modules.tar.zst") bytes"
