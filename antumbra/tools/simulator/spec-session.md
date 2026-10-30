# Antumbra simulator: look and session spec (Phosh shell)

Scope: the Phosh session after the Welcome screen (top bar, home bar and
gesture pill, app overview with favourites ("dock") and app grid, quick
settings drawer, notifications, lock screen, power/system menus, OSD, app
splash, on-screen keyboard) and the assets for them. The Welcome screen,
apps' own windows, Tor and shutdown internals are other parts.

## 0. How facts are cited

| Prefix | Meaning |
|---|---|
| `path:line` | file in the repository's `antumbra/` directory |
| `image:/path:line` | file in the built root filesystem `build/work/qemu-virt/rootfs` (checked identical to `config/rootfs` for every Antumbra file used here) |
| `phosh:/ui/x.ui:line`, `phosh:/stylesheet/x.css:line`, `phosh:/icons/...` | Phosh 0.46.0's compiled-in GResource `/mobi/phosh/...`, extracted with `gresource extract image:/usr/libexec/phosh <path>` (line numbers refer to those extracted copies, which are not kept in the repository) |
| `phosh-bin "..."` | a string in `image:/usr/libexec/phosh` (`strings`), with the source file it sits next to |
| `shot:NAME` | screenshot in `build/work/qemu-virt/run-f1/smoke/` unless another run is named; measurements are in device pixels of the 720x1440 VM display at scale 2, so logical px = device px / 2 |

Versions in the image (`image:/var/lib/dpkg/status`): phosh 0.46.0-3+deb13u1,
phosh-plugins 0.46.0-3+deb13u1, phoc 0.46.0-1, squeekboard 1.43.1-1,
adwaita-icon-theme 48.1-1, libgnome-desktop-3 44.3-3, gtk 3.24.49-3,
fonts-roboto-unhinted 2:0~20170802-4. `image:/usr/bin/phosh-session:23`
echoes `0.46.0`.

"Not in the repo" / "unverified" marks anything that is Phosh's compiled
behaviour I could not read from a file or see in a screenshot.

## 1. Display, scale, layout size

- Phone panel 1440x3120 at scale 3, 60 Hz (`config/rootfs/etc/antumbra/phoc.ini:6-8`); logical size 480x1040.
- VM: 720x1440 virtio display at scale 2 = 360x720 logical; "gives the same 360x720 logical size class as the phone" (`config/rootfs/etc/antumbra/phoc.ini:10-13`). All screenshots are this VM.
- known-issues calls the phone "a 480-pixel-wide screen" (`docs/known-issues.md:176-177`).
- Simulator: use CSS px = logical px. An iPhone (about 390 logical px wide) sits between the VM (360) and the phone (480).
- App-grid buttons are 84 px wide: "(360px screen width - 2*3px flowbox margins - (4-1)*6px column spacing) / 4 columns = 84px" (`phosh:/ui/app-grid-base-button.ui:10-12`). Observed 4 columns at 360 px (`shot:session.png`). At 480 px the same rule gives 5 columns (derived, not observed).
- Display cutout / rounded corners: gmobile has no panel description for this phone, so the top-bar clock stays centred and items may sit close to the corners (`docs/known-issues.md:133-134`, `:149-151`).

## 2. Theme tokens

### 2.1 Palette (Material 3 "tonal spot" dark, seed `#4d2c9e`)

Seed: `config/rootfs/usr/share/antumbra/theme/shell.css:26-30`, `docs/architecture.md:805-809`.

| Token (shell.css name) | Hex | Tone | Role in the session | Source |
|---|---|---|---|---|
| `antumbra_primary` | `#cebdfe` | primary 80 | active tile fill, slider fill, focus rings, Return key, locked Shift, dialog suggested button, OSD level | `shell.css:34` |
| `antumbra_on_primary` | `#35275d` | primary 20 | text/icon on active tile, slider knob, dialog suggested-button text | `shell.css:35` |
| `antumbra_primary_container` | `#4c3e76` | primary 30 | latched Shift key | `shell.css:36` |
| `antumbra_on_primary_container` | `#e8ddff` | primary 90 | text on latched Shift | `shell.css:37` |
| `antumbra_secondary` | `#cbc3dc` | secondary 80 | (defined, unused by rules) | `shell.css:38` |
| `antumbra_secondary_container` | `#494458` | secondary 30 | `phosh_action_bg_color` (notification action buttons), keyboard modifier keys | `shell.css:39`, `:61`, `:402-417` |
| `antumbra_on_secondary_container` | `#e8def8` | secondary 90 | notification action text, modifier-key text | `shell.css:40`, `:219-221` |
| `antumbra_tertiary` | `#efb8c9` | tertiary 80 | (defined, unused by rules) | `shell.css:41` |
| `antumbra_surface` | `#141218` | neutral 6 | `phosh_bg_color`: top bar, home bar, drawer background, lock screen bg colour | `shell.css:42`, `:59` |
| `antumbra_surface_container_lowest` | `#0f0d13` | neutral 4 | app-overview scrim at 72 % | `shell.css:43`, `:255-257` |
| `antumbra_surface_container_low` | `#1c1b20` | neutral 10 | (Welcome/apps) | `shell.css:44` |
| `antumbra_surface_container` | `#211f24` | neutral 12 | on-screen keyboard background | `shell.css:45`, `:386` |
| `antumbra_surface_container_high` | `#2b292f` | neutral 17 | `phosh_notification_bg_color` (notification cards), search bar, system dialogs, OSD bubble | `shell.css:46`, `:60`, `:261`, `:329`, `:364` |
| `antumbra_surface_container_highest` | `#36343a` | neutral 22 | `phosh_button_bg_color` (inactive tiles, round drawer buttons, "Show All Apps"), slider trough, keys, OSD trough | `shell.css:47`, `:62`, `:175` |
| `antumbra_on_surface` | `#e6e1e9` | neutral 90 | `phosh_fg_color`: all shell text and symbolic icons, the gesture pill | `shell.css:48`, `:58` |
| `antumbra_on_surface_variant` | `#cac4cf` | neutral variant 80 | (Welcome subtitles) | `shell.css:49` |
| `antumbra_outline` | `#948f99` | neutral variant 60 | (defined, unused by rules) | `shell.css:50` |
| `antumbra_outline_variant` | `#48454e` | neutral variant 30 | (defined, unused by rules) | `shell.css:51` |
| `antumbra_light_surface` | `#fdf7ff` | neutral 98 | `phosh_splash_bg_color`: app-launch splash background | `shell.css:52`, `:63` |
| `antumbra_light_on_surface` | `#1c1b20` | neutral 10 | `phosh_splash_fg_color` | `shell.css:53`, `:64` |

The same values as CSS custom properties for GTK 4 apps (`--antumbra-*`,
`--accent-bg-color: var(--antumbra-primary)`, `--accent-fg-color: var(--antumbra-on-primary)`):
`config/rootfs/usr/share/antumbra/theme/apps.css:28-46`. Welcome-only
mappings: `config/rootfs/usr/share/antumbra/theme/welcome.css:12-27`.

Other colours:

