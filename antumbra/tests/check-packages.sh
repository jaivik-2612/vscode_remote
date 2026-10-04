#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Verify that every package named in config/packages/*.list exists in the
# Debian suite/architecture the build targets.
# usage: tests/check-packages.sh [PACKAGES_INDEX_FILE...]
# Without arguments the trixie arm64 indexes (main, contrib,
# non-free-firmware) are downloaded into build/cache/debian-index/.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../build/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../build/lib/common.sh"

INDEXES=("$@")
if [ "${#INDEXES[@]}" -eq 0 ]; then
    require_tools curl xz
    IDX="${CACHE}/debian-index"; mkdir -p "${IDX}"
    SUITE="$(lock_get DEBIAN_SUITE)"; MIRROR="$(lock_get DEBIAN_MIRROR)"
    for comp in main contrib non-free-firmware; do
        f="${IDX}/Packages-${comp}"
        if [ ! -s "${f}" ]; then
            log "downloading ${SUITE}/${comp} arm64 index"
            curl -fsSL "${MIRROR}/dists/${SUITE}/${comp}/binary-arm64/Packages.xz" | xz -d > "${f}"
        fi
        INDEXES+=("${f}")
    done
fi

AVAILABLE="$(mktemp)"
trap 'rm -f "${AVAILABLE}"' EXIT
grep -h '^Package: ' "${INDEXES[@]}" | cut -d' ' -f2 | sort -u > "${AVAILABLE}"
# Virtual packages (Provides:) are acceptable too.
grep -h '^Provides: ' "${INDEXES[@]}" | cut -d' ' -f2- | tr ',' '\n' | sed 's/^ *//; s/ (.*//' | sort -u >> "${AVAILABLE}"

missing=0 total=0
for list in "${CONFIG_DIR}"/packages/*.list; do
    while read -r pkg; do
        pkg="${pkg%%#*}"; pkg="${pkg//[[:space:]]/}"
        [ -n "${pkg}" ] || continue
        total=$((total + 1))
        if ! grep -qxF "${pkg}" "${AVAILABLE}"; then
            printf 'MISSING: %s (from %s)\n' "${pkg}" "$(basename "${list}")" >&2
            missing=$((missing + 1))
        fi
    done < "${list}"
done
if [ "${missing}" -gt 0 ]; then
    die "${missing} of ${total} package names are not available"
fi
log "all ${total} package names exist in the target suite"
