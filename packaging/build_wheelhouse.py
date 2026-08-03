#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path

from manifest import HERMES_SOURCE, PYTHON_VERSION, write_manifest

DEFAULT_HERMES_EXTRAS = "all"
PYTHON_DOWNLOAD_VERSION = "".join(PYTHON_VERSION.split(".")[:2])

OFFLINE_RUNTIME_REQUIREMENTS = [
    # Required by the api_server platform enabled in templates/config.yaml.
    "aiohttp==3.14.1",
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
    "setuptools",
    "uvicorn",
    "websockets",
    "wheel",
]

BUILD_REQUIREMENTS = [
    # Match the build backend range declared by current upstream Hermes.
    "setuptools>=77.0,<83",
    "wheel",
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
    "skills/cn-mirrors/SKILL.md",
    "skills/software-development/plan/SKILL.md",
    "optional-skills/productivity/memento-flashcards/SKILL.md",
    "optional-mcps/linear/manifest.yaml",
    "locales/en.yaml",
    "plugins/disk-cleanup/plugin.yaml",
    "tui_dist/dist/entry.js",
    "tui_dist/package.json",
]

HERMES_SOURCE_SENTINELS = [
    "pyproject.toml",
    "setup.py",
    "uv.lock",
    "hermes",
    "hermes_cli/main.py",
    "hermes_cli/web_dist/index.html",
    "hermes_cli/tui_dist/entry.js",
    "tools/skills_sync.py",
]

HERMES_SOURCE_IGNORES = [
    ".git",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    ".venv",
    "__pycache__",
    "*.egg-info",
    "node_modules",
    "venv",
]


@dataclass(frozen=True)
class HermesSource:
    spec: str
    source_dir: Path | None


ROOT = Path(__file__).resolve().parents[1]
LOCAL_BUNDLED_RESOURCES_DIR = ROOT / "bundled-resources"


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

    overlay_local_bundled_resources(resources_dir)
    validate_hermes_resources(resources_dir)


def overlay_local_bundled_resources(resources_dir: Path) -> None:
    if not LOCAL_BUNDLED_RESOURCES_DIR.is_dir():
        return

    for source in LOCAL_BUNDLED_RESOURCES_DIR.rglob("*"):
        if source.is_dir():
            continue
        relative_path = source.relative_to(LOCAL_BUNDLED_RESOURCES_DIR)
        destination = resources_dir / relative_path
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)


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


def export_hermes_source(source_dir: Path | None, output: Path) -> Path:
    if source_dir is None:
        raise SystemExit(
            "Cannot bundle Hermes source because HERMES_SOURCE did not resolve "
            "to a local source checkout. Use a git or file:// source."
        )

    bundled_source = output / "hermes-source"
    if bundled_source.exists():
        shutil.rmtree(bundled_source)
    shutil.copytree(
        source_dir,
        bundled_source,
        symlinks=True,
        ignore=shutil.ignore_patterns(*HERMES_SOURCE_IGNORES),
    )
    validate_hermes_source(bundled_source)
    return bundled_source


def validate_hermes_source(source_dir: Path) -> None:
    missing = [rel for rel in HERMES_SOURCE_SENTINELS if not (source_dir / rel).is_file()]
    if missing:
        raise SystemExit(
            "Hermes source snapshot is incomplete. Missing: " + ", ".join(sorted(missing))
        )
    generated_dirs = list(source_dir.rglob("node_modules")) + list(source_dir.rglob("__pycache__"))
    if generated_dirs:
        raise SystemExit(
            "Hermes source snapshot contains generated directories: "
            + ", ".join(str(path.relative_to(source_dir)) for path in generated_dirs[:10])
        )


def read_source_version(source_dir: Path) -> str:
    pyproject = source_dir / "pyproject.toml"
    try:
        with pyproject.open("rb") as handle:
            project = tomllib.load(handle).get("project", {})
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise SystemExit(f"Cannot read Hermes version from {pyproject}: {exc}") from exc
    version = str(project.get("version", "")).strip()
    if not version:
        raise SystemExit(f"Hermes source does not declare project.version: {pyproject}")
    return version


