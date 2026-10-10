# Antumbra simulator: behaviour spec

Scope: what a user can try in the simulator, how the real system behaves, with
what words, and how long it takes: Tor, MAC address anonymization, the pop-up
selfie camera, Android apps, Persistent Storage, screen lock, power and
shutdown, administration, and the known issues the simulator must disclose.

Conventions

- Paths are relative to the repository's `antumbra/` directory unless absolute.
  `file:N` or `file:N-M` is a line or range. Text in "double quotes" or in code
  spans is verbatim from the source given.
- `VM log` = a run of the real image in QEMU under full software emulation
  (TCG, 3 CPUs), kept in `build/work/qemu-virt/run-*/`. Line numbers in
  `serial.log` count the raw file. Which run is which:
  `build/work/qemu-virt/runs-f.log:9` (f1: `--through-welcome --tour --camera`,
  4096 MiB, `run-f1/smoke.log:1`), `:13`/`:15` (f3a/f3b: `--persistence`,
  create then unlock), `:20` (f4b: `--android`, 6144 MiB,
  `run-f4b/smoke.log:1`).
- `Tor binary` = `build/work/qemu-virt/rootfs/usr/bin/tor`, the Tor 0.4.9.11
  in the built image (`run-f1/serial.log:897`); its strings were read with
  `strings`, its phase table found at file offset 0x396540 (24-byte entries).
- Timing labels: **[phone]** = what the repo says about the OnePlus 7T Pro
  (nothing has booted on one yet: `README.md:31-32`, `docs/known-issues.md:8`);
  **[VM]** = measured in the VM log (emulation: ~10x slower than the phone per
  `config/rootfs-android/usr/local/lib/antumbra-waydroid:63-65`); **[unknown]**
  = the repo is silent or says unmeasured.
- The simulator must say it is a simulation; the repo itself says the system is
  "alpha, not yet booted on hardware" (`README.md:14`) and "Treat this as a
  developer preview." (`README.md:32`).

---

## 0. Timing cheat sheet

| Event | Phone | VM (measured) | Source |
|---|---|---|---|
| Power on to kernel/display | "display stays dark until the panel driver binds; the first boot can take a minute" | Welcome screen "a minute or two to appear under emulation"; f1 harness saw it drawn at 302 s | `docs/hardware-validation.md:20-22`; `docs/vm-testing.md:57-58`; `run-f1/smoke/report.json` check "display: the Welcome screen is drawn" t=302.4 |
| Start pressed to user session | [unknown] | applier started 306.4 s, `amnesia` session opened 316.6 s (10 s) | `run-f1/serial.log:1427`, `:1462` |
| MAC address spoofed after Start | [unknown] | 320.8 s to 321.7 s (under 1 s, 14 s after Start) | `run-f1/serial.log:1478-1481` |
| NetworkManager up | [unknown] | 345.5 s | `run-f1/serial.log:1715` |
| Tor told to connect, first phase | [unknown] | control connections 362.8 s, "Bootstrapped 5% (conn)" 364.2 s | `run-f1/serial.log:1822`, `:1850` |
| Tor fully bootstrapped | [unknown]: not measured anywhere | never: stuck at 14 % (no route to Tor from the build host) | `docs/vm-testing.md:41-45`; `run-f1/serial.log:2353` |
| htpdate (clock) after Tor | [unknown] | never ran (waits for Tor): "Job htpdate.service/start running (33min 14s / no limit)" | `run-f1/serial.log:6415` |
| Pop-up camera course (rise or lower) | nominal ~668 ms, hard cap nominal + 50 ms (~718 ms); stock OxygenOS stops on ~620 ms; never measured on hardware | not in the VM (no motor) | `device/oneplus-hotdog/kernel/patches/0102-media-qcom-hotdog-popup-pm-shutdown-safety.patch:52-66`, `:153-164`; `docs/vm-testing.md:466-472` |
| Pop-up around suspend/resume | "can lag a few hundred milliseconds" | n/a | `docs/known-issues.md:40-43` |
| First Snapshot preview frame | [unknown] | ~196 s ("the first frame takes a few minutes") | `run-f1/smoke/report.json` check "camera: the preview shows vimc's colour bars"; `docs/vm-testing.md:199-202` |
| Persistent Storage create (argon2id 1 GiB, 4 it.) | [unknown] | applier start 298.9 s, "Persistent Storage created" 333.3 s, "unlocked" 348.2 s, features 349.9-352.9 s, "welcome settings applied" 382.5 s | `run-f3a/serial.log:1414,1487,1519,1525-1539,1686` |
| Persistent Storage unlock | [unknown] | 311.7 s to 329.1 s (~17 s) | `run-f3b/serial.log:1448,1484` |
| Wrong passphrase reported | [unknown] | 358.7 s to 375.0 s (~16 s), locked again 376.3 s | `run-f3b/serial.log:1577,1612,1616` |
| Android prepared (`antumbra-waydroid`) | [unknown] | 430.1 s to 492.6 s (~63 s) | `run-f4b/serial.log:1685`, `:2105` |
| Android boots (`sys.boot_completed=1`) | unmeasured; launcher says "The first start of a session takes a minute or two." | session start 628 s, boot_completed 1568 s (~15.5 min); docs: "about 15 minutes (666 to 1557 seconds of the guest's uptime)" | `docs/known-issues.md:243-247`; `config/rootfs-android/usr/local/lib/antumbra-android-launch:16`; `run-f4b/serial.log:2580`, `:6025`; `docs/vm-testing.md:369-371` |
| Android user unlocked after boot | "there the unlock comes seconds after the boot" | "takes minutes more under emulation"; app entries "within 8 minutes" | `docs/vm-testing.md:373-385` |
| F-Droid installed | install/compile "seconds on the phone" | 1976.5 s (~6.8 min after boot) | `config/rootfs-android/usr/local/lib/antumbra-fdroid-install:25-26`; `run-f4b/serial.log:7432` |
| Idle Android frozen / thawed | frozen after "a few minutes" with no Android app open; thawed "within seconds" by opening an app (expectations, untested) | off in the VM (`persist.waydroid.suspend=false`) | `docs/hardware-validation.md:314-317`; `docs/known-issues.md:259-265` |
| Screen blanks and locks when idle | 120 s idle, lock at blank (`lock-delay=uint32 0`) | short power press: display off ~4.4 s later, auto-shutdown timer armed ~6 s later | `config/rootfs/etc/dconf/db/local.d/00-antumbra:12-17`; `run-f1/serial.log:6421,6431,6439` |
| Locked too long | power off after 18 h, also from suspend | n/a | `config/rootfs/usr/lib/systemd/system/antumbra-auto-shutdown.timer:9-10` |
| Long press of power key | "about 5 s" to power-off; "powers off within about 5 seconds" | n/a | `docs/architecture.md:265`; `docs/hardware-validation.md:48` |
| Power-off sequence | [unknown] | poweroff starts 2404.6 s, "Powering off." 2458.9 s (~54 s) | `run-f1/serial.log:6535` area, `:7301` |
| Welcome screen gives up waiting for the applier | 600 s: "timed out waiting for the settings to be applied" | same | `config/rootfs/usr/lib/python3/dist-packages/antumbra/settings.py:110`, `:132-133` |

---

## 1. Tor

### 1.1 How Antumbra connects (the three modes)

- Tor starts at boot with `DisableNetwork 1` "until the user has chosen how to
  connect" (`docs/architecture.md:324-325`; `config/rootfs/etc/tor/torrc:49`).
  VM log: "DisableNetwork is set. Tor will not make or accept non-control
  network connections. Shutting down all existing connections."
  (`run-f1/serial.log:909`), then "Bootstrapped 0% (starting): Starting"
  (`:994`) and "Delaying directory fetches: DisableNetwork is set." (`:996`).
- No network device exists before the Welcome decision: every network driver
  is blocklisted at build time and loaded only after the Welcome screen
  (`docs/architecture.md:522-526`). The VM checks that no frame of any kind left
  the guest before the Welcome decision (`docs/vm-testing.md:130-134`).
- Welcome screen choice, row "Connect to Tor", options exactly:
  "Automatically", "Through bridges (enter below)", "Offline mode (no network at
  all)"; default is the first (`config/rootfs/usr/bin/antumbra-welcome:109-111`;
  default `network = "direct"` in `settings.py:175`). Bridge row title:
  "Bridges: obfs4, webtunnel or meek_lite, separated by ;", insensitive unless
  "Through bridges" is selected (`antumbra-welcome:117-118`, `:182-183`).
- Stored as `TAILS_NETWORK` ("false" only for offline) and `ANTUMBRA_TOR_MODE`
  (`direct`|`bridges`|`offline`), bridges as `ANTUMBRA_BRIDGES` on one line,
  `;` between bridges (`settings.py:191-194`, `:45-50`).
