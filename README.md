# Pikachu

原生 macOS Coding Agent 工作台。Phase 1 功能与冻结性能指标均已通过验收。[原生窗口呈现复验](docs/reports/interaction-performance/NATIVE-PIXELS.md)

## 本地运行

要求 macOS 27、Xcode 27 / Swift 6、Python 3，以及已配置认证的 Pi **1.x** 和 Node。版本检查接受 Pi 1.x 的次版本和补丁版本；实际 RPC 兼容性以所用版本的验证结果为准。当前仅验证本机 arm64 环境。

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

侧栏齿轮打开「通用」「项目」和「服务商」。设置面板随主窗口宽高调整，较长的页面可滚动。通用设置提供后台任务结束通知和界面语言。通知默认关闭。切换界面语言后可立即重新启动，也可保留设置并稍后重启。

在「设置 → 服务商 → Pi 模型」可设置新会话的默认模型，也可恢复为跟随 Pi 设置。点星号收藏常用模型，关闭右侧开关可将模型从会话选择器隐藏。打开会话模型选择器时，有可用的收藏就先显示收藏；仍可查看全部可见模型，当前会话的模型也会保留。

「Providers → Pi」管理 Pi、Node、可信扩展和传给 Pi 子进程的环境变量。App 自动发现 Pi、Node 和系统代理。环境变量值保存在 macOS 钥匙串，保存后在下次启动 Pi 子进程时生效。已有代理配置会迁移为 `HTTP_PROXY`、`HTTPS_PROXY` 和 `NODE_USE_ENV_PROXY`，诊断参数 `--proxy` 仍可覆盖本次启动。认证复用 `~/.pi/agent`。运行时可以修改项目和执行命令，请先确认工作目录。

从 Finder 启动时，Pi 不一定能看到终端里的工具。可在「服务商 → Pi 连接 → 工具搜索目录」选择受信任的工具目录（例如 Apple Silicon 上的 `/opt/homebrew/bin`）。Pikachu 按「已配置的 Node 目录 → 添加的工具目录 → 继承的 PATH」顺序搜索；设置在下次启动 Pi 子进程时生效，不必重启 Pikachu。`PATH` 仍由应用管理，不要在环境变量表里填写。

输入栏提供文件路径引用、执行模式、工具审批、工作区选择、模型与推理强度、上下文用量与明细入口，以及发送。工作区选择器默认使用项目工作区。用户也可选择已有 Worktree，或指定基准提交、分支和路径创建 Worktree。首次运行前可切换目录并保留草稿。之后换目录会在目标位置新建会话并带上草稿。

| 执行模式 | 工具审批 |
| --- | --- |
| 制定计划 | 只开放读取、搜索、查找和列目录，可选「每次审批」或「无需审批」（默认）。 |
| 交互执行 | 可选「每次审批」「工具审批」（默认）或「无需审批」。「工具审批」在修改文件或执行命令前逐次询问。 |
| 自主执行 | 固定「无需审批」。使用 Pi 配置的工具和所选扩展，扩展可发起自身的交互。 |

在「设置 → 通用 → 默认执行模式」可选择新建会话的模式。未修改设置时，新会话默认「交互执行」。修改默认值不会改变已有会话；缺少模式记录的旧会话和导入会话仍使用「自主执行」。会话分别保留制定计划和交互执行的审批选择，空闲时修改的设置在下次连接并发送时生效。

支持流式聊天、基础 Markdown / 代码块、图片附件缩略图、消息发送时间与复制/编辑、轮次署名与执行耗时。对话和本轮文件变更中提及的工作区路径、行内代码与相对链接可直接点击打开，带 `#L` 或 `:行号` 时定位到对应行。Pika 摘要紧跟触发该轮的消息，运行时显示跳动圆点和已用秒数；工具已结束而模型尚未继续输出时，最后一组工具下方显示「思考中」。同一轮中连续的工具调用在执行期间就组成一组；只有一条时该行同时作为组标题，完成后保留展开状态，展开后可逐项查看参数与输出。模型调用失败时，失败提示旁提供确认后重试上一条消息的入口。长历史使用 AppKit 可见行复用，保留原生文本选择与代码复制。当前会话运行时，编辑区左侧的胶囊可切换「中途调整」和「排队执行」。光标和每一行文字都从胶囊右侧开始；空闲时隐藏胶囊，恢复全宽。右下角空闲时显示「发送」，运行中显示「停止」。Return 或 Shift-Return 换行，⌘ Return 发送，⌘ . 停止。停止不会撤销已完成的文件操作。

