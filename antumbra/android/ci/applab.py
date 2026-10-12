#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Antumbra CI: the app lab's helper (standard library; curl, apksigner and
aapt2 are run as programs).

The app lab (emulator-apps.sh, the app-lab job of antumbra-android.yml)
installs real app stores and apps on the CI's virtual phone under Antumbra
and records what each one did through Tor. Every APK is downloaded here, on
the CI runner, from its store's official source over HTTPS, and checked
before it goes near the phone:

  F-Droid   index-v2.json from f-droid.org, whose SHA-256 must be the one
            entry.json lists for it. An app is the version the F-Droid client
            would suggest (the newest one with no release channel, signed by
            the package's preferred signer, built for the phone's ABI and
            SDK); its APK's SHA-256 must be the index's, and its signing
            certificate (apksigner) one the index lists for that version.
            The client itself is the file f-droid.org/F-Droid.apk, the one
            F-Droid's website hands out: its SHA-256 must be one the index
            lists for org.fdroid.fdroid, and its certificate F-Droid's own
            (FDROID_SIGNER, pinned).
  Aptoide   the web service's app metadata (getMeta): the APK's address, MD5,
            size and the SHA-1 of its signing certificate, and Aptoide's own
            rank, which must be TRUSTED (the certificate matches the one
            Aptoide knows for the developer). The APK's size and MD5 must
            match, and that SHA-1 must be among the certificates apksigner
            reports. Aptoide publishes no checksum: the SHA-256 and the
            certificate's SHA-256 are recorded. The Aptoide client is the
            one in Aptoide's own store "aptoide-web" (its website's).
  TapTap    the international client from d.tap.io/latest, the link of
            taptap.io/download. TapTap publishes no checksum: the SHA-256
            and the certificate are recorded, apksigner must verify it, and
            the certificate's SHA-1 is compared with what Aptoide lists for
            com.taptap.global (noted, not required).

Every APK must also be the package it claims to be (aapt2) and verify with
apksigner. An item that cannot be downloaded or verified is recorded with
the reason and never installed; the others go on.

Commands:

  applab.py catalogue FILE
      Checks the catalogue (app-lab.txt: store TAB package TAB label per
      line, '#' starts a comment) and prints it as JSON lines.
  applab.py fdroid-pick --index INDEX-V2.json PACKAGE [--abi ABI]... [--sdk N]
  applab.py aptoide-pick --meta GETMETA.json
      The version to install and how to check it, as JSON.
  applab.py fetch --catalogue FILE --out DIR [--apksigner PATH] [--aapt2 PATH]
                  [--abi ABI]... [--sdk N] [--stores fdroid,aptoide,taptap]
                  [--budget SECONDS]
      Downloads and checks the stores' clients and the catalogue's apps into
      DIR and writes DIR/downloads.json (again after each item). No download
      runs past the budget; what is left then is recorded as not downloaded.
      Exit 0 unless the catalogue is bad.
  applab.py plan DOWNLOADS.json
      One line per item for emulator-apps.sh: KIND TAB NAME TAB PACKAGE TAB
      LABEL TAB VERIFIED (1|0) TAB APK TAB NOTE.
  applab.py ui-summary < window_dump.xml
      For the stores' wait: COUNT TAB X TAB Y TAB BUTTON TAB ERROR, where
      COUNT is the number of distinct texts on screen, X Y BUTTON a button
      that only dismisses (Skip, Not now, Don't allow; never one that signs
      in, agrees or allows) and ERROR a network error on screen ("-" when
      there is none).
  applab.py build REPORT_DIR [--run N] [--jpeg-width 540] [--downloads FILE]
      apps.json and apps.md from the scenario's records (apps/records.jsonl,
      written by emulator-apps.sh), apps/downloads.json, tor's STREAM events
      (apps/tor-streams.txt), the DNS filter's query log (apps/dnsfilter.log),
      the logcat and screen of each item (logs/apps/) and the leak analysis
      (apps/analysis.json, when analyse.sh has run). Screenshots are turned
      into JPEGs JPEG-WIDTH pixels wide when ImageMagick's convert is there
      (0 keeps the PNGs). --downloads: the fetch's downloads.json, read
      when apps/ has none. Prints apps.md.

