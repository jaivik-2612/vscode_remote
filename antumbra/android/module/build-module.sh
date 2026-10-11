#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Antumbra: assemble the Magisk module zip from the outputs of the other
# parts, or install the same files on a running rooted emulator.
#
# Usage:
#   build-module.sh --tor DIR --dnsfilter DIR --blocklist FILE [options]
#   build-module.sh --emulator --tor DIR --dnsfilter DIR --blocklist FILE [options]
#   build-module.sh --emulator --zip FILE [--serial S] [--no-restart]
#
# Inputs (the other parts' outputs):
#   --tor DIR           build-tor.sh --out DIR: DIR/<abi>/tor
#   --dnsfilter DIR     dnsfilter/build.sh --out DIR: DIR/<abi>/antumbra-dnsfilter
#   --blocklist FILE    dnsfilter/fetch-lists.sh --out OUT: OUT/dnsfilter.list
#   --doh-list FILE     the firewall's DNS-over-HTTPS list (default:
#                       doh-ipv4.txt next to the block list, if it is there)
#   --firewall FILE     default: ../firewall/antumbra-fw next to this folder
#   --lyrebird DIR      optional: DIR/<abi>/lyrebird (pluggable transports)
#   --helper DIR        prebuilt DIR/<abi>/antumbra-run; by default it is
#                       built here from helper/antumbra-run.c with the NDK
#
# Options:
#   --abi ABI           arm64-v8a, x86_64 or all (default: all; with
#                       --emulator, the emulator's own ABI)
#   --version V         module version (default: module.prop's)
#   --out FILE          the zip (default: ./antumbra-module-<version>.zip)
#   --stage DIR         also leave the unpacked module tree in DIR (must
#                       not exist yet)
#   --no-overlay        leave out the keepalive-offload overlay APK (always
#                       left out with --emulator: nothing mounts system/
#                       there, so it would have no effect)
#   --overlay-keystore FILE  sign the overlay with this PKCS#12 keystore
#                       (alias "antumbra", password in
#                       $ANTUMBRA_OVERLAY_KS_PASS); by default a new key is
#                       made for each build, so the overlay's signature,
#                       and with it the zip, differ between builds
#   --ndk DIR           Android NDK (default: $ANDROID_NDK_ROOT, else
#                       /opt/android-sdk/ndk/28.2.13676358)
#   --sdk DIR           Android SDK (default: $ANDROID_HOME, else /opt/android-sdk);
#                       the overlay needs build-tools 36.0.0 and platforms;android-36
#   --emulator          do not write a zip: push the module to the running
#                       emulator (adb root on Google's 'default' image),
#                       install it as Magisk would (lib/emu-install.sh),
#                       then run post-fs-data.sh and service.sh by hand in
#                       the boot order (see README.md)
#   --zip FILE          with --emulator: install exactly the files of this
#                       module zip (as build-module.sh wrote it) instead of
#                       building the tree from the checkout; --tor,
#                       --dnsfilter and --blocklist are then not needed
#   --serial S          adb device to use with --emulator
#   --no-restart        with --emulator: do not stop the framework (netd,
#                       zygote) around post-fs-data.sh
#   --keep-work         keep the work directory
#
# The zip contains no third-party source. It contains the binaries built
# by the other parts (tor, the DNS filter, lyrebird), the block list, and
# NOTICE, which names their licences.
set -eu
umask 022
export LC_ALL=C TZ=UTC

HERE=$(cd "$(dirname "$0")" && pwd)
ANDROID_DIR=$(cd "$HERE/.." && pwd)

say() { printf '[build-module] %s\n' "$*" >&2; }
die() {
	printf '[build-module] error: %s\n' "$*" >&2
	exit 1
}
usage() { sed -n '3,/^set -eu/{/^set -eu/d;s/^# \{0,1\}//;p;}' "$0"; }

