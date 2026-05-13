#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
from pathlib import Path


def normalize_distribution_name(name: str) -> str:
    return re.sub(r"[-_.]+", "_", name).lower()


def wheel_version(wheel: Path, distribution: str) -> str | None:
    suffix = ".whl"
    if wheel.suffix != suffix:
        return None
    stem = wheel.name[: -len(suffix)]
    parts = stem.split("-")
    if len(parts) < 5:
        return None
    if normalize_distribution_name(parts[0]) != normalize_distribution_name(distribution):
        return None
    return parts[1]


def main() -> None:
    parser = argparse.ArgumentParser(description="Read a package version from a wheelhouse")
    parser.add_argument("--wheelhouse", required=True, type=Path)
    parser.add_argument("--distribution", default="hermes-agent")
    args = parser.parse_args()

    versions = sorted(
        {
            version
            for wheel in args.wheelhouse.glob("*.whl")
            if (version := wheel_version(wheel, args.distribution))
        }
    )
    if not versions:
        raise SystemExit(f"No wheel found for distribution: {args.distribution}")
    if len(versions) > 1:
        raise SystemExit(f"Multiple versions found for {args.distribution}: {', '.join(versions)}")
    print(versions[0])


if __name__ == "__main__":
    main()