apps.json (schema 1): {"schema", "run", "generated", "device", "session",
"leak", "stores": [ITEM], "apps": [ITEM], "totals"}. An ITEM holds what was
downloaded and how it was checked ("download": the fetch record), what
happened on the phone ("installed", "launched", "running", "crashed",
"fatal", "gms_missing", "anr", "loaded" for a store, "screenshot", "ui"),
and the window's traffic: "names" (every name the DNS filter was asked, with
its decisions), "blocked", "servfail", "tor_targets" (the destinations asked
of tor's TransPort, with tor's outcome) and "tor_resolves" (the names tor
resolved), with "window" (host times and the line ranges of both logs).
"""

import argparse
import datetime
import hashlib
import html
import json
import os
import re
import shutil
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import leak_analyser as la  # noqa: E402  tor's STREAM events and the filter's log, read the same way

SCHEMA = 1
FDROID_REPO = "https://f-droid.org/repo"
FDROID_ENTRY = FDROID_REPO + "/entry.json"
FDROID_CLIENT_URL = "https://f-droid.org/F-Droid.apk"
# F-Droid's signing certificate (SHA-256), the one f-droid.org publishes for
# its repository and client, and the index's preferredSigner for
# org.fdroid.fdroid. Pinned: a client with another certificate is not
# installed, whatever the index says.
FDROID_SIGNER = "43238d512c1e5eb2d6569f4a3afbf5523418b82e0a3ed1552770abb9a9c9ccab"
APTOIDE_META = "https://ws75.aptoide.com/api/7/app/getMeta"
# Aptoide's own store, the one its website's client download comes from.
APTOIDE_CLIENT_STORE = "aptoide-web"
TAPTAP_URL = "https://d.tap.io/latest"

# The stores, in the order the lab opens them. "hosts": the domains whose
# names count as the store's own catalogue traffic.
STORES = (
    {"name": "fdroid", "label": "F-Droid", "package": "org.fdroid.fdroid",
     "hosts": ("f-droid.org",)},
    {"name": "aptoide", "label": "Aptoide", "package": "cm.aptoide.pt",
     "hosts": ("aptoide.com", "aptoide.pt", "catappult.io")},
    {"name": "taptap", "label": "TapTap", "package": "com.taptap.global",
     "hosts": ("taptap.io", "tap.io", "tapimg.net", "tapimg.com", "taptapdada.com", "tapapis.com")},
)
CATALOGUE_STORES = ("fdroid", "aptoide")

# The time budget of one download (seconds), and of the F-Droid index.
APK_MAX_TIME = 600
INDEX_MAX_TIME = 300

# Buttons the lab may press in a store's first-run screens: each only
# dismisses. Nothing that signs in, agrees, allows or continues.
DISMISS_RE = re.compile(r"^(skip|not now|no,? thanks|maybe later|later|close|dismiss|deny|"
                        r"don.t allow|cancel)$", re.I)
NETWORK_ERROR_RE = re.compile(r"(no internet|no connection|not connected|network error|connection error|"
                              r"check your (internet|connection|network)|you.re offline|you are offline|"
                              r"couldn.t (connect|load|reach)|could not (connect|load|reach)|"
                              r"something went wrong|unable to (connect|load)|failed to (connect|load)|"
                              r"timed? ?out)", re.I)
GMS_RE = re.compile(r"(google play services|GooglePlayServicesUtil|GoogleApiAvailability|SERVICE_MISSING|"
                    r"SERVICE_INVALID|MISSING_INSTANCEID_SERVICE|com\.google\.android\.gms\S* "
                    r"(?:not found|not installed|is missing|missing)|"
                    r"Package com\.google\.android\.gms (?:not found|is missing))", re.I)
# A store's screen counts as a catalogue from this many distinct texts.
CATALOGUE_TEXTS = 12


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------------------
# The catalogue
# ---------------------------------------------------------------------------

_PACKAGE_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$")


def parse_catalogue(text):
    """[{"store", "package", "label"}] from app-lab.txt. Raises ValueError
    naming the line for a bad one (a store this lab does not know, a
    package name Android would refuse, a package twice)."""
    out = []
    seen = set()
    for n, line in enumerate(text.splitlines(), 1):
        line = line.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        parts = [p.strip() for p in line.split("\t")]
        if len(parts) != 3 or not all(parts):
            raise ValueError("line %d: want STORE<TAB>PACKAGE<TAB>LABEL" % n)
        store, package, label = parts
        if store not in CATALOGUE_STORES:
            raise ValueError("line %d: unknown store %r (known: %s)" % (n, store, ", ".join(CATALOGUE_STORES)))
        if not _PACKAGE_RE.match(package):
            raise ValueError("line %d: %r is not a package name" % (n, package))
        if package in seen:
            raise ValueError("line %d: %s is listed twice" % (n, package))
        seen.add(package)
        out.append({"store": store, "package": package, "label": label})
    return out


# ---------------------------------------------------------------------------
# F-Droid's index
# ---------------------------------------------------------------------------

def _https_mirrors(index):
    out = []
    for m in (index.get("repo") or {}).get("mirrors") or []:
        url = (m or {}).get("url") or ""
        if url.startswith("https://") and url.rstrip("/") != FDROID_REPO:
            out.append(url.rstrip("/"))
    return out


def fdroid_pick(index, package, abis=("x86_64",), sdk=36):
    """The version of PACKAGE the F-Droid client would suggest for a phone
    with these ABIs and this SDK: the newest without a release channel
    (no beta), signed by the package's preferred signer when it names one,
    with native code for one of ABIS (or none) and a usesSdk range that
    takes SDK. Raises LookupError when there is none."""
    pkg = (index.get("packages") or {}).get(package)
    if not pkg:
        raise LookupError("%s is not in F-Droid's index" % package)
    preferred = (pkg.get("metadata") or {}).get("preferredSigner")
    best = None
    for v in (pkg.get("versions") or {}).values():
        mf = v.get("manifest") or {}
        if v.get("releaseChannels"):
            continue
        native = mf.get("nativecode") or []
        if native and not set(native) & set(abis):
            continue
        uses = mf.get("usesSdk") or {}
        if (uses.get("minSdkVersion") or 1) > sdk:
            continue
        if uses.get("maxSdkVersion") and uses["maxSdkVersion"] < sdk:
            continue
        signers = (mf.get("signer") or {}).get("sha256") or []
        if preferred and preferred not in signers:
            continue
        if not (v.get("file") or {}).get("sha256"):
            continue
        if best is None or (mf.get("versionCode") or 0) > (best["manifest"].get("versionCode") or 0):
            best = v
    if best is None:
        raise LookupError("no stable version of %s for %s and SDK %d in F-Droid's index" % (
            package, "/".join(abis), sdk))
    mf, f = best["manifest"], best["file"]
    address = ((index.get("repo") or {}).get("address") or FDROID_REPO).rstrip("/")
    return {
        "package": package,
        "label": ((pkg.get("metadata") or {}).get("name") or {}).get("en-US"),
        "version": mf.get("versionName"),
        "version_code": mf.get("versionCode"),
        "url": address + f["name"],
        "mirrors": [m + f["name"] for m in _https_mirrors(index)],
        "sha256": f["sha256"].lower(),
        "size": f.get("size"),
        "signers": [s.lower() for s in (mf.get("signer") or {}).get("sha256") or []],
        "nativecode": mf.get("nativecode") or [],
        "min_sdk": (mf.get("usesSdk") or {}).get("minSdkVersion"),
    }


def fdroid_version_by_sha256(index, package, sha256):
    """The index's record of PACKAGE whose APK has this SHA-256, or None."""
    pkg = (index.get("packages") or {}).get(package) or {}
    for v in (pkg.get("versions") or {}).values():
        if ((v.get("file") or {}).get("sha256") or "").lower() == sha256.lower():
            mf = v.get("manifest") or {}
            return {"version": mf.get("versionName"), "version_code": mf.get("versionCode"),
                    "release_channels": v.get("releaseChannels") or [],
                    "signers": [s.lower() for s in (mf.get("signer") or {}).get("sha256") or []]}
    return None


# ---------------------------------------------------------------------------
# Aptoide's app metadata
# ---------------------------------------------------------------------------

def _colon_hex(s):
    return re.sub(r"[^0-9a-f]", "", (s or "").lower())


def aptoide_pick(meta):
    """What Aptoide's getMeta says about one app: where its APK is and how
    to check it. Raises LookupError when Aptoide has no such app."""
    info = meta.get("info") or {}
    if info.get("status") != "OK" or not isinstance(meta.get("data"), dict):
        errs = meta.get("errors") or []
        raise LookupError("Aptoide: " + ("; ".join("%s: %s" % (e.get("code"), e.get("description")) for e in errs)
                                          or "status %s" % info.get("status")))
    d = meta["data"]
    f = d.get("file") or {}
    hw = f.get("hardware") or {}
    sig = f.get("signature") or {}
    aab = d.get("aab")
    splits = (aab or {}).get("splits") or [] if isinstance(aab, dict) else []
    return {
        "package": d.get("package"),
        "label": d.get("name"),
        "store_name": (d.get("store") or {}).get("name"),
        "version": f.get("vername"),
        "version_code": f.get("vercode"),
        "url": f.get("path"),
        "url_alt": f.get("path_alt") if f.get("path_alt") != f.get("path") else None,
        "md5": (f.get("md5sum") or "").lower(),
        "size": f.get("filesize"),
        "signer_sha1": _colon_hex(sig.get("sha1")),
        "signer_owner": sig.get("owner"),
        "rank": (f.get("malware") or {}).get("rank"),
        "cpus": hw.get("cpus") or [],
        "min_sdk": hw.get("sdk"),
        "obb": bool(d.get("obb")),
        "splits": len(splits),
        "updated": d.get("updated"),
    }


def aptoide_meta_url(package, store=None):
    return "%s?package_name=%s%s" % (APTOIDE_META, package, "&store_name=" + store if store else "")


# ---------------------------------------------------------------------------
# Downloads and checks (curl, apksigner, aapt2)
# ---------------------------------------------------------------------------

def curl_download(url, dest, max_time=APK_MAX_TIME, compressed=False):
    """Downloads URL into DEST with curl: HTTPS only, redirects followed and
    kept on HTTPS, two retries on transient errors, given up when slower
    than 50 KB/s for a minute (the caller then tries a mirror). Returns
    (final URL, None) or (None, error). DEST is written only when the
    transfer ended with HTTP 200."""
    tmp = dest + ".part"
    cmd = ["curl", "-sS", "-L", "--proto", "=https", "--proto-redir", "=https", "--retry", "2",
           "--retry-delay", "5", "--connect-timeout", "30", "--max-time", str(int(max_time)),
           "--speed-limit", "51200", "--speed-time", "60",
           "-o", tmp, "-w", "%{http_code} %{url_effective}"]
    if compressed:
        cmd.append("--compressed")
    cmd.append(url)
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=max_time + 60)
    except (OSError, subprocess.TimeoutExpired) as e:
        _rm(tmp)
        return None, "curl: %s" % e
    code, _, final = r.stdout.strip().partition(" ")
    if r.returncode != 0 or code != "200":
        _rm(tmp)
        why = "HTTP %s" % code if code and code != "000" else "no HTTP answer"
        if r.returncode != 0:
            why += "; curl exit %d: %s" % (r.returncode, r.stderr.strip().splitlines()[-1] if r.stderr.strip() else "")
        return None, why
    os.replace(tmp, dest)
    return final or url, None


