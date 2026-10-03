#!/usr/bin/env bash
#
# Live checks: item 3 of the release rule in CLAUDE.md, on an iPhone, iPad or
# Apple TV simulator, against one running Storyteller.
#
#   scripts/live-check.sh http://<lan-address>:8001 v2-iphone
#   scripts/live-check.sh http://<lan-address>:8003 v3-ipad --device "iPad Pro 11-inch (M5)"
#   scripts/live-check.sh <server> <label> --fresh    # reset the keychain, so it pairs for real
#   scripts/live-check.sh <server> <label> --audio    # also a read-along, out of the speakers
#   scripts/live-check.sh <server> <label> --platform tvos    # the television's subset
#
# Signs the real app in by device code, then checks what a reader would see:
# the library, the session outliving the covers, Settings › Advanced's server
# version, a book's status label, a page read, and with --audio a read-along
# playing past the end of its first audio file. The screen is driven by
# Apps/IssaLiveUITests; this script sets the server up for it, approves the
# pairing code it writes out, and checks over the API what the screen cannot
# show — that the position reached the server and, on 3.x, filed the book,
# and that the read-along's position got past its first file.
#
# Everything lands in .build/live-check/<label>/: summary.txt with a PASS or
# FAIL per check, the screenshots, the app's log and the xcodebuild output.
# Exits 1 if any check failed.
#
# The server is an argument and the simulator a name, so no address, device id
# or token is written into the repository. The only credentials used are the
# local stack's fixture admin, which Tools/docker/setup.mjs creates and
# approve-device.mjs already signs in as. The run signs the app in as that
# admin, so the positions and statuses checked are the admin's.
#
# Books are found by title, and the defaults are books the local stack's
# library has; override them for another library with
#   LIVE_STATUS_TITLE     a book whose status label is checked
#   LIVE_READ_TITLE       a book opened and read (on 3.x its status is cleared first)
#   LIVE_READALONG_TITLE  a read-along whose first narrated chapter is its first
#                         audio file, ending in a gap
#   LIVE_READALONG_SECONDS  how long the read-along plays; default 75, which
#                         must outlast that first audio file
#
# With --platform tvos it runs Apps/IssaLiveTVUITests on an Apple TV simulator
# instead, moving by XCUIRemote: the pairing, the library, the session and
# Settings' server version. The television shows no status label — a book
# opens straight into the read-along screen, which has none — and a page read
# and a read-along sit behind that screen, where reaching one given book is a
# walk through focus, so on the television those two stay with the screen.
# The Mac is not covered at all: see CLAUDE.md.

set -euo pipefail
# Taken before the `cd` to the root: `$0` is a path from wherever the script
# was run, and from the root a relative one names nothing, so usage printed
# only sed's complaint (as mac-controls-check.sh already learned).
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"

usage() { sed -n '6,10p' "$SELF" | sed 's/^# \{0,1\}//' >&2; exit 2; }

SERVER=""
LABEL=""
DEVICE=""
PLATFORM=ios
AUDIO=0
FRESH=0
# What was wrong with the arguments, if anything. Collected rather than acted
# on, because a refusal must not exit before the label's old record is gone.
BAD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --device) if [ $# -ge 2 ]; then DEVICE="$2"; shift; else BAD="--device needs a simulator name"; fi ;;
    --platform) if [ $# -ge 2 ]; then PLATFORM="$2"; shift; else BAD="--platform needs ios or tvos"; fi ;;
    --audio) AUDIO=1 ;;
    --fresh) FRESH=1 ;;
    --*) BAD="unknown option $1" ;;
    *)
      if [ -z "$SERVER" ]; then SERVER="${1%/}"
      elif [ -z "$LABEL" ]; then LABEL="$1"
      else BAD="unexpected argument $1"
      fi ;;
  esac
  shift
done
# No label, no record to keep or clear.
[ -n "$LABEL" ] || usage
# The label names a directory this script empties.
case "$LABEL" in
  *[!A-Za-z0-9._-]*|.|..)
    echo "error: a label is letters, digits, dots, dashes and underscores" >&2; exit 2 ;;
esac

# ── The record ────────────────────────────────────────────────────────────
#
# Set up before anything can refuse the run. summary.txt is the record
# CLAUDE.md asks for, and a refused run that left the label's last one in
# place — all PASS, perhaps — looked like a run that passed.

OUT="$ROOT/.build/live-check/$LABEL"
DERIVED="$ROOT/.build/dd-live"
rm -rf "$OUT"
mkdir -p "$OUT"
RESULTS=()
FAILED=0
pass() { RESULTS+=("PASS $1"); }
fail() { RESULTS+=("FAIL $1"); FAILED=1; }
# Setting up refused: said on the console and kept in the record.
die() { echo "error: $1" >&2; fail "setup: $1"; exit 1; }
# The arguments refused: the same, with usage's exit status.
refuse() { echo "error: $1" >&2; fail "arguments: $1"; exit 2; }

