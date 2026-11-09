#!/usr/bin/env bash
#
# Android Auto check: the car's half of the live checks, on a phone running
# Issa Reader, through Google's Desktop Head Unit (DHU).
#
#   scripts/android-auto-check.sh <label>
#   scripts/android-auto-check.sh <label> --server http://<lan-address>:8003
#   scripts/android-auto-check.sh <label> --serial <adb-serial> --no-dhu
#
# CarPlay has no headless harness on iOS either; this is the Android Auto
# counterpart of checking CarPlay by hand, made into a record. It checks what
# can be checked from the command line (adb, the phone, the app, Android Auto,
# the head unit), starts the DHU, then walks a prompted checklist — the three
# tabs and what each holds, playing from Recent, the chapter queue, the rate
# button, voice search, the steering wheel under the bindings, the error when
# signed out and the hand-off back to the reader when the car goes — asking
# PASS or FAIL for each. It captures `adb shell dumpsys media_session` while a
# book plays and at the end, and checks the session is this app's and playing.
#
# Before running: on the phone, open Android Auto's settings, tap the version
# ten times to enable developer mode, and choose "Start head unit server" from
# the overflow menu. The phone must be signed in to the server being checked
# (the release rule's servers are in Tools/docker/compose.yaml).
#
# The record is .build/android-auto-check/<label>.txt: the server, the phone,
# the head unit, and a PASS or FAIL per check; the media session dumps sit
# beside it as <label>-media_session*.txt and the DHU's output as
# <label>-dhu.log. Exits 1 if any check failed.
#
# The DHU is $ANDROID_HOME/extras/google/auto/desktop-head-unit, which the SDK
# Manager installs as "Android Auto Desktop Head Unit Emulator".

set -euo pipefail
# Taken before the `cd`, as live-check.sh takes it: from the root a relative
# `$0` names nothing.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"

usage() { sed -n '6,8p' "$SELF" | sed 's/^# \{0,1\}//' >&2; exit 2; }

APP_ID=com.benjaminissa.issareader
GEARHEAD=com.google.android.projection.gearhead

LABEL=""
SERVER=""
SERIAL=""
DHU=1
BAD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --server) if [ $# -ge 2 ]; then SERVER="${2%/}"; shift; else BAD="--server needs a URL"; fi ;;
    --serial) if [ $# -ge 2 ]; then SERIAL="$2"; shift; else BAD="--serial needs an adb serial"; fi ;;
    --no-dhu) DHU=0 ;;
    -h|--help) usage ;;
    --*) BAD="unknown option $1" ;;
    *) if [ -z "$LABEL" ]; then LABEL="$1"; else BAD="unexpected argument $1"; fi ;;
  esac
  shift
done
[ -n "$LABEL" ] || usage
# The label names files this script replaces.
case "$LABEL" in
  *[!A-Za-z0-9._-]*|.|..)
    echo "error: a label is letters, digits, dots, dashes and underscores" >&2; exit 2 ;;
esac

# ── The record ────────────────────────────────────────────────────────────
#
# Set up before anything can refuse the run, as live-check.sh's is: a refused
# run that left the label's last record in place — all PASS, perhaps — would
# look like a run that passed.

OUT="$ROOT/.build/android-auto-check"
RECORD="$OUT/$LABEL.txt"
mkdir -p "$OUT"
rm -f "$RECORD" "$OUT/$LABEL"-media_session*.txt "$OUT/$LABEL-dhu.log"
RESULTS=()
FAILED=0
pass() { RESULTS+=("PASS $1"); }
fail() { RESULTS+=("FAIL $1"); FAILED=1; }
skip() { RESULTS+=("SKIP $1"); }
die() { echo "error: $1" >&2; fail "setup: $1"; exit 1; }
refuse() { echo "error: $1" >&2; fail "arguments: $1"; exit 2; }

GENERATION="unknown"
PHONE="unknown"
DHU_PID=""
stop_dhu() { if [ -n "$DHU_PID" ]; then kill "$DHU_PID" >/dev/null 2>&1 || true; DHU_PID=""; fi; }

# Written on the way out, whatever the way out is: a run that stops early is
# a failed run, and says so, with the verdicts it had already reached.
finish() {
  local status=$?
  trap - EXIT
  stop_dhu
  if [ -n "${ADB_OK:-}" ]; then adb_ forward --remove tcp:5277 >/dev/null 2>&1 || true; fi
  if [ "$status" != 0 ] && [ "$FAILED" = 0 ]; then
    fail "run: stopped early (exit $status); the checks after that point did not run"
  fi
  {
    echo "server   ${SERVER:-not given} ($GENERATION)"
    echo "phone    $PHONE"
    echo "app      $APP_ID ${APP_VERSION:-}"
    echo "auto     ${AUTO_VERSION:-not found}"
    echo "label    $LABEL"
    echo "when     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    for line in ${RESULTS[@]+"${RESULTS[@]}"}; do echo "$line"; done
  } > "$RECORD"
  cat "$RECORD"
  if [ "$status" = 0 ]; then exit "$FAILED"; else exit "$status"; fi
}
trap finish EXIT
trap 'exit 130' INT TERM

