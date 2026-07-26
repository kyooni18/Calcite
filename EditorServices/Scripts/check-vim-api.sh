#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINE="$ROOT/API/EditorVim.api.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cd "$ROOT"
swift build --target EditorVim >/dev/null
MODULE_DIR="$(find .build -type d -path '*/debug/Modules' -print -quit)"
if [[ -z "$MODULE_DIR" ]]; then
  echo "Unable to locate the EditorVim module directory." >&2
  exit 1
fi

swift-api-digester \
  -dump-sdk \
  -module EditorVim \
  -I "$MODULE_DIR" \
  -o "$TMP_DIR/EditorVim.api.json"

swift-api-digester \
  -diagnose-sdk \
  --input-paths "$BASELINE" \
  -input-paths "$TMP_DIR/EditorVim.api.json"
