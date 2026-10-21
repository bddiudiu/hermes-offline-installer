"""Run the CMD wrapper with isolated fixtures on Windows; never upgrade a real home."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
STUB = """[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [Parameter(Position = 0)] [string] $InstallDir,
  [string] $HermesHome,
  [switch] $SupervisorStopped,
  [switch] $KeepStopped
)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[ordered]@{
  install = $InstallDir
  home = $HermesHome
  whatif = [bool]$WhatIfPreference
  stopped = [bool]$SupervisorStopped
  keep = [bool]$KeepStopped
} | ConvertTo-Json -Compress
exit 17
"""


@unittest.skipUnless(os.name == "nt", "Requires Windows CMD and Windows PowerShell 5.1")
class WindowsUpgradeEntrypointTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="hermes cmd ")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        # Exercise spaces, non-ASCII, brackets and CMD metacharacters in paths.
        self.bundle = self.base / "new bundle 验收 [1] ! & (copy)"
        self.bundle.mkdir()
        self.install = self.base / "Program Files" / "StarSoftComm" / "ZhanClaw" / "Hermes"
        self.home = self.base / "preserved home 验收 [1] ! & (data)"

    def invoke(self, entry: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
        # cmd /s /c requires an outer quote pair around a quoted executable path.
        # All inputs are controlled fixture paths/flags without embedded quotes.
        command = '"' + ' '.join('"' + str(arg) + '"' for arg in (entry, *arguments)) + '"'
        return subprocess.run(
            f'"{os.environ["COMSPEC"]}" /d /v:off /s /c {command}',
            cwd=self.base, capture_output=True, text=True,
            encoding="utf-8", errors="replace", timeout=30,
        )

    def copy_wrapper(self, directory: Path) -> Path:
        directory.mkdir(parents=True, exist_ok=True)
        entry = directory / "upgrade.cmd"
        shutil.copyfile(ROOT / "installers" / "upgrade.cmd", entry)
        return entry

    def test_root_nested_and_fallback_forward_arguments_output_and_exit_code(self) -> None:
        for layout in ("root", "installers", "fallback"):
            with self.subTest(layout=layout):
                bundle = self.bundle / layout
                entry_dir = bundle / "installers" if layout == "installers" else bundle
                script_dir = bundle / "installers" if layout == "fallback" else entry_dir
                script_dir.mkdir(parents=True, exist_ok=True)
                entry = self.copy_wrapper(entry_dir)
                (script_dir / "upgrade.ps1").write_text(STUB, encoding="utf-8-sig")
                result = self.invoke(entry, str(self.install), "-HermesHome", str(self.home),
                                     "-SupervisorStopped", "-KeepStopped", "-WhatIf")
                self.assertEqual(result.returncode, 17, result.stdout + result.stderr)
                lines = result.stdout.splitlines()
                self.assertTrue(lines[0].startswith("[Hermes upgrade]"), result.stdout)
                payload = json.loads(next(line for line in lines if line.startswith("{")))
                self.assertEqual(payload, {"install": str(self.install), "home": str(self.home),
                                          "whatif": True, "stopped": True, "keep": True})
                self.assertFalse(self.install.exists())
                self.assertFalse(self.home.exists())

    def test_no_arguments_shows_usage_without_prompting(self) -> None:
        entry = self.copy_wrapper(self.bundle)
        result = self.invoke(entry)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("Usage: upgrade.cmd", result.stdout)

    def test_missing_powershell_script_explains_full_extraction(self) -> None:
        entry = self.copy_wrapper(self.bundle)
        result = self.invoke(entry, str(self.install), "-WhatIf")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("Fully extract the release ZIP", result.stdout)

    def test_real_script_reports_source_problem_before_scanning_existing_install(self) -> None:
        entry = self.copy_wrapper(self.bundle)
        shutil.copyfile(ROOT / "installers" / "upgrade.ps1", self.bundle / "upgrade.ps1")
        # A partial extraction has the root marker but no checksum manifest.
        (self.bundle / "manifest.json").write_text('{}', encoding="utf-8")
        result = self.invoke(entry, str(self.install), "-WhatIf")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("[Preflight] Starting Hermes upgrade checks.", result.stdout)
        self.assertIn("[Preflight] WhatIf: read-only checks", result.stdout)
        self.assertIn("Incomplete upgrade source", result.stdout)
        self.assertNotIn("Checking existing installation directory links", result.stdout)
        self.assertFalse(self.install.exists())


if __name__ == "__main__":
    unittest.main()
