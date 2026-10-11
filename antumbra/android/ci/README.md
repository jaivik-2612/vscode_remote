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
  - `baseline/` and `antumbra/`: `events.tsv`, `checks.tsv`, `analysis.json`,
    `guest-links.txt` (the guest's `ip -o link` and `ip -o addr`, which
    name the interfaces of the capture inside the guest);
    for ANTUMBRA also `tracker-test.json`, `probes-live.tsv`,
    `filter-status.json` (the DNS filter's `/status`, which includes the
    module's `status.json`), `bootstrap-progress.tsv`, `provider-row.txt`,
    `tor-connections.txt`, `tor-streams.txt` (tor's STREAM events),
    `dnsfilter.log` (the filter's log with every query; dropped first if
    the artifact is too large), `device-ipv4.txt`, `disable-ipv6.txt`,
    `consensus.gz`
  - `capture/`: per scenario the emulator's capture of eth0
    (`<scenario>.pcap`) and the capture inside the guest of every
    interface (`<scenario>-guest.pcap`, Linux cooked v2), each also cut to
    256 bytes per frame (`*.slim.pcap`); the full captures are dropped
    first when the artifact would be too large (the list is in
    `omitted.txt`)
  - `logs/`: filtered logcat, `tor.log`, the module's, firewall's and
    filter's logs, `build-module.sh`'s output, the firewall's state
    (`iptables-save`) and the armed phase, Wi-Fi, Welcome's policy checks,
    process capabilities, IPv6 addresses, the mount tables of
    system_server and NetworkStack, device facts (emulator version and
    system image revision), tcpdump's own output in the guest
    (`<scenario>-guest-capture.txt`), and, at the end of ANTUMBRA,
    `antumbra-netfilter-counters.txt`: `iptables-save -c` and
    `ip6tables-save -c` (every rule's packet and byte counters: which drop
    rules were hit), `/proc/net/stat/nf_conntrack`, and `nstat -asz` (or
    `/proc/net/netstat`) with `/proc/net/snmp`
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
every frame of the emulator's first network card (the guest's `eth0`, the
emulated radio) from the first moment of boot. That is not every path out
of the phone: Wi-Fi (`wlan0`) leaves another way, and run 4 saw none of
it (`wlan0` 10.0.2.16 never sending, none of tor's five connections). So
each scenario also runs tcpdump inside the guest, as root (`adb root`;
found with `command -v tcpdump`: userdebug builds normally carry
`/system/bin/tcpdump`):

    tcpdump -i any -y LINUX_SLL2 -n -s 0 -U -B 4096 -w /data/local/tmp/antumbra-ci-guest.pcap

`-i any` takes in every interface, also those that appear later (`wlan0`
is created after boot and again when Wi-Fi is switched on); Linux cooked
v2 headers carry each frame's direction and interface index (a tcpdump
without them falls back to v1, and the analyser names the interface by
its hardware or IP address instead). A frame leaving an interface is
recorded on its way to the driver, after netfilter: what the guest
capture shows leaving is what left the phone, packet sockets included
(DHCP). It is started (`setsid`, so that it outlives the adb shell and
adbd's restarts) before the clock marker, so before the module is
installed, and stopped at the very end with SIGTERM, on which tcpdump
writes its counters into `logs/<scenario>-guest-capture.txt`; the event
`guest_capture_stop` carries them (`captured=`, `received=`,
`dropped=`), and the file is pulled into `capture/<scenario>-guest.pcap`.
The guest's interfaces (`ip -o link`, `ip -o addr`) are recorded when it
starts, after Wi-Fi is joined and at the end. The emulator's capture stays
as a second, independent view of `eth0`. An image without tcpdump (a
`user` build) would need a static x86_64 tcpdump pushed to
`/data/local/tmp`; ANTUMBRA fails its `guest_capture` check without one,
and the analyser goes blind on `wlan0`. `-feature -WiFiPacketStream`
keeps the emulator's Wi-Fi off netsim.

### BASELINE (`emulator-baseline.sh`)

Plain Android, nothing installed. `adb root` and the capture inside the
guest (a warning if it cannot start), a clock marker, three minutes
alone, a screenshot of the home screen, the open connections and the
logs, then both captures are stopped. The report lists every destination,
Wi-Fi's included, and says how Antumbra would judge it. Not judged, except
that the captures must show traffic from the phone.

### ANTUMBRA (`emulator-antumbra.sh`)

1. `adb root`, device facts, Wi-Fi's hardware address, the capture inside
   the guest (the check `guest_capture` fails without it), a clock marker.
2. Airplane mode on until Android has no network.
3. `setprop debug.antumbra.log_queries 1` (the module then starts the DNS
   filter with `-debug-log-queries`, on the emulator only), event
   `install_start`, then `module/build-module.sh --emulator --zip` with the
   module zip the `module` job built, as it is (`--no-overlay`: the
   keep-alive overlay needs Magisk to be mounted). It installs the module,
   restarts the framework around `post-fs-data.sh` (`antumbra-fw arm`
   first), starts `service.sh`, and waits for `antumbra.fw.armed`, which
   must equal the first 16 hex digits of `antumbra-fw status`'s `hash=`
   with the state `live`. The device's clock is read once more (event
   `device_clock`). From here tor's STREAM events are recorded
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
   network), else the check fails. The guest's interfaces are recorded
   again (`guest-links.txt`). Wi-Fi's hardware address must differ
   from the one before the module (a warning). Welcome's own checks through
   `welcome/ci/welcome-adb.sh`: `check-policies --keep-adb` (the
   device-owner restrictions of a default session) and `check-addon` (the
   status screen shows the firewall live).
