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
| `app-lab` | ubuntu-24.04 with KVM | the app lab (below): real app stores and apps on a virtual phone with more memory, under Antumbra, through Tor; what each did, and the leak analysis of the whole run; `continue-on-error`, never blocking |

`module` needs `firewall`, `dnsfilter`, `tor` and `welcome`; `module-e2e`
needs `dnsfilter` and `tor`; `emulator` needs the first five; `app-lab`
needs `module` and `welcome`.

Antumbra Live (`.github/workflows/antumbra-live.yml`) is a workflow of its
own, started by hand: the virtual phone in a web page, for the owner to use
(see "Antumbra Live: a virtual phone you can use").

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
    `-welcome-emergency-dialer.png`, `-welcome-power-menu.png`,
    `-welcome-2-choices.png`,
    `-status-1-started.png`, `-status-2-bootstrapped.png`,
    `-status-3-after-tracker-test.png` (`-final.png` after a failure)
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
- `antumbra-android-apps-<run number>` (14 days, kept under 60 MB): the app
  lab's `apps.json` and `apps.md`, `screenshots/` (JPEGs 540 pixels wide:
  `store-<name>`, `app-<package>`, `apps-home`, `apps-drawer` and the
  session's screens), `apps/` (the scenario's events, checks, records,
  downloads, tor's STREAM events, the filter's log, `analysis.json`),
  `logs/apps/` (each item's install output, logcat and screen),
  `leak-report.md` and `.json`, `capture/` (see "The app lab").
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
   (Wi-Fi's store is on an empty tmpfs). Airplane mode off switches the
   emulated radio on; the module (its cell radio's watch, MOD6) stores
   mobile data off again, narrows airplane mode's radio list to the cell
   radio 30 seconds later, and about 5 minutes after this step switches
   the emulated radio off with airplane mode, which Wi-Fi then does not
   follow (`module/README.md`, "The cell radio"). The run's session
   switches it on again at Start (Phone: calls and texts, step 6).
5. The Welcome APK; the debug build's test hook
   `setprop debug.antumbra.keep_adb 1` (honoured only by debuggable or
   testOnly builds; Welcome then leaves USB debugging on; `welcome/README.md`,
   "Test hook"); `dpm set-device-owner`; Welcome as the home app;
   screenshots.
6. Emergency calls before Start (WEL7), check `welcome_emergency_dialer`:
   `welcome/ci/welcome-adb.sh check-emergency` opens the emergency dialer
   from Welcome's lock task, with Welcome's Emergency call button and with
   `am start` in a task of its own (as the power menu does), checks in
   `dumpsys activity activities` that the dialer is in front, presses Back
   and checks that Welcome is in front again and its lock task still
   `LOCKED`. It never dials: it touches nothing in the dialer and requires
   an idle call state before and after each opening (a dump without a call
   state fails the check). When it fails, the run starts WelcomeActivity
   again (singleTask: its locked task comes to the front) and goes on;
   `welcome_emergency_recover` warns if Welcome did not come back.
   Then the power menu's Emergency item in the lock task (WEL12), check
   `welcome_power_menu_emergency`: `welcome-adb.sh check-power-menu` reads
   that Android's emergency affordance is off (`force_emergency_affordance`
   and `emergency_affordance_needed` unset or 0, before and after), so that
   the menu's Emergency item is the one that opens the emergency dial pad,
   not the one that calls at once (both are labelled "Emergency", and
   `uiautomator dump` cannot tell them apart); it refuses otherwise. It
   opens the power menu with a long press on power
   (`power_button_long_press=1` meanwhile: AOSP's default long press starts
   the assistant), checks in `uiautomator dump` that SystemUI's menu (its
   "Power off" or "Restart") shows "Emergency", closes the menu with Back
   (then the screen off and on if it is still open), and checks that
   Welcome is in front and still locked. **Presence only**: it changes no
   emergency setting, registers no test number and never presses the item.
   The menu is closed and the long-press setting put back, also after a
   failure, when the run calls `clear-power-menu-test` again and brings
   Welcome back (`welcome_power_menu_recover`). A warning, not a failure,
   until it has passed on CI once.
   Then WEL8's two choices at Start, walked at each level of the
   Phone-mode gate: the run writes the root-only file
   `/data/adb/antumbra-cell` as root (`cell_gate`: removed for `off`;
   `phone`, then `data`, written whole, root's, 0600), exactly as the
   install's PH3 step writes it on the phone (there is no build flag or
   test hook: the module zip and the APK are a release's), waits until
   Welcome shows the row the gate opens (or keeps closed) enabled as it
   should, and runs `welcome-adb.sh check-choices --gate off|phone|data`:
   the six attempts (Internet Wi-Fi, mobile data, None; Phone off, calls
   and texts; mobile data straight after Phone off, so that it is seen to
   select calls and texts), each tapped by its test tag as a person would,
   from the top of the page, then the whole page read with slow scrolls (a
   row or card counts only from a dump that shows it whole: Compose lists
   only the on-screen texts of a card cut off by an edge, so one cut off on
   every page is scrolled wholly into view and read again; which rows are
   checked, which disabled with their reason, Tor's rows only with
   Internet, the carrier card with its key statements, the radio line
   against the registry, the SIM line against `gsm.sim.state`, no
   "offline" anywhere),
   checks `welcome_choices_gate_off`, `_phone` and `_data`, and
   `welcome_radio_line` from what the walk read; a screenshot per gate and
   one per attempt at `data` (`screenshots/antumbra-choices/`, in the
   artifact, not on the Daily page). The walk is bounded (7 minutes a
   gate, no gate begun after 15 minutes; a gate cut short is a warning),
   so that a slow screen cannot make the step run out of time. Nothing is
   dialled, and no emergency number is set. Then the choices for the run,
   with the gate at `phone` (as the install leaves it after PH3's outcome
   A), whatever the walk left selected: each row by its test tag alone
   (`ui_choose`: never by its text, which another row's detail may hold:
   "Wi-Fi" is also in None's), from the top of the page, and read back
   checked, with a second try: Internet Wi-Fi and Tor directly (the run
   stops if either cannot be chosen), **Phone: calls and texts**
   (`welcome_phone_start`; Phone off if Welcome does not offer it within
   60 s or the row does not read checked, a warning, so the leak test never
   stops for a WEL8 check; if the row after Start says otherwise, the
   checks after Start follow the row), new Wi-Fi address, **Administration off**
   (the default session a user gets), Unsafe Browser off; then "Start
   Antumbra". adb must still answer; the provider row must say
   `started=1`, `tor_mode=direct` and `admin=0`, and `provider_cell` its
   `cell`. The leak test then judges the setup the owner uses daily: the
   emulated radio on for the whole session, mobile data off.
7. Wi-Fi joined as a person would (`cmd wifi connect-network AndroidWifi
   open`, once Welcome has switched Wi-Fi on); Wi-Fi must become the
   default network (the `Transports:` of `dumpsys connectivity`'s default
   network), else the check fails. The guest's interfaces are recorded
   again (`guest-links.txt`). Wi-Fi's hardware address must differ
   from the one before the module (a warning). Welcome's own checks through
   `welcome/ci/welcome-adb.sh`: `check-policies --keep-adb` (the
   device-owner restrictions of a default session) and `check-addon` (the
   status screen shows the firewall live). Then MOD11: `welcome_module_word`
   (a failure since it passed in run 20; `welcome-adb.sh
   check-module-word`: the module's word given as the shell user, uid 2000
   through `su`, is refused with a `SecurityException`, a malformed one
   from root refused, a `none` from root taken; nothing that could let
   Quick power off skip a wait is sent) and `module_parsers` (the module's
   `telecom_state`, `registry_state` and `ims_state`, run as root on the
   device against the emulator's own dumps, taken with the module's
   `cell_dump` and `ims_dump`, and its `phone_proc`, which finds the phone
   process by name; only their output, numbers and words, is kept in
   `module-parsers.txt`). `module_parsers_level` compares that output with
   what the emulator should show, and `tests/test_ci.py` checks it: a
   failure unless it begins with exactly `telecom=0 0 - - 0; registry=0 0
   on|off; ims=cell|wifi|registered|none`, with nothing before it (run 20
   had dumpsys's "Broken pipe" line there; run 21, af748d0, printed exactly
   `telecom=0 0 - - 0; registry=0 0 on; ims=none`); then a warning unless
   the rest is exactly `; phone=yes`, until the phone part has passed on CI
   once (then that fails too). Then WEL8 after Start: `cell_phone_mode`
   (as root: the session record says `cell=phone gate=phone`, the module's
   log has its Phone-mode switch-on, the registry reads the radio on, and
   no `mobile_data` key is 1), `welcome_phone_status` (`welcome-adb.sh
   check-phone`: the status screen's Internet, Tor and Phone lines, the
   Phone card's SIM, radio and VoLTE lines, the carrier card for the radio
   read, no "offline" while the radio is on or not known; screenshot
   `status-phone`), then `welcome_module_cell` (`check-module-cell`: the
   word on the cell radio refused from the shell user and malformed from
   root, the most careful word taken from root; the module's next word
   replaces it). Every WEL8 check is a warning until it has passed on CI
   once (`choices_level`, which `tests/test_ci.py` checks), so the job
   cannot go red from a new step alone; the status screens of the other
   four sessions, a PIN- or PUK-locked SIM, two slots and IMS registration
   are the JVM tests' (one Start per boot, and the emulated SIM is
   unlocked and reports no IMS).
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
| `link-empty` | an empty frame: a link-layer header and nothing after it, complete in the capture, sent from a packet socket outside the firewall; it carries no data (run 6: one IPv4 frame of zero bytes on wlan0 while the firewall was armed). A frame the capture cut off is not empty; one byte after the header is a LEAK | yes |
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

A long silence at the end of the emulator's capture (more than `--max-tail-gap`, 120 s) means an unflushed file or a quiet interface. Run 7's eth0 sent nothing for five minutes once Wi-Fi carried everything. The capture inside the guest sees eth0 too: when it is whole (its own marker, tcpdump's counters with nothing dropped, no problem of its own, stopped within 15 s before the emulator's) and saw nothing on eth0 after the emulator's last frame (with a second of slack for the two clocks), the silence is a note; otherwise the verdict is `blind`.

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

## The app lab

`app-lab` answers two questions with real apps: can a person install and
use apps on Antumbra, through Tor, and does anything get past the firewall
while they run? The CI's virtual phone runs them on every build, and the
artifact shows what happened, screen by screen (to use the phone by hand,
see Antumbra Live below). It never blocks the workflow
(`continue-on-error`), and nothing it finds fails a run.

**The phone.** The emulator job's image (Android 16, `android-36;default`,
x86_64, no Google services), with more room for apps: `ram-size: 6144M`
(the runner has 16 GB) and `disk-size: 12G`, inputs of the pinned
`android-emulator-runner` v2.38.0. The Java heap stays the `pixel_6`
profile's 576 MB (`dalvik.vm.heapsize`): the action's `heap-size` input
writes `hw.heapSize`, which the emulator ignores (its key is
`vm.heapSize`, in the AVD's `config.ini`). The emulator captures eth0 as
in the emulator job (`-tcpdump`, `capture/apps.pcap`).

**Time.** Typically about 35 minutes, in parallel with the emulator job.
The job has 60; its steps' limits (build tools 5, downloads 8, the
emulator 36, the analysis 5, `apps.json` 2) and about 2 minutes for the
rest fit inside, so a slow run ends with a failed step and still uploads
its artifact.

**Downloads, on the runner.** `applab.py fetch` runs before the emulator
starts, 7 minutes at most (`--budget 420`: no download runs past it, and
what is left then is recorded as not downloaded): every APK comes from its
store's official source over HTTPS (curl, HTTPS only, redirects kept on
HTTPS; a connection that fails or breaks off, or an HTTP 408, 429 or 5xx,
is tried up to three times; a source slower than 50 KB/s for a minute, or
out of time, is given up at once for the next URL, an F-Droid mirror where
the index lists one), and is checked before it goes near the phone. Every
APK must verify with `apksigner` and be the package it claims to be
(`aapt2 dump badging`); `fetch` needs both programs, and an APK they did
not check is never verified. An item that fails any check is recorded
with the reason and never installed.

