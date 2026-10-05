#!/bin/sh
# The greeter user runs the Welcome screen before any user process exists.
set -eu
if [ -n "${ANTUMBRA_MINIMAL:-}" ]; then echo "minimal build: no greeter user"; exit 0; fi
id=993
gid_opt=""; getent group "${id}" >/dev/null || gid_opt="--gid ${id}"
uid_opt=""; getent passwd "${id}" >/dev/null || uid_opt="--uid ${id}"
# shellcheck disable=SC2086  # the options are intentionally word-split
getent group antumbra-greeter >/dev/null || addgroup --system --quiet ${gid_opt} antumbra-greeter
# shellcheck disable=SC2086
getent passwd antumbra-greeter >/dev/null || adduser --system --quiet ${uid_opt} --ingroup antumbra-greeter \
    --home /var/lib/antumbra-greeter --shell /usr/sbin/nologin antumbra-greeter
# seat access for the greeter's compositor
for g in video render input; do
    if getent group "$g" >/dev/null; then adduser --quiet antumbra-greeter "$g"; fi
done
# Interface theme for the Welcome screen and its on-screen keyboard: the
# same one-line imports antumbra-session writes for the user, root-owned.
# The greeter keeps ~/.config itself for anything else that writes there.
GREETER_CONFIG=/var/lib/antumbra-greeter/.config
install -d -o antumbra-greeter -g antumbra-greeter -m 0755 "${GREETER_CONFIG}"
install -d -o root -g root -m 0755 "${GREETER_CONFIG}/gtk-3.0" "${GREETER_CONFIG}/gtk-4.0"
printf '@import url("file:///usr/share/antumbra/theme/shell.css");\n' > "${GREETER_CONFIG}/gtk-3.0/gtk.css"
printf '@import url("file:///usr/share/antumbra/theme/apps.css");\n' > "${GREETER_CONFIG}/gtk-4.0/gtk.css"
chown root:root "${GREETER_CONFIG}/gtk-3.0/gtk.css" "${GREETER_CONFIG}/gtk-4.0/gtk.css"
chmod 0644 "${GREETER_CONFIG}/gtk-3.0/gtk.css" "${GREETER_CONFIG}/gtk-4.0/gtk.css"
