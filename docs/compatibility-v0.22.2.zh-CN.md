# Hermes 0.22.2 适配与构建记录

日期：2026-10-19。上游固定为 [v0.22.2](https://github.com/NousResearch/hermes-agent/releases/tag/v0.22.2)，提交 `d923a5eb487a17c0a68801bba9ef0f56c81040a8`。安装器基于上一版 `e31ccd3`，工作分支为 `codex/hermes-0.22.2`。

## 已实施的适配

- 构建解释器、依赖下载器和包内 Python 同步为 **3.14.7**。构建脚本检查实际解释器、系统及架构，阻止 pip 在旧 Python 上错误跳过 `python_version >= '3.14'` 的核心依赖。
- `HERMES_SOURCE` 默认固定为 `v0.22.2`。依赖解析使用已检出的本地源码，与资源、版本、提交保持一致，不重复从远端标签获取另一份源码。
- 上游 `project.version = "0.0.0"` 作为 distribution metadata 保留。真实发布版本从源码 HEAD 对应的稳定标签读取，通过上游 `scripts/write_install_stamp.py` 生成 `install-stamp.json`。其中记录真实提交、`baseVersion = 0.22.2`、`displayVersion = 0.22.2` 和 `updateMechanism = external`。
- 构建、升级预检和运行时校验统一检查真实版本与提交，同时验证 distribution metadata 与源码一致。无效身份文件、缺少版本或提交错配会失败；旧 0.21.5 无 stamp 的安装继续按其原有 metadata 读取版本。
- 补充核心 wheel 检查和安装后导入检查，包含 OpenAI SDK、ruamel.yaml、dotenv、truststore。升级辅助脚本依赖的 PyYAML 也显式预装。

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

- Python 3.14.7 下 **99 项回归测试通过**；Python 脚本编译与 Unix shell 语法检查通过。
- 真实上游 `write_install_stamp.py` 调用成功，输出 schema 2、真实版本 0.22.2、提交 d923a5e、干净源码及 external 更新责任方。
- 新配置已用上游配置/模型路由/gateway 加载器验证；测试凭据和临时 home 隔离，未调用真实模型服务。
- 新回归覆盖：占位版本拒绝、旧版兼容、精确标签解析、身份错配、0.21.5 到 0.22.2 的清单校验、config 独立产物、OSS 校验失败阻止发布。

Windows release workflow 新增 [真实安装验证脚本](../scripts/smoke_windows.ps1)，在发布前执行：

1. 解压新 ZIP，在含中文和空格的临时路径中便携安装，且不写入用户环境变量或 PATH。
2. 验证来源、metadata、运行时版本、pip 一致性、默认配置和认证后的 API readiness。
3. 下载并校验既有 `v0.21.5-92` ZIP，安装真实旧 runtime，加入需保留的模型和用户文件。
4. 运行升级 `-WhatIf`；通过占用 API 端口触发替换 runtime 后的失败，检查完整回滚及配置/凭据保留。
5. 释放端口后执行成功升级并保持停止，验证版本及原有选择和数据。

以上 Windows 工作流尚待本次运行结果确认。构建和发布结果将在验证完成后补充。自动化验证不涵盖实际外部客户端、模型推理服务或全部可选插件；这些仍需目标客户端联调。