- At Start, root applies the settings once, then runs
  `antumbra-unblock-network` (`config/rootfs/usr/local/lib/antumbra-apply-welcome-settings:262-266`):
  - offline: "network disabled by the user (offline mode); leaving drivers
    blocked" and nothing else (`config/rootfs/usr/local/lib/antumbra-unblock-network:12-15`);
  - if the early self-check did not report `firewall OK`: "refusing to unblock
    the network: firewall self-check did not pass" (`:19-22`);
  - otherwise: remove the blocklist, load `ath10k_snoc` (Wi-Fi), replay udev
    add events (MAC spoofing fires per interface, section 2), start
    NetworkManager (`:24-39`).
- When a connection comes up, the NetworkManager dispatcher
  `config/rootfs/etc/NetworkManager/dispatcher.d/10-antumbra-tor.sh` reads the
  applied mode and runs `antumbra-tor-connect direct`, or pipes the bridge lines
  into `antumbra-tor-connect bridges -`, or does nothing for offline (`:21-29`);
  then restarts `htpdate.service` unless `/run/htpdate/success` exists (`:30-33`).
  When the last connection goes down it stops
  `tails-tor-has-bootstrapped.target` (`:13-17`).
- `antumbra-tor-connect` (root only; talks to ControlPort 9052 with the cookie):
  - `direct`: sets `UseBridges 0`, no `Bridge`, `DisableNetwork 0`; prints
    "connecting directly" (`config/rootfs/usr/local/sbin/antumbra-tor-connect:53-57`);
  - `bridges FILE|-`: validates lines with the Welcome screen's own check, sets
    `UseBridges 1`, the lines, `DisableNetwork 0`; prints "connecting through N
    bridge(s)" (`:60-72`); "no bridge lines given" if empty (`:66-67`);
  - `status`: prints Tor's `status/bootstrap-phase`, then "enough-dir-info N",
    then "DisableNetwork N" (`:75-81`);
  - `disconnect`: `DisableNetwork 1`, prints "network disabled for Tor" (`:84-87`);
  - control port unreachable: "cannot reach Tor's control port" (`:28-30`).
  - SETCONF only, never SAVECONF (`:41-50`; `docs/architecture.md:391-393`).
- Pluggable transports: when any bridge needs one, `tor-pt-configuration-helper 0`
  stops Tor, writes `Sandbox 0` and the line `ClientTransportPlugin
  obfs2,obfs3,obfs4,webtunnel,meek_lite exec /usr/bin/obfs4proxy -enableLogging
  -logLevel DEBUG`, and starts Tor again; `direct` switches `Sandbox 1` back
  (also a Tor restart if it was 0) (`config/rootfs/usr/local/lib/tor-pt-configuration-helper:18-35`;
  `antumbra-tor-connect:35-38`, `:54`, `:68-69`). `/usr/bin/obfs4proxy` is
  Tor Browser's `lyrebird` (`docs/architecture.md:350-357`).
- Failures are silent: "The dispatcher ignores the tool's failures, so any other
  failure leaves Tor disconnected without a message; `antumbra-tor-connect
  status`, as root, shows it." (`docs/architecture.md:394-396`; `|| true` at
  `10-antumbra-tor.sh:24`, `:27`).
- What `antumbra-tor-connect` sets by hand lasts "until Tor restarts or, unless
  the Welcome screen chose offline mode, until the next network connection
  comes up, when the Welcome screen's choice is applied again; it is not saved
  anywhere." (`docs/known-issues.md:72-77`).
- No Tor Connection assistant, no QR code, no Moat (`docs/known-issues.md:72-73`;
  `docs/tails-porting-map.md:19`; roadmap item 5, `docs/roadmap.md:21-22`).

Bridge validation at Start (only when "Through bridges" is chosen,
`antumbra-welcome:201-202`), exact messages (`settings.py`):

| Input | Message shown under the form |
|---|---|
| no usable line | "Enter at least one bridge line, or connect automatically." (`antumbra-welcome:202`) |
| `snowflake ...` | "Snowflake bridges do not work in Antumbra: snowflake reaches its proxies through WebRTC over UDP, and the firewall lets Tor make only TCP connections and DNS queries. Use obfs4 or webtunnel bridges." (`settings.py:31-33`) |
| plain/obfs2/obfs3/obfs4 with IPv6, e.g. `[2001:db8::5]:443` | "{address} is an IPv6 address. IPv6 bridges do not work in Antumbra: IPv6 is off, and the firewall lets Tor connect only over IPv4. Use bridges with IPv4 addresses." (`settings.py:41-42`, `:79-82`) |
| other transport (e.g. `conjure`) | "Unsupported bridge type: {kind}. Antumbra takes obfs4, webtunnel, meek_lite, obfs2, obfs3 and plain bridges." (`settings.py:70-72`) |

Accepted: plain (IPv4 address first), `obfs2`, `obfs3`, `obfs4`, `webtunnel`,
`meek_lite`; webtunnel/meek_lite addresses are placeholders and may be IPv6; a
leading `Bridge` word, empty lines and `#` comments are dropped
(`settings.py:28`, `:34-40`, `:53-84`). Pasted multi-line bridges are kept and
stored with `;` (`antumbra-welcome:114-116`; self-test `:310-316`).

### 1.2 Tor's bootstrap phases (exact log lines)

Log line format, from the Tor binary: `Bootstrapped %d%% (%s): %s` and, when
stuck, `Problem bootstrapping. Stuck at %d%% (%s): %s. (%s; %s; count %d;
recommendation %s; host %s at %s)`.

Tor 0.4.9.11's phase table (percent from the binary's table at 0x396540; tag
and summary strings from the binary, in the same order):

| % | tag | summary |
|---|---|---|
| 0 | starting | Starting |
| 1 | conn_pt | Connecting to pluggable transport |
| 2 | conn_done_pt | Connected to pluggable transport |
| 3 | conn_proxy | Connecting to proxy |
| 4 | conn_done_proxy | Connected to proxy |
| 5 | conn | Connecting to a relay |
| 10 | conn_done | Connected to a relay |
| 14 | handshake | Handshaking with a relay |
| 15 | handshake_done | Handshake with a relay done |
| 20 | onehop_create | Establishing an encrypted directory connection |
| 25 | requesting_status | Asking for networkstatus consensus |
| 30 | loading_status | Loading networkstatus consensus |
| 40 | loading_keys | Loading authority key certs |
| 45 | requesting_descriptors | Asking for relay descriptors |
| 50 | loading_descriptors | Loading relay descriptors |
| 75 | enough_dirinfo | Loaded enough directory info to build circuits |
| 76 | ap_conn_pt | Connecting to pluggable transport to build circuits |
| 77 | ap_conn_done_pt | Connected to pluggable transport to build circuits |
| 78 | ap_conn_proxy | Connecting to proxy to build circuits |
| 79 | ap_conn_done_proxy | Connected to proxy to build circuits |
| 80 | ap_conn | Connecting to a relay to build circuits |
| 85 | ap_conn_done | Connected to a relay to build circuits |
| 89 | ap_handshake | Finishing handshake with a relay to build circuits |
| 90 | ap_handshake_done | Handshake finished with a relay to build circuits |
| 95 | circuit_create | Establishing a Tor circuit |
| 100 | done | Done |

Which of these phases a given run prints, and at which intermediate
percentages, is Tor's behaviour and is not recorded in the repo beyond 14 %.
The `_pt` phases are named for pluggable transports and the `_proxy` ones for
proxies (tag names above); Antumbra configures no proxy for Tor. Tor's state
directory is in RAM like everything else, so each boot starts from nothing
(`docs/architecture.md:23-25`); the repo does not discuss consensus caching.

What the VM actually printed, direct mode (all VM runs, identical; 21
occurrences each in `build/work/qemu-virt/run-*/serial.log`):

```
[  172.952012] Bootstrapped 0% (starting): Starting                 run-f1/serial.log:994
[  364.223960] Bootstrapped 5% (conn): Connecting to a relay         :1850
[  438.999669] Bootstrapped 10% (conn_done): Connected to a relay    :2108
[  439.506458] Bootstrapped 14% (handshake): Handshaking with a relay :2110
[  525.085001] Problem bootstrapping. Stuck at 14% (handshake): Handshaking with a relay. (Connection refused; CONNECTREFUSED; count 10; recommendation warn; host A208C66E3BAF32B70920EB6AF8081F7CFA5DB1D1 at 136.243.176.179:9002)   :2353
               9 connections have failed:                            :2354
                5 connections died in state connect()ing with SSL state (No SSL object)   :2355
                4 connections died in state handshaking (Tor, v3 handshake) with SSL state SSL negotiation finished successfully in CLOSED   :2356
```

Other real Tor lines from the same log, usable for a log view: "This version
of Tor was built without support for sandboxing. To build with support for
sandboxing on Linux, you must have libseccomp and its necessary header files
(e.g. seccomp.h)." (`:992`); listeners opened when told to connect, e.g.
"Opened Socks listener connection (ready) on 127.0.0.1:9050",
"Opened Transparent pf/netfilter listener connection (ready) on 127.0.0.1:9040",
"Opened DNS listener connection (ready) on 127.0.0.1:5353" (`:1831-1846`).