def _rm(p):
    try:
        os.remove(p)
    except OSError:
        pass


def file_digests(path):
    sha, md5, n = hashlib.sha256(), hashlib.md5(), 0
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            sha.update(chunk)
            md5.update(chunk)
            n += len(chunk)
    return sha.hexdigest(), md5.hexdigest(), n


_CERT_RE = re.compile(r"certificate (SHA-256|SHA-1) digest: ([0-9a-fA-F:]+)")


def parse_apksigner(text):
    """{"verifies", "sha256", "sha1", "schemes", "dn"} from 'apksigner verify
    --print-certs -v' (and, appended, 'apksigner lineage --print-certs':
    a key rotated with APK Signature Scheme v3 lists the older
    certificates there)."""
    sha256, sha1 = [], []
    for kind, value in _CERT_RE.findall(text):
        v = _colon_hex(value)
        lst = sha256 if kind == "SHA-256" else sha1
        if v not in lst:
            lst.append(v)
    dn = []
    for d in re.findall(r"^Signer\b.*? certificate DN: (.*)$", text, re.M):
        if d not in dn:
            dn.append(d)
    return {
        "verifies": bool(re.search(r"^Verifies$", text, re.M)),
        "sha256": sha256,
        "sha1": sha1,
        "schemes": re.findall(r"^Verified using (v[0-9.]+) scheme[^:\n]*: true$", text, re.M),
        "dn": dn[:3],
    }


def run_apksigner(apksigner, apk):
    if not apksigner:
        return None
    out = ""
    for args in (["verify", "--print-certs", "-v", apk], ["lineage", "--in", apk, "--print-certs"]):
        try:
            r = subprocess.run([apksigner] + args, capture_output=True, text=True, timeout=300)
            out += r.stdout + "\n" + r.stderr + "\n"
            if args[0] == "verify" and r.returncode != 0:
                break
        except (OSError, subprocess.TimeoutExpired) as e:
            out += "apksigner: %s\n" % e
            break
    return parse_apksigner(out)


def parse_badging(text):
    """{"package", "version", "version_code", "min_sdk", "native_code"} from
    'aapt2 dump badging'."""
    out = {"package": None, "version": None, "version_code": None, "min_sdk": None, "native_code": []}
    m = re.search(r"^package: name='([^']*)'(?: versionCode='([^']*)')?(?: versionName='([^']*)')?", text, re.M)
    if m:
        out["package"], out["version_code"], out["version"] = m.group(1), m.group(2), m.group(3)
    m = re.search(r"^(?:minSdkVersion|sdkVersion):'([^']*)'", text, re.M)
    if m:
        out["min_sdk"] = m.group(1)
    m = re.search(r"^native-code: (.*)$", text, re.M)
    if m:
        out["native_code"] = re.findall(r"'([^']*)'", m.group(1))
    return out


def run_aapt2(aapt2, apk):
    if not aapt2:
        return None
    try:
        r = subprocess.run([aapt2, "dump", "badging", apk], capture_output=True, text=True, timeout=300)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return parse_badging(r.stdout)


class Tools:
    """The programs fetch uses, replaceable in tests, and the downloads'
    time budget (seconds; None for none): a download never runs past it,
    and one asked for after it fails at once."""

    def __init__(self, apksigner=None, aapt2=None, download=curl_download, budget=None):
        self.apksigner = apksigner
        self.aapt2 = aapt2
        self.download = download
        self.budget = budget
        self.deadline = time.monotonic() + budget if budget else None

    def get(self, url, dest, max_time, compressed=False):
        if self.deadline is not None:
            left = self.deadline - time.monotonic()
            if left < 5:
                return None, "the downloads' time budget (%d s) ran out" % self.budget
            max_time = min(max_time, int(left))
        return self.download(url, dest, max_time, compressed=compressed)

    def signers(self, apk):
        return run_apksigner(self.apksigner, apk)

    def badging(self, apk):
        return run_aapt2(self.aapt2, apk)


def _new_item(kind, name, store, package, label, source):
    return {"kind": kind, "name": name, "store": store, "package": package, "label": label,
            "source": source, "url": None, "version": None, "version_code": None, "file": None,
            "size": None, "sha256": None, "md5": None, "expected": {}, "checks": [],
            "signer": None, "apk": None, "verified": False, "error": None, "notes": []}


def _check(item, what, ok):
    item["checks"].append({"check": what, "ok": bool(ok)})
    return bool(ok)


def _get(item, out, urls, dest_rel, tools, max_time=APK_MAX_TIME):
    """Downloads the first of URLS that answers into OUT/DEST_REL, unless a
    file already there has the expected SHA-256 (a second run by hand).
    Sets item's url, file, size and digests; returns False on failure."""
    dest = os.path.join(out, dest_rel)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    want = item["expected"].get("sha256")
    if want and os.path.isfile(dest) and file_digests(dest)[0] == want:
        item["url"] = item["url"] or urls[0]
        item["notes"].append("already downloaded")
    else:
        errors = []
        for url in [u for u in urls if u]:
            final, err = tools.get(url, dest, max_time)
            if not err:
                item["url"] = final
                break
            errors.append("%s: %s" % (url, err))
        else:
            item["error"] = "download failed: " + "; ".join(errors)
            return False
    item["file"] = dest_rel
    item["sha256"], item["md5"], item["size"] = file_digests(dest)
    return True


def _common_checks(item, out, tools):
    """apksigner and aapt2 on the downloaded file."""
    apk = os.path.join(out, item["file"])
    sig = tools.signers(apk)
    item["signer"] = sig
    if sig is None:
        item["notes"].append("signing certificate not checked (no apksigner)")
    else:
        _check(item, "apksigner verifies the signature", sig["verifies"])
    b = tools.badging(apk)
    item["apk"] = b
    if b is None:
        item["notes"].append("package name not read (no aapt2)")
    else:
        _check(item, "the APK is %s" % item["package"], b.get("package") == item["package"])
    return sig


def _finish(item):
    item["verified"] = item["error"] is None and bool(item["checks"]) and all(c["ok"] for c in item["checks"])
    if item["error"] is None and not item["verified"]:
        item["error"] = "not verified: " + ("; ".join(c["check"] for c in item["checks"] if not c["ok"])
                                            or "nothing could be checked (no apksigner, no aapt2)")
    return item


def load_fdroid_index(out, tools):
    """(index, info): F-Droid's index-v2, checked against entry.json."""
    info = {"url": FDROID_REPO + "/index-v2.json", "entry": FDROID_ENTRY, "sha256": None,
            "entry_sha256": None, "ok": False, "packages": None, "timestamp": None, "error": None}
    entry_path = os.path.join(out, "fdroid-entry.json")
    index_path = os.path.join(out, "fdroid-index-v2.json")
    _, err = tools.get(FDROID_ENTRY, entry_path, 60)
    if err:
        info["error"] = "entry.json: " + err
        return None, info
    try:
        with open(entry_path, encoding="utf-8") as f:
            entry = json.load(f)
        info["entry_sha256"] = entry["index"]["sha256"].lower()
        name = entry["index"]["name"]
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as e:
        info["error"] = "entry.json unreadable: %s" % e
        return None, info
    info["url"] = FDROID_REPO + name
    if not (os.path.isfile(index_path) and file_digests(index_path)[0] == info["entry_sha256"]):
        _, err = tools.get(info["url"], index_path, INDEX_MAX_TIME, True)
        if err:
            info["error"] = "index-v2.json: " + err
            return None, info
    info["sha256"] = file_digests(index_path)[0]
    if info["sha256"] != info["entry_sha256"]:
        info["error"] = "index-v2.json's SHA-256 is not the one entry.json lists"
        return None, info
    try:
        with open(index_path, encoding="utf-8") as f:
            index = json.load(f)
    except (OSError, ValueError) as e:
        info["error"] = "index-v2.json unreadable: %s" % e
        return None, info
    info["ok"] = True
    info["packages"] = len(index.get("packages") or {})
    info["timestamp"] = (index.get("repo") or {}).get("timestamp")
    return index, info


