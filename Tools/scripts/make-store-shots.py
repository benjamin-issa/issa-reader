#!/usr/bin/env python3
"""The App Store screenshots: each a headline, a subline and a real screen.

    Tools/scripts/make-store-shots.py <captures> <out> [--captions <file>]

`<captures>` holds one folder per device, `iphone/` and `ipad/`, each with the
raw simulator screenshots the captions file names (`StoreShotsTests` takes
them; the ones chosen are copied in under the names below). `<out>` receives
the panels in the folders App Store Connect's display sizes want, and
`screenshot-captions.csv`. Running it again over new captures rebuilds the
same set, so a panel is retaken by replacing its capture, not by editing an
image. Neither the captures nor the panels belong in the repository.

What a panel is, and why:

- A portrait canvas with a vertical gradient in one of the app's own colours
  (`Palette.swift`), a heavy headline wrapped to at most two lines, and one
  lighter subline. The type is the app's: Newsreader, its display serif, and
  Public Sans, its interface face, both bundled under the SIL Open Font
  License. No system font, so the image is the same on every Mac that builds it.
- Below the words, the app's real screen, as captured, with rounded top
  corners, a thin light outline and a soft shadow, running off the bottom
  edge. No device frame is drawn: the store shows the app, not hardware, and
  App Review 2.3.3 asks for the app in use.
- The screen is only ever scaled down. A capture smaller than the space it is
  given is an error rather than a blurred panel.
- A panel may add up to four ticked lines between the words and the screen
  ("Private by design" does); the screen still shows, lower down. A panel may
  also start its screen part-way down (`cropTop`), cutting what is above
  without changing anything it shows.
- RGB with no alpha channel, which App Store Connect requires.
"""
import argparse
import csv
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[2]
FONTS = ROOT / "Packages/IssaUI/Sources/IssaUI/Resources/Fonts"
# Shapes are drawn this many times larger and reduced, so their edges are
# smooth; Pillow's own shape drawing is not anti-aliased.
SUPERSAMPLE = 4


def colour(hex_string: str) -> tuple[int, int, int]:
    value = hex_string.lstrip("#")
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))


def load_font(spec: dict, size: int) -> ImageFont.FreeTypeFont:
    """A bundled face at a weight (and optical size) from its variable axes."""
    font = ImageFont.truetype(str(FONTS / spec["file"]), size)
    axes = spec.get("axes")
    if axes:
        names = [axis["name"].decode() if isinstance(axis["name"], bytes) else axis["name"]
                 for axis in font.get_variation_axes()]
        missing = set(axes) - set(names)
        if missing:
            sys.exit(f"error: {spec['file']} has no axis {', '.join(sorted(missing))} (it has {', '.join(names)})")
        font.set_variation_by_axes([axes.get(name, axis["default"])
                                    for name, axis in zip(names, font.get_variation_axes())])
    return font


def width_of(font: ImageFont.FreeTypeFont, text: str) -> float:
    return font.getlength(text)


def wrap(font: ImageFont.FreeTypeFont, text: str, width: float, max_lines: int) -> list[str] | None:
    """Lines no wider than `width`, or None if it takes more than `max_lines`.

    A caption's own line break is kept. Otherwise one line if it fits, and
    for two, the break that leaves the lines most even, which is how a
    headline is set by hand: "The forecast, straight / from the source", not
    a full first line over a lone word.
    """
    if "\n" in text:
        lines = text.split("\n")
        return lines if len(lines) <= max_lines and all(width_of(font, l) <= width for l in lines) else None
    if width_of(font, text) <= width:
        return [text]
    words = text.split()
    if max_lines >= 2:
        best = None
        for i in range(1, len(words)):
            pair = [" ".join(words[:i]), " ".join(words[i:])]
            widest = max(width_of(font, line) for line in pair)
            if widest <= width and (best is None or widest < best[0]):
                best = (widest, pair)
        if best:
            return best[1]
    # Greedy, for anything longer.
    lines, line = [], ""
    for word in words:
        trial = f"{line} {word}".strip()
        if width_of(font, trial) <= width:
            line = trial
        else:
            if line:
                lines.append(line)
            line = word
    lines.append(line)
    return lines if len(lines) <= max_lines and all(width_of(font, l) <= width for l in lines) else None


def fitted(spec: dict, size: int, text: str, width: float, max_lines: int, what: str):
    """The face at the largest size up to `size` that sets `text` in `max_lines`.

    Shrinks by at most a fifth; a caption that needs more than that is too
    long for the panel, and the error says so rather than printing it small.
    """
    floor = int(size * 0.8)
    for candidate in range(size, floor - 1, -2):
        font = load_font(spec, candidate)
        lines = wrap(font, text, width, max_lines)
        if lines:
            if candidate != size:
                print(f"  note: {what} set at {candidate}px, not {size}px, to fit")
            return font, lines
    sys.exit(f"error: {what} does not fit in {max_lines} line(s) even at {floor}px: {text!r}")


