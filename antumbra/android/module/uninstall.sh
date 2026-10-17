#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Antumbra module: removal.
#
# Magisk runs this script in two situations:
#   - early in the boot after the module was marked for removal (the
#     post-fs-data stage): this module's other scripts do not run in that
#     boot, and system_server does not exist yet, so Settings cannot be
#     changed;
#   - at once, while Android runs, when Magisk itself is uninstalled; the
#     module's service.sh is still running then and is stopped first.
# It puts back the Settings.Global values recorded at installation
# (settings.orig, which an update completes with the keys a newer version
# added; a value of "null" means the key was not set, so it is deleted).
# In the first case it leaves a one-time script in /data/adb/service.d
# that does this once boot has completed, then deletes itself and its
# data.
#
# Saved Wi-Fi networks are not restored: there are none on flash. Mobile
# data stays off for the SIMs Android knew (mobile_data<subId>); switch it
# on in Settings. The cell radio comes back at the next start (or when
# airplane mode is switched on and off): enable_cellular_on_boot and
# airplane_mode_radios are among the values put back. It also deletes the
# early arm script in /data/adb/post-fs-data.d.

umask 022
MODDIR=${0%/*}
RESTORE_CONF=/data/adb/antumbra-restore.conf
RESTORE_SCRIPT=/data/adb/service.d/antumbra-restore.sh

if [ -f "$MODDIR/settings.orig" ]; then
	cp -f "$MODDIR/settings.orig" "$RESTORE_CONF"
else
	# No record (installed from recovery): back to Android's defaults. For
	# airplane_mode_radios that is a value, not an unset key (Bluetooth
	# treats an unset list as one without Bluetooth).
	sed -n -e 's/^lineage://' -e 's/^phone://' -e 's/^cell://' -e 's/^\([a-z0-9_]*\)=.*/\1=null/p' \
		"$MODDIR/lib/settings.conf" |
		sed 's/^airplane_mode_radios=null$/airplane_mode_radios=cell,bluetooth,uwb,wifi,wimax/' >"$RESTORE_CONF"
fi
chmod 0600 "$RESTORE_CONF"

mkdir -p /data/adb/service.d
cat >"$RESTORE_SCRIPT" <<'EOF'
#!/system/bin/sh
# Antumbra: put back the Settings.Global values the Antumbra module had
# changed. Left by the module's uninstall.sh; deletes itself when done.
umask 022
conf=/data/adb/antumbra-restore.conf
[ -f "$conf" ] || { rm -f "$0"; exit 0; }
i=0
until [ "$(getprop sys.boot_completed)" = 1 ] &&
	/system/bin/settings get global airplane_mode_on >/dev/null 2>&1; do
	i=$((i + 1))
	[ "$i" -gt 300 ] && exit 1
	sleep 2
done
while IFS= read -r line || [ -n "$line" ]; do
	key=${line%%=*}
	value=${line#*=}
	case $key in '' | *[!a-z0-9_]*) continue ;; esac
	if [ "$value" = null ]; then
		/system/bin/settings delete global "$key" >/dev/null 2>&1
	else
		/system/bin/settings put global "$key" "$value" >/dev/null 2>&1
	fi
done <"$conf"
rm -f "$conf" "$0"
EOF
chmod 0755 "$RESTORE_SCRIPT"

# While Android runs, do it now (the script then removes itself). The
# module's service.sh still runs then, and its cell radio watch would write
# enable_cellular_on_boot, mobile_data_always_on and airplane_mode_radios
# again at its next turn: it is stopped first (only if that process
# ID is this module's service.sh). tor and the DNS filter keep running
# until the restart; the firewall stays in place.
if [ "$(getprop sys.boot_completed)" = 1 ]; then
	svc=$(cat /data/adb/antumbra/state/module/service.lock/pid 2>/dev/null)
	case $svc in
	'' | *[!0-9]*) ;;
	*)
		if tr '\0' ' ' <"/proc/$svc/cmdline" 2>/dev/null | grep -q -F "$MODDIR/service.sh"; then
			kill "$svc" 2>/dev/null
		fi
		;;
	esac
	sh "$RESTORE_SCRIPT"
fi

# The property and the empty mount point on flash. (/data/adb/antumbra is a
# tmpfs only while the module runs; in RAM it disappears at shutdown.)
if command -v resetprop >/dev/null 2>&1; then
	resetprop --delete antumbra.fw.armed >/dev/null 2>&1
fi
if ! grep -q ' /data/adb/antumbra ' /proc/mounts 2>/dev/null; then
	rmdir /data/adb/antumbra 2>/dev/null
fi
rm -f /data/adb/antumbra-force /data/adb/post-fs-data.d/antumbra-arm.sh
exit 0
