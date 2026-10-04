# Antumbra architecture

Antumbra is an amnesic, Tor-enforcing mobile operating system for the
OnePlus 7T Pro (codename `hotdog`). It takes the design of Tails, the
Amnesic Incognito Live System, and rebuilds it for an arm64 phone on
Debian 13 "trixie" with the Phosh mobile shell.

Tails is a trademark of the Tails project. Antumbra is an independent
derivative and is not endorsed by Tails or by the Tor Project.

This document describes what the repository implements. Hardware facts
come from the fact-checked research summarised in `research-notes.md`;
what still needs a physical phone is listed in section 19 and in
`hardware-validation.md`.

## 1. Goals and non-goals

Goals, in order of priority:

1. **Tor enforcement.** No application can reach the network except
   through Tor. Enforced by the kernel firewall per Unix user, exactly as
   Tails does, not by application settings.
2. **Amnesia.** The root filesystem is read-only; all writes go to RAM
   and vanish on power-off. Memory is zeroed on free. Nothing is written
   to flash unless the user unlocks an encrypted Persistent Storage.
3. **Radio hygiene.** Wi-Fi MAC addresses are randomised per session, the
   hostname and DHCP identity leak nothing, Bluetooth, NFC and GNSS are off
   by default, and the cellular radio never attaches to a network.
4. **Honesty.** The user is told what the OS does and does not protect
   against, in particular that an unlocked bootloader means no verified
   boot.

Non-goals for version 1:

- Telephony (calls, SMS, mobile data). The mainline port has not
  validated any of it, and it is at odds with goal 3.
- Fingerprint unlock (impossible on mainline: the sensor needs TrustZone
  services that no free implementation provides).
- Supporting any device other than the OnePlus 7T Pro HD1913. The
  Indian HD1911 and the T-Mobile HD1925 share the SoC but have never
  booted the complete port.
- Reusing Tails' own build system (live-build, Vagrant, x86-only) or its
  x86 images. Tails states it does not run on ARM or on phones.

## 2. Target hardware and the port we build on

| Item | Fact |
|---|---|
| Device | OnePlus 7T Pro, HD1913 (EU). `fastboot getvar product` reports `msmnile` |
| SoC | Qualcomm SM8150-AC (Snapdragon 855+), Adreno 640, 8/12 GB LPDDR4X, 256 GB UFS 3.0 |
| Display | 1440x3120 AMOLED, DSI/DSC, stable at 60 Hz; 90 Hz has intermittent DSI FIFO errors |
| Wi-Fi / Bluetooth | Qualcomm WCN3990 (`ath10k_snoc`, `hci_uart`/`btqca`) |
| Touch | Samsung S6SY761 |
| Mainline port | `github.com/Sr-0w/hotdog-linux-bringup` (GPL-2.0 tooling), boots from the stock OnePlus A/B bootloader without Halium or kexec |
| Kernel | `gitlab.com/sm8150-mainline/linux` tag `v6.17.0-sm8150` (commit `379d8fe35c7ca685a650bd82fd023af0ea3f0de0`) plus the 27 patches in `aports/device/testing/linux-oneplus-hotdog-mainline617-clean/` at release tag `v0.2.0-alpha.2` |
| Device tree | `qcom/sm8150-oneplus-hotdog.dtb` (added by the patch series; not in upstream Linux or in the sm8150-mainline tree) |
| Functional on the port (its status matrix calls most rows "partial") | UFS, GPU (Freedreno/Turnip), display at 60 Hz, touch while awake, Wi-Fi (incl. suspend), USB-C dual role and DisplayPort, speakers and handset mic, cameras (raw capture), s2idle suspend, charging, haptics, Bluetooth (with patches 0021-0023, included in the series) |
| Not functional or not validated | 90 Hz display, earpiece/headset audio, modem (boots, scans, nothing SIM-validated), GNSS (engine starts, no fixes), sensors (vendor SLPI firmware and a special iio-sensor-proxy build), fingerprint (never) |

The port is a one-developer project in alpha. Its hardware status rows
were established on its 6.16 kernel and only partly re-validated on the
6.17 line Antumbra uses. Antumbra claims nothing beyond that.

## 3. System overview

```
 OnePlus bootloader (ABL, unlocked, slot B)
   │  loads boot_b: Android boot image v2 = Linux 6.17 Image + initramfs + DTB
   │  applies dtbo_b, consults vbmeta_b (verification disabled)
   ▼
 initramfs (Debian initramfs-tools + live-boot + Antumbra hooks)
   │  losetup -P --sector-size 4096 on the UFS `userdata` partition
   │  live partition selected by its build-time UUID → /dev/antumbra/live
   │  live-boot mounts the squashfs through dm-verity, tmpfs overlay on top
   ▼
 systemd (Debian 13 arm64)
   │  nftables Tor-enforcement ruleset before any network device exists
   │  network drivers blocklisted; Tor started with DisableNetwork 1
   │  modem processor up (Wi-Fi needs it), radio pinned to low-power
   ▼
 greetd → Welcome screen, running as the `antumbra-greeter` user
   │  Persistent Storage, MAC spoofing, Tor mode and bridges,
   │  screen-lock passphrase, administration
   │  → root applies the settings once, unblocks the network
   │  → the Welcome screen asks greetd to start the user session
   ▼
 Phosh session as `amnesia`; applications reach the network only through Tor
```

## 4. Storage layout

Antumbra follows the port's current (v0.2.0) layout: the operating system
lives in the Android `userdata` partition, inside a nested GPT with
4096-byte logical sectors.

```
userdata (physical Android partition, 232,382,812,160 bytes; written from fastbootd as a sparse image)
└── GPT, 4096-byte sectors, sized to the physical partition
    ├── p1  ANTUMBRA_LIVE   ext4 without journal, read-only at runtime
    │         /live/filesystem.squashfs          the root filesystem (xz, arm BCJ)
    │         /live/filesystem.squashfs.verity   dm-verity hash tree
    │         /live/filesystem.module, antumbra.manifest, /.disk/info
    └── p2  ANTUMBRA_DATA   (Tails' Persistent Storage type GUID) grows to the end;
              unformatted until the Welcome screen creates the LUKS2 volume
```

