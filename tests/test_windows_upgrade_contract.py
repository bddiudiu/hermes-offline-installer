"""Static safeguards, not a substitute for a live Windows upgrade/rollback test."""
from __future__ import annotations

import hashlib
import json
import re
import shutil
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "packaging"))

import build_bundle  # noqa: E402


class UpgradePackagingTests(unittest.TestCase):
    def test_checksum_inventory_hashes_final_bom_crlf_and_root_entrypoints(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            bundle = Path(temp_dir)
            script = bundle / "installers" / "upgrade.ps1"
            script.parent.mkdir()
            script.write_text("# 中文脚本\nWrite-Host 'fixture'\n", encoding="utf-8")
            (bundle / "upgrade.cmd").write_text("@echo off\nexit /b %ERRORLEVEL%\n")
            (bundle / "manifest.json").write_text('{"kind":"bundle"}\n')
            nested = bundle / "hermes-agent" / "upgrade-manifest.json"
            nested.parent.mkdir()
            nested.write_text("nested file must also be hashed")
            build_bundle.write_windows_powershell_scripts_with_bom(bundle)
            shutil.copy2(script, bundle / "upgrade.ps1")
            build_bundle.write_upgrade_manifest(bundle)
            manifest_path = bundle / "upgrade-manifest.json"
            first = manifest_path.read_bytes()
            manifest = json.loads(first)
            files = manifest["files"]
            self.assertEqual(manifest["schema"], 1)
            self.assertEqual(manifest["algorithm"], "sha256")
            self.assertNotIn("upgrade-manifest.json", files)
            self.assertIn("hermes-agent/upgrade-manifest.json", files)
            self.assertIn("upgrade.cmd", files)
            self.assertEqual(files["upgrade.ps1"], files["installers/upgrade.ps1"])
            self.assertTrue(script.read_bytes().startswith(b"\xef\xbb\xbf"))
            self.assertIn(b"\r\n", script.read_bytes())
            for relative, expected in files.items():
                self.assertEqual(hashlib.sha256((bundle / relative).read_bytes()).hexdigest(), expected)
            # Rebuilding the inventory never includes its previous contents.
            build_bundle.write_upgrade_manifest(bundle)
            self.assertEqual(manifest_path.read_bytes(), first)

    def test_checksum_inventory_rejects_links(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            bundle = Path(temp_dir)
            original = bundle / "original"
            original.write_text("fixture")
            try:
                (bundle / "alias").symlink_to(original)
            except (OSError, NotImplementedError):
                self.skipTest("Creating symlinks is not supported for this test account")
            with self.assertRaisesRegex(SystemExit, "symlink"):
                build_bundle.write_upgrade_manifest(bundle)

    def test_packaging_generates_inventory_after_final_copies_and_before_archive(self) -> None:
        source = (ROOT / "packaging/build_bundle.py").read_text(encoding="utf-8")
        main = source.split("def main()", 1)[1]
        for prerequisite in ('write_windows_powershell_scripts_with_bom(bundle)',
                             'bundle / "upgrade.cmd"', 'bundle / "upgrade.ps1"',
                             'bundle / "UPGRADE.zh-CN.md"', 'write_manifest('):
            self.assertLess(main.index(prerequisite), main.index("write_upgrade_manifest(bundle)"))
        self.assertLess(main.index("write_upgrade_manifest(bundle)"), main.index("archive_bundle("))


class WindowsUpgradeStaticContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.ps = (ROOT / "installers/upgrade.ps1").read_text(encoding="utf-8-sig")
        cls.cmd = (ROOT / "installers/upgrade.cmd").read_text(encoding="utf-8-sig")
        cls.main = cls.ps.split("\ntry {\n  if ($env:OS", 1)[1]

    def function(self, name: str) -> str:
        rest = self.ps.split(f"function {name}", 1)[1]
        return re.split(r"\nfunction |\ntry \{\n  if \(\$env:OS", rest, maxsplit=1)[0]

    def test_synchronous_cmd_forwards_real_exit_code_and_all_arguments(self) -> None:
        commands = "\n".join(line for line in self.cmd.splitlines() if not line.lower().startswith("rem "))
        self.assertIn('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%UPGRADE_PS1%" %*', commands)
        self.assertIn("exit /b %ERRORLEVEL%", commands)
        self.assertNotRegex(commands, r"(?im)^\s*(?:start|pause)\b")
        self.assertNotIn("RunAs", commands)
        self.assertNotIn("/k", commands.lower())

    def test_whatif_gate_precedes_new_lock_backup_stop_and_journal(self) -> None:
        normal = self.main.split("if ($Recover) { throw 'No interrupted upgrade needs recovery.' }", 1)[1]
        gate = normal.index("$PSCmdlet.ShouldProcess(")
        self.assertLess(normal.index("$Bundle = Invoke-Helper"), gate)
        self.assertLess(normal.index("Assert-FreeSpace"), gate)
        for mutation in ("$script:Lock = [IO.File]::Open", "New-PrivateDirectory", "Write-Journal 'prepared'", "\n  Stop-Owned"):
            self.assertGreater(normal.index(mutation), gate)
        self.assertIn("SupportsShouldProcess = $true", self.ps)

    def test_preflight_rejects_nested_paths_and_reparse_points(self) -> None:
        self.assertIn("Assert-Separate $script:Source $script:InstallRoot", self.main)
        self.assertIn("Assert-Separate $script:Home $script:InstallRoot", self.main)
        self.assertIn("Assert-Separate $script:Home $script:Source", self.main)
        for path in ("$script:Source", "$script:InstallRoot", "$script:Home"):
            self.assertIn(f"Assert-NoLinks {path}", self.main)
        self.assertIn("[IO.FileAttributes]::ReparsePoint", self.function("Assert-NoLinks"))

    def test_existing_launcher_is_parsed_never_executed_or_replaced_by_install(self) -> None:
        self.assertIn("Get-Content -LiteralPath $OldShim", self.main)
        self.assertNotRegex(self.ps, r"(?im)^\s*(?:&|\.)\s+\$OldShim\b")
        self.assertNotIn("Invoke-Expression", self.ps)
        self.assertNotIn("install_windows.ps1", self.ps)
        self.assertNotIn("configure_config.py", self.ps)
        self.assertIn("[Environment]::SetEnvironmentVariable($Name, $Value, 'Process')", self.ps)
        self.assertNotRegex(self.ps, r"SetEnvironmentVariable\([^\n]+['\"](?:User|Machine)['\"]\)")

    def test_process_stopping_uses_exact_runtime_ownership_and_pid_identity(self) -> None:
        owned = self.function("Get-OwnedProcesses")
        self.assertIn("Test-Within $P.ExecutablePath $script:Runtime", owned)
        stopped = self.function("Stop-Owned")
        self.assertIn("$Now.CreationDate -eq $P.CreationDate", stopped)
        self.assertIn("Stop-Process -Id $P.ProcessId", stopped)
        self.assertNotRegex(self.ps, r"Stop-Process\s+-Name\b")
        self.assertNotRegex(self.ps, r"(?i)taskkill[^\n]+/im")
        self.assertIn("Assert-NoSupervisors", self.main)
        self.assertIn("Multiple gateways/backends", self.function("Get-RestartSpecs"))

    def test_cold_snapshots_and_hashes_precede_runtime_destruction(self) -> None:
        normal = self.main.split("Write-Journal 'prepared'", 1)[1]
        stop = normal.index("Stop-Owned")
        snapshot = normal.index("Copy-Tree $script:Home")
        comparison = normal.index("@('compare', '--home', $script:Runtime")
        journal = normal.index("Write-Journal 'replacing-runtime'")
        destructive = normal.index("Remove-Item -LiteralPath $script:Runtime -Recurse -Force")
        self.assertLess(stop, snapshot)
        self.assertLess(snapshot, comparison)
        self.assertLess(comparison, journal)
        self.assertLess(journal, destructive)
        self.assertIn("Copy-Tree $script:Runtime (Join-Path $Backup 'runtime')", normal)
        self.assertIn("Copy-Tree (Join-Path $script:InstallRoot 'bin') (Join-Path $Backup 'bin')", normal)

    def test_offline_venv_is_created_at_final_runtime_path_before_migration(self) -> None:
        normal = self.main
        self.assertIn("$Venv = Join-Path $script:Runtime 'venv'", normal)
        self.assertIn("@('-m', 'venv', '--without-pip', $Venv)", normal)
        self.assertIn("'--only-binary=:all:', '--no-index', '--find-links', $Wheelhouse", normal)
        self.assertIn("'--no-build-isolation', '-e', $Editable", normal)
        self.assertLess(normal.index("@('verify', '--source', $SourceTree"), normal.index("Write-Journal 'migrating-home'"))
        self.assertIn("foreach ($Profile in @($Inspect.homes))", normal)

    def test_real_health_and_asset_validation_precede_keep_stopped_or_commit(self) -> None:
        validation = self.main.split("Write-Journal 'validating'", 1)[1]
        self.assertLess(validation.index("Start-Spec $Gateway"), validation.index("@('health'"))
        self.assertLess(validation.index("@('health'"), validation.index("if (-not $KeepStopped)"))
        self.assertLess(validation.index("@('preserved'"), validation.index("Write-Journal 'committed'"))
        self.assertIn("Test-Within $HealthProcess.ExecutablePath $script:Runtime", validation)
        self.assertIn("Get-NetTCPConnection -State Listen -LocalPort $Endpoint.port", self.main)

    def test_journal_is_flushed_atomically_and_backups_are_private(self) -> None:
        journal = self.function("Write-Journal")
        self.assertIn("$Stream.Flush($true)", journal)
        self.assertIn("[IO.File]::Replace", journal)
        self.assertIn("[IO.File]::Move", journal)
        acl = self.function("New-PrivateDirectory")
        self.assertIn("SetAccessRuleProtection($true, $false)", acl)
        self.assertIn("S-1-5-18", acl)
        self.assertIn("S-1-5-32-544", acl)

    def test_recovery_mirrors_full_home_and_bin_and_verifies_restored_bytes(self) -> None:
        restore = self.function("Restore-Transaction")
        self.assertIn("Copy-Tree (Join-Path $script:Journal.backup 'home') $script:Home -Mirror", restore)
        self.assertIn("Copy-Tree (Join-Path $script:Journal.backup 'bin') (Join-Path $script:InstallRoot 'bin') -Mirror", restore)
        self.assertIn("@('compare', '--home', $script:Home", restore)
        self.assertIn("@('compare', '--home', $script:Runtime", restore)
        self.assertLess(restore.index("Stop-Owned"), restore.index("Copy-Tree"))
        self.assertLess(restore.index("@('compare'"), restore.index("Write-Journal 'restored'"))
        self.assertIn("if (-not $Recover)", self.main)

    def test_recovery_revalidates_journal_identity_paths_flags_and_restart_specs(self) -> None:
        self.assertIn("$Prior.schema -ne 1", self.main)
        self.assertIn("$Prior.actorSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value", self.main)
        self.assertIn("(Split-Path -Parent $Prior.backup)", self.main)
        self.assertIn("$Prior.runtimeMoved -isnot [bool]", self.main)
        self.assertIn("$Prior.homeBackupComplete -isnot [bool]", self.main)
        self.assertIn("foreach ($Spec in @($Prior.restart)) { Assert-RestartSpec $Spec }", self.main)
        spec = self.function("Assert-RestartSpec")
        self.assertIn("Test-Within $Spec.file $script:Runtime", spec)
        self.assertIn("Get-RestartSpecs", spec)

    def test_recovery_accepts_missing_live_home_and_uses_retained_original_launcher(self) -> None:
        self.assertIn("if ($RecoveryPrior.homeBackupComplete) { $OldShim = Join-Path $RecoveryPrior.backup 'bin\\hermes.cmd' }", self.main)
        self.assertIn("if (-not $Recover -and -not (Test-Path -LiteralPath (Join-Path $script:Home 'config.yaml')))", self.main)
        self.assertIn("Assert-NoLinks $script:Home -AllowMissing:$Recover", self.main)
        restore = self.function("Restore-Transaction")
        self.assertIn("@('snapshot-check', '--backup', $script:Journal.backup)", restore)
        self.assertLess(restore.index("@('snapshot-check'"), restore.index("Copy-Tree"))

    def test_shim_reconstruction_has_allowlist_and_compilation_temp_is_outside_home(self) -> None:
        self.assertIn("$KnownEnvironment = @(", self.main)
        self.assertIn("$Matches[1] -notin $KnownEnvironment", self.main)
        compile_at = self.main.index("Add-Type -TypeDefinition")
        shim_at = self.main.index("foreach ($Line in ($Shim -split")
        self.assertLess(self.main.index("Set-ProcessEnv 'TEMP' $CompileTemp"), compile_at)
        self.assertLess(compile_at, shim_at)
        self.assertIn("GetFolderPath('LocalApplicationData')", self.main)

    def test_rollback_resets_profile_and_python_bootstrap_environment_before_restore(self) -> None:
        restore = self.function("Restore-Transaction")
        check = restore.index("@('snapshot-check'")
        for setting in ("Set-ProcessEnv 'HERMES_HOME' $script:Home",
                        "Set-ProcessEnv 'HERMES_OFFLINE_HOME' $script:InstallRoot",
                        "Set-ProcessEnv 'PYTHONHOME' $null", "Set-ProcessEnv 'PYTHONPATH' $null"):
            self.assertLess(restore.index(setting), check)
        self.assertIn("Volume/share roots are not valid upgrade targets", self.function("Full-Path"))

    def test_both_platform_verifiers_accept_selected_models_instead_of_installer_defaults(self) -> None:
        for filename in ("scripts/verify_windows.ps1", "scripts/verify_unix.sh"):
            with self.subTest(filename=filename):
                text = (ROOT / filename).read_text(encoding="utf-8-sig")
                self.assertIn("upgrade_support.py", text)
                self.assertIn("model-config", text)
                self.assertNotIn("未默认选择 qwen3", text)
                self.assertNotIn("qwen3 模型兜底", text)
        wheelhouse = (ROOT / "packaging/build_wheelhouse.py").read_text(encoding="utf-8")
        self.assertNotIn('"skills/software-development/plan/SKILL.md"', wheelhouse)

    def test_complete_snapshot_is_sealed_before_endpoint_imports_and_covers_home_only_failures(self) -> None:
        normal = self.main.split("Write-Journal 'backing-up'", 1)[1]
        self.assertLess(normal.index("@('snapshot', '--backup', $Backup)"), normal.index("$OriginalEndpoint = Invoke-Helper"))
        self.assertLess(normal.index("$script:Journal.homeBackupComplete = $true"), normal.index("$OriginalEndpoint = Invoke-Helper"))
        self.assertIn("$script:Journal.runtimeMoved -or $script:Journal.homeBackupComplete", self.main)

    def test_ci_parses_the_new_script_with_windows_powershell_51(self) -> None:
        workflow = (ROOT / ".github/workflows/validate.yml").read_text(encoding="utf-8")
        self.assertIn("shell: powershell", workflow)
        self.assertIn('"installers/upgrade.ps1"', workflow)
        self.assertIn("scripts/upgrade_support.py", workflow)
        self.assertIn("#requires -Version 5.1", self.ps)


if __name__ == "__main__":
    unittest.main()
