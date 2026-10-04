# Antumbra architecture

Antumbra is an amnesic, Tor-enforcing mobile operating system for the
OnePlus 7T Pro (codename `hotdog`). It takes the design of Tails, the
Amnesic Incognito Live System, and rebuilds it for an arm64 phone on
Debian 13 "trixie" with the Phosh mobile shell.

Tails is a trademark of the Tails project. Antumbra is an independent
derivative and is not endorsed by Tails or by the Tor Project.

This document is the engineering reference for the project. Every
hardware fact in it comes from the fact-checked research summarised in
`docs/research-notes.md`; the few points that still need validation on a
physical phone are listed in section 19.

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
   by default, and the cellular radio never attaches to a network unless
   the user explicitly opts in (and is warned what that reveals).
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
| Working on the port | UFS, GPU (Freedreno/Turnip), display at 60 Hz, touch, Wi-Fi (incl. suspend), USB-C (dual role, DisplayPort out), speakers and handset mic, all four cameras (raw capture), s2idle suspend, charging, haptics, NFC reader mode (6.17 line) |
| Partial or broken | Bluetooth (fixed on 6.17 r13 via the `hsuart0 = &uart13` alias; broken on 6.16), 90 Hz display, earpiece/headset audio, modem (boots, scans, nothing SIM-validated), GNSS (engine starts, no fixes), sensors (SLPI, needs vendor firmware 2.2-00083 and a libssc build of iio-sensor-proxy), fingerprint (never) |

The port is a one-developer project in alpha. Antumbra inherits its
hardware status and does not claim anything the port has not validated.

## 3. System overview

```
 OnePlus bootloader (ABL, unlocked, slot B)
   │  loads boot_b: Android boot image v2 = Linux 6.17 Image + initramfs + DTB
   │  applies dtbo_b, consults vbmeta_b (verification disabled)
   ▼
 initramfs (Debian initramfs-tools + live-boot + Antumbra hooks)
   │  qbootctl marks the slot successful
   │  losetup -P --sector-size 4096 on the `userdata` partition exposes the nested GPT
   │  live-boot mounts /live/filesystem.squashfs read-only + tmpfs overlay
   ▼
 systemd (Debian 13 arm64)
   │  nftables Tor-enforcement ruleset loaded before any network device exists
   │  Wi-Fi driver blocked; Tor started with DisableNetwork 1
   ▼
 Phosh session, auto-login as user `amnesia`
   │  Welcome screen: Persistent Storage unlock, MAC spoofing, offline mode,
   │  admin password, screen-lock passphrase
   │  → network unblocked, MAC spoofed, Tor Connection assistant
   ▼
 Applications reach the network only through Tor (SocksPort, TransPort, DNSPort)
```

## 4. Storage layout

Antumbra follows the port's current (v0.2.0) layout: the operating system
lives in the Android `userdata` partition, inside a nested GPT with
4096-byte logical sectors. Slot A keeps the user's Android (OxygenOS or
LineageOS) boot and recovery, which is the escape hatch.

```
userdata (physical Android partition, written with fastbootd `fastboot -S 128M flash userdata`)
└── GPT, 4096-byte sectors
    ├── p1  ANTUMBRA_LIVE   ext4, read-only at runtime
    │         /live/filesystem.squashfs   the root filesystem (xz, arm BCJ)
    │         /live/antumbra.manifest     package list, build id, hashes
    │         /.disk/info                 live-boot medium marker
    └── p2  ANTUMBRA_DATA   LUKS2 (argon2id) → ext4, the Persistent Storage
              created unformatted at flash time; formatted by the Welcome
              screen only when the user asks for Persistent Storage
```

Why not `super`: the port moved from `super` to `userdata` in v0.2.0
because the bootloader's fastboot stalled on large `super` transfers, and
because `userdata` is the partition Android expects to be user-owned.
Why a nested GPT: Linux does not scan partition tables inside a
partition; the initramfs runs `losetup --sector-size 4096 -P` on
`userdata`, which yields `loopXp1`/`loopXp2`, and live-boot then finds the
medium by filesystem label. This is what the port's initramfs does.

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

- The kernel is an uncompressed arm64 `Image`; the DTB goes in the v2 DTB
  field, not appended.
- The ABL truncates the command line at 511 bytes and ignores
  `extra_cmdline`. Boot-critical parameters come first.
