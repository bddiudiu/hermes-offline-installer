#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path
import re


DEFAULT_ZHAN_AI_MODEL = "qwen3"


def _parse_yaml_scalar(line: str) -> str | None:
    if ":" not in line:
        return None
    value = line.split(":", 1)[1].strip()
    if not value or value.startswith("#"):
        return None
    value = re.sub(r"\s+#.*$", "", value).strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        value = value[1:-1]
    return value or None


def _parse_inline_model_list(value: str) -> list[str]:
    model_ids: list[str] = []
    for part in value.split(","):
        candidate = part.strip()
        if len(candidate) >= 2 and candidate[0] == candidate[-1] and candidate[0] in {"'", '"'}:
            candidate = candidate[1:-1]
        candidate = candidate.strip()
        if candidate:
            model_ids.append(candidate)
    return model_ids


def _dedupe_model_ids(model_ids: list[str]) -> list[str]:
    ordered: list[str] = []
    seen: set[str] = set()
    for model_id in model_ids:
        candidate = (model_id or "").strip()
        if not candidate:
            continue
        lowered = candidate.lower()
        if lowered in seen:
            continue
        seen.add(lowered)
        ordered.append(candidate)
    return ordered


def configure_config(path: Path) -> str:
    lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []

    def find_top_level_key(key: str) -> int:
        pattern = re.compile(rf"^{re.escape(key)}:\s*(#.*)?$")
        for index, line in enumerate(lines):
            if pattern.match(line):
                return index
        return -1

    def top_level_block_end(start: int) -> int:
        for index in range(start + 1, len(lines)):
            line = lines[index]
            if line and not line[0].isspace() and not line.lstrip().startswith("#"):
                return index
        return len(lines)

    def nested_block_end(start: int, indent: int) -> int:
        for index in range(start + 1, len(lines)):
            line = lines[index]
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            leading = len(line) - len(line.lstrip(" "))
            if leading <= indent:
                return index
        return len(lines)

    def ensure_model_provider() -> str:
        model_index = find_top_level_key("model")
        if model_index < 0:
            lines[0:0] = ["model:", f"  default: {DEFAULT_ZHAN_AI_MODEL}", "  provider: custom:zhan_ai", ""]
            return DEFAULT_ZHAN_AI_MODEL

        model_end = top_level_block_end(model_index)
        default_index = -1
        provider_index = -1
        for index in range(model_index + 1, model_end):
            if re.match(r"^\s+default\s*:", lines[index]):
                default_index = index
            if re.match(r"^\s+provider\s*:", lines[index]):
                provider_index = index

        if default_index < 0:
            lines.insert(model_index + 1, f"  default: {DEFAULT_ZHAN_AI_MODEL}")
            model_end += 1
            default_index = model_index + 1
            default_model = DEFAULT_ZHAN_AI_MODEL
        else:
            default_model = _parse_yaml_scalar(lines[default_index])
        if not default_model:
            lines[default_index] = f"  default: {DEFAULT_ZHAN_AI_MODEL}"
            default_model = DEFAULT_ZHAN_AI_MODEL

        provider_index = -1
        for index in range(model_index + 1, model_end):
            if re.match(r"^\s+provider\s*:", lines[index]):
                provider_index = index
                break

        if provider_index >= 0:
            lines[provider_index] = "  provider: custom:zhan_ai"
        else:
            lines.insert(default_index + 1, "  provider: custom:zhan_ai")
        return default_model

    def ensure_zhan_ai_provider(default_model: str) -> None:
        required_models = _dedupe_model_ids([default_model, DEFAULT_ZHAN_AI_MODEL])

        providers_index = find_top_level_key("providers")
        if providers_index < 0:
            if lines and lines[-1] != "":
                lines.append("")
            lines.extend([
                "providers:",
                "  zhan_ai:",
                '    api: "${ZHANCLAW_BASE_URL}"',
                "    key_env: ZHANCLAW_API_KEY",
                "    models:",
                *[f"      - {model_id}" for model_id in required_models],
            ])
            return

        providers_end = top_level_block_end(providers_index)
        zhan_index = -1
        for index in range(providers_index + 1, providers_end):
            if re.match(r"^\s{2}zhan_ai\s*:\s*(#.*)?$", lines[index]):
                zhan_index = index
                break

        if zhan_index < 0:
            lines[providers_index + 1:providers_index + 1] = [
                "  zhan_ai:",
                '    api: "${ZHANCLAW_BASE_URL}"',
                "    key_env: ZHANCLAW_API_KEY",
                "    models:",
                *[f"      - {model_id}" for model_id in required_models],
            ]
            return

        zhan_end = nested_block_end(zhan_index, 2)
        api_index = -1
        key_env_index = -1
        for index in range(zhan_index + 1, zhan_end):
            if re.match(r"^\s+api\s*:", lines[index]):
                api_index = index
            if re.match(r"^\s+key_env\s*:", lines[index]):
                key_env_index = index

        if api_index >= 0:
            lines[api_index] = '    api: "${ZHANCLAW_BASE_URL}"'
        else:
            lines.insert(zhan_index + 1, '    api: "${ZHANCLAW_BASE_URL}"')
            zhan_end += 1

        key_env_index = -1
        for index in range(zhan_index + 1, zhan_end):
            if re.match(r"^\s+key_env\s*:", lines[index]):
                key_env_index = index
                break

        if key_env_index >= 0:
            lines[key_env_index] = "    key_env: ZHANCLAW_API_KEY"
        else:
            lines.insert(zhan_index + 2, "    key_env: ZHANCLAW_API_KEY")
            zhan_end += 1

        zhan_end = nested_block_end(zhan_index, 2)
        models_index = -1
        for index in range(zhan_index + 1, zhan_end):
            if re.match(r"^\s+models\s*:", lines[index]):
                models_index = index
                break

        if models_index < 0:
            model_insert_index = zhan_end
            for index in range(zhan_index + 1, zhan_end):
                if re.match(r"^\s+key_env\s*:", lines[index]):
                    model_insert_index = index + 1
                    break
                if re.match(r"^\s+api\s*:", lines[index]):
                    model_insert_index = index + 1
            lines[model_insert_index:model_insert_index] = [
                "    models:",
                *[f"      - {model_id}" for model_id in required_models],
            ]
        else:
            inline_match = re.match(r"^(\s+models\s*:\s*)\[(.*)\](\s*#.*)?$", lines[models_index])
            if inline_match:
                inline_models = _parse_inline_model_list(inline_match.group(2))
                updated_models = _dedupe_model_ids([*inline_models, *required_models])
                if len(updated_models) != len(inline_models):
                    inline_comment = inline_match.group(3) or ""
                    lines[models_index] = f"{inline_match.group(1)}[{', '.join(updated_models)}]{inline_comment}"
            elif re.match(r"^\s+models\s*:\s*$", lines[models_index]):
                models_end = nested_block_end(models_index, 4)
                existing_model_ids: list[str] = []
                for index in range(models_index + 1, models_end):
                    match = re.match(r"^\s*-\s*([^\s#][^#]*?)\s*(#.*)?$", lines[index])
                    if not match:
                        continue
                    model_id = match.group(1).strip()
                    if len(model_id) >= 2 and model_id[0] == model_id[-1] and model_id[0] in {"'", '"'}:
                        model_id = model_id[1:-1]
                    existing_model_ids.append(model_id)
                existing_model_ids = _dedupe_model_ids(existing_model_ids)
                existing_lower = {model_id.lower() for model_id in existing_model_ids}
                missing_models = [
                    model_id for model_id in required_models if model_id.lower() not in existing_lower
                ]
                if missing_models:
                    insertion_index = models_index + 1
                    for model_id in reversed(missing_models):
                        lines.insert(insertion_index, f"      - {model_id}")
            else:
                lines[models_index:models_index + 1] = [
                    "    models:",
                    *[f"      - {model_id}" for model_id in required_models],
                ]

    def remove_legacy_api_server_port() -> str | None:
        legacy_port = None
        kept = []
        for line in lines:
            match = re.match(r"^api_server_port\s*:\s*([^#]+)?", line)
            if match:
                candidate = (match.group(1) or "").strip()
                if candidate:
                    legacy_port = candidate
                continue
            kept.append(line)
        lines[:] = kept
        return legacy_port

    def ensure_api_server_platform(port: str | None) -> None:
        effective_port = port or "8642"
        platforms_index = find_top_level_key("platforms")
        if platforms_index < 0:
            if lines and lines[-1] != "":
                lines.append("")
            lines.extend([
                "platforms:",
                "  api_server:",
                "    enabled: true",
                "    extra:",
                f"      port: {effective_port}",
            ])
            return

        platforms_end = top_level_block_end(platforms_index)
        api_server_index = -1
        for index in range(platforms_index + 1, platforms_end):
            if re.match(r"^\s{2}api_server\s*:\s*(#.*)?$", lines[index]):
                api_server_index = index
                break

        if api_server_index < 0:
            lines[platforms_index + 1:platforms_index + 1] = [
                "  api_server:",
                "    enabled: true",
                "    extra:",
                f"      port: {effective_port}",
            ]
            return

        api_server_end = nested_block_end(api_server_index, 2)
        enabled_index = -1
        for index in range(api_server_index + 1, api_server_end):
            if re.match(r"^\s{4}enabled\s*:", lines[index]):
                enabled_index = index
                break
        if enabled_index >= 0:
            lines[enabled_index] = "    enabled: true"
        else:
            lines.insert(api_server_index + 1, "    enabled: true")
            enabled_index = api_server_index + 1

        api_server_end = nested_block_end(api_server_index, 2)
        extra_index = -1
        for index in range(api_server_index + 1, api_server_end):
            if re.match(r"^\s{4}extra\s*:\s*(#.*)?$", lines[index]):
                extra_index = index
                break

        if extra_index < 0:
            lines[enabled_index + 1:enabled_index + 1] = [
                "    extra:",
                f"      port: {effective_port}",
            ]
            return

        extra_end = nested_block_end(extra_index, 4)
        port_index = -1
        for index in range(extra_index + 1, extra_end):
            if re.match(r"^\s{6}port\s*:", lines[index]):
                port_index = index
                break
        if port_index >= 0:
            if port:
                lines[port_index] = f"      port: {port}"
        else:
            lines.insert(extra_index + 1, f"      port: {effective_port}")

    def get_api_server_platform_port() -> str:
        platforms_index = find_top_level_key("platforms")
        if platforms_index < 0:
            return ""
        platforms_end = top_level_block_end(platforms_index)
        api_server_index = -1
        for index in range(platforms_index + 1, platforms_end):
            if re.match(r"^\s{2}api_server\s*:\s*(#.*)?$", lines[index]):
                api_server_index = index
                break
        if api_server_index < 0:
            return ""
        api_server_end = nested_block_end(api_server_index, 2)
        extra_index = -1
        for index in range(api_server_index + 1, api_server_end):
            if re.match(r"^\s{4}extra\s*:\s*(#.*)?$", lines[index]):
                extra_index = index
                break
        if extra_index < 0:
            return ""
        extra_end = nested_block_end(extra_index, 4)
        for index in range(extra_index + 1, extra_end):
            match = re.match(r"^\s{6}port\s*:\s*([^#]+)?", lines[index])
            if match:
                return (match.group(1) or "").strip()
        return ""

    legacy_port = remove_legacy_api_server_port()
    default_model = ensure_model_provider()
    ensure_zhan_ai_provider(default_model)
    ensure_api_server_platform(legacy_port)
    api_server_port = get_api_server_platform_port()
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return api_server_port


def main() -> None:
    parser = argparse.ArgumentParser(description="Configure Hermes offline installer config.yaml defaults.")
    parser.add_argument("config_path", type=Path)
    args = parser.parse_args()

    api_server_port = configure_config(args.config_path)
    print("Configured default model provider: custom:zhan_ai")
    print(f"Configured API server platform port: {api_server_port}")


if __name__ == "__main__":
    main()
