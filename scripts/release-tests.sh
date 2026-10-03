#!/usr/bin/env bash
#
# Release tests: items 1 and 2 of the release rule in CLAUDE.md, in one run.
#
#   scripts/release-tests.sh                   # every package suite, then IssaSharedTests
#   scripts/release-tests.sh --only packages   # the package suites alone
#   scripts/release-tests.sh --only app        # IssaSharedTests alone, on a simulator
#   scripts/release-tests.sh --device "iPhone 17 Pro"   # the device type it creates
#
# Every package suite runs through `swift test --filter`, one at a time (a
# second SwiftPM job waits on the first's .build lock and looks like a hang),
# then IssaSharedTests through `xcodebuild test` on a simulator this script
# creates and deletes.
#
# It sets ISSA_RELEASE_RUN=1, the release switch: a suite whose input is
# absent — the real-alignment EPUBs in /tmp, Apple Intelligence for the
# real-model Ask suites — records an issue instead of skipping. Without it a
# skip is one line among thousands and the run still exits 0, which is how a
# release could pass with the only coverage of what the servers really write
# never having run. On top of the switch, a run fails here if:
#   - any test or suite reports itself skipped;
#   - a suite prints no "Test run with" line (XCTest's "Executed 0 tests" is
#     not that line, and a filter that matched nothing prints no other);
#   - that line says it failed, or ran no tests;
#   - the command itself exited non-zero.
#
# Logs and the verdicts land in .build/release-tests/: one log per suite and
# summary.txt with a PASS or FAIL per suite. Exits 1 if any failed.

set -euo pipefail
# Before the `cd`, so usage can find this file from wherever it was run.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"

usage() { sed -n '5,8p' "$SELF" | sed 's/^# \{0,1\}//' >&2; exit 2; }

PACKAGE_SUITES=(IssaCoreTests IssaEPUBTests IssaRenderTests IssaPlaybackTests IssaUITests IssaAskTests)
RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-27-0"
DEVICE_TYPE="iPhone 17 Pro"
ONLY=all
while [ $# -gt 0 ]; do
  case "$1" in
    --only) [ $# -ge 2 ] || usage; ONLY="$2"; shift ;;
    --device) [ $# -ge 2 ] || usage; DEVICE_TYPE="$2"; shift ;;
    -h|--help) usage ;;
    *) echo "error: unknown argument $1" >&2; usage ;;
  esac
  shift
done
case "$ONLY" in all|packages|app) ;; *) usage ;; esac

export ISSA_RELEASE_RUN=1

