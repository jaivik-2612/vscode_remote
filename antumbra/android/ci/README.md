# CI for the Android-based Antumbra

The workflow is `.github/workflows/antumbra-android.yml`. It runs on every
push to `claude/tails-mobile-privacy-os-c71ate` that touches
`antumbra/android/**` or the workflow, and by hand (`workflow_dispatch`, once
the file is on the default branch). A newer push cancels a run that is still
going. Every job has a time limit.

| Job | Runner | What it does |
|---|---|---|
| `firewall` | ubuntu-24.04 | shellcheck of `antumbra-fw` and the sandbox test; `firewall/tests/sandbox-test.sh` as root with the legacy iptables backend (Android's; `AFW_TEST_BACKEND=legacy`, no silent fallback to nft), under bash, dash, busybox and mksh, with IPv6 required |
| `dnsfilter` | ubuntu-24.04 | `build.sh --test --fuzz 60s --check --require-selftest`: `go vet`, `go test -race`, 60 s of fuzzing each for `FuzzHandle` and `FuzzReply` (a failing input is uploaded), both static binaries, and both self-tests run (arm64 under `qemu-user-static`); then the block list (`fetch-lists.sh`) checked by the filter itself, with a fresh `SHA256SUMS` of exactly the files in the artifact. The last sources that downloaded cleanly are cached; a source that fails to download now is taken from there (`--fallback`), with a warning in the summary |
| `tor` | ubuntu-24.04 | `build-tor.sh` for arm64-v8a and x86_64 with the NDK pinned in `tor/sources.lock` (the runner's copy if it is that revision, else `sdkmanager`, through `sdk-install.sh`), sources checked by SHA-256 and OpenPGP signature; `hostcheck-tor.sh` as root; `check-tor-binary.sh` on both. Cached under `build-tor.sh --print-cache-key` plus `-host`: the cache and the artifact also hold `host/tor-hostcheck`, the static x86_64 tor that `module-e2e` runs |
| `welcome` | ubuntu-24.04 | `./gradlew assembleDebug`, then `testDebugUnitTest lintDebug`, `tools/builtin-bridges.sh --check`, and shellcheck of `gradlew`, `ci/welcome-adb.sh` and `tools/builtin-bridges.sh` |
| `module` | ubuntu-24.04 | shellcheck (`-s sh -x`) of every module script, `module/tests/unit.sh`, then `build-module.sh` with the outputs of the jobs above |
| `module-e2e` | ubuntu-24.04 | `module/tests/e2e-host.sh` as root: the module's boot scripts on Linux with the real firewall, tor, DNS filter and `antumbra-run`, under Android 16's toybox and mksh and Magisk's busybox, built from the pins in `module/tests/build-test-tools.sh` (cached by that file's hash) |
| `emulator` | ubuntu-24.04 with KVM | the two scenarios below, the leak analysis, the job summary, `verdict.json` and the artifact; twice: Android 16 (`android-36;default`, blocking) and Android 16 QPR2 (`android-36.1;google_apis`, the Android version of LineageOS 23.2, with Google services; `continue-on-error`) |

`module` needs `firewall`, `dnsfilter`, `tor` and `welcome`; `module-e2e`
needs `dnsfilter` and `tor`; `emulator` needs the first five.

`sdk-install.sh` installs the pinned NDK, platform 36 and build tools
36.0.0 when the runner lacks them, and checks each afterwards. It answers
sdkmanager's licence prompts with `yes`, whose SIGPIPE when sdkmanager exits
is kept out of the pipeline's status (under `pipefail` it would otherwise
end the script after a successful install); sdkmanager's own failure still
stops it.

## Artifacts