if [ -n "$BAD" ]; then
  sed -n '6,8p' "$SELF" | sed 's/^# \{0,1\}//' >&2
  refuse "$BAD"
fi
# The checklist asks; with no one to answer there is no run.
( : < /dev/tty ) 2>/dev/null || refuse "this check is interactive: run it from a terminal"

# ── The phone ─────────────────────────────────────────────────────────────

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if ! command -v adb >/dev/null 2>&1 && [ -n "$SDK" ] && [ -x "$SDK/platform-tools/adb" ]; then
  PATH="$SDK/platform-tools:$PATH"
fi
command -v adb >/dev/null 2>&1 || die "adb not found: install the SDK's platform-tools, or put adb on PATH"
pass "setup: adb $(adb version | head -1 | awk '{print $NF}')"

if [ -z "$SERIAL" ]; then
  DEVICES=$(adb devices | awk 'NR > 1 && $2 == "device" {print $1}')
  case "$(printf '%s\n' "$DEVICES" | grep -c .)" in
    0) die "no phone: connect one with USB debugging on (adb devices lists none)" ;;
    1) SERIAL="$DEVICES" ;;
    *) die "more than one phone: name one with --serial ($(echo $DEVICES))" ;;
  esac
fi
adb_() { adb -s "$SERIAL" "$@"; }
adb_ get-state >/dev/null 2>&1 || die "adb cannot reach $SERIAL"
ADB_OK=1
PHONE="$(adb_ shell getprop ro.product.model | tr -d '\r') (Android $(adb_ shell getprop ro.build.version.release | tr -d '\r'), $SERIAL)"
pass "setup: phone $PHONE"

APP_VERSION=$(adb_ shell dumpsys package "$APP_ID" | sed -n 's/.*versionName=\([^ ]*\).*/\1/p' | head -1 | tr -d '\r')
[ -n "$APP_VERSION" ] || die "$APP_ID is not installed on the phone: ./gradlew :app:installDebug"
pass "setup: Issa Reader $APP_VERSION installed"

AUTO_VERSION=$(adb_ shell dumpsys package "$GEARHEAD" | sed -n 's/.*versionName=\([^ ]*\).*/\1/p' | head -1 | tr -d '\r')
[ -n "$AUTO_VERSION" ] || die "Android Auto ($GEARHEAD) is not installed on the phone"
pass "setup: Android Auto $AUTO_VERSION installed"

# The service Android Auto binds, as the phone's package manager sees it: an
# app whose manifest lost the browser service is invisible to the car.
if adb_ shell cmd package query-services -a android.media.browse.MediaBrowserService 2>/dev/null | grep -q "$APP_ID"; then
  pass "setup: the media browser service is declared"
else
  fail "setup: no MediaBrowserService from $APP_ID: Android Auto will not list the app"
fi

# ── The server ────────────────────────────────────────────────────────────
#
# Named, so the record says which generation the car was checked against, as
# the release rule asks. Optional: the phone is what talks to it.

if [ -z "$SERVER" ]; then
  printf 'Which server is the phone signed in to? (a URL, or Enter to leave it out) ' > /dev/tty
  read -r SERVER < /dev/tty || true
  SERVER="${SERVER%/}"
fi
if [ -n "$SERVER" ]; then
  case "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$SERVER/api/v2/server/public" || true)" in
    404) GENERATION=v2 ;;
    200) GENERATION=v3 ;;
    *) GENERATION="unreachable from here" ;;
  esac
fi

# ── The head unit ─────────────────────────────────────────────────────────

ask_enter() {
  printf '%s\n  Press Enter when done. ' "$1" > /dev/tty
  read -r _ < /dev/tty || true
}

if [ "$DHU" = 1 ]; then
  DHU_BIN="$SDK/extras/google/auto/desktop-head-unit"
  [ -n "$SDK" ] || die "ANDROID_HOME is not set, so the head unit cannot be found"
  [ -x "$DHU_BIN" ] || die "no head unit at $DHU_BIN: install \"Android Auto Desktop Head Unit Emulator\" in the SDK Manager"
  ask_enter "On the phone: Android Auto › Settings, tap Version ten times for developer mode, then ⋮ › Start head unit server."
  adb_ forward tcp:5277 tcp:5277 >/dev/null || die "could not forward tcp:5277 to the phone's head unit server"
  pass "setup: tcp:5277 forwarded"
  # Its own directory, as the DHU reads its configuration from where it runs.
  (cd "$(dirname "$DHU_BIN")" && exec "$DHU_BIN") > "$OUT/$LABEL-dhu.log" 2>&1 < /dev/null &
  DHU_PID=$!
  sleep 5
  kill -0 "$DHU_PID" 2>/dev/null || { DHU_PID=""; die "the head unit exited at once: see $OUT/$LABEL-dhu.log (is the head unit server running?)"; }
  pass "setup: the head unit is running"
else
  skip "setup: head unit not started (--no-dhu): a car is assumed"
