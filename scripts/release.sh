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
        if python3 scripts/asc-api.py builds --platform "$asc" | grep -qx "$BUILD"; then
            echo "error: $asc already has build $BUILD. Pick another with --build." >&2
            exit 1
        fi
    done
fi

if [ "$BUILD" != "$CURRENT" ]; then
    # The build number is one value for every target, on purpose: App Store
    # Connect counts it per platform, so sharing it keeps the three apps
    # legible as one release.
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

echo "── build $BUILD ──"
for line in "${RESULTS[@]}"; do echo "  $line"; done
exit "$FAILED"
