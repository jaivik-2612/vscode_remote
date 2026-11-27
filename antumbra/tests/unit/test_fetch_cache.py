# SPDX-License-Identifier: GPL-3.0-or-later
"""build/fetch-sources.sh's caches of Android inputs, run for real on small
stand-ins: fetch_waydroid with made-up zips, fetch_fdroid with a made-up
APK, the downloads served from a local directory, and gpg, gpgv and openssl
replaced by functions (gpgv accepts a signature that names the APK's SHA-256).

FETCH_SOURCES=PATH tests another copy of the script (to show what an older
one does)."""
import hashlib
import os
import shutil
import subprocess
import tempfile
import unittest
import zipfile
import zlib

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
FETCH_SOURCES = os.environ.get("FETCH_SOURCES") or os.path.join(ROOT, "build", "fetch-sources.sh")

# Sources common.sh, then defines the functions under test from fetch-sources.sh
# (not its main part), with the lock file and the network replaced.
DRIVER = r"""
set -euo pipefail
export ANTUMBRA_CACHE="$T/cache" SOURCE_DATE_EPOCH=0
source "$ROOT/build/lib/common.sh"
eval "$(sed -n -e '/^lock_get_optional() {/,/^}/p' -e '/^fetch_waydroid() {/,/^}/p' -e '/^fetch_fdroid() {/,/^}/p' "$FETCH_SOURCES")"
lock_get() { local v; v="$(grep -E "^$1=" "$T/sources.lock" | head -n1 | cut -d= -f2-)"; [ -n "$v" ] || die "missing $1 in the lock"; printf '%s\n' "$v"; }
lock_get_optional() { grep -E "^$1=" "$T/sources.lock" | head -n1 | cut -d= -f2- || true; }
fetch() { echo "$1" >> "$T/fetched"; cp "$T/server/$(basename "$1")" "$2"; }
gpg() { case " $* " in *" --fingerprint "*) echo "fpr:::::::::$(lock_get FDROID_SIGNING_KEY_FPR):" ;; esac; }
gpgv() { [ "$(cat "$3")" = "signed $(sha256sum < "$4" | cut -d' ' -f1)" ]; }
openssl() { cat > /dev/null; [ "$1" = x509 ] && printf 'certificate'; true; }
WAYDROID_IMAGE_VARIANT=arm64
"$@"
"""


def sha256(data):
    return hashlib.sha256(data).hexdigest()


