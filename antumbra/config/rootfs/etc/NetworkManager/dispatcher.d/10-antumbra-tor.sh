#!/bin/sh
# Adapted from Tails' 10-tor.sh dispatcher. When a connection comes up,
# connect Tor the way the Welcome screen asked (automatically, or through
# the bridges given) and (re)start the HTP time synchronisation, which waits
# for Tor to bootstrap. When the last connection goes down, drop the
# "Tor has bootstrapped" flag so dependants notice.
set -eu
# shellcheck source=../../../usr/local/lib/tails-shell-library/network.sh
. /usr/local/lib/tails-shell-library/network.sh
[ -n "${1:-}" ] && [ "$1" != "lo" ] || exit 0
case "${2:-}" in
    up) ;;
    down)
        if ! nm_is_connected; then
            systemctl --no-block stop tails-tor-has-bootstrapped.target
        fi
        exit 0
        ;;
    *) exit 0 ;;
esac
APPLIED=/var/lib/antumbra/settings/applied
mode="$(sed -n 's/^ANTUMBRA_TOR_MODE=//p' "${APPLIED}/tails.network" 2>/dev/null | tr -d "'\"")"
case "${mode:-direct}" in
    direct) /usr/local/sbin/antumbra-tor-connect direct || true ;;
    bridges)
        sed -n 's/^ANTUMBRA_BRIDGES=//p' "${APPLIED}/tails.bridges" 2>/dev/null | tr -d "'\"" | tr ';' '\n' \
            | /usr/local/sbin/antumbra-tor-connect bridges - || true ;;
    offline) exit 0 ;;
esac
# htpdate waits for /run/tor-has-bootstrapped/done; never re-run it once it succeeded (tails#21014)
if ! [ -f /run/htpdate/success ]; then
    systemctl --no-block restart htpdate.service
fi