8. Wait (15 minutes at most) for `module.tor.bootstrap` = 100 in the
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
    addresses (`ip -4 addr`) go to the analyser. For diagnosis (not
    judged): `logs/antumbra-netfilter-counters.txt`, every firewall rule's
    counters and the kernel's network counters at the end. Then the
    capture inside the guest is stopped and pulled (`guest_capture_pulled`
    checks its size), and the emulator's capture is stopped (the event
    `capture_stop` says whether the console confirmed).

Steps 2 and 4 are not in the plain install procedure. They stop plain
Android's own traffic before the firewall is armed, so that nothing is in
flight at the cutoff, and they bring the network up behind the firewall, as
on the phone, where `post-fs-data.sh` arms it before any network exists.
Step 11 stands in for the boot path, where the armed set meets the network
before `service.sh` loads the full set; the emulator's module is started by
hand after boot, so that path itself is not what runs here.

## The leak analyser

`leak_analyser.py analyse` reads the captures with `pcapread.py` (pcap and
pcapng; Ethernet, raw IP, Linux cooked v1 and v2, 802.11 and radiotap;
standard library only) and classifies every packet the phone sent:

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

**Two views.** `--pcap` is the emulator's capture of `eth0`
(`--pcap-iface eth0`); `--guest-pcap` the capture inside the guest, whose
Linux cooked headers say which frames the phone sent. Its frames on
loopback are left out (they never leave the phone); every other frame is
named with its interface, by the index in its header, else by its hardware
or IP address, from `--guest-links`. Both views are judged: a LEAK in
either fails the run. Each flow says which views saw it ("Seen on" in the
report: `wlan0 (guest 3)`, `eth0 (emulator 2, guest 2)`); in totals a
packet that two captures of one interface saw counts once (each interface
counts with its larger view).

The phone's addresses are those seen acting as a client (TCP SYN, queries to
low UDP ports, ARP requests, echo requests, IPv6 solicitations, DHCP) from a
MAC address that is not slirp's, in private, link-local or site-local
ranges; `--guest` overrides. With `--expect-guest` (the device's
`ip -4 addr` at the end), every address the device had must appear as a
sender on its own interface (or one the capture could not name), or the
captures missed an interface: `blind`.

