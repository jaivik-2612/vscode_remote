# Antumbra Welcome (Android)

The Welcome app is the device owner of an Antumbra phone, and its home
screen until the session starts. At every boot it asks the questions the
Tails Welcome Screen asks, and two of its own (WEL8): Internet (Wi-Fi,
mobile data through Tor, or none); with Internet, connect to Tor directly
or through bridges; Phone (off, or calls and texts, which are not
anonymous); use a new Wi-Fi hardware address; Administration. (The Unsafe
Browser is shown but comes later.) Mobile data and calls are offered only
as far as the phone's Phone-mode gate allows, which the module reports
(none as installed). It shows the SIM's state, the cellular radio, the
VoLTE line and what the carrier sees, and says when to type the SIM PIN,
which Android's own screen asks for. It applies the device-owner
policies for the session and hands the choices to the Antumbra module
through a content provider. After Start it shows Tor's progress and the
tracker filter's counters, and offers Quick power off, an immediate power-off.
Both screens have an **Emergency call** button, and emergency calls work
from the locked Welcome screen before Start (see "Emergency calls"). Both
also have an **emergency card** (WEL10): the general emergency number
Android lists now, lines on the SIM, the radio and VoLTE that say this
phone can still try and point to the other phone too, and **Show my
position**, one fix from the satellite receiver shown in large type and
sent nowhere (see "Emergency card").

Package `org.antumbra.welcome`. Kotlin, Jetpack Compose with Material 3.
compileSdk and targetSdk 36 (Android 16, LineageOS 23.2), minSdk 34.

| Path | What it is |
|---|---|
| `app/src/main/java/org/antumbra/welcome/` | The app (one file per part; see below) |
| `app/src/main/assets/builtin-bridges-obfs4.txt` | Tor Browser's built-in obfs4 bridges, written by `tools/builtin-bridges.sh` (not offered until lyrebird ships) |
| `app/src/test/` | JVM unit tests: bridge checks, the provider's row, the status-page parser and the add-on rule, the policy lists, the lock task's features, when Quick power off waits (with the module's word on the last calls, MOD11), the two choices at Start and the module's word on the cell radio (WEL8), the radio line and the SIM states, that no identifier is read, the emergency card's number, lines, hook and Show my position (WEL10), and the texts |
| `ci/welcome-adb.sh` | Installs, provisions and drives the app over adb, by hand. The CI emulator job drives Welcome with its own script (`antumbra/android/ci/emulator-antumbra.sh`), using the same test tags and provider URI, and calls this one only for `check-emergency`, `check-power-menu`, `check-policies --keep-adb`, `check-addon`, `check-module-word`, `check-choices`, `check-phone`, `check-module-cell`, `check-emergency-card`, `check-emergency-states`, `check-position` and `clear-position-test`; the app lab (`emulator-apps.sh`, a session with Administration on) for `check-policies --admin --keep-adb` and `check-addon` |
| `ci/test-welcome-adb.sh` | Runs `welcome-adb.sh` against a fake adb (no device needed) |
| `tools/builtin-bridges.sh` | Rewrites or checks the built-in bridges from a pinned, checksummed source |
| `gradlew`, `gradle/wrapper/gradle-wrapper.properties` | The pinned Gradle (see "Building") |
| `gradle/libs.versions.toml` | Every plugin and library version |
| `gradle/verification-metadata.xml` | SHA-256 of every artifact the build resolves, and the PGP keys trusted to sign them |
| `gradle/verification-keyring.keys` | Those public keys, ASCII-armored (the build contacts no key server) |

## The screens

1. **Welcome** (`WelcomeActivity`, `ui/WelcomeScreen.kt`). Title "Welcome to
   Antumbra", then:
   - **Emergency** (WEL10, `ui/EmergencyCard.kt`), under the banners: the
     emergency number Android lists now, in large digits, the state lines
     and Show my position (see "Emergency card").
   - **Internet** (WEL8): *Wi-Fi* (default), *Mobile data, through Tor*,
     or *None*. Mobile data is offered only where the module's gate says
     `data` (the emulator, until FW9 and CI12), else shown disabled with
     "Not available yet: mobile data through Tor needs checks on this
     phone first." Mobile data needs the cellular radio, and while it is
     on the carrier delivers calls and texts, so choosing it selects
     *Calls and texts* and disables *Off*, with the reason on screen.
   - **Tor**, only when Internet is not None: *Connect to Tor directly*
     (default) or *Connect through bridges* with *Bridges I enter* (a text
     field, one bridge line per line). *Built-in bridges (obfs4)* is shown
     but disabled, "Not available yet", until the module ships lyrebird
     (see "Bridges"). Plain bridges reach Tor but do not hide that you use
     Tor, and the text says so.
   - **Phone** (WEL8): the SIM's state per slot ("SIM card", "SIM card 2"
     with two), the cellular radio (On, Off, Not known), "About the SIM
     PIN" while a SIM is in the phone (the PUK's text while one needs it),
     then *Off* (default) or *Calls and texts*, offered where the module's
     gate says `phone` or `data`, else disabled with "Not available yet:
     Phone needs checks on this phone first." Then the card **What your
     carrier sees** for the choice made.
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
   and Phone is not available for the session, and the SIM PIN is not to
   be typed), when a SIM is unlocked while the add-on is not running, or
   when Welcome is not the device owner.
