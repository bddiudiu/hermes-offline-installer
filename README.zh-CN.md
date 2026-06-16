# Hermes Offline Installer

[English](README.md)

Hermes Offline Installer 会把 Hermes Agent、portable Python runtime、`uv`、离线 Python wheels、Dashboard 资源、skills、plugins、locales 和安装脚本打包在一起，让最终用户无需手动安装 Python、`uv` 或 Git 即可安装 Hermes。

项目目标是在 Windows、macOS 和 Linux 上生成可分发的一键离线安装包。安装阶段只使用包内资源，不依赖 GitHub 或 PyPI 网络访问。

## 功能

- 打包 Hermes Agent、portable Python runtime、`uv`、Python 依赖和运行时资源。
- 支持安装或升级 Hermes，并保留已有的 `config.yaml` 和 `.env`。
- 提供 Windows 启动、停止、卸载辅助脚本和 PATH 命令。
- 支持通过 `HERMES_HOME` 和 `HERMES_OFFLINE_HOME` 自定义安装位置。
- 导出 Hermes runtime resources，包括内置 Agent Skills、optional skills catalog、optional MCP catalog、locales、bundled plugins、Dashboard `web_dist` 和 Dashboard TUI `tui_dist`。

## 产物

Release 产物采用以下命名规则：

- `hermes-offline-installer-win-x64.zip`
- `hermes-offline-installer-linux-x64.tar.gz`
- `hermes-offline-installer-mac-x64.tar.gz`
- `hermes-offline-installer-mac-arm64.tar.gz`

当前 GitHub Actions release workflow 优先构建 `win-x64`。打包脚本已经支持 `linux-x64`、`mac-x64` 和 `mac-arm64` 平台参数，可用于本地测试和后续扩展 release matrix。

## 安装

### Windows

下载并解压 `hermes-offline-installer-win-x64.zip`，然后在解压目录运行安装入口：

```cmd
install.cmd
```

兼容入口仍然可用：

```cmd
install_windows.cmd
```

如需自定义安装位置，可先在 PowerShell 中设置环境变量，再运行安装脚本：

```powershell
$env:HERMES_HOME="D:\Hermes\home"
$env:HERMES_OFFLINE_HOME="D:\Hermes\runtime"
.\installers\install_windows.ps1
```

Windows 安装器会尽可能停止正在运行的 Hermes 进程，刷新离线 runtime，把 `HERMES_HOME`、`HERMES_OFFLINE_HOME` 和 `HERMES_PYTHON` 写入当前用户环境变量，并创建 `%USERPROFILE%\.hermes-venv` 兼容入口。安装完成后会默认静默启动 Dashboard，但不会自动打开 Dashboard 网页。安装完成后重新打开 PowerShell 或 CMD，新的环境变量才会生效。

安装器还会设置 `PYTHONUTF8=1` 和 `PYTHONIOENCODING=utf-8`，并在 Hermes shim 中切换到 UTF-8 code page，避免 agent tools 在中文 Windows 环境下写入文件或解析终端输出时遇到编码问题。

如需升级已有离线安装，解压新版 zip 后再次运行 `install.cmd`。安装器会重建 runtime 和 venv，更新 shims，并保留已有 `config.yaml` 和 `.env`。

如果安装时提示旧 runtime 或旧 `hermes.exe` shim 正被占用，请关闭正在运行的 Hermes 或 ClawPanel 进程后重新安装。Windows 离线安装不再把 `hermes.exe` 复制到 PATH shim 目录，避免它绕过 `hermes.cmd` 中设置的 `HERMES_PYTHON` 和 bundled resources 环境变量。

自动化运行时，可关闭重新打开窗口和暂停行为：

```cmd
set HERMES_NO_RELAUNCH=1
set HERMES_NO_PAUSE=1
install_windows.cmd
```

如需安装完成后跳过 Dashboard 启动：

```cmd
set HERMES_NO_START_DASHBOARD=1
install_windows.cmd
```

如需打开可见的 Dashboard 命令行窗口以便排查日志：

```cmd
set HERMES_START_DASHBOARD_VISIBLE=1
install_windows.cmd
```

安装后可以使用包内辅助脚本：

```cmd
launch.cmd
shutdown.cmd
uninstall.cmd
```

重新打开 PowerShell 或 CMD 后，也可以直接使用 PATH 命令：

```cmd
hermes-launch
hermes-shutdown
hermes-uninstall
```

`uninstall.cmd` 会停止正在运行的 Hermes 进程，删除离线 runtime 和 shims，并清理 Hermes 用户环境变量；默认保留 `%USERPROFILE%\.hermes` 用户配置。如需同时删除用户配置：

