# Hermes Offline Installer

Hermes Offline Installer 是一个独立的一键离线安装项目，用于把 Hermes Agent、Python runtime、uv 和 Python 依赖预打包成平台安装包。

目标：最终用户不需要自行安装 Python、uv、git，也不需要在安装阶段访问 GitHub 或 PyPI。

## 产物

GitHub Actions 会按平台生成：

- `hermes-offline-installer-mac-arm64.tar.gz`
- `hermes-offline-installer-mac-x64.tar.gz`
- `hermes-offline-installer-linux-x64.tar.gz`
- `hermes-offline-installer-win-x64.zip`

## 使用方式

### macOS / Linux

```bash
tar -xzf hermes-offline-installer-<platform>.tar.gz
cd hermes-offline-installer-<platform>
./installers/install_unix.sh
```

安装后重新打开终端，验证：

```bash
hermes version
```

### Windows

解压 zip 后，直接双击或在命令行运行根目录的安装入口：

```cmd
install_windows.cmd
```

重新打开 PowerShell，验证：

```powershell
hermes version
```

## 构建

本项目推荐通过 GitHub Actions 构建平台包。CI 会用 `uv python install 3.11` 准备对应 runner 平台的 portable Python runtime，并打进 bundle。

本地调试示例：

```bash
python3 packaging/build_wheelhouse.py --platform linux-x64 --output build/wheelhouse
python3 packaging/build_bundle.py --platform linux-x64 --wheelhouse build/wheelhouse --output dist
```

## 安装位置

- runtime：`~/.hermes-offline/runtime`
- shim：`~/.local/bin/hermes` 或 `%USERPROFILE%\.hermes-offline\bin\hermes.cmd`
- Hermes 配置：`~/.hermes/config.yaml` 与 `~/.hermes/.env`

## 配置模型

安装器只创建最小配置和环境变量模板，不写入用户 API Key。安装后请编辑：

```text
~/.hermes/.env
```

## 说明

- 安装阶段只使用包内资源。
- 不复用 ClawPanel 安装流程。
- 不要求用户手动安装 Python、uv、git。
