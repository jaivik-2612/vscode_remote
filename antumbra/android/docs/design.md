# Design

This is the design of Antumbra for Android, as approved on 10 October 2026
after research by six agents, three competing designs and three independent
checks (facts, leaks, feasibility). The checks' fixes are folded in and are
requirements, not suggestions; section 12 lists them with their status in
v0. Where a part made a decision of its own, section 13 says so.

Evidence tags: **[verified]** means checked against a primary source,
**[likely]** means strong evidence but not yet tested, **[unknown]** means it
still has to be measured. Nothing in this document has been tested on the
phone.

## 1. Scope

Antumbra for Android is LineageOS 23.2 with Tails' rules added: every
connection through Tor or none, a Welcome screen at every start, a session
that is forgotten, tracker blocking in the system's name lookups, Tor
Browser as the browser, and a small set of curated apps. It targets one
phone, the OnePlus 7T Pro (`hotdog`).

It arrives in two stages:

- **Stage 1:** official LineageOS plus an Antumbra add-on that needs root
  (a Magisk module), a device-owner Welcome app and curated apps. Root is used
  only by the add-on.
- **Stage 2, if build capacity is approved:** the same parts inside
  Antumbra's own build of LineageOS, signed with its own keys, with much more
  complete forgetting.

It is not Tails and is never called Tails. `threat-model.md` says what it
does not protect against.

## 2. The base: official LineageOS 23.2 for hotdog

- **Builds:** LineageOS 23.2 (Android 16 QPR2) has weekly signed builds for
  `hotdog`; those of 2026-09-25, 10-02 and 10-09 were listed on 2026-10-10,
  the last with the 2026-10-01 security patch level **[verified, download
  API]**. Android security fixes are merged monthly (mostly quarterly upstream
  since Android 16); the vendor firmware and the kernel get no OEM updates.
- **Models:** HD1910, HD1911, HD1913 and HD1917 **[verified, LineageOS
  wiki]**. The T-Mobile 7T Pro 5G McLaren (HD1925) is another phone and is not
  supported; LineageOS's firmware steps exclude carrier-branded variants.
- **Firmware:** an Android 12 (OxygenOS 12) firmware must be on the phone
  before LineageOS is installed; LineageOS builds for `hotdog` then carry the
  firmware partitions in each update **[verified, wiki device data:
  `needs_specific_android_fw`, `ships_fw`]**. The vendor firmware is frozen at
  the 2022-12-05 patch level.
- **Kernel:** 4.14.357-openela. OpenELA's 4.14 support ended in December 2024.
  It has the netfilter features the firewall needs (owner match, conntrack,
  connmark, REDIRECT, TPROXY, `xt_bpf`, NFLOG) but no `ipset`, no `addrtype`
  match and no IPv6 NAT **[verified, `hotdog_defconfig`]**.
- **Build type:** official builds are userdebug (debug-enabled), and their
  vbmeta turns boot verification off. The bootloader cannot be relocked with
  a custom key; every project marks `hotdog` as not relockable.
- **Why LineageOS:** the largest active maintainer group for this phone,
  monthly security merges, published source revisions per build, firmware
  kept in step, no Google services, Apache-2.0. /e/OS (userdebug, microG, Tor
  as an optional VPN with exceptions), crDroid (one maintainer, not a privacy
  base), AXP.OS (Android 13 only for `hotdog`), DivestOS (ended December
  2024), GrapheneOS and CalyxOS (no support for this phone) do not fit.
- **LineageOS 24 (Android 17)** may reach `hotdog` before the install: the
  device trees had LineageOS 24 commits in September 2026. A weekly check
  watches for it, with a go/no-go in W12 (`queue.md`). Major upgrades go
  through `adb sideload` **[verified, wiki upgrade page]**, and the module
  requires API 36 until a release says otherwise.

## 3. The parts and the shared contract

Every part follows this contract exactly. Changing it means changing every
part and this section together.

**Folders:** `antumbra/android/{firewall,tor,dnsfilter,welcome,module,ci,docs}`;
CI in `.github/workflows/antumbra-android.yml`.

**On the device:**

| Item | Value |
|---|---|
| Module ID, directory | `antumbra`, `/data/adb/modules/antumbra` (`MODDIR`) |
| Runtime directory | `/data/adb/antumbra/{run,state,lists,log}`, on a tmpfs mounted at every boot |
| Binaries | `MODDIR/bin/` (`tor`, `antumbra-dnsfilter`, `antumbra-fw`); the zip carries `bin/arm64-v8a` and `bin/x86_64`, and `customize.sh` keeps the right one |
| tor | uid/gid 2950 |
| DNS filter | uid/gid 2951 (Android's `AID_OEM_RESERVED` range 2900-2999; nothing else uses them) |
| tor TransPort | `127.0.0.1:9040` |
| tor DNSPort | `127.0.0.1:9053`, reachable only by uid 2951 |
| DNS filter | `127.0.0.1:5335`, UDP and TCP, forwarding to 9053 |
| Status page | `http://127.0.0.1:5380/status` (GET, read-only JSON): `run/status.json` plus the filter's counters (queries, blocked, list size, list version) |
| tor control | no SOCKSPort, no ControlPort; `ControlSocket /data/adb/antumbra/run/tor-control.sock` (0660, uid/gid 2950) with `CookieAuthentication`; usable only by root and uid 2950 |
| Firewall | `antumbra-fw arm` (one instant rule set: all non-loopback output and all forwarding dropped, IPv4 and IPv6; first thing at boot), `apply` (the full rule set), `status` (the ruleset hash and whether it is live), `flush` (back to the armed state, never to open). Chains are named `ANTUMBRA_*` |
| Firewall published | `resetprop -n antumbra.fw.armed <sha256 prefix>`, by the module, only after `apply` succeeded and was verified, and while no other uid holds a service port (9040 and 9053 tor's, 5335 and 5380 the filter's); removed at once otherwise |
| Welcome | package `org.antumbra.welcome`, a device-admin receiver, device owner |
| Session state | `content://org.antumbra.welcome.state/session`, one row: `started` (0/1), `tor_mode` (`direct`, `bridges`, `offline`), `bridges` (one bridge line per line), `mac` (`new`, `keep`), `admin` (0/1), `unsafe_browser` (0/1), `persistent` (0/1), `session_id`, `cell` (`off`, `phone`, `data`; `off` before Start; `data` never with `offline`; WEL8). Readable only by uid 0 and 2000 (`Binder.getCallingUid()`); the module polls it with `content query`, `started:tor_mode:mac:session_id:cell`, and reads a Welcome that answers `Unknown column: cell` (one from before WEL8) without the column, its sessions keeping the cell radio off; before Start a row with a new `session_id` (a new Welcome process) is asked again with the column |
| The module's word on the last calls (MOD11) | `content call --user 0 --uri content://org.antumbra.welcome.state --method module_word` with the extras `v` (int 1), `calls` (`emergency`, `ordinary`, `unknown`, `none`), `at` (long: the module's look, seconds since boot), `until` (long: an emergency word's end, at most `at + 300`; else 0), `ims` (`cell`, `wifi`, `registered`, `none`, `unknown`, `off`), `ims_at` (long; 0 with `off`). Taken from uid 0 only (`Binder.getCallingUid()`), sent by the module only while Welcome is the device owner; Welcome answers `Result: Bundle[{v=1}]`, keeps it in memory and has no way to read it back. Never in `status.json`, a property, a file or a log |
| The module's word on the cell radio (WEL8) | `content call ... --method module_cell` with exactly the extras `v` (int 1), `gate` (`off`, `phone`, `data`: the most the module carries out on this phone now; `off` while it reads an older Welcome's row without the `cell` column), `cell` (`none` before the module read a Start; then what it carries out: `off`, `phone`, `data`), `radio` (`on`, `off`, `wait`, `unknown`: its last look at the registry) and `at` (long: that look, seconds since boot; 0 before the first). Sent when one of them changes, when Welcome's process starts again before Start, and every 5 minutes; taken from uid 0 only, the caller checked before the method or the extras are looked at; anything else is malformed and clears the word Welcome held. Welcome offers Phone and mobile data only as far as `gate` allows. Same privacy as the word on the calls |
| Phone-mode gate (WEL8) | `/data/adb/antumbra-cell`: a regular file (not a link) of root's, not writable by group or others, whose first line is exactly `phone` or `data`; anything else, or no file (as installed), is `off`. Written only by the install's PH3 step on the phone (`install.md`, section 7; kept only as PH3 decides) and by CI as root on the emulator; deleted by `uninstall.sh`. `data` counts only on the emulator until FW9 and CI12 have passed (on a phone the module stops at `phone`). The module carries out the lowest of the session's `cell`, the gate at Start and the gate now, and after Start the gate can only go down: a gate lowered during a session takes effect at once and holds until the next start, a gate raised during a session changes nothing until the next start |