`status/bootstrap-phase` (what `antumbra-tor-connect status` prints) has the
form `NOTICE BOOTSTRAP PROGRESS=%d TAG=%s SUMMARY="%s"` (format strings
`BOOTSTRAP PROGRESS=%d TAG=%s SUMMARY="%s"` and `NOTICE %s` in the Tor binary;
the third word is parsed as `PROGRESS=N` by
`config/rootfs/usr/local/lib/tor_wait_until_bootstrapped:44-46`).

"Bootstrapped" for the system means progress 100 and `enough-dir-info` 1,
checked once a second (`tor_wait_until_bootstrapped:40-50`, `:57-67`) by
`tails-wait-until-tor-has-bootstrapped.service` ("Wait for Tor to Have
Bootstrapped", no timeout: `TimeoutStartSec=0`;
`config/rootfs/usr/lib/systemd/system/tails-wait-until-tor-has-bootstrapped.service:2`, `:12`),
which then pulls in `tails-tor-has-bootstrapped.target` ("Tor has
Bootstrapped") and touches `/run/tor-has-bootstrapped/done`
(`tails-tor-has-bootstrapped-flag-file.service:12-13`). In the VM that unit
never finished: "Job tails-wait-until-tor-h…art running (38min 32s / no limit)"
(`run-f1/serial.log:6418`).

Tails' own Tor Connection assistant timeouts (10 s to first sign of life, 600 s
bootstrap) exist only in the vendored, unported `tca`
(`vendor/tails/config/chroot_local-includes/usr/lib/python3/dist-packages/tca/ui/main_window.py:50-52`);
Antumbra has no such timeout or progress UI.

### 1.3 What the user sees

- No Tor status indicator, no "Tor is ready" notification, no progress bar:
  nothing in the image produces one (no notification code outside the Android
  launcher: `config/rootfs-android/usr/local/lib/antumbra-android-launch:7-10`;
  the session screenshots show no Tor icon in the top bar or quick settings:
  `run-f1/smoke/tour-quick-settings.png`, `run-f4b/smoke/session.png`).
- The only way to see the phase is `antumbra-tor-connect status` "as root"
  (`docs/architecture.md:395-396`; hardware check `docs/hardware-validation.md:63`).
  `amnesia` cannot read Tor's log: the system journal is volatile
  (`docs/architecture.md:267`) and `amnesia` is in `audio dip video plugdev users
  input render netdev` only (`build/work/qemu-virt/rootfs/etc/group`), and the
  firewall rejects the user from the ControlPort
  (`config/rootfs/etc/nftables.conf:126`). So in practice: Administration on,
  then `sudo antumbra-tor-connect status` in Console.
- Tor Browser start page while Tor is managed by the system (screenshot
  `run-f1/smoke/tour-tor-browser.png`): tab "New Tab", address bar "Search or
  enter address", "Import bookmarks…", an info bar "Tor Browser Alpha has set
  your display language based on your system’s language." with "Change
  Language…", the alpha logo and "Test. Thorou…" (cut off), and a box "Your
  connection to Tor is not being managed by Tor Browser. Some operating systems
  (like Tails) … this for you, or you could have set up a custom configuration.
  Test your connection" (right edge cut off in the screenshot), "Search with
  DuckDuckGo". What Tor Browser shows when a page is requested before Tor has
  bootstrapped is not recorded in the repo.
- The Welcome screen warns: "Tor Browser for arm64 Linux exists only in Tor
  Project's alpha channel. Tor Project advises people at risk not to rely on
  alpha releases." (`antumbra-welcome:29-30`, `:152`).
- Self-check failures appear only as the Welcome screen's banner,
  "Privacy self-check failed: " + the FAIL lines joined by "; ", cut at 200
  characters (`antumbra-welcome:37-42`, `:68-73`); read when the Welcome screen
  opens (boot, or again after a logout).

### 1.4 Non-Tor traffic: the firewall

Source of truth: `config/rootfs/etc/nftables.conf` (Tails' ferm rules ported,
`docs/architecture.md:272-309`).

- Policy drop on input, forward and output (`nftables.conf:56-57`, `:89-90`,
  `:114-115`). Everything not allowed is logged with prefix
  "Dropped outbound packet: " (with the UID) and rejected with ICMP
  port-unreachable (`:41-43`, `:158-159`): an app gets an immediate refusal, not
  a timeout.
- The user `amnesia` (UID 1000):
  - TCP to the Internet is transparently redirected to Tor's TransPort 9040
    (`:173-175`, the same as Tails' "Transparently proxy all of amnesia's
    outgoing TCP": `vendor/tails/config/chroot_local-includes/etc/ferm/ferm.conf:152-157`);
  - DNS to 127.0.0.1:53 is redirected to Tor's DNSPort 5353 (`:172`;
    `/etc/resolv.conf` is "nameserver 127.0.0.1", `docs/architecture.md:400-407`);
  - `.onion` automap addresses 127.192.0.0/10 go to the TransPort (`:170`);
  - UDP (other than that DNS), ICMP and all IPv6 to the outside: logged and
    rejected (`docs/architecture.md:290-293`); IPv6 is also disabled by sysctl
    (`:405-407`);
  - local network (10/8, 172.16/12, 192.168/16) reachable directly, except DNS
    and NetBIOS (`nftables.conf:17`, `:105-111`, `:156`; `:174` exempts it from
    the redirect);
  - Tor's ControlPort 9052 and SocksPort 9063: rejected (`:124-126`).
- `debian-tor` may open any IPv4 TCP connection and send UDP DNS, nothing else
  (`:147-148`); hence no snowflake (UDP).
- Re-applied by the dispatcher on every interface up
  (`config/rootfs/etc/NetworkManager/dispatcher.d/00-firewall.sh:1-12`).
- VM evidence after Start: "every connection to the network belongs to Tor
  (DHCP aside)", "the guest sent no DNS, NTP, IPv6 or other UDP (DHCP aside)",
  "every TCP connection the guest opened went to a Tor directory or relay"
  (`run-f4b/smoke.log`; method: `docs/vm-testing.md:135-157`).
- Hardware leak tests to expect (`docs/hardware-validation.md:67-71`): `curl
  --socks5-hostname 127.0.0.1:9050 https://check.torproject.org` works; `ping
  1.1.1.1` fails; `dig @1.1.1.1 example.com` fails; `getent hosts example.com`
  resolves through Tor's DNSPort; `journalctl -k | grep Dropped` shows the
  rejected attempts. The same item says `curl http://1.1.1.1` fails; see
  section 11, item 3.

### 1.5 Tor Browser in its own network namespace

- Launch chain: `tor-browser` → `sudo` (NOPASSWD rule for `amnesia`) →
  `antumbra-run-tor-browser` → `ip netns exec tbb` → back to `amnesia` →
  `launch-tor-browser` (`docs/architecture.md:832`;
  `config/rootfs/usr/local/bin/tor-browser:5-6`;
  `config/rootfs/etc/sudoers.d/antumbra-tor-browser:4`;
  `config/rootfs/usr/local/lib/antumbra-run-tor-browser:12-14`).
- The launcher refuses options: "tor-browser: options are not accepted (…)"
  (`antumbra-run-tor-browser:7-11`).
- The `tbb` namespace sits on a veth in 10.200.1.0/24 and reaches only Tor's
  SocksPort 9050 and the control-port filter 951, by DNAT of its own loopback
  ports (`config/rootfs/usr/local/lib/antumbra-create-netns:4-9`, `:130`,
  `:135-136`); the browser uses the system Tor (`TOR_SKIP_LAUNCH=1`,
  `TOR_CONTROL_PORT=951`, `TOR_SOCKS_PORT=9050`:
  `config/rootfs/usr/local/lib/launch-tor-browser:20-24`).
- VM check: "tour: Tor Browser runs inside its own network namespace (tbb)" with
  detail "procs=10 netns=tbb" (`run-f1/smoke/report.json`).
- Version: Tor Browser 16.0 alpha, `tor-browser-linux-aarch64-16.0a13.tar.xz`;
  no AppArmor profile (`docs/architecture.md:832`; `docs/known-issues.md:52-55`).
  "Tor Browser is a desktop browser on a phone screen: usable with the
  compositor's 3x scale, not adapted." (`docs/known-issues.md:68-69`).
- No Unsafe Browser; captive portals cannot be handled (`docs/known-issues.md:70-71`).

### 1.6 Time synchronisation (htpdate)

- No NTP: `systemd-timesyncd` masked, ModemManager absent; the modem's NITZ is
  not used (`docs/architecture.md:411-423`).
- `htpdate.service` ("Setting time using HTP") deletes its done/success files,
  then waits `until test -e /run/tor-has-bootstrapped/done; do /bin/sleep 1;
  done`, then runs Tails' Perl `htpdate` as user `htp` through SocksPort 9062,
  with three pools and `--allowed_per_pool_failure_ratio 0.34`, logging to
  `/var/log/htpdate.log` (`config/rootfs/usr/lib/systemd/system/htpdate.service:2`, `:13-31`).
  It takes "the median of three pools of HTTPS servers" (`docs/architecture.md:419-421`).
