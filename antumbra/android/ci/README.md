# CI for the Android-based Antumbra

The workflow is `.github/workflows/antumbra-android.yml`. It runs on every
push to `claude/tails-mobile-privacy-os-c71ate` that touches
`antumbra/android/**` or the workflow, and by hand (`workflow_dispatch`, once
the file is on the default branch). A newer push cancels a run that is still
going. Every job has a time limit.

| Job | Runner | What it does |
|---|---|---|
| `firewall` | ubuntu-24.04 | `firewall/tests/sandbox-test.sh` as root, under bash, dash, busybox and mksh, with IPv6 required |
| `dnsfilter` | ubuntu-24.04 | `go vet`, `go test`, both static binaries (`build.sh --test --check`), the block list (`fetch-lists.sh`) checked by the filter itself |
| `tor` | ubuntu-24.04 | `build-tor.sh` for arm64-v8a and x86_64 with the NDK pinned in `tor/sources.lock` (the runner's copy if it is that revision, else `sdkmanager`), sources checked by SHA-256 and OpenPGP signature; `hostcheck-tor.sh` as root; `check-tor-binary.sh` on both. Cached under `build-tor.sh --print-cache-key` |
| `welcome` | ubuntu-24.04 | `./gradlew assembleDebug`, then `testDebugUnitTest` |
| `module` | ubuntu-24.04 | `module/tests/unit.sh`, then `build-module.sh` with the outputs of the jobs above |
| `emulator` | ubuntu-24.04 with KVM | the two scenarios below, the leak analysis, the job summary and the artifact |

`module` needs `firewall`, `dnsfilter`, `tor` and `welcome`; `emulator` needs
all five.

## Artifacts

- `antumbra-android-<run number>` (14 days, kept under 40 MB by
  `citool.py pack`):
  - `summary.md`: the job summary
  - `verdict.json`: the final verdict and every problem behind it
  - `leak-report.md` and `leak-report.json`: both scenarios, every flow
  - `screenshots/`: `baseline-home.png`, and `antumbra-welcome-1.png`,
    `-welcome-2-choices.png`, `-status-1-started.png`,
    `-status-2-bootstrapped.png`, `-status-3-after-tracker-test.png`
    (`-final.png` after a failure)
  - `baseline/` and `antumbra/`: `events.tsv`, `checks.tsv`, `analysis.json`;
    for ANTUMBRA also `tracker-test.json`, `filter-status.json` (the DNS
    filter's `/status`, which includes the module's `status.json`),
    `bootstrap-progress.tsv`, `provider-row.txt`, `tor-connections.txt`,
    `consensus.gz`
  - `capture/`: each capture cut to 256 bytes per frame (`*.slim.pcap`),
    and the full captures when they fit (dropped first otherwise; the list
    is in `omitted.txt`)
  - `logs/`: filtered logcat, `tor.log`, the module's, firewall's and
    filter's logs, `build-module.sh`'s output, the firewall's state
    (`iptables-save`), process capabilities, IPv6 addresses, device facts
  - `build/`: one note per build job
- `antumbra-android-module-<n>` (the Magisk zip) and
  `antumbra-android-welcome-<n>` (the debug APK), 5 days; also
  `antumbra-android-tor-<n>` and `antumbra-android-dnsfilter-<n>`.

## The emulator job

Google's Android 16 image without Google services
(`system-images;android-36;default;x86_64`), a Pixel 6 profile (411 dp
wide, as the OnePlus 7T Pro), through `reactivecircus/android-emulator-runner`
v2.38.0 pinned by commit. Each scenario is a fresh AVD with `-wipe-data`
and `-no-snapshot`, started with `-tcpdump <file>`: every frame on the
emulator's virtual network from the first moment of boot.
`-feature -WiFiPacketStream` keeps Wi-Fi on that network: from emulator
36.5 on, Wi-Fi otherwise goes through netsim, which `-tcpdump` does not
see.

### BASELINE (`emulator-baseline.sh`)

Plain Android, nothing installed. A clock marker, three minutes alone, a
screenshot of the home screen, the open connections and the logs, then the
capture is stopped. The report lists every destination and says how
Antumbra would judge it. Not judged, except that the capture must show
traffic from the phone.

### ANTUMBRA (`emulator-antumbra.sh`)

1. `adb root`, device facts, a clock marker.
2. Airplane mode on until Android has no network.
3. Event `install_start`, then `module/build-module.sh --emulator` with the
   files of the module zip itself (the job unpacks the zip the `module`
   job built). It installs the module, restarts the framework around
   `post-fs-data.sh` (`antumbra-fw arm` first), starts `service.sh`, and
   waits for `antumbra.fw.armed`.
4. Airplane mode off: networks come up behind the firewall.
5. The Welcome APK, `dpm set-device-owner`, Welcome as the home app,
   screenshots.
6. The choices, tapped where `uiautomator dump` shows them (by the test
   tags in `welcome/README.md`, else by their text): Tor directly, new
   Wi-Fi address, **Administration on**, Unsafe Browser off; then "Start
   Antumbra". Administration is on because without it Welcome switches USB
   debugging off and the job loses adb. The provider row must say
   `started=1` and `tor_mode=direct`.
7. Wait (10 minutes at most) for `module.tor.bootstrap` = 100 in the
   filter's `/status` (through `adb forward`), or "Bootstrapped 100%" in
   `tor.log`. Screenshot of the status screen.
8. Tracker test: `doubleclick.net` (HaGeZi) and `stats.lineageos.org`
   (Antumbra's own list) asked of the filter directly, DNS over TCP to
   127.0.0.1:5353 through `adb forward`; both must be NXDOMAIN (or the zero
   address). `check.torproject.org` should resolve through Tor (a warning
   otherwise: exit lookups fail now and then). The same
   names through Android's resolver with `ping`, as root and as Welcome's
   uid (`run-as`), recorded; their ICMP must not leave either.
9. Evidence and checks, also after a failure: tor's established
   connections (`/proc/net/tcp`, uid 2950), the consensus tor downloaded
   (`/data/adb/antumbra/state/tor/cached-microdesc-consensus`), the
   session's bridges; logs. Checks: `antumbra-fw status` says `live`; tor
   (uid 2950) and the filter (uid 2951) run with CapEff and CapPrm 0; tor
   listens only on TCP 127.0.0.1:9040 and UDP 127.0.0.1:9053, the filter
   only on 127.0.0.1:5353 and TCP 127.0.0.1:5380, and nothing on a SOCKS or
   control port (9050, 9051, 9052, 9150, 9151); `tor-control.sock` is 0660
   and owned by 2950:2950; Wi-Fi's store is on a tmpfs (NetworkStack's
   databases too, a warning only); no IPv6 address but loopback (a
   link-local one is a warning). Then the capture is stopped.

Steps 2 and 4 are not in the plain install procedure. They stop plain
Android's own traffic before the firewall is armed, so that nothing is in
flight at the cutoff, and they bring the network up behind the firewall, as
on the phone, where `post-fs-data.sh` arms it before any network exists.

## The leak analyser

`leak_analyser.py analyse` reads the capture with `pcapread.py` (pcap and
pcapng; Ethernet, raw IP, Linux cooked, 802.11 and radiotap; standard
library only) and classifies every packet the phone sent:

| Class | Meaning | Allowed after arm |
|---|---|---|
| `tor-relay` | TCP to the ORPort of a relay in the consensus pulled from the phone | yes |
| `tor-directory` | TCP to a directory authority (the consensus's `dir-source` lines) or a fallback directory compiled into tor (read from `bin/x86_64/tor`), which tor contacts before it has a consensus | yes |
| `bridge` | TCP to a bridge the session configured | yes |
| `lan-dhcp` | a DHCP client message (UDP 68 to 67) to the broadcast address or a local server. Android sends it from a packet socket, outside the firewall, by design (the design allows DHCP for NetworkStack) | yes |
| `link-arp`, `link-80211` | ARP, and 802.11 association frames in a Wi-Fi capture | yes |
| `ci-marker` | this CI's clock marker, before the module is installed | before arm only |
| `LEAK` | anything else: `dns`, `tcp`, `udp`, `lan`, `icmp`, `ipv6`, `multicast`, `dhcp`, `fragment`, `unattributed`, `undecoded`, `other` | no |

Emulator infrastructure that is not the phone's own traffic is every frame
sent by the emulator's user-mode network (QEMU slirp) itself: its virtual
hosts use MAC addresses `52:55:<IPv4>` and `52:56:<IPv6>` (10.0.2.2: the host
alias, gateway and DHCP server; 10.0.2.3 to 10.0.2.6: DNS forwarders;
`fec0::2`, `fec0::3`). Those frames are counted, not listed. The phone's own
packets to those hosts are listed and judged: a lookup sent to 10.0.2.3 is
the phone's DNS leaving outside Tor (on a phone, the Wi-Fi router's
resolver), a LEAK after arm; TCP to 10.0.2.2 reaches the machine that runs
the emulator (on a phone, the local network), a LEAK. In the baseline these
are listed as what they would be.

The phone's addresses are those seen acting as a client (TCP SYN, queries to
low UDP ports, ARP requests, echo requests, IPv6 solicitations, DHCP) from a
MAC address that is not slirp's, in private, link-local or site-local
ranges; `--guest` overrides. A frame from the phone's MAC address with a
source address that is not the phone's is a LEAK (`unattributed`).

