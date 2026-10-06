# Threat model

Antumbra inherits Tails' threat model and adds what a phone changes. The
honest summary: it protects the content and destination of your
communications and leaves no trace on the device, as long as the device is
in your physical control and its hardware and firmware are not already
compromised.

## Assets

- Who you talk to and what you say or read online.
- The fact that you use Tor at all (weaker: see *Censorship* below).
- The phone's identifiers: Wi-Fi MAC address, hostname, IMEI and IMSI.
- Everything that was in the session: files, keys, history, passwords.
- The contents of Persistent Storage.

## Adversaries and what they get

| Adversary | Attack | Antumbra's answer | Status |
|---|---|---|---|
| Local network observer, Wi-Fi operator, ISP | sees destinations and content | the firewall allows only Tor to leave the device; DNS goes to Tor; IPv6 is dropped | shipped |
| Same | links sessions by MAC address | `macchanger` on every interface at session start (on this port the firmware address is random anyway); random MAC in scans; no hostname or client identifier in DHCP | shipped; MAC survival across suspend to be validated |
| Same | finds hidden networks the phone probes for | hidden-network profiles are refused | shipped |
| Mobile network operator, IMSI catcher | tracks the phone by IMSI/IMEI, locates it by cell | the modem radio is pinned to low-power mode (no IMSI attach, RF off); no ModemManager; the control channel is capability-gated so no app can turn the radio on | shipped; behaviour of this firmware in low-power mode without a SIM is unmeasured |
| Application exploit (browser) | reads files, reaches the network directly, uses the camera | Tor Browser runs in its own network namespace reaching only Tor; the firewall rejects everything else. Camera: nothing yet. The browser runs as the session user, who can open the camera devices (logind access) and PipeWire's camera nodes (PipeWire's default for programs outside Flatpak) directly, and the camera portal maps every program installed in the system to one shared decision, so its prompt is no barrier: once any of them is allowed, the portal hands the browser a connected PipeWire file descriptor on request, and any program in the session can write that decision into the portal's permission store itself. The raised front camera shows front-camera use; the rear cameras show nothing (`camera.md`) | partly: network isolation shipped; an allow-list AppArmor profile for the browser is planned: no camera device, neither of PipeWire's sockets (`pipewire-0`, `pipewire-0-manager`), and on the session bus only what the browser needs, so not the camera portal, the permission store, the systemd user manager or D-Bus activation (which would start an unconfined helper) |
| Application exploit | escalates to root | no setuid helper of Antumbra's own; sudo only for the Tor Browser launcher (argument-filtered) and, if enabled, with the user's own passphrase; Debian's usual setuid programs remain (`su`, `mount`, `passwd`, `fusermount3`, polkit's and D-Bus's helpers and, with Android apps, LXC's `lxc-user-nic`, which allows no user a network device; Waydroid's `pkexec` loses its setuid bit); QRTR, ptrace, BPF, kexec and debugfs restricted | shipped |
| Android app (images built with Android apps, turned on for the session) | reaches the network directly, identifies the device, uses the camera or microphone | its traffic can reach only Tor's two listeners for Android; Android reports a generic Waydroid identity and cannot read the device tree; no camera devices in the container; the microphone is behind Android's own permission prompt | partial: Android is a weaker sandbox than the host (see *Android apps* below) |
| Malware in the session | persists across reboots | read-only verity-covered root, RAM overlay, no writable flash except the unlocked Persistent Storage | shipped |
| Someone who takes the powered-off phone | reads what was in RAM or on flash | memory zeroed on free and flushed at shutdown; nothing on flash except the LUKS2 volume (argon2id) | shipped; LPDDR4X remanence unmeasured |
| Someone who takes the locked, running phone | waits for a vulnerability, keeps it alive | screen lock with passphrase; auto-shutdown after 18 h locked, also from suspend | shipped; RTC alarm wake-up to be validated |
| Someone who takes the running phone and forces a reset | reboots into a memory-dumping image | not defended: an unlocked bootloader cannot verify what boots next, and a forced PMIC reset skips the orderly shutdown. Only a short lock-to-shutdown timer and shutting down before handing the phone over help | residual risk, documented |
| Evil maid with brief access | replaces the OS or boot image | not defended (no verified boot on an unlocked bootloader). The verity root hash in the boot image detects tampering with the root filesystem alone; a labelled USB medium cannot hijack the boot because the live partition is found by UUID on the internal storage and USB devices are not authorised in the initramfs | partial |
| Censor | blocks Tor | plain bridges, and obfs4, webtunnel, meek_lite, obfs2 and obfs3 bridges through Tor Browser's `lyrebird`; bridge lines entered at the Welcome screen, at every boot | partial: snowflake bridges do not work (snowflake needs UDP, and the firewall lets Tor make only TCP connections and DNS queries; the Welcome screen refuses them); no QR-code or Moat flow yet |
| Global passive adversary | correlates traffic entering and leaving Tor | out of scope, as for Tails |
| Hardware or firmware backdoor (baseband, TrustZone, GPU firmware) | anything | out of scope. The modem shares the SoC; its isolation from application memory on SM8150 is not documented publicly |
| You | reveal who you are inside Tor | out of scope; Tails' warnings apply |

