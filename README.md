# Hermes Offline Installer

Hermes Offline Installer 是一个独立的一键离线安装项目，用于把 Hermes Agent、Python runtime、uv 和 Python 依赖预打包成平台安装包。

目标：最终用户不需要自行安装 Python、uv、git，也不需要在安装阶段访问 GitHub 或 PyPI。

## 产物

GitHub Actions 当前优先生成 Windows 安装包：

- `hermes-offline-installer-win-x64.zip`

## 使用方式

### macOS / Linux

```bash
tar -xzf hermes-offline-installer-<platform>.tar.gz
cd hermes-offline-installer-<platform>
./installers/install_unix.sh
```

如需自定义安装位置，可在安装时传入环境变量。下面的命令可直接复制运行，其中：

- `HERMES_HOME` 控制 Hermes 配置、插件、skills、日志和状态文件位置
- `HERMES_OFFLINE_HOME` 控制离线 runtime、venv 和 shim 位置

```bash
HERMES_HOME=/data/hermes \
HERMES_OFFLINE_HOME=/data/hermes-runtime \
./installers/install_unix.sh
```

也可以把 `/data/hermes` 和 `/data/hermes-runtime` 替换成自己的目录。

安装后重新打开终端，验证：

```bash
hermes version
hermes dashboard
```

### Windows

解压 zip 后，直接双击或在命令行运行根目录的安装入口：

```cmd
install.cmd
```

也可以使用兼容入口：

```cmd
install_windows.cmd
```

如需自定义安装位置，可在 PowerShell 中传入环境变量后运行安装脚本：

```powershell
$env:HERMES_HOME="D:\Hermes\home"
$env:HERMES_OFFLINE_HOME="D:\Hermes\runtime"
.\installers\install_windows.ps1
```

Windows 安装器会在安装或升级前尝试停止正在运行的 Hermes 进程，然后刷新离线 runtime。安装完成后会把 `HERMES_HOME`、`HERMES_OFFLINE_HOME` 和 `HERMES_PYTHON` 写入当前用户环境变量，创建 `%USERPROFILE%\.hermes-venv` 兼容入口，并自动启动 Dashboard；重新打开 PowerShell/CMD 后环境变量生效。`HERMES_PYTHON` 指向离线 runtime 创建的 Hermes Python 解释器，用于后续查看或安装可选依赖。

Windows 安装器还会设置 `PYTHONUTF8=1` 和 `PYTHONIOENCODING=utf-8`，并在 Hermes shim 中切换到 UTF-8 code page，避免 agent tools 在中文 Windows 环境下写入文件或解析终端输出时遇到编码问题。

已经安装过离线包时，解压新版 zip 后再次运行 `install.cmd` 即执行升级：安装器会重建 runtime/venv 并更新 shim，但保留现有 `config.yaml` 和 `.env`。

如果安装时提示旧 runtime 或 `%APPDATA%\clawpanel\bin\hermes.exe` 正由另一进程使用，请关闭正在运行的 Hermes/ClawPanel 进程后重新安装。

脚本会打开一个保留输出的命令行窗口。自动化运行时如需禁止重新打开窗口：

```cmd
set HERMES_NO_RELAUNCH=1
set HERMES_NO_PAUSE=1
install_windows.cmd
```

如需安装完成后不自动启动 Dashboard：

```cmd
set HERMES_NO_START_DASHBOARD=1
install_windows.cmd
```

重新打开 PowerShell，验证：

```powershell
hermes version
hermes dashboard
```

## 构建

本项目推荐通过 GitHub Actions 构建平台包。CI 会用 `uv python install 3.11` 准备对应 runner 平台的 portable Python runtime，并打进 bundle。

本地调试示例：

```bash
python3 packaging/build_wheelhouse.py --platform linux-x64 --output build/wheelhouse
python3 packaging/build_bundle.py --platform linux-x64 --wheelhouse build/wheelhouse --output dist
```

离线 wheelhouse 默认包含 `hermes dashboard` 所需的 `fastapi`、`python-multipart`、`uvicorn`、`websockets` 等依赖，安装后无需额外联网安装 dashboard 依赖。

## OSS 发布

GitHub Actions 会在创建 GitHub Release 后上传同一批产物到 Aliyun OSS，并生成：

```text
hermes/latest.json
```

默认前缀为 `hermes`，版本产物会上传到：

```text
hermes/<hermes-agent-version>/
```

`latest.json` 会采用和 `openclaw-standalone` 相同的轻量结构，`editions.en.base_url` 指向当前 Windows zip 下载地址。

需要配置的 GitHub Secrets：

- `ALIYUN_OSS_BUCKET`
- `ALIYUN_OSS_ENDPOINT`
- `ALIYUN_OSS_ACCESS_KEY_ID`
- `ALIYUN_OSS_ACCESS_KEY_SECRET`
- `ALIYUN_OSS_PUBLIC_BASE_URL`

可选 GitHub Variable：

- `ALIYUN_OSS_PREFIX`

## 安装位置

- runtime：默认 `~/.hermes-offline/runtime` 或 `%USERPROFILE%\.hermes-offline\runtime`，可通过 `HERMES_OFFLINE_HOME` 调整
- shim：`~/.local/bin/hermes` 或 `%USERPROFILE%\.hermes-offline\bin\hermes.cmd`
- Hermes 配置：默认 `~/.hermes/config.yaml` 与 `~/.hermes/.env`，Windows 默认为 `%USERPROFILE%\.hermes\config.yaml` 与 `%USERPROFILE%\.hermes\.env`，可通过 `HERMES_HOME` 调整
- 后续用户插件、skills、日志和状态文件会跟随 Hermes 使用的 `HERMES_HOME`
- Hermes Python：Unix shim 会自动设置 `HERMES_PYTHON`；Windows 安装器会把 `HERMES_PYTHON` 写入用户环境变量

如果 Windows 已安装后查看可选依赖时提示 Hermes Python 解释器未找到，可先运行：

```powershell
$HermesOfflineHome = if ($env:HERMES_OFFLINE_HOME) { $env:HERMES_OFFLINE_HOME } else { Join-Path $env:USERPROFILE ".hermes-offline" }
[Environment]::SetEnvironmentVariable("HERMES_OFFLINE_HOME", $HermesOfflineHome, "User")
[Environment]::SetEnvironmentVariable("HERMES_PYTHON", (Join-Path $HermesOfflineHome "runtime\venv\Scripts\python.exe"), "User")
```

然后重新打开 PowerShell/CMD 再试。

## 配置模型

安装器只创建最小配置和环境变量模板，不写入用户 API Key。安装后请编辑：

```text
$HERMES_HOME/.env
```

## 说明

- 安装阶段只使用包内资源。
- 不复用 ClawPanel 安装流程。
- 不要求用户手动安装 Python、uv、git。