Why `userdata` and not `super`: the port records three reasons. A short
image written to the 15 GB `super` left its backup GPT in the middle of
the partition, which the kernel rejected; `userdata` leaves Android's
`super`, both recoveries and slot A untouched; and `userdata` has the
capacity. For either target, writing has to go through fastbootd in
128 MiB chunks, because the bootloader's fastboot stalls on large
transfers.

Why the image is full size: a nested GPT carries its backup header at
the end of the device, so `image.sh` builds the GPT at the exact physical
size and exports it as an Android sparse image in which the empty regions
are "don't care" chunks; fastboot writes only the live partition and the
two GPT copies.

Slot A keeps the user's Android boot and recovery. It is **not** an
escape hatch for Android: booting the Android system there formats the
shared `userdata` and erases Antumbra together with its Persistent
Storage. The way back is the slot-B backup that `flash.sh` makes, or the
OnePlus MSM Download Tool.

Boot-critical partitions, all in slot B:

| Partition | Size | Content |
|---|---|---|
| `boot_b` | 100663296 bytes (96 MiB) | Antumbra boot image, see section 5 |
| `dtbo_b` | 25165824 bytes | the port's filtered DTBO, downloaded from its release and verified by SHA-256 |
| `vbmeta_b` | 65536 bytes | the port's vbmeta with flags = 3 (hashtree and verification disabled), downloaded and verified |

Antumbra builds only `boot_b` and the `userdata` image. The DTBO and
vbmeta are taken from the hardware-validated release of the port rather
than regenerated, to keep the untested surface minimal.

## 5. Boot image

The boot image contract comes from the port and is validated on hardware:

```
mkbootimg --header_version 2 --pagesize 4096 --base 0x00000000 \
  --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 \
  --tags_offset 0x00000100 --dtb_offset 0x01f00000 \
  --kernel Image --ramdisk initrd.img --dtb sm8150-oneplus-hotdog.dtb \
  --cmdline "<at most 511 bytes>" -o boot.img
avbtool add_hash_footer --image boot.img --partition_name boot \
  --partition_size 100663296 --algorithm NONE --salt <hex>
```

Facts that constrain the design:

- The kernel is the raw arm64 `Image` from the build tree (the port's
  configuration has `EFI_ZBOOT`, so a packaged `vmlinuz` would be a PE
  file the bootloader cannot load); `kernel.sh` checks the `ARM\x64`
  magic. The DTB goes in the v2 DTB field, not appended.
- The ABL truncates the command line at 511 bytes and ignores
  `extra_cmdline`. `bootimg.sh` refuses longer lines.
- `fastboot boot` is refused by this ABL; every test is a flash.
- The AVB footer is unsigned (`--algorithm NONE`). It is a format
  requirement, not a security feature. `avbtool.py`, `mkbootimg.py` and
  `unpack_bootimg.py` are fetched from AOSP at build time and verified by
  SHA-256 (Debian does not package avbtool, and distribution mkbootimg
  packages differ).
- Required kernel parameters from the port: `iommu.passthrough=0
  arm-smmu.disable_bypass=0 clk_ignore_unused`. `console=ttyGS0` must not
  be set.

Antumbra command line (`device/oneplus-hotdog/cmdline.txt`, 328 bytes,
plus the parameters `bootimg.sh` appends):

```
boot=live live-media=/dev/antumbra/live live-media-path=/live union=overlay nopersistence
iommu.passthrough=0 arm-smmu.disable_bypass=0 clk_ignore_unused
slab_nomerge slub_debug=FZ init_on_free=1 init_on_alloc=1 page_alloc.shuffle=1
randomize_kstack_offset=on usbcore.authorized_default=0 systemd.condition_needs_update=no quiet
dm-verity-root-hash=filesystem.squashfs:<64 hex> dm-verity-oncorruption=panic   (appended; ANTUMBRA_VERITY=0 omits)
antumbra.debug=1                                                              (appended by debug builds, which also drop quiet)
```

Compared with Tails' command line, the x86-only options (`mce=0`,
`vsyscall=none`, `mds=full,nosmt`, `spec_store_bypass_disable=on`,
`efi_pstore.pstore_disable=1`, `erst_disable`) are dropped, live-config's
options are dropped (Antumbra does not use live-config), and
`page_poison` is deliberately absent: on this kernel `page_poison=on`
would disable `init_on_free`, the mechanism Tails relies on for memory
erasure. `usbcore.authorized_default=0` keeps USB devices unauthorised
until usbguard applies its policy.

## 6. Initramfs

Debian's `initramfs-tools` generates the initramfs inside the chroot
(`config/hooks/80-base-initramfs.sh`, after every modprobe.d blocklist
it must carry exists), with `MODULES=list` so only what the boot path
needs is included. live-boot supplies the live medium
logic. Verified properties of Debian's live-boot that the design relies
on: scripts in `scripts/live-premount/` run before the medium search; an
explicit `live-media=<path>` is honoured without the medium UUID check;
live-boot's own device scan skips loop devices, so the explicit path is
mandatory; its hook copies util-linux `losetup`; udev in the initramfs
creates the loop partitions' symlinks; dm-verity is built in
(`dm-verity-root-hash=`).

Antumbra adds (`config/rootfs/etc/initramfs-tools/`):

- `scripts/live-premount/05-antumbra-loop`: finds the partition named
  `userdata` whose device path lies on the UFS host controller (so no
  USB medium qualifies), runs `losetup --sector-size 4096 --partscan`,
  waits for udev, then looks for the loop partition whose filesystem
  UUID equals the value recorded at build time in
  `/etc/antumbra/live-fs-uuid`, and publishes it as `/dev/antumbra/live`.
  Any mismatch is a panic: live-boot's fallback scan of removable devices
  never runs with the right medium missing.
