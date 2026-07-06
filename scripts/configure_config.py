#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import sys
from typing import Iterable
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


DEFAULT_ZHAN_AI_MODEL = "qwen3"
ZHANCLAW_BASE_URL_NAMES = (
    "ZHANCLAW_BASE_URL",
    "CUSTOM_BASE_URL",
    "OPENAI_BASE_URL",
)
ZHANCLAW_API_KEY_NAMES = (
    "ZHANCLAW_API_KEY",
    "CUSTOM_API_KEY",
    "OPENAI_API_KEY",
)


def _dedupe_model_ids(model_ids: Iterable[str]) -> list[str]:
    ordered: list[str] = []
    seen: set[str] = set()
    for model_id in model_ids:
        candidate = str(model_id or "").strip()
        if not candidate:
            continue
        lowered = candidate.lower()
        if lowered in seen:
            continue
        seen.add(lowered)
        ordered.append(candidate)

    default_index = next(
        (index for index, item in enumerate(ordered) if item.lower() == DEFAULT_ZHAN_AI_MODEL),
        None,
    )
    if default_index not in (None, 0):
        ordered.insert(0, ordered.pop(default_index))
    return ordered


def _get_env_file_value(path: Path, names: Iterable[str]) -> str | None:
    if not path.exists():
        return None

    name_set = {name.upper() for name in names if name}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.match(r"^\s*([^#=\s]+)\s*=\s*(.*)$", line)
        if not match:
            continue
        key = match.group(1).strip().upper()
        if key not in name_set:
            continue
        value = match.group(2).strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        if value:
            return value
    return None


def _resolve_setting(names: Iterable[str], env_paths: Iterable[Path]) -> str | None:
    for name in names:
        value = os.environ.get(name, "").strip()
        if value:
            return value
    for env_path in env_paths:
        value = _get_env_file_value(env_path, names)
        if value:
            return value
    return None


def _extract_model_ids(payload: object) -> list[str]:
    if isinstance(payload, dict):
        data = payload.get("data")
        if data is not None:
            return _extract_model_ids(data)
        models = payload.get("models")
        if models is not None:
            return _extract_model_ids(models)
        model_id = payload.get("id")
        if not isinstance(model_id, str) or not model_id.strip():
            model_id = payload.get("name")
        if isinstance(model_id, str) and model_id.strip():
            return [model_id.strip()]
        return []

    if isinstance(payload, list):
        model_ids: list[str] = []
        for item in payload:
            model_ids.extend(_extract_model_ids(item))
        return _dedupe_model_ids(model_ids)

    if isinstance(payload, str) and payload.strip():
        return [payload.strip()]

    return []


def discover_zhan_ai_models(env_paths: Iterable[Path]) -> list[str] | None:
    base_url = _resolve_setting(ZHANCLAW_BASE_URL_NAMES, env_paths)
    api_key = _resolve_setting(ZHANCLAW_API_KEY_NAMES, env_paths)
    if not base_url or not api_key:
        return None

    request = Request(
        base_url.rstrip("/") + "/models",
        headers={
            "Accept": "application/json",
            "Authorization": f"Bearer {api_key}",
            "X-API-Key": api_key,
            "User-Agent": "hermes-offline-installer/1.0",
        },
    )
    try:
        with urlopen(request, timeout=3.0) as response:
            payload = json.load(response)
    except (HTTPError, URLError, TimeoutError, json.JSONDecodeError) as exc:
        print(f"Warning: could not fetch zhan_ai models; using fallback list. {exc}", file=sys.stderr)
        return None

    model_ids = _dedupe_model_ids([DEFAULT_ZHAN_AI_MODEL, *_extract_model_ids(payload)])
    return model_ids or [DEFAULT_ZHAN_AI_MODEL]


