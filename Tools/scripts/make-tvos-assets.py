#!/usr/bin/env python3
"""Builds the tvOS brand assets.

tvOS does not take a single square icon. It wants a layered image stack — the
system separates the layers for the parallax effect as the icon gains focus — in
landscape, plus top-shelf artwork. So the mark is split: the warm tile sits on
the back layer, the ring and the serif on the front, and the gap between them is
what the TV animates.
"""
import json, pathlib, sys, math
from PIL import Image, ImageDraw, ImageFont

ROOT = pathlib.Path(__file__).resolve().parents[2]
FONT = ROOT / "Packages/IssaUI/Sources/IssaUI/Resources/Fonts/Newsreader.ttf"
OUT = ROOT / "Apps/IssaReader-tvOS/Assets.xcassets"
BRAND = OUT / "App Icon & Top Shelf Image.brandassets"

TANGERINE_IN, TANGERINE_OUT = (0xF4, 0xB0, 0x63), (0xD9, 0x6E, 0x28)
PAPER = (0xEF, 0xE8, 0xDC)
RING = (255, 253, 248, 235)


def radial(w, h, inner, outer):
    img = Image.new("RGB", (w, h))
    px = img.load()
    cx, cy = w * 0.32, h * 0.26
    far = math.hypot(max(cx, w - cx), max(cy, h - cy)) * 0.78
    for y in range(h):
        for x in range(w):
            t = min(math.hypot(x - cx, y - cy) / far, 1.0)
            px[x, y] = tuple(round(i + (o - i) * t) for i, o in zip(inner, outer))
    return img


def back(w, h):
    return radial(w, h, TANGERINE_IN, TANGERINE_OUT).convert("RGBA")


def front(w, h):
    """Ring and bookmark only, transparent elsewhere, so the parallax has depth.

    The same mark as the other platforms. This file has its own copy of the
    drawing because tvOS assets are a different shape entirely — landscape
    layers for the parallax — so "side" here is the short edge, which is what
    the ring is already measured against.
    """
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    side = min(w, h)
    ring = side * 0.52
    box = [(w - ring) / 2, (h - ring) / 2, (w + ring) / 2, (h + ring) / 2]
    d.ellipse(box, outline=RING, width=max(round(ring * 0.034), 2))

    # Sized from the ring, not the canvas: this one is landscape and its ring
    # is a smaller fraction of the short edge than the square icon's, so a mark
    # measured against the side burst out through the top and bottom.
    bw, bh = (0.145 / 0.619) * ring, (0.535 / 0.619) * ring
    x0, x1 = (w - bw) / 2, (w + bw) / 2
    y0, y1 = (h - bh) / 2, (h + bh) / 2
    notch = y0 + bh * 0.75
    d.polygon([(x0, y0), (x1, y0), (x1, notch), ((x0 + x1) / 2, y1), (x0, notch)], fill=RING)
    return img


def imageset(path, sizes, render, idiom="tv"):
    path.mkdir(parents=True, exist_ok=True)
    images = []
    for scale, (w, h) in sizes.items():
        name = f"image{'@2x' if scale == '2x' else ''}.png"
        render(w, h).save(path / name)
        images.append({"filename": name, "idiom": idiom, "scale": scale})
    (path / "Contents.json").write_text(
        json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")


def layer(stack, name, render, sizes):
    d = stack / f"{name}.imagestacklayer"
    d.mkdir(parents=True, exist_ok=True)
    (d / "Contents.json").write_text(
        json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    imageset(d / "Content.imageset", sizes, render)


def stack(path, sizes):
    path.mkdir(parents=True, exist_ok=True)
    (path / "Contents.json").write_text(json.dumps({
        "layers": [{"filename": "Front.imagestacklayer"}, {"filename": "Back.imagestacklayer"}],
        "info": {"author": "xcode", "version": 1},
    }, indent=2) + "\n")
    layer(path, "Back", back, sizes)
    layer(path, "Front", front, sizes)


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


def shelf(w, h):
    """Top shelf: the mark on paper, left-weighted like the rest of the design."""
    img = Image.new("RGBA", (w, h), PAPER + (255,))
    mark = min(h * 0.55, w * 0.2)
    tile = back(int(mark), int(mark))
    mask = Image.new("L", tile.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, tile.size[0] - 1, tile.size[1] - 1],
                                           radius=tile.size[0] * 38 / 168, fill=255)
    img.paste(tile, (int(w * 0.08), int((h - mark) / 2)), mask)
    img.alpha_composite(front(int(mark), int(mark)), (int(w * 0.08), int((h - mark) / 2)))
    return img


imageset(BRAND / "Top Shelf Image.imageset", {"1x": (1920, 720), "2x": (3840, 1440)}, shelf)
imageset(BRAND / "Top Shelf Image Wide.imageset", {"1x": (2320, 720), "2x": (4640, 1440)}, shelf)
(OUT / "Contents.json").write_text('{ "info" : { "author" : "xcode", "version" : 1 } }\n')
print("tvOS brand assets written")