| Colour | Use | Source |
|---|---|---|
| `#9141ac` | GNOME "purple" accent (`accent-color='purple'`); still shows "where the theme sets no colour of its own, such as the faint tint of a focused shell button" | `config/rootfs/usr/share/glib-2.0/schemas/90_antumbra.gschema.override:12-14`, `docs/known-issues.md:144-147` |
| `#cc0000` | GTK error colour on symbolic paths with `class="error"` (battery 0 % / 10 %); amber `warning` at 20 % | observed `shot:session.png` (battery icon pixels `#CC0000`); class marks: `config/rootfs/usr/share/icons/Antumbra/SOURCES:11-13,18,20,24` |
| `#252329` / `#514f55` | insensitive tile background / its label and icon | measured, `shot:tour-quick-settings.png` (Cellular, Night Light tiles) |
| `#59585a`, `#535157` | "No notifications" label / bell (dim, insensitive) | measured, `shot:tour-quick-settings.png` |
| `#141218` | `org.gnome.desktop.background primary-color` | `90_antumbra.gschema.override:29` |
| `#0f0d13` | `org.gnome.desktop.screensaver primary-color` (lock) | `90_antumbra.gschema.override:37` |
| `#e01b24` / `#ffffff` | Phosh's emergency button bg/fg (not overridden) | `phosh:/stylesheet/adwaita-dark.css:19-20` |
| `#ba5645` | end-session dialog warning text (not overridden) | `phosh:/stylesheet/common.css:646-649` |
| `#93000a` / `#ffdad6` | Welcome screen's failed-self-check banner (not the session) | `welcome.css:66-70` |

Phosh's own defaults that Antumbra replaces (for reference only):
`phosh_fg_color white`, `phosh_bg_color black`, notification `#282828`,
action `#474747`, button `#282828`, splash `#f6f5f4`/`#282828`
(`phosh:/stylesheet/adwaita-dark.css:3-17`).

### 2.2 State layers

- Tile button hover: `mix(@phosh_button_bg_color, @phosh_fg_color, 0.08)`; pressed `0.12` (`shell.css:134-141`).
- Active tile hover/pressed: `mix(primary, on_primary, 0.08 / 0.12)`, text on_primary (`shell.css:143-151`).
- Focus ring: `inset 0 0 0 2px #cebdfe` on top panel, home, lock screen and system-modal buttons (`shell.css:69-74`); on an active tile `alpha(on_primary, 0.4)` (`shell.css:157-159`).
- Keypad key: `alpha(#36343a, 0.6)`, pressed `alpha(#e6e1e9, 0.24)` (`shell.css:304-310`).
- Keyboard key pressed: `mix(#36343a, #e6e1e9, 0.16)` (`shell.css:398-400`).

### 2.3 Shapes

| Element | Radius | Source |
|---|---|---|
| Quick-setting tile | 28 px, min-height 64 px | `shell.css:104-109` |
| Split tile halves | 28 0 0 28 / 0 28 28 0 | `shell.css:122-132` |
| Drawer (settings menu) bottom corners, its scroller | 28 px | `shell.css:92-99` |
| Slider trough / fill | 14 px, 28 px tall | `shell.css:170-186` |
| Slider knob | 20x20, radius 10, `#35275d`, inset 2 px `#cebdfe` ring, margin 4 | `shell.css:188-196` |
| Notification card, media player, status pages, settings list box | 24 px | `shell.css:211-217` |
| Rows inside lists | 16 px | `shell.css:236-239` |
| App-grid button (icon + label) | 20 px, padding 6 0 4 0 | `shell.css:270-275` |
| Search bar | Phosh: 9999 px (pill); padding 10 20 10 16 | `phosh:/stylesheet/common.css:354-359`, `shell.css:259-262` |
| "Show All Apps" button | 9999 px, padding 6 24, margin 24 0 | `phosh:/stylesheet/common.css:422-426` |
| Lock-screen passphrase entry | 16 px | `shell.css:317-320` |
| System dialogs, power-menu buttons, OSD bubble | 28 px (dialog button corners 27) | `shell.css:326-343`, `:358-365` |
| Top-panel round buttons | 99 px | `phosh:/stylesheet/common.css:65-68` |
| Keyboard keys | 8 px | `shell.css:391-396` |

### 2.4 Typography

- Interface font `Roboto 11`, document font `Roboto 11` (`90_antumbra.gschema.override:15-18`); package `fonts-roboto-unhinted` (`config/packages/phosh.list:6-7`). Roboto is also the fontconfig `sans-serif` (`config/rootfs/etc/fonts/conf.d/52-antumbra-sans.conf:13-20`). Debian's Cantarell default is overridden (`90_antumbra.gschema.override:4-5`). For a web page: Roboto from Google Fonts, weights 400/500/700.
- Top panel base 15 px (`phosh:/stylesheet/common.css:4-8`); top-bar clock 16 px, Antumbra weight 500 (Phosh: bold) (`common.css:38-45`, `shell.css:79-82`); date 14 px weight 500 (`common.css:57-59`, `shell.css:79-82`); indicators 13 px, weight 500 (Phosh 800), tabular figures (`common.css:31-36`, `shell.css:84-87`).
- Quick-setting labels 14 px weight 500 (`shell.css:104-109`).
- App-grid labels 12 px ("label medium") (`shell.css:269-275`).
- Lock clock 80 px weight 400 (small variant 57 px); lock date 16 px weight 500 (small 14 px) (`shell.css:284-302`); Phosh's padding-top 40 px, margin 12 px 0, tabular figures, text-shadow `1px 1px 1.1px rgba(0,0,0,0.3)` remain (`phosh:/stylesheet/common.css:452-468`).
- Keypad digits 28 px weight 400 (`shell.css:312-315`).
- "No notifications": class `title-2` (`phosh:/ui/settings.ui:136-143`).
- Keyboard: `font-family: Roboto, sans-serif` (`shell.css:384-389`).
- Text over the wallpaper (top bar when not solid, lock screen) carries `text-shadow: 1px 1px 1.1px rgba(0, 0, 0, 0.3)` (`phosh:/stylesheet/common.css:18-24`, `:459`, `:467`, `:489`).

### 2.5 Gesture pill

- 108x4 px, rounded ends, `-gtk-recolor` to the shell foreground (= `#e6e1e9`), replacing Phosh's 150x15 bar (`shell.css:244-251`; Phosh's: `phosh:/stylesheet/common.css:248-253`).
- Drawn at 324x12 with `rx="6"` for scale 3 (`config/rootfs/usr/share/antumbra/theme/pill-symbolic.svg:2,10`).
- Phosh's failed-gesture shake (1.5 s, left/right) and half opacity while active still apply (`shell.css:244-247`; `phosh:/stylesheet/common.css:256-276`).
- Measured (`run-f4b/smoke/session.png`): pill x 252-467, y 1421-1428 (108x4 logical), colour `#E6E1E9`, centred in a home bar y 1410-1439 (15 logical px) filled `#141218`.

### 2.6 GSettings look (vendor defaults)

`config/rootfs/usr/share/glib-2.0/schemas/90_antumbra.gschema.override`:
`color-scheme='prefer-dark'` (:11), `accent-color='purple'` (:14),
`font-name='Roboto 11'` (:17), `document-font-name='Roboto 11'` (:18),
`show-battery-percentage=true` (:19), `icon-theme='Antumbra'` (:21),
`picture-uri=...antumbra-light.svg` (:26), `picture-uri-dark=...antumbra-dark.svg` (:27),
`picture-options='zoom'` (:28), `primary-color='#141218'` (:29); screensaver
`picture-uri=...antumbra-lock.svg` (:35), `picture-options='zoom'` (:36),
`primary-color='#0f0d13'` (:37).

Icon theme `Antumbra`: "Material Symbols status icons over Adwaita",
`Inherits=Adwaita,hicolor` (`config/rootfs/usr/share/icons/Antumbra/index.theme:1-12`).
Replaces battery, Wi-Fi signal, Bluetooth, Dark Mode and Night Light icons;
everything else, including Phosh's own cellular, Wi-Fi-off, torch and
rotation icons, is Adwaita's or Phosh's, "so the two styles mix in places"
(`docs/architecture.md:814-816`, `docs/known-issues.md:169-172`).