```cmd
set HERMES_UNINSTALL_REMOVE_HOME=1
uninstall.cmd
```

验证安装：

```powershell
hermes version
hermes dashboard
```

### macOS / Linux

解压平台归档并运行 Unix 安装脚本：

```bash
tar -xzf hermes-offline-installer-<platform>.tar.gz
cd hermes-offline-installer-<platform>
./installers/install_unix.sh
```

如需自定义安装位置：

```bash
HERMES_HOME=/data/hermes \
HERMES_OFFLINE_HOME=/data/hermes-runtime \
./installers/install_unix.sh
```

`HERMES_HOME` 控制 Hermes 配置、插件、skills、日志和状态文件位置。`HERMES_OFFLINE_HOME` 控制离线 runtime、venv 和 shim 位置。

重新打开终端后验证：

```bash
hermes version
hermes dashboard
```

## 构建

推荐通过 GitHub Actions 构建发布产物。CI 会使用 `uv python install 3.12.13` 准备 portable Python runtime，下载 wheels 到离线 wheelhouse，导出 Hermes runtime resources，并构建最终平台安装包。

本地构建示例：

```bash
python3 packaging/build_wheelhouse.py --platform linux-x64 --output build/wheelhouse
python3 packaging/build_bundle.py --platform linux-x64 --wheelhouse build/wheelhouse --output dist
```

支持的平台参数：

```text
win-x64
linux-x64
mac-x64
mac-arm64
```

`packaging/build_wheelhouse.py` 默认使用 `packaging/manifest.py` 中的 `HERMES_SOURCE`。GitHub Actions 手动运行时，可以通过 `hermes_source` 输入覆盖 Hermes package spec。

离线 wheelhouse 包含 `hermes dashboard` 所需依赖，包括 `fastapi`、`python-multipart`、`uvicorn` 和 `websockets`。构建器还会从 Hermes 源码导出 runtime resources：

- 内置 Agent Skills
- optional skills catalog
- optional MCP catalog
- locales
- bundled plugins
- Dashboard `web_dist`
- Dashboard TUI `tui_dist`

安装器会把这些资源复制到 `$HERMES_OFFLINE_HOME/runtime/hermes-resources`，并把内置 Agent Skills 同步到 `$HERMES_HOME/skills`。Dashboard 的 Agent Skills 面板会读取这个目录。

## 安装位置

- Runtime：`~/.hermes-offline/runtime` 或 `%USERPROFILE%\.hermes-offline\runtime`，可通过 `HERMES_OFFLINE_HOME` 覆盖。
- Runtime resources：`$HERMES_OFFLINE_HOME/runtime/hermes-resources`，包含 `skills`、`optional-skills`、`optional-mcps`、`locales`、`plugins`、`web_dist` 和 `tui_dist`。
- Shim：`~/.local/bin/hermes` 或 `%USERPROFILE%\.hermes-offline\bin\hermes.cmd`。
- Hermes 配置：`~/.hermes/config.yaml` 和 `~/.hermes/.env`；Windows 为 `%USERPROFILE%\.hermes\config.yaml` 和 `%USERPROFILE%\.hermes\.env`；可通过 `HERMES_HOME` 覆盖。
- 用户插件、skills、日志和状态文件跟随 `HERMES_HOME`。
- 内置 Agent Skills 会在安装或升级时从 runtime resources 恢复。用户修改或删除过的 skills 会按照 Hermes bundled manifest 规则保留。
- Hermes Python：Unix shims 会设置 `HERMES_PYTHON`；Windows 安装器会把 `HERMES_PYTHON` 写入用户环境变量。

如果 Windows 在检查可选依赖时提示找不到 Hermes Python 解释器，可修复用户环境变量：

```powershell
$HermesOfflineHome = if ($env:HERMES_OFFLINE_HOME) { $env:HERMES_OFFLINE_HOME } else { Join-Path $env:USERPROFILE ".hermes-offline" }
[Environment]::SetEnvironmentVariable("HERMES_OFFLINE_HOME", $HermesOfflineHome, "User")
[Environment]::SetEnvironmentVariable("HERMES_PYTHON", (Join-Path $HermesOfflineHome "runtime\venv\Scripts\python.exe"), "User")
```

然后重新打开 PowerShell 或 CMD。

## 配置

安装器只创建最小配置和环境变量模板，不写入用户 API keys。安装完成后编辑：

```text
$HERMES_HOME/.env
```

## 说明

- 安装阶段只使用包内资源。
- 最终用户不需要手动安装 Python、`uv` 或 Git。
- 本项目维护独立安装流程，不复用 ClawPanel installer。
