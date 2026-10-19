"""Upgrade defaults must be additive, idempotent and safe for user-owned settings."""
from __future__ import annotations

import copy
from pathlib import Path
import shutil
import sys
import tempfile
import types
import unittest
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import upgrade_support as upgrade


class UpgradeConfigDefaultsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.home = self.root / "home"
        self.backup = self.root / "backup"
        self.home.mkdir()
        self.backup.mkdir()
        self.template = ROOT / "templates/config.yaml"
        self.config = {
            "model": {"default": "my-vision-model", "provider": "custom:mine", "supports_vision": True},
            "models": ["my-vision-model", "my-fallback"],
            "providers": {"mine": {"api": "https://example.invalid/v1", "key": "fixture-key",
                                   "api_mode": "responses", "models": {"my-vision-model": "remote"}}},
            "mcp_servers": {"mine": {"enabled": False, "command": "fixture-mcp", "args": []}},
            "plugins": {"mine": {"enabled": False, "key": "fixture-plugin-key", "options": []}},
            "platform_toolsets": {"api_server": ["hermes-api-server"]},
            "terminal": {"backend": "local"},
            "platforms": {"api_server": {"enabled": True, "extra": {"port": 18642, "key": "fixture-api-key"}}},
            "custom_setting": {"enabled": False, "items": [], "nullable": None},
        }
        self.write_config(self.config)
        shutil.copy2(self.home / "config.yaml", self.backup / "config.yaml")
        for directory in (self.home, self.backup):
            (directory / ".env").write_text("API_SERVER_KEY=fixture-only-key-not-real\n", encoding="utf-8")

    def write_config(self, config, home=None):
        (home or self.home).joinpath("config.yaml").write_text(
            yaml.safe_dump(config, allow_unicode=True, sort_keys=False), encoding="utf-8")

    def test_adds_runtime_defaults_keeps_sensitive_sections_and_is_idempotent(self):
        before_env = (self.home / ".env").read_bytes()
        added = upgrade.merge_config_defaults(self.home, self.template)
        current = upgrade.read_config(self.home)
        self.assertEqual(len(added), 9)
        self.assertEqual(current["model"], self.config["model"])
        self.assertEqual(current["providers"], self.config["providers"])
        self.assertNotIn("zhan_ai", current["providers"])
        self.assertEqual(current["mcp_servers"], self.config["mcp_servers"])
        self.assertEqual(current["plugins"], self.config["plugins"])
        self.assertEqual(current["platforms"]["api_server"]["extra"]["key"], "fixture-api-key")
        self.assertEqual(current["platforms"]["api_server"]["extra"]["port"], 18642)
        self.assertEqual(current["terminal"], {"backend": "local", "cwd": ".", "timeout": 180, "home_mode": "auto"})
        self.assertEqual(current["platform_toolsets"]["cli"], ["hermes-cli"])
        self.assertIs(current["security"]["allow_lazy_installs"], False)
        self.assertIs(current["compression"]["enabled"], True)
        self.assertEqual(current["memory"], {"memory_enabled": True, "user_profile_enabled": True})
        self.assertEqual((self.home / ".env").read_bytes(), before_env)
        first = (self.home / "config.yaml").read_bytes()
        self.assertEqual(upgrade.merge_config_defaults(self.home, self.template), [])
        self.assertEqual((self.home / "config.yaml").read_bytes(), first)
        self.assertTrue(upgrade.check_preserved(self.home, self.backup)["user_assets_preserved"])

    def test_explicit_values_including_false_empty_null_and_zero_are_kept(self):
        original = copy.deepcopy(self.config)
        original.update({"compression": {"enabled": False},
                         "security": {"allow_lazy_installs": True},
                         "memory": {"memory_enabled": None, "user_profile_enabled": False}})
        original["terminal"].update({"cwd": "", "timeout": 0, "home_mode": "profile"})
        original["platform_toolsets"]["cli"] = []
        original["platforms"]["api_server"]["extra"]["host"] = "::1"
        self.write_config(original)
        before = (self.home / "config.yaml").read_bytes()
        self.assertEqual(upgrade.merge_config_defaults(self.home, self.template), [])
        self.assertEqual((self.home / "config.yaml").read_bytes(), before)

    def test_existing_non_mapping_parent_is_never_replaced(self):
        for value in (None, False, "", [], ["custom"]):
            with self.subTest(value=value):
                original = copy.deepcopy(self.config)
                original["terminal"] = value
                original["platforms"]["api_server"]["extra"] = value
                self.write_config(original)
                added = upgrade.merge_config_defaults(self.home, self.template)
                current = upgrade.read_config(self.home)
                self.assertEqual(current["terminal"], value)
                self.assertEqual(current["platforms"]["api_server"]["extra"], value)
                self.assertFalse(any(key.startswith("terminal.") for key in added))

    def test_each_profile_uses_its_own_existing_values(self):
        for name, existing in (("work", True), ("personal", False)):
            profile = self.home / "profiles" / name
            profile.mkdir(parents=True)
            original = copy.deepcopy(self.config)
            original["security"] = {"allow_lazy_installs": existing}
            self.write_config(original, profile)
        for profile in upgrade.home_profiles(self.home):
            upgrade.merge_config_defaults(profile, self.template)
        self.assertIs(upgrade.read_config(self.home)["security"]["allow_lazy_installs"], False)
        self.assertIs(upgrade.read_config(self.home / "profiles/work")["security"]["allow_lazy_installs"], True)
        self.assertIs(upgrade.read_config(self.home / "profiles/personal")["security"]["allow_lazy_installs"], False)

    def test_comments_quotes_unicode_crlf_and_yaml_11_values_survive_merge(self):
        text = '# user comment\r\nmodel: {default: "用户模型", provider: custom:mine}\r\nterminal:\r\n  timeout: 42 # chosen timeout\r\nuser_switch: yes\r\nuser_mode: 0755\r\n'
        (self.home / "config.yaml").write_bytes(b"\xef\xbb\xbf" + text.encode("utf-8"))
        before = upgrade.read_config(self.home)
        upgrade.merge_config_defaults(self.home, self.template)
        after = upgrade.read_config(self.home)
        upgrade.assert_config_preserved(before, after)
        data = (self.home / "config.yaml").read_bytes()
        self.assertIn(b"# user comment", data)
        self.assertIn(b"# chosen timeout", data)
        self.assertIn('"用户模型"'.encode("utf-8"), data)
        self.assertNotIn(b"\n", data.replace(b"\r\n", b""))
        self.assertIs(after["user_switch"], True)
        self.assertEqual(after["user_mode"], 0o755)

    def test_alias_cannot_change_a_protected_section(self):
        text = 'terminal: &shared {backend: local}\nplugins: *shared\n'
        (self.home / "config.yaml").write_text(text, encoding="utf-8")
        with self.assertRaises(upgrade.UpgradeError):
            upgrade.merge_config_defaults(self.home, self.template)
        self.assertEqual((self.home / "config.yaml").read_text(), text)

    def test_duplicate_keys_are_rejected_without_changing_the_file(self):
        text = 'security: {allow_lazy_installs: true, allow_lazy_installs: false}\n'
        (self.home / "config.yaml").write_text(text, encoding="utf-8")
        with self.assertRaisesRegex(upgrade.UpgradeError, "Duplicate config key"):
            upgrade.merge_config_defaults(self.home, self.template)
        self.assertEqual((self.home / "config.yaml").read_text(), text)

    def test_missing_template_and_failed_atomic_replace_leave_original_intact(self):
        before = (self.home / "config.yaml").read_bytes()
        bad = self.root / "incomplete.yaml"
        bad.write_text("{}\n", encoding="utf-8")
        with self.assertRaisesRegex(upgrade.UpgradeError, "missing a required"):
            upgrade.merge_config_defaults(self.home, bad)
        with mock.patch.object(upgrade.os, "replace", side_effect=OSError("fixture failure")):
            with self.assertRaises(OSError):
                upgrade.merge_config_defaults(self.home, self.template)
        self.assertEqual((self.home / "config.yaml").read_bytes(), before)
        self.assertEqual(list(self.home.glob(".config-upgrade-*")), [])

    def test_preservation_check_rejects_removal_changes_and_type_coercion(self):
        for key, value in (("custom_setting", {}), ("terminal", {"backend": "docker"}),
                           ("mcp_servers", {}), ("plugins", {})):
            with self.subTest(key=key):
                changed = copy.deepcopy(self.config)
                changed[key] = value
                with self.assertRaises(upgrade.UpgradeError):
                    upgrade.assert_config_preserved(self.config, changed)
        for before, after in ((False, 0), (True, 1), (None, ""), ([], {})):
            with self.assertRaises(upgrade.UpgradeError):
                upgrade.assert_config_preserved({"custom": before}, {"custom": after})
        upgrade.assert_config_preserved({"_config_version": 13}, {"_config_version": 14})

    def test_official_migration_runs_before_merge_and_new_defaults_remain_missing_only(self):
        module = types.ModuleType("hermes_cli.config")
        def official(**kwargs):
            self.assertEqual(kwargs, {"interactive": False, "quiet": True})
            config = upgrade.read_config(self.home)
            self.assertNotIn("security", config)
            config["_config_version"] = 30
            self.write_config(config)
            return {"warnings": []}
        module.migrate_config = official
        with mock.patch.dict(sys.modules, {"hermes_cli.config": module}):
            result = upgrade.migrate(self.home, self.backup, self.template)
        self.assertIn("security.allow_lazy_installs", result["config_defaults_added"])
        current = upgrade.read_config(self.home)
        self.assertEqual(current["_config_version"], 30)
        self.assertIs(current["security"]["allow_lazy_installs"], False)
        upgrade.assert_config_preserved(self.config, current)

    def test_official_migration_cannot_silently_change_existing_non_model_settings(self):
        module = types.ModuleType("hermes_cli.config")
        def official(**kwargs):
            config = upgrade.read_config(self.home)
            config["custom_setting"]["enabled"] = True
            self.write_config(config)
            return {"warnings": []}
        module.migrate_config = official
        with mock.patch.dict(sys.modules, {"hermes_cli.config": module}):
            with self.assertRaisesRegex(upgrade.UpgradeError, "existing config value"):
                upgrade.migrate(self.home, self.backup, self.template)
        self.assertNotIn("security", upgrade.read_config(self.home))

    def test_removed_env_key_cannot_hide_behind_a_process_environment_fallback(self):
        module = types.ModuleType("hermes_cli.config")
        def official(**kwargs):
            (self.home / ".env").write_text("", encoding="utf-8")
            return {"warnings": []}
        module.migrate_config = official
        with mock.patch.dict(sys.modules, {"hermes_cli.config": module}), \
                mock.patch.dict(upgrade.os.environ, {"API_SERVER_KEY": "fixture-only-key-not-real"}):
            with self.assertRaisesRegex(upgrade.UpgradeError, "existing .env value"):
                upgrade.migrate(self.home, self.backup, self.template)

    def test_startup_cannot_drop_an_env_key_without_a_value(self):
        (self.backup / ".env").write_text("EXPLICIT_EMPTY\n", encoding="utf-8")
        (self.home / ".env").write_text("", encoding="utf-8")
        with self.assertRaisesRegex(upgrade.UpgradeError, "existing .env value"):
            upgrade.check_preserved(self.home, self.backup)


if __name__ == "__main__":
    unittest.main()
