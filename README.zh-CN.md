# Hermes Offline Installer

[English](README.md)

Hermes Offline Installer 会把 Hermes Agent、portable Python runtime、`uv`、离线 Python wheels、Dashboard 资源、skills、plugins、locales 和安装脚本打包在一起，让最终用户无需手动安装 Python、`uv` 或 Git 即可安装 Hermes。

项目目标是在 Windows、macOS 和 Linux 上生成可分发的一键离线安装包。安装阶段只使用包内资源，不依赖 GitHub 或 PyPI 网络访问。

## 功能

- 打包 Hermes Agent、portable Python runtime、`uv`、Python 依赖和运行时资源。
- 支持安装或升级 Hermes，保留已有的 `.env`，并在不覆盖其他配置的情况下确保 `config.yaml` 默认选择 `zhan_ai` 模型渠道。
- 提供 Windows 启动、停止、卸载辅助脚本和 PATH 命令。
- 提供 Windows 修复入口 `repair.cmd`，可用当前解压包重建 runtime、venv 和 shims。
- 支持通过 `HERMES_HOME` 和 `HERMES_OFFLINE_HOME` 自定义安装位置。
- 支持 `HERMES_PORTABLE_MODE=1` 或 `install.cmd -Portable` 的便携模式，runtime 和用户数据都留在解压目录内。
- Hermes shim 会把常见第三方缓存默认收敛到 `$HERMES_HOME/cache`，避免 HuggingFace、Playwright、tiktoken、Torch 等默认写入系统盘。
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

如需便携安装，不写入用户级环境变量或用户 `Path`，可运行：

```cmd
install.cmd -Portable
```

也可以使用环境变量：

```cmd
set HERMES_PORTABLE_MODE=1
install.cmd
```

Windows 默认安装会使用固定产品目录：Hermes 配置、skills、日志和缓存位于 `C:\ProgramData\SSC\Hermes`，离线 runtime 位于 `C:\Program Files\StarSoftComm\ZhanClaw\Hermes`。默认模式不会再创建 `%USERPROFILE%\.hermes` 或 `%USERPROFILE%\.hermes-offline`。因为 runtime 位于 `Program Files`，默认安装和卸载需要管理员权限；`install.cmd` 和 `uninstall.cmd` 会在需要时自动弹出 UAC 提权窗口。

便携模式默认使用解压目录下的 `.hermes-offline` 作为 runtime 目录，`.hermes` 作为 Hermes 用户数据目录。安装完成后继续使用同一解压目录里的 `launch.cmd`、`shutdown.cmd` 和 `uninstall.cmd` 即可；这些脚本会自动识别本地便携安装。

如需自定义安装位置，可先在 PowerShell 中设置环境变量，再运行安装脚本：

```powershell
$env:HERMES_HOME="D:\Hermes\home"
$env:HERMES_OFFLINE_HOME="D:\Hermes\runtime"
.\installers\install_windows.ps1
```

Windows 安装器会尽可能停止正在运行的 Hermes 进程，刷新离线 runtime，根据 `HERMES_HOME` 和 `HERMES_OFFLINE_HOME` 派生并写入完整的 Hermes 用户环境变量，并只在 `%HERMES_OFFLINE_HOME%\bin` 创建 shims。安装器会把 `C:\ProgramData\SSC\Hermes` 授予标准 Users 修改权限，以便普通用户运行 Dashboard 时可以写入配置、日志和缓存。安装完成后会默认静默启动 Dashboard，但不会自动打开 Dashboard 网页。安装完成后重新打开 PowerShell 或 CMD，新的环境变量才会生效。

安装器还会设置 `PYTHONUTF8=1` 和 `PYTHONIOENCODING=utf-8`，并在 Hermes shim 中切换到 UTF-8 code page，避免 agent tools 在中文 Windows 环境下写入文件或解析终端输出时遇到编码问题。

安装器环境变量完整清单：

