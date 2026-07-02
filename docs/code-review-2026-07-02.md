# 代码审查报告（2026-07-02）

对整个仓库（两个安装器、打包脚本、verify 脚本、CI workflow）的一次全面审查结果。
状态列说明：✅ 已修复 / ⬜ 待修复。

## 问题总览

| 编号 | 问题 | 严重性 | 位置 | 状态 |
|---|---|---|---|---|
| 1 | 中文 Windows 上升级会把配置文件里的中文读成乱码后写回，静默损坏配置 | 🔴 高 | `install_windows.ps1`、`verify_windows.ps1` | ✅ 已修复（9632403） |
| 2 | shim 用 ASCII 编码写入，安装路径含中文时全部入口脚本失效 | 🔴 高 | `install_windows.ps1` shim 写入段 | ✅ 已修复（9632403） |
| 3 | `API_SERVER_KEY` 是写死的占位符，gateway 拒绝启动 API server | 🔴 高 | `templates/env.template:2` | ✅ 已修复（工作区） |
| 4 | 升级"先删旧再装新"，中途失败会留下不可用的安装 | 🔴 高 | 两个安装器 | ✅ 已修复（工作区） |
| 5 | UAC 提权安装时环境变量写进管理员账号，实际使用者拿不到 | 🔴 高 | `install_windows.ps1` 环境变量写入段 | ✅ 已修复（工作区） |
| 6 | 杀进程按命令行子串 "hermes" 匹配，可能误杀无关进程 | 🔴 高 | 安装/卸载/停止脚本 | ✅ 已修复（工作区） |
| 7 | `ProgramData\SSC\Hermes` 递归授予所有用户可写，密钥和 skills 可被同机用户读改 | 🟡 中 | `install_windows.ps1:99` | ✅ 已修复（工作区） |
| 8 | verify 不检查 `hermes version` 的退出码，程序崩溃也算通过 | 🟡 中 | `verify_windows.ps1` 末行 | ✅ 已修复（工作区） |
| 9 | 改用户 PATH 时把 `REG_EXPAND_SZ` 固化成展开后的字符串 | 🟡 中 | `install_windows.ps1:576,1614`、`uninstall_windows.ps1:348` | ✅ 已修复（工作区） |
| 10 | shim 每次启动无条件覆盖 `ZHANCLAW_*` 会话变量；卸载误删用户自设的 `PYTHONUTF8` | 🟡 中 | shim 模板、`uninstall_windows.ps1:318` | ✅ 已修复（工作区） |
| 11 | 运行时依赖清单在 3 处重复（打包脚本 + 两个安装器） | 🟢 低 | `build_wheelhouse.py:20`、`install_unix.sh:410`、`install_windows.ps1` | ✅ 已修复（工作区） |
| 12 | config.yaml 迁移逻辑用 Python 和 PowerShell 各写一遍（约 700 行），易漂移 | 🟢 低 | 两个安装器 | ✅ 已修复（工作区） |
| 13 | Unix 安装器缺少 Windows 版已有的能力（停进程、legacy 迁移、venv 重试等） | 🟢 低 | `install_unix.sh` | ⬜ |
| 14 | CI 只做语法检查，没有任何真实执行的测试 | 🟢 低 | `.github/workflows/validate.yml` | ✅ 已修复（工作区） |
| 15 | release 只构建 win-x64（README 承诺 4 平台）；`.gitignore` 缺 `.idea/` | 🟢 低 | `release.yml`、`.gitignore` | ⬜ |

## 修复建议

### 1. 配置文件编码损坏 ✅ 已修复

Windows PowerShell 5.1 的 `Get-Content` 默认按系统 ANSI（中文系统为 GBK）解码，
读 UTF-8 的 `config.yaml`/`.env` 会得到乱码，随后被 `Write-Utf8NoBomLines` 写回固化。

**修复（commit 9632403）**：所有读取用户配置的 `Get-Content` 显式加 `-Encoding UTF8`，
共 5 处（安装器 3 处 + verify 2 处）。

### 2. shim ASCII 编码 ✅ 已修复

`Set-Content -Encoding ASCII` 会把非 ASCII 路径字符替换成 `?`。

