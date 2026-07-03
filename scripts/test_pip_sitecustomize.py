from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    if sys.platform != "win32":
        return

    with tempfile.TemporaryDirectory(prefix="hermes-pip-sitecustomize-") as tmp:
        patch_dir = Path(tmp)
        shutil.copy2(ROOT / "scripts" / "pip_sitecustomize.py", patch_dir / "sitecustomize.py")
        (patch_dir / "ctypes.py").write_text(
            'raise ImportError("synthetic ctypes failure")\n',
            encoding="utf-8",
        )

        env = os.environ.copy()
        env["PYTHONPATH"] = str(patch_dir)
        env.setdefault("ProgramData", r"C:\ProgramData")
        env.setdefault("ALLUSERSPROFILE", env["ProgramData"])

        code = r"""
import os
import pip._vendor.platformdirs.windows as windows

if not getattr(windows.get_win_folder, "_hermes_env_patch", False):
    raise SystemExit("Hermes pip platformdirs patch was not installed")

common = windows.get_win_folder("CSIDL_COMMON_APPDATA")
expected = os.environ.get("ProgramData") or os.environ.get("ALLUSERSPROFILE") or r"C:\ProgramData"
if common != expected:
    raise SystemExit(f"Expected {expected!r}, got {common!r}")

print(common)
"""
        subprocess.run([sys.executable, "-c", code], check=True, env=env)


if __name__ == "__main__":
    main()
