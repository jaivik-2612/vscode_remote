# The Antumbra module

The Magisk module `antumbra` is the part of Antumbra that runs as root on
the phone (stage 1 of the design: official LineageOS 23.2 plus Magisk). It
starts the firewall before Android, starts tor and the DNS filter as their
own unprivileged users, keeps Wi-Fi's saved networks and the DHCP lease
memory in RAM, sets fail-safe Android settings, and switches tor's network
on only after the Welcome screen's Start, the way the person chose there.
It follows the shared contract (`antumbra/android/docs`); the module ID is
`antumbra`, installed at `/data/adb/modules/antumbra`.

The format is also KernelSU's (same scripts, `customize.sh`, `system/`
folder). It has not been run under KernelSU.

| File | What it is |
|---|---|
| `module.prop` | Magisk's metadata. No `updateJson`: updates are installed by hand (or later by Welcome after a signature check), never fetched by Magisk. |
| `customize.sh` | Install-time checks and set-up. |
| `post-fs-data.sh` | Boot, before zygote: arm the firewall, RAM directories, sysctls. |
| `service.sh` | Boot, late: the filter, tor, the full firewall, Settings, Welcome's Start, and supervision until shutdown. |
| `uninstall.sh` | Puts the Settings back. |
| `lib/antumbra.sh` | Functions shared by the three boot scripts. |
| `lib/torctl.sh` | Talks to tor's control socket, as uid 2950. |
| `lib/settings.conf` | The Settings.Global values and the reason for each. |
| `lib/emu-install.sh` | Installs the module on the CI emulator as Magisk would. |
| `helper/antumbra-run.c` | Starts a program as another uid with no capabilities. |
| `overlay/` | A static resource overlay that switches keepalive offload off. |
| `META-INF/` | Recovery stub; the Magisk app replaces it. |
| `build-module.sh` | Builds the zip, or installs on a running emulator. |
| `tests/` | Unit tests, an end-to-end sandbox test and its stand-ins. |

## What runs when

### Installation (`customize.sh`)

Magisk's (or KernelSU's) installer unpacks the zip into the module
directory and sources `customize.sh`, which:

1. maps the CPU to `arm64-v8a` (the phone) or `x86_64` (the emulator) and
   refuses anything else;
2. requires API 36 (Android 16);
3. requires the OnePlus 7T Pro (`ro.product.device`, `ro.lineage.device`
   or `ro.product.vendor.device` is `hotdog`) running LineageOS
   (`ro.lineage.version`), or the Android emulator (`ro.boot.qemu=1`,
   `ro.kernel.qemu=1` or `ro.hardware=ranchu`);
4. checks every file against `SHA256SUMS`;
5. keeps `bin/<abi>/*` for this CPU in `bin/` and deletes both ABI folders;
6. sets owner root and modes 0644/0755 (programs 0755), label `system_file`;
7. records the current values of the keys in `lib/settings.conf` in
   `settings.orig` (0600), or carries over the record of the installed
   version on an update.

Checks 2 and 3 can be overridden with `ANTUMBRA_FORCE=1` in the installer's
environment (for example `ANTUMBRA_FORCE=1 magisk --install-module zip`
from a root shell) or by creating `/data/adb/antumbra-force` as root. The
boot order and the firewall have not been checked on other devices.

**Installing the module forgets every saved Wi-Fi network** at the next
start (see below).

### Boot, post-fs-data (`post-fs-data.sh`, blocking)

Magisk runs this at init's `post-fs-data` trigger and holds the boot until
it ends (at most 40 s). `/data` is mounted and decrypted; init's own
`post-fs-data` block has already run (it creates
`/data/misc/apexdata/<apex>` in `perform_apex_config`); netd, zygote and
everything that uses the network start after it. It takes well under a
second (measured in the sandbox test).

1. **`antumbra-fw arm`**, the first command. Only loopback traffic moves,
   IPv4 and IPv6, for every uid. The firewall's lock goes in
   `/dev/antumbra-fw` (RAM), because the runtime tmpfs does not exist yet.
2. **The runtime directory**: a new tmpfs (128 MB limit, `nosuid,nodev,
   noexec`) over `/data/adb/antumbra`, laid out as in the table below.
   `/data/adb` gets mode 0711 (Magisk sets 0700 at every boot), so that
   uids 2950 and 2951 can pass through it; SELinux keeps apps out anyway.