TOR_DIR='' DNS_DIR='' BLOCKLIST='' DOH='' FIREWALL=$ANDROID_DIR/firewall/antumbra-fw
LYRE_DIR='' HELPER_DIR='' ABI_ARG='' VERSION='' OUT='' STAGE_KEEP=''
OVERLAY=1 KEYSTORE='' NDK=${ANDROID_NDK_ROOT:-/opt/android-sdk/ndk/28.2.13676358}
SDK=${ANDROID_HOME:-/opt/android-sdk} EMULATOR=0 SERIAL='' RESTART=1 KEEP_WORK=0 FROM_ZIP=
API=34
while [ $# -gt 0 ]; do
	case $1 in
	--tor) TOR_DIR=${2:?}; shift 2 ;;
	--dnsfilter) DNS_DIR=${2:?}; shift 2 ;;
	--blocklist) BLOCKLIST=${2:?}; shift 2 ;;
	--doh-list) DOH=${2:?}; shift 2 ;;
	--firewall) FIREWALL=${2:?}; shift 2 ;;
	--lyrebird) LYRE_DIR=${2:?}; shift 2 ;;
	--helper) HELPER_DIR=${2:?}; shift 2 ;;
	--abi) ABI_ARG=${2:?}; shift 2 ;;
	--version) VERSION=${2:?}; shift 2 ;;
	--out) OUT=${2:?}; shift 2 ;;
	--stage) STAGE_KEEP=${2:?}; shift 2 ;;
	--no-overlay) OVERLAY=0; shift ;;
	--overlay-keystore) KEYSTORE=${2:?}; shift 2 ;;
	--ndk) NDK=${2:?}; shift 2 ;;
	--sdk) SDK=${2:?}; shift 2 ;;
	--emulator) EMULATOR=1; shift ;;
	--zip) FROM_ZIP=${2:?}; shift 2 ;;
	--serial) SERIAL=${2:?}; shift 2 ;;
	--no-restart) RESTART=0; shift ;;
	--keep-work) KEEP_WORK=1; shift ;;
	-h | --help) usage; exit 0 ;;
	*) usage >&2; die "unknown argument: $1" ;;
	esac
done

# The overlay needs Magisk (or KernelSU) to mount system/; the emulator has
# neither, so it is never built for it (and building it would need Java's
# keytool on the CI runner).
[ "$EMULATOR" = 1 ] && OVERLAY=0
if [ -n "$FROM_ZIP" ]; then
	[ "$EMULATOR" = 1 ] || die "--zip is used with --emulator"
	[ -f "$FROM_ZIP" ] || die "no module zip at $FROM_ZIP"
	FROM_ZIP=$(cd "$(dirname "$FROM_ZIP")" && pwd)/$(basename "$FROM_ZIP")
else
	if [ -z "$TOR_DIR" ] || [ -z "$DNS_DIR" ] || [ -z "$BLOCKLIST" ]; then
		die "--tor, --dnsfilter and --blocklist are required (see --help)"
	fi
	[ -f "$BLOCKLIST" ] || die "no block list at $BLOCKLIST"
	[ -f "$FIREWALL" ] || die "no firewall script at $FIREWALL"
	if [ -z "$DOH" ] && [ -f "$(dirname "$BLOCKLIST")/doh-ipv4.txt" ]; then
		DOH=$(dirname "$BLOCKLIST")/doh-ipv4.txt
	fi
	[ -z "$DOH" ] || [ -f "$DOH" ] || die "no DoH list at $DOH"
fi
[ -z "$STAGE_KEEP" ] || [ ! -e "$STAGE_KEEP" ] || die "--stage $STAGE_KEEP exists already"

ADB=adb
if [ "$EMULATOR" = 1 ]; then
	command -v adb >/dev/null 2>&1 || ADB=$SDK/platform-tools/adb
	[ -x "$ADB" ] || command -v "$ADB" >/dev/null 2>&1 || die "adb not found"
	[ -n "$SERIAL" ] && ADB="$ADB -s $SERIAL"
	# shellcheck disable=SC2086 # ADB may carry -s SERIAL
	EMU_ABI=$($ADB shell getprop ro.product.cpu.abi | tr -d '\r')
	[ -n "$EMU_ABI" ] || die "no device answers adb"
	ABI_ARG=${ABI_ARG:-$EMU_ABI}
	[ "$ABI_ARG" = "$EMU_ABI" ] || die "--abi $ABI_ARG does not match the device ($EMU_ABI)"
