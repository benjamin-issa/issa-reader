#!/usr/bin/env bash
#
# Live checks: item 3 of CLAUDE.md's Android release rule, on an Android phone
# or emulator, against one running Storyteller.
#
#   scripts/android-live-check.sh http://<lan-address>:8001 v2-android
#   scripts/android-live-check.sh http://<lan-address>:8003 v3-android --serial emulator-5554
#   scripts/android-live-check.sh <server> <label> --audio    # also a read-along, out of the speaker
#   scripts/android-live-check.sh <server> <label> --fresh    # accepted; every run pairs afresh (below)
#
# The Android twin of scripts/live-check.sh, and the same checks: it signs the
# real app in by device code, then looks at what a reader would see — the
# library, the session outliving the covers, Settings › Advanced's server
# version, a book's status label, a page read, and with --audio a read-along
# playing past the end of its first audio file. The screen is driven by
# Android/app/src/androidTest's LiveCheckTest; this script sets the server up
# for it, approves the pairing code it writes out, and checks over the API
# what the screen cannot show.
#
# The server half — the books it looks up, the positions and statuses it puts
# back first, and the verdicts it reads afterwards — is live-check.sh's, line
# for line, so the two platforms are judged the same way. Change both together.
#
# Every run is a fresh pairing. The app is uninstalled first, which on Android
# takes its Keystore key and so its token with it (the iPhone's keychain
# outlives an uninstall, hence that script's --fresh); and its data is cleared
# after the install, so nothing restored from a backup is left either.
#
# Everything lands in .build/android-live-check/<label>/: summary.txt with a
# PASS or FAIL per check, the screenshots, the app's log and the
# instrumentation output. Exits 1 if any check failed.
#
# The phone has to reach the server: give a phone or an emulator the machine's
# LAN address, never 10.0.2.2, since the server's sign-in must see one host.
#
# Books are found by title, as live-check.sh finds them:
#   LIVE_STATUS_TITLE, LIVE_READ_TITLE, LIVE_READALONG_TITLE, LIVE_READALONG_SECONDS

set -euo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"

usage() { sed -n '6,9p' "$SELF" | sed 's/^# \{0,1\}//' >&2; exit 2; }

SERVER=""
LABEL=""
SERIAL=""
AUDIO=0
BAD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --serial) if [ $# -ge 2 ]; then SERIAL="$2"; shift; else BAD="--serial needs a device serial (adb devices)"; fi ;;
    --audio) AUDIO=1 ;;
    --fresh) ;;
    --*) BAD="unknown option $1" ;;
    *)
      if [ -z "$SERVER" ]; then SERVER="${1%/}"
      elif [ -z "$LABEL" ]; then LABEL="$1"
      else BAD="unexpected argument $1"
      fi ;;
  esac
  shift
done
[ -n "$LABEL" ] || usage
case "$LABEL" in
  *[!A-Za-z0-9._-]*|.|..)
    echo "error: a label is letters, digits, dots, dashes and underscores" >&2; exit 2 ;;
esac

# ── The record ────────────────────────────────────────────────────────────
#
# Set up before anything can refuse the run, as in live-check.sh: a refused
# run must not leave the label's last summary, all PASS perhaps, in place.

OUT="$ROOT/.build/android-live-check/$LABEL"
rm -rf "$OUT"
mkdir -p "$OUT"
RESULTS=()
FAILED=0
pass() { RESULTS+=("PASS $1"); }
fail() { RESULTS+=("FAIL $1"); FAILED=1; }
die() { echo "error: $1" >&2; fail "setup: $1"; exit 1; }
refuse() { echo "error: $1" >&2; fail "arguments: $1"; exit 2; }

PACKAGE=com.benjaminissa.issareader
TEST_PACKAGE=$PACKAGE.test
RUNNER=androidx.test.runner.AndroidJUnitRunner
TEST_CLASS=$PACKAGE.live.LiveCheckTest
# Where the test leaves the pairing code, its verdicts and its screenshots: the
# app's own files, read back through run-as (a debug build is debuggable).
REMOTE=files/live-check

GENERATION="unknown"
EXPECT_VERSION=""
DEVICE=""
APPROVER=""
stop_approver() { if [ -n "$APPROVER" ]; then kill "$APPROVER" >/dev/null 2>&1 || true; APPROVER=""; fi; }

