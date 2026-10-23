# Threat model

Antumbra for Android inherits Tails' threat model and adds what a phone,
Android and Stage 1's root access change. The honest summary: it keeps the
destination and content of an app's connections away from the local network
and the Internet provider, blocks known trackers for most apps, and forgets
the network state and, from W8, the session, as long as the phone is in
your physical control, its firmware is not already compromised, and the
Antumbra module is running. It cannot verify its own boot, it runs on firmware frozen
in 2022 and a kernel past its support, and in Stage 1 it relies on root.

Nothing here has been tested on the phone. "v0" in the table means built and
checked in CI or on a build machine (`../README.md`, Status); "planned" names
the item in `queue.md`.

## Assets

- Who you talk to and what you say or read online.
- The fact that you use Tor at all (weaker: see the *Censor* row).
- The phone's identifiers: Wi-Fi MAC address, IP address and IPv6 prefix of
  the networks it joins, IMEI and IMSI, serial numbers.
- Everything that was in the session: files, keys, history, passwords.
- The contents of Persistent Storage.

## Adversaries and what they get

| Adversary | Attack | Antumbra's answer | Status |
|---|---|---|---|
| Local network observer, Wi-Fi operator, Internet provider | sees destinations and content | only tor's process leaves the phone; other TCP is passed into Tor, DNS goes through the filter to Tor, everything else is refused, IPv6 is dropped; nothing leaves before Welcome's Start | v0; emulator leak test; phone capture after the install |
| Same | links sessions by MAC address | a new random address for every connection; Android's DHCP lease memory kept in RAM, so the phone does not ask for the last session's IP address | v0. Stage 1 still sends the DHCP vendor class `android-dhcp-16`; hidden networks are refused at import (W10) |
| Same | learns the device's name, model or presence | Android 15 and later send the device's name (`Settings.Global.DEVICE_NAME`, by default the model) in DHCP option 12 on every Wi-Fi network, from NetworkStack's packet socket below the firewall, unless restricted; Welcome restricts it on open and secure networks at boot and at every Start (`WifiManager.setSendDhcpHostnameRestriction`); Wi-Fi Direct and tethering forbidden; NFC off; Bluetooth off outside Administration | **[likely] fixed in v0**, unverified: no capture has checked option 12 yet; the leak analyser fails on it after arm (`dhcp-hostname`), in CI and in the phone capture (`install.md`, section 9). The vendor class still names Android 16 |
| Same, on an IPv6 network | the phone gets a global IPv6 address that apps can read and send through Tor, revealing the household's /64 prefix | IPv6 switched off on every interface as it comes up, router advertisements dropped, the filter answers no AAAA records | v0; a short window per interface (at most 10 s) in which a link-local address can exist; the router-advertisement test in CI is planned. Prefer networks without IPv6 until the phone confirms it |
| Same, on a network that hands out a public IPv4 address directly | any app can read the address and send it through Tor | none | residual |
| An app | asks the router for the public IP address (UPnP, status pages) | TCP to the LAN is passed into Tor, which refuses private destinations; other LAN traffic is refused | v0 (sandbox test) |
| An app | reaches tor's control interface and points tor at an address it controls | there is no ControlPort; tor's control socket is a file only root and uid 2950 can open; apps may use only loopback ports 9040, 5335 and 5380 | v0 |
| An app (any app with network access, started at boot) | takes tor's TransPort `127.0.0.1:9040` (or 9053, or the filter's 5335 and 5380) while its owner is not listening: before Start (tor opens no ports while its network is off), for a whole offline session, while tor or the filter restarts. The firewall redirects every app's and system service's TCP there, so the squatter would receive other apps' connections with their original destinations and content, and tor could no longer open its port | only the owner may answer on these ports: the firewall drops packets from 9040 and 9053 whose socket is not tor's, and from 5335 and 5380 whose socket is not the filter's, so no handshake completes and no DNS answer arrives; the module checks who holds the ports at every turn of its loop (2 to 5 s), again right after a turn's look at the cell radio and the words to Welcome (MOD11's on the calls, WEL8's on the cell radio), and before switching tor's network on, and while another uid holds one it removes `antumbra.fw.armed` and puts the firewall back to armed (nothing is redirected, nothing leaves) until the port is free; the filter checks that 9053 belongs to tor before each query | v0 (module end-to-end test: an app holding 9040 before Start). Residual: until the next check a squatter on 5335 receives DNS queries (names, which it cannot answer); a squatter can keep the network closed (denial of service). The complete fix, tor holding 9040 and 9053 from boot with the firewall keeping it off the Internet until Start, changes the contract (decision D11). CI probe planned (CI8) |
| An app | learns that you made an emergency call or when, or makes Quick power off skip its wait after one | the module (root) tells Welcome alone whether the calls of the last 5 minutes were emergency calls, through Welcome's provider, which takes the word from uid 0 only and has no way to read it back; nothing about calls or IMS goes into `status.json` or a property (every app can read both), a file or the log; `/proc` hides root's command lines from apps. Quick power off skips its wait only after a call the module knows was ordinary (read again after it ended), in a Phone-mode session only, and waits whenever it cannot tell: outside Phone mode every call reads unknown (with the cell radio off, a carrier call there is an emergency call, a Wi-Fi call or follows a switch-on by something else, which the module cannot tell apart) | built (MOD11), unit and sandbox tests; forging as the shell user is checked on the emulator (a failure since run 20). Residual: root can give Welcome any word (root is the module's equal); outside Phone mode an app can see the radio come on (`airplane_mode_on` is readable by every app), which suggests an emergency call or text; it relaxes only in Phone mode (WEL8), which the per-phone gate keeps off on the phone until PH3, and outside it every call reads unknown even with Wi-Fi calling on (until MOD7); in Phone mode, a binder failure between Telecom and a live phone process (Telecom then records an emergency call as not one) is not seen; Android 17 gives the module no record, so Quick power off waits after every call |
| An app | goes around the tracker filter | DNS to any address is redirected to the filter; DNS over TLS and known DNS-over-HTTPS servers are refused; tor has no SOCKS port | v0. Not covered: DoH servers not on the list, hard-coded addresses, CNAME-cloaked trackers, first-party tracking (`design.md`, section 6) |
| An app | asks the Wi-Fi firmware to send keepalive packets for it, from the real address, below the firewall | a resource overlay sets the number of keepalive offload slots to 0 | built; untested (GrapheneOS fixed this in its own code in October 2026; LineageOS has not) |
| An app with location or nearby-device access | locates you through Tor (GNSS, Wi-Fi BSSIDs, scan results, Bluetooth) | Location off and its settings locked in every session (Administration no longer lifts it since WEL8; WEL9 brings per-app location); Bluetooth off; scanning while off disabled; time zone forced to UTC | Bluetooth outside Administration (its loosening lasts until shutdown); location and nearby-device permission grants are not yet set to denied for every app (planned); sensor calibration and other hardware fingerprints are residual |
| An app (no permission) | learns whether the phone has a SIM, whether it is locked, and whether the phone has service (the cellular radio on) | nothing: Android gives every app the SIM's state per slot and the service state without a permission (Welcome reads both the same way, renouncing location, and reads no identifier) | residual: an app can tell Phone mode from Phone off, and a SIM from none; with the radio on it can also read the SIM's country and operator without a permission (DOC4) |
| An app | links sessions through what it can read (time zone, locale, hardware values) | UTC forced; locale is global and stays | partial |
| An app that knows you (an account) | identifies you through Tor | out of scope, as in Tails | — |
| Application exploit | gets root and removes the firewall | apps never get root: Magisk's "Device owner only" denies `su` outside user 0, and sessions run in other users (W8); the Magisk app is hidden outside updates (planned); tor and the filter hold no capabilities | partial (see *Root in Stage 1*) |
| Application exploit in the DNS filter | turns a parsing bug into a way out | the filter is memory-safe Go, runs as uid 2951 with no capabilities, and the firewall lets it reach only tor's DNSPort | v0; its SELinux domain is still Magisk's (planned) |
| Someone with a cable | gets a shell, or a root shell, through adb (official builds are userdebug: "Rooted debugging", or Magisk's `su` for the shell) | Welcome switches USB and wireless debugging off when it becomes the device owner and keeps them off (`DISALLOW_DEBUGGING_FEATURES`, adb settings set to 0) at every boot and in every session, Administration included; target also `ro.debuggable=0` and adb keys deleted at boot | v0 for a release Welcome. Open: during the install, before Welcome is the device owner, adb is on; a testOnly Welcome with its test hook (CI, and the install's capture) keeps adb until the hook is switched off; `ro.debuggable=0` and deleting `adb_keys` are planned (MOD4) |
| Malware in the session | persists across sessions | throwaway users from W8; module updates are never fetched automatically (no `updateJson`) | planned; in v0 sessions run in user 0 and persist |
| Someone who takes the powered-off phone | reads the last session | session keys exist only in memory (W8); network state was on a tmpfs | partial: see *What Stage 1 leaves behind* |
| Someone who takes the running phone and forces a warm reset | boots their own image with `fastboot boot` and reads memory, including the session's file-encryption keys, an unlocked Persistent Storage key and Tor Browser's memory | not defended: the bootloader is unlocked and wipes nothing first; Qualcomm's crash-dump mode is switched off at boot, which closes one capture path [likely]. Only powering off and waiting about a minute helps; a restart is not enough | residual, documented |
| Evil maid with brief access | replaces the system, the boot image or the module | not defended: no verified boot on this phone, and EDL is reachable | residual, documented |
| Censor | blocks Tor | bridges entered at the Welcome screen | partial: in v0 only plain bridges work (lyrebird for obfs4, WebTunnel and meek_lite is not built yet), and plain bridges reach Tor but do not hide that you use Tor (Welcome says so); Snowflake is never accepted, since it needs UDP; bridges must have IPv4 addresses |
| Mobile network, IMSI catcher | tracks the phone by IMSI and IMEI, locates it by cell | the cellular radio off from power-on and in every session without Phone mode; Phone mode (calls and texts, WEL8) only when chosen at Start, never before it (D12), and only where the phone's gate allows it (none as installed; PH3 decides) | in Phone mode the carrier and anyone on its network see the SIM's identity, the IMEI and the serving cells, so roughly where you are, all the time, and every call's and text's metadata and the content of ordinary calls and texts: Phone mode is not anonymous, and Welcome says so ("What your carrier sees"); a new Wi-Fi address changes neither the IMEI nor the IMSI; the modem stays powered and outside the firewall (*The phone itself*) |
| Mobile network, Internet provider | sees the phone's own traffic over mobile data | mobile data off in every session that did not choose it (switched off again if something switches it on); a mobile-data session (WEL8) sends only Tor's traffic over it, the firewall unchanged; mobile data stored as off for every SIM Android knows, at every boot and at shutdown (Android reads it before any app runs) | over mobile data through Tor the carrier sees encrypted Tor traffic and that you use Tor (and plain bridges do not hide it); the mobile-data choice is the emulator's only until FW9 (an IPv6-only APN never connects meanwhile) and CI12; a SIM Android has never seen starts with mobile data on, and so does one switched on in a session that ended in a crash; such a boot without the module goes online in the clear (*When the module does not run*). Hence the SIM inserted PIN-locked, its PIN typed only after a start known to be normal, the first start after an update made without the SIM (D3; Android's PIN screen covers Welcome's warnings) |
| Global passive adversary | correlates traffic entering and leaving Tor | out of scope, as for Tails | — |
| Hardware or firmware backdoor (baseband, TrustZone, GPU firmware) | anything | out of scope | — |
| You | reveal who you are inside Tor | out of scope; Tails' warnings apply | — |

## The phone itself

These cannot be fixed by Antumbra, in either stage.

- **No verified boot.** The bootloader stays unlocked: official LineageOS
  turns boot verification off in vbmeta, and no project has relocked this
  phone with its own key (avbroot lists OnePlus as no longer compatible;
  /e/OS, DivestOS and AXP.OS mark it as not relockable). Never try to relock
  it: on this phone that can brick it. Anyone who has the phone unattended can
  replace its software, and nothing on the phone can tell.
- **Qualcomm's emergency download mode (EDL)** is reachable on this phone. It
  lets someone holding the phone replace partitions and possibly read memory.
  It cannot be switched off.
- **Frozen firmware.** OnePlus stopped firmware updates in December 2022; the
  vendor firmware (bootloader, TrustZone, modem, Wi-Fi, GPU) is at the
  2022-12-05 patch level. NVD lists the Snapdragon 855 (SM8150) for the Adreno
  GPU bugs CVE-2025-21479 and CVE-2025-21480, which were exploited in real
  attacks; CVE-2025-21479 is in CISA's Known Exploited Vulnerabilities list
  since 2025-06-03. Whether the 4.14 kernel carries all the kernel-side fixes,
  and whether the rest needs firmware this phone will never get, is
  **[unknown]**.
- **Kernel 4.14.** LineageOS's `hotdog` kernel is 4.14.357-openela; OpenELA's
  support for 4.14 ended in December 2024. LineageOS merges Android's monthly
  security fixes into the system, but the kernel has no upstream path forward.
- **The modem and the Wi-Fi firmware are outside the firewall.** On SM8150 the
  Wi-Fi firmware runs inside the modem's DSP, so every Wi-Fi frame passes
  through frozen 2022 firmware that sits below Android's firewall and is
  reachable over the air. "No SIM" removes carrier traffic, not the modem.
  LineageOS runs the vendor's `rmt_storage`, so the modem's file system (EFS)
  can keep its own records across sessions **[unknown]**, in Stage 2 too.
  Bluetooth and NFC are off by default.
- **Below netfilter.** Packets sent through `AF_PACKET` sockets (root and
  system daemons with `CAP_NET_RAW`, Android's DHCP client) never enter the
  firewall; nor do firmware offloads (keepalives, APF) or the tethering
  offloads (tc-BPF, Qualcomm IPA). Tethering and Wi-Fi Direct are forbidden
  and the keepalive slots are set to 0; the rest is residual. A traffic-control
  egress filter on `wlan0` is a possible later addition.
- **Persistent Storage guessing limits** come from the processor's TrustZone
  (gatekeeper, keymaster), whose firmware dates from 2022. There is no separate
  secure chip (no StrongBox, no Weaver). Use a long passphrase.

## Root in Stage 1

Stage 1 needs root, through Magisk, for one thing: the module that loads the
firewall before Android starts and keeps network state in RAM.

- **What has root:** the module's boot scripts, the one-shot firewall loader,
  `resetprop`, and the Magisk app in user 0, which always has root. tor and
  the DNS filter run as their own UIDs with no capabilities; Magisk's own
  `su` would have kept every capability since v30.7, so it is not used.
- **What does not:** apps. Magisk's "Multiuser mode: Device owner only"
  denies `su` to every Android user but user 0, and sessions run in other
  users from W8. Until then (v0) an app in user 0 can ask Magisk for root,
  and Magisk asks the person on screen. Magisk's "Superuser access: Disabled"
  setting, still in v31.0, was removed from Magisk's master branch, so nothing
  relies on it.
- **SELinux:** the module's scripts, tor and the filter run in Magisk's own
  domain, which is close to permissive. A confining domain is planned.
- **Updates:** Magisk installs a module zip without checking any signature.
  The module has no `updateJson`, so Magisk never fetches one; control of the
  repository or its releases does not reach phones by itself. Updates are
  installed by hand, and later through Welcome after a pinned-key signature
  check.
- **The debug base:** official LineageOS builds are userdebug. With developer
  options, "Rooted debugging" and a cable, adb gives a root shell, and adb
  settings, persistent logging and adb keys are device-wide and persistent.
  Welcome switches USB and wireless debugging off as soon as it is the
  device owner and keeps them off in every session, Administration
  included; device-owner restrictions persist across restarts, so they hold
  from the start of every boot. Still open in v0: `ro.debuggable=0`,
  deleting `adb_keys` and resetting persistent logging at boot (MOD4); adb
  during the install, before Welcome is the device owner; and a testOnly
  Welcome's test hook, which keeps adb on for CI and must never stay on in
  a phone in use (`design.md`, section 13).

Stage 2, Antumbra's own non-debug build, removes Magisk and this whole
section.

## When the module does not run

Without the module there is no firewall. It does not run after Magisk's Safe
Mode (one volume-key press at boot, which disables every module for later
boots too), after a LineageOS update installed without Magisk's "Install to
inactive slot" step, after a slot switch, or after a major upgrade that
replaced the boot image until Magisk is installed again. (A module that is
only switched off in the Magisk app is different: the module's early arm
script in `post-fs-data.d` still arms the firewall, and that boot has no
network at all.)

What still protects such a boot: there is no saved shared Wi-Fi network on
flash to join (while the module ran, the shared store was kept only in
RAM); Android keeps the fail-safe settings (no connectivity check, no
network time, no location assistance, no scanning, mobile data off for
every SIM Android knew); and Welcome keeps Wi-Fi off and locked when
`antumbra.fw.armed` is not set. Welcome decides from that property alone,
which only root can set; the status page, which any app could serve when
the filter is absent, never counts.

What does not:

- **A SIM.** With a SIM whose mobile data is on, the phone would go
  online over the mobile network in the clear, with no saved network and
  before Welcome runs; system traffic such as the LineageOS Updater would
  leave outside Tor. Welcome cannot stop it: it locks Wi-Fi only, and a
  device owner cannot switch airplane mode. The module stores the cellular
  radio as off from power-on (`enable_cellular_on_boot=0`, MOD6), so the
  radio stays off as the phone starts, and stores mobile data as off for
  every SIM Android knows, at every boot and at shutdown. This happens only
  once the radio is switched on (airplane mode switched on and off, or an
  emergency call, which Android always allows), and then with a SIM
  Android has never seen (LineageOS switches mobile data on for a new
  SIM), or with one switched on in a session that ended in a crash or
  power loss instead of a clean shutdown (a mobile-data session, WEL8).
  Hence no SIM at LineageOS's first boot (`install.md`), a SIM locked with
  a PIN, and the PIN typed only after a start known to be normal (the
  first start after an update made without the SIM card): in a boot
  without the module, a locked SIM never connects (D3). Welcome cannot type
  the PIN (Android's own SIM-PIN screen asks for it, over the Welcome
  screen, which then cannot show its warnings) and says when to type it.
- **Networks joined by hand.** A network joined by hand in such a boot
  connects in the clear, and system services (the LineageOS Updater,
  location assistance) may then send traffic outside Tor. Welcome removes
  the network again at shutdown; after a crash or power loss it stays
  saved on flash, and the next boot without the module can join it for the
  seconds before Welcome removes it.
- **User 0's credential-encrypted Wi-Fi store** (networks added without
  "share", network suggestions apps had approved, Passpoint configurations)
  is not kept in RAM. Welcome removes saved networks at every shutdown and
  boot; whether that also clears approved suggestions and Passpoint
  configurations is **[unknown]**. Whatever is left there can be joined.
- **Airplane mode.** If Wi-Fi was switched on in airplane mode, Welcome
  cannot switch it off (only Settings may); the removed networks and the
  Wi-Fi restrictions leave it nothing to join.

## Apps with their own Tor

Tor Browser cannot use the system's tor (Tor Browser issue #43438), and
Briar and OnionShare bring their own too. From W9 they get a narrow
exception: they may connect directly, but only to current Tor relays and the
bridges configured at Welcome. The risks:

- If Tor Browser itself were compromised, it could connect to a relay the
  attacker runs and reveal the phone's IP address to that relay. A relay list
  cannot tell an honest relay from a hostile one.
- Two tor clients on one IP address show two sets of guards on the wire,
  which makes Antumbra users easier to tell apart.
- Only bridges with fixed addresses can be listed. Snowflake and meek cannot
  be used by these apps.
- A capture cannot tell the system tor's relay connections from an exempt
  app's, or from any app that managed to reach a relay; CI therefore
  attributes each relay connection on the device to tor or an exempt UID.
- In v0 the relay list is empty: these apps cannot connect at all.

## What Stage 1 leaves behind

Stage 1 forgets by moving data to RAM and by throwaway users whose keys
exist only in memory. It does not crypto-erase the device as a whole. User 0
has no credential and the bootloader is unlocked, so anything stored with
device-level keys can be read by whoever boots their own image, without any
passphrase.

Forgotten at power-off in v0: saved shared Wi-Fi networks, the DHCP lease
memory, tor's state, the runtime directory and its logs. Planned for W8 (moved to
RAM as well): DropBox crash records, tombstones and ANR traces,
graphicsstats (the apps used in the last three days), netstats, procstats,
the vendor's crash dumps, Wi-Fi Direct groups, location data, Bluetooth
pairings, and the session itself.