def parse_extras(value: str) -> list[str]:
    extras = [item.strip() for item in value.split(",") if item.strip()]
    invalid = [item for item in extras if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", item)]
    if invalid:
        raise SystemExit("Invalid Hermes extras: " + ", ".join(invalid))
    return extras


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


def git_commit(source_dir: Path | None) -> str | None:
    if source_dir is None or not (source_dir / ".git").exists():
        return None
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "HEAD"],
            cwd=source_dir,
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except subprocess.CalledProcessError:
        return None


def main() -> None:
    parser = argparse.ArgumentParser(description="构建 Hermes Agent 离线 wheelhouse")
    parser.add_argument("--platform", required=True, help="目标平台，例如 mac-arm64、linux-x64、win-x64")
    parser.add_argument("--output", required=True, type=Path, help="wheelhouse 输出目录")
    parser.add_argument("--extras", default=DEFAULT_HERMES_EXTRAS, help="Hermes extras，例如 all,web,telegram；默认 all")
    args = parser.parse_args()

    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)

    extras = parse_extras(args.extras)
    extras_csv = ",".join(extras)
    hermes_spec = HERMES_SOURCE
    if " @ " in HERMES_SOURCE:
        hermes_name = HERMES_SOURCE.split(" @ ", 1)[0].split("[", 1)[0]
    else:
        hermes_name = "hermes-agent"
    if extras_csv:
        if " @ " in HERMES_SOURCE:
            name, source = HERMES_SOURCE.split(" @ ", 1)
            hermes_spec = f"{name}[{extras_csv}] @ {source}"
        else:
            hermes_spec = f"hermes-agent[{extras_csv}]"
        hermes_install_spec = f"{hermes_name}[{extras_csv}]"
        hermes_editable_requirement = f".[{extras_csv}]"
    else:
        hermes_install_spec = hermes_name
        hermes_editable_requirement = "."

    work_dir = output.parent / "wheelhouse-build"
    if work_dir.exists():
        shutil.rmtree(work_dir)
    work_dir.mkdir(parents=True, exist_ok=True)
    hermes_source = prepare_hermes_source(hermes_spec, work_dir)
    export_hermes_resources(hermes_source.source_dir, output)

    requirements = output / "requirements.txt"
    install_requirement_lines = [*BUILD_REQUIREMENTS, "croniter", *OFFLINE_RUNTIME_REQUIREMENTS]
    download_requirements = work_dir / "requirements-download.txt"
    download_requirement_lines = [hermes_spec, *BUILD_REQUIREMENTS, "croniter", *OFFLINE_RUNTIME_REQUIREMENTS]
    download_requirements.write_text("\n".join(download_requirement_lines) + "\n", encoding="utf-8")

    env = os.environ.copy()
    env["GIT_TERMINAL_PROMPT"] = "0"

    run([
        sys.executable,
        "-m",
        "pip",
        "download",
        "--python-version",
        PYTHON_DOWNLOAD_VERSION,
        "--only-binary=:all:",
        "--dest",
        str(output),
        "-r",
        str(download_requirements),
    ], env=env)
    remove_distribution_artifacts(output, "hermes-agent")
    requirements.write_text("\n".join(install_requirement_lines) + "\n", encoding="utf-8")
    (output / "hermes-editable-requirement.txt").write_text(
        hermes_editable_requirement + "\n",
        encoding="utf-8",
    )
    validate_required_wheels(output, OFFLINE_REQUIRED_WHEELS)
    bundled_source = export_hermes_source(hermes_source.source_dir, output)
    hermes_version = read_source_version(bundled_source)

    write_manifest(
        output / "manifest.json",
        target_platform=args.platform,
        extra={
            "kind": "wheelhouse",
            "hermes_version": hermes_version,
            "hermes_install_spec": hermes_install_spec,
            "hermes_install_mode": "editable-source",
            "hermes_editable_requirement": hermes_editable_requirement,
            "hermes_source_directory": "hermes-source",
            "hermes_resolved_spec": hermes_source.spec,
            "hermes_source_commit": git_commit(hermes_source.source_dir),
            "extras": extras,
        },
    )


if __name__ == "__main__":
    main()
