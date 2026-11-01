#!/usr/bin/env bash
# Local unsigned/ad-hoc verification only. Does not archive, upload, or change accounts.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
check_space() {
  bash "$ROOT/scripts/check-build-space.sh"
}
command -v xcodegen >/dev/null || { echo "XcodeGen is required." >&2; exit 1; }
check_space
"$ROOT/scripts/build-core-xcframework.sh"
xcodegen generate --spec "$ROOT/apple/project.yml" --project "$ROOT/apple"
mkdir -p "$ROOT/apple/build/logs"
check_space
xcodebuild -jobs 1 -project "$ROOT/apple/HomeGardenStudio.xcodeproj" -scheme HomeGardenStudio \
  -destination 'platform=macOS' -derivedDataPath "$ROOT/apple/build/DerivedData" \
  'OTHER_SWIFT_FLAGS=-driver-batch-count 1' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS= \
  build test 2>&1 | tee "$ROOT/apple/build/logs/macos-build-test.log"
check_space
xcodebuild -jobs 1 -project "$ROOT/apple/HomeGardenStudio.xcodeproj" -scheme HomeGardenStudio \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$ROOT/apple/build/DerivedData" \
  'OTHER_SWIFT_FLAGS=-driver-batch-count 1' CODE_SIGNING_ALLOWED=NO build 2>&1 | tee "$ROOT/apple/build/logs/ios-simulator-build.log"
echo "Verified: macOS build and unit tests; iOS Simulator build. Runtime and distribution gates are separate."
