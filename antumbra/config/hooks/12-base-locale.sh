#!/bin/sh
set -eu
# Locale and time zone (Tails: UTC; the clock is set through Tor later).
if [ -f /etc/locale.gen ]; then
    sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    locale-gen >/dev/null
fi
update-locale LANG=en_US.UTF-8
ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime
echo "Etc/UTC" > /etc/timezone
