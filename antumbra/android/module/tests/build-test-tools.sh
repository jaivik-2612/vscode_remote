#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Antumbra module: build the stand-ins for Android's shell tools that
# tests/e2e-host.sh runs the module's scripts with, from pinned sources:
#
#   toybox   AOSP external/toybox at android16-release, commit
#            e21e76d30fa15996188b79affbc25cfd0c13deff (toybox 0.8.12 as
#            Android 16 ships it), 'make defconfig' plus CONFIG_TR=y, which
#            Android's device build has
#   mksh     AOSP external/mksh at android16-release, commit
#            103f7c36340298f42cee2f0fe7101a93a01a14e7 (R59c), 'Build.sh -r'
#   busybox  1.37.0 from busybox.net, SHA-256
#            3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4,
#            signature by Denys Vlasenko's key
#            C9E9 416F 76E6 10DB D09D  040F 47B7 0C55 ACC9 965B, 'make
#            defconfig' plus FEATURE_SH_STANDALONE and FEATURE_PREFER_APPLETS
#            (how Magisk runs module scripts) and without tc (it does not
#            build against Linux 6.8+ headers, and nothing here uses it)
#
# git checks the two commits by their hashes. Each tool is built for this
# host (Linux x86_64, with cc, make and git; gpg for busybox's signature).
#
# Usage: tests/build-test-tools.sh --out DIR [--work DIR] [--jobs N]
#   Writes DIR/toybox, DIR/mksh and DIR/busybox. --work holds the sources
#   and the builds (default: a temporary directory, deleted at the end).
set -eu
umask 022

TOYBOX_URL=https://android.googlesource.com/platform/external/toybox
TOYBOX_COMMIT=e21e76d30fa15996188b79affbc25cfd0c13deff
MKSH_URL=https://android.googlesource.com/platform/external/mksh
MKSH_COMMIT=103f7c36340298f42cee2f0fe7101a93a01a14e7
BUSYBOX_VERSION=1.37.0
BUSYBOX_SHA256=3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4
BUSYBOX_KEY=C9E9416F76E610DBD09D040F47B70C55ACC9965B
BUSYBOX_URL=https://busybox.net/downloads
BUSYBOX_KEY_URL="https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x$BUSYBOX_KEY"

say() { printf '[build-test-tools] %s\n' "$*" >&2; }
die() {
	printf '[build-test-tools] error: %s\n' "$*" >&2
	exit 1
}

OUT='' WORK='' JOBS=2
while [ $# -gt 0 ]; do
	case $1 in
	--out) OUT=${2:?}; shift 2 ;;
	--work) WORK=${2:?}; shift 2 ;;
	--jobs) JOBS=${2:?}; shift 2 ;;
	*) die "unknown argument: $1 (usage: --out DIR [--work DIR] [--jobs N])" ;;
	esac
done
[ -n "$OUT" ] || die "--out DIR is required"
case $JOBS in '' | *[!0-9]*) die "--jobs must be a number" ;; esac
for t in cc make git curl sha256sum gpg tar bzip2; do
	command -v "$t" >/dev/null 2>&1 || die "needs $t"
done
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
if [ -z "$WORK" ]; then
	WORK=$(mktemp -d "${TMPDIR:-/tmp}/antumbra-test-tools.XXXXXX")
	trap 'rm -rf "$WORK"' EXIT
fi
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)

# fetch_commit URL COMMIT DIR: exactly that commit, checked by git.
fetch_commit() {
	rm -rf "$3"
	git init -q "$3"
	git -C "$3" fetch -q --depth 1 "$1" "$2" || die "cannot fetch $2 from $1"
	git -C "$3" -c advice.detachedHead=false checkout -q FETCH_HEAD
	[ "$(git -C "$3" rev-parse HEAD)" = "$2" ] || die "$1: HEAD is not $2"
}