def fetch_fdroid_client(out, index, tools):
    st = STORES[0]
    item = _new_item("store", st["name"], st["name"], st["package"], st["label"], FDROID_CLIENT_URL)
    if index is None:
        item["error"] = "F-Droid's index could not be read"
        return _finish(item)
    if not _get(item, out, [FDROID_CLIENT_URL], "stores/fdroid.apk", tools):
        return _finish(item)
    v = fdroid_version_by_sha256(index, st["package"], item["sha256"])
    _check(item, "its SHA-256 is one F-Droid's index lists for org.fdroid.fdroid", v is not None)
    if v:
        item["version"], item["version_code"] = v["version"], v["version_code"]
        item["expected"] = {"sha256": item["sha256"], "signers": v["signers"],
                            "how": "F-Droid's index-v2 lists this SHA-256 for org.fdroid.fdroid %s (%s)%s" % (
                                v["version"], v["version_code"],
                                ", release channel " + "/".join(v["release_channels"]) if v["release_channels"] else "")}
    item["expected"]["pinned_signer"] = FDROID_SIGNER
    sig = _common_checks(item, out, tools)
    if sig is not None:
        _check(item, "signed by F-Droid's pinned certificate", FDROID_SIGNER in sig["sha256"])
        if v:
            _check(item, "signed by a certificate the index lists for it", set(v["signers"]) & set(sig["sha256"]))
    return _finish(item)


def fetch_fdroid_app(entry, out, index, tools, abis, sdk):
    pkg = entry["package"]
    item = _new_item("app", pkg, "fdroid", pkg, entry["label"], "F-Droid index-v2 (f-droid.org)")
    if index is None:
        item["error"] = "F-Droid's index could not be read"
        return _finish(item)
    try:
        pick = fdroid_pick(index, pkg, abis, sdk)
    except LookupError as e:
        item["error"] = str(e)
        return _finish(item)
    item["version"], item["version_code"] = pick["version"], pick["version_code"]
    item["expected"] = {"sha256": pick["sha256"], "size": pick["size"], "signers": pick["signers"],
                        "how": "F-Droid's index-v2 (its SHA-256 checked against entry.json)"}
    item["abis"] = pick["nativecode"]
    if not _get(item, out, [pick["url"]] + pick["mirrors"][:2], "apps/%s.apk" % pkg, tools):
        return _finish(item)
    _check(item, "its SHA-256 is the one F-Droid's index lists", item["sha256"] == pick["sha256"])
    sig = _common_checks(item, out, tools)
    if sig is not None:
        _check(item, "signed by a certificate the index lists for this version",
               set(pick["signers"]) & set(sig["sha256"]))
    return _finish(item)


def _aptoide_item(item, out, meta_path, dest_rel, tools):
    """The common part of an Aptoide download: getMeta, the APK, its MD5,
    size and certificate."""
    with open(meta_path, encoding="utf-8") as f:
        meta = json.load(f)
    pick = aptoide_pick(meta)
    item["version"], item["version_code"] = pick["version"], pick["version_code"]
    item["expected"] = {"md5": pick["md5"], "size": pick["size"], "signer_sha1": pick["signer_sha1"],
                        "signer_owner": pick["signer_owner"], "rank": pick["rank"],
                        "how": "Aptoide's getMeta (store %s); Aptoide publishes no checksum" % pick["store_name"]}
    item["store_name"] = pick["store_name"]
    item["abis"] = pick["cpus"]
    if pick["package"] != item["package"]:
        item["error"] = "Aptoide answered for %s" % pick["package"]
        return None
    if pick["splits"]:
        item["error"] = "split APKs only (%d splits): skipped" % pick["splits"]
        return None
    if pick["obb"]:
        item["notes"].append("the app also wants an OBB expansion file, which is not installed")
    _check(item, "Aptoide ranks it TRUSTED (its certificate is the developer's)", pick["rank"] == "TRUSTED")
    if not _get(item, out, [pick["url"], pick["url_alt"]], dest_rel, tools):
        return None
    _check(item, "its MD5 is the one Aptoide lists", item["md5"] == pick["md5"])
    _check(item, "its size is the one Aptoide lists", item["size"] == pick["size"])
    sig = _common_checks(item, out, tools)
    if sig is not None:
        _check(item, "its certificate's SHA-1 is the one Aptoide lists", pick["signer_sha1"] in sig["sha1"])
    return pick


