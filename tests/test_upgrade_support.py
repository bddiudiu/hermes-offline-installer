from __future__ import annotations

import contextlib
import hashlib
import copy
import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import upgrade_support as upgrade  # noqa: E402


class BundleValidationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.bundle = Path(self.temp.name) / "new bundle"
        self.bundle.mkdir()
        files = {
            "manifest.json": json.dumps({
                "kind": "bundle", "target_platform": "win-x64",
                "hermes_install_mode": "editable-source", "hermes_version": "0.21.4",
                "wheelhouse": {"hermes_version": "0.21.4"},
            }),
            "hermes-agent/pyproject.toml": '[project]\nname = "hermes-agent"\nversion = "0.21.4"\n',
            "hermes-agent/hermes_cli/main.py": "# source fixture\n",
            "hermes-agent/tools/skills_sync.py": "# source fixture\n",
            "hermes-resources/web_dist/index.html": "<html></html>\n",
            "hermes-resources/tui_dist/dist/entry.js": "// fixture\n",
            "wheelhouse/requirements.txt": "# bundled dependencies\nexample==1.0\n",
            "wheelhouse/hermes-editable-requirement.txt": ".[all,web]\n",
            "scripts/upgrade_support.py": "# fixture\n",
            "installers/upgrade.ps1": "# fixture\n",
            "runtime/python/python.exe": "fixture, never executed\n",
        }
        for relative, content in files.items():
            path = self.bundle / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
        self.refresh_inventory()

    def refresh_inventory(self) -> None:
        files = {
            path.relative_to(self.bundle).as_posix(): upgrade.digest(path)
            for path in self.bundle.rglob("*")
            if path.is_file() and path != self.bundle / "upgrade-manifest.json"
        }
        self.write_inventory({"schema": 1, "files": files})

    def write_inventory(self, data: dict) -> None:
        (self.bundle / "upgrade-manifest.json").write_text(json.dumps(data), encoding="utf-8")

    def test_accepts_complete_verified_bundle(self) -> None:
        result = upgrade.verify_bundle(self.bundle, "0.19.1")
        self.assertEqual(result["version"], "0.21.4")
        self.assertGreater(result["files"], 0)

    def test_same_version_requires_explicit_rebuild_flag(self) -> None:
        with self.assertRaisesRegex(upgrade.UpgradeError, "AllowSameVersion"):
            upgrade.verify_bundle(self.bundle, "0.21.4")
        self.assertEqual(upgrade.verify_bundle(self.bundle, "0.21.4", True)["version"], "0.21.4")

    def test_rejects_downgrade_even_with_same_version_flag(self) -> None:
        with self.assertRaisesRegex(upgrade.UpgradeError, "Downgrades"):
            upgrade.verify_bundle(self.bundle, "0.22.0", True)

    def test_accepts_stable_numeric_versions_only(self) -> None:
        self.assertEqual(upgrade.version_tuple("0.21.4"), upgrade.version_tuple("0.21.4.0"))
        self.assertEqual(upgrade.version_tuple("0.21"), upgrade.version_tuple("0.21.0"))
        self.assertLess(upgrade.version_tuple("0.21.4"), upgrade.version_tuple("0.22.0"))
        for value in ("v0.21.4", "0.21.4rc1", "latest", "0", "1.2.3.4.5", "../0.21"):
            with self.subTest(version=value), self.assertRaises(upgrade.UpgradeError):
                upgrade.version_tuple(value)

    def test_rejects_non_windows_platform_or_unexpected_install_mode(self) -> None:
        manifest_path = self.bundle / "manifest.json"
        original = json.loads(manifest_path.read_text())
        for field, value in (("kind", "wheelhouse"), ("target_platform", "linux-x64"),
                             ("hermes_install_mode", "wheel")):
            with self.subTest(field=field):
                manifest = {**original, field: value}
                manifest_path.write_text(json.dumps(manifest))
                self.refresh_inventory()
                with self.assertRaises(upgrade.UpgradeError):
                    upgrade.verify_bundle(self.bundle, "0.19.1")

    def test_rejects_source_or_wheelhouse_version_mismatch(self) -> None:
        source = self.bundle / "hermes-agent" / "pyproject.toml"
        source.write_text('[project]\nversion = "0.20.0"\n')
        self.refresh_inventory()
        with self.assertRaisesRegex(upgrade.UpgradeError, "Source and bundle"):
            upgrade.verify_bundle(self.bundle, "0.19.1")
        source.write_text('[project]\nversion = "0.21.4"\n')
        manifest_path = self.bundle / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["wheelhouse"]["hermes_version"] = "0.20.0"
        manifest_path.write_text(json.dumps(manifest))
        self.refresh_inventory()
        with self.assertRaisesRegex(upgrade.UpgradeError, "Wheelhouse and bundle"):
            upgrade.verify_bundle(self.bundle, "0.19.1")

    def test_rejects_changed_missing_and_unlisted_files(self) -> None:
        path = self.bundle / "hermes-agent" / "hermes_cli" / "main.py"
        original = path.read_bytes()
        path.write_bytes(b"changed")
        with self.assertRaisesRegex(upgrade.UpgradeError, "checksum mismatch"):
            upgrade.verify_bundle(self.bundle, "0.19.1")
        path.unlink()
        with self.assertRaisesRegex(upgrade.UpgradeError, "inventory differs"):
            upgrade.verify_bundle(self.bundle, "0.19.1")
        path.write_bytes(original)
        (self.bundle / "unexpected.txt").write_text("unlisted")
        with self.assertRaisesRegex(upgrade.UpgradeError, "inventory differs"):
            upgrade.verify_bundle(self.bundle, "0.19.1")

    def test_only_root_checksum_manifest_is_excluded_from_inventory(self) -> None:
        nested = self.bundle / "hermes-agent" / "upgrade-manifest.json"
        nested.write_text("unlisted nested file")
        with self.assertRaisesRegex(upgrade.UpgradeError, "inventory differs"):
            upgrade.verify_bundle(self.bundle, "0.19.1")
        self.refresh_inventory()
        self.assertEqual(upgrade.verify_bundle(self.bundle, "0.19.1")["version"], "0.21.4")

    def test_rejects_missing_required_layout_even_if_inventory_matches(self) -> None:
        (self.bundle / "hermes-agent" / "tools" / "skills_sync.py").unlink()
        self.refresh_inventory()
        with self.assertRaisesRegex(upgrade.UpgradeError, "Incomplete"):
            upgrade.verify_bundle(self.bundle, "0.19.1")

    def test_rejects_malformed_inventory_and_unsafe_paths(self) -> None:
        for payload in ({"schema": 2, "files": {"x": "a" * 64}},
                        {"schema": 1, "files": {}},
                        {"schema": 1, "files": {"../outside": "a" * 64}},
                        {"schema": 1, "files": {"C:\\outside": "a" * 64}}):
            with self.subTest(payload=payload):
                self.write_inventory(payload)
                with self.assertRaises(upgrade.UpgradeError):
                    upgrade.verify_bundle(self.bundle, "0.19.1")

    def test_rejects_invalid_digest(self) -> None:
        inventory_path = self.bundle / "upgrade-manifest.json"
        data = json.loads(inventory_path.read_text())
        data["files"]["manifest.json"] = "not-a-sha256"
        self.write_inventory(data)
        with self.assertRaisesRegex(upgrade.UpgradeError, "Unsafe checksum"):
            upgrade.verify_bundle(self.bundle, "0.19.1")

    def test_rejects_bundle_links(self) -> None:
        link = self.bundle / "linked-file"
        try:
            link.symlink_to(self.bundle / "manifest.json")
        except (OSError, NotImplementedError):
            self.skipTest("Creating symlinks is not supported for this test account")
        with self.assertRaisesRegex(upgrade.UpgradeError, "links are unsupported"):
            upgrade.verify_bundle(self.bundle, "0.19.1")

    def test_rejects_network_paths_and_pip_options_in_requirements(self) -> None:
        requirements = self.bundle / "wheelhouse" / "requirements.txt"
        for value in ("https://example.test/payload.whl", "pkg @ file:C:/payload.whl",
                      "--index-url=https://example.test", "../payload.whl", "C:\\payload.whl"):
            with self.subTest(value=value):
                requirements.write_text(value)
                self.refresh_inventory()
                with self.assertRaisesRegex(upgrade.UpgradeError, "Offline requirements"):
                    upgrade.verify_bundle(self.bundle, "0.19.1")

    def test_rejects_escaping_editable_requirement(self) -> None:
        requirement = self.bundle / "wheelhouse" / "hermes-editable-requirement.txt"
        for value in ("../other", ".[web] --extra-index-url x", ".[../bad]", "git+https://example.test/x"):
            with self.subTest(value=value):
                requirement.write_text(value)
                self.refresh_inventory()
                with self.assertRaisesRegex(upgrade.UpgradeError, "Unsafe editable"):
                    upgrade.verify_bundle(self.bundle, "0.19.1")


class HomeAndMigrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.backup = self.root / "backup"
        self.home.mkdir()
        self.backup.mkdir()
        config_reader = mock.patch.object(upgrade, "read_config", return_value={})
        # Tests exercising the YAML parser explicitly stop this stdlib-only default.
        self.default_config_reader = config_reader
        config_reader.start()
        self.addCleanup(config_reader.stop)
        self.config = {
            "model": {"default": "custom-favorite", "provider": "custom:my-provider"},
            "models": ["custom-favorite", {"name": "backup", "provider": "other"}],
            "providers": {"my-provider": {"models": {"a": "remote-a", "b": "remote-b"}}},
            "other": {"setting": True},
        }

    def fake_migration_modules(self, migration):
        hermes_config = types.ModuleType("hermes_cli.config")
        hermes_config.migrate_config = migration
        dotenv = types.ModuleType("dotenv")
        dotenv.dotenv_values = lambda path: {"EXISTING_KEY": "same-secret"}
        return mock.patch.dict(sys.modules, {"hermes_cli.config": hermes_config, "dotenv": dotenv})

    def test_inspection_rejects_external_config_env_and_profile_selectors(self) -> None:
        dotenv = types.ModuleType("dotenv")
        dotenv.dotenv_values = mock.Mock(return_value={})
        with mock.patch.dict(sys.modules, {"dotenv": dotenv}), mock.patch.object(upgrade.importlib.metadata, "version", return_value="0.21.4"):
            for selector in ("HERMES_CONFIG", "HERMES_ENV", "HERMES_PROFILE", "HERMES_PROFILE_NAME"):
                with self.subTest(selector=selector, source="process"), mock.patch.dict(os.environ, {selector: "external"}, clear=True):
                    with self.assertRaisesRegex(upgrade.UpgradeError, "reviewed deployment adapter"):
                        upgrade.inspect_home(self.home)
                dotenv.dotenv_values.return_value = {selector: "external"}
                with self.subTest(selector=selector, source="dotenv"), mock.patch.dict(os.environ, {}, clear=True):
                    with self.assertRaisesRegex(upgrade.UpgradeError, "reviewed deployment adapter"):
                        upgrade.inspect_home(self.home)
                dotenv.dotenv_values.return_value = {}
            with mock.patch.dict(os.environ, {}, clear=True):
                dotenv.dotenv_values.return_value = {"HERMES_HOME": str(self.root / "outside")}
                with self.assertRaisesRegex(upgrade.UpgradeError, "outside the backed-up profile"):
                    upgrade.inspect_home(self.home)
                dotenv.dotenv_values.return_value = {"HERMES_HOME": str(self.home)}
                self.assertEqual(upgrade.inspect_home(self.home)["homes"], [str(self.home)])

    def test_protected_config_preserves_lists_maps_and_default_without_normalizing(self) -> None:
        protected = upgrade.protected_config(self.config)
        self.assertEqual(set(protected), {"model", "models", "providers"})
        self.assertEqual(protected["models"], self.config["models"])
        self.assertIsInstance(protected["models"], list)
        self.assertIsInstance(protected["providers"]["my-provider"]["models"], dict)
        self.assertEqual(upgrade.protected_config({"unrelated": True}), {})

    @unittest.skipUnless(importlib.util.find_spec("yaml"), "PyYAML is required for config parser tests")
    def test_config_reader_handles_bom_and_rejects_duplicate_keys(self) -> None:
        self.default_config_reader.stop()
        config_path = self.home / "config.yaml"
        config_path.write_text("model:\n  default: chosen\n", encoding="utf-8-sig")
        self.assertEqual(upgrade.read_config(self.home), {"model": {"default": "chosen"}})
        for value in ("model: one\nmodel: two\n", "providers:\n  custom: one\n  custom: two\n"):
            config_path.write_text(value)
            with self.assertRaisesRegex(upgrade.UpgradeError, "Duplicate config key"):
                upgrade.read_config(self.home)
        config_path.write_text("- unsupported-root-list\n")
        with self.assertRaisesRegex(upgrade.UpgradeError, "must be a mapping"):
            upgrade.read_config(self.home)

    def test_named_profiles_are_enumerated_but_cannot_be_selected_as_root(self) -> None:
        for relative in ("profiles/work/config.yaml", "profiles/personal/config.yaml",
                         "profiles/not-a-profile/readme.txt"):
            path = self.home / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("{}")
        self.assertEqual(upgrade.home_profiles(self.home), [self.home, self.home / "profiles/personal", self.home / "profiles/work"])
        with self.assertRaisesRegex(upgrade.UpgradeError, "named profile was selected"):
            upgrade.home_profiles(self.home / "profiles/work")

    def test_old_named_profile_topology_requires_review(self) -> None:
        profile = self.home / "profiles" / "work"
        profile.mkdir(parents=True)
        (profile / "config.yaml").write_text("{}")
        with mock.patch.object(upgrade, "read_config", return_value={}), mock.patch.object(upgrade.importlib.metadata, "version", return_value="0.21.3"):
            with self.assertRaisesRegex(upgrade.UpgradeError, "topology review"):
                upgrade.inspect_home(self.home)
        with mock.patch.object(upgrade, "read_config", return_value={}), mock.patch.object(upgrade.importlib.metadata, "version", return_value="0.21.4"):
            self.assertEqual(len(upgrade.inspect_home(self.home)["homes"]), 2)

    def test_standalone_and_multiplex_opt_out_require_review(self) -> None:
        for gateway in ({"standalone": True}, {"multiplex_profiles": False}, "unexpected"):
            with self.subTest(gateway=gateway), mock.patch.object(upgrade, "read_config", return_value={"gateway": gateway}):
                with self.assertRaises(upgrade.UpgradeError):
                    upgrade.inspect_home(self.home)

    def test_official_migration_is_noninteractive_and_preserves_model_shapes(self) -> None:
        migration = mock.Mock(return_value={"warnings": []})
        after = {**copy.deepcopy(self.config), "new_official_default": True}
        with self.fake_migration_modules(migration), mock.patch.object(upgrade, "read_config", side_effect=[self.config, after]):
            self.assertEqual(upgrade.migrate(self.home, self.backup), {"migrated": True})
        migration.assert_called_once_with(interactive=False, quiet=True)

    def test_migration_rejects_changed_default_list_or_provider_map(self) -> None:
        for field in ("model", "models", "providers"):
            with self.subTest(field=field):
                after = copy.deepcopy(self.config)
                after[field] = "replacement"
                with self.fake_migration_modules(mock.Mock(return_value={})), mock.patch.object(upgrade, "read_config", side_effect=[self.config, after]):
                    with self.assertRaisesRegex(upgrade.UpgradeError, "model/provider selections"):
                        upgrade.migrate(self.home, self.backup)

    def test_migration_rejects_warnings_without_logging_their_contents(self) -> None:
        secret = "private-key-should-never-appear"
        def migration(**kwargs):
            print(secret)
            print(secret, file=sys.stderr)
            return {"warnings": [secret]}
        stdout, stderr = io.StringIO(), io.StringIO()
        with self.fake_migration_modules(migration), mock.patch.object(upgrade, "read_config", return_value=self.config), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            with self.assertRaisesRegex(upgrade.UpgradeError, "reported warnings"):
                upgrade.migrate(self.home, self.backup)
        self.assertNotIn(secret, stdout.getvalue() + stderr.getvalue())

    def test_migration_rejects_changed_existing_env_value(self) -> None:
        with self.fake_migration_modules(mock.Mock(return_value={})), mock.patch.object(upgrade, "read_config", return_value=self.config), mock.patch.object(upgrade, "resolved_env", side_effect=[{"EXISTING_KEY": "before"}, {"EXISTING_KEY": "after"}]):
            with self.assertRaisesRegex(upgrade.UpgradeError, "existing .env value"):
                upgrade.migrate(self.home, self.backup)

    @unittest.skipUnless(importlib.util.find_spec("dotenv"), "python-dotenv is required for .env parser tests")
    def test_env_value_comparison_allows_equivalent_formatting(self) -> None:
        (self.backup / ".env").write_text('EXISTING_KEY="same-secret"\nEMPTY=\n')
        (self.home / ".env").write_text("# officially reformatted\nEXISTING_KEY='same-secret'\nEMPTY=\n")
        self.assertEqual(upgrade.resolved_env(self.home), upgrade.resolved_env(self.backup))
        (self.home / ".env").write_text("EXISTING_KEY=changed-secret\nEMPTY=\n")
        self.assertNotEqual(upgrade.resolved_env(self.home), upgrade.resolved_env(self.backup))

    def test_startup_validation_rejects_changed_model_and_env_values(self) -> None:
        with self.fake_migration_modules(mock.Mock(return_value={})), mock.patch.object(upgrade, "read_config", side_effect=[{"model": "changed"}, {"model": "original"}]):
            with self.assertRaisesRegex(upgrade.UpgradeError, "Startup changed model/provider"):
                upgrade.check_preserved(self.home, self.backup)
        dotenv = types.ModuleType("dotenv")
        dotenv.dotenv_values = lambda path: {"KEY": "original" if path.parent == self.backup else "changed"}
        with mock.patch.dict(sys.modules, {"dotenv": dotenv}):
            with self.assertRaisesRegex(upgrade.UpgradeError, "Startup changed an existing .env"):
                upgrade.check_preserved(self.home, self.backup)

    def test_user_asset_changes_are_rejected_but_runtime_db_changes_are_allowed(self) -> None:
        for relative in ("skills/custom/SKILL.md", "plugins/custom.py", "memories/note.txt", "SOUL.md", "USER.md", "AGENTS.md", "state.db", "state.db-wal", "state.db-shm"):
            for root in (self.home, self.backup):
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("original")
        for relative in ("state.db", "state.db-wal", "state.db-shm"):
            (self.home / relative).write_text("legitimate runtime update")
        self.assertTrue(upgrade.check_preserved(self.home, self.backup)["user_assets_preserved"])
        skill = self.home / "skills/custom/SKILL.md"
        skill.write_text("unexpected change")
        with self.assertRaisesRegex(upgrade.UpgradeError, "user-owned asset changed"):
            upgrade.check_preserved(self.home, self.backup)
        skill.unlink()
        with self.assertRaises(upgrade.UpgradeError):
            upgrade.check_preserved(self.home, self.backup)


class BundledSkillPreservationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.backup = self.root / "transaction/home"
        self.home = self.root / "live-home"
        self.resources = self.root / "transaction/runtime/hermes-resources/skills"
        self.backup.mkdir(parents=True)
        self.home.mkdir()
        self.resources.mkdir(parents=True)
        for name in ("pristine", "modified", "extra-file", "incomplete"):
            for base in (self.backup / "skills", self.resources):
                skill = base / name
                skill.mkdir(parents=True)
                (skill / "SKILL.md").write_text("# original bundled skill\n")
                (skill / "helper.txt").write_text("original helper")
        (self.backup / "skills/modified/SKILL.md").write_text("user edit")
        (self.backup / "skills/extra-file/user-note.txt").write_text("user extra")
        (self.backup / "skills/incomplete/helper.txt").unlink()
        custom = self.backup / "skills/custom"
        custom.mkdir()
        (custom / "SKILL.md").write_text("custom skill")
        shutil.copytree(self.backup / "skills", self.home / "skills")

    def test_only_wholly_pristine_bundled_skills_are_exempt(self) -> None:
        self.assertEqual(upgrade.pristine_bundled_skills(self.backup), {self.backup / "skills/pristine"})
        self.assertEqual(upgrade.pristine_bundled_skills(self.home), set())

    def test_pristine_skill_can_sync_but_custom_or_modified_skill_cannot_change(self) -> None:
        dotenv = types.ModuleType("dotenv")
        dotenv.dotenv_values = lambda path: {}
        (self.home / "skills/pristine/SKILL.md").write_text("new upstream bundled version")
        with mock.patch.dict(sys.modules, {"dotenv": dotenv}), mock.patch.object(upgrade, "read_config", return_value={}):
            self.assertTrue(upgrade.check_preserved(self.home, self.backup)["user_assets_preserved"])
            for name in ("modified", "custom", "extra-file", "incomplete"):
                with self.subTest(name=name):
                    path = self.home / "skills" / name / "SKILL.md"
                    original = path.read_text()
                    path.write_text("overwritten user asset")
                    with self.assertRaisesRegex(upgrade.UpgradeError, "user-owned asset changed"):
                        upgrade.check_preserved(self.home, self.backup)
                    path.write_text(original)

    def test_official_sync_is_quiet_and_hides_upstream_output(self) -> None:
        module = types.ModuleType("tools.skills_sync")
        def official_sync(**kwargs):
            self.assertEqual(kwargs, {"quiet": True})
            print("private upstream output")
            print("private stderr", file=sys.stderr)
            return {"total_bundled": 2, "user_modified": ["custom"]}
        module.sync_skills = official_sync
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.dict(sys.modules, {"tools.skills_sync": module}), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            self.assertEqual(upgrade.sync_skills(), {"skills_synced": True, "user_modified_kept": 1})
        self.assertEqual(stdout.getvalue() + stderr.getvalue(), "")
        module.sync_skills = mock.Mock(return_value={"total_bundled": 0})
        with mock.patch.dict(sys.modules, {"tools.skills_sync": module}):
            with self.assertRaisesRegex(upgrade.UpgradeError, "no bundled skills"):
                upgrade.sync_skills()


