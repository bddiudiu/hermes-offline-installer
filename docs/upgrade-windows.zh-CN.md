# Windows 离线安装升级

`upgrade.cmd` 用于升级已有的 Windows 离线安装。它从**另一个目录中完整解压的新版 ZIP** 读取文件，在检查、备份后替换旧 runtime，并验证启动和回滚所需的状态。首次安装仍使用 `install.cmd`。

> 升级包含停机窗口。请先做独立备份，并安排可以停止 Hermes、ClawPanel 和外部守护程序的维护时间。下面的命令需要在新版 ZIP 的解压目录执行；不要把新版文件直接覆盖到旧安装目录。

## 1. 准备与只读预检

1. 从可信发布方取得并验证适合 Windows x64 的新版离线 ZIP，完整解压到一个新目录，例如 `D:\Downloads\Hermes-new`。保留包内校验清单与全部文件，不要只复制 `upgrade.cmd`。
2. 确认旧安装根目录，即包含 `runtime` 和 `bin` 的 `HERMES_OFFLINE_HOME`，而不是 `runtime` 子目录、Python 目录或仅存放配置的 `HERMES_HOME`。
3. 在新版解压目录打开 CMD，先运行：

   ```cmd
   upgrade.cmd "C:\old\install" -WhatIf
   ```

   默认产品路径的例子：

   ```cmd
   upgrade.cmd "C:\Program Files\StarSoftComm\ZhanClaw\Hermes" -WhatIf
   ```

`-WhatIf` 只做读取与预检并显示计划，不停止进程，不备份、安装或修改旧目录和持久用户环境。PowerShell 的辅助代码编译可能使用系统临时目录。包内 SHA-256 清单检查解压内容完整性，不证明发布者身份；它不能替代可信来源或发布方的 ZIP 校验。预检会拒绝缺失或不匹配的包内校验数据、不安全的目录关系和不能可靠识别的安装状态。先处理报错，不要通过删掉清单或覆盖旧目录绕过检查。

### 指定准确的用户数据目录

升级器从旧安装生成的 `bin\hermes.cmd` 读取原 `HERMES_HOME`，不会执行该脚本。可以显式传入同一路径作为核对；如果与旧 shim 不符、无法唯一解析或存在未展开变量，升级会拒绝继续。请先确认原启动配置，不要靠覆盖参数猜测目录：

```cmd
upgrade.cmd "C:\old\install" -HermesHome "D:\Hermes\home" -WhatIf
```

正式升级时传入相同路径：

```cmd
upgrade.cmd "C:\old\install" -HermesHome "D:\Hermes\home"
```

这个参数是对原 home 的断言，不会覆盖 shim 指向，也不是迁移用户数据目录的命令。便携安装也应传入原安装的实际 runtime 根目录与 home；不要把新版解压目录中的空目录当成旧数据。

## 2. 停止外部调用方并升级

退出会继续调用或重新拉起 Hermes 的终端、ClawPanel 和其他 supervisor；涉及的计划任务需要禁用，Windows 服务需要停止并禁用自动启动。升级器不会静默改变外部 supervisor 的配置，也不会把多个独立 gateway 自动改为 multiplex 模式。

没有外部 supervisor 时，可在确认预检结果后运行：

```cmd
upgrade.cmd "C:\old\install"
```

若安装由 ClawPanel、服务、计划任务等外部程序管理，先在相应程序中停止管理与重启行为，再使用：

```cmd
upgrade.cmd "C:\old\install" -SupervisorStopped
```

`-SupervisorStopped` 是你对“外部调用方和 supervisor 已停止”的明确声明，不会替你停止那些程序，也不会允许绕过仍在运行的、不明来源的进程检查。升级器遇到多个独立 gateway、无法安全归属的 supervisor 或无法确认已停止的写入者时会拒绝继续。请按输出处理后重新执行预检。

### 权限与自动化

- `upgrade.cmd` 不自动提权、不弹出交互式暂停；需要访问 `Program Files` 等受保护目录时，请预先用具备对应权限的 CMD / PowerShell 启动它
- CMD 入口等待 PowerShell 完成，原样返回其退出码；自动化应检查退出码，不能仅凭进程已启动或文件已复制判定成功
- Windows PowerShell 5.1 是兼容目标；直接调用 `installers\upgrade.ps1` 时也应遵循相同参数和检查流程
- 不要在升级期间重新启动外部客户端、gateway 或其他 home 写入者

例如批处理：

```cmd
call upgrade.cmd "C:\old\install" -SupervisorStopped
set "UPGRADE_EXIT=%ERRORLEVEL%"
exit /b %UPGRADE_EXIT%
```

## 3. 保留的数据与配置

升级应保留已有配置，不使用首次安装流程重置模型选择：

- `config.yaml` 中的模型列表、provider 映射和默认模型，以及其他已有配置
- `.env` 中已有的凭据和变量值；官方迁移允许调整文件格式，但已有值的语义必须保持不变。不要把 `.env` 粘贴到工单或公开日志中
- 完整 `HERMES_HOME`，包括 profiles、skills、plugins、会话、状态、日志、SQLite 数据库以及同目录的 WAL / SHM 文件