# --- toybox ---------------------------------------------------------------------
say "toybox $TOYBOX_COMMIT"
fetch_commit "$TOYBOX_URL" "$TOYBOX_COMMIT" "$WORK/toybox"
(
	cd "$WORK/toybox"
	make defconfig >/dev/null
	sed -i 's/^# CONFIG_TR is not set$/CONFIG_TR=y/' .config
	grep -q '^CONFIG_TR=y$' .config || echo 'CONFIG_TR=y' >>.config
	make -j"$JOBS" toybox >/dev/null 2>"$WORK/toybox.log" || {
		tail -n 30 "$WORK/toybox.log" >&2
		exit 1
	}
) || die "toybox did not build"
"$WORK/toybox/toybox" tr a b </dev/null >/dev/null || die "toybox has no tr"
cp "$WORK/toybox/toybox" "$OUT/toybox"

# --- mksh -------------------------------------------------------------------------
say "mksh $MKSH_COMMIT"
fetch_commit "$MKSH_URL" "$MKSH_COMMIT" "$WORK/mksh"
(cd "$WORK/mksh/src" && sh Build.sh -r >"$WORK/mksh.log" 2>&1) || {
	tail -n 30 "$WORK/mksh.log" >&2
	die "mksh did not build"
}
cp "$WORK/mksh/src/mksh" "$OUT/mksh"

# --- busybox ----------------------------------------------------------------------
say "busybox $BUSYBOX_VERSION"
B=$WORK/busybox-$BUSYBOX_VERSION.tar.bz2
curl -fsSL --proto '=https' --tlsv1.2 -o "$B" "$BUSYBOX_URL/busybox-$BUSYBOX_VERSION.tar.bz2" ||
	die "cannot download busybox"
curl -fsSL --proto '=https' --tlsv1.2 -o "$B.sig" "$BUSYBOX_URL/busybox-$BUSYBOX_VERSION.tar.bz2.sig" ||
	die "cannot download busybox's signature"
[ "$(sha256sum "$B" | cut -d' ' -f1)" = "$BUSYBOX_SHA256" ] || die "busybox: SHA-256 differs from the pin"
GNUPGHOME=$WORK/gnupg
export GNUPGHOME
rm -rf "$GNUPGHOME"
mkdir -m 0700 "$GNUPGHOME"
curl -fsSL --proto '=https' --tlsv1.2 -o "$WORK/busybox-key.asc" "$BUSYBOX_KEY_URL" ||
	die "cannot download busybox's signing key"
# gpg may report a failure only because it could not start gpg-agent
# (which importing a public key does not need); what counts is that the
# pinned key is in the keyring afterwards.
gpg --batch --quiet --no-autostart --import "$WORK/busybox-key.asc" 2>/dev/null || true
gpg --batch --no-autostart --with-colons --fingerprint "$BUSYBOX_KEY" 2>/dev/null |
	grep -q "^fpr:*$BUSYBOX_KEY:" || die "cannot import busybox's key $BUSYBOX_KEY"
# The signature must be valid and made by the pinned key (its fingerprint,
# not only its short ID).
gpg --batch --no-autostart --status-fd 1 --verify "$B.sig" "$B" 2>/dev/null |
	grep -q "^\[GNUPG:\] VALIDSIG $BUSYBOX_KEY " ||
	die "busybox: no valid signature by $BUSYBOX_KEY"
tar -xjf "$B" -C "$WORK"
(
	cd "$WORK/busybox-$BUSYBOX_VERSION"
	make defconfig >/dev/null
	sed -i -e 's/^# CONFIG_FEATURE_SH_STANDALONE is not set$/CONFIG_FEATURE_SH_STANDALONE=y/' \
		-e 's/^# CONFIG_FEATURE_PREFER_APPLETS is not set$/CONFIG_FEATURE_PREFER_APPLETS=y/' \
		-e 's/^CONFIG_TC=y$/# CONFIG_TC is not set/' .config
	yes '' | make oldconfig >/dev/null 2>&1
	grep -q '^CONFIG_FEATURE_SH_STANDALONE=y$' .config && grep -q '^CONFIG_FEATURE_PREFER_APPLETS=y$' .config ||
		exit 1
	make -j"$JOBS" busybox >"$WORK/busybox.log" 2>&1 || {
		tail -n 30 "$WORK/busybox.log" >&2
		exit 1
	}
) || die "busybox did not build"
cp "$WORK/busybox-$BUSYBOX_VERSION/busybox" "$OUT/busybox"

chmod 0755 "$OUT/toybox" "$OUT/mksh" "$OUT/busybox"
say "wrote $OUT/toybox, $OUT/mksh, $OUT/busybox"
