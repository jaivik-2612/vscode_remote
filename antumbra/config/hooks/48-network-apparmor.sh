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

# Every profile must parse: one that does not is a profile apparmor.service
# cannot load, so the program it confines would run unconfined without anyone
# noticing. (The four that once failed, pidgin, totem, papers and
# plasmashell, did so because of a globbed alias tunable, now fixed.)
# ALLOWED_UNPARSEABLE lists profiles knowingly left out, for programs that
# are not installed; keep it empty unless a Debian update forces otherwise.
ALLOWED_UNPARSEABLE=""
UNPARSEABLE=/usr/share/antumbra/apparmor-unparseable
# shellcheck disable=SC2016  # $1 is expanded by the inner sh
find /etc/apparmor.d -maxdepth 1 -type f -print0 \
    | xargs -0 -P "$(nproc)" -n 1 sh -c 'apparmor_parser -Q -K "$1" >/dev/null 2>&1 || echo "$1"' sh \
    | sort > /tmp/apparmor-unparseable.txt
while IFS= read -r f; do
    [ -n "${f}" ] || continue
    # a transient failure in the parallel pass (memory, emulation) keeps the profile
    apparmor_parser -Q -K "${f}" >/dev/null 2>&1 && continue
    b="$(basename "${f}")"
    case " ${ALLOWED_UNPARSEABLE} " in
        *" ${b} "*)
            mkdir -p "${UNPARSEABLE}"
            echo "48-network-apparmor: ${f} is a known parse failure; not loaded"
            mv "${f}" "${UNPARSEABLE}/" ;;
        *)
            echo "48-network-apparmor: ${f} does not parse:" >&2
            apparmor_parser -Q -K "${f}" >&2 || true
            exit 1 ;;
    esac
done < /tmp/apparmor-unparseable.txt
rm -f /tmp/apparmor-unparseable.txt
echo "48-network-apparmor: all $(find /etc/apparmor.d -maxdepth 1 -type f | wc -l) profiles parse"