def _meta(item, out, url, name, tools):
    path = os.path.join(out, "meta", name + ".json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    _, err = tools.get(url, path, 60)
    if err:
        item["error"] = "Aptoide's getMeta: " + err
        return None
    return path


def fetch_aptoide_client(out, tools):
    st = STORES[1]
    url = aptoide_meta_url(st["package"], APTOIDE_CLIENT_STORE)
    item = _new_item("store", st["name"], st["name"], st["package"], st["label"], url)
    path = _meta(item, out, url, "store-aptoide", tools)
    if path:
        try:
            _aptoide_item(item, out, path, "stores/aptoide.apk", tools)
        except (OSError, ValueError, LookupError) as e:
            item["error"] = str(e)
    return _finish(item)


def fetch_aptoide_app(entry, out, tools):
    pkg = entry["package"]
    url = aptoide_meta_url(pkg)
    item = _new_item("app", pkg, "aptoide", pkg, entry["label"], url)
    path = _meta(item, out, url, "app-" + pkg, tools)
    if path:
        try:
            _aptoide_item(item, out, path, "apps/%s.apk" % pkg, tools)
        except (OSError, ValueError, LookupError) as e:
            item["error"] = str(e)
    return _finish(item)


def fetch_taptap(out, tools):
    st = STORES[2]
    item = _new_item("store", st["name"], st["name"], st["package"], st["label"], TAPTAP_URL)
    item["expected"] = {"how": "TapTap's own link (taptap.io/download); TapTap publishes no checksum"}
    if not _get(item, out, [TAPTAP_URL], "stores/taptap.apk", tools):
        return _finish(item)
    sig = _common_checks(item, out, tools)
    if item.get("apk") and item["apk"].get("version"):
        item["version"], item["version_code"] = item["apk"]["version"], item["apk"]["version_code"]
        item["abis"] = item["apk"].get("native_code") or []
    # A second opinion on the certificate: what Aptoide lists for the same
    # package (noted, not required).
    path = os.path.join(out, "meta", "store-taptap-aptoide.json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    _, err = tools.get(aptoide_meta_url(st["package"]), path, 60)
    try:
        if err:
            raise LookupError(err)
        with open(path, encoding="utf-8") as f:
            other = aptoide_pick(json.load(f))
        same = sig is not None and other["signer_sha1"] in sig["sha1"]
        item["expected"]["aptoide_signer_sha1"] = other["signer_sha1"]
        item["notes"].append("certificate %s the one Aptoide lists for %s" % (
            "is" if same else "is NOT", st["package"]))
    except (OSError, ValueError, LookupError) as e:
        item["notes"].append("no second opinion from Aptoide on the certificate (%s)" % e)
    return _finish(item)


def _write_downloads(out, res):
    """downloads.json, written again after every item, so that a fetch cut
    short still leaves what it had done."""
    path = os.path.join(out, "downloads.json")
    with open(path + ".tmp", "w", encoding="utf-8") as f:
        json.dump(res, f, indent=1, sort_keys=True)
        f.write("\n")
    os.replace(path + ".tmp", path)


def fetch(catalogue, out, tools, abis=("x86_64",), sdk=36, stores=("fdroid", "aptoide", "taptap")):
    os.makedirs(out, exist_ok=True)
    res = {"schema": SCHEMA, "fetched": utc_now(), "abis": list(abis), "sdk": sdk,
           "tools": {"apksigner": bool(tools.apksigner), "aapt2": bool(tools.aapt2)},
           "budget_s": tools.budget, "fdroid_index": None, "stores": [], "apps": []}
    index = None
    if "fdroid" in stores or any(e["store"] == "fdroid" for e in catalogue):
        index, res["fdroid_index"] = load_fdroid_index(out, tools)
    for st in STORES:
        if st["name"] not in stores:
            continue
        if st["name"] == "fdroid":
            item = fetch_fdroid_client(out, index, tools)
        elif st["name"] == "aptoide":
            item = fetch_aptoide_client(out, tools)
        else:
            item = fetch_taptap(out, tools)
        res["stores"].append(item)
        _say(item)
        _write_downloads(out, res)
    for e in catalogue:
        if e["store"] == "fdroid":
            item = fetch_fdroid_app(e, out, index, tools, abis, sdk)
        else:
            item = fetch_aptoide_app(e, out, tools)
        res["apps"].append(item)
        _say(item)
        _write_downloads(out, res)
    res["done"] = utc_now()
    _write_downloads(out, res)
    return res


def _say(item):
    print("applab: %s %s: %s" % (item["kind"], item["name"], "verified (%s, sha256 %s)" % (
        item["version"], (item["sha256"] or "")[:16]) if item["verified"] else item["error"]), file=sys.stderr)


def plan_lines(downloads, root):
    """The lines 'applab.py plan' prints (see the module's docstring)."""
    out = []
    for item in list(downloads.get("stores") or []) + list(downloads.get("apps") or []):
        note = item.get("error") or "; ".join(item.get("notes") or []) or "-"
        apk = os.path.join(root, item["file"]) if item.get("file") else "-"
        out.append("\t".join(_one_line(str(x)) for x in (
            item["kind"], item["name"], item["package"], item.get("label") or item["package"],
            1 if item.get("verified") else 0, apk, note)))
    return out


def _one_line(s):
    return re.sub(r"[\t\r\n]+", " ", s).strip() or "-"


# ---------------------------------------------------------------------------
# The phone's screen
# ---------------------------------------------------------------------------

def _bounds(n):
    m = re.match(r"^\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]$", n.get("bounds", ""))
    if not m:
        return None
    x1, y1, x2, y2 = (int(v) for v in m.groups())
    if x2 <= x1 or y2 <= y1:
        return None
    return (x1 + x2) // 2, (y1 + y2) // 2


def ui_summary(xml_text):
    """{"texts": [...], "count", "dismiss": (x, y, text) or None, "error",
    "gms"} for a uiautomator dump."""
    res = {"texts": [], "count": 0, "dismiss": None, "error": None, "gms": None}
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError:
        return res
    seen = set()
    for n in root.iter("node"):
        for t in (n.get("text") or "", n.get("content-desc") or ""):
            t = " ".join(t.split())
            if not t or t in seen:
                continue
            seen.add(t)
            res["texts"].append(t)
            if res["error"] is None and NETWORK_ERROR_RE.search(t):
                res["error"] = t[:120]
            if res["gms"] is None and GMS_RE.search(t):
                res["gms"] = t[:160]
        t = " ".join((n.get("text") or n.get("content-desc") or "").split())
        if res["dismiss"] is None and t and DISMISS_RE.match(t.replace("\u2019", "'")) and \
                n.get("enabled", "true") == "true":
            xy = _bounds(n)
            if xy:
                res["dismiss"] = (xy[0], xy[1], t)
    res["count"] = len(res["texts"])
    return res


# ---------------------------------------------------------------------------
# What happened in an item's window: tor's streams, the filter's log, logcat
# ---------------------------------------------------------------------------

def stream_records(lines):
    """Every stream in a tor-streams.txt transcript, with the index of the
    line that announced it: [{"line", "target", "kind", "purpose",
    "statuses", "reason", "remaps"}]. Parsed as leak_analyser does."""
    streams = {}
    order = []
    epoch = 0
    for i, line in enumerate(lines):
        line = line.rstrip("\r")
        if line.startswith("ANTUMBRA-CI-STREAMS connect"):
            epoch += 1
            continue
        m = la._STREAM_RE.match(line)
        if not m:
            continue
        sid, status, _circ, target, rest = m.groups()
        kv = {k: v.strip('"') for k, v in la._KV_RE.findall(rest)}
        key = (epoch, sid)
        st = streams.get(key)
        if st is None:
            st = streams[key] = {"line": i, "target": None, "kind": None, "purpose": kv.get("PURPOSE", ""),
                                 "statuses": [], "reason": None, "remaps": []}
            order.append(key)
        if status in ("NEW", "NEWRESOLVE") and st["target"] is None:
            st["target"] = target
            st["kind"] = "resolve" if status == "NEWRESOLVE" else "connect"
        elif status == "REMAP":
            st["remaps"].append(target)
        if kv.get("PURPOSE"):
            st["purpose"] = kv["PURPOSE"]
        if kv.get("REASON"):
            st["reason"] = kv["REASON"]
        if not st["statuses"] or st["statuses"][-1] != status:
            st["statuses"].append(status)
    return [streams[k] for k in order if streams[k]["target"]]


def _outcome(statuses):
    """SUCCEEDED when the stream got that far (it is CLOSED later anyway),
    else its last status."""
    if "SUCCEEDED" in statuses:
        return "SUCCEEDED"
    return statuses[-1] if statuses else "?"


def window_streams(streams, start, end):
    """(targets, resolves) of the streams announced in lines [start, end):
    what the phone asked of tor's TransPort, and the names tor resolved for
    the DNS filter. tor's own streams (directory fetches) are left out."""
    targets, resolves = {}, {}
    for st in streams:
        if not start <= st["line"] < end:
            continue
        if st["purpose"] in la.TOR_INTERNAL_PURPOSES or st["target"].startswith(("(", "$")):
            continue
        host, port = la._split_target(st["target"])
        out = _outcome(st["statuses"])
        if st["kind"] == "resolve":
            r = resolves.setdefault(la.normalise_name(host), {"name": la.normalise_name(host), "count": 0,
                                                              "outcomes": {}})
            r["count"] += 1
            r["outcomes"][out] = r["outcomes"].get(out, 0) + 1
            continue
        key = "[%s]:%s" % (host, port) if ":" in host else "%s:%s" % (host, port)
        t = targets.setdefault(key, {"target": key, "streams": 0, "outcomes": {}, "reasons": [], "names": []})
        t["streams"] += 1
        t["outcomes"][out] = t["outcomes"].get(out, 0) + 1
        if st["reason"] and st["reason"] not in t["reasons"]:
            t["reasons"].append(st["reason"])
        for rm in st["remaps"]:
            h, _ = la._split_target(rm)
            if la.ip_or_none(h) is None and la.normalise_name(h) not in t["names"]:
                t["names"].append(la.normalise_name(h))
    return (sorted(targets.values(), key=lambda t: (-t["streams"], t["target"])),
            sorted(resolves.values(), key=lambda r: r["name"]))


def window_queries(lines, start, end):
    """The DNS filter's query-log lines in [start, end), by name: [{"name",
    "types", "decisions": {decision: count}, "queries"}]."""
    names = {}
    for line in lines[start:end]:
        m = la._QUERY_RE.search(line)
        if not m:
            continue
        name = la.normalise_name(la._go_unquote(m.group(1)))
        r = names.setdefault(name, {"name": name, "types": [], "decisions": {}, "queries": 0})
        if m.group(2) not in r["types"]:
            r["types"].append(m.group(2))
        r["decisions"][m.group(3)] = r["decisions"].get(m.group(3), 0) + 1
        r["queries"] += 1
    return sorted(names.values(), key=lambda r: r["name"])


_THREADTIME_RE = re.compile(r"^\d\d-\d\d \d\d:\d\d:\d\d\.\d+\s+(\d+)\s+\d+\s+[VDIWEFS] ")


def scan_logcat(text, package, pids=()):
    """What a logcat slice ('-v threadtime') says about PACKAGE: {"crashed",
    "fatal": [lines], "native_crash", "anr", "died", "gms", "pids"}. "gms"
    is the first line, written by one of the app's processes or naming the
    app, that says Google Play services is missing or unusable; the app's
    processes are PIDS (pidof's) and those ActivityManager started for it
    in the slice."""
    lines = text.splitlines()
    res = {"crashed": False, "fatal": [], "native_crash": False, "anr": False, "died": False, "gms": None}
    pkg = re.escape(package)
    proc_re = re.compile(r"Process: %s(?::\S+)?, PID: \d+" % pkg)
    mine = {str(p) for p in pids if str(p).isdigit()}
    for line in lines:
        m = re.search(r"Start proc (\d+):%s(?::\S+)?/" % pkg, line) or proc_re.search(line)
        if m:
            mine.add(m.group(1) if m.lastindex else re.search(r"PID: (\d+)", line).group(1))
    res["pids"] = sorted(mine, key=int)
    for i, line in enumerate(lines):
        if "FATAL EXCEPTION" in line and any(proc_re.search(x) for x in lines[i + 1:i + 4]):
            res["crashed"] = True
            if not res["fatal"]:
                res["fatal"] = [x.strip() for x in lines[i:i + 6]]
        elif re.search(r"Fatal signal \d+ .*pid \d+ \(%s(?::\S+)?\)" % pkg, line):
            res["crashed"] = res["native_crash"] = True
            if not res["fatal"]:
                res["fatal"] = [line.strip()]
        elif re.search(r"ANR in %s(?::\S+)?\b" % pkg, line):
            res["anr"] = True
        elif re.search(r"Process %s \(pid \d+\) has died" % pkg, line):
            res["died"] = True
        if res["gms"] is None and GMS_RE.search(line):
            m = _THREADTIME_RE.match(line)
            if (m and m.group(1) in mine) or re.search(r"\b%s\b" % pkg, line):
                res["gms"] = " ".join(line.split())[:240]
    return res


# ---------------------------------------------------------------------------
# apps.json and apps.md
# ---------------------------------------------------------------------------

def _read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


def _json(path):
    t = _read(path)
    if t is None:
        return None
    try:
        return json.loads(t)
    except ValueError:
        return None


def _int(x, default=0):
    try:
        return int(float(x))
    except (TypeError, ValueError):
        return default


def _yes(x):
    return str(x).lower() in ("yes", "true", "1", "ok")


def read_records(path):
    out = []
    for line in (_read(path) or "").splitlines():
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if isinstance(r, dict) and r.get("kind") and r.get("name"):
            out.append(r)
    return out


def shrink_screenshots(shots, width):
    """Turns every PNG in SHOTS into a JPEG WIDTH pixels wide (as the Daily
    page embeds them), when ImageMagick's convert is there."""
    if not width or not shutil.which("convert") or not os.path.isdir(shots):
        return
    for name in sorted(os.listdir(shots)):
        if not name.endswith(".png"):
            continue
        src = os.path.join(shots, name)
        dst = src[:-4] + ".jpg"
        r = subprocess.run(["convert", src, "-resize", "%dx>" % width, "-strip", "-quality", "80", dst],
                           capture_output=True)
        if r.returncode == 0 and os.path.getsize(dst) > 0:
            os.remove(src)
        else:
            _rm(dst)


def shot_name(shots, stem):
    """The file a screenshot stem ended up as (JPEG once shrunk), or None."""
    if not stem or stem == "-":
        return None
    for ext in (".jpg", ".png"):
        if os.path.isfile(os.path.join(shots, stem + ext)):
            return stem + ext
    return None


def _store_loaded(item, ui, targets, queries, hosts):
    """A store's catalogue counts as loaded through Tor when its screen
    shows a catalogue (CATALOGUE_TEXTS distinct texts or more, no network
    error), its own names were resolved through Tor, and tor connected the
    phone somewhere in that window."""
    own = [q["name"] for q in queries if any(q["name"] == h or q["name"].endswith("." + h) for h in hosts)
           and any(d.startswith("forwarded") for d in q["decisions"])]
    connected = sum(t["outcomes"].get("SUCCEEDED", 0) for t in targets)
    signals = {"ui_texts": ui["count"], "ui_error": ui["error"], "own_names_through_tor": own[:10],
               "tor_streams_succeeded": connected}
    loaded = ui["count"] >= CATALOGUE_TEXTS and not ui["error"] and bool(own) and connected > 0
    return loaded, signals


def build_item(rec, dl, root, streams, filter_lines):
    """One store's or app's entry in apps.json."""
    shots = os.path.join(root, "screenshots")
    name = rec.get("name")
    package = rec.get("package") or (dl or {}).get("package") or name
    w = {k: _int(rec.get(k), None) for k in ("streams_from", "streams_to", "filter_from", "filter_to")}
    w.update({"start": rec.get("t_start"), "end": rec.get("t_end")})
    if w["streams_from"] is not None and w["streams_to"] is not None:
        targets, resolves = window_streams(streams, w["streams_from"], w["streams_to"])
    else:
        targets, resolves = [], []
    if w["filter_from"] is not None and w["filter_to"] is not None:
        queries = window_queries(filter_lines, w["filter_from"], w["filter_to"])
    else:
        queries = []
    ui = ui_summary(_read(os.path.join(root, rec["ui"])) or "") if rec.get("ui") else ui_summary("")
    # The logcat of a window where the item never ran tells nothing about it.
    ran = rec.get("install") == "ok" and rec.get("logcat")
    lc = scan_logcat(_read(os.path.join(root, rec["logcat"])) or "" if ran else "", package,
                     [rec.get("pid")] if rec.get("pid") else ())
    item = {
        "kind": rec.get("kind"), "name": name, "package": package,
        "label": rec.get("label") or (dl or {}).get("label") or package,
        "store": rec.get("store") or (dl or {}).get("store"),
        "version": (dl or {}).get("version"),
        "download": dl,
        "verified": bool((dl or {}).get("verified")),
        "installed": rec.get("install") == "ok",
        "install": rec.get("install"),
        "install_detail": rec.get("install_detail") or None,
        "launched": rec.get("launch") == "ok",
        "launch_detail": rec.get("launch_detail") or None,
        "focused": _yes(rec.get("focus")),
        "focus_window": rec.get("focus_window") or None,
        "running": _yes(rec.get("running")),
        "pid": rec.get("pid") or None,
        "crashed": lc["crashed"],
        "native_crash": lc["native_crash"],
        "fatal": lc["fatal"],
        "anr": lc["anr"],
        "gms_missing": bool(lc["gms"] or ui["gms"]),
        "gms_line": lc["gms"] or ui["gms"],
        "screenshot": shot_name(shots, rec.get("screenshot")),
        "ui": {"texts": ui["texts"][:40], "count": ui["count"], "error": ui["error"]},
        "taps": [t for t in (rec.get("taps") or "").split("; ") if t],
        "names": queries,
        "blocked": [q["name"] for q in queries if any(d.startswith("blocked") for d in q["decisions"])],
        "servfail": [q["name"] for q in queries if any(d.startswith("servfail") for d in q["decisions"])],
        "tor_targets": targets,
        "tor_resolves": resolves,
        "window": w,
        "seconds": rec.get("seconds"),
        "note": rec.get("note") or None,
    }
    if item["kind"] == "store":
        hosts = next((s["hosts"] for s in STORES if s["name"] == name), ())
        item["loaded"], item["loaded_signals"] = _store_loaded(item, ui, targets, queries, hosts)
        # What the lab's own wait saw before it stopped waiting.
        item["loaded_signals"]["seen_while_waiting"] = _yes(rec.get("loaded_early"))
    item["outcome"] = outcome(item)
    return item


def outcome(item):
    """One short phrase for the table: what became of the item."""
    if item["install"] in (None, "skipped") and not item["installed"]:
        return "not run: " + (item["note"] or (item["download"] or {}).get("error") or "skipped")
    if not item["verified"] and not item["installed"]:
        return "not installed: " + ((item["download"] or {}).get("error") or "not verified")
    if not item["installed"]:
        return "install failed: " + (item["install_detail"] or "?")
    if not item["launched"]:
        return "did not start: " + (item["launch_detail"] or "?")
    words = []
    if item["crashed"]:
        words.append("crashed")
    elif item["anr"]:
        words.append("not responding")
    elif item["running"]:
        words.append("running")
    else:
        words.append("not running at the end")
    if item["kind"] == "store":
        words.append("catalogue loaded" if item.get("loaded") else "catalogue not loaded")
    if item["gms_missing"]:
        words.append("wants Google Play services")
    return ", ".join(words)


def leak_section(analysis):
    if not isinstance(analysis, dict):
        return {"verdict": None, "reasons": ["the leak analysis did not run"]}
    phases = analysis.get("phases") or {}
    post = phases.get("post-arm")
    d = analysis.get("destinations") or {}
    return {
        "verdict": analysis.get("verdict"),
        "reasons": analysis.get("verdict_reasons") or [],
        "packets_after_arm": sum(post.values()) if isinstance(post, dict) else None,
        "packets_to_tor": analysis.get("post_arm_tor_packets"),
        "leak_flows": len(analysis.get("leaks") or []),
        "leaks": [{"kind": f.get("kind"), "dst": f.get("dst"), "dport": f.get("dport"), "proto": f.get("proto"),
                   "names": (f.get("names") or [])[:3], "reason": f.get("reason"),
                   "packets_after_arm": (f.get("phases") or {}).get("post-arm", 0)}
                  for f in (analysis.get("leaks") or [])[:30]],
        "names_through_tor": len(d.get("names") or []),
        "targets_through_tor": len(d.get("targets") or []),
    }


def _events(path):
    out = {}
    for line in (_read(path) or "").splitlines():
        p = line.split("\t")
        if len(p) >= 2:
            try:
                out.setdefault(p[0], (float(p[1]), p[2] if len(p) > 2 else ""))
            except ValueError:
                pass
    return out


def _checks(path):
    out = []
    for line in (_read(path) or "").splitlines():
        p = line.split("\t")
        if len(p) >= 2:
            out.append({"check": p[0], "result": p[1], "detail": p[2] if len(p) > 2 else ""})
    return out


def build(root, run=None, jpeg_width=540, downloads_path=None):
    """apps.json and apps.md (see the module's docstring). DOWNLOADS_PATH:
    the fetch's downloads.json when the scenario did not copy it into
    apps/ (the emulator never got that far)."""
    sdir = os.path.join(root, "apps")
    shrink_screenshots(os.path.join(root, "screenshots"), jpeg_width)
    downloads = _json(os.path.join(sdir, "downloads.json")) or \
        (_json(downloads_path) if downloads_path else None) or {}
    dl = {(i["kind"], i["name"]): i for i in list(downloads.get("stores") or []) + list(downloads.get("apps") or [])}
    streams = stream_records((_read(os.path.join(sdir, "tor-streams.txt")) or "").splitlines())
    filter_lines = (_read(os.path.join(sdir, "dnsfilter.log")) or "").splitlines()
    records = read_records(os.path.join(sdir, "records.jsonl"))
    done = set()
    items = {"store": [], "app": []}
    for rec in records:
        key = (rec["kind"], rec["name"])
        if key in done or rec["kind"] not in items:
            continue
        done.add(key)
        items[rec["kind"]].append(build_item(rec, dl.get(key), root, streams, filter_lines))
    # Downloads the phone never saw (the run ended first).
    for key, d in dl.items():
        if key not in done and key[0] in items:
            items[key[0]].append(build_item({"kind": key[0], "name": key[1], "package": d.get("package"),
                                             "label": d.get("label"), "store": d.get("store"),
                                             "install": "skipped", "note": "the run ended before it"},
                                            d, root, streams, filter_lines))
    ev = _events(os.path.join(sdir, "events.tsv"))
    boot = None
    if "welcome_start" in ev and "tor_bootstrapped" in ev:
        boot = int(ev["tor_bootstrapped"][0] - ev["welcome_start"][0] + 0.5)
    checks = _checks(os.path.join(sdir, "checks.tsv"))
    res = {
        "schema": SCHEMA,
        "run": run,
        "generated": utc_now(),
        "device": _json(os.path.join(sdir, "device.json")) or {},
        "session": {"tor_mode": "direct", "administration": True, "tor_bootstrap_s": boot,
                    "tor_bootstrapped": "tor_bootstrapped" in ev,
                    "checks": {k: sum(1 for c in checks if c["result"] == k) for k in ("ok", "warn", "fail")},
                    "failed_checks": [c for c in checks if c["result"] == "fail"],
                    "home_screenshot": shot_name(os.path.join(root, "screenshots"), "apps-home"),
                    "drawer_screenshot": shot_name(os.path.join(root, "screenshots"), "apps-drawer")},
        "fdroid_index": downloads.get("fdroid_index"),
        "leak": leak_section(_json(os.path.join(sdir, "analysis.json"))),
        "stores": items["store"],
        "apps": items["app"],
    }
    every = res["stores"] + res["apps"]
    res["totals"] = {
        "items": len(every),
        "verified": sum(1 for i in every if i["verified"]),
        "installed": sum(1 for i in every if i["installed"]),
        "running": sum(1 for i in every if i["running"] and not i["crashed"]),
        "crashed": sum(1 for i in every if i["crashed"]),
        "gms_missing": sum(1 for i in every if i["gms_missing"]),
        "stores_loaded": sum(1 for i in res["stores"] if i.get("loaded")),
    }
    with open(os.path.join(root, "apps.json"), "w", encoding="utf-8") as f:
        json.dump(res, f, indent=1, sort_keys=True)
        f.write("\n")
    md = markdown(res)
    with open(os.path.join(root, "apps.md"), "w", encoding="utf-8") as f:
        f.write(md)
    return res, md


VERDICT_WORDS = {"pass": "PASS: nothing left the phone outside Tor",
                 "fail": "FAIL: something left the phone outside Tor",
                 "blind": "COULD NOT JUDGE: a capture was incomplete",
                 "error": "ERROR: the analysis could not read its inputs",
                 None: "not run"}


def _md(s):
    return html.escape(str(s), quote=False).replace("|", "\\|").replace("\n", " ")


def markdown(res):
    L = ["# App lab%s" % (": run %s" % res["run"] if res.get("run") else ""), ""]
    s = res["session"]
    L.append("Real app stores and apps on the CI's virtual phone (Android 16, x86_64) under Antumbra: "
             "Tor directly, Administration on (installs allowed); every APK downloaded on the CI runner "
             "from its store's official source and checked first. Nothing signed in, nothing dialled.")
    L.append("")
    dev = res.get("device") or {}
    if dev:
        L.append("- Phone: %s, ABIs %s, %s MB of memory, %s MB free for apps." % (
            dev.get("model") or "?", dev.get("abilist") or "?", dev.get("mem_mb") or "?", dev.get("data_free_mb") or "?"))
    L.append("- Tor: %s." % ("connected in %s s" % s["tor_bootstrap_s"] if s.get("tor_bootstrap_s") is not None
                             else ("connected" if s.get("tor_bootstrapped") else "**did not connect**")))
    lk = res["leak"]
    v = VERDICT_WORDS.get(lk.get("verdict"), lk.get("verdict"))
    if lk.get("packets_after_arm") is not None:
        L.append("- Leak test over the whole run: **%s** (%s packets after the firewall went on, %s to the Tor "
                 "network, %s leak flow(s))." % (v, lk["packets_after_arm"], lk.get("packets_to_tor"),
                                                lk.get("leak_flows")))
    else:
        L.append("- Leak test over the whole run: **%s**%s." % (v, (": " + "; ".join(lk.get("reasons") or []))
                                                              if lk.get("reasons") else ""))
    t = res["totals"]
    L.append("- %d item(s): %d verified, %d installed, %d running at the end, %d crashed, %d asked for Google "
             "Play services; %d of %d store(s) loaded their catalogue." % (
                 t["items"], t["verified"], t["installed"], t["running"], t["crashed"], t["gms_missing"],
                 t["stores_loaded"], len(res["stores"])))
    L.append("")
    L.append("| Store / app | Installed | Ran | Names looked up | Blocked | Tor destinations | Screenshot |")
    L.append("|---|---|---|---|---|---|---|")
    for i in res["stores"] + res["apps"]:
        what = "%s (%s)" % (i["label"], "store" if i["kind"] == "store" else i.get("store") or "?")
        L.append("| %s | %s | %s | %d | %d | %d | %s |" % (
            _md(what), "yes" if i["installed"] else "no", _md(i["outcome"]), len(i["names"]),
            len(i["blocked"]), len(i["tor_targets"]), "`%s`" % i["screenshot"] if i["screenshot"] else "-"))
    L.append("")
    notes = []
    for i in res["stores"] + res["apps"]:
        d = i["download"] or {}
        if i["fatal"]:
            notes.append("%s crashed: `%s`" % (i["label"], _md(" / ".join(i["fatal"][:3])[:300])))
        if i["gms_line"]:
            notes.append("%s and Google Play services: `%s`" % (i["label"], _md(i["gms_line"][:200])))
        if i["blocked"]:
            notes.append("%s: names blocked by the tracker filter: %s" % (
                i["label"], ", ".join("`%s`" % n for n in i["blocked"][:12])))
        if d.get("notes"):
            notes.append("%s: %s" % (i["label"], _md("; ".join(d["notes"]))))
    if notes:
        L.append("**Notes:**")
        L.append("")
        L.extend("- " + n for n in notes[:60])
        L.append("")
    if lk.get("leaks"):
        L.append("**Leak flows** (anything not to the Tor network after the firewall went on):")
        L.append("")
        for f in lk["leaks"][:20]:
            L.append("- %s %s:%s %s (%s packet(s)): %s" % (f.get("kind"), f.get("dst"), f.get("dport"),
                                                         ", ".join(f.get("names") or []),
                                                         f.get("packets_after_arm"), _md(f.get("reason"))))
        L.append("")
    if s.get("failed_checks"):
        L.append("**Session checks that failed:** " + "; ".join(
            "%s (%s)" % (c["check"], _md(c["detail"][:120])) for c in s["failed_checks"][:10]))
        L.append("")
    L.append("In the artifact: `apps.json` (every field, the downloads' checks, each window's names and Tor "
             "destinations), `screenshots/`, `logs/apps/` (each item's logcat and screen), `leak-report.md`, "
             "`capture/`.")
    return "\n".join(L) + "\n"


# ---------------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("catalogue")
    c.add_argument("file")
    fp = sub.add_parser("fdroid-pick")
    fp.add_argument("--index", required=True)
    fp.add_argument("package")
    fp.add_argument("--abi", action="append")
    fp.add_argument("--sdk", type=int, default=36)
    apk = sub.add_parser("aptoide-pick")
    apk.add_argument("--meta", required=True)
    f = sub.add_parser("fetch")
    f.add_argument("--catalogue", required=True)
    f.add_argument("--out", required=True)
    f.add_argument("--apksigner")
    f.add_argument("--aapt2")
    f.add_argument("--abi", action="append")
    f.add_argument("--sdk", type=int, default=36)
    f.add_argument("--stores", default="fdroid,aptoide,taptap")
    f.add_argument("--budget", type=int, default=0, help="seconds for all the downloads (0: no limit)")
    p = sub.add_parser("plan")
    p.add_argument("downloads")
    sub.add_parser("ui-summary")
    b = sub.add_parser("build")
    b.add_argument("root")
    b.add_argument("--run")
    b.add_argument("--jpeg-width", type=int, default=540)
    b.add_argument("--downloads")
    a = ap.parse_args(argv)

    if a.cmd == "catalogue":
        try:
            entries = parse_catalogue(_read(a.file) or "")
        except ValueError as e:
            print("applab: %s: %s" % (a.file, e), file=sys.stderr)
            return 1
        for e in entries:
            print(json.dumps(e, sort_keys=True))
        return 0
    if a.cmd == "fdroid-pick":
        try:
            print(json.dumps(fdroid_pick(_json(a.index) or {}, a.package, a.abi or ["x86_64"], a.sdk),
                             indent=1, sort_keys=True))
        except LookupError as e:
            print("applab: %s" % e, file=sys.stderr)
            return 1
        return 0
    if a.cmd == "aptoide-pick":
        try:
            print(json.dumps(aptoide_pick(_json(a.meta) or {}), indent=1, sort_keys=True))
        except LookupError as e:
            print("applab: %s" % e, file=sys.stderr)
            return 1
        return 0
    if a.cmd == "fetch":
        try:
            entries = parse_catalogue(_read(a.catalogue) or "")
        except ValueError as e:
            print("applab: %s: %s" % (a.catalogue, e), file=sys.stderr)
            return 1
        for tool in (a.apksigner, a.aapt2):
            if tool and not os.access(tool, os.X_OK):
                print("applab: %s is not an executable" % tool, file=sys.stderr)
                return 1
        stores = tuple(s for s in a.stores.split(",") if s)
        res = fetch(entries, a.out, Tools(a.apksigner, a.aapt2, budget=a.budget or None),
                    tuple(a.abi or ["x86_64"]), a.sdk, stores)
        every = res["stores"] + res["apps"]
        print("applab: %d of %d verified" % (sum(1 for i in every if i["verified"]), len(every)), file=sys.stderr)
        return 0
    if a.cmd == "plan":
        d = _json(a.downloads)
        if not isinstance(d, dict):
            print("applab: cannot read %s" % a.downloads, file=sys.stderr)
            return 1
        for line in plan_lines(d, os.path.dirname(os.path.abspath(a.downloads))):
            print(line)
        return 0
    if a.cmd == "ui-summary":
        s = ui_summary(sys.stdin.read())
        dx, dy, dt = s["dismiss"] if s["dismiss"] else ("-", "-", "-")
        print("\t".join(_one_line(str(x)) for x in (s["count"], dx, dy, dt, s["error"] or "-")))
        return 0
    if a.cmd == "build":
        _, md = build(a.root, a.run, a.jpeg_width, a.downloads)
        sys.stdout.write(md)
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
