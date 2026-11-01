#!/usr/bin/env bash
# Explicit scopes distinguish partial worktree checks from full verification.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
scope="${1:-full}"
if [ "$#" -gt 1 ]; then
  echo "Usage: scripts/verify.sh [full|privacy|core|gateway|apple]" >&2
  exit 2
fi
case "$scope" in
  full) checks=(privacy core gateway apple) ;;
  privacy|core|gateway|apple) checks=("$scope") ;;
  *) echo "Unknown verification scope: $scope" >&2; exit 2 ;;
esac
echo "Verification scope: $scope"
missing=0
for check in "${checks[@]}"; do
  case "$check" in
    privacy) required=(scripts/privacy-scan.sh scripts/privacy_scan.py scripts/tests/test_publication.py) ;;
    core) required=(core/Cargo.toml core/hgs-core/src/lib.rs core/hgs-ffi/src/lib.rs) ;;
    gateway) required=(gateway/package.json gateway/src/index.ts) ;;
    apple) required=(apple/project.yml scripts/apple-verify.sh scripts/build-core-xcframework.sh scripts/check-build-space.sh) ;;
  esac
  for path in "${required[@]}"; do
    if [ ! -f "$ROOT/$path" ]; then
      echo "Missing required $check component: $path" >&2
      missing=1
    fi
  done
done
if [ "$missing" -ne 0 ]; then
  echo "Verification failed before checks: required components are missing." >&2
  exit 1
fi
for check in "${checks[@]}"; do
  echo "Running $check checks"
  case "$check" in
    privacy)
      bash "$ROOT/scripts/privacy-scan.sh"
      python3 -m unittest discover -s "$ROOT/scripts/tests" -p 'test_*.py'
      ;;
    core)
      (cd "$ROOT/core" && CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-1}" cargo fmt --all -- --check &&
        CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-1}" cargo clippy --workspace --all-targets --quiet -- -D warnings &&
        CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-1}" cargo test --workspace --quiet)
      ;;
    gateway) (cd "$ROOT/gateway" && npm run --silent typecheck && npm test --silent) ;;
    apple) bash "$ROOT/scripts/apple-verify.sh" ;;
  esac
done
echo "Passed verification scope: $scope"
