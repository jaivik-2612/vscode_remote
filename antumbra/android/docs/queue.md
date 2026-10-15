# Work queue

The work of Antumbra for Android from 11 October 2026 to mid-February 2027,
one row per item, in the order it is due, following the plan in the approved
design (`design.md`). It holds tasks and decisions only: nothing about
anyone's devices, notes, photos or times. It replaces the Debian queue
(`../../docs/plan/queue.md`, archived).

## Format and rules

- **One row per item:** ID, what, size, status, and "Done when", one line of
  acceptance. IDs by area: **FW** firewall, **TOR** tor and its transports,
  **DNS** the DNS filter and its lists, **WEL** Welcome, **MOD** the module,
  **AM** amnesia and sessions, **APP** apps and the app repository, **CI**
  tests and CI, **REL** releases and install readiness, **DOC** documents
  and reviews, **PH** work on the phone. **D** are decisions and **G** gates
  (last section). A letter after an ID (CI2a) marks one part of an item.
- **Size:** S, one session; M, 2 to 4 sessions; L, more than a week.
- **Status:** `todo`, `doing`, `done` (with the commit's short hash once it is
  pushed), `blocked: <reason>`.
- **One item per change.** Each change is its own commit on
  `claude/tails-mobile-privacy-os-c71ate`, names its item ID, and passes the
  `antumbra-android` workflow. Commits touch only `antumbra/**` and
  `.github/workflows/antumbra*.yml`; a push touching `web/`, `src/`, `data/`
  or `docs/store/` at the repository root redeploys another project's site.
- **The shared contract** (`design.md`, section 3) changes only together in
  every part and in `design.md`.
- **Wording of results:** until the phone is installed, an item is "tested
  on the Android 16 emulator", never "tested on the phone"; a LineageOS build
  is "statically checked".
- **Release gate** (each preview and candidate): every build job green; the
  emulator leak verdict `pass` on the release commit itself; SHA-256 sums
  and build provenance attached, and signatures once the keys exist (REL3,
  W7; previews before it are unsigned and say so); release notes say which
  LineageOS build was statically checked and that nothing ran on the phone
  (until W16).
- **Never:** push to or merge into `main`, relock a bootloader, add
  `updateJson` to the module, or publish a release outside the gate.

Weeks run Monday to Sunday; W2 starts Mon 19 Oct 2026. Previews for the
emulator only come weekly from W4, with SHA-256 sums and provenance, and
signed from W7, when the keys exist (REL3); release candidate 1 in W14;
v0.1 after the first week on the phone (W17). The block list updates daily
from W6.

## v0 batch · from 11 Oct · Every part, first version

