"""Private subprocess helpers for the Windows transactional upgrader.

Stdout is a small JSON result. Never print config, credentials, native stderr,
HTTP bodies or migration warnings: those may contain secrets.
"""
from __future__ import annotations

import argparse
import contextlib
import copy
import hashlib
import importlib.metadata
import io
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time
import urllib.request

if __name__ == "__main__":
    # This helper also runs under the OLD interpreter during read-only preflight.
    # A new .pyc in the extracted ZIP would invalidate its complete inventory.
    sys.dont_write_bytecode = True

from hermes_version import source_identity, stable_version, VersionError

class UpgradeError(RuntimeError):
    pass


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def version_tuple(value: str) -> tuple[int, ...]:
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", value):
        raise UpgradeError("Only stable numeric Hermes versions are supported")
    return tuple(map(int, value.split("."))) + (0,) * (4 - len(value.split(".")))


def verify_bundle(bundle: Path, installed_version: str, allow_same: bool = False) -> dict:
    manifest = json.loads((bundle / "manifest.json").read_text(encoding="utf-8-sig"))
    if manifest.get("kind") != "bundle" or manifest.get("target_platform") != "win-x64":
        raise UpgradeError("Expected a complete Windows x64 offline bundle")
    if manifest.get("hermes_install_mode") != "editable-source":
        raise UpgradeError("Unsupported bundle installation mode")
    target = str(manifest.get("hermes_version", ""))
    if version_tuple(target) < version_tuple(installed_version):
        raise UpgradeError("Downgrades require restoring the matching runtime and data backup")
    if version_tuple(target) == version_tuple(installed_version) and not allow_same:
        raise UpgradeError("Already at target version; use -AllowSameVersion for an intentional rebuild")
    try:
        identity = source_identity(bundle / "hermes-agent", expected_version=target,
                                   expected_commit=manifest.get("hermes_source_commit"))
    except VersionError as exc:
        raise UpgradeError(str(exc)) from exc
    if manifest.get("wheelhouse", {}).get("hermes_version") != target:
        raise UpgradeError("Wheelhouse and bundle versions differ")
    if identity["commit"] and (
        manifest.get("hermes_source_commit") != identity["commit"]
        or manifest.get("wheelhouse", {}).get("hermes_source_commit") != identity["commit"]
    ):
        raise UpgradeError("Source, wheelhouse and bundle commits differ")
    checksum = json.loads((bundle / "upgrade-manifest.json").read_text(encoding="utf-8-sig"))
    files = checksum.get("files")
    if checksum.get("schema") != 1 or not isinstance(files, dict) or not files:
        raise UpgradeError("Missing supported complete bundle checksum inventory")
    actual = set()
    for path in bundle.rglob("*"):
        if path.is_symlink():
            raise UpgradeError("Bundle links are unsupported")
        if path.is_file() and path.relative_to(bundle).as_posix() != "upgrade-manifest.json":
            actual.add(path.relative_to(bundle).as_posix())
    if actual != set(files):
        raise UpgradeError("Bundle file inventory differs from upgrade-manifest.json; extract a clean ZIP")
    for relative, expected in files.items():
        if "\\" in relative or any(p in ("", ".", "..") for p in relative.split("/")):
            raise UpgradeError("Unsafe checksum inventory path")
        path = (bundle / relative).resolve()
        if not path.is_relative_to(bundle.resolve()) or not re.fullmatch(r"[a-f0-9]{64}", str(expected)):
            raise UpgradeError("Unsafe checksum inventory entry")
        if digest(path) != expected:
            raise UpgradeError("Bundle checksum mismatch; extract a verified release ZIP again")
    for relative in (
        "hermes-agent/hermes_cli/main.py", "hermes-agent/tools/skills_sync.py",
        "hermes-resources/web_dist/index.html", "hermes-resources/tui_dist/dist/entry.js",
        "wheelhouse/requirements.txt", "wheelhouse/hermes-editable-requirement.txt",
        "scripts/upgrade_support.py", "installers/upgrade.ps1", "templates/config.yaml",
    ):
        if relative not in files:
            raise UpgradeError("Incomplete offline bundle layout")
    if not any((bundle / "runtime" / "python" / rel).is_file() for rel in ("python.exe", "bin/python.exe")):
        raise UpgradeError("Bundled Python is missing")
    requirement = (bundle / "wheelhouse" / "hermes-editable-requirement.txt").read_text().strip()
    if not re.fullmatch(r"\.(?:\[[A-Za-z0-9_-]+(?:,[A-Za-z0-9_-]+)*\])?", requirement):
        raise UpgradeError("Unsafe editable requirement")
    # Do not allow an unexpected network/direct-path requirement to escape --no-index.
    for line in (bundle / "wheelhouse" / "requirements.txt").read_text().splitlines():
        value = line.strip()
        if value and not value.startswith("#") and (
            value.startswith("-") or re.search(r"https?://|git\+|file:|[\\/]", value, re.I)
        ):
            raise UpgradeError("Offline requirements contain a URL, path, or pip option")
    return {"version": target, "files": len(files)}


