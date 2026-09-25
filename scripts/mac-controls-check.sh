#!/usr/bin/env bash
#
# Mac controls check: that every menu the running Mac app shows is one
# standard control, with one bezel and one arrow.
#
#   scripts/mac-controls-check.sh v2-mac
#   scripts/mac-controls-check.sh v3-mac
#
# On the macOS 27 SDK a SwiftUI `Menu` is an AppKit pull-down that draws its
# own bezel and indicator around whatever label it is given. Labels that drew
# their own capsule and chevron (the phone's chip idiom) came out as a button
# inside a button, with two arrows. The Mac branches now hand the system
# plain labels. This is the guard that they still do.
#
# Run it with the signed Debug Mac app open and signed in, and with the
# windows to be checked showing: the library on a shelf, a book in the
# inspector with Manage downloads open (for the edition menus), and Now
# Playing. It reads each "Issa Reader" window's accessibility tree through
# System Events, which needs no focus, so it leaves the screen alone. The
# terminal running it needs Accessibility access (System Settings › Privacy &
# Security › Accessibility).
#
# It lists every pop-up and pull-down button with its name, value and size,
# and fails when:
#   - any of them is taller than 30pt. The doubled controls were 44pt and
#     more, because the app's capsule sat inside the system's bezel; a
#     standard bezel is 19 to 25pt.
#   - a control an open window should have is missing:
#       library header   the tags pull-down ("Filter by tag" or "N tags
#                        selected"), the "Sort by" pop-up and the "Reverse
#                        order" toggle
#       book detail      the reading status pop-up, and with Manage
#                        downloads open, at least one "<Edition> options"
#       Now Playing      the speed pull-down, titled like "1.5×"
# A window counts as showing the library header when it is titled with a
# shelf and has the count line ("12 books", "1 result") in it, and a book
# when its Manage downloads heading is. What was and was not looked at is
# written out as coverage, so a run that checked nothing cannot pass for one
# that checked everything.
#
# A chevron image inside a control is reported but not asserted. SwiftUI may
# flatten a label's images out of the tree, so not finding one proves nothing.
#
# Writes .build/mac-check/<label>.txt: the controls found, the coverage, and a
# PASS or FAIL per check. The raw dump sits beside it as <label>.raw.tsv.
# Exits 1 if any check failed or there was nothing to check, 2 on bad usage.
#
# MAC_CHECK_DUMP=<file.raw.tsv> judges a dump already taken instead of
# reading the app, which is how the verdicts are tested without one running.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"

