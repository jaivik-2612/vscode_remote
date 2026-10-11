# Antumbra for Android

Antumbra for Android is Android with Tails' rules built in: official
LineageOS 23.2 (Android 16) for the OnePlus 7T Pro (`hotdog`), plus an
Antumbra layer that sends every connection through Tor or blocks it, asks
Tails' Welcome Screen questions at every start, and blocks trackers in the
system's name lookups. It replaces the Debian-based Antumbra, which is
archived next to this folder (`../README.md`); its threat model, Tor
configuration, firewall ideas, Welcome-screen choices and test ideas carry
over.

Tails is a trademark of the Tails project; Tor is a trademark of The Tor
Project, Inc. Antumbra is inspired by Tails, is not Tails, and is endorsed
by neither.

## Status: v0, nothing has run on a phone

Every part below exists as a first version (v0), written to one shared
contract (`docs/design.md`, section 3). Each part's README says what was
checked on a build machine and what only CI or the phone can show. The CI
workflow builds every part and runs the leak test on Google's Android 16
emulator image (x86_64).

Nothing has run on a phone, on LineageOS, on the phone's 4.14 kernel, on
arm64 or under Magisk. The emulator is not the phone: it has no Qualcomm
parts, no modem and a newer kernel. Until the phone has been installed and
its traffic captured, releases say "tested on the Android 16 emulator;
LineageOS build X statically checked", never "tested on the phone". The
work queue is `docs/queue.md`.

## What it does

