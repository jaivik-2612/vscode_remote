#!/bin/sh
# When a connection comes up, connect Tor the way the Welcome screen asked
# (automatically, or through the bridges given). Tails does this through its
# Tor Connection assistant; this is the non-interactive equivalent.
set -eu
[ "$2" = "up" ] || exit 0
[ "$1" != "lo" ] || exit 0
APPLIED=/var/lib/antumbra/settings/applied
mode="$(sed -n 's/^ANTUMBRA_TOR_MODE=//p' "${APPLIED}/tails.network" 2>/dev/null | tr -d "'\"")"
case "${mode:-direct}" in
    direct) /usr/local/sbin/antumbra-tor-connect direct || true ;;
    bridges)
        sed -n 's/^ANTUMBRA_BRIDGES=//p' "${APPLIED}/tails.bridges" 2>/dev/null | tr -d "'\"" | tr ';' '\n' \
            | /usr/local/sbin/antumbra-tor-connect bridges - || true ;;
    offline) ;;
esac
