# SPDX-License-Identifier: GPL-3.0-or-later
"""Static checks of the interface theme (runs on the build host).

The GTK 3 stylesheet is read by every GTK 3 program of the user, Tor
Browser included, so each of its selectors must name a phosh or squeekboard
node; the GTK 3 and GTK 4 copies of the palette must agree; the VM test
must look for the accent the Welcome screen actually uses.
"""
import ast
import os
import re
import unittest
import xml.etree.ElementTree as ET

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
OVERLAY = os.path.join(ROOT, "config", "rootfs")
THEME = os.path.join(OVERLAY, "usr", "share", "antumbra", "theme")
BACKGROUNDS = os.path.join(OVERLAY, "usr", "share", "backgrounds", "antumbra")
OVERRIDE = os.path.join(OVERLAY, "usr", "share", "glib-2.0", "schemas", "90_antumbra.gschema.override")
SVG_NS = "{http://www.w3.org/2000/svg}"


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def strip_comments(css):
    return re.sub(r"/\*.*?\*/", "", css, flags=re.S)


def rules(css):
    """(selector list, body) of every top-level rule; @-statements skipped."""
    css = strip_comments(css)
    out, i, depth, start = [], 0, 0, 0
    while i < len(css):
        c = css[i]
        if c == "{":
            if depth == 0:
                head, start = css[start:i].strip(), i + 1
                # drop @define-color / @import statements that precede the rule
                head = head.rsplit(";", 1)[-1].strip()
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                out.append((head, css[start:i]))
                start = i + 1
        i += 1
    return out


def overlay_path(uri):
    assert uri.startswith("file:///"), uri
    return os.path.join(OVERLAY, uri[len("file:///"):])


class StylesheetTest(unittest.TestCase):
    FILES = ("shell.css", "apps.css", "welcome.css")

    def test_braces_balanced(self):
        for name in self.FILES:
            css = strip_comments(read(os.path.join(THEME, name)))
            depth = 0
            for c in css:
                depth += {"{": 1, "}": -1}.get(c, 0)
                self.assertGreaterEqual(depth, 0, name)
            self.assertEqual(depth, 0, name)

    def test_shell_selectors_are_scoped(self):
        scoped = re.compile(r"(?<![\w-])[.#]?(phosh-[\w-]+|sq_\w+)")
        found = 0
        for head, _ in rules(read(os.path.join(THEME, "shell.css"))):
            self.assertFalse(head.startswith("@"), head)
            for sel in head.split(","):
                found += 1
                self.assertRegex(sel.strip(), scoped,
                                 f"shell.css selector {sel.strip()!r} names no phosh or squeekboard node")
        self.assertGreater(found, 40)

    def test_shell_defines_only_its_own_colours(self):
        css = strip_comments(read(os.path.join(THEME, "shell.css")))
        names = re.findall(r"@define-color\s+([\w-]+)", css)
        self.assertTrue(names)
        for n in names:
            self.assertRegex(n, r"^(phosh|antumbra)_", f"shell.css redefines GTK-wide colour {n}")

    def test_palette_agrees(self):
        gtk3 = {n.replace("_", "-"): v.lower() for n, v in re.findall(
            r"@define-color\s+antumbra_(\w+)\s+(#[0-9a-fA-F]{6})\s*;", read(os.path.join(THEME, "shell.css")))}
        gtk4 = {n: v.lower() for n, v in re.findall(
            r"--antumbra-([\w-]+):\s*(#[0-9a-fA-F]{6})\s*;", read(os.path.join(THEME, "apps.css")))}
        shared = set(gtk3) & set(gtk4)
        self.assertGreaterEqual(len(shared), 10)
        for n in shared:
            self.assertEqual(gtk3[n], gtk4[n], f"palette role {n} differs between shell.css and apps.css")

    def test_vm_harness_uses_the_accent(self):
        apps = read(os.path.join(THEME, "apps.css"))
        self.assertIn("--accent-bg-color: var(--antumbra-primary);", apps)
        primary = re.search(r"--antumbra-primary:\s*#([0-9a-f]{6});", apps).group(1)
        src = read(os.path.join(ROOT, "tests", "vm", "antumbra_vm.py"))
        m = re.search(r"^WELCOME_ACCENT = (\(.*?\))", src, re.M)
        self.assertIsNotNone(m, "tests/vm/antumbra_vm.py has no WELCOME_ACCENT")
        self.assertEqual(ast.literal_eval(m.group(1)), tuple(int(primary[i:i + 2], 16) for i in (0, 2, 4)))

    def test_welcome_css_imports_apps_css(self):
        self.assertIn('@import url("apps.css");', read(os.path.join(THEME, "welcome.css")))

    def test_referenced_files_exist(self):
        for uri in re.findall(r'url\("(file:///[^"]+)"\)', read(os.path.join(THEME, "shell.css"))):
            self.assertTrue(os.path.isfile(overlay_path(uri)), uri)
        # the per-user and greeter stubs import these two
        for script in (os.path.join(OVERLAY, "usr", "libexec", "antumbra-session"),
                       os.path.join(ROOT, "config", "hooks", "50-session-users.sh")):
            text = read(script)
            for name in ("shell.css", "apps.css"):
                self.assertIn(name, text, script)
                self.assertTrue(os.path.isfile(os.path.join(THEME, name)), name)


