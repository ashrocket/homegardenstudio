#!/usr/bin/env bash
# Explicitly select upload-only or verified internal distribution.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec python3 "$ROOT/scripts/release/testflight.py" "$@"
