#!/usr/bin/env bash
# Shared-host policy when installed; a read-only space guard on other Macs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLEANER="$HOME/ashcode/diskcleaner/bin/diskcleaner"
if [[ -x "$CLEANER" ]]; then
  code=0
  DISKCLEANER_TUI=0 "$CLEANER" check || code=$?
  if [[ "$code" == 0 || "$code" == 10 ]]; then exit 0; fi
  echo "Native build stopped: diskcleaner check returned $code." >&2
  exit "$code"
fi
available_kib="$(df -Pk "$ROOT" | awk 'END {print $4}')"
if [[ ! "$available_kib" =~ ^[0-9]+$ ]]; then
  echo "Cannot determine available build space." >&2
  exit 1
fi
if (( available_kib < 10485760 )); then
  echo "Native build needs at least 10 GiB of available disk space." >&2
  exit 1
fi