- Pools: `config/rootfs/etc/default/htpdate.pools:2-4` (e.g. pool 1 starts
  "puscii.nl,espiv.net,db.debian.org,…", pool 3 "www.google.com,github.com,…").
- Never re-run once `/run/htpdate/success` exists (`10-antumbra-tor.sh:30-33`).
- Gap: "`htpdate` time synchronisation needs Tor to bootstrap first; the
  pre-Tor clock fix from Tails (captive-portal `Date` header) is not wired to a
  user prompt." (`docs/known-issues.md:118-120`). Whether the phone's RTC holds
  real time is unconfirmed (`docs/hardware-validation.md:295-297`; the PMIC RTC
  "cannot be set from Linux": `docs/threat-model.md:107-110`). Tor "needs a
  roughly correct clock" (`docs/architecture.md:411`).
- The user sees nothing of this; duration on the phone [unknown].

### 1.7 Offline mode and disconnecting

- Offline: drivers stay blocked, so there is no Wi-Fi interface at all;
  the dispatcher does nothing (`antumbra-unblock-network:12-15`;
  `10-antumbra-tor.sh:28`). Welcome option text "Offline mode (no network at
  all)" (`antumbra-welcome:111`).
- Wi-Fi is connected through Phosh's settings (`docs/hardware-validation.md:61`).
  Hidden networks are refused: the profile is torn down and deleted, journal
  "refusing hidden Wi-Fi profile <name>; removing it"
  (`config/rootfs/etc/NetworkManager/dispatcher.d/pre-up.d/10-antumbra-no-hidden-ssid:8-13`).
  No user-facing message for that is in the repo.
- The cellular radio is never used: "The cellular radio stays off. Only Wi-Fi is
  used, through Tor." (`antumbra-welcome:154`).

---

## 2. MAC address anonymization

- Welcome row "MAC address anonymization", subtitle "Random Wi-Fi hardware
  address for this session", on by default (`antumbra-welcome:105-108`;
  `settings.py:174`).
- When: at the moment each Ethernet-type interface (Wi-Fi included) appears,
  which is after Start, when the drivers are unblocked and before NetworkManager
  starts (`antumbra-unblock-network:1-5`, `:24-38`; udev rule
  `config/rootfs/etc/udev/rules.d/00-mac-spoof.rules:13-14`). VM: 14 s after
  the applier started, before NetworkManager (`run-f1/serial.log:1478-1481`,
  `:1715`).
- What: `macchanger -e` on the interface, up to three attempts until the address
  differs (`config/rootfs/usr/local/lib/antumbra-spoof-mac:60-65`, `:93-103`).
  VM: hardware `52:54:00:a1:7b:01`, interface `50:54:00:b4:4d:48` (f1) and
  `50:54:00:a4:ce:fd` (f4b): only the last three bytes and the first byte
  changed (`run-f1/smoke/report.json`; `run-f4b/smoke.log`).
- Journal lines (tag `spoof-mac`): "Trying to spoof MAC address of NIC enp0s7...",
  "Successfully spoofed MAC address of NIC enp0s7" (`run-f1/serial.log:1479-1481`;
  `antumbra-spoof-mac:87`, `:114`).
- Excluded: iPhone USB tethering (`ipheth`), `veth*`, the Android bridge
  `waydroid-tor` (`00-mac-spoof.rules:4-11`).
- Also: random MAC in Wi-Fi scans (`wifi.scan-rand-mac-address=yes`), no
  hostname sent, a per-boot DHCP client id (`config/rootfs/etc/NetworkManager/conf.d/antumbra-privacy.conf:3-13`);
  NetworkManager keeps the spoofed address (`spoof-mac.conf:1-3`). Hostname is
  `amnesia` and never sent (`docs/architecture.md:542`).
- On this port the pre-spoof address is already random at every boot (no
  factory-address provisioning) (`docs/architecture.md:531-533`).
- Turned off: "MAC spoofing disabled by the user for <nic>" in the journal; the
  late self-check reports `mac-<nic> (anonymization off by choice)`
  (`antumbra-spoof-mac:69-72`; `config/rootfs/usr/local/sbin/antumbra-selfcheck:139-147`).
- Failure (panic mode): interface down, driver unloaded and blocklisted for the
  session; if that fails, NetworkManager stopped and masked. Recorded texts:
  "Network interface disabled" / "MAC address anonymization failed for <nic>,
  so it is disabled for this session." or "All networking disabled" / "MAC
  address anonymization failed for <nic> and the error recovery also failed, so
  all networking is disabled." (`antumbra-spoof-mac:42-57`, `:28-35`). These go
  to `/run/antumbra/mac-spoof-failed`, read only by the late self-check as
  `mac-spoofing FAIL: <first line>` (`antumbra-selfcheck:173`), which runs 4 min
  after boot and every 15 min
  (`config/rootfs/usr/lib/systemd/system/antumbra-selfcheck-late.timer:5-6`). No
  notification exists (section 11, item 5).
- Survival across suspend is "to be validated" (`docs/threat-model.md:22`;
  `docs/hardware-validation.md:26`).

---

## 3. The pop-up selfie camera

### 3.1 Path and apps

- Front camera IMX471 (pop-up), rear IMX586 main, S5K3M5 tele, IMX481 ultra-wide
  (`docs/camera.md:3-5`). Kernel CAMSS + libcamera software ISP + PipeWire +
  camera portal + GNOME Snapshot 48 (`docs/camera.md:10-16`). Snapshot's
  launcher name is "Camera" (`build/work/qemu-virt/rootfs/usr/share/applications/org.gnome.Snapshot.desktop`),
  it is in the dock (`config/rootfs/etc/dconf/db/local.d/00-antumbra:28`).
- No OnePlus camera app, and there will not be (`docs/known-issues.md:66-67`;
  reasons `docs/camera.md:214-242`).

### 3.2 The portal permission prompt (exact, from the screenshot)

`build/work/qemu-virt/run-f1/smoke/camera-portal-prompt.png` (Phosh's Access
dialog, centred card over a dimmed "Camera" window):

- Title: "Allow app to Use the Camera?"
- Camera icon (purple), then body: "An app wants to access camera devices."
- Two buttons side by side: "Cancel" (left, dark, outlined) and "Ok" (right,
  filled light purple).

Behaviour:

- Asked "once per session" (`docs/camera.md:129`). The VM confirms the dialog
  title "'Allow app to Use the Camera?' handled by phosh" and that "while the
  portal waits for an answer, Snapshot gets no stream" (`run-f1/smoke/report.json`).
  So the camera does not rise until the user answers yes.
- Deny: "Snapshot shows no camera and the front camera stays down. The answer is
  remembered for the session" (`docs/hardware-validation.md:192-194`). Snapshot's
  own text for that state is not in the repo.
- Allow is one decision for every program installed in the system (stored as
  `yes`), not per app, and any program in the session can set it itself
  (`docs/camera.md:130-152`; `docs/known-issues.md:56-67`).
- The portal decision lives in the session's RAM home, so the next boot asks
  again (the permission store is not a Persistent Storage feature:
  `config/rootfs/etc/antumbra/persistence-features.conf:10-14`; inference from
  that list, the repo does not say it explicitly).

### 3.3 Rising and lowering

- "When an application starts streaming from the front camera, the kernel raises
  the camera first; when the stream stops, the sensor powers down and the camera
  retracts. Opening the device without streaming moves nothing."
  (`docs/camera.md:80-83`). Expected order on the phone: "the camera rises
  before the first preview frame and retracts when Snapshot switches to a rear
  camera, when it quits and when it is killed" (`docs/hardware-validation.md:200-203`).
- With Snapshot, the stream starts when it shows the front preview and stops
  when it quits, is killed or switches to a rear camera; "Every start and stop
  is a full course of the motor." (`docs/camera.md:87-89`). Also retracts when
  "the stream fails to start" (`docs/hardware-validation.md:129-132`); a failed
  opening is closed again, never left half-way (driver
  `build/cache/kernel/drivers/media/platform/qcom/hotdog-popup-motor.c:791-796`).
- Duration of one course: the motor's nominal full course is 44160 microsteps:
  960 at 105000 ns, then 43200 at 13125 ns, "about 668 ms"; a course ends at
  the Hall endpoint, at 44160 microsteps, or at the wall-clock cap "nominal
  course (about 668 ms) plus 50 ms", whichever comes first; "Stock stops its
  course on a timer of about 620 ms at 12000 ns." (`0102-…patch:52-66`,
  `:153-164`; driver constants `hotdog-popup-motor.c:36`, `:50-52`, `:68-73`).
  The real duration on hardware is to be recorded (`elapsed_us`,
  `docs/hardware-validation.md:122-128`): [unknown]. At least 1 ms from motor
  wake to the first step (`0102-…patch:79-80`).