finish() {
  local status=$?
  trap - EXIT
  stop_approver
  if [ "$status" != 0 ] && [ "$FAILED" = 0 ]; then
    fail "run: stopped early (exit $status); the checks after that point did not run"
  fi
  {
    echo "server   $SERVER ($GENERATION, expecting \"$EXPECT_VERSION\")"
    echo "device   $DEVICE"
    echo "label    $LABEL"
    echo "when     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    for line in ${RESULTS[@]+"${RESULTS[@]}"}; do echo "$line"; done
  } > "$OUT/summary.txt"
  cat "$OUT/summary.txt"
  if [ "$status" = 0 ]; then exit "$FAILED"; else exit "$status"; fi
}
trap finish EXIT
trap 'exit 130' INT TERM

if [ -n "$BAD" ]; then
  sed -n '6,9p' "$SELF" | sed 's/^# \{0,1\}//' >&2
  refuse "$BAD"
fi
[ -n "$SERVER" ] || refuse "no server given"
case "$SERVER" in
  http://*|https://*) ;;
  *) refuse "the server must be a URL, such as http://<address>:8003" ;;
esac
case "$SERVER" in
  *://10.0.2.2*|*://localhost*|*://127.*) refuse "give the machine's LAN address: the server's sign-in must see one host, and a phone cannot reach $SERVER" ;;
esac

# live-check.sh's names, so its server half below reads unchanged. Android
# always reads books: there is no television here.
BOOKS=1
STATUS_TITLE="${LIVE_STATUS_TITLE:-Moby Dick; Or, The Whale}"
READ_TITLE="${LIVE_READ_TITLE:-The Time Machine}"
READALONG_TITLE="${LIVE_READALONG_TITLE:-The Gap Book}"

command -v adb >/dev/null || die "adb not found (Android SDK platform-tools)"
command -v node >/dev/null || die "node not found"
[ -d "$ROOT/Tools/docker/node_modules/playwright" ] \
  || die "Playwright is not installed: (cd Tools/docker && npm install && npx playwright install chromium)"

# ── The device ────────────────────────────────────────────────────────────

if [ -z "$SERIAL" ]; then
  ATTACHED=$(adb devices | awk 'NR > 1 && $2 == "device" { print $1 }')
  case "$(printf '%s\n' "$ATTACHED" | grep -c .)" in
    1) SERIAL="$ATTACHED" ;;
    0) die "no device attached (adb devices)" ;;
    *) adb devices >&2; die "more than one device attached; name one with --serial" ;;
  esac
fi
export ANDROID_SERIAL="$SERIAL"
adb get-state >/dev/null 2>&1 || die "device $SERIAL is not ready (adb devices)"
SDK=$(adb shell getprop ro.build.version.sdk | tr -d '\r')
DEVICE="$SERIAL, $(adb shell getprop ro.product.model | tr -d '\r'), Android $(adb shell getprop ro.build.version.release | tr -d '\r') (API $SDK)"
[ "${SDK:-0}" -ge 30 ] || die "the app needs Android 11 (API 30) or later; $SERIAL is API $SDK"
echo "▸ $DEVICE"

# ── The server ────────────────────────────────────────────────────────────
#
# From here to "The run" is live-check.sh's server half, unchanged.

echo "▸ $SERVER"
# Its own token, from the fixture admin, rather than one left lying around:
# a saved token outlives the database it was minted against.
TOKEN=$(curl -sf -X POST "$SERVER/api/v2/token" \
          --data-urlencode usernameOrEmail=admin --data-urlencode password=issareader \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])' 2>/dev/null) \
  || die "no admin token from $SERVER. Is it up, and provisioned by setup.mjs?"
api() { curl -sf -H "Authorization: Bearer $TOKEN" "$@"; }

# The generation, decided the way the app decides it: /server/public exists
# only on 3.x, and 2.14.21 answers it 404.
case "$(curl -s -o /dev/null -w '%{http_code}' "$SERVER/api/v2/server/public")" in
  404) GENERATION=v2 ;;
  200) GENERATION=v3 ;;
  *) die "$SERVER/api/v2/server/public answered neither 200 nor 404" ;;
esac

