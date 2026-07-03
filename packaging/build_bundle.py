#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shutil
import stat
import subprocess
import sys
import tarfile
import urllib.request
import zipfile
from pathlib import Path

from manifest import PYTHON_VERSION, UV_VERSION, WINDOWS_PYTHON_VERSION, write_manifest

ROOT = Path(__file__).resolve().parents[1]
PYTHON_STDLIB_ZIP = f"python{''.join(PYTHON_VERSION.split('.')[:2])}.zip"

UV_TARGETS = {
    "mac-arm64": "aarch64-apple-darwin",
    "mac-x64": "x86_64-apple-darwin",
    "linux-x64": "x86_64-unknown-linux-gnu",
    "win-x64": "x86_64-pc-windows-msvc",
}

HERMES_RESOURCE_SENTINELS = [
    "skills/apple/imessage/SKILL.md",
    "skills/autonomous-ai-agents/codex/SKILL.md",
    "optional-skills/productivity/memento-flashcards/SKILL.md",
    "optional-mcps/linear/manifest.yaml",
    "locales/en.yaml",
    "plugins/disk-cleanup/plugin.yaml",
    "web_dist/index.html",
    "tui_dist/dist/entry.js",
    "tui_dist/package.json",
]

PYTHON_RUNTIME_IMPORT_CHECK = "import ctypes, encodings, ensurepip, venv"

WINDOWS_PYTHON_RUNTIME_SMOKE = r"""
import ctypes
import encodings
import ensurepip
import os
import subprocess
import sys
import tempfile
import venv
from pathlib import Path

print(f"Python executable: {sys.executable}")
print(f"ctypes module: {ctypes.__file__}")

with tempfile.TemporaryDirectory(prefix="hermes-runtime-smoke-") as tmp:
    venv_dir = Path(tmp) / "venv"
    venv.EnvBuilder(with_pip=True, clear=True).create(venv_dir)
    venv_python = venv_dir / "Scripts" / "python.exe"
    env = os.environ.copy()
    env.pop("PYTHONHOME", None)
    env.pop("PYTHONPATH", None)
    subprocess.run([str(venv_python), "-m", "pip", "--version"], check=True, env=env)
"""