- Kernel log per course (root only): "open stopped: steps=… elapsed_us=…
  endpoint=1 error=0 Hall up a -> b, down c -> d" / "close stopped: …"
  (`hotdog-popup-motor.c:677`; `docs/hardware-validation.md:122-128`). A cap hit
  logs "course deadline reached, watchdog stopped the motor" (`:265`).
- Suspend: retracted before sleep at `PM_SUSPEND_PREPARE`; raised again after
  resume only if a stream was held across sleep ("raising the camera again for a
  stream held across sleep"); log "camera not closed at system sleep" then a
  close course (`docs/camera.md:101-103`; `0102-…patch:11-23`;
  `docs/hardware-validation.md:138-148`; message format "camera not closed at %s
  (Hall up %d, down %d), retracting", `hotdog-popup-motor.c:902`). After resume
  "Snapshot streams again with the camera raised, or shows an error with the
  camera down. The camera is never left raised without a stream."
  (`docs/hardware-validation.md:222-226`). It "can lag a few hundred milliseconds
  behind around suspend and resume" (`docs/known-issues.md:42-43`).
- Power-off and reboot: retracted before the phone goes off ("camera not closed
  at reboot or power-off") (`docs/hardware-validation.md:149-152`;
  `0102-…patch:43-46`).
- Boot: a camera found raised (e.g. after a forced PMIC reset, which runs no
  kernel code) is retracted at probe: "camera not closed at probe"
  (`docs/hardware-validation.md:153-156`; `0102-…patch:48-50`).
- Driver ready message: "Hall-bounded pop-up power domain ready; motor remains
  off" (`hotdog-popup-motor.c:1398`).
- None of this has run on the phone (`docs/known-issues.md:44-47`).

### 3.4 Hall sensors

- Two Hall channels, `hall-up` and `hall-down` (`0102-…patch:107-108`). Thresholds
  from a single HD1913: closed needs |up| < 50 and |down| >= 340 (that unit read
  about -13 and -369); fully open needs |up| >= 300 and |down| <= 50
  (`docs/hardware-validation.md:157-160`). Motion aborts at |Hall| > 450 or with
  no progress (`0102-…patch:79-82`).
- Read only for a course, for `status`, around sleep, at boot and at power-off;
  "so it does not follow a push" (`docs/known-issues.md:36-39`).
- `/sys/bus/platform/devices/camera-popup/status` is root-only
  (`-r--------`), one line:
  `preflight_used=… restore_used=… open_used=… finish_open_used=… close_used=…
  automatic_open_count=… automatic_close_count=… endpoint=… error=… hall_up=…
  hall_down=… before_up=… before_down=… after_up=… after_down=… last_steps=…
  preflight_microsteps=320 course_limit=44160 last_elapsed_us=… course_cap_us=…
  domain_on=… sleeping=… shutdown=…` (`hotdog-popup-motor.c:1054-1082`;
  `docs/hardware-validation.md:117-120`, `:170`).

### 3.5 Drop, push, walking

- "The pop-up front camera has no drop protection. OxygenOS retracts it when the
  phone falls, on a signal from the sensor DSP, which Antumbra disables; mainline
  offers no free-fall sensor either. Do not keep the selfie camera open while
  walking, and do not push a raised camera down by hand" (`docs/known-issues.md:33-39`;
  `docs/camera.md:97-100`). Sensors (rotation, light, proximity) are not
  available (`docs/known-issues.md:31-32`).
- The OS shows no on-screen drop warning: no such text exists in the image
  (only in the docs). A simulator warning must be labelled as from the docs.

### 3.6 Indicator and who can use the cameras

- "The raised camera shows that the front camera is in use, whichever program
  uses it. It is an indicator, not a security boundary against root."
  "The rear cameras have no indicator at all." (`docs/camera.md:93-96`). Rear
  check: "Nothing shows that a rear camera is in use." (`docs/hardware-validation.md:210-211`).
- No software privacy indicator exists in Phosh's top bar for cameras (none in
  the repo or screenshots).
- Any program running as `amnesia`, Tor Browser included, can use the cameras
  without a prompt; the VM proves the portal hands a PipeWire connection to a
  call from Tor Browser's namespace: "camera: from Tor Browser's network
  namespace the camera portal gives amnesia a PipeWire connection"
  (`docs/known-issues.md:56-67`; `run-f1/smoke/report.json`).

### 3.7 Snapshot's UI and pictures

`build/work/qemu-virt/run-f1/smoke/camera-preview.png`: top bar (status bar
"Oct 6  8:15 PM", battery "0%" which is a VM artifact, `docs/vm-testing.md:59-62`);
Snapshot row: timer/countdown icon at left; a pill with three modes, photo
(selected), video, QR code; a menu (hamburger) icon at right; the preview in the
middle (the VM's `vimc` colour bars); a large round white shutter button at the
bottom; gesture pill below.

- Pictures go to `~/Pictures/Camera`, named like "Photo from 2026-10-06
  20-15-51.811664.jpeg" (VM: `run-f1/smoke/report.json`, check "camera: Snapshot
  saves a JPEG picture to ~/Pictures/Camera"; Snapshot binary strings "Photo from
  {date}", "%Y-%m-%d %H-%M-%S.%f", "Recording from {date}"). Keyboard shortcut
  `t` takes a picture (`docs/vm-testing.md:202`).
- `~/Pictures` is not a Persistent Storage feature, so pictures are forgotten at
  shutdown unless moved to `~/Persistent` (`persistence-features.conf:10-14`).

### 3.8 Limits

- Front camera: one mode, 1748x1748 RAW10; "Snapshot shows a square picture."
  (`docs/camera.md:110-111`). Saved front picture is 1748x1748
  (`docs/hardware-validation.md:209-210`).
- Software-ISP quality with untuned parameters, no flash control, no optical
  stabilisation, no touch focus, video recording untested; a CAMSS failure "can
  need a reboot"; preview orientation and mirroring untested (`docs/camera.md:112-125`;
  `docs/known-issues.md:23-30`).
- Exposure and white balance are expected to "settle within a few seconds"
  (a check to run, `docs/hardware-validation.md:212-213`): [unknown].

---

## 4. Android apps

### 4.1 Off by default; turning them on

- Only in images built with `ANTUMBRA_ANDROID=1`; "experimental and off until
  turned on at the Welcome screen" (`docs/known-issues.md:181-184`), "and then
  only for that session" (`docs/architecture.md:855-857`).
- Welcome group "Android apps", description "Android 13 (LineageOS) in a
  container, with F-Droid and no Google apps. Its traffic goes only through Tor.
  Off by default."; switch "Android apps (experimental)" (mnemonic Alt+A),
  subtitle "A weaker sandbox than the rest of Antumbra: use only apps you
  trust."; second switch "Keep Android apps and data", subtitle "In Persistent
  Storage, with Android's own usage history", sensitive only with Android on and
  Persistent Storage not "Do not use" (`antumbra-welcome:34`, `:135-147`,
  `:174-180`; screenshot `run-f4b/smoke/welcome-android.png`).
- At Start: the applier creates `/run/antumbra/android-enabled` and starts
  `antumbra-waydroid.service` without waiting; journal "Android apps enabled for
  this session" (`antumbra-apply-welcome-settings:216-220`;
  `run-f4b/serial.log:1687`).

### 4.2 Preparing and starting Android

1. `antumbra-waydroid` ("Prepare Android apps (Waydroid) for this session", up
   to 15 min): loads the `lxc-waydroid` profile, writes `waydroid.cfg`
   (multi-window, density 480 on the phone, 320 in the VM), `waydroid init`,
   `waydroid upgrade -o`, masks hardware identifiers ("7 hardware identifiers
   masked in the container" in the VM), starts the container service, writes
   `/run/antumbra/android-ready`, logs "Android apps ready for the session"
   (`config/rootfs-android/usr/lib/systemd/system/antumbra-waydroid.service:6`,
   `:17`; `antumbra-waydroid:125-154`, `:291-331`; `run-f4b/smoke/android-journal.txt`).
   Offline from the images in the read-only system; never contacts Waydroid's
   servers (`docs/architecture.md:876-879`).
2. In the session, `antumbra-android-session.path` starts `waydroid session
   start` once ready ("Android apps session (Waydroid)"); Waydroid logs "Starting
   up container for a new session" (`config/rootfs-android/usr/lib/systemd/user/antumbra-android-session.path:1-11`;
   `antumbra-android-session.service:8-18`; `run-f4b/smoke/android-journal.txt`).
3. LXC's start-host hook checks the firewall, bridge, configuration and masks;
   on success the journal says "Android container checked: Tor only, 7 hardware
   identifiers hidden in its view" (VM), on failure "Android container start
   refused: <reason>" and Android does not start
   (`config/rootfs-android/usr/local/lib/antumbra-waydroid-start-host:31-33`,
   `:141`; `run-f4b/serial.log:2703`; `docs/known-issues.md:226-230`).
