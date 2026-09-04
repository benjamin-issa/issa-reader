#!/usr/bin/env bash
#
# Layout sweep: build once, then run the layout invariants on one simulator
# width at a time, keep the screenshots, and delete the device.
#
#   scripts/layout-sweep.sh                     # the three-width quick pass
#   scripts/layout-sweep.sh --all               # every width, plus iPad
#   scripts/layout-sweep.sh --devices 375,440   # named widths
#   scripts/layout-sweep.sh --keep-devices      # leave them, for iterating
#   scripts/layout-sweep.sh --purge             # clean up after a hard kill
#
# Four of this app's recent bugs were one bug: a subview with a rigid minimum
# width larger than its container, or a margin that drifted from the token.
# Every one was found by eye, on one simulator, after shipping. This is the
# same check, made automatic, at every width a phone comes in.
#
# Devices are created and DELETED one at a time. A booted simulator's data
# container runs to hundreds of megabytes, `simctl` never reclaims one, and the
# three already on this machine hold 9.9 GB against 45 GiB free — so seven
# retained devices would grow that on every run. One at a time means peak usage
# is one device, and the trap means a failure still cleans up.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"

RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-26-5"
SCHEME="IssaReader-iOS"
BUNDLE_ID="com.benjaminissa.issareader"
DERIVED="$ROOT/.build/dd-sweep"
WORK="$ROOT/.build/layout-sweep"
OUT="$ROOT/docs/screenshots/sweep"
FIXTURE_READALONG_UUID="11111111-1111-4111-8111-111111111111"

# width | slug | device type | extra
ALL_DEVICES=(
  "375|iphone-se3|com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation|"
  "375|iphone-13-mini|com.apple.CoreSimulator.SimDeviceType.iPhone-13-mini|"
  "390|iphone-16e|com.apple.CoreSimulator.SimDeviceType.iPhone-16e|"
  "402|iphone-17-pro|com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro|"
  "420|iphone-air|com.apple.CoreSimulator.SimDeviceType.iPhone-Air|"
  "440|iphone-17-pro-max|com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max|"
  "820|ipad-a16|com.apple.CoreSimulator.SimDeviceType.iPad-A16|"
  "402|iphone-17-pro-axxl|com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro|content_size=accessibility-extra-large"
)
# 375 is where things break, 440 is where they stop breaking -- the 430-in-402
# bug fitted on a Pro Max, which is exactly why it survived review -- and 402 is
# this machine's daily simulator.
QUICK_SLUGS="iphone-se3 iphone-17-pro iphone-17-pro-max"

MODE=quick
KEEP_DEVICES=0
WANTED=""
for arg in "$@"; do
  case "$arg" in
    --all) MODE=all ;;
    --keep-devices) KEEP_DEVICES=1 ;;
    --devices) MODE=named ;;
    --purge)
      xcrun simctl list devices | grep -o 'issa-sweep-[^ ]*([0-9A-F-]*)' >/dev/null 2>&1 || true
      xcrun simctl list devices -j \
        | python3 -c 'import json,sys;d=json.load(sys.stdin)["devices"];[print(x["udid"]) for v in d.values() for x in v if x["name"].startswith("issa-sweep-")]' \
        | while read -r udid; do echo "  deleting $udid"; xcrun simctl delete "$udid"; done
      exit 0 ;;
    --*) ;;
    *) WANTED="$arg"; MODE=named ;;
  esac
done

SELECTED=()
for row in "${ALL_DEVICES[@]}"; do
  IFS='|' read -r width slug devtype extra <<< "$row"
  case "$MODE" in
    all) SELECTED+=("$row") ;;
    quick) [[ " $QUICK_SLUGS " == *" $slug "* ]] && SELECTED+=("$row") ;;
    named) [[ ",$WANTED," == *",$width,"* || ",$WANTED," == *",$slug,"* ]] && SELECTED+=("$row") ;;
  esac
