#!/usr/bin/env bash
# install.sh — symlink bin/bishop into $PREFIX (default: ~/.local/bin)
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local/bin}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BISHOP_BIN="${REPO_ROOT}/bin/bishop"
TARGET="${PREFIX}/bishop"

FETCH_BIN="${REPO_ROOT}/bin/bishop-fetch-usage"
FETCH_TARGET="${PREFIX}/bishop-fetch-usage"

mkdir -p "$PREFIX"
ln -sf "$BISHOP_BIN" "$TARGET"
echo "Installed bishop -> $TARGET"
ln -sf "$FETCH_BIN" "$FETCH_TARGET"
echo "Installed bishop-fetch-usage -> $FETCH_TARGET"