3. **Wi-Fi's configuration store** `/data/misc/apexdata/com.android.wifi`
   (and user 0's `/data/misc_de/0/apexdata/com.android.wifi`): whatever is
   on flash is deleted, then a tmpfs is mounted over it with the
   directory's owner, mode and SELinux label (`apex_system_server_data_file`
   on LineageOS 23.2). New files inherit that label; SELinux allows any
   file type on a tmpfs (`allow file_type tmpfs:filesystem associate`).
   Saved networks therefore never reach flash, and a boot without the
   module has no network to join.
4. **NetworkStack's IpMemoryStore**: `IpMemoryStoreV2.db` (earlier
   `IpMemoryStore.db`) in
   `/data/user_de/0/com.android.networkstack/databases` (NetworkStack is
   direct-boot aware and keeps its data in device-encrypted storage;
   Android 16 source). The database is deleted and the directory put on a
   tmpfs, with its owner (1073) and label. Without it, Android asks the
   router for the previous session's IP address (DHCP INIT-REBOOT) and
   links a new MAC address to the old one. The Google and in-process
   package names are covered too.
5. **sysctls**: `accept_ra=0` and `disable_ipv6=1` for `all`, `default`
   and every interface but `lo` (Android uses `::1`). Qualcomm's crash-dump
   mode off: `download_mode=0` in `/sys/module/msm_poweroff/parameters`
   (the hotdog kernel has `CONFIG_QCOM_DLOAD_MODE=y`).

Problems are written to `state/module/problem` and shown in `status.json`.

### Boot, late (`service.sh`, runs until shutdown)

Magisk starts it without waiting, while Android finishes booting.

1. **The DNS filter** as uid/gid 2951, first, so that it holds
   `127.0.0.1:5353` before Android's mDNS can bind that port.
2. **tor** as uid/gid 2950 with `etc/torrc` (rendered from
   `tor/torrc.in`), `DisableNetwork 1`.
3. **`antumbra-fw apply`**, then `antumbra-fw status`: only if the status
   is live and its hash equals the one `apply` printed does the module run
   `resetprop -n antumbra.fw.armed <first 16 hex digits>`. On failure the
   firewall is back in the armed state and the property is removed.
4. **`run/status.json`** (below).
5. **IPv6 guard**: NetworkStack switches IPv6 back on for every network it
   brings up. A background loop switches it off again on every interface
   whenever `ip monitor` reports a link or address change, and every 10
   seconds in any case.
6. Once boot has completed and the settings provider answers: **the
   Settings.Global values in `lib/settings.conf`**, and
   `cmd wifi set-scan-always-available disabled`.
7. **Welcome's Start**: every 2 seconds,
   `content query --user 0 --uri content://org.antumbra.welcome.state/session
   --projection started:tor_mode:mac:session_id`. The first row with
   `started=1` and valid values is kept for the rest of the boot (if
   Welcome's process dies it starts a new, unstarted session, which is
   ignored). For `tor_mode=bridges`, a second query
   (`--projection session_id:bridges`) reads the bridge lines; the session
   ID in front shows they belong to the same session. Then:
   - `offline`: tor's network stays off;
   - `direct`: `SETCONF DisableNetwork=0`;
   - `bridges`: the lines are checked (the same rules as Welcome's
     `Bridges.kt`) and sent in one `SETCONF UseBridges=1 Bridge="…" …
     DisableNetwork=0`, which tor applies whole or not at all. Lines with
     a pluggable transport also set `ClientTransportPlugin` to
     `bin/lyrebird`; without lyrebird in the module they are refused.
   - `mac=keep`: `non_persistent_mac_randomization_force_enabled=0` (the
     boot default is 1: a new MAC address for every connection).

   The network is switched on only while the firewall is live.
8. **Supervision**, every 2 seconds while something changes, else every 5:
   the filter and tor are restarted if they stop (pause doubling from 2 to
   64 s), and a restarted tor gets the session's choice again; the
   firewall is checked every 30 seconds with `status`, and if it is not
   live the property is removed at once and `apply` runs again; tor's
   bootstrap progress is asked while it connects; `status.json` is
   rewritten when something changed, and at least once a minute.

### Removal (`uninstall.sh`)

Magisk runs it early in the boot after the module was marked for removal
(the module's other scripts do not run in that boot, and system_server
does not exist yet), or at once when Magisk itself is uninstalled. It
copies `settings.orig` to `/data/adb/antumbra-restore.conf` and writes the
one-time script `/data/adb/service.d/antumbra-restore.sh`, which waits
for boot to complete, puts each value back (`null` = delete the key), and
deletes itself and its data. While Android runs, the script is run at
once. Saved Wi-Fi networks are not restored: there are none on flash.

