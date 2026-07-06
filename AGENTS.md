# Repository Guidelines

## Project Structure & Module Organization

This repository builds offline Hermes Agent installer bundles. Packaging code lives in `packaging/`: `build_wheelhouse.py` downloads wheels and writes manifests, while `build_bundle.py` assembles release archives. Installer entrypoints and platform helpers live in `installers/`, including Windows PowerShell/CMD scripts and the Unix shell installer. Post-install validation scripts live in `scripts/`. Default runtime configuration is in `templates/`, and review notes or maintenance plans belong in `docs/`. GitHub Actions workflows are under `.github/workflows/`.

## Build, Test, and Development Commands

Use Python 3.11+ for packaging script checks:

```bash
python -m py_compile packaging/build_wheelhouse.py packaging/build_bundle.py packaging/manifest.py packaging/read_hermes_version.py
bash -n installers/install_unix.sh scripts/verify_unix.sh
```

Build a local Linux bundle with:

```bash
python3 packaging/build_wheelhouse.py --platform linux-x64 --output build/wheelhouse
python3 packaging/build_bundle.py --platform linux-x64 --wheelhouse build/wheelhouse --output dist
```

On Windows, validate PowerShell syntax with the parser pattern used in `.github/workflows/validate.yml`.

## Coding Style & Naming Conventions

Keep scripts explicit and dependency-light. Python files use standard library-first code, 4-space indentation, typed helper functions where useful, and snake_case names. Shell scripts should remain POSIX/Bash readable, quote paths, and prefer `set -euo pipefail` for new executable flows. PowerShell functions use Verb-Noun names, PascalCase parameters, and UTF-8-safe file operations when touching user config.

## Testing Guidelines

CI currently performs syntax and compilation checks, not full end-to-end installs. When changing installers, run the relevant syntax checks plus a manual install/verify cycle for the affected platform: `scripts/verify_windows.ps1` or `scripts/verify_unix.sh`. Add focused regression checks when changing config migration, environment variables, PATH handling, or wheelhouse manifests.

## Commit & Pull Request Guidelines

Recent history uses short imperative subjects, often prefixed with `fix:` for targeted fixes, for example `Fix offline installer reliability issues` or `fix: write Windows config without UTF-8 BOM`. Keep commits scoped to one behavior. PRs should describe the affected platform, list validation commands run, note installer compatibility risks, and link issues or release tags when relevant. Include screenshots only for Dashboard-facing changes.

## Security & Configuration Tips

Never commit generated bundles, wheelhouses, secrets, `.env`, or machine-specific IDE files. Preserve existing user config during upgrades, and treat `HERMES_HOME`, `HERMES_OFFLINE_HOME`, `ZHANCLAW_*`, and PATH updates as compatibility-sensitive surfaces.
