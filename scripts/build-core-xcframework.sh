#!/usr/bin/env bash
# One caller owns the native build slot. All generated output is worktree-local.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="${HGS_CORE_DIR:-$ROOT/core}"
OUT="$ROOT/apple/build/rust"
FRAMEWORKS="$ROOT/apple/Frameworks"
check_space() {
  bash "$ROOT/scripts/check-build-space.sh"
}
check_space
[[ -f "$CORE/hgs-ffi/include/hgs.h" ]] || { echo "Missing core C header." >&2; exit 1; }
mkdir -p "$OUT/headers" "$FRAMEWORKS"
cp "$CORE/hgs-ffi/include/hgs.h" "$OUT/headers/hgs.h"
cat > "$OUT/headers/module.modulemap" <<'MODULE'
module HgsCore {
  header "hgs.h"
  export *
}
MODULE
export CARGO_BUILD_JOBS=1
export CARGO_TARGET_DIR="$OUT/target"
for target in aarch64-apple-darwin x86_64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim; do
  check_space
  if ! rustup target list --installed | /usr/bin/grep -Fxq "$target"; then
    echo "Missing Rust target $target. Install explicitly before building." >&2
    exit 1
  fi
  cargo build --manifest-path "$CORE/Cargo.toml" --locked --release -p hgs-ffi --target "$target"
done
mkdir -p "$OUT/macos"
lipo -create "$OUT/target/aarch64-apple-darwin/release/libhgs_ffi.a" "$OUT/target/x86_64-apple-darwin/release/libhgs_ffi.a" -output "$OUT/macos/libhgs_ffi.a"
check_space
# xcodebuild requires a previously absent output directory; remove only our generated framework.
if [[ -d "$FRAMEWORKS/HgsCore.xcframework" ]]; then /bin/rm -rf "$FRAMEWORKS/HgsCore.xcframework"; fi
xcodebuild -create-xcframework \
  -library "$OUT/macos/libhgs_ffi.a" -headers "$OUT/headers" \
  -library "$OUT/target/aarch64-apple-ios/release/libhgs_ffi.a" -headers "$OUT/headers" \
  -library "$OUT/target/aarch64-apple-ios-sim/release/libhgs_ffi.a" -headers "$OUT/headers" \
  -output "$FRAMEWORKS/HgsCore.xcframework"
