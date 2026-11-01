#!/usr/bin/env bash
# Local unsigned/ad-hoc verification only. Does not archive, upload, or change accounts.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
scope="${1:-all}"
case "$scope" in
  all) schemes=(HomeGardenStudio HomeGardenStudioApple) ;;
  standard) schemes=(HomeGardenStudio) ;;
  apple-only) schemes=(HomeGardenStudioApple) ;;
  *) echo "Usage: scripts/apple-verify.sh [all|standard|apple-only]" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then echo "Unexpected arguments." >&2; exit 2; fi
if [ "$scope" != standard ]; then
  for path in apple/HomeGardenStudio/AI/AppleConceptImage.swift apple/HomeGardenStudio/Views/AppleConceptSheet.swift \
    apple/HomeGardenStudioAppleTests/AppleOnlyServicesTests.swift apple/HomeGardenStudioTests/AppleConceptImageTests.swift \
    scripts/check-apple-only-build.py; do
    test -f "$ROOT/$path" || { echo "Missing Apple-only component: $path" >&2; exit 1; }
  done
fi
check_space() {
  bash "$ROOT/scripts/check-build-space.sh"
}
command -v xcodegen >/dev/null || { echo "XcodeGen is required." >&2; exit 1; }
check_space
"$ROOT/scripts/build-core-xcframework.sh"
xcodegen generate --spec "$ROOT/apple/project.yml" --project "$ROOT/apple"
mkdir -p "$ROOT/apple/build/logs"
for scheme in "${schemes[@]}"; do
  check_space
  xcodebuild -jobs 1 -project "$ROOT/apple/HomeGardenStudio.xcodeproj" -scheme "$scheme" \
    -destination 'platform=macOS' -derivedDataPath "$ROOT/apple/build/DerivedData" \
    'OTHER_SWIFT_FLAGS=-driver-batch-count 1' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS= \
    build test 2>&1 | tee "$ROOT/apple/build/logs/$scheme-macos-build-test.log"
  check_space
  xcodebuild -jobs 1 -project "$ROOT/apple/HomeGardenStudio.xcodeproj" -scheme "$scheme" \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$ROOT/apple/build/DerivedData" \
    'OTHER_SWIFT_FLAGS=-driver-batch-count 1' CODE_SIGNING_ALLOWED=NO build 2>&1 | tee "$ROOT/apple/build/logs/$scheme-ios-simulator-build.log"
  if [ "$scheme" = HomeGardenStudioApple ]; then
    python3 "$ROOT/scripts/check-apple-only-build.py" --derived-data "$ROOT/apple/build/DerivedData"
  fi
done
echo "Verified schemes: ${schemes[*]} — macOS builds and unit tests; iOS Simulator builds. Runtime and distribution gates are separate."