What the theme cannot do (do not add to the simulator): clock moved to a
side, hiding/reordering the nine built-in tiles, a two-stage shade, back or
quick-switch edge gestures, home-screen widgets, camera/torch shortcuts on
the lock screen, wallpaper-derived colours, adaptive icon masks, themed
monochrome icons, blur (`docs/known-issues.md:133-148`). Phosh itself stays
dark when the Dark Mode tile is off; only apps and the wallpaper turn light
(`docs/known-issues.md:162-165`).

## 3. Wallpapers

All 1440x3120 SVGs, gradients only, GPL-3.0-or-later, "gradients around an
annular eclipse" (`docs/architecture.md:810-814`). Copied to `sim/assets/`
(byte-identical to the repo and the image).

| File | Used as | Setting | Source |
|---|---|---|---|
| `antumbra-dark.svg` | home/session wallpaper (default, since color-scheme is prefer-dark) | `org.gnome.desktop.background picture-uri-dark`, zoom | `90_antumbra.gschema.override:27-28` |
| `antumbra-light.svg` | home wallpaper after the Dark Mode tile turns dark mode off; keeps dark top/bottom edges because the status bar and pill stay white | `picture-uri` | `90_antumbra.gschema.override:24-26`; comment `config/rootfs/usr/share/backgrounds/antumbra/antumbra-light.svg:4-12` |
| `antumbra-lock.svg` | lock screen; "darker and plainer ... no stars, and a smaller, dimmer eclipse" | `org.gnome.desktop.screensaver picture-uri`, zoom; Phosh shows it "whenever picture-options is not 'none'" | `90_antumbra.gschema.override:31-37`; comment `antumbra-lock.svg:4-9` |

`picture-options='zoom'` = CSS `background-size: cover`. The session
wallpaper as rendered is visible in `run-f4b/smoke/session.png` (eclipse
centred around y 550 of 1440, stars in the upper third, violet to plum
gradient downwards).

## 4. Top bar (folded top panel)

Structure: `phosh:/ui/top-panel.ui:206-332`, height 32 px
(`PHOSH_TOP_PANEL_HEIGHT`, `top-panel.ui:215-216`), padding 4 px top/bottom
(`phosh:/stylesheet/common.css:26-29`).

- Left (`box_network`, `top-panel.ui:217-264`), each shown only when its condition holds: cellular (`wwaninfo.present`), Wi-Fi (`wifiinfo.present`), Bluetooth (`btinfo.present`), VPN (`vpn_info.enabled`), connectivity (shown when `connectivity` is false), docked (`docked_info.enabled`). Margin-end 8 px each (`top-panel.ui:359-386`).
- Centre: clock `lbl_clock` (`top-panel.ui:265-274`).
- Right (`box_indicators`, `top-panel.ui:275-329`): language label `lbl_lang`, microphone kill switch (when blocked), camera kill switch (when blocked), feedback (only when muted), location (when active), battery `PhoshBatteryInfo` (always).
- Observed text: `Oct 6` + gap + `7:46 PM` centred; battery icon + `0%` at the right; nothing on the left (`shot:session.png`, `shot:tour-apps.png`, `run-f4b/smoke/session.png`).
- Clock format: gnome-desktop's wall clock with date, 12-hour: `%b %-e_%l:%M %p` (string in `image:/usr/lib/aarch64-linux-gnu/libgnome-desktop-3.so.20.0.0`), where the `_` is replaced by U+2003 EM SPACE (binary strings show `format_string` → ` ` → `_`, fallbacks ` ` and two spaces). `%l` pads the hour with a space, hence the wide gap. 12-hour is what the screenshots show; the schema default is `'24h'` localised by LC_TIME (`image:/usr/share/glib-2.0/schemas/org.gnome.desktop.interface.gschema.xml:210-212`), `clock-show-date` default true (`:225-227`). Locale `en_US.UTF-8`, time zone `Etc/UTC` (`config/hooks/12-base-locale.sh:8-10`).
- Battery: `show-battery-percentage=true` (`90_antumbra.gschema.override:19`); icons from the Antumbra theme `battery-level-{0..100}[-charging]-symbolic`, `battery-level-100-charged-symbolic`, `battery-missing-symbolic` (names asked by phosh-bin "battery-level-%d-symbolic", "battery-level-%d-charging-symbolic", "battery-level-100-charged-symbolic", "battery-missing-symbolic"). 0 % and 10 % draw red, 20 % amber.
- Background: solid `#141218` over the home screen and over apps (`run-f4b/smoke/session.png` y 0-63, `shot:tour-tor-browser.png`); transparent over the open app overview, with text shadow (`shot:tour-apps.png`; `phosh:/stylesheet/common.css:14-24` `.p-solid`).
- Phone vs VM: on the phone Wi-Fi exists (WCN3990, `docs/device-oneplus-7t-pro.md:10,42`) so a Wi-Fi signal icon appears on the left (Antumbra `network-wireless-signal-{none,weak,ok,good,excellent}-symbolic`, `network-wireless-acquiring-symbolic`); cellular stays hidden (ModemManager not installed, `config/rootfs/usr/share/dbus-1/system-services/org.freedesktop.ModemManager1.service:1-5`, `docs/architecture.md:568-570`); Bluetooth stays hidden (bluez not installed, `docs/architecture.md:604`). Whether the connectivity icon shows on the phone before Wi-Fi connects: not in the repo.
- Location indicator never shows: location is off and locked (`config/rootfs/etc/dconf/db/local.d/00-antumbra:19-20`, `locks/00-antumbra:1`).

## 5. Home bar, app overview ("dock" + app grid)

### 5.1 Home bar and gestures

