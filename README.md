# Hermes Offline Installer

[简体中文](README.zh-CN.md)

Hermes Offline Installer packages Hermes Agent with a portable Python runtime, `uv`, offline Python wheels, dashboard assets, skills, plugins, locales, and installer scripts, so Hermes can be installed without requiring end users to install Python, `uv`, or Git.

The project builds redistributable one-click offline installers for Windows, macOS, and Linux. The install phase uses only bundled resources and does not require GitHub or PyPI network access.

## Features

- Bundles Hermes Agent, portable Python runtime, `uv`, Python dependencies, and runtime resources.
- Installs or upgrades Hermes, preserving `.env` and ensuring `config.yaml` defaults to the `zhan_ai` model provider without overwriting unrelated settings.
- Provides Windows launch, shutdown, uninstall helpers and PATH commands.
- Provides a Windows `repair.cmd` helper that rebuilds the runtime, venv, and shims from the extracted bundle.
- Supports configurable install locations through `HERMES_HOME` and `HERMES_OFFLINE_HOME`.
- Supports portable mode through `HERMES_PORTABLE_MODE=1` or `install.cmd -Portable`, keeping runtime and user data inside the extracted directory.
- Hermes shims default common third-party caches to `$HERMES_HOME/cache`, avoiding surprise writes to the system drive from HuggingFace, Playwright, tiktoken, Torch, and similar libraries.
- Exports Hermes runtime resources, including bundled Agent Skills, optional skills catalog, optional MCP catalog, locales, bundled plugins, Dashboard `web_dist`, and Dashboard TUI `tui_dist`.

## Artifacts

Release artifacts follow this naming convention:

- `hermes-offline-installer-win-x64.zip`
- `hermes-offline-installer-linux-x64.tar.gz`
- `hermes-offline-installer-mac-x64.tar.gz`
- `hermes-offline-installer-mac-arm64.tar.gz`

The current GitHub Actions release workflow builds `win-x64` first. The packaging scripts already accept `linux-x64`, `mac-x64`, and `mac-arm64` platform targets for local testing and future release matrix expansion.

## Installation

### Windows

Download and unzip `hermes-offline-installer-win-x64.zip`, then run the installer from the extracted directory:

```cmd
install.cmd
```

The compatibility entry remains available:

```cmd
install_windows.cmd
```

For a portable install that does not write user-level environment variables or the user `Path`, run:

```cmd
install.cmd -Portable
```

Or use the environment variable form:

```cmd
set HERMES_PORTABLE_MODE=1
install.cmd
```

The default Windows install uses fixed product directories: Hermes config, skills, logs, and caches live under `C:\ProgramData\SSC\Hermes`, and the offline runtime lives under `C:\Program Files\StarSoftComm\ZhanClaw\Hermes`. Default mode no longer creates `%USERPROFILE%\.hermes` or `%USERPROFILE%\.hermes-offline`. Because the runtime is under `Program Files`, default install and uninstall require administrator rights; `install.cmd` and `uninstall.cmd` automatically request UAC elevation when needed.

Portable mode defaults to `.hermes-offline` for the runtime and `.hermes` for Hermes user data inside the extracted directory. After installation, keep using `launch.cmd`, `shutdown.cmd`, and `uninstall.cmd` from that same directory; the scripts automatically detect the local portable install.

To customize install locations, set environment variables in PowerShell before running the installer:

```powershell
$env:HERMES_HOME="D:\Hermes\home"
$env:HERMES_OFFLINE_HOME="D:\Hermes\runtime"
.\installers\install_windows.ps1
```

The Windows installer stops running Hermes processes when possible, refreshes the offline runtime, derives the full Hermes user environment from `HERMES_HOME` and `HERMES_OFFLINE_HOME`, and creates shims only in `%HERMES_OFFLINE_HOME%\bin`. It grants standard Users modify access to `C:\ProgramData\SSC\Hermes` so non-admin Dashboard runs can write config, logs, and caches. It starts Dashboard silently after installation by default, and it does not open a Dashboard browser page. Reopen PowerShell or CMD after installation for the updated environment variables to take effect.

