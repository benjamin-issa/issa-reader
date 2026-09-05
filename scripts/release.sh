#!/usr/bin/env bash
#
# Archive and upload Issa Reader to App Store Connect.
#
# One command for all three apps, because the build number lives in one place
# and a release that ships two platforms out of three is how they drift.
#
#   scripts/release.sh                              # bump, then ship all three
#   scripts/release.sh --platforms macos            # just the Mac
#   scripts/release.sh --build 18 --destination export   # local .pkg/.ipa, no upload
#   scripts/release.sh --archive-only               # stop after archiving
#
# Authentication is the App Store Connect API key, never Xcode's session:
# `xcodebuild` cannot read Xcode's signed-in account and prints
# "exportArchive No Accounts" when it tries. See docs/RELEASE.md.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"

KEY_PATH="$HOME/.app-store-connect-key.p8"
KEY_META="$HOME/.app-store-connect-key.json"

# The string that must never reach a shipping binary. It is the launch
# argument UITestFixture.installIfRequested() checks for, so it exists only
# inside the fixture code.
FIXTURE_MARKER='IssaUITestFixture'

# Whether the marker is in this binary.
#
# The capture into a variable is the whole point, and replaces
# `strings "$binary" | grep -q "$FIXTURE_MARKER"`. That form could never report
# a leak: `grep -q` exits at the first match, `strings` then dies of SIGPIPE,
# and `set -o pipefail` promotes 141 to the pipeline status — so the `if` took
# the false branch precisely when the marker WAS present, and the guard was
# correct only in the case where there was nothing to find. `grep -c` reads to
# the end, so nothing is closed early and there is no signal to mistake.
#
# `-a` scans every section. Swift stores string literals of fifteen UTF-8 bytes
# or fewer in (__TEXT,__text), which plain `strings` skips; the marker survives
# that today only by being eighteen bytes long.
fixture_present() {
    local binary="$1" hits
    hits=$(strings -a "$binary" 2>/dev/null | grep -c "$FIXTURE_MARKER" || true)
    [ "${hits:-0}" -gt 0 ]
}

# Prove the guard can fire before trusting it to stay silent.
#
# This is the lesson of the bug above: for a whole release cycle the check
# reported "clean" on every build, and that was indistinguishable from working.
# A guard nobody has seen fail is not evidence.
fixture_guard_selftest() {
    local probe status=0
    probe="$(mktemp "${TMPDIR:-/tmp}/issa-fixture-probe.XXXXXX")"
    printf 'padding %s padding\n' "$FIXTURE_MARKER" > "$probe"
    # Push the marker well back from the end so a truncated read cannot pass by
    # luck, and keep it printable so `strings` emits it.
    head -c 200000 /dev/zero | tr '\0' 'a' >> "$probe"
    fixture_present "$probe" || status=1
    rm -f "$probe"
    if [ "$status" -ne 0 ]; then
        echo "error: the fixture-leak guard failed its own self-test." >&2
        echo "       It cannot find $FIXTURE_MARKER in a file that contains it," >&2
        echo "       so it cannot be trusted to find it in a shipping binary." >&2
        return 1
    fi
    return 0
}

# The build-number bump edits a tracked file. A failure anywhere downstream used
# to leave it bumped on disk, so a failed archive silently consumed a build
# number and the next run started from the wrong one.
PROJECT_YML_BACKUP=""
restore_project_yml() {
    [ -n "$PROJECT_YML_BACKUP" ] || return 0
    [ -f "$PROJECT_YML_BACKUP" ] || return 0
    mv "$PROJECT_YML_BACKUP" "$ROOT/project.yml"
    echo "project.yml: build number restored — this run did not consume one" >&2
    PROJECT_YML_BACKUP=""
}
trap restore_project_yml EXIT

PLATFORMS="ios,tvos,macos"
BUILD=""
BUMP=1
DESTINATION="upload"
ARCHIVE_ONLY=0
WORK=""

usage() {
    sed -n '3,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --platforms) PLATFORMS="$2"; shift 2 ;;
        --build) BUILD="$2"; BUMP=0; shift 2 ;;
        --no-bump) BUMP=0; shift ;;
        --destination) DESTINATION="$2"; shift 2 ;;
        --archive-only) ARCHIVE_ONLY=1; shift ;;
        --work) WORK="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) echo "unknown argument: $1" >&2; usage 1 ;;
    esac
done

case "$DESTINATION" in
    upload|export) ;;
    *) echo "--destination must be upload or export" >&2; exit 1 ;;
esac

for path in "$KEY_PATH" "$KEY_META"; do
    [ -f "$path" ] || { echo "missing $path — see docs/RELEASE.md" >&2; exit 1; }