def run(cmd: list[str]) -> None:
    print("+", " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True)


def download(url: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    print(f"download {url}", flush=True)
    urllib.request.urlretrieve(url, dest)


def copytree(src: Path, dest: Path) -> None:
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(src, dest)


def chmod_executable(path: Path) -> None:
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def write_windows_powershell_scripts_with_bom(bundle: Path) -> None:
    for script in bundle.rglob("*.ps1"):
        content = script.read_text(encoding="utf-8-sig")
        script.write_text(content, encoding="utf-8-sig", newline="\r\n")


def prepare_uv(platform_name: str, bundle: Path) -> None:
    target = UV_TARGETS[platform_name]
    suffix = "zip" if platform_name.startswith("win") else "tar.gz"
    archive = bundle / "runtime" / f"uv.{suffix}"
    url = f"https://github.com/astral-sh/uv/releases/download/{UV_VERSION}/uv-{target}.{suffix}"
    download(url, archive)


def prepare_python_runtime(platform_name: str, bundle: Path) -> None:
    if platform_name.startswith("win"):
        prepare_windows_python_runtime(bundle)
        return
    python_dest = bundle / "runtime" / "python"
    uv_python_dir = Path(os.environ.get("UV_PYTHON_INSTALL_DIR", ROOT / ".bundle-work" / "uv-python"))
    os.environ["UV_PYTHON_INSTALL_DIR"] = str(uv_python_dir)
    run(["uv", "python", "install", PYTHON_VERSION])
    candidates = sorted(uv_python_dir.glob(f"cpython-{PYTHON_VERSION}*"))
    if not candidates:
        raise SystemExit(f"未找到 uv 安装的 Python runtime: {uv_python_dir}")
    copytree(candidates[-1], python_dest)


def prepare_windows_python_runtime(bundle: Path) -> None:
    # Windows 必须使用 python.org 官方签名构建(NuGet 分发):python-build-standalone
    # 的二进制没有 Authenticode 签名,会被应用程序控制策略(智能应用控制 / WDAC)拦截。
    python_dest = bundle / "runtime" / "python"
    work = ROOT / ".bundle-work"
    nupkg = work / f"python.{WINDOWS_PYTHON_VERSION}.nupkg"
    if not nupkg.exists():
        download(
            "https://api.nuget.org/v3-flatcontainer/python/"
            f"{WINDOWS_PYTHON_VERSION}/python.{WINDOWS_PYTHON_VERSION}.nupkg",
            nupkg,
        )
    extract_dir = work / f"python-nuget-{WINDOWS_PYTHON_VERSION}"
    if extract_dir.exists():
        shutil.rmtree(extract_dir)
    with zipfile.ZipFile(nupkg) as zf:
        zf.extractall(extract_dir)
    tools = extract_dir / "tools"
    if not (tools / "python.exe").is_file():
        raise SystemExit(f"NuGet python 包缺少 tools/python.exe: {nupkg}")
    copytree(tools, python_dest)


def validate_python_runtime(platform_name: str, bundle: Path) -> None:
    if platform_name.startswith("win"):
        candidates = [
            bundle / "runtime" / "python" / "python.exe",
            bundle / "runtime" / "python" / "bin" / "python.exe",
        ]
    else:
        candidates = [
            bundle / "runtime" / "python" / "bin" / "python3",
            bundle / "runtime" / "python" / "bin" / "python",
            bundle / "runtime" / "python" / "python",
        ]
    python = next((candidate for candidate in candidates if candidate.exists()), None)
    if python is None:
        raise SystemExit(f"未找到 bundle Python executable: {bundle / 'runtime' / 'python'}")

    if platform_name.startswith("win"):
        python_home = python.parent
        print(f"Python runtime executable: {python}")
        print(f"Python runtime home: {python_home}")
        print(f"Python runtime Lib/encodings: {(python_home / 'Lib' / 'encodings').exists()}")
        print(f"Python runtime {PYTHON_STDLIB_ZIP}: {(python_home / PYTHON_STDLIB_ZIP).exists()}")

    env = os.environ.copy()
    env.pop("PYTHONHOME", None)
    env.pop("PYTHONPATH", None)
    env["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
    if platform_name.startswith("win"):
        if sys.platform != "win32":
            raise SystemExit("Windows bundle Python smoke tests must run on a Windows host")
        env["PYTHONHOME"] = str(python.parent)
    subprocess.run(
        [str(python), "-c", PYTHON_RUNTIME_IMPORT_CHECK],
        check=True,
        cwd=bundle,
        env=env,
    )
    if platform_name.startswith("win"):
        subprocess.run(
            [str(python), "-c", WINDOWS_PYTHON_RUNTIME_SMOKE],
            check=True,
            cwd=bundle,
            env=env,
        )
        validate_windows_python_signatures(python.parent)


def validate_windows_python_signatures(python_home: Path) -> None:
    # 应用程序控制策略按签名放行,这里锁死关键二进制必须带有效 Authenticode 签名,
    # 防止运行时来源回退到无签名构建。
    stdlib_dll = f"python{''.join(WINDOWS_PYTHON_VERSION.split('.')[:2])}.dll"
    critical = [
        python_home / "python.exe",
        python_home / "python3.dll",
        python_home / stdlib_dll,
        python_home / "DLLs" / "_ctypes.pyd",
        *sorted((python_home / "DLLs").glob("libffi*.dll")),
    ]
    missing = [str(path) for path in critical if not path.is_file()]
    if missing:
        raise SystemExit("Windows Python runtime 缺少关键文件: " + ", ".join(missing))
    joined = ", ".join(f"'{path}'" for path in critical)
    script = (
        f"$bad = @({joined}) | Where-Object {{ "
        "(Get-AuthenticodeSignature -FilePath $_).Status -ne 'Valid' }; "
        "if ($bad) { $bad | ForEach-Object { Write-Output $_ }; exit 1 }"
    )
    result = subprocess.run(
        ["powershell", "-NoProfile", "-NonInteractive", "-Command", script],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise SystemExit(
            "Windows Python runtime 存在无效 Authenticode 签名(会被应用程序控制策略拦截):\n"
            + (result.stdout or "") + (result.stderr or "")
        )


def validate_hermes_resources(resources: Path) -> None:
    if not resources.is_dir():
        raise SystemExit(f"缺少 Hermes runtime resources: {resources}")
    missing = [rel for rel in HERMES_RESOURCE_SENTINELS if not (resources / rel).is_file()]
    if missing:
        raise SystemExit(
            "Hermes runtime resources are incomplete. Missing: " + ", ".join(sorted(missing))
        )

    skill_count = sum(1 for _ in (resources / "skills").rglob("SKILL.md"))
    optional_skill_count = sum(1 for _ in (resources / "optional-skills").rglob("SKILL.md"))
    optional_mcp_count = sum(1 for _ in (resources / "optional-mcps").rglob("manifest.yaml"))
    plugin_count = sum(1 for _ in (resources / "plugins").rglob("plugin.yaml"))
    locale_count = len(list((resources / "locales").glob("*.yaml")))
    print(
        "Hermes runtime resources: "
        f"skills={skill_count}, optional_skills={optional_skill_count}, "
        f"optional_mcps={optional_mcp_count}, plugins={plugin_count}, locales={locale_count}",
        flush=True,
    )


def archive_bundle(platform_name: str, bundle: Path, output: Path) -> Path:
    output.mkdir(parents=True, exist_ok=True)
    if platform_name.startswith("win"):
        archive = output / f"hermes-offline-installer-{platform_name}.zip"
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as zf:
            for file in bundle.rglob("*"):
                zf.write(file, file.relative_to(bundle.parent))
        return archive

    archive = output / f"hermes-offline-installer-{platform_name}.tar.gz"
    with tarfile.open(archive, "w:gz") as tf:
        tf.add(bundle, arcname=bundle.name)
    return archive


def validate_archive_python_stdlib(platform_name: str, archive: Path) -> None:
    if not platform_name.startswith("win"):
        return

    with zipfile.ZipFile(archive) as zf:
        names = set(zf.namelist())
        prefix = f"hermes-offline-installer-{platform_name}/runtime/python/"
        lib_encoding = prefix + "Lib/encodings/__init__.py"
        nested_zip = prefix + PYTHON_STDLIB_ZIP
        if lib_encoding in names:
            return
        if nested_zip in names:
            import io

            with zf.open(nested_zip) as nested_file:
                nested_data = nested_file.read()
            with zipfile.ZipFile(io.BytesIO(nested_data)) as nested:
                nested_names = set(nested.namelist())
            if "encodings/__init__.py" in nested_names:
                return
        raise SystemExit(
            f"{archive.name} does not contain Python encodings in "
            f"{lib_encoding} or {nested_zip}"
        )


def validate_archive_windows_runtime_hooks(platform_name: str, archive: Path) -> None:
    if not platform_name.startswith("win"):
        return

    with zipfile.ZipFile(archive) as zf:
        names = set(zf.namelist())
    prefix = f"hermes-offline-installer-{platform_name}/"
    python_prefix = prefix + "runtime/python/"
    if not any(name.startswith(python_prefix) and name.endswith("/_ctypes.pyd") for name in names):
        raise SystemExit(f"{archive.name} does not contain bundled Python _ctypes.pyd")
    pip_hook = prefix + "scripts/pip_sitecustomize.py"
    if pip_hook not in names:
        raise SystemExit(f"{archive.name} does not contain {pip_hook}")


def validate_archive_hermes_resources(platform_name: str, archive: Path) -> None:
    prefix = f"hermes-offline-installer-{platform_name}/hermes-resources/"
    expected = {prefix + rel for rel in HERMES_RESOURCE_SENTINELS}
    if platform_name.startswith("win"):
        with zipfile.ZipFile(archive) as zf:
            names = set(zf.namelist())
    else:
        with tarfile.open(archive, "r:gz") as tf:
            names = set(tf.getnames())
    missing = sorted(expected - names)
    if missing:
        raise SystemExit(
            f"{archive.name} does not contain required Hermes resources: "
            + ", ".join(path.removeprefix(prefix) for path in missing)
        )


def read_wheelhouse_manifest(wheelhouse: Path) -> dict[str, object]:
    manifest = wheelhouse / "manifest.json"
    if not manifest.is_file():
        return {}
    return json.loads(manifest.read_text(encoding="utf-8"))


def main() -> None:
    parser = argparse.ArgumentParser(description="构建 Hermes Agent 离线安装 bundle")
    parser.add_argument("--platform", required=True, choices=sorted(UV_TARGETS))
    parser.add_argument("--wheelhouse", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    work = ROOT / ".bundle-work"
    bundle = work / f"hermes-offline-installer-{args.platform}"
    if bundle.exists():
        shutil.rmtree(bundle)
    bundle.mkdir(parents=True)

    wheelhouse = args.wheelhouse.resolve()
    wheelhouse_manifest = read_wheelhouse_manifest(wheelhouse)
    copytree(wheelhouse, bundle / "wheelhouse")
    resources_in_wheelhouse = bundle / "wheelhouse" / "hermes-resources"
    validate_hermes_resources(resources_in_wheelhouse)
    shutil.move(str(resources_in_wheelhouse), str(bundle / "hermes-resources"))
    copytree(ROOT / "installers", bundle / "installers")
    copytree(ROOT / "templates", bundle / "templates")
    copytree(ROOT / "scripts", bundle / "scripts")

    for script in [bundle / "installers" / "install_unix.sh", bundle / "scripts" / "verify_unix.sh"]:
        if script.exists():
            chmod_executable(script)
    if args.platform.startswith("win"):
        write_windows_powershell_scripts_with_bom(bundle)
        shutil.copy2(bundle / "installers" / "install_windows.cmd", bundle / "install_windows.cmd")
        shutil.copy2(bundle / "installers" / "install_windows.cmd", bundle / "install.cmd")
        shutil.copy2(bundle / "installers" / "launch_windows.cmd", bundle / "launch.cmd")
        shutil.copy2(bundle / "installers" / "repair_windows.cmd", bundle / "repair.cmd")
        shutil.copy2(bundle / "installers" / "shutdown_windows.cmd", bundle / "shutdown.cmd")
        shutil.copy2(bundle / "installers" / "uninstall_windows.cmd", bundle / "uninstall.cmd")

    prepare_uv(args.platform, bundle)
    prepare_python_runtime(args.platform, bundle)
    validate_python_runtime(args.platform, bundle)
    write_manifest(
        bundle / "manifest.json",
        target_platform=args.platform,
        extra={
            "kind": "bundle",
            "python_version": (
                WINDOWS_PYTHON_VERSION if args.platform.startswith("win") else PYTHON_VERSION
            ),
            "wheelhouse": wheelhouse_manifest,
            "hermes_version": wheelhouse_manifest.get("hermes_version"),
            "hermes_extras": wheelhouse_manifest.get("extras"),
            "hermes_source_commit": wheelhouse_manifest.get("hermes_source_commit"),
        },
    )

    archive = archive_bundle(args.platform, bundle, args.output.resolve())
    validate_archive_python_stdlib(args.platform, archive)
    validate_archive_windows_runtime_hooks(args.platform, archive)
    validate_archive_hermes_resources(args.platform, archive)
    print(f"created {archive}")


if __name__ == "__main__":
    main()