GENERATION="unknown"
EXPECT_VERSION=""
APPROVER=""
stop_approver() { if [ -n "$APPROVER" ]; then kill "$APPROVER" >/dev/null 2>&1 || true; APPROVER=""; fi; }

# summary.txt is written here, on the way out, whatever the way out is. It
# used to be the script's last lines, so anything `set -e` stopped on after a
# ten-minute test (the server gone, the token expired, a book deleted) lost
# the whole record, the verdicts already reached with it, and printed nothing
# but curl's exit status. A run that stops early is a failed run, and says so.
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
  sed -n '6,10p' "$SELF" | sed 's/^# \{0,1\}//' >&2
  refuse "$BAD"
fi
[ -n "$SERVER" ] || refuse "no server given"
case "$SERVER" in
  http://*|https://*) ;;
  *) refuse "the server must be a URL, such as http://<address>:8003" ;;
esac

# What differs by platform: the runtime to find the simulator in, the scheme
# and test target, and where the app keeps its log (`StorageRoot`: Caches on
# tvOS, Application Support elsewhere). BOOKS says whether this platform's
# test reads books, which decides the book lookups and the API checks.
case "$PLATFORM" in
  ios)
    RUNTIME=iOS; SIMULATOR="iOS Simulator"; SCHEME=IssaReader-iOS; TESTS=IssaLiveUITests
    STORAGE="Library/Application Support"; BOOKS=1; DEVICE="${DEVICE:-iPhone 17 Pro}" ;;
  tvos)
    RUNTIME=tvOS; SIMULATOR="tvOS Simulator"; SCHEME=IssaReader-tvOS; TESTS=IssaLiveTVUITests
    STORAGE="Library/Caches"; BOOKS=0; DEVICE="${DEVICE:-Apple TV 4K (3rd generation)}"
    [ "$AUDIO" = 0 ] || refuse "--audio is iPhone and iPad only" ;;
  *) refuse "unknown platform $PLATFORM: ios or tvos" ;;
esac

STATUS_TITLE="${LIVE_STATUS_TITLE:-Moby Dick; Or, The Whale}"
READ_TITLE="${LIVE_READ_TITLE:-The Time Machine}"
READALONG_TITLE="${LIVE_READALONG_TITLE:-The Gap Book}"

command -v xcodegen >/dev/null || die "xcodegen not found"
command -v node >/dev/null || die "node not found"
[ -d "$ROOT/Tools/docker/node_modules/playwright" ] \
  || die "Playwright is not installed: (cd Tools/docker && npm install && npx playwright install chromium)"

# The bundle id the build signs with, read the way layout-sweep.sh reads it
# (see there for why the loop ends in `|| continue`).
BUNDLE_ID=$(
    for f in "$ROOT/Signing.xcconfig" "$ROOT/Signing.local.xcconfig"; do
        [ -f "$f" ] || continue
        sed -n 's/^[[:space:]]*ISSA_BUNDLE_ID[[:space:]]*=[[:space:]]*//p' "$f"
    done | tail -1 | sed 's/[[:space:]]*$//'
)
[ -n "$BUNDLE_ID" ] || die "ISSA_BUNDLE_ID is not set in Signing.xcconfig"

# ── The server ────────────────────────────────────────────────────────────

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

# ── The simulator ─────────────────────────────────────────────────────────

# By name, on the newest runtime of the platform that has one, so nothing
# machine-specific is written down. A name that matches nothing lists what
# there is.
UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, re, sys
found = []
for runtime, devices in json.load(sys.stdin)["devices"].items():
    m = re.search(r"\." + sys.argv[2] + r"-([0-9]+)-([0-9]+)$", runtime)
    if m:
        found += [((int(m.group(1)), int(m.group(2))), d["udid"]) for d in devices if d["name"] == sys.argv[1]]
print(max(found)[1] if found else "")' "$DEVICE" "$RUNTIME")
if [ -z "$UDID" ]; then
  xcrun simctl list devices available "$RUNTIME" >&2 || true
  die "no available $RUNTIME simulator named \"$DEVICE\"; the ones there are are listed above"
fi
echo "▸ $DEVICE"
xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
# A half-booted device fails installs in ways that look like build problems.
xcrun simctl bootstatus "$UDID" -b > "$OUT/boot.log" 2>&1
# The data container goes with the app (its library, positions and the
# remembered server), so the run starts from a first launch.
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
# The keychain does not: a device signed in to this server before signs
# straight back in. --fresh clears it, which is the only way to prove the
# pairing itself. It clears every app's items on this simulator.
if [ "$FRESH" = 1 ]; then xcrun simctl keychain "$UDID" reset; fi

# ── The run ───────────────────────────────────────────────────────────────

# Approves the pairing code the moment the test writes it. It waits as long
# as the build and the test take, and is stopped when they end.
(
  until [ -s "$OUT/code.txt" ]; do sleep 1; done
  cd "$ROOT/Tools/docker"
  MODE=password STORYTELLER_URL="$SERVER" node approve-device.mjs "$(tr -d '[:space:]' < "$OUT/code.txt")"
) > "$OUT/approve.log" 2>&1 &
APPROVER=$!

