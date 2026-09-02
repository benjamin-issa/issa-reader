#!/usr/bin/env python3
"""Builds the tvOS brand assets.

tvOS does not take a single square icon. It wants a layered image stack — the
system separates the layers for the parallax effect as the icon gains focus — in
landscape, plus top-shelf artwork. So the mark is split three ways: the slate
tile on the back layer, the book in the middle, the headphones in front, and
the gaps between them are what the TV animates.

The drawing is `icon_mark.py`, shared with the square icon; only the placement
is this file's. The 180-unit box is scaled to nine tenths of the short edge
and centred, which keeps the band and the page corners clear of the edges the
focus effect crops and the corners the system rounds.
"""
import json, pathlib, sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from PIL import Image, ImageDraw
from icon_mark import CANVAS, VARIANTS, render

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "Apps/IssaReader-tvOS/Assets.xcassets"
BRAND = OUT / "App Icon & Top Shelf Image.brandassets"

COLOURS = VARIANTS["default"]
PAPER = (0xEF, 0xE8, 0xDC)


def placement(w, h):
    unit = 0.9 * h / CANVAS
    return unit, ((w - CANVAS * unit) / 2, (h - CANVAS * unit) / 2)


def back(w, h):
    return render(w, h, COLOURS, parts=("bg",))


def middle(w, h):
    unit, origin = placement(w, h)
    return render(w, h, COLOURS, parts=("book",), unit=unit, origin=origin)


def front(w, h):
    unit, origin = placement(w, h)
    return render(w, h, COLOURS, parts=("headphones",), unit=unit, origin=origin)


def imageset(path, sizes, draw, idiom="tv"):
    path.mkdir(parents=True, exist_ok=True)
    images = []
    for scale, (w, h) in sizes.items():
        name = f"image{'@2x' if scale == '2x' else ''}.png"
        draw(w, h).save(path / name)
        images.append({"filename": name, "idiom": idiom, "scale": scale})
    (path / "Contents.json").write_text(
        json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")


def layer(stack, name, draw, sizes):
    d = stack / f"{name}.imagestacklayer"
    d.mkdir(parents=True, exist_ok=True)
    (d / "Contents.json").write_text(
        json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    imageset(d / "Content.imageset", sizes, draw)


LAYERS = (("Front", front), ("Middle", middle), ("Back", back))  # front-most first


def stack(path, sizes):
    path.mkdir(parents=True, exist_ok=True)
    (path / "Contents.json").write_text(json.dumps({
        "layers": [{"filename": f"{name}.imagestacklayer"} for name, _ in LAYERS],
        "info": {"author": "xcode", "version": 1},
    }, indent=2) + "\n")
    for name, draw in LAYERS:
        layer(path, name, draw, sizes)


def shelf(w, h):
    """Top shelf: the tile on paper, left-weighted like the rest of the design."""
    img = Image.new("RGBA", (w, h), PAPER + (255,))
    side = int(min(h * 0.55, w * 0.2))
    tile = render(side, side, COLOURS)
    mask = Image.new("L", tile.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, side - 1, side - 1],
                                           radius=side * 38 / CANVAS, fill=255)
    img.paste(tile, (int(w * 0.08), int((h - side) / 2)), mask)
    return img


if __name__ == "__main__":
    BRAND.mkdir(parents=True, exist_ok=True)
    (BRAND / "Contents.json").write_text(json.dumps({
        "assets": [
            {"filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
            {"filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
            {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"},
            {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"},
        ],
        "info": {"author": "xcode", "version": 1},
    }, indent=2) + "\n")

    stack(BRAND / "App Icon.imagestack", {"1x": (400, 240), "2x": (800, 480)})
    stack(BRAND / "App Icon - App Store.imagestack", {"1x": (1280, 768)})
    imageset(BRAND / "Top Shelf Image.imageset", {"1x": (1920, 720), "2x": (3840, 1440)}, shelf)
    imageset(BRAND / "Top Shelf Image Wide.imageset", {"1x": (2320, 720), "2x": (4640, 1440)}, shelf)
    (OUT / "Contents.json").write_text('{ "info" : { "author" : "xcode", "version" : 1 } }\n')
    print("tvOS brand assets written")
