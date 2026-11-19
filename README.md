# Pikachu

原生 macOS Coding Agent 工作台。Phase 1 功能与冻结性能指标均已通过验收。[原生窗口呈现复验](docs/reports/interaction-performance/NATIVE-PIXELS.md)

## 本地运行

要求 macOS 27、Xcode 27 / Swift 6、Python 3，以及已配置认证的 Pi **1.5.2** 和 Node。当前仅验证本机 arm64 环境。

### 使用 Xcode

打开 `Pikachu.xcodeproj`，选择 `Pikachu` scheme，按 ⌘R 构建并运行（⌘U 运行全部单元测试）。工程默认采用本地 ad-hoc 签名，自动内嵌 6 个动态 framework 与独立监督进程 `pikachu-supervisor`。

### 使用命令行（`xcodebuild`）

Debug 构建并启动：

```sh
xcodebuild -project Pikachu.xcodeproj -scheme Pikachu -derivedDataPath build build
open build/Build/Products/Debug/Pikachu.app
```

Release 构建并启动：

```sh
xcodebuild -project Pikachu.xcodeproj -scheme Pikachu -configuration Release -derivedDataPath build build
open build/Build/Products/Release/Pikachu.app
```

独立诊断配置构建（必须使用非默认 Bundle Identifier，防止混入正式工作台）：

```sh
xcodebuild -project Pikachu.xcodeproj -scheme Pikachu -configuration Release -derivedDataPath build \
  PIKACHU_BUNDLE_IDENTIFIER=ai.yuzio.pikachu.diagnostics \
  PIKACHU_DIAGNOSTICS_CONFIG=/path/to/DiagnosticsConfiguration.json \
  build
```

打开后，点击「打开项目…」，选择或新建会话。发送草稿时自动连接并开始任务。

App 自动发现 Pi、Node 和系统代理，连接前可在“连接设置”调整。认证复用 `~/.pi/agent`；没有新增密钥管理。运行时可以修改项目和执行命令，请先确认工作目录。

输入栏提供文件路径引用、执行模式、权限摘要、模型与推理强度、上下文用量与明细入口，以及发送。新会话默认使用「交互」，写入、编辑和命令执行前逐次确认。「计划」只开放读取和搜索，「自动」使用现有工具和已选第三方扩展。已有和导入会话默认使用「自动」。

支持流式聊天、基础 Markdown / 代码块、工具展开、消息发送时间与复制/编辑、轮次署名与执行耗时、补充与后续输入、停止和草稿恢复。长历史使用 AppKit 可见行复用，保留原生文本选择与代码复制。⌘ Return 发送，⌘ . 停止。停止不会撤销已完成的文件操作。

支持多项目、独立会话草稿、只读历史和重启恢复。打开模型选择器时加载可用模型。执行会话空闲时立即应用模型配置，其余会话保存并在下次发送时应用。会话顶栏展示连接状态、项目与会话身份、Git 分支/领先提交/变更文件摘要及当前会话的停止与连接操作。查看其他会话时当前任务继续运行，顶部按需显示运行横幅以返回执行会话或停止它；跨会话执行时可明确停止旧任务并发送。

工作台的项目索引、草稿、配置与发送状态保存在 `~/Library/Application Support/Pikachu/Workspace/workspace.store`（SwiftData）。普通编辑约 250 ms 合并保存；发送前必须完成提交状态持久化，退出前显式保存。尚未保存的编辑不承诺在强制退出后恢复。

对话真实来源仍是 Pi JSONL。新会话保存在 `~/Library/Application Support/Pikachu/Sessions/<projectID>/`；同时发现标准 `~/.pi/agent/sessions/` 和历史兼容目录 `~/Library/Application Support/Pikachu/M1Sessions/`。打开项目和“刷新”用于发现历史，重新选择会话会读取源文件。读取不启动 Pi。未知格式、损坏、缺失或尾部未写完均明确提示；已确认的历史不会静默变成空会话。