- `hooks/antumbra`: copies that UUID file, the driver blocklist,
  `blkid`, `losetup`, `udevadm` and the `overlay`, `loop`, `squashfs`,
  `ext4` and `dm-verity` modules (most are built in). It then removes
  every network-related module that live-boot's own hook pulls in for
  netboot (`auto_add_modules net`: USB NICs copied at once, Ethernet, MDIO
  and PHY drivers queued for later), both from the staging tree and from
  initramfs-tools' pending module list, and refuses to run if that list
  interface disappears. Tails patches live-boot for the same end: nothing
  in the initramfs may bring up a network interface before the firewall
  and the MAC spoofer exist. Four modules initramfs-tools adds after all
  hooks ran, as hidden dependencies of the built-in `msm` display driver
  (`qrtr`, `pmic_glink`, `pmic_glink_altmode`, `gpio_sbu_mux`), cannot be
  kept out; the hook makes them unloadable inside the initramfs with
  `install <module> /bin/false` instead (the root filesystem loads them
  itself later). `80-base-initramfs.sh` fails the build if any module
  outside the filesystem, device-mapper, block, crypto and library
  subtrees is present without that block, or if the UUID file, the
  blocklist, the premount script, `losetup` or `veritysetup` is missing.
- `hooks/antumbra-shutdown` and the matching units (section 7): on
  shutdown systemd returns into an unpacked copy of the initramfs
  (`/run/initramfs`), which unmounts the overlay and the medium, detaches
  the loop device and drops the page cache. This is Tails' memory-erasure
  design minus the removable medium; the initrd copy comes from `/boot`
  inside the read-only, verity-covered root.

No proprietary firmware is in the initramfs, so `boot.img` is a
publishable artifact. Slot marking is **not** done in the initramfs:
Debian's `qbootctl.service` runs `qbootctl -m` once `multi-user.target`
is reached. If the system fails before that point, the bootloader's
retry counter is left to count down and after seven failed boots the
phone falls back to slot A's recovery.

The initramfs contains **no** USB gadget networking, no DHCP server, no
serial console and no shell. The postmarketOS initramfs the port uses
exposes NCM/RNDIS networking with SSH and a passwordless root console on
`ttyGS0`; Antumbra ships none of that.

## 7. Amnesia and memory

| Mechanism | Antumbra | Tails equivalent |
|---|---|---|
| Root filesystem | squashfs, read-only, under dm-verity, with a tmpfs overlay (live-boot `union=overlay`) | squashfs + overlay |
| Writes to flash | none without Persistent Storage; `nopersistence` on the cmdline; the modem's storage partitions served read-only (`rmtfs -r`) | same |
| Swap | zram only (`systemd-zram-generator`, zstd, half of RAM); `swapon` diverted to a wrapper that refuses anything but zram | zram |
| Memory zeroing | `init_on_free=1 init_on_alloc=1` on the cmdline and as kernel defaults | `init_on_free=1` |
| Kernel log stores | pstore and ramoops disabled in the kernel and removed from the device tree; `dmesg_restrict=1` | `efi_pstore` disabled |
| Shutdown | overlay `rw`/`work` directories removed late in shutdown (`antumbra-remove-overlayfs-dirs.service`), return to the initramfs to unmount everything (`initramfs-shutdown.service`, `run-initramfs.mount`), caches dropped | same |
| Emergency shutdown | long press of the power button (`HandlePowerKeyLongPress=poweroff`, about 5 s), Phosh's power menu, and `antumbra-auto-shutdown.timer`, armed by `antumbra-lock-watch` when the session locks and fired after 18 h with `WakeSystem=yes` so it works from suspend through the PMIC RTC alarm | pulling the USB stick (udev-watchdog), which has no equivalent on UFS |
| Suspend | allowed; the Welcome screen warns that suspend keeps keys in RAM; the auto-shutdown alarm still fires | n/a |
| Logs | journal `Storage=volatile`, no syslog, no core dumps (`systemd-coredump` masked, `core_pattern` disabled) | same |
| Debug surfaces | `debugfs` and `tracefs` mounts masked, `kexec_load_disabled=1`, Yama `ptrace_scope=2`, unprivileged BPF off, `dmesg` restricted | same, where applicable |

## 8. Tor enforcement

### 8.1 Firewall

Tails enforces Tor with a ferm-generated iptables ruleset keyed on the
Unix user of the socket owner. Antumbra ports `ferm.conf` to native
nftables (`config/rootfs/etc/nftables.conf`), because the port's kernel
builds nftables but not the legacy `xt_owner` match, and because ferm 2.5
only emits iptables syntax. The file is the specification; in summary:

- `inet antumbra` table: `input`, `forward` and `output` chains with
  policy `drop`, `log_reject` logging to the journal (`Dropped outbound
  packet:` with the UID) and rejecting with port-unreachable.
- Output: IPv4 established traffic accepted; on loopback, related ICMP,
  Tor's SocksPorts for `_apt`/`proxy`/`nobody` (9050) and `htp` (9062),
  the user rejected from 9063 and from the ControlPort 9052, root allowed
  to 9052 and to the control-port filter 951, UDP 53/5353 for the user,
  `htp` and root (rejected for `_apt`), and any other local TCP for the
  user (so OnionShare and local servers work). The user's redirected
  traffic to TransPort 9040 is accepted; `clearnet` may send TCP and UDP
  DNS on external interfaces; `debian-tor` may open any TCP connection and
  send UDP DNS; the local network is reachable directly except DNS and
  NetBIOS; everything else, including all IPv6 and all ICMP to the
  outside, is logged and rejected.
- Input: IPv4 established and loopback accepted; the four application
  namespaces accepted only for the exact source/destination/port pairs
  they need (SocksPort and/or 951); the clearnet namespace rejected from
  the host network.
- Forward: policy drop; per-session accepts for the clearnet namespace
  live in the separate `antumbra-session` tables, which a reload never
  flushes; a mangle chain resets the TTL of forwarded clearnet packets to
  64, as Tails does against passive fingerprinting.