- `antumbra-android-<run number>` (14 days, kept under 40 MB by
  `citool.py pack`; `antumbra-android-qpr2-<run number>` for the QPR2 run):
  - `summary.md`: the job summary
  - `verdict.json`: the final verdict, every problem behind it, and the
    warnings (written before the upload; the job's last step fails on it)
  - `leak-report.md` and `leak-report.json`: both scenarios, every flow,
    the armed window, and the names and destinations reached through Tor
  - `screenshots/`: `baseline-home.png`, and `antumbra-welcome-1.png`,
    `-welcome-2-choices.png`, `-status-1-started.png`,
    `-status-2-bootstrapped.png`, `-status-3-after-tracker-test.png`
    (`-final.png` after a failure)
  - `baseline/` and `antumbra/`: `events.tsv`, `checks.tsv`, `analysis.json`;
    for ANTUMBRA also `tracker-test.json`, `probes-live.tsv`,
    `filter-status.json` (the DNS filter's `/status`, which includes the
    module's `status.json`), `bootstrap-progress.tsv`, `provider-row.txt`,
    `tor-connections.txt`, `tor-streams.txt` (tor's STREAM events),
    `dnsfilter.log` (the filter's log with every query; dropped first if
    the artifact is too large), `device-ipv4.txt`, `disable-ipv6.txt`,
    `consensus.gz`
  - `capture/`: each capture cut to 256 bytes per frame (`*.slim.pcap`),
    and the full captures when they fit (dropped first otherwise; the list
    is in `omitted.txt`)
  - `logs/`: filtered logcat, `tor.log`, the module's, firewall's and
    filter's logs, `build-module.sh`'s output, the firewall's state
    (`iptables-save`) and the armed phase, Wi-Fi, Welcome's policy checks,
    process capabilities, IPv6 addresses, the mount tables of
    system_server and NetworkStack, device facts (emulator version and
    system image revision)
  - `build/`: one note per build job
- `antumbra-android-module-<n>` (the Magisk zip) and
  `antumbra-android-welcome-<n>` (the debug APK), 5 days; also
  `antumbra-android-tor-<n>`, `antumbra-android-dnsfilter-<n>` and
  `antumbra-android-e2e-<n>`.

## The emulator job

Google's Android 16 image without Google services
(`system-images;android-36;default;x86_64`), a Pixel 6 profile (411 dp
wide, as the OnePlus 7T Pro), through `reactivecircus/android-emulator-runner`
v2.38.0 pinned by commit, with the emulator pinned too (`emulator-build:
16428233`, 37.2.12 from Google's stable channel, downloaded over HTTPS from
dl.google.com). The system image is sdkmanager's current revision of the
package, recorded in `logs/<scenario>-device.txt`. Each scenario is a fresh
AVD with `-wipe-data` and `-no-snapshot`, started with `-tcpdump <file>`:
every frame on the emulator's virtual network from the first moment of
boot. `-feature -WiFiPacketStream` keeps Wi-Fi on that network: from
emulator 36.5 on, Wi-Fi otherwise goes through netsim, which `-tcpdump`
does not see (the analyser's address coverage check would then fail the
run as blind).

### BASELINE (`emulator-baseline.sh`)

Plain Android, nothing installed. A clock marker, three minutes alone, a
screenshot of the home screen, the open connections and the logs, then the
capture is stopped. The report lists every destination and says how
Antumbra would judge it. Not judged, except that the capture must show
traffic from the phone.

### ANTUMBRA (`emulator-antumbra.sh`)

1. `adb root`, device facts, Wi-Fi's hardware address, a clock marker.
2. Airplane mode on until Android has no network.
3. `setprop debug.antumbra.log_queries 1` (the module then starts the DNS
   filter with `-debug-log-queries`, on the emulator only), event
   `install_start`, then `module/build-module.sh --emulator --zip` with the
   module zip the `module` job built, as it is (`--no-overlay`: the
   keep-alive overlay needs Magisk to be mounted). It installs the module,
   restarts the framework around `post-fs-data.sh` (`antumbra-fw arm`
   first), starts `service.sh`, and waits for `antumbra.fw.armed`, which
   must equal the first 16 hex digits of `antumbra-fw status`'s `hash=`
   with the state `live`. From here tor's STREAM events are recorded
   (`lib/tor-streams.sh`, run on the device as tor's uid 2950 through the
   module's `antumbra-run`: root never opens tor's cookie or socket).
4. Airplane mode off and mobile data off (`svc data disable`): the phone
   has no SIM, so its only network is Wi-Fi, which has no saved network
   (Wi-Fi's store is on an empty tmpfs).
5. The Welcome APK; the debug build's test hook
   `setprop debug.antumbra.keep_adb 1` (honoured only by debuggable or
   testOnly builds; Welcome then leaves USB debugging on; `welcome/README.md`,
   "Test hook"); `dpm set-device-owner`; Welcome as the home app;
   screenshots.
6. The choices, tapped where `uiautomator dump` shows them (by the test
   tags in `welcome/README.md`, else by their text): Tor directly, new
   Wi-Fi address, **Administration off** (the default session a user gets),
   Unsafe Browser off; then "Start Antumbra". adb must still answer; the
   provider row must say `started=1`, `tor_mode=direct` and `admin=0`.
7. Wi-Fi joined as a person would (`cmd wifi connect-network AndroidWifi
   open`, once Welcome has switched Wi-Fi on); Wi-Fi must become the
   default network (the `Transports:` of `dumpsys connectivity`'s default
   network), else the check fails. Wi-Fi's hardware address must differ
   from the one before the module (a warning). Welcome's own checks through
   `welcome/ci/welcome-adb.sh`: `check-policies --keep-adb` (the
   device-owner restrictions of a default session) and `check-addon` (the
   status screen shows the firewall live).
8. Wait (10 minutes at most) for `module.tor.bootstrap` = 100 in the
   filter's `/status` (through `adb forward`), or "Bootstrapped 100%" in
   `tor.log`. Screenshot of the status screen.
9. Tracker test: `doubleclick.net` (HaGeZi) and `stats.lineageos.org`
   (Antumbra's own list) asked of the filter directly, DNS over TCP to
   127.0.0.1:5335 through `adb forward`; both must be NXDOMAIN (or the zero
   address). `check.torproject.org` should resolve through Tor (a warning
   otherwise: exit lookups fail now and then). The same names through
   Android's resolver with `ping`, as root and as Welcome's uid (`run-as`),
   recorded; their ICMP must not leave either.
10. Probes with the full rule set, as root and as an app (Welcome's uid):
    TCP to the emulator host's ports 80, 5000 and 49152 (on the phone, the
    router's web page, UPnP and the like; the capture judges whether a SYN
    left), to 127.0.0.1:9052, and to another app's loopback port (a
    listener as uid 10998 with the inet group, which must never receive the
    probe's token).
11. **The armed state with the network up.** `service.sh`'s loop is paused
    (SIGSTOP), `antumbra-fw flush` (with the module's firewall directory)
    puts the firewall back to its armed set, and `antumbra.fw.armed` is
    cleared. Between the events `armed_probe_start` and `armed_probe_end`:
    ping to 10.0.2.2, 1.1.1.1 and a name, TCP to a relay's ORPort (one of
    tor's connections) and to 10.0.2.2:80, UDP to 10.0.2.2:9 and DNS to
    10.0.2.3, as root; ping, a name, the relay and 10.0.2.2:80 as Welcome's
    uid; the relay as tor's uid. The capture must show nothing from the
    phone in that window but ARP and DHCP (which Android sends from packet
    sockets, outside the firewall). The firewall must still be `armed` at
    the end. Then the loop resumes, finds the firewall armed, and loads the
    full rule set again: it must be `live` within 90 s with the property
    matching.
12. Evidence and checks, also after a failure: tor's established
    connections (`/proc/net/tcp`, uid 2950); the consensus tor downloaded
    and the module's `status.json`, read as uid 2950 through `antumbra-run`
    (tor can write in `run/` and `state/tor/`, so root must not follow a
    link there into the artifact); the session's bridges; logs. Checks:
    the firewall `live` and `antumbra.fw.armed` equal to its hash's first
    16 hex digits (any other state fails); tor (uid 2950) and the filter
    (uid 2951) run with CapEff and CapPrm 0; tor listens only on TCP
    127.0.0.1:9040 and UDP 127.0.0.1:9053, the filter only on
    127.0.0.1:5335 and TCP 127.0.0.1:5380, no other uid holds any of these
    ports on any address, and nothing listens on a SOCKS or control port
    (9050, 9051, 9052, 9150, 9151); `tor-control.sock` is a socket, 0660,
    owned by 2950:2950; Wi-Fi's store is on a tmpfs in system_server's
    mount namespace (`/proc/<pid>/mountinfo`), NetworkStack's databases in
    NetworkStack's (a warning only); IPv6 is off: no IPv6 address on any
    interface but `lo`, and `disable_ipv6` = 1 for every entry but `lo`;
    the DNS filter ran with its query log (a warning). The device's IPv4
    addresses (`ip -4 addr`) go to the analyser. Then the capture is
    stopped (the event `capture_stop` says whether the console confirmed).

Steps 2 and 4 are not in the plain install procedure. They stop plain
Android's own traffic before the firewall is armed, so that nothing is in
flight at the cutoff, and they bring the network up behind the firewall, as
on the phone, where `post-fs-data.sh` arms it before any network exists.
Step 11 stands in for the boot path, where the armed set meets the network
before `service.sh` loads the full set; the emulator's module is started by
hand after boot, so that path itself is not what runs here.

## The leak analyser

`leak_analyser.py analyse` reads the capture with `pcapread.py` (pcap and
pcapng; Ethernet, raw IP, Linux cooked, 802.11 and radiotap; standard
library only) and classifies every packet the phone sent:

| Class | Meaning | Allowed after arm |
|---|---|---|
| `tor-relay` | TCP to the ORPort of a relay in the consensus pulled from the phone | yes |
| `tor-directory` | TCP to the ORPort of a directory authority (the consensus's `dir-source` lines) or of a fallback directory compiled into tor (read from `bin/x86_64/tor`), which tor contacts before it has a consensus | yes |
| `bridge` | TCP to a bridge the session configured | yes |
| `lan-dhcp` | a DHCP client message (UDP 68 to 67) to the broadcast address or a local server. Android sends it from a packet socket, outside the firewall, by design (the design allows DHCP for NetworkStack) | yes, unless it asks for a lease from before arm |
| `link-arp`, `link-80211` | ARP, and 802.11 association frames in a Wi-Fi capture | yes |
| `ci-marker` | this CI's clock marker, before the module is installed | before arm only |
| `LEAK` | anything else: `dns`, `tcp`, `udp`, `lan`, `icmp`, `ipv6`, `multicast`, `dhcp`, `dhcp-lease`, `dhcp-hostname`, `armed`, `fragment`, `unattributed`, `undecoded`, `other` | no |

DirPorts are never allowed: tor clients fetch directory documents over the
ORPort (BEGIN_DIR). TCP to a relay's or an authority's DirPort is a LEAK
whose label names the relay.

**Which frames are the phone's** (`--network emulator`, the default). On
the emulator's virtual Ethernet there are only two kinds of station: QEMU's
user-mode network (slirp) and the phone. The analyser fails closed: a frame
is the emulator's own (counted, not listed) only when its source MAC is
exactly one of slirp's (`52:55:0a:00:02:0X` for its hosts 10.0.2.X,
`52:56:00:00:00:02` and `:03` for `fec0::2` and `fec0::3`; a random Wi-Fi
address can begin with 52:55 too), it is not addressed to one of those
MACs, and it is an ARP frame from a slirp address, or an IP packet from an
address that is not the phone's to the phone (one of its addresses, a
broadcast or multicast group, a DHCP answer from port 67 to 68, or another
address of slirp's network that is not one of slirp's hosts, which cannot
leave the emulator). Every other frame is the phone's and is judged,
whatever its source address and whichever interface sent it. A frame the
phone sent from an address that is not one of its own is a LEAK
(`unattributed`). The phone's own packets to slirp's hosts are judged: a
lookup sent to 10.0.2.3 is the phone's DNS leaving outside Tor (on a phone,
the Wi-Fi router's resolver); TCP to 10.0.2.2 reaches the machine that runs
the emulator (on a phone, the local network). In the baseline these are
listed as what they would be. A capture made on a real network (on the
phone, or on a hotspot) is attributed by address instead, with
`--network lan`: a frame is the phone's when the capture marks it outgoing,
when it comes from one of the phone's MAC addresses or when its source is
one of the phone's addresses; other stations' frames are not counted.

The phone's addresses are those seen acting as a client (TCP SYN, queries to
low UDP ports, ARP requests, echo requests, IPv6 solicitations, DHCP) from a
MAC address that is not slirp's, in private, link-local or site-local
ranges; `--guest` overrides. With `--expect-guest` (the device's
`ip -4 addr` at the end), every address the device had must appear as a
sender in the capture, or the capture missed an interface: `blind`.

**The arm cutoff.** Capture time stamps come from the emulator, events from
the CI host. The clock marker (one UDP datagram `ANTUMBRA-CLOCK <nonce>` to
10.0.2.2:9, sent before the module is installed, between two host time
stamps) gives the offset between the two clocks. The cutoff is the host
time of `install_start`, which is taken before `build-module.sh` starts and
so before `antumbra-fw arm` runs, moved to the capture's clock with the
lower bound of the offset, minus 1 s (3 s without a marker). Every packet
from the cutoff on counts. The cutoff can only be early, never late.
`--judge-from-start` judges every packet instead (a capture on the phone,
which has neither marker nor arm event).

**The armed window** (`--armed-window armed_probe_start:armed_probe_end`).
Moved inward by the clock's uncertainty plus 0.5 s at each end (3 s without
a marker), so that it never takes in a packet sent before the flush or
after the rule set was loaded again. Every packet from the phone in it,
other than ARP and DHCP, is a LEAK (`armed`), Tor traffic included. With
`--require-armed-window`, a window that is missing or shorter than 5 s
makes the verdict `blind`.

**DHCP lease memory.** After arm, a DHCP REQUEST that asks for an address
the phone held before arm (option 50 without a server identifier, the
INIT-REBOOT that Android's lease memory sends; or a renewal with that
address in `ciaddr`) is a LEAK (`dhcp-lease`): the new session would
announce the previous one's lease. A REQUEST answering the server's offer
(with its identifier) is not.

**DHCP host name.** After arm, a DHCP client message that carries a host
name (option 12) is a LEAK (`dhcp-hostname`): Android 15 and later send the
device's name on every Wi-Fi network unless a device owner restricts it,
which Welcome does (`setSendDhcpHostnameRestriction`). Before arm it is
listed, not judged.

**Names and destinations through Tor.** A capture cannot see what goes
through Tor. `--tor-streams` (tor's STREAM events: every name tor resolved
for the DNS filter, every destination asked of the TransPort, with its
outcome; tor's own directory streams left out) and `--filter-log` (the
filter's `-debug-log-queries` log: every name and the filter's answer) give
the list, compared with `expected-destinations.txt` (the CI's own test
names and probe targets). In `learning` mode (`ANTUMBRA_CI_DESTINATIONS`,
the default while the list is learned from the first runs) a name or
destination that is not expected is listed in `leak-report.md` and in the
summary's warnings; in `strict` mode it fails the run, and STREAM events
that were not recorded make it `blind`. Names the filter blocked are listed
but never "reached".

**Verdicts.** ANTUMBRA passes only when, after the cutoff, there is no LEAK,
there is Tor traffic, the consensus was read, every connection tor reported
in `/proc/net/tcp` is in the capture, every address the device had is a
sender in it, the armed window ran and stayed clean, and the capture is
whole: a capture file cut in the middle of a frame, or whose last frame lies
more than 120 s before `capture_stop` (`--max-tail-gap`), makes it `blind`.
BASELINE is `info`, and fails only if the capture shows nothing from the
phone (`blind`) or cannot be read (`error`). `summary.py --verdict` writes
`verdict.json` (fails when either scenario did not run to the end, a check
failed, or the leak test did not pass); the workflow writes it before the
artifact is uploaded and fails the job afterwards with `summary.py --check`.

### What it cannot see

- Only the emulator's virtual network is captured. Hardware paths of the
  phone (Wi-Fi keep-alive offload, the modem, Qualcomm's IPA) do not exist
  here; the capture on the phone in January covers them. The module's
  keep-alive overlay has no effect in CI either: without Magisk nothing
  mounts it.
- A capture cannot tell which app sent a packet: a connection to a Tor
  relay's ORPort counts as Tor even if another app made it.
- What goes through Tor is not in the capture; tor's STREAM events and the
  filter's query log list it (see above), the emulator only.
- The emulator runs Android 16 QPR0 (and, not blocking, QPR2 with Google
  services) on a 6.x kernel, not LineageOS 23.2 on the phone's 4.14
  kernel, and is rooted with `adb root`, not Magisk: the module is started
  by hand after boot.
- Not covered yet (`docs/queue.md`): a reboot with the module (a
  Magisk-rooted emulator, Magisk's `avd.sh` on a `google_apis` image, for
  the true boot path), Magisk's Safe Mode and a start without the module,
  tor or the DNS filter killed during a session (fail closed; covered on
  Linux by `module-e2e`), a network change, IPv6 router advertisements,
  DHCP renewal over a long session, and the keep-alive offload check.

## Running the pieces by hand

```sh
# Unit tests of the CI tools (synthetic captures, no emulator)
python3 -B -m unittest discover -s antumbra/android/ci/tests -v

# The leak analysis of a capture made on a real network (for example on the
# phone, with tcpdump on wlan0, or on a hotspot): every packet is judged,
# from the start of the capture, by address
python3 -B antumbra/android/ci/leak_analyser.py analyse --scenario phone \
    --network lan --judge-from-start --require-tor-traffic \
    --pcap phone.pcap --consensus cached-microdesc-consensus \
    --tor-binary MODULE/bin/arm64-v8a/tor [--bridges bridges.txt] \
    --guest 192.168.1.23 --out phone.json
python3 -B antumbra/android/ci/leak_analyser.py report --in phone.json \
    --json leak-report.json --md leak-report.md
# Only the verdict "pass" (exit 0) means no leak was seen.

# A scenario against a running emulator (adb root works on 'default' and
# 'google_apis' images)
export ANTUMBRA_CI_OUT=/tmp/report ANTUMBRA_MODULE_ZIP=antumbra-module.zip \
    ANTUMBRA_WELCOME_APK=app-debug.apk
bash antumbra/android/ci/emulator-antumbra.sh
```

| File | What it is |
|---|---|
| `emulator-baseline.sh`, `emulator-antumbra.sh` | the two scenarios |
| `lib/common.sh` | adb, uiautomator, events, checks, screenshots, logs |
| `lib/tor-streams.sh` | runs on the device as uid 2950: records tor's STREAM events |
| `analyse.sh` | runs the analyser on both captures after the emulator exits |
| `pcapread.py` | the capture reader and decoder |
| `leak_analyser.py` | classification, verdicts, reports; also `tor-conns`, `listeners` and `slim` |
| `expected-destinations.txt` | the names and destinations expected through Tor |
| `citool.py` | uiautomator search, DNS over TCP, JSON lookups, the artifact size limit |
| `summary.py` | the job summary, `verdict.json` and the final verdict |
| `sdk-install.sh` | the pinned NDK, platform 36 and build tools 36.0.0 |
| `tests/test_ci.py` | unit tests with generated captures |

## Contracts with the other parts

- **Welcome:** the debug build honours `debug.antumbra.keep_adb=1` (set
  before `dpm set-device-owner`) by leaving USB debugging on; the test tags
  `tor_direct`, `switch_mac`, `switch_admin`, `switch_unsafe_browser`,
  `start_button`, `status_title`, `row_firewall`; the provider row's
  `started`, `tor_mode` and `admin`; `welcome/ci/welcome-adb.sh -s SERIAL
  check-policies --keep-adb` and `check-addon`. After Start with the add-on
  present, Welcome switches Wi-Fi on and unlocks it.
- **Module:** `build-module.sh --emulator --zip FILE --serial S
  --no-overlay`; `antumbra.fw.armed` = the first 16 hex digits of
  `antumbra-fw status`'s `hash=`; the firewall directory
  `/data/adb/antumbra/state/module/fw`; `service.sh` runs as
  `sh /data/adb/modules/antumbra/service.sh` and, every 30 s, loads the
  full rule set again when the firewall is no longer live; `bin/antumbra-run`;
  `run/tor-control.sock` and `run/tor-control.authcookie`; and, on the
  emulator only, the DNS filter started with `-debug-log-queries` when
  `getprop debug.antumbra.log_queries` is `1`.
- **DNS filter:** `-debug-log-queries` lines `query "NAME." TYPE -> DECISION`
  after `debug mode: query names will be logged`.
