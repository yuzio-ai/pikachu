# Pikachu

原生 macOS Coding Agent 工作台。Phase 1 / M3 功能与冻结性能指标均已通过验收。 [M3 原生复验](docs/m3/NATIVE-PIXELS.md)

## 本地运行

要求 macOS 27、Xcode 27 / Swift 6、Python 3，以及已配置认证的 Pi **1.5.2** 和 Node。当前仅验证本机 arm64 环境。

```sh
python3 Scripts/build-app.py --open
```

`--open` 在构建和签名校验通过后，用 `/usr/bin/open` 打开输出的 `.app`。省略该选项时只构建，也可以随后在 Finder 双击应用包。从 Codex 直接执行 `Contents/MacOS/Pikachu` 会让进程继承命令沙盒，导致 AppKit 注册时以 `SIGABRT` 中止。若 Codex 的命令环境无法调用 `/usr/bin/open`，请在 macOS 终端运行上面的命令。

打开后，点击「打开项目…」，选择或新建会话。发送草稿时自动连接并开始任务。构建脚本生成 debug App，并对 App 和内置独立监督进程做 ad-hoc 签名，供本地运行。

App 自动发现 Pi、Node 和系统代理，连接前可在“连接设置”调整。认证复用 `~/.pi/agent`；没有新增密钥管理。运行时可以修改项目和执行命令，请先确认工作目录。

输入栏提供文件路径引用、执行模式、权限摘要、模型与推理强度、上下文用量与明细入口，以及发送。新会话默认使用「交互」，写入、编辑和命令执行前逐次确认。「计划」只开放读取和搜索，「自动」使用现有工具和已选第三方扩展。已有和导入会话默认使用「自动」。

支持流式聊天、基础 Markdown / 代码块、工具展开、消息发送时间与复制/编辑、轮次署名与执行耗时、补充与后续输入、停止和草稿恢复。长历史使用 AppKit 可见行复用，保留原生文本选择与代码复制。⌘ Return 发送，⌘ . 停止。停止不会撤销已完成的文件操作。

支持多项目、独立会话草稿、只读历史和重启恢复。打开模型选择器时加载可用模型。执行会话空闲时立即应用模型配置，其余会话保存并在下次发送时应用。会话顶栏展示连接状态、项目与会话身份、Git 分支/领先提交/变更文件摘要及当前会话的停止与连接操作。查看其他会话时当前任务继续运行，顶部按需显示运行横幅以返回执行会话或停止它；跨会话执行时可明确停止旧任务并发送。

工作台的项目索引、草稿、配置与发送状态保存在 `~/Library/Application Support/Pikachu/Workspace/workspace.store`（SwiftData）。普通编辑约 250 ms 合并保存；发送前必须完成提交状态持久化，退出前显式保存。尚未保存的编辑不承诺在强制退出后恢复。

对话真实来源仍是 Pi JSONL。新会话保存在 `~/Library/Application Support/Pikachu/Sessions/<projectID>/`；同时发现标准 `~/.pi/agent/sessions/` 和原 M1 会话目录。打开项目和“刷新”用于发现历史，重新选择会话会读取源文件。读取不启动 Pi。未知格式、损坏、缺失或尾部未写完均明确提示；已确认的历史不会静默变成空会话。

目录移动后用“重新定位项目…”更新原项目路径，保留稳定项目和会话标识。Pi 1.5.2 RPC 无法覆盖旧历史中的工作目录，因此旧会话只读，不能在新位置直接续跑；可在新位置新建会话，原历史不改写。

重启不恢复推理、不重放旧队列、不自动重发任务。结果未确认的提交保留关联标识，并要求用户核对。M3 增加累计 Token / 估算费用、独立上下文占用、原生扩展弹窗与快捷键；未知费用明确显示不可用。原生性能的完成边界见报告。

M3 快捷键还包括 ⌘L 聚焦输入、⇧⌘R 返回执行会话、⇧⌘M 模型设置、⇧⌘U 用量、⇧⌘I 处理交互请求。可信扩展可在「连接设置」明确添加，由自动模式加载。

Release 构建：

```sh
python3 Scripts/build-app.py --configuration release --output dist/Release/Pikachu.app --open
```

## 验证

```sh
swift test --disable-sandbox
.build/debug/m1-verify
.build/debug/m1-verify --real
.build/debug/m1-verify --baseline
.build/debug/m2-verify
.build/debug/m2-verify --real
.build/release/m3-verify
python3 Tools/M3Verification/Fixtures/execution-policy.py --wait-for-timeout
```

M1 默认集成检查使用合成协议进程；M2 默认还验证本机 Pi 的无推理恢复与合成故障。`--real` 额外使用现有 Pi 认证和模型，在临时目录中执行真实编码任务，会产生模型调用费用。M3 默认验证真实 Pi 的扩展命令与合成大输出，不调用模型。结果分别写入忽略目录 `.m1-runs/`、`.m2-runs/`、`.m3-runs/`。基线只测领域状态投影，不测原生显示延迟。

开发者可用 `--fake` 参数替换执行后端；同一界面和协调器无需修改。`--state-dir` 可指定隔离的工作台存储，`--sessions` 指定会话目录。其余诊断参数见 [AppSettings](PikachuApp/AppSettings.swift)。不要将 Pi 凭据复制到项目或诊断文件中。

侧栏按 Open 和 Settled 组织会话。点击「已处理」后移入 Settled，右键可移回 Open。顶部可搜索和筛选项目，左下角刷新本地会话，底栏右侧的账户额度入口在当前版本显示额度不可用。

## 文档

- [产品与架构设计](DESIGN.md)
- [侧边栏会话、提醒及账户额度](docs/design/sidebar-session-groups-v2.md)
- [M1 交付及验收报告](docs/m1/REPORT.md)
- [M2 交付及验收报告](docs/m2/REPORT.md)
- [M3 实现与验收边界](docs/m3/REPORT.md)
- [M3 原生性能验收](docs/m3/PERFORMANCE.md)
- [基线与性能目标](docs/m1/PERFORMANCE.md)
- [M0 监督策略及边界](docs/m0/SUPERVISION.md)
