#!/bin/sh
# Enable the network-enforcement services, keep NetworkManager off until the
# Welcome screen, and apply Tails' AppArmor adjustments for Tor.
set -eu
systemctl enable nftables.service antumbra-create-netns.service onion-grater.service \
    antumbra-set-wireless-devices-state.service antumbra-selfcheck.service \
    antumbra-selfcheck-late.timer antumbra-modem-radio-off.service antumbra-modem-radio-off.timer \
    htpdate.service tails-wait-until-tor-has-bootstrapped.service tails-tor-has-bootstrapped-flag-file.service \
    rmtfs.service tqftpserv.service
# NetworkManager is started by antumbra-unblock-network, never at boot.
systemctl disable NetworkManager.service NetworkManager-wait-online.service 2>/dev/null || true
# The in-kernel QRTR name service is used; the userspace one must not run.
systemctl disable qrtr-ns.service 2>/dev/null || true
systemctl mask qrtr-ns.service 2>/dev/null || true
# No NTP, no persisted rfkill state, no ModemManager.
systemctl mask systemd-timesyncd.service systemd-networkd.service systemd-rfkill.service systemd-rfkill.socket 2>/dev/null || true
systemctl mask ModemManager.service 2>/dev/null || true
# Debian's tor.service is enabled by the package; tor starts with DisableNetwork 1.
# Tails' AppArmor adjustments for Tor (bridge-mode DNS, SAVECONF, obfs4proxy).
for p in /usr/share/antumbra/patches/apparmor-adjust-tor-profile.diff /usr/share/antumbra/patches/apparmor-adjust-tor-abstraction.diff; do
    if patch -p1 -d / --dry-run -s -N < "${p}" >/dev/null 2>&1; then
        patch -p1 -d / -s -N < "${p}"
    else
        echo "warning: $(basename "${p}") does not apply to this tor package; skipped" >&2
    fi
done
# usbguard: our policy only (0600), never a host-generated allow-list.
chmod 0600 /etc/usbguard/rules.conf
chown root:root /etc/usbguard/rules.conf
