#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

from manifest import HERMES_SOURCE, PYTHON_VERSION, write_manifest


def run(cmd: list[str], *, env: dict[str, str] | None = None) -> None:
    print("+", " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True, env=env)


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
    requirements.write_text(f"{hermes_spec}\ncroniter\n", encoding="utf-8")

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

    write_manifest(
        output / "manifest.json",
        target_platform=args.platform,
        extra={"kind": "wheelhouse", "extras": args.extras.split(",") if args.extras else []},
    )


if __name__ == "__main__":
    main()