class OverrideTest(unittest.TestCase):
    def test_comments_on_their_own_lines(self):
        # GKeyFile has no trailing comments: "key='v'  # note" makes the
        # note part of the value, and glib-compile-schemas --strict fails.
        for n, line in enumerate(read(OVERRIDE).splitlines(), 1):
            s = line.strip()
            if not s or s.startswith("#") or (s.startswith("[") and s.endswith("]")):
                continue
            self.assertRegex(s, r"^[a-z0-9-]+=", f"line {n}")
            unquoted = re.sub(r"'[^']*'", "", s.split("=", 1)[1])
            self.assertNotIn("#", unquoted, f"line {n}: trailing comment")

    def test_wallpapers_exist(self):
        uris = re.findall(r"^picture-uri(?:-dark)?='([^']+)'", read(OVERRIDE), re.M)
        self.assertEqual(len(uris), 3)
        for uri in uris:
            self.assertTrue(os.path.isfile(overlay_path(uri)), uri)


class SvgTest(unittest.TestCase):
    def check_svg(self, path, size, max_bytes):
        data = read(path)
        self.assertLess(len(data.encode()), max_bytes, path)
        # gdk-pixbuf recognises SVG by "<svg" in the first 256 bytes, and
        # phosh loads its wallpapers from a stream, without a file name to
        # fall back on: a long comment before the element makes the image
        # "Unrecognized image file format". Comments go inside <svg>.
        self.assertIn(b"<svg", data.encode()[:256], f"{path}: <svg not in the first 256 bytes")
        self.assertNotIn("data:", data, f"{path}: embedded data")
        self.assertIn("SPDX-License-Identifier: GPL-3.0-or-later", data, path)
        root = ET.fromstring(data)
        self.assertEqual(root.tag, SVG_NS + "svg")
        self.assertEqual((root.get("width"), root.get("height")), size, path)
        self.assertFalse(list(root.iter(SVG_NS + "image")), f"{path}: raster image")
        # every url(#id) reference resolves
        ids = {e.get("id") for e in root.iter() if e.get("id")}
        for ref in re.findall(r"url\(#([\w-]+)\)", data):
            self.assertIn(ref, ids, f"{path}: url(#{ref})")

    def test_wallpapers(self):
        for name in ("antumbra-dark.svg", "antumbra-light.svg", "antumbra-lock.svg"):
            self.check_svg(os.path.join(BACKGROUNDS, name), ("1440", "3120"), 16384)

    def test_pill(self):
        self.check_svg(os.path.join(THEME, "pill.svg"), ("324", "12"), 2048)


if __name__ == "__main__":
    unittest.main()
