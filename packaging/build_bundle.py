#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import shutil
import stat
import subprocess
import tarfile
import urllib.request
import zipfile
from pathlib import Path

from manifest import PYTHON_VERSION, UV_VERSION, write_manifest

ROOT = Path(__file__).resolve().parents[1]

UV_TARGETS = {
    "mac-arm64": "aarch64-apple-darwin",
    "mac-x64": "x86_64-apple-darwin",
    "linux-x64": "x86_64-unknown-linux-gnu",
    "win-x64": "x86_64-pc-windows-msvc",
}



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


def prepare_python_runtime(bundle: Path) -> None:
    python_dest = bundle / "runtime" / "python"
    uv_python_dir = Path(os.environ.get("UV_PYTHON_INSTALL_DIR", ROOT / ".bundle-work" / "uv-python"))
    os.environ["UV_PYTHON_INSTALL_DIR"] = str(uv_python_dir)
    run(["uv", "python", "install", PYTHON_VERSION])
    candidates = sorted(uv_python_dir.glob(f"cpython-{PYTHON_VERSION}*"))
    if not candidates:
        raise SystemExit(f"未找到 uv 安装的 Python runtime: {uv_python_dir}")
    copytree(candidates[-1], python_dest)


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

    env = os.environ.copy()
    env.pop("PYTHONHOME", None)
    env.pop("PYTHONPATH", None)
    if platform_name.startswith("win"):
        env["PYTHONHOME"] = str(python.parent)
    subprocess.run(
        [str(python), "-c", "import encodings, venv"],
        check=True,
        cwd=bundle,
        env=env,
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

    copytree(args.wheelhouse.resolve(), bundle / "wheelhouse")
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

    prepare_uv(args.platform, bundle)
    prepare_python_runtime(bundle)
    validate_python_runtime(args.platform, bundle)
    write_manifest(bundle / "manifest.json", target_platform=args.platform, extra={"kind": "bundle"})

    archive = archive_bundle(args.platform, bundle, args.output.resolve())
    print(f"created {archive}")


if __name__ == "__main__":
    main()
