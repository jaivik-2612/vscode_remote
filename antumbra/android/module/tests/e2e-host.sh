#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Antumbra module: end-to-end test of the module's boot scripts on a Linux
# host, with the real firewall, the real tor, the real DNS filter and the
# real antumbra-run, but without Android.
#
# Usage (as root):
#   tests/e2e-host.sh --tor-bin FILE --dnsfilter-bin FILE --blocklist FILE \
#       --toybox FILE --mksh FILE --busybox FILE [--scenarios "LIST"] [--keep]
#
#   --tor-bin        tor for this host: the static x86_64 copy that
#                    tor/build-tor.sh leaves in WORK/x86_64/tor-hostcheck
#   --dnsfilter-bin  dnsfilter/build.sh's x86_64 antumbra-dnsfilter (static)
#   --blocklist      a compiled block list (dnsfilter.list)
#   --toybox         toybox built for this host from Android 16's source
#                    (AOSP external/toybox, android16-release), with tr
#   --mksh           mksh built for this host from Android 16's source
#                    (AOSP external/mksh)
#   --busybox        busybox with FEATURE_SH_STANDALONE, standing in for
#                    Magisk's
#   --scenarios      default: "bridges:busybox direct:mksh offline:mksh
#                    pt:busybox badbridges:mksh cell:busybox"
#
# tests/build-test-tools.sh builds --toybox, --mksh and --busybox from
# pinned sources.
#
# Each scenario gets a new sandbox: mount, network and PID namespaces, and
# a chroot into an overlay of the host's root file system whose upper layer
# holds /system/bin (Android's toybox and mksh, the host's iptables-legacy
# and ip, and the stand-ins in tests/fakes), /data (a Wi-Fi store and a
# NetworkStack database to be forgotten) and the staged module; the
# stand-ins for dumpsys and cmd play Telecom, the telephony registry and
# airplane mode (the phone process's part included) from files the test
# writes, and a file bound over /proc/uptime lets the test move the
# module's clock on (the cell radio's 5-minute holds). Nothing in
# it reaches the host: the overlay's upper layer is in a temporary
# directory, and the network namespace has only loopback and one end of a
# veth pair (with a default route through the other end). The scripts run
# with umask 0, as adb's shell has on the CI emulator. tests/e2e-inner.sh
# installs the module, runs the early arm script, post-fs-data.sh and
# service.sh, and plays the scenario:
#   bridges     plain bridges, MAC "keep"; Welcome restarting; tor, the
#               filter and the firewall broken and repaired; shutdown puts
#               the fail-safe Settings back
#   direct      on a LineageOS hotdog (by its properties): an app takes
#               127.0.0.1:9040 before Start (firewall back to armed, tor's
#               network held off until the port is free); mobile data off
#               for every SIM; no bridges
#   offline     an update over a record made before the cell radio work
#               (the keys it lacks added); tor stays off; an app takes the
#               filter's 5335 while the filter restarts; then uninstall.sh,
#               during a boot and while Android runs (service.sh stopped
#               first), puts the Settings back and nothing writes them again
#   pt          obfs4 bridges without lyrebird: refused, network off; then,
#               during a call on the cell radio, iptables broken: the
#               firewall reports open, Wi-Fi and mobile data go off at once,
#               the cell radio (airplane mode) and Bluetooth only 5 minutes
#               after the call; shutdown stores airplane mode off
#   badbridges  Start from a Welcome that is not the device owner: ignored;
#               then a bridge line with a quote: refused, network off
#   cell        on a LineageOS hotdog: the cell radio switched on by
#               something else and switched off again, after each hold:
#               5 minutes after a switch-on, a ringing, active and held
#               call, emergency callback mode (property, calls, texts), an
#               unreadable state, a call between two looks, with
#               enable_cellular_on_boot kept at 1 while each hold lasts and
#               0 again before the switch-off; shutdown during a call leaves
#               airplane mode as it is
#
# Every scenario also checks the cell radio's stored values, the narrowed
# airplane-mode list, cell=off in the session record and that the module
# never switches the radio on.
#
# What it cannot show: Android itself (SELinux, netd, Magisk's timing,
# Welcome, the framework restart). The emulator job does that.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
MODULE=$(cd "$HERE/.." && pwd)

TOR_BIN='' DNS_BIN='' BLOCKLIST='' TOYBOX='' MKSH='' BUSYBOX='' KEEP=0
SCENARIOS='bridges:busybox direct:mksh offline:mksh pt:busybox badbridges:mksh cell:busybox'
while [ $# -gt 0 ]; do
	case $1 in
	--tor-bin) TOR_BIN=$2; shift 2 ;;
	--dnsfilter-bin) DNS_BIN=$2; shift 2 ;;
	--blocklist) BLOCKLIST=$2; shift 2 ;;
	--toybox) TOYBOX=$2; shift 2 ;;
	--mksh) MKSH=$2; shift 2 ;;
	--busybox) BUSYBOX=$2; shift 2 ;;
	--scenarios) SCENARIOS=$2; shift 2 ;;
	--keep) KEEP=1; shift ;;
	*) echo "e2e-host.sh: unknown argument $1" >&2; exit 2 ;;
	esac
