#!/usr/bin/env bash
# Archive, export and upload one platform to TestFlight, then add the build to an
# internal group. Usage: scripts/release/testflight.sh ios|macos
# Requires: HGS_APP_ID (App Store Connect app id), an internal TestFlight group
# (HGS_GROUP name or id), installed App Store profiles named below, and asc auth.
set -euo pipefail
PLATFORM="${1:?Usage: testflight.sh ios|macos}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_ID="${HGS_APP_ID:?Set HGS_APP_ID}"
case "$PLATFORM" in
  ios)   DEST='generic/platform=iOS';   EXT=ipa; ASC_PLATFORM=IOS;    PROFILE='HomeGardenStudio iOS App Store' ;;
  macos) DEST='generic/platform=macOS'; EXT=pkg; ASC_PLATFORM=MAC_OS; PROFILE='HomeGardenStudio Mac App Store' ;;
  *) echo "Unknown platform $PLATFORM" >&2; exit 1 ;;
esac
asc auth status --validate >/dev/null
~/ashcode/diskcleaner/bin/diskcleaner check || [ $? -eq 10 ]
"$ROOT/scripts/build-core-xcframework.sh"
cd "$ROOT/apple" && xcodegen generate
REL="$ROOT/apple/build/release-$PLATFORM"; rm -rf "$REL"; mkdir -p "$REL"
ARCHIVE="$REL/HomeGardenStudio.xcarchive"
# Monotonic build number shared by both platforms unless overridden.
BUILD_NUMBER="${HGS_BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
xcodebuild -project HomeGardenStudio.xcodeproj -scheme HomeGardenStudio -configuration Release \
  -destination "$DEST" -archivePath "$ARCHIVE" -derivedDataPath "$REL/derived" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY='Apple Distribution' DEVELOPMENT_TEAM=6P24N3R4TP \
  PROVISIONING_PROFILE_SPECIFIER="$PROFILE" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" archive
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$REL/export" \
  -exportOptionsPlist "$ROOT/scripts/release/exportOptions-$PLATFORM.plist"
PKG="$(ls "$REL"/export/*.$EXT | head -1)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' "$ARCHIVE/Info.plist")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleShortVersionString' "$ARCHIVE/Info.plist")"
asc builds upload --app "$APP_ID" "--$EXT" "$PKG" --wait --checksum --version "$VERSION" --build-number "$BUILD" --output table
if [ -n "${HGS_GROUP:-}" ]; then
  asc builds add-groups --app "$APP_ID" --build-number "$BUILD" --platform "$ASC_PLATFORM" --group "$HGS_GROUP" --output table
fi
rm -rf "$REL/derived"
echo "HomeGardenStudio $PLATFORM $VERSION ($BUILD) uploaded. Archive kept at $ARCHIVE"
