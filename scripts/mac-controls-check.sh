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
# the Accessibility API (a short Swift program it runs with `swift`), which
# needs no focus, so it leaves the screen alone. The terminal running it needs
# Accessibility access (System Settings › Privacy & Security › Accessibility).
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
# when the book detail's container is; its edition menus are expected once the
# Manage downloads section's text is showing. What was and was not looked at is
# written out as coverage, so a run that checked nothing cannot pass for one
# that checked everything. A window whose contents could not be read fails
# the run: it would otherwise count as a window showing nothing expected.
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
# Both taken before the `cd` to the root: `$0` and a relative MAC_CHECK_DUMP
# are paths from wherever the script was run, and from the root they name
# nothing, or the wrong file.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
case "${MAC_CHECK_DUMP:-}" in "" | /*) ;; *) MAC_CHECK_DUMP="$PWD/$MAC_CHECK_DUMP" ;; esac
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"

usage() { sed -n '6,7p' "$SELF" | sed 's/^# \{0,1\}//' >&2; exit 2; }

[ $# -eq 1 ] || usage
LABEL="$1"
case "$LABEL" in -*|*/*|"") usage ;; esac

APP="Issa Reader"
OUT="$ROOT/.build/mac-check"
REPORT="$OUT/$LABEL.txt"
RAW="$OUT/$LABEL.raw.tsv"
mkdir -p "$OUT"
rm -f "$REPORT"

command -v swift >/dev/null || { echo "error: swift not found; this runs on a Mac with Xcode" >&2; exit 1; }
command -v python3 >/dev/null || { echo "error: python3 not found" >&2; exit 1; }

# The dump. One tab-separated record per line:
#   P  <count of processes named APP>  <bundle path of the first>
#   W  <window>  <title>  <AXIdentifier>
#   C  <window>  <role>  <description>  <title>  <value>  <width>  <height>  <image children>
#   B  <window>  <role>  <description>  <title>  <value>  <width>  <height>
#   T  <window>  <static text>
#   E  <window>  <why its contents could not be read>
# C is every pop-up and pull-down button, named by its AXDescription or
# AXTitle. B is a button or checkbox labelled "Reverse order". T marks what a
# window is showing: the library's count line, the Manage downloads section's
# text, or "#book-detail" for the book detail's container (AXIdentifier
# `content.bookDetail`). E is a window whose tree could not be read. An attribute
# SwiftUI leaves unset reads as empty, never as a failure.
#
# To a file, not through `$(...)`: macOS's bash 3.2 misparses a here-document
# inside a command substitution.
if [ -n "${MAC_CHECK_DUMP:-}" ]; then
  [ -f "$MAC_CHECK_DUMP" ] || { echo "error: no dump at $MAC_CHECK_DUMP" >&2; exit 2; }
  [ "$MAC_CHECK_DUMP" -ef "$RAW" ] || cp "$MAC_CHECK_DUMP" "$RAW"
else
  # Through the Accessibility API itself, not System Events. System Events
  # answers `description` with the role ("pop up button") and cannot see the
  # AXDescription SwiftUI gives a pop-up or a button-style toggle, so every
  # label this check matches on was invisible to it. The API is what VoiceOver
  # reads, which is the point of matching on labels at all.
  cat > "$OUT/$LABEL.ax.swift" <<'SWIFT'
import AppKit
import ApplicationServices

let appName = CommandLine.arguments[1]
func clean(_ s: String) -> String {
    s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
}
func string(_ e: AXUIElement, _ a: String) -> String {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success, let v else { return "" }
    if let s = v as? String { return clean(s) }
    if let n = v as? NSNumber { return n.stringValue }
    return ""
}
func size(_ e: AXUIElement) -> String {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &v) == .success,
          let v, CFGetTypeID(v) == AXValueGetTypeID() else { return "?\t?" }
    var s = CGSize.zero
    AXValueGetValue(v as! AXValue, .cgSize, &s)
    return "\(Int(s.width.rounded()))\t\(Int(s.height.rounded()))"
}
func children(_ e: AXUIElement) -> [AXUIElement]? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) == .success else { return nil }
    return (v as? [AXUIElement]) ?? []
}

