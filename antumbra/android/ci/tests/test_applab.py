# SPDX-License-Identifier: GPL-3.0-or-later
"""Unit tests for applab.py, the app lab's helper. The F-Droid index, the
Aptoide answers and the apksigner and aapt2 output under fixtures/applab/
were recorded from the real services in October 2026 and trimmed, and
tor-streams-run10.txt holds lines of tor's STREAM events from CI run 10;
nothing here touches the network (downloads go through a fake), and the
APKs are a few bytes each.

Run: python3 -B -m unittest discover -s antumbra/android/ci/tests -p 'test_applab.py' -v
"""

import contextlib
import copy
import hashlib
import io
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

sys.dont_write_bytecode = True
CI = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, CI)

import applab  # noqa: E402

FIX = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "applab")
HAVE_CONVERT = bool(shutil.which("convert"))


def fixture(name):
    with open(os.path.join(FIX, name), encoding="utf-8") as f:
        return f.read()


def fixture_json(name):
    return json.loads(fixture(name))


def sha256(b):
    return hashlib.sha256(b).hexdigest()


def md5(b):
    return hashlib.md5(b).hexdigest()


def png(path, w=60, h=120):
    raw = b"".join(b"\x00" + bytes((20, 120, 200)) * w for _ in range(h))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


class TestCatalogue(unittest.TestCase):
    def test_the_repository_catalogue(self):
        with open(os.path.join(CI, "app-lab.txt"), encoding="utf-8") as f:
            entries = applab.parse_catalogue(f.read())
        self.assertGreaterEqual(len(entries), 8)
        self.assertEqual({e["store"] for e in entries}, {"fdroid", "aptoide"})
        self.assertIn({"store": "fdroid", "package": "org.schabi.newpipe", "label": "NewPipe"}, entries)
        self.assertIn({"store": "aptoide", "package": "com.whatsapp", "label": "WhatsApp"}, entries)

    def test_comments_and_blank_lines(self):
        e = applab.parse_catalogue("# head\n\nfdroid\torg.example.app\tExample  # why\n")
        self.assertEqual(e, [{"store": "fdroid", "package": "org.example.app", "label": "Example"}])

    def test_bad_lines(self):
        for text, word in (("playstore\tcom.x.y\tX\n", "unknown store"),
                           ("fdroid\tnot a package\tX\n", "not a package"),
                           ("fdroid\tcom.x.y\n", "want"),
                           ("fdroid com.x.y X\n", "want"),
                           ("fdroid\tcom.x.y\tX\naptoide\tcom.x.y\tY\n", "twice")):
            with self.assertRaises(ValueError) as cm:
                applab.parse_catalogue(text)
            self.assertIn(word, str(cm.exception))

    def test_cli(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "c.txt")
            with open(p, "w") as f:
                f.write("aptoide\tcom.whatsapp\tWhatsApp\n")
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(applab.main(["catalogue", p]), 0)
            self.assertEqual(json.loads(out.getvalue())["package"], "com.whatsapp")
            with open(p, "w") as f:
                f.write("aptoide\tcom.whatsapp\n")
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(applab.main(["catalogue", p]), 1)


class TestFDroidIndex(unittest.TestCase):
    def setUp(self):
        self.index = fixture_json("fdroid-index-v2.json")

    def test_stable_version_not_beta(self):
        # The client's 2.0.x releases are in the Beta channel; 1.23.2 is the
        # stable one the client would suggest.
        p = applab.fdroid_pick(self.index, "org.fdroid.fdroid")
        self.assertEqual((p["version"], p["version_code"]), ("1.23.2", 1023052))
        self.assertEqual(p["url"], "https://f-droid.org/repo/org.fdroid.fdroid_1023052.apk")
        self.assertEqual(p["signers"], [applab.FDROID_SIGNER])
        self.assertEqual(p["sha256"], "985f5181d48bb6bafd54083a048b391271e0ab28385881cc41294fb01a222762")

    def test_preferred_signer(self):
        # NewPipe is published twice per version: built by F-Droid and as
        # upstream's reproducible build; the preferred signer wins.
        p = applab.fdroid_pick(self.index, "org.schabi.newpipe")
        self.assertEqual(p["version_code"], 1015)
        self.assertTrue(p["url"].endswith("_cb84069.apk"))
        self.assertTrue(p["signers"][0].startswith("cb84069bd681"))

    def test_abi(self):
        p = applab.fdroid_pick(self.index, "im.vector.app", ("x86_64",))
        self.assertEqual(p["nativecode"], ["x86_64"])
        q = applab.fdroid_pick(self.index, "im.vector.app", ("arm64-v8a",))
        self.assertEqual(q["nativecode"], ["arm64-v8a"])
        self.assertNotEqual(p["sha256"], q["sha256"])

    def test_no_native_code_fits_any_abi(self):
        p = applab.fdroid_pick(self.index, "com.github.libretube", ("x86_64",))
        self.assertEqual(p["nativecode"], [])

    def test_sdk(self):
        with self.assertRaises(LookupError):
            applab.fdroid_pick(self.index, "app.organicmaps", sdk=20)

    def test_mirrors_https_only(self):
        p = applab.fdroid_pick(self.index, "app.organicmaps")
        self.assertTrue(p["mirrors"])
        self.assertTrue(all(m.startswith("https://") and "f-droid.org" not in m for m in p["mirrors"]))
        self.assertTrue(all(m.endswith(p["url"].rsplit("/", 1)[1]) for m in p["mirrors"]))

    def test_only_beta(self):
        with self.assertRaises(LookupError) as cm:
            applab.fdroid_pick(self.index, "net.osmand.plus")
        self.assertIn("no stable version", str(cm.exception))

    def test_missing(self):
        with self.assertRaises(LookupError):
            applab.fdroid_pick(self.index, "org.telegram.messenger")

    def test_version_by_sha256(self):
        # f-droid.org/F-Droid.apk was 2.0.1 (Beta channel) in October 2026.
        v = applab.fdroid_version_by_sha256(
            self.index, "org.fdroid.fdroid", "83d3fe522281c3cb89fce3bc05038f81b3c3b32c108536941f184c5f9bb53778")
        self.assertEqual(v["version"], "2.0.1")
        self.assertEqual(v["release_channels"], ["Beta"])
        self.assertEqual(v["signers"], [applab.FDROID_SIGNER])
        self.assertIsNone(applab.fdroid_version_by_sha256(self.index, "org.fdroid.fdroid", "00" * 32))

    def test_cli(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = applab.main(["fdroid-pick", "--index", os.path.join(FIX, "fdroid-index-v2.json"),
                              "app.organicmaps", "--abi", "x86_64"])
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(out.getvalue())["package"], "app.organicmaps")


