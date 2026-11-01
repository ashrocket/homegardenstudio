#!/usr/bin/env bash
# Fails if tracked or staged files contain credentials or private-data patterns.
# Generic patterns live here. Owner-specific patterns (never published) are read
# from .coordination/private-patterns.txt when present (Git-ignored).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
files=$(git ls-files -c -o --exclude-standard | grep -vE '^(scripts/privacy-scan\.sh)$' || true)
[ -z "$files" ] && exit 0
generic=(
  'sk-ant-[A-Za-z0-9_-]{20,}'
  'sk-(proj-)?[A-Za-z0-9]{32,}'
  'hgs_[A-Za-z0-9_-]{40,}'
  'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY'
  'AuthKey_[A-Z0-9]{10}\.p8'
  'r2\.cloudflarestorage\.com'
  'gho_[A-Za-z0-9]{20,}'
  'xox[bap]-[A-Za-z0-9-]{10,}'
  '-?[0-9]{2}\.[0-9]{5,}, ?-?[0-9]{2,3}\.[0-9]{5,}'
)
status=0
for p in "${generic[@]}"; do
  if hits=$(echo "$files" | xargs grep -nIEo -- "$p" 2>/dev/null); then
    echo "privacy-scan: generic pattern matched:"; echo "$hits" | cut -c1-160; status=1
  fi
done
if [ -f .coordination/private-patterns.txt ]; then
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    case "$p" in \#*) continue;; esac
    if echo "$files" | xargs grep -nIiE -- "$p" >/dev/null 2>&1; then
      echo "privacy-scan: a private pattern matched in:"; echo "$files" | xargs grep -lIiE -- "$p" 2>/dev/null; status=1
    fi
  done < .coordination/private-patterns.txt
fi
[ $status -eq 0 ] && echo "privacy-scan: clean ($(echo "$files" | wc -l | tr -d ' ') files)"
exit $status