def gradient(size: tuple[int, int], top: tuple, bottom: tuple) -> Image.Image:
    width, height = size
    column = Image.new("RGB", (1, height))
    for y in range(height):
        t = y / max(height - 1, 1)
        column.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return column.resize(size)


def rounded_mask(size: tuple[int, int], radius: int) -> Image.Image:
    """An anti-aliased mask with rounded top corners; the bottom runs off the
    canvas, so its corners are square."""
    width, height = size
    big = Image.new("L", (width * SUPERSAMPLE, (height + radius) * SUPERSAMPLE), 0)
    ImageDraw.Draw(big).rounded_rectangle(
        (0, 0, big.width - 1, big.height - 1), radius=radius * SUPERSAMPLE, fill=255)
    return big.resize((width, height + radius), Image.LANCZOS).crop((0, 0, width, height))


def outline_layer(size: tuple[int, int], radius: int, stroke: int, rgba: tuple) -> Image.Image:
    width, height = size
    big = Image.new("RGBA", (width * SUPERSAMPLE, (height + radius) * SUPERSAMPLE), (0, 0, 0, 0))
    inset = stroke * SUPERSAMPLE / 2
    ImageDraw.Draw(big).rounded_rectangle(
        (inset, inset, big.width - 1 - inset, big.height - 1 - inset),
        radius=radius * SUPERSAMPLE, outline=rgba, width=stroke * SUPERSAMPLE)
    return big.resize((width, height + radius), Image.LANCZOS).crop((0, 0, width, height))


def tick_mark(diameter: int, fill: tuple, mark: tuple) -> Image.Image:
    """A filled circle with a check in it."""
    d = diameter * SUPERSAMPLE
    big = Image.new("RGBA", (d, d), (0, 0, 0, 0))
    draw = ImageDraw.Draw(big)
    draw.ellipse((0, 0, d - 1, d - 1), fill=fill + (255,))
    draw.line([(d * 0.28, d * 0.52), (d * 0.44, d * 0.68), (d * 0.73, d * 0.36)],
              fill=mark + (255,), width=round(d * 0.1), joint="curve")
    return big.resize((diameter, diameter), Image.LANCZOS)


def draw_centred(draw: ImageDraw.ImageDraw, lines: list[str], font, y: float, centre: float,
                 line_height: float, fill: tuple) -> float:
    for line in lines:
        draw.text((centre, y), line, font=font, fill=fill, anchor="mt")
        y += line_height
    return y