**Clocks and the arm cutoff.** Events come from the CI host; each capture
has its own clock: the emulator's (in run 4, 0.84 s or more behind the
host's), and the device's for the capture inside the guest. The clock
marker is sent before the module is installed, by one
adb call between two host time stamps (events `clock_marker_before` and
`clock_marker_after`, a second or two apart): an ICMP echo request to
10.0.2.2 from each interface with an IPv4 address (`ping -I IFACE -p
414e54554d425241<nonce>`: its data holds `ANTUMBRA` and the nonce), and a
UDP datagram `ANTUMBRA-CLOCK <nonce>` to 10.0.2.2:9 by the default route.
Each command has a time limit. Run 4's marker used `toybox nc -u -w 1`,
which never exits after the end of its input (`-w` only limits the
connect, and without `-q` it waits for the socket forever): `adb shell`'s
60 s time-out killed it, the fallback ran the same command for another
60 s, and the two stamps were 120 s apart. The cutoff then lay two minutes
early, so mDNS sent a minute before `install_start` was judged after arm,
and the armed window came out negative. In each capture, every marker the
phone sent bounds that capture's offset to the host (several markers:
their bounds intersect; bounds that do not meet make the verdict
`blind`); the analyser counts only what the phone sent, since slirp's echo
reply may come after the second stamp. The cutoff is the host time of
`post_fs_data_start`, which `build-module.sh --emulator` records just
before the step that runs `post-fs-data.sh` (whose first act is
`antumbra-fw arm`), or of the earlier `install_start` when that event is
missing, moved to each capture's clock with the lower bound of its offset,
minus 1 s (3 s without a marker). Run 5 used `install_start`, taken
before the module's files were pushed: an IPv6 router solicitation sent
on `dummy0` half a second after it, while the files were still being
pushed, was judged after arm. Every packet
from the cutoff on counts. The cutoff can only be early, never late.
`--judge-from-start` judges every packet instead (a capture on the phone,
which has neither marker nor arm event).

The capture inside the guest must hold a marker: it shows the capture ran
from before the module was installed, and places its clock. The device's
clock is read again between two host stamps after the module is live and
at the end (events `device_clock`); a reading more than 0.5 s outside the
marker's bounds means the device's clock moved (Android may set it), and
the guest capture's times cannot be trusted: `blind`.

The module's own log line `post-fs-data: firewall armed` (`--module-log`)
is placed on the time line by the device's clock, and must not lie before
the arm event (else the device's clock moved: `blind` when the guest
capture depends on it, a note otherwise). It is not the cutoff: it is
written after `antumbra-fw arm` and after the runtime directory is set
up, to the second, by the device's clock, so it bounds the arm only from
above. The arm event bounds it from below by construction, and with a
bracket of a second or two the cutoff lies only a few seconds before the
real arm (run 4, replayed with such a bracket: 4.6 s or more before the
module's line).

**The armed window** (`--armed-window armed_probe_start:armed_probe_end`).
In each capture, moved inward by its clock's uncertainty plus 0.5 s at each
end (3 s without a marker), so that it never takes in a packet sent before
the flush or after the rule set was loaded again. Every packet from the phone in it,
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
in `/proc/net/tcp` is in the captures, every address the device had is a
sender in them on its own interface, the armed window ran and stayed clean
in every capture, and the captures are whole: a capture file cut in the
middle of a frame, or whose last frame lies more than 120 s before
`capture_stop` (`guest_capture_stop` for the one inside the guest;
`--max-tail-gap`), makes it `blind`, and so do, for the capture inside the
guest, no clock marker, no counters from tcpdump when it was stopped, any
packet tcpdump dropped, or the device's clock moving.
BASELINE is `info`, and fails only if the capture shows nothing from the
phone (`blind`) or cannot be read (`error`). `summary.py --verdict` writes
`verdict.json` (fails when either scenario did not run to the end, a check
failed, or the leak test did not pass); the workflow writes it before the
artifact is uploaded and fails the job afterwards with `summary.py --check`.

### What it cannot see

- The captures see what the guest's kernel sends: the emulator's capture
  of `eth0`, and tcpdump inside the guest on every interface after
  netfilter. Hardware paths of the phone (Wi-Fi keep-alive offload, the
  modem, Qualcomm's IPA) do not exist here; the capture on the phone in
  January covers them. The module's
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
| `lib/common.sh` | adb, uiautomator, events, checks, screenshots, logs; the clock marker, the device's clock, the capture inside the guest |
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