- `fastboot boot` is refused by this ABL; every test is a flash.
- The AVB footer is unsigned (`--algorithm NONE`). It is a format
  requirement, not a security feature.
- Required kernel parameters from the port: `iommu.passthrough=0
  arm-smmu.disable_bypass=0 clk_ignore_unused`. `console=ttyGS0` must not
  be set (it trips the SLPI watchdog path in the port's notes).
- `avbtool` is not packaged in Debian; the build fetches `avbtool.py`
  from AOSP `external/avb` at a pinned commit with a recorded SHA-256.

Antumbra kernel command line (version 1):

```
boot=live live-media=/dev/disk/by-label/ANTUMBRA_LIVE live-media-path=/live
union=overlay nopersistence noprompt noautologin timezone=Etc/UTC
module=antumbra iommu.passthrough=0 arm-smmu.disable_bypass=0 clk_ignore_unused
slab_nomerge slub_debug=FZ init_on_free=1 init_on_alloc=1 page_alloc.shuffle=1
randomize_kstack_offset=on systemd.condition_needs_update=no quiet splash
```

Compared with Tails' command line, the x86-only options (`mce=0`,
`vsyscall=none`, `mds=full,nosmt`, `spec_store_bypass_disable=on`,
`efi_pstore.pstore_disable=1`, `erst_disable`) are dropped, and
`page_poison` is deliberately absent: on this kernel `page_poison=on`
would disable `init_on_free`, the mechanism Tails relies on for memory
erasure.

## 6. Initramfs

Debian's `initramfs-tools` generates the initramfs inside the chroot when
the Antumbra kernel package is installed. live-boot supplies the live
medium logic. Antumbra adds:

- `scripts/live-premount/05-antumbra-loop`: waits for
  `/dev/disk/by-partlabel/userdata`, runs `losetup --sector-size 4096 -Pf
  --direct-io=on` on it, runs `udevadm settle`, and creates the
  `/dev/disk/by-label/ANTUMBRA_LIVE` symlink itself if udev has not.
- `scripts/init-top/01-antumbra-slot`: runs `qbootctl -m` so the
  bootloader's boot-retry counter is reset. Without this the slot becomes
  unbootable after seven boots.
- `hooks/antumbra`: copies `losetup` (util-linux, for `--sector-size`),
  `qbootctl`, the GPU firmware the display needs for early output, and the
  touch and panel modules into the initramfs.
- `hooks/antumbra-shutdown` and the matching `initramfs-shutdown.service`:
  on shutdown systemd returns into an unpacked copy of the initramfs
  (`/run/initramfs`), which unmounts the overlay, drops the page cache and
  powers off. This is Tails' memory-erasure design minus the removable
  medium.

The initramfs contains **no** USB gadget networking, no DHCP server, no
serial console and no shell. The postmarketOS initramfs the port uses
exposes RNDIS networking with SSH and a passwordless root console on
`ttyGS0`; Antumbra ships none of that. A debug variant can be built with
`ANTUMBRA_DEBUG=1`, which is never used for release images.

## 7. Amnesia and memory

