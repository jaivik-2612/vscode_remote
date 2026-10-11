# shellcheck shell=sh source-path=SCRIPTDIR
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Antumbra module: install the module on the CI emulator as Magisk would,
# without Magisk.
#
# Usage (as root, on the device): sh emu-install.sh SOURCE_DIR
#
# The emulator's 'default' system image gives a root shell with 'adb root'
# but has no Magisk. This copies the unpacked module from SOURCE_DIR to
# /data/adb/modules/antumbra, applies Magisk's default permissions and
# labels, and sources customize.sh with the functions and variables
# Magisk's installer provides. build-module.sh --emulator runs it, and then
# runs post-fs-data.sh and service.sh by hand.
set -u

SRC=${1:?usage: emu-install.sh SOURCE_DIR}
# As in Magisk: the new version is prepared in modules_update while the
# installed one (if any) stays in place, then takes its place.
MODPATH=/data/adb/modules_update/antumbra
FINAL=/data/adb/modules/antumbra
TMPDIR=/data/local/tmp/antumbra-tmp
# The variables Magisk's installer gives customize.sh.
# shellcheck disable=SC2034
ZIPFILE=
# shellcheck disable=SC2034
BOOTMODE=true
# shellcheck disable=SC2034
MAGISK_VER=none
# shellcheck disable=SC2034
MAGISK_VER_CODE=0
# shellcheck disable=SC2034
API=$(getprop ro.build.version.sdk)
# shellcheck disable=SC2034
case $(getprop ro.product.cpu.abi) in
arm64-v8a) ARCH=arm64 ;;
x86_64) ARCH=x64 ;;
*) ARCH=$(getprop ro.product.cpu.abi) ;;
esac
# shellcheck disable=SC2034
IS64BIT=true

ui_print() { echo "$1"; }
abort() {
	echo "$1" >&2
	exit 1
}
set_perm() {
	chown "$2:$3" "$1" || return 1
	chmod "$4" "$1" || return 1
	chcon "${5:-u:object_r:system_file:s0}" "$1" 2>/dev/null
	return 0
}
set_perm_recursive() {
	find "$1" -type d | while IFS= read -r _d; do
		set_perm "$_d" "$2" "$3" "$4" "${6-}"
	done
	find "$1" -type f | while IFS= read -r _f; do
		set_perm "$_f" "$2" "$3" "$5" "${6-}"
	done
}

[ "$(id -u)" = 0 ] || abort "! emu-install.sh must run as root (adb root)"
[ -f "$SRC/module.prop" ] || abort "! $SRC is not an unpacked Antumbra module"

# Magisk creates /data/adb (0700) and /data/adb/modules on its first boot.
mkdir -p /data/adb/modules /data/adb/modules_update
chmod 0700 /data/adb
restorecon /data/adb 2>/dev/null
mkdir -p "$TMPDIR"

rm -rf "$MODPATH"
mkdir -p "$MODPATH"
cp -R "$SRC/." "$MODPATH/" || abort "! cannot copy the module"
set_perm_recursive "$MODPATH" 0 0 0755 0644
# shellcheck source=../customize.sh
. "$MODPATH/customize.sh"
# Magisk's installer removes these after customize.sh.
rm -f "$MODPATH/customize.sh" "$MODPATH/README.md"
rm -rf "$TMPDIR"

rm -rf "$FINAL"
mv "$MODPATH" "$FINAL" || abort "! cannot move the module to $FINAL"
rmdir /data/adb/modules_update 2>/dev/null
ui_print "- Installed in $FINAL"