home 的一致性备份在相关进程停止后进行。失败回滚使用完整 home 快照，而不只是恢复 `config.yaml` 或单个数据库文件，这样新版本启动时发生的数据迁移也能回退。home 外自定义存放的数据和外部数据库不在这个范围内，应由维护人员另行备份。

内置 skills 使用上游官方同步逻辑：只有与旧包完全一致、没有任何用户修改的完整 skill 目录可更新到新版；自定义或已修改的 skill 文件继续受保护。官方同步维护 `.bundled_manifest`，升级检查不会把这份同步元数据的正常更新当成用户文件丢失。

升级不自动进行多 gateway 到 multiplex 的拓扑转换。旧 runtime 低于 `0.21.4` 且存在命名 profiles 时，以及配置明确使用 standalone 或关闭 multiplex 时，会要求先审查 gateway 拓扑。需要转换时，应另行规划、验证和备份。

## 4. 验证与保持停止

成功必须通过新版 runtime 的实际健康检查；只完成解压、Python 导入或进程创建不足以判定服务可用。检查会使用现有 API server 的凭据，在本机回环地址验证版本和已认证 readiness；API server 被禁用、密钥缺失或明显不安全、绑定方式不受支持时会阻止升级，需要先单独处理配置，不能靠 `-KeepStopped` 跳过。健康检查不发起付费的外部模型推理请求，因此不能证明每个外部 provider 的额度和推理响应正常。默认健康检查超时为 90 秒，可用 `-HealthTimeoutSeconds` 调整。根据升级器报告核对版本、配置保护检查及 Dashboard / gateway 的启动状态，再重新接入外部客户端。

如果希望完成健康验证后保持服务停止，用：

```cmd
upgrade.cmd "C:\old\install" -KeepStopped
```

`-KeepStopped` 不跳过真实健康检查。需要同时声明已停止外部 supervisor 时，可以组合：

```cmd
upgrade.cmd "C:\old\install" -SupervisorStopped -KeepStopped
```

### 有意重建相同版本

默认拒绝把相同版本当成一次新升级。确需使用同版的完整、校验通过的新解压包重建时，显式添加 `-AllowSameVersion`；它仍执行备份、配置保护和健康验证，也不允许降级。需要回到旧版本时使用匹配的 runtime 与数据备份，不直接把旧 ZIP 当作升级包运行。

## 5. 失败与中断恢复

普通失败会尝试恢复旧 runtime 和完整 home，并报告回滚结果。请保留完整输出并检查退出码；“尝试回滚”不等于“已确认恢复”。若回滚失败，保持外部客户端停止，不要直接重跑安装器覆盖现场。

如果断电、窗口被强制关闭或系统重启留下未完成的事务日志，保留新版解压包、旧安装目录及备份，在确认外部调用方仍已停止后运行：

```cmd
upgrade.cmd "C:\old\install" -Recover
```

需要时追加同一 `-HermesHome` 或 `-SupervisorStopped` 参数。`-Recover` 根据已有事务日志恢复上次中断的状态，不是跳过预检强制进行一次新升级。遵照它的输出确认恢复结果后，重新运行 `-WhatIf`，再决定是否重新升级。

备份和事务资料会保留，可能包含凭据、会话和数据库。应放在受控的本地磁盘，保留其访问权限，不上传到公开位置；只有确认新版正常、独立备份可用且不再需要回退后，才由维护人员决定清理。不要在处理中断事务时删除或修改备份内容。

## 6. 构建验收与 OSS 更新渠道

GitHub Actions 的 `update_root_latest` 是默认 `false` 的布尔输入。常规构建会先上传安装包、校验文件等产物，全部成功后再上传版本目录中的元数据：

```text
<ALIYUN_OSS_PREFIX，默认 hermes>/<HermesVersion>-<runNumber>/latest.json
```

默认保留根目录的 `<prefix>/latest.json`（默认 `hermes/latest.json`），因此上传验收包不会把现有客户端的自动更新渠道切到未经验证的版本。应先使用版本目录中的 ZIP 完成 Windows 升级、配置保留、健康检查和回滚验收。

只有发布负责人确认可推广，并在手动触发工作流时显式将 `update_root_latest` 设为 `true`，才会在版本元数据上传成功后更新根目录 `latest.json`。安装包上传失败或版本元数据上传失败时不会推广根目录元数据。上传成功不等于 Windows 实机升级验收通过。

## 验证范围

仓库中的 Python 回归测试、脚本静态检查和 PowerShell 语法检查不能替代 Windows 真实升级演练。本指南不代表已在 Windows 实机验证成功。发布前至少应在可回退的测试机覆盖：普通与便携安装、含空格/中文路径、实际 Dashboard/gateway 启动、外部 supervisor 阻断、失败回滚，以及中断后的 `-Recover`。