class ModelConfigValidationTests(unittest.TestCase):
    def config(self, provider_models):
        return {"model": {"default": "chosen", "provider": "custom:my-provider"},
                "providers": {"my-provider": {"models": provider_models}}}

    def test_accepts_model_lists_and_maps_without_requiring_qwen_or_zhan_ai(self) -> None:
        for models in (["chosen", "fallback"], {"chosen": "remote-id", "fallback": {"context": 8192}}, {}):
            with self.subTest(models=models):
                config = self.config(models)
                original = copy.deepcopy(config)
                self.assertEqual(upgrade.validate_model_config(config), {"model_config_valid": True})
                self.assertEqual(config, original)
        self.assertTrue(upgrade.validate_model_config({"model": {"default": "chosen", "provider": "openai"}})["model_config_valid"])

    def test_rejects_missing_selection_and_invalid_provider_shapes(self) -> None:
        cases = [ {}, {"model": "chosen"}, {"model": {"default": "", "provider": "openai"}},
                  {"model": {"default": "chosen", "provider": ""}},
                  {"model": {"default": "chosen", "provider": "custom:missing"}},
                  {**self.config([]), "providers": []},
                  self.config("one-string-is-not-a-list"), self.config([{"id": "chosen"}]),
                  self.config(["chosen", ""]), self.config({1: "invalid numeric key"}) ]
        for config in cases:
            with self.subTest(config=config), self.assertRaises(upgrade.UpgradeError):
                upgrade.validate_model_config(config)


class ColdTreeVerificationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.backup = self.root / "backup"
        files = {
            "config.yaml": b"model: chosen\n",
            ".env": b"EXISTING_KEY=fixture-only\r\n",
            "state.db": b"SQLite fixture\x00",
            "state.db-wal": b"pending WAL bytes\x01",
            "state.db-shm": b"shared memory fixture\x02",
            "profiles/work/config.yaml": b"model: work-model\n",
            "profiles/work/state.db-wal": b"profile WAL bytes\x03",
            "profiles/work/sessions/conversation.jsonl": b'{"session":"fixture"}\n',
            "skills/custom/SKILL.md": b"# local skill\n",
            "plugins/local.py": b"# user code\n",
            "memories/user-note.txt": "用户笔记\n".encode(),
        }
        for relative, data in files.items():
            path = self.home / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        (self.home / "profiles/empty-directory").mkdir()
        shutil.copytree(self.home, self.backup)

    def test_full_home_fixture_round_trips_including_profiles_and_database_sidecars(self) -> None:
        self.assertEqual(upgrade.compare_trees(self.home, self.backup), {"identical": True})

    def test_rejects_missing_corrupt_or_extra_backup_files(self) -> None:
        sidecar = self.backup / "profiles/work/state.db-wal"
        original = sidecar.read_bytes()
        sidecar.write_bytes(b"truncated")
        with self.assertRaises(upgrade.UpgradeError):
            upgrade.compare_trees(self.home, self.backup)
        sidecar.unlink()
        with self.assertRaises(upgrade.UpgradeError):
            upgrade.compare_trees(self.home, self.backup)
        sidecar.write_bytes(original)
        (self.backup / "unexpected.db-wal").write_bytes(b"unexpected")
        with self.assertRaises(upgrade.UpgradeError):
            upgrade.compare_trees(self.home, self.backup)

    def test_missing_trees_cannot_be_reported_as_identical(self) -> None:
        empty = self.root / "empty"
        empty.mkdir()
        for source, target in ((self.root / "missing", self.root / "also-missing"),
                               (empty, self.root / "missing"), (self.root / "missing", empty)):
            with self.subTest(source=source, target=target), self.assertRaises(upgrade.UpgradeError):
                upgrade.compare_trees(source, target)

    def test_preserves_empty_directories(self) -> None:
        (self.backup / "profiles/empty-directory").rmdir()
        with self.assertRaises(upgrade.UpgradeError):
            upgrade.compare_trees(self.home, self.backup)

    def make_transaction_backup(self) -> Path:
        transaction = self.root / "transaction"
        transaction.mkdir()
        shutil.copytree(self.home, transaction / "home")
        for relative, data in (("runtime/venv/Scripts/python.exe", b"runtime fixture"),
                               ("bin/hermes.cmd", b"launcher fixture")):
            path = transaction / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        return transaction

    def test_retained_snapshot_records_all_three_trees_and_detects_tampering(self) -> None:
        transaction = self.make_transaction_backup()
        self.assertEqual(upgrade.snapshot(transaction), {"snapshot_verified": True})
        payload = json.loads((transaction / "snapshot.json").read_text())
        self.assertEqual(set(payload), {"home", "runtime", "bin"})
        self.assertIn("profiles/work/state.db-wal", payload["home"])
        self.assertIn("profiles/empty-directory/", payload["home"])
        self.assertEqual(upgrade.snapshot(transaction, check=True), {"snapshot_verified": True})
        (transaction / "home/.env").write_text("changed after backup")
        with self.assertRaisesRegex(upgrade.UpgradeError, "Retained backup no longer matches"):
            upgrade.snapshot(transaction, check=True)

    def test_snapshot_creation_does_not_overwrite_an_existing_inventory(self) -> None:
        transaction = self.make_transaction_backup()
        upgrade.snapshot(transaction)
        existing = (transaction / "snapshot.json").read_bytes()
        with self.assertRaises(FileExistsError):
            upgrade.snapshot(transaction)
        self.assertEqual((transaction / "snapshot.json").read_bytes(), existing)

    def test_snapshot_rejects_missing_or_empty_required_trees(self) -> None:
        transaction = self.make_transaction_backup()
        shutil.rmtree(transaction / "bin")
        with self.assertRaises(upgrade.UpgradeError):
            upgrade.snapshot(transaction)
        (transaction / "bin").mkdir()
        with self.assertRaisesRegex(upgrade.UpgradeError, "incomplete"):
            upgrade.snapshot(transaction)

    def test_backup_links_are_not_treated_as_snapshot_bytes(self) -> None:
        link = self.backup / "linked-config"
        try:
            link.symlink_to(self.home / "config.yaml")
        except (OSError, NotImplementedError):
            self.skipTest("Creating symlinks is not supported for this test account")
        with self.assertRaises(upgrade.UpgradeError):
            upgrade.compare_trees(self.home, self.backup)