4. Android boots; Waydroid writes one launcher per app; `antumbra-android-folder`
   gathers them in the app grid folder "Android", Antumbra's "Android" launcher
   first (`docs/architecture.md:967-976`;
   `config/rootfs-android/usr/local/lib/antumbra-android-folder:3-11`, `:44-55`).
   VM: folder apps `['antumbra-android.desktop', 'waydroid.org.fdroid.fdroid.desktop']`
   (`run-f4b/smoke.log`); 13 app entries appeared once the user was unlocked
   (`docs/vm-testing.md:381-383`).
5. `antumbra-waydroid-provision` sets inside Android: captive-portal checks
   off, Private DNS off, network time off; journal "Android setting
   captive_portal_mode = 0", "private_dns_mode = off", "auto_time = 0",
   "auto_time_zone = 0" (`docs/architecture.md:502-504`;
   `run-f4b/smoke/android-journal.txt`). Before that, Android's first captive
   portal check of a session goes through Tor (`docs/known-issues.md:208-210`).
6. F-Droid 2.0.1 installed on Android's first start in a session unless already
   there: waits up to 40 min for Android, then up to 15 min for the install; its
   unit allows 60 min; journal "F-Droid installed" / "F-Droid is already
   installed" / "Android did not start; F-Droid not installed" / "F-Droid could
   not be installed" (`docs/architecture.md:863`;
   `config/rootfs-android/usr/local/lib/antumbra-fdroid-install:11-33`;
   `antumbra-fdroid-install.service:13-14`).

Timings: section 0. On the phone, Android's boot time is "unmeasured"
(`docs/known-issues.md:243-247`); the hardware checklist asks to record it
(`docs/hardware-validation.md:238-244`).

### 4.3 The "Android" launcher (exact notifications)

`config/rootfs-android/usr/local/lib/antumbra-android-launch` (notifications
from app name "Android", icon `waydroid`, timeout 8000 ms, `:7-10`):

- Android off for this session: title "Android apps are off", body "Turn on
  Android apps on the Welcome screen when you next start Antumbra." (`:11-14`).
- Android on but not ready yet: title "Android is starting", body "Android opens
  when it is ready. The first start of a session takes a minute or two."; then
  the full UI opens when ready (`:15-18`).
- Otherwise opens Android's full-screen interface (`waydroid show-full-ui`).
- Launcher entry: Name "Android", GenericName "Android apps", Comment "Android 13
  in a container (Waydroid); its traffic goes through Tor"
  (`config/rootfs-android/usr/share/applications/antumbra-android.desktop:3-5`).
  Waydroid's own launcher is hidden because it offers to download images
  (`config/rootfs-android/usr/local/share/applications/Waydroid.desktop:2-10`).
- With Android off, "Android" sits in the main app grid (screenshot
  `run-f1/smoke/tour-apps.png`: Android, Calculator, Clocks, Electrum Bitco…,
  Image Viewer, Metadata Clea…, Mobile Setting…, OnionShare, Papers, Secrets,
  Text Editor; dock above: Tor Browser, Files, Camera, Console; "Search apps…";
  "Show All Apps").

### 4.4 What Android looks like

- Full UI (`run-f4b/smoke/android-full-ui.png`, `run-diag2/diag2-fullui.png`):
  Phosh's top bar stays; below it Android 13's own pulled-down shade: status
  line with time and date ("9:41  Tue, Oct 6"), battery "85%" with a charging
  icon; tiles "Internet" (highlighted, with ">"), "Bluetooth", "Flashlight"
  (dimmed), "Do Not Distu…" (cut); "No notifications"; Android's 3-button
  navigation bar (back triangle, home circle, recents square). In
  `diag2-fullui.png` the Internet tile shows a globe with an "x"; in
  `android-full-ui.png` it shows `<··>` (Ethernet-style) icon.
- Multi-window: apps open as ordinary windows (app_id `waydroid.<package>`)
  (`docs/architecture.md:967-970`). F-Droid's window
  (`run-f4b/smoke/android-fdroid.png`): a floating Android window over the
  eclipse wallpaper with a caption bar (back "<", minimise, maximise, close "X"),
  bottom tabs "Discover", "Search", "My apps".
- F-Droid's first-start permission prompt, over its window: bell icon, "Allow
  **F-Droid** to send you notifications?" (F-Droid in bold), buttons "Allow" and
  "Don’t allow" (stacked, light cyan) (`android-fdroid.png`; harness note:
  "On its first start F-Droid asks for the notification permission",
  `tests/vm/antumbra_vm.py:1798-1799`).
- Android uses its own keyboard, not Phosh's; no clipboard sharing
  (`docs/known-issues.md:213-215`).

### 4.5 Network, camera, identifiers

- Traffic: "TCP to the Internet only, through Tor. UDP (calls, WebRTC, QUIC, many
  games), VPN apps and IPv6 do not work. `.onion` addresses do not work either";
  local network connections "wait for a time-out instead of failing at once";
  "All apps share one Tor identity, separate from the host's and unchanged by Tor
  Browser's "New Identity"; streams are separated per destination only."
  (`docs/known-issues.md:196-207`). Separate Tor listeners for Android:
  `TransPort 10.200.2.1:9041`, `DNSPort 10.200.2.1:5354`
  (`config/rootfs-android/usr/share/antumbra/android/torrc:10-11`). Container
  address 10.200.2.2 by DHCP on bridge `waydroid-tor` (`docs/architecture.md:438-439`).
- VM: a `.onion` ping inside Android: "PING 2gzyxa5ihm7nsggfxnu52rck2vv4rvmdlkiu3zzui5du4xyclen53wid.onion
  (127.226.183.213) 56(84) bytes of data." / "From 127.226.183.213: icmp_seq=1
  Destination Port Unreachable" (`run-f4b/smoke/android-onion-ping.txt`).
- While Tor cannot bootstrap, Android's TCP is accepted by the TransPort but goes
  nowhere and its lookups get no address (`tests/vm/antumbra_vm.py:1808-1810`, `:1814-1816`).
- No camera inside Android; the microphone is available behind Android's own
  prompt (`docs/known-issues.md:211-212`; `docs/camera.md:207-212`).
- Identity Android reports: generic Waydroid values, on the phone model
  "WayDroid arm64 Device" (VM: "WayDroid arm64 only Device")
  (`config/hooks/56-session-android.sh:31-38`). Masked: serial numbers, disk and
  device-mapper UUIDs, partition GUIDs, nvmem/QFPROM, RTC, the host's kernel
  command line; not masked: kernel release, CPU/GPU model, screen size, battery
  capacity (`docs/threat-model.md:89-131`; `docs/known-issues.md:216-225`).
  No host MAC address or Wi-Fi radio in Android's sysfs; its own `eth0` is
  `00:16:3e:f9:d3:03`, shared by every Waydroid installation
  (`run-f4b/smoke.log`; `docs/threat-model.md:92-93`).
- Security caveats to show: "Android is a weaker sandbox than the rest of
  Antumbra and than a stock phone: a privileged container where Android's root
  is the system's root, no SELinux, and binder open to every local user while
  Android runs. Use it only for apps you trust." (`docs/known-issues.md:192-195`).
  No Google apps or Play services; security patches frozen at the image of
  2026-09-27 (`docs/known-issues.md:186-191`).

### 4.6 Freezing, stopping, restarting

- On the phone Waydroid freezes the container whenever Android's display sleeps:
  "an Android app left in the background does not run, and a frozen Android
  answers nothing until an app is opened again"; untested on the phone
  (`docs/known-issues.md:259-265`). Expected: FROZEN after a few minutes with no
  Android app open, back "within seconds" (`docs/hardware-validation.md:314-317`).
- Stopping: `waydroid session stop` (from Console) or logout; the container stops,
  then "Android stopped: Waydroid's container service stopped, its devices
  closed"; within a minute the service is inactive and devices are closed again
  (`docs/architecture.md:985-999`;
  `config/rootfs-android/usr/local/lib/antumbra-waydroid-stopped:29`;
  `docs/hardware-validation.md:264-270`). There is no stop button in any GUI in
  the repo.
- "Android stopped in a session stays stopped until the "Android" launcher
  starts it again." (`docs/known-issues.md:231-232`). VM: "a stopped Android
  stays stopped" for 30 s (`docs/vm-testing.md:342-344`).
- If vold dies under Android's 2-second stack-dump limit, Android reboots, which
  stops the container until the launcher starts it again; phone timeouts
  untested (`docs/known-issues.md:248-258`).
- Cost: roughly 1 to 1.5 GB RAM while Android runs (estimate), "tight next to Tor
  Browser on the 8 GB model" (`docs/known-issues.md:233-238`).

---

## 5. Persistent Storage

### 5.1 Welcome screen