| 变量 | 来源 |
| --- | --- |
| `HERMES_HOME` | 用户传入值；默认 Windows 为 `C:\ProgramData\SSC\Hermes`，Unix 为 `$HOME/.hermes` |
| `HERMES_OFFLINE_HOME` | 用户传入值；默认 Windows 为 `C:\Program Files\StarSoftComm\ZhanClaw\Hermes`，Unix 为 `$HOME/.hermes-offline` |
| `HERMES_PYTHON` | `$HERMES_OFFLINE_HOME/runtime/venv/Scripts/python.exe`（Windows）或 `$HERMES_OFFLINE_HOME/runtime/venv/bin/python`（Unix） |
| `HERMES_BUNDLED_SKILLS` | `$HERMES_OFFLINE_HOME/runtime/hermes-resources/skills` |
| `HERMES_OPTIONAL_SKILLS` | `$HERMES_OFFLINE_HOME/runtime/hermes-resources/optional-skills` |
| `HERMES_OPTIONAL_MCPS` | `$HERMES_OFFLINE_HOME/runtime/hermes-resources/optional-mcps` |
| `HERMES_BUNDLED_LOCALES` | `$HERMES_OFFLINE_HOME/runtime/hermes-resources/locales` |
| `HERMES_BUNDLED_PLUGINS` | `$HERMES_OFFLINE_HOME/runtime/hermes-resources/plugins` |
| `HERMES_WEB_DIST` | `$HERMES_OFFLINE_HOME/runtime/hermes-resources/web_dist` |
| `HERMES_TUI_DIR` | `$HERMES_OFFLINE_HOME/runtime/hermes-resources/tui_dist` |
| `PYTHONUTF8` | `1`（Windows 用户环境变量和 shim） |
| `PYTHONIOENCODING` | `utf-8`（Windows 用户环境变量和 shim） |

其中用户自定义安装位置时只需要提前设置 `HERMES_HOME` 和 `HERMES_OFFLINE_HOME`。Windows 会把上表 12 个变量写入当前用户环境，并把 `%HERMES_OFFLINE_HOME%\bin` 追加到当前用户 `Path`；当检测到旧版本写入的 `%USERPROFILE%\.hermes` 或 `%USERPROFILE%\.hermes-offline` 默认变量时，安装器会把它们视为 legacy 默认值并改用新的产品目录，同时清理旧 `%USERPROFILE%\.hermes-offline\bin` 的 PATH 入口。Unix 不修改 shell 启动文件，而是在生成的 `~/.local/bin/hermes` shim 中导出 Hermes 相关变量。

如需升级已有离线安装，解压新版 zip 后再次运行 `install.cmd`。安装器会重建 runtime 和 venv，更新 shims，保留已有 `.env`，并只对 `config.yaml` 中的默认模型渠道和 `zhan_ai` provider 做最小修正。