**修复（commit 9632403）**：改用已有的 `Write-Utf8NoBomLines`（UTF-8 无 BOM）。
可行前提：shim 前两行是纯 ASCII 的 `@echo off` + `chcp 65001`，切换代码页后才出现
嵌入路径的行；不能带 BOM，否则 cmd.exe 会把 BOM 当作首行命令的一部分。

### 3. API_SERVER_KEY 占位符

**修复（工作区）**：`env.template` 不再写死 `clawpanel-local`。Windows 和 Unix 安装器会在每次安装/升级时
检查 `$HERMES_HOME/.env`，当 `API_SERVER_KEY` 缺失、为空、等于占位符或短于 16 字符时自动生成
32 字节随机 hex key，并移除旧的 `API_SERVER_KEY=` 行后追加强 key。两个 verify 脚本已加入断言。

**建议**：安装器在复制 `.env` 后检查该值，若缺失、等于占位符或短于 16 字符则自动生成随机密钥：

- Unix：`openssl rand -hex 32`（无 openssl 时回退 `od -An -tx1 -N32 /dev/urandom | tr -d ' \n'`），用 `sed` 原位替换。
- Windows：`[System.Security.Cryptography.RandomNumberGenerator]` 生成 32 字节转 hex，
  按行替换后用 `Write-Utf8NoBomLines` 写回。
- 无条件调用（不只在新装时），这样已装机器升级时也会把占位符换掉。
- 两个 verify 脚本加断言：`API_SERVER_KEY` 存在、≠ `clawpanel-local`、长度 ≥ 16。

### 4. 升级非事务性

**修复（工作区）**：Windows 和 Unix 安装器现在会先把旧 `runtime` 改名为
`runtime.old.<timestamp>`，然后在最终 `runtime` 路径重建新 venv/runtime。安装或自检失败时会删除
失败的新 `runtime` 并恢复旧 runtime；成功后再删除旧备份。这样避免 Windows venv 装到 staging
目录后再重命名导致内部路径失效。

**建议**：新 venv/runtime 先装到临时目录（如 `runtime.new`），`hermes version` 自检通过后
再把旧目录改名为 `runtime.old` → 新目录就位 → 删除旧目录。失败时旧安装保持可用。
Windows 注意目录被占用时改名会失败，需保留现有的停进程逻辑并在失败时回滚。

### 5. 提权后写错用户环境

**修复（工作区）**：`install.cmd` 在 UAC 提权前记录原始安装用户 SID，并传给 elevated 安装进程。
Windows 安装器现在会通过 `HKEY_USERS\<SID>\Environment` 读写目标用户的 `HERMES_*`、`ZHANCLAW_*`
和 `Path`，同时根据该 SID 解析原始用户 profile 路径用于 legacy `.hermes` 迁移。这样即使 UAC 使用
另一个管理员账号确认，环境变量和 PATH 也会落回发起安装的用户。

**建议**：`install.cmd` 提权前记录原始用户名（`%USERNAME%`）传给 PowerShell；
写 User 环境变量时若检测到当前身份≠原始用户，改写 HKU 下原始用户的注册表键，
或改用 Machine 级环境变量（更简单，且默认安装本来就要求管理员）。

### 6. 杀进程范围过宽

**修复（工作区）**：安装、停止、卸载脚本已移除“命令行包含 `hermes` 即匹配”的兜底逻辑；
现在只匹配进程可执行路径或命令行中明确出现当前安装根、runtime、Hermes home 或 shim 目录的进程。

**建议**：匹配条件从"命令行含 hermes"收紧为：进程可执行文件路径位于
`$HERMES_OFFLINE_HOME` 之下，或命令行中引用的脚本/入口路径位于安装目录之下。
三个脚本（install/uninstall/shutdown）同步修改。

### 7. ProgramData ACL 过宽

**修复（工作区）**：Windows 安装器不再对整个 `ProgramData\SSC\Hermes` 递归授予
`BUILTIN\Users` 修改权限。安装后会收紧 Hermes home 的继承 ACL，只给 SYSTEM、
Administrators 和安装发起用户访问；仅 `cache`、`logs`、`state` 三个运行时可写目录
单独开放标准用户修改权限。

