#!/usr/bin/env bash
#
# The Android layout sweep: item 5 of CLAUDE.md's Android release rule.
#
#   scripts/android-layout-sweep.sh
#
# Draws the app's screens — sign-in, the device code, the library and its
# grid, Reading, a book's page and a series, light and dark — against the
# built-in fixture library at five widths: the iPhone sweep's three (375, 402
# and 440) so the sheets compare panel for panel with
# docs/screenshots/sweep/_sheets, and the two most Android phones are (360
# and 412). The app runs whole under Robolectric, its real sign-in and library
# paths against the fixture server, so no device or server is needed.
#
# The screenshots land in docs/screenshots/android-sweep/<width>dp/ (ignored by
# git), and one contact sheet per screen in docs/screenshots/android-sweep/_sheets
# (kept), drawn by the iPhone sweep's own Tools/scripts/make-contact-sheet.py
# with a hairline at the screen margin each run measured. Compare them by eye
# with the iPhone's: as on the iPhone, they are the only coverage for a control
# whose inner padding drifted, which no assertion can see.
#
# Exits 1 if the screenshots could not be drawn or a sheet could not be made.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"

OUT="$ROOT/docs/screenshots/android-sweep"
SHOTS="$ROOT/Android/app/build/sweep"
WIDTHS=(360 375 402 412 440)

command -v python3 >/dev/null || { echo "error: python3 not found" >&2; exit 1; }
python3 -c 'import PIL' 2>/dev/null || { echo "error: the contact sheets need Pillow (pip3 install pillow)" >&2; exit 1; }

echo "▸ drawing the screens at ${WIDTHS[*]} dp (log: $ROOT/.build/android-layout-sweep.log)"
mkdir -p "$ROOT/.build"
rm -rf "$SHOTS"
# --rerun: the pictures are the point, and Gradle would otherwise call an
# unchanged test task up to date and draw nothing.
if ! (cd "$ROOT/Android" && ./gradlew :app:testDebugUnitTest --rerun --tests '*Sweep*ScreenshotTest' \
        -Proborazzi.test.record=true --console=plain) > "$ROOT/.build/android-layout-sweep.log" 2>&1; then
  echo "error: the sweep's screenshot tests failed; see .build/android-layout-sweep.log" >&2
  exit 1
fi

# Each width's folder replaced whole, so a screen dropped from the sweep does
# not leave last run's picture on a sheet. The sheets are kept until they are
# drawn again.
missing=0
for width in "${WIDTHS[@]}"; do
  from="$SHOTS/$width"
  to="$OUT/${width}dp"
  if [ ! -f "$from/reference.txt" ] || ! ls "$from"/*.png >/dev/null 2>&1; then
    echo "error: no screenshots, or no reference.txt, at $width dp" >&2
    missing=1
    continue
  fi
  rm -rf "$to"
  mkdir -p "$to"
  cp "$from"/*.png "$from/reference.txt" "$to/"
done
[ "$missing" = 0 ] || exit 1

echo "▸ contact sheets"
python3 -I Tools/scripts/make-contact-sheet.py "$OUT"
echo
echo "Sheets: $OUT/_sheets — compare with docs/screenshots/sweep/_sheets."
