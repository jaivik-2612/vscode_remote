#!/bin/sh
# Display manager and session services.
set -eu
if [ -n "${ANTUMBRA_MINIMAL:-}" ]; then echo "minimal build: no session"; exit 0; fi
systemctl enable greetd.service antumbra-apply-welcome-settings.path antumbra-persistence-probe.service
systemctl mask phosh.service 2>/dev/null || true
# No file indexer. localsearch (package tracker-extract, which nautilus
# depends on) would rebuild its index in RAM at every boot, costing CPU and
# battery; on a loaded system its first start outlasts systemd's timeout and
# every later start fails on the half-made database. Its user units are
# masked: gnome-session.target wants localsearch-3.service, and every D-Bus
# name of localsearch and of tinysparql's portal is activated through one of
# these units (SystemdService=), so a masked unit refuses both. Nautilus's
# own search engine still finds files by name, not by content.
systemctl --global disable localsearch-3.service
systemctl --global mask localsearch-3.service localsearch-control-3.service localsearch-writeback-3.service \
    tinysparql-xdg-portal-3.service
# Its XDG autostart entry is skipped under systemd; hidden for any other
# session manager too.
AUTOSTART=/etc/xdg/autostart/localsearch-3.desktop
if [ -f "${AUTOSTART}" ] && ! grep -qx 'Hidden=true' "${AUTOSTART}"; then echo 'Hidden=true' >> "${AUTOSTART}"; fi
# The overlay (with 90_antumbra.gschema.override) is synced after dpkg's
# schema trigger has run, so compile again. --strict turns an unknown key,
# schema or value in any override into a build failure.
glib-compile-schemas --strict /usr/share/glib-2.0/schemas
dconf update
# The Antumbra icon theme (status icons) comes from the overlay too; GTK
# also finds the icons without a cache, only more slowly.
if command -v gtk-update-icon-cache >/dev/null 2>&1; then gtk-update-icon-cache -q -f -t /usr/share/icons/Antumbra; fi
# The live user: no password until the Welcome screen sets one.
passwd -d amnesia >/dev/null 2>&1 || true
chmod 0440 /etc/sudoers.d/antumbra-tor-browser /etc/sudoers.d/always-ask-password /etc/sudoers.d/allow-closefrom
visudo -c -q
chmod 0600 /etc/skel/.tor/control_auth_cookie
mkdir -p /home/amnesia/.tor
cp -a /etc/skel/.tor/control_auth_cookie /home/amnesia/.tor/
chown -R amnesia:amnesia /home/amnesia/.tor