**Boot sequence** (section 7 has the detail):

1. `post-fs-data.sh`, blocking, before zygote: `antumbra-fw arm` first (and
   before it, the module's early arm script in `/data/adb/post-fs-data.d`,
   which also runs when the module is switched off); a tmpfs (with the
   right SELinux context) over the Wi-Fi configuration store, so saved
   shared networks never reach flash; the DHCP lease memory (IpMemoryStore)
   cleared.
2. `service.sh`: the filter as uid 2951, tor as uid 2950 with
   `DisableNetwork 1`, `antumbra-fw apply`, the service-port owner check,
   then `antumbra.fw.armed`, `status.json`, the fail-safe Settings and
   mobile data off once the framework answers; then it waits for Welcome's
   `started=1`, trusted only while Welcome is the device owner. `offline`
   keeps `DisableNetwork 1`; otherwise it sets the bridges, if any, and
   `DisableNetwork 0` over the control socket. A session with `cell=phone`
   or `data` has the cell radio switched on at Start, never before (D12),
   mobile data off first; with `data`, mobile data then on over the live
   firewall; each only as far as the Phone-mode gate allows (none, as
   installed). In every other session mobile data is kept off.

WEL10's emergency card changes nothing in this contract: no column, no
`content call` method, no property and nothing in `status.json`. It reads
Android's emergency-number list and WEL8's readings, and its position fix
is shown on Welcome's screen alone.

## 4. Tails features on Android

| Tails feature | Antumbra on Android | How strong | What is different |
|---|---|---|---|
| Everything goes through Tor; anything else is blocked | A firewall that loads before any app starts. Stage 1: the module's `post-fs-data.sh`, which Magisk runs blocking (up to 40 s) before zygote **[verified, Magisk docs]**. Stage 2: system start-up. Only tor's process may go out; other TCP is passed into Tor's TransPort without the app's knowledge, DNS goes to the filter and through Tor, everything else is refused, for root and system services too. Nothing goes out until Welcome's Start. The rules are written for Android from scratch (section 5). | **Strong, pending the phone capture.** Stage 1 depends on the module running (section 7.3), and without it on there being no SIM. | Tails makes apps use Tor on purpose; Android apps cannot be set up that way, so they are passed through Tor. The modem, firmware offloads and packet sockets are below the firewall (`threat-model.md`). Apps with their own Tor get a narrow exception (W9). |
| Amnesia | **Stage 1:** each session is a new throwaway Android user (W8) whose encryption keys exist only in memory **[verified, AOSP vold]**; network state is kept in RAM (v0: saved Wi-Fi networks and the DHCP lease memory); system records listed in section 9 are moved to RAM in W8. **Stage 2:** the whole working storage gets a new key at every boot and is formatted. | **Stage 1: session data only. Stage 2: good, with open points (section 10).** | The phone writes to flash and destroys keys. A restart is not enough against someone holding the phone: memory survives a warm reset (`threat-model.md`). |
| Persistent Storage | **Stage 1 (W10):** a separate Android user with a long passphrase; guessing is slowed by the processor's TrustZone (gatekeeper, keymaster), whose firmware dates from 2022; there is no separate secure chip (no StrongBox, no Weaver). Welcome re-adds that user's Wi-Fi networks and bridges after the firewall is live. **Stage 2:** an encrypted area in Tails' format (LUKS2, argon2id). | **Stage 1: good, with a long passphrase. Stage 2: [unknown]** until a safe place for it exists. | All or nothing in Stage 1. The user's existence, creation and last-login times and its device-encrypted storage are readable without the passphrase. Fingerprint unlock is useful only in this user. |
| Welcome Screen | The Welcome app, a locked home screen in user 0 before the session: Internet (Wi-Fi, mobile data through Tor, or none); Tor directly or through bridges (with Internet); Phone (off, or calls and texts: not anonymous); mobile data and calls only where this phone's Phone-mode gate allows them (none as installed, section 3), shown with the reason otherwise; the SIM's state, the cellular radio, "What your carrier sees" and "About the SIM PIN"; an emergency card on this screen and the status screen (WEL10: the general emergency number Android lists now, read at run time and never written in Welcome, or every one Android ranks alike when it has none from the network, the SIM or its database; state lines for no SIM, a locked or unusable SIM, the radio off and VoLTE not connected, each saying this phone can still try and pointing to the other phone too; Show my position, one fix from the satellite receiver on request, shown in large type and sent nowhere); new Wi-Fi address (on); Persistent Storage (shown, not yet available); Administration (off); Unsafe Browser (off; shown but disabled until W11). | **Good** | It runs after Android has started, but the network stays closed until Start, as in Tails. The language is set once in Settings. Welcome cannot type the SIM PIN: Android's own SIM-PIN screen asks for it, over the Welcome screen, and Welcome (like `install.md`) says to type it only after a start known to be normal, the first start after an update being made without the SIM card. |
| MAC address anonymisation | A new random Wi-Fi address for every connection (`non_persistent_mac_randomization_force_enabled=1`), unless "keep" is chosen. The DHCP lease memory is kept in RAM so Android does not ask the router for the last session's address (DHCP INIT-REBOOT). Stage 2: GrapheneOS's DHCP-state flush and per-connection randomisation, and a neutral DHCP vendor class. | **Good** (less in Stage 1) | Stage 1 still sends the vendor class `android-dhcp-16` **[verified]**. Android 15 and later also send the device name (DHCP option 12) unless a device owner restricts it; Welcome does (`setSendDhcpHostnameRestriction`) **[likely]**, unverified until a capture checks it. Hidden networks make the phone probe for their names under every address; they are refused at import (W10). |
| Tor Browser | The official Tor Browser for Android, unchanged and signature-checked (W9). It gets uBlock Origin only if Tor Browser 17 bundles it (Tor issue #17569, labelled "17.0 stable" **[verified as open]**). | **Good** | It cannot use the system's Tor (issue #43438 **[verified as open]**), so it runs its own and may connect only to Tor relays and bridges (section 5). Android's Firefox engine has weaker internal sandboxing than the desktop one. |
| Unsafe Browser (captive portals) | Off by default. When ticked at Welcome: a dedicated WebView app with its own UID, launched by hand, bound to the Wi-Fi network, with a root helper that opens a clearnet and DNS exemption for that UID while it runs and closes it on exit, with Tails' warning (W11). Android's captive-portal detection stays off (`captive_portal_mode=0`) in every session. | **Partial** | A session-wide captive-portal switch was rejected: Android would probe Google on every connection, and any app can trigger a probe (`reportNetworkConnectivity`) at a time it chooses. |
| Curated apps | KeePassDX (for KeePassXC), Thunderbird, OnionShare (beta), Scrambled Exif (for Metadata Cleaner), Electrum, Briar and the HeliBoard keyboard, from Antumbra's signed repository, over Tor (W9). | **Good** | Android equivalents of Tails' apps, not the same programs. |
| Emergency shutdown | Quick power off. Stage 1: a Quick Settings tile and the session notification's action (v0), a trigger from a PanicKit app such as Ripple, and optionally a power-off after the phone has been locked for some hours. Each powers off: Welcome installed as a privileged app with the `SHUTDOWN` permission, or a power-off request the module carries out at once. Until then (v0) the tile restarts the phone. Stage 2: a power-menu entry. Never bound to the power button (below). | **Good** once it powers off | An app cannot add a power-menu entry in Stage 1. A forced hardware reset skips all of this. |
| Memory wiping | Qualcomm's crash-dump mode off at boot (`download_mode=0`, v0) **[likely, Stage 1]**, to be checked with a forced panic on the phone. Freed memory zeroed (`init_on_free=1`) in Stage 1 only if the kernel command line can be changed **[unknown]**; certain in Stage 2. | **Weak to partial** | No memory wipe at shutdown as in Tails. EDL cannot be switched off. |
| Nothing phones home | Android's own background connections off (section 6, L0). Anything missed cannot leave outside Tor, but it can reach its server through Tor, so tests log the system's name lookups and block every unexpected destination by name; a packet capture alone cannot show it. | **Good** | A modem with a SIM talks to the carrier outside Android, hence no SIM by default. |
| Signed images and updates | Stage 1: the system is signed by LineageOS; the module, Welcome, the apps and the repository by Antumbra, with SHA-256 sums and build provenance. The module has no `updateJson`: Magisk never fetches it. Module updates go through Welcome after a pinned-key signature check (later). Stage 2: the whole system signed with Antumbra's keys, as a non-debug "user" build. | **Partial** | No verified boot on this phone, ever. |
| Administration | The Administration option at Welcome lifts two restrictions from Start until the next shutdown: app installation from outside the preinstalled store, and Bluetooth. Location stays off and locked in every session, Administration included (WEL8; WEL9 brings "off, or on for chosen apps"); Welcome itself switches it on only for one satellite fix the person asks for, and off again (WEL10). Settings itself is reachable in every session once Start has ended Welcome's locked task. Apps never get root. Debugging stays off in every session, Administration included (v0, a test build's hook aside, section 13). | **Good**; `ro.debuggable=0` still to come (MOD4) | |
| Tracker blocking (no Tails equivalent) | Section 6. | **Good for apps** | Tor Browser is deliberately not filtered. |