def parse_config(text: str) -> dict:
    import yaml
    # Duplicate keys can hide a model/provider definition; refuse before migration.
    class UniqueLoader(yaml.SafeLoader):
        pass
    def mapping(loader, node, deep=False):
        result = {}
        for key_node, value_node in node.value:
            key = loader.construct_object(key_node, deep=deep)
            if key in result:
                raise UpgradeError("Duplicate config key; resolve it before upgrading")
            result[key] = loader.construct_object(value_node, deep=deep)
        return result
    UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, mapping)
    cfg = yaml.load(text, Loader=UniqueLoader)
    if not isinstance(cfg, dict):
        raise UpgradeError("config.yaml must be a mapping")
    return cfg


def read_config(home: Path) -> dict:
    return parse_config((home / "config.yaml").read_text(encoding="utf-8-sig"))


def home_profiles(home: Path) -> list[Path]:
    if home.parent.name.lower() == "profiles":
        raise UpgradeError("A named profile was selected as the root; resolve its shared runtime/default home first")
    result = [home]
    profiles = home / "profiles"
    if profiles.exists():
        for profile in sorted(profiles.iterdir()):
            if profile.is_dir() and (profile / "config.yaml").is_file():
                result.append(profile)
    return result


def validate_model_config(cfg: dict) -> dict:
    model = cfg.get("model")
    if not isinstance(model, dict) or not isinstance(model.get("default"), str) or not model["default"].strip():
        raise UpgradeError("model.default must identify the selected model")
    provider = model.get("provider")
    if not isinstance(provider, str) or not provider.strip():
        raise UpgradeError("model.provider must identify the selected provider")
    providers = cfg.get("providers", {})
    if not isinstance(providers, dict):
        raise UpgradeError("providers must be a mapping")
    if provider.startswith("custom:") and not isinstance(providers.get(provider.split(":", 1)[1]), dict):
        raise UpgradeError("The selected custom provider has no configuration")
    for value in providers.values():
        if not isinstance(value, dict):
            raise UpgradeError("Each provider must be a mapping")
        models = value.get("models", {})
        if isinstance(models, list):
            if not all(isinstance(item, str) and item.strip() for item in models):
                raise UpgradeError("Provider model lists must contain model ID strings")
        elif isinstance(models, dict):
            if not all(isinstance(key, str) and key.strip() for key in models):
                raise UpgradeError("Provider model maps must use model ID keys")
        else:
            raise UpgradeError("Provider models must be a list or mapping")
    return {"model_config_valid": True}


def protected_config(cfg: dict) -> dict:
    # These sections are user-owned in their entirety, including their absence.
    return {k: cfg[k] for k in (
        "model", "providers", "models", "custom_providers", "mcp_servers", "mcp",
        "plugins", "plugin_config", "plugin_settings", "credentials", "secrets",
    ) if k in cfg}