fi
case ${ABI_ARG:-all} in
all) ABIS='arm64-v8a x86_64' ;;
arm64-v8a | x86_64) ABIS=$ABI_ARG ;;
*) die "--abi must be arm64-v8a, x86_64 or all" ;;
esac
for abi in $ABIS; do
	[ -z "$FROM_ZIP" ] || break
	[ -f "$TOR_DIR/$abi/tor" ] || die "no $TOR_DIR/$abi/tor"
	[ -f "$DNS_DIR/$abi/antumbra-dnsfilter" ] || die "no $DNS_DIR/$abi/antumbra-dnsfilter"
	[ -z "$HELPER_DIR" ] || [ -f "$HELPER_DIR/$abi/antumbra-run" ] || die "no $HELPER_DIR/$abi/antumbra-run"
	[ -z "$LYRE_DIR" ] || [ -f "$LYRE_DIR/$abi/lyrebird" ] || die "no $LYRE_DIR/$abi/lyrebird"
done

VERSION=${VERSION:-$(sed -n 's/^version=//p' "$HERE/module.prop")}
case $VERSION in '' | *[!A-Za-z0-9._+-]*) die "bad version '$VERSION'" ;; esac
OUT=${OUT:-$PWD/antumbra-module-$VERSION.zip}

# Time stamps in the zip: SOURCE_DATE_EPOCH, else the last commit of this
# folder, else 1980-01-01 (the earliest a zip can hold).
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
	SOURCE_DATE_EPOCH=$(git -C "$HERE" log -1 --format=%ct -- . 2>/dev/null || true)
	SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-315532800}
fi
case $SOURCE_DATE_EPOCH in *[!0-9]* | '') die "SOURCE_DATE_EPOCH must be a number" ;; esac
export SOURCE_DATE_EPOCH

WORK=$(mktemp -d "${TMPDIR:-/tmp}/antumbra-module.XXXXXX")
cleanup() {
	if [ "$KEEP_WORK" = 1 ]; then
		say "work directory kept: $WORK"
	else
		rm -rf "$WORK"
	fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
STAGE=$WORK/antumbra

# --- 1. The helper ----------------------------------------------------------------

build_helper() { # ABI OUTPUT
	case $1 in
	arm64-v8a) _bh_target=aarch64-linux-android$API ;;
	x86_64) _bh_target=x86_64-linux-android$API ;;
	esac
	_bh_tc=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin
	[ -x "$_bh_tc/clang" ] || die "no NDK clang in $_bh_tc (use --ndk or --helper)"
	"$_bh_tc/clang" --target="$_bh_target" -std=c11 -O2 -Wall -Wextra -Werror -Wformat=2 -Wshadow \
		-fPIE -pie -fstack-protector-strong -D_FORTIFY_SOURCE=2 \
		-ffile-prefix-map="$HERE"=. \
		-Wl,-z,relro,-z,now,-z,noexecstack -Wl,-z,max-page-size=16384 -Wl,--build-id=sha1 \
		-o "$2" "$HERE/helper/antumbra-run.c"
	"$_bh_tc/llvm-strip" --strip-all "$2"
}

# --- 2. The overlay ------------------------------------------------------------------