**Quick power off, never on the power button.** Antumbra's immediate
power-off is called Quick power off: where the emergency number is 112, a
"panic button" on a phone means an emergency call, so no Antumbra text
names it "panic" or "emergency" (it was "Emergency off", then "Panic off").
No Antumbra action, in Welcome, the module or a later Stage 2 build, is
ever bound to presses of the power button, repeated or held. Android's own
emergency gesture (five quick presses) and the power menu's Emergency item
belong to the system, and Antumbra leaves them as they are, before Start
too: Welcome's locked task keeps the power menu
(`LOCK_TASK_FEATURE_GLOBAL_ACTIONS`) and lets emergency calls through
(`LOCK_TASK_FEATURE_KEYGUARD`), and CI checks that the power menu shows its
Emergency item there (`welcome_power_menu_emergency`; the item is never
pressed in a test). A power-menu entry for Quick power off (Stage 2) is an
item to choose, not a press pattern.

## 5. The firewall policy

The rules were derived for Android from scratch. Translating Tails' rules
(or the archived `nftables.conf`) rule for rule would give every Android app
the exceptions Tails grants its one trusted desktop user: direct access to
the local network (an app could ask the router for the public address), any
loopback TCP port (an app could reach tor's ControlPort, set a bridge it
controls and learn the real address), and "accept established" for everyone
(listening apps could answer the network). The leak check rated that a
blocker. The Debian work's Waydroid chain, which treated Android as one
untrusted guest, was the better model.

Policy, for every UID except tor's (2950):

| Traffic | Result |
|---|---|
| TCP to any destination, including the LAN, link-local and loopback ports other than the allowed ones | REDIRECT to `127.0.0.1:9040`; tor refuses private and loopback destinations |
| UDP and TCP to port 53, anywhere | REDIRECT to `127.0.0.1:5335` (the filter) |
| Loopback TCP to 9040, 5335, 5380 | allowed; an exempted app also to its own listed ports |
| Answers on loopback from 9040 or 9053 by a socket that is not tor's, or from 5335 or 5380 by one that is not the filter's | dropped, so an app that takes a service port while its owner is not listening completes no handshake and sends no answer; the module's owner check does the rest (section 7.2) |
| TCP to port 853 (DNS over TLS), and to known DNS-over-HTTPS servers | rejected, so apps fall back to the system's lookups |
| DHCP renewals (UDP 68 to 67) from the network stack (uid 1073), to private or link-local addresses and the broadcast address | allowed, so leases do not lapse (Android's first DHCP messages use a packet socket, below netfilter) |
| Everything else: other UDP (NTP, QUIC, mDNS, SSDP, STUN), ICMP, multicast, all IPv6 except `::1` for system UIDs | rejected |
| Inbound from other interfaces | dropped, except replies on connections the firewall let out, and DHCP replies from private or link-local addresses |
| Forwarding | dropped (and tethering forbidden, since its offload bypasses netfilter) |

tor (2950) may reach the Internet, but not the LAN, link-local or
multicast, and on loopback only TCP to 127.0.0.1 ports in the kernel's
ephemeral range (32768-60999), where lyrebird, its pluggable-transport
client, listens on a random port. On those connections only a socket of
uid 2950 may answer, so another app's listener in that range never
completes a handshake with tor. The filter
(2951) may reach only `127.0.0.1:9053`. Established and related traffic
leaving the phone is accepted only for tor (and for an exempt app's
connections to listed relays). The filter table decides per UID; a second,
independent gate in mangle POSTROUTING lets a packet leave a non-loopback
interface only on a connection the filter table marked. netd's own chains
still run after Antumbra's (`firewall/README.md`).

**Apps with their own Tor** (Tor Browser, Briar, OnionShare): an optional
exception list by app UID lets them connect directly, but only to addresses
in a chain of current Tor relays and configured bridges. In v0 the chain
exists and is empty, so these apps cannot connect. Filling it is W9, with
these facts setting its design: the `hotdog` kernel has no `ipset` but has
`xt_bpf`; the relay set changes every hour; only bridges with fixed addresses
can be listed (obfs4; WebTunnel only where its address is fixed
**[unknown]**; Snowflake needs UDP to changing peers and meek needs CDN
endpoints); each throwaway session is a new Android user, so the exempt UIDs
change at every boot. The options to measure are a per-UID chain matched on
new connections only, or an `xt_bpf` program with a pinned map of (address,
ORPort) pairs, refreshed by a non-root helper from the system tor's
consensus every hour and at each session start, failing closed when stale.
If rule cost on this kernel is too high, these apps use bridges only.

Kernel features used: owner, conntrack, connmark, multiport, limit,
REDIRECT, REJECT, NFLOG, in the filter, nat and mangle tables, all present
in both the `hotdog` kernel and the emulator's GKI kernel **[verified,
defconfigs]**. netd's OEM iptables hook (`setupOemIptablesHook()`) has an
empty body in AOSP `android16-release` and LineageOS `lineage-23.2`
**[verified]**, so Stage 1 hooks its chains in as rule 1 of built-in chains
that netd does not flush.

## 6. Tracker blocking, layer by layer

