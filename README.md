# Pikachu

Pikachu 是通过 ACP 连接本地编程智能体的原生 macOS 工作台，支持多项目、并行会话、Worktree、工具审批和历史浏览。

## 本地运行

- 构建需要 macOS 27 或更高版本、Xcode 27 和 Swift 6。当前验证环境为 Apple Silicon（arm64）。
- 真实会话需要至少一个已安装的 ACP 智能体。可执行文件、启动参数和认证由对应智能体管理。
- Python 3 用于验证工具和测试夹具。

用 Xcode 打开 `Pikachu.xcodeproj`，选择 `Pikachu` scheme，按 ⌘R 构建并运行。工程采用本地 ad-hoc 签名，并内嵌运行时框架和独立监督进程 `pikachu-supervisor`。也可以在仓库根目录运行下列命令。

```sh
xcodebuild -project Pikachu.xcodeproj -scheme Pikachu -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/Pikachu.app
```

构建 Release 时将 `-configuration Debug` 改为 `-configuration Release`，打开 `build/Build/Products/Release/Pikachu.app`。

首次启动时，在「设置 → 智能体」添加并启用本机 ACP 智能体。打开项目后即可新建会话；首次发送时按需连接。也可以从侧栏或 ⌘N 进入配置。

## 使用工作台

### 会话和工作目录

手动会话可并行运行，没有固定会话额度。每个会话独立处理消息、工具审批和停止操作。切换查看对象时，后台任务继续执行。可从侧栏、后台运行横幅或 macOS 菜单栏返回会话。菜单栏显示运行、待审批和未读完成的数量。

输入栏的工作区选择器默认使用项目工作区，也可选已有 Worktree，或指定基准提交、分支和路径新建 Worktree。首次发送前可在原会话切换目录并保留草稿。会话与工作目录绑定后，换目录会在目标目录新建会话并带上草稿。同目录会话共享文件，同时改代码时可使用不同 Worktree。

会话顶栏显示项目、会话、Git 摘要和连接状态。悬停标题旁的连接胶囊可查看详情。空闲连接在无任务、队列或扩展交互的情况下，持续 35 分钟后会断开。下次发送按需重连。受管进程清理未确认时，同一会话暂停新的执行。

侧栏按「待处理」和「已处理」组织会话，支持搜索、项目筛选、刷新和标记处理状态。底栏的账户额度入口显示本机 Codex CLI 账户的额度，可手动刷新。会话用量独立显示累计 Token、估算费用和上下文占用。无法估算的费用会标为不可用。

### 执行模式与审批

连接后，输入栏显示智能体提供的执行模式。工具审批使用智能体返回的选项。文件读写和终端等客户端权限按智能体配置，默认关闭。

### 输入与对话

- 默认按 ⌘ Return 发送，Return 或 ⇧ Return 换行，⌘. 停止。可在「设置 → 通用 → 输入与对话」选择 Return 发送。运行中可编辑下一条草稿，本轮结束后再发送。停止会请求智能体取消当前回合，已完成的文件写入会保留。
- 输入栏支持添加文件、从剪贴板粘贴图片、从 Finder 粘贴视频文件。图片和视频可显示缩略图。附件以文件路径随消息发送，引用的视频留在原位置。
- 对话支持流式 Markdown、列表、表格、可复制的代码块和原生文本选择，提供消息复制、用户消息重编辑、右侧消息导航和「回到最新」。长历史使用 AppKit 可见行复用。
- 同一轮中连续的工具调用自动成组，默认折叠。展开后可检查参数和输出。只有一项时，该工具行就是组标题。工具结束后如果模型尚未继续输出，会显示「思考中」。模型调用失败时，可以确认后重试上一条消息。
- 点击窗口右上角的「项目文件」或按 ⌥⌘B，浏览当前会话目录。宽窗中目录在文件面板左侧。打开的文件显示在顶部标签栏，悬停时可从标签左侧关闭，切换工作目录会清空标签。面包屑标明项目或 worktree，可点击目录段定位。正文默认显示带行号的原文，支持切换换行和 Markdown 格式预览。刷新可读取磁盘上的新内容并尽量保留阅读位置。「打开方式」可临时选择 Finder、编辑器或系统默认方式。
- 点击工作区文件链接或本轮变更的文件可打开对应路径。链接可用 `#L42` 或 `:42` 指定行号，所选编辑器支持时会跳转到该行。

### 常用设置

点击侧栏齿轮或按 ⌘, 打开设置。

| 位置 | 用途 |
| --- | --- |
| 通用 | 管理通知、界面语言、字体、文件打开方式、发送快捷键和会话标题。 |
| 项目 | 管理显示名称、工作目录、归档和项目规则及 Skills 的来源。 |
| 智能体 | 添加或启用 ACP 智能体，检查连接、登录和配置模型。 |

在「设置 → 通用 → 会话标题」可设置所有项目的命名规则，选择自动、指定模型或关闭模型生成。默认自动使用「智能体」列表中首个可独立生成标题的配置，优先使用为该智能体保存的默认模型。新会话先使用首条消息或附件名称。智能体确认收到首条正文后，Pikachu 将完整正文和命名规则交给标题模型生成一次。纯附件、历史恢复和手动命名保留各自的标题。模型不可用时保留首条消息标题。

