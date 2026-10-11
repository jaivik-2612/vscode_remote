# Antumbra Welcome (Android)

The Welcome app is the device owner of an Antumbra phone, and its home
screen until the session starts. At every boot it asks the questions the
Tails Welcome Screen asks: connect to Tor directly, through bridges, or
stay offline; use a new Wi-Fi hardware address; Administration; the Unsafe
Browser. It applies the device-owner policies for the session and hands the
choices to the Antumbra module through a content provider. After Start it
shows Tor's progress and the tracker filter's counters, and offers an
emergency power-off.

Package `org.antumbra.welcome`. Kotlin, Jetpack Compose with Material 3.
compileSdk and targetSdk 36 (Android 16, LineageOS 23.2), minSdk 34.

| Path | What it is |
|---|---|
| `app/src/main/java/org/antumbra/welcome/` | The app (one file per part; see below) |
| `app/src/main/assets/builtin-bridges-obfs4.txt` | Tor Browser's built-in obfs4 bridges, written by `tools/builtin-bridges.sh` |
| `app/src/test/` | JVM unit tests: bridge checks, the provider's row, the status-page parser |
| `ci/welcome-adb.sh` | Installs, provisions and drives the app over adb (CI emulator job, or by hand) |
| `tools/builtin-bridges.sh` | Rewrites or checks the built-in bridges from a pinned, checksummed source |
| `gradlew`, `gradle/wrapper/gradle-wrapper.properties` | The pinned Gradle (see "Building") |
| `gradle/libs.versions.toml` | Every plugin and library version |
| `gradle/verification-metadata.xml` | SHA-256 of every artifact the build resolves |

## The screens

1. **Welcome** (`WelcomeActivity`, `ui/WelcomeScreen.kt`). Title "Welcome to
   Antumbra", then:
   - **Tor**: *Connect to Tor directly* (default), *Connect through bridges*
     with *Built-in bridges (obfs4)* or *Bridges I enter* (a text field, one
     bridge line per line), or *Stay offline*.
   - **Network**: *New Wi-Fi hardware address*, on by default.
   - **Persistent Storage**: shown, disabled, "Not set up yet" (v0).
   - **Additional settings**: *Administration*, off; *Unsafe Browser*, off.
   - A large **Start Antumbra** button that stays above the keyboard and the
     navigation bar.

   A red banner says when the add-on is not running (Wi-Fi then stays off
   for the session) or when Welcome is not the device owner.
2. **Status** (`StatusActivity`, `ui/StatusScreen.kt`), after Start, and the
   "Antumbra" entry in the launcher: Tor's bootstrap progress, the tracker
   filter's counters (lookups, blocked, domains on the list, list version),
   the session's choices and the firewall state, buttons for Wi-Fi settings
   and for adding the Quick Settings tile, and a **Power off now** button
   that stays on screen. It polls `http://127.0.0.1:5380/status` every two
   seconds while visible.
3. **Emergency off**, a Quick Settings tile (`EmergencyTileService`), plus
   the same action in the session's ongoing notification. One tap, no
   question asked, also from the lock screen. See "Emergency off" for what
   it can and cannot do.

Visual design: the Material 3 "tonal spot" dark scheme from the seed
`#4d2c9e`, the same values as the archived theme
(`antumbra/config/rootfs/usr/share/antumbra/theme/shell.css`), completed with
the roles that file did not need (generated once with
material-color-utilities 0.3.0; only the values are kept, in `ui/Theme.kt`).
System font (Roboto). Rows are at least 72 dp tall, buttons 56 to 64 dp.
Laid out for 412 dp wide phones and narrower.

The UI's test tags are exposed as resource ids
(`testTagsAsResourceId`), so uiautomator and `ci/welcome-adb.sh` find
controls by name: `tor_direct`, `tor_bridges`, `tor_offline`,
`bridges_builtin`, `bridges_custom`, `bridges_text`, `switch_mac`,
`switch_admin`, `switch_unsafe_browser`, `start_button`, `status_title`,
`card_tor`, `tor_progress`, `card_filter`, `filter_queries`,
`filter_blocked`, `row_firewall`, `wifi_settings`, `add_tile`,
`poweroff_button`.

## Building

