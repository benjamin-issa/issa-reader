#!/usr/bin/env python3
"""Draw the Play listing's icon and feature graphic.

    python3 Android/play/make-graphics.py

Both come from the app's own artwork and type, so the listing looks like the
app: the icon is the iPhone's 1024-pixel App Store icon at Play's 512, and the
feature graphic sets that artwork on its own slate beside the name in
Newsreader and a line in Literata, the faces the app ships. Written into
`Android/play/listing/en-US/graphics/`; the output is committed, so run this
only when the artwork or the words change. Needs Pillow.
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
ICON = ROOT / "Apps/IssaReader-iOS/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
FONTS = ROOT / "Packages/IssaUI/Sources/IssaUI/Resources/Fonts"
OUT = ROOT / "Android/play/listing/en-US/graphics"

# The icon's own background, and the app's paper and tangerine (Palette.kt).
SLATE = (0x2F, 0x3A, 0x3F)
PAPER = (0xEF, 0xE8, 0xDC)
TANGERINE = (0xEE, 0x9B, 0x57)


def icon() -> Image.Image:
    """Play's 512-pixel icon: full square, no rounding (Play applies its own mask)."""
    return Image.open(ICON).convert("RGB").resize((512, 512), Image.LANCZOS)


def feature_graphic() -> Image.Image:
    """1024 by 500, no alpha. The artwork left, the name and a line right."""
    width, height = 1024, 500
    canvas = Image.new("RGB", (width, height), SLATE)
    # The artwork on the icon's own slate, so its square edge vanishes.
    art = Image.open(ICON).convert("RGB").resize((440, 440), Image.LANCZOS)
    canvas.paste(art, (40, (height - 440) // 2))

    draw = ImageDraw.Draw(canvas)
    name = ImageFont.truetype(str(FONTS / "Newsreader.ttf"), 92)
    line = ImageFont.truetype(str(FONTS / "Literata-Italic.ttf"), 34)
    small = ImageFont.truetype(str(FONTS / "Literata-Regular.ttf"), 25)
    left = 500
    draw.text((left, 150), "Issa Reader", font=name, fill=PAPER)
    draw.text((left + 4, 268), "Read and listen, in step.", font=line, fill=TANGERINE)
    draw.text((left + 4, 326), "For your own Storyteller library.", font=small, fill=PAPER)
    return canvas


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    icon().save(OUT / "icon.png", optimize=True)
    feature_graphic().save(OUT / "featureGraphic.png", optimize=True)
    for name in ("icon.png", "featureGraphic.png"):
        with Image.open(OUT / name) as made:
            print(f"{OUT / name}: {made.size[0]}x{made.size[1]} {made.mode}")


if __name__ == "__main__":
    main()
