# Hermes 0.22.2 适配与构建记录

日期：2026-10-19。上游固定为 [v0.22.2](https://github.com/NousResearch/hermes-agent/releases/tag/v0.22.2)，提交 `d923a5eb487a17c0a68801bba9ef0f56c81040a8`。安装器基于上一版 `e31ccd3`，工作分支为 `codex/hermes-0.22.2`。

## 已实施的适配

- 构建解释器、依赖下载器和包内 Python 同步为 **3.14.7**。构建脚本检查实际解释器、系统及架构，阻止 pip 在旧 Python 上错误跳过 `python_version >= '3.14'` 的核心依赖。
- `HERMES_SOURCE` 默认固定为 `v0.22.2`。依赖解析使用已检出的本地源码，与资源、版本、提交保持一致，不重复从远端标签获取另一份源码。
- 上游 `project.version = "0.0.0"` 作为 distribution metadata 保留。真实发布版本从源码 HEAD 对应的稳定标签读取，通过上游 `scripts/write_install_stamp.py` 生成 `install-stamp.json`。其中记录真实提交、`baseVersion = 0.22.2`、`displayVersion = 0.22.2` 和 `updateMechanism = external`。
- 构建、升级预检和运行时校验统一检查真实版本与提交，同时验证 distribution metadata 与源码一致。无效身份文件、缺少版本或提交错配会失败；旧 0.21.5 无 stamp 的安装继续按其原有 metadata 读取版本。
- 补充核心 wheel 检查和安装后导入检查，包含 OpenAI SDK、ruamel.yaml、dotenv、truststore。升级辅助脚本依赖的 PyYAML 也显式预装。
- 安装器和验证脚本统一使用新版支持的 `hermes --version`；静默安装日志统一写入 UTF-8。
- 升级辅助命令禁止向安装包目录写入导入缓存，保证旧 Python 执行预检与 `-WhatIf` 时不会改变包内文件及校验清单。
- 升级预检通过只读文件流计算 SHA-256，避免 Windows PowerShell 5.1 的 `Get-FileHash` 在继承 `-WhatIf` 时跳过路径解析。新增 Windows 函数回归，验证预检保持 `WhatIf`、不新增文件，并继续拒绝损坏的包。
- 升级脚本的数据目录变量更名为 `HermesDataHome`，避免 PowerShell 不区分大小写导致与只读自动变量 `$HOME` 冲突。
- 进程归属预检可处理带引号的脚本参数、卷根参数和无 `Execute` 字段的 COM 计划任务；不会再将普通命令参数误当成非法路径。真实引用安装目录的进程与计划任务继续阻止升级。
- 已从 `v0.21.5-92` 原包提取并复现旧源码（上游 `v2026.9.24` / `f97608f`）的配置读取副作用：读取 API 端点会初始化 `SOUL.md`、目录及配置历史快照。升级现在先封存完整备份，再读取端点、恢复原 home 并严格复核全树哈希，然后才替换 runtime；不排除缓存或任何用户文件。比对失败仅输出差异路径和类别，不输出文件内容或凭据。

核心实现：[构建脚本](../packaging/build_wheelhouse.py)、[版本身份解析](../scripts/hermes_version.py)、[升级验证](../scripts/upgrade_support.py)。

## 配置与产物规则

[默认模板](../templates/config.yaml) 与 [0.22.2 配置示例](../templates/config.v0.22.2.example.yaml) 同步。保留 `custom:zhan_ai`、`qwen3`、local terminal、API Server `127.0.0.1:8642`，明确使用 `chat_completions`，凭据继续来自 `ZHANCLAW_*` 和独立的 `API_SERVER_KEY`。

视觉能力与上下文长度不按别名猜测，确认实际服务能力后再启用；默认关闭自动安装缺失依赖。既有 home 的模型选择、凭据和数据继续由专用升级流程保留。

升级在官方迁移后，从包内模板补齐明确列出的 **9 项运行配置**。已有值（包括 `false`、`0`、空字符串、空列表和 `null`）保留，非映射父节点不替换。模型、服务商、凭据、MCP 和插件整段不从模板补入或覆盖。根 home 和命名 profiles 分别处理，重复执行不重复改写；除上游管理的 `_config_version` 外，原有设置被迁移或启动过程改变时会触发回滚。完整规则见 [Windows 升级指南](upgrade-windows.zh-CN.md#3-保留的数据与配置)。

发布产物分别为：

- `hermes-offline-installer-win-x64.zip`
- `hermes-offline-installer-win-x64.zip.sha256`
- **`config.yaml`（独立文件）**
- `config.yaml.sha256`

不再将 config 与 ZIP 打成外层总压缩包。安装 ZIP 内只保留首次安装必须的 `templates/config.yaml` 和 `env.template`，不复制额外的版本示例。

GitHub 标签仍为 `v<version>-<run number>`；OSS 上传到 `hermes/<version>-<run number>/`。独立 config 及其校验文件同样经过远端 SHA-256 回读后，才写入版本目录的 `latest.json`。`update_root_latest` 默认 false，本次不推广根目录更新指针。

## 验证

已完成的检查：

- 本地 Python 3.12 和 3.14.7 下各 **116 项回归测试通过**；Windows runner 的 Python 测试同样为 116 项通过。Python 脚本编译与 Unix shell 语法检查通过。
- Windows runner 的 PowerShell 5.1 语法检查和 **62 项隔离函数检查通过**，覆盖路径/命令行解析、只读预检、计划任务识别、冷复制、原子 journal 和文件锁；真实安装/升级/回滚由下述 smoke 步骤另外验证。
- 真实上游 `write_install_stamp.py` 调用成功，输出 schema 2、真实版本 0.22.2、提交 d923a5e、干净源码及 external 更新责任方。
- 新配置已用上游配置/模型路由/gateway 加载器验证；测试凭据和临时 home 隔离，未调用真实模型服务。
- 新回归覆盖：占位版本拒绝、旧版兼容、精确标签解析、身份错配、0.21.5 到 0.22.2 的清单校验、config 独立产物、OSS 校验失败阻止发布。
- 配置补齐回归覆盖显式值、空值、非映射父节点、多 profiles、注释/引号/中文/CRLF、YAML 别名、重复键、原子替换失败、重复运行及 `.env` 键被删除的检测。真实 0.22.2 迁移器的隔离样例验证了补齐与保留规则。

Windows release workflow 新增 [真实安装验证脚本](../scripts/smoke_windows.ps1)，在发布前执行：

1. 解压新 ZIP，在含中文和空格的临时路径中便携安装，且不写入用户环境变量或 PATH。
2. 验证来源、metadata、运行时版本、pip 一致性、默认配置和认证后的 API readiness。
3. 下载并校验既有 `v0.21.5-92` ZIP。该包的安装器仍调用已移除的 `hermes version`，因此仅在隔离测试副本中将最后的版本查询改为 `hermes --version`，保留原始 runtime、源码、依赖和配置。安装真实旧 runtime 后加入需保留的模型、终端超时、压缩/记忆开关、MCP、插件设置和用户文件。
4. 运行升级 `-WhatIf`；通过占用 API 端口触发替换 runtime 后的失败，检查完整回滚及配置/凭据保留。
5. 释放端口后执行成功升级并保持停止，验证版本、原有选择和数据，并检查缺失运行配置已补齐。

2026-10-19，[第 106 次构建](https://github.com/bddiudiu/hermes-offline-installer/actions/runs/39209916773)中的上述 Windows 安装/升级验证步骤全部通过，用时 21 分 56 秒。真实旧运行时和完整 home 回滚成功，回滚后的 config 与 `.env` 哈希保持一致；成功升级样例补齐 **6 项缺失配置**，另外 3 项用户已显式设置的值继续保留。模型、凭据、MCP、插件、用户文件与已认证 API readiness 检查均通过。

自动化验证不涵盖实际外部客户端、模型推理服务或全部可选插件；这些仍需目标客户端联调。

## 最终产物

[GitHub Release：v0.22.2-106](https://github.com/bddiudiu/hermes-offline-installer/releases/tag/v0.22.2-106)，安装器提交 `2feeb07a23b4e023d514da10785dd99fea7e3e1a`。远端发布标签指向该提交。

第 106 次工作流最终状态为 **success**。OSS 已发布至 `hermes/0.22.2-106/`：ZIP、独立 config、各自校验文件及版本目录 `latest.json` 均完成 SDK 远端回读，完整 SHA-256 匹配；日志确认 `Root latest.json preserved`，本次未推广根目录更新指针。

- [Windows 一键包](https://github.com/bddiudiu/hermes-offline-installer/releases/download/v0.22.2-106/hermes-offline-installer-win-x64.zip)：229,814,754 字节。
- [独立 config.yaml](https://github.com/bddiudiu/hermes-offline-installer/releases/download/v0.22.2-106/config.yaml)：3,376 字节，UTF-8 / Windows CRLF；内容与第 105 次发布一致，本次变更在升级时的补齐逻辑。
- [一键包 SHA-256](https://github.com/bddiudiu/hermes-offline-installer/releases/download/v0.22.2-106/hermes-offline-installer-win-x64.zip.sha256) 与 [config SHA-256](https://github.com/bddiudiu/hermes-offline-installer/releases/download/v0.22.2-106/config.yaml.sha256) 同目录独立提供。

重新下载后已验证 ZIP 整体哈希、包内 **22,636 个文件**的完整清单哈希、Hermes 0.22.2 / Python 3.14.7 / 上游提交身份，并确认包内升级脚本与安装器提交一致。ZIP 内 `templates/config.yaml` 与独立 `config.yaml` 逐字节一致；与仓库模板只存在 Windows CRLF / LF 换行差异。ZIP 内无额外版本示例，也没有将安装包和独立 config 再合成外层压缩包。

```text
hermes-offline-installer-win-x64.zip
b9ad81224edbaacc34a58525cbfe8684d2035d7bdb556b460bbbc417e2a1ce75

config.yaml
0e3a9941f3966e75743d1e151dc14f6867089dd4bf1abc945a149902a0bc98e6
```

## 2026-10-21：按最终部署目录升级的验收与重打包

升级代码提交为 `028c52444070ad76278809068902507714abc97e`，包含已部署目录检查、原启动器路径绑定检查、旧 Python/editable 源码来源校验、启动前完整 home 文件校验，以及预检进度输出。升级源使用完整新版包；不读取旧版本 ZIP 或旧解压目录。仍在运行且无法确认归属的进程会阻止升级；针对已退出进程的 WMI 残留，先重新查询 PID，再用操作系统退出状态确认，不把残留记录当成存活进程。

[Windows 验收任务 39583300513](https://github.com/bddiudiu/hermes-offline-installer/actions/runs/39583300513)最终 **success**，使用 Windows PowerShell 5.1、Python 3.14.7：

- **124 项 Python/CMD 回归测试通过**，Windows 专用入口用例实际执行；**76 项 PowerShell 隔离函数检查通过**。
- 新版完整离线安装、版本/依赖/配置与已认证 API readiness 通过。
- 安装真实 `v0.21.5-92` 后，删除旧解压目录，再从最终安装目录的 `bin\hermes.cmd` 验证启动入口。
- 从新版包运行 `upgrade.cmd <已安装根目录> -WhatIf`，完整安装树和 home 的文件清单/哈希保持不变。
- 占用 API 端口触发失败，确认 `home`、`runtime`、`bin` 三棵树与冷备份完全一致；根 home 和 `profiles/work` 的数据库会话、消息及自定义文件保留。
- 完成 `0.21.5 → 0.22.2` 升级；根 home 和命名 profile 分别补齐 6 项缺失运行配置，原模型选择、显式配置、凭据、MCP、插件及用户文件保持。
- SQLite `quick_check`、原 session/message 查询通过。升级完成后删除新版解压目录，最终安装目录的命令入口与 `verify_windows.ps1` 仍通过。服务按 `-KeepStopped` 保持停止。

此次使用 `packaging/repack_bundle.py`，以 SHA-256 固定的 `v0.22.2-106` ZIP 为运行时基础，刷新当前 installer/scripts/升级指南并重建完整校验清单。Hermes 源码、Python、wheels、资源及默认模板沿用已核验的基础包。该方式不升级 Hermes/Python/uv 版本或模板；版本/模板不匹配时拒绝重打包。

Windows 验收并上传的安装 ZIP：

```text
hermes-offline-installer-win-x64.zip
SHA-256: 506fe695ea264496504b61ed013c4f597593ee4ebc364cb20a9b6c87391429d1

upgrade-manifest.json
SHA-256: 89aed24101e9eda47beb13b48a2ffb4b1337201e66ae035e665a873238674b16
已校验文件数: 22637
```

GitHub Actions artifact 为 `hermes-windows-candidate-39583300513`（ID `12340985774`），其中包含安装 ZIP、独立 config 与校验文件。此轮仅构建和验收，没有创建新 Release、上传 OSS 或推广根 `latest.json`。验收使用隔离 Windows runner；真实客户端/supervisor 与目标机器联调仍属于部署验收。