```sh
cd antumbra/android/welcome
export ANDROID_HOME=/opt/android-sdk        # platforms;android-36 and build-tools;36.0.0
./gradlew assembleDebug                     # app/build/outputs/apk/debug/app-debug.apk
./gradlew testDebugUnitTest lintDebug       # unit tests and lint
./gradlew assembleRelease                   # app/build/outputs/apk/release/app-release-unsigned.apk
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
(assembleDebug, assembleRelease, lintDebug, testDebugUnitTest on Linux).
Gradle refuses an artifact whose checksum differs or is missing. After
changing a version, regenerate it and review the diff:

```sh
./gradlew --write-verification-metadata sha256 assembleDebug assembleRelease lintDebug testDebugUnitTest
```

A build on macOS or Windows resolves a different AAPT2 artifact and needs
its checksum added the same way.

**Outputs** (measured 2026-10-11): `app-debug.apk` 29.2 MB (not minified;
Compose debug builds are large), `app-release-unsigned.apk` 2.0 MB (R8
minified and resources shrunk). Release APKs are left unsigned; CI signs
them with the project key. Build outputs and the Gradle cache are ignored
(`.gitignore`) and never committed.

Debug builds are marked `android:testOnly` (`app/src/debug/AndroidManifest.xml`):
`adb install` needs `-t`, and a test device owner can be removed again
without a factory reset. Release builds are not testOnly; whether the
phone's build should be is a decision for RC1 (pivot checks).

## Installing and provisioning

The device must have no accounts (a fresh emulator or a freshly installed
LineageOS has none). Then:

```sh
adb install -t app-debug.apk                       # -t: debug builds are testOnly
adb shell dpm set-device-owner org.antumbra.welcome/.AdminReceiver
```

Welcome takes over at once: it becomes the home screen, locks its task,
applies the baseline policies, turns Wi-Fi off and locks it off until Start.

To remove a test device owner (testOnly builds only):

```sh
adb shell dpm remove-active-admin org.antumbra.welcome/.AdminReceiver
adb uninstall org.antumbra.welcome
```

A release (non-testOnly) device owner can only be removed by a factory
reset. Replacing it later needs the same signing key.

`ci/welcome-adb.sh` wraps these steps; see "CI".

## How a session runs

**Before Start** (at boot, on becoming the device owner, and again at
shutdown for the next boot; `BootState`, `Home`):

- Welcome is enabled, is the persistent preferred home activity, and runs
  as a locked task: no notification shade, no recents, no other app. The
  power menu stays (`LOCK_TASK_FEATURE_GLOBAL_ACTIONS`). Back does nothing.
- The baseline policies are applied (next section).
- Wi-Fi is turned off and `DISALLOW_CHANGE_WIFI_STATE` is set; saved Wi-Fi
  networks are removed (`removeNonCallerConfiguredNetworks`). With the
  module, the network store is on tmpfs anyway; this covers a boot without
  the module.
- A leftover power-off request (see "Emergency off") is deleted.

**At Start** (`WelcomeActivity.startSession`), in this order:

1. Bridge lines are checked (see "Bridges"); an error stops here.
2. The add-on is checked: the `antumbra.fw.armed` property, then the status
   page (see "Add-on check").
3. The device-owner policies for the session are applied. Each failure is
   recorded and shown on the status screen; the rest still apply.
4. The session's choices are fixed in memory, and the provider starts
   answering `started = 1`. Policies come first because the module opens
   the network as soon as it reads `started = 1`.
5. The session service starts in the foreground (ongoing notification with
   "Emergency off").
6. The locked task ends, the home preference is cleared, the status screen
   opens, and WelcomeActivity is disabled, so the normal launcher is the
   only home.

**During the session** the choices exist only in memory. The foreground
service keeps the process alive, so the provider keeps answering, and so
the shutdown broadcast reaches the app. (Android sends `ACTION_SHUTDOWN` to
registered receivers only, and defers it for cached processes.)

**At shutdown or restart**, Welcome is made home again (enabled, preferred,
allowed to lock its task), Wi-Fi is turned off and locked, and saved
networks are removed. If the phone loses power or crashes instead, the
same happens at the next boot (`LOCKED_BOOT_COMPLETED`), a few seconds
after the launcher may have shown.

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
| `unsafe_browser` | integer | `0` | `0` or `1` |
| `persistent` | integer | `0` | `0` (Persistent Storage is not set up in v0) |
| `session_id` | text | 32 hex digits, random per process | the same |

Before Start every column holds its safe value, so a module that read the
row too early would still keep the network closed. Only `started = 1` makes
the other columns the user's choices.

How the module should read it:

```sh
content query --uri content://org.antumbra.welcome.state/session \
    --projection started:tor_mode:mac:admin:unsafe_browser:persistent:session_id
# Row: 0 started=1, tor_mode=bridges, mac=new, admin=0, unsafe_browser=0, persistent=0, session_id=5f0c...
content query --uri content://org.antumbra.welcome.state/session --projection bridges
# Row: 0 bridges=obfs4 192.0.2.1:443 0123...ABCD cert=... iat-mode=0
# obfs4 192.0.2.2:443 ...
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
  that. Welcome's status screen then says it no longer knows the session.