The installer also sets `PYTHONUTF8=1` and `PYTHONIOENCODING=utf-8`, and the Hermes shim switches to the UTF-8 code page. This avoids encoding issues when agent tools write files or parse terminal output on Chinese Windows environments.

Complete installer environment variable list:

| Variable | Source |
| --- | --- |
| `HERMES_HOME` | User-provided value; defaults to `C:\ProgramData\SSC\Hermes` on Windows and `$HOME/.hermes` on Unix |
| `HERMES_OFFLINE_HOME` | User-provided value; defaults to `C:\Program Files\StarSoftComm\ZhanClaw\Hermes` on Windows and `$HOME/.hermes-offline` on Unix |
| `HERMES_PYTHON` | `$HERMES_OFFLINE_HOME/runtime/venv/Scripts/python.exe` on Windows or `$HERMES_OFFLINE_HOME/runtime/venv/bin/python` on Unix |
| `HERMES_BUNDLED_SKILLS` | `$HERMES_OFFLINE_HOME/runtime/hermes-resources/skills` |
| `HERMES_OPTIONAL_SKILLS` | `$HERMES_OFFLINE_HOME/runtime/hermes-resources/optional-skills` |
| `HERMES_OPTIONAL_MCPS` | `$HERMES_OFFLINE_HOME/runtime/hermes-resources/optional-mcps` |
| `HERMES_BUNDLED_LOCALES` | `$HERMES_OFFLINE_HOME/runtime/hermes-resources/locales` |
| `HERMES_BUNDLED_PLUGINS` | `$HERMES_OFFLINE_HOME/runtime/hermes-resources/plugins` |
| `HERMES_WEB_DIST` | `$HERMES_OFFLINE_HOME/runtime/hermes-resources/web_dist` |
| `HERMES_TUI_DIR` | `$HERMES_OFFLINE_HOME/runtime/hermes-resources/tui_dist` |
| `PYTHONUTF8` | `1` in the Windows user environment and shim |
| `PYTHONIOENCODING` | `utf-8` in the Windows user environment and shim |

End users only need to set `HERMES_HOME` and `HERMES_OFFLINE_HOME` before running a custom-location install. Windows writes all 12 variables above to the current user's environment and appends `%HERMES_OFFLINE_HOME%\bin` to the current user's `Path`; when it detects old `%USERPROFILE%\.hermes` or `%USERPROFILE%\.hermes-offline` defaults, it treats them as legacy values, migrates to the new product directories, and removes the old `%USERPROFILE%\.hermes-offline\bin` PATH entry. Unix does not modify shell startup files; the generated `~/.local/bin/hermes` shim exports the Hermes variables.

To upgrade an existing offline installation, extract the new zip and run `install.cmd` again. The installer rebuilds the runtime and venv, updates shims, preserves `.env`, and only patches the default model provider plus the `zhan_ai` provider block in `config.yaml`.

If installation reports that an old runtime or legacy `hermes.exe` shim is in use, close running Hermes or ClawPanel processes and rerun the installer. The Windows offline installer writes a `hermes.exe` wrapper into `%HERMES_OFFLINE_HOME%\bin` for callers that only recognize `.exe` commands. The wrapper forwards to `hermes.cmd` in the same directory, so launches still use the `HERMES_PYTHON` and bundled resource environment variables set by `hermes.cmd`.

For automation, disable relaunch and pause behavior:

```cmd
set HERMES_NO_RELAUNCH=1
set HERMES_NO_PAUSE=1
install_windows.cmd
```

To skip Dashboard startup after install:

```cmd
set HERMES_NO_START_DASHBOARD=1
install_windows.cmd
```

To start Dashboard in a visible command window for troubleshooting:

```cmd
set HERMES_START_DASHBOARD_VISIBLE=1
install_windows.cmd
```

After installation, use the bundled helpers:

```cmd
launch.cmd
repair.cmd
shutdown.cmd
uninstall.cmd
```

`repair.cmd` rebuilds the runtime, venv, and shims using the current extracted bundle. It skips Dashboard startup by default. To repair and start Dashboard immediately:

```cmd
set HERMES_REPAIR_START_DASHBOARD=1
repair.cmd
```

After reopening PowerShell or CMD, the PATH commands are also available:

```cmd
hermes-launch
hermes-shutdown
hermes-uninstall
```

