#!/bin/sh
# Display manager and session services.
set -eu
if [ -n "${ANTUMBRA_MINIMAL:-}" ]; then echo "minimal build: no session"; exit 0; fi
systemctl enable greetd.service antumbra-apply-welcome-settings.path antumbra-persistence-probe.service
systemctl mask phosh.service 2>/dev/null || true
dconf update
# The live user: no password until the Welcome screen sets one.
passwd -d amnesia >/dev/null 2>&1 || true
chmod 0440 /etc/sudoers.d/antumbra-tor-browser /etc/sudoers.d/always-ask-password /etc/sudoers.d/allow-closefrom
visudo -c -q
chmod 0600 /etc/skel/.tor/control_auth_cookie
mkdir -p /home/amnesia/.tor
cp -a /etc/skel/.tor/control_auth_cookie /home/amnesia/.tor/
chown -R amnesia:amnesia /home/amnesia/.tor