usage() { sed -n '6,7p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

[ $# -eq 1 ] || usage
LABEL="$1"
case "$LABEL" in -*|*/*|"") usage ;; esac

APP="Issa Reader"
OUT="$ROOT/.build/mac-check"
REPORT="$OUT/$LABEL.txt"
RAW="$OUT/$LABEL.raw.tsv"
mkdir -p "$OUT"
rm -f "$REPORT"

command -v osascript >/dev/null || { echo "error: osascript not found; this runs on a Mac" >&2; exit 1; }
command -v python3 >/dev/null || { echo "error: python3 not found" >&2; exit 1; }

# The dump. One tab-separated record per line:
#   P  <count of processes named APP>  <bundle path of the first>
#   W  <window>  <title>  <AXIdentifier>
#   C  <window>  <role>  <description>  <title>  <value>  <width>  <height>  <image children>
#   B  <window>  <role>  <description>  <title>  <value>  <width>  <height>
#   T  <window>  <static text>
# C is every pop-up and pull-down button. B is a button or checkbox named
# "Reverse order". T is a static text that marks what a window is showing:
# the library's count line or the book detail's Manage downloads section.
# Every attribute read is in its own `try`: SwiftUI leaves some unset, and one
# missing description must not lose the rest of the window.
#
# To a file, not through `$(...)`: macOS's bash 3.2 misparses a here-document
# inside a command substitution.
if [ -n "${MAC_CHECK_DUMP:-}" ]; then
  [ -f "$MAC_CHECK_DUMP" ] || { echo "error: no dump at $MAC_CHECK_DUMP" >&2; exit 2; }
  [ "$MAC_CHECK_DUMP" -ef "$RAW" ] || cp "$MAC_CHECK_DUMP" "$RAW"
elif ! osascript - "$APP" > "$RAW" 2> "$OUT/$LABEL.osascript.err" <<'OSA'
on clean(v)
	if v is missing value then return ""
	try
		set s to v as text
	on error
		return ""
	end try
	-- A tab or line break inside a name would split its record.
	set saved to AppleScript's text item delimiters
	set AppleScript's text item delimiters to {tab, return, linefeed}
	set parts to text items of s
	set AppleScript's text item delimiters to " "
	set s to parts as text
	set AppleScript's text item delimiters to saved
	return s
end clean

on sizeOf(el)
	tell application "System Events"
		try
			set sz to size of el
			return ((item 1 of sz) as integer as text) & tab & ((item 2 of sz) as integer as text)
		on error
			return "?" & tab & "?"
		end try
	end tell
end sizeOf

on field(el, what)
	tell application "System Events"
		try
			if what is "description" then return my clean(description of el)
			if what is "title" then return my clean(title of el)
			if what is "value" then return my clean(value of el)
		end try
	end tell
	return ""
end field

on run argv
	set appName to item 1 of argv
	set out to {}
	with timeout of 600 seconds
		tell application "System Events"
			set procs to (every process whose name is appName)
			if (count of procs) is 0 then return "P" & tab & "0" & tab & ""
			set p to item 1 of procs
			set bundlePath to ""
			try
				set bundlePath to POSIX path of (application file of p)
			end try
			set end of out to "P" & tab & ((count of procs) as text) & tab & bundlePath
			set wins to windows of p
			repeat with wi from 1 to count of wins
				set w to item wi of wins
				set wt to ""
				try
					set wt to my clean(name of w)
				end try
				set wid to ""
				try
					set wid to my clean(value of attribute "AXIdentifier" of w)
				end try
				set end of out to "W" & tab & wi & tab & wt & tab & wid
				set els to {}
				try
					set els to entire contents of w
				end try
				repeat with ei from 1 to count of els
					set el to item ei of els
					set r to ""
					try
						set r to role of el
					end try
					if r is "AXPopUpButton" or r is "AXMenuButton" then
						set ims to ""
						try
							repeat with im in (images of el)
								set ims to ims & my field(im, "description") & ";"
							end repeat
						end try
						set end of out to "C" & tab & wi & tab & r & tab & my field(el, "description") & tab & my field(el, "title") & tab & my field(el, "value") & tab & my sizeOf(el) & tab & ims
					else if r is "AXButton" or r is "AXCheckBox" or r is "AXToggle" then
						set d to my field(el, "description")
						set t to my field(el, "title")
						if d is "Reverse order" or t is "Reverse order" then
							set end of out to "B" & tab & wi & tab & r & tab & d & tab & t & tab & my field(el, "value") & tab & my sizeOf(el)
						end if
					else if r is "AXStaticText" then
						set v to my field(el, "value")
						if v is "" then set v to my field(el, "description")
						if v is "Manage downloads" or v starts with "Books download automatically" then
							set end of out to "T" & tab & wi & tab & v
						else if v is not "" and "0123456789" contains (character 1 of v) then
							if v ends with " book" or v ends with " books" or v ends with " result" or v ends with " results" then
								set end of out to "T" & tab & wi & tab & v
							end if
						end if
					end if
				end repeat
			end repeat
		end tell
	end timeout
	set AppleScript's text item delimiters to linefeed
	set text_ to out as text
	set AppleScript's text item delimiters to ""
	return text_
end run
OSA
then
  cat "$OUT/$LABEL.osascript.err" >&2
  if grep -qiE 'assistive|not allowed|-1719|-25211|-1743' "$OUT/$LABEL.osascript.err"; then
    echo "error: System Events may not read another app's controls from this terminal." >&2
    echo "       Grant it Accessibility (System Settings › Privacy & Security › Accessibility)." >&2
  else
    echo "error: reading $APP's windows through System Events failed (above)" >&2
  fi
  exit 1
fi
rm -f "$OUT/$LABEL.osascript.err"

# The verdicts, from the dump. Python rather than awk for the regular
# expressions, and a here-document into a plain command for the same bash 3.2
# reason as above.
set +e
python3 - "$RAW" "$REPORT" "$LABEL" <<'PY'
import datetime, re, sys

raw_path, report_path, label = sys.argv[1:4]
LIMIT = 30  # points; a standard bezel is 19 to 25, the doubled controls were 44+

procs, bundle = 0, ""
windows = {}  # index -> {title, ident, controls, toggles, texts}
for line in open(raw_path, encoding="utf-8"):
    f = line.rstrip("\n").split("\t")
    kind = f[0]
    if kind == "P":
        procs, bundle = int(f[1] or 0), (f[2] if len(f) > 2 else "")
    elif kind == "W":
        windows[f[1]] = dict(title=f[2], ident=f[3] if len(f) > 3 else "",
                             controls=[], toggles=[], texts=[])
    elif kind in ("C", "B") and f[1] in windows:
        f += [""] * (9 - len(f))
        item = dict(role=f[2], desc=f[3], title=f[4], value=f[5], width=f[6], height=f[7],
                    images=[i for i in f[8].split(";") if i] if kind == "C" else [])
        windows[f[1]]["controls" if kind == "C" else "toggles"].append(item)
    elif kind == "T" and f[1] in windows:
        windows[f[1]]["texts"].append(f[2])

results, notes, coverage, listing = [], [], [], []
seen = set()
failed = False

def verdict(ok, text):
    global failed
    results.append(("PASS " if ok else "FAIL ") + text)
    failed = failed or not ok

def name(c):
    return c["desc"] or c["title"] or c["value"] or "(unnamed)"

def describe(c):
    bits = [c["role"]]
    if c["title"] and c["title"] != name(c):
        bits.append("title \"%s\"" % c["title"])
    if c["value"] and c["value"] != name(c):
        bits.append("value \"%s\"" % c["value"])
    bits.append("%sx%spt" % (c["width"], c["height"]))
    return "\"%s\" (%s)" % (name(c), ", ".join(bits))

def height(c):
    try:
        return float(c["height"])
    except ValueError:
        return None

def find(controls, pattern):
    rx = re.compile(pattern)
    return [c for c in controls if any(rx.fullmatch(c[k] or "") for k in ("desc", "title"))]

def expect(where, what, found):
    if found:
        verdict(True, "%s: %s present: %s" % (where, what, describe(found[0])))
    else:
        verdict(False, "%s: %s is missing" % (where, what))

if procs == 0:
    verdict(False, "no Issa Reader window: the app is not running")
elif procs > 1:
    verdict(False, "%d processes are called Issa Reader; quit all but the build under test" % procs)
elif not windows:
    verdict(False, "no Issa Reader window: the app is running with none open")

if procs == 1:
    # The header is LibraryView's, and the library window takes the shelf's
    # title (`LibraryArrangement.Shelf.title`) while it shows one. The count
    # line alone is not enough: a series pushed over the grid says "5 books"
    # too, and has no header.
    SHELVES = {"All books", "Reading", "To read", "Finished", "Downloaded", "With audio"}
    COUNT_LINE = re.compile(r"\d+ (books?|results?)|\d+ of \d+ books?")
    for index in sorted(windows, key=int):
        w = windows[index]
        where = "window %s \"%s\"" % (index, w["title"])
        listing.append("%s%s" % (where, "  [%s]" % w["ident"] if w["ident"] else ""))
        for c in w["controls"]:
            listing.append("  %s" % describe(c)
                           + ("  images: %s" % ", ".join(c["images"]) if c["images"] else ""))
        for t in w["toggles"]:
            listing.append("  %s" % describe(t))

        # Every pop-up and pull-down, whatever window it is in.
        for c in w["controls"]:
            h = height(c)
            if h is None:
                notes.append("%s: %s reported no size" % (where, name(c)))
            elif h > LIMIT:
                verdict(False, "%s: \"%s\" is %gpt tall, over %dpt: a second control drawn"
                        " inside the system's?" % (where, name(c), h, LIMIT))
            if any("chevron" in i.lower() for i in c["images"]):
                notes.append("%s: \"%s\" has a chevron image inside it (%s); not asserted"
                             % (where, name(c), ", ".join(c["images"])))

        texts = [t.lower() for t in w["texts"]]
        showing = []
        if w["title"] in SHELVES and any(COUNT_LINE.fullmatch(t) for t in w["texts"]):
            showing.append("library header")
            expect(where, "tags pull-down", find(w["controls"], r"Filter by tag|\d+ tags? selected"))
            expect(where, "sort pop-up", find(w["controls"], r"Sort by"))
            expect(where, "Reverse order toggle", find(w["toggles"], r"Reverse order"))
        if "manage downloads" in texts:
            showing.append("book detail")
            expect(where, "reading status pop-up",
                   find(w["controls"], r"(Set|Change) reading status"))
            if any(t.startswith("books download automatically") for t in texts):
                showing.append("edition menus")
                expect(where, "edition options pull-down", find(w["controls"], r".+ options"))
            else:
                notes.append("%s: Manage downloads is closed, so the edition menus were not"
                             " checked" % where)
        if w["title"] == "Now Playing" or "NowPlaying" in w["ident"]:
            showing.append("Now Playing")
            expect(where, "speed pull-down", find(w["controls"], r"\d+(\.\d+)?×"))
        seen.update(showing)
        coverage.append("%s: %s" % (where, ", ".join(showing) if showing else
                                    "no expected controls, height rule only"))

    all_controls = [c for w in windows.values() for c in w["controls"]]
    tall = [c for c in all_controls if (height(c) or 0) > LIMIT]
    if all_controls and not tall:
        verdict(True, "all %d pop-up and pull-down buttons are %dpt or shorter"
                % (len(all_controls), LIMIT))
    for part in ("library header", "book detail", "edition menus", "Now Playing"):
        if part not in seen:
            notes.append("not checked in this run: %s (no window was showing it)" % part)
    if not all_controls and windows:
        verdict(False, "no pop-up or pull-down button in any window: nothing was checked")

with open(report_path, "w", encoding="utf-8") as out:
    out.write("label    %s\n" % label)
    out.write("when     %s\n" % datetime.datetime.now(datetime.timezone.utc)
              .strftime("%Y-%m-%dT%H:%M:%SZ"))
    out.write("app      %s\n" % (bundle or "(not running)"))
    out.write("limit    %dpt\n\n" % LIMIT)
    if listing:
        out.write("controls\n")
        out.writelines("  %s\n" % l for l in listing)
        out.write("\n")
    if coverage:
        out.write("coverage\n")
        out.writelines("  %s\n" % l for l in coverage)
        out.write("\n")
    out.writelines("%s\n" % r for r in results)
    if notes:
        out.write("\n")
        out.writelines("NOTE %s\n" % n for n in notes)
sys.exit(1 if failed else 0)
PY
STATUS=$?
set -e
cat "$REPORT"
exit "$STATUS"
