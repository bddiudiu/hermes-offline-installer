# Hermes Offline Installer

[简体中文](README.zh-CN.md)

Hermes Offline Installer packages Hermes Agent with a portable Python runtime, `uv`, offline Python wheels, dashboard assets, skills, plugins, locales, and installer scripts, so Hermes can be installed without requiring end users to install Python, `uv`, or Git.

项目目标是在 Windows、macOS 和 Linux 上生成可分发的一键离线安装包。安装阶段只使用包内资源，不依赖 GitHub 或 PyPI 网络访问。

## Features

- Bundles Hermes Agent, portable Python runtime, `uv`, Python dependencies, and runtime resources.
- Installs or upgrades Hermes without overwriting existing `config.yaml` and `.env`.
- Provides Windows launch, shutdown, uninstall helpers and PATH commands.
- Supports configurable install locations through `HERMES_HOME` and `HERMES_OFFLINE_HOME`.
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

To customize install locations, set environment variables in PowerShell before running the installer:

```powershell
$env:HERMES_HOME="D:\Hermes\home"
$env:HERMES_OFFLINE_HOME="D:\Hermes\runtime"
.\installers\install_windows.ps1
```

The Windows installer stops running Hermes processes when possible, refreshes the offline runtime, writes `HERMES_HOME`, `HERMES_OFFLINE_HOME`, and `HERMES_PYTHON` to the current user's environment, and creates the `%USERPROFILE%\.hermes-venv` compatibility entry. It starts Dashboard silently after installation by default, and it does not open a Dashboard browser page. Reopen PowerShell or CMD after installation for the updated environment variables to take effect.

The installer also sets `PYTHONUTF8=1` and `PYTHONIOENCODING=utf-8`, and the Hermes shim switches to the UTF-8 code page. This avoids encoding issues when agent tools write files or parse terminal output on Chinese Windows environments.

To upgrade an existing offline installation, extract the new zip and run `install.cmd` again. The installer rebuilds the runtime and venv, updates shims, and preserves existing `config.yaml` and `.env`.

If installation reports that an old runtime or legacy `hermes.exe` shim is in use, close running Hermes or ClawPanel processes and rerun the installer. The Windows offline installer no longer copies `hermes.exe` into PATH shim directories, so launches go through `hermes.cmd` with `HERMES_PYTHON` and bundled resource environment variables set.

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
shutdown.cmd
uninstall.cmd
```

After reopening PowerShell or CMD, the PATH commands are also available:

```cmd
hermes-launch
hermes-shutdown
hermes-uninstall
```

`uninstall.cmd` stops running Hermes processes, removes the offline runtime and shims, removes Hermes user environment variables, and preserves `%USERPROFILE%\.hermes` by default. To remove Hermes user data as well:

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

Supported platform values:

```text
win-x64
linux-x64
mac-x64
mac-arm64
```

`packaging/build_wheelhouse.py` uses `HERMES_SOURCE` from `packaging/manifest.py` by default. For GitHub Actions manual runs, the `hermes_source` input can override the Hermes package spec.

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

- Runtime: `~/.hermes-offline/runtime` or `%USERPROFILE%\.hermes-offline\runtime`; override with `HERMES_OFFLINE_HOME`.
- Runtime resources: `$HERMES_OFFLINE_HOME/runtime/hermes-resources`, containing `skills`, `optional-skills`, `optional-mcps`, `locales`, `plugins`, `web_dist`, and `tui_dist`.
- Shim: `~/.local/bin/hermes` or `%USERPROFILE%\.hermes-offline\bin\hermes.cmd`.
- Hermes config: `~/.hermes/config.yaml` and `~/.hermes/.env`; on Windows, `%USERPROFILE%\.hermes\config.yaml` and `%USERPROFILE%\.hermes\.env`; override with `HERMES_HOME`.
- User plugins, skills, logs, and state follow `HERMES_HOME`.
- Bundled Agent Skills are restored from runtime resources during install or upgrade. User-modified or deleted skills are preserved according to the Hermes bundled manifest rules.
- Hermes Python: Unix shims set `HERMES_PYTHON`; the Windows installer writes `HERMES_PYTHON` to the user environment.

If Windows reports that the Hermes Python interpreter cannot be found when checking optional dependencies, repair the user environment:

```powershell
$HermesOfflineHome = if ($env:HERMES_OFFLINE_HOME) { $env:HERMES_OFFLINE_HOME } else { Join-Path $env:USERPROFILE ".hermes-offline" }
[Environment]::SetEnvironmentVariable("HERMES_OFFLINE_HOME", $HermesOfflineHome, "User")
[Environment]::SetEnvironmentVariable("HERMES_PYTHON", (Join-Path $HermesOfflineHome "runtime\venv\Scripts\python.exe"), "User")
```

Then reopen PowerShell or CMD.

## Configuration

The installer creates only minimal config and environment templates. It does not write user API keys. After installation, edit:

```text
$HERMES_HOME/.env
```

## Notes

- Installation uses only bundled resources.
- End users do not need to install Python, `uv`, or Git manually.
- This project maintains its own installer flow and does not reuse the ClawPanel installer.