Built in parallel to one contract, ahead of the plan's W2 to W7. Each stays
`doing` until its CI job passes on the work branch.

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| FW1 | `antumbra-fw` v0: `arm`, `apply`, `status`, `flush`, `print`; rules derived for Android from scratch (TCP into the TransPort, DNS to the filter, the rest refused; tor and the filter held to their own rules; IPv6 refused; a mangle egress gate; DoT and DoH refused; DHCP renewals for the network stack); NFLOG for tests; the exception chains for apps with their own Tor, empty | M | done (500c369) | The `firewall` job's sandbox test passes under bash, dash, busybox and mksh, with IPv6 |
| TOR1 | tor 0.4.9.14 for arm64-v8a and x86_64 with the pinned NDK, sources checked by SHA-256 and OpenPGP signature, reproducible; `torrc.in` (TransPort, DNSPort, ControlSocket with cookie, no SOCKS or ControlPort, `DisableNetwork 1`, DataDirectory on tmpfs); binary and host checks | M | done (476cde3; the same cached build in 500c369) | The `tor` job passes, the host check as root included |
| DNS1 | `antumbra-dnsfilter` v0 (Go, static): blocked names NXDOMAIN, no AAAA, fails closed, upstream owner check, rate limits, status page on 5380; the list compiler and pinned sources (HaGeZi Multi Pro and its encrypted-DNS list, Antumbra's own list; Exodus off until DNS3); fuzz targets | M | done (500c369) | The `dnsfilter` job passes and the block list compiles from its pinned sources |
| WEL1 | Welcome v0: device owner, locked home screen, Tor direct, bridges or offline, new MAC, Administration, Unsafe Browser (recorded only), baseline and session policies, the state provider, the status screen, the Panic off tile (restarts; named "Emergency off" until WEL7) | M | done (500c369) | The `welcome` job passes; the emulator run shows the Welcome and status screens |
| MOD1 | Module v0: `arm` first in post-fs-data; the runtime tmpfs; Wi-Fi store and IpMemoryStore on tmpfs; IPv6 off per interface (and a guard loop); crash dumps off; tor and the filter as 2950 and 2951 with no capabilities (`antumbra-run`); `apply` and the property; `status.json`; fail-safe Settings; Welcome's Start; supervision; the keepalive overlay; no `updateJson` | M | done (500c369) | The `module` job passes, and the `module-e2e` job runs `module/tests/e2e-host.sh` as root and passes |
| CI1 | The workflow and the emulator leak test v1: BASELINE (plain Android 16) and ANTUMBRA (module, Welcome with Administration off, Start, Wi-Fi, tor, tracker test, LAN and loopback probes from root and an app, the armed state with the network up) with `-tcpdump` from boot; the leak analyser against the consensus tor downloaded; checks (firewall live, CapEff 0, no other uid on the service ports, IPv6 off); the artifact under 40 MB | M | done (500c369) | One full run: ANTUMBRA `pass` with Tor traffic seen; the BASELINE report in the artifact |
| DOC1 | `README.md`, `design.md`, `threat-model.md`, `install.md` (draft), this queue; after the v0 review: the capture procedure judged by the analyser, the SIM caveat, the DHCP host name, the loopback-port takeover | S | doing | In the tree; the contract in `design.md` matches every part's README; `install.md`'s analyser command gives `pass` and `fail` on synthetic hotspot captures |

## SIM batch · from 12 Oct · Phone mode on an LTE-only carrier (decision D3)

The owner decided (D3): Phone mode, calls and texts, with the SIM in the
owner's own name, on an LTE-only carrier whose voice and SMS run only over
VoLTE (IMS); no 2G or 3G network to fall back on. The Internet comes first
from a phone hotspot over Wi-Fi; the SIM's mobile data is later and optional
(the carrier's network is largely IPv6, which Antumbra refuses). The owner's
other phone stays the emergency phone; the emergency number in the country
of use is 112, and no Antumbra text or code ever hard-codes a number.
Precise location is wanted, granted per app. Facts that hold whatever the
setup: the carrier sees the SIM, the IMEI and the serving cell while the
radio is on; calls and SMS never go through Tor; the modem works outside
the firewall. Safety first: emergency calls must work and are never tested
by dialling a real emergency number (`cmd phone emergency-number-test-mode
-a <harmless number>:normal` as root, never `emergency` or `unknown`
routing). Never: IMEI changes or tools that make them, jammers or spoofers,
Tor relays or bridges on the phone, getting around a messaging app's SIM
check. Phone tests (PH3 to PH6) wait for the install.

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| WEL7 | Emergency calls from Welcome's lock task: AOSP's LockTaskController lets emergency-call intents through only when `LOCK_TASK_FEATURE_KEYGUARD` is set, and Welcome sets only `GLOBAL_ACTIONS` (Home.kt), so before Start the emergency dialer is very likely refused. Allow it (the keyguard feature, or the emergency and system dialer packages in the lock-task allowlist); an "Emergency call" button on the Welcome screen; "Emergency off" renamed "Panic off"; panic and any power-off refuse during an emergency call and its callback period | S | done (c786253) | On the emulator, before Start, the emergency dialer opens from the lock task and Welcome comes back (`welcome_emergency_dialer`), with nothing dialled; a call through the lock task with a stand-in emergency number is PH4's, on the phone |
| WEL12 | "Panic off" renamed "Quick power off" (where the emergency number is 112, "panic button" means an emergency call); a rule that no Antumbra action is ever bound to repeated power-button presses; an emulator check of the power menu inside the lock task, presence only: no emergency setting changed and the item never pressed, run only while the emergency affordance is off (`force_emergency_affordance` and `emergency_affordance_needed`), so that the menu has no item that calls at once. Forcing the affordance item was dropped after review: it has the same label as the dial-pad item, so a dump cannot tell them apart, and a forced menu left open is a one-tap call to the platform number | S | done (9b8b4b2) | On the emulator, before Start, the power menu opened in the lock task shows an item labelled Emergency (`welcome_power_menu_emergency` ok), the menu is closed and `power_button_long_press` put back, nothing pressed or dialled; the affordance item and any call through it are PH4's, on the phone, with a stand-in number |
| MOD6 | Cellular radio off unless Phone mode is chosen: `enable_cellular_on_boot=0`, `mobile_data_always_on=0` and `mobile_data<subId>=0` at every boot and shutdown, written again right after each radio power-on (Android's airplane-mode path sets `enable_cellular_on_boot` back to 1); `airplane_mode_radios` narrowed to the cell radio. Phone mode = radio on, mobile data off: the IMS and emergency bearers come up without mobile data, SUPL only during an emergency call or emergency callback mode. When the radio may come on follows D12. Every radio-off and airplane step, the fail-safe included, is held during a call, in emergency callback mode and for 5 minutes after any call; a cell-off the emergency dialer cannot undo is never used; any new subscription is set to data off before the radio may come on Built (module side; WEL8 supplies the Phone-mode choice through service.sh's session_cell, which returns off today): the radio is off from power-on by stored values (enable_cellular_on_boot=0, airplane mode stored off, cell_on=1), so airplane mode is never left on across a restart (Wi-Fi reads it once at its start and would then refuse Welcome); at run time airplane mode with airplane_mode_radios narrowed to the cell radio; holds read from Telecom, the telephony registry and the callback-mode property, and an unreadable state holds. During a hold enable_cellular_on_boot is kept at 1, not written back to 0 after a power-on (safer: a restart of the phone process during an emergency call or callback mode leaves the radio on); 0 again when the hold ends. Known gaps: a new SIM's mobile-data default (ro.com.android.mobiledata) is not changed yet; dump formats are read from source, not yet seen on the emulator ; run 15 (b1c1301): the module switched the emulated radio off mid-run with airplane mode for the cell radio only, Wi-Fi stayed connected and validated, apps reached Tor afterwards, leak test PASS | M | done (b1c1301) | Unit and e2e tests show each hold; CI11: a boot without the module shows zero packets on the emulated radio; on the phone (PH3) the radio stays off from power-on until Phone mode |
| MOD11 | The module (root) tells Welcome privately, through Welcome's provider and as uid 0 only, whether the calls of the last 5 minutes were emergency calls (Telecom's call analytics) and the IMS registration; Quick power off then skips its 5-minute wait only after a call the module positively knows was ordinary, and waits as before whenever it cannot tell. Nothing about calls or IMS goes into `status.json` or a property (every app can read both) Built: the word is `emergency`, `ordinary`, `unknown` or `none`; Welcome takes it from uid 0 only (apps and the shell are refused before the extras are read), keeps it in memory and never hands it out; an "ordinary" word counts only if its look came after the call ended and it is at most 30 s old; an emergency word can only add waiting, up to 5 minutes; during a call and in callback mode Quick power off waits whatever the word says. A cut or timed-out Telecom dump reads unknown. IMS is read only in Phone mode, so it stays dormant until WEL8. Known gaps: on Android 17 Telecom no longer prints call analytics, so the word is always unknown there (see OS1); an emergency text without callback mode is not seen; the parsers are read from source and are checked on the emulator only by warn-only steps (welcome_module_word, module_parsers) until they pass once | S | done | Unit tests cover the three states (emergency, ordinary, unknown); unknown always waits |
| WEL8 | Two choices at Start: Internet (Wi-Fi, mobile data through Tor, or none) and Phone (off, or calls and texts), with a `cell = off, phone or data` column in the shared contract (design section 3, StateProvider, service.sh's session_read and the e2e tests changed together); a VoLTE status line from the module; a plain "what your carrier sees" card; SIM status (present, PIN-locked, radio on or off). Welcome cannot enter a SIM PIN (`supplyIccLockPin` is a system API): it explains the system's SIM-PIN screen and says to type the PIN only once the firewall is armed. Texts corrected: "offline" never while the radio is on, plain bridges do not hide Tor use, Administration no longer covers location, the new Wi-Fi address changes neither the IMEI nor the IMSI | M | todo | Emulator UI tests cover every combination; no text says "offline" while the cellular radio is on |
| WEL10 | An emergency card in Welcome: the general emergency number read from Android's emergency-number list at run time, never hard-coded; state lines (no SIM, SIM locked, radio off, VoLTE not registered) that point to the other phone without discouraging use of this one; a "show my position" button that takes one GNSS-only fix on request and shows the coordinates in large type, sent nowhere | S | todo | Emulator tests show each state's text and a test-provider fix on screen |
| MOD7 | Wi-Fi Calling and video calling off for the whole platform: `persist.dbg.wfc_avail_ovr=0` and `persist.dbg.vt_avail_ovr=0` (with `resetprop -p`, or set again in service.sh after Android loads persistent properties); `persist.dbg.volte_avail_ovr=1`, which VoLTE on this device depends on, is never touched | S | todo | A CI check shows the three properties at those values after boot; Settings offers no Wi-Fi Calling or video calling |
| WEL9 | Telephony and location policies: no 2G restriction and LTE-only never forced (on a carrier with no 2G they protect nothing and could remove a fallback to another operator's network for an emergency call); data roaming checked on the phone, not relied on (carrier settings may keep roaming sticky); location becomes "off, or on for chosen apps", precise or approximate per app (`setPermissionGrantState`), leaves Administration, and the chosen apps are exempt from WEL6; packages with carrier privileges (the live list from MOD10, which covers the SIM's own access rules) are refused; SIM-bound messaging apps get no phone-state access unless the owner opts in. Never block a call or SMS the person makes. Decided: the owner opts in for messaging apps bound to the SIM, which get phone-state access in Phone mode only, with their data in Persistent Storage; their traffic stays Tor-only | M | todo | Unit tests pass; after installs in the emulator only the chosen apps hold location, and carrier-privileged packages are refused |
| MOD10 | A cellular measuring kit for PH3 (`module/tests/ph3-snapshot.sh`): the ANTUMBRA iptables and ip6tables counters; NFLOG rejects by uid and interface; every `rmnet_data*` interface with its addresses and netd network; networks with IMS or EIMS capability and their interfaces; IMS registration; the APN protocol granted for the Internet and IMS APNs; packages with carrier privileges; any `nm_mdmprxy` rules | M | todo | It runs on the emulator in CI and produces a report (the emulator has no IMS: the mechanics only) |
| MOD9 | A module switch, off by default: `ipv6_sweep` and `ipv6_guard` skip interfaces of IMS or EIMS networks without the INTERNET capability | S | todo | An e2e test shows the sweep skipping a simulated IMS interface and disabling IPv6 everywhere else |
| FW6 | A narrow IMS/EIMS exemption, designed now and switched on only on PH3's data: only on interfaces of networks with IMS or EIMS capability and without INTERNET, only for the uids PH3 names (the IMS daemons run as radio with the inet group; the IMS app has its own uid), IPv6 only there, DNS from those uids on those interfaces not redirected into Tor; never for tor, apps, root or a network with INTERNET; removed when the network goes, listed in status, present in the applied, armed and failed states | M | todo | Sandbox tests show it matching only the IMS/EIMS interface, never an INTERNET network, and holding in the armed and failed states; PH3 outcome B passes with it |
| FW7 | Coexistence with Qualcomm's netmgrd: `antumbra-fw status` checks that Antumbra's jumps come first in mangle PREROUTING and POSTROUTING and filter OUTPUT and that FORWARD's policy is DROP, and reports "partial" otherwise; the guard loop restores the jump positions | S | todo | A sandbox test loads `nm_mdmprxy`-like rules after apply (the PREROUTING UDP accept included) and shows the gates still holding and status reporting it |
| DNS5 | `xtracloud.net` next to `izatcloud.net` and `gpsonextra.net` on the filter's own list; the leak analyser fails a run in which any of them or `supl.google.com` resolves | S | todo | The filter's self-test blocks the names and the analyser fails a synthetic run that resolves one |
| DNS6 | `3gppnetwork.org` on the filter's own list, so carrier-internal names never reach a Tor exit; the leak analyser flags any such lookup | S | todo | The filter's self-test blocks the name and the analyser flags a synthetic run that looks one up |
| FW5 | tor's uid limited to TCP until a UDP transport is chosen on purpose (ANTUMBRA_TOR marks any protocol today) | S | todo | The sandbox test refuses tor's UDP and ICMP to the Internet and still passes tor's TCP |
| TOR2 | lyrebird from pinned, verified sources for both ABIs, in the module, with `ClientTransportPlugin`; obfs4, WebTunnel and meek_lite bridges accepted. Bridges offered on every uplink, a phone hotspot counting as cellular (its carrier logs the connections); suggested automatically through a status line when direct bootstrap stalls or directory servers time out. WebTunnel lines need `addr=`: tor's uid has no resolver before bootstrap | M | todo | An emulator test with blocked directory servers shows the bridge suggestion, and a bridges session with built-in obfs4 bridges bootstraps |
| CI11 | Zero-packet scenarios from power-on: a reboot without the module with Wi-Fi on and a saved network; the same with the emulator's mobile data and a SIM Android has never seen; Magisk Safe Mode; a module `disable` file; a slot switch without re-root; tethering cannot be enabled | M | todo | Removing the add-on leaves the phone with no network |
| WEL13 | A read-only "Satellite" line on Welcome's status screen from `PackageManager.hasSystemFeature("android.hardware.telephony.satellite")` (public, no permission), reading "not supported on this phone" when absent; never a switch; a help card: satellite links are licensed operators that know who and where you are | S | todo | An emulator test shows the line; no satellite toggle exists anywhere in Welcome |
| FW8 | Any new uplink, satellite or other non-terrestrial included, gets the same treatment: a sandbox test with a simulated extra uplink interface shows only tor leaving and the module's per-interface IPv6-off step applying; FW6's IMS exemption refuses any network with satellite transport, the INTERNET capability, or an interface it did not discover | S | todo | The sandbox and e2e tests pass with the extra interface |
| FW9 | The SIM's mobile data through Tor, if PH3 finds the carrier's Internet APN IPv6-only (with 464XLAT): IPv6 left on for the cellular uplink only, ip6tables letting only tor's uid out on it and refusing every other uid, the clat path allowed only for tor; a contract change in design sections 3 and 5 | M | blocked: PH3 | Sandbox and e2e tests show only tor leaving over IPv6 on the cellular uplink; on the phone tor bootstraps over the SIM's data with every other uid refused in the counters |
| MOD14 | Faster location fixes: the module fetches the GNSS assistance data (Qualcomm XTRA, or Android's PSDS where used) through Tor without identifiers and serves it locally to the GNSS stack; the assistance hosts stay blocked for everything else; emergency SUPL never touched. Only after PH5 shows how xtra-daemon chooses its server on this device | M | blocked: PH5 | On the phone a cold fix with the local assistance data is faster than without it, and the capture shows no assistance request outside Tor |
| CI13 | A build guard: no modem diagnostic or NV-write code, no IMEI-related hooks, no `diag` in any USB configuration; tor client-only (no ORPort, BridgeRelay or Snowflake proxy); no overlay that removes the power menu's emergency item; no module file that clears `persist.dbg.volte_avail_ovr`; the curated app repository rejects satellite-messenger and satellite-terminal companion apps, radio-firmware flashers and apps whose radio region differs from the configured one; no Snowflake proxy mode in any Tor app | S | todo | CI fails on a synthetic file that breaks each rule |
| CI15 | App lab follow-ups from its first run (run 11: 9 of 13 items ran, 0 crashed, leak test pass with 19,569 of 19,574 packets to Tor): wait up to 180 s for a store's catalogue (F-Droid was still fetching its repositories at 90 s); a larger download budget and an F-Droid mirror first for big APKs (Element X and Zoom ran out of time); prefer x86_64 builds where a store offers them (Instagram and TapTap are ARM-only, refused by the x86_64 emulator); record the on-screen text with every screenshot (Spotify's sign-in screen blocks screenshots); requested apps from the test page added to the catalogue; run 12 (no change to the lab itself): F-Droid's catalogue loaded, Element X and Zoom installed, 12 of 14 items installed; YouTube installed but was not opened, because its launcher name (`.app.honeycomb.Shell$HomeActivity`) lost `$HomeActivity` in the device's shell (fixed: the name is quoted) | S | todo | The next app-lab run loads F-Droid's catalogue, installs every item that has an x86_64 or universal build, and records screen text for each app |
| CI14 | A monthly check of Tor's reachability (OONI's tor and torsf tests and the Tor Project's sites) on the networks in use, their AS numbers kept in a repository variable, not in the code; results on the Daily page, flagged above 10% anomalies | S | todo | The job runs and the Daily page shows the figures |
| WEL11 | An offline map app among the curated apps (F-Droid), its Internet access off by default, maps downloaded through Tor into Persistent Storage, its hosts audited with the leak analyser | S | todo | The app installs from the curated list, and an audited run shows only its map servers |
| MOD8 | At session end, before location goes off, delete only the GNSS engine's last position, not ephemeris, almanac or time (a cold start would slow a fix during a later emergency call); recorded in status.json | S | todo | An e2e test shows the command sent before location goes off, and status.json records it |
| AM5 | Amnesia with a SIM: where texts, the call log, SIM information and the radio and IMS vendor data live on LineageOS; RAM or Persistent Storage for each, following the owner's answer; what the SIM card and the modem keep. Decided: texts, the call log and contacts are kept in Persistent Storage behind the passphrase | M | todo | design.md section 9 lists each path with its handling, and a restart test shows texts and the call log handled as decided |
| DOC4 | D3 written into the documents: Phone mode on an LTE-only VoLTE carrier; uplinks in order: a phone hotspot, then the SIM's mobile data if ever wanted; the SIM inserted PIN-locked with its PUK kept, the PIN typed only once the firewall is armed; on a boot without the module the SIM stays locked and emergency calls from this phone are uncertain, so the other phone is the emergency phone; Phone mode labelled "not anonymous". Threat-model rows: the carrier (identity from registration, cell location, call and SMS records, two-year records of Tor or bridge connections), the modem outside the firewall, SIM applets and carrier-privileged apps, apps reading the SIM's country and operator without permission, phones that travel together, emergency calls. An owner guide: buy the SIM in person in one's own name, never lend it, accidental emergency calls (stay on the line), never test with a real emergency number | M | todo | `grep -n "no SIM\|pocket hotspot"` finds no passage that contradicts this, and the guide is linked from the README |
| DOC9 | Re-check the device baseline: the LineageOS wiki lists 24.0 as hotdog's current branch and 23.2 as previously supported, while the SIM research read 23.2's code; which model variant the phone is; that the target network's LTE bands are covered and the phone is LTE-only (no 5G) | S | todo | design.md names the target branch with a reason, and the hardware line matches the wiki and the device tree |
| DOC11 | The satellite answer in design.md and threat-model.md: this device has no satellite transmit path and no software can add one (the modem's hardware and signed firmware decide it); every lawful satellite service is a licensed operator with identity checks, records, terminal location on demand and interception, so it is never a privacy channel; a licensed satellite dish, if ever available, is a Wi-Fi uplink with Tor on top (resilience against infrastructure failure only, not against shutdowns); direct-to-cell satellites appear as an ordinary cellular network, controlled only by the modem and the SIM's network lists | S | todo | Both documents say this, with sources |
| DOC10 | A dated law-and-rules page for the country of use (each item: in force, direction, proposed, withdrawn or stayed), a "check again by" date, a law-watch list and the never-list, kept in the owner's private notes, not in the repository | S | todo | The page exists where the owner keeps it, every row dated and sourced |
| CI12 | An ANTUMBRA-CELL scenario: Wi-Fi off, the emulator's mobile data on, tor through the emulated radio, judged by the leak analyser. After PH3, and only if the SIM's mobile data is wanted | M | todo | It runs in CI and passes: only tor's packets leave over the emulated radio |
| PH6 | Before LineageOS, on the stock system with the SIM: VoLTE registration shown, one ordinary call and one SMS each way with a number the tester owns, the SIM PIN set and the PUK kept, the model number and the IMEIs recorded, then the SIM removed; no emergency number dialled | S | blocked: the install (W16) | install.md makes it mandatory for Phone mode and records the results |
| PH3 | The gate for Phone mode, with MOD10, during IMS registration, an ordinary call and SMS both ways, once with the IPv6 sweep as it is and once with MOD9 on; also the Internet APN's protocol (IPv4, IPv4v6, or IPv6-only with 464XLAT), whether the radio stays silent at power-on, the PIN-locked SIM's limited service, whether roaming is reported in other regions of the carrier, which WEL9 policies hold. Outcome A: no Android-side IMS packets, Phone mode allowed. B: FW6 and MOD9 needed. C: VoLTE never registers, no Phone mode (and whether SMS still arrives without IMS). MMS recorded as unsupported | M | blocked: the install (W16) | install.md records the outcome with the counters; Phone mode is enabled only for A, or for B after FW6 passes |
| PH4 | Emergency reachability with a stand-in number only: the power menu's Emergency item in the lock task and in a session user (`dumpsys emergency_affordance`), with the SIM locked, the radio off and the SIM unlocked; whether anything handles Android's 5-press gesture; cell-broadcast alerts over the lock task and in the session user; the time from radio-off to an emergency-capable state; the emergency-number list with its sources | S | blocked: the install (W16) | Results in install.md and threat-model.md; Welcome's emergency texts match them |
| MOD12 | After PH4: if nothing handles Android's 5-press emergency gesture, either a small system handler with a full-screen, cancellable countdown that opens an emergency call, or the gesture's setting hidden so nobody trusts a gesture that does nothing | S | blocked: PH4 | PH4's answer recorded and one of the two options tested on the emulator with a stand-in number |
| PH7 | Read-only record of the phone's satellite support: `pm has-feature android.hardware.telephony.satellite`, `cmd phone cc get-value -p <subId>` for the satellite keys, `dumpsys carrier_config`; no `cmd phone ... satellite` subcommand (they are all test overrides that change state); nothing enabled, nothing transmitted | S | blocked: the install (W16) | install.md records the answers |
| PH5 | A GNSS audit on a lab build: is `persist.sys.xtra-daemon.enabled` honoured, which hosts xtra-daemon and the Qualcomm Wi-Fi location clients contact, which gps.conf is in force, the SUPL host and NFW proxy apps (`dumpsys location`), network-initiated requests and the HAL's answers; cold and warm time to first fix with assistance off, the constellations and signals used. No change to emergency SUPL settings, ever | M | blocked: the install (W16) | design.md section 6 records each answer with the build and date |

## Base and look · from 15 Oct

LineageOS moved this phone to version 24.0 (Android 17) on 12 Oct 2026:
the download service lists lineage-24.0-20261012 after the last 23.2
build of 9 Oct, so 23.2 gets no more updates. The owner tried the real
Antumbra in Antumbra Live and found the look dated; that look is Google's
bare Android 16 test image (AOSP Launcher3 with its old search widget,
3-button navigation, no Material 3 Expressive), not what LineageOS shows
on the phone.

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| OS1 | The base for the January install: LineageOS 24.0 (Android 17), where the updates now are. Re-check against 24.0: design.md and install.md (they say 23.2), the module's version-specific parts (netd chains, NetworkStack, settings keys, the cell radio's dump formats from MOD6, the connectivity overlay). Blocker found by MOD11: Android 17's Telecom no longer prints its call analytics (`Analytics:`), which MOD6's holds and MOD11's word read; without a replacement call record every radio-off step, the fail-safe's included, is held for the whole boot and Quick power off waits after every call, Welcome's target SDK and device-owner APIs, and the CI emulator image (Google's Android 17 images: which exist without Google services) | M | todo | The base is recorded with the reasons; the docs name it; CI runs on the matching Android version where an image exists, and says plainly where it does not |
| UI1 | The look, after D14: A, LineageOS's own (comes with the system; small polish: Welcome's navigation-bar scrim and font, an optional seed colour), or B, an OxygenOS-style look-alike from open parts (overlays for colour, font and icon shape in a separate optional module, an open launcher; its quick settings, lock-screen clocks and motion only with Stage 2). Look settings are per user, so Welcome applies them again for each session's throwaway user | S (A) / L (B) | blocked: D14 | The chosen look on the emulator, with screenshots on the test phone page |
| LIVE2 | Antumbra Live's virtual phone closer to the real phone, privacy-neutral, set by adb before Welcome becomes device owner: QuickSearchBox off (no old search widget), dark theme, gesture navigation, animations on, LineageOS's own wallpaper (Apache-2.0), a sharper stream (noVNC quality 8). Its system UI stays Android 16 QPR0: Google publishes no newer image without Google services | S | todo | A Live session shows the changes; no new network traffic in its privacy check |

