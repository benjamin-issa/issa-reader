#!/usr/bin/env python3
"""One sheet per screen, every device width side by side, with margin guides.

The important decision here is that panels are normalised by *points*, not
pixels. A 375-point iPhone SE screenshot is 750px wide at 2x and a 440-point
Pro Max is 1320px at 3x, so normalising on pixel height makes the small phone
look wider than the large one — exactly backwards for the thing being
inspected. Dividing by each device's scale first means a 440 panel is 17%
wider on the sheet than a 375 panel, as it is in life.

The tangerine hairlines at one screen margin from each edge are what turn this
from a gallery into a check. They are also the only coverage for the class of
bug the frame assertions cannot see: a control whose inner padding drifted from
the token, where the text inside has no frame to measure.
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

# Point widths, so a screenshot's scale can be derived from its pixel width.
DEVICE_POINTS = {
    "iphone-se3": 375,
    "iphone-13-mini": 375,
    "iphone-16e": 390,
    "iphone-17-pro": 402,
    "iphone-17-pro-axxl": 402,
    "iphone-air": 420,
    "iphone-17-pro-max": 440,
    "ipad-a16": 820,
}

MARGIN_PT = 16
PAPER = (239, 232, 220)
INK = (47, 58, 63)
TANGERINE = (226, 133, 58)
GAP = 28
PANEL_HEIGHT = 900
CAPTION = 34


def font(size: int):
    for candidate in ("/System/Library/Fonts/SFNSMono.ttf",
                      "/System/Library/Fonts/Supplemental/Arial.ttf"):
        try:
            return ImageFont.truetype(candidate, size)
        except OSError:
            continue
    return ImageFont.load_default()


def main(root: Path) -> int:
    devices = sorted(
        (d for d in root.iterdir() if d.is_dir() and not d.name.startswith("_")),
        key=lambda d: (DEVICE_POINTS.get(d.name, 9999), d.name),
    )
    if not devices:
        print("no device folders to sheet", file=sys.stderr)
        return 0

    screens = sorted({p.name for d in devices for p in d.glob("*.png")})
    sheets = root / "_sheets"
    sheets.mkdir(exist_ok=True)
    label = font(22)

    for screen in screens:
        panels = []
        for device in devices:
            path = device / screen
            if not path.exists():
                continue
            image = Image.open(path).convert("RGB")
            points = DEVICE_POINTS.get(device.name)
            if not points:
                continue
            # The scale the screenshot was taken at, so every panel below is
            # measured in the same units.
            scale = image.width / points
            point_height = image.height / scale
            factor = PANEL_HEIGHT / point_height
            size = (max(1, round(points * factor)), PANEL_HEIGHT)
            panels.append((device.name, points, image.resize(size, Image.LANCZOS), factor))

        if not panels:
            continue

        width = sum(p[2].width for p in panels) + GAP * (len(panels) + 1)
        height = PANEL_HEIGHT + GAP * 2 + CAPTION
        sheet = Image.new("RGB", (width, height), PAPER)
        draw = ImageDraw.Draw(sheet)

        x = GAP
        for name, points, image, factor in panels:
            sheet.paste(image, (x, GAP))
            for edge in (MARGIN_PT, points - MARGIN_PT):
                guide = x + round(edge * factor)
                draw.line([(guide, GAP), (guide, GAP + PANEL_HEIGHT)], fill=TANGERINE, width=1)
            draw.text((x, GAP + PANEL_HEIGHT + 8), f"{name} · {points}pt", font=label, fill=INK)
            x += image.width + GAP

        out = sheets / f"{screen}"
        sheet.save(out)
        print(f"  sheet: {out}")
    return 0


if __name__ == "__main__":
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("docs/screenshots/sweep")
    raise SystemExit(main(root))
