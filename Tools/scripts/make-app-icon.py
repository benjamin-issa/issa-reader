#!/usr/bin/env python3
"""Draws the Issa Reader app icon from the design canvas's Brand artboard.

The mark, in the designer's words: "One warm mark: a narration ring around a
reader's serif" — a rounded tile carrying a ring, with a Newsreader "I" inside
it. Geometry and colours are taken verbatim from the canvas, expressed as
fractions of the tile so every size is drawn rather than resampled:

  tile radius   38/168  of the side
  ring diameter 104/168
  ring stroke   3.5/168

Three variants, matching the canvas's "Light / Dark / tinted" row.

Usage: make-app-icon.py <output-dir>
"""
import sys, pathlib, math
from PIL import Image, ImageDraw, ImageFont

OUT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "icons")
FONT = pathlib.Path(__file__).resolve().parents[2] / \
    "Packages/IssaUI/Sources/IssaUI/Resources/Fonts/Newsreader.ttf"

# Fractions of the tile's side, from the canvas.
R_TILE, D_RING, W_RING = 38 / 168, 104 / 168, 3.5 / 168
# The bookmark, as fractions of the RING's diameter, so every platform's ring
# holds it at the same proportion however big that ring is.
W_MARK, H_MARK = 0.145 / D_RING, 0.535 / D_RING
SUPERSAMPLE = 4  # draw large, downsample once: keeps the ring edge clean

VARIANTS = {
    # name: (gradient inner, gradient outer, ring colour, glyph colour, flat bg)
    "light": ((0xF4, 0xB0, 0x63), (0xD9, 0x6E, 0x28), (255, 253, 248, 235), (255, 253, 248, 255), None),
    "dark": (None, None, (0xE2, 0x85, 0x3A, 255), (0xE2, 0x85, 0x3A, 255), (0x24, 0x21, 0x1B)),
    "tinted": (None, None, (0xC9, 0x8A, 0x3E, 255), (0xC9, 0x8A, 0x3E, 255), (0xF2, 0xE7, 0xD5)),
}


def radial(size, inner, outer):
    """The canvas's radial-gradient(circle at 32% 26%, inner, outer 78%)."""
    img = Image.new("RGB", (size, size))
    px = img.load()
    cx, cy = size * 0.32, size * 0.26
    # 78% stop, measured against the far corner so the falloff matches the canvas.
    far = math.hypot(max(cx, size - cx), max(cy, size - cy)) * 0.78
    for y in range(size):
        for x in range(size):
            t = min(math.hypot(x - cx, y - cy) / far, 1.0)
            px[x, y] = tuple(round(i + (o - i) * t) for i, o in zip(inner, outer))
    return img


def bookmark(d, cx, cy, ring_d, fill):
    """A bookmark, centred in the ring.

    Testers said the icon did not look like it had anything to do with
    reading — it was a ring with a serif "I" in it, which reads as a generic
    logo. A bookmark is the one object that means "a book, and your place in
    it" at 16px, which is where an app icon has to work hardest.

    Measured against the ring rather than the tile. tvOS draws the same mark on
    a landscape canvas with a proportionally smaller ring, and sizing from the
    side there pushed the bookmark straight out through the top and bottom of
    the circle.
    """
    w, h = W_MARK * ring_d, H_MARK * ring_d
    x0, x1 = (cx - w / 2), (cx + w / 2)
    y0, y1 = (cy - h / 2), (cy + h / 2)
    notch = y0 + h * 0.75  # the shoulders the V is cut up from
    d.polygon([(x0, y0), (x1, y0), (x1, notch), ((x0 + x1) / 2, y1), (x0, notch)], fill=fill)


def draw(size, variant, rounded=True):
    """Draws one icon.

    `rounded` is the difference between the two platforms' idea of an icon.
    A Mac icon is a free-form shape, so it rounds its own corners and keeps the
    alpha channel that makes them. An iOS icon is a full-bleed square that the
    system masks itself — rounding it here would show a rounded tile inside
    iOS's own rounded mask, and the transparency outside the corners is
    rejected outright at upload ("the large app icon can't be transparent or
    contain an alpha channel").
    """
    inner, outer, ring, glyph, flat = VARIANTS[variant]
    s = size * SUPERSAMPLE

    base = Image.new("RGB", (s, s), flat) if flat else radial(s, inner, outer)

    if rounded:
        # Round the tile by masking, so the corner is antialiased with the artwork.
        mask = Image.new("L", (s, s), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, s - 1, s - 1], radius=R_TILE * s, fill=255)
        tile = Image.new("RGBA", (s, s), (0, 0, 0, 0))
        tile.paste(base, (0, 0), mask)
    else:
        tile = base  # RGB, fully opaque, corner to corner

    d = ImageDraw.Draw(tile)
    ring_d, ring_w = D_RING * s, max(W_RING * s, 1)
    box = [(s - ring_d) / 2, (s - ring_d) / 2, (s + ring_d) / 2, (s + ring_d) / 2]
    d.ellipse(box, outline=ring, width=round(ring_w))

    bookmark(d, s / 2, s / 2, ring_d, glyph)

    return tile.resize((size, size), Image.LANCZOS)


OUT.mkdir(parents=True, exist_ok=True)
for variant in VARIANTS:
    for size in (1024, 512, 256, 128, 64, 32, 16):
        draw(size, variant).save(OUT / f"icon-{variant}-{size}.png")
    # Square, opaque, for iOS.
    draw(1024, variant, rounded=False).save(OUT / f"icon-ios-{variant}-1024.png")
print(f"wrote {len(list(OUT.glob('*.png')))} images to {OUT}")

# Install into the asset catalogues.
#
# This step used to be done by hand, and nothing recorded that it had to be:
# the filenames above match no catalogue, so "re-run the script and the icons
# update" was quietly false and the shipped icons could drift from the source
# that claims to generate them.
REPO = pathlib.Path(__file__).resolve().parents[2]
IOS = REPO / "Apps/IssaReader-iOS/Assets.xcassets/AppIcon.appiconset"
MAC = REPO / "Apps/IssaReader-macOS/Assets.xcassets/AppIcon.appiconset"

if IOS.is_dir() and MAC.is_dir():
    # iOS takes the square, opaque pair: an alpha channel is rejected at upload
    # and the system draws its own rounded mask.
    draw(1024, "light", rounded=False).save(IOS / "icon-1024.png")
    draw(1024, "dark", rounded=False).save(IOS / "icon-1024-dark.png")

    # macOS is a free-form shape, so it keeps the rounded corners and alpha.
    for points, scale in ((16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                          (256, 1), (256, 2), (512, 1), (512, 2)):
        suffix = "@2x" if scale == 2 else ""
        draw(points * scale, "light").save(MAC / f"icon_{points}x{points}{suffix}.png")
    print(f"installed into {IOS.name} and {MAC.name}")
    print("tvOS assets come from make-tvos-assets.py — run that too")
else:
    print("asset catalogues not found; wrote to the output directory only")