def config_contains(original: object, current: object, *, exact: bool = False) -> bool:
    """Compare values without treating false/0, null/missing or list/map as equivalent."""
    if isinstance(original, dict):
        return (isinstance(current, dict)
                and (not exact or original.keys() == current.keys())
                and all(key in current and config_contains(value, current[key], exact=exact)
                        for key, value in original.items()))
    if isinstance(original, list):
        return (isinstance(current, list) and len(original) == len(current)
                and all(config_contains(a, b, exact=True) for a, b in zip(original, current)))
    return type(original) is type(current) and original == current


def assert_config_preserved(before: dict, after: dict) -> None:
    if not config_contains(protected_config(before), protected_config(after), exact=True):
        raise UpgradeError("Upgrade changed protected model/provider, credential, MCP or plugin settings; rollback required")
    # Only Hermes owns the schema stamp. Every other existing key/value is retained.
    original = {key: value for key, value in before.items() if key != "_config_version"}
    if not config_contains(original, after):
        raise UpgradeError("Upgrade changed an existing config value; rollback required")


# Reviewed runtime-only additions. Do not copy model/provider defaults, credentials,
# MCP or plugin definitions from a fresh-install template into an existing profile.
UPGRADE_DEFAULT_PATHS = (
    ("platform_toolsets", "cli"),
    ("terminal", "cwd"), ("terminal", "timeout"), ("terminal", "home_mode"),
    ("platforms", "api_server", "extra", "host"),
    ("compression", "enabled"),
    ("memory", "memory_enabled"), ("memory", "user_profile_enabled"),
    ("security", "allow_lazy_installs"),
)


def merge_config_defaults(home: Path, template: Path) -> list[str]:
    """Add only absent reviewed paths, preserving explicit null/false/empty values."""
    from ruamel.yaml import YAML
    from ruamel.yaml.comments import CommentedMap

    path = home / "config.yaml"
    original_bytes = path.read_bytes()
    original_text = original_bytes.decode("utf-8-sig")
    before = parse_config(original_text)
    defaults = parse_config(template.read_text(encoding="utf-8-sig"))
    yaml = YAML(typ="rt")
    # Match the YAML 1.1 semantics used by Hermes' PyYAML reader (e.g. yes, 0755).
    yaml.version = (1, 1)
    yaml.preserve_quotes = True
    yaml.line_break = "\r\n" if b"\r\n" in original_bytes else "\n"
    current = yaml.load(original_text)
    added = []
    for keys in UPGRADE_DEFAULT_PATHS:
        value = defaults
        for key in keys:
            if not isinstance(value, dict) or key not in value:
                raise UpgradeError("Upgrade template is missing a required runtime default")
            value = value[key]
        node = current
        for key in keys[:-1]:
            if key not in node:
                node[key] = CommentedMap()
            node = node[key]
            if not isinstance(node, dict):
                break  # A present null, scalar or list is an explicit user choice.
        else:
            if keys[-1] not in node:
                node[keys[-1]] = copy.deepcopy(value)
                added.append(".".join(keys))
    if not added:
        return []
    output = io.StringIO()
    yaml.dump(current, output)
    rendered = output.getvalue()
    # Also catches alias side effects and serializer changes before touching the file.
    assert_config_preserved(before, parse_config(rendered))
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", newline="", dir=home,
                                         prefix=".config-upgrade-", suffix=".tmp", delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(rendered)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, path.stat().st_mode)
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return added


def resolved_env(home: Path) -> dict[str, str]:
    from dotenv import dotenv_values
    env = dict(os.environ)
    env.update({k: v for k, v in dotenv_values(home / ".env").items() if v is not None})
    return env


