#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output=${1:-"$project_root/Calcite-source.tar.gz"}
output_dir=$(dirname -- "$output")
output_name=$(basename -- "$output")
mkdir -p "$output_dir"

# Archive from the parent so the extracted source keeps one stable Calcite/ root.
tar \
  --exclude='./Calcite/.git' \
  --exclude='*/.DS_Store' \
  --exclude='*/._*' \
  --exclude='*/.AppleDouble' \
  --exclude='*/DerivedData' \
  --exclude='*/.build' \
  --exclude='*/.swiftpm' \
  --exclude='*/xcode-build' \
  --exclude='*/.build-xcode' \
  --exclude='*/xcuserdata' \
  --exclude="./Calcite/$output_name" \
  -czf "$output" \
  -C "$(dirname -- "$project_root")" \
  ./Calcite

printf 'Created %s\n' "$output"