- **L0: Android stays quiet.** Every connection Android makes on its own is
  switched off or sent through Tor: the connectivity check that contacts
  Google (`captive_portal_mode=0`); network time (pointed at `127.0.0.1`,
  where the firewall refuses it; time checked over Tor after Tor connects, as
  Tails does, is W5); location assistance (SUPL, XTRA; `assisted_gps_enabled=0`,
  which Welcome reads and never writes: Show my position refuses while it
  is not 0; Android's own PSDS download, armed by the first fix of a boot, is
  system traffic: into Tor, the known hosts refused by name, PH5 and DNS5);
  Wi-Fi and Bluetooth scanning while off; LineageOS statistics (also blocked
  by name in the filter's own list); Google fallback DNS and Private DNS (off,
  and every DNS query is redirected to the filter anyway). Anything missed
  still cannot leave outside Tor, but it could reach its server through Tor.
  The tests therefore check
  two things: a packet capture (only Tor leaves the phone) and the log of
  names the system looks up (no unexpected destination, even through Tor).
- **L1: side doors closed.** The firewall rejects DNS over TLS (port 853), the
  known DNS-over-HTTPS servers (HaGeZi's list of 1,434 IPs), and all UDP
  other than DNS. Apps cannot reach a SOCKS port of tor's, where a lookup
  would skip the filter: there is none.
- **L2: the filter in the system's name lookups (the core).** A small program
  between Android's resolver and Tor's DNSPort answers "does not exist" for
  tracker domains.
  - It fails closed: if it stops, or tor does not answer, lookups fail.
  - Lists: HaGeZi Multi Pro (195,726 domains; HaGeZi Normal, 159,965, if too
    many apps break), HaGeZi's list of encrypted-DNS servers, and Antumbra's
    own list of LineageOS, OnePlus, Qualcomm and Google endpoints. The
    Exodus Privacy tracker signatures are off in v0: read as domains, many
    block whole sites or working services, and their licence (ODbL 1.0,
    contents DbCL 1.0) is not yet checked against HaGeZi's GPL-3.0 (queue
    DNS3; `dnsfilter/lists/sources.conf`).
  - Updates: CI builds a new list every day and signs it (W6). The phone
    fetches it over Tor, keeps it only in Persistent Storage, and otherwise
    uses the copy in the module.
  - The same list for everyone, so the list does not make anyone stand out.
  - Speed: a lookup takes microseconds against about 10 ms for Android's
    plain hosts file, measured on 195,726 domains **[verified on a server CPU;
    phone unmeasured]**.
  - It answers no AAAA records (IPv6 is off) and forwards only A and PTR
    queries; tor's DNSPort hides CNAME chains anyway.
- **L3: per-app network access.** LineageOS's per-app "Network access"
  switches. Welcome turns network access off for apps that need none:
  KeePassDX, the keyboard and Scrambled Exif. `restricted_networking_mode=1`
  makes LineageOS enforce those switches. It does not by itself deny new
  apps: LineageOS 23.2 grants restricted-mode access to every app whose switch
  is on (read in its source by the module part), so "no network" as the
  default for newly installed apps needs Welcome to switch each new app off
  as it is installed **[unknown]**. Later: a separate Tor circuit per app,
  so trackers in different apps cannot link activity through a shared exit.
- **L4: where apps come from.** Only Antumbra's curated repository by default.
  F-Droid, with its "Tracking" and "Ads" labels, in Administration sessions.
  Later: an offline scan of new apps for known tracker code (Exodus
  signatures).
- **L5: the browser.** Tor Browser exactly as the Tor Project ships it, never
  filtered by the system, so that every Tor Browser user looks alike: the Tor
  Project's and Tails' reasoning.

**What no layer can block:** tracking by the service actually used
(first-party); trackers hidden behind another name (Tor's resolver hides
CNAME chains); hard-coded addresses; DNS-over-HTTPS servers not on the list;
tracking code that sends data to shared, ordinary domains. A clean scan does
not prove that an app does not track.

## 7. Boot sequence and failing closed

### 7.1 A normal boot