def compose(panel: dict, device: dict, theme: dict, fonts: dict, capture: Path, out: Path) -> None:
    width, height = device["size"]
    canvas = gradient((width, height), colour(theme["top"]), colour(theme["bottom"]))
    draw = ImageDraw.Draw(canvas)
    text_width = width * device["textWidth"]
    centre = width / 2

    head_font, head_lines = fitted(fonts["headline"], device["headlineSize"], panel["headline"],
                                   text_width, 2, f"{panel['file']} headline")
    sub_font, sub_lines = fitted(fonts["subline"], device["sublineSize"], panel["subline"],
                                 text_width, 2, f"{panel['file']} subline")

    y = height * device["textTop"]
    y = draw_centred(draw, head_lines, head_font, y, centre, head_font.size * 1.12,
                     colour(theme["headline"]))
    y += head_font.size * 0.22
    y = draw_centred(draw, sub_lines, sub_font, y, centre, sub_font.size * 1.32, colour(theme["subline"]))

    ticks = panel.get("ticks") or []
    if len(ticks) > 4:
        sys.exit(f"error: {panel['file']} has {len(ticks)} ticks; four at most")
    block_height = 0
    if ticks:
        tick_font = load_font(fonts["tick"], device["tickSize"])
        detail_font = load_font(fonts["tickDetail"], device["tickDetailSize"])
        diameter = round(device["tickSize"] * 1.5)
        row_height = max(diameter, tick_font.size * 1.25 + detail_font.size * 1.3)
        row_gap = device["tickSize"] * 0.75
        block_height = len(ticks) * row_height + (len(ticks) - 1) * row_gap
    text_end = y
    clearance = device["tickSize"] * 1.3 if ticks else 0

    # The screen: below the words, never over them, and never upscaled.
    screen_top = round(max(height * (device["screenTopWithTicks"] if ticks else device["screenTop"]),
                           text_end + clearance + block_height + device["sublineSize"] * 1.2))
    screen_width = round(width * device["screenWidth"])
    shot = Image.open(capture)
    if shot.width < screen_width:
        sys.exit(f"error: {capture} is {shot.width}px wide; the panel needs at least {screen_width}px "
                 "(a screen is only ever scaled down)")
    expected = tuple(device["size"])
    if shot.size != expected:
        print(f"  note: {capture.name} is {shot.width}x{shot.height}, not the device's {expected[0]}x{expected[1]}")
    scale = screen_width / shot.width
    # `cropTop` shows a real screen from part-way down, for a screen whose top
    # must not be in the set; the rest of it is shown as captured. Anchored to
    # the canvas's foot, so it still runs off the bottom edge, and never pulled
    # up over the words.
    crop_top = round(shot.height * panel.get("cropTop", 0))
    if crop_top:
        shot = shot.crop((0, crop_top, shot.width, shot.height))
        screen_top = max(screen_top, height - round(shot.height * scale))

    # The ticks, in the middle of the room between the words and the screen.
    if ticks:
        gap = round(diameter * 0.55)
        block_width = width * device["screenWidth"]
        left = (width - block_width) / 2
        text_left = left + diameter + gap
        room = block_width - diameter - gap
        mark = tick_mark(diameter, colour(theme.get("tick", theme["headline"])),
                         colour(theme.get("tickMark", theme["top"])))
        y = text_end + max(clearance, (screen_top - text_end - block_height) / 2)
        for title, detail in ticks:
            for text, font in ((title, tick_font), (detail, detail_font)):
                if width_of(font, text) > room:
                    sys.exit(f"error: {panel['file']} tick line too wide for the panel: {text!r}")
            row_top = round(y)
            canvas.paste(mark, (round(left), row_top), mark)
            draw.text((text_left, row_top + diameter * 0.04), title, font=tick_font,
                      fill=colour(theme["headline"]), anchor="lt")
            draw.text((text_left, row_top + diameter * 0.04 + tick_font.size * 1.25), detail,
                      font=detail_font, fill=colour(theme["subline"]), anchor="lt")
            y = row_top + row_height + row_gap
    visible = height - screen_top
    source_height = min(shot.height, round(visible / scale) + 1)
    screen = shot.convert("RGB").crop((0, 0, shot.width, source_height)).resize(
        (screen_width, min(visible, round(source_height * scale))), Image.LANCZOS)
    radius = round(screen_width * device["cornerRadius"])
    left = (width - screen_width) // 2

    # A soft shadow under the screen, cast a little downwards.
    shadow = Image.new("L", (width, height), 0)
    shadow_shape = rounded_mask(screen.size, radius).point(lambda v: v * 0.42)
    shadow.paste(shadow_shape, (left, screen_top + round(height * 0.006)))
    shadow = shadow.filter(ImageFilter.GaussianBlur(round(width * 0.022)))
    canvas = Image.composite(Image.new("RGB", (width, height), (0, 0, 0)), canvas, shadow)

    canvas.paste(screen, (left, screen_top), rounded_mask(screen.size, radius))
    # White on a dark ground; on a light one the palette's strong border, which
    # white would vanish into.
    rgba = colour(theme["outline"]) + (255,) if "outline" in theme else (255, 255, 255, 150)
    line = outline_layer(screen.size, radius, device["outline"], rgba)
    canvas.paste(line, (left, screen_top), line)

    out.parent.mkdir(parents=True, exist_ok=True)
    canvas.convert("RGB").save(out, optimize=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("captures", type=Path, help="folder with iphone/ and ipad/ captures")
    parser.add_argument("out", type=Path, help="where the panels go")
    parser.add_argument("--captions", type=Path, default=Path(__file__).with_name("store-shots.json"))
    parser.add_argument("--only", choices=["iphone", "ipad"], help="build one device's panels")
    args = parser.parse_args()

    spec = json.loads(args.captions.read_text())
    rows = []
    made = []
    for number, panel in enumerate(spec["panels"]):
        device_name = panel["device"]
        if args.only and device_name != args.only:
            continue
        device = spec["devices"][device_name]
        capture = args.captures / device_name / panel["capture"]
        if not capture.exists():
            sys.exit(f"error: no capture {capture}")
        out = args.out / device["folder"] / panel["file"]
        print(f"{device_name} {panel['file']} <- {panel['capture']}")
        compose(panel, device, spec["themes"][panel["theme"]], spec["fonts"], capture, out)
        made.append((out, tuple(device["size"])))
        slot = f"{device['slot']} {panel['file'][:2]}"
        rows.append([slot, panel["headline"], panel["subline"],
                     "; ".join(f"{t} ({d})" for t, d in panel.get("ticks") or [])])

    # Read back, as App Store Connect will: the size it expects, RGB, no alpha.
    for path, size in made:
        image = Image.open(path)
        if image.size != size or image.mode != "RGB":
            sys.exit(f"error: {path} is {image.size} {image.mode}, expected {size} RGB")
    if made:
        with open(args.out / "screenshot-captions.csv", "w", newline="") as handle:
            writer = csv.writer(handle)
            writer.writerow(["Slot", "Headline", "Subline", "Ticks"])
            writer.writerows(rows)
    print(f"{len(made)} panels, each checked for size and RGB, in {args.out}")


if __name__ == "__main__":
    main()