**建议**：把授予 `BUILTIN\Users` 修改权限的范围从整个 `SSC\Hermes` 缩小到
确需写入的子目录（`logs`、`cache`、`state`）；`.env` 与 `skills\` 保持仅管理员和
SYSTEM 可写。若产品需求就是多用户共用，至少对 `.env` 单独收紧 ACL。

### 8. verify 不看退出码

**修复（工作区）**：Windows verify 在执行 `hermes version` 后检查 `$LASTEXITCODE`，
非 0 退出会直接失败。

**建议**：`& $HermesCmd version` 后补 `if ($LASTEXITCODE -ne 0) { throw "hermes version 退出码 $LASTEXITCODE" }`。
Unix 版有 `set -euo pipefail` 已覆盖，无需改。

### 9. PATH 固化 REG_EXPAND_SZ

**修复（工作区）**：Windows 安装和卸载均通过目标用户 SID 下的
`HKEY_USERS\<SID>\Environment` 读写环境变量。读取 PATH 时使用
`DoNotExpandEnvironmentNames` 保留原始 `%VAR%` 文本；写回时保留原注册表类型。

**建议**：读写用户 PATH 改用注册表 API 并保留类型：
`(Get-Item HKCU:\Environment).GetValue("Path", "", "DoNotExpandEnvironmentNames")` 读原始值，
`Set-ItemProperty` / `[Microsoft.Win32.Registry]::SetValue(..., RegistryValueKind.ExpandString)` 写回。

### 10. shim 覆盖会话变量 / 卸载误删

**修复（工作区）**：Windows shim 只在当前会话未定义 `ZHANCLAW_BASE_URL` /
`ZHANCLAW_API_KEY` 时才从用户环境回填；卸载脚本不再删除用户自己的
`PYTHONUTF8` / `PYTHONIOENCODING`。

**建议**：shim 中 `reg query` 读 `ZHANCLAW_*` 的两行改成 `if not defined ZHANCLAW_BASE_URL ...`
的条件赋值，与其他默认值行为保持一致；卸载脚本不再删除 `PYTHONUTF8`/`PYTHONIOENCODING`
（无法区分是否用户自设），或仅当值与安装器写入值完全一致时才删。

### 11. 依赖清单三处重复

**修复（工作区）**：`build_wheelhouse.py` 现在把安装期依赖写入 wheelhouse
`manifest.json` 的 `install_requirements` 字段；Windows 和 Unix 安装器都从 manifest
读取依赖，不再维护各自的 `RUNTIME_PACKAGES` / `$RuntimePackages`。

**建议**：继续保持依赖清单单一来源，版本升级只改 `build_wheelhouse.py` 一处。

### 12. 配置迁移逻辑双实现

**修复（工作区）**：配置迁移逻辑抽到 `scripts/configure_config.py`，Unix 和 Windows
安装器都调用这份共享 Python 脚本；Windows 侧旧的 `Ensure-*` / `Remove-LegacyApiServerPort`
等 PowerShell 迁移函数已删除。

**建议**：把 `install_unix.sh` 内嵌的 Python 迁移脚本抽成独立文件（如
`scripts/configure_config.py`）随包分发；两个安装器都在 venv 建好后用捆绑 Python 调它。
可删除 PowerShell 侧约 400 行 `Ensure-*`/`Remove-LegacyApiServerPort` 等函数，消除漂移。
建议在下一次涉及配置迁移的功能改动前先做这项。

### 13. Unix 安装器功能缺口

**建议**：按需补齐（不必全部）：升级前检测并提示停止运行中的 hermes 进程；
venv 创建失败时清理重试；`.env`/config 的 legacy 迁移如果 Unix 用户群需要再做。

### 14. CI 缺真实测试

**修复（工作区）**：新增 `scripts/test_configure_config.py`，覆盖默认配置生成、旧
`api_server_port` 迁移和 inline models 追加；`validate.yml` 会编译新脚本并真实运行该测试。

**建议**：分两步走——
1. 低成本：`validate.yml` 加 `shellcheck installers/install_unix.sh scripts/verify_unix.sh`。
2. 端到端：加一个 Linux job，跑 `build_wheelhouse.py` + `build_bundle.py`（linux-x64）→
   解压产物 → `install_unix.sh` → `verify_unix.sh`，覆盖"真实安装"路径。

### 15. 杂项

**建议**：`release.yml` 的 matrix 补上 `linux-x64`（ubuntu-latest）、`mac-x64`/`mac-arm64`
（macos-13/macos-latest），或修改 README 不承诺未构建的平台；`.gitignore` 加一行 `.idea/`。
