#!/usr/bin/env python3
"""Verify that every vendored SwiftPM dependency is credited and licensed."""

from __future__ import annotations

import re
import sys
from collections import deque
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VENDOR = (ROOT / "Vendor").resolve()
README = ROOT / "README.md"
NOTICES = ROOT / "THIRD_PARTY_NOTICES.md"
PACKAGE_PATTERN = re.compile(r'\.package\s*\(\s*path:\s*"([^"]+)"\s*\)')


def local_dependencies(package_directory: Path) -> list[Path]:
    manifest = package_directory / "Package.swift"
    if not manifest.is_file():
        raise RuntimeError(f"missing Package.swift: {manifest}")

    text = manifest.read_text(encoding="utf-8")
    return [(package_directory / path).resolve() for path in PACKAGE_PATTERN.findall(text)]


def reachable_vendor_packages() -> set[Path]:
    pending: deque[Path] = deque([ROOT.resolve()])
    visited: set[Path] = set()
    vendored: set[Path] = set()

    while pending:
        package = pending.popleft()
        if package in visited:
            continue
        visited.add(package)

        for dependency in local_dependencies(package):
            try:
                dependency.relative_to(VENDOR)
            except ValueError as error:
                raise RuntimeError(
                    f"local dependency escapes Vendor/: {package} -> {dependency}"
                ) from error

            if not (dependency / "Package.swift").is_file():
                raise RuntimeError(f"vendored dependency is incomplete: {dependency}")

            vendored.add(dependency)
            pending.append(dependency)

    return vendored


def main() -> int:
    try:
        reachable = reachable_vendor_packages()
    except RuntimeError as error:
        print(f"third-party credit audit failed: {error}", file=sys.stderr)
        return 1

    shipped = {
        directory.resolve()
        for directory in (ROOT / "Vendor").iterdir()
        if directory.is_dir() and (directory / "Package.swift").is_file()
    }

    errors: list[str] = []
    orphaned = sorted(shipped - reachable)
    if orphaned:
        for package in orphaned:
            errors.append(
                f"shipped vendored package is unreachable from Package.swift: "
                f"{package.relative_to(ROOT).as_posix()}"
            )

    readme = README.read_text(encoding="utf-8")
    notices = NOTICES.read_text(encoding="utf-8")

    if "## Third-party packages and credits" not in readme:
        errors.append("README.md is missing the third-party credit section")

    for package in sorted(reachable):
        relative = package.relative_to(ROOT).as_posix()
        license_file = package / "LICENSE"

        if f"`{relative}`" not in readme:
            errors.append(f"README.md does not credit {relative}")
        if not license_file.is_file():
            errors.append(f"missing license file: {license_file.relative_to(ROOT)}")
        if f"`{relative}/LICENSE`" not in notices:
            errors.append(f"THIRD_PARTY_NOTICES.md does not list {relative}/LICENSE")

    if errors:
        print("third-party credit audit failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print(
        f"third-party credit audit passed: "
        f"{len(reachable)} reachable vendored packages credited and licensed"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
