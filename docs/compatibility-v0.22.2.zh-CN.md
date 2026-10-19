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

发布产物分别为：

- `hermes-offline-installer-win-x64.zip`
- `hermes-offline-installer-win-x64.zip.sha256`
- **`config.yaml`（独立文件）**
- `config.yaml.sha256`

不再将 config 与 ZIP 打成外层总压缩包。安装 ZIP 内只保留首次安装必须的 `templates/config.yaml` 和 `env.template`，不复制额外的版本示例。

GitHub 标签仍为 `v<version>-<run number>`；OSS 上传到 `hermes/<version>-<run number>/`。独立 config 及其校验文件同样经过远端 SHA-256 回读后，才写入版本目录的 `latest.json`。`update_root_latest` 默认 false，本次不推广根目录更新指针。

## 验证

本地已完成：

- Python 3.12 和 3.14.7 下 **103 项回归测试通过**；Python 脚本编译与 Unix shell 语法检查通过。
- Windows PowerShell 5.1 下 **62 项隔离函数检查通过**，覆盖路径/命令行解析、只读预检、计划任务识别、冷复制、原子 journal 和文件锁。
- 真实上游 `write_install_stamp.py` 调用成功，输出 schema 2、真实版本 0.22.2、提交 d923a5e、干净源码及 external 更新责任方。
- 新配置已用上游配置/模型路由/gateway 加载器验证；测试凭据和临时 home 隔离，未调用真实模型服务。
- 新回归覆盖：占位版本拒绝、旧版兼容、精确标签解析、身份错配、0.21.5 到 0.22.2 的清单校验、config 独立产物、OSS 校验失败阻止发布。

Windows release workflow 新增 [真实安装验证脚本](../scripts/smoke_windows.ps1)，在发布前执行：

1. 解压新 ZIP，在含中文和空格的临时路径中便携安装，且不写入用户环境变量或 PATH。
2. 验证来源、metadata、运行时版本、pip 一致性、默认配置和认证后的 API readiness。
3. 下载并校验既有 `v0.21.5-92` ZIP。该包的安装器仍调用已移除的 `hermes version`，因此仅在隔离测试副本中将最后的版本查询改为 `hermes --version`，保留原始 runtime、源码、依赖和配置。安装真实旧 runtime 后加入需保留的模型和用户文件。
4. 运行升级 `-WhatIf`；通过占用 API 端口触发替换 runtime 后的失败，检查完整回滚及配置/凭据保留。
5. 释放端口后执行成功升级并保持停止，验证版本及原有选择和数据。

2026-10-19，[第 105 次构建](https://github.com/bddiudiu/hermes-offline-installer/actions/runs/39196239530)中的上述 Windows 安装/升级验证步骤全部通过，包含真实旧运行时恢复、认证后的 API readiness，以及成功升级后的模型、凭据和用户文件保留。

自动化验证不涵盖实际外部客户端、模型推理服务或全部可选插件；这些仍需目标客户端联调。

## 最终产物

[GitHub Release：v0.22.2-105](https://github.com/bddiudiu/hermes-offline-installer/releases/tag/v0.22.2-105)，安装器提交 `2b905f0755fd0b908c3777a525fb80a40d501979`。

第 105 次工作流最终状态为 **success**。OSS 已发布至 `hermes/0.22.2-105/`：ZIP、独立 config、各自校验文件及版本目录 `latest.json` 均完成 SDK 远端回读，完整 SHA-256 匹配；日志确认 `Root latest.json preserved`，本次未推广根目录更新指针。

- [Windows 一键包](https://github.com/bddiudiu/hermes-offline-installer/releases/download/v0.22.2-105/hermes-offline-installer-win-x64.zip)：229,812,090 字节。
- [独立 config.yaml](https://github.com/bddiudiu/hermes-offline-installer/releases/download/v0.22.2-105/config.yaml)：3,376 字节，UTF-8 / Windows CRLF。
- [一键包 SHA-256](https://github.com/bddiudiu/hermes-offline-installer/releases/download/v0.22.2-105/hermes-offline-installer-win-x64.zip.sha256) 与 [config SHA-256](https://github.com/bddiudiu/hermes-offline-installer/releases/download/v0.22.2-105/config.yaml.sha256) 同目录独立提供。

重新下载后已验证 ZIP 整体哈希、包内 **22,636 个文件**的完整清单哈希、Hermes 0.22.2 / Python 3.14.7 / 上游提交身份。ZIP 内 `templates/config.yaml` 与独立 `config.yaml` 逐字节一致；与仓库模板只存在 Windows CRLF / LF 换行差异。ZIP 内无额外版本示例，也没有将安装包和独立 config 再合成外层压缩包。

```text
hermes-offline-installer-win-x64.zip
ddd059a48ebbde14394d8093b246a8a9dbc8dc25338e6b82be0109b4416d690b

config.yaml
0e3a9941f3966e75743d1e151dc14f6867089dd4bf1abc945a149902a0bc98e6
```