| When | What | Network |
|---|---|---|
| Bootloader, kernel, init | LineageOS starts; Magisk's init patches its own policy in | none (no interface up) |
| `post-fs-data` (Magisk, blocking, before zygote and netd) | 0. The module's early arm script in `/data/adb/post-fs-data.d` runs `antumbra-fw arm` before any module, also when the module is switched off in the Magisk app (not in Magisk's Safe Mode). 1. `antumbra-fw arm`: only loopback moves, IPv4 and IPv6, for every UID. 2. The runtime tmpfs. 3. A tmpfs over `/data/misc/apexdata/com.android.wifi` (Wi-Fi's shared store), with its owner, mode and SELinux label; the flash copy deleted. User 0's credential-encrypted store is still locked here and is not covered. 4. NetworkStack's IpMemoryStore database deleted and its directory on a tmpfs. 5. `accept_ra=0`, `disable_ipv6=1` on every interface; Qualcomm crash dumps off. 6. Wi-Fi calling and video calling off (MOD7): `persist.dbg.wfc_avail_ovr` and `persist.dbg.vt_avail_ovr` to 0 in memory only (`resetprop -n`, never stored, so a boot without the module is LineageOS's own), after init.rc's own `on post-fs-data` has loaded stored persistent properties and before the phone process starts; `persist.dbg.volte_avail_ovr`, which VoLTE depends on, never touched. | closed |
| `service` (Magisk, not waited for) | 1. The filter (uid 2951), first, so it holds its ports before any app can. 2. tor (uid 2950), `DisableNetwork 1`: it opens no TransPort or DNSPort at all. 3. `antumbra-fw apply`, `status`, and the service-port owner check; only if live, the hash matches and no other uid holds 9040, 9053, 5353 or 5380, `resetprop -n antumbra.fw.armed`. 4. `status.json`. 5. The IPv6 guard: NetworkStack re-enables IPv6 on each interface it brings up, so a loop switches it off again on every link or address change. Wi-Fi calling's and video calling's properties read in the first turn and every 30 s and set to 0 again if something wrote another value later (MOD7; stored values are already loaded at post-fs-data), never during a call, callback mode or the 5 minutes after one. 6. Fail-safe Settings, and mobile data stored as off for every SIM Android knows, once the framework answers; then the cell radio's watch: the radio has been off since power-on (`enable_cellular_on_boot=0`, airplane mode off, `cell_on=1`), airplane mode's radio list is narrowed to the cell radio once airplane mode has read off for 30 s, and if anything switches the radio on it is switched off again with airplane mode, unless a call, emergency callback mode or the 5 minutes after either holds it; while that hold lasts `enable_cellular_on_boot` is kept at 1, so that a restart of the phone process does not switch the radio off (`module/README.md`, "The cell radio"). | closed: TCP redirected into a tor that is not listening, DNS failing in the filter; the cell radio off |
| Welcome (device owner, home screen, locked task) | Applies the baseline policies (USB debugging off, no DHCP host name among them); Wi-Fi off and locked until Start; saved networks removed (a boot without the module). Checks the add-on: `antumbra.fw.armed`, nothing else. At Start: the session's policies, then `started=1`. | closed until Start |
| Start | The module latches the first `started=1` of the boot, only while Welcome is the device owner, and switches tor's network on only while the firewall is live and no other uid holds a service port. `offline`: tor stays off. `direct`: `SETCONF DisableNetwork=0`. `bridges`: the lines are checked again and sent with `UseBridges=1` in one `SETCONF`. `mac=keep` clears the per-connection MAC setting. A session that chose calls and texts or mobile data (`cell=phone` or `data`) has the cell radio switched on here and never before (D12), mobile data off first, as far as the Phone-mode gate allows (section 3; none as installed, so on the phone every session keeps the radio off until PH3); with `data` (the emulator only until FW9 and CI12), mobile data then on for the default data SIM over the live firewall. Every other session keeps mobile data off, switching it off again if something switches it on. | Tor only (calls and texts over the cell radio in Phone mode) |
| During the session | Supervision: the service-port owners at every turn (2 to 5 s), and again right after a look at the cell radio or a word to Welcome; the cell radio and mobile data as the session chose them, as far as the Phone-mode gate allows (read at every turn); the filter and tor are restarted if they stop (a restarted tor gets the session's choice again); `antumbra-fw status` every 30 s, and if it is not live the property is removed and `apply` runs again. | Tor only |
| Shutdown | Welcome makes itself home again, applies the baseline policies again (Administration's loosening ends), turns Wi-Fi off and locks it, removes saved networks. The module puts the fail-safe Settings back (`enable_cellular_on_boot=0` among them) and stores mobile data as off again; if airplane mode is on, it stores airplane mode off and `cell_on=1` without a broadcast, unless a call holds it, so the next start has the radio off and Wi-Fi under Welcome's control (best effort: a crash or power loss skips all of it). tmpfs contents disappear at power-off. | closed |

### 7.2 What happens when something fails

| Failure | Result |
|---|---|
| tor dies or is killed | TransPort and DNSPort vanish: TCP is redirected to a closed port, DNS fails in the filter. Restarted by supervision with the session's choice. |
| The filter dies | Nothing answers on 5335; DNS fails (closed, not open). Restarted by supervision. |
| An app binds a service port while its owner is not listening (9040 or 9053 before Start, in an offline session or while tor restarts; 5335 or 5380 while the filter restarts) | Without a guard, a squatter on 5335 would receive every app's and the system's lookups and could answer with addresses of its choice, skipping the tracker filter and steering connections (still through Tor) to its own servers; one on 9040 would receive every redirected TCP connection with its original destination and content, and tor could not open its port. The firewall drops answers from these ports by any socket but the owner's, so no handshake completes and no answer arrives. The module checks the owners at every turn (2 to 5 s) and before tor's network goes on; while another uid holds a port it removes the property and puts the firewall back to armed, which redirects nothing, until the port is free (`module/README.md`). Left: until the next check a squatter on 5335 still receives queries (names), and it can keep the network closed. |
| Android's mDNS holds 5353 | Seen in the first emulator run (11 October 2026): mDNS (uid 1020) held `0.0.0.0:5353` before the module started, so the filter could not start and the firewall stayed armed (closed). The filter has listened on 5335 since. If any other uid takes 5335 first, the same closed state follows. |
| A firewall rule is deleted or reordered | `status` reports `partial` or `open`; the property is removed at once and `apply` runs again. The mangle egress gate still drops anything the filter table did not mark. |
| `apply` fails | `antumbra-fw` goes back to the armed set; no property; tor's network is never switched on. |
| Welcome's process dies after Start | A new process answers `started=0` with a new `session_id`; the module keeps the latched choice, and Welcome refuses a second Start while the module reports a started session, asking for a restart instead. |
| The firewall cannot even be armed (`open`) | Wi-Fi and mobile data go off at once; the cell radio (airplane mode) and Bluetooth when no call holds them (below). Until then the cell radio carries calls and texts, and the IMS and emergency bearers, but no mobile data. |
| The cell radio would go off during a call, in emergency callback mode, within 5 minutes after either, or when the call state cannot be read | Held: no airplane step and no radio-off step, the fail-safe's included, until 5 minutes after the last of these; an unreadable state counts as a call. Meanwhile `enable_cellular_on_boot` is kept at 1, so that a restart of the phone process does not leave the radio off. Wi-Fi off and mobile data off do not wait. The only switch-off used is airplane mode, which Android's emergency-call path undoes by itself. |
| The module does not run at all | Section 7.3. |

### 7.3 When the module does not run

The module, and with it the firewall, does not start when Magisk's Safe Mode
is entered (one volume-key press at boot, which also leaves a `disable` file
so later boots stay without modules), after a LineageOS update installed
without Magisk's "Install to inactive slot" step, after a slot switch, or
after a major upgrade that replaced the boot image. Android's own safe mode
is separate; Welcome's `DISALLOW_SAFE_BOOT` blocks only that one. (A module
only switched off in the Magisk app still has its early arm script in
`post-fs-data.d`: that boot is armed and has no network at all.) The
safeguards therefore do not depend on noticing in time:

1. **No saved shared network on flash.** While the module runs, the Wi-Fi
   configuration store (`/data/misc/apexdata/com.android.wifi`) is a tmpfs
   and its flash copy is deleted, so a boot without the module has no
   shared network to join. This is the main Wi-Fi safeguard: Android joins
   saved networks during boot, before any app runs and before unlock.
   User 0's credential-encrypted store (networks added without "share",
   approved suggestions, Passpoint) is not covered (section 12).
2. **Welcome removes networks and turns Wi-Fi off** at every session end, at
   shutdown and at boot, and re-adds Persistent Storage networks only after
   it has read `antumbra.fw.armed` (W10).
3. **Fail-safe Settings that hold without Magisk**, because Android stores
   them: `captive_portal_mode=0`, `ntp_server=127.0.0.1`,
   `assisted_gps_enabled=0`, Wi-Fi and Bluetooth scanning off,
   `private_dns_mode=off`, `tether_offload_disabled=1`, per-connection MAC
   addresses, and on LineageOS `restricted_networking_mode=1` (enforced by
   netd's BPF program, so it holds without the module, but it only blocks
   apps whose "Network access" switch is off).
4. **The cell radio off from power-on, and mobile data stored as off.**
   The phone process reads `enable_cellular_on_boot` once, when it
   starts; the module stores 0 (at installation, every boot and shutdown,
   and after every switch-on once no call, callback mode or 5-minute hold
   keeps the radio on; during one it keeps 1, so that a restart of the
   phone process does not switch the radio off then), and with airplane
   mode stored off and `cell_on=1` the radio stays off from power-on,
   before any app runs. A crash during such a hold skips the shutdown's 0:
   that next start has the radio on until the module switches it off.
   Only airplane mode switched on and off, or an emergency call (which
   Android always lets switch the radio on), brings it up. Android keeps
   the mobile-data choice per SIM in Settings (`mobile_data<subId>`, and
   `mobile_data`) and reads it when the SIM comes up; the module sets it to
   0 for every SIM Android knows at every boot and again at shutdown, and
   `mobile_data_always_on=0`.
5. **Welcome's add-on check:** without `antumbra.fw.armed`, Wi-Fi stays off
   and locked for the session, whatever the Tor choice. Welcome decides from
   the property alone, which only root can set; the filter's status page,
   which any app could serve when the module is absent, never counts. In
   airplane mode Welcome cannot switch Wi-Fi off if the user switched it on
   (only Settings may); the removed networks and the Wi-Fi restrictions
   then leave it nothing to join, and Start refuses a network session.

What remains:

- **A SIM.** These safeguards are about Wi-Fi, except point 4. With point
  4 a SIM does not connect as the phone starts: its radio stays off. If
  someone switches airplane mode on and off, or an emergency call switches
  the radio on, a SIM with mobile data on connects over the mobile
  network, and system traffic such as the Updater leaves in the clear.
  Welcome locks Wi-Fi only, and a device owner cannot switch airplane
  mode. Point 4's mobile-data part covers the SIMs Android knows; it does
  not cover a SIM Android has never seen (LineageOS switches mobile data
  on for it), nor one whose mobile data a session switched on and that
  ended in a crash instead of a shutdown (a mobile-data session, WEL8,
  possible once the gate allows `data`: on the emulator only until FW9 and
  CI12). Hence no SIM at LineageOS's first boot (`install.md`), and the SIM
  inserted PIN-locked, its PIN typed only once the firewall is on (D3).
