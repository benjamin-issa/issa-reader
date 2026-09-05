#!/usr/bin/env python3
"""One sheet per screen, every device width side by side, with margin guides.

Panels are normalised by *points*: one points-per-pixel factor, shared by every
panel on a sheet, so a 440-point phone is drawn 17% wider than a 375-point one,
as it is in life. Panel *heights* therefore differ, which is correct — a taller
phone is taller.

That is a fix, not a description of how it always worked. The factor used to be
`PANEL_HEIGHT / point_height`, recomputed per device, which normalises on
constant pixel *height* and so tracks aspect ratio rather than width: the
375-point SE (aspect 1.78) came out 506px wide while the 402 and 440 phones
(both ~2.17) came out 414px each — the small phone widest, and two different
widths identical. The tangerine guides inherited the same per-panel factor and
landed at three different insets for one token.

The numbers come from the app, not from here. `LayoutSweepTests` writes a
`reference.txt` beside each device's screenshots carrying the window width and
`Metrics.screenMargin` as the running app measured them. This script used to
keep its own table of device point widths and its own `MARGIN_PT = 16` — a
second and third copy of the two values whose drift the sheet exists to reveal.

The tangerine hairlines at one screen margin from each edge are what turn this
from a gallery into a check. They are also the only coverage for the class of
bug the frame assertions cannot see: a control whose inner padding drifted from
the token, where the text inside has no frame to measure.
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

PAPER = (239, 232, 220)
INK = (47, 58, 63)
TANGERINE = (226, 133, 58)
GAP = 28
PANEL_MAX_HEIGHT = 900
CAPTION = 34


def font(size: int):
    for candidate in ("/System/Library/Fonts/SFNSMono.ttf",
                      "/System/Library/Fonts/Supplemental/Arial.ttf"):
        try:
            return ImageFont.truetype(candidate, size)
        except OSError:
            continue
    return ImageFont.load_default()


def reference_for(device: Path) -> dict[str, float] | None:
    """What the app measured on this device, or None if it was never recorded.

    Written by LayoutSweepTests.recordReference. No fallback on purpose: a
    guessed width or margin draws a guide in the wrong place, and a guide in
    the wrong place is worse than no sheet at all — it is a check that agrees
    with itself.
    """
    path = device / "reference.txt"
    if not path.exists():
        return None
    fields: dict[str, float] = {}
    for line in path.read_text().splitlines():
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        try:
            fields[key.strip()] = float(value)
        except ValueError:
            return None
    return fields if {"margin", "width"} <= fields.keys() else None


def main(root: Path) -> int:
    devices = sorted(
        (d for d in root.iterdir() if d.is_dir() and not d.name.startswith("_")),
        key=lambda d: ((reference_for(d) or {}).get("width", 9999), d.name),
    )
    if not devices:
        print("no device folders to sheet", file=sys.stderr)
        return 0

    screens = sorted({p.name for d in devices for p in d.glob("*.png")})
    sheets = root / "_sheets"
    sheets.mkdir(exist_ok=True)
    label = font(22)

    missing = 0
    for screen in screens:
        panels = []
        for device in devices:
            path = device / screen
            if not path.exists():
                continue
            fields = reference_for(device)
            if fields is None:
                print(f"  skipping {device.name}/{screen}: no readable reference.txt")
                missing += 1
                continue
            image = Image.open(path).convert("RGB")
            points = fields["width"]
            # The scale the screenshot was taken at, so every panel below is
            # measured in the same units.
            scale = image.width / points
            panels.append((device.name, points, fields["margin"],
                           image, image.height / scale))

        if not panels:
            continue

        # One factor for every panel on the sheet, chosen so the tallest fits.
        # Shared is the whole point: it is what makes width on the sheet
        # proportional to width in points.
        factor = PANEL_MAX_HEIGHT / max(p[4] for p in panels)
        panels = [
            (name, points, margin,
             image.resize((max(1, round(points * factor)),
                           max(1, round(point_height * factor))), Image.LANCZOS))
            for name, points, margin, image, point_height in panels
        ]

        width = sum(p[3].width for p in panels) + GAP * (len(panels) + 1)
        height = max(p[3].height for p in panels) + GAP * 2 + CAPTION
        sheet = Image.new("RGB", (width, height), PAPER)
        draw = ImageDraw.Draw(sheet)

        x = GAP
        caption_y = GAP + max(p[3].height for p in panels) + 8
        for name, points, margin, image in panels:
            sheet.paste(image, (x, GAP))
            for edge in (margin, points - margin):
                guide = x + round(edge * factor)
                draw.line([(guide, GAP), (guide, GAP + image.height)],
                          fill=TANGERINE, width=1)
            draw.text((x, caption_y), f"{name} · {points:g}pt", font=label, fill=INK)
            x += image.width + GAP

        out = sheets / f"{screen}"
        sheet.save(out)
        print(f"  sheet: {out}")
    if missing:
        print(f"  {missing} panel(s) had no reference.txt and were left out", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("docs/screenshots/sweep")
    raise SystemExit(main(root))