let apps = NSWorkspace.shared.runningApplications.filter { $0.localizedName == appName }
print("P\t\(apps.count)\t\(apps.first?.bundleURL?.path ?? "")")
guard let app = apps.first else { exit(0) }
guard AXIsProcessTrusted() else {
    FileHandle.standardError.write("not allowed: this terminal has no Accessibility access\n".data(using: .utf8)!)
    exit(3)
}
let countLine = try! NSRegularExpression(pattern: #"^\d+ (books?|results?)$|^\d+ of \d+ books?$"#)
var windowsRef: CFTypeRef?
AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                              kAXWindowsAttribute as CFString, &windowsRef)
for (i, w) in ((windowsRef as? [AXUIElement]) ?? []).enumerated() {
    let wi = i + 1
    print("W\t\(wi)\t\(string(w, kAXTitleAttribute))\t\(string(w, kAXIdentifierAttribute))")
    guard var stack = children(w) else { print("E\t\(wi)\tits children could not be read"); continue }
    var visited = 0
    while let e = stack.popLast(), visited < 20_000 {
        visited += 1
        let role = string(e, kAXRoleAttribute)
        let desc = string(e, kAXDescriptionAttribute), title = string(e, kAXTitleAttribute)
        // The book detail's own container: there for every book, where the
        // Read button is not — an audiobook with no edition to read has none,
        // and keyed on it the detail went unchecked and the run still passed.
        if string(e, kAXIdentifierAttribute) == "content.bookDetail" { print("T\t\(wi)\t#book-detail") }
        switch role {
        case "AXPopUpButton", "AXMenuButton":
            let images = (children(e) ?? []).filter { string($0, kAXRoleAttribute) == "AXImage" }
                .map { string($0, kAXDescriptionAttribute) }.joined(separator: ";")
            print("C\t\(wi)\t\(role)\t\(desc)\t\(title)\t\(string(e, kAXValueAttribute))\t\(size(e))\t\(images)")
        case "AXButton", "AXCheckBox":
            if [desc, title, string(e, kAXHelpAttribute)].contains("Reverse order") {
                print("B\t\(wi)\t\(role)\t\(desc)\t\(title)\t\(string(e, kAXValueAttribute))\t\(size(e))")
            }
        case "AXStaticText":
            let v = string(e, kAXValueAttribute).isEmpty ? desc : string(e, kAXValueAttribute)
            let range = NSRange(v.startIndex..., in: v)
            if v.hasPrefix("Books download automatically")
                || countLine.firstMatch(in: v, range: range) != nil {
                print("T\t\(wi)\t\(v)")
            }
        default: break
        }
        stack.append(contentsOf: children(e) ?? [])
    }
    if visited >= 20_000 { print("E\t\(wi)\tover 20000 elements; stopped walking") }
}
SWIFT
  if ! swift "$OUT/$LABEL.ax.swift" "$APP" > "$RAW" 2> "$OUT/$LABEL.ax.err"; then
    cat "$OUT/$LABEL.ax.err" >&2
    if grep -q 'not allowed' "$OUT/$LABEL.ax.err"; then
      echo "error: this terminal may not read another app's controls." >&2
      echo "       Grant it Accessibility (System Settings › Privacy & Security › Accessibility)." >&2
    else
      echo "error: reading $APP's windows through the Accessibility API failed (above)" >&2
    fi
    exit 1
  fi
  rm -f "$OUT/$LABEL.ax.swift" "$OUT/$LABEL.ax.err"
fi

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
                             controls=[], toggles=[], texts=[], errors=[])
    elif kind in ("C", "B") and f[1] in windows:
        f += [""] * (9 - len(f))
        item = dict(role=f[2], desc=f[3], title=f[4], value=f[5], width=f[6], height=f[7],
                    images=[i for i in f[8].split(";") if i] if kind == "C" else [])
        windows[f[1]]["controls" if kind == "C" else "toggles"].append(item)
    elif kind == "T" and f[1] in windows:
        windows[f[1]]["texts"].append(f[2])
    elif kind == "E" and f[1] in windows:
        windows[f[1]]["errors"].append(f[2] if len(f) > 2 and f[2] else "no reason given")

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

        # A window that could not be read shows no count line and no Manage
        # downloads, so below it would pass as one showing nothing expected.
        for e in w["errors"]:
            verdict(False, "%s: could not read its contents (%s), so nothing in it was checked"
                    % (where, e))

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
        if "#book-detail" in w["texts"]:
            showing.append("book detail")
            expect(where, "reading status pop-up",
                   find(w["controls"], r"(Set|Change) reading status"))
            if any(t.startswith("books download automatically") for t in texts):
                showing.append("edition menus")
                expect(where, "edition options pull-down", find(w["controls"], r".+ options"))
            else:
                notes.append("%s: Manage downloads is closed, so the edition menus were not"
                             " checked" % where)
        # By title alone: every window's identifier is its SwiftUI type, and
        # the library's names `NowPlayingController` in its environment.
        if w["title"] == "Now Playing":
            showing.append("Now Playing")
            expect(where, "speed pull-down", find(w["controls"], r"\d+(\.\d+)?×"))
        seen.update(showing)
        coverage.append("%s: %s" % (where, "could not be read" if w["errors"] else
                                    ", ".join(showing) if showing else
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
