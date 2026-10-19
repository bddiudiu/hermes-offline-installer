"""Read release identity without importing Hermes or trusting a placeholder version."""
from __future__ import annotations

import json
from pathlib import Path
import re
import tomllib


class VersionError(ValueError):
    pass


def stable_version(value: object) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", value):
        raise VersionError("Hermes release version must be stable and numeric")
    if not any(int(part) for part in value.split(".")):
        raise VersionError("Hermes release identity cannot use the 0.0.0 placeholder")
    return value


def distribution_version(source: Path) -> str:
    try:
        project = tomllib.loads((source / "pyproject.toml").read_text(encoding="utf-8"))["project"]
        version = project["version"]
    except (OSError, ValueError, KeyError, TypeError) as exc:
        raise VersionError("Cannot read Hermes distribution metadata") from exc
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", version):
        raise VersionError("Invalid Hermes distribution version")
    return version


def source_identity(source: Path, *, expected_version: str | None = None,
                    expected_commit: str | None = None) -> dict:
    metadata_version = distribution_version(source)
    stamp_file = source / "install-stamp.json"
    commit = None
    if stamp_file.exists():
        try:
            stamp = json.loads(stamp_file.read_text(encoding="utf-8-sig"))
        except (OSError, ValueError) as exc:
            raise VersionError("Invalid Hermes install stamp") from exc
        if not isinstance(stamp, dict):
            raise VersionError("Invalid Hermes install stamp")
        version = stable_version(stamp.get("baseVersion"))
        commit = stamp.get("commit")
        if (stamp.get("schemaVersion") != 2
                or not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}", commit)
                or set(commit) == {"0"}
                or stamp.get("updateMechanism") != "external"
                or stamp.get("payload") != "bootstrap"
                or stamp.get("dirty") is not False
                or stamp.get("distance") != 0
                or stamp.get("displayVersion") != version):
            raise VersionError("Invalid offline Hermes install identity")
        if metadata_version != "0.0.0" and metadata_version != version:
            raise VersionError("Source metadata and install stamp versions differ")
    else:
        # Pre-0.22 offline bundles used the real version in distribution metadata.
        version = stable_version(metadata_version)
    if expected_version is not None and version != expected_version:
        raise VersionError("Source and bundle versions differ")
    if expected_commit is not None and commit is not None and commit != expected_commit:
        raise VersionError("Source and bundle commits differ")
    return {"version": version, "distribution_version": metadata_version, "commit": commit}