**The arm cutoff.** Capture time stamps come from the emulator, events from
the CI host. The clock marker (one UDP datagram `ANTUMBRA-CLOCK <nonce>` to
10.0.2.2:9, sent before the module is installed, between two host time
stamps) gives the offset between the two clocks. The cutoff is the host
time of `install_start`, which is taken before `build-module.sh` starts and
so before `antumbra-fw arm` runs, moved to the capture's clock with the
lower bound of the offset, minus 1 s (3 s without a marker). Every packet
from the cutoff on counts. The cutoff can only be early, never late.

**Verdicts.** ANTUMBRA passes only when, after the cutoff, there is no LEAK,
there is Tor traffic, the consensus was read, and every connection tor
reported in `/proc/net/tcp` is in the capture (otherwise the capture missed
a path out of the phone: `blind`, a failure). BASELINE is `info`, and fails
only if the capture shows nothing from the phone (`blind`) or cannot be
read (`error`). `summary.py --verdict` fails the job when either scenario
did not run to the end, a check failed, or the leak test did not pass.

### What it cannot see

- Only the emulator's virtual network is captured. Hardware paths of the
  phone (Wi-Fi keep-alive offload, the modem, Qualcomm's IPA) do not exist
  here; the capture on the phone in January covers them.
- A capture cannot tell which app sent a packet: a connection to a Tor
  relay's ORPort counts as Tor even if another app made it.
- What goes through Tor is not visible. The filter's counters and the
  tracker test cover names looked up through Tor.
- The emulator runs Android 16 QPR0 on a 6.x kernel, not LineageOS 23.2
  (QPR2) on the phone's 4.14 kernel, and is rooted with `adb root`, not
  Magisk.

## Running the pieces by hand

```sh
# Unit tests of the CI tools (synthetic captures, no emulator)
python3 -B -m unittest discover -s antumbra/android/ci/tests -v

# The leak analysis of a capture you made (for example on the phone, with
# tcpdump on wlan0 or a hotspot capture)
python3 -B antumbra/android/ci/leak_analyser.py analyse --scenario phone \
    --pcap phone.pcap --consensus cached-microdesc-consensus \
    --guest 192.168.1.23 --out phone.json
python3 -B antumbra/android/ci/leak_analyser.py report --in phone.json \
    --json leak-report.json --md leak-report.md

# A scenario against a running emulator (adb root works on 'default' and
# 'google_apis' images), with the module zip unpacked in /tmp/module
export ANTUMBRA_CI_OUT=/tmp/report ANTUMBRA_MODULE_TREE=/tmp/module \
    ANTUMBRA_WELCOME_APK=app-debug.apk
bash antumbra/android/ci/emulator-antumbra.sh
```

| File | What it is |
|---|---|
| `emulator-baseline.sh`, `emulator-antumbra.sh` | the two scenarios |
| `lib/common.sh` | adb, uiautomator, events, checks, screenshots, logs |
| `analyse.sh` | runs the analyser on both captures after the emulator exits |
| `pcapread.py` | the capture reader and decoder |
| `leak_analyser.py` | classification, verdicts, reports; also `tor-conns` and `slim` |
| `citool.py` | uiautomator search, DNS over TCP, JSON lookups, the artifact size limit |
| `summary.py` | the job summary and the final verdict |
| `sdk-install.sh` | the pinned NDK, platform 36 and build tools 36.0.0 |
| `tests/test_ci.py` | unit tests with generated captures |
