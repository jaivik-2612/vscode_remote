#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Fail if OnePlus/OxygenOS camera software or Qualcomm camera HAL blobs are
present under the given directories (docs/camera.md explains why Antumbra
never ships them). tests/lint.sh runs it on the source tree; the VM camera
checks run it on the image's root filesystem. Standard library only.

usage: no-oneplus-camera.py [--xdev] [--skip DIR]... ROOT...
Prints each offending path; exit status 1 if there is any.
"""
import fnmatch
import os
import sys
import zipfile

# File names, matched case-insensitively. The OnePlus Camera app and service
# and the native libraries bundled with it; Qualcomm's CamX/CHI camera HAL
# and its firmware and tuning blobs (LineageOS sm8150-common
# proprietary-files.txt names them).
NAMES = [
    "oneplus*camera*", "op*camera*.apk", "*oxygen*.apk", "*oneplus*.apk",
    "libopcamera*", "libopbaselib*", "liboppictureprocess*", "libopx.so",
    "libarcsoft*", "libmpbase.so", "libvdblurless*", "libsnpe*.so",
    "camera.qcom.so", "com.qti.chi.*", "com.qti.camx.*", "com.qti.sensormodule.*",
    "com.qti.tuned.*", "com.qti.sensor.*", "camera_icp*", "libcamx*",
    "libchromatix*", "libmmcamera*",
]
# Package names inside an APK's binary manifest (UTF-16 strings, compared
# with the zero bytes removed).
MANIFEST_MARKERS = [b"com.oneplus.", b"net.oneplus.", b"oxygenos"]
ANDROID_PACKAGES = (".apk", ".apex", ".xapk")


def apk_is_oneplus(path):
    try:
        with zipfile.ZipFile(path) as z:
            data = z.read("AndroidManifest.xml")
    except (OSError, KeyError, zipfile.BadZipFile, RuntimeError):
        return False
    flat = data.replace(b"\x00", b"").lower()
    return any(m in flat for m in MANIFEST_MARKERS)


def scan(root, xdev, skip):
    hits = []
    root_dev = os.lstat(root).st_dev
    for dirpath, dirnames, filenames in os.walk(root):
        keep = []
        for d in dirnames:
            p = os.path.normpath(os.path.join(dirpath, d))
            if p in skip or d == ".git":
                continue
            if xdev:
                try:
                    if os.lstat(p).st_dev != root_dev:
                        continue
                except OSError:
                    continue
            keep.append(d)
        dirnames[:] = keep
        for f in filenames:
            low = f.lower()
            p = os.path.join(dirpath, f)
            if any(fnmatch.fnmatchcase(low, n) for n in NAMES):
                hits.append(p)
            elif low.endswith(ANDROID_PACKAGES) and os.path.isfile(p) and apk_is_oneplus(p):
                hits.append(p)
    return hits


def main(argv):
    xdev, skip, roots = False, set(), []
    args = iter(argv)
    for a in args:
        if a == "--xdev":
            xdev = True
        elif a == "--skip":
            skip.add(os.path.normpath(next(args)))
        else:
            roots.append(a)
    if not roots:
        print(__doc__, file=sys.stderr)
        return 2
    hits = []
    for r in roots:
        hits += scan(os.path.normpath(r), xdev, {os.path.normpath(s) for s in skip})
    for h in hits:
        print(h)
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
