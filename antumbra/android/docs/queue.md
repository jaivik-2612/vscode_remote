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
  emulator leak verdict `pass` on the release commit itself; SHA-256 sums,
  signatures and build provenance attached; release notes say which
  LineageOS build was statically checked and that nothing ran on the phone
  (until W16).
- **Never:** push to or merge into `main`, relock a bootloader, add
  `updateJson` to the module, or publish a release outside the gate.

Weeks run Monday to Sunday; W2 starts Mon 19 Oct 2026. Previews for the
emulator only, signed, come weekly from W4; release candidate 1 in W14;
v0.1 after the first week on the phone (W17). The block list updates daily
from W6.

## v0 batch · from 11 Oct · Every part, first version

Built in parallel to one contract, ahead of the plan's W2 to W7. Each stays
`doing` until its CI job passes on the work branch.

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| FW1 | `antumbra-fw` v0: `arm`, `apply`, `status`, `flush`, `print`; rules derived for Android from scratch (TCP into the TransPort, DNS to the filter, the rest refused; tor and the filter held to their own rules; IPv6 refused; a mangle egress gate; DoT and DoH refused; DHCP renewals for the network stack); NFLOG for tests; the exception chains for apps with their own Tor, empty | M | doing | The `firewall` job's sandbox test passes under bash, dash, busybox and mksh, with IPv6 |
| TOR1 | tor 0.4.9.14 for arm64-v8a and x86_64 with the pinned NDK, sources checked by SHA-256 and OpenPGP signature, reproducible; `torrc.in` (TransPort, DNSPort, ControlSocket with cookie, no SOCKS or ControlPort, `DisableNetwork 1`, DataDirectory on tmpfs); binary and host checks | M | doing | The `tor` job passes, the host check as root included |
| DNS1 | `antumbra-dnsfilter` v0 (Go, static): blocked names NXDOMAIN, no AAAA, fails closed, upstream owner check, rate limits, status page on 5380; the list compiler and pinned sources (HaGeZi Multi Pro, Exodus, Antumbra's own list); fuzz targets | M | doing | The `dnsfilter` job passes and the block list compiles from its pinned sources |
| WEL1 | Welcome v0: device owner, locked home screen, Tor direct, bridges or offline, new MAC, Administration, Unsafe Browser (recorded only), baseline and session policies, the state provider, the status screen, the emergency tile (restarts) | M | doing | The `welcome` job passes; the emulator run shows the Welcome and status screens |
| MOD1 | Module v0: `arm` first in post-fs-data; the runtime tmpfs; Wi-Fi store and IpMemoryStore on tmpfs; IPv6 off per interface (and a guard loop); crash dumps off; tor and the filter as 2950 and 2951 with no capabilities (`antumbra-run`); `apply` and the property; `status.json`; fail-safe Settings; Welcome's Start; supervision; the keepalive overlay; no `updateJson` | M | doing | The `module` job passes; `module/tests/e2e-host.sh` passes as root |
| CI1 | The workflow and the emulator leak test v1: BASELINE (plain Android 16) and ANTUMBRA (module, Welcome, Start, tor, tracker test) with `-tcpdump` from boot; the leak analyser against the consensus tor downloaded; checks (firewall live, CapEff 0, no global IPv6); the artifact under 40 MB | M | doing | One full run: ANTUMBRA `pass` with Tor traffic seen; the BASELINE report in the artifact |
| DOC1 | `README.md`, `design.md`, `threat-model.md`, `install.md` (draft), this queue | S | doing | In the tree; the contract in `design.md` matches every part's README |

## W2 · 19 to 25 Oct · Freeze the Debian track, the emulator job passes

The emulator job passing is CI1 (v0 batch).

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| REL0 | Freeze the Debian track after decision D1: tag `antumbra-debian-final` on its last commit, stop its daily VM run, Daily page fed by the Android emulator. Its documents are already marked archived | S | blocked: D1 | Tag pushed, `antumbra-vm.yml` no longer scheduled, the page shows the Android run |
| REL1 | Mirror the official LineageOS build the release is checked against, with its `build-manifest.xml` and the SHA-256 values from the download API; static checks of the zip: iptables and the `-restore` tools present, init and Updater assumptions, netd and Connectivity changes against AOSP `android16-release`; a weekly check of `hotdog`'s builds for LineageOS 24 | M | todo | A CI job checks the mirrored build and reports any LineageOS 24 build for `hotdog` |

## W3 · 26 Oct to 1 Nov · Leak baselines

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| CI2 | Leak test v1 completed: each relay connection attributed to tor's UID (or an exempt UID) on the device; NFLOG records of redirected flows with their UID in the report; the log of names the system looks up, with unexpected names flagged | M | todo | The report lists UIDs for every flow and the system's looked-up names |
| CI3 | A baseline with a pinned Orbot as always-on VPN with "Block connections without VPN", to show what a VPN alone lets out | S | todo | A third report in the artifact |
| CI4 | A secondary QPR2 run on Google's `google_apis` image for API 36.1 (LineageOS 23.2 is QPR2; the `default` image is QPR0), Google services disabled before the baseline | S | todo | The ANTUMBRA scenario passes on QPR2 too |

## W4 · 2 to 8 Nov · A rooted emulator, the first preview

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| CI5 | A Magisk-rooted emulator, the way Magisk's own CI does it (`avd.sh`), Magisk v31.0; the module installed through Magisk; the capture from power-on of a boot with the module | M | todo | Only Tor traffic leaves, during boot too, with Magisk's real boot stages |
| CI5a | `su` from a UID outside user 0 is denied ("Device owner only") | S | todo | The check passes in the Magisk run |
| REL2 | Weekly emulator preview: module zip and Welcome APK, signed, with SHA-256 sums and provenance | S | todo | The first preview passes the release gate |

## W5 · 9 to 15 Nov · Quiet Android, more scenarios

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| MOD2 | Time over Tor, as Tails does: after tor connects, the time from HTTPS Date headers fetched through Tor, set by root; automatic time stays off | M | todo | In the emulator, a clock set wrong by hours is corrected after bootstrap |
| CI6 | Scenarios: tor killed, network change, reboot; zero leaks in each | M | todo | Each scenario passes |
| CI7 | An IPv6 router-advertisement source on the emulator's network | S | todo | No global or ULA address appears, in `ip -6 addr` or in an app's `getifaddrs` |
| CI8 | Probes from an app UID: the router on 80, 5000 and 49152, `127.0.0.1:9052`, another app's loopback port; DHCP reconnection with a new MAC | S | todo | Every probe fails; the DHCPDISCOVER carries no requested-IP option |
| FW2 | Decision D7 with the NFLOG data from CI2: keep redirecting system UIDs into Tor, or refuse UIDs below 10000 | S | todo | The decision recorded and, if changed, the firewall and contract updated together |
| PH0 | The arm64 binaries on a real arm64 Android, unprivileged, in Termux: tor built with `--api 30` (`--verify-config`), the filter's `-self-test` | S | todo | Both run and pass on an Android 11 or 12 phone |

## W6 · 16 to 22 Nov · The tracker filter v1 and the daily list

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| DNS2 | The daily list job: fetch, deduplicate, allowlist, compile, sign with the list key; published as a release asset under a fixed tag; the DoH address list for the firewall from the same job | M | todo | A signed list and its signature are published by a run; the filter refuses an unsigned one |
| DNS3 | The Exodus Privacy tracker data's licence confirmed (attribution and share-alike duties), or the source left out | S | todo | The licence recorded in `dnsfilter/lists/sources.conf` |
| CI9 | Filter killed: lookups stop; the tracker test extended to Exodus and vendor names | S | todo | Lookups fail while the filter is down; known tracker names are blocked |

## W7 · 23 to 29 Nov · Welcome v1, bridges, keys

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| WEL2 | Welcome wording and flow checked against the archived Welcome screen; screenshots of every state | S | todo | Screens in the artifact; wording reviewed |
| TOR2 | lyrebird from pinned, verified sources for both ABIs, in the module, with `ClientTransportPlugin`; obfs4, WebTunnel and meek_lite bridges accepted | M | todo | A bridges session with built-in obfs4 bridges bootstraps in the emulator |
| REL3 | Keys generated after decision D5: app, repository index, block list, module | S | blocked: D5 | Keys stored as secrets with an encrypted backup outside GitHub |
| CI10 | One install script sets up a fresh emulator alone: module, Welcome, provisioning | S | todo | A fresh emulator is set up by the script alone |

## W8 · 30 Nov to 6 Dec · Throwaway sessions

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| AM1 | Each session a new ephemeral Android user created by Welcome (affiliated, apps installed from user 0, then switched to); ending a session is a restart; the emulator's user limit set to 4 as on LineageOS | M | todo | A session runs in a new user that is gone after a restart |
| AM2 | System records to RAM in post-fs-data (`design.md`, section 9), and deleted at shutdown | M | todo | After a restart none of the paths holds anything from the session |
| AM3 | The amnesia test: a marker text typed in a session, a restart, storage searched for it; plus a dump of the section 9 paths | M | todo | The marker text is gone |
| MOD3 | IpMemoryStore cleared whenever the MAC address changes within a session | S | todo | CI8's DHCP check passes after a mid-session MAC change |
| MOD4 | Debugging off in every session: `ro.debuggable=0` with `resetprop` (tested for breakage), `DISALLOW_DEBUGGING_FEATURES` in Administration too, adb settings and logging reset and `adb_keys` deleted at boot; CI keeps a test-only way in | M | todo | In a non-test build no session has adb, and nothing else breaks |

## W9 · 7 to 13 Dec · Apps with their own Tor, the repository

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| FW3 | The relays-only exception: a per-UID chain on new connections or an `xt_bpf` map of (address, ORPort); a non-root helper refreshing it from the system tor's consensus every hour and at each session start; failing closed when stale; bridges entered at Welcome added; exempt UIDs rewritten each session | L | todo | Tor Browser connects; nothing else leaves; rule cost measured in the emulator (the phone in W17) |
| APP1 | Tor Browser (official APK, signature checked) and the curated apps; Antumbra's repository in F-Droid format, signed, published as release assets under a fixed address (decision D6) | M | todo | Apps install from the repository over Tor in the emulator |
| MOD5 | A SELinux domain of their own for tor and the filter (`sepolicy.rule`), tested on the Magisk emulator | M | todo | Both run confined, and the scenarios still pass |
| WEL3 | Make `antumbra.fw.armed` readable to Welcome by policy, and drop the status-page fallback | S | todo | Welcome decides from the property alone |

## W10 · 14 to 20 Dec · Persistent Storage v1

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| AM4 | Persistent Storage as a separate Android user with a long passphrase; its Wi-Fi networks (non-persistent MAC, locked) and bridges re-added only after `antumbra.fw.armed`; hidden networks refused; the passphrase field without learning and `FLAG_SECURE`; the newer block list kept here | L | todo | Create, unlock and wrong-passphrase tests pass |

## W11 · 21 to 27 Dec · Emergency power-off, the Unsafe Browser (light week)

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| WEL4 | Emergency off powers off: Welcome as a privileged app with a `SHUTDOWN` allowlist installed by the module, or the module carries out Welcome's power-off request; a Ripple/PanicKit trigger; optional power-off after some hours locked | M | todo | The panic test powers the emulator off |
| APP2 | The Unsafe Browser: a WebView app with its own UID, bound to the Wi-Fi network, launched by hand; a root helper opens its clearnet and DNS exemption on launch and closes it on exit; Tails' warning | M | todo | It reaches a fake login page in CI; nothing else leaves outside Tor |

## W12 · 28 Dec to 3 Jan · Update safety

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| CI11 | Zero-packet scenarios from power-on: a reboot without the module with Wi-Fi on and a saved network; Magisk Safe Mode; a module `disable` file; a slot switch without re-root; tethering cannot be enabled | M | todo | Removing the add-on leaves the phone with no network |
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
| PH1 | The install (`install.md`), in two sittings, after gate G2; gate G1 at the unlock | L | blocked: G2 | The phone reaches Tor, and a capture shows only Tor |

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
| D1 | W2 | Freeze the Debian track: tag it, stop its daily VM run, switch the Daily page to the Android emulator? | yes | open |
| D2 | apply now, decide W18 | Build capacity for Stage 2: apply for a free crave.io account now (an application by a person, not by CI), spend nothing before February, then decide between crave.io, on-demand servers (about €15 to €40 a month) and an always-on server (about €100 a month plus set-up) | apply now; decide with phone data | open |
| D3 | W2 | A SIM card in the Antumbra phone? | no SIM, Wi-Fi only; a "phone mode" later, clearly labelled as not anonymous | open |
| D4 | before W6 | Daily jobs: Antumbra's workflows on the default branch (GitHub's schedules run only there), or runs started by a push from the routine? | routine-driven; a pause leaves the block list stale and the phone uses the module's copy | open |
| D5 | before W7 | Generate the signing keys (app, repository index, block list, module), stored as secrets with a passphrase-encrypted backup outside GitHub. A device-owner app can only be updated with the same key | yes | open |
| D6 | before W9 | The app repository as release assets under a fixed tag, or a separate public repository (the repository's Pages site serves another project) | release assets; the address fixed from RC1 on | open |
| D7 | W5 | System UIDs: redirected into Tor (contract) or refused below 10000 (leak check)? | decide with CI2's data | open |
| D8 | W12 | LineageOS 24: has `hotdog` moved to 24.0? Then the emulator moves to Android 17 and the install takes 24.0 | follow REL1's weekly check | open |
| D9 | before RC1 | Welcome on the phone as a removable test build (`testOnly`) or as a release (removed only by a factory reset) | — | open |
| D10 | W9 | If the relays-only exception costs too much on the 4.14 kernel: apps with their own Tor use bridges only | measure first | open |
| G1 | install, first sitting | Does `fastboot oem unlock` work? If not: the OxygenOS 11 detour (`install.md`, section 2) and a further day | — | open |
| G2 | before W16 | A computer for the install, preferably Windows for the recovery tool; without one, W16 to W18 move back | — | open |