done
KEY_ID=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.app-store-connect-key.json")))["keyID"])')
ISSUER_ID=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.app-store-connect-key.json")))["issuerID"])')

# Per platform: the scheme, the archive destination, and the name App Store
# Connect knows the platform by.
scheme_for()      { case "$1" in ios) echo IssaReader-iOS ;; tvos) echo IssaReader-tvOS ;; macos) echo IssaReader-macOS ;; esac; }
destination_for() { case "$1" in ios) echo 'generic/platform=iOS' ;; tvos) echo 'generic/platform=tvOS' ;; macos) echo 'generic/platform=macOS' ;; esac; }
asc_platform_for(){ case "$1" in ios) echo IOS ;; tvos) echo TV_OS ;; macos) echo MAC_OS ;; esac; }

IFS=',' read -r -a REQUESTED <<< "$PLATFORMS"
for platform in "${REQUESTED[@]}"; do
    [ -n "$(scheme_for "$platform")" ] || { echo "unknown platform: $platform" >&2; exit 1; }
done

if [ -n "$(git status --porcelain)" ]; then
    echo "warning: the working tree is dirty; the build will not match any commit" >&2
fi

CURRENT=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\{0,1\}\([0-9][0-9]*\)"\{0,1\} *$/\1/p' project.yml | head -1)
[ -n "$CURRENT" ] || { echo "could not read CURRENT_PROJECT_VERSION from project.yml" >&2; exit 1; }
if [ -z "$BUILD" ]; then
    if [ "$BUMP" = 1 ]; then BUILD=$((CURRENT + 1)); else BUILD="$CURRENT"; fi
fi

# A build number is spent permanently on a successful upload, and
# `manageAppVersionAndBuildNumber` is false, so a reused one fails as
# ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE — after a six-minute archive. Ask
# first. Also catches the macOS platform not being enabled on the app record,
# which no API can fix.
if [ "$DESTINATION" = upload ] && [ "$ARCHIVE_ONLY" = 0 ]; then
    RECORD_PLATFORMS=$(python3 scripts/asc-api.py platforms)
    for platform in "${REQUESTED[@]}"; do
        asc=$(asc_platform_for "$platform")
        if ! echo "$RECORD_PLATFORMS" | grep -qx "$asc"; then
            echo "error: the App Store Connect record has no $asc platform." >&2
            echo "       Add it in App Store Connect (Apps → Issa Reader → the platform" >&2
            echo "       list → +) — no endpoint can do it. See docs/RELEASE.md." >&2
            exit 1
        fi
        # Captured first: a command in an `if` condition is exempt from
        # `set -e`, so a failing query read as "the number is free".
        EXISTING=$(python3 scripts/asc-api.py builds --platform "$asc")
        if grep -qx "$BUILD" <<<"$EXISTING"; then
            echo "error: $asc already has build $BUILD. Pick another with --build." >&2
            exit 1
        fi
    done
fi

fixture_guard_selftest || exit 1

if [ "$BUILD" != "$CURRENT" ]; then
    # The build number is one value for every target, on purpose: App Store
    # Connect counts it per platform, so sharing it keeps the three apps
    # legible as one release.
    PROJECT_YML_BACKUP="$(mktemp "${TMPDIR:-/tmp}/issa-project-yml.XXXXXX")"
    cp project.yml "$PROJECT_YML_BACKUP"
    /usr/bin/sed -i '' "s/^\( *CURRENT_PROJECT_VERSION: \).*$/\1\"$BUILD\"/" project.yml
    echo "project.yml: CURRENT_PROJECT_VERSION $CURRENT → $BUILD"
fi

command -v xcodegen >/dev/null || { echo "xcodegen not found" >&2; exit 1; }
xcodegen generate >/dev/null
echo "xcodegen: IssaReader.xcodeproj regenerated"

[ -n "$WORK" ] || WORK="${TMPDIR:-/tmp}/issa-release-$BUILD"
mkdir -p "$WORK"
echo "work directory: $WORK"
echo

declare -a RESULTS=()
FAILED=0