What stays, also after W8:

- Android's user serial counter (how many sessions there have been) and the
  Persistent Storage user's metadata: that it exists, when it was created,
  when it was last unlocked.
- batterystats and app-ops history; Settings, including the time zone and
  locale. A session's own Settings changes (MAC "keep", mobile data switched
  on) are undone at a clean shutdown only; after a crash or power loss they
  stay until the next boot with the module.
- Apps installed during a session (`/data/app`).
- User 0's credential-encrypted Wi-Fi store (networks added in user 0
  without sharing, approved network suggestions, Passpoint configurations).
- Whatever the vendor's services keep under `/data/vendor` that is not on
  the list, `/persist`, `/metadata`, the modem's file system, and the
  gatekeeper's records.
- On the first boot after the module is installed, NetworkStack's data
  directory may not exist yet; that boot's lease memory reaches flash and is
  deleted at the next.

A restart is not erasure against someone holding the phone: memory survives
a warm reset (the *forced reset* row above).

## What a packet capture cannot show

The firewall passes every UID's TCP into Tor (section 13 of `design.md`), so
anything Android or a vendor service still sends after L0 reaches its server
through Tor instead of being blocked: for example location assistance with
the chip's serial number, DRM provisioning, update checks, OEM telemetry. A
capture on the wire shows only Tor. The tests therefore log the names the
system looks up and fail on unexpected destinations, and NFLOG can record
each redirected flow with its UID. The emulator has no Qualcomm services, so
the phone's own vendor traffic is known only after the install capture.