`uninstall.cmd` stops running Hermes processes, removes the offline runtime and shims, removes Hermes user environment variables, and preserves `HERMES_HOME` by default. To remove Hermes user data as well:

```cmd
set HERMES_UNINSTALL_REMOVE_HOME=1
uninstall.cmd
```

Verify the installation:

```powershell
hermes version
hermes dashboard
```

### macOS / Linux

Extract the platform archive and run the Unix installer:

```bash
tar -xzf hermes-offline-installer-<platform>.tar.gz
cd hermes-offline-installer-<platform>
./installers/install_unix.sh
```

To customize install locations:

```bash
HERMES_HOME=/data/hermes \
HERMES_OFFLINE_HOME=/data/hermes-runtime \
./installers/install_unix.sh
```

Unix also supports portable mode:

```bash
HERMES_PORTABLE_MODE=1 ./installers/install_unix.sh
```

In portable mode, the shim is written under `$HERMES_OFFLINE_HOME/bin`, defaulting to `.hermes-offline/bin/hermes` inside the extracted directory, and Hermes user data defaults to `.hermes` inside the extracted directory.

`HERMES_HOME` controls Hermes configuration, plugins, skills, logs, and state. `HERMES_OFFLINE_HOME` controls the offline runtime, venv, and shim location.

Reopen the terminal and verify:

```bash
hermes version
hermes dashboard
```

## Build

The recommended release path is GitHub Actions. CI prepares the portable Python runtime with `uv python install 3.12.13`, downloads wheels into an offline wheelhouse, exports Hermes runtime resources, and builds the final platform bundle.

Local build example:

```bash
python3 packaging/build_wheelhouse.py --platform linux-x64 --output build/wheelhouse
python3 packaging/build_bundle.py --platform linux-x64 --wheelhouse build/wheelhouse --output dist
```

To build a Chinese community runtime fork or a desktop-prebaked extra set, override `HERMES_SOURCE` and `--extras`:

```bash
HERMES_SOURCE="hermes-agent @ git+https://github.com/Eynzof/Hermes-CN-Core.git" \
python3 packaging/build_wheelhouse.py \
  --platform win-x64 \
  --extras cn-desktop \
  --output build/wheelhouse-cn

python3 packaging/build_bundle.py \
  --platform win-x64 \
  --wheelhouse build/wheelhouse-cn \
  --output dist
```

The installer reads `wheelhouse/manifest.json` and installs the extras recorded at build time, for example `hermes-agent[cn-desktop]`, instead of hard-coding `hermes-agent[all]`.

Supported platform values:

```text
win-x64
linux-x64
mac-x64
mac-arm64
```

`packaging/build_wheelhouse.py` uses `HERMES_SOURCE` from `packaging/manifest.py` by default. For GitHub Actions manual runs, the `hermes_source` input can override the Hermes package spec.

The wheelhouse manifest records the actual `hermes_version`, `hermes_install_spec`, `hermes_source_commit`, and extras. The final bundle `manifest.json` carries these fields forward so a zip can be inspected for its real Hermes version.

The offline wheelhouse includes dependencies needed by `hermes dashboard`, including `fastapi`, `python-multipart`, `uvicorn`, and `websockets`. The builder also exports runtime resources from Hermes source:

- bundled Agent Skills
- optional skills catalog
- optional MCP catalog
- locales
- bundled plugins
- Dashboard `web_dist`
- Dashboard TUI `tui_dist`

Installers copy these resources to `$HERMES_OFFLINE_HOME/runtime/hermes-resources` and sync bundled Agent Skills to `$HERMES_HOME/skills`. Dashboard reads the Agent Skills panel from that directory.

## Install Layout

