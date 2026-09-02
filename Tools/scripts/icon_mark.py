"""The Issa Reader mark — design 2d, "book & headphones".

A slate tile carrying a warm two-tone open book with tangerine headphones
over it: text you can hear. The geometry is the handoff's, in 180 design
units (`Tools/design/app-icon/ICON.md`, and the SVG masters beside it), and
it is drawn here at every size rather than resampled from one PNG, so a 16 px
Mac icon and a 4640 px top shelf are both crisp.

Both generators import this: `make-app-icon.py` renders the square tile for
iOS and macOS, `make-tvos-assets.py` renders the same mark split across the
parallax layers tvOS wants. Keep the numbers here equal to the SVGs; the
fidelity check in docs/VERIFICATION.md diffs the two.
"""
from PIL import Image, ImageDraw

CANVAS = 180  # design units on a side

# Per-variant colours, from the ICON.md table. `bg` None means transparent —
# the dark appearance ships without a background so iOS can composite it over
# its own dark material.
VARIANTS = {
    "default": {
        "bg": (0x2F, 0x3A, 0x3F), "page_left": (0xFF, 0xFD, 0xF8),
        "page_right": (0xE9, 0xDE, 0xC9), "spine": (0x2F, 0x3A, 0x3F),
        "band": (0xEE, 0x9B, 0x57),
    },
    "dark": {
        "bg": None, "page_left": (0xF2, 0xE9, 0xD7),
        "page_right": (0xCB, 0xBF, 0xA6), "spine": (0x4A, 0x41, 0x33),
        "band": (0xF0, 0xA8, 0x63),
    },
    "tinted": {
        "bg": (0x00, 0x00, 0x00), "page_left": (0xCF, 0xCF, 0xCF),
        "page_right": (0x9C, 0x9C, 0x9C), "spine": (0x00, 0x00, 0x00),
        "band": (0xE8, 0xE8, 0xE8),
    },
}

# The two pages, as the SVG paths read: a cubic across the top, a straight
# edge down, a cubic back across the bottom. Left page from (38,70), right
# page mirrored about the spine at x=90. Pillow has no bezier primitive, so
# each curve is sampled into a polygon.
_LEFT = [((38, 70), (53.9, 61), (72.1, 61), (88, 70)),
         ((88, 134), (72.1, 125), (53.9, 125), (38, 134))]
_RIGHT = [((142, 70), (126.1, 61), (107.9, 61), (92, 70)),
          ((92, 134), (107.9, 125), (126.1, 125), (142, 134))]

# Spine: a 3-unit stroke at x=90 from y=67.3 to 134. Band: a semicircle of
# radius 38 about (90,54), stroke 8, round caps. Cups: 14×22, corner 6.
SPINE = (88.5, 67.3, 91.5, 134)
BAND_CENTRE, BAND_R, BAND_W = (90, 54), 38, 8
CUPS = [(46, 52, 60, 74), (120, 52, 134, 74)]
CUP_R = 6


def _cubic(p0, p1, p2, p3, steps=64):
    for i in range(steps + 1):
        t = i / steps
        s = 1 - t
        yield (s ** 3 * p0[0] + 3 * s * s * t * p1[0] + 3 * s * t * t * p2[0] + t ** 3 * p3[0],
               s ** 3 * p0[1] + 3 * s * s * t * p1[1] + 3 * s * t * t * p2[1] + t ** 3 * p3[1])


def _page(curves):
    top, bottom = curves
    return list(_cubic(*top)) + list(_cubic(*bottom))


def draw_book(d, at, colours):
    d.polygon([at(*p) for p in _page(_LEFT)], fill=colours["page_left"])
    d.polygon([at(*p) for p in _page(_RIGHT)], fill=colours["page_right"])
    x0, y0, x1, y1 = SPINE
    d.rectangle([at(x0, y0), at(x1, y1)], fill=colours["spine"])


def draw_headphones(d, at, colours, unit):
    band = colours["band"]
    cx, cy = BAND_CENTRE
    outer = BAND_R + BAND_W / 2
    # Pillow's arc keeps its stroke inside the box, so the box is the stroke's
    # outer edge and the width runs inward to the inner edge.
    d.arc([at(cx - outer, cy - outer), at(cx + outer, cy + outer)],
          180, 360, fill=band, width=max(round(BAND_W * unit), 1))
    for x in (cx - BAND_R, cx + BAND_R):  # round caps
        d.ellipse([at(x - BAND_W / 2, cy - BAND_W / 2), at(x + BAND_W / 2, cy + BAND_W / 2)],
                  fill=band)
    for x0, y0, x1, y1 in CUPS:
        d.rounded_rectangle([at(x0, y0), at(x1, y1)], radius=CUP_R * unit, fill=band)


def render(w, h, colours, parts=("bg", "book", "headphones"), unit=None, origin=None,
           supersample=4):
    """Draws the mark into a w×h image.

    `unit` is pixels per design unit at the final size (default: the square
    fit, `min(w, h) / 180`); `origin` is the top-left of the 180-unit box in
    final pixels (default: centred). `parts` picks the layers, which is how
    tvOS gets the book and the headphones as separate images.

    Drawn `supersample` times larger and reduced once, which is where the
    antialiasing comes from. A transparent result is reduced premultiplied,
    or the invisible black under the alpha would bleed into the edges.
    """
    unit = unit if unit is not None else min(w, h) / CANVAS
    ox, oy = origin if origin is not None else ((w - unit * CANVAS) / 2, (h - unit * CANVAS) / 2)
    ss = supersample
    bg = colours["bg"] if "bg" in parts else None
    img = (Image.new("RGB", (w * ss, h * ss), bg) if bg is not None
           else Image.new("RGBA", (w * ss, h * ss), (0, 0, 0, 0)))
    d = ImageDraw.Draw(img)
    u = unit * ss
    def at(x, y): return (ox * ss + x * u, oy * ss + y * u)
    if "book" in parts:
        draw_book(d, at, colours)
    if "headphones" in parts:
        draw_headphones(d, at, colours, u)
    if img.mode == "RGB":
        return img.resize((w, h), Image.LANCZOS)
    return img.convert("RGBa").resize((w, h), Image.LANCZOS).convert("RGBA")