class TestAptoide(unittest.TestCase):
    def test_pick(self):
        p = applab.aptoide_pick(fixture_json("aptoide-getmeta-whatsapp.json"))
        self.assertEqual(p["package"], "com.whatsapp")
        self.assertEqual(p["md5"], "eed17f28a633f93ebbf548f389cece72")
        self.assertEqual(p["size"], 148660262)
        self.assertEqual(p["signer_sha1"], "8b0debf9516af037c9be2f539584b97fe9781764")
        self.assertEqual(p["rank"], "TRUSTED")
        self.assertTrue(p["url"].startswith("https://pool.apk.aptoide.com/"))
        self.assertIsNone(p["url_alt"])  # the same as path
        self.assertIn("x86-64", p["cpus"])
        self.assertEqual((p["obb"], p["splits"]), (False, 0))

    def test_not_found(self):
        with self.assertRaises(LookupError) as cm:
            applab.aptoide_pick(fixture_json("aptoide-getmeta-notfound.json"))
        self.assertIn("APP-1", str(cm.exception))

    def test_splits_and_obb(self):
        m = fixture_json("aptoide-getmeta-whatsapp.json")
        m["data"]["aab"] = {"required_split_types": ["abi"], "splits": [{"name": "config.x86_64"}]}
        m["data"]["obb"] = {"main": {"filename": "main.1.com.whatsapp.obb"}}
        p = applab.aptoide_pick(m)
        self.assertEqual((p["obb"], p["splits"]), (True, 1))

    def test_meta_url(self):
        self.assertEqual(applab.aptoide_meta_url("cm.aptoide.pt", "aptoide-web"),
                         "https://ws75.aptoide.com/api/7/app/getMeta?package_name=cm.aptoide.pt"
                         "&store_name=aptoide-web")


class TestTools(unittest.TestCase):
    def test_apksigner_with_key_rotation(self):
        # WhatsApp rotated its key with APK Signature Scheme v3.1: both
        # certificates count, the old one from the lineage too.
        s = applab.parse_apksigner(fixture("apksigner-whatsapp.txt"))
        self.assertTrue(s["verifies"])
        self.assertIn("v3.1", s["schemes"])
        self.assertEqual(set(s["sha256"]), {
            "fb920d381bee1b2093f27dc8f13d994da629dc91887d0529b35c9a2dc4f4a6c2",
            "3987d043d10aefaf5a8710b3671418fe57e0e19b653c9df82558feb5ffce5d44"})
        self.assertIn("8b0debf9516af037c9be2f539584b97fe9781764", s["sha1"])
        self.assertIn("38a0f7d505fe18fec64fbf343ecaaaf310dbd799", s["sha1"])
        self.assertTrue(any("WhatsApp LLC" in d for d in s["dn"]))
        # Public key digests are not certificates.
        self.assertNotIn("da20616489af7f02458b5e488c3fcf7f51f7cce20360a7b7da978d23666bf660", s["sha256"])

    def test_apksigner_failure(self):
        s = applab.parse_apksigner("DOES NOT VERIFY\nERROR: APK Signature Scheme v2 signer #1: Malformed\n")
        self.assertFalse(s["verifies"])
        self.assertEqual(s["sha256"], [])

    def test_badging(self):
        b = applab.parse_badging(fixture("aapt2-badging-whatsapp.txt"))
        self.assertEqual(b["package"], "com.whatsapp")
        self.assertEqual(b["version"], "2.26.39.71")
        self.assertEqual(b["min_sdk"], "23")
        self.assertIn("x86_64", b["native_code"])


# --- fetch, with a fake network and fake tools --------------------------------

CLIENT = b"F-Droid client APK"
NEWPIPE = b"NewPipe APK"
APTOIDE = b"Aptoide client APK"
WHATSAPP = b"WhatsApp APK"
TAPTAP = b"TapTap APK"
CERT = {CLIENT: (applab.FDROID_SIGNER, "05f2e65928088981b317fc9a6dbfe04b0fa13b4e"),
        NEWPIPE: ("cb84069bd68116bafae5ee4ee5b08a567aa6d898404e7cb12f9e756df5cf5cab", "aa" * 20),
        APTOIDE: ("73534d45c1345a4783c7eff2cf6038551ab5fdf09673f32c68c3b0864baa80e4",
                  "d590a7d792fd0331542d99faf9997641790773a9"),
        WHATSAPP: ("fb920d381bee1b2093f27dc8f13d994da629dc91887d0529b35c9a2dc4f4a6c2",
                   "8b0debf9516af037c9be2f539584b97fe9781764"),
        TAPTAP: ("5e" * 32, "a999c3230000000000000000000000000000beef")}
PACKAGE = {CLIENT: "org.fdroid.fdroid", NEWPIPE: "org.schabi.newpipe", APTOIDE: "cm.aptoide.pt",
           WHATSAPP: "com.whatsapp", TAPTAP: "com.taptap.global"}


def synthetic_index():
    """The recorded index, with the client's and NewPipe's files replaced by
    the few bytes the fake network serves."""
    idx = fixture_json("fdroid-index-v2.json")
    for v in idx["packages"]["org.fdroid.fdroid"]["versions"].values():
        if v["manifest"]["versionCode"] == 2000051:
            v["file"]["sha256"] = sha256(CLIENT)
    for v in idx["packages"]["org.schabi.newpipe"]["versions"].values():
        if v["manifest"]["versionCode"] == 1015 and v["file"]["name"].endswith("_cb84069.apk"):
            v["file"]["sha256"] = sha256(NEWPIPE)
            v["file"]["size"] = len(NEWPIPE)
    return idx


def getmeta(package, store, blob, sha1, path):
    m = fixture_json("aptoide-getmeta-whatsapp.json")
    d = m["data"]
    d["package"], d["store"]["name"] = package, store
    d["file"].update({"md5sum": md5(blob), "filesize": len(blob), "path": path, "path_alt": path,
                      "signature": {"sha1": ":".join(sha1[i:i + 2].upper() for i in range(0, 40, 2)),
                                    "owner": "CN=Test"}})
    return m