for platform in "${REQUESTED[@]}"; do
    scheme=$(scheme_for "$platform")
    archive="$WORK/$platform.xcarchive"
    log="$WORK/$platform-archive.log"

    echo "▸ $scheme — archiving build $BUILD"
    if xcodebuild -project IssaReader.xcodeproj -scheme "$scheme" \
        -configuration Release -destination "$(destination_for "$platform")" \
        -archivePath "$archive" \
        -authenticationKeyPath "$KEY_PATH" \
        -authenticationKeyID "$KEY_ID" \
        -authenticationKeyIssuerID "$ISSUER_ID" \
        -allowProvisioningUpdates archive > "$log" 2>&1; then
        echo "  archived"

        # The layout-sweep fixture is compiled out of Release by
        # EXCLUDED_SOURCE_FILE_NAMES, and ISSA_UITEST_FIXTURE on top of that.
        # This is the check that neither has quietly drifted: the marker exists
        # only inside the guarded code, so finding it in a shipping binary means
        # a stub server and an in-memory token store went with it. Fails the
        # release rather than the review.
        #
        # `shopt -s nullglob` matters. Without it an unmatched pattern stays
        # literal, `[ -f ]` skips it, and the loop body never runs — so the
        # release passed having inspected nothing at all.
        shopt -s nullglob
        scanned=0
        for binary in "$archive"/Products/Applications/*.app/IssaReader-* \
                      "$archive"/Products/Applications/*.app/Contents/MacOS/IssaReader-* \
                      "$archive"/Products/Applications/*.app/PlugIns/*.appex/IssaWidgets; do
            [ -f "$binary" ] || continue
            scanned=$((scanned + 1))
            if fixture_present "$binary"; then
                echo "  ERROR: the UI-test fixture is present in $binary"
                RESULTS+=("$platform: fixture leaked into the Release binary")
                FAILED=1
                shopt -u nullglob
                continue 2
            fi
        done
        shopt -u nullglob

        # A guard that inspected nothing is not a guard. The product name is
        # $(TARGET_NAME) today, so these globs match by coincidence; setting
        # PRODUCT_NAME would make them vacuous with no other visible change.
        if [ "$scanned" -eq 0 ]; then
            echo "  ERROR: found no binary to scan for the fixture marker in $archive"
            RESULTS+=("$platform: fixture guard inspected no binaries")
            FAILED=1
            continue
        fi
        echo "  fixture guard: $scanned binar$([ "$scanned" = 1 ] && echo y || echo ies) clean"
    else
        echo "  ARCHIVE FAILED — $log"
        grep -m 5 "error:" "$log" | sed 's/^/    /' || true
        RESULTS+=("$platform: archive failed")
        FAILED=1
        continue
    fi

    if [ "$ARCHIVE_ONLY" = 1 ]; then
        RESULTS+=("$platform: archived at $archive")
        continue
    fi

    # The committed plist says `upload`; a dry run rewrites the copy, never the
    # original.
    plist="$WORK/$platform-export.plist"
    cp "$ROOT/scripts/export/$platform.plist" "$plist"
    /usr/libexec/PlistBuddy -c "Set :destination $DESTINATION" "$plist" >/dev/null

    export_log="$WORK/$platform-export.log"
    echo "▸ $scheme — ${DESTINATION}ing"
    if xcodebuild -exportArchive -archivePath "$archive" \
        -exportOptionsPlist "$plist" -exportPath "$WORK/$platform-export" \
        -authenticationKeyPath "$KEY_PATH" \
        -authenticationKeyID "$KEY_ID" \
        -authenticationKeyIssuerID "$ISSUER_ID" \
        -allowProvisioningUpdates > "$export_log" 2>&1 \
        && grep -q "EXPORT SUCCEEDED" "$export_log"; then
        if [ "$DESTINATION" = upload ]; then
            RESULTS+=("$platform: uploaded build $BUILD")
            # Spent, the moment one platform's upload lands: App Store Connect
            # now holds this build number, so reverting project.yml because a
            # *later* platform failed — which the EXIT trap did — made the next
            # release collide with a number the store already has.
            rm -f "$PROJECT_YML_BACKUP"
            PROJECT_YML_BACKUP=""
        else
            RESULTS+=("$platform: exported to $WORK/$platform-export")
        fi
        echo "  done"
    else
        echo "  EXPORT FAILED — $export_log"
        grep -m 5 -E "error:|Error Domain" "$export_log" | sed 's/^/    /' || true
        RESULTS+=("$platform: export failed")
        FAILED=1
    fi
    echo
done

if [ "$FAILED" = 0 ]; then
    # The bump stands only when every requested platform got through. Keeping
    # the backup until here is what makes a partial failure cost nothing.
    rm -f "$PROJECT_YML_BACKUP"
    PROJECT_YML_BACKUP=""
fi

echo "── build $BUILD ──"
# `${arr[@]}` on an empty array is a fatal unbound-variable error under `set -u`
# on bash 3.2, which is what /usr/bin/env bash is on macOS.
for line in ${RESULTS[@]+"${RESULTS[@]}"}; do echo "  $line"; done
exit "$FAILED"