- Before trusting the row, check that Welcome is the device owner
  (`dpm list-owners` shows `org.antumbra.welcome`); otherwise none of the
  policies below was applied.

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
| `module.firewall.state` | `"live"` once `antumbra-fw apply` succeeded and was verified |
| `module.firewall.hash` | the ruleset hash prefix, as published in `antumbra.fw.armed` |

The module's file sits in a directory tor's uid can also write, so Welcome
only shows it; it decides nothing from it.

### Add-on check

At Start (and every three seconds on the Welcome screen) Welcome decides
whether the add-on is present: the property `antumbra.fw.armed` (only root
can set it) holds a hash, or, if apps cannot read it, the status page
answers as the DNS filter. Without the add-on, Wi-Fi is turned off and
locked off for the session, whatever the Tor choice. See "Open risks" for
why the second signal is weaker.

## Device-owner policies

Restrictions set by a device owner survive reboots, so each one that a
choice can loosen is set or cleared again at every Start (`Policies.kt`).

| Policy | When | Why |
|---|---|---|
| `DISALLOW_SAFE_BOOT` | always | Android's safe mode would start without third-party code. (Magisk's own safe mode is separate and not affected; the module's tmpfs Wi-Fi store covers it.) |
| `DISALLOW_CONFIG_TETHERING` | always | Tethered traffic is forwarded or offloaded (tc-BPF, IPA) below the firewall. |
| `DISALLOW_WIFI_DIRECT` | always | Wi-Fi Direct groups and discovery bypass the firewall and expose the device name. |
| Automatic time off, automatic time zone off, time zone UTC | always | See "Automatic time". |
| `DISALLOW_DEBUGGING_FEATURES` | unless Administration | USB debugging and developer options; this also stops adb. |
| `DISALLOW_INSTALL_UNKNOWN_SOURCES_GLOBALLY` | unless Administration | No apps from outside the preinstalled store. |
| `DISALLOW_BLUETOOTH` | unless Administration | Bluetooth tethering and nearby-device scans. |
| `DISALLOW_CONFIG_LOCATION`, and Location off | restriction unless Administration; Location off always | Location, scans and GNSS through Tor still locate you. |
| Wi-Fi off and `DISALLOW_CHANGE_WIFI_STATE` | before Start; offline sessions; add-on missing | Fail closed: no network without the add-on. A device owner can still toggle Wi-Fi (checked in `WifiServiceImpl`, Android 16). |
| Wi-Fi on, restriction cleared | Start, direct or bridges, add-on present | |
| `POST_NOTIFICATIONS` granted to itself | Start | The session notification. |

Not set in v0, on purpose:

- `DISALLOW_CONFIG_WIFI` and `DISALLOW_ADD_WIFI_CONFIG`: Wi-Fi must be set
  up in the emulator (and on the phone) after Start.
- `DISALLOW_DEBUGGING_FEATURES` before Start: CI drives the device over adb
  until it starts a session. On the phone, the pivot checks ask for it in
  every session, Administration included, and for `ro.debuggable=0` from
  the module; that is later work.
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
network, stable across sessions). Welcome only records the choice.

## Emergency off

A device owner cannot power the phone off. Android gives it one power
action, `DevicePolicyManager.reboot()`. A real power-off needs
`android.permission.SHUTDOWN`, which is signature|privileged. So
`Emergency.trigger`:

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
   `service.sh` (or post-fs-data, once `/data/user_de/0` is readable there)
   checks for that file, deletes it, and powers off at once (`reboot -p`)
   before starting anything else. Welcome deletes a leftover file at boot,
   so a request the module did not act on never powers off a later boot.

What this gives today, without the module's help: a restart. A restart ends
the session (tor's state is on tmpfs, the Welcome screen returns, choices
are gone), and the module wipes what it wipes at boot. It is weaker than a
power-off against someone holding the phone: memory keeps traces for a short
while after a warm restart. The status screen says which of the two the
button does.

Before Start the tile is out of reach (locked task); the power menu works.
`DevicePolicyManager.reboot()` refuses during a phone call; then the session
goes on and the message says why.

## Bridges

`Bridges.kt` checks every line, typed or built in, before it reaches the
module, as the archived Debian Antumbra did (`antumbra.settings`):

- accepted: `obfs4`, `webtunnel`, `meek_lite`, and plain bridges
  (`IPv4:port [fingerprint]`); a leading `Bridge` is dropped, blank lines
  and `#` comments are skipped;
