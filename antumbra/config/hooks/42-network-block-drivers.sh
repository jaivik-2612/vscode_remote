#!/bin/sh
# Tails' 80-block-network hook: every network driver module is blocklisted
# until the Welcome screen has recorded the MAC-spoofing decision
# (antumbra-unblock-network removes the file).
set -eu
: "${KERNEL_RELEASE:?}"
MODDIR="/lib/modules/${KERNEL_RELEASE}/kernel/drivers/net"
OUT=/etc/modprobe.d/all-net-blocklist.conf
is_allowed() {
    case "$1" in veth|dummy|tun|tap|bridge|bonding) return 0 ;; esac
    return 1
}
{
    echo "# Generated at build time by 42-network-block-drivers.sh: network drivers"
    echo "# stay unloadable until antumbra-unblock-network removes this file."
    find "${MODDIR}" -type f \( -name '*.ko' -o -name '*.ko.xz' -o -name '*.ko.zst' -o -name '*.ko.gz' \) 2>/dev/null \
        | while read -r mod; do
            name="$(basename "${mod}" | sed -E 's/\.ko(\.(xz|zst|gz))?$//')"
            is_allowed "${name}" || printf 'install %s /bin/true\n' "${name}"
        done | sort -u
} > "${OUT}"
echo "blocklisted $(grep -c '^install' "${OUT}") network driver modules"
