#!/system/bin/sh
# shellcheck source-path=SCRIPTDIR
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Antumbra module: the post-fs-data stage.
#
# Magisk (and KernelSU) run this script at init's post-fs-data trigger and
# hold the boot until it ends (Magisk lets the boot go on after 40 s).
# /data is mounted and decrypted; netd, zygote and everything that uses the
# network start after it. It must be quick and must not call 'settings',
# 'content', 'cmd' or setprop: system_server does not exist yet.
#
# The order is fixed by the shared contract:
#   1. 'antumbra-fw arm': only loopback traffic can move, IPv4 and IPv6,
#      for every uid, until service.sh loads the full rule set.
#   2. /data/adb/antumbra on a new tmpfs: tor's state, logs, status and the
#      session record live in RAM only.
#   3. Wi-Fi's configuration store on a tmpfs: saved networks never reach
#      flash, so a boot without this module has no network to join.
#   4. NetworkStack's IpMemoryStore (the DHCP lease memory) deleted, and on
#      a tmpfs: a new MAC address is not linked to the old one by asking
#      the router for the previous session's IP address.
#   5. sysctls: IPv6 off, Qualcomm's crash-dump mode off.

MODDIR=${0%/*}

# 1. Arm, before anything else. The firewall's lock goes in /dev (RAM);
# the runtime tmpfs does not exist yet.
mkdir -p /dev/antumbra-fw
ANTUMBRA_DIR=/dev/antumbra-fw "$MODDIR/bin/antumbra-fw" arm >/dev/null 2>/dev/antumbra-fw/arm.log
ARM_RC=$?

LOG_TAG=post-fs-data
# shellcheck source=lib/antumbra.sh
. "$MODDIR/lib/antumbra.sh"

PROBLEMS=
problem() {
	log "PROBLEM: $*"
	PROBLEMS="${PROBLEMS:+$PROBLEMS; }$*"
}

# 2. The runtime directory.
if runtime_setup; then
	cat "$ARMDIR/arm.log" >>"$LOGDIR/firewall.log" 2>/dev/null
else
	echo "antumbra: cannot set up $ANTUMBRA_DIR" >&2
fi
if [ "$ARM_RC" -eq 0 ]; then
	log "firewall armed: only loopback until the full rule set is loaded"
else
	problem "the firewall could not be armed (exit $ARM_RC)"
fi
# Magisk sets /data/adb to 0700 at every boot. tor (uid 2950) and the DNS
# filter (uid 2951) must pass through it to reach their files: allow that
# (x), not listing (r). Apps cannot use it either way: SELinux keeps them
# out of /data/adb.
chmod 0711 /data/adb
# A property left by an earlier run of these scripts (only possible when
# they are started by hand, as on the CI emulator) must not survive.
prop_clear "$FW_PROP"

# tmpfs_over DIR UID GID MODE CONTEXT: forget what is in DIR on flash and
# mount a tmpfs over it with DIR's owner, mode and SELinux label (or the
# ones given, if DIR does not exist yet). Files created in it get the
# directory's label, as on flash, and SELinux lets any file type live on a
# tmpfs ("allow file_type tmpfs:filesystem associate").
tmpfs_over() {
	_t_dir=$1 _t_uid=$2 _t_gid=$3 _t_mode=$4 _t_ctx=$5
	if $TB mountpoint -q "$_t_dir" 2>/dev/null; then
		log "$_t_dir is already a mount point; left as it is"
		return 0
	fi
	if [ -L "$_t_dir" ]; then
		problem "$_t_dir is a symbolic link; not mounted"
		return 1
	fi
	if [ -d "$_t_dir" ]; then
		# shellcheck disable=SC2046 # four words from stat
		set -- $($TB stat -c '%u %g %a %C' "$_t_dir" 2>/dev/null)
		[ $# -eq 4 ] && _t_uid=$1 _t_gid=$2 _t_mode=$3
		case ${4-} in u:object_r:*) _t_ctx=$4 ;; esac
		# What was saved on flash before this boot is deleted, so that a
		# later boot without the module finds nothing either.
		find "$_t_dir" -mindepth 1 -delete 2>/dev/null
	else
		if ! { mkdir -p "$_t_dir" && chown "$_t_uid:$_t_gid" "$_t_dir" && chmod "$_t_mode" "$_t_dir"; }; then
			problem "cannot create $_t_dir"
			return 1
		fi
	fi
	mount -t tmpfs -o "mode=$_t_mode,uid=$_t_uid,gid=$_t_gid,nosuid,nodev,noexec,size=16m" \
		antumbra-ram "$_t_dir" || {
		problem "cannot mount a tmpfs over $_t_dir"
		return 1
	}
	if [ -e /sys/fs/selinux/enforce ]; then
		$TB chcon "$_t_ctx" "$_t_dir" 2>/dev/null
		if [ "$($TB stat -c %C "$_t_dir" 2>/dev/null)" != "$_t_ctx" ]; then
			# Kept mounted: without the label Android cannot save into it,
			# which loses nothing but convenience, while the flash
			# directory underneath would keep what is saved.
			problem "cannot label $_t_dir as $_t_ctx"
			return 1
		fi
	fi
	log "tmpfs over $_t_dir ($_t_uid:$_t_gid $_t_mode $_t_ctx)"
}

# 3. Wi-Fi's shared configuration store: saved networks, their MAC
# settings and Wi-Fi's own settings. init's perform_apex_config creates it
# (root:system 0771) earlier in the same trigger. The per-user store of
# user 0 in device-encrypted storage is covered too; the credential-
# encrypted one (/data/misc_ce/0/...) is still locked at this point and is
# a known gap (README).
tmpfs_over /data/misc/apexdata/com.android.wifi 0 1000 0771 \
	u:object_r:apex_system_server_data_file:s0
if [ -d /data/misc_de/0/apexdata/com.android.wifi ]; then
	tmpfs_over /data/misc_de/0/apexdata/com.android.wifi 0 1000 0771 \
		u:object_r:apex_system_server_data_file:s0
fi

# 4. NetworkStack's IpMemoryStore: IpMemoryStoreV2.db (IpMemoryStore.db
# before Android 12) in NetworkStack's device-encrypted data, keyed by a
# hash of the network that survives reboots. The package is
# com.android.networkstack on LineageOS; the other names are Google's and
# the in-process variant's.
NS_FOUND=0
for ns in com.android.networkstack com.google.android.networkstack \
	com.android.networkstack.inprocess com.google.android.networkstack.inprocess; do
	app=/data/user_de/0/$ns
	if [ ! -d "$app" ] || [ -L "$app" ]; then
		continue
	fi
	NS_FOUND=1
	rm -f "$app"/databases/IpMemoryStore* 2>/dev/null
	# shellcheck disable=SC2046 # four words from stat
	set -- $($TB stat -c '%u %g %a %C' "$app" 2>/dev/null)
	tmpfs_over "$app/databases" "${1:-1073}" "${2:-1073}" 0771 "${4:-u:object_r:radio_data_file:s0}"
done
[ "$NS_FOUND" = 1 ] || log "no NetworkStack data directory yet (first boot?); its DHCP memory is deleted at the next boot"

# 5. sysctls. IPv6 off for every interface that exists and every new one
# ("default"); loopback keeps it, because Android uses ::1. NetworkStack
# switches IPv6 back on for each network it brings up; service.sh switches
# it off again (ipv6_guard), and the firewall drops IPv6 anyway.
write_value /proc/sys/net/ipv6/conf/default/accept_ra 0
write_value /proc/sys/net/ipv6/conf/all/accept_ra 0
write_value /proc/sys/net/ipv6/conf/default/disable_ipv6 1
write_value /proc/sys/net/ipv6/conf/all/disable_ipv6 1
ipv6_sweep
# Qualcomm's crash-dump ("download") mode keeps RAM readable after a crash
# reset. The hotdog kernel is built with CONFIG_QCOM_DLOAD_MODE; this turns
# it off at run time. It cannot switch off the EDL boot mode.
if write_value /sys/module/msm_poweroff/parameters/download_mode 0; then
	log "crash-dump mode off"
fi

printf '%s\n' "$PROBLEMS" >"$PRIV/problem" 2>/dev/null
log "done"
exit 0
