#!/usr/bin/env python3
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import configure_config


class ConfigureConfigTests(unittest.TestCase):
    def configure_text(self, initial: str) -> tuple[str, str]:
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = Path(tmpdir) / "config.yaml"
            if initial:
                config_path.write_text(initial, encoding="utf-8")
            port = configure_config.configure(config_path)
            return config_path.read_text(encoding="utf-8"), port

    def test_creates_default_model_provider_and_api_server(self) -> None:
        text, port = self.configure_text("")

        self.assertEqual(port, "8642")
        self.assertIn("model:\n  default: qwen3\n  provider: custom:zhan_ai", text)
        self.assertIn('api: "${ZHANCLAW_BASE_URL}"', text)
        self.assertIn("key_env: ZHANCLAW_API_KEY", text)
        self.assertIn("      - qwen3", text)
        self.assertIn("platforms:\n  api_server:\n    enabled: true\n    extra:\n      port: 8642", text)

    def test_migrates_legacy_api_server_port(self) -> None:
        text, port = self.configure_text(
            "\n".join([
                "api_server_port: 9999",
                "model:",
                "  default: gpt-4o-mini",
            ])
            + "\n"
        )

        self.assertEqual(port, "9999")
        self.assertNotIn("api_server_port:", text)
        self.assertIn("  default: qwen3", text)
        self.assertIn("      port: 9999", text)

    def test_appends_qwen3_to_inline_provider_models(self) -> None:
        text, _ = self.configure_text(
            "\n".join([
                "providers:",
                "  zhan_ai:",
                '    api: "https://example.invalid"',
                "    models: [deepseek-r1]",
            ])
            + "\n"
        )

        self.assertIn("    models: [deepseek-r1, qwen3]", text)
        self.assertIn('    api: "${ZHANCLAW_BASE_URL}"', text)


if __name__ == "__main__":
    unittest.main()
