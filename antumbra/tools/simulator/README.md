# Antumbra Simulator

A hand-built HTML mock of Antumbra's interface: the Welcome screen, Start,
the Phosh session (top bar, app grid, quick settings, notifications, lock
screen, power menu), Tor's progress, the camera prompt, Android apps,
Persistent Storage and power-off. It exists for quick design choices ("A
or B?" in half a minute on any phone or desktop browser), **not** to test
the system: nothing in it runs Antumbra's code.

It is published as the private "Antumbra Simulator" page. After a change,
build it and republish the result to the same address, so links to it keep
working.

## Where it differs from the real OS

The page models the system from the sources and acts out the rest. The
screens, labels, defaults, messages and rules come from this repository,
the built root filesystem and screenshots of the image in QEMU, each fact
cited in the three specs below; it does not invent Android behaviour that
Phosh lacks. It looks better than the real system in these ways:

- **Keyboard:** the browser's own keyboard (on a phone, the phone's),
  not squeekboard.
- **Width:** it lays out at the browser's width, about 390 logical pixels
  on a typical phone browser, where the QEMU test display is 360 and the
  phone 480. Layout and size are judged at the phone's real size, never
  here.
- **Apps:** GNOME apps are title-only placeholders; Tor Browser is an HTML
  mock that fits the screen, not the desktop browser in a narrow window.
- **Time:** waits are shortened and the browser composites the animations
  on its GPU; nothing says how fast the phone will be.
- **Acted out:** Tor's progress (the real image has not got past 14 % in a
  VM), Wi-Fi, battery, brightness, the camera and Android. Persistent
  Storage lives in the browser's storage and is not encrypted; the page
  says so before the first Create.
- **Network:** none. The page makes no request at all; even its fonts (the
  image's Roboto and Noto Sans Mono, subset) are embedded.

The page's own About panel says the same to its visitors. The plan's T7
adds a Real, Modelled or Acted-out badge to every screen and a phone-size
mode, and T7b compares its screens with the daily VM screenshots
(`docs/plan/queue.md`).

## Layout

| Path | What it is |
|---|---|
| `build.py` | assembles the single page from `src/` and `assets/` (Python's standard library only) |
| `src/body.html`, `src/style.css`, `src/app.js` | the page: markup, styles, and the behaviour (one `ANTUMBRA_SIM` namespace; `app.js`'s header lists its modules, among them a port of `antumbra/settings.py`) |
| `assets/` | wallpapers, app icons, the symbolic icons the session uses, the subset fonts; `manifest.json` and `fonts/fonts.json` record where each file comes from in the image, its package and its licence |
| `assets/make_fonts.py` | regenerates the subset WOFF2 fonts from a built root filesystem (needs fontTools and brotli) |
| `spec-welcome.md`, `spec-session.md`, `spec-behaviour.md` | what the page must show and do, written from the repository, the image and the VM runs of early October 2026, with a source for every fact; line numbers refer to the tree of that time |
| `test/` | Playwright checks (below) |

## Build

```sh
python3 tools/simulator/build.py                 # writes tools/simulator/antumbra-simulator.html
python3 tools/simulator/build.py /tmp/sim.html   # or anywhere else
```

The page is about 700 KB and not committed (`.gitignore`). The symbolic
icons become one inline SVG sprite recoloured to `currentColor`, the app
icons and wallpapers data URIs, the fonts `@font-face` data URIs.

## Test

```sh
sh tools/simulator/test/run-all.sh
```

It rebuilds the page, checks that its script parses, runs `flow.js` (a
full click-through) at a 390x844 touch phone viewport and on a 1280x900
desktop in parallel, then `fixes.js` (regression checks for the review
findings, each in a fresh page: small and landscape screens, safe areas,
storage that throws, the intro texts and more), and fails on any failed
check, console error, page error, dialog, popup, download or network
request. `smoke.js` is a quick look at the intro and the Welcome screen.

The tests serve the page from a fake HTTPS origin, wrapped as it is when
published. They need Node.js with Playwright and Chromium: by default the
cloud container's (`/opt/node22`, `/opt/pw-browsers`); `NODE`, `NODE_PATH`
and `CHROMIUM` name others. Screenshots go to `shots/` (`SIM_SHOTS` names
another directory), results to `test/results-*.json` and logs to
`test/log-*.txt`, all ignored by git. A full run takes several minutes and
writes about 35 MB of screenshots.

The specs cite file and line numbers as of early October 2026. Since then
the compositor settings for the phone and the VM moved from
`config/rootfs/etc/antumbra/phoc.ini` to `config/rootfs/etc/phosh/phoc.ini`
(read by both the Welcome screen and the session).