build_overlay() { # OUTPUT
	_bo_bt=$SDK/build-tools/36.0.0
	_bo_jar=$SDK/platforms/android-36/android.jar
	for _bo_t in "$_bo_bt/aapt2" "$_bo_bt/zipalign" "$_bo_bt/apksigner"; do
		[ -x "$_bo_t" ] || return 1
	done
	[ -f "$_bo_jar" ] || return 1
	_bo_w=$WORK/overlay
	mkdir -p "$_bo_w"
	"$_bo_bt/aapt2" compile --dir "$HERE/overlay/res" -o "$_bo_w/res.zip"
	"$_bo_bt/aapt2" link -o "$_bo_w/unsigned.apk" -I "$_bo_jar" \
		--manifest "$HERE/overlay/AndroidManifest.xml" \
		--min-sdk-version 34 --target-sdk-version 36 "$_bo_w/res.zip"
	"$_bo_bt/zipalign" -p -f 4 "$_bo_w/unsigned.apk" "$_bo_w/aligned.apk"
	if [ -n "$KEYSTORE" ]; then
		[ -n "${ANTUMBRA_OVERLAY_KS_PASS:-}" ] || die "set ANTUMBRA_OVERLAY_KS_PASS for --overlay-keystore"
		_bo_ks=$KEYSTORE
	else
		command -v keytool >/dev/null 2>&1 || die "keytool (Java) is needed to sign the overlay"
		_bo_ks=$_bo_w/ephemeral.p12
		ANTUMBRA_OVERLAY_KS_PASS=$(od -An -N 24 -tx1 /dev/urandom | tr -d ' \n')
		export ANTUMBRA_OVERLAY_KS_PASS
		keytool -genkeypair -keystore "$_bo_ks" -storetype PKCS12 -storepass:env ANTUMBRA_OVERLAY_KS_PASS \
			-alias antumbra -keyalg RSA -keysize 3072 -validity 36500 \
			-dname 'CN=Antumbra connectivity overlay' >/dev/null 2>&1 || die "keytool failed"
	fi
	export ANTUMBRA_OVERLAY_KS_PASS
	# RSA signatures (PKCS#1 v1.5) are deterministic: the same key gives
	# the same APK.
	"$_bo_bt/apksigner" sign --ks "$_bo_ks" --ks-key-alias antumbra \
		--ks-pass env:ANTUMBRA_OVERLAY_KS_PASS --v1-signing-enabled false \
		--v2-signing-enabled true --v3-signing-enabled true --v4-signing-enabled false \
		--out "$1" "$_bo_w/aligned.apk"
	"$_bo_bt/apksigner" verify "$1" >/dev/null
	rm -f "$_bo_w/ephemeral.p12"
}

# --- 3. The module tree ----------------------------------------------------------------

if [ -n "$FROM_ZIP" ]; then
	# Exactly the zip's files: Magisk's installer unpacks the same, and
	# customize.sh checks them against SHA256SUMS before it does anything.
	say "unpacking $FROM_ZIP"
	mkdir -p "$STAGE"
	if command -v unzip >/dev/null 2>&1; then
		unzip -q "$FROM_ZIP" -d "$STAGE" || die "cannot unpack $FROM_ZIP"
	else
		python3 -I -m zipfile -e "$FROM_ZIP" "$STAGE" || die "cannot unpack $FROM_ZIP"
	fi
	if [ ! -f "$STAGE/module.prop" ] || [ ! -f "$STAGE/SHA256SUMS" ]; then
		die "$FROM_ZIP is not an Antumbra module zip"
	fi
	find "$STAGE" -type d -exec chmod 0755 {} +
	find "$STAGE" -type f -exec chmod 0644 {} +
	chmod 0755 "$STAGE"/*.sh
	VERSION=$(sed -n 's/^version=//p' "$STAGE/module.prop")
else
# The tree from the checkout and the other parts' outputs (to the matching
# 'fi' after SHA256SUMS).
say "staging module $VERSION for: $ABIS"
mkdir -p "$STAGE/bin" "$STAGE/lib" "$STAGE/etc" "$STAGE/lists" "$STAGE/META-INF/com/google/android"
for f in customize.sh post-fs-data.sh service.sh uninstall.sh; do
	cp "$HERE/$f" "$STAGE/$f"
done
for f in antumbra.sh torctl.sh settings.conf emu-install.sh; do
	cp "$HERE/lib/$f" "$STAGE/lib/$f"
done
cp "$HERE/META-INF/com/google/android/update-binary" "$HERE/META-INF/com/google/android/updater-script" \
	"$STAGE/META-INF/com/google/android/"
sed "s/^version=.*/version=$VERSION/" "$HERE/module.prop" >"$STAGE/module.prop"
cp "$FIREWALL" "$STAGE/bin/antumbra-fw"
sh "$ANDROID_DIR/tor/render-torrc.sh" /data/adb/antumbra "$ANDROID_DIR/tor/torrc.in" >"$STAGE/etc/torrc"

