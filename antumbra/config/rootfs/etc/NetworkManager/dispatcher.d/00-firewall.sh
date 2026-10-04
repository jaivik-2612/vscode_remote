#!/bin/sh
# Ported from Tails' NetworkManager dispatcher 00-firewall.sh: re-apply the
# Tor-enforcement ruleset whenever an interface comes up, then replay the
# session rules. The session table itself survives a reload; replaying is
# defence in depth.
set -e
[ "$2" = "up" ] || exit 0
/usr/sbin/nft -f /etc/nftables.conf
if [ -e /var/lib/antumbra/session-firewall-rules ]; then
    while read -r rule; do
        [ -n "${rule}" ] || continue
        /usr/sbin/nft "${rule}" || true
    done < /var/lib/antumbra/session-firewall-rules
fi