done
for f in "$TOR_BIN" "$DNS_BIN" "$BLOCKLIST" "$TOYBOX" "$MKSH" "$BUSYBOX"; do
	if [ -z "$f" ] || [ ! -f "$f" ]; then
		echo "e2e-host.sh: missing input '$f' (see the usage at the top)" >&2
		exit 2
	fi
done
[ "$(id -u)" = 0 ] || { echo "e2e-host.sh: needs root (namespaces, mounts, iptables)" >&2; exit 2; }
for t in unshare chroot mknod setpriv python3 iptables-legacy ip6tables-legacy iptables-legacy-restore \
	ip6tables-legacy-restore ip cc; do
	command -v "$t" >/dev/null 2>&1 || { echo "e2e-host.sh: needs $t" >&2; exit 2; }
done

W=$(mktemp -d "${TMPDIR:-/tmp}/antumbra-e2e.XXXXXX")
cleanup() {
	if [ "$KEEP" = 1 ]; then
		echo "kept: $W"
	else
		rm -rf "$W"
	fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# --- The module, staged for x86_64 with the host's binaries --------------------
mkdir -p "$W/helper/x86_64" "$W/tor/x86_64" "$W/dns/x86_64"
cc -O2 -Wall -Wextra -Werror -fPIE -pie -o "$W/helper/x86_64/antumbra-run" "$MODULE/helper/antumbra-run.c" ||
	exit 2
cp "$TOR_BIN" "$W/tor/x86_64/tor"
cp "$DNS_BIN" "$W/dns/x86_64/antumbra-dnsfilter"
sh "$MODULE/build-module.sh" --tor "$W/tor" --dnsfilter "$W/dns" --blocklist "$BLOCKLIST" \
	--abi x86_64 --helper "$W/helper" --no-overlay --stage "$W/stage" --out "$W/module.zip" >"$W/build.log" 2>&1 || {
	cat "$W/build.log"
	exit 2
}

IP6_BACKEND=legacy
if ! unshare -n ip6tables-legacy -w -t mangle -S >/dev/null 2>&1; then
	command -v ip6tables-nft >/dev/null 2>&1 || { echo "e2e-host.sh: no usable ip6tables" >&2; exit 2; }
	IP6_BACKEND=nft
	echo "note: this kernel has no legacy IPv6 tables; IPv6 rules use ip6tables-nft"
fi

# populate UPPER SCENARIO: the sandbox's own files.
populate() {
	U=$1
	mkdir -p "$U/system/bin" "$U/magisk-bin" "$U/antumbra-test" "$U/data/adb" "$U/data/local/tmp" \
		"$U/data/misc/apexdata/com.android.wifi" "$U/data/user_de/0/com.android.networkstack/databases"
	cp "$TOYBOX" "$U/system/bin/toybox"
	cp "$MKSH" "$U/system/bin/sh"
	for a in $("$TOYBOX"); do
		case $a in sh | toybox | getprop | setprop | ip | iptables* | ip6tables*) continue ;; esac
		ln -s toybox "$U/system/bin/$a"
	done
	ln -s /usr/sbin/ip "$U/system/bin/ip"
	# Android's iptables is the legacy one. Some host kernels have no legacy
	# IPv6 tables; then IPv6 uses the nf_tables tools, as the firewall's own
	# sandbox test does.
	for t in iptables ip6tables; do
		b=legacy
		[ "$t" = ip6tables ] && [ "$IP6_BACKEND" = nft ] && b=nft
		ln -s "/usr/sbin/$t-$b" "$U/system/bin/$t"
		ln -s "/usr/sbin/$t-$b-restore" "$U/system/bin/$t-restore"
		ln -s "/usr/sbin/$t-$b-save" "$U/system/bin/$t-save"
	done
	for f in getprop setprop settings cmd content dumpsys; do
		cp "$HERE/fakes/$f" "$U/system/bin/$f"
	done
	cp "$HERE/fakes/resetprop" "$U/magisk-bin/resetprop"
	cp "$BUSYBOX" "$U/magisk-bin/busybox"
	chmod 0755 "$U"/system/bin/* "$U"/magisk-bin/* 2>/dev/null
	cp -a "$W/stage" "$U/antumbra-test/stage"
	cp "$HERE/probe.py" "$HERE/e2e-inner.sh" "$U/antumbra-test/"
	# The phone (two SIM slots) or the emulator (one).
	case $2 in
	direct | cell)
		printf 'ro.product.device=hotdog\nro.lineage.device=hotdog\nro.lineage.version=23.2-20261009-NIGHTLY-hotdog\nro.hardware=qcom\n' >"$U/antumbra-test/props"
		echo 2 >"$U/antumbra-test/phones"
		;;
	*)
		printf 'ro.boot.qemu=1\nro.hardware=ranchu\nro.product.device=emu64x\n' >"$U/antumbra-test/props"
		echo 1 >"$U/antumbra-test/phones"
		;;
	esac
	printf 'ro.build.version.sdk=36\nro.product.cpu.abi=x86_64\ngsm.sim.state=LOADED,ABSENT\n' >>"$U/antumbra-test/props"
	# Android's defaults for airplane mode's radios and cell_on; no
	# enable_cellular_on_boot yet (Android's default: on).
	printf 'airplane_mode_on=0\nntp_server=time.android.com\nprivate_dns_mode=opportunistic\nmobile_data2=1\n' >"$U/antumbra-test/settings"
	printf 'airplane_mode_radios=cell,bluetooth,uwb,wifi,wimax\ncell_on=1\n' >>"$U/antumbra-test/settings"
	# The cell radio off since power-on; no call in this boot yet.
	echo 0 >"$U/antumbra-test/radio"
	printf '%s\n' 'CallsManager: ' '  mCalls: ' '  mCallAudioManager: ' 'PhoneAccountRegistrar: ' 'Analytics:' \
		'  Hardware Version: ' '  Past analytics dumps: ' 'Flag Configurations: ' >"$U/antumbra-test/telecom"
	# Welcome is the device owner; two SIMs known to Android.
	printf 'User  0: admin=org.antumbra.welcome/.AdminReceiver,DeviceOwner\n' >"$U/antumbra-test/owners"
	printf '1\n3\n' >"$U/antumbra-test/siminfo"
	: >"$U/antumbra-test/settings.log"
	: >"$U/antumbra-test/cmd.log"
	: >"$U/antumbra-test/dumpsys.log"
	: >"$U/antumbra-test/resetprop.log"
	# What Android left on flash: a saved network and a lease memory.
	echo '<WifiConfigStoreData><NetworkList><Network>home</Network></NetworkList></WifiConfigStoreData>' \
		>"$U/data/misc/apexdata/com.android.wifi/WifiConfigStore.xml"
	chown -R 0:1000 "$U/data/misc/apexdata/com.android.wifi"
	chmod 0771 "$U/data/misc/apexdata/com.android.wifi"
	echo lease >"$U/data/user_de/0/com.android.networkstack/databases/IpMemoryStoreV2.db"
	chown -R 1073:1073 "$U/data/user_de/0/com.android.networkstack"
	chmod 0771 "$U/data/user_de/0/com.android.networkstack/databases"
	chmod 0700 "$U/data/adb"
}

total=0
for item in $SCENARIOS; do
	scen=${item%%:*}
	shell=${item#*:}
	R=$W/$scen
	mkdir -p "$R/upper" "$R/work" "$R/merged"
	populate "$R/upper" "$scen"
	cat >"$R/enter.sh" <<EOF
set -e
mount --make-rprivate /
mount -t overlay overlay -o lowerdir=/,upperdir=$R/upper,workdir=$R/work $R/merged
mount -t proc proc $R/merged/proc
mount -t sysfs sysfs $R/merged/sys
mount -t tmpfs -o mode=0755,nosuid tmpfs $R/merged/dev
for n in null:1:3 zero:1:5 full:1:7 random:1:8 urandom:1:9 tty:5:0; do
	mknod -m 0666 $R/merged/dev/\${n%%:*} c \$(echo \$n | cut -d: -f2) \$(echo \$n | cut -d: -f3)
done
ln -s /proc/self/fd $R/merged/dev/fd
mount -t tmpfs -o mode=1777 tmpfs $R/merged/tmp
exec chroot $R/merged /system/bin/sh /antumbra-test/e2e-inner.sh $shell $scen
EOF
	unshare -m -n -p -f --kill-child sh "$R/enter.sh"
	rc=$?
	# The saved network and the lease memory are gone from "flash" (the
	# overlay's upper layer), not only hidden under a tmpfs.
	if [ -e "$R/upper/data/misc/apexdata/com.android.wifi/WifiConfigStore.xml" ]; then
		echo "  FAIL  the saved network is still on flash"
		rc=1
	else
		echo "  PASS  the saved network is gone from flash"
	fi
	if [ -e "$R/upper/data/user_de/0/com.android.networkstack/databases/IpMemoryStoreV2.db" ]; then
		echo "  FAIL  the lease memory is still on flash"
		rc=1
	else
		echo "  PASS  the lease memory is gone from flash"
	fi
	if [ -n "$(find "$R/upper/data/adb/antumbra" -mindepth 1 2>/dev/null)" ]; then
		echo "  FAIL  something was written under /data/adb/antumbra on flash"
		rc=1
	else
		echo "  PASS  nothing of the runtime directory reached flash"
	fi
	[ "$rc" -eq 0 ] || total=$((total + 1))
done
echo "== $total scenario(s) failed"
[ "$total" -eq 0 ]