# What Settings › Advanced should say, in `ServerCapabilities.displayVersion`'s
# wording: the test compares it character for character.
if [ "$GENERATION" = v2 ]; then
  EXPECT_VERSION="2.x (not reported)"
else
  EXPECT_VERSION=$(api "$SERVER/api/v2/server/details" | python3 -c '
import json, sys
version = json.load(sys.stdin).get("version")
if not version:
    print("3.x")
elif version.split(".")[0] == "3":
    print(version)
else:
    print("3.x (reports %s)" % version)')
fi

# One pass over the catalogue for every book the run needs, written out as
# shell assignments (quoted, because titles and labels are the server's text)
# and read back in. A file rather than `eval "$(...)"`: macOS's bash 3.2
# misparses a here-document inside a command substitution.
api "$SERVER/api/v2/books" > "$OUT/books-before.json"
python3 - "$OUT/books-before.json" "$STATUS_TITLE" "$READ_TITLE" "$READALONG_TITLE" \
    > "$OUT/books.env" <<'PY'
import json, shlex, sys
books = json.load(open(sys.argv[1]))
def find(title):
    return next((b for b in books if b.get("title") == title), None)
def say(name, value):
    print(name + "=" + shlex.quote(value or ""))
status = find(sys.argv[2])
if status:
    s = status.get("status")
    # What the pill shows as its value, as Status.displayName has it: the
    # label as sent where 3.x gives one that is not blank, padding and all,
    # the name otherwise, and None for no status at all.
    raw = (s.get("label") or "") if s else ""
    label = (raw if raw.strip() else s.get("name")) if s else "None"
    say("STATUS_BOOK", status["uuid"])
    say("STATUS_LABEL", label)
read = find(sys.argv[3])
if read:
    say("READ_BOOK", read["uuid"])
readalong = find(sys.argv[4])
if readalong and (readalong.get("readaloud") or {}).get("status") == "ALIGNED":
    say("READALONG_BOOK", readalong["uuid"])
PY
STATUS_BOOK="" STATUS_LABEL="" READ_BOOK="" READ_BEFORE=0 READALONG_BOOK=""
if [ "$BOOKS" = 1 ]; then
  . "$OUT/books.env"
  # A refusal, not a note: the status label is one of the release rule's
  # checks, and a run without its book recorded it as PASS.
  [ -n "$STATUS_BOOK" ] || die "no \"$STATUS_TITLE\" on this server, so its status label cannot be checked (set LIVE_STATUS_TITLE)"
  [ -n "$READ_BOOK" ] || die "no \"$READ_TITLE\" on this server (set LIVE_READ_TITLE)"
  if [ "$AUDIO" = 1 ] && [ -z "$READALONG_BOOK" ]; then
    die "--audio, but no aligned \"$READALONG_TITLE\" on this server (set LIVE_READALONG_TITLE)"
  fi
fi

# The book to read is put back at its start, as a position newer than any
# the server holds, so the page turns are judged from a known place. Every
# run used to open it where the last one left it and turn three pages on;
# once that reached the end of the book, a tap that moved nothing still
# saved, with a new timestamp, and the timestamp was all the verdict read.
#
# The start is the first item of the reading order: the server's own
# manifest where it serves one, else the spine of the book's EPUB, which is
# what the app itself reads.
if [ "$BOOKS" = 1 ]; then
  rm -f "$OUT/read-manifest.json" "$OUT/read-book.epub"
  if ! api "$SERVER/api/v2/books/$READ_BOOK/read/manifest.json" > "$OUT/read-manifest.json"; then
    rm -f "$OUT/read-manifest.json"
    api "$SERVER/api/v2/books/$READ_BOOK/files?format=ebook" > "$OUT/read-book.epub" \
      || die "no reading order for \"$READ_TITLE\": neither its manifest nor its EPUB could be fetched"
  fi
  python3 - "$OUT" > "$OUT/read-start.json" 2> "$OUT/read-start.err" <<'PY' \
    || die "no reading order for \"$READ_TITLE\": $(tail -1 "$OUT/read-start.err")"
import json, os, posixpath, sys, time, zipfile
import xml.etree.ElementTree as ET
out = sys.argv[1]
manifest = os.path.join(out, "read-manifest.json")
if os.path.exists(manifest):
    first = json.load(open(manifest))["readingOrder"][0]
    href, kind = first["href"], first.get("type")
else:
    book = zipfile.ZipFile(os.path.join(out, "read-book.epub"))
    ns = {"c": "urn:oasis:names:tc:opendocument:xmlns:container", "o": "http://www.idpf.org/2007/opf"}
    opf = ET.fromstring(book.read("META-INF/container.xml")).find(".//c:rootfile", ns).get("full-path")
    package = ET.fromstring(book.read(opf))
    items = {i.get("id"): i for i in package.find("o:manifest", ns)}
    item = items[package.find("o:spine", ns).find("o:itemref", ns).get("idref")]
    href = posixpath.normpath(posixpath.join(posixpath.dirname(opf), item.get("href")))
    kind = item.get("media-type")
print(json.dumps({
    "locator": {"href": href, "type": kind or "application/xhtml+xml",
                "locations": {"progression": 0, "totalProgression": 0}},
    "timestamp": round(time.time() * 1000)}))
PY
  api -X POST -H "Content-Type: application/json" --data @"$OUT/read-start.json" \
      "$SERVER/api/v2/books/$READ_BOOK/positions" >/dev/null \
    || die "could not put \"$READ_TITLE\" back at its start"
fi

# On 3.x a book can have no status, and reading it files it as Reading. That
# happens once per book, so the book is put back to no status first; without
# this the check would pass on a status an earlier run set.
if [ "$BOOKS" = 1 ] && [ "$GENERATION" = v3 ]; then
  api -X PUT -H "Content-Type: application/json" -d '{"status":null}' \
      "$SERVER/api/v2/books/$READ_BOOK/status" >/dev/null \
    || die "could not clear the status of \"$READ_TITLE\""
fi

# Both read back, not trusted. A 2xx that left the status in place (a server
# that ignores a null, or coerces it) would let the `filed` verdict pass on
# the status an earlier run set, and one that kept the old position would
# leave the page turns judged from the wrong place. This is also where a
# newer 3.x is seen still to accept `{"status":null}`. The position's
# timestamp is taken from what the server kept, as the baseline.
if [ "$BOOKS" = 1 ]; then
  api "$SERVER/api/v2/books" > "$OUT/books-reset.json" \
    || die "could not read \"$READ_TITLE\" back after putting it at its start"
  python3 - "$OUT/books-reset.json" "$READ_BOOK" "$OUT/read-start.json" "$GENERATION" \
      > "$OUT/read-reset.txt" <<'PY' || die "could not read \"$READ_TITLE\" back after putting it at its start"
import json, sys
book = next((b for b in json.load(open(sys.argv[1])) if b["uuid"] == sys.argv[2]), None)
start = json.load(open(sys.argv[3]))["locator"]
if book is None:
    sys.exit("the book is gone")
position = book.get("position") or {}
locator = position.get("locator") or {}
status = (book.get("status") or {}).get("name") or "none"
problem = ""
if locator.get("href") != start["href"] or (locator.get("locations") or {}).get("progression") not in (0, 0.0):
    problem = "is still at %s, not at its start %s" % (locator.get("href"), start["href"])
elif sys.argv[4] == "v3" and status != "none":
    problem = "still has the status \"%s\" after clearing it, so filing it cannot be checked" % status
print(position.get("timestamp") or 0, problem)
PY
  read -r READ_BEFORE RESET_PROBLEM < "$OUT/read-reset.txt" || true
  [ -z "$RESET_PROBLEM" ] || die "\"$READ_TITLE\" $RESET_PROBLEM"
fi

# A read-along picks up where it was left, and a run that crossed its first
# file leaves it in the second chapter, where the next run would play on
# inside one file and cross nothing. So it is put back at the top of its first
# narrated chapter, as a position newer than any the server holds. The test
# cannot judge the crossing itself: its "still playing" is the Pause narration
# button, which a player stuck at the file's end, or looping it, shows just
# the same. The verdict is the server's, afterwards: the position must have
# moved on to a later chapter.
if [ "$BOOKS" = 1 ] && [ "$AUDIO" = 1 ]; then
  api "$SERVER/api/v2/books/$READALONG_BOOK/read/manifest.json" > "$OUT/readalong-manifest.json" \
    || die "no reading order for \"$READALONG_TITLE\""
  python3 - "$OUT/readalong-manifest.json" > "$OUT/readalong-start.json" 2> "$OUT/readalong-start.err" <<'PY' \
    || die "\"$READALONG_TITLE\": $(tail -1 "$OUT/readalong-start.err"), so a crossing cannot be told from a start"
import json, sys, time
order = json.load(open(sys.argv[1]))["readingOrder"]
# The first chapter with a media overlay: a title page ahead of it has no
# audio, so starting there would reach the narration without crossing a file.
narrated = [r for r in order
            if any("guided-navigation" in (a.get("type") or "") for a in r.get("alternate") or [])]
# None at all is a refusal, not the first spine item: starting on a page with
# no audio, pressing Play reaches the narration in a later item, and the
# verdict below would call that a crossing when no file boundary was crossed.
if not narrated:
    sys.exit("no chapter in the reading order has a media overlay (guided-navigation)")
first = narrated[0]
print(json.dumps({
    "locator": {"href": first["href"], "type": first.get("type") or "application/xhtml+xml",
                "locations": {"progression": 0, "totalProgression": 0}},
    "timestamp": round(time.time() * 1000)}))
PY
  api -X POST -H "Content-Type: application/json" --data @"$OUT/readalong-start.json" \
      "$SERVER/api/v2/books/$READALONG_BOOK/positions" >/dev/null \
    || die "could not put \"$READALONG_TITLE\" back at its start"
fi

# ── The run ───────────────────────────────────────────────────────────────

echo "▸ building the app and its live test"
(cd "$ROOT/Android" && ./gradlew :app:assembleDebug :app:assembleDebugAndroidTest --console=plain) \
  > "$OUT/gradle.log" 2>&1 || die "the build failed; see $OUT/gradle.log"
APK="$ROOT/Android/app/build/outputs/apk/debug/app-debug.apk"
TEST_APK="$ROOT/Android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk"

# Uninstalled, which takes the Keystore key and the token with it; installed;
# then cleared, so a backup restored at install leaves nothing behind either.
adb uninstall "$PACKAGE" >/dev/null 2>&1 || true
adb uninstall "$TEST_PACKAGE" >/dev/null 2>&1 || true
adb install -r -t "$APK" > "$OUT/install.log" 2>&1 || die "could not install the app; see $OUT/install.log"
adb install -r -t "$TEST_APK" >> "$OUT/install.log" 2>&1 || die "could not install the live test; see $OUT/install.log"
adb shell pm clear "$PACKAGE" >/dev/null
# The answer-ready notification is asked for in context; granted here so the
# prompt does not sit over the screens the test reads.
adb shell pm grant "$PACKAGE" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true

# A file the test wrote, or nothing. The redirect is the device shell's:
# exec-out carries the remote command's errors on the same stream as its
# output, so a host-side 2>/dev/null would let "No such file" through as if
# the test had written it.
remote() { adb exec-out "run-as $PACKAGE cat $REMOTE/$1 2>/dev/null" || true; }

# Approves the pairing code the moment the test writes it, as live-check.sh's
# approver does; stopped when the test ends.
(
  code=""
  until [ -n "$code" ]; do sleep 1; code=$(remote code.txt | tr -d '[:space:]'); done
  printf '%s\n' "$code" > "$OUT/code.txt"
  cd "$ROOT/Tools/docker"
  MODE=password STORYTELLER_URL="$SERVER" node approve-device.mjs "$code"
) > "$OUT/approve.log" 2>&1 &
APPROVER=$!

# The settings go over as instrumentation arguments, base64'd: adb hands the
# command line to the device's shell, and titles carry semicolons and quotes.
# A blank one is left out (an empty value would swallow the next -e), and the
# test reads a missing argument as blank, as the iPhone's reads an empty one.
arg() { [ -z "$2" ] || printf -- '-e %s %s ' "$1" "$(printf '%s' "$2" | base64 | tr -d '\n')"; }
ARGS="$(arg server "$SERVER")$(arg expectVersion "$EXPECT_VERSION")"
ARGS+="$(arg statusBook "$STATUS_BOOK")$(arg statusTitle "$STATUS_TITLE")$(arg statusLabel "$STATUS_LABEL")"
ARGS+="$(arg readBook "$READ_BOOK")$(arg readalongBook "$READALONG_BOOK")"
ARGS+="$(arg audio "$([ "$AUDIO" = 1 ] && echo 1)")$(arg readalongSeconds "${LIVE_READALONG_SECONDS:-75}")"

echo "▸ running LiveCheckTest (log: $OUT/instrument.log)"
set +e
adb shell am instrument -w -r $ARGS -e class "$TEST_CLASS" "$TEST_PACKAGE/$RUNNER" > "$OUT/instrument.log" 2>&1
TEST_STATUS=$?
set -e
stop_approver

# The screenshots and the verdicts, off the device.
remote checks.txt > "$OUT/checks.txt"
for shot in $(adb exec-out run-as "$PACKAGE" ls "$REMOTE" 2>/dev/null | tr -d '\r' | grep '\.png$' || true); do
  remote "$shot" > "$OUT/$shot"
done

# ── The verdicts ──────────────────────────────────────────────────────────

# What ran, from the instrumentation's own status lines: in raw mode each test
# ends with a status code, 0 for passed and negative for failed, errored,
# ignored or assumed away. A test that never started reports no code at all.
RAN=$(grep -c '^INSTRUMENTATION_STATUS_CODE: \(0\|-[1-4]\)' "$OUT/instrument.log" || true)
BAD_ENDS=$(grep -c '^INSTRUMENTATION_STATUS_CODE: -[1-4]' "$OUT/instrument.log" || true)
if [ "${RAN:-0}" -eq 0 ]; then
  fail "test did not run: see $OUT/instrument.log"
elif [ "$TEST_STATUS" != 0 ] || [ "${BAD_ENDS:-0}" -gt 0 ] || ! grep -q '^INSTRUMENTATION_CODE: -1' "$OUT/instrument.log"; then
  fail "test: the instrumentation reported a failure; a failed check is listed below, and a failure outside the checks is in $OUT/instrument.log"
else
  pass "test ran: instrumentation OK"
fi

if [ -s "$OUT/code.txt" ]; then
  if grep -q '^\[approve\] approved' "$OUT/approve.log"; then
    pass "approve: code $(tr -d '[:space:]' < "$OUT/code.txt") approved on the server"
  else
    fail "approve: the code was not approved; see $OUT/approve.log"
  fi
else
  # Every run here starts from an uninstall, so a run that landed without
  # showing a code paired nothing.
  fail "approve: the app showed no code to approve, so no pairing was made"
fi

if [ -s "$OUT/checks.txt" ]; then
  while read -r check verdict detail; do
    if [ "$verdict" = PASS ]; then pass "$check: $detail"; else fail "$check: $detail"; fi
  done < "$OUT/checks.txt"
fi
if ! grep -q '^sessionAtEnd ' "$OUT/checks.txt" 2>/dev/null; then
  fail "sessionAtEnd: the test stopped before its last check; see $OUT/instrument.log"
fi

# From here to "The log" is live-check.sh's, unchanged.

# What only the server can say. The position is compared by its timestamp,
# which the client sets when it writes one.
#
# Every step here tolerates failing. This runs after a test of ten minutes
# or more, and a server that restarted, a token that expired or a book
# deleted meanwhile is a FAIL for the checks it touches, not the end of the
# record: the checks after it still run, and summary.txt is still written.
READ_AFTER=0 READ_STATUS=unread
if [ "$BOOKS" = 1 ] && ! api "$SERVER/api/v2/books" > "$OUT/books-after.json"; then
  fail "server: could not read the catalogue back after the test, so the position and filing were not checked"
elif [ "$BOOKS" = 1 ]; then
  # Newer is not enough: a tap that turned nothing still saves, with a new
  # timestamp and the same place. The place must have moved on from the
  # start the book was put at.
  python3 - "$OUT/books-after.json" "$READ_BOOK" "$OUT/read-start.json" > "$OUT/read-after.txt" <<'PY' \
    || echo "0 unread no nowhere" > "$OUT/read-after.txt"
import json, sys
book = next((b for b in json.load(open(sys.argv[1])) if b["uuid"] == sys.argv[2]), None)
start = json.load(open(sys.argv[3]))["locator"]
if book is None:
    print(0, "missing", "no", "nowhere")
else:
    status = (book.get("status") or {}).get("name") or "none"
    position = book.get("position") or {}
    locator = position.get("locator") or {}
    href = locator.get("href") or "nowhere"
    progression = (locator.get("locations") or {}).get("progression") or 0
    moved = href != start["href"] or progression > 0
    print(position.get("timestamp") or 0, status, "yes" if moved else "no",
          "%s@%.3f" % (href, progression))
PY
  read -r READ_AFTER READ_STATUS READ_MOVED READ_WHERE < "$OUT/read-after.txt" || true
  READ_START=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["locator"]["href"])' \
    "$OUT/read-start.json" 2>/dev/null) || READ_START="its start"
  if [ "$READ_STATUS" = missing ] || [ "$READ_STATUS" = unread ]; then
    fail "position: \"$READ_TITLE\" could not be read back from the server ($READ_STATUS)"
  elif [ "$READ_AFTER" -le "$READ_BEFORE" ]; then
    fail "position: \"$READ_TITLE\" has no newer position on the server ($READ_BEFORE -> $READ_AFTER)"
  elif [ "$READ_MOVED" != yes ]; then
    fail "position: \"$READ_TITLE\" saved again but did not move from $READ_START: the pages did not turn"
  else
    pass "position: \"$READ_TITLE\" moved from $READ_START to $READ_WHERE on the server ($READ_BEFORE -> $READ_AFTER)"
  fi
  if [ "$GENERATION" = v3 ]; then
    if [ "$READ_STATUS" = Reading ]; then
      pass "filed: \"$READ_TITLE\" went from no status to Reading"
    else
      fail "filed: \"$READ_TITLE\" had no status and is now \"$READ_STATUS\", not Reading"
    fi
  fi
  # The read-along was put at the top of its first narrated chapter, so a
  # position anywhere later in the reading order is narration that got past
  # the end of the first file, and the same chapter is narration that did not.
  if [ "$AUDIO" = 1 ]; then
    python3 - "$OUT/books-after.json" "$READALONG_BOOK" "$OUT/readalong-manifest.json" \
        "$OUT/readalong-start.json" > "$OUT/readalong-after.txt" <<'PY' \
      || echo "FAIL unknown unreadable" > "$OUT/readalong-after.txt"