done
[ ${#SELECTED[@]} -gt 0 ] || { echo "no devices selected" >&2; exit 1; }

CURRENT_UDID=""
cleanup() {
  local status=$?
  if [ -n "$CURRENT_UDID" ] && [ "$KEEP_DEVICES" = 0 ]; then
    echo "  cleaning up $CURRENT_UDID"
    xcrun simctl shutdown "$CURRENT_UDID" >/dev/null 2>&1 || true
    xcrun simctl delete   "$CURRENT_UDID" >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

command -v xcodegen >/dev/null || { echo "xcodegen not found" >&2; exit 1; }
xcodegen generate >/dev/null

# $OUT too, not just $WORK. collect-sweep-shots copies by name and never
# deletes, so an --all run followed by a quick one left five stale device
# folders in place and make-contact-sheet.py sheeted them beside the three
# fresh ones — a regression that only shows at 402pt presented as fixed, with
# nothing marking the panels as coming from different code.
rm -rf "$WORK" "$OUT"; mkdir -p "$WORK" "$OUT"

echo "▸ building once for all destinations"
# Signed, deliberately: CODE_SIGNING_ALLOWED=NO breaks the simulator keychain
# and every background download (docs/VERIFICATION.md). The sweep needs neither,
# but the rule is not worth a special case.
xcodebuild build-for-testing \
    -project IssaReader.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$DERIVED" \
    > "$WORK/build.log" 2>&1 \
  || { echo "build failed — $WORK/build.log" >&2; grep -m 5 "error:" "$WORK/build.log" >&2; exit 1; }

XCTESTRUN=$(ls -t "$DERIVED"/Build/Products/*.xctestrun | head -1)
PRODUCTS="$DERIVED/Build/Products/Debug-iphonesimulator"
APP="$PRODUCTS/IssaReader-iOS.app"

# The reader needs a book on disk: DownloadManager uses a background session,
# which URLProtocol cannot intercept, so the fixture cannot serve one.
python3 Tools/scripts/make-readalong-fixture.py "$WORK/readalong.epub" >/dev/null 2>&1 || true

FAILED=0
RESULTS=()

for row in "${SELECTED[@]}"; do
  IFS='|' read -r width slug devtype extra <<< "$row"
  echo "▸ $slug (${width}pt)"

  CURRENT_UDID=$(xcrun simctl create "issa-sweep-$slug-$$" "$devtype" "$RUNTIME")
  xcrun simctl bootstatus "$CURRENT_UDID" -b >/dev/null

  xcrun simctl ui "$CURRENT_UDID" appearance light >/dev/null 2>&1 || true
  xcrun simctl status_bar "$CURRENT_UDID" override \
      --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
      --cellularMode active --cellularBars 4 \
      --batteryState charged --batteryLevel 100 >/dev/null 2>&1 || true
  case "$extra" in
    content_size=*) xcrun simctl ui "$CURRENT_UDID" content_size "${extra#content_size=}" >/dev/null 2>&1 || true ;;
  esac

  # Install first: there is no data container before one. xcodebuild's own
  # reinstall of the same bundle id below preserves it.
  xcrun simctl install "$CURRENT_UDID" "$APP"
  if [ -f "$WORK/readalong.epub" ]; then
    DATA=$(xcrun simctl get_app_container "$CURRENT_UDID" "$BUNDLE_ID" data)
    mkdir -p "$DATA/Library/Application Support/Books"
    cp "$WORK/readalong.epub" \
       "$DATA/Library/Application Support/Books/$FIXTURE_READALONG_UUID-readaloud.epub"
  fi

  RESULT="$WORK/$slug.xcresult"
  rm -rf "$RESULT"
  set +e
  xcodebuild test-without-building \
      -xctestrun "$XCTESTRUN" \
      -destination "platform=iOS Simulator,id=$CURRENT_UDID" \
      -resultBundlePath "$RESULT" \
      -parallel-testing-enabled NO \
      TEST_RUNNER_ISSA_SWEEP_DEVICE="$slug" \
      > "$WORK/$slug.log" 2>&1
  status=$?
  set -e

  # Extract before deleting the device, and before reacting to the status: a
  # failing sweep is exactly when the screenshots are wanted.
  rm -rf "$WORK/$slug-attachments"
  if ! xcrun xcresulttool export attachments \
      --path "$RESULT" --output-path "$WORK/$slug-attachments" >/dev/null 2>&1; then
    echo "error: could not export attachments for $slug" >&2
    FAILED=1
    RESULTS+=("$slug: attachment export failed")
  elif ! python3 Tools/scripts/collect-sweep-shots.py \
      "$WORK/$slug-attachments" "$OUT/$slug"; then
    echo "error: could not collect screenshots for $slug" >&2
    FAILED=1
    RESULTS+=("$slug: screenshot collection failed")
  fi

  # A scheme whose Test action omits the UI-test target builds fine, runs
  # nothing, and exits 0. That would be the worst outcome this whole exercise
  # can produce, so it is checked rather than assumed.
  if ! xcrun xcresulttool get test-results summary --path "$RESULT" --format json 2>/dev/null \
      | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("totalTestCount",0) > 0 else 1)'; then
    echo "error: zero tests ran on $slug — check the scheme's Test action" >&2
    FAILED=1
    RESULTS+=("$slug: NO TESTS RAN")
  elif [ "$status" -ne 0 ]; then
    FAILED=1
    RESULTS+=("$slug (${width}pt): FAILED — $WORK/$slug.log")
  else
    RESULTS+=("$slug (${width}pt): ok")
  fi

  xcrun simctl shutdown "$CURRENT_UDID" >/dev/null 2>&1 || true
  [ "$KEEP_DEVICES" = 0 ] && xcrun simctl delete "$CURRENT_UDID"
  CURRENT_UDID=""
  rm -rf "$RESULT"
done

# Not `|| true`. Without Pillow the import raises, every device still reported
# "ok", and the script named a sheets directory it had never written — while
# the sheets are documented as the only coverage for inner-padding drift.
if ! python3 Tools/scripts/make-contact-sheet.py "$OUT"; then
  echo "error: contact sheets were not written" >&2
  FAILED=1
  RESULTS+=("contact sheets: FAILED")
fi

echo
echo "── sweep ──"
for line in ${RESULTS[@]+"${RESULTS[@]}"}; do echo "  $line"; done
echo "  screenshots: $OUT"
echo "  contact sheets: $OUT/_sheets"
exit "$FAILED"
