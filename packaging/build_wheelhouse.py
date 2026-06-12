#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import subprocess
import sys
import shutil
import zipfile
from dataclasses import dataclass
from pathlib import Path

from manifest import HERMES_SOURCE, PYTHON_VERSION, write_manifest

DEFAULT_HERMES_EXTRAS = "all"

OFFLINE_RUNTIME_REQUIREMENTS = [
    # Required by the api_server platform enabled in templates/config.yaml.
    "aiohttp==3.13.4",
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

HERMES_RESOURCE_DIRS = [
    "skills",
    "optional-skills",
    "optional-mcps",
    "locales",
    "plugins",
]

HERMES_RESOURCE_SENTINELS = [
    "skills/apple/imessage/SKILL.md",
    "skills/autonomous-ai-agents/codex/SKILL.md",
    "skills/software-development/plan/SKILL.md",
    "optional-skills/productivity/memento-flashcards/SKILL.md",
    "optional-mcps/linear/manifest.yaml",
    "locales/en.yaml",
    "plugins/disk-cleanup/plugin.yaml",
    "tui_dist/dist/entry.js",
    "tui_dist/package.json",
]


@dataclass(frozen=True)
class HermesSource:
    spec: str
    source_dir: Path | None


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


def prepare_hermes_source(hermes_spec: str, work_dir: Path) -> HermesSource:
    if " @ " not in hermes_spec:
        return HermesSource(spec=hermes_spec, source_dir=None)

    name, source = hermes_spec.split(" @ ", 1)
    parsed = parse_git_source(source)
    if parsed is None:
        if source.startswith("file://"):
            return HermesSource(spec=hermes_spec, source_dir=Path(source.removeprefix("file://")))
        return HermesSource(spec=hermes_spec, source_dir=None)

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

    run([npm, "ci", "--workspace", "ui-tui"], cwd=source_dir, env=npm_env)
    run([npm, "run", "build", "--workspace", "ui-tui"], cwd=source_dir, env=os.environ.copy())
    tui_entry = source_dir / "ui-tui" / "dist" / "entry.js"
    if not tui_entry.exists():
        raise SystemExit(f"TUI frontend build did not create {tui_entry}")
    hermes_cli_tui_dist = source_dir / "hermes_cli" / "tui_dist"
    hermes_cli_tui_dist.mkdir(parents=True, exist_ok=True)
    shutil.copy2(tui_entry, hermes_cli_tui_dist / "entry.js")

    return HermesSource(spec=f"{name} @ {source_dir.as_uri()}", source_dir=source_dir)


def export_hermes_resources(source_dir: Path | None, output: Path) -> None:
    resources_dir = output / "hermes-resources"
    if resources_dir.exists():
        shutil.rmtree(resources_dir)
    resources_dir.mkdir(parents=True)

    if source_dir is None:
        raise SystemExit(
            "Cannot export Hermes runtime resources because HERMES_SOURCE did not resolve "
            "to a local source checkout. Use the default git source or a file:// source."
        )

    for name in HERMES_RESOURCE_DIRS:
        src = source_dir / name
        if not src.is_dir():
            raise SystemExit(f"Hermes source is missing required resource directory: {src}")
        shutil.copytree(src, resources_dir / name)

    web_dist = source_dir / "hermes_cli" / "web_dist"
    if not (web_dist / "index.html").is_file():
        raise SystemExit(f"Hermes dashboard web_dist is missing: {web_dist}")
    shutil.copytree(web_dist, resources_dir / "web_dist")

    tui_entry = source_dir / "ui-tui" / "dist" / "entry.js"
    if not tui_entry.is_file():
        raise SystemExit(f"Hermes TUI dist is missing: {tui_entry}")
    tui_resource_dir = resources_dir / "tui_dist"
    (tui_resource_dir / "dist").mkdir(parents=True)
    shutil.copy2(tui_entry, tui_resource_dir / "dist" / "entry.js")
    shutil.copy2(source_dir / "ui-tui" / "package.json", tui_resource_dir / "package.json")

    validate_hermes_resources(resources_dir)


def validate_hermes_resources(resources_dir: Path) -> None:
    missing = [rel for rel in HERMES_RESOURCE_SENTINELS if not (resources_dir / rel).is_file()]
    if missing:
        raise SystemExit(
            "Hermes resources export is incomplete. Missing: " + ", ".join(sorted(missing))
        )

    skill_count = sum(1 for _ in (resources_dir / "skills").rglob("SKILL.md"))
    optional_skill_count = sum(1 for _ in (resources_dir / "optional-skills").rglob("SKILL.md"))
    optional_mcp_count = sum(1 for _ in (resources_dir / "optional-mcps").rglob("manifest.yaml"))
    plugin_count = sum(1 for _ in (resources_dir / "plugins").rglob("plugin.yaml"))
    locale_count = len(list((resources_dir / "locales").glob("*.yaml")))
    if skill_count < 20 or optional_skill_count < 1 or optional_mcp_count < 1 or plugin_count < 1 or locale_count < 1:
        raise SystemExit(
            "Hermes resources export has suspicious counts: "
            f"skills={skill_count}, optional_skills={optional_skill_count}, "
            f"optional_mcps={optional_mcp_count}, plugins={plugin_count}, locales={locale_count}"
        )

    print(
        "Hermes resources exported: "
        f"skills={skill_count}, optional_skills={optional_skill_count}, "
        f"optional_mcps={optional_mcp_count}, plugins={plugin_count}, locales={locale_count}",
        flush=True,
    )


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
    if "hermes_cli/tui_dist/entry.js" not in names:
        raise SystemExit(
            f"{wheel.name} does not include hermes_cli/tui_dist/entry.js. "
            "Build the TUI frontend before building the wheel."
        )


def main() -> None:
    parser = argparse.ArgumentParser(description="构建 Hermes Agent 离线 wheelhouse")
    parser.add_argument("--platform", required=True, help="目标平台，例如 mac-arm64、linux-x64、win-x64")
    parser.add_argument("--output", required=True, type=Path, help="wheelhouse 输出目录")
    parser.add_argument("--extras", default=DEFAULT_HERMES_EXTRAS, help="Hermes extras，例如 all,web,telegram；默认 all")
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
    hermes_source = prepare_hermes_source(hermes_spec, work_dir)
    export_hermes_resources(hermes_source.source_dir, output)

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
        hermes_source.spec,
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
