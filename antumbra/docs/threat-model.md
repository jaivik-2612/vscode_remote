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
| Application exploit (browser) | reads files, reaches the network directly, uses the camera | Tor Browser runs in its own network namespace reaching only Tor; the firewall rejects everything else. Camera: nothing yet. The browser runs as the session user, who can open the camera devices (logind access) and PipeWire's camera nodes (PipeWire's default for programs outside Flatpak) directly, and the camera portal maps every program installed in the system to one shared decision, so its prompt is no barrier. The raised front camera shows front-camera use; the rear cameras show nothing (`camera.md`) | partly: network isolation shipped; an AppArmor profile for the browser that denies the camera devices and the PipeWire socket is planned |
| Application exploit | escalates to root | no setuid helpers beyond sudo; sudo only for the Tor Browser launcher (argument-filtered) and, if enabled, the user's own passphrase; QRTR, ptrace, BPF, kexec and debugfs restricted | shipped |
| Android app (images built with Android apps, turned on for the session) | reaches the network directly, identifies the device, uses the camera or microphone | its traffic can reach only Tor's two listeners for Android; Android reports a generic Waydroid identity and cannot read the device tree; no camera devices in the container; the microphone is behind Android's own permission prompt | partial: Android is a weaker sandbox than the host (see *Android apps* below) |
| Malware in the session | persists across reboots | read-only verity-covered root, RAM overlay, no writable flash except the unlocked Persistent Storage | shipped |
| Someone who takes the powered-off phone | reads what was in RAM or on flash | memory zeroed on free and flushed at shutdown; nothing on flash except the LUKS2 volume (argon2id) | shipped; LPDDR4X remanence unmeasured |
| Someone who takes the locked, running phone | waits for a vulnerability, keeps it alive | screen lock with passphrase; auto-shutdown after 18 h locked, also from suspend | shipped; RTC alarm wake-up to be validated |
| Someone who takes the running phone and forces a reset | reboots into a memory-dumping image | not defended: an unlocked bootloader cannot verify what boots next, and a forced PMIC reset skips the orderly shutdown. Only a short lock-to-shutdown timer and shutting down before handing the phone over help | residual risk, documented |
| Evil maid with brief access | replaces the OS or boot image | not defended (no verified boot on an unlocked bootloader). The verity root hash in the boot image detects tampering with the root filesystem alone; a labelled USB medium cannot hijack the boot because the live partition is found by UUID on the internal storage and USB devices are not authorised in the initramfs | partial |
| Censor | blocks Tor | obfs4, snowflake, webtunnel and meek bridges through Tor Browser's transports; bridge lines entered at the Welcome screen | shipped; no QR-code or Moat flow yet |
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
  SM8150 phone under Antumbra. It cannot read the phone's serial numbers:
  Android gets a generic kernel command line instead of the host's (where
  the boot loader puts `androidboot.serialno`, which would become
  `ro.serialno`), and the SoC's, the UFS device's and the disks' serial
  number files in sysfs read empty in the container. On the host itself,
  `/proc/cmdline` still shows the serial number to every local process.
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