# The block list: the DNS filter's own check when it can run here.
HOSTDNS=$DNS_DIR/x86_64/antumbra-dnsfilter
if [ "$(uname -s)-$(uname -m)" = Linux-x86_64 ] && [ -x "$HOSTDNS" ]; then
	"$HOSTDNS" -check-list "$BLOCKLIST" >&2 || die "the block list does not verify"
else
	head -n 1 "$BLOCKLIST" | grep -q '^# antumbra-dnsfilter block list' || die "$BLOCKLIST is not a block list"
fi
cp "$BLOCKLIST" "$STAGE/lists/dnsfilter.list"
[ -z "$DOH" ] || cp "$DOH" "$STAGE/lists/doh-ipv4.txt"

for abi in $ABIS; do
	mkdir -p "$STAGE/bin/$abi"
	cp "$TOR_DIR/$abi/tor" "$STAGE/bin/$abi/tor"
	cp "$DNS_DIR/$abi/antumbra-dnsfilter" "$STAGE/bin/$abi/antumbra-dnsfilter"
	if [ -n "$HELPER_DIR" ]; then
		cp "$HELPER_DIR/$abi/antumbra-run" "$STAGE/bin/$abi/antumbra-run"
	else
		build_helper "$abi" "$STAGE/bin/$abi/antumbra-run"
	fi
	[ -z "$LYRE_DIR" ] || cp "$LYRE_DIR/$abi/lyrebird" "$STAGE/bin/$abi/lyrebird"
done

if [ "$OVERLAY" = 1 ]; then
	mkdir -p "$STAGE/system/product/overlay"
	if build_overlay "$STAGE/system/product/overlay/AntumbraConnectivity.apk"; then
		say "overlay: system/product/overlay/AntumbraConnectivity.apk"
	else
		die "the overlay needs aapt2, zipalign and apksigner (build-tools) and platforms;android-36 in $SDK, or --no-overlay"
	fi
elif [ "$EMULATOR" = 1 ]; then
	say "overlay: left out on the emulator (nothing mounts system/ there)"
fi

cat >"$STAGE/NOTICE" <<EOF
Antumbra module $VERSION

The Antumbra scripts and antumbra-run are GPL-3.0-or-later.

