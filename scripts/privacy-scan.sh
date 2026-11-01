#!/usr/bin/env bash
# Check the index and working files without echoing matched secrets.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$ROOT/scripts/privacy_scan.py" --root "$ROOT" "$@"