2. **Status** (`StatusActivity`, `ui/StatusScreen.kt`), after Start, and the
   "Antumbra" entry in the launcher: the emergency card (WEL10) under the
   first line and the banners; Tor's bootstrap progress and, when the
   module gives one, its reason why tor cannot connect; the tracker
   filter's counters (lookups, blocked, domains on the list, list version);
   the **Phone** card (the SIM, the cellular radio, "Calls and texts
   (VoLTE)" from the module's IMS reading in a Phone-mode session, "Not
   checked" otherwise) and **What your carrier sees** for the radio as
   it is now and what the add-on carries out; the session's choices (Internet, Tor, Phone, Wi-Fi address,
   Administration, Unsafe Browser) and the firewall row ("Live (rules …)" only from
   `antumbra.fw.armed`); buttons for Wi-Fi settings and for adding the
   Quick Settings tile; and **Emergency call** and **Power off now** (Quick
   power off) buttons that stay on screen. Its first line says
   "Offline" only when the session has no Internet and no Phone and the
   cellular radio is known to be off (with Phone on, the radio comes back
   on without a restart); no other text on either screen says it. Mobile
   data the add-on did not allow (its gate lowered during the session) is
   said to be off, with no Internet, never "over mobile data". It polls `http://127.0.0.1:5380/status` every two seconds while
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
name: `internet_wifi`, `internet_mobile`, `internet_none`, `tor_direct`,
`tor_bridges`, `bridges_builtin`, `bridges_custom`, `bridges_text`,
`sim_status_1` (and `_2`), `radio_status`, `sim_pin_help`, `phone_off`,
`phone_calls`, `card_carrier_choice`, `switch_mac`, `switch_admin`,
`switch_unsafe_browser`, `start_button`, `start_error`,
`warning_not_owner`, `warning_no_addon`, `warning_sim_unlocked_no_addon`,
`status_title`, `status_mode`, `card_phone`, `ims_status`, `card_carrier`,
`row_internet`, `row_tor`, `row_phone`, `card_tor`,
`tor_progress`, `tor_error`, `card_filter`, `filter_queries`,
`filter_blocked`, `row_firewall`, `warning_policies`, `warning_wifi_off`,
`warning_lost`, `open_welcome`, `wifi_settings`, `add_tile`,
`poweroff_button`, `emergency_call`, `return_to_call`; the emergency card's
(WEL10, each line its own node): `card_emergency`, `emergency_number_value`,
`emergency_number_text`, `emergency_state_no_sim`,
`emergency_state_sim_locked`, `emergency_state_sim_unusable`,
`emergency_state_radio_off`, `emergency_state_volte`,
`emergency_other_phone`, `position_detail`, `position_detail_apps`,
`position_button`, `position_stop`, `position_hide`, `position_status`,
`position_refusal`, `position_lat_label`, `position_lat`,
`position_lon_label`, `position_lon`, `position_map`, `position_accuracy`,
`position_age`, `position_mock`, `position_location`.
`emergency_number_value` holds one number, or several Android ranks alike
separated by " · ".

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
   the first session, so a second Start could only mislead. Then the
   Phone and Internet choices are checked again against the module's last
   word on the cell radio (WEL8): a choice it no longer offers (its gate
   lowered, the add-on gone) is taken back on screen and Start refused
   ("The add-on does not offer this choice on this phone any more"), with
   nothing written and nothing loosened.
4. The device-owner policies for the session are applied (`Policies.applyAtStart`):
   the baseline again, and the Wi-Fi lock unless the session's Internet is
   Wi-Fi and the add-on is present (a mobile-data session keeps Wi-Fi off
   and locked too). **A session with Internet (Wi-Fi or mobile data) is
   refused when a protective policy failed**: tethering, Wi-Fi Direct or
   safe-boot lock, USB debugging off, or, when Wi-Fi must stay off, the
   Wi-Fi lock and Wi-Fi being off. Nothing is loosened then, and the
   message says to choose *Internet: None* or restart. A session without
   Internet starts anyway and lists the failures on the status screen.