class FetchCacheTest(unittest.TestCase):
    def setUp(self):
        for tool in ("unzip", "sha256sum"):
            if not shutil.which(tool):
                self.skipTest(f"{tool} missing")
        self.t = tempfile.mkdtemp(prefix="antumbra-fetch-")
        os.makedirs(os.path.join(self.t, "server"))
        self.lock = {}

    def tearDown(self):
        shutil.rmtree(self.t)

    def serve(self, name, data):
        with open(os.path.join(self.t, "server", name), "wb") as f:
            f.write(data)

    def write_lock(self):
        with open(os.path.join(self.t, "sources.lock"), "w", encoding="utf-8") as f:
            f.write("".join(f"{k}={v}\n" for k, v in self.lock.items()))

    def run_fn(self, fn):
        self.write_lock()
        env = dict(os.environ, T=self.t, ROOT=ROOT, FETCH_SOURCES=FETCH_SOURCES)
        return subprocess.run(["bash", "-c", DRIVER, "driver", fn], env=env, capture_output=True, text=True, timeout=120)

    # --- Waydroid images -----------------------------------------------------------------

    def pin_image(self, kind, image):
        name = f"{kind.lower()}.img"
        zpath = os.path.join(self.t, f"{kind}.zip")
        with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as z:
            z.writestr(name, image)
        with open(zpath, "rb") as f:
            zdata = f.read()
        url = f"https://example.org/{kind}-{sha256(zdata)[:8]}.zip"
        self.serve(os.path.basename(url), zdata)
        k = f"WAYDROID_ARM64_{kind}"
        self.lock.update({f"{k}_URL": url, f"{k}_SHA256": sha256(zdata), f"{k}_SIZE": len(zdata),
                          f"{k}_IMG_SIZE": len(image), f"{k}_IMG_CRC32": f"{zlib.crc32(image):08x}",
                          f"{k}_IMG_SHA256": sha256(image)})

    def images(self):
        self.system, self.vendor = os.urandom(70000), os.urandom(50000)
        self.pin_image("SYSTEM", self.system)
        self.pin_image("VENDOR", self.vendor)
        self.dest = os.path.join(self.t, "cache", "waydroid", "arm64")

    def cached(self, name):
        with open(os.path.join(self.dest, name), "rb") as f:
            return f.read()

    def test_images_extracted_and_recorded(self):
        self.images()
        r = self.run_fn("fetch_waydroid")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.cached("system.img"), self.system)
        self.assertEqual(self.cached("images.sha256").decode(),
                         f"{sha256(self.system)}  system.img\n{sha256(self.vendor)}  vendor.img\n")

    def test_cached_image_changed_in_place_is_extracted_again(self):
        # Same size, same .from marker, different bytes (an ext4 image
        # mounted read-write for a look).
        self.images()
        self.assertEqual(self.run_fn("fetch_waydroid").returncode, 0)
        with open(os.path.join(self.dest, "system.img"), "r+b") as f:
            f.seek(1024)
            f.write(b"\xff" * 16)
        r = self.run_fn("fetch_waydroid")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.cached("system.img"), self.system, "the changed cached image was kept")
        self.assertIn(f"{sha256(self.system)}  system.img", self.cached("images.sha256").decode())

    def test_image_pin_is_required(self):
        self.images()
        del self.lock["WAYDROID_ARM64_VENDOR_IMG_SHA256"]
        r = self.run_fn("fetch_waydroid")
        self.assertNotEqual(r.returncode, 0, "an image without a SHA-256 pin was accepted")
        self.assertIn("WAYDROID_ARM64_VENDOR_IMG_SHA256", r.stderr)

    def test_image_that_is_not_the_pinned_one_fails(self):
        self.images()
        self.lock["WAYDROID_ARM64_SYSTEM_IMG_SHA256"] = "0" * 64
        r = self.run_fn("fetch_waydroid")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("pinned", r.stderr)

    # --- F-Droid -------------------------------------------------------------------------

    def fdroid(self, version):
        apk_path = os.path.join(self.t, f"fdroid-{version}.apk")
        with zipfile.ZipFile(apk_path, "w") as z:
            z.writestr("AndroidManifest.xml", f"version {version}")
            z.writestr("META-INF/CERT.RSA", "signature block")
        with open(apk_path, "rb") as f:
            apk = f.read()
        base = f"https://f-droid.org/repo/org.fdroid.fdroid_{version}.apk"
        self.serve(os.path.basename(base), apk)
        self.serve(os.path.basename(base) + ".asc", f"signed {sha256(apk)}".encode())
        self.lock.update({"FDROID_APK_URL": base, "FDROID_APK_SHA256": sha256(apk), "FDROID_APK_SIZE": len(apk),
                          "FDROID_SIG_URL": base + ".asc", "FDROID_SIGNING_KEY_FPR": "A" * 40,
                          "FDROID_SIGNING_KEY_URL": "https://example.org/key.asc",
                          "FDROID_APK_CERT_SHA256": sha256(b"certificate")})
        self.serve("key.asc", b"key")

    def test_fdroid_pin_bump_fetches_the_new_signature(self):
        self.fdroid(2000051)
        r = self.run_fn("fetch_fdroid")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.fdroid(2000052)
        r = self.run_fn("fetch_fdroid")
        self.assertEqual(r.returncode, 0, "a new F-Droid pin met the previous signature: " + r.stderr)
        with open(os.path.join(self.t, "fetched"), encoding="utf-8") as f:
            self.assertIn("https://f-droid.org/repo/org.fdroid.fdroid_2000052.apk.asc", f.read().split())

    def test_fdroid_bad_signature_fails(self):
        self.fdroid(2000051)
        self.serve("org.fdroid.fdroid_2000051.apk.asc", b"signed something else")
        r = self.run_fn("fetch_fdroid")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("signature verification failed", r.stderr)


if __name__ == "__main__":
    unittest.main()
