# Issa Reader — App Icon (design 2d)

Selected direction: **2d — book & headphones, "bigger book"**, from the design
canvas's *App Icon 2d Package*. A slate tile, a warm two-tone open book, and
tangerine headphones over it: the read-along duality — text you can hear — in
one mark, with the book scaled to fill the tile so it stays clear at
Home-Screen size.

## What's here

```
Tools/design/app-icon/
├─ ICON.md            ← this spec
├─ icon-default.svg   ← light / "Any" appearance (opaque slate)
├─ icon-dark.svg      ← dark appearance (transparent background)
└─ icon-tinted.svg    ← tinted appearance (grayscale on black)
```

The SVGs are the source of truth for the *drawing*. The shipped PNGs are not
exported from them: `Tools/scripts/icon_mark.py` draws the same geometry with
Pillow at every size the three platforms want, and the two generators install
the results straight into the asset catalogues:

```sh
python3 Tools/scripts/make-app-icon.py /tmp/icons   # iOS + macOS appiconsets
python3 Tools/scripts/make-tvos-assets.py           # tvOS brand assets
```

Change the numbers in one place and the other: `icon_mark.py` carries the
geometry table below, and docs/VERIFICATION.md records how the Pillow output
was diffed against a browser render of these SVGs (mean difference under
0.2/255, the rest antialiasing).

## What each platform gets

- **iOS** — one 1024×1024 PNG per appearance (Any, Dark, Tinted), single-size
  set. No baked corners: the art fills the square and iOS applies the squircle.
  Default and Tinted are opaque (an alpha channel is rejected at upload); Dark
  ships on transparency so the system composites it over its own dark material.
  Tinted is grayscale on solid black, recoloured by luminance to the user's
  home-screen tint.
- **macOS** — the ten-size set (16–512 @1x/@2x) from the Default variant, also
  full-bleed and opaque: macOS 26 masks every icon into its own rounded
  rectangle, and a tile that rounded itself would show a second edge inside it.
- **tvOS** — the mark split across three parallax layers (slate back, book
  middle, headphones front) in the 400×240 / 1280×768 stacks, scaled to nine
  tenths of the short edge and centred; the top-shelf images carry the rounded
  tile on paper, left-weighted.

## Geometry (180×180 design units; × 5.689 → 1024)

| Parameter | Value | Meaning |
|---|---|---|
| page width | 50 | half-book width, each page |
| book top (y) | 70 | top edge of pages |
| book height | 64 | page height |
| page bow | 9 | curve depth of top/bottom edges |
| spine | x=90, y 67.3–134, stroke 3 | between the pages |
| arc radius | 38 | headphone band radius, centre (90, 54) |
| band width | 8 | headphone stroke weight, round caps |
| ear cups | 20×28, r8 | at x=42 and x=118, y=50 — enlarged 2026-09 so the terminals stay legible at notification size |
| vertical shift | `translate(0 11)` | optical centring, applied to the art group and never to the background |

The shift is deliberate: the mark's weight is all in the book, and the airy arc
above it made a geometrically centred mark read as sitting high in the squircle.
Do not "recentre" it to the mathematical middle.

The 2026-09 handoff's own `icon-dark.svg` put the left ear cup outside the
`translate(0 11)` group and the right one inside, so its dark PNG ships with the
cups 11 units apart vertically. The masters here apply the shift to the whole
art group in all three variants, which is what the table above specifies.

## Colours per variant

| Element | Default | Dark | Tinted |
|---|---|---|---|
| Background | `#2F3A3F` (slate) | transparent | `#000000` |
| Page (left) | `#FFFDF8` | `#F2E9D7` | `#CFCFCF` |
| Page (right) | `#E9DEC9` | `#CBBFA6` | `#9C9C9C` |
| Spine | `#2F3A3F` | `#4A4133` | `#000000` |
| Headphones | `#EE9B57` (tangerine) | `#F0A863` | `#E8E8E8` |

Tangerine and slate are the app's own accent and neutral
(`Palette.tangerine`, `Palette.slate` in `Packages/IssaUI`); keep the icon in
step if those change. The tinted variant is deliberately monochrome — its
colour comes from the system tint at render time.

## Later

- Alternative app icons need their own Any/Dark/Tinted trio each; reuse the
  geometry with another palette.
- An Icon Composer `.icon` (the layered Liquid Glass format for iOS and macOS
  26) would replace the PNG set on those platforms; it is a separate design
  deliverable.