## Files on the phone

Everything under `/data/adb/antumbra` is on a tmpfs: it disappears at
power-off.

| Path | Owner, mode | Content |
|---|---|---|
| `/data/adb/antumbra` | root, 0711 | tmpfs |
| `run/` | 2950:2950, 0751 | tor's control socket and cookie; `status.json` (0644) |
| `state/` | root, 0711 | `fw-exempt.conf`, `fw-relays.conf` (not written in v0) |
| `state/tor/` | 2950:2950, 0700 | tor's DataDirectory |
| `state/module/` | root, 0700 | process IDs, the session's bridges, the firewall's lock and hash (`fw/`) |
| `lists/` | root, 0755 | updated block list and DoH list (none in v0: the module's copies in `MODDIR/lists` are used) |
| `log/` | root, 0755 | `module.log`, `firewall.log`, `dnsfilter.log`, `tor.stderr`, `tor.log` (2950, 0600) |

Logs never contain bridge lines or addresses.

### status.json

Written for display: the filter serves it under `"module"` on
`http://127.0.0.1:5380/status`, and Welcome shows `firewall.state`,
`firewall.hash`, `tor.bootstrap`, `tor.summary` and `tor.network`.

```json
{"schema":1,
 "module":{"version":"0.1.0","updated":"2026-10-11T07:51:51Z","problem":null},
 "firewall":{"state":"live","hash":"9a4d326ea2eee9bf"},
 "tor":{"running":true,"mode":"bridges","network":"enabled","bootstrap":5,
        "summary":"Connecting to a relay","error":null},
 "dnsfilter":{"running":true},
 "welcome":{"started":true,"session_id":"0123456789abcdef0123456789abcdef"}}
```

`firewall.state` is `armed` (before the first apply), `live` or `failed`;
`tor.mode` is `pending` (before Start), `direct`, `bridges` or `offline`;
`tor.network` is `enabled` or `disabled`; `tor.error` says why a session's
bridges were refused. tor's uid can rewrite this file, so nothing may base
a decision on it: the firewall's word is the property `antumbra.fw.armed`,
which only root can set.

## Trust and privileges

- **tor owns `run/`.** tor refuses a control socket in a directory it does
  not own. A root process must therefore never open, write or follow a
  path in `run/`: tor could have replaced it with a symbolic link to any
  file. The module reads the control cookie, talks to the socket and
  writes `status.json` through processes running as uid 2950 itself.
- **The firewall's own files** (its lock and the recorded hash, by default
  in `$ANTUMBRA_DIR/run`) are kept in `state/module/fw` instead, by calling
  `antumbra-fw` with `ANTUMBRA_DIR=/data/adb/antumbra/state/module/fw` and
  the three input files named explicitly (`ANTUMBRA_FW_EXEMPT`,
  `ANTUMBRA_FW_RELAYS`, `ANTUMBRA_FW_DOH`). Run by hand,
  `ANTUMBRA_DIR=/data/adb/antumbra/state/module/fw antumbra-fw status`
  shows the live state.
- **tor and the filter** run with every capability gone (permitted,
  effective, inheritable, ambient and the bounding set), locked
  securebits, `no_new_privs`, no file descriptors but 0-2, a clean
  environment, their own session, and supplementary group 3003 (`inet`,
  which kernels with Android's old "paranoid network" check require). The
  filter refuses to run otherwise.
- **SELinux**: both run in Magisk's `magisk` domain, which Magisk
  describes as effectively permissive. See the gaps below.

## Decisions

### Starting programs as uid 2950 and 2951: `antumbra-run`

The options were Magisk's busybox `setuidgid`, toybox `setpriv`, Magisk's
`su`, or a small helper. Android 16's toybox (0.8.12, AOSP
`android16-release`) has no `setpriv` or `setuidgid`; busybox's
`setuidgid` exists only under Magisk and does not empty the bounding set
or set `no_new_privs`; Magisk's `su` exists only under Magisk and since
v30.7 keeps every capability unless `--drop-cap` is given. None works on
the CI emulator, which has no Magisk. `helper/antumbra-run.c` (about 370
lines of C, built with the NDK for API 34) does the same thing everywhere,
checks the result before it runs the program, and is tested on the host
(see Tests).

### Talking to tor: POSIX sh with toybox `nc -U`