- **Tor or nothing.** From the moment Android starts, a firewall lets only
  tor's own process reach the Internet. Every other connection, from apps,
  Android's system services and root alike, is passed into Tor or refused.
  Name lookups go through Tor. Other UDP and all IPv6 are refused (DHCP
  renewals by Android's network stack aside). Nothing goes out until the
  Welcome screen's Start.
- **A Welcome screen at every start**, as in Tails: connect to Tor directly,
  through bridges, or stay offline; a new Wi-Fi hardware address; later,
  Persistent Storage; Administration (off); the Unsafe Browser (off).
- **Trackers blocked by the system.** A small DNS filter between the system's
  resolver and Tor's answers "does not exist" for tracker domains. Most apps
  cannot get around it; `docs/design.md` (section 6) lists what it cannot
  block. Tor Browser is deliberately not filtered.
- **Network state kept in RAM.** Saved Wi-Fi networks and Android's DHCP
  lease memory never reach flash, so a new session cannot be linked to the
  last one through them, and a phone that starts without the Antumbra layer
  has no network to join.
- **Planned, not in v0:** a throwaway Android user for each session, Persistent
  Storage, Tor Browser and other apps with their own Tor, a signed app
  repository, time over Tor, the emergency power-off as a privileged app
  (`docs/queue.md`).

## What it is not

- **It is not Tails.** Tails runs from a USB stick and never writes to the
  computer. Antumbra runs from the phone's storage and forgets by destroying
  encryption keys, and only partly so in Stage 1.
- **It cannot prove it has not been tampered with.** The bootloader stays
  unlocked on this phone, so there is no verified boot, and Qualcomm's
  emergency download mode (EDL) is reachable. Someone who has the phone
  unattended can replace its software.
- **It is not fully up to date.** LineageOS publishes weekly builds with
  monthly Android security fixes, but OnePlus stopped firmware updates in
  December 2022, and the kernel (4.14) is past its support. Graphics-chip bugs
  exploited in real attacks are listed for this processor.
- **Calls and SMS are not anonymous**, and the modem is outside the firewall.
  The default is no SIM card.
- **It does not make anyone invisible.** Few people run it, so its users
  stand out, and apps that know who you are still know.
- **For a serious, well-funded adversary, other setups are safer:** Tails on
  a computer, or a supported Google Pixel with GrapheneOS and Tor.

`docs/threat-model.md` has the full list.

## The layers

```
 app or system service            Welcome (device owner, user 0)
   |  TCP to anywhere               | content://org.antumbra.welcome.state/session
   |  DNS to anywhere               v
   v                              module service.sh (root) -- control socket --> tor
 antumbra-fw (iptables, root)
   |  TCP  -> REDIRECT 127.0.0.1:9040 --------------------------> tor TransPort
   |  DNS  -> REDIRECT 127.0.0.1:5353 -> DNS filter (uid 2951) -> tor DNSPort 127.0.0.1:9053
   |  rest -> rejected                                             |
   v                                                               v
 only tor (uid 2950) leaves the phone  <---------------------- the Internet, through Tor
```

| Layer | What it is | Runs as | Folder |
|---|---|---|---|
| Base | Official LineageOS 23.2 for `hotdog`, unmodified | — | not in this repository |
| Root | Magisk, pinned to v31.0; used only by the module | — | not in this repository |
| Module | The Magisk module `antumbra`: boot scripts that arm the firewall before Android starts, keep network state in RAM, set fail-safe settings, start tor and the filter, and open tor's network after Welcome's Start | root | `module/` |
| Firewall | `antumbra-fw`: `arm`, `apply`, `status`, `flush` | root, one-shot | `firewall/` |
| tor | The system tor, built for Android from pinned sources; TransPort, DNSPort and a control socket, no SOCKS port | uid 2950 | `tor/` |
| DNS filter | `antumbra-dnsfilter`: the tracker filter in front of tor's DNSPort, and a read-only status page | uid 2951 | `dnsfilter/` |
| Welcome | The device-owner app: the Welcome screen, the session's policies, the status screen, the emergency tile | an app in user 0 | `welcome/` |
| Apps | Tor Browser and curated privacy apps from a signed repository | apps | planned (`docs/queue.md`, W9) |

This is Stage 1. Stage 2, if build capacity is approved, moves the same
parts into Antumbra's own build of LineageOS, signed with its own keys, with
a working storage that gets a new key and is wiped at every boot
(`docs/design.md`, section 10).

## Folder map

```
antumbra/android/
  README.md          this file
  firewall/          antumbra-fw (POSIX sh) and its network-namespace sandbox test
  tor/               build-tor.sh, sources.lock (pins, SHA-256, signing keys), torrc.in, checks
  dnsfilter/         the DNS filter (Go), the list compiler, list sources and Antumbra's own lists
  welcome/           the Welcome app (Kotlin, Jetpack Compose), package org.antumbra.welcome
  module/            the Magisk module: boot scripts, antumbra-run, overlay, build script, tests
  ci/                the emulator scenarios, the leak analyser and the CI reports
  docs/              design, threat model, install draft, work queue
.github/workflows/antumbra-android.yml   the CI workflow
```

On the phone:

| Path | What it holds |
|---|---|
| `/data/adb/modules/antumbra` (`MODDIR`) | the installed module; `bin/` holds `tor`, `antumbra-dnsfilter`, `antumbra-fw` and the helper `antumbra-run`. The zip carries `bin/arm64-v8a` and `bin/x86_64`; `customize.sh` keeps the one for the CPU |
| `/data/adb/antumbra/{run,state,lists,log}` | the runtime directory, a tmpfs mounted at every boot: tor's control socket and `status.json` (`run`), tor's DataDirectory and the module's state (`state`), updated lists (`lists`), logs (`log`) |
| property `antumbra.fw.armed` | the first 16 hex digits of the live ruleset's SHA-256, set by the module with `resetprop -n` only after `apply` succeeded and was verified |

## Building

No binaries are kept in the repository. Every build script downloads its
pinned sources over HTTPS, checks their SHA-256, and also checks OpenPGP
signatures where the project publishes them. Third-party code stays out of
the tree. Needs a Linux x86_64 host with the Android SDK (`platforms;android-36`,
`build-tools;36.0.0`, `ndk;28.2.13676358`), Go, JDK 17 or later (CI uses
21), `curl`, `make`, `perl` and Python 3. Commands are run from the
repository root unless they say otherwise.

| Part | Build | Check |
|---|---|---|
| firewall | nothing to build; `firewall/antumbra-fw print` shows the ruleset without root | `sudo bash antumbra/android/firewall/tests/sandbox-test.sh` |
| tor | `antumbra/android/tor/build-tor.sh --out TOR_OUT --abi all --jobs 2` | `tor/check-tor-binary.sh`, and as root `tor/hostcheck-tor.sh` |
| DNS filter | `antumbra/android/dnsfilter/build.sh --out DNS_OUT --test --check` | `go vet ./... && go test -race ./...` in `dnsfilter/` |
| block list | `antumbra/android/dnsfilter/fetch-lists.sh --out LISTS --listc DNS_OUT/host/listc` | `DNS_OUT/x86_64/antumbra-dnsfilter -check-list LISTS/dnsfilter.list` |
| Welcome | `cd antumbra/android/welcome && ./gradlew assembleDebug` | `./gradlew testDebugUnitTest lintDebug` |
| module | `antumbra/android/module/build-module.sh --tor TOR_OUT --dnsfilter DNS_OUT --blocklist LISTS/dnsfilter.list --out antumbra-module.zip` | `sh antumbra/android/module/tests/unit.sh`; as root `module/tests/e2e-host.sh` |
| CI tools | — | `python3 -B -m unittest discover -s antumbra/android/ci/tests -v` |

Build tor, the DNS filter and the list first: the module zip is made from
their outputs. Each folder's README has the details, the pinned versions and
the options. `build-module.sh --emulator` installs the module on a running
emulator the way Magisk would (`module/README.md`).

## How CI tests it

`.github/workflows/antumbra-android.yml` runs on every push to the work
branch that touches `antumbra/android/**` or the workflow. A newer push
cancels a run still going. In order:

1. **firewall:** the sandbox test, as root, under bash, dash, busybox and
   mksh, with IPv6: two network namespaces, fake tor and filter services
   under their real UIDs, and probes as root, the network stack, tor, the
   filter, apps and an exempt app.
2. **dnsfilter:** `go vet`, the tests, both static binaries, and the block
   list compiled from its pinned sources and checked by the filter itself.
3. **tor:** tor for arm64-v8a and x86_64 with the pinned NDK, sources checked
   by SHA-256 and signature, then the host check as root and the binary
   checks.
4. **welcome:** the debug APK and the unit tests.
5. **module:** the unit tests, then the module zip from the outputs above.
6. **emulator:** on a runner with KVM, Google's Android 16 image without
   Google services (`system-images;android-36;default;x86_64`), each
   scenario a fresh device, every packet recorded from the first moment of
   boot (`-tcpdump`):
   - **BASELINE:** plain Android left alone for 3 minutes: what it contacts
     by itself.
   - **ANTUMBRA:** the module installed and started as Magisk would at boot
     (the emulator is rooted with `adb root`, not Magisk), Welcome as device
     owner, "Start Antumbra", tor's bootstrap, and a tracker test.

   The leak analyser classifies every packet the emulated phone sent: Tor
   relay or directory, configured bridge, link-level (ARP, DHCP), or LEAK.
   The run passes only with zero LEAK after the firewall was armed, Tor
   traffic in the capture, every connection tor reported present in the
   capture, the tracker names blocked, and every check passed (among them:
   the firewall live, tor and the filter running with no capabilities, no
   IPv6 address but loopback and link-local).

The artifact `antumbra-android-<run>` (14 days) holds the summary, the leak
report, screenshots of the Welcome and status screens, the slimmed captures
and the logs. `ci/README.md` describes every step and what the capture
cannot see.

What CI cannot show: anything about the phone's hardware paths (Wi-Fi
keepalive offload, the modem, Qualcomm's IPA), LineageOS 23.2 itself (the
emulator runs Android 16 QPR0, LineageOS 23.2 is QPR2), the 4.14 kernel,
arm64, Magisk's timing, and which app sent a packet that went to a Tor
relay. Planned additions are in `docs/queue.md`: a Magisk-rooted emulator,
a QPR2 (`google_apis` 36.1) run, and the scenarios Tor killed, filter
killed, network change, reboot, IPv6 router advertisements, DHCP
reconnection, Magisk Safe Mode and update without the Magisk step.

## Documents

- `docs/design.md`: the design: the Tails-feature mapping, the shared
  contract, the firewall policy, the tracker-blocking layers, the boot
  sequence and how it fails closed, Stage 1 and Stage 2, and the checks'
  requirements with their status
- `docs/threat-model.md`: what Antumbra for Android protects against, and
  what it does not
- `docs/install.md`: the install procedure, a draft that has not been
  tried
- `docs/queue.md`: the work queue
- Each part's README: `firewall/`, `tor/`, `dnsfilter/`, `welcome/`,
  `module/`, `ci/`

## Licence

GPL-3.0-or-later, like the rest of Antumbra (`../LICENSE`). The tor binary
is built in tor's GPL mode and is GPL-3.0; its corresponding source is the
pinned tarballs plus `tor/`. The block list's sources keep their own
licences (HaGeZi: GPL-3.0; the Exodus Privacy tracker data: to be confirmed
before a list containing it is published). LineageOS, Magisk and Tor Browser
are not redistributed by this repository.