def inspect_home(home: Path) -> dict:
    profiles = home_profiles(home)
    from dotenv import dotenv_values
    for profile in profiles:
        local_env = dotenv_values(profile / ".env")
        for name in ("HERMES_CONFIG", "HERMES_ENV", "HERMES_PROFILE", "HERMES_PROFILE_NAME"):
            if os.environ.get(name) or local_env.get(name):
                raise UpgradeError("External config/env/profile selectors need a reviewed deployment adapter")
        if local_env.get("HERMES_HOME") and Path(local_env["HERMES_HOME"]).resolve() != profile.resolve():
            raise UpgradeError(".env redirects HERMES_HOME outside the backed-up profile")
        cfg = read_config(profile)
        gateway = cfg.get("gateway", {}) or {}
        if not isinstance(gateway, dict):
            raise UpgradeError("Unsupported gateway config shape")
        if gateway.get("multiplex_profiles") is False or gateway.get("standalone") is True:
            raise UpgradeError("Standalone/multiplex opt-out topology needs a separate reviewed migration")
    # Changing pre-multiplex deployments with named profiles can change ingress ownership.
    installed = installed_version()
    if len(profiles) > 1 and version_tuple(installed) < version_tuple("0.21.4"):
        raise UpgradeError("Named profiles on this older runtime require gateway topology review before upgrading")
    return {"version": installed, "homes": [str(p) for p in profiles]}


def installed_version() -> str:
    metadata_version = importlib.metadata.version("hermes-agent")
    try:
        if metadata_version != "0.0.0":
            return stable_version(metadata_version)
        import hermes_cli
        source = Path(hermes_cli.__file__).resolve().parent.parent
        return source_identity(source)["version"]
    except VersionError as exc:
        raise UpgradeError(str(exc)) from exc


def migrate(home: Path, backup: Path, template: Path) -> dict:
    before = read_config(backup)
    env_before = resolved_env(backup)
    # Use the new official migration engine, in a fresh process for EACH profile.
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        from hermes_cli.config import migrate_config
        result = migrate_config(interactive=False, quiet=True)
    if result.get("warnings"):
        raise UpgradeError("Official config migration reported warnings; rollback required for review")
    after = read_config(home)
    assert_config_preserved(before, after)
    # .env formatting may be normalized officially; semantic credential values must remain.
    env_after = resolved_env(home)
    from dotenv import dotenv_values
    original_env = dotenv_values(backup / ".env")
    current_env = dotenv_values(home / ".env")
    for key, value in original_env.items():
        if key not in current_env or current_env[key] != value or env_before.get(key) != env_after.get(key):
            raise UpgradeError("Migration changed an existing .env value; rollback required")
    added = merge_config_defaults(home, template)
    return {"migrated": True, "config_defaults_added": added}


def verify_runtime(source: Path, expected: str, home: Path) -> dict:
    import hermes_cli
    from hermes_constants import get_hermes_home
    if Path(hermes_cli.__file__).resolve().parent != (source / "hermes_cli").resolve():
        raise UpgradeError("Hermes imports do not come from the final runtime source directory")
    try:
        identity = source_identity(source, expected_version=expected)
    except VersionError as exc:
        raise UpgradeError("Installed Hermes version differs from bundle manifest: " + str(exc)) from exc
    if importlib.metadata.version("hermes-agent") != identity["distribution_version"]:
        raise UpgradeError("Installed Hermes version differs from bundle manifest")
    if identity["commit"]:
        from hermes_cli.version_info import get_version_info
        runtime = get_version_info()
        if runtime.base_version != expected or runtime.commit != identity["commit"]:
            raise UpgradeError("Hermes runtime identity differs from the packaged source")
    if get_hermes_home().resolve() != home.resolve():
        raise UpgradeError("Resolved Hermes home changed")
    return {"version": expected, "source_verified": True}