- Group "Persistent Storage", description "Encrypted storage that survives
  shutdown. Everything else is forgotten." Combo "Persistent Storage" with
  "Do not use (amnesic session)" and either "Unlock" (a LUKS volume exists) or
  "Create (erases the data partition)" (none). Rows "Persistent Storage
  passphrase" and "Repeat passphrase" (hidden when unlocking), insensitive for
  "Do not use" (`antumbra-welcome:79-100`, `:174-177`).
- The volume's presence is probed at boot (`antumbra-persistence status`,
  `config/rootfs/usr/lib/systemd/system/antumbra-persistence-probe.service:10`).
- Errors at Start: "The Persistent Storage passphrase needs at least 12
  characters.", "The Persistent Storage passphrases differ.", "Enter the
  Persistent Storage passphrase, or choose not to use it." (`antumbra-welcome:189-195`).
- While applying, the Start button reads "Applying settings…" and is
  insensitive (`antumbra-welcome:222-223`); on error the message appears under
  the form and the button reads "Start Antumbra" again (`:253-256`).

### 5.2 Create

- `luksFormat --type luks2 --label AntumbraData --pbkdf argon2id --pbkdf-memory
  1048576 --pbkdf-force-iterations 4`, then ext4, then every feature directory
  except those marked `off`; prints "Persistent Storage created"; then unlock and
  activate (`config/rootfs/usr/local/sbin/antumbra-persistence:50-73`;
  `antumbra-apply-welcome-settings:157-164`).
- Features, in mount order (`config/rootfs/etc/antumbra/persistence-features.conf:10-14`):

| Feature | On the volume | Mounted at |
|---|---|---|
| Persistent folder | `Persistent` | `/home/amnesia/Persistent` |
| Welcome settings | `welcome-settings` | `/var/lib/antumbra/settings/persistent` |
| Network connections | `nm-system-connections` | `/etc/NetworkManager/system-connections` |
| GnuPG | `gnupg` | `/home/amnesia/.gnupg` |
| SSH client | `ssh` | `/home/amnesia/.ssh` |
| Android (off until chosen) | `waydroid` | `/home/amnesia/.local/share/waydroid` |

  VM journal lines: "feature persistent-folder: /home/amnesia/Persistent",
  "feature welcome-settings: /var/lib/antumbra/settings/persistent", "feature
  network-connections: /etc/NetworkManager/system-connections", "feature gnupg:
  /home/amnesia/.gnupg", "feature ssh-client: /home/amnesia/.ssh"
  (`run-f3a/serial.log:1525-1539`).
- The user sees no feature chooser: there is no Persistent Storage settings app
  in the repo; the features are fixed.

### 5.3 Unlock on the next boot; wrong passphrase

- Choose "Unlock", type the passphrase, Start. Journal "Persistent Storage
  unlocked", then the feature lines (`antumbra-persistence:75-89`;
  `run-f3b/serial.log:1484-1505`).
- Wrong passphrase: the Welcome screen shows exactly "wrong passphrase, or
  Persistent Storage is damaged" and lets you start again; the volume is locked
  again first (`antumbra-apply-welcome-settings:168`, `:69-84`;
  `run-f3b/smoke.log:31`; `docs/hardware-validation.md:98-101`).
- Other failure texts the Welcome screen can show (`antumbra-apply-welcome-settings`):
  "creating Persistent Storage failed" (`:160`), "unlocking the new Persistent
  Storage failed" (`:161`), "activating Persistent Storage failed" (`:162`,
  `:169`), "Persistent Storage is still open from a failed attempt; restart to
  start without it" (`:177`), "unexpected error (line N, exit status S)" (`:85`;
  VM example "unexpected error (line 208, exit status 1)", `run-f3b/smoke.log:29`),
  with "; Persistent Storage could not be locked again" appended when locking
  fails (`:75-78`); from the Welcome screen itself "timed out waiting for the
  settings to be applied" and "settings could not be applied" (`settings.py:131-133`).
- Started without Persistent Storage after a wrong attempt, the session is
  amnesic and the volume is not open (`docs/hardware-validation.md:99-101`).

### 5.4 What is kept and what is forgotten

- Kept: the five folders above (and Android's data with the switch). Wi-Fi
  profiles persist (`docs/hardware-validation.md:93-95`). The volume also keeps
  this boot's Welcome choices except the screen-lock passphrase hash
  (`antumbra-apply-welcome-settings:41-45`), but "The Welcome screen does not show
  the settings saved in Persistent Storage … every question, bridges included, is
  answered again at each boot." (`docs/known-issues.md:91-95`).
- Forgotten at every restart: everything else in RAM, including Tor Browser
  bookmarks, Electrum wallets (`~/.electrum`) and APT-installed software
  (`docs/known-issues.md:102-104`; `docs/architecture.md:1019-1026`); Dotfiles
  keeps nothing yet (`docs/architecture.md:1026-1029`).
- OS updates (full re-flash) erase the volume (`docs/known-issues.md:100-101`).

### 5.5 "Keep Android apps and data"

- Needs Android on and Persistent Storage in use; creates the `android` feature
  the first time ("feature android: created"), mounts it only in sessions with
  both switches on; keeps Android's own usage history too; turning it off later
  does not delete what is stored (`docs/architecture.md:1011-1017`;
  `docs/known-issues.md:239-242`; `antumbra-persistence:91-105`;
  `antumbra-apply-welcome-settings:148-155`).
- With it, F-Droid is not reinstalled ("F-Droid is already installed",
  `antumbra-fdroid-install:21-24`). Without it, "Every session sets Android up
  again" and F-Droid is installed again (`docs/known-issues.md:243-247`).
- Test flow from the docs: install an app, reboot, unlock with the switch on and
  find it; unlock with it off and get a fresh Android
  (`docs/hardware-validation.md:271-273`).

---

## 6. Screen lock

- Welcome group "Security", description "A passphrase locks the screen. Without
  one, anyone who picks up the phone can use the session."; rows "Screen-lock
  passphrase (recommended)" and "Repeat passphrase" (`antumbra-welcome:122-128`).
  Errors: "The screen-lock passphrases differ.", "The screen-lock passphrase
  needs at least 6 characters." (`:204-207`).
- Set with `chpasswd -e` for `amnesia`; with none, the password is deleted and
  the journal says "no passphrase: screen lock is not protective, administration
  disabled" (`antumbra-apply-welcome-settings:197-210`; VM
  `run-f4b/serial.log:1681`). "Screen lock without a passphrase is not
  protective; the Welcome screen says so but does not force one."
  (`docs/known-issues.md:121-122`).
- Phosh's lock screen authenticates through PAM with that passphrase
  (`docs/architecture.md:761-764`). Lock screen shows no notification content
  and no plugins (`config/rootfs/etc/dconf/db/local.d/10-antumbra-shell:11-20`,
  locked in `locks/10-antumbra-shell:1-3`).
- When it locks: after 120 s idle (`idle-delay=uint32 120`), at once when the
  screen blanks (`lock-enabled=true`, `lock-delay=uint32 0`)
  (`00-antumbra:12-17`), and on a short power-key press (section 7). Locking
  arms the 18 h auto-shutdown timer; unlocking disarms it
  (`config/rootfs/usr/local/lib/antumbra-lock-watch:3-5`, `:16-26`). VM journal on
  lock: "Started antumbra-auto-shutdown.timer - Power off after being locked for
  too long." (`run-f1/serial.log:6439`).
- The passphrase is asked at every boot and never stored on the volume
  (`docs/architecture.md:746-749`).
- Fingerprint unlock "will never work on mainline" (`docs/known-issues.md:48`).

---

## 7. Power key, shutdown, restart, memory wiping

- Power key (`config/rootfs/usr/lib/systemd/logind.conf.d/antumbra.conf:1-5`):
  short press is ignored by logind ("the shell handles the screen"), long press
  (5 s) is an orderly power-off. VM: a short press logs "Power key pressed
  short." and Phosh turns the display off and the session locks
  (`run-f1/serial.log:6421`, `:6431`, `:6439`); "a short press does not shut the
  system down" (VM check, `docs/vm-testing.md:164-165`). Long press: "powers off
  within about 5 seconds" (`docs/hardware-validation.md:48`).
- Other ways: Phosh's power menu; the auto-shutdown timer after 18 h locked,
  also from suspend (`docs/architecture.md:265`). Phosh's power menu texts are not
  in the repo (the quick-settings screenshot shows a power icon at top right,
  `run-f1/smoke/tour-quick-settings.png`).
- Suspend is allowed and keeps keys in RAM (`docs/architecture.md:266`; see
  section 11, item 2). The threat model assumes you "shut it down, rather than
  suspend it, when that matters" (`docs/threat-model.md:163-164`).