Android 16's toybox netcat connects to Unix sockets (`-U`; checked in AOSP
`external/toybox` at `android16-release`). After the end of its input it
half-closes the connection and reads until tor closes it (`-q 10` bounds
the wait, `timeout 20` the whole call). `lib/torctl.sh` sends
`AUTHENTICATE <cookie hex>`, the commands, and `QUIT`; if authentication
fails, tor answers 515 and closes, so no command runs. No Go helper was
needed.

### `restricted_networking_mode`: on LineageOS only

Checked in the sources: netd's eBPF program returns PASS for every uid
whose app ID is below 10000 before it looks at any firewall chain
(`is_system_uid()` in Android 16's `bpf/progs/netd.c`), so tor (2950), the
filter (2951), root and the system are never affected. On LineageOS 23.2,
`NetworkPolicyManagerService` gives every uid restricted-mode access
unless its policy has `POLICY_REJECT_ALL`, which is what each app's
"Network access" switch sets: the mode enforces those switches, which
Welcome uses for apps that need no network (design layer L3). On plain
Android (the CI emulator) the same mode blocks every app without a
privileged permission, including loopback traffic to tor's TransPort (only
the background chain exempts `lo`), so the module sets it on LineageOS
only. It adds little when the module is absent: apps whose switch is on
still go online.

### No `sepolicy.rule`

Nothing the module does needs a policy change: its scripts and the
programs they start run in Magisk's `magisk` domain, and Welcome (an
`untrusted_app`, which is a `coredomain`) may read the `default_prop`
label that `antumbra.fw.armed` gets (`get_prop(coredomain, default_prop)`
in AOSP Android 16 and LineageOS 23.2 `private/coredomain.te`, marked as a
TODO to remove upstream). A confining domain for tor and the filter is
later work (gaps).

### Keepalive offload off: a static overlay

An app can ask Android for NAT-T or TCP keepalives that the Wi-Fi firmware
then sends by itself, from the real address, below iptables. The overlay
`system/product/overlay/AntumbraConnectivity.apk` targets
`com.android.connectivity.resources` (overlayable group
`ServiceConnectivityResourcesConfig`, policy product/system/vendor) and
sets `config_networkSupportedKeepaliveCount` to `0,0` and `1,0` (no
offload slots on cellular or Wi-Fi; AOSP's default is 1 and 3, and the
hotdog tree does not change it). `KeepaliveResourceUtil` accepts 0, so
every request fails with `ERROR_UNSUPPORTED`. An app cannot replace a
static overlay with an update.

## Building

```sh
antumbra/android/module/build-module.sh \
    --tor TOR_OUT --dnsfilter DNSFILTER_OUT --blocklist LISTS_OUT/dnsfilter.list \
    [--abi arm64-v8a|x86_64|all] [--version V] [--out FILE] [--stage DIR] \
    [--lyrebird DIR] [--overlay-keystore FILE] [--no-overlay]
```

The inputs are the other parts' outputs: `build-tor.sh --out TOR_OUT`
(`TOR_OUT/<abi>/tor`), `dnsfilter/build.sh --out DNSFILTER_OUT`
(`DNSFILTER_OUT/<abi>/antumbra-dnsfilter`) and `fetch-lists.sh --out
LISTS_OUT` (`dnsfilter.list`, and `doh-ipv4.txt` next to it, which is
used when present). The firewall script is taken from
`../firewall/antumbra-fw` and the torrc rendered from `../tor/torrc.in`.
It needs the NDK (`ndk;28.2.13676358`, for `antumbra-run`), and for the
overlay `build-tools;36.0.0`, `platforms;android-36` and Java's `keytool`.
When the host can run it, the x86_64 filter checks the block list
(`-check-list`).

The zip holds no third-party source; `NOTICE` names the licences of the
binaries and lists inside. File times are `SOURCE_DATE_EPOCH` (else the
last commit of this folder), files are sorted and zip metadata is left
out. The overlay is signed with a new RSA key at every build unless
`--overlay-keystore` is given (PKCS#12, alias `antumbra`, password in
`$ANTUMBRA_OVERLAY_KS_PASS`); with a fixed key the zip is reproducible.

### The CI emulator (`--emulator`)

```sh
build-module.sh --emulator --tor TOR_OUT --dnsfilter DNSFILTER_OUT \
    --blocklist LISTS_OUT/dnsfilter.list [--serial emulator-5554] [--no-restart]
```

Google's `default` system image has no Magisk but gives a root shell with
`adb root`. This mode builds for the emulator's ABI and then does by hand
what Magisk would do at boot, in the same order:

