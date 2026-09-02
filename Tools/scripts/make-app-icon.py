#!/usr/bin/env python3
"""Draws the Issa Reader app icon for iOS and macOS.

Design 2d — "book & headphones" — from the design canvas's App Icon 2d
Package. The drawing lives in `icon_mark.py` so tvOS draws the same mark;
the geometry and colours are the handoff's (`Tools/design/app-icon/`).

Every size is drawn, not resampled. Both platforms take the full-bleed
square with no baked corners: iOS has always masked its own squircle, and
since macOS 26 the Mac does the same, so a tile that rounded itself would
show a second edge inside the system's. The light and tinted appearances are
opaque (an alpha channel in the 1024 is rejected at upload); the dark one is
transparent, so the system composites it over its own dark material.

Usage: make-app-icon.py <output-dir>
"""
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from icon_mark import VARIANTS, render

OUT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "icons")
REPO = pathlib.Path(__file__).resolve().parents[2]
IOS = REPO / "Apps/IssaReader-iOS/Assets.xcassets/AppIcon.appiconset"
MAC = REPO / "Apps/IssaReader-macOS/Assets.xcassets/AppIcon.appiconset"


def square(size, variant):
    return render(size, size, VARIANTS[variant])


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    for variant in VARIANTS:
        for size in (1024, 512, 256, 128, 64, 32, 16):
            square(size, variant).save(OUT / f"icon-{variant}-{size}.png")
    print(f"wrote {len(list(OUT.glob('*.png')))} images to {OUT}")

    # Install into the asset catalogues. This step used to be done by hand,
    # and nothing recorded that it had to be, so "re-run the script and the
    # icons update" was quietly false.
    if IOS.is_dir() and MAC.is_dir():
        square(1024, "default").save(IOS / "icon-1024.png")
        square(1024, "dark").save(IOS / "icon-1024-dark.png")
        square(1024, "tinted").save(IOS / "icon-1024-tinted.png")
        for points, scale in ((16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                              (256, 1), (256, 2), (512, 1), (512, 2)):
            suffix = "@2x" if scale == 2 else ""
            square(points * scale, "default").save(MAC / f"icon_{points}x{points}{suffix}.png")
        print(f"installed into {IOS.name} and {MAC.name}")
        print("tvOS assets come from make-tvos-assets.py — run that too")
    else:
        print("asset catalogues not found; wrote to the output directory only")