## W2 · 19 to 25 Oct · Freeze the Debian track, the emulator job passes

The emulator job passing is CI1 (v0 batch).

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| REL0 | Freeze the Debian track after decision D1: record its last commit (fd98a1c; the work session cannot push tags, so `antumbra-debian-final` is left to the owner, from GitHub's web page, if wanted), stop its daily VM run, Daily page fed by the Android emulator (`ci/daily.py`). Its documents are already marked archived | S | done (83d37fe) | The final commit recorded, `antumbra-vm.yml` no longer scheduled, the page shows the Android run |
| REL1 | Mirror the official LineageOS build the release is checked against, with its `build-manifest.xml` and the SHA-256 values from the download API; static checks of the zip: iptables and the `-restore` tools present, init and Updater assumptions, netd and Connectivity changes against AOSP `android16-release`; a weekly check of `hotdog`'s builds for LineageOS 24 | M | todo | A CI job checks the mirrored build and reports any LineageOS 24 build for `hotdog` |

## W3 · 26 Oct to 1 Nov · Leak baselines

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| CI2 | Leak test v1 completed: each relay connection attributed to tor's UID (or an exempt UID) on the device; NFLOG records of redirected flows with their UID in the report; the log of names the system looks up, with unexpected names flagged (names and destinations through Tor are listed in v0, in learning mode; strict once the expected list is learned) | M | doing | The report lists UIDs for every flow and the system's looked-up names |
| CI3 | A baseline with a pinned Orbot as always-on VPN with "Block connections without VPN", to show what a VPN alone lets out | S | todo | A third report in the artifact |
| CI4 | A secondary QPR2 run on Google's `google_apis` image for API 36.1 (LineageOS 23.2 is QPR2; the `default` image is QPR0), Google services disabled before the baseline; in the workflow since v0, not blocking. Runs 3 to 5: 'dpm set-device-owner' is refused there ("already some accounts on the device") although 'dumpsys account' lists none, only Google's authenticators | S | doing | The ANTUMBRA scenario passes on QPR2 too |

## W4 · 2 to 8 Nov · A rooted emulator, the first preview

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| CI5 | A Magisk-rooted emulator, the way Magisk's own CI does it (`avd.sh`), Magisk v31.0; the module installed through Magisk; the capture from power-on of a boot with the module | M | todo | Only Tor traffic leaves, during boot too, with Magisk's real boot stages |
| CI5a | `su` from a UID outside user 0 is denied ("Device owner only") | S | todo | The check passes in the Magisk run |
| REL2 | Weekly emulator preview: module zip and Welcome APK with SHA-256 sums and provenance; unsigned, and labelled so, until REL3's keys (W7), signed from then | S | todo | The first preview passes the release gate (signatures from W7 on) |

## W5 · 9 to 15 Nov · Quiet Android, more scenarios

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| MOD2 | Time over Tor, as Tails does: after tor connects, the time from HTTPS Date headers fetched through Tor, set by root; automatic time stays off | M | todo | In the emulator, a clock set wrong by hours is corrected after bootstrap |
| CI6 | Scenarios: tor killed, network change, reboot; zero leaks in each | M | todo | Each scenario passes |
| CI7 | An IPv6 router-advertisement source on the emulator's network | S | todo | No global or ULA address appears, in `ip -6 addr` or in an app's `getifaddrs` |
| CI8 | The probes CI1 does not make yet: an app that binds `127.0.0.1:9040` before Start; DHCP reconnection with a new MAC. (The router and loopback probes and the Wi-Fi session are in CI1's ANTUMBRA scenario; the leak analyser already fails on a DHCP host name, option 12, after arm: `dhcp-hostname`.) | S | todo | The squatter receives no connection and the network stays closed while it holds the port; the DHCPDISCOVER carries no requested-IP option and no host name |
| FW2 | Decision D7 with the NFLOG data from CI2: keep redirecting system UIDs into Tor, or refuse UIDs below 10000 | S | todo | The decision recorded and, if changed, the firewall and contract updated together |
| PH0 | The arm64 binaries on a real arm64 Android, unprivileged, in Termux: the CI artifact's arm64 tor (built for API 29, `tor/README.md`; `--verify-config`), the filter's `-self-test` | S | todo | Both run and pass on the still-locked phone (OxygenOS, Android 10 to 12) |
| FW4 | After decision D11: tor holds 9040 and 9053 from boot (`DisableNetwork 0`), and the firewall keeps uid 2950 off the Internet until Start; torrc, module, firewall and the contract change together | M | blocked: D11 | No app can bind 9040 or 9053 at any time in the emulator; nothing leaves before Start |

## W6 · 16 to 22 Nov · The tracker filter v1 and the daily list

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| DNS2 | The daily list job: fetch, deduplicate, allowlist, compile, sign with the list key; published as a release asset under a fixed tag; the DoH address list for the firewall from the same job | M | todo | A signed list and its signature are published by a run; the filter refuses an unsigned one |
| DNS3 | The Exodus Privacy tracker data: off in v0. Its licence is ODbL 1.0 (contents DbCL 1.0, recorded in `dnsfilter/lists/sources.conf`); its attribution and share-alike duties checked against HaGeZi's GPL-3.0 for one merged list, and its signatures reviewed as domains (`exodus-exclude.txt`), before it is switched on, or it stays out | S | todo | A decision recorded in `dnsfilter/lists/sources.conf`; if on, the merged list's licence notice names both |
| DNS4 | The filter's wait for tor (`-upstream-timeout`, 4 s) against tor's first look-ups after it connects: in emulator run 8 `www.gstatic.com` and `check.torproject.org` were answered SERVFAIL four and three times before tor's answer arrived; measure it over several runs, then lengthen the wait or keep the look-up waiting for tor's late answer | S | todo | The control look-up is answered on its first try in five emulator runs in a row, or the reason it cannot be is recorded |
| CI9 | Filter killed: lookups stop; the tracker test extended to Exodus and vendor names | S | todo | Lookups fail while the filter is down; known tracker names are blocked |

## W7 · 23 to 29 Nov · Welcome v1, bridges, keys

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| WEL2 | Welcome wording and flow checked against the archived Welcome screen; screenshots of every state | S | todo | Screens in the artifact; wording reviewed |
| REL3 | Keys generated after decision D5: app, repository index, block list, module | S | blocked: D5 | Keys stored as secrets with an encrypted backup outside GitHub |
| CI10 | One install script sets up a fresh emulator alone: module, Welcome, provisioning | S | todo | A fresh emulator is set up by the script alone |

## W8 · 30 Nov to 6 Dec · Throwaway sessions

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| AM1 | Each session a new ephemeral Android user created by Welcome (affiliated, apps installed from user 0, then switched to); ending a session is a restart; the emulator's user limit set to 4 as on LineageOS; in Phone mode the module lifts `no_outgoing_calls` and `no_sms` for the session user (`pm set-user-restriction`; a device owner cannot clear these base restrictions), and the power menu's Emergency item and emergency alerts are checked there | M | todo | A session runs in a new user that is gone after a restart |
| AM2 | System records to RAM in post-fs-data (`design.md`, section 9), and deleted at shutdown; first the paths checked against `android16-release` and on the emulator (netstats' path is **[unknown]**) | M | todo | After a restart none of the paths holds anything from the session |
| AM3 | The amnesia test: a marker text typed in a session, a restart, storage searched for it; plus a dump of the section 9 paths | M | todo | The marker text is gone |
| MOD3 | IpMemoryStore cleared whenever the MAC address changes within a session | S | todo | CI8's DHCP check passes after a mid-session MAC change |
| MOD4 | The rest of debugging off: `ro.debuggable=0` with `resetprop` (tested for breakage), persistent logging reset and `adb_keys` deleted at boot. (Welcome already keeps `DISALLOW_DEBUGGING_FEATURES` and the adb settings at 0 in every session, Administration included; CI's way in is the test build's hook) | M | todo | In a non-test build no session has adb, `ro.debuggable` reads 0, and nothing else breaks |

## W9 · 7 to 13 Dec · Apps with their own Tor, the repository

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| FW3 | The relays-only exception: a per-UID chain on new connections or an `xt_bpf` map of (address, ORPort); a non-root helper refreshing it from the system tor's consensus every hour and at each session start; failing closed when stale; bridges entered at Welcome added; exempt UIDs rewritten each session | L | todo | Tor Browser connects; nothing else leaves; rule cost measured in the emulator (the phone in W17) |
| APP1 | Tor Browser (official APK, signature checked) and the curated apps; Antumbra's repository in F-Droid format, signed, published as release assets under a fixed address (decision D6) | M | todo | Apps install from the repository over Tor in the emulator |
| MOD5 | A SELinux domain of their own for tor and the filter (`sepolicy.rule`), tested on the Magisk emulator | M | todo | Both run confined, and the scenarios still pass |
| WEL3 | Make `antumbra.fw.armed` readable to Welcome by a property context of its own (it is readable today only as `default_prop`, which upstream marks for removal); Welcome already decides from the property alone | S | todo | Welcome reads the property under the new context on the Magisk emulator |
| WEL6 | Location and nearby-device permission grants set to denied for every app, and for each new install (a package-added listener) | S | todo | After an install in the emulator, no app holds a location or nearby-device grant |

## W10 · 14 to 20 Dec · Persistent Storage v1

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| AM4 | Persistent Storage as a separate Android user with a long passphrase; its Wi-Fi networks (non-persistent MAC, locked) and bridges re-added only after `antumbra.fw.armed`; hidden networks refused; the passphrase field without learning and `FLAG_SECURE`; the newer block list kept here (needed before Phone mode is used daily: contacts, the hotspot password, maps) | L | todo | Create, unlock and wrong-passphrase tests pass |

## W11 · 21 to 27 Dec · Emergency power-off, the Unsafe Browser (light week)

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| WEL4 | Quick power off powers off: Welcome as a privileged app with a `SHUTDOWN` allowlist installed by the module, or the module carries out Welcome's power-off request; a Ripple/PanicKit trigger, never one bound to the power button (WEL12); optional power-off after some hours locked | M | todo | The power-off test (`welcome-adb.sh power-off-tile`) powers the emulator off |
| APP2 | The Unsafe Browser: a WebView app with its own UID, bound to the Wi-Fi network, launched by hand; a root helper opens its clearnet and DNS exemption on launch and closes it on exit; Tails' warning | M | todo | It reaches a fake login page in CI; nothing else leaves outside Tor |

## W12 · 28 Dec to 3 Jan · Update safety

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| WEL5 | An update flow in Administration: the LineageOS Updater and the Magisk app allowed for "Install to inactive slot"; the Magisk app hidden at all other times | M | todo | The update steps work in the emulator; Magisk is hidden outside them |
| REL4 | The LineageOS 24 go/no-go (decision D8); the update procedure in `install.md` checked | S | todo | Decision recorded; the procedure matches the emulator run |

## W13 · 4 to 10 Jan · Review

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| DOC2 | Adversarial review of the whole design and code; `threat-model.md` updated; fixes | M | todo | Every finding fixed or documented |

## W14 · 11 to 17 Jan · Release candidate 1

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| REL5 | RC1: module, Welcome, repository; the install runbook with the refused-unlock branch step by step and the expected output of every fastboot command; the install script rehearsed in the emulator 3 times; decision D9 | M | todo | RC1 frozen and passes the release gate |

## W15 · 18 to 24 Jan · Buffer, files staged

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| REL6 | Every file the install needs staged with SHA-256: the LineageOS zip, `boot.img`, `dtbo.img`, `vbmeta.img`, `recovery.img` and manifest; Magisk v31.0; the module and Welcome; the OxygenOS 11 rollback package and the latest OxygenOS 12 package for the model; payload-dumper-go; platform-tools. Files kept as Actions artifacts expire after at most 90 days, so they are re-staged here | S | todo | Every file and its checksum listed in the runbook |

## W16 · 25 to 31 Jan · The install

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| PH1 | The install (`install.md`), in two sittings, after gate G2; gate G1 at the unlock | L | blocked: G2 | The phone reaches Tor, the leak analyser judges the hotspot capture `pass` with exit status 0 (`install.md`, section 9), and no DHCP message carries a host name |

If the install moves later, W16 to W18 move with it; nothing before them
depends on it.

## W17 · 1 to 7 Feb · The first week on the phone

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| PH2 | Battery over 24 hours; time to the Welcome screen; vendor traffic in captures; the clock after restarts; a forced panic to check that crash dumps are off; the exempt-app rule cost on the 4.14 kernel; the first weekly LineageOS update the Antumbra way; fixes | M | todo | Measurements recorded; tag v0.1 |

## W18 · 8 to 14 Feb · Stage 2 decision

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| DOC3 | The Stage 2 decision (D2) with the phone's data, including the open points in `design.md`, section 10 | S | todo | Decision recorded |

## Not in this window

The archived Debian track (the mainline kernel port, the Phosh shell,
Waydroid, the install-guide PDF), unless the mainline port gains calls and
mobile data. Relocking the bootloader. Google services. The repository's
GitHub Pages site. Filtering Tor Browser. Per-app Tor circuits and an offline
tracker scan of new apps (after v0.1). Stage 2 work before decision D2.

## Gates and decisions

A settled decision is recorded here as `decided: <choice>` with the date.

| ID | When | Question | Recommended | Status |
|---|---|---|---|---|
| D1 | W2 | Freeze the Debian track: tag it, stop its daily VM run, switch the Daily page to the Android emulator? | yes | decided: yes (11 Oct 2026); REL0 |
| D2 | apply now, decide W18 | Build capacity for Stage 2: apply for a free crave.io account now (an application by a person, not by CI), spend nothing before February, then decide between crave.io, on-demand servers (about €15 to €40 a month) and an always-on server (about €100 a month plus set-up) | apply now; decide with phone data | open: the owner applies (12 Oct 2026) |
| D3 | W2 | A SIM card in the Antumbra phone? A SIM is also a way out in the clear whenever the module does not run (mobile data on for a SIM Android has never seen) | no SIM, Wi-Fi only, and none from LineageOS's first boot on; a "phone mode" later, clearly labelled as not anonymous, after MOD6 | decided: a SIM (11 Oct 2026); Phone mode for calls and texts on an LTE-only VoLTE carrier, the SIM in the owner's name, the Internet from a phone hotspot first, the other phone as the emergency phone, precise location per app (12 Oct 2026); the SIM batch |; Phone mode is a lasting feature, not a trial; the SIM's mobile data is wanted later if it can be made safe; messaging apps bound to the SIM are wanted on this phone; faster location fixes with assistance fetched through Tor (13 Oct 2026)
| D4 | before W6 | Daily jobs: Antumbra's workflows on the default branch (GitHub's schedules run only there), or runs started by a push from the routine? | routine-driven; a pause leaves the block list stale and the phone uses the module's copy | open |
| D5 | before W7 | Generate the signing keys (app, repository index, block list, module), stored as secrets with a passphrase-encrypted backup outside GitHub. A device-owner app can only be updated with the same key | yes | open |
| D6 | before W9 | The app repository as release assets under a fixed tag, or a separate public repository (the repository's Pages site serves another project) | release assets; the address fixed from RC1 on | open |
| D7 | W5 | System UIDs: redirected into Tor (contract) or refused below 10000 (leak check)? | decide with CI2's data | open |
| D8 | W12 | LineageOS 24: has `hotdog` moved to 24.0? Then the emulator moves to Android 17 and the install takes 24.0 | follow REL1's weekly check | open |
| D9 | before RC1 | Welcome on the phone as a removable test build (`testOnly`) or as a release (removed only by a factory reset). A testOnly build honours the test hook that keeps adb, which the install's capture can use to copy tor's consensus (`install.md`, sections 8 and 9); a release build turns adb off for good, and the capture then takes the consensus from CollecTor | — | open |
| D10 | W9 | If the relays-only exception costs too much on the 4.14 kernel: apps with their own Tor use bridges only | measure first | open |
| D11 | W5 | tor holding 9040 and 9053 from boot (`DisableNetwork 0`, the firewall keeping uid 2950 off the Internet until Start), so that no app can take them; changes the contract of tor and the firewall (FW4). v0 guards the ports instead (`design.md`, section 7.2) | decide with D7: both change the rules for uid 2950 | open |
| D12 | before MOD6 | In Phone mode, may the radio come on as soon as `antumbra.fw.armed` is set and the SIM PIN is typed (calls and texts reach the phone before Start), or only at Start? | as soon as armed and unlocked, mobile data off; recorded as a modem-only exception to "nothing goes out until Start" | decided: only at Start (13 Oct 2026); no calls or texts reach the phone before Start |
| D13 | with WEL9 | Messaging with no network at all: a session-only "Mesh" switch that grants Bluetooth and nearby-device permission to Briar alone (later perhaps a LoRa companion app over USB, only once the local radio rules are confirmed in writing), or Bluetooth stays off outside Administration as today? | the owner's answer | open |
| D14 | before UI1 | The look: A, LineageOS's own modern Android look, or B, an OxygenOS-style look-alike from open parts (OnePlus's own fonts, icons, wallpapers and apps cannot be used); compared side by side on the test phone page | A (comes with the system; B's most recognisable parts need Stage 2) | open |
| G1 | install, first sitting | Does `fastboot oem unlock` work? If not: the OxygenOS 11 detour (`install.md`, section 2) and a further day | — | open |
| G2 | before W16 | A computer for the install, preferably Windows for the recovery tool; without one, W16 to W18 move back | — | open |