如果安装时提示旧 runtime 或旧 `hermes.exe` shim 正被占用，请关闭正在运行的 Hermes 或 ClawPanel 进程后重新安装。Windows 离线安装会把 `hermes.exe` 包装器放到 `%HERMES_OFFLINE_HOME%\bin`，兼容只识别 `.exe` 的调用方；该包装器会转发到同目录的 `hermes.cmd`，因此仍会使用 `hermes.cmd` 中设置的 `HERMES_PYTHON` 和 bundled resources 环境变量。

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
repair.cmd
shutdown.cmd
uninstall.cmd
```

`repair.cmd` 会使用当前解压包内资源重建 runtime、venv 和 shims，默认不启动 Dashboard。需要修复后立即启动时可设置：

```cmd
set HERMES_REPAIR_START_DASHBOARD=1
repair.cmd
```

重新打开 PowerShell 或 CMD 后，也可以直接使用 PATH 命令：

```cmd
hermes-launch
hermes-shutdown
hermes-uninstall
```

`uninstall.cmd` 会停止正在运行的 Hermes 进程，删除离线 runtime 和 shims，并清理 Hermes 用户环境变量；默认保留 `HERMES_HOME` 用户配置。如需同时删除用户配置：

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

Unix 也支持便携模式：

```bash
HERMES_PORTABLE_MODE=1 ./installers/install_unix.sh
```

此时 runtime shim 写入 `$HERMES_OFFLINE_HOME/bin`，默认位置为解压目录下的 `.hermes-offline/bin/hermes`，Hermes 用户数据默认位于解压目录下的 `.hermes`。

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

如需构建中文社区 runtime fork 或桌面预打包 extra，可覆盖 `HERMES_SOURCE` 和 `--extras`：

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

安装器会读取 wheelhouse 内的 `manifest.json`，按构建时记录的 extras 安装，例如 `hermes-agent[cn-desktop]`，不再固定写死为 `hermes-agent[all]`。

支持的平台参数：

```text
win-x64
linux-x64
mac-x64
mac-arm64
```

`packaging/build_wheelhouse.py` 默认使用 `packaging/manifest.py` 中的 `HERMES_SOURCE`。GitHub Actions 手动运行时，可以通过 `hermes_source` 输入覆盖 Hermes package spec。

wheelhouse manifest 会记录实际 `hermes_version`、`hermes_install_spec`、`hermes_source_commit` 和 extras；最终 bundle 的 `manifest.json` 会继续带上这些字段，便于确认 zip 内实际 Hermes 版本。

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

- Runtime：Windows 默认为 `C:\Program Files\StarSoftComm\ZhanClaw\Hermes\runtime`，Unix 默认为 `~/.hermes-offline/runtime`，可通过 `HERMES_OFFLINE_HOME` 覆盖。
- Runtime resources：`$HERMES_OFFLINE_HOME/runtime/hermes-resources`，包含 `skills`、`optional-skills`、`optional-mcps`、`locales`、`plugins`、`web_dist` 和 `tui_dist`。
- Shim：Unix 为 `~/.local/bin/hermes`；Windows 为 `%HERMES_OFFLINE_HOME%\bin\hermes.cmd`。
- 便携模式：Windows 为 `<解压目录>\.hermes-offline\bin\hermes.cmd`，Unix 为 `<解压目录>/.hermes-offline/bin/hermes`。
- Hermes 配置：Windows 默认为 `C:\ProgramData\SSC\Hermes\config.yaml` 和 `C:\ProgramData\SSC\Hermes\.env`；Unix 默认为 `~/.hermes/config.yaml` 和 `~/.hermes/.env`；可通过 `HERMES_HOME` 覆盖。
- 用户插件、skills、日志和状态文件跟随 `HERMES_HOME`。
- 常见第三方缓存默认随 Hermes shim 收敛到 `$HERMES_HOME/cache`，包括 `HF_HOME`、`HUGGINGFACE_HUB_CACHE`、`TORCH_HOME`、`TIKTOKEN_CACHE_DIR`、`MPLCONFIGDIR`、`NLTK_DATA`、`PLAYWRIGHT_BROWSERS_PATH` 和临时目录。
- 内置 Agent Skills 会在安装或升级时从 runtime resources 恢复。用户修改或删除过的 skills 会按照 Hermes bundled manifest 规则保留。
- Hermes Python：`HERMES_PYTHON` 从 `$HERMES_OFFLINE_HOME/runtime/venv` 派生；Unix shim 会导出上表 Hermes 环境变量，Windows 安装器会写入用户环境变量。

如果 Windows 在检查可选依赖时提示找不到 Hermes Python 解释器，可按 `HERMES_HOME` 和 `HERMES_OFFLINE_HOME` 修复完整用户环境变量：

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

然后重新打开 PowerShell 或 CMD。

## 配置

安装器会把默认模型配置为 `zhan_ai` 渠道下的 `qwen3`。如果 `config.yaml` 已存在，安装器不会覆盖其他无关配置项，但会确保 `model.provider` 为 `custom:zhan_ai`，把旧安装器生成的 `gpt-4o-mini` 默认值修正为 `qwen3`，并补齐 `providers.zhan_ai`；当实时模型发现不可用时，`qwen3` 会作为兜底模型显示。模型服务配置从 Windows 用户环境变量读取：

```powershell
[Environment]::SetEnvironmentVariable("ZHANCLAW_BASE_URL", "https://your-zhanclaw-endpoint/v1", "User")
[Environment]::SetEnvironmentVariable("ZHANCLAW_API_KEY", "your-api-key", "User")
```

设置完成后重启已经在运行的 ClawPanel / Hermes gateway。新的 Windows shim 启动时也会从当前用户环境刷新 `ZHANCLAW_BASE_URL` 和 `ZHANCLAW_API_KEY`。从旧版本升级时，如果 `.env` 里已有 `CUSTOM_BASE_URL` / `OPENAI_BASE_URL` 或 `CUSTOM_API_KEY` / `OPENAI_API_KEY`，安装器会在 `ZHANCLAW_*` 尚未设置时迁移到对应的 Windows 用户环境变量。`$HERMES_HOME/.env` 仍只保存安装包自身需要的非模型密钥配置，不写入新的 `ZHANCLAW_API_KEY`。

## 说明

- 安装阶段只使用包内资源。
- 最终用户不需要手动安装 Python、`uv` 或 Git。
- 本项目维护独立安装流程，不复用 ClawPanel installer。