5. Only then are the session's choices loosened: Administration lifts its
   restrictions; for a Wi-Fi session with the add-on, the Wi-Fi lock is
   lifted and Wi-Fi switched on. The cellular radio and mobile data are the
   module's (root): Welcome only reports the choice (`cell`), and the
   module carries it out as far as the phone's gate allows.
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
| `cell` | text | `off` | `off`, `phone` (calls and texts) or `data` (mobile data through Tor, which comes with calls and texts); never `data` with `tor_mode=offline` (WEL8) |

Before Start every column holds its safe value, so a module that read the
row too early would still keep the network closed. Only `started = 1` makes
the other columns the user's choices. `started = 1` is never reported
unless Welcome is the device owner and the session's policies are in place.

How the module should read it:

```sh
content query --uri content://org.antumbra.welcome.state/session \
    --projection started:tor_mode:mac:session_id:cell
# Row: 0 started=1, tor_mode=bridges, mac=new, session_id=5f0c..., cell=phone
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
- `cell` is the person's choice, not a permission: the module carries out
  no more than the phone's Phone-mode gate allows, whatever the row says.
  A Welcome from before WEL8 has no `cell` column (`Unknown column: cell`);
  the module then reads its row without it and keeps the radio off.

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

### The module's word on the cell radio (WEL8)

A second method, the same rules (uid 0 only, checked before the method or
the extras are looked at; `ModuleCalls` dispatches only then): what this
phone's Phone-mode gate allows, what the module carries out, and the
cellular radio as its last look read it.

```sh
content call --user 0 --uri content://org.antumbra.welcome.state --method module_cell \
    --extra v:i:1 --extra gate:s:phone --extra cell:s:none --extra radio:s:off --extra at:l:1234