def endpoint(home: Path) -> tuple[str, str]:
    # Official resolution includes env > YAML > legacy gateway.json and scoped credentials.
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        from dotenv import load_dotenv
        load_dotenv(home / ".env", override=True)
        from gateway.config import load_gateway_config, Platform
        cfg = load_gateway_config()
        api = cfg.platforms.get(Platform.API_SERVER)
    if api is None or not api.enabled:
        raise UpgradeError("API server is disabled; this upgrader requires authenticated API readiness")
    extra = api.extra
    key = str(extra.get("key") or os.environ.get("API_SERVER_KEY") or "")
    if len(key) < 16 or key.lower() in {"clawpanel-local", "change-me-please"}:
        raise UpgradeError("Existing API_SERVER_KEY is missing/weak; set it before upgrading")
    port = int(extra.get("port") or os.environ.get("API_SERVER_PORT") or 8642)
    host = str(extra.get("host") or os.environ.get("API_SERVER_HOST") or "127.0.0.1")
    if host in {"0.0.0.0", "localhost"}:
        host = "127.0.0.1"
    elif host == "::":
        host = "::1"
    if host not in {"127.0.0.1", "::1"} or not 1 <= port <= 65535:
        raise UpgradeError("Non-loopback-only API binding needs an explicitly reviewed health adapter")
    if ":" in host:
        host = f"[{host}]"
    return f"http://{host}:{port}", key


def health(home: Path, expected: str, timeout: int) -> dict:
    base, key = endpoint(home)
    # Never honor proxies or redirects when transmitting the local authentication key.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            def get(path: str, auth: bool = False) -> dict:
                headers = {"Authorization": "Bearer " + key} if auth else {}
                with opener.open(urllib.request.Request(base + path, headers=headers), timeout=3) as response:
                    return json.load(response)
            public = get("/health")
            details = get("/health/detailed", True)
            if (public.get("platform") == "hermes-agent" and public.get("version") == expected
                    and details.get("version") == expected and details.get("status") == "ok"
                    and details.get("readiness", {}).get("status") == "ok"
                    and details.get("gateway_state") == "running"):
                api = details.get("platforms", {}).get("api_server", {})
                if str(api.get("state", api.get("status", ""))).lower() in {"running", "connected", "ok"}:
                    return {"healthy": True, "pid": int(details["pid"])}
        except Exception:
            pass
        time.sleep(1)
    raise UpgradeError("Authenticated gateway readiness failed; rollback required")


def tree_inventory(root: Path) -> dict:
    if not root.is_dir() or root.is_symlink():
        raise UpgradeError("Snapshot tree is missing or linked")
    result = {}
    for path in root.rglob("*"):
        if path.is_symlink():
            raise UpgradeError("Snapshot links are unsupported")
        relative = path.relative_to(root).as_posix()
        if path.is_dir():
            result[relative + "/"] = "directory"
        elif path.is_file():
            result[relative] = digest(path)
        else:
            raise UpgradeError("Snapshot contains an unsupported filesystem entry")
    return result


def snapshot_inventory(backup: Path) -> dict:
    return {name: tree_inventory(backup / name) for name in ("home", "runtime", "bin")}


def snapshot(backup: Path, check: bool = False) -> dict:
    inventory = snapshot_inventory(backup)
    if not all(inventory.values()):
        raise UpgradeError("Backup is incomplete")
    file = backup / "snapshot.json"
    if check:
        if inventory != json.loads(file.read_text(encoding="utf-8")):
            raise UpgradeError("Retained backup no longer matches its cold snapshot")
    else:
        with file.open("x", encoding="utf-8") as stream:
            json.dump(inventory, stream)
            stream.flush()
            os.fsync(stream.fileno())
    return {"snapshot_verified": True}


def compare_trees(source: Path, copy: Path) -> dict:
    original = tree_inventory(source)
    copied = tree_inventory(copy)
    if original != copied:
        # Paths and categories only: never expose config values or file contents.
        differences = {
            "missing_from_copy": sorted(original.keys() - copied.keys())[:3],
            "extra_in_copy": sorted(copied.keys() - original.keys())[:3],
            "changed": sorted(path for path in original.keys() & copied.keys()
                              if original[path] != copied[path])[:3],
        }
        raise UpgradeError("Cold backup/restore verification failed: file contents differ; "
                           + json.dumps(differences, ensure_ascii=True))
    return {"identical": True}


def sync_skills() -> dict:
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        from tools.skills_sync import sync_skills as official_sync
        result = official_sync(quiet=True)
    if not result.get("total_bundled"):
        raise UpgradeError("Official skill synchronization found no bundled skills")
    return {"skills_synced": True, "user_modified_kept": len(result.get("user_modified", []))}


