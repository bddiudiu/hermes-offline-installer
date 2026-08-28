from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "packaging"))

import build_wheelhouse  # noqa: E402
import build_bundle  # noqa: E402
import read_hermes_version  # noqa: E402
import resolve_hermes_source  # noqa: E402


class SourceDistributionTests(unittest.TestCase):
    def test_release_workflow_matches_bundled_tool_versions(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8")
        self.assertEqual(build_bundle.PYTHON_VERSION, "3.12.14")
        self.assertEqual(build_bundle.UV_VERSION, "0.12.7")
        self.assertIn(f'"uv=={build_bundle.UV_VERSION}"', workflow)

    def test_runtime_requirements_match_current_upstream_release(self) -> None:
        self.assertIn("aiohttp==3.14.3", build_wheelhouse.OFFLINE_RUNTIME_REQUIREMENTS)
        self.assertIn("python-multipart==0.0.32", build_wheelhouse.OFFLINE_RUNTIME_REQUIREMENTS)
        self.assertIn("websockets==15.0.1", build_wheelhouse.OFFLINE_RUNTIME_REQUIREMENTS)
        self.assertIn("setuptools==83.0.0", build_wheelhouse.BUILD_REQUIREMENTS)

    def test_release_tag_normalization_adds_missing_v_prefix(self) -> None:
        self.assertEqual(resolve_hermes_source.normalize_release_tag("2026.8.27"), "v2026.8.27")
        self.assertEqual(resolve_hermes_source.normalize_release_tag("v2026.8.27"), "v2026.8.27")
        self.assertEqual(resolve_hermes_source.normalize_release_tag("main"), "main")

    def test_parse_extras_normalizes_and_rejects_invalid_values(self) -> None:
        self.assertEqual(build_wheelhouse.parse_extras(" all, web "), ["all", "web"])
        with self.assertRaises(SystemExit):
            build_wheelhouse.parse_extras("all,../../escape")

    def test_export_source_keeps_runtime_files_and_drops_generated_dirs(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source = root / "source"
            output = root / "wheelhouse"
            source.mkdir()
            output.mkdir()
            for relative in build_wheelhouse.HERMES_SOURCE_SENTINELS:
                path = source / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("placeholder\n", encoding="utf-8")
            (source / "pyproject.toml").write_text(
                '[project]\nname = "hermes-agent"\nversion = "0.19.1"\n',
                encoding="utf-8",
            )
            (source / "node_modules" / "pkg").mkdir(parents=True)
            (source / "node_modules" / "pkg" / "index.js").write_text("", encoding="utf-8")
            (source / ".git").mkdir()
            (source / ".git" / "config").write_text("[core]\n", encoding="utf-8")
            (source / "hermes_cli" / "__pycache__").mkdir()
            (source / "hermes_cli" / "__pycache__" / "main.pyc").write_bytes(b"cache")

            bundled = build_wheelhouse.export_hermes_source(source, output)

            self.assertEqual(build_wheelhouse.read_source_version(bundled), "0.19.1")
            self.assertTrue((bundled / "hermes_cli" / "main.py").is_file())
            self.assertFalse((bundled / ".git").exists())
            self.assertFalse((bundled / "node_modules").exists())
            self.assertFalse((bundled / "hermes_cli" / "__pycache__").exists())

    def test_manifest_version_supports_source_only_wheelhouse(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            wheelhouse = Path(temp_dir)
            (wheelhouse / "manifest.json").write_text(
                json.dumps({"hermes_version": "0.19.1", "hermes_install_mode": "editable-source"}),
                encoding="utf-8",
            )

            self.assertEqual(
                read_hermes_version.manifest_version(wheelhouse, "hermes-agent"),
                "0.19.1",
            )

    def test_windows_script_encoding_does_not_rewrite_bundled_source(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            bundle = Path(temp_dir)
            installer_script = bundle / "installers" / "install.ps1"
            source_script = bundle / "hermes-agent" / "scripts" / "install.ps1"
            installer_script.parent.mkdir(parents=True)
            source_script.parent.mkdir(parents=True)
            installer_script.write_bytes(b"Write-Host installer\n")
            source_script.write_bytes(b"Write-Host upstream\n")

            build_bundle.write_windows_powershell_scripts_with_bom(bundle)

            self.assertTrue(installer_script.read_bytes().startswith(b"\xef\xbb\xbf"))
            self.assertIn(b"\r\n", installer_script.read_bytes())
            self.assertEqual(source_script.read_bytes(), b"Write-Host upstream\n")


if __name__ == "__main__":
    unittest.main()
