#!/usr/bin/env bash
# doctor.sh — verify bishop's runtime dependencies
set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
RESET='\033[0m'

ok()       { printf "${GREEN}✔${RESET}  %s\n" "$1"; }
missing()  { printf "${RED}✘${RESET}  %s — required, please install\n" "$1"; }
advisory() { printf "${YELLOW}!${RESET}  %s — optional (needed to run tests)\n" "$1"; }

any_required_missing=0

# Required dependencies
for dep in jq flock; do
  if command -v "$dep" >/dev/null 2>&1; then
    ok "$dep ($(command -v "$dep"))"
  else
    missing "$dep"
    any_required_missing=1
  fi
done

# Advisory dependencies
for dep in bats; do
  if command -v "$dep" >/dev/null 2>&1; then
    ok "$dep ($(command -v "$dep"))"
  else
    advisory "$dep"
  fi
done

if [[ "$any_required_missing" -ne 0 ]]; then
  echo ""
  echo "Some required dependencies are missing."
  echo "On macOS, install with: brew install jq flock"
  exit 1
fi

echo ""
echo "All required dependencies present."
exit 0