OUT="$ROOT/.build/release-tests"
mkdir -p "$OUT"
rm -f "$OUT"/*.log "$OUT/summary.txt"
RESULTS=()
FAILED=0
pass() { RESULTS+=("PASS $1"); }
fail() { RESULTS+=("FAIL $1"); FAILED=1; }

UDID=""
finish() {
  local status=$?
  trap - EXIT
  if [ -n "$UDID" ]; then
    xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
    xcrun simctl delete "$UDID" >/dev/null 2>&1 || true
  fi
  if [ "$status" != 0 ] && [ "$FAILED" = 0 ]; then
    fail "run: stopped early (exit $status); the suites after that point did not run"
  fi
  {
    echo "release run  ISSA_RELEASE_RUN=1"
    # Dirty by `git status`, not `git diff`: a staged change and an untracked
    # source file (SwiftPM and XcodeGen compile every file under Sources) are
    # what was tested too, and `git diff --quiet` sees neither.
    echo "commit       $(git rev-parse --short HEAD 2>/dev/null || echo unknown)$([ -z "$(git status --porcelain 2>/dev/null)" ] || echo ' (dirty)')"
    echo "when         $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    for line in ${RESULTS[@]+"${RESULTS[@]}"}; do echo "$line"; done
  } > "$OUT/summary.txt"
  echo
  cat "$OUT/summary.txt"
  if [ "$status" = 0 ]; then exit "$FAILED"; else exit "$status"; fi
}
trap finish EXIT
trap 'exit 130' INT TERM

# The verdict on one suite's log and exit status, by the rules above.
#
# Swift Testing ends a skipped test's line, or a skipped suite's, with
# "skipped" (and the reason, quoted); XCTest writes "Test Case ... skipped".
# Anchored to the end, so a test whose *name* says "skipped" is not one. Note
# that a run with skips still ends "Test run with ... passed": the run line
# alone cannot be trusted to show them.
SKIPPED='(Test|Suite) .* skipped(: ".*")?\.?$|Test Case .* skipped'
judge() {
  local name="$1" log="$2" status="$3" runline skipped problems=()
  runline=$(grep -E 'Test run with [0-9]+ tests?' "$log" | tail -1 || true)
  skipped=$(grep -cE "$SKIPPED" "$log" || true)
  if [ -z "$runline" ]; then
    problems+=("no \"Test run with\" line, so nothing is known to have run")
  elif grep -qE 'Test run with 0 tests' <<<"$runline"; then
    problems+=("ran no tests")
  elif ! grep -qE 'Test run with [0-9]+ tests? .*passed' <<<"$runline"; then
    problems+=("${runline#*Test run with }")
  fi
  if [ "$skipped" -gt 0 ]; then
    problems+=("$skipped skipped, and on a release run every test runs: $(grep -m 3 -E "$SKIPPED" "$log" | sed 's/^[^A-Za-z]*//' | tr '\n' ' ')")
  fi
  if [ "$status" != 0 ] && [ ${#problems[@]} = 0 ]; then
    problems+=("exit $status after \"${runline#*Test run with }\"")
  fi
  if [ ${#problems[@]} = 0 ]; then
    pass "$name: ${runline#*Test run with }"
  else
    local joined
    joined=$(printf '%s; ' "${problems[@]}")
    fail "$name: ${joined%; } (see $log)"
  fi
}

# Left out on purpose, and named rather than filtered by a pattern: suites
# that are opt-in by design and not release checks. AskScorecardTests
# records a scorecard on request (ISSA_ASK_SCORECARD) rather than asserting;
# RethinkExperiments records the Ask design experiments on request
# (ISSA_ASK_RETHINK). Both would otherwise report themselves skipped.
skip_args() {
  case "$1" in
    IssaAskTests) echo "--skip AskScorecardTests --skip RethinkExperiments" ;;
  esac
}

if [ "$ONLY" != app ]; then
  for suite in "${PACKAGE_SUITES[@]}"; do
    echo "▸ $suite"
    set +e
    # shellcheck disable=SC2046 # skip_args is flags and plain names, or nothing
    swift test --filter "$suite" $(skip_args "$suite") > "$OUT/$suite.log" 2>&1
    status=$?
    set -e
    judge "$suite" "$OUT/$suite.log" "$status"
  done
fi

if [ "$ONLY" != packages ]; then
  echo "▸ IssaSharedTests on a new $DEVICE_TYPE simulator"
  command -v xcodegen >/dev/null || { fail "IssaSharedTests: xcodegen not found"; exit 1; }
  xcodegen generate >/dev/null
  UDID=$(xcrun simctl create "issa-release-tests-$$" "$DEVICE_TYPE" "$RUNTIME")
  xcrun simctl bootstatus "$UDID" -b > "$OUT/boot.log" 2>&1
  set +e
  # Signed, deliberately: CODE_SIGNING_ALLOWED=NO loses the simulator
  # keychain, which the app suite's sign-in tests stand on.
  #
  # `-collect-test-diagnostics never`: without it Xcode 27 runs `simctl
  # diagnose` after the session and waits on it indefinitely.
  TEST_RUNNER_ISSA_RELEASE_RUN=1 \
  xcodebuild test \
      -project IssaReader.xcodeproj \
      -scheme IssaReader-iOS \
      -destination "platform=iOS Simulator,id=$UDID" \
      -derivedDataPath "$ROOT/.build/dd-release-tests" \
      -only-testing:IssaSharedTests \
      -collect-test-diagnostics never \
      > "$OUT/IssaSharedTests.log" 2>&1
  status=$?
  set -e
  judge IssaSharedTests "$OUT/IssaSharedTests.log" "$status"
fi

exit "$FAILED"
