#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Verify a downloaded release directory: minisign signature (if a public key
# is given) and SHA-256 of every file.
# usage: verify-release.sh RELEASE_DIR [MINISIGN_PUBKEY_FILE]
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_tools sha256sum
[ $# -ge 1 ] || die "usage: verify-release.sh RELEASE_DIR [MINISIGN_PUBKEY_FILE]"
REL="$1"; PUB="${2:-}"
[ -f "${REL}/SHA256SUMS" ] || die "no SHA256SUMS in ${REL}"
if [ -n "${PUB}" ]; then
    require_tools minisign
    [ -f "${REL}/SHA256SUMS.minisig" ] || die "release is unsigned (no SHA256SUMS.minisig)"
    minisign -V -p "${PUB}" -m "${REL}/SHA256SUMS" || die "signature verification FAILED"
    log "signature OK"
else
    warn "no public key given: checking hashes only"
fi
( cd "${REL}" && sha256sum --quiet -c SHA256SUMS ) || die "hash verification FAILED"
log "all files match SHA256SUMS"
