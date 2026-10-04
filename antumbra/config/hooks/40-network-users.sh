#!/bin/sh
# System users whose traffic the firewall treats specially (fixed IDs, as in
# Tails' 06-adduser_* hooks).
set -eu
getent group htp >/dev/null || addgroup --system --quiet --gid 1101 htp
getent passwd htp >/dev/null || adduser --system --quiet --uid 1101 --gid 1101 --no-create-home --home /nonexistent htp
getent group clearnet >/dev/null || addgroup --system --quiet --gid 1102 clearnet
getent passwd clearnet >/dev/null || adduser --system --quiet --uid 1102 --gid 1102 --no-create-home --home /nonexistent clearnet