class HealthAndOutputTests(unittest.TestCase):
    def fake_endpoint_modules(self, *, key="long-enough-test-secret", host="127.0.0.1", port=8642, enabled=True):
        api = types.SimpleNamespace(enabled=enabled, extra={"key": key, "host": host, "port": port})
        gateway_config = types.ModuleType("gateway.config")
        gateway_config.Platform = types.SimpleNamespace(API_SERVER="api_server")
        gateway_config.load_gateway_config = lambda: types.SimpleNamespace(platforms={"api_server": api})
        dotenv = types.ModuleType("dotenv")
        dotenv.load_dotenv = mock.Mock()
        return mock.patch.dict(sys.modules, {"gateway.config": gateway_config, "dotenv": dotenv})

    def test_endpoint_accepts_only_loopback_health_destinations_and_strong_existing_key(self) -> None:
        for host, expected in (("127.0.0.1", "127.0.0.1"), ("localhost", "127.0.0.1"),
                               ("0.0.0.0", "127.0.0.1"), ("::", "[::1]")):
            with self.subTest(host=host), self.fake_endpoint_modules(host=host):
                self.assertEqual(upgrade.endpoint(Path("home"))[0], f"http://{expected}:8642")
        for options in ({"host": "example.test"}, {"host": "192.0.2.1"}, {"port": 65536},
                        {"key": "clawpanel-local"}, {"key": "short"}, {"enabled": False}):
            with self.subTest(options=options), self.fake_endpoint_modules(**options):
                with self.assertRaises(upgrade.UpgradeError):
                    upgrade.endpoint(Path("home"))

    def test_health_requires_authenticated_readiness_and_disables_proxies_and_redirects(self) -> None:
        public = {"platform": "hermes-agent", "version": "0.21.4"}
        details = {"version": "0.21.4", "status": "ok", "readiness": {"status": "ok"},
                   "gateway_state": "running", "platforms": {"api_server": {"state": "connected"}}, "pid": 123}
        opener = mock.Mock()
        opener.open.side_effect = [io.StringIO(json.dumps(public)), io.StringIO(json.dumps(details))]
        with mock.patch.object(upgrade, "endpoint", return_value=("http://127.0.0.1:8642", "secret-health-key")), mock.patch.object(upgrade.urllib.request, "build_opener", return_value=opener) as build:
            self.assertEqual(upgrade.health(Path("home"), "0.21.4", 1), {"healthy": True, "pid": 123})
        handlers = build.call_args.args
        self.assertEqual(handlers[0].proxies, {})
        self.assertIsNone(handlers[1].redirect_request(None, None, 302, "redirect", {}, "https://example.test"))
        requests = [call.args[0] for call in opener.open.call_args_list]
        self.assertEqual(requests[0].full_url, "http://127.0.0.1:8642/health")
        self.assertIsNone(requests[0].get_header("Authorization"))
        self.assertEqual(requests[1].full_url, "http://127.0.0.1:8642/health/detailed")
        self.assertEqual(requests[1].get_header("Authorization"), "Bearer secret-health-key")

    def test_health_rejects_wrong_version_unready_or_other_listener(self) -> None:
        good_public = {"platform": "hermes-agent", "version": "0.21.4"}
        good_details = {"version": "0.21.4", "status": "ok", "readiness": {"status": "ok"},
                        "gateway_state": "running", "platforms": {"api_server": {"state": "running"}}, "pid": 123}
        cases = [({**good_public, "platform": "other"}, good_details),
                 ({**good_public, "version": "0.20.0"}, good_details),
                 (good_public, {**good_details, "readiness": {"status": "starting"}}),
                 (good_public, {**good_details, "gateway_state": "stopped"}),
                 (good_public, {**good_details, "platforms": {"api_server": {"state": "failed"}}})]
        for public, details in cases:
            opener = mock.Mock()
            opener.open.side_effect = [io.StringIO(json.dumps(public)), io.StringIO(json.dumps(details))]
            with self.subTest(public=public, details=details), mock.patch.object(upgrade, "endpoint", return_value=("http://127.0.0.1:8642", "key")), mock.patch.object(upgrade.urllib.request, "build_opener", return_value=opener), mock.patch.object(upgrade.time, "monotonic", side_effect=[0, 0, 2]), mock.patch.object(upgrade.time, "sleep"):
                with self.assertRaisesRegex(upgrade.UpgradeError, "Authenticated gateway readiness failed"):
                    upgrade.health(Path("home"), "0.21.4", 1)

    def test_runtime_verification_checks_final_source_version_and_exact_home(self) -> None:
        source = Path("final-runtime/hermes-agent").resolve()
        home = Path("existing-home").resolve()
        hermes_cli = types.ModuleType("hermes_cli")
        hermes_cli.__file__ = str(source / "hermes_cli/__init__.py")
        constants = types.ModuleType("hermes_constants")
        constants.get_hermes_home = lambda: home
        with mock.patch.dict(sys.modules, {"hermes_cli": hermes_cli, "hermes_constants": constants}), mock.patch.object(upgrade.importlib.metadata, "version", return_value="0.21.4"):
            self.assertTrue(upgrade.verify_runtime(source, "0.21.4", home)["source_verified"])
            with self.assertRaisesRegex(upgrade.UpgradeError, "version differs"):
                upgrade.verify_runtime(source, "0.21.3", home)
            with self.assertRaisesRegex(upgrade.UpgradeError, "home changed"):
                upgrade.verify_runtime(source, "0.21.4", home / "other")
            with self.assertRaisesRegex(upgrade.UpgradeError, "final runtime source"):
                upgrade.verify_runtime(source / "staged-copy", "0.21.4", home)

    def test_cli_never_exposes_generic_exception_details(self) -> None:
        output = io.StringIO()
        with mock.patch.object(sys, "argv", ["upgrade_support.py", "inspect", "--home", "unused"]), mock.patch.object(upgrade, "inspect_home", side_effect=ValueError("PRIVATE_CONFIG_OR_SECRET")), contextlib.redirect_stdout(output):
            self.assertEqual(upgrade.main(), 1)
        self.assertEqual(json.loads(output.getvalue()), {"error": "Upgrade helper failed: ValueError"})

    def test_endpoint_cli_returns_no_credential(self) -> None:
        output = io.StringIO()
        with mock.patch.object(sys, "argv", ["upgrade_support.py", "endpoint", "--home", "unused"]), mock.patch.object(upgrade, "endpoint", return_value=("http://[::1]:8642", "private-secret")), contextlib.redirect_stdout(output):
            self.assertEqual(upgrade.main(), 0)
        result = json.loads(output.getvalue())
        self.assertEqual(result["url"], "http://[::1]:8642")
        self.assertEqual(result["port"], 8642)
        self.assertEqual(result["auth_fingerprint"], hashlib.sha256(b"private-secret").hexdigest())
        self.assertNotIn("private-secret", output.getvalue())


if __name__ == "__main__":
    unittest.main()
