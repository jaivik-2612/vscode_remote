#!/bin/sh
# System users whose traffic the firewall treats specially (Tails'
# 06-adduser_* hooks). Fixed ids inside the system range when free,
# otherwise dynamically allocated: the firewall references them by name.
set -eu
make_system_user() { # make_system_user NAME PREFERRED_ID
    name="$1"; id="$2"
    gid_opt=""; getent group "${id}" >/dev/null || gid_opt="--gid ${id}"
    uid_opt=""; getent passwd "${id}" >/dev/null || uid_opt="--uid ${id}"
    # shellcheck disable=SC2086  # the options are intentionally word-split
    getent group "${name}" >/dev/null || addgroup --system --quiet ${gid_opt} "${name}"
    # shellcheck disable=SC2086
    getent passwd "${name}" >/dev/null || adduser --system --quiet ${uid_opt} --ingroup "${name}" \
        --no-create-home --home /nonexistent "${name}"
}
make_system_user htp 991
make_system_user clearnet 992
