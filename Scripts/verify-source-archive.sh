#!/usr/bin/env bash
set -euo pipefail

ARCHIVE_INPUT="${1:?Usage: verify-source-archive.sh <archive.tar.gz>}"
ARCHIVE_DIR="$(cd "$(dirname "${ARCHIVE_INPUT}")" && pwd)"
ARCHIVE_PATH="${ARCHIVE_DIR}/$(basename "${ARCHIVE_INPUT}")"
TEMP_ROOT="$(mktemp -d "${ARCHIVE_DIR}/.calcite-verify.XXXXXX")"
trap 'rm -rf "${TEMP_ROOT}"' EXIT

tar -xzf "${ARCHIVE_PATH}" -C "${TEMP_ROOT}"
ROOT_COUNT="$(find "${TEMP_ROOT}" -mindepth 1 -maxdepth 1 -type d -print | wc -l | tr -d '[:space:]')"
if [[ "${ROOT_COUNT}" != "1" ]]; then
  echo 'Archive must contain exactly one project root.' >&2
  exit 1
fi
PROJECT_ROOT="$(find "${TEMP_ROOT}" -mindepth 1 -maxdepth 1 -type d -print -quit)"

if find "${PROJECT_ROOT}" \
  \( -name '._*' -o -name '.DS_Store' -o -name '.AppleDouble' \
     -o -name '.build' -o -name '.swiftpm' -o -name 'DerivedData' -o -name 'xcuserdata' \) \
  -print -quit | grep -q .; then
  echo 'Archive contains generated or macOS metadata files.' >&2
  exit 1
fi

find "${PROJECT_ROOT}/Calcite" "${PROJECT_ROOT}/CalciteTests" \
  -name '*.swift' -type f -print0 | xargs -0 swiftc -parse

(
  cd "${PROJECT_ROOT}/EditorServices"
  swift package dump-package >/dev/null
  swift test \
    --scratch-path "${TEMP_ROOT}/swift-build" \
    --jobs "${SWIFT_JOBS:-4}"
)

printf 'Archive verified: %s\n' "${ARCHIVE_PATH}"