# Result: Bundle[{v=1}]
```

| Extra | Type | Values |
|---|---|---|
| `v` | int | `1` |
| `gate` | string | `off`, `phone`, `data`: the most the module carries out on this phone now |
| `cell` | string | `none` before the module read a Start; then what it carries out: `off`, `phone`, `data` |
| `radio` | string | `on`, `off`, `wait` (the modem starting or stopping), `unknown` |
| `at` | long | that look's time since boot; `0` before the first look |

Exactly these five, with these types; anything else is malformed and
clears the word Welcome held (the safe side: no Phone choices, the radio
"Not known"). The module sends it when one of them changes, when Welcome's
process started again before Start, and every 5 minutes; Welcome trusts a
radio reading for 10 minutes. It offers Mobile data only with `gate=data`
and Calls and texts with `gate` `phone` or `data`; without a word (an
older module, no add-on), neither. It is kept in memory (`CellWatch`),
never logged, written or handed out, and shown only as the Phone lines.

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
| `DISALLOW_CONFIG_LOCATION`, and Location off | always, Administration included (since WEL8; Location switched off before Start and at every Start, through `Position.offWhenSafe`: nothing written while it is already off, and left as it is while a call, emergency callback mode or the 5 minutes after a call hold; at shutdown at once) | Location, scans and GNSS through Tor still locate you. Until WEL9 ("off, or on for chosen apps") nothing switches Location on but Welcome itself, for one satellite fix the person asks for (WEL10, "Emergency card"); the person still cannot switch it. |
| Wi-Fi locked: `DISALLOW_CHANGE_WIFI_STATE`, `DISALLOW_CONFIG_WIFI`, `DISALLOW_ADD_WIFI_CONFIG`; Wi-Fi off, checked | before Start; sessions whose Internet is not Wi-Fi (None, mobile data); add-on missing | Fail closed: no network without the add-on. A device owner can still switch Wi-Fi (`WifiServiceImpl`, Android 16), except in airplane mode (below). |
| Wi-Fi lock lifted, Wi-Fi on | Start, Internet Wi-Fi, add-on present | The user then adds a network in Settings. |
| `POST_NOTIFICATIONS` granted to itself | Start | The session notification. |
| `READ_PHONE_STATE` granted to itself | before Start (`Home.claim`) | "Return to call" (`TelecomManager.showInCallScreen`; see "Emergency calls"), Android's emergency-number list and `TelecomManager.isInCall` (WEL10). WEL9's phone-state denial must leave Welcome out. |
| `ACCESS_FINE_LOCATION` and `ACCESS_COARSE_LOCATION` granted to itself | the first press of Show my position (WEL10) | One fix from the GPS provider. Allowed to a device owner set with `dpm set-device-owner` over adb (`canAdminGrantSensorsPermissions`); never revoked, since revoking a runtime permission kills the app and the session it keeps in memory. WEL6's denial must leave Welcome out. |

"Administration" lifts the two "unless Administration" rows from Start
until the next shutdown; it never turns debugging or Location on. The
protective rows (safe boot, tethering, Wi-Fi Direct, debugging, and the
Wi-Fi lock when Wi-Fi must stay off) refuse a session with Internet when
they fail. No call or SMS restriction is set (`DISALLOW_OUTGOING_CALLS`,
`DISALLOW_SMS`): emergency calls must work in every session, and Phone
off is the module's radio, not a restriction.

**Wi-Fi in airplane mode.** Android 16 lets only Settings switch Wi-Fi in
airplane mode (`WifiServiceImpl.setWifiEnabled`: "only Settings can toggle
wifi"); a device owner is not privileged there. If the user switched Wi-Fi
on in airplane mode, Welcome cannot switch it off. Then:

- the configuration restrictions and the removed networks leave Wi-Fi
  nothing to join, before Start and in a session without Internet;
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
  package-added listener); later work. Location stays off and locked in
  every session, and Bluetooth is off unless Administration.
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

WEL10's hook, `debug.antumbra.emergency_states`, is honoured by the same
builds only (`TestHook.emergencyStates`; any other build reads no property
and starts no `getprop`): a comma list of `no_sim`, `sim_locked`,
`sim_unusable`, `radio_off`, `volte`, `number_none`, `number_unreadable`,
or `none`, unknown words ignored, unset or empty for the real readings. It
replaces the emergency card's state lines (and, with a `number_` word, its
number line) and nothing else: not the Phone card, not Start, not what the
module is told. The CI emulator cannot remove or lock its SIM, so this is
how each state's text is shown there (`check-emergency-states`, which
clears the property afterwards whatever happens).

## SIM, cellular radio and VoLTE (WEL8)

What the Phone parts show, and how Welcome learns it (`CellWord.kt`,
`PhoneTexts.kt`). Public APIs only, none of them needing a permission
(read in AOSP `android16-release`, and again in `android17-release` for
OS1, where they stay public and permission-free; each call is wrapped
against `UnsupportedOperationException` and `SecurityException`).
`READ_PHONE_STATE`, which Welcome already holds for "Return to call"
(WEL7), is not needed by any of them, and nothing here sets the radio or
mobile data: a device owner may not (they are not in its global-settings
allowlist), so that stays the module's, as root. What Welcome reads:

- **The SIM's state per slot**: `TelephonyManager.getSimState(slot)` for
  `0 until activeModemCount` (API 26 and 30): absent, locked (PIN), blocked
  (PUK), locked to another network, unlocked, not ready, disabled for good,
  card error, restricted, not known. The no-argument `getSimState()` is not
  used: without a default subscription it reads "unknown" whenever a slot
  holds a card.
- **The cellular radio**: Welcome may not ask for the radio's power (radio
  power events need `READ_PRIVILEGED_PHONE_STATE`, `isRadioOn` is a system
  API), so it combines three things (`RadioRule`): a call in progress or
  Quick power off's wait after one (on); its own service-state listener
  (`TelephonyCallback.ServiceStateListener`, API 31, registered with
  `INCLUDE_LOCATION_DATA_NONE`, API 33, so no cell identity, operator or
  location ever reaches it; anything but `STATE_POWER_OFF` is on, IMS over
  Wi-Fi included: the carrier can reach the phone then); and the module's
  word (`module_cell`, at most 10 minutes old). Off only when something
  says off and nothing says on; "Not known" otherwise, and every text
  treats "Not known" as possibly on. The listener follows the default
  subscription it was registered with, so a SIM's change registers it
  again.
- **The VoLTE line**: MOD11's IMS reading (`CallWatch.ims()`, 15 minutes)
  in a Phone-mode session ("Not known yet" until the module's first
  reading after the switch-on, never "off"); outside Phone mode the module
  reads no IMS, so the line says "Not checked: Phone is off in this
  session", not that VoLTE is off. "Ready over
  Wi-Fi calling" says that Antumbra does not expect it: WEL8 does not
  switch Wi-Fi calling off (MOD7 will), but the firewall refuses the UDP
  that Wi-Fi calling needs for every uid but tor's [likely; PH3 and MOD7
  check].
- **What your carrier sees**: a plain card, the same on every phone, naming
  no country or carrier. With the radio on (or not known): the SIM and the
  name it is registered to, the phone's IMEI (a new Wi-Fi address does not
  change it), the cell towers and so roughly where you are, who you call
  and text, when, for how long and what is said in ordinary calls and
  texts; calls and texts never go through Tor; with mobile data through
  Tor, only encrypted Tor traffic and that Tor is used (plain bridges do
  not hide it); with Wi-Fi, that a phone hotspot's carrier sees Tor use.
  With the radio off: nothing new.

**No identifier is read.** Welcome holds `READ_PHONE_STATE` (granted to
itself for "Return to call"), and Android lets a device owner holding it
read the IMEI, the IMSI and the SIM's serial number
(`DevicePolicyManagerService`, `LegacyPermissionManagerService`). So this
is a rule of Welcome's own code, checked by `NoIdentifiersTest` over every
source file (comments taken out): no IMEI, MEID, device ID, IMSI, ICCID,
card ID, phone, voicemail or call number, group ID, NAI, serial, type
allocation or manufacturer code, operator, country, carrier ID, service
state or cell identity is asked for, in the Java form (`getImei`,
`getSimOperatorName`) or the Kotlin one (`.imei`, `.simOperatorName`); no
class that lists subscriptions, cells or cards (`SubscriptionManager`,
`SubscriptionInfo`, `CellInfo`, ...) is named; and a `TelephonyManager` or
`ServiceState` Welcome holds is used only through an allow-list
(`activeModemCount`, `getSimState`, `registerTelephonyCallback`,
`unregisterTelephonyCallback`; `state`). The test seeds each form, and
Welcome's own uses, to show the scan catches the first and passes the
second. Since WEL10 Welcome holds the location permissions, for Show my
position alone; the listener still renounces location
(`INCLUDE_LOCATION_DATA_NONE`, its only registration), and the scan also
forbids Wi-Fi's scan results and connection info, an emergency number's
country and network code, and any emergency-number entry turned into a
string. The SIM's
state and the radio are shown inside Welcome only: never logged, written
to a file or a property, or handed to another app.

**The SIM PIN.** Welcome cannot type it: `supplyIccLockPin` is a system
API behind `MODIFY_PHONE_STATE`. When a slot needs its PIN (or PUK),
SystemUI shows its own full-screen SIM-PIN screen, even with no screen lock
set, and because Welcome's lock task keeps the keyguard
(`LOCK_TASK_FEATURE_KEYGUARD`, the price of emergency calls, WEL7) it
shows over the Welcome screen, so Welcome's own warnings cannot be seen
while it is up. "About the SIM PIN" therefore words the rule around what
the person knows at that moment (as `install.md` does): type the PIN only
after a normal start (nothing updated since a start whose Welcome screen
showed no warning, no volume key held while it started: Magisk's Safe
Mode); after an update, start once without the SIM card and check the
Welcome screen first; if in doubt, do not type it and restart. While the
add-on is not running, the warning banner says not to type it, and a
second banner says when a SIM is unlocked anyway. Whether the SIM-PIN
screen can be left without the PIN (PH4), and the SIM's state with the
radio off (PH3), are checked on the phone.

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

## Emergency card (WEL10)

On both screens, under the title and the banners (`ui/EmergencyCard.kt`).
The pinned **Emergency call** button stays as it is: an empty emergency dial
pad, nothing pre-filled, no one-tap call.

**The number** (`EmergencyNumbers.kt`). Android's own list,
`TelephonyManager.getEmergencyNumberList()` (`READ_PHONE_STATE`, which
Welcome holds), read at run time in the screens' poll and never during a
call (the last reading stays then). Every subscription's list is merged and
put in Android's own order (`EmergencyNumber.compareTo`: the source's rank
first, network > SIM > database > default > modem config, then the digits
as text). Only *general* numbers count: one whose category is "unspecified"
or covers police, ambulance and fire together, preferring those Android
does not place as an ordinary call; digits only, 1 to 8, each once. The
card shows one number when the first of them comes from the network, the
SIM or Android's database, or outranks every other one. Otherwise Android
ranks several alike and orders them only by their digits as text: with no
SIM and no word from the modem yet (the radio off since power-on, as before
Start), Android's fallback is 3GPP's list, eight general numbers from no
source (`EmergencyNumberTracker` 1054-1066, 1118-1132), whose first by text
is not the general number in most places. Then the card shows every number
ranked like the first, in Android's order, under "Emergency numbers", with
one line: a call to any of them is placed as an emergency call from this
phone (each is in Android's list, so the call goes out as one). Of each
entry Welcome reads its digits, categories, routing and sources
(`getEmergencyNumberSources`), never its country, network code or URNs, and
never logs it. The list is not empty while the phone process runs; when it
is empty or cannot be read, the card says so and that Emergency call still
opens the emergency dial pad. No number is written in Welcome's code or
texts (`EmergencyNumbersTest` scans both). Android 17 (android17-release)
has the same API and permission.

**The state lines** (`EmergencyTexts.kt`), from WEL8's readings only: no
SIM, the SIM locked (PIN, PUK, network), the SIM unusable (card error,
disabled, restricted), the cellular radio off (WEL8's radio rule), and
"Calls over 4G (VoLTE) are not connected yet" in a Phone-mode session with
a SIM unlocked, the radio not off and the module's IMS word "none" (Wi-Fi
calling stays WEL8's own VoLTE line until MOD7). Each says this phone can
still try: Android switches the radio on for an emergency call and tries
any network it finds, with or without a usable SIM
(`TelephonyConnectionService`, `EmergencyCallDomainSelector`). Then, only
with a state line, "Your other phone can make emergency calls too." No text
says an emergency call cannot be made (`EmergencyCardTest`). Before Start
the radio is off (D12, MOD6), so the Welcome screen shows the radio line.

**Show my position** (`Position.kt`). One fix from the satellite receiver,
on request:

1. Refused, with its reason and nothing changed, unless Welcome is the
   device owner; no call, emergency callback mode or the 5 minutes after a
   call hold (Quick power off's hold, plus `TelecomManager.isInCall`, which
   also sees a call still connecting; looked at again after the permission
   is granted and after Location comes on, so a call that begins during the
   press stops it there, Location then left as it is until the hold ends); `assisted_gps_enabled` reads 0 (the
   module sets it; Welcome only reads it, and never writes it or any other
   GNSS, SUPL, XTRA or location-provider setting: Android's emergency
   location may depend on them); no network location provider exists;
   Wi-Fi scanning for location is off; a GPS provider exists.
2. `ACCESS_FINE_LOCATION` and `ACCESS_COARSE_LOCATION` granted by the
   device owner to itself at the first press, never revoked.
3. Location on with `DevicePolicyManager.setLocationEnabled` (the device
   owner's switch; `DISALLOW_CONFIG_LOCATION` stays set, so the person still
   cannot switch it). Android posts its notice that apps can access your
   location. If Location does not read on within 5 s, the press ends
   ("Location could not be switched on.") and Welcome looks at the switch
   again 5 s later, switching it off if it came on after all; the card says
   "Nothing was changed: Location is off." only once it reads off and was
   never seen on.
4. One request to `LocationManager.GPS_PROVIDER` alone (one update, 3
   minutes), made once the provider has followed the switch (a request on a
   provider still off is told "off" at once: `LocationProviderManager`).
   Never the fused, network or passive provider, never a remembered fix.
5. Location off again at once after the fix, the 3 minutes, Stop, the
   screen leaving (`onStop`, or the screen going off) or Start; Start also
   takes a position off the screen. If a call begins during a search, the
   search stops and Location stays as it is until 5 minutes after the call
   (the card says so): Welcome never changes Location's switch while a call
   holds, in case the emergency service needs this phone, and when Location
   is already off it writes nothing at all. Every other switch-off in
   Welcome (the baseline at boot, on becoming the device owner and at
   Start, and a new process finding Location on) follows the same rule;
   only shutdown switches off at once. A new process does not know the
   calls before it (the call record is in memory only), so when its first
   look finds Location on (left on by a process that died during a call's
   hold), Location stays on for 5 minutes from the process's start, as
   after a call, and the card says why.
6. The latitude and longitude in large type (5 decimals, the same digits in
   every language, "10.12345° N"), a line for a map, the accuracy, the age,
   and whether it came from a test location. In memory only, for 15 minutes
   at most or until Hide position; the window is `FLAG_SECURE` meanwhile
   and the screen stays on while it looks (`WindowRules`, the same for both
   screens). No copy or share button; nothing
   in a file, a preference, a property, the provider, a notification, an
   intent, the log or `status.json` (`PositionTest` scans the sources).

What remains (PH5 on the phone, WEL6, MOD8): while Location is on, apps
holding a location grant can get the fix, and Android's remembered last
fix the next time Location is on; the app-ops history records that Welcome
used location, and when; the GNSS engine keeps its last position; a PSDS
download Android arms with the first fix of a boot runs at the next network,
as system traffic, so through Tor after Start, with the known hosts refused
by name; what the Qualcomm stack asks for is PH5's.

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
$W check-emergency-card                        # WEL10 (adb root): each number the card shows is Android's, its lines match the device; reads only
$W check-emergency-states --shots shots/       # WEL10 (debug build): each state's text through the hook; the hook cleared after
$W check-position --source test                # WEL10 (adb root): a test-provider fix on screen, Location off after, nothing kept
$W screenshot welcome.png
$W check-choices --gate off                    # WEL8, before Start: the six attempts; the gate the module told Welcome
$W start --tor bridges --bridges-file plain-bridges.txt   # --internet wifi|mobile|none, --phone off|calls
$W expect started=1 tor_mode=bridges bridges=2
$W check-policies                              # add --admin, --keep-adb, --wifi-locked as they apply
$W check-addon                                 # Welcome reads antumbra.fw.armed (opens the status screen, scrolls to the row)
$W check-phone --cell off                      # WEL8: the status screen's session lines, Phone and carrier cards
$W check-module-cell                           # WEL8 (adb root): the word on the cell radio from root only
$W screenshot status.png
$W power-off-tile                              # waits until the boot id changes
$W wait-welcome 180
$W start --internet none --expect-adb-loss     # last: clears the hook; adb goes away at Start
```

