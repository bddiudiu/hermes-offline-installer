from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "scripts"), str(ROOT / "packaging")]
import build_bundle
import build_wheelhouse
import hermes_version
import upgrade_support

COMMIT = "d923a5eb487a17c0a68801bba9ef0f56c81040a8"


def stamp() -> dict:
    return {"schemaVersion": 2, "commit": COMMIT, "source": "build",
            "updateMechanism": "external", "payload": "bootstrap", "dirty": False,
            "distance": 0, "baseVersion": "0.22.2", "displayVersion": "0.22.2"}


class ReleaseIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.source.mkdir()
        (self.source / "pyproject.toml").write_text('[project]\nversion = "0.0.0"\n')

    def write_stamp(self, value=None):
        (self.source / "install-stamp.json").write_text(json.dumps(stamp() if value is None else value))

    def test_placeholder_requires_identity_and_legacy_metadata_still_works(self):
        with self.assertRaises(hermes_version.VersionError):
            hermes_version.source_identity(self.source)
        self.write_stamp()
        identity = hermes_version.source_identity(self.source, expected_version="0.22.2", expected_commit=COMMIT)
        self.assertEqual(identity, {"version": "0.22.2", "distribution_version": "0.0.0", "commit": COMMIT})
        (self.source / "install-stamp.json").unlink()
        (self.source / "pyproject.toml").write_text('[project]\nversion = "0.21.5"\n')
        self.assertEqual(hermes_version.source_identity(self.source)["version"], "0.21.5")

    def test_malformed_or_conflicting_identity_never_falls_back(self):
        cases = [None, [], {**stamp(), "baseVersion": "0.0.0"},
                 {**stamp(), "commit": "0" * 40}, {**stamp(), "updateMechanism": "self"},
                 {**stamp(), "dirty": True}, {**stamp(), "payload": "light"},
                 {**stamp(), "displayVersion": "0.21.5"}]
        for value in cases:
            with self.subTest(value=value):
                (self.source / "install-stamp.json").write_text(json.dumps(value))
                with self.assertRaises(hermes_version.VersionError):
                    hermes_version.source_identity(self.source)
        self.write_stamp()
        with self.assertRaisesRegex(hermes_version.VersionError, "commits differ"):
            hermes_version.source_identity(self.source, expected_commit="a" * 40)
        with self.assertRaisesRegex(hermes_version.VersionError, "versions differ"):
            hermes_version.source_identity(self.source, expected_version="0.21.5")

    def test_build_version_comes_from_exact_stable_tag(self):
        def git(*args):
            subprocess.run(["git", *args], cwd=self.source, check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        git("init")
        git("add", "pyproject.toml")
        git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "fixture")
        with self.assertRaises(SystemExit):
            build_wheelhouse.read_source_version(self.source)
        git("tag", "v0.22.2")
        self.assertEqual(build_wheelhouse.read_source_version(self.source), "0.22.2")
        git("tag", "v0.22.3")
        with self.assertRaises(SystemExit):
            build_wheelhouse.read_source_version(self.source)

    def test_build_refuses_interpreter_that_would_skip_core_markers(self):
        with mock.patch.object(build_wheelhouse.sys, "version_info", (3, 12, 14)):
            with self.assertRaisesRegex(SystemExit, "markers"):
                build_wheelhouse.validate_build_environment("win-x64")

    def test_preflight_helper_does_not_write_into_the_extracted_bundle(self):
        helper_dir = self.root / "scripts"
        helper_dir.mkdir()
        for name in ("upgrade_support.py", "hermes_version.py"):
            shutil.copy2(ROOT / "scripts" / name, helper_dir / name)
        before = {p.name: p.read_bytes() for p in helper_dir.iterdir()}
        env = os.environ.copy()
        env.pop("PYTHONDONTWRITEBYTECODE", None)
        env.pop("PYTHONPYCACHEPREFIX", None)
        result = subprocess.run([sys.executable, str(helper_dir / "upgrade_support.py"),
                                 "bundle", "--bundle", str(self.root / "missing"), "--version", "0.21.5"],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("error", json.loads(result.stdout))
        self.assertEqual({p.name: p.read_bytes() for p in helper_dir.iterdir()}, before)

    def test_runtime_checks_stamp_metadata_and_upstream_identity_together(self):
        self.write_stamp()
        home = self.root / "home"
        hermes_cli = types.ModuleType("hermes_cli")
        hermes_cli.__file__ = str(self.source / "hermes_cli" / "__init__.py")
        constants = types.ModuleType("hermes_constants")
        constants.get_hermes_home = lambda: home
        info = types.ModuleType("hermes_cli.version_info")
        info.get_version_info = lambda: types.SimpleNamespace(base_version="0.22.2", commit=COMMIT)
        with mock.patch.dict(sys.modules, {"hermes_cli": hermes_cli, "hermes_constants": constants,
                                          "hermes_cli.version_info": info}), \
                mock.patch.object(upgrade_support.importlib.metadata, "version", return_value="0.0.0"):
            self.assertEqual(upgrade_support.installed_version(), "0.22.2")
            self.assertEqual(upgrade_support.verify_runtime(self.source, "0.22.2", home)["version"], "0.22.2")
            info.get_version_info = lambda: types.SimpleNamespace(base_version="unknown", commit=None)
            with self.assertRaisesRegex(upgrade_support.UpgradeError, "runtime identity"):
                upgrade_support.verify_runtime(self.source, "0.22.2", home)

    def test_new_bundle_accepts_legacy_upgrade_and_rejects_commit_mismatch(self):
        bundle = self.root / "bundle"
        bundled_source = bundle / "hermes-agent"
        bundled_source.mkdir(parents=True)
        (bundled_source / "pyproject.toml").write_text('[project]\nversion = "0.0.0"\n')
        (bundled_source / "install-stamp.json").write_text(json.dumps(stamp()))
        manifest = {"kind": "bundle", "target_platform": "win-x64", "hermes_install_mode": "editable-source",
                    "hermes_version": "0.22.2", "hermes_source_commit": COMMIT,
                    "wheelhouse": {"hermes_version": "0.22.2", "hermes_source_commit": COMMIT}}
        (bundle / "manifest.json").write_text(json.dumps(manifest))
        for name in ("hermes-agent/hermes_cli/main.py", "hermes-agent/tools/skills_sync.py",
                     "hermes-resources/web_dist/index.html", "hermes-resources/tui_dist/dist/entry.js",
                     "scripts/upgrade_support.py", "installers/upgrade.ps1", "runtime/python/python.exe",
                     "templates/config.yaml"):
            path = bundle / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture")
        (bundle / "wheelhouse").mkdir()
        (bundle / "wheelhouse/requirements.txt").write_text("example==1.0\n")
        (bundle / "wheelhouse/hermes-editable-requirement.txt").write_text(".[all]\n")
        build_bundle.write_upgrade_manifest(bundle)
        self.assertEqual(upgrade_support.verify_bundle(bundle, "0.21.5")["version"], "0.22.2")
        manifest["hermes_source_commit"] = "a" * 40
        (bundle / "manifest.json").write_text(json.dumps(manifest))
        build_bundle.write_upgrade_manifest(bundle)
        with self.assertRaisesRegex(upgrade_support.UpgradeError, "commits differ"):
            upgrade_support.verify_bundle(bundle, "0.21.5")

    def test_config_is_a_separate_asset_and_only_default_template_enters_zip(self):
        bundle = self.root / "hermes-offline-installer-win-x64"
        build_bundle.copy_install_templates(bundle)
        output = self.root / "dist"
        archive = build_bundle.archive_bundle("win-x64", bundle, output)
        config = build_bundle.export_config(output)
        self.assertEqual(config.read_bytes(), (ROOT / "templates/config.yaml").read_bytes())
        self.assertEqual(config.read_bytes(), (ROOT / "templates/config.v0.22.2.example.yaml").read_bytes())
        self.assertEqual((output / "config.yaml.sha256").read_text().split()[0], hashlib.sha256(config.read_bytes()).hexdigest())
        with zipfile.ZipFile(archive) as zf:
            self.assertIn("hermes-offline-installer-win-x64/templates/config.yaml", zf.namelist())
            self.assertFalse(any("example.yaml" in name for name in zf.namelist()))
            self.assertNotIn("config.yaml", zf.namelist())


if __name__ == "__main__":
    unittest.main()
