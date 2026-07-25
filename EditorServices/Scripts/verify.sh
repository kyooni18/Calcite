#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOBS="${JOBS:-4}"
cd "$ROOT"

echo "== Third-party credit audit =="
python3 Scripts/check-third-party-credits.py

echo "== Root strict debug tests =="
swift test --jobs "$JOBS" -Xswiftc -warnings-as-errors

echo "== Root strict release build =="
swift build -c release --jobs "$JOBS" -Xswiftc -warnings-as-errors

echo "== Public symbol graph =="
swift package dump-symbol-graph --minimum-access-level public
python3 Scripts/check-public-api.py

if [[ "${FULL_VENDOR_TESTS:-0}" == "1" ]]; then
  test_packages=(
    Vendor/DebugAdapterProtocol
    Vendor/JSONRPC
    Vendor/LanguageClient
    Vendor/LanguageServerProtocol
    Vendor/ProcessEnv
    Vendor/Queue
    Vendor/Semaphore
    Vendor/swift-glob
    Vendor/swift-tree-sitter
  )

  for package in "${test_packages[@]}"; do
    echo "== Strict tests: $package =="
    (cd "$package" && swift test --jobs "$JOBS" -Xswiftc -warnings-as-errors)
  done

  build_packages=(
    Vendor/TreeSitter
    Vendor/TreeSitterSwift
  )

  for package in "${build_packages[@]}"; do
    echo "== Strict build (no test target): $package =="
    (cd "$package" && swift build --jobs "$JOBS" -Xswiftc -warnings-as-errors)
  done

  if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "== Strict tests: Vendor/FSEventsWrapper =="
    (cd Vendor/FSEventsWrapper && swift test --jobs "$JOBS" -Xswiftc -warnings-as-errors)
  else
    echo "== Skipping Vendor/FSEventsWrapper: requires macOS CoreServices =="
  fi
fi
