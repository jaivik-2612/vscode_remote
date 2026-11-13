#!/bin/sh
# Tails' 05-replace_swapon: divert swapon so only zram can ever be used.
set -eu
if [ ! -e /sbin/swapon.real ]; then
    dpkg-divert --quiet --add --rename --divert /sbin/swapon.real /sbin/swapon
    install -m 0755 /usr/share/antumbra/swapon-wrapper /sbin/swapon
fi
