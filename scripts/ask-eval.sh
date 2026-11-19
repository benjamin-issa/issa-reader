#!/usr/bin/env bash
#
# Runs the Ask accuracy study, or the Private Cloud Compute spike, on this Mac.
#
#   ISSA_ASK_EVAL_CORPUS=/abs/corpus.json ISSA_ASK_EVAL_OUT=/abs/results.jsonl \
#       scripts/ask-eval.sh [--variants D0,C1] [--only id1,id2]
#   scripts/ask-eval.sh --spike [--asks 5]
#   scripts/ask-eval.sh --probe          # the smallest requests, 90 s each
#
# Both run in IssaMacEvalTests, hosted by the Debug Mac app signed with the
# Mac development profile named in Signing.xcconfig (ISSA_MACOS_EVAL_PROFILE).
# That is the only signing that gives a build this Mac can run the Private
# Cloud Compute entitlement: `swift test` binaries are unsigned, the Developer
# ID profile Debug normally uses cannot carry it, and in the iOS Simulator the
# model reports itself available but a request never comes back.
#
# The host app opens its window while the tests run. Nothing here names a book:
# the corpus and the results live wherever the two variables point, and the
# console carries counts only.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE=study
VARIANTS=""
ONLY=""
ASKS=3
SPIKE=1
while [ $# -gt 0 ]; do
    case "$1" in
        --spike) MODE=spike; shift ;;
        --probe) MODE=spike; SPIKE=probe; shift ;;
        --asks) ASKS="$2"; shift 2 ;;
        --variants) VARIANTS="$2"; shift 2 ;;
        --only) ONLY="$2"; shift 2 ;;
        -h|--help) sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [ "$MODE" = study ]; then
    : "${ISSA_ASK_EVAL_CORPUS:?set ISSA_ASK_EVAL_CORPUS to the corpus JSON}"
    : "${ISSA_ASK_EVAL_OUT:?set ISSA_ASK_EVAL_OUT to the results file}"
fi

# Signing.xcconfig, then Signing.local.xcconfig, as Xcode reads them.
signing_value() {
    local key="$1" value=""
    for file in Signing.xcconfig Signing.local.xcconfig; do
        [ -f "$file" ] || continue
        local found
        found=$(sed -n "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*\(.*\)$/\1/p" "$file" | tail -1)
        [ -n "$found" ] && value="$found"
    done
    printf '%s' "$value"
}
PROFILE=$(signing_value ISSA_MACOS_EVAL_PROFILE)
[ -n "$PROFILE" ] || { echo "ISSA_MACOS_EVAL_PROFILE is not set in Signing.xcconfig" >&2; exit 1; }

# One heavy job at a time on a shared machine.
until mkdir /tmp/mac-heavy-job.lock 2>/dev/null; do
    echo "waiting for /tmp/mac-heavy-job.lock ($(cat /tmp/mac-heavy-job.lock/owner 2>/dev/null))"
    sleep 30
done
echo "issa-reader: ask-eval $MODE" > /tmp/mac-heavy-job.lock/owner
trap 'rm -rf /tmp/mac-heavy-job.lock' EXIT

WORK="$ROOT/.build/ask-eval"
DD="$ROOT/.build/dd-ask-eval"
mkdir -p "$WORK"
xcodegen generate >/dev/null

echo "▸ building the host and the suite"
xcodebuild build-for-testing \
    -project IssaReader.xcodeproj -scheme IssaMacEval -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$DD" \
    ISSA_MACOS_DEBUG_IDENTITY="Apple Development" \
    ISSA_MACOS_DEBUG_PROFILE="$PROFILE" \
    ISSA_MACOS_DEBUG_ENTITLEMENTS=Apps/IssaReader-macOS/IssaReader-Eval.entitlements \
    > "$WORK/build.log" 2>&1 \
  || { echo "build failed — $WORK/build.log" >&2; grep -m 10 'error:' "$WORK/build.log" >&2; exit 1; }

XCTESTRUN=$(ls -t "$DD"/Build/Products/IssaMacEval_*.xctestrun | grep -v '/run-' | head -1)
RUN="$(dirname "$XCTESTRUN")/run-$MODE.xctestrun"
cp "$XCTESTRUN" "$RUN"
# Xcode 27.1 drops TEST_RUNNER_ settings given beside -xctestrun, so the
# environment goes into a copy of the run file.
setenv() { plutil -replace "IssaMacEvalTests.EnvironmentVariables.$1" -string "$2" "$RUN"; }
if [ "$MODE" = spike ]; then
    setenv ISSA_PCC_SPIKE "$SPIKE"
    setenv ISSA_PCC_SPIKE_ASKS "$ASKS"
    SUITE=PrivateCloudSpikeTests
else
    setenv ISSA_ASK_EVAL_CORPUS "$ISSA_ASK_EVAL_CORPUS"
    setenv ISSA_ASK_EVAL_OUT "$ISSA_ASK_EVAL_OUT"
    [ -n "$VARIANTS" ] && setenv ISSA_ASK_EVAL_VARIANTS "$VARIANTS"
    [ -n "$ONLY" ] && setenv ISSA_ASK_EVAL_ONLY "$ONLY"
    SUITE=AskEvalRunner
fi

LOG="$WORK/$MODE-$(date +%Y%m%d-%H%M%S).log"
echo "▸ running $SUITE — $LOG"
set +e
xcodebuild test-without-building -xctestrun "$RUN" -destination 'platform=macOS' \
    -only-testing:"IssaMacEvalTests/$SUITE" -collect-test-diagnostics never > "$LOG" 2>&1
STATUS=$?
set -e
grep -E '^\[(pcc-spike|ask-eval)\]' "$LOG" | cut -c1-400 || true
grep -E 'Test run with|✘' "$LOG" | tail -5 || true
exit $STATUS
