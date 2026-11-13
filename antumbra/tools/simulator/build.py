#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Assemble antumbra-simulator.html from src/ and assets/.

usage: build.py [OUT.html]   (default: antumbra-simulator.html next to this script)

- symbolic icons -> one inline <svg> sprite of <symbol id="i-NAME">, recoloured to
  currentColor (paths with class="error"/"warning" keep GTK's error/warning colours)
- app icons -> data: URIs in a JS object (one copy each)
- wallpapers -> data: URIs in CSS custom properties
- fonts -> the image's own Roboto and Noto Sans Mono, subset to WOFF2 by assets/make_fonts.py,
  embedded as @font-face data: URIs, so the page makes no request at all
"""
import base64, json, re, sys
import xml.etree.ElementTree as ET
from pathlib import Path

HERE = Path(__file__).resolve().parent
A = HERE / "assets"
SRC = HERE / "src"
OUT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else HERE / "antumbra-simulator.html"

SVGNS = "http://www.w3.org/2000/svg"
ET.register_namespace("", SVGNS)

SYMBOLIC = [
    # Antumbra (Material Symbols)
    *[f"battery-level-{n}-symbolic" for n in range(0, 101, 10)],
    "battery-level-100-charged-symbolic",
    "network-wireless-signal-none-symbolic", "network-wireless-signal-weak-symbolic",
    "network-wireless-signal-ok-symbolic", "network-wireless-signal-good-symbolic",
    "network-wireless-signal-excellent-symbolic", "network-wireless-acquiring-symbolic",
    "bluetooth-disabled-symbolic", "dark-mode-symbolic", "dark-mode-disabled-symbolic",
    "night-light-symbolic", "night-light-disabled-symbolic",
    # Adwaita
    "network-wireless-disabled-symbolic", "network-cellular-disabled-symbolic",
    "display-brightness-symbolic", "audio-speakers-symbolic", "go-next-symbolic",
    "go-previous-symbolic", "go-down-symbolic", "system-shutdown-symbolic", "system-reboot-symbolic",
    "system-log-out-symbolic", "system-lock-screen-symbolic", "preferences-system-notifications-symbolic",
    "notifications-disabled-symbolic", "edit-clear-symbolic", "input-keyboard-symbolic",
    "edit-find-symbolic", "camera-photo-symbolic", "camera-hardware-disabled-symbolic",
    "folder-open-symbolic", "document-edit-symbolic", "view-refresh-symbolic",
    "camera-disabled-symbolic", "open-menu-symbolic", "network-wireless-encrypted-symbolic",
    # Phosh built-ins
    "padlock-symbolic", "swipe-arrow-symbolic", "no-notifications-symbolic",
    "screen-rotation-portrait-symbolic", "screen-rotation-landscape-symbolic",
    "feedback-quiet-symbolic", "moon-filled-symbolic", "app-close-symbolic",
    "eye-open-negative-filled-symbolic", "eye-not-looking-symbolic",
]

# Icons the spec gives as verbatim path data (libadwaita widgets on the Welcome screen)
EXTRA = {
    "view-reveal-symbolic": "m 8 2 c -3.648438 0.003906 -6.832031 2.476562 -7.738281 6.007812 c 0.914062 3.527344 4.097656 5.988282 7.738281 5.992188 c 3.648438 -0.003906 6.832031 -2.476562 7.738281 -6.011719 c -0.914062 -3.523437 -4.097656 -5.984375 -7.738281 -5.988281 z m 0 2 c 2.210938 0 4 1.789062 4 4 s -1.789062 4 -4 4 s -4 -1.789062 -4 -4 s 1.789062 -4 4 -4 z m 0 2 c -1.105469 0 -2 0.894531 -2 2 s 0.894531 2 2 2 s 2 -0.894531 2 -2 s -0.894531 -2 -2 -2 z m 0 0",
    "view-conceal-symbolic": "m 1.53125 0.46875 l -1.0625 1.0625 l 14 14 l 1.0625 -1.0625 l -2.382812 -2.382812 c 1.265624 -1.0625 2.171874 -2.496094 2.589843 -4.097657 c -0.914062 -3.523437 -4.097656 -5.984375 -7.738281 -5.988281 c -1.367188 0.011719 -2.707031 0.371094 -3.894531 1.042969 z m 6.46875 3.53125 c 2.210938 0 4 1.789062 4 4 c -0.003906 0.800781 -0.246094 1.578125 -0.699219 2.238281 l -1.46875 -1.46875 c 0.105469 -0.242187 0.164063 -0.503906 0.167969 -0.769531 c 0 -1.105469 -0.894531 -2 -2 -2 c -0.265625 0.003906 -0.527344 0.0625 -0.769531 0.167969 l -1.46875 -1.46875 c 0.660156 -0.453125 1.4375 -0.695313 2.238281 -0.699219 z m -6.144531 0.917969 c -0.753907 0.898437 -1.296875 1.957031 -1.59375 3.09375 c 0.914062 3.523437 4.097656 5.984375 7.738281 5.988281 c 0.855469 -0.007812 1.703125 -0.152344 2.511719 -0.425781 l -1.667969 -1.667969 c -0.277344 0.058594 -0.5625 0.089844 -0.84375 0.09375 c -2.210938 0 -4 -1.789062 -4 -4 c 0.003906 -0.28125 0.035156 -0.566406 0.09375 -0.84375 z m 0 0",
    "pan-down-symbolic": "m 3.292969 7.707031 l 4 4 c 0.390625 0.390625 1.023437 0.390625 1.414062 0 l 4 -4 c 0.390625 -0.390625 0.390625 -1.023437 0 -1.414062 s -1.023437 -0.390625 -1.414062 0 l -3.292969 3.292969 l -3.292969 -3.292969 c -0.390625 -0.390625 -1.023437 -0.390625 -1.414062 0 s -0.390625 1.023437 0 1.414062 z m 0 0",
    "object-select-symbolic": "m 13.753906 4.660156 c 0.175782 -0.199218 0.261719 -0.460937 0.246094 -0.726562 c -0.019531 -0.265625 -0.140625 -0.511719 -0.339844 -0.6875 c -0.199218 -0.175782 -0.460937 -0.261719 -0.726562 -0.246094 c -0.265625 0.019531 -0.511719 0.140625 -0.6875 0.339844 l -6.296875 7.195312 l -2.242188 -2.242187 c -0.390625 -0.390625 -1.023437 -0.390625 -1.414062 0 c -0.1875 0.1875 -0.292969 0.441406 -0.292969 0.707031 s 0.105469 0.519531 0.292969 0.707031 l 3 3 c 0.195312 0.195313 0.464843 0.304688 0.738281 0.292969 c 0.277344 -0.007812 0.539062 -0.132812 0.722656 -0.339844 z m 0 0",
}

KEEP_STYLE = {"opacity", "fill-opacity", "fill-rule", "clip-rule", "display", "stroke-width",
              "stroke-linecap", "stroke-linejoin", "stroke-opacity"}
DROP_TAGS = {"metadata", "title", "desc", "namedview", "filter"}
ERROR = "#cc0000"     # GTK error colour on symbolic class="error" (measured in the VM)
WARNING = "#f5c211"   # amber; GTK warning colour (not observed in a screenshot)


def local(tag):
    return tag.split("}", 1)[-1]


def clean(el, inherited_cls=None):
    """Return a cleaned copy of el, or None to drop it."""
    t = local(el.tag)
    if t in DROP_TAGS:
        return None
    if t == "defs":
        # keep only clip paths / masks that some Adwaita icons use
        kids = [c for c in el if local(c.tag) in ("clipPath", "mask")]
        if not kids:
            return None
    new = ET.Element(f"{{{SVGNS}}}{t}")
    cls = el.get("class") or inherited_cls
    for k, v in el.attrib.items():
        lk = local(k)
        if k.startswith("{") and "svg" not in k:
            continue            # inkscape:/sodipodi: attributes
        if lk in ("id", "class", "filter") or lk.startswith("data-"):
            if lk == "id" and t in ("clipPath", "mask"):
                new.set("id", v)
            continue
        if lk == "fill":
            if v in ("none",):
                new.set("fill", "none")
            continue
        if lk == "stroke":
            if v != "none":
                new.set("stroke", "currentColor")
            continue
        if lk == "style":
            props = []
            for decl in v.split(";"):
                if ":" not in decl:
                    continue
                p, val = [x.strip() for x in decl.split(":", 1)]
                if p == "fill" and val == "none":
                    props.append("fill:none")
                elif p == "stroke" and val != "none":
                    props.append("stroke:currentColor")
                elif p in KEEP_STYLE:
                    props.append(f"{p}:{val}")
            if props:
                new.set("style", ";".join(props))
            continue
        new.set(lk, v)
    if cls in ("error", "warning") and t in ("path", "rect", "circle", "g"):
        new.set("fill", ERROR if cls == "error" else WARNING)
    for c in el:
        cc = clean(c, cls)
        if cc is not None:
            new.append(cc)
    if t == "g" and len(new) == 0:
        return None
    return new


def symbol_from_file(name, path):
    root = ET.parse(path).getroot()
    vb = root.get("viewBox")
    if not vb:
        w = re.sub(r"px$", "", root.get("width", "16"))
        h = re.sub(r"px$", "", root.get("height", "16"))
        vb = f"0 0 {w} {h}"
    sym = ET.Element(f"{{{SVGNS}}}symbol", {"id": "i-" + name, "viewBox": vb})
    for c in root:
        cc = clean(c)
        if cc is not None:
            sym.append(cc)
    s = ET.tostring(sym, encoding="unicode")
    s = s.replace(' xmlns="http://www.w3.org/2000/svg"', "")
    s = re.sub(r"\s+", " ", s)
    return s


def sprite():
    out = []
    for n in SYMBOLIC:
        out.append(symbol_from_file(n, A / "symbolic" / f"{n}.svg"))
    for n, d in EXTRA.items():
        out.append(f'<symbol id="i-{n}" viewBox="0 0 16 16"><path d="{d}"/></symbol>')
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="0" height="0" style="position:absolute" '
            'aria-hidden="true" focusable="false"><defs>' + "".join(out) + "</defs></svg>")


def data_uri(path):
    mime = "image/svg+xml" if path.suffix == ".svg" else "image/png"
    return f"data:{mime};base64," + base64.b64encode(path.read_bytes()).decode()


def app_icons():
    icons = {}
    for p in sorted((A / "icons").iterdir()):
        icons[p.stem] = data_uri(p)
    return icons


def font_faces():
    faces = json.loads((A / "fonts" / "fonts.json").read_text())
    out = []
    for f in faces:
        uri = "data:font/woff2;base64," + base64.b64encode((A / f["file"]).read_bytes()).decode()
        out.append(f'@font-face{{font-family:"{f["family"]}";font-style:normal;font-weight:{f["weight"]};'
                   f'font-display:swap;src:url("{uri}") format("woff2")}}')
    return "\n".join(out)


def main():
    css = (SRC / "style.css").read_text()
    body = (SRC / "body.html").read_text()
    js = (SRC / "app.js").read_text()
    walls = {k: data_uri(A / f"antumbra-{k}.svg") for k in ("dark", "light", "lock")}
    css = css.replace("/*@WALLPAPERS@*/",
                      "".join(f'--wp-{k}:url("{v}");' for k, v in walls.items()))
    js = js.replace("/*@ICONS@*/{}", json.dumps(app_icons(), separators=(",", ":")))
    html = (
        "<title>Antumbra Simulator</title>\n"
        '<meta name="description" content="An interactive simulator of the Antumbra privacy OS for the OnePlus 7T Pro: Welcome screen, Phosh session, Tor, camera, Android apps and Persistent Storage.">\n'
        "<style>\n" + font_faces() + "\n" + css + "\n</style>\n"
        + sprite() + "\n"
        + body + "\n"
        "<script>\n" + js + "\n</script>\n"
    )
    OUT.write_text(html)
    print(f"{OUT} {OUT.stat().st_size} bytes")


if __name__ == "__main__":
    main()