- Memory wiping (Tails' design, `docs/architecture.md:255-268`):
  `init_on_free=1 init_on_alloc=1`; late in shutdown the overlay's `rw`/`work`
  directories are removed (`antumbra-remove-overlayfs-dirs.service:14`); systemd
  returns into an unpacked copy of the initramfs, which unmounts the old root
  and the medium, removes the verity device, detaches loops and drops caches.
  Its lines (debug console): "antumbra-shutdown: oldroot unmounted",
  "antumbra-shutdown: medium unmounted", "antumbra-shutdown: verity removed",
  "antumbra-shutdown: loops detached", "antumbra-shutdown: caches dropped"
  (`config/rootfs/usr/local/lib/initramfs-pre-shutdown-hook:8-29`), then
  "Powering off." (`run-f1/serial.log:7301`). The VM shows the guest "wrote not
  one block to its disk" without Persistent Storage (`docs/vm-testing.md:168-170`).
- The pop-up camera retracts before power-off and reboot (section 3.3); Android's
  container stops before the overlay is emptied
  (`config/rootfs-android/etc/systemd/system/waydroid-container.service.d/antumbra.conf:11-14`).
- What the phone's screen shows during shutdown is not recorded: release builds
  boot with `quiet` (`device/oneplus-hotdog/cmdline.txt:1`) and have no splash
  package; only debug builds show the hook's output on the console
  (`docs/hardware-validation.md:85-87`).
- Restart takes the same path (the reboot notifier retracts the camera:
  `0102-…patch:43-46`); then the orange "device has been unlocked and can't be
  trusted" screen at every boot is expected (`docs/flashing.md:12-14`; Welcome
  note "The bootloader is unlocked: an attacker with the phone in hand can
  replace the system. The orange warning at boot is expected.",
  `antumbra-welcome:153`).
- Logout: greetd shows the Welcome screen again; settings cannot change, the
  button reads "Start a new session" (`docs/architecture.md:757-759`;
  `antumbra-welcome:168-172`).
- Forced reset (power + volume up) skips the orderly shutdown and is not
  defended (`docs/architecture.md:664-668`; `docs/threat-model.md:31`).

---

## 8. Administration, sudo, Console

- Welcome switch "Administration (sudo) with that passphrase", subtitle "Off by
  default, as in Tails" (`antumbra-welcome:129-131`); "Administration needs a
  passphrase." if on without a screen-lock passphrase (`:209-210`).
- On: `/etc/sudoers.d/antumbra-admin` = `amnesia ALL = (ALL) ALL` and a polkit
  admin rule; journal "administration enabled"
  (`antumbra-apply-welcome-settings:201-206`). sudo asks every time
  (`Defaults timestamp_timeout=0`, `config/rootfs/etc/sudoers.d/always-ask-password:1`).
- Off: no rule; the only sudo rule left is the NOPASSWD Tor Browser launcher
  (`sudoers.d/antumbra-tor-browser:4`). sudo's own prompts and refusal texts are
  not in the repo.
- Console: GNOME Console, launcher name "Console", `Exec=kgx`, in the dock
  (`build/work/qemu-virt/rootfs/usr/share/applications/org.gnome.Console.desktop`;
  `00-antumbra:28`). User `amnesia` (UID 1000), hostname `amnesia`
  (`build/work/qemu-virt/rootfs/etc/hostname`), Debian's default prompt
  `\u@\h:\w\$` (`build/work/qemu-virt/rootfs/etc/skel/.bashrc:60-62`), so
  `amnesia@amnesia:~$`.
- Useful root commands for a simulated Console: `antumbra-tor-connect
  direct|bridges FILE|-|status|disconnect` (section 1.1),
  `cat /run/antumbra/selfcheck.status` (one "<check> OK|FAIL[: detail]" line per
  check, `antumbra-selfcheck:2-6`; VM early lines "firewall OK | firewall-android
  OK | android-bridge OK | lxc-net OK | binder OK | android-off OK | resolver OK |
  ipv6-disabled OK | sysctl OK | overlay-root OK | swap OK | flash-writes OK |
  init-on-free OK | pstore OK | radios OK | usb-gadget OK | usbguard OK |
  modemmanager OK | qrtr-access OK", `run-f4b/smoke.log`), `antumbra-persistence
  status|lock` (`antumbra-persistence:7-14`). USB devices other than hubs need
  `usbguard allow-device` (`docs/architecture.md:627-635`).

---

## 9. Known issues the simulator must tell the user

From `docs/known-issues.md` unless noted.

Camera
- Front camera single 1748x1748 mode; software ISP; no flash, touch focus;
  video untested; a CAMSS failure can need a reboot (`:23-30`).
- No drop protection; do not walk with it open or push it down (`:33-39`).
- Indicator for the front camera only, not a boundary against root, can lag
  around suspend; rear cameras have no indicator (`:40-43`).
- Motor thresholds from one unit; the safety patch has not run on hardware
  (`:44-47`).
- The camera prompt does not protect against installed programs; Tor Browser can
  use the cameras without a prompt (`:56-67`).

Android
- Android 13, no Google apps, patches frozen at 2026-09-27 (`:186-191`).
- Weaker sandbox (`:192-195`); TCP-only through Tor, no UDP/VPN/IPv6/.onion
  (`:196-207`); no cameras (`:211-212`); Android keyboard, no clipboard sharing
  (`:213-215`); fingerprintable kernel/CPU/GPU (`:216-225`).
- Refuses to start without its Tor-only network (`:226-232`); RAM cost
  (`:233-238`); amnesic unless kept (`:239-242`); slow first start, unmeasured
  on the phone, ~15 min in the VM (`:243-247`); freezing (`:259-265`); none of
  it has run on the phone (`:183-184`).

Bridges and Tor
- No Tor Connection assistant, QR or Moat; bridges re-entered at every boot
  (`:72-77`, `:89-90`).
- IPv4 only for plain/obfs; snowflake refused; "No bridge of any type has
  connected through Antumbra yet, in the VM or on the phone" (`:78-90`).
- Tor Browser is an alpha with no AppArmor profile (`:52-55`); no Unsafe Browser
  (`:70-71`); htpdate needs Tor first (`:118-120`).

Other
- Nothing has booted on a physical phone (`:6-12`).
- 90 Hz off; earpiece/headset audio missing; charging from USB hosts may be
  limited; Bluetooth off with no opt-in; no sensors or auto-rotation;
  fingerprint never (`:16-22`, `:31-32`, `:48`).
- Welcome screen does not read back stored settings (`:91-95`); Persistent
  Storage passphrase passed through a RAM file (`:96-99`); bind mounts without
  `nosymfollow`; updates erase the volume (`:100-101`).
- Screen lock without a passphrase is not protective (`:121-122`).
- Files searches names only (`:123-125`).
- Interface limits of the Phosh theme (`:127-177`).

---

## 10. Where the repo is silent (do not invent; show as unknown)

- Any timing on the phone except: long-press ~5 s, motor course bounds
  (~668 ms nominal, cap ~718 ms), first boot "can take a minute", Android
  launcher's "a minute or two", "seconds" for Android's unlock and F-Droid's
  compile, freeze/thaw expectations. Tor bootstrap time, htpdate time,
  Persistent Storage create/unlock time, Android boot, shutdown duration: unknown.
- A successful Tor bootstrap past 14 % in Antumbra (never happened in the VM;
  not yet on the phone).
- Tor Browser's behaviour when Tor is not bootstrapped; Snapshot's no-camera
  screen text; Phosh's lock-screen, power-menu and Wi-Fi texts; sudo's prompts;
  what the screen shows during shutdown on a release build.
- How a user stops Android from the GUI (only `waydroid session stop` and
  logout are documented).
- Whether the phone's RTC gives a usable clock before htpdate.

---

## 11. Discrepancies found (decide which to simulate; the screenshot or code is the real behaviour)

1. Camera prompt buttons: the real dialog shows "Cancel" and "Ok"
   (`run-f1/smoke/camera-portal-prompt.png`); the docs call them "Allow"/"Deny"
   (`docs/vm-testing.md:193`; `docs/hardware-validation.md:192-193`). Simulate
   "Cancel"/"Ok".
2. `docs/architecture.md:266` says "the Welcome screen warns that suspend keeps
   keys in RAM", but `antumbra-welcome` contains no such text (its notes are
   `:150-157`). Do not show a suspend warning on the Welcome screen.
3. `docs/hardware-validation.md:67` says `curl http://1.1.1.1` as `amnesia`
   fails, yet `nftables.conf:173-175` (like Tails' ferm.conf) redirects the
   user's TCP to Tor's TransPort; with Tor bootstrapped such a request would go
   through Tor. The repo does not reconcile this.
4. `config/rootfs/usr/share/antumbra/tor-browser-user.js:45-47` suppresses the
   display-language notification, but the VM screenshot shows it
   (`run-f1/smoke/tour-tor-browser.png`). Simulate what the screenshot shows.
5. `docs/tails-porting-map.md:24` says the MAC-spoofing failure goes to "a state
   file the shell reads"; nothing in the shell reads it, only
   `antumbra-selfcheck --late` (`:173`). No notification is shown.
6. Tor in the image logs "This version of Tor was built without support for
   sandboxing" although torrc sets `Sandbox 1` (`run-f1/serial.log:992`;
   `torrc:35`). Informational only.
