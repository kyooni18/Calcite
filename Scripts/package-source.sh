#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_PATH="${1:-${PROJECT_ROOT}/../Calcite-source.tar.gz}"
OUTPUT_DIR="$(dirname "${OUTPUT_PATH}")"
OUTPUT_NAME="$(basename "${OUTPUT_PATH}")"

mkdir -p "${OUTPUT_DIR}"
rm -f "${OUTPUT_PATH}"

# Prevent macOS from writing AppleDouble entries and extended-attribute sidecars.
export COPYFILE_DISABLE=1
export COPY_EXTENDED_ATTRIBUTES_DISABLE=1

cd "$(dirname "${PROJECT_ROOT}")"
tar \
  --exclude='._*' \
  --exclude='.DS_Store' \
  --exclude='.AppleDouble' \
  --exclude='.build' \
  --exclude='.swiftpm' \
  --exclude='DerivedData' \
  --exclude='xcuserdata' \
  -czf "${OUTPUT_PATH}" \
  "$(basename "${PROJECT_ROOT}")"

printf 'Created %s\n' "${OUTPUT_PATH}"