def pristine_bundled_skills(backup: Path) -> set[Path]:
    """Exempt ONLY whole skills identical to the backed-up original package.

    A hand-edited, extra-file or incomplete skill remains fully protected. The official
    synchronizer owns .bundled_manifest and preserves user modifications/deletions.
    """
    resources = None
    for candidate in backup.parents:
        if backup.is_relative_to(candidate / "home") and (candidate / "runtime" / "hermes-resources" / "skills").is_dir():
            resources = candidate / "runtime" / "hermes-resources" / "skills"
            break
    if resources is None:
        return set()
    result = set()
    for skill in (backup / "skills").rglob("SKILL.md"):
        relative = skill.parent.relative_to(backup / "skills")
        original = resources / relative
        if original.is_dir() and tree_inventory(skill.parent) == tree_inventory(original):
            result.add(skill.parent)
    return result


def check_preserved(home: Path, backup: Path) -> dict:
    # Runtime-generated databases/logs may legitimately change. User-authored assets may not.
    assert_config_preserved(read_config(backup), read_config(home))
    from dotenv import dotenv_values
    original_env = dotenv_values(backup / ".env")
    current_env = dotenv_values(home / ".env")
    if any(key not in current_env or current_env[key] != value for key, value in original_env.items()):
        raise UpgradeError("Startup changed an existing .env value")
    managed_skills = pristine_bundled_skills(backup)
    protected = ("skills", "plugins", "memories", "SOUL.md", "USER.md", "AGENTS.md")
    for relative in protected:
        root = backup / relative
        paths = root.rglob("*") if root.is_dir() else [root]
        for old in paths:
            if old.is_file():
                if old == backup / "skills" / ".bundled_manifest":
                    continue
                if any(old.is_relative_to(managed) for managed in managed_skills):
                    continue
                current = home / old.relative_to(backup)
                if not current.is_file() or digest(old) != digest(current):
                    raise UpgradeError("An existing user-owned asset changed during validation")
    return {"user_assets_preserved": True}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["bundle", "inspect", "migrate", "verify", "endpoint", "health", "preserved", "compare", "snapshot", "snapshot-check", "model-config", "sync-skills"])
    parser.add_argument("--home", type=Path)
    parser.add_argument("--backup", type=Path)
    parser.add_argument("--bundle", type=Path)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--template", type=Path)
    parser.add_argument("--version", default="")
    parser.add_argument("--timeout", type=int, default=90)
    parser.add_argument("--allow-same", action="store_true")
    args = parser.parse_args()
    try:
        if args.action == "bundle":
            result = verify_bundle(args.bundle, args.version, args.allow_same)
        elif args.action == "inspect":
            result = inspect_home(args.home)
        elif args.action == "migrate":
            if args.template is None:
                raise UpgradeError("Config migration requires the verified bundle template")
            result = migrate(args.home, args.backup, args.template)
        elif args.action == "verify":
            result = verify_runtime(args.source, args.version, args.home)
        elif args.action == "endpoint":
            base, key = endpoint(args.home)
            result = {"url": base, "port": int(base.rsplit(":", 1)[1]),
                      "auth_fingerprint": hashlib.sha256(key.encode()).hexdigest()}
        elif args.action == "health":
            result = health(args.home, args.version, args.timeout)
        elif args.action in ("snapshot", "snapshot-check"):
            result = snapshot(args.backup, args.action == "snapshot-check")
        elif args.action == "sync-skills":
            result = sync_skills()
        elif args.action == "model-config":
            result = validate_model_config(read_config(args.home))
        elif args.action == "compare":
            result = compare_trees(args.home, args.backup)
        else:
            result = check_preserved(args.home, args.backup)
        print(json.dumps(result))
        return 0
    except UpgradeError as exc:
        print(json.dumps({"error": str(exc)}))
    except Exception as exc:
        # Exception messages may embed a YAML line, key, HTTP header or URL.
        print(json.dumps({"error": "Upgrade helper failed: " + type(exc).__name__}))
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