## Android apps

Only in images built with `ANTUMBRA_ANDROID=1`, and off until the user
turns them on at the Welcome screen for a session (`architecture.md`,
sections 8.5 and 11.1). While they are on:

- **Android root is host root.** Waydroid runs Android in a privileged
  LXC container, without a user namespace. LXC's authors state that
  privileged containers "aren't and cannot be root-safe". What separates
  the container from the host: Waydroid's seccomp profile (no module
  loading, kexec, reboot, swap or kernel keyrings; the set-time calls do
  nothing), the capabilities it keeps (Antumbra drops `sys_time`; it keeps
  `sys_admin`, `net_admin` and `net_raw`), a device-cgroup rule against
  cameras, and Waydroid's AppArmor profiles, which are in complain mode
  (they log, they do not block). A compromise of Android's system, not
  just of an app, is a compromise of the host, including its Tor
  enforcement.
- **No SELinux.** The kernel has no SELinux, so Android's SELinux policy is
  not enforced: Android apps are separated from each other by Linux users
  and Android's seccomp filter only, less than on a stock phone.
- **Binder is open to every local user.** Waydroid's host-side session runs
  as the user and talks to Android through binder, so Waydroid makes the
  binder devices mode 0666 while the container runs. The host user,
  `amnesia`, has UID 1000, which is Android's `AID_SYSTEM`, and binder
  reports the caller's UID as it is: any program running as the user,
  Tor Browser included, can call Android's system services with Android's
  system privileges, and owns Android's system files under
  `~/.local/share/waydroid/data`. Waydroid also opens the GPU render node,
  the DMA-BUF heaps and the framebuffers to every user (0777). Once the
  container stops (Android stopped in the session, or logout), Waydroid's
  container service is stopped too: the binder devices and the DMA-BUF
  heaps go back to 0600 and udev re-applies its modes to the render node
  and the framebuffers. Binder itself is kernel attack surface with a long
  history of bugs.
- **Waydroid's D-Bus service** accepts Stop, Freeze, Unfreeze and
  GetSession from any local user (Start checks the caller), so any process
  can stop or freeze Android.
- **One Tor identity.** All Android apps share one Tor client address;
  streams are isolated per destination only. Apps you log in to identify
  you, as anywhere. Container root can craft arbitrary packets, but they
  reach only Tor's two listeners for Android and the DHCP server: the
  rules that decide this run on the host, and the container's start-host
  hook refuses to start Android without them.
- **`.onion` names.** Tor answers Android's lookups of them with addresses
  on Android's own loopback (127.192.0.0/10). The start-host hook rejects
  that range inside the container, so that no app receives what another
  app meant for an onion service; Android's root could remove that rule.
- **Microphone.** Android reaches the session's PulseAudio socket
  (`pipewire-pulse`); recording is gated only by Android's own permission
  prompt, not by the host.
