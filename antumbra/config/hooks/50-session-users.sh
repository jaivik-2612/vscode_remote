#!/bin/sh
# The greeter user runs the Welcome screen before any user process exists.
set -eu
getent group antumbra-greeter >/dev/null || addgroup --system --quiet --gid 1104 antumbra-greeter
getent passwd antumbra-greeter >/dev/null || adduser --system --quiet --uid 1104 --gid 1104 \
    --home /var/lib/antumbra-greeter --shell /usr/sbin/nologin antumbra-greeter
# seat access for the greeter's compositor
for g in video render input; do
    if getent group "$g" >/dev/null; then adduser --quiet antumbra-greeter "$g"; fi
done
