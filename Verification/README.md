# Pikachu 验证工具

所有验证工具均由 `Pikachu.xcodeproj` 管理，提供对应的共享 scheme，产物输出到构建目录（如 `build/Build/Products/<Debug|Release>/`），每次运行结果写入忽略目录 `.verification-runs/<工具名>/<runID>/`。

要求 macOS 27+、Xcode 27 / Swift 6、Python 3，以及 Pi **1.5.2** 和 Node。所有工具都会通过依赖自动构建同目录的独立监督进程 `pikachu-supervisor`。

## 工具与用法

### 1. `pi-compat-probe`（Pi 协议与进程监督兼容探针）

独立测试 Pi 1.5.2 RPC 协议行为、历史分支读取和 `pikachu-supervisor` 进程树监督策略。

```sh
xcodebuild -project Pikachu.xcodeproj -scheme pi-compat-probe -derivedDataPath build build
build/Build/Products/Debug/pi-compat-probe --suite local
build/Build/Products/Debug/pi-compat-probe --suite extended
build/Build/Products/Debug/pi-compat-probe --suite supervision
build/Build/Products/Debug/pi-compat-probe --suite real --proxy http://127.0.0.1:7897
build/Build/Products/Debug/pi-compat-probe --suite continuation --proxy http://127.0.0.1:7897
build/Build/Products/Debug/pi-compat-probe --suite agent-crash --proxy http://127.0.0.1:7897
```

可选参数：`--pi`、`--node`、`--provider`、`--model`、`--proxy`、`--output`。默认 Pi 为 `~/bin/pi`，Node 为 `~/.nvm/versions/node/v24.12.0/bin/node`，默认模型为 `openai/gpt-6.1-sol`。

| Suite | 内容 | 模型调用 |
|---|---|---|
| `local` | 启动环境、真实 RPC、模型查询、扩展交互、直接 Bash 停止、空闲崩溃 | 无 |
| `extended` | 构造分支/压缩历史、EOF、直接 Bash 崩溃、10 MiB 输出 | 无 |
| `supervision` | 脱离后代、宿主 SIGKILL、实例隔离、监督失效与 SIGTERM 升级 | 无 |
| `real` | 三轮真实缺陷修复、三轮 Agent 队列清空及停止 | 有 |
| `continuation` | 补充和 follow-up 的实际交付 | 有 |
| `agent-crash` | 三轮真实 Agent Bash 运行期间终止 Pi | 有 |
| `all` | 上述全部 | 有 |

监督进程为运行时注入每实例随机标记（`PIKACHU_EXECUTION_TOKEN`），按同用户进程的标记、已观测谱系和启动时间维护所有权；Pi 或 RPC 宿主退出后清理对应进程并等待终态。`--unsupervised` 仅供研究原始行为，不可用于监督策略验收。每轮使用独立临时目录和权限 `0700` 的隔离配置目录（`auth.json` 权限 `0600`），正常收尾自动删除。

### 2. `runtime-verify`（运行时集成与领域投影基线）

```sh
xcodebuild -project Pikachu.xcodeproj -scheme runtime-verify -derivedDataPath build build
build/Build/Products/Debug/runtime-verify
build/Build/Products/Debug/runtime-verify --real
build/Build/Products/Debug/runtime-verify --baseline
```

默认使用合成协议夹具（`Verification/Fixtures/fake-pi.py`），不调用模型；`--real` 在临时目录执行真实编码任务（会产生模型调用费用）；`--baseline` 测量 100 / 5,000 条消息的领域状态投影耗时（不测原生显示延迟）。

### 3. `workspace-verify`（工作台状态、只读历史与恢复验证）

```sh
xcodebuild -project Pikachu.xcodeproj -scheme workspace-verify -derivedDataPath build build
build/Build/Products/Debug/workspace-verify
build/Build/Products/Debug/workspace-verify --real
build/Build/Products/Debug/workspace-verify --case workspace/local-drafts-and-restart
```

默认验证本地草稿持久化、只读历史分支/压缩/损坏拦截、本机 Pi 无推理恢复及合成故障无重放；`--real` 额外验证模型配置读回、真实编码恢复、运行中切换和目录重新定位。

### 4. `interaction-verify`（原生扩展交互、用量与大输出负载）

```sh
xcodebuild -project Pikachu.xcodeproj -scheme interaction-verify -configuration Release -derivedDataPath build build
build/Build/Products/Release/interaction-verify
```

默认使用真实 Pi 的隔离扩展夹具与 10 MiB 合成流式负载，不调用模型。另支持：
- `--prepare-native <空目录>`：生成原生诊断数据集与 `DiagnosticsConfiguration.json` / `LoadDiagnosticsConfiguration.json`。
- `--history-benchmark <目录>`：测量 100 / 5,000 条历史文件读取耗时。

### 5. 执行模式与原生像素分析脚本

```sh
python3 Scripts/check-execution-policy.py --wait-for-timeout
python3 Scripts/analyze-window-pixels.py <capture-root> --help
```

---

## 新旧名称对照表（历史报告参考）

项目由 SwiftPM 重构为 `Pikachu.xcodeproj` 时，将历史里程碑命名（`M0`–`M3`）统一改为按职责命名。`docs/reports/` 中的归档报告和证据保持当时原文，对照关系如下：

| 历史名称（归档报告） | 当前名称 |
|---|---|
| `Tools/M0Validation` / `m0-verify` | `Verification/PiCompatProbe` / `pi-compat-probe` |
| `Tools/M1Verification` / `m1-verify` | `Verification/RuntimeVerify` / `runtime-verify` |
| `Tools/M2Verification` / `m2-verify` | `Verification/WorkspaceVerify` / `workspace-verify` |
| `Tools/M3Verification` / `m3-verify` | `Verification/InteractionVerify` / `interaction-verify` |
| `CM0Process` / `M0Support` / `m0-supervisor` | `CProcessInspection` / `ProcessSupervision` / `pikachu-supervisor` |
| `Packages/*` / `PikachuApp/` / `PikachuCoreTests` | `Modules/*` / `Pikachu/` / `PikachuTests` |
| `Tools/M0Validation/Tests/M0SupportTests` | `Tests/ProcessSupervisionTests` |
| `.m0-runs/` … `.m3-runs/` | `.verification-runs/<工具名>/` |
| 用例前缀 `M0-*` / `M0-S/` / `M1/` / `M2/` / `M3/` | `pi-compat/` / `pi-compat/supervision/` / `runtime/` / `workspace/` / `interaction/` |
| 夹具命令 `/m0-*`、`/m2-noop`、`/m3-*` | `/fixture-*`、`/fixture-noop`、`/interaction-*` |
| `PIKACHU_M0_EXECUTION_TOKEN` / `M0_SUPERVISION_FAIL_SCAN` | `PIKACHU_EXECUTION_TOKEN` / `PIKACHU_SUPERVISION_FAIL_SCAN` |
| `M3Diagnostics.json` / `M3Metric` | `DiagnosticsConfiguration.json` / `DiagnosticMetric` |
| `Scripts/analyze-m3-pixels.py` | `Scripts/analyze-window-pixels.py` |
| `Tools/M3Verification/Fixtures/execution-policy.py` | `Scripts/check-execution-policy.py` |
| `docs/m0` / `docs/m1` / `docs/m2` / `docs/m3` | `docs/reports/{pi-rpc-compatibility, runtime-integration, workspace-recovery, interaction-performance}` |
