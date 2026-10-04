#!/bin/sh
# Install Tor Browser from the verified tarball (Tails' 10-tbb hook, simplified):
# the browser into /usr/local/lib/tor-browser, the profile skeleton into
# /etc/tor-browser/profile, the pluggable transports into /usr/bin.
set -eu
if [ -n "${ANTUMBRA_MINIMAL:-}" ]; then echo "minimal build: skipping Tor Browser"; exit 0; fi
SRC=/run/antumbra-build/tor-browser
TARBALL=""
for f in "${SRC}"/tor-browser-linux-aarch64-*.tar.xz; do [ -f "$f" ] && TARBALL="$f" && break; done
[ -n "${TARBALL}" ] || { echo "Tor Browser tarball missing" >&2; exit 1; }
TMP="$(mktemp -d)"
tar -xf "${TARBALL}" -C "${TMP}" --strip-components=1
[ -d "${TMP}/Browser" ] || { echo "unexpected tarball layout" >&2; exit 1; }
rm -rf /usr/local/lib/tor-browser /etc/tor-browser
mv "${TMP}/Browser" /usr/local/lib/tor-browser
mkdir -p /etc/tor-browser
mv /usr/local/lib/tor-browser/TorBrowser/Data/Browser/profile.default /etc/tor-browser/profile
# Pluggable transports, as Tails does: lyrebird as /usr/bin/obfs4proxy so
# Debian's Tor AppArmor abstraction keeps matching.
PT=/usr/local/lib/tor-browser/TorBrowser/Tor/PluggableTransports
install -m 0755 "${PT}/lyrebird" /usr/bin/obfs4proxy
if [ -f "${PT}/conjure-client" ]; then install -m 0755 "${PT}/conjure-client" /usr/bin/conjure-client; fi
# The bundled tor daemon is not used (the system tor is).
rm -f /usr/local/lib/tor-browser/TorBrowser/Tor/tor
ICON="$(find /usr/local/lib/tor-browser/browser/chrome/icons/default -name 'default128.png' 2>/dev/null | head -n1 || true)"
if [ -n "${ICON}" ]; then install -D -m 0644 "${ICON}" /usr/share/icons/hicolor/128x128/apps/tor-browser.png; fi
chown -R root:root /usr/local/lib/tor-browser /etc/tor-browser
rm -rf "${TMP}"
cat "${SRC}/version" > /usr/share/antumbra/tor-browser.version
echo "Tor Browser $(cat /usr/share/antumbra/tor-browser.version) installed"
