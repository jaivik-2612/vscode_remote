#!/bin/sh
# Memory-erasure and power services; nothing persistent anywhere.
set -eu
systemctl enable run-initramfs.mount initramfs-shutdown.service antumbra-remove-overlayfs-dirs.service \
    antumbra-lock-watch.service memlockd.service
# No debugfs exposure, no persisted random seed or timers, no core dumps.
# No text login anywhere: the greeter is the only way in (and a passwordless
# amnesia account must not be reachable from a console).
systemctl mask getty@tty1.service getty-static.service
systemctl mask sys-kernel-debug.mount sys-kernel-tracing.mount systemd-random-seed.service \
    systemd-coredump.socket systemd-coredump@.service 2>/dev/null || true
# Live config: nothing survives; machine-id is regenerated in RAM at every boot.
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id
