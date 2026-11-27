#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Subset the image's own fonts to WOFF2 for the simulator (run once; needs fontTools + brotli).

usage: make_fonts.py [--rootfs DIR] [--pylib DIR]
    --rootfs  a built root filesystem (default: build/work/qemu-virt/rootfs of this checkout)
    --pylib   a directory holding fontTools and brotli, e.g. from
              pip install --target DIR fonttools brotli (default: the interpreter's own)

The page embeds the results (build.py), so it makes no font request at all.
Sources: the built image's /usr/share/fonts (fonts-roboto-unhinted, Apache-2.0;
fonts-noto-mono, OFL-1.1). Subset: Basic Latin, Latin-1, Latin Extended-A,
General Punctuation, arrows and a few symbols the page uses.
"""
import argparse, json, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ap = argparse.ArgumentParser(description="Subset the image's fonts to WOFF2 for the simulator.")
ap.add_argument("--rootfs", type=Path, default=HERE.parents[2] / "build" / "work" / "qemu-virt" / "rootfs")
ap.add_argument("--pylib", type=Path)
args = ap.parse_args()
if args.pylib:
    sys.path.insert(0, str(args.pylib.resolve()))
from fontTools import subset  # noqa: E402

ROOTFS = args.rootfs
OUT = HERE / "fonts"
FACES = [
    ("Roboto", 300, "usr/share/fonts/truetype/roboto/unhinted/RobotoTTF/Roboto-Light.ttf", "fonts-roboto-unhinted", "Apache-2.0"),
    ("Roboto", 400, "usr/share/fonts/truetype/roboto/unhinted/RobotoTTF/Roboto-Regular.ttf", "fonts-roboto-unhinted", "Apache-2.0"),
    ("Roboto", 500, "usr/share/fonts/truetype/roboto/unhinted/RobotoTTF/Roboto-Medium.ttf", "fonts-roboto-unhinted", "Apache-2.0"),
    ("Roboto", 700, "usr/share/fonts/truetype/roboto/unhinted/RobotoTTF/Roboto-Bold.ttf", "fonts-roboto-unhinted", "Apache-2.0"),
    ("Roboto", 900, "usr/share/fonts/truetype/roboto/unhinted/RobotoTTF/Roboto-Black.ttf", "fonts-roboto-unhinted", "Apache-2.0"),
    ("Noto Sans Mono", 400, "usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf", "fonts-noto-mono", "OFL-1.1"),
    ("Noto Sans Mono", 700, "usr/share/fonts/truetype/noto/NotoSansMono-Bold.ttf", "fonts-noto-mono", "OFL-1.1"),
]
UNICODES = [*range(0x20, 0x7F), *range(0xA0, 0x180), *range(0x2000, 0x2070), 0x20AC, 0x2122, *range(0x2190, 0x2200),
            0x2212, 0x22EE, 0x24D8, 0x25CF, 0x2715]


def main():
    OUT.mkdir(exist_ok=True)
    manifest = []
    for family, weight, rel, pkg, lic in FACES:
        src = ROOTFS / rel
        name = f"{family.replace(' ', '')}-{weight}.woff2"
        opts = subset.Options()
        opts.flavor = "woff2"
        opts.layout_features = ["kern", "liga", "calt", "tnum", "pnum", "lnum"]
        opts.name_IDs = ["*"]
        opts.notdef_outline = True
        font = subset.load_font(str(src), opts)
        sub = subset.Subsetter(opts)
        sub.populate(unicodes=UNICODES)
        sub.subset(font)
        subset.save_font(font, str(OUT / name), opts)
        manifest.append({"file": f"fonts/{name}", "family": family, "weight": weight, "source_in_image": "/" + rel,
                         "package": pkg, "licence": lic, "bytes": (OUT / name).stat().st_size})
        print(name, (OUT / name).stat().st_size)
    (OUT / "fonts.json").write_text(json.dumps(manifest, indent=1) + "\n")


if __name__ == "__main__":
    main()