目前可独立生成标题的配置为 Claude Agent ACP 0.88 起的 0.x 版本，搭配 Claude Code 2.1.293 或更新版本，并配置 Claude API Key 或受支持的云服务认证。仅有 Claude 订阅登录时使用首条消息标题。标题进程使用 Claude Code 的 bare 模式，关闭工具和会话写入。 [Claude Code bare 模式](https://code.claude.com/docs/en/headless#start-faster-with-bare-mode)

在「设置 → 智能体」点击「添加智能体…」，按名称或 ID 搜索官方 ACP Registry。选择智能体后可编辑预填的可执行文件和启动参数。「检查本机安装」查看配置能否找到对应的本地可执行文件。保存后，可在该智能体的设置中运行连接自检以验证 ACP 握手。目录不可用时可重试或手动填写配置。 [ACP Registry](https://agentclientprotocol.com/get-started/registry)

在「登录与登出」选择 Agent 提供的登录方式。选择终端登录后，确认参数及环境覆盖，随后在 Pikachu 的登录终端完成操作。登录成功后应用会重新连接 Agent。

文件打开方式支持系统默认、Xcode、Visual Studio Code 和自定义命令。自定义命令可填 `code -g {path}:{line}`。应用会替换路径和行号，`{path}` 自带 shell 引号，无行号时自动省略 `:{line}`。编辑器不可用或命令失败时，会尝试系统默认应用，需要时在 Finder 中显示文件。

「设置 → 项目」底部可在所有会话断开后删除项目。删除会清除 Pikachu 内的项目设置、会话条目和草稿。磁盘上的项目文件、Worktree 和智能体历史保留。

每个 ACP 智能体可以独立设置普通环境变量和工具搜索目录。从钥匙串存储环境变量的旧版升级后，请在设置中重新录入需要的普通变量。认证由智能体管理。只从环境变量读取 API Key 的智能体需要从 Pikachu 的外部启动环境获取 Key。

⌘O 打开项目，⌘N 新建会话，⌘L 聚焦输入，⌘B 切换侧栏，⌘+ / ⌘- / ⌘0 调整字号，⌃⌘F 切换全屏。⇧⌘M 打开「智能体与模型」，可从当前智能体的收藏或全部可见模型选取模型及推理档位。⇧⌘U 查看或关闭会话用量。仅有一个执行会话时，可用 ⇧⌘R 返回。空闲时按住或连按两次 ⌘Q 退出，有活跃任务时弹出退出确认。

## 本地数据与恢复

- 工作台索引、草稿、配置和发送状态存放于 `~/Library/Application Support/Pikachu/Workspace/workspace.store`（SwiftData），剪贴板粘贴的图片存放在 `~/Library/Application Support/Pikachu/Pasted Images/`。普通编辑约 250 ms 合并保存，发送前先保存提交状态。强制退出时可能丢失尚未保存的编辑。
- ACP 会话按原智能体的能力恢复。断开后可查看已缓存的对话，切换智能体时冻结旧段。新会话优先使用指定的默认智能体，否则使用首个已启用项。
- 升级后，当前绑定内置 Pi 的会话、归档和未发送草稿会移出工作台。原始 JSONL 保留在原位置。当前绑定 ACP 的会话保留全部冻结段，包括早期由 Pi 产生的内容。

- 重启后可恢复已保存的草稿和可确认的历史。系统会标记尚未确认的提交，等待用户核对，避免重复发送或重放队列。重新定位项目后可以继续查看原历史，在新目录执行时需新建会话。

## 开发与验证

Xcode 中用 ⌘U 运行 `PikachuTests` 和 `ProcessSupervisionTests`。命令行入口如下。

```sh
Scripts/run-isolated-verify.sh --scheme Pikachu --action test
```

合成 ACP 集成验证可运行 `Scripts/run-isolated-verify.sh --tool acp-compat-probe -- --suite fake`。更多用法见 [验证工具说明](Verification/README.md)。开发诊断可用 `--state-dir` 指向独立的工作区存储目录。

## 设计与报告

- [产品与架构设计](DESIGN.md) · [设计令牌](DESIGN_TOKEN.md) · [应用图标](docs/design/app-icon/README.md) · [第三方资源声明](THIRD-PARTY-NOTICES.md)
- [工作台布局](docs/design/workbench-ui-refresh.md) · [侧栏会话](docs/design/sidebar-session-groups-v4.md) · [提醒和账户额度](docs/design/sidebar-session-groups-v2.md) · [会话顶栏](docs/design/session-window-toolbar-v2.md)
- [会话详情](docs/design/session-detail-ui-v5.md) · [运行时间线](docs/design/session-run-timeline.md) · [输入区](docs/design/composer-send-mode-placement.md) · [设置](docs/design/settings-organization.md) · [确认弹窗](docs/design/confirmation-dialogs.md)
- [Pi 协议与进程监督](docs/reports/pi-rpc-compatibility/SUPERVISION.md) · [运行时集成](docs/reports/runtime-integration/REPORT.md) · [工作台恢复](docs/reports/workspace-recovery/REPORT.md)
- [原生交互](docs/reports/interaction-performance/REPORT.md) · [性能验收](docs/reports/interaction-performance/PERFORMANCE.md) · [领域投影基线](docs/reports/runtime-integration/PERFORMANCE.md)
