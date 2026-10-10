# Spec: Antumbra Welcome screen (greeter) and Start, for the web simulator

Everything below comes from the repository's `antumbra/` directory
(read-only), from the built root filesystem `build/work/qemu-virt/rootfs`, and from
screenshots of the real system in QEMU. Strings in `code quotes` or in quoted blocks are
verbatim. Where the repository says nothing, this spec says "repo silent".

## 0. Source abbreviations

| Short | Path (relative to the repo root) |
|---|---|
| `W` | `config/rootfs/usr/bin/antumbra-welcome` (the Welcome screen, GTK4/libadwaita, Python) |
| `S` | `config/rootfs/usr/lib/python3/dist-packages/antumbra/settings.py` |
| `G` | `config/rootfs/usr/lib/python3/dist-packages/antumbra/greetd.py` |
| `CSS` | `config/rootfs/usr/share/antumbra/theme/welcome.css` |
| `APPS` | `config/rootfs/usr/share/antumbra/theme/apps.css` |
| `A` | `config/rootfs/usr/local/lib/antumbra-apply-welcome-settings` (root-side applier) |
| `P` | `config/rootfs/usr/local/sbin/antumbra-persistence` |
| `F` | `config/rootfs/etc/antumbra/persistence-features.conf` |
| `H56` | `config/hooks/56-session-android.sh` |
| `TC` | `config/rootfs/usr/local/sbin/antumbra-tor-connect` |
| `D` | `config/rootfs/etc/NetworkManager/dispatcher.d/10-antumbra-tor.sh` |
| `UN` | `config/rootfs/usr/local/lib/antumbra-unblock-network` |
| `SM` | `config/rootfs/usr/local/lib/antumbra-spoof-mac` |
| `TG` | `config/rootfs/usr/local/lib/tails-shell-library/tails-greeter.sh` |
| `SC` | `config/rootfs/usr/local/sbin/antumbra-selfcheck` |
| `GS` | `config/rootfs/usr/libexec/antumbra-greeter-session` |
| `GI` | `config/rootfs/usr/libexec/antumbra-greeter-inner` |
| `PHOC` | `config/rootfs/etc/antumbra/phoc.ini` |
| `GSO` | `config/rootfs/usr/share/glib-2.0/schemas/90_antumbra.gschema.override` |
| `ARCH` / `KI` / `VMT` / `HV` | `docs/architecture.md` / `docs/known-issues.md` / `docs/vm-testing.md` / `docs/hardware-validation.md` |
| `ADW` | libadwaita 1.7.6 stylesheet compiled into `build/work/qemu-virt/rootfs/usr/lib/aarch64-linux-gnu/libadwaita-1.so.0` (read with `strings`; no line numbers, rules quoted). This is the library the image ships (`dpkg` status: `libadwaita-1-0 1.7.6-1~deb13u1`, `libgtk-4-1 4.18.6+ds-2`), not repo code: use it only for widget metrics the repo does not set. |
| `SHOT1` | `build/work/qemu-virt/run-f1/smoke/display.png` (Welcome screen, top, defaults) |
| `SHOT2` | `build/work/qemu-virt/run-f4b/smoke/welcome-android.png` (Android image, scrolled to the end, "Android apps (experimental)" switched on with Alt+A) |
| `SHOT3` | `build/work/qemu-virt/run-f4b/smoke/display.png` (same as SHOT1, Android image) |

The built rootfs copies of `W`, `S`, `G`, `CSS`, `APPS`, `A` and `P` are byte-identical to the
repo files (checked with `cmp`). The built `etc/antumbra/persistence-features.conf` has one extra
line 16, the Android feature appended by `H56:149`.

