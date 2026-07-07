#!/usr/bin/env python3
from __future__ import annotations

import tempfile
import textwrap
import unittest
from pathlib import Path

from configure_config import configure_config


def _run_case(initial_text: str) -> str:
    with tempfile.TemporaryDirectory() as tmpdir:
        config_path = Path(tmpdir) / "config.yaml"
        config_path.write_text(textwrap.dedent(initial_text).lstrip(), encoding="utf-8")
        configure_config(config_path)
        return config_path.read_text(encoding="utf-8")


class ConfigureConfigTests(unittest.TestCase):
    def test_fresh_config_defaults_to_qwen3(self) -> None:
        updated = _run_case("")
        self.assertIn("default: qwen3", updated)
        self.assertIn("provider: custom:zhan_ai", updated)
        self.assertIn("models:\n      - qwen3", updated)

    def test_upgrade_preserves_existing_visual_model_default(self) -> None:
        updated = _run_case(
            """
            model:
              default: gpt-4o-mini
              provider: custom:zhan_ai

            providers:
              zhan_ai:
                api: "${ZHANCLAW_BASE_URL}"
                key_env: ZHANCLAW_API_KEY
            """
        )
        self.assertIn("default: gpt-4o-mini", updated)
        self.assertIn("provider: custom:zhan_ai", updated)
        self.assertIn("      - gpt-4o-mini", updated)
        self.assertIn("      - qwen3", updated)

    def test_upgrade_preserves_existing_default_inside_inline_model_list(self) -> None:
        updated = _run_case(
            """
            model:
              default: gpt-4o-mini
              provider: custom:zhan_ai

            providers:
              zhan_ai:
                api: "${ZHANCLAW_BASE_URL}"
                key_env: ZHANCLAW_API_KEY
                models: [qwen3]
            """
        )
        self.assertIn("default: gpt-4o-mini", updated)
        self.assertIn("models: [qwen3, gpt-4o-mini]", updated)

    def test_blank_default_still_falls_back_to_qwen3(self) -> None:
        updated = _run_case(
            """
            model:
              default:
              provider: custom:zhan_ai
            """
        )
        self.assertIn("default: qwen3", updated)

if __name__ == "__main__":
    unittest.main()