- **A network joined by hand** in a boot without the module connects in the
  clear (system traffic such as the Updater could then leave). Welcome
  removes it again at shutdown; if that boot ends in a crash or power loss
  instead, the network stays saved on flash, and the next boot without the
  module can join it for the seconds before Welcome removes it.

CI tests a reboot without the module, with Wi-Fi on and a saved network
present at the moment of reboot, captured from power-on: zero packets
allowed (W12), plus Magisk Safe Mode, a module `disable` file, a slot switch
without re-root, and the emulator's mobile data.

## 8. Root and privileges in Stage 1

- **Magisk is pinned to v31.0**, a release Antumbra has read and tested
  against. Its "Superuser access: Disabled" setting is still in v31.0 but was
  removed from Magisk's master branch, so nothing relies on it. Magisk's
  "Multiuser mode: Device owner only" (Magisk's "owner" is Android's user 0)
  denies `su` to every other Android user **[verified in source]**; sessions
  run in other users from W8. CI checks that `su` from a session UID is
  denied (needs a Magisk-rooted emulator).
- **The Magisk app** always has root and must be in user 0 for the weekly
  "Install to inactive slot" step. Welcome hides or suspends it except during
  an explicit update flow in Administration (later).
- **tor and the filter** run as uid 2950 and 2951 with every capability gone
  (permitted, effective, inheritable, ambient and bounding), `no_new_privs`,
  a clean environment and supplementary group 3003 (`inet`), started by the
  module's small helper `antumbra-run`. Magisk's own `su` keeps every
  capability since v30.7 unless `--drop-cap` is given **[verified, Magisk
  changelog]**, which is why it is not used. CI checks CapEff and CapPrm are 0.
  A bug in either cannot rewrite the firewall. Both still run in Magisk's
  near-permissive SELinux domain; a confining domain through `sepolicy.rule`
  is later work.
- **The debug base.** Official LineageOS is userdebug: with developer options,
  "Rooted debugging" and a cable, adb gives a root shell. The target is
  `ro.debuggable=0` set by the module with `resetprop` (tested for breakage
  first), `DISALLOW_DEBUGGING_FEATURES` in every session including
  Administration (Administration means app installation, Bluetooth and the
  location settings, not adb), and at boot `adb_enabled`,
  `adb_wifi_enabled`, `development_settings_enabled` and persistent logging
  reset and `/data/misc/adb/adb_keys` deleted. In v0 Welcome does the first
  half: `DISALLOW_DEBUGGING_FEATURES` and the adb settings at 0 from the
  moment it is the device owner, at every boot and in every session; a
  debuggable or testOnly Welcome honours a test hook that keeps adb for CI
  (section 13). `ro.debuggable=0`, the adb keys and logging are MOD4. Stage
  2's "user" build removes this.
- **Module updates** are never fetched by Magisk (no `updateJson`). An
  update is a zip installed by hand, or later by Welcome after checking a
  signature with a pinned key before `magisk --install-module`.
- **The DNS filter parses every app's queries.** It is a memory-safe Go
  program with fuzz targets for its query and reply parsers, it runs without
  privileges, and the firewall lets it reach only tor's DNSPort.

## 9. Amnesia in Stage 1

- **The session** (W8) is a new ephemeral Android user created by Welcome,
  with keys only in memory; it is gone at restart **[verified, AOSP vold]**.
  Until W8, v0 sessions run in user 0, and only the network state below is
  forgotten.
- **Moved to RAM** (tmpfs bind mounts with the right SELinux contexts in
  `post-fs-data`, so a boot without the module also leaves nothing new on
  flash): the Wi-Fi configuration store and NetworkStack's IpMemoryStore
  (v0); in W8 `/data/system/dropbox`, `graphicsstats`, netstats (in
  `/data/system/netstats` before Android 14; since NetworkStatsService
  moved into the Tethering module, **[likely]**
  `/data/misc/apexdata/com.android.tethering/netstats`; the path is
  **[unknown]** until checked against `android16-release` and on the
  emulator, before AM2), `procstats`, `/data/tombstones`, `/data/anr`, `/data/vendor/tombstones`,
  `/data/vendor/ramdump`, `/data/vendor/wifi/wpa`, `/data/vendor/location`,
  and `/data/misc/bluedroid` (or Bluetooth forbidden). Also deleted at
  shutdown.
- **tor's DataDirectory** is on the runtime tmpfs, as in Tails, so guards and
  time stamps never reach flash; Persistent Storage may later keep guards by
  choice.
- **Session boundaries:** ending a session is a restart, so tor's circuits
  and the DNS cache never carry over.
- **What stays** (listed in `threat-model.md`): Android's user serial
  counter, the Persistent Storage user's metadata, batterystats, app-ops
  history, Settings, apps installed mid-session in `/data/app`, the user 0
  credential-encrypted Wi-Fi store, and whatever the vendor firmware and the
  modem keep.

## 10. Stage 1 and Stage 2

