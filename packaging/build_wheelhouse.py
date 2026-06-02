#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import subprocess
import sys
import shutil
import zipfile
from pathlib import Path

from manifest import HERMES_SOURCE, PYTHON_VERSION, write_manifest

OFFLINE_RUNTIME_REQUIREMENTS = [
    # Required by the api_server platform enabled in templates/config.yaml.
    "aiohttp==3.13.3",
    # Required by `hermes dashboard`.
    "fastapi==0.133.1",
    # Required by FastAPI routes that accept form data.
    "python-multipart",
    "uvicorn==0.41.0",
    # Required by dashboard/API websocket endpoints and tools.browser_dialog_tool.
    "websockets",
]

OFFLINE_REQUIRED_WHEELS = [
    "aiohttp",
    "fastapi",
    "python_multipart",
    "uvicorn",
    "websockets",
]


def run(cmd: list[str], *, cwd: Path | None = None, env: dict[str, str] | None = None) -> None:
    print("+", " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True, cwd=cwd, env=env)


def parse_git_source(source: str) -> tuple[str, str | None] | None:
    if not source.startswith("git+"):
        return None
    git_url = source.removeprefix("git+").split("#", 1)[0]
    marker = ".git@"
    if marker in git_url:
        base, ref = git_url.split(marker, 1)
        return base + ".git", ref or None
    return git_url, None


def prepare_hermes_source(hermes_spec: str, work_dir: Path) -> str:
    if " @ " not in hermes_spec:
        return hermes_spec

    name, source = hermes_spec.split(" @ ", 1)
    parsed = parse_git_source(source)
    if parsed is None:
        return hermes_spec

    url, ref = parsed
    source_dir = work_dir / "hermes-agent-src"
    if source_dir.exists():
        shutil.rmtree(source_dir)

    clone_cmd = ["git", "clone", "--depth", "1"]
    if ref:
        clone_cmd.extend(["--branch", ref])
    clone_cmd.extend([url, str(source_dir)])
    try:
        run(clone_cmd)
    except subprocess.CalledProcessError:
        if not ref:
            raise
        run(["git", "clone", url, str(source_dir)])
        run(["git", "checkout", ref], cwd=source_dir)

    web_dir = source_dir / "web"
    if not web_dir.is_dir():
        raise SystemExit(f"Hermes source has no web directory: {web_dir}")
    npm = shutil.which("npm")
    if not npm:
        raise SystemExit("npm not found. Install Node.js before building the dashboard frontend.")
    npm_env = os.environ | {"npm_config_audit": "false", "npm_config_fund": "false"}
    run([npm, "ci"], cwd=web_dir, env=npm_env)
    run([npm, "run", "build"], cwd=web_dir, env=os.environ.copy())
    dist_index = source_dir / "hermes_cli" / "web_dist" / "index.html"
    if not dist_index.exists():
        raise SystemExit(f"Dashboard frontend build did not create {dist_index}")

    return f"{name} @ {source_dir.as_uri()}"


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


def remove_distribution_artifacts(output: Path, distribution: str) -> None:
    prefixes = {
        distribution.replace("_", "-").lower(),
        distribution.replace("-", "_").lower(),
    }
    for artifact in output.iterdir():
        if not artifact.is_file():
            continue
        name = artifact.name.lower()
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


def validate_hermes_wheel_has_dashboard(output: Path) -> None:
    wheels = sorted(output.glob("hermes_agent-*.whl")) + sorted(output.glob("hermes-agent-*.whl"))
    if not wheels:
        raise SystemExit("Missing hermes-agent wheel")
    wheel = wheels[-1]
    with zipfile.ZipFile(wheel) as zf:
        names = set(zf.namelist())
    if "hermes_cli/web_dist/index.html" not in names:
        raise SystemExit(
            f"{wheel.name} does not include hermes_cli/web_dist/index.html. "
            "Build the dashboard frontend before building the wheel."
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

    work_dir = output.parent / "wheelhouse-build"
    if work_dir.exists():
        shutil.rmtree(work_dir)
    work_dir.mkdir(parents=True, exist_ok=True)
    wheel_hermes_spec = prepare_hermes_source(hermes_spec, work_dir)

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
    remove_distribution_artifacts(output, "hermes-agent")
    run([
        sys.executable,
        "-m",
        "pip",
        "wheel",
        "--wheel-dir",
        str(output),
        "--no-deps",
        wheel_hermes_spec,
    ], env=env)
    remove_source_archives(output, "hermes-agent")
    validate_required_wheels(output, OFFLINE_REQUIRED_WHEELS)
    validate_hermes_wheel_has_dashboard(output)

    write_manifest(
        output / "manifest.json",
        target_platform=args.platform,
        extra={"kind": "wheelhouse", "extras": args.extras.split(",") if args.extras else []},
    )


if __name__ == "__main__":
    main()
