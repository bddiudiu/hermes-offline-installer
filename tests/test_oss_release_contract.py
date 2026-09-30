"""Run the workflow's upload code against a fake SDK; never contact OSS."""
from __future__ import annotations

import contextlib
import io
import hashlib
import json
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


sys.path.insert(0, str(ROOT / "scripts"))
import upload_oss as publisher


class OSSReleaseContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        upload = self.root / "upload"
        upload.mkdir()
        archive = upload / "hermes-offline-installer-win-x64.zip"
        archive.write_bytes(b"verified fixture archive contents")
        (upload / (archive.name + ".sha256")).write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + "  " + archive.name + "\n")
        (upload / "latest.json").write_text(json.dumps({"editions": {"en": {
            "version": "0.21.4-123", "base_url": "https://fixture.invalid/" + VERSION_PREFIX + "/" + archive.name}}}))
        self.env = {
            "ALIYUN_OSS_BUCKET": "fixture-bucket",
            "ALIYUN_OSS_ENDPOINT": "fixture.invalid",
            "ALIYUN_OSS_ACCESS_KEY_ID": "fixture-id",
            "ALIYUN_OSS_ACCESS_KEY_SECRET": "fixture-secret",
            "ALIYUN_OSS_PREFIX": "hermes",
        }
        self.calls = []

    def run_upload(self, *, promote=None, failed_key=None, raise_key=None, corrupt_key=None,
                   part_size=publisher.PART_SIZE, fail_part_once=False, budget=None):
        self.events = []
        self.objects = {}
        self.part_attempts = {}
        pending = {}
        fail_once = [fail_part_once]
        def status(key):
            if key == raise_key:
                raise RuntimeError("secret-bearing simulated network failure")
            return 503 if key == failed_key else 200
        def put(key, data, **kwargs):
            self.calls.append((key, kwargs))
            self.events.append(("put", key))
            code = status(key)
            if code == 200:
                self.objects[key] = bytes(data)
                kwargs["progress_callback"](len(data), len(data))
            return types.SimpleNamespace(status=code)
        def init(key, **kwargs):
            self.events.append(("init", key))
            pending[key] = {}
            return types.SimpleNamespace(status=200, upload_id="private-upload-id")
        def part(key, upload_id, number, data, **kwargs):
            self.events.append(("part", key, number, bytes(data)))
            self.part_attempts[(key, number)] = self.part_attempts.get((key, number), 0) + 1
            if fail_once[0]:
                fail_once[0] = False
                raise TimeoutError("secret-bearing timeout")
            code = status(key)
            pending[key][number] = bytes(data)
            kwargs["progress_callback"](len(data), len(data))
            return types.SimpleNamespace(status=code, etag=str(number), crc=0)
        def complete(key, upload_id, parts):
            self.calls.append((key, {}))
            self.events.append(("complete", key))
            code = status(key)
            if code == 200:
                self.objects[key] = b"".join(pending[key][item.part_number] for item in parts)
            return types.SimpleNamespace(status=code)
        def abort(key, upload_id):
            self.events.append(("abort", key))
            return types.SimpleNamespace(status=204)
        def head(key):
            self.events.append(("head", key))
            return types.SimpleNamespace(status=200, content_length=len(self.objects[key]), etag="stable-etag")
        def get(key, *, byte_range, headers):
            self.assertEqual(headers, {"If-Match": '"stable-etag"'})
            self.events.append(("get", key, byte_range))
            start, end = byte_range
            data = self.objects[key][start:end + 1]
            if key == corrupt_key and start == 0:
                data = bytes([data[0] ^ 1]) + data[1:]
            stream = io.BytesIO(data)
            return types.SimpleNamespace(status=206, read=stream.read, close=stream.close)
        self.bucket = types.SimpleNamespace(put_object=put, init_multipart_upload=init, upload_part=part,
                                           complete_multipart_upload=complete, abort_multipart_upload=abort,
                                           head_object=head, get_object=get)
        def part_info(number, etag, **kwargs):
            return types.SimpleNamespace(part_number=number, etag=etag, **kwargs)
        self.output = io.StringIO()
        with contextlib.redirect_stdout(self.output):
            publisher.publish_directory(self.bucket, part_info, self.root / "upload", "hermes", VERSION_PREFIX,
                                        promote=promote == "true", part_size=part_size,
                                        sleep=lambda _: None, budget=budget)

    def test_build_release_and_oss_share_one_validated_windows_workspace(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertNotIn("actions/upload-artifact@", text)
        self.assertNotIn("actions/download-artifact@", text)
        self.assertEqual(text.count("    runs-on:"), 1)
        self.assertIn("    runs-on: windows-latest", text)
        self.assertIn("          fetch-depth: 0", text)
        self.assertIn("          files: dist/*", text)
        self.assertIn("          cp dist/* upload/", text)
        self.assertIn("          target_commitish: ${{ github.sha }}", text)
        self.assertIn("Packaging commit: ${{ github.sha }}", text)
        self.assertIn("          make_latest: ${{ github.event_name == 'workflow_dispatch' && inputs.update_root_latest && 'true' || 'false' }}", text)
        order = [text.index(name) for name in (
            "      - name: Validate upgrade and packaging contracts",
            "      - name: Parse Windows PowerShell 5.1 scripts",
            "      - name: Test Windows PowerShell 5.1 upgrade functions",
            "      - name: Build wheelhouse",
            "      - name: Build bundle",
            "      - name: Create release",
            "      - name: Upload files to OSS",
        )]
        self.assertEqual(order, sorted(order))
        # Publishing credentials are scoped to the upload step, never upstream build hooks.
        before_upload, uploader = text.split("      - name: Upload files to OSS\n", 1)
        self.assertNotIn("secrets.ALIYUN_OSS_ACCESS_KEY", before_upload)
        self.assertIn("secrets.ALIYUN_OSS_ACCESS_KEY_ID", uploader)
        self.assertIn("secrets.ALIYUN_OSS_ACCESS_KEY_SECRET", uploader)

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
        self.assertEqual(self.calls[-1][1]["headers"]["Content-Type"], "application/json")
        self.assertNotIn("hermes/latest.json", keys)

    def test_only_exact_true_promotes_root_after_successful_version_metadata(self) -> None:
        self.run_upload(promote="true")
        keys = [key for key, _ in self.calls]
        self.assertEqual(keys[-2:], [f"{VERSION_PREFIX}/latest.json", "hermes/latest.json"])
        self.calls.clear()
        self.run_upload(promote="True")
        self.assertNotIn("hermes/latest.json", [key for key, _ in self.calls])

    def test_failed_artifact_prevents_both_metadata_uploads(self) -> None:
        with self.assertRaisesRegex(publisher.UploadError, "bounded retries"):
            self.run_upload(promote="true", failed_key=f"{VERSION_PREFIX}/hermes-offline-installer-win-x64.zip")
        self.assertFalse(any(key.endswith("/latest.json") for key, _ in self.calls))

    def test_artifact_exception_prevents_both_metadata_uploads(self) -> None:
        with self.assertRaisesRegex(publisher.UploadError, "bounded retries"):
            self.run_upload(promote="true", raise_key=f"{VERSION_PREFIX}/hermes-offline-installer-win-x64.zip")
        self.assertFalse(any(key.endswith("/latest.json") for key, _ in self.calls))

    def test_failed_version_metadata_prevents_root_promotion(self) -> None:
        with self.assertRaisesRegex(publisher.UploadError, "bounded retries"):
            self.run_upload(promote="true", failed_key=f"{VERSION_PREFIX}/latest.json")
        keys = [key for key, _ in self.calls]
        self.assertIn(f"{VERSION_PREFIX}/latest.json", keys)
        self.assertNotIn("hermes/latest.json", keys)

    def test_failed_root_promotion_is_reported_as_failure(self) -> None:
        with self.assertRaisesRegex(publisher.UploadError, "bounded retries"):
            self.run_upload(promote="true", failed_key="hermes/latest.json")

    def test_missing_credentials_cause_no_upload(self) -> None:
        with mock.patch.dict(os.environ, {}, clear=True), contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(publisher.main(["--directory", str(self.root / "upload"), "--path-prefix", VERSION_PREFIX]), 1)
        self.assertIn("Missing OSS", output.getvalue())
        self.assertEqual(self.calls, [])

    def test_multipart_retries_same_part_bytes_and_verifies_every_byte(self):
        self.run_upload(part_size=16, fail_part_once=True)
        archive_key = VERSION_PREFIX + "/hermes-offline-installer-win-x64.zip"
        attempts = [event for event in self.events if event[:3] == ("part", archive_key, 1)]
        self.assertEqual(len(attempts), 2)
        self.assertEqual(attempts[0][3], attempts[1][3])
        self.assertEqual(self.objects[archive_key], (self.root / "upload" / "hermes-offline-installer-win-x64.zip").read_bytes())
        first_metadata = next(i for i, event in enumerate(self.events) if event[0] == "init" and event[1].endswith("/latest.json"))
        last_archive_read = max(i for i, event in enumerate(self.events) if event[0] == "get" and event[1] == archive_key)
        self.assertLess(last_archive_read, first_metadata)
        self.assertIn("SHA-256 matched", self.output.getvalue())
        self.assertNotIn("secret-bearing", self.output.getvalue())
        self.assertNotIn("private-upload-id", self.output.getvalue())

    def test_multipart_failure_aborts_and_never_publishes_metadata(self):
        key = VERSION_PREFIX + "/hermes-offline-installer-win-x64.zip"
        with self.assertRaises(publisher.UploadError):
            self.run_upload(part_size=16, failed_key=key)
        self.assertIn(("abort", key), self.events)
        self.assertFalse(any(event[1].endswith("/latest.json") for event in self.events))
        self.assertEqual(self.part_attempts[(key, 1)], 3)

    def test_readback_checksum_mismatch_blocks_all_metadata(self):
        with self.assertRaisesRegex(publisher.UploadError, "SHA-256"):
            self.run_upload(corrupt_key=VERSION_PREFIX + "/hermes-offline-installer-win-x64.zip")
        self.assertFalse(any(key.endswith("/latest.json") for key, _ in self.calls))

    def test_local_checksum_mismatch_causes_zero_network_calls(self):
        (self.root / "upload" / "hermes-offline-installer-win-x64.zip").write_bytes(b"tampered")
        with self.assertRaisesRegex(publisher.UploadError, "Local archive checksum"):
            self.run_upload()
        self.assertEqual(self.events, [])

    def test_time_budget_blocks_operations_before_network(self):
        times = iter([0, 100])
        budget = publisher.Budget(seconds=1, clock=lambda: next(times))
        with self.assertRaisesRegex(publisher.UploadError, "time budget"):
            self.run_upload(budget=budget)
        self.assertEqual(self.events, [])

    def test_workflow_upload_is_unbuffered_with_independent_hard_budget(self):
        text = WORKFLOW.read_text()
        step = text.split("      - name: Upload files to OSS\n", 1)[1]
        self.assertIn("timeout-minutes: 20", step)
        self.assertIn("python -u scripts/upload_oss.py", step)
        self.assertEqual(publisher.SOCKET_TIMEOUT, (15, 45))
        self.assertLess(publisher.BUDGET_SECONDS, 20 * 60)
        script = (ROOT / "scripts/upload_oss.py").read_text()
        self.assertIn("threading.Timer(BUDGET_SECONDS, expire)", script)
        self.assertIn("os._exit(124)", script)
        self.assertIn("stop.wait(20)", script)


if __name__ == "__main__":
    unittest.main()