class FakeCurl:
    """curl's runs for curl_download: each answer is (exit code, HTTP code)."""

    def __init__(self, answers):
        self.answers = list(answers)
        self.cmds = []

    def __call__(self, cmd, capture_output=True, text=True, timeout=None):
        self.cmds.append(cmd)
        rc, code = self.answers.pop(0)
        with open(cmd[cmd.index("-o") + 1], "wb") as f:
            f.write(b"apk")
        return subprocess.CompletedProcess(cmd, rc, "%s %s" % (code, cmd[-1]), "curl: (%d) failed" % rc if rc else "")


class TestCurl(unittest.TestCase):
    URL = "https://example.org/x.apk"

    def get(self, answers, max_time=600):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        fake, slept = FakeCurl(answers), []
        dest = os.path.join(tmp.name, "x.apk")
        res = applab.curl_download(self.URL, dest, max_time, run=fake, sleep=slept.append)
        return res, fake, slept, dest

    def test_options(self):
        (url, err), fake, _, dest = self.get([(0, "200")])
        self.assertEqual((url, err), (self.URL, None))
        self.assertTrue(os.path.isfile(dest))
        cmd = fake.cmds[0]
        for opt, value in (("--proto", "=https"), ("--proto-redir", "=https"), ("--max-time", "600"),
                           ("--speed-limit", "51200"), ("--speed-time", "60")):
            self.assertEqual(cmd[cmd.index(opt) + 1], value, opt)
        self.assertFalse([c for c in cmd if c.startswith("--retry")])

    def test_too_slow_is_given_up_at_once(self):
        # curl's exit 28 (slower than 50 KB/s for a minute, or out of time):
        # the caller tries the next URL instead.
        (url, err), fake, slept, dest = self.get([(28, "200")])
        self.assertIsNone(url)
        self.assertIn("curl exit 28", err)
        self.assertEqual((len(fake.cmds), slept), (1, []))
        self.assertFalse(os.path.exists(dest) or os.path.exists(dest + ".part"))

    def test_broken_connections_and_5xx_are_tried_again(self):
        (url, err), fake, slept, dest = self.get([(56, "000"), (0, "503"), (0, "200")])
        self.assertEqual((url, err), (self.URL, None))
        self.assertEqual((len(fake.cmds), slept), (3, [5, 5]))
        (url, err), fake, _, dest = self.get([(7, "000")] * 3)
        self.assertIsNone(url)
        self.assertEqual(len(fake.cmds), 3)
        self.assertIn("(try 3)", err)
        self.assertFalse(os.path.exists(dest))

    def test_not_found_is_not_tried_again(self):
        (url, err), fake, _, _ = self.get([(0, "404")])
        self.assertEqual((url, err, len(fake.cmds)), (None, "HTTP 404", 1))


class FakeNet:
    """URL -> bytes; anything else answers 404. Records what was asked."""

    def __init__(self, pages):
        self.pages = pages
        self.asked = []

    def __call__(self, url, dest, max_time=0, compressed=False):
        self.asked.append(url)
        if url not in self.pages:
            return None, "HTTP 404"
        body = self.pages[url]
        if not isinstance(body, bytes):
            body = json.dumps(body).encode()
        with open(dest, "wb") as f:
            f.write(body)
        return url, None


class FakeTools(applab.Tools):
    def __init__(self, net, certs=CERT):
        super().__init__("apksigner", "aapt2", net)
        self.certs = certs

    def _blob(self, apk):
        with open(apk, "rb") as f:
            return f.read()

    def signers(self, apk):
        sha, sha1 = self.certs.get(self._blob(apk), ("", ""))
        return {"verifies": bool(sha), "sha256": [sha] if sha else [], "sha1": [sha1] if sha1 else [],
                "schemes": ["v2"], "dn": []}

    def badging(self, apk):
        return {"package": PACKAGE.get(self._blob(apk)), "version": "1", "version_code": "1", "min_sdk": "21",
                "native_code": []}


def pages(index=None):
    idx = index or synthetic_index()
    blob = json.dumps(idx).encode()
    newpipe = applab.fdroid_pick(idx, "org.schabi.newpipe")
    wa_path = "https://pool.apk.aptoide.com/store/com-whatsapp.apk"
    ap_path = "https://pool.apk.aptoide.com/aptoide-web/cm-aptoide-pt.apk"
    return {
        applab.FDROID_ENTRY: {"index": {"name": "/index-v2.json", "sha256": sha256(blob)}},
        applab.FDROID_REPO + "/index-v2.json": blob,
        applab.FDROID_CLIENT_URL: CLIENT,
        newpipe["url"]: NEWPIPE,
        applab.aptoide_meta_url("cm.aptoide.pt", applab.APTOIDE_CLIENT_STORE):
            getmeta("cm.aptoide.pt", "aptoide-web", APTOIDE, CERT[APTOIDE][1], ap_path),
        ap_path: APTOIDE,
        applab.aptoide_meta_url("com.whatsapp"): getmeta("com.whatsapp", "apps", WHATSAPP, CERT[WHATSAPP][1], wa_path),
        wa_path: WHATSAPP,
        applab.TAPTAP_URL: TAPTAP,
        applab.aptoide_meta_url("com.taptap.global"):
            getmeta("com.taptap.global", "x", b"other", CERT[TAPTAP][1], "https://pool.apk.aptoide.com/x.apk"),
    }


CAT = [{"store": "fdroid", "package": "org.schabi.newpipe", "label": "NewPipe"},
       {"store": "aptoide", "package": "com.whatsapp", "label": "WhatsApp"},
       {"store": "aptoide", "package": "org.telegram.messenger", "label": "Telegram"}]


def items_error(res, name):
    return [i for i in res["stores"] + res["apps"] if i["name"] == name][0]["error"]