| Mechanism | Antumbra | Tails equivalent |
|---|---|---|
| Root filesystem | squashfs, read-only, with a tmpfs overlay (live-boot `union=overlay`) | same |
| Writes to flash | none without Persistent Storage; `nopersistence` on the cmdline | same |
| Swap | zram only (`systemd-zram-generator`, zstd), never disk swap; `swapon` wrapped like Tails' `05-replace_swapon` | zram |
| Memory zeroing | `init_on_free=1 init_on_alloc=1` on the cmdline | `init_on_free=1`; Debian's kernel has `INIT_ON_ALLOC_DEFAULT_ON` |
| Shutdown | overlay `rw`/`work` directories removed late in shutdown, return to initramfs to unmount everything | same |
| Emergency shutdown | long press of the power button (`HandlePowerKeyLongPress=poweroff`), a lock-screen "Shut down now" action, and an auto-shutdown timer that fires after a configurable time locked (default 18 h, GrapheneOS's auto-reboot default) | pulling the USB stick (udev-watchdog), which has no equivalent on UFS |
| Suspend | allowed, but the Welcome screen warns that suspend keeps keys in RAM; the auto-shutdown timer still runs | n/a |
| Journal and logs | `Storage=volatile`, `rsyslog` not installed | same |

## 8. Tor enforcement

### 8.1 Firewall

Tails enforces Tor with a ferm-generated iptables ruleset keyed on the
Unix user of the socket owner. Antumbra ports `ferm.conf` to native
nftables (`/etc/nftables.conf`), because the port's kernel builds nftables
but not the legacy `xt_owner` match, and because ferm 2.5 only emits
iptables syntax. The semantics are kept one-to-one:

- Output policy `drop`; established connections accepted; everything
  else that is not matched is logged (`Dropped outbound packet:`) and
  rejected with port-unreachable.
- User `debian-tor` may open any TCP connection and send UDP DNS. Nobody
  else may leave the device directly.
- User `amnesia` (UID 1000) may connect only to Tor's local ports:
  SocksPorts 9050/9062 (not 9063, not the ControlPort 9052), DNSPort
  5353 via the redirect of UDP 53, and TransPort 9040. All of its other
  TCP traffic to the Internet is transparently redirected to 9040 (nat
  `redirect to :9040`); RFC 1918 destinations are reachable directly but
  LAN DNS and NetBIOS are rejected, as in Tails.
- Mapped `.onion` addresses (`127.192.0.0/10`, Tor's
  `AutomapHostsOnResolve` range) are redirected to the TransPort.
- `_apt`, `proxy`, `nobody` may use SocksPort 9050; `htp` (time sync) may
  use 9062; `root` may reach the ControlPort 9052 and the control-port
  filter on 951.
- `clearnet` may reach anything on non-loopback interfaces (used only
  by the pre-Tor clock step and the Unsafe Browser, both opt-in).
- IPv6: everything dropped except loopback.
- Network namespaces: the Tor Browser, OnionShare and the Tor Connection
  assistant run in their own namespaces (`tbb`, `onionshare`, `tca`, and
  `clearnet` for the Unsafe Browser) wired to the host with veth pairs in
  `10.200.1.0/24` and reach Tor only via SocksPort `10.200.1.1:9050` and
  the control-port filter on 951, exactly as Tails' `tails-create-netns`
  does. The namespace addresses are hard-coded in torrc, the firewall and
  the onion-grater filters, so they are kept verbatim.
- Forwarding is dropped; the TTL of the clearnet namespace is reset to 64
  so the Unsafe Browser is not fingerprintable by a LAN observer.

The ruleset is loaded by `nftables.service` before `network-pre.target`
and is never flushed on stop (Tails' `no-drop-on-stop` drop-in). A
NetworkManager dispatcher script re-applies it on every interface event.
The kernel config fragment enables `NFT_REDIR`, `NFT_FIB_INET` and the
connection-tracking netlink pieces the ruleset needs (section 13).

### 8.2 Tor configuration

`/etc/tor/torrc` is Tails' torrc unchanged: SocksPorts 9050/9062/9063
on loopback with destination isolation, `10.200.1.1:9050` for the
browser namespace, `ControlPort 9052` with cookie authentication,
`DNSPort 5353` with `AutomapHostsOnResolve`, `TransPort 9040`,
`Sandbox 1`, `AvoidDiskWrites 1`, `DisableNetwork 1` until the user has
chosen how to connect. The `tor@default.service` drop-ins (writable
`/etc/tor` for SAVECONF, `resolv.conf` override, no `NoNewPrivileges`
for pluggable transports) are carried over.

The control port is never exposed to applications directly. Tails'
`onion-grater` (Python, stem) listens on 951 and applies per-application
YAML allow-lists (Tor Browser, OnionShare, Onion Circuits, Tor
Connection). It is vendored from the Tails tree.

Bridges and pluggable transports: `obfs4proxy` 0.0.14 from Debian trixie
(protocol-compatible with current obfs4 bridge lines) and
`snowflake-client` 2.5.1. `webtunnel` and `lyrebird` are only in Debian
unstable and are added when they reach trixie-backports, or taken from
the aarch64 Tor Browser tarball if it ships them.

### 8.3 DNS and name resolution

`/etc/resolv.conf` is a static file pointing at `127.0.0.1`.
NetworkManager runs with `dns=none` and `dhcp=internal` so it never
touches it. UDP 53 to loopback is redirected to Tor's DNSPort 5353.
`systemd-resolved` is not installed. There is no IPv6 resolution because
IPv6 is disabled by sysctl on every interface except loopback.

### 8.4 Time

Tor needs a roughly correct clock, and a phone has no trusted time
source: the modem's NITZ time is a tracking channel and NTP is a leak.
Antumbra ports Tails' two-step design:

1. Optional pre-Tor step, run as user `clearnet` and only with the user's
   consent in the Tor Connection assistant: fetch a captive-portal
   detection URL and set the clock from the HTTP `Date` header
   (`tails-get-network-time`).
2. After Tor has bootstrapped: `htpdate` over SocksPort 9062 as user
   `htp`, taking the median of three pools of HTTPS servers, accepting
   not-yet-valid certificates for the reason explained in Tails' design
   notes.

`systemd-timesyncd` and `hwclock-save` are masked. ModemManager is not
installed, so NITZ cannot reach the clock.

## 9. Radio and hardware policy

### 9.1 Wi-Fi

- The Wi-Fi driver module (`ath10k_snoc`, plus `ath10k_core`) is
  blocklisted at build time and loaded only after the Welcome screen has
  recorded the MAC-spoofing decision (`antumbra-unblock-network`, Tails'
  `80-block-network` / `tails-unblock-network` pattern).
- Every new Ethernet-type interface triggers `antumbra-spoof-mac` from a
  udev rule: `macchanger -e` (keeps the OUI, randomises the device part),
  three attempts; on failure the module is unloaded and the interface is
  reported to the user, exactly as `tails-spoof-mac` does. Changing the
  MAC with `ip link set address` is confirmed to work on WCN3990.
- NetworkManager: `wifi.cloned-mac-address=preserve` (the udev step owns
  the address, as in Tails), `wifi.scan-rand-mac-address=yes`,
  `ipv4.dhcp-send-hostname=false`, `ipv6.dhcp-send-hostname=false`,
  `ipv4.dhcp-client-id=stable`, `connection.stable-id=${CONNECTION}/${BOOT}`,
  `hostname-mode=none`, `ipv6.ip6-privacy=2`, `dns=none`, `dhcp=internal`.
  Hidden-network profiles are refused (they broadcast the SSID in probes).
- Hostname is `amnesia` and is never sent on the wire.

### 9.2 Cellular modem

The modem (MPSS) is a remote processor whose firmware the kernel loads
through `remoteproc`. On this SoC the Wi-Fi firmware stack and the modem
are tightly coupled (the port notes that `wlan0` survives "a modem
crash" only after dedicated patches), so **whether Wi-Fi can work with
the modem processor stopped is an open question** (section 19). The
policy is therefore defined in two layers:

1. **Radio off, always.** No ModemManager, no `hotdog-radio-bootstrap`,
   no `msm-modem` tooling. If the modem processor has to run for Wi-Fi,
   `antumbra-modem-radio-off.service` puts it into persistent low-power
   mode over QMI (`qmicli --dms-set-operating-mode=persistent-low-power`)
   as soon as the QRTR service appears, and `antumbra-selfcheck` verifies
   the operating mode on every boot. A modem in low-power mode does not
   camp on cells, so neither IMSI nor IMEI are broadcast, even without a
   SIM.
2. **Processor off when possible.** If hardware testing shows Wi-Fi does
   not need the MPSS, `remoteproc` for the modem is never started
   (`rmtfs`, `pd-mapper`, `tqftpserv` are not installed), which also
   removes the IPA/rmnet attack surface.

Cellular data as an opt-in "cellular session" with explicit warnings is
on the roadmap, not in version 1.

### 9.3 Bluetooth, NFC, GNSS, sensors, cameras, microphones

| Radio or sensor | Default | Mechanism |
|---|---|---|
| Bluetooth | off | `rfkill block bluetooth` in a unit ordered before `bluetooth.service`; the Welcome screen can enable it for the session; when enabled a random public address is set with `btmgmt public-addr` before power-on (plan: the controller only works on the 6.17 r13 kernel) |
| NFC | off | `nxp_nci_i2c` and `nxp_nci` blocklisted in `modprobe.d`, `rfkill block nfc` |
| GNSS | off | lives in the modem (QMI LOC); nothing starts it, and it is inert in low-power mode |
| Motion, light, proximity sensors | unavailable to apps | `iio-sensor-proxy` is not installed (trixie's build has no SLPI backend anyway); the SLPI firmware is still loaded because the ultrasonic proximity path shares the DSP stack |
| Cameras | available, no indicator | libcamera via PipeWire and the GNOME portal permission prompts |
| Microphones | available | PipeWire; the Welcome screen offers "mute microphones for this session" |

Cameras and microphones have no hardware kill switch on this phone;
software policy is the only control, as on every phone.

### 9.4 USB

The phone is a USB gadget most of the time (charging). Antumbra ships no
gadget function at all: no RNDIS/NCM networking, no ACM console, no MTP,
no ADB-like debug. In host mode (a dock or an OTG adapter) `usbguard`
runs with `ImplicitPolicyTarget=block` and `PresentDevicePolicy=apply-policy`
and the user authorises devices from the shell. A "charge only / file
transfer" chooser is on the roadmap.

### 9.5 Boot security, honestly

The bootloader is unlocked and shows the "Orange state" warning at
every boot. Android Verified Boot is disabled (vbmeta flags = 3), so
nothing anchors the boot image or the root filesystem to the hardware,
and an attacker with the phone in hand can replace them. This is the
same assumption Tails makes (physical control of the device). Antumbra
mitigates what it can:

- Persistent Storage is LUKS2 with argon2id (memory cost 1 GiB, 4
  iterations, mirroring Tails' `tps` parameters) and is only ever opened
  from the running system with the user's passphrase.
- The squashfs root is covered by a `dm-verity` hash tree whose root hash
  is embedded in the boot image command line. It does not resist an
  attacker who replaces the boot image, but it makes silent tampering with
  the root filesystem alone detectable at boot. `DM_VERITY` is enabled in
  the kernel fragment; this feature is behind `ANTUMBRA_VERITY=1` until
  validated on hardware because it adds a second loop device and a
  `veritysetup` step in the initramfs.
- No swap on flash, zeroing on free, shutdown instead of suspend when the
  user wants amnesia.

## 10. Session, Welcome screen and lock screen

The shell is Phosh (phoc compositor, squeekboard on-screen keyboard),
the same stack Mobian ships on Debian. The display manager question
(Debian's `phosh.service`, or `greetd` with `phrog`) is being resolved
against the actual package contents (section 19); whichever is used, the
behaviour is:

1. The system boots straight into a Phosh session for user `amnesia`
   (UID 1000, no password, as in Tails). Network is blocked and the
   Wi-Fi module is not loaded.
2. `antumbra-welcome`, a full-screen GTK4/libadwaita application started
   by a user unit that the shell waits for, asks the Tails Welcome Screen
   questions in phone form:
   - unlock Persistent Storage (passphrase via squeekboard), or create it;
   - MAC address anonymisation (on by default);
   - network: connect normally / configure a bridge first / offline mode;
   - administration password for this session (off by default; enables
     `sudo` for `amnesia`);
   - screen-lock passphrase for this session (strongly recommended; the
     Persistent Storage passphrase can double as it);
   - Unsafe Browser on/off (off by default);
   - mute microphones (off by default).
   It writes the answers as `KEY=value` files to
   `/var/lib/antumbra/settings/{persistent,transient}` (the Tails greeter
   file format and keys: `tails.password`, `tails.macspoof`,
   `tails.network`, `tails.unsafe-browser`, `tails.create-persistence`),
   so Tails' shell library (`tails-greeter.sh`) and Python helpers keep
   working.
3. A privileged one-shot (`antumbra-apply-welcome-settings.service`,
   triggered through polkit) applies them: sets the admin password with
   `chpasswd -e`, installs the sudoers rule, configures the screen lock,
   activates persistence features, and finally runs
   `antumbra-unblock-network`, which loads the Wi-Fi driver (triggering MAC
   spoofing) and starts NetworkManager.
4. The Tor Connection assistant (Tails' `tca`, run in the `tca`
   namespace) takes over: automatic connection, or bridge configuration
   (manual bridge lines, QR code scan is on the roadmap), optional
   pre-Tor clock fix, and the "Tor is ready" notification.

Lock screen: Phosh's lock screen authenticates through PAM. If the user
set a lock passphrase the session locks on the power button and after a
timeout; the lock screen carries a "Shut down now" button
(`antumbra-emergency-shutdown`), and the auto-shutdown timer (section 7)
runs while locked.

## 11. Applications

| Role | Package or source | Notes |
|---|---|---|
| Browser | Tor Browser for Linux aarch64 from the 16.0 alpha channel (`tor-browser-linux-aarch64-16.0aN.tar.xz`), OpenPGP-verified at build against the Tor Browser Developers key | The only official Tor Browser for this architecture. Stable 15.0.x is x86 only. Tor Project advises at-risk users against the alpha; the Welcome screen and docs say so. Runs as the `amnesia` user in the `tbb` namespace with Tails' launcher, prefs and AppArmor profile; switches to the stable tarball the day one exists for aarch64. |
| Unsafe Browser | the same binary in the `clearnet` namespace, Tails' overlay/bwrap design | opt-in, for captive portals |
| File sharing | OnionShare 2.6.3 (CLI and GTK) | Qt GUI is usable on the phone but not adaptive |
| Passwords | GNOME Secrets (KeePass format), KeePassXC as an alternative | Secrets is adaptive |
| Metadata | Metadata Cleaner (`mat2` back end) | adaptive |
| Files, images, documents, text | Nautilus, Loupe, Papers, GNOME Text Editor, GNOME Console | all adaptive GTK4 |
| Email and chat | none by default; Chatty (XMPP/Matrix) is an optional feature | Thunderbird is not adaptive and Tails' patched build is x86 |
| Crypto wallet | Electrum (as Tails ships) | optional feature |
| Camera | Megapixels | raw capture quality only |
| Encryption | GnuPG, `gnome-keyring`, Kleopatra omitted | |

No app store or Flatpak by default (Tails' Additional Software feature is
on the roadmap as a Persistent Storage feature).

## 12. Persistent Storage

The Tails Persistent Storage service (`tps`, Python, UDisks, cryptsetup)
is vendored with its D-Bus service and feature definitions. Differences:

- The LUKS2 volume is the pre-allocated `ANTUMBRA_DATA` partition of the
  nested GPT rather than a partition created on a USB stick; `tps`'s
  parent-device discovery is pointed at the loop device instead of the
  boot medium. The partition keeps Tails' type GUID
  (`8DA63339-0007-60C0-C436-083AC8230908`) so its tooling recognises it.
- Features offered in version 1: Persistent Folder, Welcome Screen
  settings, Network Connections, Tor Bridges, Tor Browser bookmarks,
  Secrets/KeePass database, GnuPG, SSH client, Dotfiles. Features are
  bind mounts applied through a `nosymfollow` view of `/`, as in Tails.
- The Welcome screen creates the volume on first use (`cryptsetup
  luksFormat --type luks2 --pbkdf argon2id --pbkdf-memory 1048576
  --pbkdf-force-iterations 4`) and the format is reflected in a
  `persistence.conf` so live-boot could also mount it in a future
  initramfs-based design.

## 13. Kernel

Source: `gitlab.com/sm8150-mainline/linux` at `v6.17.0-sm8150` with the
27-patch series from the port, applied in order, then the Antumbra
configuration fragment merged over
`config-oneplus-hotdog-mainline617-clean.aarch64`. Built with Debian's
cross toolchain (`crossbuild-essential-arm64`, GCC) via `make
bindeb-pkg`; `LLVM=1` is supported because the port builds with clang.

The fragment (`device/oneplus-hotdog/kernel/antumbra.config`) changes
the port's configuration where the research found gaps:

| Option | Why |
|---|---|
| `CONFIG_NFT_REDIR=m`, `CONFIG_NFT_FIB_INET=m`, `CONFIG_NF_CT_NETLINK=m`, `CONFIG_NETFILTER_XT_MATCH_OWNER=m`, `CONFIG_NETFILTER_XT_TARGET_LOG=m` | the Tor-enforcement ruleset needs `redirect`, reverse-path checks and conntrack tooling; `xt_owner` keeps `iptables-nft` compatibility for Tails scripts |
| `CONFIG_SQUASHFS_ZSTD=y`, `CONFIG_SQUASHFS_FILE_DIRECT=y`, `CONFIG_SQUASHFS_DECOMP_MULTI_PERCPU=y` | the port only enables gzip/lz4/lzo/xz and single-threaded decompression; xz stays the default image codec, zstd becomes available |
| `CONFIG_DM_VERITY=y` | root filesystem integrity (section 9.5) |
| `CONFIG_SECURITY_APPARMOR=y`, `CONFIG_LSM="landlock,lockdown,yama,loadpin,safesetid,integrity,apparmor,bpf"`, `CONFIG_SECURITYFS=y`, `CONFIG_SECURITY_LOCKDOWN_LSM=y` | the port has no AppArmor; Tails' confinement of Tor Browser, OnionShare and Tor depends on it |
| `CONFIG_KEXEC=n`, `CONFIG_CRASH_DUMP=n`, `CONFIG_DEVMEM=n`, `CONFIG_DEBUG_FS=n`, `CONFIG_IKCONFIG=n` | attack surface the port needs for bring-up and a release does not |
| `CONFIG_MODULE_SIG=y`, `CONFIG_MODULE_SIG_FORCE=y`, `CONFIG_MODULE_SIG_ALL=y` | only modules from the build load |
| `CONFIG_INIT_ON_FREE_DEFAULT_ON=y`, `CONFIG_INIT_ON_ALLOC_DEFAULT_ON=y`, `CONFIG_RANDOMIZE_KSTACK_OFFSET_DEFAULT=y` | the command line enables them too; defaults make a truncated command line safe |
| `CONFIG_ZRAM=y`, `CONFIG_ZRAM_DEF_COMP_ZSTD=y` | zram swap without module loading in early boot |
| `CONFIG_USB_CONFIGFS=n` and all `USB_CONFIGFS_*`, `CONFIG_USB_G_*=n` | no USB gadget functions in a release kernel (section 9.4) |

The port's `CONFIG_ONEPLUS_HOTDOG_EARLY_BOOT=y` and `CONFIG_QCOM_WDT`
handling are kept as-is: they are what makes the kernel boot from the
ABL at all.

## 14. Firmware and licensing

Every radio, the GPU, the DSPs and the modem need proprietary firmware
that OnePlus and Qualcomm do not license for redistribution, and the
GPU's `a640_zap.mbn` is signed per device. Debian's `firmware-qcom-soc`
contains nothing for SM8150. Therefore:

- Published Antumbra images contain **no device firmware**. The build
  pulls firmware from a directory the builder provides
  (`ANTUMBRA_FIRMWARE_DIR`), populated by `build/fetch-firmware.sh` from
  the community mirror the port uses
  (`github.com/sm8150-linux-mainline/firmware-oneplus-hotdog`, pinned
  commit, SHA-256 manifest) for the user's own device, with the legal
  caveat spelled out in `docs/legal.md`.
- Firmware needed per feature: `qcom/a630_sqe.fw`, `qcom/a640_gmu.bin`,
  `qcom/sm8150/oneplus/hotdog/a640_zap.mbn` (display and GPU);
  `ath10k/WCN3990/hw1.0/{firmware-5.bin,board-2.bin}` and
  `qcom/sm8150/oneplus/hotdog/wlanmdsp.mbn` (Wi-Fi);
  `qcom/sm8150/oneplus/hotdog/{adsp,cdsp}.mbn` (audio, DSP);
  `modem.mbn` (modem processor, possibly required for Wi-Fi);
  `qca/crbtfw21.tlv`, `qca/crnv21.bin` (Bluetooth); `venus.mbn` (video);
  `slpi.mbn` version 2.2-00083 only for sensors, which Antumbra does not
  expose.
- The per-device proximity calibration and the SLPI registry from the
  phone's `persist` partition are never needed because sensors are off.

## 15. Build pipeline and reproducibility

```
build/build.sh                      orchestrates the steps below; every step is idempotent
  fetch-sources.sh                  kernel tree + port patches + avbtool + Tor Browser tarball, all pinned and hash-checked
  kernel.sh                         cross-compile, bindeb-pkg → linux-image-*.deb + dtb
  rootfs.sh                         mmdebstrap (root mode, arm64, trixie, pinned snapshot) + overlay + hooks → directory
  squashfs.sh                       mksquashfs -comp xz -Xbcj arm -b 1M -all-root -noappend, SOURCE_DATE_EPOCH
  image.sh                          mke2fs -d (live partition) + systemd-repart (4096-byte-sector GPT) → userdata.img
  bootimg.sh                        mkbootimg v2 + avbtool footer → boot.img
  release.sh                        zstd, split < 1.9 GiB, SHA256SUMS, manifest
build/flash.sh                      guided fastboot/fastbootd flashing with backups and safety checks
```

Reproducibility: `SOURCE_DATE_EPOCH` from the git commit everywhere
(mmdebstrap, mksquashfs, mke2fs, kernel `KBUILD_BUILD_TIMESTAMP`), apt
pinned to a `snapshot.debian.org` timestamp, fixed filesystem UUIDs and
GPT GUIDs (`systemd-repart --seed`), `/etc/machine-id` empty, no
`resolv.conf` or `hostname` leaked from the build host, and the package
manifest recorded in the image.

Hosts: any Debian/Ubuntu x86_64 machine with `qemu-user-static` (the
rootfs step runs arm64 maintainer scripts under emulation, about 3x
slower), or a native arm64 machine. In CI the `ubuntu-24.04-arm` runner
builds the rootfs natively; the kernel is cross-built on x86_64.
Validation performed in this repository's CI without hardware: shellcheck,
`nft -c` on the ruleset, `tor --verify-config`, Python byte-compilation,
unit tests of the helpers, a real arm64 rootfs build of the package set,
and `unpack_bootimg` on the produced boot image.

## 16. Updates

Version 1 updates are full re-flashes of `boot_b` and `userdata` with
`build/flash.sh`, after `build/verify-release.sh` checks the release's
signature (minisign) and hashes. Persistent Storage survives because the
flash script writes only the live partition when `--keep-data` is given
(the LUKS partition is left untouched).

The designed path to over-the-air updates mirrors Tails' incremental
upgrade kit model on A/B slots: a signed upgrade description lists
`boot` and `live` images with hashes and a monotonically increasing
version; the updater writes to the inactive slot, flips it with
`qbootctl`, and marks success only after the first successful boot.
This needs a per-slot live partition, which the nested GPT can hold.

## 17. Hardware support status for Antumbra

| Feature | Status | Note |
|---|---|---|
| Boot from stock bootloader | expected to work | identical boot contract to the port's v0.2.0-alpha.2 |
| Display, touch, GPU | expected to work at 60 Hz | 90 Hz disabled |
| Wi-Fi with MAC spoofing | expected to work | needs the Wi-Fi/modem question answered (section 19) |
| Tor over Wi-Fi, firewall, DNS | expected to work | validated by the self-check script on first boot |
| Suspend, charging | expected to work | Warp charging unsupported |
| Speakers, handset microphone | expected to work | earpiece and headset unsupported |
| Cameras | preview and raw capture | no production image quality |
| Bluetooth | plan | only on the 6.17 r13 kernel line; off by default |
| Calls, SMS, mobile data | out of scope | |
| Fingerprint | never | |
| Persistent Storage | expected to work | FDE has not been validated by the port either |

## 18. Repository layout

```
antumbra/
  README.md                  what it is, status, quick start
  LICENSE                    GPL-3.0-or-later (Tails is GPL-3+)
  docs/                      this document, threat model, device, building, flashing, legal, roadmap
  build/                     build and flash scripts (bash, shellcheck-clean)
  device/oneplus-hotdog/     kernel config fragment, boot parameters, pinned sources and hashes
  config/rootfs/             files copied over the Debian root filesystem (the overlay)
  config/packages/           package lists
  config/hooks/              scripts run inside the chroot at build time
  tests/                     lint and unit tests (host), antumbra-selfcheck (device)
  vendor/tails/              files taken from Tails with their provenance recorded
```

## 19. Open questions to resolve on hardware

1. **Wi-Fi without the modem processor.** Does `ath10k_snoc` on this
   board work with the MPSS remoteproc stopped? Until answered, the modem
   processor runs and the radio is forced to low-power mode (section 9.2).
2. **Session manager.** Debian trixie's `phosh.service` versus `greetd`
   with `phrog` for auto-login; being decided from the package contents.
3. **vbmeta.** Antumbra reuses the port's vbmeta with flags = 3. Whether an
   `avbtool make_vbmeta_image --flags 3` image generated by the build
   works equally must be tested before the build can be self-contained.
4. **dm-verity in the initramfs** (section 9.5) on top of the loop device.
5. **Touch in early boot** for a future initramfs passphrase prompt
   (`unl0kr` is in Debian; the S6SY761 module would need to be in the
   initramfs). Not needed for version 1, where unlocking happens in the
   session.
6. **Power.** Whether keeping the modem in low-power mode (rather than
   fully stopped) costs measurable battery, and whether the port's
   power-domain fixes hold with Antumbra's service set.
7. **90 Hz.** Stays off until the port's DSI issue is fixed upstream.