- refused, with the reason: Snowflake (it needs UDP, which the firewall
  allows to nobody), IPv6 addresses for obfs4 and plain bridges (IPv6 is
  off), unknown or obsolete transports (obfs2, obfs3, scramblesuit), a bad
  fingerprint, an obfs4 line without `cert=`, a webtunnel or meek_lite line
  without `url=`, more than 20 bridges, lines over 600 characters, and any
  character outside printable ASCII or `"` or `\` (so no line can break
  out of the control port's quoting).

The bridge text field uses a password keyboard type with visible text, so
keyboards neither learn nor suggest from it, and the window is
`FLAG_SECURE` (no screenshots, no recents thumbnail) while typed bridges
are on screen.

**Built-in bridges** are Tor Browser's own obfs4 lines from
tor-browser-build `projects/tor-expert-bundle/pt_config.json` at a pinned
commit (2026-04-09). `tools/builtin-bridges.sh` downloads that file over
HTTPS, refuses it unless its SHA-256 matches the pin, checks the form of
each line, and writes the asset; `--check` fails if the asset differs. The
lines are data, not code.

obfs4, webtunnel and meek_lite need the pluggable-transport helper
(lyrebird) and a `ClientTransportPlugin` line in the module's torrc. The tor
build in `antumbra/android/tor` does not ship lyrebird yet; until it does,
only plain bridges can work.

## CI

`ci/welcome-adb.sh` (run it without arguments for help):

```sh
W=antumbra/android/welcome/ci/welcome-adb.sh
$W install app-debug.apk
$W provision                                   # dpm set-device-owner, waits for the Start button
$W screenshot welcome.png
$W start --tor bridges --builtin-bridges --admin
$W expect started=1 tor_mode=bridges bridges=7
$W check-policies --admin
$W screenshot status.png
$W emergency-tile                              # waits until the boot id changes
$W wait-welcome 180
$W start --tor offline --expect-adb-loss       # last: adb goes away without Administration
```

It finds controls by their resource ids through `uiautomator dump`, taps
them with `input tap`, and checks results through the provider (as the shell
user), `dumpsys user`, `settings` and `getprop`. **A session started
without `--admin` switches USB debugging off and adb disconnects**, so CI
starts its working sessions with Administration on, and can end a run with
`--expect-adb-loss` to prove that the restriction works.

## Verified, and not yet

Verified locally (2026-10-11, no emulator here):

- `./gradlew assembleDebug assembleRelease lintDebug testDebugUnitTest`
  passes with dependency verification on: 0 lint issues, 20 unit tests
  (bridge rules and the built-in asset, the provider's columns, values,
  caller rule and projection, the status-page parser and the add-on rule).
- The merged manifests (`aapt2 dump`): components, exported flags, direct
  boot, permissions, `testOnly` in debug only.
- `tools/builtin-bridges.sh` and its `--check` against the pinned source.
- `ci/welcome-adb.sh` passes shellcheck, and its screen and provider logic
  runs against a fake `adb`.
- The screens rendered with Paparazzi (layoutlib) at 412 dp, in a scratch
  copy of the project; Paparazzi is not a dependency of this build.
- Framework behaviour read in Android 16 sources (android16-release):
  `ACTION_SHUTDOWN` is sent registered-only and deferred for cached
  processes; device owners may start activities from the background; a
  device owner may toggle Wi-Fi under `DISALLOW_CHANGE_WIFI_STATE` (not in
  airplane mode); `removeNonCallerConfiguredNetworks` is for device owners;
  `DevicePolicyManager.reboot()` refuses during a call; `ShutdownActivity`
  requires `SHUTDOWN`; the `content query` output format.

Only CI (the API 36 emulator) or the phone can verify: provisioning, the
locked task and home switching, every policy taking effect, adb going away
without Administration, the provider answering root and shell and refusing
others, the status page through the real firewall, the tile and the
restart, the shutdown receiver, `FLAG_SECURE`, and anything about
`antumbra.fw.armed` being readable by apps.

## Open risks

- **The add-on check's fallback is weaker than the property.** If SELinux
  hides `antumbra.fw.armed` from apps, Welcome takes an answer from the DNS
  filter's status page as the sign that the add-on runs. Without the add-on
  there is no firewall, so any app already installed could listen on
  127.0.0.1:5380 and fake that answer, and Wi-Fi would be turned on. The
  module should make the property readable to Welcome (a property context or
  a sepolicy rule), after which the fallback can go.
- **The session lives in one process.** The foreground service makes its
  death unlikely, not impossible; the module must latch (see the provider
  contract).
- **The first seconds after a crash.** If the phone lost power during a
  session, the launcher is home at the next boot until
  `LOCKED_BOOT_COMPLETED` arrives and Welcome takes over again. The network
  stays closed meanwhile only because of the module (and Wi-Fi was locked
  off by the previous shutdown, if there was one).
- **Emergency off restarts rather than powers off** unless the module
  installs Welcome as a privileged app or implements the power-off request.
- **Bridges need lyrebird**, which the tor part does not build yet.
- **Administration loosens USB debugging**, which the pivot checks would
  rather keep off in every session.
- **The provider's caller check trusts uid 2000.** Anything running as the
  shell user (adb, or an app with Shizuku-style shell access granted in an
  Administration session) can read the bridge lines.