1. `adb root`; push the module tree; `lib/emu-install.sh` installs it as
   Magisk's installer would (it prepares `/data/adb/modules_update/antumbra`,
   sources `customize.sh` with the same functions and variables, then
   moves it to `/data/adb/modules/antumbra`);
2. `stop` (toolbox: zygote, system_server, netd, …), `post-fs-data.sh`,
   `start`: netd and the framework start again after the firewall is armed
   and over the tmpfs stores, as on a real boot (`--no-restart` skips this
   and only runs `post-fs-data.sh`);
3. `setsid sh service.sh &`, detached from adb. Without resetprop the
   property is set with `setprop`; adb's root shell runs in the `su`
   domain, which is permissive on debug builds, so init accepts it;
4. waits up to 3 minutes for `antumbra.fw.armed` and prints the module log
   and `antumbra-fw status`.

Installing Welcome and making it the device owner is the CI job's part.

## Tests

All shell is POSIX sh and is checked with `shellcheck -s sh`:

```sh
cd antumbra/android/module
shellcheck -s sh -x *.sh lib/*.sh tests/*.sh tests/fakes/* META-INF/com/google/android/update-binary
```

**`tests/unit.sh`** (no root): bridge-line checks (27 cases), IPv4
addresses, provider-row parsing, control-reply parsing, JSON helpers and
the Settings list, under `sh`, dash, busybox and mksh (`MKSH=` names
Android's).

**`tests/e2e-host.sh`** (root, Linux): the module's real scripts with the
real firewall, tor, DNS filter and `antumbra-run`, without Android. Each
scenario gets mount, network and PID namespaces and a chroot into an
overlay of the host whose upper layer holds `/system/bin` (Android 16's
toybox and mksh built for the host, the host's `iptables-legacy` and `ip`,
and the stand-ins in `tests/fakes` for `getprop`, `setprop`, `resetprop`,
`settings`, `cmd` and `content`), a Wi-Fi store and a lease database "on
flash", and the staged module. It installs the module through
`emu-install.sh` (so `customize.sh` runs), then runs `post-fs-data.sh` and
`service.sh` and checks, among other things: the arm set and that root
cannot send while armed; the runtime tmpfs, owners and modes; the Wi-Fi
and lease stores on tmpfs and their flash copies deleted; the property
equal to the live hash and published only through `resetprop -n`; tor and
the filter with their uids, no capabilities, `no_new_privs` and group
3003; `status.json` and the filter's status page as an app sees them; an
app's DNS for a tracker answered NXDOMAIN through the firewall's redirect,
and other DNS failing closed while tor is offline; other UDP refused; no
Settings before the framework is up, all of them after; and per scenario:

| Scenario | Shell | Checks |
|---|---|---|
| `bridges` | busybox, standalone | plain bridges and the network reach tor (`GETCONF`); MAC "keep"; no bridge line in the log; a restarted Welcome is ignored; tor killed → restarted with the session; filter killed → restarted and blocking; firewall rule deleted → reloaded and property re-published |
| `direct` | mksh, LineageOS hotdog properties | network on without bridges; `restricted_networking_mode=1` |
| `offline` | mksh | network stays off; `uninstall.sh` during boot leaves the restore script, which puts the Settings back and deletes itself |
| `pt` | busybox | obfs4 without lyrebird: refused, network off, reason in status |
| `badbridges` | mksh | a quote in a bridge line: refused, network off |

```sh
sudo tests/e2e-host.sh --tor-bin WORK/x86_64/tor-hostcheck \
    --dnsfilter-bin DNSFILTER_OUT/x86_64/antumbra-dnsfilter --blocklist LISTS_OUT/dnsfilter.list \
    --toybox TOYBOX --mksh MKSH --busybox BUSYBOX
```

`tor-hostcheck` is the static copy `build-tor.sh` leaves in its work
directory. Toybox and mksh are built from AOSP `external/toybox` and
`external/mksh` at `android16-release` (`make defconfig`, plus
`CONFIG_TR=y`, which Android's device build has; `Build.sh -r`); busybox
from upstream 1.37.0 with `FEATURE_SH_STANDALONE` and
`FEATURE_PREFER_APPLETS`, as Magisk runs its scripts. If the kernel has no
legacy IPv6 tables, IPv6 uses `ip6tables-nft`; if it boots with
`ipv6.disable=1`, the IPv6 sysctl checks are skipped and say so.

What these tests cannot show is Android: SELinux, netd, Magisk's timing,
Welcome, Wi-Fi and the overlay. The emulator job covers part of that; the
phone the rest.

## Known gaps

**Confinement**
- tor and the filter run in Magisk's `magisk` SELinux domain. Only their
  uid, the missing capabilities, `no_new_privs` and the firewall confine
  them; SELinux does not. A domain of their own via `sepolicy.rule` needs a
  Magisk-rooted emulator to be tested before it goes on the phone.
- A process in that domain can still ask Magisk for root; Magisk then
  asks the person in the Magisk app. Welcome is meant to hide the Magisk
  app outside updates (pivot checks); the module does not enforce it.
- `status.json` can be rewritten by tor's uid (display only, as above).
- The firewall's lock and hash are moved out of `run/` with the
  firewall's environment variables, which its README describes as for
  tests and debugging. The firewall should keep them out of `run/` itself.

**Amnesia**
- Installing the module deletes every saved Wi-Fi network at the next
  boot.
- User 0's credential-encrypted Wi-Fi store
  (`/data/misc_ce/0/apexdata/com.android.wifi`, networks added in user 0
  without "share") is still locked at post-fs-data and is not covered.
- On the first boot after installation, NetworkStack's data directory may
  not exist yet; its lease memory is then written to flash in that boot
  and deleted at the next.
- The lease memory is not cleared when the MAC address changes within a
  session.
- Not covered yet (design W8): DropBox, tombstones, ANR traces,
  graphicsstats, netstats, batterystats, procstats, Bluetooth pairings,
  `/data/vendor/*` (modem dumps, Wi-Fi Direct groups, location, time),
  Persistent-user metadata.
- Settings.Global values are stored by Android, so they persist by
  design (they are the fail-safe for a boot without the module).

**Network**
- Without the module (Magisk Safe Mode, an update without the Magisk
  step) there is no firewall. What remains is the RAM-only Wi-Fi store
  (nothing to join), the stored Settings, and Welcome's check of
  `antumbra.fw.armed`. A network joined by hand then connects in the
  clear.
- Apps with their own tor (Tor Browser, Briar, OnionShare) cannot
  connect in v0: the module writes no exemptions (`fw-exempt.conf`,
  `fw-relays.conf`), so their tor is redirected into the system tor, and
  Tor refuses Tor over Tor. Design W9.
- Pluggable transports: lyrebird is not built yet, so obfs4, webtunnel
  and meek_lite bridges are refused; only plain bridges work. Snowflake is
  never accepted. Plain bridges must have IPv4 addresses.
- Network time is pointed at 127.0.0.1 and therefore off; there is no
  time over Tor yet. tor needs a roughly correct clock.
- `admin`, `unsafe_browser` and `persistent` from Welcome are not used
  yet; captive-portal detection stays off.
- IPv6: between NetworkStack switching IPv6 on and the guard switching it
  off (events, at most 10 s), the interface has IPv6 on. The firewall
  drops all IPv6 on it meanwhile, router advertisements included, so no
  global address is assigned; a link-local one can exist briefly.
- The filter must bind `127.0.0.1:5353` before Android's mDNS. It starts
  first in `service.sh`, but after zygote; if mDNS wins, DNS stays off
  (closed, not open). Unverified on the phone.
- The overlay works only where Magisk (or KernelSU) mounts `system/`: not
  on the CI emulator, whose Google-built resources package is also named
  differently (`com.google.android.connectivity.resources`). Untested on
  the phone.
- The DHCP vendor class (`android-dhcp-16`), probes for hidden networks,
  Bluetooth, NFC, location and ADB/rooted debugging (`ro.debuggable`) are
  left to Welcome's policies or Stage 2.
- `download_mode=0` is the run-time switch for Qualcomm's crash dumps; it
  is [likely] effective and must be checked with a forced panic on the
  phone. EDL stays reachable.
- Every app can read `antumbra.fw.armed` (that is how Welcome reads it),
  so an app can tell that Antumbra runs.

**Operations**
- Logs are in RAM: a failed boot's log is gone after the next start.
- `content query` starts a Java process, about once every 2 seconds until
  Start.
- `uninstall.sh` restores the values recorded at installation, even if
  the person changed one of those keys since.
- API 36 only: LineageOS 24 (Android 17) needs a new release (or
  `ANTUMBRA_FORCE`).
- Built against Magisk v31.0's documented behaviour (boot stages, busybox
  standalone mode, `resetprop`, removal order, read in its source); not
  yet run under Magisk or KernelSU.
