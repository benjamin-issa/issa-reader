#!/usr/bin/env bash
#
# Android release tests: items 1 and 2 of the release rule in CLAUDE.md, for
# the Android app, in one run.
#
#   scripts/android-release-tests.sh                       # every module's suites
#   scripts/android-release-tests.sh --ask-device SERIAL   # and the real-model Ask suites on that phone
#
# Every module's JVM and Robolectric suites run through Gradle, one module at
# a time, reading the same captured responses and books as the Swift suites
# (every Storyteller generation's, from Packages/*/Tests/Fixtures). The
# screenshot baselines are verified after them.
#
# It sets ISSA_RELEASE_RUN=1, the release switch: a suite whose input is
# absent — the real-alignment EPUBs in /tmp, the parity goldens the Mac writes
# — fails instead of skipping. On top of the switch, a module fails here if:
#   - any test in it reports itself skipped;
#   - it ran no tests at all;
#   - any test failed or errored;
#   - Gradle itself exited non-zero.
#
# The real-model Ask suites need Gemini Nano, which no emulator has. With
# --ask-device they run on that phone (adb serial) and must pass; without it
# the summary records them as not run, which the release rule allows only
# when no Gemini Nano phone is to hand.
#
# Logs and the verdicts land in .build/android-release-tests/: one log per
# module and summary.txt with a PASS or FAIL per module. Exits 1 if any failed.

set -euo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"

usage() { sed -n '5,6p' "$SELF" | sed 's/^# \{0,1\}//' >&2; exit 2; }

# Module and the Gradle task that runs its suites.
MODULES=(
  "core:test" "epub:test" "render:test" "playback:test" "ask:test"
  "ui:testDebugUnitTest" "render-android:testDebugUnitTest"
  "playback-android:testDebugUnitTest" "ask-android:testDebugUnitTest"
  "app:testDebugUnitTest"
)
ASK_DEVICE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ask-device) [ $# -ge 2 ] || usage; ASK_DEVICE="$2"; shift ;;
    -h|--help) usage ;;
    *) echo "error: unknown argument $1" >&2; usage ;;
  esac
  shift
done

export ISSA_RELEASE_RUN=1

OUT="$ROOT/.build/android-release-tests"
mkdir -p "$OUT"
rm -f "$OUT"/*.log "$OUT/summary.txt"
RESULTS=()
FAILED=0
# shasum on the Mac, sha256sum elsewhere.
sha256() { if command -v shasum >/dev/null; then shasum -a 256 "$1"; else sha256sum "$1"; fi; }
pass() { RESULTS+=("PASS $1"); }
fail() { RESULTS+=("FAIL $1"); FAILED=1; }
note() { RESULTS+=("NOT RUN $1"); }

finish() {
  local status=$?
  trap - EXIT
  if [ "$status" != 0 ] && [ "$FAILED" = 0 ]; then
    fail "run: stopped early (exit $status); the modules after that point did not run"
  fi
  {
    echo "release run  ISSA_RELEASE_RUN=1 (Android)"
    echo "commit       $(git rev-parse --short HEAD 2>/dev/null || echo unknown)$([ -z "$(git status --porcelain 2>/dev/null)" ] || echo ' (dirty)')"
    echo "when         $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for book in /tmp/pw2.epub /tmp/pw3.epub /tmp/pw3-loop.epub /tmp/pw3-beta46.epub /tmp/pw3-loop-beta46.epub /tmp/pw3-beta40.epub /tmp/pw3-loop-beta40.epub; do
      if [ -f "$book" ]; then
        echo "staged       $book sha256 $(sha256 "$book" | cut -c1-16)"
      else
        echo "staged       $book absent"
      fi
    done
    echo
    for line in ${RESULTS[@]+"${RESULTS[@]}"}; do echo "$line"; done
  } > "$OUT/summary.txt"
  echo
  cat "$OUT/summary.txt"
  if [ "$status" = 0 ]; then exit "$FAILED"; else exit "$status"; fi
}
trap finish EXIT
trap 'exit 130' INT TERM

# The verdict on one module, from its JUnit XML: totals, and the first few
# skipped or failing tests by name.
judge() {
  local name="$1" results="$2" log="$3" status="$4" verdict
  verdict=$(python3 -I - "$results" <<'PY'
import glob, sys, xml.etree.ElementTree as ET
tests = skipped = failed = 0
named = []
for path in sorted(glob.glob(sys.argv[1] + "/*.xml")):
    suite = ET.parse(path).getroot()
    tests += int(suite.get("tests", 0))
    skipped += int(suite.get("skipped", 0))
    failed += int(suite.get("failures", 0)) + int(suite.get("errors", 0))
    for case in suite.iter("testcase"):
        for kind in ("skipped", "failure", "error"):
            if case.find(kind) is not None and len(named) < 3:
                named.append(f"{kind}: {case.get('classname', '').rsplit('.', 1)[-1]}.{case.get('name')}")
problems = []
if tests == 0:
    problems.append("ran no tests")
if failed:
    problems.append(f"{failed} failed")
if skipped:
    problems.append(f"{skipped} skipped, and on a release run every test runs")
print(f"{tests} tests" + ("" if not problems else " | " + "; ".join(problems) + " | " + ", ".join(named)))
PY
)
  if [[ "$verdict" == *"|"* ]] || [ "$status" != 0 ]; then
    fail "$name: $verdict$([ "$status" = 0 ] || echo " (gradle exit $status)") (see $log)"
  else
    pass "$name: $verdict"
  fi
}

cd "$ROOT/Android"
for entry in "${MODULES[@]}"; do
  module="${entry%%:*}"
  task="${entry#*:}"
  echo "▸ :$module:$task"
  rm -rf "$module/build/test-results/$task"
  set +e
  ./gradlew ":$module:$task" --console=plain > "$OUT/$module.log" 2>&1
  status=$?
  set -e
  judge ":$module" "$module/build/test-results/$task" "$OUT/$module.log" "$status"
done

echo "▸ screenshot baselines"
set +e
./gradlew verifyRoborazziDebug --console=plain > "$OUT/screenshots.log" 2>&1
status=$?
set -e
if [ "$status" = 0 ]; then pass "screenshots: match their baselines"; else fail "screenshots: differ from their baselines (see $OUT/screenshots.log)"; fi

if [ -n "$ASK_DEVICE" ]; then
  echo "▸ real-model Ask suites on $ASK_DEVICE"
  # The two opt-in recorders are left out by name, as the Swift run leaves out
  # AskScorecardTests and RethinkExperiments: unasked, they would skip.
  rm -rf ask-android/build/outputs/androidTest-results/connected
  set +e
  ANDROID_SERIAL="$ASK_DEVICE" ./gradlew :ask-android:connectedDebugAndroidTest \
      -Pandroid.testInstrumentationRunnerArguments.ISSA_RELEASE_RUN=1 \
      -Pandroid.testInstrumentationRunnerArguments.notClass=com.benjaminissa.issareader.ask.android.AskScorecardTest,com.benjaminissa.issareader.ask.android.RethinkExperiments \
      --console=plain > "$OUT/ask-device.log" 2>&1
  status=$?
  set -e
  judge "Ask on $ASK_DEVICE" "ask-android/build/outputs/androidTest-results/connected/debug" "$OUT/ask-device.log" "$status"
else
  note "real-model Ask suites: no Gemini Nano phone named (--ask-device); the release rule allows this only when none is to hand"
fi

exit "$FAILED"