| | Stage 1 (from the install) | Stage 2 (if build capacity is approved) |
|---|---|---|
| System | Official LineageOS 23.2, signed by LineageOS, userdebug | Antumbra's own LineageOS build from the same published source revisions, "user" build, signed with Antumbra's keys |
| Tor enforcement | The module's firewall, loaded by Magisk before zygote | The same rules from init, before any interface is up |
| Root | Magisk, for the module only | none |
| Amnesia | Throwaway users, network state and system records in RAM | The userdata key generated in RAM at every boot and never stored; userdata formatted at every boot (a change to vold's metadata encryption and fs_mgr) |
| Persistent Storage | A separate Android user | LUKS2/argon2id with Tails-style features **[unknown: where it lives]** |
| Leak fixes | Settings, overlays, device-owner policies | GrapheneOS's patches ported: DHCP-state flush, per-connection MAC, keepalive, captive-portal and network-time changes, a neutral DHCP vendor class, IPv6 off in Wi-Fi provisioning |
| Kernel | as shipped (crash-dump mode switched off at run time) | built without `QCOM_DLOAD_MODE`, with `INIT_ON_FREE_DEFAULT_ON` |
| Quick power off | tile, notification action and a PanicKit trigger | also a power-menu entry |
| CI image | Google's Android 16 emulator image | Antumbra's own LineageOS emulator image (`sdk_phone` x86_64, buildable from LineageOS 21 on **[verified, LineageOS wiki]**) |

**Stage 2's open points** **[unknown]**, to be measured before the Stage 2
decision (W18), in the emulator where possible:

- **Where Persistent Storage would live** once userdata is wiped at every
  boot. Shrinking userdata or repartitioning the UFS from recovery is untested
  and can brick the phone. Fallbacks: a USB-C stick, as Tails uses, or Stage
  1's persistent Android user.
- **The clock.** Qualcomm's `time_daemon` keeps its offset under
  `/data/vendor/time`, so a wiped /data may reset the clock at every boot, and
  Tor needs a roughly correct clock to connect. `/persist/time` survives a
  wipe, which is a write location that does not forget. Options: keep the
  offset outside /data (it is not secret), or a Tails-style "fix the clock"
  step at Welcome when Tor fails on clock skew.
- **Boot time** when every boot is a first boot.
- **What else survives:** `/metadata`, `/persist`, `misc`, the gatekeeper's
  RPMB records, and the modem's file system (EFS, kept by `rmt_storage`).

**Build capacity.** A LineageOS 23.2 build needs about 64 GB of RAM and
400 GB of disk; free GitHub runners have 4 CPUs, 16 GB and 14 GB
**[verified, GitHub docs]**. Options: a crave.io account (free if granted,
with a queue); an always-on dedicated server, about €100 a month (Hetzner
AX42-1, €97.30 a month plus a €49 set-up fee); or on-demand servers per build
(Hetzner CCX43 at €0.4423 an hour, about €2.65 per 6-hour build, plus a
persistent volume, since its 360 GB disk is under the 400 GB LineageOS asks
for), roughly €15 to €40 a month for weekly builds (estimate). GitHub's
larger runners need an organisation on the Team plan. A self-hosted runner on
a public repository must never run on pull-request triggers.

## 11. Testing and its limits

- **On every change:** the firewall in a Linux network-namespace sandbox; the
  filter's unit tests and a minute of fuzzing; tor's host check (when tor is
  rebuilt); Welcome's unit tests and lint; the module's unit tests and its
  boot scripts end to end as root on Linux; then the emulator leak test
  (`ci/README.md`), also on QPR2 without blocking.
- **The emulator leak test** runs Google's Android 16 image without Google
  services on a KVM runner, records every packet from the first moment of
  boot, and passes only if every connection after the firewall was armed
  goes to a Tor relay or directory in the consensus the phone's tor
  downloaded, or to a configured bridge. In v0 the emulator is rooted with
  `adb root` and the module is started as Magisk would start it, so the
  install steps match the phone's except the rooting step.
- **Scenarios** (v0 runs the first two): baseline (plain Android), boot to a
  started session on Wi-Fi with a tracker test, LAN and loopback probes and
  the armed state with the network up; then Welcome offline, tor killed,
  filter killed, network change, reboot, update guard (module absent with a
  saved network), Magisk Safe Mode, tracker test, the amnesia marker test (a
  marker text typed in a session must be gone from storage after a restart,
  plus a dump of the paths in section 9), an IPv6 router-advertisement source
  (no global address may appear, in `ip -6 addr` or in an app), a DHCP
  reconnection with a new MAC (no requested-IP option, no host name), an
  app that binds 127.0.0.1:9040 before Start (no connection reaches it, the
  network stays closed until it lets go), tethering cannot be enabled, and
  `su` from a session UID denied.
- **What a capture cannot show:** traffic that reaches its server through Tor
  (hence the log of the system's name lookups, and NFLOG records of
  redirected flows with their UID, which `antumbra-fw` can emit for tests);
  which app made a connection to a Tor relay.
- **The emulator is not the phone:** no Qualcomm parts, no modem, no Wi-Fi
  keepalive offload or IPA; a 6.x GKI kernel, not 4.14; Android 16 QPR0
  (`default`), while LineageOS 23.2 is QPR2, which Google publishes only as
  `google_apis` 36.1 (a secondary run does the same test on it, without
  blocking the workflow); `adb root` instead of Magisk, whose own CI boots
  rooted Android 36, 36.1 and 37.0 emulators on the same runners
  **[verified, Magisk's workflow and `avd.sh`]**. The phone capture after the
  install (`install.md`, section 9: the same analyser, judging every packet
  of a capture on the computer's hotspot) closes that gap, and a root
  `tcpdump` on the phone's `wlan0` is the weaker fallback.
- **Before the install:** the arm64 binaries are checked statically
  (`check-tor-binary.sh`, the filter's `-self-test` under `qemu-aarch64`) and
  can be smoke-tested in Termux on an older Android, built with a lower API
  level; the mirrored LineageOS zip is checked statically (iptables present,
  init and Updater assumptions, netd and Connectivity differences); Android's
  user limit is set to 4 on the emulator to match LineageOS before the
  session tests.
- **Scheduled runs** on GitHub only run from the default branch; until the
  workflows are there, daily runs depend on a push to the work branch, and a
  pause leaves the block list stale (the phone then uses the module's copy).

## 12. The checks' requirements and where they stand

| Requirement | Where | v0 |
|---|---|---|
| Firewall derived for Android from scratch, not from Tails' rules | `firewall/` | done |
| Fail closed when the module is absent | `module/` (Wi-Fi tmpfs, Settings, mobile data stored off, the cell radio stored off from power-on, early arm script for a switched-off module), `welcome/` (Wi-Fi off, property check alone) | done for Wi-Fi and for SIMs Android knew; not for a SIM Android has never seen (no SIM by default, D3); CI scenarios W12 |
| No saved Wi-Fi network on flash | `module/post-fs-data.sh` | done for the shared store (user 0's credential-encrypted store not covered; the first boot after installing writes that boot's lease memory to flash) |
| Mobile data off when the module is absent | `module/` (`mobile_data`, `mobile_data<subId>`, `mobile_data_always_on` at boot and shutdown, and after every switch-on of the cell radio) | done for SIMs Android knew; a new SIM starts with mobile data on |
| Cell radio off from power-on, and at run time outside Phone mode; never switched off during a call, in emergency callback mode or within 5 minutes after either | `module/` (`enable_cellular_on_boot=0` with airplane mode stored off; airplane mode narrowed to the cell radio at run time; holds read from Telecom and the telephony registry) | built in the module (MOD6), with unit and sandbox tests; run 15 switched the emulated radio off mid-run; not on the phone yet (CI11, PH3). Phone mode is chosen at Start (WEL8) and carried out only as far as the per-phone gate allows: off as installed, `phone` after PH3, `data` on the emulator only until FW9 and CI12. Airplane mode is not kept on across a restart: Wi-Fi would then refuse Welcome for the whole boot |
| Service ports held only by their owners (9040, 9053 tor; 5335, 5380 the filter) | `firewall/` (answers from other sockets dropped), `module/` (owner check, armed while held), `dnsfilter/` (9053 owner check) | done, with a window of up to 5 s per check (more while a look at the cell radio, up to 8 s, or a word to Welcome, up to 10 s each, runs; the check is repeated right after them); tor holding its ports from boot is decision D11 (a contract change) |
| No DHCP host name (option 12, Android 15 and later) | `welcome/` (`setSendDhcpHostnameRestriction`); the leak analyser fails on it (`dhcp-hostname`) | done **[likely]**; no capture has checked it yet (CI, the phone capture) |
| ControlSocket, not ControlPort; cookie authentication | `tor/torrc.in` | done |
| IPv6 off per interface, not only globally | `module/` (sysctls at boot, guard loop), firewall drops IPv6, filter answers no AAAA | done; RA test in CI pending |
| Hardware keepalive offload off | `module/overlay/` | built; untested (the emulator does not mount it) |
| DHCP lease memory cleared | `module/post-fs-data.sh` | done at boot; not yet when the MAC changes mid-session |
| The DNS filter fails closed | `dnsfilter/` | done |
| post-fs-data does one instant "drop all" first | `antumbra-fw arm` | done |
| `antumbra.fw.armed` set only after a verified apply | `module/service.sh` | done (and only while no other uid holds a service port) |
| tor and the filter: own UIDs, no capabilities | `module/helper/antumbra-run.c` | done; CI checks CapEff |
| tor and the filter: own SELinux domain | `module/` | todo |
| DHCP only for the network stack; other UDP rejected; DNS redirected | `firewall/` | done |
| DNS over TLS and DoH servers rejected | `firewall/`, `dnsfilter/fetch-lists.sh` | done (the DoH list comes from the list job) |
| Tethering, Wi-Fi Direct, safe boot forbidden; `tether_offload_disabled=1` | `welcome/`, `module/` | done |
| Location off, Bluetooth off, UTC, automatic time off | `welcome/` | done (Bluetooth lifted in Administration, until shutdown; Location off and locked in every session since WEL8, until WEL9's per-app choice; since WEL10 Welcome switches it on for one satellite fix the person asks for, at most 3 minutes, and off again, never while a call or the 5 minutes after one hold) |
| Emergency card: Android's own general emergency number at run time, state lines that point to the other phone without discouraging this one, one satellite-only fix on request shown only on screen | `welcome/` | built (WEL10), with unit tests (the number, every state line for every SIM, radio, IMS and session mix, the hook a release build ignores, the position's whole path with a fake platform, source scans: no number written in the code, the satellite receiver alone, nothing stored, logged or sent, no location setting but Location's switch written, no permission of Welcome's own revoked) and fake-screen tests of the emulator checks; the emulator checks (each state's text through a debug-build hook, a test-provider fix on screen) warn until they have passed on CI once; the phone in PH4 and PH5 |
| Location and nearby-device permission grants set to denied for every app | `welcome/` | todo (a grant per installed app and on every new install) |
| tor's DataDirectory on tmpfs | `module/`, `tor/` | done |
| Qualcomm crash dumps off | `module/post-fs-data.sh` | done; verify with a forced panic on the phone |
| Wi-Fi calling and video calling off for the whole phone; VoLTE's force-on never touched; no emergency path lost (the firewall already refuses the ePDG tunnel, and this phone's emergency path uses Wi-Fi only when Wi-Fi calling is registered) | `module/` (post-fs-data.sh, service.sh every 30 s, uninstall.sh) | built (MOD7), unit and e2e tests, a CI emulator check (a warning until it passes once); the phone's own IMS service and Settings with the real SIM unverified until PH3 |
| No `updateJson`; signed updates through Welcome | `module/module.prop`; `welcome/` | first half done |
| Magisk pinned; "Device owner only"; `su` from sessions denied | `docs/install.md`; CI | documented; CI check needs a Magisk-rooted emulator |
| `ro.debuggable=0`; debugging off in every session; adb settings reset at boot | `module/`, `welcome/` | debugging off and adb settings at 0 in every session, Administration included: done in Welcome (a test build's hook keeps adb, section 13); `ro.debuggable=0`, `adb_keys` and logging: todo (MOD4) |
| Magisk app hidden outside updates | `welcome/` | todo |
| Unsafe Browser as its own app, captive-portal detection always off | `welcome/`, new app | detection off done; the switch shown but disabled; the app W11 |
| Quick power off powers off, not restarts; never bound to the power button | `welcome/`, `module/` | the name and the rule done (WEL12); powering off todo (v0 restarts) |
| Quick power off never cuts an emergency call short or switches off in a callback window; it waits during any call, in callback mode and 5 minutes after a call, unless the module, as root, knows that call was ordinary (Phone mode only: outside it every call reads unknown) | `welcome/` (`CallWatch`), `module/` (the word, private to Welcome) | built (WEL7, MOD11) with unit and sandbox tests (the e2e `phone` scenario reads an ordinary call); relaxes only in Phone mode (WEL8), which the gate keeps off on the phone until PH3; Android 16 only (Android 17 keeps no record the module can read, so it waits after every call); the emulator check `welcome_module_word` fails since run 20 |
| System records moved to RAM (section 9) | `module/` | W8 |
| Hidden networks refused; passphrase field without learning, `FLAG_SECURE` | `welcome/` | W10 |
| Exempt apps: relays and bridges only, fail closed when stale | `firewall/`, helper | chain exists, empty (W9) |
| Time over Tor | `module/` | W5 |
| Releases worded "tested on the emulator; LineageOS build X statically checked" | releases | rule in force |

## 13. Where v0 departs from the design

These are decisions the parts took, each explained in its README:

- **System UIDs are redirected into Tor, not refused.** The leak check
  suggested passing only app UIDs into Tor and refusing root, system and
  vendor daemons outright, so that anything L0 misses is blocked rather than
  sent through Tor. The shared contract treats every UID except tor's the
  same, and the firewall follows it. The cost: a missed system connection is
  hidden from a packet capture, which is why the tests also log the system's
  name lookups. Revisit in W5 with the emulator's NFLOG data.
- **`restricted_networking_mode` is set on LineageOS only.** On plain Android
  (the emulator) it would block every app, even on loopback.
- **A test build keeps adb.** Welcome keeps debugging off in every session,
  Administration included; a debuggable or testOnly Welcome honours the
  property `debug.antumbra.keep_adb`, which CI sets before provisioning so
  that it can drive a session over adb. A release build never reads it.
  Which build the phone gets is decision D9.
- **tor does not hold its ports before Start.** With `DisableNetwork 1` tor
  opens no TransPort or DNSPort, so 9040 and 9053 are free before Start, in
  offline sessions and while tor restarts. The firewall and the module guard
  them instead (section 7.2); tor holding them from boot, with the firewall
  keeping uid 2950 off the Internet until Start, changes the contract of
  tor and the firewall and is decision D11.
- **`DISALLOW_CONFIG_WIFI` and `DISALLOW_ADD_WIFI_CONFIG` are lifted at a
  network Start**: Wi-Fi is set up by hand after Start until Persistent
  Storage brings networks back. They stay set before Start, in offline
  sessions and when the add-on is missing.
- **The Quick power off tile restarts the phone** until Welcome is a privileged app
  with `SHUTDOWN`, or the module carries out a power-off request.
- **Only plain bridges work**: lyrebird (obfs4, WebTunnel, meek_lite) is not
  built yet; Snowflake is never accepted (it needs UDP).
- **Apps with their own Tor cannot connect** until the relay chain is filled
  (W9): their tor is redirected into the system tor, and Tor refuses Tor over
  Tor (exits deny re-entry since 0.4.5.5-rc, and clients close such streams
  since 0.4.6.5 **[verified, tor release notes]**).
- **No time over Tor yet**: network time is off; tor tolerates some hours of
  error.
- **Phone mode is gated per phone** (WEL8): Welcome offers calls and texts,
  and mobile data through Tor, only as far as a root-only file allows
  (section 3), which no phone has as installed; the install's PH3 step
  writes it. The module never carries out more than the gate, whatever
  Welcome's row says, and mobile data through Tor stays the emulator's
  until FW9 and CI12. There is no build flag or test hook: the module zip
  and the APK CI tests are the ones a release ships, and CI writes the
  same file as root. Wi-Fi calling and video calling are off for the whole
  phone (MOD7; unverified until PH3 with the phone's own IMS service), and
  the firewall refuses the tunnel Wi-Fi calling needs anyway. Outside
  Phone mode every call still reads unknown (MOD11) and IMS is not read,
  so Welcome's VoLTE line says "Not checked" there; in Phone mode it would
  say if IMS still registered over Wi-Fi calling.

## Sources

- LineageOS for `hotdog`: https://wiki.lineageos.org/devices/hotdog/,
  https://wiki.lineageos.org/devices/hotdog/install,
  https://wiki.lineageos.org/devices/hotdog/upgrade/,
  https://download.lineageos.org/api/v2/devices/hotdog/builds,
  https://wiki.lineageos.org/emulator
- netd: https://android.googlesource.com/platform/system/netd/+/refs/heads/android16-release/server/oem_iptables_hook.cpp,
  https://android.googlesource.com/platform/system/netd/+/refs/heads/main/server/Controllers.cpp
- Magisk: https://raw.githubusercontent.com/topjohnwu/Magisk/master/docs/guides.md
  (boot scripts), its changelog (v30.7, v31.0) and its CI (`scripts/avd.sh`)
- Tor over Tor: https://blog.torproject.org/node/1989
- Tor Browser: https://gitlab.torproject.org/tpo/applications/tor-browser/-/issues/43438,
  https://gitlab.torproject.org/tpo/applications/tor-browser/-/issues/17569
- Connectivity checks outside a VPN: https://mullvad.net/en/blog/2022/10/10/android-leaks-connectivity-check-traffic/
- Tor VPN's threat model: https://support.torproject.org/tor-vpn/security/threat-model/
- Relocking: https://github.com/chenxiaolong/avbroot/issues/299
- GPU bug: https://services.nvd.nist.gov/rest/json/cves/2.0?cveId=CVE-2025-21479
- Server prices: https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/
