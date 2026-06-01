#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

from manifest import HERMES_SOURCE, PYTHON_VERSION, write_manifest

OFFLINE_RUNTIME_REQUIREMENTS = [
    # Required by the api_server platform enabled in templates/config.yaml.
    "aiohttp==3.13.3",
    # Required by `hermes dashboard`.
    "fastapi==0.133.1",
    "uvicorn==0.41.0",
    # Required by dashboard/API websocket endpoints and tools.browser_dialog_tool.
    "websockets",
]

OFFLINE_REQUIRED_WHEELS = [
    "aiohttp",
    "fastapi",
    "uvicorn",
    "websockets",
]


def run(cmd: list[str], *, env: dict[str, str] | None = None) -> None:
    print("+", " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True, env=env)


def remove_source_archives(output: Path, distribution: str) -> None:
    prefixes = {
        distribution.replace("_", "-").lower(),
        distribution.replace("-", "_").lower(),
    }
    for artifact in output.iterdir():
        name = artifact.name.lower()
        if not (name.endswith(".zip") or name.endswith(".tar.gz")):
            continue
        if any(name.startswith(f"{prefix}-") for prefix in prefixes):
            artifact.unlink()


def validate_required_wheels(output: Path, distributions: list[str]) -> None:
    missing = []
    for distribution in distributions:
        prefixes = {
            distribution.replace("_", "-").lower(),
            distribution.replace("-", "_").lower(),
        }
        found = any(
            artifact.suffix == ".whl"
            and any(artifact.name.lower().startswith(f"{prefix}-") for prefix in prefixes)
            for artifact in output.iterdir()
        )
        if not found:
            missing.append(distribution)
    if missing:
        raise SystemExit(
            "Missing required wheelhouse artifacts: " + ", ".join(sorted(missing))
        )


def main() -> None:
    parser = argparse.ArgumentParser(description="构建 Hermes Agent 离线 wheelhouse")
    parser.add_argument("--platform", required=True, help="目标平台，例如 mac-arm64、linux-x64、win-x64")
    parser.add_argument("--output", required=True, type=Path, help="wheelhouse 输出目录")
    parser.add_argument("--extras", default="", help="Hermes extras，例如 web,telegram")
    args = parser.parse_args()

    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)

    hermes_spec = HERMES_SOURCE
    if args.extras:
        if " @ " in HERMES_SOURCE:
            name, source = HERMES_SOURCE.split(" @ ", 1)
            hermes_spec = f"{name}[{args.extras}] @ {source}"
        else:
            hermes_spec = f"hermes-agent[{args.extras}]"

    requirements = output / "requirements.txt"
    requirement_lines = [hermes_spec, "croniter", "setuptools>=61.0", *OFFLINE_RUNTIME_REQUIREMENTS]
    requirements.write_text("\n".join(requirement_lines) + "\n", encoding="utf-8")

    env = os.environ.copy()
    env["GIT_TERMINAL_PROMPT"] = "0"

    run([
        sys.executable,
        "-m",
        "pip",
        "download",
        "--python-version",
        PYTHON_VERSION.replace(".", ""),
        "--only-binary=:all:",
        "--dest",
        str(output),
        "-r",
        str(requirements),
    ], env=env)
    run([
        sys.executable,
        "-m",
        "pip",
        "wheel",
        "--wheel-dir",
        str(output),
        "--no-deps",
        hermes_spec,
    ], env=env)
    remove_source_archives(output, "hermes-agent")
    validate_required_wheels(output, OFFLINE_REQUIRED_WHEELS)

    write_manifest(
        output / "manifest.json",
        target_platform=args.platform,
        extra={"kind": "wheelhouse", "extras": args.extras.split(",") if args.extras else []},
    )


if __name__ == "__main__":
    main()
