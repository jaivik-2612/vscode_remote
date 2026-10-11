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

umask 022

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
	sed -n -e 's/^lineage://' -e 's/^phone://' -e 's/^\([a-z0-9_]*\)=.*/\1/p' "$MODPATH/lib/settings.conf" |
		while IFS= read -r k; do
			printf '%s=%s\n' "$k" "$(/system/bin/settings get global "$k" 2>/dev/null)"
		done >"$MODPATH/settings.orig"
fi
[ -f "$MODPATH/settings.orig" ] && set_perm "$MODPATH/settings.orig" 0 0 0600

# 9. Arm early, and also when the module is disabled. Magisk runs the
# scripts in /data/adb/post-fs-data.d before any module's post-fs-data.sh
# (they share one 40-second budget, in directory order), and runs them
# even when this module carries a 'disable' flag; it runs neither in Magisk
# Safe Mode. This one only arms the firewall (loopback only), so a boot in
# which the module is disabled has no network at all; removing the module
# deletes it. Through it, a slow module or script that comes first in the
# directory order cannot delay the arming either.
ANTUMBRA_EARLY=/data/adb/post-fs-data.d/antumbra-arm.sh
mkdir -p /data/adb/post-fs-data.d
cat >"$ANTUMBRA_EARLY" <<'EOF'
#!/system/bin/sh
# Antumbra: arm the firewall (loopback only) before any Magisk module runs,
# and also in a boot where the Antumbra module is disabled. Written by the
# module's customize.sh; its uninstall.sh deletes it.
umask 022
fw=/data/adb/modules/antumbra/bin/antumbra-fw
[ -f "$fw" ] || exit 0
# Being removed in this boot (Magisk app, Remove): leave it to stock.
[ -e /data/adb/modules/antumbra/remove ] && exit 0
mkdir -p /dev/antumbra-fw
ANTUMBRA_DIR=/dev/antumbra-fw "$fw" arm >/dev/null 2>/dev/antumbra-fw/arm-early.log
exit 0
EOF
set_perm "$ANTUMBRA_EARLY" 0 0 0755 u:object_r:adb_data_file:s0
ui_print "- Early arming: $ANTUMBRA_EARLY"

# 10. Other boot scripts in the same window: each one that runs before this
# module's post-fs-data.sh delays the rest of its work (the RAM stores,
# the sysctls), and a slow one can use up Magisk's 40 seconds, after which
# the boot goes on without waiting for this module.
ANTUMBRA_OTHERS=
for d in /data/adb/modules/*/; do
	n=${d%/}
	n=${n##*/}
	[ "$n" = antumbra ] && continue
	[ -f "$d/post-fs-data.sh" ] && [ ! -e "$d/disable" ] && ANTUMBRA_OTHERS="$ANTUMBRA_OTHERS $n"
done
for f in /data/adb/post-fs-data.d/*; do
	[ -f "$f" ] && [ "$f" != "$ANTUMBRA_EARLY" ] && ANTUMBRA_OTHERS="$ANTUMBRA_OTHERS post-fs-data.d/${f##*/}"
done
if [ -n "$ANTUMBRA_OTHERS" ]; then
	ui_print "! Other boot scripts share Magisk's post-fs-data window:"
	ui_print "! $ANTUMBRA_OTHERS"
	ui_print "! Antumbra's boot order assumes it runs alone: remove them unless you need them."
fi

ui_print "- At the next start, every saved Wi-Fi network is forgotten:"
ui_print "  from then on, Wi-Fi networks are kept in memory only."
ui_print "- The Antumbra Welcome app must be the device owner."
ui_print "  Until its Start button is pressed, nothing but tor's own"
ui_print "  checks run, and tor stays offline."