- `ip antumbra-nat` output chain: `.onion` automap addresses
  (`127.192.0.0/10`) and the user's outgoing TCP (except the local
  network) redirected to 9040; UDP 53 to loopback redirected to the
  DNSPort 5353.
- Loaded by `nftables.service` before `network-pre.target`, never flushed
  on stop (Tails' no-drop-on-stop), re-applied by the NetworkManager
  dispatcher on every interface up, syntax-checked in CI, and verified at
  boot by `antumbra-selfcheck` before the network is unblocked.

Namespaces (`antumbra-create-netns`, Tails' `tails-create-netns` with
nftables inside the namespaces): `tbb` (Tor Browser), `onioncircs`,
`tca`, `onionshare` and `clearnet`, veth pairs in `10.200.1.0/24`, each
reaching the host only through DNAT of its loopback ports to the host
address. The addresses are hard-coded in torrc, the firewall and the
onion-grater filters and are therefore kept verbatim.

### 8.2 Tor configuration

`/etc/tor/torrc` is Tails' torrc unchanged: SocksPorts 9050/9062/9063
on loopback with destination isolation, `10.200.1.1:9050` for the
browser namespace, `ControlPort 9052` with cookie authentication,
`DNSPort 5353` with `AutomapHostsOnResolve`, `TransPort 9040`,
`Sandbox 1`, `AvoidDiskWrites 1`, `DisableNetwork 1` until the user has
chosen how to connect. The `tor@default.service` drop-ins (writable
`/etc/tor` for SAVECONF, `resolv.conf` override for bridge-mode DNS, no
`NoNewPrivileges` for the transports) and Tails' AppArmor adjustments to
Debian's Tor profile are carried over.

The control port is never exposed to applications directly. Tails'
`onion-grater` (Python, stem) listens on 951 and applies per-application
YAML allow-lists. It is installed unchanged, as are the units that raise
the "Tor has bootstrapped" flag.

Bridges and pluggable transports follow Tails: the transport binaries
come from the Tor Browser tarball the build verifies. The Linux aarch64
tarball ships `lyrebird` (obfs4, meek_lite, webtunnel, snowflake) and
`conjure-client`; `lyrebird` is installed as `/usr/bin/obfs4proxy` so
Debian's Tor AppArmor abstraction keeps matching, and Tails'
`tor-pt-configuration-helper` writes the `ClientTransportPlugin` line and
turns the seccomp sandbox off only when a transport is in use.

Connecting: Tails' Tor Connection assistant is not ported yet. The
Welcome screen records the mode (automatic, bridges with the lines
given, or offline), and the NetworkManager dispatcher calls
`antumbra-tor-connect` when a connection comes up; the same tool serves
on the command line (`direct`, `bridges FILE|-`, `status`,
`disconnect`).

### 8.3 DNS and name resolution

`/etc/resolv.conf` is a static file pointing at `127.0.0.1`.
NetworkManager runs with `dns=none` and `dhcp=internal` so it never
touches it (the DHCP-provided servers are only recorded in
`/etc/resolv-over-clearnet.conf` for Tor's own bridge-mode lookups).
UDP 53 to loopback is redirected to Tor's DNSPort 5353.
`systemd-resolved` is not installed. There is no IPv6 resolution because
IPv6 is disabled by sysctl on every interface except loopback and dropped
by the firewall everywhere.

### 8.4 Time

Tor needs a roughly correct clock, and a phone has no trusted time
source: the modem's NITZ time is a tracking channel and NTP is a leak.
The NetworkManager dispatcher `10-antumbra-tor.sh` (Tails' `10-tor.sh`
adapted) runs on every connection: it connects Tor the way the Welcome
screen asked (`antumbra-tor-connect direct` or `bridges`), then restarts
`htpdate.service` unless `/run/htpdate/success` already exists, and when
the last connection goes down it stops `tails-tor-has-bootstrapped.target`
so dependants notice. Once Tor has bootstrapped, Tails' `htpdate` (the
Perl implementation vendored in `/usr/local/sbin/htpdate`, not Debian's
package of the same name) runs as user `htp` over SocksPort 9062, taking the median of three
pools of HTTPS servers and accepting not-yet-valid certificates for the
reason explained in Tails' design notes. `systemd-timesyncd` is masked
and ModemManager is absent, so nothing else can set the clock. Tails'
optional pre-Tor clock fix through a captive-portal `Date` header (as
user `clearnet`) is prepared for in the firewall but not yet offered to
the user.

## 9. Radio and hardware policy

### 9.1 Wi-Fi

- Every network driver module is blocklisted at build time
  (`config/hooks/42-network-block-drivers.sh` generates
  `/etc/modprobe.d/all-net-blocklist.conf`) and loaded only after the
  Welcome screen has recorded the MAC-spoofing decision
  (`antumbra-unblock-network`, Tails' pattern).
- Every new Ethernet-type interface triggers `antumbra-spoof-mac` from a
  udev rule: `macchanger -e`, three attempts; on failure the module is
  unloaded and blocklisted for the session, and if the interface
  survives that, NetworkManager is stopped and masked (Tails' panic
  mode). On this port the pre-spoof address is already random at every
  boot (the port has no factory-address provisioning yet); Antumbra must
  never add any (no `local-mac-address` property, no `bootmac`).
- NetworkManager: `wifi.cloned-mac-address=preserve` (the udev step owns
  the address), `wifi.scan-rand-mac-address=yes`,
  `ipv4.dhcp-send-hostname=false`, `ipv6.dhcp-send-hostname=false`,
  `ipv4.dhcp-client-id=stable` with a per-boot `stable-id`,
  `hostname-mode=none`, `ipv6.ip6-privacy=2`, `dns=none`, `dhcp=internal`.
  A pre-up dispatcher script tears down and deletes any profile with
  `802-11-wireless.hidden=yes` (hidden networks make the phone broadcast
  their names everywhere).
- Hostname is `amnesia` and is never sent on the wire.

### 9.2 Cellular modem

On SM8150 the modem processor (MPSS) is a hard dependency of Wi-Fi, not
only of telephony. The WLAN firmware (`wlanmdsp.mbn`) is not loaded by
`ath10k`; it runs as a protection domain inside the modem's DSP, the
modem fetches it over TFTP from `tqftpserv`, and `ath10k_snoc` only
talks to it through a QMI service that appears once the modem is up. The
port isolated this step by step and the postmarketOS SDM845 documentation
states the same dependency. The modem processor therefore boots, with:

- `rmtfs -r -P -s` (Debian's unit already runs it read-only: the modem can
  never write to the phone's flash),
- `tqftpserv` (serves `wlanmdsp.mbn` to the modem),
- the kernel's own protection-domain mapper (`qcom_pd_mapper`, loaded
  from `modules-load.d`; the userspace `pd-mapper` and its vendor maps
  are not installed).

What keeps this compatible with goal 3 is that the modem's **radio** is
separate from the modem **processor**, and nothing on mainline turns the
radio on by itself: the port observed the firmware booting into the
`shutting-down` operating mode; RF bring-up only happens on an explicit
QMI DMS "online" request, which ModemManager sends when NetworkManager
enables the modem. Antumbra therefore:

1. does not install ModemManager, masks its unit, and ships a D-Bus
   activation override (`Exec=/bin/false`) for
   `org.freedesktop.ModemManager1` so nothing can start it on demand (the
   port needed the same fix);
2. runs `antumbra-modem-radio-off.service` after `rmtfs` and `tqftpserv`:
   once the DMS service is reachable on QRTR node 0 it requests
   `--dms-set-operating-mode=persistent-low-power` (falling back to
   `low-power`), which in Qualcomm's definition means IMSI detach and RF
   off, records the mode and registration state, and a timer re-asserts
   it every five minutes so a modem restart cannot bring RF back;
3. **gates the control channel**: a small kernel patch
   (`device/oneplus-hotdog/kernel/patches/0101-…`) makes creating an
   `AF_QIPCRTR` socket require `CAP_NET_ADMIN`. Without it any process
   could send the modem an "online" request, because QMI has no client
   authentication. In-kernel users (ath10k, the name service, the
   pd-mapper) are unaffected; the root-owned daemons keep working;
   `antumbra-selfcheck` verifies that `nobody` cannot open such a socket.
4. verifies in the late self-check that the mode is low-power and the
   registration state is not registered, and records the result for the
   session.

There is no kernel rfkill switch for a QRTR modem, so `rfkill block wwan`
does nothing here; the QMI operating mode is the control. The modem
configuration catalogue (MCFG), SIM handling, IPA and rmnet (disabled in
the kernel) and anything else that only telephony needs are absent.

Residual facts the user is told: the modem firmware runs with the
phone's IMEI inside it; in low-power mode it does not transmit, but the
firmware is proprietary and this cannot be audited, and whether a
low-power modem still answers emergency-camping requests on this
firmware has not been measured.

### 9.3 Bluetooth, NFC, GNSS, sensors, cameras, microphones

| Radio or sensor | Default | Mechanism |
|---|---|---|
| Bluetooth | off | the driver stack (`bluetooth`, `bnep`, `btusb`, `btqca`, `hci_uart`) is blocklisted in `modprobe.d`, as in Tails; bluez is not installed; rfkill soft-block is defence in depth, not the control (the seat user can toggle rfkill). An opt-in session with a random address before power-on is on the roadmap |
| NFC | off | `nfc`, `nci`, `nxp_nci`, `nxp_nci_i2c` blocklisted |
| GNSS | off | lives in the modem (QMI LOC) and only tracks between an explicit `Start` and `Stop`; nothing sends `Start`, and the QRTR gate keeps applications away |
| Motion, light, proximity sensors | unavailable | the sensor DSP (SLPI) is disabled in the device tree by Antumbra's override; no sensor daemon is installed; the ultrasonic proximity path that depends on it is not shipped either (no calls, so no need) |
| Cameras | available, no indicator | libcamera via PipeWire and the portal permission prompts |
| Microphones | available | PipeWire; a per-session mute switch is on the roadmap |

Cameras and microphones have no hardware kill switch on this phone;
software policy is the only control, as on every phone.

### 9.4 USB

The phone is a USB gadget most of the time (charging). The kernel keeps
gadget and dual-role support because the Type-C role switch and the
port's USB-PD handling depend on the same controller driver; Antumbra
configures **no** gadget function in userspace and blocklists the gadget
function modules (`usb_f_rndis`, `usb_f_ncm`, `usb_f_ecm`, `usb_f_acm`,
`usb_f_fs`, `usb_f_mass_storage`, the legacy `g_*` drivers). In host mode
(a dock or an OTG adapter) devices stay unauthorised from the kernel
command line until `usbguard` (Debian's defaults: `ImplicitPolicyTarget=block`,
`PresentDevicePolicy=apply-policy`) applies the Antumbra policy, which
allows only hubs; every other device needs the user's approval. The rules
file is written by the build, because Debian's package would otherwise
generate an allow-list from whatever was attached to the build host.
Charging from USB hosts may follow the USB default (about 500 mA) rather
than the 900 mA the port negotiated through gadget enumeration; dedicated
chargers are unaffected.

### 9.5 Boot security, honestly

The bootloader is unlocked and shows the "Orange state" warning at
every boot. Android Verified Boot is disabled (vbmeta flags = 3), so
nothing anchors the boot image to the hardware, and an attacker with the
phone in hand can replace it. This is the same assumption Tails makes
(physical control of the device). Antumbra mitigates what it can:

- The squashfs root is covered by a dm-verity hash tree whose root hash
  is embedded in the boot image command line (live-boot's own support).
  It does not resist an attacker who replaces the boot image, but silent
  tampering with the root filesystem alone, or a corrupted flash, is
  detected at boot. On by default; `ANTUMBRA_VERITY=0` builds without it.
- The live medium is selected by its UUID on the internal UFS storage
  and USB devices are not authorised during early boot, so a labelled
  USB stick cannot hijack the boot.
- Persistent Storage is LUKS2 with argon2id (memory cost 1 GiB, 4
  iterations, mirroring Tails' `tps` parameters) and is only ever opened
  from the running system with the user's passphrase.
- No swap on flash, zeroing on free, no persistent kernel logs, shutdown
  instead of suspend when the user wants amnesia.

Forced reset and cold boot: an attacker who holds the power button long
enough for a PMIC reset, or enters the bootloader with the phone powered
on, bypasses the orderly shutdown and can boot a memory-dumping image.
Only short lock-to-shutdown timers and shutting the phone down before
handing it over help; LPDDR4X remanence on SM8150 is unmeasured.

## 10. Session, Welcome screen and lock screen

The shell is Phosh (phoc compositor, squeekboard on-screen keyboard),
the same stack Mobian ships on Debian. Session start-up was decided from
the actual trixie package contents: Debian's `phosh.service` is a
development unit hard-wired to UID 1000 with no greeter; `greetd` has a
documented IPC and runs greeters as their own user; `phosh-session`
exports none of the session variables itself.

Antumbra's trust boundary is Tails': the Welcome screen runs **before**
any user process exists, as a dedicated system user, and root applies its
answers once.

1. `greetd` (`/etc/greetd/config.toml`) starts
   `/usr/libexec/antumbra-greeter-session` as the `antumbra-greeter` user:
   a bare phoc compositor (`/etc/antumbra/phoc.ini`: scale 3, 60 Hz)
   running squeekboard and `antumbra-welcome`, exactly as the phrog
   greeter's session works.
2. `antumbra-welcome` (GTK4/libadwaita) asks the Tails Welcome Screen
   questions in phone form: Persistent Storage (unlock, or create if the
   partition is still empty), MAC address anonymisation (on by default),
   Tor connection (automatic, bridge lines, or offline), a screen-lock
   passphrase (recommended), and administration (sudo with that
   passphrase, off by default). It writes the answers in Tails' file
   format and keys (`tails.macspoof`, `tails.network`, `tails.password`,
   `tails.create-persistence`, plus `antumbra.*`) to
   `/var/lib/antumbra/settings/{persistent,transient}`, directories owned
   by the greeter user, then touches `welcome-done`.
3. `antumbra-apply-welcome-settings.path` wakes the root one-shot of the
   same name, Tails' `PostLogin/Default` as a unit. It refuses to run if
   `/run/antumbra/welcome-applied` exists or if any input is not owned by
   the greeter user; unlocks or creates Persistent Storage and activates
   its features (so persistent settings come from the volume); copies the
   settings to `settings/applied/` (root-owned); sets the user's password
   with `chpasswd -e` or deletes it; installs the sudoers and polkit admin
   rules when asked; writes the marker; runs `antumbra-unblock-network`.
   The Persistent Storage passphrase travels in a 0600 file in the
   greeter's tmpfs directory that the applier shreds; a D-Bus service as in
   Tails' `tps` is on the roadmap.
4. The Welcome screen waits for the marker, then uses greetd's IPC to
   create a session for `amnesia` (greetd's PAM stack for IPC sessions,
   `/etc/pam.d/greetd`, lets that user in without a password, since the
   passphrase is only for the lock screen) and starts `/usr/libexec/antumbra-session`, which exports the
   session variables and runs `phosh-session`. If the user logs out,
   greetd shows the Welcome screen again; settings cannot change in the
   same boot, only a new session can start.

Lock screen: Phosh's lock screen authenticates through PAM with the
passphrase the Welcome screen set; without one the lock is not
protective, and the Welcome screen says so. `antumbra-lock-watch` arms
the auto-shutdown timer on lock and disarms it on unlock.

## 11. Applications

| Role | Package or source | Notes |
|---|---|---|
| Browser | Tor Browser for Linux aarch64 from the 16.0 alpha channel (`tor-browser-linux-aarch64-16.0a13.tar.xz`), verified at build against the Tor Browser Developers key `EF6E 286D DA85 EA2A 4BA7 DE68 4E2C 6E87 9329 8290` (vendored) and the signed checksum list | The only official Tor Browser for this architecture; stable 15.0.x is x86 only. Tor Project advises at-risk users against alphas; the Welcome screen says so. Launched as `amnesia` inside the `tbb` namespace (`tor-browser` → sudo → `antumbra-run-tor-browser` → `ip netns exec` → drop privileges → `launch-tor-browser`), with Tails' preferences; no AppArmor profile yet |
| Unsafe Browser | not ported | the `clearnet` namespace and firewall rules are in place |
| File sharing | OnionShare 2.6.3 (CLI and GTK) | Qt GUI usable, not adaptive |
| Passwords | GNOME Secrets (KeePass format) | adaptive |
| Metadata | Metadata Cleaner (`mat2`) | adaptive |
| Files, images, documents, text, calculator, clocks | Nautilus, Loupe, Papers, GNOME Text Editor, GNOME Console, Calculator, Clocks | adaptive GTK4 |
| Crypto wallet | Electrum (as Tails ships) | |
| Camera | Megapixels | raw capture quality only |
| Encryption | GnuPG, `gnome-keyring` | |

APT reaches the network only through Tor (`socks5h://127.0.0.1:9050`, user
`_apt`). No app store or Flatpak by default.

## 12. Persistent Storage

`antumbra-persistence` (root only) manages the LUKS2 volume on the
`ANTUMBRA_DATA` partition with Tails' `tps` parameters and the partition
type GUID Tails uses. Features (`/etc/antumbra/persistence-features.conf`)
are directories on the volume bind-mounted onto their targets, in order:
Persistent folder, Welcome settings, Network connections, Tor bridges
(`/var/lib/tca`), GnuPG, SSH client, and Dotfiles (symlinked into the
home). Creation formats the partition (`luksFormat --type luks2 --pbkdf
argon2id --pbkdf-memory 1048576 --pbkdf-force-iterations 4`) and
pre-creates every feature directory with its owner and mode. Differences
from Tails: no D-Bus service, no `nosymfollow` bind of `/` (roadmap), and
OS updates currently erase the volume because they re-flash `userdata`.

## 13. Kernel

Source: `gitlab.com/sm8150-mainline/linux` at `v6.17.0-sm8150` with the
27-patch series from the port applied in order, then Antumbra's own
patch (`0101`, the QRTR capability gate), then the device-tree overrides
appended to the hotdog DTS (`antumbra-dts-overrides.dtsi`: SLPI remote
processor disabled, ramoops node deleted), then the configuration
fragment merged over the port's config with `merge_config.sh`.
`kernel.sh` fails if any fragment line is not honoured. Built with LLVM
by default (the port's validated recipe); `ANTUMBRA_KERNEL_TOOLCHAIN=gcc`
is experimental.

The fragment (`device/oneplus-hotdog/kernel/antumbra.config`):

| Option | Why |
|---|---|
| `NFT_REDIR=m`, `NFT_FIB_INET=m`, `NF_CT_NETLINK=m`, `NETFILTER_XT_MATCH_OWNER=m` | the Tor-enforcement ruleset needs the `redirect` statement; conntrack tooling; `xt_owner` keeps `iptables-nft` compatibility for Tails scripts |
| `SQUASHFS_FILE_DIRECT=y`, `SQUASHFS_COMPILE_DECOMP_MULTI_PERCPU=y` (single and file-cache off), `SQUASHFS_ZSTD=y` | multi-core decompression of the root filesystem; zstd available (xz remains the image default) |
| `DM_VERITY=y` | root filesystem integrity (section 9.5) |
| `SECURITY_APPARMOR=y`, `SECURITY_YAMA=y`, `SECURITY_LANDLOCK=y`, `LSM="landlock,lockdown,yama,loadpin,safesetid,ipe,apparmor,bpf"`, `SECURITY_DMESG_RESTRICT=y` | Tails' confinement of Tor needs AppArmor; its `ptrace_scope=2` sysctl needs Yama; the port built none of them |
| `INIT_ON_FREE_DEFAULT_ON=y`, `INIT_ON_ALLOC_DEFAULT_ON=y`, `RANDOMIZE_KSTACK_OFFSET_DEFAULT=y`, `SHUFFLE_PAGE_ALLOCATOR=y` | the command line enables them too; defaults make a truncated command line safe, and `page_alloc.shuffle=1` needs the allocator option |
| `SLAB_FREELIST_RANDOM=y`, `SLAB_FREELIST_HARDENED=y`, `RANDOM_KMALLOC_CACHES=y`, `HARDENED_USERCOPY=y`, `FORTIFY_SOURCE=y`, `BUG_ON_DATA_CORRUPTION=y`, `ARM64_BTI_KERNEL=y` | hardening Debian's kernel also enables |
| `ACPI_APEI` and `PSTORE` off | ACPI APEI selected pstore; this phone has no ACPI tables, and no kernel log may survive a reboot (the port's ramoops region would keep Wi-Fi identifiers and firewall lines in DRAM) |
| `QRTR_TUN` off | no userspace tunnel into the QRTR bus |
| `QCOM_IPA` and `RMNET` off | no cellular data path in version 1 |
| `IKCONFIG_PROC`, `LEGACY_PTYS`, `DEVPORT`, `CRYPTO_USER_API_ENABLE_OBSOLETE` off; `CRYPTO_USER_API_AEAD=m` | attack surface; the AEAD interface as a module so Tails' `algif_aead` blocklist is effective |
| `RTC_DRV_PM8XXX=y` | the auto-shutdown timer's alarm wake-up |
| `QCOM_PD_MAPPER=m` | the in-kernel protection-domain mapper (it cannot be built in because QRTR is a module; `modules-load.d` loads it) |

Deliberately **not** changed: `DEBUG_FS` (masked at run time), `KEXEC`
(disabled by sysctl), `DEVMEM` (already strict), USB gadget support
(section 9.4), module signing (it would make builds unreproducible; the
read-only verity root covers the modules), `VA_BITS` and everything the
port needs to boot from the ABL (`CONFIG_ONEPLUS_HOTDOG_EARLY_BOOT=y`,
`EFI`, the watchdog handling). The build reads
`CONFIG_ARCH_MMAP_RND_BITS_MAX` and its compat counterpart from the final
configuration and writes `/etc/sysctl.d/mmap_aslr.conf` from them (33 and
16 for this kernel) instead of copying Tails' x86 values.

## 14. Firmware and licensing

Every radio, the GPU, the DSPs and the modem need proprietary firmware
that OnePlus and Qualcomm do not license for redistribution. Debian's
`firmware-qcom-soc` provides only `qcom/a630_sqe.fw` of what this phone
needs. Therefore:

- Published Antumbra images contain **no** device firmware. The build
  copies firmware from a directory the builder provides
  (`ANTUMBRA_FIRMWARE_DIR`), populated by `build/fetch-firmware.sh` from
  the community mirror the port uses, pinned by commit and per-file
  SHA-256, for the user's own device, after an explicit acknowledgement
  (`docs/legal.md`).
- Files installed: `qcom/a630_sqe.fw`, `qcom/a640_gmu.bin` and
  `qcom/sm8150/oneplus/hotdog/a640_zap.mbn` (GPU; the zap shader is signed
  by OnePlus for this model); `qcom/sm8150/oneplus/hotdog/{adsp,cdsp}.mbn`
  (audio and compute DSPs); `qcom/sm8150/oneplus/hotdog/modem.mbn` and
  `wlanmdsp.mbn` (the modem processor, which Wi-Fi requires);
  `ath10k/WCN3990/hw1.0/{firmware-5.bin,board-2.bin}` (Wi-Fi);
  `qcom/sm8150/oneplus/hotdog/venus.mbn` (video); `qca/crbtfw21.tlv` and
  `qca/crnv21.bin` (Bluetooth, for the future opt-in session).
- Not installed: `slpi.mbn` (sensor DSP disabled), the pd-mapper vendor
  maps (kernel pd-mapper used), the NFC configuration, `ipa_fws.mbn` (IPA
  disabled), and the per-unit calibration from the `persist` partition.

## 15. Build pipeline and reproducibility

```
build/build.sh                      orchestrates; every step is idempotent and runs alone too
  fetch-sources.sh                  kernel tree + port patches + avbtool + DTBO/vbmeta + Tor Browser, all pinned and verified
  fetch-firmware.sh                 (separate, explicit) the builder's own device firmware
  kernel.sh                         patches, DTS overrides, fragment merge and check, Image + modules + DTB
  rootfs.sh (root)                  mmdebstrap (arm64, trixie) + overlay + hooks inside the chroot → tree, initramfs, package list
  squashfs.sh (root)                mksquashfs xz/arm BCJ with fixed times; dm-verity hash tree and root hash
  image.sh                          ext4 live partition (mke2fs -d), GPT at the physical size (systemd-repart), img2simg -s
  bootimg.sh                        mkbootimg v2 + verity hash on the cmdline + avbtool footer, then unpack_bootimg checks
  release.sh                        boot.img, userdata.simg.zst (split under 2 GiB), DTBO/vbmeta copies, SHA256SUMS, MANIFEST, minisign
build/flash.sh                      guided fastboot/fastbootd flashing with identity, size and backup checks
build/verify-release.sh             signature and hash verification for downloads
```

Reproducibility: `SOURCE_DATE_EPOCH` from the git commit everywhere
(mmdebstrap, mksquashfs, mke2fs, kernel timestamp), apt optionally pinned
to a `snapshot.debian.org` timestamp, filesystem UUIDs and GPT GUIDs
derived from the version string (the initramfs only accepts the live
partition with that UUID), `/etc/machine-id` empty, no `resolv.conf` or
`hostname` from the build host, and the package manifest recorded in the
image and the release.

Hosts: any Debian/Ubuntu x86_64 machine with `qemu-user-static` (the
rootfs step runs arm64 maintainer scripts under emulation), or a native
arm64 machine. Validation performed without hardware: shellcheck on
every script, `nft -c` on the ruleset, `tor --verify-config`,
`systemd-analyze verify`, Python byte-compilation and unit tests, every
package name checked against the Debian index, a boot image assembled and
inspected with `unpack_bootimg` and `avbtool info_image`, and the minimal
root filesystem build end to end.

## 16. Updates

Version 1 updates are full re-flashes of `boot_b` and `userdata` with
`build/flash.sh`, after `build/verify-release.sh` checks the release's
signature (minisign) and hashes. This erases Persistent Storage; the user
exports it first. The designed path to in-place updates mirrors Tails'
incremental upgrade model on A/B slots: a signed upgrade description
listing `boot` and `live` images with hashes and a monotonically
increasing version; the updater writes to the inactive slot, flips it
with `qbootctl`, and marks success only after the first successful boot.

## 17. Hardware support status for Antumbra

| Feature | Status | Note |
|---|---|---|
| Boot from stock bootloader | expected to work | identical boot contract to the port's v0.2.0-alpha.2 |
| Display, touch, GPU | expected to work at 60 Hz | 90 Hz disabled |
| Wi-Fi with MAC spoofing | expected to work | the modem processor runs with its radio in low-power mode |
| Tor over Wi-Fi, firewall, DNS | expected to work | verified by the self-check at boot |
| Suspend, charging | expected to work | Warp charging unsupported; USB-host charging may be limited to the default |
| Speakers, handset microphone | expected to work | earpiece and headset unsupported; generic UCM profiles |
| Cameras | preview and raw capture | no production image quality |
| Bluetooth | off, roadmap | driver stack works on the 6.17 line |
| Calls, SMS, mobile data | out of scope | |
| Fingerprint | never | |
| Persistent Storage | expected to work | FDE has not been validated by the port either |

## 18. Repository layout

```
antumbra/
  README.md, VERSION, LICENSE (GPL-3.0-or-later), Makefile
  docs/                      this document, threat model, device, building, flashing, legal,
                             roadmap, known issues, porting map, research notes, validation checklist
  build/                     build and flash scripts (bash), build/lib/common.sh
  device/oneplus-hotdog/     sources.lock, cmdline.txt, bootimg.conf, keys/, firmware/*.sha256,
                             kernel/{antumbra.config, patches.list, port-patches.sha256, patches/, antumbra-dts-overrides.dtsi}
  config/rootfs/             files installed over the Debian root filesystem (the overlay)
  config/packages/           package lists (base, amnesia, network, session, phosh, apps)
  config/hooks/              scripts run inside the chroot at build time, in numeric order
  config/squashfs-excludes
  tests/                     lint.sh, check-packages.sh, unit/
  vendor/tails/              the Tails 7.11 files this derives from, with PROVENANCE.md
```

## 19. Open questions to resolve on hardware

1. **Modem radio pinning.** Whether this firmware accepts
   `persistent-low-power` directly from `shutting-down`, whether the
   setting survives a modem restart, and whether a low-power modem still
   answers emergency-camping requests. The self-check reports the
   operating mode and registration state.
2. **Welcome under bare phoc.** Squeekboard and a GTK4 application before
   `gnome-session` is how phrog's greeter works, but Antumbra's exact
   sequence has not run on hardware.
3. **vbmeta.** Antumbra reuses the port's vbmeta with flags = 3. Whether an
   image generated by `avbtool make_vbmeta_image --flags 3` works equally
   must be tested before the build can be self-contained.
4. **dm-verity through live-boot** on the loop partition.
5. **RTC alarm wake-up** from s2idle for the auto-shutdown timer.
6. **Power.** The cost of keeping the modem in low-power mode rather than
   fully stopped, and whether the port's power-domain fixes hold with
   Antumbra's service set and the SLPI disabled.
7. **Audio routing** with Debian's generic UCM profiles.
8. **90 Hz.** Stays off until the port's DSI issue is fixed upstream.