import json, sys
book = next((b for b in json.load(open(sys.argv[1])) if b["uuid"] == sys.argv[2]), None) or {}
order = [r["href"] for r in json.load(open(sys.argv[3]))["readingOrder"]]
start = json.load(open(sys.argv[4]))["locator"]["href"]
after = ((book.get("position") or {}).get("locator") or {}).get("href") or "nowhere"
crossed = after in order and order.index(after) > order.index(start)
print("PASS" if crossed else "FAIL", start, after)
PY
    read -r CROSSED START_HREF AFTER_HREF < "$OUT/readalong-after.txt" || true
    if [ "$CROSSED" = PASS ]; then
      pass "crossed: \"$READALONG_TITLE\" moved on from $START_HREF to $AFTER_HREF on the server"
    else
      fail "crossed: \"$READALONG_TITLE\" was put at $START_HREF and is at $AFTER_HREF, so narration never got past its first file"
    fi
  fi
fi

# ── The log ───────────────────────────────────────────────────────────────

# A second witness for the version row: what the app logged when it probed.
adb exec-out run-as "$PACKAGE" cat files/Logs/current.log > "$OUT/current.log" 2>/dev/null || : > "$OUT/current.log"
if [ -s "$OUT/current.log" ]; then
  python3 - "$OUT/current.log" > "$OUT/detected.txt" <<'PY' || : > "$OUT/detected.txt"
import json, sys
seen = ""
for line in open(sys.argv[1]):
    try:
        entry = json.loads(line)
    except ValueError:
        continue
    if entry.get("message") == "server detected":
        fields = entry.get("fields", {})
        seen = "generation=%s version=%s" % (fields.get("generation"), fields.get("version"))
print(seen)
PY
  DETECTED=$(cat "$OUT/detected.txt")
  if [[ "$DETECTED" == "generation=$GENERATION "* ]]; then
    pass "log: server detected $DETECTED"
  else
    fail "log: expected generation=$GENERATION, logged \"${DETECTED:-nothing}\""
  fi
else
  fail "log: no files/Logs/current.log in the app's data"
fi

# summary.txt is written by `finish`, on the way out.
exit "$FAILED"
