#!/usr/bin/env python3
"""Antumbra's build guard (queue item CI13).

Scans the Android tree for things that must never be built into Antumbra
and exits 1 if it finds one. Usage:

    python3 -B ci/build_guard.py [ROOT]

ROOT defaults to antumbra/android (this file's parent's parent). Tests,
test fixtures and documentation are not scanned: they may name what is
forbidden in order to check for it. Comment lines are skipped in code.

The rules:

  modem-diag     no modem diagnostic or NV-write code (/dev/diag, diag_mdlog,
                 QPST/QFIL tools, NV writes, AT+EGMR, AT$QCNV)
  imei           no IMEI-related hooks (reading or setting the IMEI)
  usb-diag       no `diag` function in any USB configuration
  tor-relay      tor is a client only: no ORPort, DirPort, BridgeRelay,
                 ExitRelay or ServerTransportPlugin in tor's configuration
                 (module/ and tor/)
  snowflake-proxy  no Snowflake proxy mode, in any file or app list
  power-menu     an overlay that sets config_globalActionsList keeps the
                 emergency item
  volte          no module file names persist.dbg.volte_avail_ovr outside a
                 comment (MOD7: VoLTE's force-on is never cleared)
  app-list       the curated app lists hold no satellite-messenger or
                 satellite-terminal companion app, radio-firmware flasher or
                 Snowflake proxy

Apps whose radio region differs from the configured one cannot be judged
from a package name; that check belongs to the curated repository (APP1).
"""

import os
import re
import sys

CODE_EXT = {".sh", ".kt", ".kts", ".java", ".py", ".go", ".xml", ".prop", ".rc", ".conf", ".txt", ".json",
            ".c", ".h", ".cc", ".cpp", ".mk", ".bp", ".gradle", ".properties", ".yml", ".yaml"}
SKIP_DIRS = {"tests", "test", "androidTest", "fixtures", "docs", "build", ".gradle", ".git", "node_modules"}
SELF = os.path.abspath(__file__)

# (rule, regex, path filter or None, message)
LINE_RULES = [
    ("modem-diag", re.compile(r"/dev/diag\b|\bdiag_mdlog\b|\bQPST\b|\bQFIL\b|\bnv_?write\b|AT\+EGMR|AT\$QCNV",
                              re.I), None, "modem diagnostic or NV-write code"),
    ("imei", re.compile(r"\bgetImei\b|\bgetDeviceId\s*\(|\bgetMeid\b|\bsetImei\b|\bimei\s*=|persist\.radio\.imei",
                        re.I), None, "an IMEI-related hook"),
    ("usb-diag", re.compile(r"usb\.config\b[^\n]*\bdiag\b|\bdiag\b[^\n]*usb\.config\b|functions/diag", re.I), None,
     "diag in a USB configuration"),
    ("tor-relay", re.compile(r"^\s*(?:echo\s+['\"]?|printf\s+['\"]?)?(ORPort|DirPort|BridgeRelay|ExitRelay|"
                             r"ServerTransportPlugin)\b(?!\s+0\b)"),
     lambda rel: rel.startswith(("module/", "tor/")) or os.path.basename(rel).startswith("torrc"),
     "a relay setting in tor's configuration (tor is a client only)"),
    ("snowflake-proxy", re.compile(r"snowflake[-_ ]?proxy|proxy[-_ ]?snowflake|org\.torproject\.snowflake\b", re.I),
     None, "a Snowflake proxy"),
    ("volte", re.compile(r"volte_avail_ovr"), lambda rel: rel.startswith("module/"),
     "persist.dbg.volte_avail_ovr named in a module file"),
]

APP_LIST_BAD = re.compile(r"satellite|iridium|inreach|starlink|zoleo|bivystick|spotx|thuraya|globalstar|"
                          r"qfil|msmdownload|\bodin\b|heimdall|firmware[-_.]?flash|radio[-_.]?flash|snowflake", re.I)
POWER_MENU = re.compile(r"config_globalActionsList")


def is_comment(line, ext):
    s = line.strip()
    if not s:
        return True
    if ext in (".sh", ".py", ".conf", ".prop", ".rc", ".mk", ".txt", ".yml", ".yaml", ".properties") or ext == "":
        return s.startswith("#")
    if ext in (".kt", ".kts", ".java", ".go", ".c", ".h", ".cc", ".cpp", ".gradle", ".bp"):
        return s.startswith(("//", "/*", "*"))
    if ext == ".xml":
        return s.startswith("<!--")
    return False


def app_list(rel):
    base = os.path.basename(rel)
    return base in ("app-lab.txt", "apps.txt", "curated-apps.txt") or base.endswith(".apps.txt")


def scan(root):
    findings = []
    for d, dirs, files in os.walk(root):
        dirs[:] = sorted(x for x in dirs if x not in SKIP_DIRS)
        for f in sorted(files):
            path = os.path.join(d, f)
            if os.path.abspath(path) == SELF or os.path.islink(path):
                continue
            rel = os.path.relpath(path, root).replace(os.sep, "/")
            ext = os.path.splitext(f)[1].lower()
            if ext not in CODE_EXT and not f.startswith("torrc") and f not in (
                    "service.sh", "post-fs-data.sh", "customize.sh", "uninstall.sh"):
                if ext != "" or not _is_script(path):
                    continue
            try:
                with open(path, encoding="utf-8", errors="replace") as fh:
                    text = fh.read()
            except OSError:
                continue
            lines = text.splitlines()
            for n, line in enumerate(lines, 1):
                if is_comment(line, ext):
                    continue
                for rule, rx, only, msg in LINE_RULES:
                    if only is not None and not only(rel):
                        continue
                    if rx.search(line):
                        findings.append((rule, rel, n, msg))
            if app_list(rel):
                for n, line in enumerate(lines, 1):
                    if line.strip().startswith("#") or not line.strip():
                        continue
                    if APP_LIST_BAD.search(line):
                        findings.append(("app-list", rel, n, "an app the curated lists must never hold"))
            if ext == ".xml" and POWER_MENU.search(text):
                for m in re.finditer(r"<string-array[^>]*config_globalActionsList[^>]*>(.*?)</string-array>",
                                     text, re.S):
                    if "emergency" not in m.group(1):
                        n = text[:m.start()].count("\n") + 1
                        findings.append(("power-menu", rel, n, "the power menu without its emergency item"))
    return findings


def _is_script(path):
    try:
        with open(path, "rb") as fh:
            return fh.read(2) == b"#!"
    except OSError:
        return False


def main(argv):
    root = argv[1] if len(argv) > 1 else os.path.dirname(os.path.dirname(SELF))
    findings = scan(root)
    for rule, rel, n, msg in findings:
        print("build-guard: %s:%d: %s (%s)" % (rel, n, msg, rule))
    if findings:
        print("build-guard: %d finding(s)" % len(findings))
        return 1
    print("build-guard: clean (%s)" % os.path.abspath(root))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