- The home is a drag surface at the bottom: a 15 px home bar holding the pill (`phosh:/ui/home.ui:11-47`), above the overview (`home.ui:53-64`).
- Open the app overview: "a swipe up from the home bar opens the app overview" (`tests/vm/antumbra_vm.py:752-754`); the harness swipes from y 1425 to 500 (`:754`) and back down to close (`:755`). A tap on the home bar is also wired (`GtkGestureMultiPress` on the home bar → `on_home_released`, `home.ui:68-71`); that it toggles fold/unfold is Phosh code, unverified.
- Long press on the pill toggles the on-screen keyboard (`GtkGestureLongPress` "osk_toggle_long_press", `home.ui:72-78`; delay factor `osk-unfold-delay` default `1.0`, `image:/usr/share/glib-2.0/schemas/mobi.phosh.shell.gschema.xml:110-111`).
- While the overview is open the pill is not drawn (no pill pixels at the bottom of `shot:tour-apps.png`; Phosh's `rev_powerbar` crossfade 400 ms, `home.ui:28-32`).
- No back or quick-switch edge gestures; Phosh uses only the top and bottom edges (`docs/known-issues.md:139-141`).

### 5.2 Overview layout (observed `shot:session.png`, `shot:tour-apps.png`)

Top to bottom (`phosh:/ui/overview.ui`, `phosh:/ui/app-grid.ui`):

1. Running-app carousel (`HdyCarousel`, spacing 18, `overview.ui:88-96`). Each running app is a card with a window preview, its 48 px icon at the bottom and a round close button (`app-close-symbolic` 24 px) top-right; cards swipe away (`phosh:/ui/activity.ui:8-121`). No screenshot shows it.
2. Search entry, placeholder `Search apps…` (U+2026) (`app-grid.ui:22-34`); bar `#2b292f`, padding 10 20 10 16 (`shell.css:259-262`), margin 6 16 (`phosh:/stylesheet/common.css:350-352`); focus ring 1 px `#cebdfe` (`shell.css:264-267`). Measured x 32-688, y 106-214. Magnifier icon at the left (GtkSearchEntry; Adwaita `edit-find-symbolic` copied).
3. Favourites row (the "dock"), icons only, no labels (observed), flowbox margins 3/3/6/12, spacing 6 (`app-grid.ui:59-71`). Measured icon centres x 90/270/450/630, y 320, icons 128 device px = 64 px.
4. Separator, margin 6 px each side (`app-grid.ui:74-78`), 2 px, radius 1, Phosh's `alpha(fg, .1)` (`phosh:/stylesheet/common.css:377-382`). Measured y ≈ 423, colour `#201E23` over the scrim.
5. App grid: homogeneous flowbox, margin-top 12, spacing 6 (`app-grid.ui:88-101`); 64 px icons (`phosh:/ui/app-grid-button.ui:8-13`), 12 px label below with a fade-out (PhoshFadingLabel, `app-grid-base-button.ui:30-35`) — observed `Electrum Bitco`, `Metadata Clea`, `Mobile Setting` fading at the right edge, not ellipsised. Measured row pitch 214 device px (107 px), column pitch 180 (90 px); first grid row icons centred y 530, labels ≈ 623.
6. Button with an eye icon and `Show All Apps` (`phosh-bin "Show All Apps"`, `"Show Only Mobile Friendly Apps"`, next to app-grid code), measured x 194-526, y 1134-1206, fill `#36343a` (`shot:session.png` sample `#747077` is the label). Observed icon is Phosh's `eye-open-negative-filled-symbolic`; the other state uses `eye-not-looking-symbolic` (`app-grid.ui:123-126`; pairing of icon to label is Phosh code, unverified). With the image's desktop files, "Show All Apps" adds no app (every visible entry is adaptive or forced; derived from `image:/usr/share/applications`, not observed).
7. Scrim behind the open overview: `alpha(#0f0d13, 0.72)` (`shell.css:253-257`); measured `#0A090D` over black (`shot:session.png`, wallpaper not yet drawn at session start) and wallpaper-tinted in `shot:tour-apps.png`.

Search: typing filters; the first result gets a 2 px `#cebdfe` inset ring (`.search-active`, `shell.css:277-279`); Enter activates (`on_search_activated`, `app-grid.ui:28`).

Long press (touch) or right click on an app (`app-grid-button.ui:14-27`) opens a popover: the app's desktop actions, then `Remove from _Favorites` / `Add to _Favorites`, `View _Details`, `Uninstall`, each hidden when disabled (`app-grid-button.ui:28-51`); `Add to Folder` with existing folders and `Create new folder` (phosh-bin, next to app-grid-button code); `_Remove from Folder` inside a folder (`app-grid-button.ui:53-57`). Underscores are mnemonics, not shown. `View Details`/`Uninstall` run `gnome-software` (phosh-bin "Failed to run 'gnome-software %s' for '%s': %s"), which the image does not have; whether they are hidden as a result is not in the repo.

Tapping an app launches it and folds the overview (`home.ui:56-59` `activity-launched` → `fold_cb`); a splash with the app icon at 192 px (`phosh:/ui/splash.ui:11-18`) on `#fdf7ff` with `#1c1b20` (`shell.css:63-64`) shows while it starts.

At session start with no app running, `shot:session.png` (run-f1) shows the overview open; `run-f4b/smoke/session.png` shows the folded home (wallpaper + pill). Which one Phosh shows at start is not documented in the repo.

### 5.3 Dock (favourites), in order

`favorites=['tor-browser.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.Snapshot.desktop', 'org.postmarketos.Megapixels.desktop', 'org.gnome.Console.desktop']`
(`config/rootfs/etc/dconf/db/local.d/00-antumbra:25-28`); "phosh drops a
favourite that is not installed" (`:26-27`); Megapixels is not in the image
(`docs/camera.md:33`). Documented result: "Tor Browser, Files, Camera,
Console" (`docs/architecture.md:786-787`); observed the same four
(`shot:session.png`). Favourites are not repeated in the grid (observed).

| # | Desktop id | Name | Icon= | Asset |
|---|---|---|---|---|
| 1 | `tor-browser.desktop` | `Tor Browser` (`config/rootfs/usr/share/applications/tor-browser.desktop:2`) | `tor-browser` (`:5`) | `icons/tor-browser.png` |
| 2 | `org.gnome.Nautilus.desktop` | `Files` (`image:/usr/share/applications/org.gnome.Nautilus.desktop:87`) | `org.gnome.Nautilus` (`:231`) | `icons/org.gnome.Nautilus.svg` |
| 3 | `org.gnome.Snapshot.desktop` | `Camera` (`image:.../org.gnome.Snapshot.desktop:50`) | `org.gnome.Snapshot` (`:153`) | `icons/org.gnome.Snapshot.svg` |
| 4 | `org.gnome.Console.desktop` | `Console` (`image:.../org.gnome.Console.desktop:54`) | `org.gnome.Console` (`:57`) | `icons/org.gnome.Console.svg` |

### 5.4 App grid (phone mode), in displayed order

Observed alphabetical by name (`shot:session.png`, `shot:tour-apps.png`):

| # | Desktop id | Name (verbatim) | Icon= | Why it is in the phone grid | Desktop actions (long-press) | Asset |
|---|---|---|---|---|---|---|
| 1 | `antumbra-android.desktop` | `Android` (`config/rootfs-android/usr/share/applications/antumbra-android.desktop:3`) | `waydroid` (`:7`) | `X-Purism-FormFactor=Workstation;Mobile;` (`:10`) | none | `icons/antumbra-android-192.png` (resized, see 9) |
| 2 | `org.gnome.Calculator.desktop` | `Calculator` (`image:...:95`) | `org.gnome.Calculator` (`:253`) | FormFactor Mobile (`:258`) | none | `icons/org.gnome.Calculator.svg` |
| 3 | `org.gnome.clocks.desktop` | `Clocks` (`image:...:75`) | `org.gnome.clocks` (`:303`) | FormFactor Mobile (`:312`) | none | `icons/org.gnome.clocks.svg` |
| 4 | `electrum.desktop` | `Electrum Bitcoin Wallet` (`image:...:12`) | `electrum` (`:10`) | `force-adaptive` | `Testnet mode` (`:19,23`) | `icons/electrum.png` |
| 5 | `org.gnome.Loupe.desktop` | `Image Viewer` (`image:...:53`) | `org.gnome.Loupe` (`:55`) | `force-adaptive` | none | `icons/org.gnome.Loupe.svg` |
| 6 | `fr.romainvigier.MetadataCleaner.desktop` | `Metadata Cleaner` (`image:...:39`) | `fr.romainvigier.MetadataCleaner` (`:112`) | `force-adaptive` | none | `icons/fr.romainvigier.MetadataCleaner.svg` |
| 7 | `mobi.phosh.MobileSettings.desktop` | `Mobile Settings` (`image:...:24`) | `mobi.phosh.MobileSettings` (`:27`) | FormFactor Mobile (`:59`), `OnlyShowIn=Phosh;` (`:58`) met by `XDG_CURRENT_DESKTOP=Phosh:GNOME` (`config/rootfs/usr/libexec/antumbra-session:6`) | none | `icons/mobi.phosh.MobileSettings.svg` |
| 8 | `org.onionshare.OnionShare.desktop` | `OnionShare` (`image:...:2`) | `org.onionshare.OnionShare` (`:6`) | `force-adaptive` | none | `icons/org.onionshare.OnionShare.png` |
| 9 | `org.gnome.Papers.desktop` | `Papers` (`image:...:35`) | `org.gnome.Papers` (`:155`) | FormFactor Mobile (`:160`) | `New Window` (`:158,212`) | `icons/org.gnome.Papers.svg` |
| 10 | `org.gnome.World.Secrets.desktop` | `Secrets` (`image:...:41`) | `org.gnome.World.Secrets` (`:83`) | FormFactor Mobile (`:130`) | none | `icons/org.gnome.World.Secrets.svg` |
| 11 | `org.gnome.TextEditor.desktop` | `Text Editor` (`image:...:110`) | `org.gnome.TextEditor` (`:215`) | FormFactor Mobile (`:221`) | `New Window` (`:222,271`) | `icons/org.gnome.TextEditor.svg` |

Dock apps' actions: Files `New Window` (`org.gnome.Nautilus.desktop:239,307`);
Console `New Window`, `New Tab` (`org.gnome.Console.desktop:119,177,235`);
Tor Browser and Camera none.

`force-adaptive=['electrum.desktop', 'fr.romainvigier.MetadataCleaner.desktop', 'org.gnome.Loupe.desktop', 'org.onionshare.OnionShare.desktop']`
"These apps declare no X-Purism-FormFactor" (`config/rootfs/etc/dconf/db/local.d/10-antumbra-shell:7-9`).
Electrum and OnionShare (Qt) "are not designed for a 480-pixel-wide screen" (`docs/known-issues.md:176-177`).

Hidden entries (NoDisplay or not for Phosh), for completeness: Debian's
`Waydroid.desktop` is shadowed by `NoDisplay=true` in
`/usr/local/share/applications/Waydroid.desktop`, whose launcher "offers to
download Android images" (`config/rootfs-android/usr/local/share/applications/Waydroid.desktop:1-10`);
also `gcr-prompter`, `gcr-viewer`, `geoclue-demo-agent`, `mobi.phosh.Phoc`,
`mobi.phosh.Shell`, `nautilus-autorun-software`, `org.gnome.Papers-previewer`,
`python3.13`, `sm.puri.OSK0` (→ Squeekboard), `sm.puri.Squeekboard`,
`user-dirs-update-gtk`, `waydroid.app.install`, `waydroid.market`, the
three portals (all `NoDisplay=true` in `image:/usr/share/applications`).

Images built without `ANTUMBRA_ANDROID=1` have no Android entry at all
(`docs/architecture.md:854-857`).

### 5.5 The "Android" folder (only when Android apps are on)

- Exists only when the user turned on Android apps at the Welcome screen this boot: units carry `ConditionPathExists=/run/antumbra/android-enabled` (`config/rootfs-android/usr/lib/systemd/user/antumbra-android-folder.path:6`, `.service:5`). In run-f1 (Android off) the grid shows the plain `Android` app (`shot:session.png`).
- Folder name `Android`; contents: "Antumbra's "Android" launcher first, then every visible Waydroid entry" (`config/rootfs-android/usr/local/lib/antumbra-android-folder:3-11,18-21,44-55`). Verified list after F-Droid installed: `['antumbra-android.desktop', 'waydroid.org.fdroid.fdroid.desktop']`, `folder-children` `['Android']` (`run-f4b/smoke/report.json:392-394`, check "android: Android apps listed in the app grid's Android folder").
- Waydroid writes each Android app as `waydroid.<package>.desktop` with `Name` = the app's label, `Exec=waydroid app launch <package>`, `Icon=<waydroid data>/icons/<package>.png`, `X-Purism-FormFactor=Workstation;Mobile`, action `App Settings` (`image:/usr/lib/waydroid/tools/services/user_manager.py:94-131`); Android's own system apps get `NoDisplay` (`:24-36,124-125`). F-Droid's label `F-Droid` is seen in `run-f4b/smoke/android-fdroid.png` ("Allow **F-Droid** to send you notifications?").
- Folder button: a grid of the member apps' icons, spacing 8, height 64 (`phosh:/ui/app-grid-folder-button.ui:9-22`), button background `alpha(@phosh_bg_color,.4)`, radius 9 (Phosh) → 20 (Antumbra) (`phosh:/stylesheet/common.css:402-411`, `shell.css:270-275`). There is no folder icon file; how many mini icons Phosh draws is Phosh code, not in the repo. No screenshot shows the folder.
- Opening it slides to a folder page: back button (`go-previous-symbolic`), centred folder name (class `heading`), rename toggle (`document-edit-symbolic`), then the apps' grid; empty folder shows `folder-open-symbolic` and a label (`phosh:/ui/app-grid.ui:156-295`).
- Tapping `Android`: opens Android's full-screen UI (`waydroid show-full-ui`) when on; otherwise a notification (section 7) (`config/rootfs-android/usr/local/lib/antumbra-android-launch:3-18`). The Android UI itself (`run-f4b/smoke/android-full-ui.png`, Android 13 quick settings "Internet", "Bluetooth", "Flashlight", "Do Not Distu..", "No notifications", 3-button nav) is Android's, not Phosh's.

## 6. Quick settings drawer (unfolded top panel)

Open: "a pull down from the top bar opens the quick settings" (`tests/vm/antumbra_vm.py:752-753`; swipe y 4 → 1000, `:756`; close by swiping back up, `:757`). A tap on the top bar is also wired (`phosh:/ui/top-panel.ui:405-409` `released_cb`; behaviour unverified). At the bottom of the open drawer an up-chevron (`PhoshArrow`, margin-bottom 6, `top-panel.ui:339-352`) folds it; observed at y ≈ 1410 (`shot:tour-quick-settings.png`). The drawer is a single panel: sliders, tiles, media player, notifications (`docs/known-issues.md:137-138`).

Drawer background `#141218`, bottom corners 28 px (`shell.css:92-99`); content inset 6 px + 12 px = 18 px from each edge (`phosh:/stylesheet/common.css:74-93`; measured tiles start at x 36 device px).

Top to bottom (observed `shot:tour-quick-settings.png`):

1. Header (`box_clock`, padding 16, `top-panel.ui:130-191`, `common.css:61-63`):
   - left: round button with `padlock-symbolic`, action `panel.lockscreen` (locks the screen) (`top-panel.ui:136-148`); measured circle ≈ 40 px, `#36343a`.
   - centre: time `7:48 PM` (`lbl_clock2`) over date `Tuesday, October 6` (`lbl_date`) (`top-panel.ui:150-171`); date format `%A, %B %-e` (phosh-bin, next to `../src/wall-clock.c`).
   - right: round menu button `system-shutdown-symbolic` (`top-panel.ui:173-190`) opening the system menu (section 8.1).
   - Both buttons are hidden on the lock screen (`top-panel.ui:137,175`).
   - The black square at the top-left of the screenshot is the VM's pointer, not part of the UI (`docs/vm-testing.md:57-62`).
2. Brightness slider: `display-brightness-symbolic` + scale (`phosh:/ui/settings.ui:34-51`); measured centre y 206.
3. Volume slider: `audio-speakers-symbolic` (observed; `phosh:/ui/audio-settings.ui:15` `audio-speakers`), scale, `go-next-symbolic` arrow to output/input device lists (`Output Devices`, `Input Devices`, `Sound Settings`, `audio-settings.ui:84,108,136`); measured centre y 310.
   - Both sliders: 28 px trough `#36343a`, fill `#cebdfe`, knob `#35275d` ring `#cebdfe` (section 2.3). Observed both near full.
4. Tiles, two per row, 64 px tall, gap 6 (`phosh:/ui/quick-settings.ui:7-9`; measured rows at y 374/514/654/794, 128 device px tall, left tile x 36-354, right 366-684).
5. Torch slider (revealed only while the torch is on, `settings.ui:69-94`).
6. Media player card (when something plays) and notifications, hidden on the lock screen (`settings.ui:101-209`).
7. Empty state: `no-notifications-symbolic` 48 px, then `No notifications` (`settings.ui:117-149`); observed dim at y ≈ 1040 / 1138.
   With notifications: header `Notifications` (bold) and a `Clear all` pill button, then the cards (`settings.ui:155-204`).

### 6.1 Tiles, in order

Phosh's nine built-in tiles in fixed order (`phosh:/ui/quick-settings.ui:11-95`; "keep their order and cannot be hidden", `docs/known-issues.md:135-136`), then the two plugins `quick-settings=['dark-mode-quick-setting', 'night-light-quick-setting']` (`config/rootfs/etc/dconf/db/local.d/10-antumbra-shell:11-15`). Tiles 1-5 are always shown and insensitive when the device is absent; 6-9 are shown only when present.

| # | Tile | Shown / sensitive | Labels (verbatim) | Icons | Arrow / status page | Observed (VM) | Source |
|---|---|---|---|---|---|---|---|
| 1 | Cellular | always; sensitive if a modem is present | `Cellular` (or operator name, code) | `network-cellular-disabled-symbolic` (Adwaita), signal icons | no | `Cellular`, insensitive | `quick-settings.ui:11-18`; phosh-bin "Cellular" (`../src/wwan-info.c`) |
| 2 | Wi-Fi | always; sensitive if Wi-Fi present | `Wi-Fi` or the network name (code) | `network-wireless-disabled-symbolic` (Adwaita) / Antumbra signal icons | yes: Wi-Fi page `Wi-Fi`, `Wi-Fi Settings`; empty states `No Wi-Fi Device Found`, `Wi-Fi Disabled`, `Enable Wi-Fi`, `Wi-Fi Hotspot Active`, `Turn Off`, `No Wi-Fi Hotspots` | `Wi-Fi`, insensitive, with separator and `>` | `quick-settings.ui:21-29`; `phosh:/ui/wifi-status-page.ui:6,86`; phosh-bin (`../src/wifi-status-page.c`) |
| 3 | Bluetooth | always; sensitive if present | `Bluetooth`, `One device`, `%d devices` | Antumbra `bluetooth-disabled-symbolic` / `bluetooth-active-symbolic` | yes: page `Bluetooth`, `Enable Bluetooth`, `Bluetooth Settings`, `No connectable Bluetooth Devices found`, `Bluetooth disabled` | `Bluetooth`, insensitive, with `>` | `quick-settings.ui:32-40`; `phosh:/ui/bt-status-page.ui:6,39,54`; phosh-bin (`../src/bt-info.c`, `bt-status-page`) |
| 4 | Battery | always | the percentage, observed `0%` (the format string is not visible next to `../src/batteryinfo.c`) | Antumbra battery icons (names from phosh-bin next to `../src/batteryinfo.c`) | no | `0%`, red battery icon (VM has no battery, `docs/vm-testing.md:61-62`) | `quick-settings.ui:43-50` |
| 5 | Rotation | always | `Portrait` / `Landscape` (no accelerometer); `On`/`Off` with one | `screen-rotation-portrait-symbolic` / `-landscape-` (Phosh); `rotation-allowed-symbolic` / `rotation-locked-symbolic` | no | `Portrait`, inactive (`#36343a`) | `quick-settings.ui:53-59`; phosh-bin "Portrait", "Landscape", "Off" (`../src/rotateinfo.c`) |
| 6 | Feedback | when present | `On` / `Quiet` / `Silent` | `preferences-system-notifications-symbolic` (bell) / `feedback-quiet-symbolic` / `notifications-disabled-symbolic` | no | `On`, active (`#cebdfe`) | `quick-settings.ui:62-68`; phosh-bin "Quiet", "Silent" (`../src/feedbackinfo.c`); "On" is shorter than `strings`' minimum, seen in the screenshot |
| 7 | Torch | when a torch is present | `Torch` (and `%d%%`) | `torch-enabled-symbolic` / `torch-disabled-symbolic` (Phosh) | torch slider | hidden (no torch in the VM) | `quick-settings.ui:71-77`; phosh-bin (`../src/torch-info.c`) |
| 8 | Docked | when docking is possible | `Docked` / `Undocked` | `phone-docked-symbolic` / `phone-undocked-symbolic` | no | hidden | `quick-settings.ui:80-86`; phosh-bin |
| 9 | VPN | when a VPN exists | `VPN` | `network-vpn-*` | no | hidden | `quick-settings.ui:89-95`; phosh-bin |
| 10 | Dark Mode (plugin) | always | `Dark mode`, `Light mode`, `Default style` | Antumbra `dark-mode-symbolic` (filled) / `dark-mode-disabled-symbolic` (outline) | no | `Dark mode`, active | strings of `image:/usr/lib/aarch64-linux-gnu/phosh/plugins/libphosh-plugin-dark-mode-quick-setting.so` |
| 11 | Night Light (plugin) | always; sensitive if supported | `Night Light On` / `Night Light Off` | Antumbra `night-light-symbolic` / `night-light-disabled-symbolic` | no | `Night Light Off`, insensitive | strings of `.../libphosh-plugin-night-light-quick-setting.so` (`night-light-supported`, `sensitive`) |

Tile anatomy: label left-aligned, ellipsised in the middle, icon before it, spacing 6 (`phosh:/ui/quick-setting.ui:7-30`); split tiles get a separator (`alpha(currentColor, 0.24)`, margin 18 0, `shell.css:161-164`) and a `go-next-symbolic` 16 px arrow button (`quick-setting.ui:33-49`). Active = filled `#cebdfe` with `#35275d` content (`shell.css:111-114`); inactive `#36343a` with `#e6e1e9`; insensitive measured `#252329` with `#514f55`. Long press on a tile requests a settings panel (`long-press-action-name settings.launch-panel`, targets `wwan`, `wifi`, `bluetooth`, `power`, `notifications`, `display`, `network`, `quick-settings.ui:15-93`); the image has `phosh-mobile-settings` but no `gnome-control-center` (`image:/usr/bin`), so what a long press does here is not in the repo.

Behaviour notes:
- Dark Mode: tapping turns dark off; apps and the wallpaper go light (`antumbra-light.svg`), Phosh itself stays dark (`docs/known-issues.md:162-165`; `90_antumbra.gschema.override:24-25`). Whether the label then reads `Light mode` or `Default style` (which color-scheme value the plugin writes) is plugin code, not in the repo.
- Rotation: the image has no iio-sensor-proxy (`image:/usr/bin` has no `monitor-sensor`) and Antumbra disables the phone's sensors (`docs/device-oneplus-7t-pro.md:14,49`), so the phone shows `Portrait`/`Landscape` as the VM does; tapping toggles orientation (Phosh behaviour, unverified).
- Cellular and Bluetooth tiles are insensitive on the phone too (no ModemManager, no bluez; section 4). Wi-Fi is sensitive on the phone ("Wi-Fi connects through Phosh's settings", `docs/hardware-validation.md:61`).
- Torch on the phone, Night Light support on the phone: not in the repo.
- There is no airplane-mode tile in Phosh 0.46 (nine built-ins listed above); the Adwaita `airplane-mode-symbolic` asset is copied only because it was asked for.
- The `mobile-data-quick-setting` plugin is installed but not enabled (`image:/usr/lib/aarch64-linux-gnu/phosh/plugins/`, `10-antumbra-shell:15`).

### 6.2 Drawer on the lock screen

The drawer can be pulled down on the lock screen; the header's lock and power buttons and the bottom half (media player and notifications) are hidden there (`top-panel.ui:137,175`, `settings.ui:101-103` `on-lockscreen` bindings). Not observed in a screenshot.

## 7. Notifications

- Cards: header with 16 px app icon, app name (`heading`), timestamp (`caption`, dim); body with optional 32 px image, summary (ellipsised), body (dim, max 3 lines); action buttons in a row (`phosh:/ui/notification-frame.ui:23-73`, `phosh:/ui/notification-content.ui:12-76`). Card `#2b292f`, radius 24, actions `#494458` with `#e8def8` text and 24 px bottom corners (`shell.css:60-61,211-234`). New notifications also appear as a banner at the top (`phosh-notification-banner`, margin 6, shadow, `phosh:/stylesheet/common.css:775-789`).
- Never on the lock screen: `show-in-lock-screen=false`, locked (`config/rootfs/etc/dconf/db/local.d/10-antumbra-shell:18-20`, `locks/10-antumbra-shell:1`; `docs/known-issues.md:173-175`).
- The only notifications the image itself sends (`config/rootfs-android/usr/local/lib/antumbra-android-launch:7-17`), app name `Android`, icon `waydroid`, timeout 8000 ms:
  - summary `Android apps are off`, body `Turn on Android apps on the Welcome screen when you next start Antumbra.` (when Android apps are off)
  - summary `Android is starting`, body `Android opens when it is ready. The first start of a session takes a minute or two.` (Android on but not ready)
- No Tor-ready or other session notification exists in `config/` (searched for `Notify`, `notify-send`).

## 8. Power, lock and session end

### 8.1 System menu (drawer's power button)

Popover, buttons in this order, 16 px icons (`phosh:/ui/top-panel.ui:4-123`; mnemonic underscores not shown):

| Label | Icon | Action |
|---|---|---|
| `_Power Off…` | `system-shutdown-symbolic` | `panel.poweroff` |
| `_Restart…` | `system-reboot-symbolic` | `panel.restart` |
| `_Suspend…` | `moon-filled-symbolic` | `panel.suspend` |
| `_Log Out…` | `system-log-out-symbolic` | `panel.logout` |

Buttons: padding 8 16, radius 99, bold, 90 % size (`phosh:/stylesheet/common.css:237-242`). `enable-suspend` defaults to `false` ("Whether to enable suspend from the power menu", `image:/usr/share/glib-2.0/schemas/mobi.phosh.shell.gschema.xml:82-89`) and Antumbra does not change it; whether `Suspend…` is then hidden or insensitive is Phosh code, unverified. The architecture allows suspend (`docs/architecture.md:266`).

### 8.2 End-session dialog (after Power Off… / Restart… / Log Out…)

System-modal dialog over `alpha(bg, 0.8)` (`phosh:/stylesheet/common.css:588-590`), card `#2b292f` radius 28 (`shell.css:326-330`): title = action, subtitle with countdown, optional warning `Some applications are busy or have unsaved work` with the inhibiting apps, buttons `Cancel` and `Ok` (suggested, `#cebdfe` on `#35275d`) (`phosh:/ui/end-session-dialog.ui:12-73`; `shell.css:345-348`). Strings (phosh-bin, next to `../src/end-session-dialog.c`):

- `Power Off` — `The system will power off automatically in %d seconds.` / `...in %d second.`
- `Restart` — `The system will restart automatically in %d seconds.` / `...in %d second.`
- `Log Out` — `%s will be logged out automatically in %d seconds.` / `...in %d second.` (`%s` = the user; the session user is `amnesia`, `docs/architecture.md:753-757`)

The countdown length comes from gnome-session and whether the confirm button is relabelled from `Ok` is Phosh code: neither is in the repo. Logging out returns to the Welcome screen; "settings cannot change in the same boot, only a new session can start" (`docs/architecture.md:757-759`). Power-off returns to the initramfs to wipe memory (`docs/architecture.md:264`).

### 8.3 Power menu (Phosh's)

"Phosh's power menu" is one of the emergency shutdown paths (`docs/architecture.md:265`). Layout (`phosh:/ui/power-menu.ui:4-245`): close button (`app-close-symbolic` 24 px) at the top right; a 2x2 grid, spacing 18, flat buttons with 32 px icons over labels:

| Cell | Label | Icon | Action |
|---|---|---|---|
| (0,0) | `Power Off` (or `Suspend`, stacked in the same cell) | `system-shutdown-symbolic` / `moon-filled-symbolic` | `power-menu.poweroff` / `power-menu.suspend` |
| (1,0) | `Lock` | `system-lock-screen-symbolic` | `power-menu.screen-lock` |
| (0,1) | `Screenshot` | `screenshot-portrait-symbolic` | `power-menu.screenshot` |
| (1,1) | `Emergency` | `asterisk-symbolic`, red (`#e01b24`) | `power-menu.emergency-call` |

Buttons radius 28 (`shell.css:358-360`). `sm.puri.phosh.emergency-calls enabled` defaults to `false`, "the shell will not offer emergency call functionality" (`mobi.phosh.shell.gschema.xml:121-129`); Antumbra does not change it. Which of Power Off/Suspend shows, and whether Emergency is hidden, is Phosh code (unverified; with suspend disabled `Power Off` is the expected one). How the menu is opened (power-key long press in Phosh) is not documented in the repo; no screenshot.

### 8.4 Power key and timers

- `HandlePowerKey=ignore` ("Short press: the shell handles the screen"), `HandlePowerKeyLongPress=poweroff` ("long press (5 s): orderly power-off") (`config/rootfs/usr/lib/systemd/logind.conf.d/antumbra.conf:2-5`); the VM test checks that a short press does not shut down (`tests/vm/antumbra_vm.py:2583-2590`).
- Screen blanks after `idle-delay=uint32 120` s, locks with `lock-enabled=true`, `lock-delay=uint32 0` (immediately) (`config/rootfs/etc/dconf/db/local.d/00-antumbra:12-17`).
- Locking arms `antumbra-auto-shutdown.timer`, `OnActiveSec=18h`, `WakeSystem=yes`; unlocking disarms it (`config/rootfs/usr/lib/systemd/system/antumbra-auto-shutdown.timer:1-12`, `config/rootfs/usr/local/lib/antumbra-lock-watch:3-5,16-26`). Timer description: `Power off after being locked for too long` (`antumbra-auto-shutdown.timer:2`).

## 9. Lock screen

No screenshot of the lock screen exists; everything below is from files.

- Background: `antumbra-lock.svg`, zoom; fallback colour `#0f0d13` (`90_antumbra.gschema.override:31-37`).
- Vertical carousel, 400 ms (`phosh:/ui/lockscreen.ui:7-12`):
  - Page 1, info (`lockscreen.ui:69-220`): centred clock (`#phosh-lockscreen-clock`, 80 px weight 400) and date (`#phosh-lockscreen-date`, 16 px weight 500; `shell.css:286-302`), date format `%A, %B %-e` (phosh-bin, wall-clock.c); below, call notifications, media player and notifications areas (notifications never shown here, section 7). At the bottom a 32 px `swipe-arrow-symbolic` (an up chevron) pulsing up 14 px, 1.8 s, 15 times (`phosh:/stylesheet/common.css:482-486,514-518`), and the dim label `Slide up to unlock` (`lockscreen.ui:78-97`).
  - Page 2, unlock (`lockscreen.ui:267-340`, margin-top 100): `Enter Passcode` (16 pt); a password entry (dots, centred, `.phosh-lockscreen-pin`, radius 16); a keypad 1 2 3 / 4 5 6 / 7 8 9 / [keyboard] 0 [delete] (`phosh:/ui/keypad.ui` labels; start action `btn_keyboard` with `input-keyboard-symbolic`, end action `btn_delete` with `edit-clear-symbolic`, long press on delete clears, `lockscreen.ui:346-372`); an `Unlock` button, insensitive until something is typed (`lockscreen.ui:327-336`). Keypad keys `alpha(#36343a, 0.6)`, round (`shell.css:304-315`, `phosh:/stylesheet/common.css:527-533`).
  - While checking: `Checking…` (U+2026); a wrong passphrase shakes the entry and returns to `Enter Passcode` (phosh-bin "Checking…", "[PhoshLockscreen] shake PIN entry", "Enter Passcode", next to `../src/lockscreen.c`). Exact timing is Phosh code.
  - A deck page to the side holds lock-screen plugins (`lockscreen.ui:14-65`); the plugin list is empty and locked (`10-antumbra-shell:16`, `locks/10-antumbra-shell:3`; `docs/known-issues.md:173-175`). Whether Phosh still offers the empty page is not in the repo.
- Authentication: PAM with the screen-lock passphrase set on the Welcome screen; "without one the lock is not protective, and the Welcome screen says so" (`docs/architecture.md:761-764`); the passphrase is text ("needs at least 6 characters", `config/rootfs/usr/bin/antumbra-welcome:205-207`), so the keyboard key (squeekboard) matters. `require-unlock` is locked at its default `true` ("Setting this to false allows unlocking without entering the PIN or password by simply swiping up", `mobi.phosh.shell.gschema.xml:142-150`; `locks/10-antumbra-shell:2`). `shuffle-keypad` default `false` (`:133-140`).
- No camera or torch shortcuts (`docs/known-issues.md:142-143`). The top bar's lock/power buttons are hidden on the lock screen (section 6.2); whether the top-bar clock shows above the big clock is not in the repo.

## 10. OSD, splash, keyboard

- Volume/brightness OSD: bubble radius 28, `#2b292f`, 16 px icon, label 9 pt, level bar blocks `#cebdfe` on `#36343a` (`shell.css:362-375`; `phosh:/ui/osd-window.ui`; `phosh:/stylesheet/common.css:961-987`). Not observed.
- App-launch splash: app icon 192 px on `#fdf7ff` (section 5.2). Not observed.
- On-screen keyboard (squeekboard) is on (`screen-keyboard-enabled=true`, `00-antumbra:1-2`); observed under Tor Browser (`shot:tour-tor-browser.png`): rows `q w e r t y u i o p`, `a s d f g h j k l`, `⇧ z x c v b n m ⌫`, `123 🌐 [space] . ↵`; background `#211f24`, keys `#36343a` radius 8, modifiers `#494458`/`#e8def8`, Return `#cebdfe`/`#35275d`, latched Shift `#4c3e76`, locked (caps) `#cebdfe` (`shell.css:378-464`). The home bar with the pill stays below the keyboard (observed).

## 11. VM artefacts to leave out

From `docs/vm-testing.md:57-62`: "a black square in the top-left corner (the pointer, under software rendering), in one screenshot black patches over the top bar's clock, and the battery indicator at 0% (the VM has no battery)". Also in `shot:tour-apps.png` a mouse cursor and a dark disc in the middle (the pointer's rendering); and `shot:session.png` (run-f1) shows the session before the wallpaper was drawn (black behind the scrim).

## 12. Assets (`sim/assets/`, listed in `sim/assets/manifest.json`)

Naming: `icons/<desktop id without .desktop>.<ext>`, `symbolic/<freedesktop icon name>.svg`. The manifest gives for each: path, what it is, source path in the image, owning package (from `var/lib/dpkg/info/*.list`), licence (from that package's `usr/share/doc/<pkg>/copyright` Files stanza, or the file's SPDX header), bytes, sha256. 118 assets, about 700 KB in total.

- Wallpapers: `antumbra-dark.svg`, `antumbra-light.svg`, `antumbra-lock.svg` (GPL-3.0-or-later).
- App icons (16): the 15 visible apps plus `waydroid.org.fdroid.fdroid.png` and Phosh's fallback `app-icon-unknown.svg`. SVG where hicolor has one; `tor-browser.png` (128x128, no SVG; from the Tor Browser bundle, installed by `config/hooks/54-session-tor-browser.sh:25-28`, licence not stated next to it); `electrum.png` (128x128, no SVG).
- Symbolic (98): the 37 Antumbra theme icons (Material Symbols, Apache-2.0); 42 Adwaita 48 icons (CC-BY-SA-3.0 or LGPL-3, and CC-BY-SA-4.0) incl. shutdown, reboot, log-out, lock-screen, brightness, speakers, bell, cellular/Wi-Fi off, chevrons, keypad keys, search, camera, airplane (unused); 19 Phosh built-in icons extracted from the binary (GPL-3+): padlock, swipe-arrow, no-notifications, rotation portrait/landscape, torch on/off, feedback-quiet, moon-filled, screenshot, asterisk, app-close, the two eye icons, docked/undocked, mobile-data; plus `pill-symbolic.svg` (Antumbra) and Phosh's original `input-powerbar-symbolic.svg` for reference. Two Adwaita icons that Antumbra shadows are kept as `adwaita-*.svg` for comparison only.
- Symbolic SVGs are monochrome templates: fill them with the widget's foreground colour (`#e6e1e9`, or `#35275d` on an active tile); keep `class="error"`/`"warning"` paths red/amber.
- Icon resolution order in the session: Antumbra → Adwaita → hicolor, and Phosh's built-in icons count as hicolor, so where Adwaita has the same name (cellular-disabled, Wi-Fi-disabled, VPN-disabled, SIM, camera/microphone kill switch) Adwaita's is the one shown (`index.theme` `Inherits=Adwaita,hicolor`; GTK 3 resource-path rule). The copied set follows that.

Skipped or derived (also in `manifest.json` → `skipped_over_60KB` and `derived`):
- `org.onionshare.OnionShare.svg` (160685 bytes) skipped; the 512x512 PNG (24613 bytes) is used instead.
- Waydroid's `waydroid.png` 512x512 (174212 bytes), the `Android` launcher's icon, skipped; `icons/antumbra-android-192.png` is a 192x192 resize of it (ImageMagick, 26083 bytes) = Phosh's 64 px icon at scale 3. Flagged as derived.
- Tor Browser's `about-logo.svg` (62923 bytes) not used (not what `Icon=tor-browser` resolves to).
- F-Droid: the icon Phosh shows is written by Waydroid at runtime (`~/.local/share/waydroid/data/icons/org.fdroid.fdroid.png`) and is not in the image. `icons/waydroid.org.fdroid.fdroid.png` is the APK's own 192x192 launcher PNG (`image:/usr/share/antumbra/android/F-Droid.apk`, entry `res/o-.png`, identified by eye because resource names are obfuscated); licence not stated in the image.
- No "Android folder icon" exists as a file; Phosh composes it from the member icons.

## 13. Where the repo is silent (do not invent)

- Phosh's exact timings and animation curves for the drag surfaces, and the threshold distances of the swipes.
- Whether the overview is open or folded when the session starts (screenshots show both).
- Lock-screen appearance (no screenshot), whether the top-bar clock shows on it, the empty plugin page.
- Folder button rendering and the folder page (no screenshot).
- Running-app cards in the overview (no screenshot).
- Which color-scheme value the Dark Mode plugin writes (label `Light mode` vs `Default style` when off).
- Torch, Night Light support, and the connectivity indicator on the phone.
- The visibility of `Suspend…`, `Emergency`, `View Details`, `Uninstall` given the settings above.
- The end-session countdown length and the confirm-button label.
- How Phosh's power menu is opened.
- What a long press on a quick-setting tile does without gnome-control-center.
