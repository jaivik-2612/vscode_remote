# Antumbra Welcome (Android)

The Welcome app is the device owner of an Antumbra phone, and its home
screen until the session starts. At every boot it asks the questions the
Tails Welcome Screen asks: connect to Tor directly, through bridges, or
stay offline; use a new Wi-Fi hardware address; Administration. (The
Unsafe Browser is shown but comes later.) It applies the device-owner
policies for the session and hands the choices to the Antumbra module
through a content provider. After Start it shows Tor's progress and the
tracker filter's counters, and offers Quick power off, an immediate power-off.
Both screens have an **Emergency call** button, and emergency calls work
from the locked Welcome screen before Start (see "Emergency calls").

Package `org.antumbra.welcome`. Kotlin, Jetpack Compose with Material 3.
compileSdk and targetSdk 36 (Android 16, LineageOS 23.2), minSdk 34.

| Path | What it is |
|---|---|
| `app/src/main/java/org/antumbra/welcome/` | The app (one file per part; see below) |
| `app/src/main/assets/builtin-bridges-obfs4.txt` | Tor Browser's built-in obfs4 bridges, written by `tools/builtin-bridges.sh` (not offered until lyrebird ships) |
| `app/src/test/` | JVM unit tests: bridge checks, the provider's row, the status-page parser and the add-on rule, the policy lists, the lock task's features, when Quick power off waits (with the module's word on the last calls, MOD11), and the texts |
| `ci/welcome-adb.sh` | Installs, provisions and drives the app over adb, by hand. The CI emulator job drives Welcome with its own script (`antumbra/android/ci/emulator-antumbra.sh`), using the same test tags and provider URI, and calls this one only for `check-emergency`, `check-power-menu`, `check-policies --keep-adb` and `check-addon`; the app lab (`emulator-apps.sh`, a session with Administration on) for `check-policies --admin --keep-adb` and `check-addon` |
| `ci/test-welcome-adb.sh` | Runs `welcome-adb.sh` against a fake adb (no device needed) |
| `tools/builtin-bridges.sh` | Rewrites or checks the built-in bridges from a pinned, checksummed source |
| `gradlew`, `gradle/wrapper/gradle-wrapper.properties` | The pinned Gradle (see "Building") |
| `gradle/libs.versions.toml` | Every plugin and library version |
| `gradle/verification-metadata.xml` | SHA-256 of every artifact the build resolves, and the PGP keys trusted to sign them |
| `gradle/verification-keyring.keys` | Those public keys, ASCII-armored (the build contacts no key server) |

## The screens

1. **Welcome** (`WelcomeActivity`, `ui/WelcomeScreen.kt`). Title "Welcome to
   Antumbra", then:
   - **Tor**: *Connect to Tor directly* (default), *Connect through bridges*
     with *Bridges I enter* (a text field, one bridge line per line), or
     *Stay offline*. *Built-in bridges (obfs4)* is shown but disabled, "Not
     available yet", until the module ships lyrebird (see "Bridges").
   - **Network**: *New Wi-Fi hardware address*, on by default.
   - **Persistent Storage**: shown, disabled, "Not set up yet" (v0).
   - **Additional settings**: *Administration*, off; *Unsafe Browser*,
     shown off and disabled, "Coming later" (W11: nothing in v0 would act
     on it, so the provider always reports `unsafe_browser = 0`).
   - A large **Start Antumbra** button that stays above the keyboard and the
     navigation bar, with **Emergency call** above it, and **Return to
     call** above that while a call is in progress (see "Emergency
     calls"). When Start is refused, the reason appears above it.

   A red banner says when the add-on is not running (Wi-Fi then stays off
   for the session) or when Welcome is not the device owner.
2. **Status** (`StatusActivity`, `ui/StatusScreen.kt`), after Start, and the
   "Antumbra" entry in the launcher: Tor's bootstrap progress and, when the
   module gives one, its reason why tor cannot connect; the tracker
   filter's counters (lookups, blocked, domains on the list, list version);
   the session's choices and the firewall row ("Live (rules …)" only from
   `antumbra.fw.armed`); buttons for Wi-Fi settings and for adding the
   Quick Settings tile; and **Emergency call** and **Power off now** (Quick
   power off) buttons that stay on screen. It polls `http://127.0.0.1:5380/status` every two seconds while
   visible. If Welcome's process was restarted after Start and the module
   still holds the session, it says so and asks for a restart instead of
   offering the Welcome screen again.
3. **Quick power off**, a Quick Settings tile (`QuickPowerOffTileService`),
   plus the same action in the session's ongoing notification. One tap, no
   question asked, except during a call and its callback period. See "Quick
   power off" for what it can and cannot do, also from the lock screen, and
   why it is never on the power button.

Visual design: the Material 3 "tonal spot" dark scheme from the seed
`#4d2c9e`, the same values as the archived theme
(`antumbra/config/rootfs/usr/share/antumbra/theme/shell.css`), completed with
the roles that file did not need (generated once with
material-color-utilities 0.3.0; only the values are kept, in `ui/Theme.kt`).
System font (Roboto). Rows are at least 72 dp tall, buttons 56 to 64 dp.
Laid out for 412 dp wide phones and narrower.

The UI's test tags are exposed as resource ids
(`testTagsAsResourceId`), so uiautomator and test scripts find controls by
name: `tor_direct`, `tor_bridges`, `tor_offline`, `bridges_builtin`,
`bridges_custom`, `bridges_text`, `switch_mac`, `switch_admin`,
`switch_unsafe_browser`, `start_button`, `start_error`,
`warning_not_owner`, `warning_no_addon`, `status_title`, `card_tor`,
`tor_progress`, `tor_error`, `card_filter`, `filter_queries`,
`filter_blocked`, `row_firewall`, `warning_policies`, `warning_wifi_off`,
`warning_lost`, `open_welcome`, `wifi_settings`, `add_tile`,
`poweroff_button`, `emergency_call`, `return_to_call`.

## Building

```sh
cd antumbra/android/welcome
export ANDROID_HOME=/opt/android-sdk        # platforms;android-36 and build-tools;36.0.0
./gradlew assembleDebug                     # app/build/outputs/apk/debug/app-debug.apk
./gradlew testDebugUnitTest lintDebug       # unit tests and lint
./gradlew assembleRelease                   # app/build/outputs/apk/release/app-release-unsigned.apk
sh tools/builtin-bridges.sh --check         # the built-in bridges match the pinned source
ci/test-welcome-adb.sh                      # the adb driver against a fake adb
```

Needs JDK 17 or later (CI and the local build use JDK 21), `curl`,
`unzip`, and `sha256sum` or `shasum`.

Versions (checked 2026-10-11): Gradle 9.8.1, Android Gradle plugin 9.4.1
(built-in Kotlin), Kotlin 2.4.21 with its Compose compiler plugin, Compose
BOM 2026.06.01 (Compose 1.11.4, Material 3 1.4.0), Activity Compose 1.13.0;
JUnit 4.13.2 and org.json 20260814 for the unit tests only. Compose BOMs from
2026.08.00 on (Compose 1.12) require compileSdk 37, so the BOM stays at
2026.06.01 while the app compiles against API 36. The app has no other
dependency.

**No binaries in the repository.** `gradlew` is a short shell script instead
of Gradle's wrapper jar: it reads `distributionUrl` and
`distributionSha256Sum` from `gradle/wrapper/gradle-wrapper.properties`,
downloads that distribution once over HTTPS, refuses it unless the SHA-256
matches, keeps it under `$GRADLE_USER_HOME/wrapper/dists/antumbra/` and runs
it. The properties file keeps the standard format, so Android Studio reads
the same pin. There is no `gradlew.bat`; on Windows use WSL or Android
Studio.

**Dependency verification.** `gradle/verification-metadata.xml` holds the
SHA-256 of every plugin, library and tool artifact the build resolves
(assembleDebug, assembleRelease, lintDebug, testDebugUnitTest on Linux),
and `verify-signatures` is on: an artifact whose publisher signs it (the
Kotlin plugin and libraries, AGP and the androidx libraries, JUnit,
org.json and most of the build's tools) must carry a valid signature from
a key listed under `trusted-keys`. Gradle refuses an artifact whose
checksum differs or is missing, or whose signature fails. The public keys
are in `gradle/verification-keyring.keys` (`keyring-format` armored; the
binary `.gpg` export is not used and is ignored by git), and key servers
are switched off (`<key-servers enabled="false"/>`), so a build never
fetches a key. The 86 unsigned artifacts (mostly older androidx and
Google libraries) are checked by SHA-256 alone.

How the pins were obtained (2026-10-11): the SHA-256 values are trust on
first use, written by Gradle from what Google Maven, Maven Central and the
Gradle plugin portal served over HTTPS. The keys were fetched by Gradle from
keyserver.ubuntu.com and keys.openpgp.org over HTTPS and exported with
`--export-keys`; every signed artifact verified against them, and every
SHA-256 stayed the same as in the earlier checksum-only file. After
changing a version, regenerate both and review the diff: replace
`<key-servers enabled="false"/>` with
`<key-servers><key-server uri="https://keyserver.ubuntu.com"/><key-server uri="https://keys.openpgp.org"/></key-servers>`,
then

```sh
./gradlew --write-verification-metadata pgp,sha256 --export-keys assembleDebug assembleRelease lintDebug testDebugUnitTest
rm gradle/verification-keyring.gpg
```

and switch the key servers off again. A build on macOS or Windows
resolves a different AAPT2 artifact and needs its checksum added the same
way.

**Outputs** (measured 2026-10-11): `app-debug.apk` about 29 MB (not
minified; Compose debug builds are large), `app-release-unsigned.apk` about
2 MB (R8 minified and resources shrunk). Release APKs are left unsigned:
no CI job builds or signs a release Welcome APK yet (the signing key is
decided before RC1). CI's Welcome job builds the debug APK and runs the
unit tests. Build outputs and the Gradle cache are ignored (`.gitignore`)
and never committed.

Debug builds are marked `android:testOnly` (`app/src/debug/AndroidManifest.xml`):
`adb install` needs `-t`, and a test device owner can be removed again
without a factory reset. Release builds are not testOnly; whether the
phone's build should be is a decision for RC1 (pivot checks).

## Installing and provisioning

The device must have no accounts (a fresh emulator or a freshly installed
LineageOS has none). **Welcome switches USB debugging off the moment it
becomes the device owner, and keeps it off in every session**, so adb goes
away at `dpm set-device-owner`. Do everything that needs adb first.

A release build:

```sh
adb install Welcome.apk
adb shell dpm set-device-owner org.antumbra.welcome/.AdminReceiver   # adb goes away here
```

A debug build, for tests, with the test hook that keeps adb (see "Test
hook"):

```sh
adb install -t app-debug.apk                       # -t: debug builds are testOnly
adb shell setprop debug.antumbra.keep_adb 1        # before set-device-owner
adb shell dpm set-device-owner org.antumbra.welcome/.AdminReceiver
```

Welcome takes over at once: it becomes the home screen, locks its task,
applies the baseline policies, turns Wi-Fi off and locks it off until Start.

To remove a test device owner (testOnly builds only, with the hook on):

```sh
adb shell setprop debug.antumbra.keep_adb 0
adb shell dpm remove-active-admin org.antumbra.welcome/.AdminReceiver
adb uninstall org.antumbra.welcome
```

A release (non-testOnly) device owner can only be removed by a factory
reset. Replacing it later needs the same signing key. Until it is removed,
its restrictions stay: without the add-on, Wi-Fi stays locked off.

`ci/welcome-adb.sh` wraps these steps; see "Driving it over adb".

## How a session runs

**Before Start** (at boot, on becoming the device owner, and again at
shutdown for the next boot; `BootState`, `Home`):

- Welcome is enabled, is the persistent preferred home activity, and runs
  as a locked task: no notification shade, no recents, no other app. The
  power menu stays (`LOCK_TASK_FEATURE_GLOBAL_ACTIONS`), and emergency calls
  go through (`LOCK_TASK_FEATURE_KEYGUARD`, see "Emergency calls"); with it
  a screen lock, if one is set, shows as usual, and so does the call screen
  of any call, an incoming one too, with the full dialer behind its "Add
  call" button. Back does nothing.
- The baseline policies are applied (next section), including those that
  an earlier Administration session lifted: Administration lasts until the
  next shutdown, not into the next boot.
- Wi-Fi is locked (`DISALLOW_CHANGE_WIFI_STATE`, `DISALLOW_CONFIG_WIFI`,
  `DISALLOW_ADD_WIFI_CONFIG`), switched off, and checked to be off; saved
  Wi-Fi networks are removed (`removeNonCallerConfiguredNetworks`). With
  the module, the network store is on tmpfs anyway; this covers a boot
  without the module. At boot this runs off the main thread (`goAsync`).

**At Start** (`WelcomeActivity.startSession`), in this order:

1. Bridge lines are checked (see "Bridges"); an error stops here.
2. **Start is refused** unless Welcome is the device owner: no row, no
   session, and the reason above the button.
3. The add-on is checked: only the `antumbra.fw.armed` property counts (see
   "Add-on check"). If the module's status page says it already holds a
   started session from this boot (`module.welcome.started`), Start is
   refused and the user is asked to restart the phone: the module latches
   the first session, so a second Start could only mislead.
4. The device-owner policies for the session are applied (`Policies.applyAtStart`):
   the baseline again, and the Wi-Fi lock unless the session uses the
   network and the add-on is present. **A network session (direct or
   bridges) is refused when a protective policy failed**: tethering, Wi-Fi
   Direct or safe-boot lock, USB debugging off, or, when Wi-Fi must stay
   off, the Wi-Fi lock and Wi-Fi being off. Nothing is loosened then, and
   the message says to choose *Stay offline* or restart. An offline session
   starts anyway and lists the failures on the status screen.
5. Only then are the session's choices loosened: Administration lifts its
   restrictions; for a network session with the add-on, the Wi-Fi lock is
   lifted and Wi-Fi switched on.
6. A leftover power-off request is deleted (see "Quick power off"), the
   session's choices are fixed in memory, and the provider starts
   answering `started = 1`. Policies come first because the module opens
   the network as soon as it reads `started = 1`. Steps 4 to 6 hold a lock
   that a late boot broadcast also takes, so it cannot lock Wi-Fi again in
   between.
7. The session service starts in the foreground (ongoing notification with
   "Quick power off").
8. The locked task ends, the home preference is cleared, the status screen
   opens, and WelcomeActivity is disabled, so the normal launcher is the
   only home. The status screen has its own task affinity: in Welcome's
   home task it was closed along with WelcomeActivity when Android acted
   on the disabled component, about 10 s later.

**During the session** the choices exist only in memory. The foreground
service keeps the process alive, so the provider keeps answering, and so
the shutdown broadcast reaches the app. (Android sends `ACTION_SHUTDOWN` to
registered receivers only, and defers it for cached processes.)

**At shutdown or restart**, Welcome is made home again (enabled, preferred,
allowed to lock its task), the baseline policies are applied again
(Administration's loosening ends here), Wi-Fi is turned off and locked,
and saved networks are removed. The shutdown broadcast has a few seconds,
so it does not wait to see Wi-Fi off. If the phone loses power or crashes
instead, the same happens at the next boot (`LOCKED_BOOT_COMPLETED`), a
few seconds after the launcher may have shown.

## The state provider (contract with the module)

`content://org.antumbra.welcome.state/session` (`StateProvider`). One row.
Read-only: insert, update and delete throw. Only uid 0 (root) and uid 2000
(shell) may query it, checked with `Binder.getCallingUid()`; everyone else,
including every app, gets a `SecurityException`. A selection is refused; a
projection may name any subset of the columns, in any order.

| Column | Type | Before Start | After Start |
|---|---|---|---|
| `started` | integer | `0` | `1` |
| `tor_mode` | text | `offline` | `direct`, `bridges` or `offline` |
| `bridges` | text | empty | one bridge line per line (`\n` between lines); empty unless `tor_mode` is `bridges` |
| `mac` | text | `new` | `new` or `keep` |
| `admin` | integer | `0` | `0` or `1` |
| `unsafe_browser` | integer | `0` | `0` (the switch is disabled in v0) |
| `persistent` | integer | `0` | `0` (Persistent Storage is not set up in v0) |
| `session_id` | text | 32 hex digits, random per process | the same |

Before Start every column holds its safe value, so a module that read the
row too early would still keep the network closed. Only `started = 1` makes
the other columns the user's choices. `started = 1` is never reported
unless Welcome is the device owner and the session's policies are in place.

How the module should read it:

```sh
content query --uri content://org.antumbra.welcome.state/session \
    --projection started:tor_mode:mac:admin:unsafe_browser:persistent:session_id
# Row: 0 started=1, tor_mode=bridges, mac=new, admin=0, unsafe_browser=0, persistent=0, session_id=5f0c...
content query --uri content://org.antumbra.welcome.state/session --projection bridges
# Row: 0 bridges=192.0.2.1:443 0123...ABCD
# 192.0.2.2:443 ...
```

Query `bridges` on its own: its value spans several lines, and everything
after `Row: 0 bridges=` is the list. Every line has passed the checks in
"Bridges" (printable ASCII, no `"` or `\`), but the module must still quote
each one for the control port (`SETCONF Bridge="<line>" ...`) and must not
trust the app further than that.

Rules for the module:

- **Latch the first `started = 1` of a boot** and ignore later rows until
  the next boot. The choices live in Welcome's memory only; if its process
  died after Start anyway, a new process answers `started = 0` with a new
  `session_id`. A changed `session_id` after `started = 1` means exactly
  that. Welcome's status screen then says it no longer knows the session,
  and refuses a second Start while the module reports
  `welcome.started = true` in its status file.
- Before trusting the row, check that Welcome is the device owner
  (`dpm list-owners` shows `org.antumbra.welcome`); Welcome itself never
  reports `started = 1` otherwise, but another app could answer for a
  missing Welcome.

### The module's word on the last calls (MOD11)

The same provider takes one call, write-only, from uid 0 alone: the
module's word on what the calls of the last 5 minutes were (see "Emergency
calls" and the module's README, "The module's word to Welcome"). Every
other caller, the shell (uid 2000) included, gets a `SecurityException`
before anything is read, and the word Welcome holds stays as it was.

```sh
content call --user 0 --uri content://org.antumbra.welcome.state --method module_word \
    --extra v:i:1 --extra calls:s:ordinary --extra at:l:1234 --extra until:l:0 \
    --extra ims:s:off --extra ims_at:l:0
# Result: Bundle[{v=1}]
```

| Extra | Type | Values |
|---|---|---|
| `v` | int | `1` |
| `calls` | string | `emergency`, `ordinary`, `unknown` or `none` |
| `at` | long | the module's look, in seconds since boot (`/proc/uptime`; Welcome's `elapsedRealtime` is the same clock) |
| `until` | long | for `emergency`, the end of its wait, between `at` and `at + 300`; else `0` |
| `ims` | string | the IMS registration: `cell`, `wifi`, `registered`, `none`, `unknown`, or `off` outside Phone mode |
| `ims_at` | long | the time of that reading; `0` with `off` |

Exactly these six, with these types; anything else is malformed: Welcome
throws `IllegalArgumentException` and forgets the word it held. Welcome
answers only `Result: Bundle[{v=1}]`, keeps the word in memory, never logs
or shows it, and has no way to read it back. The module sends it only
while Welcome is the device owner, and treats any other output as not
taken.

## What Welcome reads from the status page

`GET http://127.0.0.1:5380/status` (the DNS filter;
`antumbra/android/dnsfilter/internal/status`). The firewall allows it; the
network security config allows clear text to `127.0.0.1` only, and the app
connects nowhere else. Welcome accepts the document only if `service` is
`antumbra-dnsfilter`, and reads:

- the filter's own fields: `queries`, `blocked`, `list.loaded`,
  `list.size`, `list.version`, `upstream.state`;
- from `module` (the module's `run/status.json`, passed on by the filter),
  all optional:

| Field | Meaning |
|---|---|
| `module.tor.bootstrap` | tor's bootstrap progress, 0 to 100 (`GETINFO status/bootstrap-phase` PROGRESS) |
| `module.tor.summary` | its SUMMARY text |
| `module.tor.network` | `"enabled"` or `"disabled"` (DisableNetwork 0 or 1) |
| `module.tor.error` | why tor cannot connect (for example "these bridges need pluggable transports"); shown in the Tor card |
| `module.firewall.state`, `module.firewall.hash` | parsed, not shown (the firewall row uses the property only) |
| `module.welcome.started` | `true` once the module latched a session in this boot (a non-empty `module.welcome.session_id` is read the same way) |

The module writes `null` for an empty text field (`tor.error` is `null`
while tor has no complaint). For every text field, `null`, `""`, a
missing key and a value that is not a string all mean "none". (Android's
`JSONObject.optString` turns a JSON `null` into the text `"null"`, so the
parser does not use it.)

The module's file sits in a directory tor's uid can also write, and while
the filter is down any app could answer on its port. So Welcome only shows
it, and the one decision it takes part in can only refuse:
`welcome.started` stops a second Start, and only while
`antumbra.fw.armed` is set.

### Add-on check

At Start (and every three seconds on the Welcome screen) Welcome decides
whether the add-on is present: **the property `antumbra.fw.armed` holds a
hash, and nothing else counts.** Only root can set it, and the module sets
it only after the firewall's full rule set is live and verified. Apps can
read it: an unlisted property is `default_prop`, Android 16's sepolicy
grants `get_prop(coredomain, default_prop)` (private/coredomain.te), and
`untrusted_app` is a `coredomain` (private/untrusted_app.te). If a future
policy hid it, Welcome would see the add-on as absent and keep Wi-Fi off:
it fails closed. The status page never makes the add-on present: without
the firewall any app could serve that page. Without the add-on, Wi-Fi is
turned off and locked off for the session, whatever the Tor choice.
`welcome-adb.sh check-addon` checks on a device that Welcome reads the
property (the status screen's firewall row says "Live" with the
property's rules).

## Device-owner policies

Restrictions set by a device owner survive reboots, so the strict state is
applied at boot, on becoming the device owner, at shutdown and at every
Start; only a Start loosens anything (`Policies.kt`).

| Policy | When | Why |
|---|---|---|
| `DISALLOW_SAFE_BOOT` | always | Android's safe mode would start without third-party code, and Magisk loads no module in it. (Magisk's own safe mode is separate and not affected; the module's tmpfs Wi-Fi store covers it.) |
| `DISALLOW_CONFIG_TETHERING` | always | Tethered traffic is forwarded or offloaded (tc-BPF, IPA) below the firewall. |
| `DISALLOW_WIFI_DIRECT` | always | Wi-Fi Direct groups and discovery bypass the firewall and expose the device name. |
| `DISALLOW_CONFIG_PRIVATE_DNS` | always | The module sets private DNS off; a DNS-over-TLS host set by the user would go around the tracker filter. |
| `DISALLOW_NEAR_FIELD_COMMUNICATION_RADIO` | always (Android 15 and later) | NFC off; the 7T Pro has NFC. |
| `DISALLOW_DEBUGGING_FEATURES`, and `adb_enabled` and `adb_wifi_enabled` set to 0 | always, Administration included | USB and wireless debugging (and LineageOS's rooted debugging) give a shell below the firewall. Only the debug-build test hook keeps adb (see "Test hook"). |
| No DHCP host name (`WifiManager.setSendDhcpHostnameRestriction`, open and secure networks) | always (Android 15 and later) | Android 15 and later send the device name in DHCP option 12 on every Wi-Fi network, from below the firewall. |
| Automatic time off, automatic time zone off, time zone UTC | always | See "Automatic time". |
| `DISALLOW_INSTALL_UNKNOWN_SOURCES_GLOBALLY` | unless Administration | No apps from outside the preinstalled store. |
| `DISALLOW_BLUETOOTH` | unless Administration | Bluetooth tethering and nearby-device scans. |
| `DISALLOW_CONFIG_LOCATION`, and Location off | restriction unless Administration; Location switched off before Start and at every Start | Location, scans and GNSS through Tor still locate you. |
| Wi-Fi locked: `DISALLOW_CHANGE_WIFI_STATE`, `DISALLOW_CONFIG_WIFI`, `DISALLOW_ADD_WIFI_CONFIG`; Wi-Fi off, checked | before Start; offline sessions; add-on missing | Fail closed: no network without the add-on. A device owner can still switch Wi-Fi (`WifiServiceImpl`, Android 16), except in airplane mode (below). |
| Wi-Fi lock lifted, Wi-Fi on | Start, direct or bridges, add-on present | The user then adds a network in Settings. |
| `POST_NOTIFICATIONS` granted to itself | Start | The session notification. |
| `READ_PHONE_STATE` granted to itself | before Start (`Home.claim`) | "Return to call" (`TelecomManager.showInCallScreen`; see "Emergency calls"). WEL9's phone-state denial must leave Welcome out. |

"Administration" lifts the three "unless Administration" rows from Start
until the next shutdown; it never turns debugging on. The protective rows
(safe boot, tethering, Wi-Fi Direct, debugging, and the Wi-Fi lock when
Wi-Fi must stay off) refuse a network session when they fail.

**Wi-Fi in airplane mode.** Android 16 lets only Settings switch Wi-Fi in
airplane mode (`WifiServiceImpl.setWifiEnabled`: "only Settings can toggle
wifi"); a device owner is not privileged there. If the user switched Wi-Fi
on in airplane mode, Welcome cannot switch it off. Then:

- the configuration restrictions and the removed networks leave Wi-Fi
  nothing to join, before Start and in an offline session;
- Start checks the Wi-Fi state (up to 5 seconds) and refuses a network
  session that needs Wi-Fi off (add-on missing), saying why;
- a network session with the add-on needs Wi-Fi on anyway; if airplane
  mode keeps it off, the status screen asks the user to switch it on in
  Quick Settings (the lock is lifted by then).

Welcome does not use `DISALLOW_AIRPLANE_MODE`, which would force airplane
mode off: with a SIM and mobile data, that would bring up a cellular
network, in the clear when the module is missing. This also means the
pivot checks' fix (3), airplane mode on at shutdown, would only make every
Start ask the user to switch Wi-Fi on; a device owner cannot set airplane
mode in any case (`airplane_mode_on` is not in DevicePolicyManagerService's
global-settings allowlist), so it would be the module's job (as root).

Not set in v0:

- Location and nearby-device permissions set to denied for every app:
  needs a grant per installed app and on every new install (a
  package-added listener); later work. Location stays off and locked unless
  Administration, and Bluetooth is off.
- Hiding or suspending the Magisk app in user 0 outside a maintenance
  mode: the weekly "Install to inactive slot" update needs the app, and
  that maintenance mode does not exist yet (later work).
- Airplane mode at shutdown: impossible for a device owner (above).
- `DISALLOW_FACTORY_RESET`, factory-reset protection: kept off while the
  device owner must stay removable for trials.
- Security logging and network logging: never; they would record the
  session.

### Automatic time

`setAutoTimeEnabled(false)` is applied, for these reasons. Android's
automatic time asks an NTP server over UDP port 123 and the carrier (NITZ)
for the time. The firewall rejects that NTP query, so automatic time would
only fail, and on a boot without the module it would leave the phone in
clear. NITZ needs a SIM, which Antumbra does not use by default. Tails sets
the clock from Tor once Tor is connected, and the module is meant to do the
same (as root). With automatic time off, a time set by root is not
overwritten. The cost: the clock drifts if the module does not set it; Tor
tolerates some hours of error. Automatic time zone is off and the zone is
UTC, so apps learn nothing about where you are; a user may still change the
zone in Settings, and the next Start sets UTC again.

### Wi-Fi hardware address (MAC)

Android 16 already gives every saved network its own random MAC address by
default (`RANDOMIZATION_AUTO`). For most networks that address is
"persistent": derived from a secret kept in the device's keystore and from
the network's name, so the same network sees the same address in every
session, even when the module keeps the network list on tmpfs; Android
picks a fresh address only in some cases. [likely] What a device owner can
enforce:

- For networks it adds itself (Persistent Storage, later):
  `WifiConfiguration.setMacRandomizationSetting(RANDOMIZATION_NON_PERSISTENT)`
  (API 33), a new address per connection; and
  `WIFI_DEVICE_OWNER_CONFIGS_LOCKDOWN` so the user cannot change those
  networks. [likely: allowed to an admin for networks it created]
- It cannot change the setting of networks the user adds in Settings, and
  it cannot write `Settings.Global.non_persistent_mac_randomization_force_enabled`.

So for `mac = new` the module must set that global flag as root
(`settings put global non_persistent_mac_randomization_force_enabled 1`), and
clear IpMemoryStore so DHCP does not ask for the previous session's address.
For `mac = keep` it leaves Android's default (one random address per
network, stable across sessions). Welcome only records the choice; for the
same reason it cannot put the flag back to 1 at shutdown after a `keep`
session (that is the module's job).

### Test hook

For CI only. A **debuggable or testOnly** build honours the property
`debug.antumbra.keep_adb` (`TestHook.kt`); a release build never reads it.
With `1`, Welcome leaves USB debugging on in every session (it clears
`DISALLOW_DEBUGGING_FEATURES` and does not reset the adb settings), so a
session without Administration can be driven and checked over adb. With
`0`, debugging goes off at the next policy step (boot, Start, shutdown).
`debug.*` properties may be set by the shell user and read by every app
(sepolicy `set_prop(shell, debug_prop)`, `get_prop(domain, debug_prop)`).
They are lost at a restart, so Welcome keeps a marker in its
device-protected storage while the hook is on; the hook then survives
restarts until `0` is seen. Set it **before** `dpm set-device-owner`:
becoming the device owner already switches debugging off.

## Emergency calls

The **Emergency call** button (Welcome screen and status screen,
`EmergencyCall.kt`) opens the system's emergency dial pad: the activity
that handles `android.intent.action.DIAL_EMERGENCY` in a system app
(`com.android.phone/.EmergencyDialer` in AOSP), started as an explicit
intent so that an app installed later can neither stand in for it nor add
a chooser. That dial pad calls emergency numbers only and knows them for
the country, the network and the SIM (112, 911 or any other); Welcome
never names a number. It places the call through Telecom
(`TelecomManager.placeCall`), and Telecom shows the call on the **system
dialer's** call screen, which it always uses for emergency calls.

**Through the lock task before Start.** AOSP's `LockTaskController`
(android16-release, `isLockTaskModeViolationInternal`) lets three kinds of
activity start in a task of their own during a locked task, and only while
`LOCK_TASK_FEATURE_KEYGUARD` is set: the emergency dial pad
(`TelecomManager.EMERGENCY_DIALER_COMPONENT`), the `CALL_EMERGENCY` intent,
and any activity of the system dialer package. Welcome sets that feature
next to `GLOBAL_ACTIONS` (`Home.LOCK_TASK_FEATURES`). Without it, the call
screen (the dialer's in-call activity, which has a task of its own) and the
power menu's Emergency entry (which starts the dial pad with
`FLAG_ACTIVITY_NEW_TASK`) are refused. Welcome's own button starts the
dial pad inside Welcome's locked task, which an activity may always join,
so the button works even without the feature; the call screen does not.
(Cell broadcast emergency alerts are let through either way.)

Why the keyguard feature and not the lock-task allowlist, and what either
costs before Start:

- **The keyguard comes back.** Without the feature the
  locked task holds the keyguard off, even with a PIN. With it the keyguard
  behaves as outside the locked task: with no screen lock nothing changes;
  with a swipe lock the swipe screen comes back after the screen goes off;
  with a PIN, the PIN is asked before the Welcome screen (and the bouncer's
  own Emergency call button works). The notification shade, Home and
  recents stay off: the status bar flags of the locked task do not depend
  on it.
- **The allowlist is wider.** The power menu's Emergency entry needs
  `com.android.phone` on the list, and the call screen the dialer
  package. Every activity of both packages (call settings, the full dialer)
  could then start in the locked task, they could lock tasks of their own,
  and Welcome would have to find their names at run time.
- **Ordinary calls before Start**: the keyguard feature, like the
  allowlist, lets every activity of the system dialer through. The
  emergency dial pad itself refuses a number that is not an emergency
  number, but the call screen of *any* call now shows before Start: an
  incoming call's, and the emergency service calling back is an ordinary
  incoming call. That screen's **Add call** button, which Telecom offers
  whenever no emergency call is in progress (`CallsManager.canAddCall`),
  opens the full dialer (`TelecomAdapter.addCall`: `ACTION_DIAL` in a new
  task), and the exemption lets it in. From there the person can place
  ordinary calls and open the call log and the dialer's settings, and
  whatever the dialer starts without `FLAG_ACTIVITY_NEW_TASK`, from any
  package, joins that task: for a task that exists, the lock task checks
  only its root intent. Before WEL7 all of these call screens were
  refused. No setting avoids it: the call screen needs the dialer package
  with either option, and `LOCK_TASK_FEATURE_BLOCK_ACTIVITY_START_IN_TASK`
  would block the call screen as well
  (`ActivityStartInterceptor.interceptLockTaskModeViolationPackageIfNeeded`).
  With the cellular radio off before Start (MOD6) no call comes in, which
  closes this route.
- **"Emergency information" is refused before Start.** The emergency dial
  pad's button for the owner's emergency information (medical details,
  emergency contacts) starts EmergencyInfo's `ViewInfoActivity`, which is
  `singleTask` with the task affinity `com.android.settings`, so it opens
  in a task of its own; `com.android.emergency` is neither exempt nor on
  the allowlist, and the lock task refuses it with its toast. It works
  after Start. Welcome does not put EmergencyInfo on the allowlist: its
  editing screens share that task affinity, and its contact picker would
  open further apps inside the lock task.

**Back to the call** (`EmergencyCall.returnToCall`). Before Start the
locked task keeps the notification shade, the ongoing-call chip, recents
and Home off (`LockTaskController.getStatusBarDisableFlags` clears none of
them for Welcome's features), so once the call screen leaves the front
(Back on the call screen does that, unless the dial pad is open or a call
is ringing) nothing else leads back to it. While a call is in progress
(`CallWatch`: `MODE_IN_CALL` or `MODE_CALL_REDIRECT`), the Welcome screen
shows **Return to call**, which calls `TelecomManager.showInCallScreen`:
Telecom asks the system dialer's in-call service to start its call screen
again, in a task of its own, which the keyguard feature lets in. That API
needs `READ_PHONE_STATE`, a runtime permission Welcome grants itself as the
device owner (`Home.claim`, so before Start; it is not one of the sensor
permissions Android keeps from admins). The call screen gives back hang
up, mute, the speaker and the keypad for tones. A boot broadcast that
arrives during a call (`BOOT_COMPLETED` comes after the first unlock when a
PIN is set) does not bring Welcome over the call screen. Limit: the
button appears only once the audio mode says a call is in progress, not
while the call is still connecting.

**Quick power off waits for emergency calls** (`CallWatch`). Quick power
off never cuts a call short and never switches off while the emergency service may
call back. It refuses, and says why: during a call; while Android reports
emergency callback mode; and for 5 minutes after any call ends (the length
of Android's own default emergency callback mode,
`EmergencyStateTracker`). Welcome cannot tell an emergency call from any
other call by itself: `TelecomManager.isInEmergencyCall` needs `MODIFY_PHONE_STATE`
and `TelephonyManager.getEmergencyCallbackMode` needs
`READ_PRIVILEGED_PHONE_STATE`; both are system APIs behind permissions only
the platform and privileged apps hold, which a device owner cannot grant
itself. So every call counts, unless the module says otherwise (below).
What Welcome reads, with no permission:

- the audio mode (`AudioManager.getMode`, and a mode listener for the life
  of the process, from `WelcomeApp`): `MODE_IN_CALL` or `MODE_CALL_REDIRECT`
  means a SIM call is dialling, active or held. Only holders of
  `MODIFY_PHONE_STATE` may set those modes (`AudioService.setMode`), so no
  app can fake a call, and a VoIP call (`MODE_IN_COMMUNICATION`) does not
  hold Quick power off;
- emergency callback mode from the sticky, protected
  `ACTION_EMERGENCY_CALLBACK_MODE_CHANGED` broadcast, which the phone
  process sends without a permission, on networks that use the mode.

**The module's word (MOD11).** The module, as root, reads Telecom's own
record of each call (`isEmergency`, set from Android's emergency-number
list, and the network's emergency flag) and tells Welcome after each of
its looks, through the provider (above), what the calls of the last 5
minutes were. It changes one thing only:

| The module's word | Quick power off after a call it saw end |
|---|---|
| `ordinary`, at most 30 s old, from a look after that call ended | goes ahead: the module knows every call of the last 5 minutes, that one included, was not an emergency call. The module says it only in a Phone-mode session (WEL8); outside it the cell radio is off, so a carrier call there is an emergency call, a Wi-Fi call (until MOD7) or follows a switch-on by something else, which the module cannot tell apart, and it says `unknown` after every call |
| `emergency` | waits as before, and at least until the word's end (at most 5 minutes after the module's look), even if Welcome saw no call (its process restarted, or an emergency text with callback mode) |
| `unknown`, `none`, an `ordinary` word that is older or from a look before the end, a malformed or refused word, no word at all (the module not running, Android 17, which no longer keeps that record) | waits exactly as before |

During a call and in callback mode it waits whatever the word says, and a
later word never shortens an emergency word's wait. The texts are the same.
Until WEL8 every session is outside Phone mode, so the module never says
`ordinary` and Quick power off waits after every call, exactly as before
MOD11.
Wi-Fi calling is a carrier call (`MODE_IN_CALL`, an entry in Telecom like
any SIM call) and counts like one; VoIP apps use `MODE_IN_COMMUNICATION`,
so Quick power off has never waited for them.

The end of the last call and the module's last word are kept in memory
only, like the session. Not covered: a call that is still connecting (the
radio being switched on for an emergency call, a few seconds, before the
audio mode changes; after an ordinary call the module's next look, about
10 s later, sees it), and a call that ended before Welcome's process started
(unless the module calls it an emergency call). The power menu's Power
off is never held: the message says how to switch off on purpose.
Android's own restart (`DevicePolicyManager.reboot()`) also refuses during
any call.

## Quick power off

The immediate power-off (`QuickPowerOff.kt`): the Quick Settings tile, the
session notification's action and the status screen's **Power off now**.
It was called "Emergency off" until WEL7 and "Panic off" until WEL12:
where the emergency number is 112, a "panic button" on a phone means an
emergency call, so the name must never suggest one. It has nothing to do
with emergency calls, and it waits for them (see "Emergency calls").

**Never on the power button.** No Antumbra action, in Welcome or in the
module, is ever bound to presses of the power button, repeated or held.
Android's own emergency gesture (pressing power five times quickly,
"Emergency SOS"; whether anything handles it on the phone is PH4's
question) and the power menu's **Emergency** item belong to the system,
and Antumbra leaves both as they are: someone who presses power several
times or opens the power menu in an emergency must reach an emergency
call, never a power-off. A trigger from another app (WEL4: a PanicKit app
such as Ripple) is acceptable only if it is not bound to the power button
either. The power menu itself stays
available before Start (`LOCK_TASK_FEATURE_GLOBAL_ACTIONS`), and CI checks
that its Emergency item shows there (`check-power-menu`, below).

A device owner cannot power the phone off. Android gives it one power
action, `DevicePolicyManager.reboot()`. A real power-off needs
`android.permission.SHUTDOWN`, which is `signature|privileged|role` in
Android 16's core manifest. So `QuickPowerOff.trigger`, unless a call holds
it (see "Emergency calls"):

1. If the app holds `SHUTDOWN`, starts the system's `ShutdownActivity`
   (`com.android.internal.intent.action.REQUEST_SHUTDOWN`, no confirmation).
   The app holds it only if the module installs it as a privileged app
   with an allowlist file:
   ```xml
   <!-- MODDIR/system/etc/permissions/privapp-permissions-org.antumbra.welcome.xml -->
   <permissions>
       <privapp-permissions package="org.antumbra.welcome">
           <permission name="android.permission.SHUTDOWN" />
       </privapp-permissions>
   </permissions>
   ```
   with the APK at `MODDIR/system/priv-app/AntumbraWelcome/AntumbraWelcome.apk`.
   Never install it in `priv-app` without that file: with
   `ro.control_privapp_permissions=enforce`, a privileged app that requests
   an unlisted privileged permission stops the phone from booting.
2. Otherwise writes `/data/user_de/0/org.antumbra.welcome/files/poweroff-requested`
   and calls `DevicePolicyManager.reboot()`. **Proposed module contract:**
   early in the next boot (post-fs-data, once `/data/user_de/0` is readable
   there, or at the start of `service.sh`), the module checks for that
   file, deletes it, and powers off at once (`reboot -p`) before starting
   anything else.

The marker's life: Welcome never deletes it at boot, where it would race
the module. It deletes a leftover marker at Start and on becoming the
device owner (by then the module had its chance), and at a shutdown that
its own process did not ask for (`QuickPowerOff.requested`), so a request the
module did not act on never powers off a later boot.

What this gives today, without the module's help: a restart. A restart ends
the session (tor's state is on tmpfs, the Welcome screen returns, choices
are gone), and the module wipes what it wipes at boot. It is weaker than a
power-off against someone holding the phone: memory keeps traces for a short
while after a warm restart. The status screen says which of the two the
button does.

**From the lock screen.** The restart path (`DevicePolicyManager.reboot()`)
asks for nothing. The power-off path starts `ShutdownActivity` through
`TileService.startActivityAndCollapse`, which SystemUI runs only after
dismissing the keyguard; with a secure lock screen (the planned
Persistent user) it would therefore ask for the PIN first. Unverified on
the phone; the alternative, starting `ShutdownActivity` directly from the
tile service (device owners are exempt from background-start limits), is
to be tested there.

Before Start the tile is out of reach (locked task); the power menu works.
`DevicePolicyManager.reboot()` refuses during a phone call; then the session
goes on and the message says why.

## Bridges

`Bridges.kt` checks every line, typed or built in, before it reaches the
module, as the archived Debian Antumbra did (`antumbra.settings`):

- accepted: plain bridges (`IPv4:port [fingerprint]`), and `obfs4`,
  `webtunnel` and `meek_lite` once pluggable transports are available; a
  leading `Bridge` is dropped, blank lines and `#` comments are skipped;
- refused, with the reason: Snowflake (it needs UDP, which the firewall
  allows to nobody), IPv6 addresses for obfs4 and plain bridges (IPv6 is
  off), unknown or obsolete transports (obfs2, obfs3, scramblesuit), a bad
  fingerprint, an obfs4 line without `cert=`, a webtunnel or meek_lite line
  without `url=`, more than 20 bridges, lines over 600 characters, and any
  character outside printable ASCII or `"` or `\` (so no line can break
  out of the control port's quoting).

**Pluggable transports are not available in v0.** obfs4, webtunnel and
meek_lite need the pluggable-transport helper (lyrebird) and a
`ClientTransportPlugin` line in the module's torrc; the module does not
include lyrebird yet and refuses such bridges. So Welcome refuses them
first, with the reason, instead of starting a session that cannot connect
(`Bridges.TRANSPORTS_AVAILABLE = false`), and the built-in (obfs4) bridges
are shown as not available yet. Only plain bridges work. If the module
reports a reason anyway (`module.tor.error`), the Tor card shows it.

The bridge text field uses a password keyboard type with visible text, so
keyboards neither learn nor suggest from it, and the window is
`FLAG_SECURE` (no screenshots, no recents thumbnail) while typed bridges
are on screen.

**Built-in bridges** are Tor Browser's own obfs4 lines from
tor-browser-build `projects/tor-expert-bundle/pt_config.json` at a pinned
commit (2026-04-09). `tools/builtin-bridges.sh` downloads that file over
HTTPS, refuses it unless its SHA-256 matches the pin, checks the form of
each line, and writes the asset; `--check` fails if the asset differs. The
lines are data, not code. They stay in the APK for when lyrebird ships.

## Driving it over adb

`ci/welcome-adb.sh` (run it without arguments for help), with a debug
build:

```sh
W=antumbra/android/welcome/ci/welcome-adb.sh
$W install app-debug.apk
$W provision                                   # test hook on, dpm set-device-owner, waits for Start
$W check-emergency                             # before Start: the emergency dialer opens from the lock task; dials nothing
$W check-power-menu                            # before Start: the power menu shows its Emergency item (never pressed); menu closed
$W screenshot welcome.png
$W start --tor bridges --bridges-file plain-bridges.txt
$W expect started=1 tor_mode=bridges bridges=2
$W check-policies                              # add --admin, --keep-adb, --wifi-locked as they apply
$W check-addon                                 # Welcome reads antumbra.fw.armed (opens the status screen, scrolls to the row)
$W screenshot status.png
$W power-off-tile                              # waits until the boot id changes
$W wait-welcome 180
$W start --tor offline --expect-adb-loss       # last: clears the hook; adb goes away at Start
```

It finds controls by their resource ids through `uiautomator dump`, taps
them with `input tap`, and checks results through the provider (as the shell
user), `dumpsys user`, `settings`, `cmd wifi` and `getprop`. Without the
test hook, Welcome switches USB debugging off at provisioning and in every
session, Administration or not; `start` refuses to run then unless
`--expect-adb-loss` says that losing adb is the point.
`ci/test-welcome-adb.sh` runs the script against a fake adb.

`check-emergency` runs before Start, while Welcome holds its lock task. It
opens the emergency dialer twice, with Welcome's Emergency call button (the
dialer joins Welcome's task) and with `am start -n <dialer>` (a task of its
own, the way the power menu starts it, which only
`LOCK_TASK_FEATURE_KEYGUARD` lets in), and each time checks in
`dumpsys activity activities` that the dialer is the resumed activity,
presses Back, and checks that Welcome is resumed again and the lock task
still `LOCKED`. **It never dials**: it touches nothing in the dialer, types
no number, and requires the call state (`dumpsys telephony.registry`) to be
idle before it starts and after each opening; a dump without a call state
fails the check rather than counting as idle. Never test emergency calls by dialling a real
emergency number; for an end-to-end test use
`cmd phone emergency-number-test-mode -a <harmless number>:normal` as root,
never with `emergency` or `unknown` routing.

`check-power-menu` (WEL12) also runs before Start, in Welcome's lock task,
and only looks. The power menu has one of two items labelled
**Emergency**, and a dump cannot tell them apart (same label, same view
ids; only the icon differs): SystemUI's `EmergencyDialerAction`, which
opens the emergency dial pad and dials nothing, or, while Android's
emergency affordance is on, `EmergencyAffordanceAction`, which **calls at
once** (`EmergencyAffordanceManager.performEmergencyCall`: `CALL_EMERGENCY`
to `config_emergency_call_number`, 112 in AOSP). The affordance is on when
`force_emergency_affordance` (a test setting) or `emergency_affordance_needed`
(which Android sets when the SIM's or the network's country is in
`config_emergency_iso_country_codes`) is not 0. So the check runs only
while both are unset or 0, and then the item it sees is the dial-pad one.
It changes no emergency setting, registers no test number, presses nothing
on the keyguard, and never presses the item:

1. Refuses, with nothing changed, unless Welcome is in front and `LOCKED`,
   no call is in progress, and the emergency affordance is off (both
   settings read back as unset or 0; unreadable counts as on).
2. Opens the power menu with `input keyevent --longpress KEYCODE_POWER`,
   with `power_button_long_press` set to 1 meanwhile (AOSP's
   `config_longPressOnPowerBehavior` is 5, the assistant; the old value is
   kept in `/data/local/tmp` and put back).
3. Finds the menu in `uiautomator dump` by SystemUI's "Power off",
   "Restart" or "Power" (the keyguard's bouncer also has a SystemUI button
   labelled "Emergency", so that label alone does not prove the menu), and
   "Emergency" in it; takes the screenshot if asked.
4. Closes the menu without touching it: Back, and if a dump still shows
   the menu (or fails), the screen off and on (SystemUI's
   `GlobalActionsDialogLite` closes on `ACTION_SCREEN_OFF`).
5. Checks that Welcome is in front, still `LOCKED`, with no call, and that
   the affordance is still off (so the item seen was the dial-pad one),
   then puts `power_button_long_press` back. A failure, a kill (`INT`,
   `TERM`, `HUP`) or an error after step 1 runs the same reset
   (`clear-power-menu-test`): the menu closed first, then the setting.

The item that calls at once, and a call through either item with a
stand-in number, stay PH4's, on the phone: forcing that item on the
emulator would add a one-tap emergency call to every power menu opened
meanwhile without proving anything a dump can show, and a test call is not
proven to keep normal routing (with domain selection,
`TelephonyConnectionService` can redial an emergency call with emergency
routing, `EXTRA_USE_EMERGENCY_ROUTING`).

`check-policies` reads only user 0's "Effective restrictions" in
`dumpsys user`: the dump also lists the guest's default restrictions
(`no_config_wifi` among them) and each user type's. `check-addon` opens
the status screen when something else is in front and scrolls down to the
firewall row, since uiautomator lists only what is on screen.

**CI.** The emulator job (`antumbra/android/ci/emulator-antumbra.sh`)
drives Welcome itself with the same test tags and provider URI, and calls
this script only for `check-emergency` (before Start, check
`welcome_emergency_dialer`), `check-power-menu` (right after it, check
`welcome_power_menu_emergency`, a warning until it has passed on CI once),
`check-policies --keep-adb` and `check-addon`. It
must set `debug.antumbra.keep_adb 1` before `dpm set-device-owner` to keep
adb. The Welcome job in
`.github/workflows/antumbra-android.yml` builds the debug APK and runs the
unit tests.

## Verified, and not yet

Verified locally (2026-10-11, again for emergency calls on 2026-10-12, and
for Quick power off and the power menu check on 2026-10-13; no emulator
here):

- `./gradlew assembleDebug assembleRelease lintDebug testDebugUnitTest`
  passes with dependency verification on (checksums and signatures, key
  servers off; a build without the keyring fails verification): no lint
  issues, 49 unit tests
  (bridge rules, including transports refused while lyrebird is missing,
  and the built-in asset; the provider's columns, values, caller rule and
  projection; the status-page parser, the property-only add-on rule, the
  latched-session and tor-error fields, null or empty text as none; the
  policy lists and which failures refuse a network session; the lock
  task's features (keyguard and power menu, no Home, recents or shade);
  which audio modes count as a call, when Quick power off waits, and the
  call in progress that shows "Return to call"; its permission and text;
  no "Emergency off", no "panic" and no number in the texts, and the tile
  and the notification action under the label "Quick power off"; MOD11
  (2026-10-15): only uid 0 may give the module's word, a forged word (an
  app, the shell, the system) refused with the held word unchanged, every
  malformed word refused, and the three states: a fresh `ordinary` word
  from after the call lets Quick power off go, a stale, early or future
  one does not; `emergency` makes it wait until the word's end, with or
  without a call it saw, and no later word shortens that; `unknown`,
  `none`, missing, forged and malformed words, and no module, wait exactly
  as before at every whole second of the 5 minutes and 999 ms after each;
  during a call and in callback mode every word waits; the IMS reading
  counts for 15 minutes; the word is never logged; a forged word is
  refused before its extras are read, and the provider's `call` hands
  `Binder.getCallingUid()` straight to that one check (a JVM test reads
  the provider's source for it; that the binder gives the caller's uid
  there is checked on the emulator only, `welcome_module_word`, which
  passed in run 20: the shell's word refused, root's taken)).
- `ci/welcome-adb.sh` and `ci/test-welcome-adb.sh` pass shellcheck, and the
  fake-adb test passes: bridge lines with `[`, `]`, `+`, `/`, `=` are
  typed, `;`, quotes and `\` refused; the test-hook rule; check-policies
  (user 0's restrictions only, the guest's defaults ignored); check-addon
  (the launcher in front, the row below the fold, "Checking…", other
  rules or "Not running" refused); check-emergency (the dialer opened by
  the button and by `am start`, refused either way, stuck after Back, the
  lock task ending while the dialer is open, a call appearing after the
  first opening, no lock task, a call in progress, no call state to read,
  no emergency dialer; nothing that could dial is ever sent);
  check-power-menu (the emergency affordance read as off before the menu
  opens, the long-press setting set and put back, the menu found by its
  own items and its Emergency item seen, never pressed, no emergency
  setting or test number touched, the menu closed with Back, or with the
  screen off and on when Back does not close it; a menu without the item,
  no menu, the keyguard's bouncer (its "Emergency" is not the menu's), the
  affordance coming on during the check, a long-press setting that does
  not take, and a kill while the menu is open all fail and put everything
  back, the earlier long-press value included; a menu that stays open
  fails and still gets its long-press setting back; refused with nothing
  changed when the affordance is forced, needed or unreadable, with no
  lock task or a call in progress); clear-power-menu-test (an open menu
  closed and the saved value put back; a value it did not save left
  alone); check-module-word (only "none" and malformed words sent; fails
  when the shell user's or a malformed word is taken, when root's is not,
  and without adb as root); expect.
- `tools/builtin-bridges.sh` and its `--check` against the pinned source.
- Framework behaviour read in Android 16 sources (android16-release):
  `ACTION_SHUTDOWN` is sent registered-only and deferred for cached
  processes; device owners may start activities from the background; a
  device owner may toggle Wi-Fi under `DISALLOW_CHANGE_WIFI_STATE` but not
  in airplane mode; `setSendDhcpHostnameRestriction` accepts the device
  owner; `adb_enabled`, `adb_wifi_enabled` and `private_dns_mode` are in
  DevicePolicyManagerService's global-settings allowlist;
  `removeNonCallerConfiguredNetworks` is for device owners;
  `DevicePolicyManager.reboot()` refuses during a call; `ShutdownActivity`
  requires `SHUTDOWN` (`signature|privileged|role`); apps may read
  `default_prop` and `debug_prop`; the `content query` output format.
  For emergency calls: `LockTaskController`'s exemption needs
  `LOCK_TASK_FEATURE_KEYGUARD` and covers the emergency dial pad, the
  `CALL_EMERGENCY` intent and the system dialer's package (so also the
  call screen of an ordinary call, and the full dialer that its "Add call"
  button starts in a new task, `TelecomAdapter.addCall`; Telecom offers
  "Add call" unless an emergency call is in progress), besides letting the
  keyguard show; for a task that exists only its root intent is checked;
  `LOCK_TASK_FEATURE_BLOCK_ACTIVITY_START_IN_TASK` would block the call
  screen too; an activity started without `FLAG_ACTIVITY_NEW_TASK` from
  inside a locked task is allowed (`ActivityStarter.isAllowedToStart`),
  also into a home task; the power menu's Emergency entry starts the dial
  pad in a new task; Telecom shows emergency calls on the system dialer's
  call screen; the emergency dial pad refuses numbers that are not
  emergency numbers; its "Emergency information" button opens
  EmergencyInfo in a task of its own (`singleTask`, affinity
  `com.android.settings`), which the lock task refuses; Back on the call
  screen leaves it, and the locked task's status bar flags keep the shade,
  the ongoing-call chip and recents off; `TelecomManager.showInCallScreen`
  needs only `READ_PHONE_STATE`, a runtime permission a device owner may
  grant itself;
  `isInEmergencyCall` and `getEmergencyCallbackMode` are system APIs behind
  `MODIFY_PHONE_STATE` and `READ_PRIVILEGED_PHONE_STATE`; only
  `MODIFY_PHONE_STATE` holders may set `MODE_IN_CALL`; the emergency
  callback mode broadcast is sticky, protected and sent without a
  permission, and its default length is 5 minutes.
  For the power menu (WEL12): SystemUI's `GlobalActionsDialogLite` builds
  its items when the menu opens (again only on a rotation or a
  configuration change, never on a settings change) and, when
  `EmergencyAffordanceManager.needsEmergencyAffordance()` (the global
  `force_emergency_affordance`, on any build, or
  `emergency_affordance_needed`, which `EmergencyAffordanceService` sets
  from the SIM's and the network's country; nothing else) puts the
  affordance's Emergency item first in place of the dial-pad one
  (`EmergencyDialerAction`, shown whenever the device has telephony; AOSP's
  `config_globalActionsList` starts with it); both are labelled
  "Emergency", with the same view ids, and show over the keyguard and
  before provisioning; the affordance's item sends `CALL_EMERGENCY` in a
  new task to `config_emergency_call_number` (112 in AOSP), or to
  `emergency_affordance_number` on debuggable builds only, read when it is
  pressed; the menu closes on `ACTION_SCREEN_OFF`; the keyguard bouncer's
  emergency button is labelled "Emergency" too
  (`lockscreen_emergency_call`); `config_longPressOnPowerBehavior` is 5
  (the assistant) in AOSP and the emulator's overlays do not change it,
  `power_button_long_press` overrides it, and an injected long press
  (`input keyevent --longpress`) reaches the power key's long-press rule;
  Telephony can redial a normal-routed emergency number with emergency
  routing.

Only CI (the API 36 emulator) or the phone can verify: provisioning, the
locked task and home switching, every policy taking effect (including the
DHCP host name and NFC), adb going away at provisioning without the hook,
Welcome reading `antumbra.fw.armed`, the Wi-Fi state check and airplane
mode, the provider answering root and shell and refusing others, the
module's word taken from root and refused from the shell (the emulator
job's `welcome_module_word`, passed in run 20), the status
page through the real firewall, the tile and the restart, the shutdown
receiver, `FLAG_SECURE`, the emergency dialer opening from the lock task
(the emulator job's `welcome_emergency_dialer` check), the power menu's
Emergency item in the lock task (`welcome_power_menu_emergency`, not yet
run on CI), and a stand-in emergency number reaching the call screen
before Start, from the emergency dial pad and from the power menu's item
(the dial-pad one, and the one that calls at once where the emergency
affordance is on), "Return to call" bringing it back after Back, Quick power off waiting
during that call, and the keyguard before Start with a swipe lock or a PIN
(the phone, PH4).

## Open risks

- **The session lives in one process.** The foreground service makes its
  death unlikely, not impossible; the module must latch (see the provider
  contract), and Welcome refuses a second Start only while the module's
  status says it latched one.
- **The first seconds after a crash.** If the phone lost power during a
  session, the launcher is home at the next boot until
  `LOCKED_BOOT_COMPLETED` arrives and Welcome takes over again. The network
  stays closed meanwhile only because of the module (and Wi-Fi was locked
  off by the previous shutdown, if there was one). An Administration
  session's loosening likewise lasts until that broadcast.
- **Wi-Fi switched on by hand in airplane mode** cannot be switched off by
  Welcome; it has nothing to join, and a network session without the
  add-on is refused (see "Wi-Fi in airplane mode").
- **Quick power off waits after every call** unless the module's fresh
  word says it was an ordinary call (MOD11), which it says only in a
  Phone-mode session (WEL8; until then it waits after every call):
  Welcome cannot tell calls apart without system permissions, and on
  Android 17 the module cannot either. A call that is still connecting (a few seconds) is not seen
  (after an ordinary call, until the module's next look), and the end of a
  call is known only to the process that saw it. An emergency text without
  callback mode is not seen at all. The power menu's Power off always
  works.
- **The module's word trusts uid 0.** Anything running as root could tell
  Welcome a call was ordinary; root is the module's equal (it could
  switch the firewall off), and no app gets root.
- **The keyguard shows before Start** when a swipe lock or a PIN is set
  (`LOCK_TASK_FEATURE_KEYGUARD`, the price of emergency calls through the
  lock task).
- **Before Start, an incoming call opens a way to the dialer**: its call
  screen shows, and "Add call" opens the full dialer, its call log and
  settings, and what they start in that task (see "Emergency calls"). The
  same feature lets emergency calls through, so no setting avoids it;
  keeping the cellular radio off before Start (MOD6) does.
- **Quick power off restarts rather than powers off** unless the module
  installs Welcome as a privileged app or implements the power-off request.
- **Bridges need lyrebird**, which the tor part does not build yet; only
  plain bridges work in v0.
- **The provider's caller check trusts uid 2000.** Anything running as the
  shell user (adb, or an app with Shizuku-style shell access) can read the
  bridge lines. With debugging off in every session this needs root or the
  debug-build test hook.
- **Dependency pins are trust on first use** for the 86 unsigned
  artifacts, and the trusted keys themselves were taken from key servers on
  first use; a key listed for a whole group (for example `androidx.core`)
  also accepts that publisher's other versions.