class TestFetch(unittest.TestCase):
    def run_fetch(self, net, cat=CAT, certs=CERT):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        with contextlib.redirect_stderr(io.StringIO()):
            res = applab.fetch(cat, self.tmp.name, FakeTools(net, certs))
        items = {i["name"]: i for i in res["stores"] + res["apps"]}
        return res, items

    def test_everything_verified(self):
        res, items = self.run_fetch(FakeNet(pages()))
        self.assertTrue(res["fdroid_index"]["ok"])
        for name in ("fdroid", "aptoide", "taptap", "org.schabi.newpipe", "com.whatsapp"):
            self.assertTrue(items[name]["verified"], (name, items[name]["error"], items[name]["checks"]))
            self.assertTrue(os.path.isfile(os.path.join(self.tmp.name, items[name]["file"])))
        self.assertEqual(items["fdroid"]["version"], "2.0.1")
        self.assertIn("Beta", items["fdroid"]["expected"]["how"])
        self.assertEqual(items["fdroid"]["sha256"], sha256(CLIENT))
        self.assertEqual(items["com.whatsapp"]["md5"], md5(WHATSAPP))
        self.assertEqual(items["com.whatsapp"]["store_name"], "apps")
        self.assertIn("certificate is the one Aptoide lists for com.taptap.global",
                      "; ".join(items["taptap"]["notes"]))
        # Telegram: Aptoide has no such app; recorded, not fatal.
        self.assertFalse(items["org.telegram.messenger"]["verified"])
        self.assertIn("404", items["org.telegram.messenger"]["error"])
        with open(os.path.join(self.tmp.name, "downloads.json")) as f:
            self.assertEqual(json.load(f)["schema"], applab.SCHEMA)

    def test_plan(self):
        res, _ = self.run_fetch(FakeNet(pages()))
        lines = [ln.split("\t") for ln in applab.plan_lines(res, "/dl")]
        self.assertEqual([ln[1] for ln in lines], ["fdroid", "aptoide", "taptap", "org.schabi.newpipe",
                                                    "com.whatsapp", "org.telegram.messenger"])
        self.assertTrue(all(len(ln) == 7 for ln in lines))
        self.assertEqual(lines[0][:6], ["store", "fdroid", "org.fdroid.fdroid", "F-Droid", "1", "/dl/stores/fdroid.apk"])
        self.assertEqual(lines[-1][4:6], ["0", "-"])

    def test_wrong_bytes_are_not_installed(self):
        p = pages()
        p[applab.FDROID_CLIENT_URL] = b"something else"
        newpipe = applab.fdroid_pick(synthetic_index(), "org.schabi.newpipe")
        p[newpipe["url"]] = b"tampered"
        p["https://pool.apk.aptoide.com/store/com-whatsapp.apk"] = b"tampered too"
        _, items = self.run_fetch(FakeNet(p))
        for name, word in (("fdroid", "index lists"), ("org.schabi.newpipe", "SHA-256"),
                           ("com.whatsapp", "MD5")):
            self.assertFalse(items[name]["verified"], name)
            self.assertIn("not verified", items[name]["error"])
            self.assertIn(word, items[name]["error"])

    def test_wrong_certificate(self):
        certs = dict(CERT)
        certs[CLIENT] = ("ab" * 32, "cd" * 20)
        certs[WHATSAPP] = ("ab" * 32, "cd" * 20)
        _, items = self.run_fetch(FakeNet(pages()), certs=certs)
        self.assertFalse(items["fdroid"]["verified"])
        self.assertIn("pinned certificate", items["fdroid"]["error"])
        self.assertFalse(items["com.whatsapp"]["verified"])
        self.assertIn("SHA-1", items["com.whatsapp"]["error"])

    def test_index_not_matching_entry(self):
        p = pages()
        p[applab.FDROID_ENTRY] = {"index": {"name": "/index-v2.json", "sha256": "00" * 32}}
        res, items = self.run_fetch(FakeNet(p))
        self.assertFalse(res["fdroid_index"]["ok"])
        self.assertIn("entry.json", res["fdroid_index"]["error"])
        self.assertFalse(items["fdroid"]["verified"])
        self.assertFalse(items["org.schabi.newpipe"]["verified"])
        self.assertTrue(items["com.whatsapp"]["verified"])

    def test_mirror_after_a_failure(self):
        p = pages()
        newpipe = applab.fdroid_pick(synthetic_index(), "org.schabi.newpipe")
        del p[newpipe["url"]]
        p[newpipe["mirrors"][0]] = NEWPIPE
        net = FakeNet(p)
        _, items = self.run_fetch(net)
        self.assertTrue(items["org.schabi.newpipe"]["verified"])
        self.assertEqual(items["org.schabi.newpipe"]["url"], newpipe["mirrors"][0])

    def test_untrusted_rank(self):
        p = pages()
        p[applab.aptoide_meta_url("com.whatsapp")]["data"]["file"]["malware"]["rank"] = "UNKNOWN"
        _, items = self.run_fetch(FakeNet(p))
        self.assertFalse(items["com.whatsapp"]["verified"])
        self.assertIn("TRUSTED", items["com.whatsapp"]["error"])

    def test_time_budget(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        net = FakeNet(pages())
        tools = FakeTools(net)
        tools.budget, tools.deadline = 60, 0.0  # long gone
        with contextlib.redirect_stderr(io.StringIO()):
            res = applab.fetch(CAT, self.tmp.name, tools)
        self.assertEqual(net.asked, [])
        every = res["stores"] + res["apps"]
        self.assertEqual(len(every), 6)
        self.assertTrue(all(not i["verified"] for i in every))
        self.assertIn("time budget (60 s) ran out", items_error(res, "com.whatsapp"))
        with open(os.path.join(self.tmp.name, "downloads.json")) as f:
            self.assertIn("done", json.load(f))

    def test_nothing_verified_without_apksigner_and_aapt2(self):
        # Even with the right bytes (SHA-256, MD5 and size as listed), an APK
        # that apksigner and aapt2 did not look at is never installed.
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        with contextlib.redirect_stderr(io.StringIO()):
            res = applab.fetch(CAT, self.tmp.name, applab.Tools(None, None, FakeNet(pages())))
        items = {i["name"]: i for i in res["stores"] + res["apps"]}
        for name in ("fdroid", "aptoide", "taptap", "org.schabi.newpipe", "com.whatsapp"):
            self.assertFalse(items[name]["verified"], name)
            self.assertIn("apksigner did not run", items[name]["error"])
            self.assertIn("aapt2 did not run", items[name]["error"])
        self.assertIn({"check": "its MD5 is the one Aptoide lists", "ok": True}, items["com.whatsapp"]["checks"])
        self.assertEqual({ln.split("\t")[4] for ln in applab.plan_lines(res, "/dl")}, {"0"})

    def test_cli_needs_apksigner_and_aapt2(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        err = io.StringIO()
        with contextlib.redirect_stderr(err), self.assertRaises(SystemExit):
            applab.main(["fetch", "--catalogue", os.path.join(CI, "app-lab.txt"), "--out", tmp.name])
        self.assertIn("--apksigner", err.getvalue())
        self.assertEqual(os.listdir(tmp.name), [])

    def test_split_apks_skipped(self):
        p = pages()
        p[applab.aptoide_meta_url("com.whatsapp")]["data"]["aab"] = {"splits": [{"name": "a"}, {"name": "b"}]}
        net = FakeNet(p)
        _, items = self.run_fetch(net)
        self.assertIn("split APKs only", items["com.whatsapp"]["error"])
        self.assertNotIn("https://pool.apk.aptoide.com/store/com-whatsapp.apk", net.asked)


# --- The screen, the logs and apps.json ---------------------------------------

def node(text="", desc="", bounds="[0,0][100,50]", rid="", enabled="true"):
    return ('<node text="%s" content-desc="%s" bounds="%s" resource-id="%s" enabled="%s" />'
            % (text, desc, bounds, rid, enabled))


def dump(*nodes):
    return '<?xml version="1.0"?><hierarchy rotation="0">%s</hierarchy>' % "".join(nodes)


class TestUiSummary(unittest.TestCase):
    def test_dismiss_only_safe_buttons(self):
        for label, want in (("Skip", True), ("Not now", True), ("Don’t allow", True), ("Don't allow", True),
                            ("No thanks", True), ("Sign in", False), ("Log in", False), ("Allow", False),
                            ("Agree and continue", False), ("Continue", False), ("Accept", False)):
            s = applab.ui_summary(dump(node("Welcome"), node(label, bounds="[10,20][30,40]")))
            self.assertEqual(s["dismiss"] is not None, want, label)
            if want:
                self.assertEqual(s["dismiss"][:2], (20, 30))

    def test_disabled_button_is_not_pressed(self):
        s = applab.ui_summary(dump(node("Skip", enabled="false")))
        self.assertIsNone(s["dismiss"])

    def test_counts_and_errors(self):
        s = applab.ui_summary(dump(*[node("App %d" % i) for i in range(14)] + [node(desc="App 3"), node("")]))
        self.assertEqual(s["count"], 14)
        self.assertIsNone(s["error"])
        s = applab.ui_summary(dump(node("Couldn't connect. Check your connection"), node("Retry")))
        self.assertIsNotNone(s["error"])
        s = applab.ui_summary(dump(node("This app won't run without Google Play services")))
        self.assertIn("Google Play services", s["gms"])

    def test_broken_xml(self):
        self.assertEqual(applab.ui_summary("ERROR: could not get idle state.")["count"], 0)

    def test_cli(self):
        out = io.StringIO()
        old = sys.stdin
        sys.stdin = io.StringIO(dump(node("Skip", bounds="[0,0][10,10]")))
        try:
            with contextlib.redirect_stdout(out):
                self.assertEqual(applab.main(["ui-summary"]), 0)
        finally:
            sys.stdin = old
        self.assertEqual(out.getvalue(), "1\t5\t5\tSkip\t-\n")


# tor's STREAM events as the module's tor sends them: lines of run 10's
# ANTUMBRA transcript (antumbra/tor-streams.txt), verbatim, picked and put
# in order for two windows. Lines 3..16 (an F-Droid window): a DNSPort
# lookup (NEWRESOLVE, SENTRESOLVE, REMAP to its address, CLOSED DONE),
# tor's own directory fetch (the only kind that gets SUCCEEDED), a
# TransPort connection that worked (NEW, SENTCONNECT, REMAP SOURCE=EXIT,
# CLOSED END/DONE: no SUCCEEDED) and one tor refused (CLOSED PRIVATE_ADDR).
# Lines 17..30 (a WhatsApp window): a directory fetch that timed out, a
# lookup, a connection, another refusal, and a lookup still open at the end.
STREAMS = fixture("tor-streams-run10.txt")

# The filter's query log. "servfail (timeout)" is the filter's own failure
# (run 10 has it); "servfail (rcode RCodeServerFailure)" is how it logs
# tor's SERVFAIL, and "forwarded nxdomain" tor's "no such name".
FILTER = """antumbra-dnsfilter: 2026/10/12 06:38:00 debug mode: query names will be logged
antumbra-dnsfilter: 2026/10/12 06:38:19 query "f-droid.org." A -> forwarded
antumbra-dnsfilter: 2026/10/12 06:38:19 query "F-Droid.org." AAAA -> empty (type)
antumbra-dnsfilter: 2026/10/12 06:38:20 query "doubleclick.net." A -> blocked
antumbra-dnsfilter: 2026/10/12 06:38:21 query "nosuch.f-droid.org." A -> forwarded nxdomain
antumbra-dnsfilter: 2026/10/12 06:39:00 query "g.whatsapp.net." A -> forwarded
antumbra-dnsfilter: 2026/10/12 06:39:01 query "graph.facebook.com." A -> servfail (timeout)
antumbra-dnsfilter: 2026/10/12 06:39:02 query "app-measurement.com." A -> blocked
antumbra-dnsfilter: 2026/10/12 06:39:03 query "mmg.whatsapp.net." A -> servfail (rcode RCodeServerFailure)
"""


def stream(*lines):
    return applab.stream_records(["650 STREAM 7 " + ln for ln in lines])[0]


class TestWindows(unittest.TestCase):
    def test_streams_in_a_window(self):
        st = applab.stream_records(STREAMS.splitlines())
        # The F-Droid window: tor's own fetch is left out.
        targets, resolves = applab.window_streams(st, 3, 17)
        self.assertEqual([t["target"] for t in targets], ["10.0.2.2:80", "142.251.20.94:443"])
        by = {t["target"]: t for t in targets}
        self.assertEqual(by["142.251.20.94:443"]["outcomes"], {"CONNECTED": 1})
        self.assertEqual(by["10.0.2.2:80"]["outcomes"], {"PRIVATE_ADDR": 1})
        self.assertEqual(by["10.0.2.2:80"]["reasons"], ["PRIVATE_ADDR"])
        self.assertEqual(resolves, [{"name": "check.torproject.org", "count": 1, "outcomes": {"RESOLVED": 1}}])
        targets, resolves = applab.window_streams(st, 17, 99)
        self.assertEqual({t["target"]: t["outcomes"] for t in targets},
                         {"127.0.0.1:47000": {"PRIVATE_ADDR": 1}, "142.251.20.94:443": {"CONNECTED": 1}})
        self.assertEqual(resolves, [{"name": "www.gstatic.com", "count": 2,
                                     "outcomes": {"RESOLVED": 1, "NEWRESOLVE": 1}}])

    def test_outcomes(self):
        # Connected: the exit's REMAP, or its DONE; a SOCKS client's SUCCEEDED.
        self.assertEqual(applab._outcome(stream("NEW 0 192.0.2.7:443 PURPOSE=USER CLIENT_PROTOCOL=TRANS",
                                                "SENTCONNECT 4 192.0.2.7:443 CLIENT_PROTOCOL=TRANS",
                                                "CLOSED 4 192.0.2.7:443 REASON=END REMOTE_REASON=DONE")),
                         "CONNECTED")
        self.assertEqual(applab._outcome(stream("NEW 0 192.0.2.7:443 PURPOSE=USER CLIENT_PROTOCOL=SOCKS5",
                                                "SUCCEEDED 4 192.0.2.7:443")), "CONNECTED")
        # Not connected: the exit's reason for END, else tor's; a REMAP that
        # tor made from its own cache is not the exit's answer.
        self.assertEqual(applab._outcome(stream("NEW 0 192.0.2.7:25 PURPOSE=USER CLIENT_PROTOCOL=TRANS",
                                                "SENTCONNECT 4 192.0.2.7:25 CLIENT_PROTOCOL=TRANS",
                                                "CLOSED 4 192.0.2.7:25 REASON=END REMOTE_REASON=EXITPOLICY")),
                         "EXITPOLICY")
        self.assertEqual(applab._outcome(stream("NEW 0 192.0.2.7:443 PURPOSE=USER CLIENT_PROTOCOL=TRANS",
                                                "SENTCONNECT 4 192.0.2.7:443 CLIENT_PROTOCOL=TRANS",
                                                "DETACHED 4 192.0.2.7:443 REASON=END REMOTE_REASON=CONNECTREFUSED",
                                                "SENTCONNECT 5 192.0.2.7:443 CLIENT_PROTOCOL=TRANS",
                                                "CLOSED 5 192.0.2.7:443 REASON=TIMEOUT")), "TIMEOUT")
        self.assertEqual(applab._outcome(stream("NEW 0 192.0.2.7:443 PURPOSE=USER CLIENT_PROTOCOL=TRANS",
                                                "REMAP 0 192.0.2.7:443 SOURCE=CACHE",
                                                "SENTCONNECT 4 192.0.2.7:443 CLIENT_PROTOCOL=TRANS")),
                         "SENTCONNECT")
        # A lookup tor closed without an answer.
        self.assertEqual(applab._outcome(stream("NEWRESOLVE 0 nosuch.example:0 PURPOSE=DNS_REQUEST",
                                                "SENTRESOLVE 4 nosuch.example:0",
                                                "CLOSED 4 nosuch.example:0 REASON=DONE")), "UNRESOLVED")

    def test_store_loaded_needs_a_connection_and_its_own_names(self):
        st = applab.stream_records(STREAMS.splitlines())
        ui = applab.ui_summary(dump(*[node("App %d" % i) for i in range(15)]))
        queries = applab.window_queries(FILTER.splitlines(), 0, 5)
        hosts = ("f-droid.org",)
        loaded, sig = applab._store_loaded({}, ui, applab.window_streams(st, 3, 17)[0], queries, hosts)
        self.assertTrue(loaded)
        self.assertEqual((sig["tor_streams_connected"], sig["own_names_through_tor"]), (1, ["f-droid.org"]))
        # Only tor's own directory fetch (which SUCCEEDED), or only a refusal.
        for start, end in ((4, 10), (12, 14)):
            loaded, sig = applab._store_loaded({}, ui, applab.window_streams(st, start, end)[0], queries, hosts)
            self.assertFalse(loaded)
            self.assertEqual(sig["tor_streams_connected"], 0)
        # Only a name tor said does not exist.
        nx = [q for q in queries if q["name"] != "f-droid.org"]
        self.assertFalse(applab._store_loaded({}, ui, applab.window_streams(st, 3, 17)[0], nx, hosts)[0])

    def test_shell_connected_since_pattern(self):
        # emulator-apps.sh's store wait: only the exits' REMAPs of TransPort
        # streams count, not lookups (CLIENT_PROTOCOL=DNS) nor tor's own
        # fetches (SUCCEEDED).
        with open(os.path.join(CI, "emulator-apps.sh"), encoding="utf-8") as f:
            pattern = re.search(r"grep -q -E '([^']*REMAP[^']*)'", f.read()).group(1)
        r = subprocess.run(["grep", "-E", pattern], input=STREAMS, capture_output=True, text=True)
        self.assertEqual([ln.split(" ")[2] for ln in r.stdout.splitlines()], ["95", "80"])

    def test_queries_in_a_window(self):
        lines = FILTER.splitlines()
        q = applab.window_queries(lines, 0, 4)
        self.assertEqual([r["name"] for r in q], ["doubleclick.net", "f-droid.org"])
        self.assertEqual(q[1]["decisions"], {"forwarded": 1, "empty (type)": 1})
        self.assertEqual(q[1]["types"], ["A", "AAAA"])
        q = applab.window_queries(lines, 5, 9)
        self.assertEqual({r["name"]: list(r["decisions"]) for r in q},
                         {"g.whatsapp.net": ["forwarded"], "graph.facebook.com": ["servfail (timeout)"],
                          "app-measurement.com": ["blocked"],
                          "mmg.whatsapp.net": ["servfail (rcode RCodeServerFailure)"]})


LOGCAT = """10-12 06:40:00.000  1234  1234 I ActivityManager: Start proc 4321:com.whatsapp/u0a190 for top-activity
10-12 06:40:01.000  4321  4321 W GooglePlayServicesUtil: Google Play services is missing.
10-12 06:40:02.000  5555  5555 E AndroidRuntime: FATAL EXCEPTION: main
10-12 06:40:02.000  5555  5555 E AndroidRuntime: Process: com.other.app, PID: 5555
10-12 06:40:02.000  5555  5555 E AndroidRuntime: java.lang.IllegalStateException: other
"""
CRASH = """10-12 06:41:02.000  4321  4321 E AndroidRuntime: FATAL EXCEPTION: main
10-12 06:41:02.000  4321  4321 E AndroidRuntime: Process: com.whatsapp, PID: 4321
10-12 06:41:02.000  4321  4321 E AndroidRuntime: java.lang.RuntimeException: Unable to start activity
10-12 06:41:03.000  1234  1300 I ActivityManager: Process com.whatsapp (pid 4321) has died: fg TOP
"""


class TestLogcat(unittest.TestCase):
    def test_gms_and_other_apps_crash(self):
        r = applab.scan_logcat(LOGCAT, "com.whatsapp")
        self.assertFalse(r["crashed"])
        self.assertIn("Google Play services is missing", r["gms"])

    def test_gms_of_another_process_is_not_the_apps(self):
        # The same line, written by a process the app does not own.
        r = applab.scan_logcat(LOGCAT, "org.schabi.newpipe")
        self.assertIsNone(r["gms"])
        r = applab.scan_logcat(LOGCAT.replace("Start proc 4321:com.whatsapp", "Start proc 99:x"), "com.whatsapp")
        self.assertIsNone(r["gms"])
        # pidof's answer counts too.
        r = applab.scan_logcat(LOGCAT.replace("Start proc 4321:com.whatsapp", "Start proc 99:x"), "com.whatsapp",
                               ["4321"])
        self.assertEqual(r["pids"], ["4321"])
        self.assertIsNotNone(r["gms"])

    def test_crash(self):
        r = applab.scan_logcat(LOGCAT + CRASH, "com.whatsapp")
        self.assertTrue(r["crashed"] and r["died"])
        self.assertIn("Process: com.whatsapp, PID: 4321", " ".join(r["fatal"]))
        self.assertTrue(applab.scan_logcat(LOGCAT, "com.other.app")["crashed"])

    def test_native_crash_and_anr(self):
        r = applab.scan_logcat("F libc    : Fatal signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x0 in "
                               "tid 77 (RenderThread), pid 70 (com.spotify.music)\n"
                               "E ActivityManager: ANR in com.spotify.music (com.spotify.music/.MainActivity)\n",
                               "com.spotify.music")
        self.assertTrue(r["native_crash"] and r["crashed"] and r["anr"])


def report_dir(root, with_analysis=True):
    """A small app lab artifact: the F-Droid store loaded, WhatsApp ran
    and asked for Google Play services, NewPipe crashed, and an app the
    fetch could not verify."""
    sdir = os.path.join(root, "apps")
    alogs = os.path.join(root, "logs", "apps")
    shots = os.path.join(root, "screenshots")
    for d in (sdir, alogs, shots):
        os.makedirs(d)
    dl = {"schema": 1, "fdroid_index": {"ok": True}, "stores": [
        {"kind": "store", "name": "fdroid", "store": "fdroid", "package": "org.fdroid.fdroid", "label": "F-Droid",
         "version": "2.0.1", "verified": True, "error": None, "notes": [], "file": "stores/fdroid.apk"},
        {"kind": "store", "name": "taptap", "store": "taptap", "package": "com.taptap.global", "label": "TapTap",
         "version": "3.56.9", "verified": True, "error": None, "notes": [], "file": "stores/taptap.apk"}],
        "apps": [
        {"kind": "app", "name": "com.whatsapp", "store": "aptoide", "package": "com.whatsapp", "label": "WhatsApp",
         "version": "2.26", "verified": True, "error": None, "notes": [], "file": "apps/com.whatsapp.apk"},
        {"kind": "app", "name": "org.schabi.newpipe", "store": "fdroid", "package": "org.schabi.newpipe",
         "label": "NewPipe", "version": "0.29.1", "verified": True, "error": None, "notes": []},
        {"kind": "app", "name": "org.telegram.messenger", "store": "aptoide", "package": "org.telegram.messenger",
         "label": "Telegram", "verified": False, "error": "Aptoide: APP-1: not found", "notes": []}]}
    with open(os.path.join(sdir, "downloads.json"), "w") as f:
        json.dump(dl, f)
    with open(os.path.join(sdir, "tor-streams.txt"), "w") as f:
        f.write(STREAMS)
    with open(os.path.join(sdir, "dnsfilter.log"), "w") as f:
        f.write(FILTER)
    with open(os.path.join(sdir, "events.tsv"), "w") as f:
        f.write("welcome_start\t1000.0\t\ntor_bootstrapped\t1041.6\t41 s, from /status\n")
    with open(os.path.join(sdir, "checks.tsv"), "w") as f:
        f.write("adb_root\tok\t\nprovider_admin\tok\tAdministration on\nwifi_mac_new\twarn\tsame\n")
    with open(os.path.join(sdir, "device.json"), "w") as f:
        json.dump({"model": "sdk_gphone64_x86_64", "abilist": "x86_64", "mem_mb": "5923", "data_free_mb": "9800"}, f)
    store_ui = dump(*[node("App %d" % i) for i in range(15)])
    with open(os.path.join(alogs, "store-fdroid-ui.xml"), "w") as f:
        f.write(store_ui)
    with open(os.path.join(alogs, "app-com.whatsapp-logcat.txt"), "w") as f:
        f.write(LOGCAT)
    with open(os.path.join(alogs, "app-org.schabi.newpipe-logcat.txt"), "w") as f:
        f.write(CRASH.replace("com.whatsapp", "org.schabi.newpipe"))
    for stem in ("store-fdroid", "app-com.whatsapp", "apps-home", "apps-drawer"):
        png(os.path.join(shots, stem + ".png"))
    recs = [
        {"kind": "store", "name": "fdroid", "package": "org.fdroid.fdroid", "label": "F-Droid", "install": "ok",
         "launch": "ok", "focus": "yes", "running": "yes", "screenshot": "store-fdroid", "taps": "Skip",
         "ui": "logs/apps/store-fdroid-ui.xml", "logcat": "logs/apps/store-fdroid-logcat.txt",
         "streams_from": "3", "streams_to": "17", "filter_from": "0", "filter_to": "5", "t_start": "1100",
         "t_end": "1190", "seconds": "90"},
        {"kind": "store", "name": "taptap", "package": "com.taptap.global", "label": "TapTap", "install": "failed",
         "install_detail": "Failure [INSTALL_FAILED_NO_MATCHING_ABIS: Failed to extract native libraries, res=-113]"},
        {"kind": "app", "name": "com.whatsapp", "package": "com.whatsapp", "label": "WhatsApp", "install": "ok",
         "launch": "ok", "focus": "yes", "running": "yes", "screenshot": "app-com.whatsapp",
         "logcat": "logs/apps/app-com.whatsapp-logcat.txt",
         "streams_from": "17", "streams_to": "99", "filter_from": "5", "filter_to": "9"},
        {"kind": "app", "name": "org.schabi.newpipe", "package": "org.schabi.newpipe", "label": "NewPipe",
         "install": "ok", "launch": "ok", "focus": "no", "running": "no", "screenshot": "app-org.schabi.newpipe",
         "logcat": "logs/apps/app-org.schabi.newpipe-logcat.txt",
         "streams_from": "99", "streams_to": "99", "filter_from": "9", "filter_to": "9"},
        {"kind": "app", "name": "org.telegram.messenger", "package": "org.telegram.messenger", "label": "Telegram",
         "install": "not-verified", "note": "Aptoide: APP-1: not found"},
    ]
    with open(os.path.join(sdir, "records.jsonl"), "w") as f:
        for r in recs:
            f.write(json.dumps(r) + "\n")
        f.write("not json\n")
    if with_analysis:
        with open(os.path.join(sdir, "analysis.json"), "w") as f:
            json.dump({"verdict": "pass", "verdict_reasons": [], "phases": {"post-arm": {"tor-relay": 900, "link-arp": 4}},
                       "post_arm_tor_packets": 900, "leaks": [],
                       "destinations": {"names": [1, 2, 3], "targets": [1, 2]}}, f)


class TestBuild(unittest.TestCase):
    def build(self, **kw):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        report_dir(self.tmp.name, **kw)
        res, md = applab.build(self.tmp.name, run="42", jpeg_width=0)
        with open(os.path.join(self.tmp.name, "apps.json")) as f:
            self.assertEqual(json.load(f), json.loads(json.dumps(res)))
        return res, md

    def test_items(self):
        res, _ = self.build()
        st = {i["name"]: i for i in res["stores"]}
        ap = {i["name"]: i for i in res["apps"]}
        f = st["fdroid"]
        self.assertTrue(f["installed"] and f["launched"] and f["running"] and f["loaded"])
        # nosuch.f-droid.org went through Tor too, but tor found no such name.
        self.assertEqual(f["loaded_signals"]["own_names_through_tor"], ["f-droid.org"])
        self.assertEqual(f["loaded_signals"]["tor_streams_connected"], 1)
        self.assertEqual(f["taps"], ["Skip"])
        self.assertEqual(f["screenshot"], "store-fdroid.png")
        self.assertEqual([t["target"] for t in f["tor_targets"]], ["10.0.2.2:80", "142.251.20.94:443"])
        self.assertEqual(f["blocked"], ["doubleclick.net"])
        self.assertIn("catalogue loaded", f["outcome"])
        self.assertFalse(st["taptap"]["installed"])
        self.assertIn("NO_MATCHING_ABIS", st["taptap"]["outcome"])
        w = ap["com.whatsapp"]
        self.assertTrue(w["running"] and w["gms_missing"] and not w["crashed"])
        self.assertEqual(w["blocked"], ["app-measurement.com"])
        self.assertEqual(w["servfail"], ["graph.facebook.com", "mmg.whatsapp.net"])
        self.assertEqual(w["tor_resolves"][0]["name"], "www.gstatic.com")
        self.assertIn("wants Google Play services", w["outcome"])
        n = ap["org.schabi.newpipe"]
        self.assertTrue(n["crashed"])
        self.assertIsNone(n["screenshot"])
        self.assertEqual(n["names"], [])
        t = ap["org.telegram.messenger"]
        self.assertFalse(t["installed"] or t["verified"])
        self.assertIn("not found", t["outcome"])

    def test_session_leak_totals(self):
        res, md = self.build()
        self.assertEqual(res["session"]["tor_bootstrap_s"], 42)
        self.assertEqual(res["session"]["home_screenshot"], "apps-home.png")
        self.assertEqual(res["session"]["checks"], {"ok": 2, "warn": 1, "fail": 0})
        self.assertEqual(res["leak"]["verdict"], "pass")
        self.assertEqual(res["leak"]["packets_after_arm"], 904)
        self.assertEqual(res["totals"]["installed"], 3)
        self.assertEqual(res["totals"]["crashed"], 1)
        self.assertEqual(res["totals"]["stores_loaded"], 1)
        self.assertEqual(res["device"]["abilist"], "x86_64")
        self.assertIn("| WhatsApp (aptoide) | yes | running, wants Google Play services | 4 | 1 | 2 |", md)
        self.assertIn("PASS", md)
        self.assertIn("connected in 42 s", md)

    def test_without_analysis(self):
        res, md = self.build(with_analysis=False)
        self.assertIsNone(res["leak"]["verdict"])
        self.assertIn("not run", md)

    def test_download_never_run(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        report_dir(self.tmp.name)
        recs = os.path.join(self.tmp.name, "apps", "records.jsonl")
        with open(recs) as f:
            lines = [ln for ln in f if "whatsapp" not in ln]
        with open(recs, "w") as f:
            f.writelines(lines)
        res, _ = applab.build(self.tmp.name, jpeg_width=0)
        w = [i for i in res["apps"] if i["name"] == "com.whatsapp"][0]
        self.assertEqual(w["install"], "skipped")
        self.assertIn("run ended", w["outcome"])

    def test_emulator_never_ran(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        report_dir(self.tmp.name)
        dl = os.path.join(self.tmp.name, "downloads.json")
        os.replace(os.path.join(self.tmp.name, "apps", "downloads.json"), dl)
        os.remove(os.path.join(self.tmp.name, "apps", "records.jsonl"))
        res, _ = applab.build(self.tmp.name, jpeg_width=0)
        self.assertEqual(res["apps"], [])
        res, md = applab.build(self.tmp.name, jpeg_width=0, downloads_path=dl)
        self.assertEqual(len(res["stores"] + res["apps"]), 5)
        self.assertTrue(all(i["install"] == "skipped" for i in res["apps"] if i["verified"]))
        self.assertIn("not run: the run ended before it", md)

    @unittest.skipUnless(HAVE_CONVERT, "needs ImageMagick's convert")
    def test_jpeg(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        report_dir(self.tmp.name)
        res, _ = applab.build(self.tmp.name, jpeg_width=30)
        f = [i for i in res["stores"] if i["name"] == "fdroid"][0]
        self.assertEqual(f["screenshot"], "store-fdroid.jpg")
        shots = os.listdir(os.path.join(self.tmp.name, "screenshots"))
        self.assertFalse([s for s in shots if s.endswith(".png")])
        # A second build (after the leak analysis) finds the JPEGs.
        res, _ = applab.build(self.tmp.name, jpeg_width=30)
        self.assertEqual(res["session"]["drawer_screenshot"], "apps-drawer.jpg")

    def test_markdown_escapes(self):
        res, _ = self.build()
        res = copy.deepcopy(res)
        res["apps"][0]["label"] = "A | B <b>"
        md = applab.markdown(res)
        self.assertIn("A \\| B &lt;b&gt;", md)


if __name__ == "__main__":
    unittest.main()