fi

# ── The media session ─────────────────────────────────────────────────────

# Saves the session dump under [suffix] and says whether this app's session
# is the one playing: `state=3` is PlaybackState.STATE_PLAYING.
dump_session() {
  local file="$OUT/$LABEL-media_session$1.txt"
  adb_ shell dumpsys media_session > "$file" 2>&1 || true
  python3 - "$file" "$APP_ID" <<'PY'
import re, sys
lines = open(sys.argv[1], errors="replace").read().splitlines()
package = sys.argv[2]
# Each session's record has a `package=` line a couple of lines under its
# header; a record runs from there to the next one's. Take ours.
starts = [i for i, line in enumerate(lines) if line.strip().startswith("package=")]
ours = []
for n, i in enumerate(starts):
    if lines[i].strip() != "package=" + package:
        continue
    end = starts[n + 1] - 2 if n + 1 < len(starts) else len(lines)
    ours.append("\n".join(lines[max(i - 2, 0):end]))
if not ours:
    print("FAIL no media session from " + package)
    sys.exit()
playing = any(re.search(r"state=PlaybackState \{state=(3|PLAYING)", b) for b in ours)
active = any(re.search(r"active=true", b) for b in ours)
print(("PASS" if playing else "FAIL") + " session " + ("playing" if playing else "not playing") + (", active" if active else ", inactive"))
PY
}

# ── The checklist ─────────────────────────────────────────────────────────
#
# One question per check, in the order a drive takes. y passes, n fails (with
# a note saying what was seen), s skips — and a skipped check is said in the
# record, never counted as a pass.

check() {
  local name="$1" instruction="$2" answer note
  printf '\n▸ %s\n  %s\n' "$name" "$instruction" > /dev/tty
  while true; do
    printf '  Pass? [y/n/s] ' > /dev/tty
    read -r answer < /dev/tty || answer=s
    case "$answer" in
      y|Y) pass "$name"; return ;;
      n|N)
        printf '  What did the car show? ' > /dev/tty
        read -r note < /dev/tty || note=""
        fail "$name: ${note:-no note}"; return ;;
      s|S) skip "$name"; return ;;
    esac
  done
}

check "tabs" \
  "The car lists Issa Reader; opening it shows three tabs: Recent, Library, Downloaded."
check "recent" \
  "Recent lists the books in progress, most recent first, each \"author · Xh Ym left\" with a progress bar and a square cover. No book from the phone's own files appears in any tab."
check "library" \
  "Library lists every book with audio, A to Z; text-only books are absent."
check "downloaded" \
  "Downloaded lists only books downloaded on this phone, marked as downloaded; with none, it says \"No downloads on this phone\"."
check "empty-messages" \
  "A tab with nothing in it says why (\"Nothing started yet\", \"No audiobooks in your library\", \"No downloads on this phone\") rather than showing a blank list. (Skip if no tab is empty.)"
check "play-from-recent" \
  "Tap the top book in Recent: Now Playing shows its title, author, chapter and cover, and it plays from where it was left."

PLAYING=$(dump_session "-playing")
case "$PLAYING" in
  PASS*) pass "media session while playing: ${PLAYING#PASS }" ;;
  *) fail "media session while playing: ${PLAYING#FAIL }" ;;
esac

check "chapter-queue" \
  "Open the queue on Now Playing (\"Chapters\"): the chapter playing is marked. Pick another: it plays from that chapter's start."
check "rate-button" \
  "Press the speed button five times: 1.25×, 1.5×, 1.75×, 2×, back to 1×. The phone's own speed setting follows."
check "voice-search" \
  "Say \"Hey Google, play <a title from Library> on Issa Reader\" (or use the mic on the DHU): that book plays. Then \"play Issa Reader\": the most recent book resumes."
check "skip-buttons" \
  "With the default Android Auto bindings, the transport shows ⏮ ⏭ and the wheel's » and « (DHU console: keycode media_next, keycode media_previous) skip 30 seconds on and 15 back — never a chapter."
check "wheel-bindings" \
  "On the phone, Settings › Controls › Android Auto: bind Wheel » to Next chapter. keycode media_next now plays the next chapter. Put the binding back."
check "phone-bindings" \
  "With nothing bound to the phone's wheel, the phone's media notification shows ⏪15 and ⏩30, not ⏮ ⏭, once the car has gone (check after the hand-off below if easier)."
check "signed-out" \
  "Sign out on the phone: the car says \"Sign in on your phone\" and offers to open the app; signing back in brings the tabs back."
check "disconnect-handoff" \
  "Play a read-along from the car, open the same book in the reader on the phone, then end the car session (close the DHU, or stop the head unit server). The reader picks up the narration at the car's sentence, without jumping back."

FINAL=$(dump_session "")
case "$FINAL" in
  *"no media session"*) skip "media session at the end: none (nothing loaded)" ;;
  *) pass "media session at the end: captured (${FINAL#* })" ;;
esac

# The record is written by `finish`, on the way out.
exit "$FAILED"