目录移动后用“重新定位项目…”更新原项目路径，保留稳定项目和会话标识。Pi 1.5.2 RPC 无法覆盖旧历史中的工作目录，因此旧会话只读，不能在新位置直接续跑；可在新位置新建会话，原历史不改写。

重启不恢复推理、不重放旧队列、不自动重发任务。结果未确认的提交保留关联标识，并要求用户核对。提供累计 Token / 估算费用、独立上下文占用、原生扩展弹窗与快捷键；未知费用明确显示不可用。原生性能的完成边界见报告。

快捷键还包括 ⌘L 聚焦输入、⇧⌘R 返回执行会话、⇧⌘M 模型设置、⇧⌘U 用量、⇧⌘I 处理交互请求。可信扩展可在「连接设置」明确添加，由自动模式加载。

侧栏按 Open 和 Settled 组织会话。点击「已处理」后移入 Settled，右键可移回 Open。顶部可搜索和筛选项目，左下角刷新本地会话，底栏右侧的账户额度入口在当前版本显示额度不可用。

## 验证

```sh
# 单元测试（PikachuTests + ProcessSupervisionTests）
xcodebuild -project Pikachu.xcodeproj -scheme Pikachu -derivedDataPath build test

# 构建并运行集成验证工具（均可在 Xcode 中通过对应 scheme 运行）
xcodebuild -project Pikachu.xcodeproj -scheme pi-compat-probe -derivedDataPath build build
xcodebuild -project Pikachu.xcodeproj -scheme runtime-verify -derivedDataPath build build
xcodebuild -project Pikachu.xcodeproj -scheme workspace-verify -derivedDataPath build build
xcodebuild -project Pikachu.xcodeproj -scheme interaction-verify -configuration Release -derivedDataPath build build

build/Build/Products/Debug/pi-compat-probe --suite local
build/Build/Products/Debug/pi-compat-probe --suite supervision
build/Build/Products/Debug/runtime-verify
build/Build/Products/Debug/runtime-verify --real
build/Build/Products/Debug/runtime-verify --baseline
build/Build/Products/Debug/workspace-verify
build/Build/Products/Debug/workspace-verify --real
build/Build/Products/Release/interaction-verify
python3 Scripts/check-execution-policy.py --wait-for-timeout
```

`runtime-verify` 默认使用合成协议进程；`workspace-verify` 默认还验证本机 Pi 的无推理恢复与合成故障。`--real` 额外使用现有 Pi 认证和模型，在临时目录中执行真实编码任务，会产生模型调用费用。`interaction-verify` 默认验证真实 Pi 的扩展命令与合成大输出，不调用模型。结果统一写入忽略目录 `.verification-runs/<工具名>/`。基线只测领域状态投影，不测原生显示延迟。详细参数见 [验证工具说明](Verification/README.md)。

开发者可用 `--fake` 参数替换执行后端；同一界面和协调器无需修改。`--state-dir` 可指定隔离的工作台存储，`--sessions` 指定会话目录（均已在 `Pikachu` scheme 的启动参数中预置）。其余诊断参数见 [AppSettings](Pikachu/App/AppSettings.swift)。不要将 Pi 凭据复制到项目或诊断文件中。

## 文档

- [产品与架构设计](DESIGN.md)
- [验证工具说明与命名对照](Verification/README.md)
- [侧边栏会话、提醒及账户额度](docs/design/sidebar-session-groups-v2.md)
- [Pi 协议兼容与进程监督报告](docs/reports/pi-rpc-compatibility/SUPERVISION.md)
- [运行时集成与原生交互报告](docs/reports/runtime-integration/REPORT.md)
- [工作台持久化与会话恢复报告](docs/reports/workspace-recovery/REPORT.md)
- [扩展交互与工作台优化报告](docs/reports/interaction-performance/REPORT.md)
- [原生性能验收报告](docs/reports/interaction-performance/PERFORMANCE.md)
- [领域投影基线与性能目标](docs/reports/runtime-integration/PERFORMANCE.md)