- **Fingerprinting by apps.** Android reports Waydroid's generic product
  values and cannot read the device tree, but apps can still read the
  kernel release (it names the SoC and the phone's port), the CPU model,
  the GPU through OpenGL, the screen size, and the container's MAC address,
  which every Waydroid installation shares. An app can tell it runs on an
  SM8150 phone under Antumbra. What would tell it *which* phone, and so
  link amnesic sessions, is hidden as far as Antumbra knows, but the list
  is checked only in the VM so far (`hardware-validation.md`, item 55):
  - *Masked:* Android gets a generic kernel command line instead of the
    host's (where the boot loader puts `androidboot.serialno`, which would
    become `ro.serialno`). In the container's sysfs, the SoC's, the UFS
    device's and the disks' serial numbers and SCSI identifiers, any SD
    card's CID, any EEPROM's contents, device-mapper UUIDs (unlocked
    Persistent Storage's is its LUKS UUID) and the partitions' `uevent`
    files (their GPT unique GUIDs; whether the factory partitions' differ
    from phone to phone is not known) read empty. Every nvmem provider's
    directory is empty: on the phone that is the SoC's QFPROM fuse region,
    which the kernel shows everyone and which holds per-chip calibration
    and, very likely, the chip's serial number. The RTC's directory and
    `/proc/driver/rtc` are empty too: the phone's PMIC RTC cannot be set
    from Linux and should count from its first power-up, so its reading
    minus the real time would be a constant of the phone. These masks
    cover the devices present when the container starts; the container
    refuses to start with one unmasked, in its configuration or in what
    it would see (a mask LXC failed to mount, which it skips: the
    start-host hook reads each identifier through the container's own
    root after LXC's mounts), but something plugged in while
    Android runs (a USB device's serial number) is readable until Android
    is next started. The container's sysfs belongs to its own network
    namespace, so the host's network interfaces and Wi-Fi radio (their
    MAC addresses, the factory one included) are not in it. Apps get no
    Bluetooth socket (the kernel allows those only in the host's network
    namespace; Bluetooth is off anyway) and no QRTR socket (the modem's
    and DSPs' services, the IMEI's among them; Antumbra's kernel allows
    them only with `CAP_NET_ADMIN`).
  - *Not masked:* what is the same on every 7T Pro (SoC model and
    revision, memory size, the kernel's configuration); slowly drifting
    values a determined app could still correlate across sessions, such
    as the battery's measured capacity and cycle count; accessories'
    identifiers other than USB serial numbers (a USB keyboard's serial
    number again in its input device's `uniq`, a monitor's in its EDID).
    Android's root, unlike its apps, is root on the host as well and can
    read anything, the kernel log with the serial number included.
  On the host itself, `/proc/cmdline` still shows the serial number to
  every local process, and the identifiers above stay readable there.
- **Frozen images.** The LineageOS 20 images are those pinned at build
  time and receive no updates until Antumbra pins new ones. They are built
  by Waydroid's small team, are not reproducible, and are verified only by
  the SHA-256 that Waydroid's update channel lists, with no signature.
  F-Droid's APK carries F-Droid's signatures; apps installed from F-Droid
  update through F-Droid, over Tor.
- **Persistent Storage.** The `android` feature keeps Android's apps and
  data, and with them Android's own usage history (usage statistics,
  recent apps, logs), on the encrypted volume.

## What Antumbra does not do

- It does not make the phone a phone: no calls, SMS or mobile data.
- It does not verify its own boot chain.
- It does not hide that a device is running Tor from the local network
  unless bridges are used.
- It does not protect against an adversary who had the phone before you
  flashed it.
- It does not protect against microphone or camera use by an application
  running in your session, prompt or not; the phone has no kill switch,
  and only the front camera shows when it is in use (it rises).
- It does not isolate Android apps as well as a stock phone does, nor
  isolate the host from Android's system, when Android apps are on.
- It has not been reviewed by Tails, Tor Project or anyone else, and has
  not run on hardware.

## Assumptions

- You flash your own build or a release whose signature you verified.
- You keep the phone in your physical control and shut it down, rather
  than suspend it, when that matters.
- The firmware you provide for your own device is the firmware OnePlus
  shipped for it.
