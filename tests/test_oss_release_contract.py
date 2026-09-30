"""Run the workflow's upload code against a fake SDK; never contact OSS."""
from __future__ import annotations

import contextlib
import io
import os
import sys
import tempfile
import textwrap
import types
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/release.yml"
VERSION_PREFIX = "hermes/0.21.4-123"


def upload_code() -> str:
    text = WORKFLOW.read_text(encoding="utf-8")
    step = text.split("      - name: Upload files to OSS\n", 1)[1]
    block = step.split("          python <<'PY'\n", 1)[1].split("          PY\n", 1)[0]
    return textwrap.dedent(block).replace("${{ steps.meta.outputs.path_prefix }}", VERSION_PREFIX)


class OSSReleaseContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        upload = self.root / "upload"
        upload.mkdir()
        for name in ("hermes-offline-installer-win-x64.zip", "hermes-offline-installer-win-x64.zip.sha256", "latest.json"):
            (upload / name).write_text("fixture only", encoding="utf-8")
        self.env = {
            "ALIYUN_OSS_BUCKET": "fixture-bucket",
            "ALIYUN_OSS_ENDPOINT": "fixture.invalid",
            "ALIYUN_OSS_ACCESS_KEY_ID": "fixture-id",
            "ALIYUN_OSS_ACCESS_KEY_SECRET": "fixture-secret",
            "ALIYUN_OSS_PREFIX": "hermes",
        }
        self.calls = []

    def run_upload(self, *, promote=None, failed_key=None, raise_key=None) -> None:
        module = types.ModuleType("oss2")
        module.Auth = mock.Mock(return_value="fixture-auth")
        def upload(key, path, **kwargs):
            self.assertTrue(Path(path).is_file(), path)
            self.calls.append((key, kwargs))
            if key == raise_key:
                raise RuntimeError("simulated network failure")
            return types.SimpleNamespace(status=503 if key == failed_key else 200)
        module.Bucket = mock.Mock(return_value=types.SimpleNamespace(put_object_from_file=upload))
        env = dict(self.env)
        if promote is not None:
            env["UPDATE_ROOT_LATEST"] = promote
        previous = Path.cwd()
        try:
            os.chdir(self.root)
            with mock.patch.dict(os.environ, env, clear=True), mock.patch.dict(sys.modules, {"oss2": module}), contextlib.redirect_stdout(io.StringIO()):
                exec(compile(upload_code(), str(WORKFLOW) + ":mock-upload", "exec"), {"__name__": "__main__"})
        finally:
            os.chdir(previous)

    def test_dispatch_input_is_explicit_boolean_false_by_default(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        declaration = text.split("      update_root_latest:\n", 1)[1].split("      hermes_extras:\n", 1)[0]
        self.assertIn("type: boolean", declaration)
        self.assertIn("default: false", declaration)
        self.assertIn("github.event_name == 'workflow_dispatch' && inputs.update_root_latest && 'true' || 'false'", text)

    def test_release_run_checks_tests_and_ps51_before_building_wheelhouse(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        build = text.index("      - name: Build wheelhouse")
        self.assertLess(text.index('python -m unittest discover -s tests -p "test_*.py"'), build)
        self.assertLess(text.index("[System.Management.Automation.Language.Parser]::ParseFile"), build)
        self.assertIn("shell: powershell", text[:build])

    def test_default_upload_writes_only_version_scoped_metadata_after_artifacts(self) -> None:
        self.run_upload()
        keys = [key for key, _ in self.calls]
        self.assertEqual(keys, [f"{VERSION_PREFIX}/hermes-offline-installer-win-x64.zip",
                                f"{VERSION_PREFIX}/hermes-offline-installer-win-x64.zip.sha256",
                                f"{VERSION_PREFIX}/latest.json"])
        self.assertEqual(self.calls[-1][1], {"headers": {"Content-Type": "application/json"}})
        self.assertNotIn("hermes/latest.json", keys)

    def test_only_exact_true_promotes_root_after_successful_version_metadata(self) -> None:
        self.run_upload(promote="true")
        keys = [key for key, _ in self.calls]
        self.assertEqual(keys[-2:], [f"{VERSION_PREFIX}/latest.json", "hermes/latest.json"])
        self.calls.clear()
        self.run_upload(promote="True")
        self.assertNotIn("hermes/latest.json", [key for key, _ in self.calls])

    def test_failed_artifact_prevents_both_metadata_uploads(self) -> None:
        with self.assertRaisesRegex(SystemExit, "Upload failed for"):
            self.run_upload(promote="true", failed_key=f"{VERSION_PREFIX}/hermes-offline-installer-win-x64.zip")
        self.assertFalse(any(key.endswith("/latest.json") for key, _ in self.calls))

    def test_artifact_exception_prevents_both_metadata_uploads(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "simulated network failure"):
            self.run_upload(promote="true", raise_key=f"{VERSION_PREFIX}/hermes-offline-installer-win-x64.zip")
        self.assertFalse(any(key.endswith("/latest.json") for key, _ in self.calls))

    def test_failed_version_metadata_prevents_root_promotion(self) -> None:
        with self.assertRaisesRegex(SystemExit, "Upload failed"):
            self.run_upload(promote="true", failed_key=f"{VERSION_PREFIX}/latest.json")
        keys = [key for key, _ in self.calls]
        self.assertIn(f"{VERSION_PREFIX}/latest.json", keys)
        self.assertNotIn("hermes/latest.json", keys)

    def test_failed_root_promotion_is_reported_as_failure(self) -> None:
        with self.assertRaisesRegex(SystemExit, "hermes/latest.json"):
            self.run_upload(promote="true", failed_key="hermes/latest.json")

    def test_missing_credentials_cause_no_upload(self) -> None:
        del self.env["ALIYUN_OSS_ACCESS_KEY_ID"]
        with self.assertRaisesRegex(SystemExit, "Missing OSS environment variables"):
            self.run_upload()
        self.assertEqual(self.calls, [])


if __name__ == "__main__":
    unittest.main()