支持多项目、独立会话草稿、只读历史和重启恢复。打开模型选择器时加载可用模型。执行会话空闲时立即应用模型配置，其余会话保存并在下次发送时应用。会话顶栏展示项目与会话身份、Git 摘要和连接操作。连接状态统一紧跟会话标题，运行中使用胶囊；悬停可查看详情。点击项目名可在当前项目下新建会话。会话列表在启动和工作台重新激活时自动刷新。手动会话可并行运行，不设固定并发额度。会话独立处理消息、扩展请求及停止；同目录会话共享项目文件，同时改代码建议使用不同的 Worktree。切换会话时已有任务继续运行，可从侧栏或后台运行横幅定位；横幅较多时可滚动。启动其他会话不会挤掉已有连接。没有运行任务、待执行队列或扩展交互的连接，持续空闲 35 分钟后才会自动断开，避免为了节省本地 CPU 在常见的半小时续聊窗口内提前重启运行时；历史和草稿保留，下次发送会按需重连。模型缓存的有效期和命中由服务商决定。清理未确认时，会话仍会阻止新的执行。

工作台的项目索引、草稿、配置与发送状态保存在 `~/Library/Application Support/Pikachu/Workspace/workspace.store`（SwiftData）。普通编辑约 250 ms 合并保存；发送前必须完成提交状态持久化，退出前显式保存。尚未保存的编辑不承诺在强制退出后恢复。

对话真实来源仍是 Pi JSONL。新会话保存在 `~/Library/Application Support/Pikachu/Sessions/<projectID>/`；同时发现标准 `~/.pi/agent/sessions/`。打开项目和“刷新”用于发现历史，重新选择会话会读取源文件。读取不启动 Pi。未知格式、损坏、缺失或尾部未写完均明确提示；已确认的历史不会静默变成空会话。

「设置 → 项目」提供工作目录、「加载项目提供的 Pi 配置」开关、项目级的会话刷新和重新定位。项目配置加载默认关闭（启动 Pi 时传入 `--no-approve`），按实际工作目录保存；主目录与各 Worktree 分别设置，切换 Worktree 或重新定位后按目标目录自己的设置生效，开启时传入 `--approve`。目录移动后，用「重新定位项目…」更新原路径并保留项目和会话标识。旧会话仍可只读查看。要在新位置执行任务，请新建会话。

重启不恢复推理、不重放旧队列、不自动重发任务。结果未确认的提交保留关联标识，并要求用户核对。提供累计 Token / 估算费用、独立上下文占用、原生扩展弹窗与快捷键；未知费用明确显示不可用。原生性能的完成边界见报告。

⌘B 显示或隐藏侧栏，⌘, 打开设置，⌘L 聚焦输入，⇧⌘R 返回执行会话，⇧⌘M 模型设置，⇧⌘U 查看或关闭用量，⇧⌘I 处理交互请求。可信扩展可从「服务商 → Pi 连接」添加，由自主执行加载。

侧栏按「待处理」和「已处理」组织会话。悬停待处理卡片可显示提醒和标记已处理操作，运行标签位于时间左侧。标记已处理后，会话移入「已处理」，右键可移回「待处理」。顶部可搜索和筛选项目，左下角刷新本地会话，底栏右侧的账户额度入口读取本机 Codex CLI 的账户额度，弹层标注额度只属于本机 Codex 账号、不绑定当前会话，并可手动刷新。

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

开发者可用 `--fake` 参数替换执行后端；同一界面和协调器无需修改。`--state-dir` 可指定隔离的工作台存储，`--sessions` 指定会话目录（均已在 `Pikachu` scheme 的启动参数中预置）。由语言设置重启时，相对路径仍以原启动目录为准。其余诊断参数见 [AppSettings](Pikachu/App/AppSettings.swift)。不要将 Pi 凭据复制到项目或诊断文件中。

## 文档

- [产品与架构设计](DESIGN.md)
- [验证工具说明与命名对照](Verification/README.md)
- [侧边栏会话、提醒及账户额度](docs/design/sidebar-session-groups-v2.md)
- [侧边栏分组方向与选中样式](docs/design/sidebar-session-groups-v3.md)
- [侧栏会话列表与 Settled 历史](docs/design/sidebar-session-groups-v4.md)
- [设置分组与交互](docs/design/settings-organization.md)
- [Pi 协议兼容与进程监督报告](docs/reports/pi-rpc-compatibility/SUPERVISION.md)
- [运行时集成与原生交互报告](docs/reports/runtime-integration/REPORT.md)
- [工作台持久化与会话恢复报告](docs/reports/workspace-recovery/REPORT.md)
- [扩展交互与工作台优化报告](docs/reports/interaction-performance/REPORT.md)
- [原生性能验收报告](docs/reports/interaction-performance/PERFORMANCE.md)
- [领域投影基线与性能目标](docs/reports/runtime-integration/PERFORMANCE.md)
