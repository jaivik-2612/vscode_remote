#!/bin/sh
# Identity of the build.
set -eu
: "${ANTUMBRA_VERSION:?}" "${SOURCE_DATE_EPOCH:?}" "${KERNEL_RELEASE:?}"
BUILT="$(date -u -d "@${SOURCE_DATE_EPOCH}" +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p /etc/antumbra
cat > /etc/antumbra-release <<REL
ANTUMBRA_VERSION=${ANTUMBRA_VERSION}
ANTUMBRA_BUILD_DATE=${BUILT}
ANTUMBRA_KERNEL=${KERNEL_RELEASE}
ANTUMBRA_DEBUG=${ANTUMBRA_DEBUG:-}
ANTUMBRA_MINIMAL=${ANTUMBRA_MINIMAL:-}
REL
cat > /usr/lib/os-release <<REL
NAME="Antumbra"
ID=antumbra
ID_LIKE=debian
VERSION="${ANTUMBRA_VERSION}"
VERSION_ID="${ANTUMBRA_VERSION}"
PRETTY_NAME="Antumbra ${ANTUMBRA_VERSION} (Debian 13 based)"
HOME_URL="https://github.com/jaivik-2612/vscode_remote/tree/main/antumbra"
REL
ln -sf ../usr/lib/os-release /etc/os-release