## Fingerprinting

- Very few people run Antumbra; its users stand out on the network (Tor
  traffic from a phone, two guard sets with Tor Browser) and to apps
  (LineageOS, the `hotdog` model, a readable `antumbra.fw.armed` property).
- The tracker list is the same for everyone and updates only as a whole, so
  the list itself does not tell users apart.
- Tor Browser is not filtered or changed, so that it looks like every other
  Tor Browser for Android.

## What Antumbra does not do

- It does not make calls or SMS anonymous, and it does not put the modem
  behind the firewall.
- It does not verify its own boot chain, and cannot on this phone.
- It does not patch the firmware or the kernel beyond what LineageOS ships.
- It does not hide from the local network that a device uses Tor, and in
  v0 not with bridges either: plain bridges, the only ones it accepts, do
  not hide it (obfs4 or WebTunnel would, once lyrebird ships).
- It does not protect against an adversary who had the phone before
  Antumbra was installed, or while it was out of your control.
- It does not stop apps from using the microphone or camera when they have
  permission, and the phone has no kill switch.
- It does not make apps you log in to anonymous.
- It has not been reviewed by the Tails project, the Tor Project or anyone
  else, and it has not run on the phone.

## Assumptions

- You install official LineageOS builds whose checksums you checked, and an
  Antumbra module and Welcome app whose checksums and signatures you checked.
- You keep the phone in your physical control, and you power it off, rather
  than restart or lock it, before it leaves your sight or crosses a border.
- After every LineageOS update you follow the update steps, Magisk's
  "Install to inactive slot" included, before using a network.
- You use no SIM card unless you accept that calls, SMS and the modem are
  outside Tor, and that a boot without the module may go online over mobile
  data in the clear. In any case none is in the phone at LineageOS's first
  boot, before the module exists.
- You prefer networks without IPv6 until the phone has confirmed that IPv6
  stays off.
