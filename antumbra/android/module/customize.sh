# shellcheck shell=sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Antumbra module: install-time checks and set-up.
#
# Magisk's and KernelSU's installers source this file (it is not executed)
# after unpacking the zip into $MODPATH. They provide ui_print, abort,
# set_perm and set_perm_recursive, and the variables ARCH, API, MODPATH and
# BOOTMODE. It must not call 'exit'. On the CI emulator,
# lib/emu-install.sh provides the same things.
#
# It refuses to install on anything but the OnePlus 7T Pro (hotdog) on
# LineageOS, or the Android emulator, on Android 16, unless ANTUMBRA_FORCE=1
# is in the environment or the file /data/adb/antumbra-force exists (only
# root can create it). That override exists for testing on other devices;
# the firewall and the boot order have not been checked anywhere else.

antumbra_prop() { sed -n "s/^$1=//p" "$MODPATH/module.prop" | head -n 1; }

antumbra_forced() {
	[ "${ANTUMBRA_FORCE:-0}" = 1 ] || [ -f /data/adb/antumbra-force ]
}

# antumbra_require MESSAGE: stop the installation, unless forced.
antumbra_require() {
	if antumbra_forced; then
		ui_print "! $1"
		ui_print "! Installing anyway: ANTUMBRA_FORCE is set."
	else
		abort "! $1"
	fi
}

ui_print "- Antumbra $(antumbra_prop version)"

# 1. CPU: the zip carries arm64-v8a (the phone) and x86_64 (the emulator).
case $ARCH in
arm64) ANTUMBRA_ABI=arm64-v8a ;;
x64) ANTUMBRA_ABI=x86_64 ;;
*) abort "! This CPU ($ARCH) is not supported: only arm64 and x86_64." ;;
esac

# 2. Android 16.
[ "$API" = 36 ] || antumbra_require "Android 16 (API 36) is required; this is API $API."

# 3. The device: the OnePlus 7T Pro, or the Android emulator for CI.
ANTUMBRA_EMULATOR=0
if [ "$(getprop ro.boot.qemu)" = 1 ] || [ "$(getprop ro.kernel.qemu)" = 1 ] ||
	[ "$(getprop ro.hardware)" = ranchu ]; then
	ANTUMBRA_EMULATOR=1
	ui_print "- Device: Android emulator"
elif [ "$(getprop ro.product.device)" = hotdog ] || [ "$(getprop ro.lineage.device)" = hotdog ] ||
	[ "$(getprop ro.product.vendor.device)" = hotdog ]; then
	ui_print "- Device: OnePlus 7T Pro (hotdog)"
else
	antumbra_require "This module is for the OnePlus 7T Pro (hotdog), not '$(getprop ro.product.device)'."
fi

# 4. LineageOS (the emulator runs Google's plain Android image).
if [ "$ANTUMBRA_EMULATOR" = 0 ]; then
	ANTUMBRA_LINEAGE=$(getprop ro.lineage.version)
	if [ -n "$ANTUMBRA_LINEAGE" ]; then
		ui_print "- LineageOS $ANTUMBRA_LINEAGE"
	else
		antumbra_require "LineageOS is required."
	fi
fi

# 5. Every file as it was built (SHA256SUMS is written by build-module.sh).
if [ ! -f "$MODPATH/SHA256SUMS" ]; then
	abort "! SHA256SUMS is missing: this is not a complete Antumbra module."
fi
if ! (cd "$MODPATH" && sha256sum -c SHA256SUMS >/dev/null 2>&1); then
	abort "! Some files differ from SHA256SUMS. Download the module again."
fi
ui_print "- Files checked against SHA256SUMS"

# 6. Keep the programs for this CPU only.
for f in tor antumbra-dnsfilter antumbra-run; do
	[ -f "$MODPATH/bin/$ANTUMBRA_ABI/$f" ] || abort "! bin/$ANTUMBRA_ABI/$f is missing."
done
for f in "$MODPATH/bin/$ANTUMBRA_ABI"/*; do
	mv -f "$f" "$MODPATH/bin/"
done
rm -rf "$MODPATH/bin/arm64-v8a" "$MODPATH/bin/x86_64"

# 7. Permissions: everything root's and read-only, the programs executable.
# Magisk labels module files system_file; the same is done here.
set_perm_recursive "$MODPATH" 0 0 0755 0644
for f in tor antumbra-dnsfilter antumbra-run antumbra-fw lyrebird; do
	[ -f "$MODPATH/bin/$f" ] && set_perm "$MODPATH/bin/$f" 0 0 0755
done

# 8. What uninstall.sh puts back: the Settings values from before the
# first installation. An update keeps the record of the installed version.
ANTUMBRA_OLD=/data/adb/modules/antumbra/settings.orig
if [ -f "$ANTUMBRA_OLD" ]; then
	cp -f "$ANTUMBRA_OLD" "$MODPATH/settings.orig"
elif [ "$BOOTMODE" = true ] && /system/bin/settings get global airplane_mode_on >/dev/null 2>&1; then
	sed -n 's/^\(lineage:\)\{0,1\}\([a-z0-9_]*\)=.*/\2/p' "$MODPATH/lib/settings.conf" |
		while IFS= read -r k; do
			printf '%s=%s\n' "$k" "$(/system/bin/settings get global "$k" 2>/dev/null)"
		done >"$MODPATH/settings.orig"
fi
[ -f "$MODPATH/settings.orig" ] && set_perm "$MODPATH/settings.orig" 0 0 0600

ui_print "- At the next start, every saved Wi-Fi network is forgotten:"
ui_print "  from then on, Wi-Fi networks are kept in memory only."
ui_print "- The Antumbra Welcome app must be the device owner."
ui_print "  Until its Start button is pressed, nothing but tor's own"
ui_print "  checks run, and tor stays offline."
