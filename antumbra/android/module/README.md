# The Antumbra module

The Magisk module `antumbra` is the part of Antumbra that runs as root on
the phone (stage 1 of the design: official LineageOS 23.2 plus Magisk). It
starts the firewall before Android, starts tor and the DNS filter as their
own unprivileged users, keeps Wi-Fi's saved networks and the DHCP lease
memory in RAM, sets fail-safe Android settings, keeps the cellular radio
off unless the session chose Phone mode (and never switches it off during
a call), and switches tor's network on only after the Welcome screen's
Start, the way the person chose there.
It follows the shared contract (`antumbra/android/docs`); the module ID is
`antumbra`, installed at `/data/adb/modules/antumbra`.

The format is also KernelSU's (same scripts, `customize.sh`, `system/`
folder). It has not been run under KernelSU.

| File | What it is |
|---|---|
| `module.prop` | Magisk's metadata. No `updateJson`: updates are installed by hand (or later by Welcome after a signature check), never fetched by Magisk. |
| `customize.sh` | Install-time checks and set-up. |
| `post-fs-data.sh` | Boot, before zygote: arm the firewall, RAM directories, sysctls. |
| `service.sh` | Boot, late: the filter, tor, the full firewall, Settings, the cell radio, Welcome's Start, and supervision until shutdown. |
| `uninstall.sh` | Puts the Settings back. |
| `lib/antumbra.sh` | Functions shared by the three boot scripts. |
| `lib/torctl.sh` | Talks to tor's control socket, as uid 2950. |
| `lib/settings.conf` | The Settings.Global values and the reason for each. |
| `lib/emu-install.sh` | Installs the module on the CI emulator as Magisk would. |
| `helper/antumbra-run.c` | Starts a program as another uid with no capabilities. |
| `overlay/` | A static resource overlay that switches keepalive offload off. |
| `META-INF/` | Recovery stub; the Magisk app replaces it. |
| `build-module.sh` | Builds the zip, or installs on a running emulator. |
| `tests/` | Unit tests, an end-to-end sandbox test, its stand-ins, and `build-test-tools.sh`, which builds its toybox, mksh and busybox from pinned sources. |

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
   version on an update and adds the keys that version did not have (an
   earlier version never set them, so their current values are the ones
   from before; from recovery, `null` and Android's default radio list);
   then, while Android runs, stores `enable_cellular_on_boot=0`, so that
   the first start with the module already has the cellular radio off
   (below);
8. writes `/data/adb/post-fs-data.d/antumbra-arm.sh` (root, 0755), which
   only arms the firewall (below);
9. warns when other modules or `post-fs-data.d` scripts share Magisk's
   post-fs-data window.

Every script sets `umask 022` before it creates anything, whatever umask
it was started with (adb's root shell, which starts them on the CI
emulator, has 0).

Checks 2 and 3 can be overridden with `ANTUMBRA_FORCE=1` in the installer's
environment (for example `ANTUMBRA_FORCE=1 magisk --install-module zip`
from a root shell) or by creating `/data/adb/antumbra-force` as root. The
boot order and the firewall have not been checked on other devices.

**Installing the module forgets every saved Wi-Fi network** at the next
start (see below).

### Boot, early arming (`post-fs-data.d/antumbra-arm.sh`, blocking)

Magisk v31.0 runs the scripts in `/data/adb/post-fs-data.d` first, then
each module's `post-fs-data.sh`, in directory order, all within one
40-second budget. The early script runs `antumbra-fw arm` (with its lock in
`/dev/antumbra-fw`) before any module, so a slow module or script cannot
delay the arming, and it also runs when the module carries a `disable`
flag (Magisk app, switch off): such a boot is armed and stays without
network, because nothing loads the full rule set. It does nothing when the
module is being removed in this boot (`remove` flag) or is gone. Magisk
Safe Mode runs neither it nor the module (gaps).

### Boot, post-fs-data (`post-fs-data.sh`, blocking)

Magisk runs this at init's `post-fs-data` trigger and holds the boot until
it ends (at most 40 s, shared with the scripts before it). `/data` is mounted and decrypted; init's own
`post-fs-data` block has already run (it creates
`/data/misc/apexdata/<apex>` in `perform_apex_config`); netd, zygote and
everything that uses the network start after it. It takes well under a
second (measured in the sandbox test).

1. **`antumbra-fw arm`**, the first command (again, after the early
   script). Only loopback traffic moves, IPv4 and IPv6, for every uid. The
   firewall's lock goes in `/dev/antumbra-fw` (RAM), because the runtime
   tmpfs does not exist yet.
2. **The runtime directory**: a new tmpfs (128 MB limit, `nosuid,nodev,
   noexec`) over `/data/adb/antumbra`, laid out as in the table below.
   `/data/adb` gets mode 0711 (Magisk sets 0700 at every boot), so that
   uids 2950 and 2951 can pass through it; SELinux keeps apps out anyway.
3. **Wi-Fi's shared configuration store**
   `/data/misc/apexdata/com.android.wifi` (`WifiConfigStore`: saved
   networks, which are shared by default, their MAC settings, Wi-Fi's own
   settings; the Wi-Fi APEX's device-protected directory,
   `getWifiSharedDirectory()` in Android 16): whatever is on flash is
   deleted, then a tmpfs is mounted over it with the directory's owner,
   mode and SELinux label (`apex_system_server_data_file` on LineageOS
   23.2). New files inherit that label; SELinux allows any file type on a
   tmpfs (`allow file_type tmpfs:filesystem associate`). Saved shared
   networks therefore never reach flash, and a boot without the module has
   none to join. Wi-Fi's per-user store is credential-encrypted
   (`getWifiUserDirectory()`: `/data/misc_ce/<user>/apexdata/com.android.wifi`),
   still locked at this point, and not covered (gaps); Wi-Fi keeps nothing
   in `/data/misc_de`.
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
Schedules use the time since boot (`/proc/uptime`), never the clock, which
the person may set by hand for tor.

0. **The firewall's state** from `antumbra-fw status`: `armed` after
   post-fs-data, or `open` if arming failed there (then step 3 tries
   again, and switches the radios off if that fails too: step 3).
1. **The DNS filter** as uid/gid 2951, first, so that it holds
   `127.0.0.1:5335` before an app can bind that port. (It was 5353 until
   the emulator showed Android's mDNS holding `0.0.0.0:5353` at boot.)
2. **tor** as uid/gid 2950 with `etc/torrc` (rendered from
   `tor/torrc.in`), `DisableNetwork 1`.
3. **`antumbra-fw apply`**, then `antumbra-fw status`, then the port check
   (below): only if the status is live, its hash equals the one `apply`
   printed and no other uid holds a service port does the module run
   `resetprop -n antumbra.fw.armed <first 16 hex digits>`. On failure the
   firewall is back in the armed state and the property is removed. If
   even that leaves it `open` (not even the arm set loads), Wi-Fi and
   mobile data go off as soon as the framework answers (`cmd wifi
   set-wifi-enabled disabled`, mobile data off as below), and the cellular
   radio (airplane mode) and Bluetooth (`cmd bluetooth_manager disable`)
   as soon as no call holds them (below, "The cell radio: off from
   power-on", holds); `status.json` says so, never why it waits.
4. **`run/status.json`** (below).
5. **IPv6 guard**: NetworkStack switches IPv6 back on for every network it
   brings up. A background loop switches it off again on every interface
   whenever `ip monitor` reports a link or address change, and every 10
   seconds in any case.
6. Once boot has completed and the settings provider answers: **the
   Settings.Global values in `lib/settings.conf`** (among them
   `enable_cellular_on_boot=0` and `mobile_data_always_on=0`), **mobile
   data off** for every SIM Android knows (below), and
   `cmd wifi set-scan-always-available disabled`. Then, at every turn of
   the loop, **the cell radio's watch** (below, "The cell radio: off from
   power-on"): airplane mode's radio list is narrowed to the cell radio
   once airplane mode has read off for 30 seconds; whenever something else
   switched the radio on (the person with airplane mode, an emergency call
   or text), it is switched off again with airplane mode, unless a call,
   emergency callback mode, the 5 minutes after either, or a state it
   cannot read holds it. Mobile data off is written again after every
   switch-on and whenever a SIM's state changes; `enable_cellular_on_boot`
   is kept at 1 while a hold lasts (so that a restart of the phone process
   does not switch the radio off then) and written 0 again when it ends,
   just before the switch-off.
7. **Welcome's Start**: every 2 seconds for the first 3 minutes after the
   framework answers, then every 5,
   `content query --user 0 --uri content://org.antumbra.welcome.state/session
   --projection started:tor_mode:mac:session_id`. The first row with
   `started=1` and valid values counts only while Welcome is the device
   owner (`cmd device_policy list-owners` shows
   `admin=org.antumbra.welcome/…,DeviceOwner` for user 0; below). It is
   kept for the rest of the boot (if Welcome's process dies it starts a
   new, unstarted session, which is ignored), in the root-only
   `state/module/session`. For `tor_mode=bridges`, a second query
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
     boot default is 1: a new MAC address for every connection);
   - the cell radio: `session_cell` in `service.sh` gives the session's
     choice, `off` or `phone` (calls and texts). Welcome's row has no such
     column yet; WEL8 adds `cell` to the shared contract and changes only
     that function. Until then every session is `off`. With `phone`, the
     radio is switched on at Start and never before (decision D12): mobile
     data off for every SIM first, then Android's airplane-mode path
     (`enable` and `disable`, or only `disable` when airplane mode is on).

   The network is switched on only while the firewall is live and no
   other uid holds a service port; otherwise it is tried again at every
   turn of the loop. A refused `SETCONF` (55x) fails the session's network
   for good, except `553 … Failed to bind one of the listener ports`,
   which is tried again once the port is free.
8. **Supervision**, every 2 seconds while something changes, else every 5:
   - **who holds the service ports**, at every turn, and again right after
     a turn's look at the cell radio (below): while another uid does, the
     property is removed and the firewall goes back to armed, and the full
     rule set is loaded again as soon as the port is free;
   - the filter and tor are restarted if they stop (pause doubling from 2
     to 64 s), and a restarted tor gets the session's choice again;
   - the firewall is checked every 30 seconds with `status`, and if it is
     not live the property is removed at once and `apply` runs again;
   - tor's bootstrap progress is asked while it connects;
   - `status.json` is rewritten when something changed, and at least once
     a minute;
   - when Android begins to shut down (`sys.shutdown.requested`, which
     ShutdownThread sets first), the fail-safe Settings are put back and
     mobile data is switched off again, so that a start without the module
     does not inherit a session's MAC "keep" or mobile data (best effort:
     a crash or a forced power-off skips it). If airplane mode is on (the
     module's run-time switch-off), `cell_on=1` and `airplane_mode_on=0`
     are written directly, without the airplane-mode broadcast, unless a
     call holds it: nothing switches now, and the next start has the radio
     off (`enable_cellular_on_boot=0`) and Wi-Fi under Welcome's control.
     The cell radio's watch stops there.

   A call to tor's control socket is bounded (5 s of silence, 10 s in
   all), and nothing in the loop waits for tor, so a hung tor cannot hold
   up the port and firewall checks.

### Removal (`uninstall.sh`)

Magisk runs it early in the boot after the module was marked for removal
(the module's other scripts do not run in that boot, and system_server
does not exist yet), or at once when Magisk itself is uninstalled. It
copies `settings.orig` to `/data/adb/antumbra-restore.conf` and writes the
one-time script `/data/adb/service.d/antumbra-restore.sh`, which waits
for boot to complete, puts each value back (`null` = delete the key), and
deletes itself and its data. While Android runs, the module's `service.sh`
is stopped first (its cell radio watch would write the radio's values
again; it checks that the recorded process ID is that script), and the
script is run at once; tor, the filter and the firewall stay until the
restart. It also deletes the early arm script. Saved Wi-Fi networks are not
restored: there are none on flash. Mobile data stays off for each SIM
Android knew (the per-SIM values are not recorded); switch it on in
Settings. `enable_cellular_on_boot`, `mobile_data_always_on` and
`airplane_mode_radios` are put back like the other keys (without a record:
deleted, and Android's default list `cell,bluetooth,uwb,wifi,wimax`), so
the cellular radio comes back at the next start, or when airplane mode is
switched on and off. Airplane mode itself is not touched.

## Files on the phone

Everything under `/data/adb/antumbra` is on a tmpfs: it disappears at
power-off.

| Path | Owner, mode | Content |
|---|---|---|
| `/data/adb/antumbra` | root, 0711 | tmpfs |
| `run/` | 2950:2950, 0751 | tor's control socket and cookie; `status.json` (0644) |
| `state/` | root, 0711 | `fw-exempt.conf`, `fw-relays.conf` (not written in v0) |
| `state/tor/` | 2950:2950, 0700 | tor's DataDirectory |
| `state/module/` | root, 0700 | process IDs, the session (`session`, 0600: session ID, tor mode, MAC, cell radio) and its bridges, the firewall's lock and hash (`fw/`) |
| `lists/` | root, 0755 | updated block list and DoH list (none in v0: the module's copies in `MODDIR/lists` are used) |
| `log/` | root, 0755 | `module.log`, `firewall.log`, `dnsfilter.log`, `tor.stderr`, `tor.log` (2950, 0600) |

Logs never contain bridge lines or addresses.

### status.json

Written for display: the filter serves it under `"module"` on
`http://127.0.0.1:5380/status`, and Welcome shows `firewall.state`,
`firewall.hash`, `tor.bootstrap`, `tor.summary`, `tor.network` and
`tor.error`. Every app can read that page, so the file holds nothing more:
no session ID and no tor mode (whether the session uses bridges would tell
an app that the person is on a censored network). `tor.error` can still
say that bridges were refused.

```json
{"schema":1,
 "module":{"version":"0.1.0","updated":"2026-10-11T07:51:51Z","problem":null},
 "firewall":{"state":"live","hash":"9a4d326ea2eee9bf"},
 "tor":{"running":true,"network":"enabled","bootstrap":5,
        "summary":"Connecting to a relay","error":null},
 "dnsfilter":{"running":true},
 "welcome":{"started":true}}
```

`firewall.state` is `armed` (before the first apply), `live`, `failed`
(the full rule set is not live; the arm set is in place, so nothing
leaves) or `open` (not even the arm set could be loaded; Wi-Fi and mobile
data are switched off, then the cellular radio and Bluetooth; while a
hold keeps those two on, the problem says "cellular radio and Bluetooth
off shortly", never why); `tor.network` is `enabled` or `disabled`;
`tor.error` says why the session's network could not be switched on;
`module.problem` joins the boot's problems with the current ones, for
example `service port taken: 9040/tcp held by uid 10187` or
`org.antumbra.welcome is not the device owner: Start is not trusted`.
tor's uid can rewrite this file, so nothing may base a decision on it: the
firewall's word is the property `antumbra.fw.armed`, which only root can
set.

## Trust and privileges

- **tor owns `run/`.** tor refuses a control socket in a directory it does
  not own. A root process must therefore never open, write or follow a
  path in `run/`: tor could have replaced it with a symbolic link to any
  file. The module reads the control cookie, talks to the socket and
  writes `status.json` through processes running as uid 2950 itself.
- **The firewall's own files** (its lock and the recorded hash, in a
  root-only directory under `$ANTUMBRA_DIR`, never in `run/`) are kept
  under `state/module/fw`, by calling `antumbra-fw` with
  `ANTUMBRA_DIR=/data/adb/antumbra/state/module/fw` and the three input
  files named explicitly (`ANTUMBRA_FW_EXEMPT`, `ANTUMBRA_FW_RELAYS`,
  `ANTUMBRA_FW_DOH`). Run by hand,
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
- **The service ports.** Only tor may hold `127.0.0.1:9040` (TCP) and
  `:9053` (UDP, and TCP), only the filter `:5335` (UDP and TCP) and
  `:5380` (TCP). See "Who holds the service ports" below.
- **Welcome's provider** is trusted only while Welcome is the device
  owner (below).

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
half-closes the connection and reads until tor closes it. `-q 5` bounds
that wait: the help text says "quit SECONDS after EOF on stdin", and
`pollinate()` in toybox's `lib/net.c` makes it the poll timeout once stdin
has ended, so nc gives up after 5 seconds in which tor sent nothing.
`timeout 10` bounds the whole call. `lib/torctl.sh` sends
`AUTHENTICATE <cookie hex>`, the commands, and `QUIT`; if authentication
fails, tor answers 515 and closes, so no command runs. No Go helper was
needed.

### Who holds the service ports

The firewall redirects every app's TCP to `127.0.0.1:9040` and every DNS
query to `127.0.0.1:5335`. tor holds no TransPort or DNSPort while its
network is off (before Start, in an offline session, while it restarts),
and the filter's ports are free while it restarts: then any app could bind
them. The firewall drops the answers of a socket that is not the owner's
(its `ANTUMBRA_SQUAT` chain), so no handshake completes, but it cannot keep
a squatter from receiving SYNs and UDP queries, with the names in them;
and a squatter on 9040 or 9053 makes tor's `DisableNetwork=0` fail (553).

So `listeners_ok()` reads `/proc/net/{tcp,tcp6,udp,udp6}`: sockets bound
to `127.0.0.1`, `0.0.0.0`, `::` or `::ffff:127.0.0.1` (the ones that receive
what is sent to 127.0.0.1); TCP listeners on 9040 and 9053 must be uid
2950's and on 5335 and 5380 uid 2951's; UDP sockets in any state on 9053
must be 2950's and on 5335 2951's. No listener at all is fine. If
`/proc/net/tcp` cannot be read, that counts as a failure. It runs before
the full rule set is published (in `fw_publish`, before `apply` and after
`status`), at every turn of the loop, and before tor's network is
switched on. While another uid holds a port, the property is removed, the
firewall goes back to armed (no redirect at all, so the squatter is sent
nothing and nothing leaves), tor's network stays off, and `module.problem`
names the port and the uid; once the port is free, the full rule set is
loaded again at once. What remains: between a squatter's bind and the next
turn (at most about 5 s) it can receive UDP queries to 5335 (names, no
answers) and TCP SYNs.

The complete fix, tor holding 9040 and 9053 from boot (`DisableNetwork 0`
with the firewall keeping uid 2950 from the Internet until Start), changes
the contract of tor and the firewall and was not taken in v0.

### Welcome's provider: only from the device owner

Any app could declare the authority `org.antumbra.welcome.state` while
Welcome is not installed (between installing the module and Welcome, or if
Welcome were ever removed) and answer `started=1` with `tor_mode=direct`
or bridges of its choosing. The module therefore acts on a started row
only while `org.antumbra.welcome` is the device owner of user 0 (`cmd
device_policy list-owners`). A device owner cannot be uninstalled, an
authority belongs to one package only, and the device owner is set by the
person over adb at installation; no app can make itself one afterwards.
So while Welcome is the device owner, the authority is Welcome's.
Pinning Welcome's signing certificate as well was not done: a shell cannot
compute an installed APK's certificate digest (`dumpsys package` prints
only a hash code), and Welcome has no release key yet.

### Mobile data off: stored per SIM

A SIM connects whatever Wi-Fi's store holds, and LineageOS starts with
mobile data on. Android 16 keeps the choice per subscription in
Settings.Global (`mobile_data<subId>` in dual-SIM mode, which the hotdog's
two slots use; `mobile_data` with one slot; `GlobalSettingsHelper` and
`DataSettingsManager` in `frameworks/opt/telephony`, `android16-release`)
and reads it when the SIM comes up, also in a boot without the module. At
every boot the module sets `mobile_data=0` (`settings.conf`) and
`mobile_data<subId>=0` for every subscription it finds (the
keys already in Settings.Global and the IDs in
`content://telephony/siminfo`), and runs `cmd phone data disable` for the
default data SIM now; again at shutdown, after every switch-on of the cell
radio, whenever a SIM's state changes (`gsm.sim.state`), and before the
module itself switches the radio on (Phone mode). The person may switch
mobile data on after Start; it then goes through Tor like everything else.
On the emulator too (until the cell radio work it was left alone there):
CI switches its simulated mobile data off itself, and a start without the
module must find it stored off. A SIM Android has never seen has no
stored value and starts with mobile data on (`ro.com.android.mobiledata`,
default true): gaps.

### The cell radio: off from power-on

The cellular radio stays off unless the session chose Phone mode (WEL8,
not built yet; until then every session keeps it off), and in Phone mode
it comes on at Start only (decision D12). Android 16 sources read for
this (`android16-release`, and the same places on `android16-qpr2-release`,
which LineageOS 23.2 is): `ServiceStateTracker`, `PhoneGlobals`,
`RadioOnHelper`, `TelephonyConnectionService`, `EmergencyStateTracker`,
`ConnectivityService`, Wi-Fi's `WifiSettingsStore` and `ActiveModeWarden`,
Bluetooth's `RadioModeListener`, `TelephonyRegistry`, Telecom's
`CallsManager` and `Analytics`.

**Off from power-on: three stored values.** The phone process reads
`enable_cellular_on_boot` once, when it starts, and with 0 keeps the radio
off ("off by the user"); with airplane mode stored off and `cell_on=1`,
`PhoneGlobals` does nothing at its start either (with `cell_on=2` it would
switch the radio on). `settings.conf` sets the first at every boot and
shutdown, `customize.sh` at installation, and the watch again after every
switch-on (Android's airplane-mode path sets it back to 1) once no hold
lasts (below). This holds on a start without the module too.

**Why airplane mode is never left on across a restart.** Wi-Fi copies
airplane mode once, when it starts (`WifiSettingsStore`), and updates that
copy only on an airplane-mode change while the list of airplane-mode
radios names Wi-Fi. While the copy says "on", Android lets only privileged
callers switch Wi-Fi, and a device owner is not one: Welcome could not
switch Wi-Fi on at Start, or off, for the whole boot. So the module stores
airplane mode off at shutdown (above), and narrows the list only once
airplane mode has read off for 30 seconds (Wi-Fi must have handled the
last airplane-off first; otherwise its copy would stay "on").

**Off at run time: airplane mode, for the cell radio only.** With
`airplane_mode_radios=cell`, `cmd connectivity airplane-mode enable`
switches the cell radio off and leaves Wi-Fi and Bluetooth as they are.
It is Android's own path, and the only one used, because Android's
emergency-call path undoes it by itself: `RadioOnHelper` switches the
radio on and airplane mode off, `ServiceStateTracker` clears every reason
the radio was off for (so `enable_cellular_on_boot=0` cannot block it
either), and `PhoneGlobals` switches airplane mode back off if it is
switched on during an emergency call.

| Way to switch the cell radio | Verdict |
|---|---|
| Airplane mode with the list narrowed to `cell` | used at run time; undone by the emergency path |
| `enable_cellular_on_boot=0` with airplane mode off and `cell_on=1` | used for "off from power-on"; undone by the emergency path |
| `cmd phone` | has no radio-power command in Android 16 |
| `service call phone <n>` | never: transaction numbers change between releases, and a wrong one calls another method |
| Switching a modem or a SIM slot off, SIM power, the multi-SIM setting, stopping the RIL or the phone process, modem restarts, `remoteproc` or `sysfs`, thermal mitigation, carrier-config overrides, `DISALLOW_AIRPLANE_MODE` | never: the emergency dialer cannot undo them, or they could hide a call |

**Holds.** No airplane step and no radio-off step (the run-time
switch-off, Phone mode's whole switch-on, `enable` and `disable` alike,
the fail-safe's cell radio and Bluetooth, the shutdown reset) while:

- Telecom lists a call in any state (`dumpsys telecom`, `mCalls`: ringing,
  dialing, connecting, active, on hold, disconnecting; VoIP calls too), or
  the telephony registry shows a phone that is not idle (`dumpsys
  telephony.registry`: `mCallState`, and the precise ringing, foreground
  and background states);
- emergency callback mode, for calls or texts, is on (the property
  `ril.cdma.inecmmode`, which both of Android 16's paths set, or the
  registry's callback-mode durations);
- less than 5 minutes have passed since a look that saw either, since the
  look that saw it end, since Telecom's call counter moved (`TC@<n>` in
  its Analytics: a call that began and ended between two looks), or since
  the radio came on or airplane mode went off without the module doing it
  (an emergency text switches the radio on and starts no call);
- any of it cannot be read (a missing service, a timeout, a layout the
  parsers do not know, `/proc/uptime` unreadable): a hold as if in a
  call, and 5 more minutes once it can be read again.

Wi-Fi off and mobile data off never wait. While a hold lasts and the
radio is not off, the watch keeps `enable_cellular_on_boot=1`: the phone
process reads it whenever it starts, and if it restarted then (a crash,
or a restart of system_server), 0 would switch the radio off during a
call, callback mode or the 5 minutes after, and no callback could reach
the phone. It writes 0 again once the hold ends, just before the
switch-off.

The watch looks (two dumps, each bounded at 3 s by `dumpsys -t` and at 4 s
in all, so a look takes at most 8 s) every 10 seconds while the radio is
on or a hold lasts, every 60 otherwise, 30 seconds after a look that could
not read the state, and at once when airplane mode, the callback-mode
property or a SIM's state changes, or when something else sets
`enable_cellular_on_boot` (a switch-on). A step that nothing holds is
taken only on a look from the same turn of the loop, never on one from an
earlier turn, and is tried at most once in 10 seconds. After its own
airplane step the watch takes the airplane mode it asked for as read, so
that airplane mode switched off again before its next turn (the
emergency path, the person) still counts as switched off by something
else. The dumps go through pipes only: the registry prints the incoming
number. The module's log names the hold (`held: call`, `callback`,
`recent`, `unknown`); `status.json` never does.

**Phone mode** (`session_cell`, the one place WEL8 changes): before Start
the radio is off whatever the choice; at Start, mobile data off for every
SIM, then the switch-on above; afterwards airplane mode switched on by the
person is left alone, and if the phone process restarts outside a hold
(it then reads `enable_cellular_on_boot=0` and the radio goes off) the
module switches it on again, with the same holds (during a hold it reads
1 and the radio stays on). With mobile data off, Android still allows
the IMS and emergency bearers and SUPL during an emergency call or
callback mode (`DataNetworkController`); whether the carrier's IMS
registers so is PH3's.

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
build-module.sh --emulator --zip antumbra-module-0.1.0.zip [--serial emulator-5554] [--no-restart]
build-module.sh --emulator --tor TOR_OUT --dnsfilter DNSFILTER_OUT \
    --blocklist LISTS_OUT/dnsfilter.list [--serial emulator-5554] [--no-restart]
```

Google's `default` system image has no Magisk but gives a root shell with
`adb root`. With `--zip`, this mode installs exactly the files of a built
zip (what Magisk's installer would unpack; `customize.sh` checks them
against `SHA256SUMS`). Without it, it builds the tree for the emulator's
ABI from the checkout and the other parts' outputs. The overlay is never
built for the emulator: nothing mounts `system/` there. Then it does by
hand what Magisk would do at boot, in the same order:

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
The module's `customize.sh` also writes the early arm script there, which
nothing runs on the emulator.

On the emulator only, `start_dnsfilter` honours the CI's switch
`debug.antumbra.log_queries=1` (set before the install): it starts the
filter with `-debug-log-queries -status-refresh 0`, so the leak test can
list every name looked up. The switch is ignored on any other device
(`is_emulator`), so a phone never logs query names. The firewall's state by hand:
`ANTUMBRA_DIR=/data/adb/antumbra/state/module/fw sh
/data/adb/modules/antumbra/bin/antumbra-fw status`.

## Tests

All shell is POSIX sh and is checked with `shellcheck -s sh`:

```sh
cd antumbra/android/module
shellcheck -s sh -x *.sh lib/*.sh tests/*.sh tests/fakes/* META-INF/com/google/android/update-binary
```

**`tests/unit.sh`** (no root): bridge-line checks (27 cases), IPv4
addresses, provider-row parsing, control-reply parsing, JSON helpers, the
Settings list on the emulator and on the phone (13 and 14 values;
`airplane_mode_radios` never set at boot), `ports_bad()` against
`/proc/net` fixtures (owners, other uids, wildcard and IPv6 addresses,
TIME_WAIT, connected sockets, an unreadable file), and the cell radio:
the parsers against dumps in Android 16's layout (every call state, VoIP
calls, a call line in another section, missing sections, empty input, a
missing service; idle, ringing, off-hook, active, held, dialing,
incoming, disconnecting, disconnected and not-valid states on either
phone, callback mode for calls and texts, the radio states, a field
missing, the incoming number never printed), `cell_hold` (each reason,
their order, 299 s held and 300 s released, no clock), `cell_note` (the
call counter up and down, the radio switched on by something else or by
the module, a call's end, an unreadable state), `cell_decide` in each
state (a step only on a look from the same turn), and the watch turn by
turn against stand-ins for Settings, airplane mode and a restart of the
phone process (with `PhoneGlobals`' and `ServiceStateTracker`'s parts)
and the dumps: every hold and its release, a call that begins to ring
between two turns, `enable_cellular_on_boot` kept at 1 through a call,
callback mode and the 5 minutes after (a restart of the phone process
then keeps the radio on, after an emergency call over the module's
switch-off and from power-on alike) and 0 again before the switch-off,
the fail-safe during a call (Wi-Fi and mobile data at once, the cell radio
and Bluetooth after it), Phone mode's switch-on (only after Start, mobile
data off first, enable then disable, both held during a call, again after
a phone-process restart, airplane mode left to the person), nothing
written once the module's files are gone, and the shutdown reset (its
order, held during a call or an unreadable state). Under `sh`, dash, busybox and mksh (`MKSH=` names
Android's).

**`tests/e2e-host.sh`** (root, Linux): the module's real scripts with the
real firewall, tor, DNS filter and `antumbra-run`, without Android. Each
scenario gets mount, network and PID namespaces and a chroot into an
overlay of the host whose upper layer holds `/system/bin` (Android 16's
toybox and mksh built for the host, the host's `iptables-legacy` and `ip`,
and the stand-ins in `tests/fakes` for `getprop`, `setprop`, `resetprop`,
`settings`, `cmd`, `content` and `dumpsys`), a Wi-Fi store and a lease
database "on flash", and the staged module. The stand-ins for `dumpsys`
and `cmd` play Telecom, the telephony registry and airplane mode (with the
phone process's part: `cell_on`, `enable_cellular_on_boot`, the radio)
from files the test writes, and a file bound over `/proc/uptime` (rewritten
every second: the real time since boot plus a skew) lets the test move the
module's clock past the 5-minute holds; production code has no test hook.
The module's scripts run with umask 0. It
installs the module through `emu-install.sh` (so `customize.sh` runs),
then runs the early arm script, `post-fs-data.sh` and `service.sh` and
checks, among other things: modes despite umask 0; the arm set and that
root cannot send while armed; the runtime tmpfs, owners and modes; the
Wi-Fi and lease stores on tmpfs and their flash copies deleted; the
property equal to the live hash and published only through `resetprop -n`;
tor and the filter with their uids, no capabilities, `no_new_privs` and
group 3003; `status.json` (without session ID or tor mode) and the
filter's status page as an app sees them; an app's DNS for a tracker
answered NXDOMAIN through the firewall's redirect, and other DNS failing
closed while tor is offline; other UDP refused; no Settings before the
framework is up, all of them after (the cell radio's among them, and
`enable_cellular_on_boot=0` already at installation; each key recorded
once); in every scenario
the list narrowed to the cell radio, `cell=off` in the session record, and
no switch-on by the module; and per scenario:

| Scenario | Shell | Checks |
|---|---|---|
| `bridges` | busybox, standalone | plain bridges and the network reach tor (`GETCONF`), tor holds 9040; MAC "keep"; no bridge line in the log; a restarted Welcome is ignored; tor killed → restarted with the session; filter killed → restarted and blocking; firewall rule deleted → reloaded and property re-published; shutdown → MAC randomization back to 1 |
| `direct` | mksh, LineageOS hotdog properties | mobile data off for every SIM (`mobile_data`, `mobile_data1-3`, `cmd phone data disable`); an app (uid 10200) binds `127.0.0.1:9040` before Start → armed, property removed, status names port and uid, another app's TCP not passed on, the squatter accepts nothing, Start does not switch tor's network on; port free → live again, network on, tor holds 9040; `restricted_networking_mode=1` |
| `offline` | mksh | an update over a record made before the cell radio work: the old record kept and the three keys it lacked added; network stays off; mobile data stored off on the emulator too; an app binds `127.0.0.1:5335` while the filter restarts → armed, status names it, no query reaches it; port free → filter back, live, blocking; `uninstall.sh` during boot leaves the restore script; while Android runs it stops `service.sh` and puts the Settings back at once (the first installation's values; the radio list, `enable_cellular_on_boot` and `mobile_data_always_on` included), nothing writes them again, the restore script deletes itself, and the early arm script is deleted |
| `pt` | busybox | obfs4 without lyrebird: refused, network off, reason in status; during an active call on the cell radio, iptables broken → firewall `open`, property removed, Wi-Fi and mobile data off at once, status says the rest follows (not why); no airplane mode and no Bluetooth off during the call or 270 s after it; 5 minutes after it both, status says so; repaired → live; shutdown → `cell_on 1` and `airplane_mode_on 0` stored, no airplane-mode command |
| `badbridges` | mksh | Start while another package is the device owner → ignored, reason in status; with Welcome as device owner, a quote in a bridge line: refused, network off |
| `cell` | busybox, LineageOS hotdog properties | the cell radio switched on by something else and off again by the module, after each hold, each shown held after the clock is moved on and released 5 minutes after it ends: a switch-on with airplane mode off (an emergency text, or the emergency path); airplane mode switched off by the person (mobile data off again at once); a ringing, an active and a held call; callback mode from the property, and for calls and texts from the registry; an unreadable state; a call seen only by Telecom's call counter; `enable_cellular_on_boot` stored 1 while a hold lasts and written 0 before the switch-off; shutdown during a call leaves airplane mode as it is |

```sh
sudo tests/e2e-host.sh --tor-bin WORK/x86_64/tor-hostcheck \
    --dnsfilter-bin DNSFILTER_OUT/x86_64/antumbra-dnsfilter --blocklist LISTS_OUT/dnsfilter.list \
    --toybox TOYBOX --mksh MKSH --busybox BUSYBOX
```

`tor-hostcheck` is the static copy `build-tor.sh` leaves in its work
directory. `tests/build-test-tools.sh --out TOOLS` builds the three shell
tools from pinned sources:

| Tool | Source | Pin | Build |
|---|---|---|---|
| toybox | AOSP `external/toybox`, `android16-release` | commit `e21e76d30fa15996188b79affbc25cfd0c13deff` (checked by git) | `make defconfig`, plus `CONFIG_TR=y`, which Android's device build has |
| mksh | AOSP `external/mksh`, `android16-release` | commit `103f7c36340298f42cee2f0fe7101a93a01a14e7` | `Build.sh -r` |
| busybox | busybox.net 1.37.0 | SHA-256 `3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4`; signature by `C9E9 416F 76E6 10DB D09D 040F 47B7 0C55 ACC9 965B` (Denys Vlasenko) | `make defconfig`, plus `FEATURE_SH_STANDALONE` and `FEATURE_PREFER_APPLETS` (as Magisk runs its scripts), without `tc` |

If the kernel has no legacy IPv6 tables, IPv6 uses `ip6tables-nft`; if it
boots with `ipv6.disable=1`, the IPv6 sysctl checks are skipped and say so.

In CI the module job runs `tests/unit.sh` only so far; shellcheck and this
test need the workflow's steps (the CI part's file): `shellcheck -s sh -x`
as above, `tests/build-test-tools.sh` (cached by its pins), and
`sudo tests/e2e-host.sh` with tor's `tor-hostcheck` and the filter's
x86_64 binary from the earlier jobs.

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
- The firewall keeps its lock and recorded hash in a root-only directory
  of its own (`$ANTUMBRA_DIR/state/fw`); the module points `ANTUMBRA_DIR`
  at `state/module/fw`, so they end up in `state/module/fw/state/fw`, and
  anything that asks `antumbra-fw status` by hand (CI included) passes the
  same `ANTUMBRA_DIR`.

**Amnesia**
- Installing the module deletes every saved Wi-Fi network at the next
  boot.
- User 0's credential-encrypted Wi-Fi store
  (`/data/misc_ce/0/apexdata/com.android.wifi`) is still locked at
  post-fs-data and is not covered. It holds networks added without
  "share", the network suggestions apps had approved, and user 0's
  Passpoint configurations; they stay on flash, so "a start without the
  module has no network to join" holds for the shared store only. Covering
  it from `service.sh` as soon as user 0 is unlocked
  (`sys.user.0.ce_available`) races Wi-Fi's own read of it at unlock; the
  timing has to be measured on the phone first (design W8).
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
  design (they are the fail-safe for a boot without the module). A
  session's own changes (`non_persistent_mac_randomization_force_enabled=0`
  for MAC "keep", mobile data switched on) are undone at shutdown only on
  a clean shutdown that leaves `service.sh` a moment (best effort); after a
  crash or a forced power-off, a start without the module keeps them.
  Welcome resetting them at `ACTION_SHUTDOWN` would add a second chance
  (Welcome's part).

**Network**
- Without the module (Magisk Safe Mode, an update without the Magisk
  step) there is no firewall. What remains is the RAM-only Wi-Fi store
  (nothing shared to join), the stored Settings (the cellular radio off
  from power-on, mobile data off for the SIMs Android knew), and Welcome's
  check of `antumbra.fw.armed`. A network joined by hand, or a SIM once
  its radio is switched on (airplane mode switched on and off, or an
  emergency call) when it is one Android has never seen (mobile data on
  by default) or one whose mobile data was switched on in a session that
  ended without a clean shutdown, then connects in the clear. With the
  module only disabled (`disable` flag), the early arm script keeps the
  network closed.
- The port check runs at every turn of the loop (2 to 5 s), and again
  right after a look at the cell radio, which can take up to 8 s (two
  dumps of a slow service); in between, a
  squatter on 5335 can receive DNS queries (it cannot answer them, and
  nothing leaves) and one on 9040 SYNs. On the phone, Android's mDNS
  (system_server, uid 1000) on 5335 before the filter would count as a
  squatter too: the firewall then stays armed, with the reason in the
  status (closed, not open).
- If the firewall cannot even be armed, Wi-Fi and mobile data go off at
  once, the cellular radio and Bluetooth only when no call holds them (up
  to 5 minutes after a call, and never while the call state cannot be
  read); they stay off after the firewall comes back, until the person
  switches them on (the cellular radio then goes off again after the
  holds, unless the session is in Phone mode).
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
- The filter must bind `127.0.0.1:5335` before any other uid. It starts
  first in `service.sh`, but after zygote; if another uid holds the port,
  DNS stays off and the firewall stays armed (closed, not open).
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

**The cell radio**
- After anything else switches the radio on (the person with airplane
  mode, an emergency call or text), it stays on for at least 5 minutes,
  and while a call or callback mode lasts; the person can switch it on
  with airplane mode in any session (it goes off again after the holds).
- The holds read `dumpsys` layouts (Telecom's `mCalls` and Analytics, the
  telephony registry). If Android changes them, the module holds as if in
  a call and stops switching the radio off at run time, and keeps
  `enable_cellular_on_boot=1` for the session, so a restart of the phone
  process switches the radio on; it is still off from power-on after a
  clean shutdown. The layouts were read in Android 16's source; no device
  or emulator has run the parsers yet.
- `enable_cellular_on_boot=1` while a hold lasts: a crash or a forced
  power-off then (during a call, callback mode or the 5 minutes after,
  also in Phone mode after any call) skips the shutdown's 0, and the next
  start has the radio on before Start (against D12 in that case), until
  the watch switches it off after the 5-minute rule; on a start without
  the module, for that whole boot. A clean shutdown or restart during a
  hold stores 0 like any other: the next start has the radio off, and a
  callback reaches the phone only once it is on again (Phone mode's
  Start); an emergency call still switches it on. Welcome's Quick power
  off waits during a call, callback mode and the 5 minutes after; the
  system's power menu does not.
- A crash or forced power-off while airplane mode is on (the module's
  run-time switch-off) skips the shutdown reset: the next start has
  airplane mode on and Wi-Fi's copy with it, so Welcome cannot switch
  Wi-Fi; switch it on in Quick Settings for that boot. The same follows a
  shutdown during a call with airplane mode on.
- A SIM Android has never seen starts with mobile data on until the
  module writes its key (at the SIM's state change, at most a few seconds;
  before Phone mode's switch-on in any case). If the radio comes on before
  that without the module (the emergency path, or airplane mode switched
  by the person), that SIM's data can come up meanwhile, through the
  firewall. `resetprop -n ro.com.android.mobiledata false` at post-fs-data
  would make "off" the default for such a SIM; not done (a decision for
  the lead).
- With the radio off since power-on, the emergency numbers beyond the ones
  Android always knows depend on the network country, which the radio has
  not seen (PH4).
- Installed from recovery, the first start has the radio on (no
  `enable_cellular_on_boot=0` yet) until the watch switches it off, after
  the 5-minute rule.
- Uninstalling leaves the radio off until the next start (or airplane mode
  switched on and off).

**Operations**
- Logs are in RAM: a failed boot's log is gone after the next start.
- `content query` starts a Java process each time Welcome's provider is
  asked: every 2 seconds for the first 3 minutes after the framework
  answers, then every 5 until Start (so a late Start takes up to about 6
  seconds to reach tor). A signal from Welcome that root can wait for
  would remove the polling.
- `uninstall.sh` restores the values recorded at installation, even if
  the person changed one of those keys since.
- API 36 only: LineageOS 24 (Android 17) needs a new release (or
  `ANTUMBRA_FORCE`).
- Built against Magisk v31.0's documented behaviour (boot stages, busybox
  standalone mode, `resetprop`, removal order, read in its source); not
  yet run under Magisk or KernelSU.