| Store | Its client | Apps from it | Checks |
|---|---|---|---|
| F-Droid | `f-droid.org/F-Droid.apk`, the file F-Droid's website hands out | `index-v2.json` from `f-droid.org/repo`: the version the client would suggest (the newest without a release channel, signed by the package's preferred signer, built for x86_64, for SDK 36); an HTTPS mirror from the index when f-droid.org fails or crawls | the index's SHA-256 is the one `entry.json` lists; each APK's SHA-256 is the index's, and its certificate one the index lists for that version; the client's SHA-256 is one the index lists for `org.fdroid.fdroid`, and its certificate F-Droid's own, pinned in `applab.py` (`43238d51…`) |
| Aptoide | `cm.aptoide.pt` from Aptoide's own store `aptoide-web` (its website's) | Aptoide's web service, `ws75.aptoide.com/api/7/app/getMeta`: Aptoide's pick of the newest version | Aptoide's rank must be `TRUSTED` (the certificate is the one it knows for the developer); size and MD5 as listed; the certificate's SHA-1 as listed, among the certificates apksigner reports (a key rotated with APK Signature Scheme v3, as WhatsApp's, counts with its lineage). Aptoide publishes no checksum: SHA-256 and certificates are recorded. Split-only apps are skipped; an app that wants an OBB file is noted |
| TapTap | the international client from `d.tap.io/latest`, the link of `taptap.io/download` | none | no published checksum: SHA-256 and certificates recorded; the certificate is compared with what Aptoide lists for `com.taptap.global` (noted, not required) |

The apps are in `app-lab.txt` (`STORE<TAB>PACKAGE<TAB>LABEL`, `#` for
comments): five well-known apps from F-Droid (NewPipe, Organic Maps,
AntennaPod, Thunderbird, Element X) and five from Aptoide (WhatsApp,
Spotify, Instagram, Discord, Zoom), taking turns. Instagram is built for
arm64-v8a only and installs only if the image translates ARM code.
`downloads.json` records, per item, the URL it came from, version, size,
SHA-256, MD5, what it was checked against and how, every check with its
result, the certificates, and why an item was not verified.

**The session** (`emulator-apps.sh`; the ANTUMBRA scenario's functions,
shared in `lib/common.sh`): `adb root`, tcpdump inside the guest (with a
16 MB buffer), the clock marker, airplane mode, the module installed with
`build-module.sh --emulator` and the filter's query log, tor's STREAM
events recorded, mobile data off, Welcome as device owner, then Start with
Tor directly, a new Wi-Fi address and **Administration on**: without it
Welcome keeps `DISALLOW_INSTALL_UNKNOWN_SOURCES_GLOBALLY`, and Android
refuses every install but the preinstalled store's. The provider row must
say `admin=1`; `welcome-adb.sh check-policies --admin --keep-adb` checks
that session's restrictions. Wi-Fi joined, tor's bootstrap (10 minutes at
most), then the home screen (`apps-home`). The firewall and the filter
are a normal session's: no app is exempted, and everything an app sends
goes through Tor or is refused.

**Each store, then each app**, in a window of its own: `adb install`
(three minutes at most; the output kept), its launcher activity started
(`am start -W`, else `monkey` with the LAUNCHER category), then

- a store: up to 90 s for its catalogue: the screen shows one (twelve or
  more distinct texts, no network error) and tor connected the phone since
  the window began (a TransPort stream that its exit's CONNECTED cell
  remapped, `REMAP ... SOURCE=EXIT`: tor sends `SUCCEEDED` only to SOCKS
  clients, never for TransPort or DNSPort streams). A button that only dismisses a first-run screen (Skip,
  Not now, Don't allow; four at most) is pressed; never one that signs in,
  agrees, allows or continues;
- an app: 45 s, and nothing on screen is touched;

then a screenshot once the item's window has the input focus (10 s at
most, else of whatever is in front: a permission dialog, a crash), its
screen (`uiautomator dump`), whether its process still runs (`pidof`),
`am force-stop`, and its logcat since the window began. The window
records where tor's STREAM events and the filter's query log stood at its
start and end. No item starts after 24 minutes of the script; one item
never stops the others. At the end, the app drawer (`apps-drawer`), the
ANTUMBRA scenario's evidence and checks, and both captures stopped.

**`apps.json`** (`applab.py build`; schema in its docstring) has, per item:
the download and its checks; installed, launched, running at the end,
crashed (a `FATAL EXCEPTION` in its process, a native crash), not
responding (ANR), and whether it asked for Google Play services (a logcat
line or a screen that says so: common on this image, recorded as such);
for a store, whether its catalogue loaded through Tor (its screen, its own
names forwarded and answered by tor, not `forwarded nxdomain`, and a
connection tor made) with the signals; every name the filter was asked in
the window, with its decisions (forwarded, blocked, `servfail (...)`: the
filter's own failures and tor's SERVFAIL alike); the names the filter
asked tor for (`RESOLVED`, `UNRESOLVED` or tor's reason); the destinations
asked of tor's TransPort with tor's outcome per stream (`CONNECTED`, or
the reason: `PRIVATE_ADDR`, `TIMEOUT`, the exit's `CONNECTREFUSED` or
`EXITPOLICY`...); the screenshot. Also the
phone (ABIs, memory, free storage), the session (Tor's time, the checks)
and the leak verdict. `apps.md` is the short summary, also the job's
summary.

**The leak test.** `analyse.sh` judges the scenario `apps` with the
ANTUMBRA rules: after the arm cutoff, anything not to the Tor network
(relays, directory authorities, fallback directories) and not link-level
(ARP, DHCP, empty frames) is a LEAK, in either capture. There is no armed
window. Every name and destination through Tor is listed against
`expected-destinations.txt` in `learning` mode: real apps reach names no
list expects. Real apps are a stress test of the firewall; the verdict
goes into `apps.json` and `apps.md` and never fails the workflow.

**Never.** No number is dialled and no SMS sent; no account is signed in
to; nothing is typed into any app; no personal data is used. The
catalogue is generic.

**What it does not show.** The stores' own download and install flows are
not driven: the APKs come from the runner, from the same sources. Most
closed apps stop at a sign-in screen, and many want
Google Play services, which this image does not have (LineageOS has none
either, unless microG is added). Aptoide's pick may be an older version
from one of its user stores; its rank, MD5 and certificate are checked,
its age is not. ARM-only apps need the image's ARM translation (the
phone's `ro.product.cpu.abilist` is in `apps.json`). The emulator is not
the phone: no modem, no GPU drivers, and swiftshader draws the screen.

## Antumbra Live: a virtual phone you can use

Antumbra Live (`.github/workflows/antumbra-live.yml`) starts the CI's
virtual phone with Antumbra on it and shows its screen in a web page, for
as long as you ask (60 minutes by default, 180 at most). You open the page
in Safari on an iPhone or iPad, tap and type on the phone, press Start in
Welcome, and install and try apps from F-Droid and Aptoide through Tor. It
runs on GitHub's computer, only when started by hand, and ends by itself.
At the end, the phone's network traffic is checked for leaks, as in the app
lab, and the result goes into the run's summary.

It is a virtual phone on GitHub's computer, and GitHub's machine and
Cloudflare carry its screen: never sign in to real accounts on it, and never
type real passwords or personal details in it.

### For the owner, from an iPhone

**Once: the password.** The page asks for a password, which you keep in a
repository secret. Let your password manager make one (20 characters or
more; a generated one is best), or use six or more random words, and use it
nowhere else.

1. In Safari, open github.com, sign in, and open the repository.
2. Ask for the desktop site: tap the page menu button at the left of the
   address bar (**aA** on older iPhones), tap **⋯** if it is there, then
   **Request Desktop Website**. (Pressing and holding the reload arrow
   offers it too.)
3. Tap **Settings** (the repository's, at the top), then on the left
   **Secrets and variables**, then **Actions**.
4. Tap **New repository secret**. Name: `ANTUMBRA_LIVE_PASSWORD`. Secret:
   your password. Tap **Add secret**.

To change it later, open the same page and tap the pencil next to the
secret. Without the secret, or with a shorter one, Antumbra Live does not
start, and its summary says why.

**Each time: start, open, use, end.**

1. Start it with a label. In the GitHub app: the repository, **Pull
   requests**, the open pull request #8 (from the Antumbra branch), then
   **Labels** (or the gear next to Labels on the website), and tick
   **antumbra-live** for 60 minutes with the phone, or
   **antumbra-live-30**, **antumbra-live-120** or **antumbra-live-180**.
   The session starts within a minute. For another session later, remove
   the label and add it again. (Run workflow in the Actions tab is not
   offered: GitHub shows it only for workflows on the default branch,
   `main`, which is not changed. Claude can also start a session for you.)
2. Open the run: **Actions**, **Antumbra Live**, the newest run. After 5 to 10 minutes the link is there
   (`https://<four words>.trycloudflare.com`), with the time the session
   ends (UTC). Look for it in the run's **Summary** (or its annotation).
   If the Summary is still empty, tap the job **Antumbra Live (a virtual
   phone in the browser)**, then the step **The link (Cloudflare quick
   tunnel), checked, in the summary**: its last line reads
   `the link: https://….trycloudflare.com`. Tap the link: it opens in
   Safari. If the summary says the build has expired, a new Antumbra
   Android build is needed first: ask Claude for one, and start Antumbra
   Live again when it has passed.
3. On the page, type the password and tap **Open the phone**. *Remember on
   this device* keeps it in this browser for this session's page. A wrong
   password gets no connection at all. The page says when the phone is
   ready: about 10 minutes after the link appears. Until then it says that
   the phone is starting. The phone's page has **Page** (back to the first
   page) and **Keyboard** at the top.
4. On the phone you see Welcome. To install apps, turn **Administration**
   on; then tap **Start Antumbra**. The virtual Wi-Fi is joined for you.
   Wait until the status screen says Tor is connected.
5. Swipe up on the home screen for the app drawer: **F-Droid** and
   **Aptoide** should be there. If one is missing, the first page says why
   (under the phone's state). When a store installs its first app, Android
   asks you to allow installs from that store: allow it. Everything goes
   through Tor, so the stores are slower than usual.
6. Tap to tap and drag to swipe. To press and hold (an app's menu,
   selecting text, Power's menu), keep your finger still for about two
   seconds. To type, tap **Keyboard** at the top of the phone's page (the
   keys go to the phone as from a keyboard), or tap the keys of Android's
   own keyboard on the phone's screen.
7. To end early, open the link again and tap **End the session now** (type
   the password first if the page asks), or open the run in the GitHub app
   and cancel it. Otherwise it ends by itself at the time in the summary.
   A few minutes later the summary has a second part, **privacy check of
   the session**.

The buttons beside the phone (the emulator's toolbar, from the top):

| Button | What it does |
|---|---|
| Power | Tap: screen off or on. Hold (about two seconds): Android's power menu. Powering off or restarting the phone ends the session (the virtual phone has no Magisk, so Antumbra's module would not start again). |
| Volume up, volume down | The volume. |
| Camera, magnifier | A screenshot (kept on GitHub's machine, not on your device) and a zoom. |
| Rotate left, rotate right | Turns the phone. |
| Back, Home, Overview | Android's three buttons: back, the home screen, recent apps. |
| … (More) | Does nothing here: the emulator's own settings are kept closed on purpose. |

The toolbar's top row, × and –, is left out of the picture on purpose: ×
switches the virtual phone off at once, without asking, which ends the
session and loses the phone's own recording of the network.

**Limits.**

- It is an x86_64 virtual phone: apps built only for phone (ARM)
  processors do not install.
- There are no Google Play services (as on LineageOS without microG): apps
  that need them complain or stop.
- It is slower than a real phone, and its screen comes over the Internet.
- No sound and no camera: the virtual phone has neither, and the page
  carries only the screen.
- One session at a time: a second run waits until the first has ended.
- GitHub's rules allow Actions for building and testing the project, and
  this is testing Antumbra. Use it for that.
- The phone is wiped at the end; nothing is kept but the report.

### How it works

One job, on a runner with KVM:

1. **The password.** The secret must be set and 20 characters or more, or
   the run stops before any tunnel exists.
2. **The build.** The Welcome APK, tor, the DNS filter and the module zip
   of the newest *successful* run of `antumbra-android.yml` on the Antumbra
   branch (the Actions API with the job's own token, then
   `actions/download-artifact` with `run-id`; the job may only read Actions
   and the code). Only this repository's own runs count, started by a push
   or by hand, of a commit that is on the branch (the compare API): a pull
   request's run can come from a stranger's fork, with a branch of the same
   name and a workflow file of its own, and its files would go into the
   phone as device owner and as root. Those artifacts are kept 5 days: when they have expired,
   the summary says so and the run stops; nothing is rebuilt. The module's
   x86_64 tor and filter must be the build's.
3. **The stores**, on the runner: `applab.py fetch --stores fdroid,aptoide`
   with no catalogue, the app lab's own download and checks (F-Droid's
   client against F-Droid's index and its pinned certificate, Aptoide's
   against Aptoide's metadata; apksigner and aapt2 for both).
4. **The screen** (`live-stream.sh start`): Xvfb on `:99` (1440 by 1440),
   x11vnc on 127.0.0.1:5917 only, websockify on 127.0.0.1:6080 only, which
   serves the landing page (`live/index.html`), the phone's page
   (`live/phone.html`) and noVNC's `core/` (Ubuntu's `novnc` package) and
   passes a WebSocket on only with a token from its token file (TokenFile
   plugin), and an End listener on 127.0.0.1:5998. The step fails if any of
   them listens on another address. noVNC's own pages (`vnc.html` and the
   like) are not served: they take the server's host, port and path from
   their address, so a crafted link could have sent the token to another
   server. `phone.html` connects to its own host only, with the token the
   landing page left in the tab's sessionStorage, and turns a finger held
   still into a held left button (noVNC makes it a right click, which
   Android ignores). A fitter (once a second) moves the emulator's window
   to 0,24 and its toolbar 24 pixels higher, and shows only them from 24
   down (`x11vnc -R clip:`), so that the toolbar's × and – are never on
   the screen; it hides the emulator's Extended Controls (the toolbar's
   More opens them at 0,0, over everything, and with no window manager
   they could not be closed). After a rotation the emulator puts the
   toolbar back beside the phone, and the fitter moves it up again within
   about two seconds.
5. **The link** (`live-stream.sh tunnel`): `cloudflared tunnel --url
   http://127.0.0.1:6080`, version 2026.9.3, its SHA-256 checked, no
   account. Then the token file: the screen's token and the End token are
   PBKDF2-HMAC-SHA-256 of the password (NFC, without spaces at either end),
   600,000 rounds, with the salt `antumbra-live` or `antumbra-live-end`, a
   line break and the tunnel's host name. The page computes the same in the
   browser, so the password itself never leaves it, the tokens are good for
   this session's host name only, and a token seen on the way (Cloudflare
   carries it) is slow to guess the password from. Then the check, through
   the tunnel (at the address Cloudflare's resolver gave): a file with a
   random word, put in the web root for the check, must come back (else a
   refusal would prove nothing: a tunnel that is not up refuses everything
   too); a WebSocket without a token and one with a wrong token must be
   refused, with no new client in x11vnc's log; the right one must get the
   VNC greeting. Each try is repeated while it gets no answer. A stranger
   getting through, or a check that could not be made, closes the link and
   stops the run. Then the summary: the link, the start and the end time
   (link up + 20 minutes for the phone to start + the minutes). GitHub may
   show a job's summary only when the job ends, so the link is also an
   annotation and the last line of the step's log.
6. **The phone** (`emulator-live.sh`, inside the pinned
   `android-emulator-runner`, as the app lab's: `android-36;default`, 6 GB,
   12 GB, emulator 16428233, `-tcpdump`), with a window on `:99` (no
   `-no-window`). As the app lab, up to just before Start (`session_root`
   and `session_prepare` in `lib/common.sh`): `adb root`, tcpdump inside the
   guest on every interface, the clock marker, airplane mode, the module
   installed and its firewall live, tor's STREAM events, mobile data off;
   then the two stores installed with `adb install` (only verified APKs),
   before Welcome becomes the device owner, since from then on Welcome
   refuses apps from outside until a session with Administration on; then
   Welcome as device owner (the debug build's test hook keeps adb). As in
   the app lab, tcpdump inside the phone has a 16 MB buffer, so that a busy
   session drops nothing. The phone has a hardware keyboard
   (`enable-hw-keyboard`: without one the emulator drops the keys typed in
   the browser), and Android's own keyboard stays on as well. The page
   then says the phone is ready, and which store is or is not on it.
   Nothing is pressed or typed. Once the owner has pressed Start, the
   virtual Wi-Fi is joined as in the app lab (`wifi_join`, for a session
   with the network), and a store that could not be installed before is
   installed then, if Administration is on.
7. **The end.** At the end time, on End session (the End listener writes
   `end-requested`), when the phone restarts, or when it stops answering for
   2 minutes: the link is closed first, then the evidence
   (`collect_evidence`), both captures stopped and pulled. If the run is
   cancelled, or the step times out, the next step (`emulator-live.sh
   finish`) asks a session script that still runs to end and waits for it,
   or collects the evidence itself while the emulator still runs.
8. **The privacy check.** `analyse.sh` judges the scenario `live` by the app
   lab's rules (after the arm cutoff, anything not to the Tor network and not
   link-level is a LEAK, in either capture; names and destinations through
   Tor in learning mode), whatever the owner did. Its log stays on the
   runner: the analyser's reasons name tor's connections. `live.py report`
   writes the summary's second part and the artifact
   `antumbra-live-<run number>` (14 days): `report.md`, `report.json`
   (packets after arm, to Tor, leak flows, the session's times and checks)
   and `checks.tsv`, with every address outside the phone's own networks
   left out of the reasons and the checks, and a "leak" to one of tor's own
   connections or bridges shown without its address. No capture goes in,
   not even a small one: a leaked lookup in it would name what the owner
   did.

**Public and private.** The repository, the logs, the summaries and the
artifacts are public. The tunnel's host name is in the summary; it opens
nothing without the password. The password is a secret (GitHub masks it),
present only in the steps that check it and write the token file, and in
no background process; the tokens are masked too (`::add-mask::`). The
token file, websockify's log (which holds the WebSocket paths),
cloudflared's and x11vnc's logs are in a private directory on the runner,
never printed, never uploaded; tor's connections at the end are counted
in the log, not listed (`QUIET_TOR_CONNS`). The artifact holds counts and leaks only
(a leak's kind, destination and reason, not the names looked up for it):
no capture (the one inside the phone holds, on its loopback, what apps
sent to Tor), not the names and destinations reached through Tor, not the
session's bridges, no screenshots. The checkout keeps no credentials.

**How it starts.** GitHub runs Run workflow (`workflow_dispatch`) only
for a workflow on the default branch, `main`, which is not changed. A
pull request's `labeled` event, though, runs the workflow files of the
pull request itself. So a label whose name starts with `antumbra-live` on
the open pull request of the Antumbra branch starts a session
(`antumbra-live` is 60 minutes, `antumbra-live-<n>` is n, from 10 to 180).
The job runs only for a pull request from this repository's Antumbra
branch, never for a fork's, and only people with write access can add
labels. It checks out the Antumbra branch itself for the scripts, and
takes the build only from push or by-hand runs of Antumbra Android (never
from a pull request's run). If the file is ever on `main` too, Run
workflow (with its minutes) works as well.

**Time.** The job's limit is the minutes plus about 80, and the phone's
step the minutes plus about 45 (tiers of 30, 60, 90, 120 and 180 minutes),
so that a session that overruns still leaves time for the check and the
artifact. `concurrency: antumbra-live` keeps to one session; the Android
workflow's own group is untouched.

**Not tested before the first run.** The setup on the phone (Android 16
under KVM) and the quick tunnel from GitHub's runner were not run before
the first session. The emulator's window and toolbar were, with the pinned
emulator on Xvfb (an older, small Android image without KVM): the fitter,
the hidden × and – and Extended Controls. The screen chain (Xvfb, x11vnc,
websockify with the token file, the two pages and noVNC's core) was run
with a stand-in window in Chromium at an iPhone's size with touch, and
`test_live.py` runs a real websockify against a fake VNC server.

## The daily page

`daily.py` turns one emulator run's artifact (unpacked `antumbra-android-<n>`),
compared with the run before it, into the "Antumbra Daily" page: the verdict
(pass, fail, or "could not judge" for `blind`), the leak test in plain words
(packets after arm, how many went to Tor, what the rest were, LEAK flows, the
armed window, and what plain Android sent in the baseline), each screenshot
with "Looks right"/"Looks off" buttons (before and after when more than 2% of
it changed, the status bar left out), the numbers with their change since the
previous run, and the checks, warnings and failures first. It reads
`verdict.json`, `leak-report.json`, `<scenario>/checks.tsv` and `events.tsv`,
`antumbra/filter-status.json`, `bootstrap-progress.tsv`, `build/*.md` and
`screenshots/`; without `verdict.json` it judges with `summary.py`. A missing
value shows as a dash. Standard library only, plus ImageMagick (`convert`,
`compare`, `identify`) for the embedded JPEGs; without it the page has no
images.

```sh
python3 -I antumbra/android/ci/daily.py --run RUN_DIR [--prev PREV_DIR] \
    --run-number N --sha SHA --subject "commit subject" --run-url URL \
    [--question QUESTION.json] [--date 2026-10-11] \
    --out antumbra-daily.html --metrics-out metrics.json
```

The output is the page's content for an artifact (no `<html>` or `<body>`),
titled "Antumbra Daily". The artifact holds no run number, commit or link, so
they are passed in; the run number defaults to the DNS filter's version
(`ci.<n>`), which also names the previous run (`--prev-run-number`
overrides it). The page's buttons write the same database documents as the
Debian track's page (`feedback/<run>_<screen>`, `controls/state`,
`undo/<sha>`, `answers/<id>`, `photos/<asset>`), and its history table reads
`metrics/<run>`, the document `--metrics-out` writes (its fields are listed
in the script's docstring). Pause and Stop keep any other field of
`controls/state` (such as a `reason`), and the page says in words that
changes are paused, and why. `--sha` must be a commit id; without it the
page offers no Undo. When the leak analysis ended in an error, or has no
time after the firewall went on, the page and the metrics show no packet
or leak counts (a dash, `null`) instead of zeros; the armed window counts
only when it was measured (`ok` or `fail`). Tor's time is rounded once, to
whole seconds, for the page and the metrics alike. A screen counts as
changed when more than 2% of its pixels differ at full size, the status
bar left out. Tests: `tests/test_daily.py`.

## Running the pieces by hand

```sh
# Unit tests of the CI tools (synthetic captures and recorded fixtures, no
# emulator). In CI the emulator job runs test_ci and test_daily, the
# app-lab job test_applab, so that the app lab never stops the leak test,
# and Antumbra Live test_live.
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

# The app lab's downloads and checks, on any Linux host with curl and the
# build tools (apksigner, aapt2); then the scenario against a running
# emulator (it fetches by itself when ANTUMBRA_APPLAB_DL has no
# downloads.json), and apps.json from its report
python3 -B -I antumbra/android/ci/applab.py fetch --catalogue antumbra/android/ci/app-lab.txt \
    --out /tmp/applab --apksigner "$ANDROID_HOME/build-tools/36.0.0/apksigner" \
    --aapt2 "$ANDROID_HOME/build-tools/36.0.0/aapt2"
ANTUMBRA_APPLAB_DL=/tmp/applab bash antumbra/android/ci/emulator-apps.sh
python3 -B -I antumbra/android/ci/applab.py build "$ANTUMBRA_CI_OUT"
```

| File | What it is |
|---|---|
| `emulator-baseline.sh`, `emulator-antumbra.sh` | the two scenarios |
| `emulator-apps.sh` | the app lab's scenario |
| `lib/common.sh` | adb, uiautomator, events, checks, screenshots, logs; the clock marker, the device's clock, the capture inside the guest; the Antumbra session shared by ANTUMBRA and the app lab (the module, Welcome, Wi-Fi, tor's bootstrap and STREAM events, the evidence) |
| `lib/tor-streams.sh` | runs on the device as uid 2950: records tor's STREAM events |
| `analyse.sh` | runs the analyser on both captures after the emulator exits |
| `pcapread.py` | the capture reader and decoder |
| `leak_analyser.py` | classification, verdicts, reports; also `tor-conns`, `listeners` and `slim` |
| `expected-destinations.txt` | the names and destinations expected through Tor |
| `citool.py` | uiautomator search, DNS over TCP, JSON lookups, the artifact size limit |
| `summary.py` | the job summary, `verdict.json` and the final verdict |
| `daily.py` | the "Antumbra Daily" page and its `metrics/<run>` document, from an artifact |
| `sdk-install.sh` | the pinned NDK, platform 36 and build tools 36.0.0 |
| `tests/test_ci.py` | unit tests with generated captures |
| `tests/test_daily.py` | unit tests of `daily.py` with synthetic artifacts |
| `applab.py`, `app-lab.txt` | the app lab's downloads and checks, its screen and log readers, `apps.json`; its catalogue |
| `tests/test_applab.py`, `tests/fixtures/applab/` | unit tests of `applab.py`, with F-Droid's index, Aptoide's answers and apksigner's output recorded and trimmed |

## Contracts with the other parts

- **Welcome:** the debug build honours `debug.antumbra.keep_adb=1` (set
  before `dpm set-device-owner`) by leaving USB debugging on; the test tags
  `tor_direct`, `switch_mac`, `switch_admin`, `switch_unsafe_browser`,
  `start_button`, `status_title`, `row_firewall`; the provider row's
  `started`, `tor_mode` and `admin`; `welcome/ci/welcome-adb.sh -s SERIAL
  check-policies --keep-adb` and `check-addon` (the app lab:
  `check-policies --admin --keep-adb`, and `admin=1` after Start with
  `switch_admin` on). After Start with the add-on
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
