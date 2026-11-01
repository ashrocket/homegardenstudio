#!/usr/bin/env bash
# Repository checks. Runs each component's tests when that component exists.
# Native Xcode builds are separate (scripts/apple-verify.sh) because they are heavy.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
status=0
if [ -f "$ROOT/core/Cargo.toml" ]; then
  echo "== core: cargo fmt --check, clippy, test"
  (cd "$ROOT/core" && cargo fmt --all -- --check && cargo clippy --workspace --all-targets --quiet -- -D warnings && cargo test --workspace --quiet) || status=1
fi
if [ -f "$ROOT/gateway/package.json" ]; then
  echo "== gateway: typecheck, test"
  (cd "$ROOT/gateway" && npm run --silent typecheck && npm test --silent) || status=1
fi
if [ -x "$ROOT/scripts/privacy-scan.sh" ]; then
  echo "== privacy scan"
  "$ROOT/scripts/privacy-scan.sh" || status=1
fi
exit $status
