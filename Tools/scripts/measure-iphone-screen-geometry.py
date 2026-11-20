#!/usr/bin/env python3
"""Measure how far each iPhone's rounded corners and sensor housing reach.

The reader's full-screen page (ReaderChrome.hardwareTop / hardwareBottom, and
the table in IssaRender's FillEdges.swift) puts text part-way into the safe
areas. How far it may go comes from numbers this script measures, so that
they are not guesses:

  * every home-indicator iPhone's `framebufferMask` (a PDF in the simulator's
    device profile whose opaque pixels are the visible screen) gives, at each
    depth from the top and bottom edge, how far in from the side the corner
    cuts. The largest value over all the phones, per depth, is the envelope
    ScreenCorner.iPhone is built from;
  * the phone's `sensorBarImage` (the artwork of its Dynamic Island or notch)
    gives the sensor housing's height as its PDF MediaBox height.

Run it again when a new Xcode adds phones, and update the table and the
clearances in FillEdges.swift if the envelope moved. Needs macOS (`sips`),
Xcode's simulator device profiles and Pillow (`python3 -m pip install pillow`).

    Tools/scripts/measure-iphone-screen-geometry.py [--profiles DIR]
"""

import argparse
import glob
import os
import plistlib
import subprocess
import sys
import tempfile

from PIL import Image

PROFILES = "/Library/Developer/CoreSimulator/Profiles/DeviceTypes"

# The point widths of every iPhone screen. The mask's pixel width is the
# screen's width times some scale (the Air's mask comes at 6x), so the scale
# is whichever one lands on one of these.
POINT_WIDTHS = (375, 390, 393, 402, 414, 420, 428, 430, 440)
SCALES = (1, 2, 3, 4, 6)

DEPTHS = range(0, 81, 5)


def sips_png(pdf, out):
    subprocess.run(
        ["sips", "-s", "format", "png", pdf, "--out", out],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def media_height(pdf):
    """The PDF's page height in points, as sips reports it."""
    out = subprocess.run(
        ["sips", "-g", "pixelHeight", pdf], check=True, capture_output=True, text=True).stdout
    return float(out.split("pixelHeight:")[1].split()[0])


def scale_for(pixel_width):
    for scale in SCALES:
        if pixel_width % scale == 0 and pixel_width // scale in POINT_WIDTHS:
            return scale
    return None


def cut_in(image, row, scale):
    """How far in from the left the screen begins on this pixel row, in points."""
    width, _ = image.size
    pixels = image.load()
    for x in range(width):
        if pixels[x, row][3] > 127:
            return x / scale
    return float(width) / scale


def measure(resources, tmp):
    with open(os.path.join(resources, "profile.plist"), "rb") as f:
        profile = plistlib.load(f)
    mask = profile.get("framebufferMask")
    if not mask:
        return None
    png = os.path.join(tmp, "mask.png")
    sips_png(os.path.join(resources, mask + ".pdf"), png)
    image = Image.open(png).convert("RGBA")
    width, height = image.size
    scale = scale_for(width)
    if scale is None:
        print(f"  unknown width {width}px, skipped", file=sys.stderr)
        return None
    # A square-cornered screen (the home-button phones) has an opaque corner
    # pixel and nothing to measure.
    if image.getpixel((0, 0))[3] > 127 or image.getpixel((0, height - 1))[3] > 127:
        return None
    top = [cut_in(image, min(round(d * scale), height - 1), scale) for d in DEPTHS]
    bottom = [cut_in(image, max(height - 1 - round(d * scale), 0), scale) for d in DEPTHS]
    sensor = profile.get("sensorBarImage")
    sensor_height = None
    if sensor:
        pdf = os.path.join(resources, sensor + ".pdf")
        if os.path.exists(pdf):
            sensor_height = media_height(pdf)
    return width // scale, top, bottom, sensor_height


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--profiles", default=PROFILES)
    args = parser.parse_args()

    paths = sorted(glob.glob(os.path.join(args.profiles, "iPhone*.simdevicetype")))
    if not paths:
        sys.exit(f"no iPhone device profiles under {args.profiles}")

    envelope = {edge: [0.0] * len(DEPTHS) for edge in ("top", "bottom")}
    header = "depth (pt)".ljust(26) + " ".join(f"{d:5d}" for d in DEPTHS)
    print(header)
    with tempfile.TemporaryDirectory() as tmp:
        for path in paths:
            name = os.path.basename(path)[: -len(".simdevicetype")]
            if name == "iPhone Duo":
                continue
            result = measure(os.path.join(path, "Contents", "Resources"), tmp)
            if result is None:
                continue
            points, top, bottom, sensor = result
            for edge, row in (("top", top), ("bottom", bottom)):
                envelope[edge] = [max(a, b) for a, b in zip(envelope[edge], row)]
                print(f"{name[:17]:17s}{points:4d} {edge[:3]:3s} " + " ".join(f"{v:5.1f}" for v in row))
            if sensor:
                print(f"{'':17s}     sensor bar image {sensor:.0f} pt tall")

    print()
    for edge in ("top", "bottom"):
        print(f"envelope, {edge}".ljust(26) + " ".join(f"{v:5.1f}" for v in envelope[edge]))
    both = [max(a, b) for a, b in zip(envelope["top"], envelope["bottom"])]
    print("envelope, both".ljust(26) + " ".join(f"{v:5.1f}" for v in both))


if __name__ == "__main__":
    main()