Screenshot coordinates: the VM display is 720x1440 at phoc scale 2 (`PHOC:10-13`: "a 720x1440
virtio display at scale 2 gives the same 360x720 logical size class as the phone"), so
**1 logical px (lp) = 2 screenshot px**. The phone is 1440x3120 at scale 3 (`PHOC:6-8`), i.e.
**480x1040 lp**. Measurements below are given as screenshot px and lp.

---

## 1. Where the screen runs (context the simulator should reproduce)

- It runs **before any user session**, as user `antumbra-greeter`, under greetd (`config/rootfs/etc/greetd/config.toml:8-10`), inside a **bare phoc compositor with no Phosh shell** (`GS:19-21`, `ARCH:683-687`). Consequence: **no status bar, no clock, no gesture pill**; the window fills the screen (SHOT1, SHOT2 show no status bar).
- The on-screen keyboard is **squeekboard**, started next to the Welcome screen; it "shows itself whenever a text field has focus" (`GI:4-9`; `HV:36` "Touch works in the Welcome screen; squeekboard appears for text fields.").
- The window goes **fullscreen** once presented (`W:284-288`); default size requested is 480x1000 (`W:57`).
- Colour scheme is **forced dark** whatever the setting (`W:267-272`), and `welcome.css` is loaded at APPLICATION priority (`W:273-279`). The greeter session sets `GSETTINGS_BACKEND=memory` and `ADW_DISABLE_PORTAL=1` so the look comes from the schema defaults (`GS:9-14`): font `'Roboto 11'`, accent `'purple'`, `color-scheme='prefer-dark'` (`GSO:11,14,17`).
- Application id `org.antumbra.Welcome` (`W:261`).
- No language, keyboard-layout or formats options exist (Tails has them; the code has none - repo silent beyond that). No Unsafe Browser option is written (the shell library can read `tails.unsafe-browser`, `TG:10,30-31`, but `W` never writes it).

## 2. Window and header

| Item | Value | Source |
|---|---|---|
| Window title (shown centred in the header bar) | `Welcome to Antumbra` | `W:56`; SHOT1 |
| Header bar | `Adw.HeaderBar` in an `Adw.ToolbarView`, **no window buttons** (start and end title buttons hidden) | `W:61-66` |
| Header min-height | `64px` | `CSS:30-32` |
| Header title font | `24px`, weight `400` | `CSS:34-37` |
| Header colours | background `--antumbra-surface` `#141218`, text `--antumbra-on-surface` `#e6e1e9`; `--headerbar-shade-color: transparent` | `CSS:17-20`, `APPS:35,40` |
| Measured | title ink x 123-595, y 48-84 px; top bar ends at y=140 px (70 lp). When content is scrolled under it, a shadow line appears at y 140-147 px (from `#0d0c12` fading to `#141218`) | SHOT1, SHOT2 |

The top shadow when scrolled is libadwaita's ToolbarView undershoot: `ADW`: `toolbarview.undershoot-top scrolledwindow > undershoot.top { box-shadow: inset 0 1px color-mix(in srgb, var(--shade-color) 75%, transparent); background: linear-gradient(to bottom, color-mix(in srgb, var(--shade-color) 75%, transparent), transparent 4px); }` with dark `@define-color shade_color RGB(0 0 6/25%);`. The same shade appears **above the bottom bar** while content continues under it (SHOT1 y 1250-1264 px), using the `undershoot.bottom` rule (`ADW`, same shape "to top").

## 3. Privacy self-check banner (conditional)

- An `Adw.Banner` sits under the header bar (`W:68-73`). It is **revealed only if** `/run/antumbra/selfcheck.status` contains lines with `" FAIL"` (`W:27,37-42,69-72`).
- Title, verbatim construction (`W:71`):
  `"Privacy self-check failed: " + "; ".join(failures)[:200]`
  i.e. the prefix, then the failing lines (each stripped) joined by `"; "`, the **joined string cut at 200 characters** (the prefix is not counted).
- Line format written by the self-check: `<check> FAIL: <detail>` (`SC:16`). Possible early-run lines (the run before the Welcome screen, `config/rootfs/usr/lib/systemd/system/antumbra-selfcheck.service`, "Before=antumbra-apply-welcome-settings.service"), verbatim from `SC`:
  - `firewall FAIL: Tor-enforcement ruleset is not loaded or incomplete` (`SC:26`)
  - `firewall-android FAIL: the rules for the Android bridge are not loaded or incomplete` (`SC:40`)
  - `android-bridge FAIL: waydroid-tor is missing, has the wrong address, forwards or routes to loopback` (`SC:48`, Android images only)
  - `lxc-net FAIL: lxc's default bridge is up` (`SC:53`)
  - `binder FAIL: binder devices not root-only:<list>` (`SC:66`)
  - `android-off FAIL: the Android container service runs although Android apps are off` (`SC:68`)
  - `resolver FAIL: /etc/resolv.conf does not point only at 127.0.0.1` (`SC:73`)
  - `ipv6-disabled FAIL: IPv6 is not disabled by sysctl` (`SC:74`)
  - `sysctl FAIL: systemd-sysctl reported errors (see journal)` (`SC:75`)
  - `overlay-root FAIL: root is not an overlay` (`SC:78`)
  - `swap FAIL: swap on flash storage` (`SC:79`)
  - `flash-writes FAIL: a flash partition is mounted read-write outside Persistent Storage` (`SC:81`)
  - `init-on-free FAIL: init_on_free=1 missing from the kernel command line` (`SC:85`)
  - `pstore FAIL: persistent kernel log records present` (`SC:86`)
  - `radios FAIL: Bluetooth or NFC driver loaded` (`SC:89`)
  - `usb-gadget FAIL: USB gadget function loaded` (`SC:90`)
  - `usbguard FAIL: usbguard is not running` (`SC:92`)
  - `modemmanager FAIL: ModemManager is running` (`SC:94`)
  - `qrtr-access FAIL: unprivileged processes can open QRTR sockets` (`SC:97`)
- Look: `banner > revealer > widget { background-color: #93000a; color: #ffdad6; }` ("Material 3's error container") (`CSS:66-70`). Padding from `ADW`: `banner > revealer > widget { ... padding: 6px; }`. Wrapping/alignment of the banner title: libadwaita default, not observed in any screenshot (repo silent).
- The banner is read once, when the window is built (`W:69`). No banner appears in SHOT1/SHOT2 (all checks passed).
- Consequence of a failed firewall check after Start: `antumbra-unblock-network` refuses to unblock the network (`UN:17-22`, message to the log only: `refusing to unblock the network: firewall self-check did not pass`); the applier only logs `network unblock reported an error (see journal)` (`A:264`). The user sees nothing more than the banner.

## 4. Page layout: groups in order

The content is an `Adw.PreferencesPage` (scrolls vertically) (`W:75-76`). Groups, top to bottom:

| # | Group title | Group description (verbatim) | Present when | Source |
|---|---|---|---|---|
| 1 | `Persistent Storage` | `Encrypted storage that survives shutdown. Everything else is forgotten.` | always | `W:79-81` |
| 2 | `Network and Tor` | (none) | always | `W:103-104` |
| 3 | `Security` | `A passphrase locks the screen. Without one, anyone who picks up the phone can use the session.` | always | `W:122-124` |
| 4 | `Android apps` | `Android 13 (LineageOS) in a container, with F-Droid and no Google apps. Its traffic goes only through Tor. Off by default.` | only in images built with `ANTUMBRA_ANDROID=1` (`/usr/share/antumbra/android` exists), and always in `--demo`/`--self-test` | `W:31-33,133-138` |
| 5 | `Before you start` | (none) | always | `W:149-157` |
| 6 | (no title) | holds only the error label | always (label empty until an error) | `W:159-162` |

Then, **outside the scrolling page**, in the ToolbarView's bottom bar: the Start button (`W:164-167`).

The simulator should offer both image variants (with and without the Android group), or say which one it shows.

## 5. Rows, group by group

Widget names are libadwaita classes. "Insensitive" = greyed out and not editable (GTK `set_sensitive(False)`); "hidden" = not shown at all (`set_visible(False)`).

### 5.1 Group 1 "Persistent Storage"

| Row | Widget | Title (verbatim) | Subtitle | Default / initial state | Source |
|---|---|---|---|---|---|
| 1 | `Adw.ComboRow` (dropdown) | `Persistent Storage` | none | first option selected (`Do not use (amnesic session)`) | `W:83-93` |
| 2 | `Adw.PasswordEntryRow` | `Persistent Storage passphrase` | none | empty, **insensitive** | `W:94-96` |
| 3 | `Adw.PasswordEntryRow` | `Repeat passphrase` | none | empty, **insensitive**; **hidden when the volume exists** (state `luks`) | `W:97-100` |

Dropdown options depend on the boot-time Persistent Storage state read from `/run/antumbra/persistence-state` (`W:28,45-51,82-90`):

| State file says | Options (verbatim, in order) | Internal values |
|---|---|---|
| `luks` (an encrypted volume exists) | `Do not use (amnesic session)`, `Unlock` | `none`, `unlock` |
| anything else (`none`, `absent`, empty, or file unreadable = `unknown`) | `Do not use (amnesic session)`, `Create (erases the data partition)` | `none`, `create` |

The state is written before greetd starts by `antumbra-persistence status --quiet` (`config/rootfs/usr/lib/systemd/system/antumbra-persistence-probe.service:5,10`): `luks` if the `ANTUMBRA_DATA` partition holds a LUKS volume, `none` if the partition exists without one, `absent` if there is no such partition (`P:36-48`). So only one of "Unlock"/"Create" is ever offered in a boot.

SHOT1: the combo row shows the title left, the selected value right-aligned and ellipsized (`Do not use (amnesic …`), then a down chevron.

### 5.2 Group 2 "Network and Tor"

| Row | Widget | Title (verbatim) | Subtitle (verbatim) | Default | Source |
|---|---|---|---|---|---|
| 1 | `Adw.SwitchRow` | `MAC address anonymization` | `Random Wi-Fi hardware address for this session` | **on** | `W:105-108` |
| 2 | `Adw.ComboRow` (dropdown) | `Connect to Tor` | none | `Automatically` (index 0) | `W:109-113` |
| 3 | `Adw.EntryRow` (single-line text) | `Bridges: obfs4, webtunnel or meek_lite, separated by ;` | none | empty, **insensitive** | `W:114-119` |

"Connect to Tor" options, verbatim and in order, with the stored value (`W:110-111,197`):

| Index | Label | Stored `ANTUMBRA_TOR_MODE` |
|---|---|---|
| 0 | `Automatically` | `direct` |
| 1 | `Through bridges (enter below)` | `bridges` |
| 2 | `Offline mode (no network at all)` | `offline` |

The bridge row's title is the row's label/placeholder; it is ellipsized at the VM's 360-lp width (SHOT1: `Bridges: obfs4, webtunnel or meek_lite, separ…`); the code comment says the title "fits the phone's 480-pixel width; a longer one is cut short" (`W:114-116`).

### 5.3 Group 3 "Security"

| Row | Widget | Title (verbatim) | Subtitle (verbatim) | Default | Source |
|---|---|---|---|---|---|
| 1 | `Adw.PasswordEntryRow` | `Screen-lock passphrase (recommended)` | none | empty, sensitive | `W:125-126` |
| 2 | `Adw.PasswordEntryRow` | `Repeat passphrase` | none | empty, sensitive | `W:127-128` |
| 3 | `Adw.SwitchRow` | `Administration (sudo) with that passphrase` | `Off by default, as in Tails` | **off** | `W:129-131` |

### 5.4 Group 4 "Android apps" (Android images only)

| Row | Widget | Title (verbatim) | Subtitle (verbatim) | Default | Source |
|---|---|---|---|---|---|
| 1 | `Adw.SwitchRow` with mnemonic | `_Android apps (experimental)` (displayed `Android apps (experimental)`; underscore = mnemonic, `use_underline=True`) | `A weaker sandbox than the rest of Antumbra: use only apps you trust.` | **off** | `W:34,139-143` |
| 2 | `Adw.SwitchRow` | `Keep Android apps and data` | `In Persistent Storage, with Android's own usage history` | **off, insensitive** | `W:144-147` |

SHOT2 shows row 1 on (accent track, dark knob) and row 2 off and greyed out (Persistent Storage was "Do not use").

### 5.5 Group 5 "Before you start"

Three `Adw.ActionRow`s, plain text, titles wrap without a line limit (`set_title_lines(0)`), no subtitle, not clickable (`W:150-157`). Verbatim, in order:

1. `Tor Browser for arm64 Linux exists only in Tor Project's alpha channel. Tor Project advises people at risk not to rely on alpha releases.` (`W:29-30,152`)
2. `The bootloader is unlocked: an attacker with the phone in hand can replace the system. The orange warning at boot is expected.` (`W:153`)
3. `The cellular radio stays off. Only Wi-Fi is used, through Tor.` (`W:154`)

### 5.6 Group 6: error label

A `Gtk.Label` with `wrap=True` and CSS class `error`, added to an untitled group at the **end of the scrolling page** (below "Before you start") (`W:159-162`). Non-row widgets in an `Adw.PreferencesGroup` go below its (empty) list, so the label is **not on a card**. Default `Gtk.Label` alignment is centred (repo silent on alignment; library default). Colour: `ADW` `.error { color: var(--accent-color); ... --accent-color: var(--error-color); }` with dark `@define-color error_color oklab(from @error_bg_color max(l, 0.85) a b);` and `@define-color error_bg_color @red_4;` `@define-color red_4 #c01c28;` which computes to **`#ff938c`** (computed here, not measured: no screenshot shows an error).

Nothing in the code scrolls the page to the label: if the page is scrolled to the top, the message is below the fold (repo silent on any scroll-to-error; none exists in `W`).

### 5.7 Start button (bottom bar, not scrolling)

| Item | Value | Source |
|---|---|---|
| Widget | `Gtk.Button`, classes `suggested-action`, `pill`, centred (`halign=CENTER`), `margin_top=12`, `margin_bottom=24`, in the ToolbarView bottom bar | `W:164-167` |
| Labels | initial `Start Antumbra`; while working `Applying settings…` (U+2026 ellipsis), insensitive; after a failure back to `Start Antumbra`, sensitive; after a logout (settings already applied this boot) `Start a new session`; demo mode only `Done (demo)` | `W:164,172,223,251,256` |
| Look | `button.pill.suggested-action { min-height: 24px; padding: 14px 48px; font-size: 16px; font-weight: 500; }`; fill = accent `#cebdfe`, text = `#35275d` | `CSS:72-78`, `APPS:29-30,44-45`, `ADW` `button.suggested-action { color: var(--accent-fg-color); }`, `ADW` `button.pill { padding: 10px 32px; border-radius: 9999px; }` |
| Disabled look | `ADW` `button:disabled { filter: Opacity(var(--disabled-opacity)); }`, `--disabled-opacity: 50%` | `ADW` |
| Measured | button x 154-566 px, y 1288-1392 px (206 x 52 lp at 360-lp width); text ink x 251-467, y 1326-1349; bottom bar starts at y=1264 px (632 lp), i.e. bottom bar height 88 lp = 12 + 52 + 24 | SHOT1 |

## 6. Mnemonics and keyboard

- The only mnemonic: **Alt+A** toggles "Android apps (experimental)" (`W:139-140`; `VMT:293-295` "turns on "Android apps" at the Welcome screen (Alt+A, the switch's mnemonic ...)"). In GTK 4 the underline under "A" is shown only while Alt is held (library behaviour; SHOT2 shows no underline).
- No other mnemonics, no accelerators. The entry rows do not connect `entry-activated`, so **Enter in a text row does not press Start** (nothing connected in `W`; no default widget set).

## 7. Sensitivity and visibility rules (exact)

From `W:94-100,118,146,174-183` (handlers are connected to the Persistent Storage dropdown's `notify::selected`, the Android switch's `notify::active` (both call `on_persistence_changed`), and the Tor dropdown's `notify::selected`):

```
initially:
  pers_pass.sensitive   = false
  pers_pass2.sensitive  = false
  pers_pass2.visible    = (state != "luks")          # never changes afterwards
  bridges.sensitive     = false
  android_keep.sensitive= false                      # Android images only

on Persistent Storage dropdown change, or Android switch change:
  choice = "none" | "unlock" | "create"
  pers_pass.sensitive  = (choice != "none")
  pers_pass2.sensitive = (choice == "create")
  if android rows exist:
      android_keep.sensitive = (choice != "none") and android.active

on Connect-to-Tor dropdown change:
  bridges.sensitive = (selected index == 1)          # "Through bridges (enter below)"
```

Notes:
- Making a row insensitive **does not clear its text or switch state** (no code does). E.g. "Keep Android apps and data" switched on, then Android switched off: the Keep switch stays on but greyed; it is ignored at Start (section 8).
- The screen-lock rows and the admin switch are always sensitive.
- After a logout in the same boot (`/run/antumbra/welcome-applied` exists and not demo), **the whole page is insensitive** and the button reads `Start a new session` (`W:168-172`). Widgets show their defaults (it is a fresh process), not the settings applied earlier.

## 8. Validation at Start (exact order and messages)

`on_start` first clears the error label, then runs `collect()`; on the first `ValueError` it puts the message in the error label and stops (button stays `Start Antumbra`, sensitive) (`W:215-221`). `collect()` in order (`W:185-213`):

```
persistence = choice of dropdown 1                         # none | unlock | create
pp = text of "Persistent Storage passphrase" (read even if insensitive)
if persistence == "create":
    if len(pp) < 12:            error "The Persistent Storage passphrase needs at least 12 characters."
    if pp != text of row "Repeat passphrase" (group 1):
                                error "The Persistent Storage passphrases differ."
if persistence == "unlock" and pp == "":
                                error "Enter the Persistent Storage passphrase, or choose not to use it."
mac_spoof = MAC switch
network   = ["direct", "bridges", "offline"][Tor dropdown index]
bridges   = normalise_bridges(text of bridge row)          # section 9; done in every mode
if network == "bridges":
    lines = bridge_lines(bridges.split(";"))               # may raise its own errors, section 9
    if lines is empty:          error "Enter at least one bridge line, or connect automatically."
pw = text of "Screen-lock passphrase (recommended)"
if pw != text of row "Repeat passphrase" (group 3):
                                error "The screen-lock passphrases differ."
if pw != "" and len(pw) < 6:    error "The screen-lock passphrase needs at least 6 characters."
admin = admin switch
if admin and pw == "":          error "Administration needs a passphrase."
if android rows exist:
    android = Android switch
    android_persistent = android and keep switch and persistence != "none"
```

Facts that follow from the code:
- "Unlock" has **no minimum length**, only non-empty; no repeat row.
- Screen-lock passphrase: the **differ check comes before the length check**; empty in both rows = no passphrase, accepted.
- `len()` is Python's: Unicode code points (a JS port must count code points, e.g. `Array.from(s).length`, not UTF-16 units).
- Bridges are **not validated** unless "Through bridges" is chosen, but their normalised text is stored in every mode (`W:198`, `S:194`).
- The validation messages are verbatim from `W:191,193,195,202,205,207,210`.

## 9. Bridges: exact port of `normalise_bridges` and `bridge_lines`

Constants (`S:28-42`):

```
BRIDGE_TRANSPORTS    = ("obfs2", "obfs3", "obfs4", "webtunnel", "meek_lite")
ADDRESSED_TRANSPORTS = ("obfs2", "obfs3", "obfs4")
SNOWFLAKE_REFUSED = "Snowflake bridges do not work in Antumbra: snowflake reaches its proxies through WebRTC over UDP, and the firewall lets Tor make only TCP connections and DNS queries. Use obfs4 or webtunnel bridges."
IPV6_REFUSED = "{address} is an IPv6 address. IPv6 bridges do not work in Antumbra: IPv6 is off, and the firewall lets Tor connect only over IPv4. Use bridges with IPv4 addresses."
```

`normalise_bridges(text)` (`S:45-50`):

```
pieces = split text at every "\r", "\n" or ";"        # re.split(r"[\r\n;]", text)
keep each piece trimmed of whitespace (Python str.strip), drop empty ones
return pieces joined with ";"
```

`bridge_lines(lines)` (`S:53-84`), called with `bridges.split(";")`:

```
out = []
for line in lines:
    line = strip(line)
    words = line split on whitespace into at most 2 parts     # str.split(None, 1)
    if words not empty and lower(words[0]) == "bridge":
        line = words[1] if 2 parts else ""                    # remainder, leading whitespace gone
    if line == "" or line starts with "#": continue           # comments and empty lines skipped
    words = line split on whitespace                          # str.split()
    kind = words[0]
    if lower(kind) == "snowflake": raise SNOWFLAKE_REFUSED    # case-insensitive
    if kind not in BRIDGE_TRANSPORTS and "." not in kind and ":" not in kind:
        raise "Unsupported bridge type: " + kind + ". Antumbra takes obfs4, webtunnel, meek_lite, obfs2, obfs3 and plain bridges."
    if kind not in BRIDGE_TRANSPORTS:      address = kind       # a plain bridge (address first)
    elif kind in ADDRESSED_TRANSPORTS and len(words) > 1: address = words[1]
    else:                                  address = ""         # webtunnel, meek_lite, or obfs* without address
    if address starts with "[" or address contains more than one ":":
        raise IPV6_REFUSED with {address} replaced by address
    out.append(line)                                          # the line without a leading "Bridge"
return out
```

Exact message for an unsupported type (`S:71-72`), e.g. `Unsupported bridge type: conjure. Antumbra takes obfs4, webtunnel, meek_lite, obfs2, obfs3 and plain bridges.`

Behaviours that follow (all from the code above; several are in `tests/unit/test_settings.py`):
- Transport names are **case-sensitive** except "snowflake" and the "Bridge" prefix: `OBFS4 ...` gives `Unsupported bridge type: OBFS4. ...`; `Bridge Snowflake ...` gives the snowflake message (`tests/unit/test_settings.py:142-145`).
- webtunnel and meek_lite may have an IPv6 placeholder address and are accepted (`tests/unit/test_settings.py:164-169`).
- IPv6 refusal examples and the exact `{address}` shown (`tests/unit/test_settings.py:155-162`): `[2001:db8::5]:443 <fp>` -> `[2001:db8::5]:443`; `2001:db8::5 <fp>` -> `2001:db8::5`; `Bridge obfs4 [2001:db8::5]:443 ...` -> `[2001:db8::5]:443`; `obfs3 [2001:db8::6]:80 ...`; `obfs2 [::ffff:192.0.2.4]:443 ...`.
- A plain bridge needs a `.` or `:` in its first word (`192.0.2.7:9001 <fp>` and `192.0.2.8 <fp>` are accepted).
- The first refused line stops the check; its message is the one shown.
- Normalisation test vector (`tests/unit/test_settings.py:125`): `" {OBFS4}\r\n\r\n{WEBTUNNEL}\n;; {MEEK} ;\n"` -> `"{OBFS4};{WEBTUNNEL};{MEEK}"`; `" \r\n ; \n"` -> `""`.
- Self-test vector (`W:298-316`): a snowflake line `snowflake 192.0.2.3:80 2B280B23E1107BB62ABFC40DDCC8824814F80A72` with "Through bridges" is refused with `SNOWFLAKE_REFUSED`; `"obfs4 192.0.2.1:443 A cert=x iat-mode=0\r\n\nwebtunnel 192.0.2.2:443 B url=https://example.org/b\n"` is stored as `obfs4 192.0.2.1:443 A cert=x iat-mode=0;webtunnel 192.0.2.2:443 B url=https://example.org/b`.
- The bridge row is **one line**; bridges pasted one per line keep their line breaks in the GTK entry and become `;` when stored (`W:114-116`, `ARCH:383-390`, `KI:88-90`). (An HTML `<input>` strips pasted line breaks; a faithful port must turn pasted `\r`/`\n` into `;` itself, or keep them in a hidden value.)
- After the session starts, the NetworkManager dispatcher runs the same check again through `antumbra-tor-connect` (`TC:63-67`), which also says `no bridge lines given` if nothing is left; failures there are ignored silently (`D:25-27`, `ARCH:394-396`).

## 10. What happens on Start

### 10.1 Welcome-screen side (`W:215-256`)

1. Error label cleared; `collect()` (section 8). On error: message shown, stop.
2. Start button set **insensitive** and labelled `Applying settings…`. The rest of the page stays sensitive (only the button is changed). A background thread runs step 3.
3. If settings were not yet applied this boot (`/run/antumbra/welcome-applied` absent):
   - `submit`: note the current failure report, then write the settings files (section 10.2) unless a previous attempt's `welcome-done` is still there (after a time-out) (`S:97-107`).
   - `wait_for_applier`: poll every 0.5 s until `/run/antumbra/welcome-applied` exists (success) or a **new** `/run/antumbra/welcome-failed` appears (failure; its text is the error) or **600 s** pass (`S:110-134`).
4. Ask greetd to create a session for user `amnesia` (empty answers to PAM prompts) and start `/usr/libexec/antumbra-session` with `XDG_SESSION_TYPE=wayland`, `XDG_CURRENT_DESKTOP=Phosh:GNOME`, `XDG_SESSION_DESKTOP=phosh`, `GDMSESSION=phosh` (`W:241-244`, `G:38-50`). The Welcome app then quits (`W:245`); squeekboard is killed (`GI:9-12`). greetd's PAM lets `amnesia` in without a password (`config/rootfs/etc/pam.d/greetd:7`).
5. Any exception in 3-4: error label shows its text, button back to `Start Antumbra`, sensitive (`W:246-256`). **No retry limit** exists anywhere.

No spinner, progress bar or progress text other than the button label exists (repo silent on anything else).

Error texts the Welcome side can show (besides the applier's, 10.4):
- `timed out waiting for the settings to be applied` (`S:133`)
- `settings could not be applied` (empty failure report) (`S:131`)
- `unexpected password hash format` (`S:166`)
- `GREETD_SOCK is not set: not running under greetd` (`G:18`), `greetd closed the connection` (`G:34`), `greetd refused the session: {resp}` (`G:47`), `greetd could not start the session: {resp}` (`G:50`)

Logout case: greetd shows the Welcome screen again; with settings applied this boot the page is insensitive and the button says `Start a new session` (`W:168-172`, `ARCH:757-759` "settings cannot change in the same boot, only a new session can start"). Pressing it still runs `collect()` on the default widgets, shows `Applying settings…`, skips writing and waiting, and starts the session (`W:215-245`).

Demo mode (`--demo`): settings written to a temp dir, error label shows `Demo: settings written to {root}`, button `Done (demo)` (`W:228-232,249-251`). Not the real flow.

### 10.2 Files the Welcome screen writes (`S:184-225`)

Format: `KEY=value` lines, value shell-quoted with `shlex.quote` (e.g. `true` stays bare, empty becomes `''`). Root `/var/lib/antumbra/settings`.

| File | Keys and values |
|---|---|
| `persistent/tails.macspoof` | `TAILS_MACSPOOF_ENABLED=true|false` |
| `persistent/tails.network` | `TAILS_NETWORK=false` if offline else `true`; `ANTUMBRA_TOR_MODE=direct|bridges|offline` |
| `persistent/tails.bridges` | `ANTUMBRA_BRIDGES=<normalised bridges, ';'-separated>` |
| `persistent/tails.password` | `TAILS_USER_PASSWORD=<sha512crypt $6$ hash>` (mode 0600), only if a screen-lock passphrase was given; otherwise the file is removed |
| `persistent/antumbra.admin` | `ANTUMBRA_ADMIN_ENABLED=true|false` |
| `persistent/antumbra.android` | `ANTUMBRA_ANDROID_ENABLED=true|false`; `ANTUMBRA_ANDROID_PERSISTENT=true` only if Android on and keep on and persistence is unlock/create |
| `transient/tails.create-persistence` | `CREATE_PERSISTENT_STORAGE=true|false` |
| `transient/antumbra.persistence` | `ANTUMBRA_PERSISTENCE=none|unlock|create` |
| `transient/antumbra.persistence-passphrase` | the raw passphrase (0600), only for unlock/create with a non-empty passphrase |
| `transient/welcome-done` | `1` (the trigger for the applier) |

The hash is made with `openssl passwd -6 -stdin` (`S:161-167`).

### 10.3 Root-side applier, in order (`A:118-266`)

Triggered by `welcome-done` (`config/rootfs/usr/lib/systemd/system/antumbra-apply-welcome-settings.path:5-6`), once per boot.

1. Remove an old failure report; refuse if already applied this boot, if no `welcome-done`, or if the settings directories are not the greeter's (`A:118-124`).
2. Stage (move) each greeter file into a root-only directory and use it only if it is a regular file owned by the greeter (`A:126-142`).
3. Persistent Storage (`A:144-180`):
   - `create`: `antumbra-persistence create` (LUKS2, argon2id, 1 GiB memory, 4 iterations, label `AntumbraData`, ext4, feature directories created except "off" ones: `P:50-73`), then `unlock`, then activate features.
   - `unlock`: `antumbra-persistence unlock` then activate features.
   - activate: if Android on **and** keep on: `antumbra-persistence enable android` (creates its directory the first time) then `activate` (mounts every feature); otherwise `activate --skip android` (`A:148-155`).
   - `none`: refuse if a failed attempt left the volume open (`A:172-179`).
4. Shred the passphrase file (`A:181`).
5. Copy the settings to `settings/applied/` (root-owned); network and Android settings world-readable (`A:183-194`).
6. Screen lock and admin (`A:196-210`): with a passphrase, `chpasswd -e` sets `amnesia`'s password; with admin also a sudoers rule `amnesia ALL = (ALL) ALL` and a polkit admin rule. Without a passphrase: `passwd -d amnesia` ("no passphrase: screen lock is not protective, administration disabled").
7. Android on: create `/run/antumbra/android-enabled`, start `antumbra-waydroid.service` without waiting (`A:212-220`).
8. If this run unlocked/created the volume: save this boot's settings (`tails.macspoof tails.network tails.bridges antumbra.admin antumbra.android`, never `tails.password`) on the volume's Welcome-settings feature (`A:41-45,222-253`).
9. Drop staged copies; **touch `/run/antumbra/welcome-applied`** (this is what releases the Welcome screen); run `antumbra-unblock-network`; remove `welcome-done` (`A:255-266`). So the session starts while the network is being unblocked.

### 10.4 Applier failure texts (what the error label can show)

On failure the applier first re-locks Persistent Storage if this run opened it, removes `welcome-done`, then writes the message to `/run/antumbra/welcome-failed` (`A:69-84`). Verbatim messages:

| Message | When | Source |
|---|---|---|
| `wrong passphrase, or Persistent Storage is damaged` | Unlock with a wrong passphrase | `A:168` |
| `creating Persistent Storage failed` | Create failed (e.g. no `ANTUMBRA_DATA` partition) | `A:160` |
| `unlocking the new Persistent Storage failed` | after Create | `A:161` |
| `activating Persistent Storage failed` | Create or Unlock | `A:162,169` |
| `no passphrase for creating Persistent Storage` | | `A:158` |
| `no passphrase for unlocking Persistent Storage` | | `A:166` |
| `Persistent Storage is still open from a failed attempt; restart to start without it` | "Do not use" after a failed attempt left the volume open | `A:177` |
| `settings were already applied this boot` | | `A:120` |
| `no welcome-done marker` | | `A:121` |
| `/var/lib/antumbra/settings/persistent is not owned by antumbra-greeter` (or `.../transient`) | | `A:123` |
| `unexpected error (line N, exit status S)` | any other command failing | `A:85` |
| suffix `; Persistent Storage could not be locked again` | re-locking failed too | `A:75-77` |

## 11. Persistent Storage behaviour

- **Create** is offered only when no LUKS volume exists; its label warns `Create (erases the data partition)` (`W:90`). Needs a passphrase of >= 12 characters typed twice (`W:189-193`). Parameters: LUKS2, argon2id, `--pbkdf-memory 1048576` (1 GiB), `--pbkdf-force-iterations 4` (`P:54-57`, "Tails' tps parameters").
- **Unlock** is offered only when a LUKS volume exists; one passphrase row (the repeat row is hidden) (`W:87-100`).
  - Wrong passphrase: the applier fails with `wrong passphrase, or Persistent Storage is damaged` (`A:168`); the Welcome screen shows it, re-enables `Start Antumbra`, and the user can try again (`HV:98-101` "A wrong passphrase is refused: the Welcome screen shows the error and lets you start again."). **No retry limit, no delay** in the code. Each attempt rewrites all settings files (`ARCH:731-732`).
  - If the volume was left open by a failed attempt, unlock still checks the passphrase (`cryptsetup open --test-passphrase`, `P:79-82`, `ARCH:1038-1042`).
  - Duration: argon2id with 1 GiB "runs several times under emulation" and takes long in the VM (`VMT:443-445`); phone timing unmeasured (repo silent).
- Success shows nothing special: the session starts (the `Persistent Storage created`/`unlocked` messages go to the journal only, `P:72,88`).
- The Welcome screen **does not read back** stored settings: every question is asked again each boot (`KI:91-95`, `ARCH:741-747`).
- Features (`F:10-14`, plus `H56:149`), bind-mounted in this order (`ARCH:1005-1008`):

| Feature name | Directory on volume | Mounted at | Default |
|---|---|---|---|
| `persistent-folder` | `Persistent` | `/home/amnesia/Persistent` | on (created with the volume) |
| `welcome-settings` | `welcome-settings` | `/var/lib/antumbra/settings/persistent` | on |
| `network-connections` | `nm-system-connections` | `/etc/NetworkManager/system-connections` | on |
| `gnupg` | `gnupg` | `/home/amnesia/.gnupg` | on |
| `ssh-client` | `ssh` | `/home/amnesia/.ssh` | on |
| `android` (Android images only) | `waydroid` | `/home/amnesia/.local/share/waydroid` | **off**: created only by "Keep Android apps and data" |

  Dotfiles: "handled specially: symlinked into /home/amnesia", not in the features file, keeps nothing yet (`F:15`, `ARCH:1026-1029`). No Tor-bridges feature (`F:7-9`). The Welcome screen has **no per-feature switches** (no such widget in `W`).
- "Keep Android apps and data" needs: an image with Android, the Android switch on, and Persistent Storage set to Create or Unlock (`W:178-180,213`, `S:205-209`, `A:148-155`). It keeps Android's own usage history; turning it off later does not delete the stored data (`KI:239-242`).

## 12. Tor connection modes

| Choice | Stored | What happens after Start |
|---|---|---|
| `Automatically` | `TAILS_NETWORK=true`, `ANTUMBRA_TOR_MODE=direct` | Drivers unblocked, NetworkManager started (`UN:24-39`). On every connection up, the dispatcher runs `antumbra-tor-connect direct`: Tor `UseBridges 0`, no bridges, `DisableNetwork 0` (`D:23-24`, `TC:53-57`); then htpdate time sync unless it already succeeded (`D:30-33`). |
| `Through bridges (enter below)` | `TAILS_NETWORK=true`, `ANTUMBRA_TOR_MODE=bridges`, `ANTUMBRA_BRIDGES=...` | Same unblocking; on connection up the dispatcher splits the stored bridges at `;` and pipes them to `antumbra-tor-connect bridges -` (`D:25-27`): `UseBridges 1`, the bridge lines, `DisableNetwork 0`; Tor's sandbox off when a transport is used (`TC:60-72`). Prints `connecting through N bridge(s)` (journal only). |
| `Offline mode (no network at all)` | `TAILS_NETWORK=false`, `ANTUMBRA_TOR_MODE=offline` | Network drivers stay blocked: "network disabled by the user (offline mode); leaving drivers blocked" (`UN:12-15`); no interface exists; Tor keeps `DisableNetwork 1` (`ARCH:324-325`). |

Before the Welcome decision there is **no network driver, no interface and NetworkManager is inactive** (`VMT:124-125`; run-f1 `report.json` check "network: no frame of any kind left the guest before the Welcome decision"). Tails' Tor Connection assistant is not ported (`KI:72-77`). No bridge type has connected yet (`KI:83-84`).

## 13. MAC address anonymization

- Stored as `TAILS_MACSPOOF_ENABLED` (`S:189-190`). Treated as off only if explicitly `false` (`TG:20-23`).
- On: for every new Ethernet-type interface, `antumbra-spoof-mac` runs `macchanger -e` up to 3 times (`SM:99-104,132-142`; udev rule `config/rootfs/etc/udev/rules.d/00-mac-spoof.rules:14`). On failure, panic mode: interface down and its driver blocklisted for the session, or if that fails NetworkManager stopped and masked (`SM:81-97,144-152`). Recorded titles/messages (read only by the late self-check, `SC:173`): `Network interface disabled` / `MAC address anonymization failed for <nic>, so it is disabled for this session.`; `All networking disabled` / `MAC address anonymization failed for <nic> and the error recovery also failed, so all networking is disabled.` (`SM:92,95`).
- Off: the address is left alone ("MAC spoofing disabled by the user", `SM:108-111`).
- VM observation: hardware `52:54:00:a1:7b:01` became `50:54:00:b4:4d:48` (run-f1 `report.json`, check "after Welcome: the interface's MAC address is not the hardware one").

## 14. Screen lock and administration

- Passphrase set: Phosh's lock screen asks for it (`ARCH:761-764`). Not set: "the lock is not protective, and the Welcome screen says so" (the Security group description) and it does not force one (`KI:121-122`).
- Administration on requires the passphrase (`W:209-210`); gives sudo and polkit admin to `amnesia` (`A:201-206`). Off by default (`W:129-131`).
- The hash is never saved on Persistent Storage (`A:42-45`, `ARCH:746-749`).

## 15. Android apps effect

Switch on: `/run/antumbra/android-enabled` created and `antumbra-waydroid.service` started without waiting (`A:216-220`); Android prepares in the background ("Preparing Android takes a while, so it is not waited for", `A:214-215`). It is for this session only (`ARCH:854-857`). Off by default (`W:136-137`).

## 16. Look: CSS values

### 16.1 Palette (`APPS:28-46`, Material 3 "tonal spot" dark from seed `#4d2c9e`, `APPS:20-22`)

| Token | Value |
|---|---|
| `--antumbra-primary` | `#cebdfe` |
| `--antumbra-on-primary` | `#35275d` |
| `--antumbra-primary-container` | `#4c3e76` |
| `--antumbra-on-primary-container` | `#e8ddff` |
| `--antumbra-secondary-container` | `#494458` |
| `--antumbra-on-secondary-container` | `#e8def8` |
| `--antumbra-surface` | `#141218` |
| `--antumbra-surface-container-low` | `#1c1b20` |
| `--antumbra-surface-container` | `#211f24` |
| `--antumbra-surface-container-high` | `#2b292f` |
| `--antumbra-surface-container-highest` | `#36343a` |
| `--antumbra-on-surface` | `#e6e1e9` |
| `--antumbra-on-surface-variant` | `#cac4cf` |
| `--antumbra-outline-variant` | `#48454e` |
| `--accent-bg-color` | `var(--antumbra-primary)` |
| `--accent-fg-color` | `var(--antumbra-on-primary)` |

### 16.2 `welcome.css` (complete, `CSS:10-78`)

- `@import url("apps.css");`
- `:root`: window, view and header-bar backgrounds = surface `#141218`, their text = on-surface `#e6e1e9`; `--headerbar-shade-color: transparent`; cards = surface-container `#211f24`; popovers and dialogs = surface-container-high `#2b292f` (`CSS:12-27`).
- `headerbar { min-height: 64px; }`, `headerbar .title { font-size: 24px; font-weight: 400; }` (`CSS:30-37`).
- Group titles: `preferencesgroup label.heading { color: var(--antumbra-primary); font-size: 14px; font-weight: 500; }` (`CSS:40-44`).
- Cards: `list.boxed-list { border-radius: 24px; box-shadow: none; }`, first row top corners 24px, last row bottom corners 24px (`CSS:47-60`).
- `row .subtitle { color: var(--antumbra-on-surface-variant); }` (`CSS:62-64`).
- Banner: `#93000a` background, `#ffdad6` text (`CSS:67-70`).
- Start: `button.pill.suggested-action { min-height: 24px; padding: 14px 48px; font-size: 16px; font-weight: 500; }` (`CSS:73-78`).
- Switches (`APPS:51-63`): checked knob `var(--accent-fg-color)` (`#35275d`), checked track `var(--accent-bg-color)` (`#cebdfe`), `border-color: transparent`.

### 16.3 Font

`Roboto 11` (11 pt; GTK's 96 dpi makes it 14.67 px) for everything not set in px (`GSO:15-18`; `fonts-roboto-unhinted` in the rootfs at `usr/share/fonts/truetype/roboto/unhinted/RobotoTTF/`). Px sizes: header title 24, group titles 14 (weight 500), Start 16 (weight 500). Row subtitles: `ADW` `row label.subtitle { font-size: smaller; }`.

### 16.4 libadwaita metrics the repo relies on (from `ADW`, not repo code)

- Opacities (normal contrast): `--border-opacity: 15%; --dim-opacity: 55%; --disabled-opacity: 50%;`
- Dim text: group descriptions (class `dimmed`) and row subtitles use `opacity: var(--dim-opacity)` (55%).
- Page: `preferencespage > scrolledwindow > viewport > clamp > box { margin: 24px 12px; border-spacing: 24px; }` (24 lp top/bottom, 12 lp sides, 24 lp between groups).
- Group: `preferencesgroup > box, preferencesgroup > box box.labels { border-spacing: 6px; }`, `preferencesgroup > box > box.header:not(.single-line) { margin-bottom: 6px; }`.
- Rows: `row > box.header { margin-left: 12px; margin-right: 12px; border-spacing: 6px; min-height: 50px; }`, `row > box.header > box.title { margin-top: 6px; margin-bottom: 6px; border-spacing: 3px; }`; entry rows `margin-left: 6px; margin-right: 6px` plus `.editable-area { padding: 0 6px; }`, edit icon and peek button `min-width: 24px; min-height: 24px; padding: 5px;`, edit icon `:disabled { opacity: 30%; }`.
- Row separators: `list.boxed-list > row { border-bottom: 1px solid var(--card-shade-color); }` with dark `card_shade_color RGB(0 0 6/36%)` (measured `#151419` on the card).
- Focused entry row: `outline-color: color-mix(in srgb, var(--accent-color) 50%, transparent); outline-width: 2px; outline-offset: -1px;`.
- Switch: `switch { border-radius: 14px; padding: 3px; background-color: color-mix(in srgb, currentColor 15%, transparent); }`, `switch > slider { min-width: 20px; min-height: 20px; border-radius: 50%; background-color: color-mix(in srgb, white 80%, var(--view-bg-color)); box-shadow: 0 2px 4px RGB(0 0 6/20%); }`, `switch:disabled { filter: Opacity(var(--disabled-opacity)); }` (46 x 26 lp overall; measured 92 x 52 px).
- Popovers (the dropdown list): `popover > contents { padding: 8px; border-radius: 15px; }`, background `--popover-bg-color` = `#2b292f` (via `CSS:23`), border `1px solid RGB(0 0 0/14%)`, `row.combo popover > contents { min-width: 120px; }`. The open-dropdown look is libadwaita's (list of options, check mark on the selected one); **no screenshot shows it**.

### 16.5 Measured colours and geometry (SHOT1/SHOT2, px at scale 2)

| Element | Colour | Geometry |
|---|---|---|
| Page background | `#141218` | |
| Header title | `#e6e1e9` | ink y 48-84 |
| Group title (e.g. "Persistent Storage") | `#cebdfe` | ink x 26-255, y 194-219 |
| Group description | `#87848b` (on-surface at 55%) | 2 lines, ink y 239-299 |
| Card | `#211f24`, separators `#151419` | x 24-696 (12 lp side margins); card 1 y 328-656 (rows 54 lp each); card 2 y 784-1136 (MAC row 66 lp, others 54 lp) |
| Row title | `#e6e1e9` | |
| Row subtitle | `#7e7a82` (on-surface-variant at 55%) | |
| Insensitive row title | `#838087` (50%) | |
| Insensitive row subtitle | `#504c53` | SHOT2 "Keep" row |
| Combo value and chevron | `#e6e1e9` | value right-aligned, ellipsized; chevron x 642-661 |
| Password row icons (pencil, eye), insensitive | `#3e3c42` | pencil x 540-567, eye x 619-648 |
| Switch on | track `#cebdfe`, knob `#35275d` | x 576-668, y 824-876 |
| Switch off, insensitive | track `#302e33`, knob `#78777b` | SHOT2 |
| Android group card | rows 66 lp each | SHOT2 y 354-620 |
| "Before you start" card | text `#e6e1e9`; rows 68, 68, 54 lp | SHOT2 y 748-1132 |
| Start button | fill `#cebdfe`, text `#35275d` | x 154-566, y 1288-1392 |
| Bottom-bar undershoot | `#2b282e`..`#0d0c12` | y 1250-1264 (only while content continues below) |

VM-only artifacts not to reproduce: the black square/pointer and cursor (`VMT:57-62`; SHOT2 shows a mouse pointer at ~360,700).

### 16.6 Icons (Adwaita symbolic, from the rootfs `usr/share/icons/Adwaita/symbolic/`; licence CC-BY-SA-3.0 or LGPL-3 per `usr/share/doc/adwaita-icon-theme/copyright`)

Which icon each libadwaita widget uses is library behaviour; the shapes match SHOT1 (pencil and eye on password rows, pencil on the bridge row, chevron on combo rows). 16x16 viewBox path data, verbatim:

- `actions/document-edit-symbolic.svg` (pencil): `m 12.277344 0.832031 c -0.578125 0.007813 -1.167969 0.230469 -1.691406 0.753907 l -9 9 c -0.375 0.375 -0.585938 0.882812 -0.585938 1.414062 v 3 h 3 c 0.53125 0 1.039062 -0.210938 1.414062 -0.585938 l 9 -9 c 1.789063 -1.789062 0.082032 -4.390624 -1.890624 -4.570312 c -0.082032 -0.011719 -0.164063 -0.011719 -0.246094 -0.011719 z m -1.777344 3.605469 l 1.0625 1.0625 l -7.0625 7.0625 l -1.0625 -1.0625 z m 0 0`
- `actions/view-reveal-symbolic.svg` (eye): `m 8 2 c -3.648438 0.003906 -6.832031 2.476562 -7.738281 6.007812 c 0.914062 3.527344 4.097656 5.988282 7.738281 5.992188 c 3.648438 -0.003906 6.832031 -2.476562 7.738281 -6.011719 c -0.914062 -3.523437 -4.097656 -5.984375 -7.738281 -5.988281 z m 0 2 c 2.210938 0 4 1.789062 4 4 s -1.789062 4 -4 4 s -4 -1.789062 -4 -4 s 1.789062 -4 4 -4 z m 0 2 c -1.105469 0 -2 0.894531 -2 2 s 0.894531 2 2 2 s 2 -0.894531 2 -2 s -0.894531 -2 -2 -2 z m 0 0`
- `actions/view-conceal-symbolic.svg` (eye struck through, after peeking): `m 1.53125 0.46875 l -1.0625 1.0625 l 14 14 l 1.0625 -1.0625 l -2.382812 -2.382812 c 1.265624 -1.0625 2.171874 -2.496094 2.589843 -4.097657 c -0.914062 -3.523437 -4.097656 -5.984375 -7.738281 -5.988281 c -1.367188 0.011719 -2.707031 0.371094 -3.894531 1.042969 z m 6.46875 3.53125 c 2.210938 0 4 1.789062 4 4 c -0.003906 0.800781 -0.246094 1.578125 -0.699219 2.238281 l -1.46875 -1.46875 c 0.105469 -0.242187 0.164063 -0.503906 0.167969 -0.769531 c 0 -1.105469 -0.894531 -2 -2 -2 c -0.265625 0.003906 -0.527344 0.0625 -0.769531 0.167969 l -1.46875 -1.46875 c 0.660156 -0.453125 1.4375 -0.695313 2.238281 -0.699219 z m -6.144531 0.917969 c -0.753907 0.898437 -1.296875 1.957031 -1.59375 3.09375 c 0.914062 3.523437 4.097656 5.984375 7.738281 5.988281 c 0.855469 -0.007812 1.703125 -0.152344 2.511719 -0.425781 l -1.667969 -1.667969 c -0.277344 0.058594 -0.5625 0.089844 -0.84375 0.09375 c -2.210938 0 -4 -1.789062 -4 -4 c 0.003906 -0.28125 0.035156 -0.566406 0.09375 -0.84375 z m 0 0`
- `ui/pan-down-symbolic.svg` (chevron): `m 3.292969 7.707031 l 4 4 c 0.390625 0.390625 1.023437 0.390625 1.414062 0 l 4 -4 c 0.390625 -0.390625 0.390625 -1.023437 0 -1.414062 s -1.023437 -0.390625 -1.414062 0 l -3.292969 3.292969 l -3.292969 -3.292969 c -0.390625 -0.390625 -1.023437 -0.390625 -1.414062 0 s -0.390625 1.023437 0 1.414062 z m 0 0` (fill-rule evenodd)
- `actions/object-select-symbolic.svg` (check mark in the open dropdown): `m 13.753906 4.660156 c 0.175782 -0.199218 0.261719 -0.460937 0.246094 -0.726562 c -0.019531 -0.265625 -0.140625 -0.511719 -0.339844 -0.6875 c -0.199218 -0.175782 -0.460937 -0.261719 -0.726562 -0.246094 c -0.265625 0.019531 -0.511719 0.140625 -0.6875 0.339844 l -6.296875 7.195312 l -2.242188 -2.242187 c -0.390625 -0.390625 -1.023437 -0.390625 -1.414062 0 c -0.1875 0.1875 -0.292969 0.441406 -0.292969 0.707031 s 0.105469 0.519531 0.292969 0.707031 l 3 3 c 0.195312 0.195313 0.464843 0.304688 0.738281 0.292969 c 0.277344 -0.007812 0.539062 -0.132812 0.722656 -0.339844 z m 0 0`

## 17. VM timings (for pacing a simulation; not phone timings)

- run-f1 `report.json`: Start tapped at t=302.4 s; "settings applied and the Phosh session started" confirmed at t=385.5 s (polled every 5 s, under software emulation). The Welcome screen itself takes "a minute or two to appear under emulation" (`VMT:57-58`). Phone timings: repo silent (not booted on hardware yet, `README.md:31-32`).

## 18. Repo silent / not present

- No expander rows, no per-feature Persistent Storage switches, no language/keyboard/time-zone options, no Unsafe Browser option, no progress indicator besides the button label, no retry limit or lock-out for wrong passphrases, no auto-scroll to the error label, no tooltip texts, no help links.
- The look of the open dropdown popover, focused password rows (floating title above typed dots), and the banner's wrapping are libadwaita defaults never captured in a screenshot.
- Tor bootstrap progress is not shown on the Welcome screen at all (Tor connects only after the session starts, when a network comes up).