It finds controls by their resource ids through `uiautomator dump`, taps
them with `input tap`, and checks results through the provider (as the shell
user), `dumpsys user`, `settings`, `cmd wifi` and `getprop`. Without the
test hook, Welcome switches USB debugging off at provisioning and in every
session, Administration or not; `start` refuses to run then unless
`--expect-adb-loss` says that losing adb is the point.
`ci/test-welcome-adb.sh` runs the script against a fake adb, and WEL8's
`check-choices` and `check-phone` against a fake screen that shows
Welcome's own texts (from `strings.xml`), scrolls (a fast swipe flings
on) and dumps what is on screen as Compose's accessibility tree does (a
card cut off by an edge lists only its texts on screen), and applies
Welcome's rules to taps, with a switch for each fault the checks must
catch (an unavailable row enabled, the wrong row checked, Phone rows that
do not follow mobile data, "offline" on screen, a radio or SIM line that
disagrees, Tor's rows without Internet, taps that do nothing, a carrier
card without what the carrier sees, a wrong VoLTE line) and a layout in
which no page of the scan shows the carrier card whole.

`check-choices --gate off|phone|data` (WEL8) runs before Start. For each
of the six attempts (Internet Wi-Fi, mobile data, None; Phone off, calls
and texts; mobile data straight after Phone off, so that it is seen to
select calls and texts by itself) it taps the Internet row, then the
Phone row, by their test tags, from the top of the page, as a person
would, then reads the whole page (slow scrolls, every text and
description) and checks: which rows are checked; rows the gate does not
allow disabled, unchecked and giving their reason; Phone off disabled
with mobile data; Tor's rows exactly when there is Internet; the carrier
card for the choice with its key statements (with Phone on, that the
carrier sees the SIM, the IMEI and roughly where you are, and that calls
never go through Tor; with Phone off, that the radio stays off and what an
emergency call shows the carrier); the radio line against the registry's `mRadioPowerState` (read
before and after the page; a change between them skips the comparison);
the SIM line against `gsm.sim.state`; and no "offline" anywhere. A row or
card counts only from a dump in which it lies wholly inside the scroll
view (Compose lists only the on-screen texts of a card or info row cut
off by an edge, and gives it the bounds of its visible part); one that no
page shows whole is scrolled wholly into view with slow drags and read
again. It ends with Wi-Fi and Phone off selected. It only taps rows,
scrolls and reads. `check-phone [--internet …] --cell off|phone|data`
reads the status screen the same way (no "offline" there unless the
session has no Internet and no Phone and the radio reads off; the VoLTE
line "Not checked" with Phone off; the carrier card's key statements). `check-module-cell` (adb as root)
sends the word on the cell radio as the shell user (refused), malformed
as root (refused) and the most careful word as root ("gate off, nothing
carried out, the radio not known": taken); the module's next word
replaces it.

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
  passed in run 20: the shell's word refused, root's taken)). WEL8
  (2026-10-20, 74 unit tests in all): the six attempts of the two choices
  and the five sessions they give, mobile data always with calls and
  texts, what each gate offers (none, off, phone, data) and Start's check,
  which only takes choices back; the module's word on the cell radio
  (exact keys, types and values, uid 0 only and checked before the method
  or the extras, a malformed word clearing the held one, an unknown method
  changing neither word, never logged or written); the radio line for
  every mix of the module's word (on, off, wait, unknown, missing, old,
  from the future), the listener and a call; all twelve SIM states; the
  texts for each session, radio state, way to connect and what the add-on
  carries out: "offline" only without Internet and Phone and with the
  radio known off, and in exactly one string; mobile data the add-on did
  not allow never said to be on; the VoLTE line never "off" in Phone mode;
  the carrier card complete whenever the radio may be on, and for every
  Phone-on choice; the key statements word for word (Phone on is not
  anonymous; with mobile data the carrier sees that Tor is used but not
  what you do; Phone off gets no calls or texts; with the radio on, an
  emergency call included, the carrier sees the phone, its SIM and roughly
  where it is); the corrected texts; no number in the new texts; the SIM-unlocked warning
  only while the add-on is known not to run; Location locked in every
  session and Wi-Fi only for a Wi-Fi session; `cell` in the row; and no
  identifier API named in any source file.
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
  and without adb as root); expect; WEL8: `start --internet/--phone` and
  the row's `cell`; `check-choices` at each gate (six attempts, six
  screenshots, Wi-Fi and Phone off again; what each gate lets the walk
  choose; a carrier card that no page of the scan shows whole, read once
  scrolled into view) and each fault it must catch (an unavailable row
  enabled, the wrong row checked, Phone rows that do not follow mobile
  data, "offline" on screen, the radio or SIM line disagreeing, Tor's rows
  without Internet, taps that do nothing, a gate told wrong, a carrier card
  without what the carrier sees), and that it only taps, scrolls and
  reads; `check-phone` (on and off radio, "offline" allowed only without
  Internet and Phone and with the radio off, a wrong VoLTE or Internet
  line); `check-module-cell` (only the most
  careful word sent; fails when the shell user's or a malformed word is
  taken, when root's is not, and without adb as root).
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
(the phone, PH4). For WEL8: the choices at each gate level, the radio and
SIM lines, the status screen in Phone mode and the word on the cell radio
from root only (the emulator job's `welcome_choices_gate_*`,
`welcome_radio_line`, `welcome_phone_status`, `welcome_module_cell`, not
yet run on CI; how uiautomator reports the texts of the merged choice rows
is seen there first); the SIM-PIN screen over Welcome and whether it can be
left without the PIN, the SIM's state with the radio off, IMS and the VoLTE
line under the firewall, and emergency calls in each combination (the
phone: PH3, PH4).

WEL10 (2026-10-27, 109 unit tests in all, lint clean; no emulator here):
the general number picked from Android's entries in Android's order, with
stand-in numbers only (unspecified, or police, ambulance and fire; a number
placed as an ordinary call only when no other general one exists; odd and
long entries skipped; an empty, unreadable or throwing list read as such);
no digit-only literal in the code and none of 3GPP's defaults as a token;
the state lines for every SIM mix, radio and IMS reading, in and out of a
Phone-mode session, the other-phone line exactly with them, no text that
discourages an emergency call; the hook's words, and that a build that is
neither debuggable nor testOnly never reads the property; Show my position
with a fake platform and clock: each refusal in order with nothing
changed, the whole search, the 3-minute limit to the millisecond, Stop,
the screen leaving and Start, Location going off elsewhere (and the moment
the provider takes to follow the switch, which is not an end), a call
beginning during a search (nothing switched until its hold ends), nothing
written while Location is already off, shutdown at once, failed switches
retried every 5 s, the 15-minute display and Hide; the format in four
languages, rounding and hemispheres; source scans for the GPS provider
alone, nothing stored, logged or sent, no location setting written but
Location's switch, no permission of Welcome's own revoked, `FLAG_SECURE`
and Start's order. `ci/test-welcome-adb.sh` runs `check-emergency-card`,
`check-emergency-states`, `check-position` and `clear-position-test`
against a fake screen drawn by Welcome's rules, passing as they should and
failing with each fault they must catch (a number Android does not list, a
line missing or extra, a discouraging text, a release build ignoring the
hook, a changed text, a hook that sticks, Location not switched on, left on
after the fix or after leaving, a wrong hemisphere, no test-location line,
a window not secure, the coordinates in a file, the log or a property, a
request under the fused provider, Hide doing nothing), and undoing what
they changed, also when killed. Not yet: all of it on a device. The
emulator job's WEL10 checks (`welcome_emergency_card`,
`welcome_emergency_states`, `welcome_position` and its parts,
`welcome_position_gnss`, and after Start `welcome_emergency_card_session`,
`welcome_position_session`, `position_lookups`, `position_not_in_status`)
warn until they have passed on CI once: how uiautomator lists the card's
lines and reads a `FLAG_SECURE` window, the test provider as the shell
user, `setLocationEnabled(true)` with `DISALLOW_CONFIG_LOCATION` set,
`onStop` when the screen goes off, `adb emu geo fix`, the `dumpsys
location` and `dumpsys window` formats, and whether the emulator's GNSS HAL
asks for assistance data, are seen there first. On the phone (PH4, PH5):
the list with the radio off and the SIM locked, the card's lines in each
state, the Qualcomm stack in standalone mode, its time to a fix against the
3-minute limit, and anything it asks a server for.

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
  Phone-mode session (WEL8; the per-phone gate keeps Phone mode off on the
  phone until PH3, so there it waits after every call):
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
- **Every app can read the SIM's state and whether the phone has
  service**, without a permission, as Welcome does: an app can tell Phone
  mode from Phone off, and a SIM from none (threat model).
- **The SIM-PIN screen covers Welcome** before Start when the SIM is
  locked; the person must not type the PIN in a start without the add-on.
  Welcome can only say so.
- **Location cannot be switched on** by the person in any session until
  WEL9 brings "off, or on for chosen apps" (WEL8 took it out of
  Administration); only Welcome switches it, for one satellite fix the
  person asks for (WEL10), and off again. Meanwhile apps holding a location
  grant could get that fix (WEL6), and the phone's own GNSS stack may ask
  for assistance data through Tor (PH5).
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
