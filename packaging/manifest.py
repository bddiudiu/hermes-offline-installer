from __future__ import annotations

import json
import os
import platform
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

HERMES_SOURCE = os.environ.get(
    "HERMES_SOURCE",
    "hermes-agent @ git+https://github.com/NousResearch/hermes-agent.git",
)
PYTHON_VERSION = os.environ.get("PYTHON_VERSION", "3.11")
UV_VERSION = os.environ.get("UV_VERSION", "0.7.12")


def write_manifest(path: Path, *, target_platform: str, extra: dict[str, Any] | None = None) -> None:
    payload: dict[str, Any] = {
        "target_platform": target_platform,
        "host_platform": platform.platform(),
        "python_version": PYTHON_VERSION,
        "uv_version": UV_VERSION,
        "hermes_source": HERMES_SOURCE,
        "created_at": datetime.now(timezone.utc).isoformat(),
    }
    if extra:
        payload.update(extra)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