xcodegen generate >/dev/null
echo "▸ building and running $TESTS (log: $OUT/xcodebuild.log)"
AUDIO_FLAG=""
if [ "$AUDIO" = 1 ]; then AUDIO_FLAG=1; fi
set +e
# Signed, deliberately: CODE_SIGNING_ALLOWED=NO loses the simulator keychain
# and every background download, and a book is a background download.
#
# `-collect-test-diagnostics never`: without it Xcode 27 runs `simctl
# diagnose` after the session and waits on it indefinitely.
TEST_RUNNER_E2E_SERVER="$SERVER" \
TEST_RUNNER_E2E_OUT="$OUT" \
TEST_RUNNER_E2E_EXPECT_VERSION="$EXPECT_VERSION" \
TEST_RUNNER_E2E_STATUS_BOOK="$STATUS_BOOK" \
TEST_RUNNER_E2E_STATUS_TITLE="$STATUS_TITLE" \
TEST_RUNNER_E2E_STATUS_LABEL="$STATUS_LABEL" \
TEST_RUNNER_E2E_READ_BOOK="$READ_BOOK" \
TEST_RUNNER_E2E_READALONG_BOOK="$READALONG_BOOK" \
TEST_RUNNER_E2E_AUDIO="$AUDIO_FLAG" \
TEST_RUNNER_E2E_READALONG_SECONDS="${LIVE_READALONG_SECONDS:-75}" \
xcodebuild test \
    -project IssaReader.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination "platform=$SIMULATOR,id=$UDID" \
    -derivedDataPath "$DERIVED" \
    -only-testing:"$TESTS" \
    -parallel-testing-enabled NO \
    -collect-test-diagnostics never \
    -resultBundlePath "$OUT/result.xcresult" \
    > "$OUT/xcodebuild.log" 2>&1
TEST_STATUS=$?
set -e
stop_approver

# ── The verdicts ──────────────────────────────────────────────────────────

# A run that skipped (no settings reached the runner) or never built exits as
# quietly as a pass, so what actually ran is read from the result bundle.
#
# And one that ran is judged by xcodebuild's exit too, not only by the lines
# below. Those are the checks the test got to write; a failure raised outside
# `record` — a tab that never appeared, a tap on an element that went away,
# the app crashing — fails the run without writing one, and a summary built
# from the lines alone read all PASS over a run xcodebuild called failed.
RAN=$(xcrun xcresulttool get test-results summary --path "$OUT/result.xcresult" --format json 2>/dev/null \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("passedTests",0)+d.get("failedTests",0))' \
  2>/dev/null) || RAN=0
if [ "${RAN:-0}" -eq 0 ]; then
  fail "test did not run: see $OUT/xcodebuild.log"
elif [ "$TEST_STATUS" != 0 ]; then
  fail "test: xcodebuild exit $TEST_STATUS; a failed check is listed below, and a failure outside the checks is in $OUT/xcodebuild.log"
else
  pass "test ran: xcodebuild exit 0"
fi

# The pairing, when there was one to approve.
if [ -s "$OUT/code.txt" ]; then
  if grep -q '^\[approve\] approved' "$OUT/approve.log"; then
    pass "approve: code $(tr -d '[:space:]' < "$OUT/code.txt") approved on the server"
  else
    fail "approve: the code was not approved; see $OUT/approve.log"
  fi
elif [ "$FRESH" = 1 ]; then
  # --fresh exists to prove the pairing. A run that landed without showing a
  # code paired nothing, whatever the sign-in line says, and that is a fail:
  # the keychain reset left something the app signed back in with.
  fail "approve: --fresh, but the app showed no code to approve, so no pairing was made"
fi

# The test's own verdicts, one line per check it made.
if [ -f "$OUT/checks.txt" ]; then
  while read -r check verdict detail; do
    if [ "$verdict" = PASS ]; then pass "$check: $detail"; else fail "$check: $detail"; fi
  done < "$OUT/checks.txt"
fi
# The line both tests write last. Without it the run stopped part-way, and
# the checks it never reached are missing from the list rather than failed
# in it — on the television, with no API checks after, that list could be
# all PASS.
if ! grep -q '^sessionAtEnd ' "$OUT/checks.txt" 2>/dev/null; then
  fail "sessionAtEnd: the test stopped before its last check; see $OUT/xcodebuild.log"
fi

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

# A second witness for the version row: what the app logged when it probed.
DATA=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null) || DATA=""
LOG="$DATA/$STORAGE/Logs/current.log"
if [ -n "$DATA" ] && [ -f "$LOG" ]; then
  cp "$LOG" "$OUT/current.log"
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
  fail "log: no current.log in the app's container"
fi

# summary.txt is written by `finish`, on the way out.
exit "$FAILED"
