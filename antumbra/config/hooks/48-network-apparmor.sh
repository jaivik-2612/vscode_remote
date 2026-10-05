#!/bin/sh
# Tails' 48-tweak-AppArmor-profiles: give every profile the
# attach_disconnected flag, which overlayfs needs (tails#9045), so that the
# profiles still apply on Antumbra's overlay root. Then check that the
# result parses.
set -eu
for f in /etc/apparmor.d/*; do
    [ -f "${f}" ] || continue
    # "profile name /path {" or "/path {" without flags: add the flag;
    # an existing flags=(...) list without it: append it.
    sed -i -E \
        -e '/^[[:space:]]*(profile[[:space:]]|\/).*\{[[:space:]]*$/ { /flags=\(/ { /attach_disconnected/! s/flags=\(([^)]*)\)/flags=(\1,attach_disconnected)/ } }' \
        -e '/^[[:space:]]*(profile[[:space:]]|\/).*\{[[:space:]]*$/ { /flags=\(/! s/[[:space:]]*\{[[:space:]]*$/ flags=(attach_disconnected) {/ }' \
        "${f}"
done
echo "attach_disconnected added to $(grep -l 'attach_disconnected' /etc/apparmor.d/* 2>/dev/null | wc -l) profiles"

# Profiles that this AppArmor version cannot parse would make apparmor.service
# fail at every boot (several of apparmor-profiles-extra's, e.g. pidgin,
# totem, papers: "merged rule with conflicting x modifiers"). They could not
# be enforced anyway; move them out of the load path, keep them for
# reference, and refuse to build if Tor's own profile is among them.
UNPARSEABLE=/usr/share/antumbra/apparmor-unparseable
mkdir -p "${UNPARSEABLE}"
# shellcheck disable=SC2016  # $1 is expanded by the inner sh
find /etc/apparmor.d -maxdepth 1 -type f -print0 \
    | xargs -0 -P "$(nproc)" -n 1 sh -c 'apparmor_parser -Q -K "$1" >/dev/null 2>&1 || echo "$1"' sh \
    | sort > /tmp/apparmor-unparseable.txt
while IFS= read -r f; do
    [ -n "${f}" ] || continue
    case "$(basename "${f}")" in
        system_tor|torbrowser.*) echo "48-network-apparmor: ${f} does not parse" >&2; exit 1 ;;
    esac
    echo "48-network-apparmor: ${f} does not parse with this AppArmor version; not loaded"
    mv "${f}" "${UNPARSEABLE}/"
done < /tmp/apparmor-unparseable.txt
rm -f /tmp/apparmor-unparseable.txt
apparmor_parser -Q -K /etc/apparmor.d/system_tor
echo "48-network-apparmor: $(find /etc/apparmor.d -maxdepth 1 -type f | wc -l) profiles parse"
