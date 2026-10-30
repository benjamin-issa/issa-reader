#!/usr/bin/env bash
#
# Build the Android app's release bundle for Google Play.
#
#   scripts/android-release.sh                 # raise the build number, then build
#   scripts/android-release.sh --build 18      # build this number, no raise
#
# The signed bundle, its R8 mapping and a note of what was built land in
# .build/android-release/. Uploading is scripts/android-play.py's, as a draft
# release the Play Console then sends for review. See docs/RELEASE.md,
# "Android".
#
# The version name is the Apple apps' MARKETING_VERSION, read from project.yml
# by the build itself; the build number is Android/version.properties.

set -euo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"

usage() { sed -n '5,6p' "$SELF" | sed 's/^# \{0,1\}//' >&2; exit 2; }

BUILD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --build) [ $# -ge 2 ] || usage; BUILD="$2"; shift ;;
    -h|--help) usage ;;
    *) echo "error: unknown argument $1" >&2; usage ;;
  esac
  shift
done

# The upload key, from outside the repository (Android/app/build.gradle.kts
# reads the same file). A bundle signed with anything else is refused by Play.
KEY_FILE="${ISSA_ANDROID_UPLOAD_KEY:-$HOME/.android-upload-key.properties}"
if [ ! -f "$KEY_FILE" ]; then
  echo "error: no upload key at $KEY_FILE (or set ISSA_ANDROID_UPLOAD_KEY). See docs/RELEASE.md." >&2
  exit 1
fi
KEY_ALIAS=$(sed -n 's/^[[:space:]]*keyAlias[[:space:]]*=[[:space:]]*//p' "$KEY_FILE" | tail -1)

# The string that exists only inside the UI-test fixture (the iPhone's
# release.sh guards the same one). It must never reach a shipping build.
FIXTURE_MARKER='IssaUITestFixture'

VERSION_FILE="$ROOT/Android/version.properties"
current=$(sed -n 's/^versionCode=//p' "$VERSION_FILE")
[[ "$current" =~ ^[0-9]+$ ]] || { echo "error: no versionCode in $VERSION_FILE" >&2; exit 1; }
if [ -n "$BUILD" ]; then
  [[ "$BUILD" =~ ^[0-9]+$ ]] || { echo "error: --build takes a number" >&2; exit 2; }
  [ "$BUILD" -ge "$current" ] || echo "warning: $BUILD is below the recorded $current; Play refuses a number it has seen" >&2
  next="$BUILD"
else
  next=$((current + 1))
fi
if [ "$next" != "$current" ]; then
  sed -i.bak "s/^versionCode=.*/versionCode=$next/" "$VERSION_FILE" && rm -f "$VERSION_FILE.bak"
fi
version=$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}.*/\1/p' "$ROOT/project.yml" | head -1)
echo "▸ Issa Reader for Android $version ($next)"

cd "$ROOT/Android"
./gradlew :app:bundleRelease --console=plain

AAB="$ROOT/Android/app/build/outputs/bundle/release/app-release.aab"
MAPPING="$ROOT/Android/app/build/outputs/mapping/release/mapping.txt"
[ -f "$AAB" ] || { echo "error: no bundle at $AAB" >&2; exit 1; }

echo "▸ checking the bundle"
# Signed, and by the upload key's alias.
verify=$(jarsigner -verify -verbose -certs "$AAB" 2>&1 || true)
if ! grep -q "jar verified" <<<"$verify"; then
  echo "error: the bundle is not signed; jarsigner says:" >&2
  tail -5 <<<"$verify" >&2
  exit 1
fi
# No fixture code in any dex file. Read with Python rather than piped through
# grep -q, which would close the pipe early (see release.sh's fixture_present).
python3 -I - "$AAB" "$FIXTURE_MARKER" <<'PY'
import sys, zipfile
bundle, marker = sys.argv[1], sys.argv[2].encode()
dexes = [n for n in zipfile.ZipFile(bundle).namelist() if n.endswith(".dex")]
if not dexes:
    sys.exit("error: the bundle holds no dex files, so nothing was scanned")
leaks = [n for n in dexes if marker in zipfile.ZipFile(bundle).read(n)]
if leaks:
    sys.exit(f"error: the UI-test fixture is in the release build: {', '.join(leaks)}")
print(f"  no fixture code in {len(dexes)} dex file(s)")
PY

cd "$ROOT"
OUT="$ROOT/.build/android-release"
mkdir -p "$OUT"
name="IssaReader-$version-$next"
cp "$AAB" "$OUT/$name.aab"
[ -f "$MAPPING" ] && cp "$MAPPING" "$OUT/$name-mapping.txt"
{
  echo "version      $version ($next)"
  echo "commit       $(git rev-parse --short HEAD 2>/dev/null || echo unknown)$([ -z "$(git status --porcelain -- . ':!Android/version.properties' 2>/dev/null)" ] || echo ' (dirty)')"
  echo "when         $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "signed by    ${KEY_ALIAS:-unknown alias}"
  echo "bundle       $OUT/$name.aab"
} > "$OUT/$name.txt"
cat "$OUT/$name.txt"
echo
echo "Upload it with scripts/android-play.py upload $OUT/$name.aab --track alpha --notes Android/play/listing/en-US/release-notes.txt,"
echo "and commit Android/version.properties at $next."