- Runtime: `C:\Program Files\StarSoftComm\ZhanClaw\Hermes\runtime` on Windows or `~/.hermes-offline/runtime` on Unix; override with `HERMES_OFFLINE_HOME`.
- Runtime resources: `$HERMES_OFFLINE_HOME/runtime/hermes-resources`, containing `skills`, `optional-skills`, `optional-mcps`, `locales`, `plugins`, `web_dist`, and `tui_dist`.
- Shim: `~/.local/bin/hermes` on Unix; `%HERMES_OFFLINE_HOME%\bin\hermes.cmd` on Windows.
- Portable mode shim: `<extracted-dir>\.hermes-offline\bin\hermes.cmd` on Windows; `<extracted-dir>/.hermes-offline/bin/hermes` on Unix.
- Hermes config: `C:\ProgramData\SSC\Hermes\config.yaml` and `C:\ProgramData\SSC\Hermes\.env` on Windows, or `~/.hermes/config.yaml` and `~/.hermes/.env` on Unix; override with `HERMES_HOME`.
- User plugins, skills, logs, and state follow `HERMES_HOME`.
- Common third-party caches default to `$HERMES_HOME/cache` through the Hermes shims, including `HF_HOME`, `HUGGINGFACE_HUB_CACHE`, `TORCH_HOME`, `TIKTOKEN_CACHE_DIR`, `MPLCONFIGDIR`, `NLTK_DATA`, `PLAYWRIGHT_BROWSERS_PATH`, and temp directories.
- Bundled Agent Skills are restored from runtime resources during install or upgrade. User-modified or deleted skills are preserved according to the Hermes bundled manifest rules.
- Hermes Python: `HERMES_PYTHON` is derived from `$HERMES_OFFLINE_HOME/runtime/venv`; Unix shims export the Hermes environment variables listed above, and the Windows installer writes them to the user environment.

If Windows reports that the Hermes Python interpreter cannot be found when checking optional dependencies, rebuild the full user environment from `HERMES_HOME` and `HERMES_OFFLINE_HOME`:

```powershell
$HermesHome = if ($env:HERMES_HOME) { $env:HERMES_HOME } else { "C:\ProgramData\SSC\Hermes" }
$HermesOfflineHome = if ($env:HERMES_OFFLINE_HOME) { $env:HERMES_OFFLINE_HOME } else { "C:\Program Files\StarSoftComm\ZhanClaw\Hermes" }
$HermesResources = Join-Path $HermesOfflineHome "runtime\hermes-resources"
$HermesEnv = [ordered]@{
  "HERMES_HOME" = $HermesHome
  "HERMES_OFFLINE_HOME" = $HermesOfflineHome
  "HERMES_PYTHON" = (Join-Path $HermesOfflineHome "runtime\venv\Scripts\python.exe")
  "HERMES_BUNDLED_SKILLS" = (Join-Path $HermesResources "skills")
  "HERMES_OPTIONAL_SKILLS" = (Join-Path $HermesResources "optional-skills")
  "HERMES_OPTIONAL_MCPS" = (Join-Path $HermesResources "optional-mcps")
  "HERMES_BUNDLED_LOCALES" = (Join-Path $HermesResources "locales")
  "HERMES_BUNDLED_PLUGINS" = (Join-Path $HermesResources "plugins")
  "HERMES_WEB_DIST" = (Join-Path $HermesResources "web_dist")
  "HERMES_TUI_DIR" = (Join-Path $HermesResources "tui_dist")
  "PYTHONUTF8" = "1"
  "PYTHONIOENCODING" = "utf-8"
}
foreach ($Entry in $HermesEnv.GetEnumerator()) {
  [Environment]::SetEnvironmentVariable($Entry.Key, $Entry.Value, "User")
}
```

Then reopen PowerShell or CMD.

## Configuration

The installer configures the default model provider as `zhan_ai`. If `config.yaml` already exists, the installer leaves unrelated settings intact but ensures `model.provider` is `custom:zhan_ai` and `providers.zhan_ai` is present. Model service settings are read from Windows user environment variables:

```powershell
[Environment]::SetEnvironmentVariable("ZHANCLAW_BASE_URL", "https://your-zhanclaw-endpoint/v1", "User")
[Environment]::SetEnvironmentVariable("ZHANCLAW_API_KEY", "your-api-key", "User")
```

After setting them, reopen PowerShell / CMD or restart ClawPanel / Hermes gateway. `$HERMES_HOME/.env` remains for non-model installer settings and does not store `ZHANCLAW_API_KEY`.

## Notes

- Installation uses only bundled resources.
- End users do not need to install Python, `uv`, or Git manually.
- This project maintains its own installer flow and does not reuse the ClawPanel installer.