Programs and data built by the other Antumbra parts, from pinned upstream
sources (see antumbra/android/*/README.md and sources.lock):
  bin/*/tor                 tor (BSD-3-Clause; built with --enable-gpl, so
                            GPL-3.0), statically linked with OpenSSL
                            (Apache-2.0), libevent (BSD-3-Clause) and zlib
                            (Zlib)
  bin/*/antumbra-dnsfilter  GPL-3.0-or-later, with golang.org/x/net
                            (BSD-3-Clause) and the Go runtime (BSD-3-Clause)
  bin/*/lyrebird            if present: BSD-2-Clause and BSD-3-Clause
  lists/dnsfilter.list      compiled from HaGeZi's lists (GPL-3.0) and
                            Antumbra's own; its header names every source
  lists/doh-ipv4.txt        from HaGeZi's DoH server list (GPL-3.0)
EOF

# Modes: everything 0644, directories and programs 0755. customize.sh sets
# them again on the device.
find "$STAGE" -type d -exec chmod 0755 {} +
find "$STAGE" -type f -exec chmod 0644 {} +
chmod 0755 "$STAGE"/bin/*/* "$STAGE/bin/antumbra-fw" "$STAGE"/*.sh \
	"$STAGE/META-INF/com/google/android/update-binary"

# SHA256SUMS over everything Magisk unpacks into the module directory
# (it leaves META-INF out); customize.sh checks it before anything else.
(
	cd "$STAGE"
	find . -type f ! -path './META-INF/*' | sed 's|^\./||' | sort |
		while IFS= read -r f; do sha256sum "$f"; done >"$WORK/SHA256SUMS"
)
mv "$WORK/SHA256SUMS" "$STAGE/SHA256SUMS"
find "$STAGE" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
fi # --zip or the checkout
[ -z "$STAGE_KEEP" ] || { cp -a "$STAGE" "$STAGE_KEEP" && say "module tree: $STAGE_KEEP"; }

# --- 4a. The zip -------------------------------------------------------------------------

if [ "$EMULATOR" = 0 ]; then
	command -v zip >/dev/null 2>&1 || die "zip is needed"
	rm -f "$OUT"
	(cd "$STAGE" && find . -type f | sed 's|^\./||' | sort | zip -X -D -q -9 "$WORK/module.zip" -@)
	mv "$WORK/module.zip" "$OUT"
	say "wrote $OUT"
	sha256sum "$OUT" | sed 's|  .*/|  |'
	exit 0
fi

# --- 4b. The emulator --------------------------------------------------------------------
#
# Google's 'default' emulator image has no Magisk, so nothing runs the
# module's scripts at boot. This does what Magisk would do, in the same
# order, after boot:
#   1. adb root, push the tree, install it (lib/emu-install.sh sources
#      customize.sh as Magisk's installer would);
#   2. stop the framework (toolbox 'stop': netd, surfaceflinger,
#      audioserver and the zygotes, so system_server too), run
#      post-fs-data.sh, and start them again, so that netd and Wi-Fi start
#      after the firewall is armed and over the tmpfs stores, as on a real
#      boot (--no-restart skips the stop and start);
#   3. start service.sh in the background, detached from adb;
#   4. wait until antumbra.fw.armed is set, and print the status.
# shellcheck disable=SC2086 # ADB may carry -s SERIAL
emu() { $ADB "$@"; }

say "emulator: adb root"
emu root >/dev/null
emu wait-for-device
[ "$(emu shell id -u | tr -d '\r')" = 0 ] || die "adb root did not give a root shell (needs the 'default' or 'google_apis' image)"
# $STAGE is a directory named "antumbra": it arrives as /data/local/tmp/antumbra.
emu shell rm -rf /data/local/tmp/antumbra
emu push "$STAGE" /data/local/tmp/ >/dev/null || die "adb push failed"
say "emulator: installing"
emu shell sh /data/local/tmp/antumbra/lib/emu-install.sh /data/local/tmp/antumbra ||
	die "installation failed"
emu shell rm -rf /data/local/tmp/antumbra
MD=/data/adb/modules/antumbra
if [ "$RESTART" = 1 ]; then
	say "emulator: stop framework, post-fs-data.sh, start framework"
	emu shell "stop; sh $MD/post-fs-data.sh; start"
	emu wait-for-device
else
	say "emulator: post-fs-data.sh"
	emu shell sh "$MD/post-fs-data.sh"
fi
say "emulator: service.sh (in the background)"
emu shell "setsid sh $MD/service.sh </dev/null >/dev/null 2>&1 &"
i=0
while [ "$i" -lt 90 ]; do
	armed=$(emu shell getprop antumbra.fw.armed | tr -d '\r')
	[ -n "$armed" ] && break
	sleep 2
	i=$((i + 1))
done
emu shell cat /data/adb/antumbra/log/module.log >&2 || true
[ -n "${armed:-}" ] || die "antumbra.fw.armed was not set within 3 minutes"
say "emulator: antumbra.fw.armed=$armed"
emu shell "ANTUMBRA_DIR=/data/adb/antumbra/state/module/fw sh $MD/bin/antumbra-fw status" >&2 || true