def configure_config(path: Path, env_paths: Iterable[Path] = ()) -> str:
    lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
    discovered_models = discover_zhan_ai_models(env_paths)

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

    def zhan_ai_model_lines(model_ids: list[str]) -> list[str]:
        ordered_models = _dedupe_model_ids(model_ids or [DEFAULT_ZHAN_AI_MODEL])
        return ["    models:", *[f"      - {model_id}" for model_id in ordered_models]]

    def ensure_model_provider() -> None:
        model_index = find_top_level_key("model")
        if model_index < 0:
            lines[0:0] = ["model:", f"  default: {DEFAULT_ZHAN_AI_MODEL}", "  provider: custom:zhan_ai", ""]
            return

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
        elif (
            re.match(r"^\s+default\s*:\s*([#].*)?$", lines[default_index])
            or re.match(r"^\s+default\s*:\s*['\"]?gpt-4o-mini['\"]?\s*(#.*)?$", lines[default_index])
        ):
            lines[default_index] = f"  default: {DEFAULT_ZHAN_AI_MODEL}"

        provider_index = -1
        for index in range(model_index + 1, model_end):
            if re.match(r"^\s+provider\s*:", lines[index]):
                provider_index = index
                break

        if provider_index >= 0:
            lines[provider_index] = "  provider: custom:zhan_ai"
        else:
            lines.insert(default_index + 1, "  provider: custom:zhan_ai")

    def ensure_zhan_ai_provider() -> None:
        providers_index = find_top_level_key("providers")
        if providers_index < 0:
            if lines and lines[-1] != "":
                lines.append("")
            model_lines = zhan_ai_model_lines(discovered_models or [DEFAULT_ZHAN_AI_MODEL])
            lines.extend([
                "providers:",
                "  zhan_ai:",
                '    api: "${ZHANCLAW_BASE_URL}"',
                "    key_env: ZHANCLAW_API_KEY",
                *model_lines,
            ])
            return

        providers_end = top_level_block_end(providers_index)
        zhan_index = -1
        for index in range(providers_index + 1, providers_end):
            if re.match(r"^\s{2}zhan_ai\s*:\s*(#.*)?$", lines[index]):
                zhan_index = index
                break

        if zhan_index < 0:
            model_lines = zhan_ai_model_lines(discovered_models or [DEFAULT_ZHAN_AI_MODEL])
            lines[providers_index + 1:providers_index + 1] = [
                "  zhan_ai:",
                '    api: "${ZHANCLAW_BASE_URL}"',
                "    key_env: ZHANCLAW_API_KEY",
                *model_lines,
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

        desired_model_lines = zhan_ai_model_lines(discovered_models or [DEFAULT_ZHAN_AI_MODEL])
        if models_index < 0:
            model_insert_index = zhan_end
            for index in range(zhan_index + 1, zhan_end):
                if re.match(r"^\s+key_env\s*:", lines[index]):
                    model_insert_index = index + 1
                    break
                if re.match(r"^\s+api\s*:", lines[index]):
                    model_insert_index = index + 1
            lines[model_insert_index:model_insert_index] = desired_model_lines
        elif discovered_models:
            models_end = nested_block_end(models_index, 4)
            if models_end == models_index + 1 and lines[models_index].strip() != "models:":
                models_end = models_index + 1
            lines[models_index:models_end] = desired_model_lines
        else:
            inline_match = re.match(r"^(\s+models\s*:\s*)\[(.*)\](\s*#.*)?$", lines[models_index])
            has_inline_qwen3 = bool(
                inline_match
                and re.search(r"(^|[^A-Za-z0-9_-])qwen3([^A-Za-z0-9_-]|$)", inline_match.group(2))
            )
            if inline_match and not has_inline_qwen3:
                inline_models = inline_match.group(2).strip()
                inline_comment = inline_match.group(3) or ""
                if inline_models:
                    lines[models_index] = f"{inline_match.group(1)}[{inline_models}, {DEFAULT_ZHAN_AI_MODEL}]{inline_comment}"
                else:
                    lines[models_index] = f"{inline_match.group(1)}[{DEFAULT_ZHAN_AI_MODEL}]{inline_comment}"
            elif re.match(r"^\s+models\s*:\s*$", lines[models_index]):
                models_end = nested_block_end(models_index, 4)
                has_qwen3_model = any(
                    re.match(r"^\s+(?:-\s*)?[\"']?qwen3[\"']?\s*(?::|#.*)?$", lines[index])
                    for index in range(models_index + 1, models_end)
                )
                if not has_qwen3_model:
                    lines.insert(models_index + 1, f"      - {DEFAULT_ZHAN_AI_MODEL}")

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
    ensure_model_provider()
    ensure_zhan_ai_provider()
    ensure_api_server_platform(legacy_port)
    api_server_port = get_api_server_platform_port()
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return api_server_port


def main() -> None:
    parser = argparse.ArgumentParser(description="Configure Hermes offline installer config.yaml defaults.")
    parser.add_argument("config_path", type=Path)
    parser.add_argument(
        "--env-path",
        action="append",
        default=[],
        type=Path,
        help="Optional .env path to consult for ZHANCLAW_* and legacy model settings.",
    )
    args = parser.parse_args()

    api_server_port = configure_config(args.config_path, env_paths=args.env_path)
    print("Configured default model provider: custom:zhan_ai")
    print(f"Configured API server platform port: {api_server_port}")


if __name__ == "__main__":
    main()
