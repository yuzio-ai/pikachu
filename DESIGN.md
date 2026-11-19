# Pikachu — Design Specification

> Lightning-fast. Native by design.

- **文档版本**：v0.9 Draft
- **日期**：2026-11-18
- **目标产品版本**：Phase 1 为 v0.1 MVP；后续阶段尚未分配产品版本号
- **平台**：macOS 优先，未来按需跨平台
- **当前技术栈**：Swift 6、SwiftUI、AppKit、Swift Concurrency
- **首期引擎**：Pi Coding Agent（直接使用本地 RPC，过渡方案）
- **Phase 1 形态**：开发者自用、单窗口多项目、全局单任务执行
- **长期方向**：ACP 优先的多 Runtime 接入、自研 Rust Mini Agent Loop、Pikachu 自主管理 Subagent
- **当前状态**：Phase 1 的 M0–M3 已验收。M3 最终构建通过用量、扩展交互、快捷键和冻结性能指标。 [M3 原生复验](docs/m3/NATIVE-PIXELS.md)

本文中的产品行为和架构约束是设计约定。M0 实测结果和适用边界见 [M0 监督收口报告](docs/m0/SUPERVISION.md)，首轮失败保留于 [历史报告](docs/m0/REPORT.md)。M1 范围见 [原生交互报告](docs/m1/REPORT.md)，M2 范围与兼容限制见 [会话恢复报告](docs/m2/REPORT.md)。M3 实现与证据边界见 [工作台完善报告](docs/m3/REPORT.md) 和 [性能验收](docs/m3/PERFORMANCE.md)；后续阶段设计不代表当前已实现。文档核对和领域基线不等于完整原生性能或兼容性验收。

## 1. 产品定义

**Pikachu 是一款为 AI Coding Agent 打造的轻量、快速、原生 macOS Workbench。**

核心价值是让用户看清任务过程、控制任务运行、检查任务结果。产品能力覆盖多 Agent Runtime 接入与切换、Session 管理与持久化、流式聊天与工具可视化、模型和 Token / Cost 信息，以及 Subagent 委派、并发和生命周期管理；按第 9 节分阶段交付。

**核心原则：Pikachu owns orchestration. Runtime owns execution.**

Pikachu 负责项目、会话、Agent 组织、任务编排、交互和结果汇总；Agent Runtime 负责独立 Session 内的模型推理循环和工具执行。

Phase 1 通过本地 `pi --mode rpc` 交付单任务工作台。Phase 2 沿用 Pi RPC，先在真实任务中验证 Pikachu 自有的 Subagent 委派、进度查看、取消和结果回传。Phase 3 引入独立的 Rust Mini Agent Loop 和 Swift ACP 客户端，用第二个真实 Runtime 复验工作台与编排边界。MVP 提供对话和工具结果检查，只读改动预览随后补齐代码检查体验。

### 产品原则

1. **Native first**：以 SwiftUI 为主，必要时用 AppKit 补足原生能力，不采用 WebView 封装方案。
2. **Runtime agnostic / Protocol first**：UI 和业务状态不依赖具体 Agent；通过统一接口与适配层隔离协议差异。
3. **Fast & focused**：快速启动、低交互延迟、信息密度适中，并通过固定环境下的测量验收。
4. **Local by default**：默认操作本地项目和本地 Agent 进程，不自建云端中转；模型请求仍由 Runtime 发往所配置的 Provider。
5. **Observe before automate**：执行过程透明，明确区分 UI 确认与真实执行权限控制。
6. **Recover without repeating**：异常恢复优先还原可确认状态，不自动重复可能已经执行的任务。
7. **Minimal core**：自研 Agent Loop 只承担执行所需的最小职责，不内置多 Agent 编排。
8. **Product first**：先验证 macOS 产品，不为未来跨平台提前迁移 GPUI。

Runtime 隔离的目标是尽量复用 UI 和业务流程，不承诺未来接入任意 Runtime 都只需修改 Adapter。会话分支、权限和任务语义的差异可能需要调整领域模型与特定界面。

## 2. 用户与核心场景

**目标用户**：习惯桌面 GUI、希望使用轻量 Coding Agent 的 macOS 开发者。首版先满足开发者自用，不以公开分发为前提。

核心工作流：

1. 选择本地代码仓库，检查 Pi 连接和版本兼容状态。
2. 创建或恢复会话，选择 Pi 已配置的 Provider、Model 和 Thinking Level。
3. 发送任务，查看流式输出、工具执行、等待输入、重试和错误状态。
4. 必要时补充当前任务、安排后续消息或停止；明确知道队列是否仍会继续执行。
5. 运行期间查看其他会话历史，返回执行会话继续跟进。
6. 结束后检查回复和工具结果；未来通过只读改动预览检查代码变化。
7. 重启 App 后恢复历史和草稿；对异常中断或发送结果不明的任务，由用户决定下一步。

Phase 2 允许 Main Agent 委派独立的 Pi Child Session。用户可查看任务树和进度、停止指定任务，并检查回传结果。不同 Child Session 可选择 Pi 支持的模型。Phase 3 增加 ACP Runtime 的选择与切换，并验证使用不同 Runtime 和模型的 Child Session。

## 3. 阶段范围与 MVP（Phase 1 / 产品 v0.1）

| 优先级 | 功能 | 交付标准 |
|---|---|---|
| P0 | 项目管理 | 打开本地文件夹、最近项目、稳定项目标识及可更新路径 |
| P0 | Pi 连接 | 自动发现及手动选择可执行文件；启动、版本兼容和异常状态可见 |
| P0 | 对话 | 多行文本发送、流式输出、Markdown 和代码块渲染 |
| P0 | 工具事件 | 展示工具名称、参数摘要、执行状态及可展开结果 |
| P0 | 会话 | 新建、恢复、浏览和执行切换；重启后已持久化历史仍可读取 |
| P0 | 模型与思考级别 | 从 Pi 查询模型及选项；不写死模型列表 |
| P0 | 运行控制 | 补充与后续消息语义明确；停止、清队列、超时和异常恢复一致 |
| P0 | Extension UI 最低兼容 | 识别需要回复的请求；未实现的已知交互明确提示并返回取消 |
| P1 | 用量统计 | 会话 Token、估算费用、上下文占用；缺失数据不显示为零 |
| P1 | 完整 Extension UI | 为 `select`、`confirm`、`input`、`editor` 提供原生交互 |
| P1 | 快捷键与体验 | 新建会话、聚焦输入框、停止响应、明暗模式和辅助功能完善 |

**Phase 1 不做**：自研 Agent Loop、ACP 客户端、自研模型路由、Git Worktree 并行、Subagent 编排、只读改动预览、完整 Git Diff 编辑器、内置 API Key 管理、云同步、强制执行审批策略、多窗口任务执行。Subagent 编排属于 Phase 2，Mini Agent 与 ACP 属于 Phase 3。

**当前三阶段路线不纳入**：GPUI / Windows / Linux 客户端、Swift ↔ Rust FFI、Pi Subagent Extension、复杂多 Agent Framework、Agent Loop 内置编排，以及复杂 Memory、Planning 和高级工作流系统。按需评估的跨平台迁移不构成本轮交付承诺。

**MVP 后首个产品体验增强**：只读改动预览；其排期不作为 Phase 2、Phase 3 的前置条件。展示仓库工作区变化时，必须区分运行前已有改动与可归属本次任务的改动。仅有当前 Git Diff 时，不得将全部变化标为 Agent 产出；并发人工修改或其他工具修改导致归属不明时，应明确标注。此阶段不提供编辑、暂存、回滚或自动提交。

## 4. 信息架构与交互

4.1–4.3 定义 Phase 1 的单任务交互。4.4–4.5 的恢复和视觉原则跨阶段适用。Phase 2 在 4.6 扩展多任务交互，执行额度由 Pikachu 调度策略决定。

### 4.1 主界面

Phase 2 前的工作台优化已完成设计确认。分区名称、布局调整与验收标准见 [工作台分区命名与界面优化](docs/design/workbench-ui-refresh.md)。

```text
┌─────────────────────────────────────────────────────────────────┐
│ Pikachu       正在查看：Project / Session                 ⚙     │
├─────────────────┬───────────────────────────────────────────────┤
│ + New Session   │ 当前查看会话的模型 / 思考级别                  │
│                 │                                               │
│ PROJECTS        │ User message                                  │
│ • Mewoo         │                                               │
│   • Health UI ▶ │ Assistant response                            │
│   • Fix tests   │                                               │
│ • Cohestra      │ ▸ Tool: read — Completed                      │
│                 │ ▸ Tool: bash — Running                        │
│                 │                                               │
│                 │ ┌───────────────────────────────────────────┐ │
│                 │ │ 当前查看会话的输入 / 草稿                 │ │
│                 │ └───────────────────────────────────────────┘ │
├─────────────────┴───────────────────────────────────────────────┤
│ 正在执行：Mewoo / Health UI · 工具执行中 · 返回会话 · 停止       │
└─────────────────────────────────────────────────────────────────┘
```

- **左侧栏**：搜索会话标题或项目名称，也可按所属项目筛选。Open 与 Settled 独立折叠，按最近活动排序，收起时保留组内符合筛选的选中会话。用户标记已处理时移入 Settled。后台运行标记跟随实际执行会话。底部提供设置、当前会话统计、历史刷新和独立的账户额度入口。见[侧栏设计](docs/design/sidebar-session-groups-v2.md)。
- **中央区域**：展示当前查看会话；工具默认摘要，展开查看结果。历史中的运行标记不能冒充当前实时状态。
- **会话工作区顶栏与运行反馈**：顶栏展示当前查看会话的连接状态图标、「项目 / 会话」身份、只读异步 Git 摘要（分支、领先本地 upstream 提交数、文件增删变化）及本会话的执行/连接操作；查看其他会话或无选中会话时，顶部按需出现执行横幅以返回执行会话或停止运行，移除常驻底部状态条。见[右侧会话工作区 v5](docs/design/session-detail-ui-v5.md)。
- **输入区域**：始终绑定当前查看会话，支持多行输入、附件、模式、权限摘要、模型与上下文进度/明细入口；不能将历史会话中的输入悄悄发给正在执行的会话。
- **次级信息**：模型、Token、估算费用和上下文占用归属于具体会话；查看其他历史时不混用执行会话的数据。
- **错误**：区分 Pi 不存在、运行依赖缺失、启动失败、版本不兼容、认证失败、模型错误、工具错误、协议错误和进程退出。
- **键盘和辅助功能**：遵循 macOS 焦点与键盘习惯；为状态变化、工具结果和运行控制提供 VoiceOver 标签。

### 4.2 查看会话与执行会话

**查看会话**决定中央内容和输入草稿；Phase 1 的**执行会话**占用全局唯一执行槽位。两者可以不同；槽位数量由 Pikachu 编排策略控制，不固化在 `AgentRuntime` 接口中。

| 操作 | 首版行为 |
|---|---|
| 点击其他会话或项目 | 只读取历史和草稿；当前任务继续，不重建进程 |
| 新建会话 | 先创建本地待初始化条目；首次执行时创建 Runtime 会话 |
| 返回执行会话 | 恢复实时视图及该会话草稿，不重新发送任务 |
| 在其他会话发送任务 | 当前槽位忙时不发送；默认保留草稿，提供“返回当前任务”或明确的“停止当前任务并发送”操作 |
| 确认停止当前任务并发送 | 完成停止流程并确认旧执行实例不再运行后，初始化目标会话并发送；停止失败则保持草稿，不启动新任务 |
| 当前任务自然结束 | 释放执行槽位；不自动发送其他会话草稿，也不强制切换正在查看的会话 |
| 修改模型或推理强度 | 打开模型设置时查询可用选项。已连接的空闲会话立即应用，其余会话保存为下次发送时应用 |
| 退出 App | 有运行任务时提供取消退出或停止后退出；扩展弹窗中的 ⌘Q / 退出菜单先取消该请求并关闭弹窗，再进入退出确认；取消退出不重发扩展请求 |

首版不建立跨会话任务队列。用户选择等待当前任务完成时，目标会话内容保持为草稿，之后由用户再次发送。

### 4.3 运行中输入与停止

- 空闲时发送会启动任务。运行中默认选择**补充当前任务**，对应 Pi 的 `steer` 语义；另提供**完成后执行**，对应 `followUp` 语义。控件必须明确显示当前模式。
- 补充指令在 Runtime 允许的边界生效，不承诺立即打断正在执行的工具。
- 输入区区分待确认发送、已接受、排队、已交付、拒绝和结果不明。成功响应不等于任务完成，队列状态以 Runtime 事件或可确认快照为准。
- 点击停止后进入“正在停止”，暂停向该执行实例发送新消息；串行发送 `clear_queue`，保存返回内容，再调用 `abort`。停止不代表撤销已经完成的文件或 shell 操作。
- 清出的消息按类型和原有顺序保存到原会话的**待发送草稿列表**，保留与当前编辑草稿的区别。不得覆盖已有输入、自动重新入队或重复保存同一批返回内容。
- 若清队列失败、请求超时或连接断开，不宣称已清空。保留本地已知待发送内容并标记执行状态待核实；用户可选择终止受控进程，确认其退出后才能启动其他会话。
- 停止完成需由 Runtime 的终止状态确认；连接消失本身不等于任务成功停止。终止进程时也须处理所拥有的工具子进程，无法确认终止的执行应明确显示。

### 4.4 异常恢复

恢复首先通过对应 Runtime 的历史读取接口恢复已持久化历史（Phase 1–2 使用 Pi 历史），再核对当前连接、会话和消息状态。进程崩溃或 App 重启后，不自动恢复推理，不自动重发 Prompt，也不自动执行旧队列。

发送时保存本地关联标识和提交状态。若请求写出后未收到可确认结果，显示“发送结果不明”；只有 Runtime 历史或明确回执能消除不确定性，不能仅靠相同文本判断已经执行。需要重试时由用户明确操作，并提示可能重复执行。

崩溃前的未完成工具记录显示为中断或结果未知，不伪造成功结果。已确认保存的历史、编辑草稿和清队列返回内容可恢复；未收到或未持久化的数据不承诺无损恢复。

### 4.5 视觉方向

- 使用 macOS 原生侧边栏与分栏布局，不模拟终端。
- Light/Dark 自适应，使用系统字体、SF Symbols 和系统材质。
- 品牌强调色可选低饱和闪电黄；大面积界面保持克制。
- 不使用宝可梦角色造型或相关官方视觉资产；公开发布前复核名称和商标风险。

### 4.6 Subagent 任务交互（Phase 2 起）

- 通过任务树展示 Parent / Child 关系；每个任务标明 Session、Runtime、模型、执行状态和结果入口。Phase 2 的执行后端为 Pi。选择 Child Session 只改变查看对象，不中断其他任务。
- 运行区域由单任务栏扩展为任务概览；停止操作明确区分当前 Child 与整棵任务树，不能默认停止无关任务。取消传播和结果回传遵循 5.3 的编排约定。
- 等待输入及后端提供的审批请求始终归属原任务和执行实例。父任务等待 Child 时仍可查看进展；部分 Child 失败、取消或结果不明须分别呈现，不以父任务一次回复掩盖状态。
- 退出 App 时检查所有活跃任务；停止后退出须确认相关执行实例及其工具进程已结束。不能沿用 Phase 1 的单会话检查遗漏 Child。

## 5. 技术架构

### 技术路线

| 层级 | 当前方案 | 长期方向 |
|---|---|---|
| 平台 | macOS | macOS 优先，按需扩展 Windows / Linux |
| UI | SwiftUI + AppKit | 跨平台需求成立后评估 GPUI |
| 编排层 | Pikachu / Swift，独立于视图 | 保持独立，未来可迁移 Rust |
| Agent 通信 | Phase 1–2 直接 Pi RPC，Phase 3 引入 ACP | ACP 优先，按能力接入 Agent |
| Agent Runtime | Phase 1–2 使用 Pi，Phase 3 增加 Rust Mini Agent | 逐步验证并替换过渡后端 |
| Subagent | Phase 2 由 Pikachu 编排 Pi 子会话 | Phase 3 验证跨 Runtime 编排 |

下图展示目标边界，不代表所有模块都在 Phase 1 实现：

```text
Pikachu macOS App (SwiftUI / AppKit)
  └─ Features (Projects / Sessions / Chat / Settings)
      └─ AppState + ViewModels (MainActor)
          ├─ 查看会话 / 草稿 / 交互呈现
          └─ Pikachu Orchestration Core（Swift，独立于 UI）
              ├─ Session / Task / 父子关系 / 调度 / 取消 / 结果回传
              ├─ AgentRuntime 接口（Pikachu 自有模型与事件）
              │   ├─ PiRuntimeAdapter → Pi RPC / stdio → 独立 Pi 进程
              │   ├─ ACPRuntimeAdapter → ACP → Rust Mini Agent 进程
              │   │                           或其他兼容 Agent
              │   └─ FakeRuntime（测试）
              └─ Runtime 历史读取接口
                  ├─ PiHistoryReader（只读 session JSONL）
                  └─ 其他后端的历史或恢复适配
```

### 5.1 边界与状态所有权

1. `Features/` 不得引用 Pi RPC、ACP 的原始类型或直接解析后端会话文件。
2. `Packages/AgentRuntimeCore/` 定义与 UI 无关的 Session、Message、ToolCall、Event、Capability 和错误类型；Task 与父子关系由编排核心定义。
3. 各 Runtime Adapter 负责进程、协议、历史格式及领域映射。后端专有 metadata 可选保留，但不能成为基础 UI 的前提。
4. App 层持有查看会话与草稿呈现；Pikachu 编排核心持有任务关系、调度及执行实例生命周期，Runtime 提供执行事实。不能依靠多个 ViewModel 各自推测运行状态。
5. 连接状态、执行状态和队列分别建模；等待输入、重试、压缩和停止都有可见状态。连接断开时保留最后已知状态并标明过期。
6. `RuntimeCapability` 允许不同 Runtime 有不同能力；模型切换后更新相关能力，不要求所有 Runtime 功能相同。
7. 协议接收与解码不依赖界面刷新速度；UI 更新可合并，但不能丢失影响状态的事件。
8. Pi RPC 和 ACP 是通信适配，不是编排层。Runtime 只执行独立 Session；父子任务、并发额度和结果汇总由 Pikachu 决定。

| 状态维度 | 必须表达的情况 |
|---|---|
| 连接 | 未连接、启动中、就绪、关闭中、失败 |
| 执行 | 空闲、运行、等待输入、重试、压缩、停止中、中断或结果未知 |
| 队列 | 补充消息与后续消息各自的已知条目、确认状态和快照是否有效 |
| 运行结果 | 正常结束、用户停止、失败、无法确认；“已停止自动继续”不等于需求验收通过 |

### 5.2 接口草案

通过统一的 `AgentRuntime` 接口创建、恢复和关闭 Session，发送 Prompt、接收执行事件并取消任务。以下是职责约定，不是最终可编译 API；使用 Pikachu 自有类型，不直接复刻 Pi 或 ACP 命令。

| 接口职责 | 输入与输出约定 |
|---|---|
| 能力与兼容信息 | 返回 Runtime 标识、检测到的版本、能力集合及验证状态 |
| 打开执行会话 | 输入项目位置和新建或恢复描述；返回已确认的会话标识与状态快照 |
| 读取状态快照 | 返回连接、执行、模型配置和可确认队列；无法确认的字段显式为未知 |
| 发送消息 | 输入内容、本地关联标识和发送模式；返回接受、排队、处理或拒绝结果，不作为完成信号 |
| 停止运行 | 表达停止并保留待发送内容的业务语义；Pi Adapter 组合清队列和中断命令，返回清出内容及确认状态 |
| 查询和应用配置 | 按后端能力查询模型及思考级别；空闲时应用，返回最终有效配置 |
| 用量与费用 | 按后端能力返回 Token、Cost 和上下文信息；缺失或估算值明确标记 |
| 回复交互请求 | 按请求标识提交选择、文本、确认或取消；过期请求不再次提交 |
| 订阅事件 | 提供带执行实例来源的有序领域事件流；异常结束与正常关闭可区分 |
| 关闭执行实例 | 结束事件流并完成或取消所有未决请求；不得留下永久等待的调用 |
| 历史列表与读取 | 按后端能力读取会话索引和可展示历史；不占用任务执行额度、不触发模型调用；不支持的能力显式标明 |

Pi 的运行中补充、队列和 settled 语义不直接当作所有后端的共同能力。Adapter 负责转换；不支持的交互禁用并解释，不能伪装为已经提交。`delegate_task` 属于 Pikachu 编排能力，通过适配入口暴露给 Agent，不是 `AgentRuntime` 内置的多 Agent 调度方法。

每次启动或重新绑定执行会话都生成新的执行实例标识。事件、请求响应和交互回复须与项目、Session、Task（有任务记录时）及执行实例绑定；旧实例的迟到内容不能污染新会话或其他 Child。后端事件缺少全局标识时，由 Adapter 在接收边界补充来源信息。

Fake Runtime 必须覆盖流式输出、工具事件、队列、等待输入、停止和连接失败。替换为 Fake Runtime 后，主 UI 的通用行为测试无需修改。Phase 2 用 Fake Runtime 和真实 Pi 验证多实例编排，Phase 3 用 Mini Agent 验证第二个真实后端。

### 5.3 基于 Pi 的 Subagent 编排（Phase 2）

**Subagent = Independent Session + Delegated Task + Parent-Child Relationship。**

| Pikachu 负责 | Agent Runtime 负责 |
|---|---|
| 创建和管理 Child Session，维护父子任务关系 | 执行被分配到独立 Session 的任务 |
| 并发调度、状态跟踪和生命周期管理 | 模型推理、工具调用与单次执行的终止 |
| 取消传播、结果汇总及向 Parent Agent 回传 | 返回结构化执行事件、结果及错误 |

Main Agent 通过 Pikachu 提供的 `delegate_task` 能力主动委派。最小流程为：接收委派请求 → 持久化父子关系与任务描述 → 分配 Child Session、Runtime 和模型 → 调度执行 → 汇总终态与结果 → 按原委派关联回传 Parent。Child 默认只接收明确委派内容及所需上下文，不自动复制整段父会话。

Phase 2 先验证一个真实 Pi Main Agent 和一个 Pi Child 的委派闭环。Pi 适配入口使用自定义工具将委派请求交给 Pikachu，并把结果返回原工具调用。工具注册、等待期间的取消以及父会话收到结果后能否继续，均须在选定 Pi 版本的 RPC 模式下实测。闭环通过后再扩展任务树和有界并发。 [Pi 自定义工具](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md)

- 每个 Child 有独立的 Session、Task 和执行实例标识。Phase 2 为每个并发 Agent 分配独立受监督的 Pi RPC 进程，并按 Pi 能力选择模型。Phase 3 再引入多 Runtime 组合。
- 并发额度与工作目录冲突检查由 Pikachu 执行。对未隔离的同一项目写任务采用保守串行调度；后续可引入 Git Worktree 隔离，再开放相应并发写入。任务看似只读不等于具备强制只读能力。
- 取消单个 Child 不影响无关任务；取消整棵任务树由 Pikachu 向相关执行实例传播，并分别等待终态。父任务停止后的迟到结果可以记录，但不能自动重新启动父任务。
- 成功、失败、取消与结果未知分别汇总。回传使用委派关联标识，避免重复结果触发重复继续；Parent 不可用时保留待回传状态，不丢弃结果或静默重发任务。
- `delegate_task` 是 Pikachu 的产品级能力。工具注册和结果交付由各后端的适配入口完成。Phase 3 按 6.6 验证 ACP 后端的委派通路。缺少该通路的 Agent 仍可作为独立执行后端，主 Agent 委派入口按能力开放。
- 不使用 Pi Subagent Extension，也不将 Pikachu 的任务树委托给 Runtime 内置 Subagent。若某后端自行执行内部子任务，其展示数据不能自动当作 Pikachu 可调度的 Child。

### 5.4 Rust Mini Agent Loop（Phase 3）

使用 Rust 独立实现，不依赖 Pi 或 TypeScript。Runtime 作为独立进程运行，原生提供 ACP 接口；Swift 客户端通过 ACP 通信，暂不使用 Swift ↔ Rust FFI。

| 最小模块 | 职责 |
|---|---|
| AgentLoop | 模型推理、工具调用循环及终止条件 |
| ModelProvider | 模型 API 与 Streaming |
| ToolRegistry | 工具注册、执行及执行前审批检查 |
| ContextManager | 当前对话上下文管理 |
| Session | 会话状态、持久化与恢复 |
| EventStream | 结构化执行事件，供 ACP 适配输出 |

初期工具限定为 `read`、`write`、`edit`、`bash`、`grep`、`glob`。基础取消、超时、错误处理和工具执行审批是 Phase 3 必须交付的执行能力，不属于后续可选增强。

审批由 Runtime 在工具执行路径上强制检查，通过 ACP 与 Pikachu 交互。拒绝、取消或失效后不得继续执行相关操作；仅显示弹窗不算完成审批实现。基础审批不等于已经提供操作系统沙箱。

Mini Agent Loop 负责独立会话的执行。它通过适配入口使用 Phase 2 定义的委派能力，任务创建、调度和结果汇总仍由 Pikachu 完成。Phase 3 复跑已验证的产品场景，检验 Mini Agent 能否在现有工作台和任务树中运行，并保留 Pi 会话的原始历史来源。

### 5.5 UI 与跨平台策略

当前保留 SwiftUI + AppKit，优先完成 macOS 产品验证。只有 Windows / Linux 需求明确后才评估 GPUI，不提前迁移 UI，也不引入 WebView 封装。

Session、Task、Event 模型和协议数据格式独立于 SwiftUI；Agent 通信与业务逻辑不放在 View 内。Swift 编排层通过明确接口独立组织，未来可迁移 Rust，但本轮不重写。

未来 GPUI 客户端可以复用 Rust Runtime、ACP 协议及中立数据格式；SwiftUI 视图和部分 Swift 编排代码仍需迁移或重写。不能将这些边界描述为 UI 或业务代码可直接跨平台复用的保证。

## 6. Runtime 通信与集成

6.1–6.5 定义 Pi 原生 RPC 的接入约定，6.6 定义 Phase 3 的 ACP 接入边界。Phase 1–2 使用上游 Pi 和直接 RPC，委派工具作为扩展接入。两条路径都实现统一 Runtime 接口。

### 6.1 启动与进程管理

- 使用 Swift 的 `Foundation.Process` 启动受管的本地 `pi --mode rpc`。Phase 1 最多保留一个 Pi 执行实例。Phase 2 由 Pikachu 按额度分配多个独立实例，每个实例沿用独立监督、身份核对和有界清理。清理未确认时，该实例继续占用额度并保留关联写入限制。监督进程不占任务执行槽位，只读历史浏览不创建执行实例。
- 执行项目通过 `Process.currentDirectoryURL` 指定工作目录，不假定 RPC 能动态切换 CWD。Phase 1 更换唯一执行目标时，在旧实例安全关闭后重建进程。Phase 2 为各任务绑定工作目录，按调度规则同时持有实例。
- 同项目空闲时可通过会话命令切换；必须先完成未决请求和事件来源的隔离。若无法可靠确定边界，重建进程。浏览历史不触发上述切换。
- M2 采用每次变更执行目标都重建受管进程的保守策略；新进程使用 `switch_session` 恢复目标，并核对取消结果、Runtime 会话 ID 和文件位置。Pi 1.5.2 的恢复会重建历史 CWD 的运行时服务，不支持覆盖 CWD；历史 CWD 与项目当前位置不符时禁止续跑，只读浏览与新位置新建会话仍可用。
- GUI 的 `PATH` 可能不同于 Terminal；支持自动发现与手动选择 Pi。探测启动所需依赖及环境，不只检查文件是否存在；不把用户路径拼接为 shell 命令。
- stdout 用于 JSONL 协议，stderr 单独接收诊断。连续读取两条流，避免工具输出过大阻塞进程。
- M3 生产接收使用有界读取与缓冲，响应单独匹配；仅合并相邻展示增量，控制事件保序并以反压限制积压。写入和关闭串行化，生产管道使用 FD 级 SIGPIPE 防护，将对端关闭转成错误。未知结果不自动重发。M0 探针保留默认模式，生产模式独立验证；监督所有权与信号升级算法不变。
- 记录仅按 LF（`\n`）切分，并处理 UTF-8 分包；不能将 Unicode 行分隔符视为协议换行。
- 每条命令使用唯一 `id` 关联响应；允许请求响应和事件交错，不按响应顺序匹配。
- 为请求、启动和关闭设置有界等待。超时意味着结果未确认，不意味着服务端没有执行；状态修改命令不自动重试。
- 未知可选事件可降级处理并记录脱敏诊断；破坏必要状态同步的格式错误应进入显式协议失败，不得静默继续显示正常状态。
- 正常关闭前先处理运行中的任务和未决交互，再关闭 stdin 并有界等待退出；异常时执行受控终止。子进程终止行为属于 M0/M1 实测项，不能仅以 Pi 主进程退出推断所有工具都已停止。

**M0 已验证的监督策略**：Pi 1.5.2 的 Bash 可脱离 Pi 进程组，因此增加独立宿主监督进程。它按每实例继承标记、已观测谱系及 PID/启动时间记录所有权，在 Pi 或 RPC 宿主退出后清理所属进程；必要时从 SIGTERM 升级到 SIGKILL。只有监督明确报告受管边界 clean 才允许释放槽位。枚举、身份核对或监督终态无法确认时阻止新命令和槽位释放；clean 不代表任务成功。

原六个异常退出失败案例已在该策略下复验通过，夹具 PID 未参与清理决策。适用范围是同用户可检查、继承标记或已登记谱系的进程；不是操作系统沙箱，不保证主动去标记并立即脱离所有谱系、跨用户提权或宿主与监督同时被强制杀死的进程清理。M1 已通过源码共享保留此策略，并验证内置 helper 的 ad-hoc GUI 构建和受控退出。M3 在隔离原生夹具中观察到测试宿主强退后监督器完成清理；该场景不扩大上述保证。App Sandbox 和公证分发仍未验证。

### 6.2 版本兼容

M0 固定验证版本，记录 Pi 版本、发行物指纹或对应源码 tag/commit、启动环境及通过的协议场景。**当前记录：Pi 1.5.2 在本机配置与上述受管执行边界内通过 M0 复验。** 发行物、监督实现、两个可执行文件的指纹和分场景证据见 M0 监督收口报告；不能扩大为全部扩展、模型或其他环境的兼容保证，也不将可变的 `main` 文档视为已安装版本的行为依据。

启动时检测版本并对照兼容记录。未知版本明确显示“未验证”，默认不发送任务；用户可明确选择试用，但仍须检查必要能力。缺少停止、必要生命周期或会话恢复能力时阻止执行；可选统计或展示能力缺失时隐藏相关功能并说明原因。兼容检查只使用版本信息和无副作用查询，不发送探测 Prompt。

不假定 Pi 提供统一能力协商接口。Adapter 可结合已验证版本映射与查询结果生成能力集合；每次 Pi 升级都重新执行相关协议验收。

### 6.3 命令映射

| 目的 | Pi RPC Command / 字段 |
|---|---|
| 空闲时发送任务 | `prompt` |
| 运行中补充 / 后续执行 | `prompt` 的 `streamingBehavior: steer / followUp` |
| 读取状态 / 当前消息 | `get_state` / `get_messages` |
| 创建 / 恢复执行会话 | `new_session` / `switch_session` |
| 会话命名 | `set_session_name` |
| 模型列表 / 切换 | `get_available_models` / `set_model` |
| 思考级别 | `get_available_thinking_levels` / `set_thinking_level` |
| 统计 | `get_session_stats` |
| 清队列 / 停止 | `clear_queue`，随后 `abort` |
| 扩展交互回复 | `extension_ui_response` |

`prompt` 成功只表示已接受、排队或被处理。若版本提供更细的 disposition，则映射到领域状态；没有该字段时不得自行推断已经执行。任务接受后的失败通过事件和消息呈现。

以 `agent_settled` 判断该次运行不再自动继续，不只看 `agent_end`。同时记录错误和中断原因；settled 不等于任务成功或代码通过验收。会话创建和切换还须检查返回数据中的取消结果，不能只检查 `success`。

### 6.4 事件与状态同步

| Pi Event | Pikachu 领域行为 |
|---|---|
| `agent_start` | 标记运行开始 |
| `message_start` | 建立当前消息及内容块归属 |
| `message_update` | 聚合文本、思考和工具调用增量，按支持能力展示 |
| `message_end` | 以完整消息纠正增量状态 |
| `tool_execution_start / update / end` | 建立、更新和结束工具执行记录 |
| `queue_update` | 更新已确认的待处理队列 |
| 重试、压缩相关事件 | 更新执行阶段，不误报空闲 |
| `agent_settled` | 结束该次自动运行，并结合错误或中断记录确定结果 |
| `extension_ui_request` | 区分待回复交互与无需回复的通知 |
| 进程退出或协议连接结束 | 结束事件流、处理未决请求、标记中断或未知状态 |

流式内容按执行实例、消息和 `contentIndex` 聚合，不能只用 `contentIndex` 跨消息拼接。工具使用执行实例内的 `toolCallId` 关联。状态更新保持接收顺序；启动恢复时先订阅并缓冲事件，再建立快照和增量的应用边界，避免重复或遗漏。

### 6.5 Extensions 与审批

Pi RPC 的部分 Extension UI 可通过 `extension_ui_request` / `extension_ui_response` 桥接到原生界面；`ctx.ui.custom()` 等终端专用能力不适用。需要回复的交互与无需回复的通知不能混为一类。

- **M1 最低兼容**：识别 `select`、`confirm`、`input`、`editor`。未实现时展示原因并回复取消，不能默默丢弃，也不能自动同意。
- **M3 完整交互**：提供原生选择、确认、单行和多行输入；等待状态归属于发起请求的执行会话，查看其他历史时仍有入口返回处理。
- 回复须绑定请求和执行实例，且至多一次。用户关闭、Runtime 超时、停止或断连后关闭本地待处理界面，避免提交过期响应。M3 连续弹窗按请求身份重建编辑状态；确认不设回车默认同意，多行 Return 换行、Command Return 提交。弹窗内提供停止入口。
- Pi 1.5.2 缺少独立过期通知：使用保守本地期限（默认 300 秒，声明超时时提前取消），命令完成也清理遗留请求。此为适配约定，不宣称服务端提供过期事件。
- `set_editor_text` 进入保留草稿；状态、组件文字和标题使用有界文字展示。只加载用户明确选择的可信扩展，自动发现保持关闭。
- 无需回复的通知可降级为状态或提示。遇到无法识别且可能阻塞的协议请求时，明确显示兼容失败并提供停止入口，不伪造成功响应。

Pikachu 提供三种 Pi 执行模式。交互模式的写入、编辑和命令工具在原生确认后才执行。计划模式只提供读取、查找、搜索和列目录。两种模式均关闭第三方扩展和 MCP。自动模式保留原有 Pi 工具和明确选择的扩展，扩展自行发起的确认按其自身行为处理。Phase 3 Mini Agent 的强制工具审批按 5.4 实现。

### 6.6 ACP 接入（Phase 3 起）

ACP（Agent Client Protocol）是未来 Agent 接入的首选通信协议。Pikachu 实现 Swift ACP 客户端，将会话、流式输出、工具状态、取消和权限交互映射到自有领域模型。自研 Mini Agent 原生提供 ACP，不通过 Pi 或 TypeScript 包装。

ACP 使用 JSON-RPC 通信；连接初始化时协商协议版本及双方能力。Session 恢复、模型配置、用量等按实际后端与协议能力启用，不能假定所有兼容 Agent 功能一致。以选定版本的稳定规范为准，不将 RFD 提案直接当成既有兼容能力。[协议概览](https://agentclientprotocol.com/protocol/v1/overview)、[初始化与能力协商](https://agentclientprotocol.com/protocol/v1/initialization)。

| 接入约定 | 产品边界 |
|---|---|
| 创建、恢复和关闭 Session | 区分本地会话引用、Runtime Session 与连接生命周期；恢复能力缺失时明确提示 |
| Prompt 与流式事件 | 按 Session 和执行实例路由，不沿用 Pi 专有事件名作为 ACP 完成条件 |
| 取消与权限交互 | 根据 ACP 和后端语义等待终态；取消发送成功不代表执行已停止，工具审批必须有执行侧约束 |
| 模型、Token 与 Cost | 仅展示后端可提供的数据；缺失不伪造，估算值明确标注 |
| `delegate_task` 通路 | 复用 Phase 2 的委派契约，验证 Mini Agent 暴露工具并将结果回传原调用的方式。兼容 ACP 只说明可按协议通信，是否开放委派取决于该后端的实际能力 |

允许接入 Codex、Gemini CLI 等提供兼容 ACP 接口的 Agent；具体发行版、启动方式和能力须逐一验证，不将候选接入对象写成已完成支持。

Pi RPC 与 ACP Adapter 可并存。替换 Runtime 时保留原会话与历史来源，不承诺不同后端间可直接恢复同一个执行 Session。ACP 协议版本、后端版本和兼容场景分别记录。

## 7. 本地数据与安全

### 7.1 数据所有权与标识

- **会话真实来源**：由对应 Runtime 保存可恢复的执行会话。Pi 保留自身 session JSONL，Mini Agent 由 Session 模块持久化；Pikachu 不直接改写后端历史或维护冲突的第二份执行会话真相。第三方历史能力不足时明确标注。
- **本地存储**：M2 使用 SwiftData 保存项目注册、会话引用、当前查看对象、连接偏好、草稿和最小提交状态。存储层独立于 UI，通过 actor 读写版本化的中立数据快照；当前为一个原子元数据文档，关闭 CloudKit 与自动保存，关键操作显式保存。SwiftData 对象不传入领域或视图层。
- **编排持久化**：从 Phase 2 起，Task、Parent / Child 关系、委派内容、调度状态和结果回传状态由 Pikachu 持有。恢复任务树时读取这些记录。
- **重建边界**：历史索引和展示缓存可从 Runtime 数据重建；稳定项目标识、用户偏好、草稿和发送结果不明记录属于 Pikachu 自有数据，不能声称全部可从 Pi 恢复。
- **项目身份**：创建后使用稳定 `projectID`；路径是可更新位置。目录移动后通过用户重新定位更新原项目记录，不凭同名文件夹自动合并项目。
- **移动后的执行限制**：M2 重新定位保留项目、会话和草稿身份，并按已登记旧位置发现历史。原 Pi 文件不改写。Pi 1.5.2 RPC 无 CWD override，旧会话只读并明确提示，不能静默在旧目录执行；需要在新位置执行时创建新会话。
- **会话身份**：本地会话记录使用稳定标识，绑定 `projectID + runtimeID + runtimeSessionID`；Pi 文件路径作为定位信息，不作全局主键。待初始化会话暂不具有 Runtime 会话标识。
- **任务身份**：Task 使用独立稳定标识，关联 Session、父任务及委派请求；不将一次任务、长期会话和一次进程运行混成同一个标识。
- **草稿与提交状态**：与本地会话绑定，用于恢复用户意图及提交状态，不作为第二份对话历史。保留最小必要信息，确认后的重复内容及时清理。
- **M2 保存边界**：普通编辑采用约 250 ms 合并保存；发送前先持久化本地关联标识和意图，保存失败不发送。清出的草稿尽快保存，停止、切换和退出再显式核对。重启将未决提交标为待核实，不凭相同文本与历史合并。存储不可用时保留内存草稿并阻止新任务，不自动重建数据库；未持久化的数据仍不承诺无损恢复。
- **提交内容边界**：点击发送时固定该次内容和模式；激活及连接等待期间的新编辑作为独立草稿保留，不替换正在提交的内容。

### 7.2 历史读取

统一历史读取接口按后端提供历史或恢复入口；ACP 通信本身不保证可直接访问本地历史文件。Mini Agent 与第三方 Agent 在各自适配层实现或声明缺失能力，查看历史不能触发推理。Pikachu 编排记录的恢复与 Runtime 会话恢复分别进行；恢复父子任务树不自动重启任何任务。

PiHistoryReader 在适配层只读发现和解析 Pi 会话文件，向 UI 提供统一历史模型。读取其他 Pi 会话不启动 Pi、不切换执行 CWD、不触发推理。

必须按选定 Pi 版本的会话结构还原当前有效对话，处理分支、压缩及非消息记录；不能简单把所有 JSONL 记录展平成聊天。当前执行会话以实时事件及 Runtime 快照为准；文件读取用于历史和恢复，不与实时事件无条件拼接。

读取正在写入的文件时只解析完整记录，尾部不完整记录暂缓处理并标明刷新状态。损坏记录、未知格式或缺失文件显式提示，不覆盖源文件，也不展示伪造的空会话。会话发现、分支还原和项目移动后的恢复路径均须在 M0/M2 验证。

M2 支持 Pi v3 的当前分支历史，保留压缩前的可见消息并显示压缩、分支摘要和上下文编辑标记；不把 UI 历史等同于压缩后的模型上下文。未完成工具显示中断，历史错误使用脱敏说明。当前读取上限为单文件 128 MiB；标准 Pi 目录、原 M1 目录和 App 会话目录可发现，自定义目录可显式配置。外部进程同时写同一执行会话不在已验证边界内。

### 7.3 认证、日志与风险呈现

- Phase 1–2 复用 Pi 已配置的 Provider 和凭据。Phase 3 Mini Agent 的 ModelProvider 独立配置认证。产品仍不新增内置 API Key 管理，不在会话、草稿或日志中保存明文密钥。
- 默认过滤 API Key、Authorization Header 等敏感信息；诊断日志不直接记录完整 Prompt、草稿或工具输出。日志与用户主动查看的会话历史分离。
- 首次激活未知仓库执行前展示工作目录和实际执行权限风险；仅浏览历史不等于授权执行。首版不承诺沙箱隔离。
- `get_session_stats` 提供会话用量与估算费用，不代表 Provider 官方余额。累计 Token 与当前上下文占用分别展示，不能相互替代。
- 无模型、无价格或压缩后暂缺有效上下文数据时，显示未知或待更新，不显示误导性的零值。
- 未来替换 Runtime 时保留 Pi 历史只读浏览，不默认强行转换旧会话；可读范围受已支持格式版本约束。

## 8. 产品代码组织（当前与规划）

M1 已创建根 SwiftPM 工程、`PikachuApp/`、`Packages/AgentRuntimeCore/`、`Packages/OrchestrationCore/`、`Packages/PiRuntimeAdapter/`、`Tests/PikachuCoreTests/` 和 `Tools/M1Verification/`。M2 增加 `Packages/WorkspacePersistence/`、`PiHistoryReader`、工作台协调器及 `Tools/M2Verification/`。`Scripts/build-app.py` 打包原生 App 与独立监督 helper。M0 源码直接共享，实验工程和原证据继续保留。

当前文件按最小功能组织；下图仍是后续展开的目标结构，已交付范围以上述当前模块及阶段报告为准。ACP、Mini Agent 与 Subagent 尚未实现。

```text
Pikachu/
├── PikachuApp/
│   ├── App/                 # 查看会话、草稿及编排入口
│   ├── Features/
│   │   ├── Projects/
│   │   ├── Sessions/
│   │   ├── Chat/
│   │   └── Settings/
│   ├── DesignSystem/
│   └── Persistence/
├── Packages/
│   ├── AgentRuntimeCore/
│   │   ├── Models/
│   │   ├── Events/
│   │   └── Protocols/
│   ├── OrchestrationCore/   # Swift；Phase 1 单任务，Phase 2 任务树与调度
│   ├── PiRuntimeAdapter/   # Phase 2 增加 Pi 委派适配入口
│   │   ├── PiProcessManager.swift
│   │   ├── PiRPCClient.swift
│   │   ├── PiEventMapper.swift
│   │   ├── PiHistoryReader.swift
│   │   └── PiRuntimeAdapter.swift
│   └── ACPRuntimeAdapter/  # Phase 3：Swift ACP 客户端与领域映射
├── Runtimes/
│   └── MiniAgent/           # Phase 3：独立 Rust 工程与 ACP 进程入口
├── Tests/
│   ├── AgentRuntimeCoreTests/
│   ├── PiRPCProtocolTests/
│   ├── PiHistoryReaderTests/
│   ├── ACPRuntimeTests/     # Phase 3
│   ├── OrchestrationTests/  # Phase 2 委派与并发，Phase 3 跨 Runtime 回归
│   ├── TestSupport/         # Fake Runtime 与脱敏协议样本
│   └── PikachuUITests/
├── README.md
└── DESIGN.md
```

此目录图包含后续阶段的目标模块，按阶段创建。Phase 1 实现单任务协调。Phase 2 增加编排与 Pi 委派适配。Phase 3 增加 ACP 客户端与独立 Rust Runtime。

## 9. 里程碑与验收

### 9.1 交付顺序

| 开发阶段 | 技术与目标 | 阶段验收 |
|---|---|---|
| Phase 1 — macOS MVP | SwiftUI + AppKit、直接 Pi RPC；Session、聊天、工具、模型和消耗管理 | 完成下方 M0–M3，交付单任务 v0.1 MVP |
| Phase 2 — 基于 Pi 的 Subagent | Pikachu 管理委派、独立 Pi 子会话、任务树、并发和回传 | 在真实编码任务中完成委派、查看进展、取消和结果回传。验证受控并发、同项目写冲突控制、进程清理和故障恢复 |
| Phase 3 — Mini Agent + ACP | 独立 Rust Mini Agent 与 Swift ACP 客户端，Pi 和 Mini Agent 并存 | 验证六类初期工具、流式执行、会话恢复、取消、超时、错误和强制工具审批。复跑 Phase 2 场景并验证 Pi 与 Mini Agent 混合编排 |

Phase 2 从一个真实 Pi 父子委派闭环开始。委派接口、状态和标识明确后，编排逻辑与任务树界面可用 Fake Runtime 并行验证，真实产品验收见 9.2。Phase 2 通过后进入 Phase 3。选定 ACP 版本和能力约定后，Swift ACP 客户端与 Rust Mini Agent 可分别用协议夹具开发，再联调验收。

**Phase 1 保留以下实施里程碑；M0–M3 不是 Phase 1–3 的另一套编号：**

| 里程碑 | 交付物 | 必须通过的验收 |
|---|---|---|
| M0 — 协议与真实任务验证 | 固定 Pi 版本、最小连接验证工具、协议样本和兼容记录 | 在临时测试仓库完成真实任务；验证流式事件、工具、追加、清队列、停止和进程退出；探明历史格式、分支及恢复路径 |
| M1 — 最小原生交互 | App Shell、Runtime 接口、聊天、工具、队列、停止和 Extension UI 最低兼容 | 从原生界面完成真实任务；请求超时、协议错误、崩溃和事件流结束可见；未实现弹窗不会无限等待；Fake Runtime 可替换 |
| M2 — 会话恢复与切换 | 项目、历史浏览、草稿持久化、执行切换、模型配置 | 重启后恢复可确认历史与草稿；运行中查看其他会话不中断；切换执行对象无迟到事件污染；异常输入不自动重发 |
| M3 — 工作台完善 | 用量统计、完整 Extension UI、快捷键、辅助功能和性能完善 | 原生交互完整；模型与费用信息准确或明确缺失；长历史与大输出场景达到已冻结性能指标 |

M0 的原全量 40/40 与 M1 的 17 项单元、13 项集成和原生结果保留在对应阶段报告。M2 已实现项目索引、只读历史、独立草稿持久化、会话恢复、执行目标切换及模型配置。目录移动后的旧会话续跑受上文 Pi RPC 限制。M3 已增加用量、原生扩展交互和工作台优化，最终构建通过冻结性能目标。 [M2 报告](docs/m2/REPORT.md) · [M3 性能验收](docs/m3/PERFORMANCE.md)

M1 的最低可靠性不能延期到 M3；M3 负责覆盖完善和体验优化，不是首次处理异常。M0–M3 完成后构成 Phase 1 的 v0.1 MVP，不代表 Phase 2、Phase 3 已完成。

### 9.2 自动化与集成验证

以下保留 Phase 1 的 Pi 协议与通用可靠性场景；Pi 专有命令和事件不直接用来验收 ACP 后端。

| 类别 | 场景及预期 |
|---|---|
| 协议分帧 | JSONL 分包、UTF-8 边界、CRLF 和字符串内 Unicode 行分隔符；完整记录仅解析一次 |
| 请求关联 | 多个请求响应次序不同、事件与响应交错、超时后迟到响应；不匹配到其他请求，不自动重试状态修改 |
| 消息与工具 | 多消息的相同 `contentIndex` 不串联；最终消息纠正增量；工具状态按实例和调用标识归属 |
| 运行生命周期 | `agent_end` 后重试、压缩或 follow-up 继续；直到 settled 才结束自动运行，错误不被标成成功 |
| 输入与队列 | 默认补充、显式后续执行、拒绝和已处理响应；UI 不把已接受一律标成仍在队列 |
| 停止与草稿 | 先清队列后中断；已有草稿保留，清出消息有序保存且不重复、不自动发送；清队列失败不显示成功 |
| 并发交互 | 停止期间禁止新发送；查看历史不停止执行；另一会话发送前确认停止；切换取消不改变执行对象 |
| 扩展交互 | 未实现的已知对话请求返回取消；原生回复、关闭、超时和断连至多产生一次有效回复 |
| 故障恢复 | Pi 不存在、依赖缺失、认证失败、协议错误、进程崩溃、工具子进程终止失败；错误明确且不自动重发 |
| 历史与持久化 | 重启、目录移动、会话分支、压缩、尾部部分记录、损坏和未知格式；不改写源历史，不伪造空会话 |
| 事件隔离 | 旧进程、旧会话和旧交互的迟到事件不更新新执行实例；所有未决调用在关闭时结束 |
| Runtime 替换 | Fake Runtime 替换 Pi 后通用 UI 测试无需修改；缺少可选能力时正确降级 |
| 版本兼容 | 已验证、未知和缺少必要能力的版本分别处理；不以可连接等同于可安全执行 |

后续阶段增加以下场景：

| 阶段 | 场景及预期 |
|---|---|
| Phase 2 / 真实委派 | Pi Main Agent 在实际 RPC 模式调用 `delegate_task`。Pikachu 创建独立 Pi Child Session 并记录父子关系。Child 完成后，Main Agent 收到结果并用它继续原任务 |
| Phase 2 / 多任务交互 | 任务树展示每个 Session 的进度、状态和结果。运行中切换查看对象不会改变执行对象；等待输入时明确显示请求归属 |
| Phase 2 / 并发 | 每个并发 Pi Agent 使用独立受监督的进程。并发额度生效，工具、流式事件和迟到回复归属正确，未隔离的同项目写任务串行 |
| Phase 2 / 取消与恢复 | 单 Child 取消不影响无关任务，整树取消覆盖后代。受管进程清理确认后释放其额度。崩溃后恢复任务树和可确认状态，未决执行保留为待核实，不自动重跑 |
| Phase 2 / 结果回传 | 成功、失败、取消和未知结果分别记录。原父会话可用时按委派标识回传。重复或迟到结果不能造成重复继续，Parent 不可用时保留结果 |
| Phase 3 / ACP | 验证版本与能力协商、Session 创建与恢复、流式事件路由和取消。在缺少恢复、模型或用量能力时正确降级。按对应后端语义确认终态 |
| Phase 3 / Mini Agent | 验证 `read`、`write`、`edit`、`bash`、`grep`、`glob` 的成功与失败，以及工具超时、推理取消和崩溃恢复。核对未决操作不会被重复执行 |
| Phase 3 / 审批 | 批准只作用于原请求和执行实例。拒绝、取消、过期或断连后，相关工具操作不得执行 |
| Phase 3 / 跨 Runtime 回归 | 用 Mini Agent 复跑 Phase 2 委派、取消和回传场景，并验证至少一种 Pi 与 Mini Agent 混合的父子组合。切换后端后保留原会话和历史。缺少委派通路时按能力禁用主动委派 |

Phase 2 使用真实 Pi 编码任务验证完整体验。Phase 3 使用真实 Mini Agent 和混合后端场景复验。两阶段均分别记录协议、原生交互、辅助功能和性能结果。

### 9.3 性能与原生体验

测量必须记录设备、macOS、构建配置、Runtime 及协议版本、数据集规模和采样方法，并区分本地 UI 延迟与模型网络响应时间。下表为 Phase 1 基线。Phase 2 在固定并发数量和任务规模下新增调度与交互测量。Phase 3 在可比条件下复测，并分别记录不同后端的执行等待。

| 指标 | 测量边界 |
|---|---|
| 冷启动 | 用户启动 App 到界面可输入；Pi 就绪时间另行记录 |
| 会话切换 | 选择历史到首屏可读、到历史加载完成；与执行实例切换分开测量 |
| 长历史滚动 | 固定历史长度和内容类型下的滚动流畅度、主线程卡顿与内存占用 |
| 输入响应 | 流式文本及大量工具输出期间，按键到文字显示的延迟 |
| 大输出处理 | 协议处理积压、内存增长和控件响应；折叠结果也不能无限积累 UI 渲染负担 |

M0 确定参考设备、样本规模和测量方法；M1 建立首轮基线并冻结首版数值目标，M3 按同一条件验收。不在尚未测量时虚构具体性能数值或“已达标”结论。

M1 已建立可重跑的领域状态投影基线，固定 100 / 5,000 条规模，并冻结首版目标。M3 在独立诊断构建中采集 WindowServer 呈现时间、聊天区帧变化和输入字形，并用 Instruments 验证主线程停顿。最终构建通过原冻结目标。 [基线与目标](docs/m1/PERFORMANCE.md) · [最终原生测量](docs/m3/NATIVE-PIXELS.md)

实现需避免每个 token 都触发整段历史的重排；工具输出按需展示，历史逐步加载，渲染缓存设有边界。具体策略由测量支持，不以替换 UI 框架作为默认优化方案。

## 10. 已定决策与待决事项

### 已定决策

以下决策已确定，不再作为实施前的开放选型；详细行为以对应章节为准。

| 决策 | 定义位置 |
|---|---|
| Pikachu 编排、Runtime 执行。Phase 1 单任务，Phase 2 自主管理 Pi Subagent，Phase 3 验证跨 Runtime 编排 | 第 1 节、5.1、5.3、9.1 |
| 当前 SwiftUI + AppKit；不提前迁移 GPUI，Swift 编排保持独立 | 第 5 节技术路线、5.5 |
| Phase 1–2 直接 Pi RPC。Phase 3 引入独立 Rust Mini Agent 与 ACP。长期按 ACP 能力适配，不使用 FFI | 5.4、第 6 节 |
| 查看与执行分离、停止保留草稿、异常不自动重发 | 第 4 节 |
| Phase 3 Mini Agent 必须具备执行侧强制审批。Phase 1–2 的 Pi 权限按其既有能力标明 | 5.4、6.5 |
| 历史按 Runtime 保留，不默认跨后端转换；任务编排记录由 Pikachu 持久化 | 第 7 节 |

### 待决事项及决策时点

| 事项 | 决策时点 | 当前约束 |
|---|---|---|
| 持久化格式后续迁移 | 变更已交付格式前 | M2 已采用本地 SwiftData 和版本化中立元数据快照；后续须定义迁移并验证旧草稿、关联标识和稳定 ID 保留 |
| 原生监督的分发环境扩展 | 启用 App Sandbox 或公开分发前 | M1 自用 ad-hoc 包与受控退出已验证；不同权限和签名环境仍须复验，不扩大 M0 受管边界 |
| 原生性能基线补齐与验收 | M3 收尾 | M3 已按冻结阈值验证最终构建，保留原生时序与追踪 |
| 只读改动预览的归属方案 | MVP 后增强实施前 | 必须处理已有改动和外部并发修改，无法确认时明确标注 |
| 公开分发、签名公证及名称 | 公开测试或发布前 | 首版自用；不宣称已具备公开发布条件 |
| `delegate_task` 工具暴露与结果回传契约 | Phase 2 真实 Pi 委派验证前 | 先确定委派标识、取消和终态回传语义。Pi 工具适配由 Pikachu 控制。Phase 3 用同一领域契约验证 Mini Agent 的接入方式 |
| Subagent 并发额度、委派深度与隔离扩展 | Phase 2 调度实现前 | 明确首版额度与深度。未隔离的同项目写任务保守串行，Worktree 留作后续隔离选项 |
| ACP 规范版本与兼容 Agent 清单 | Phase 3 接入实现前 | 选定稳定版本，逐一验证后端能力和具体接入方式 |
| Mini Agent 首批 Provider、认证配置与审批策略细则 | Phase 3 执行工具接入前 | Rust 与基础工具集已确定，审批须在执行侧生效。认证配置独立验证 |

## 11. 参考资料

- [Pi RPC Mode](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md)
- [Pi RPC Commands](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc-commands.md)
- [Pi JSON Events](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/json.md)
- [Pi Extension UI](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc-extension-ui.md)
- [Pi Extensions 与自定义工具](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md)
- [Pi Session File Format](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/session-format.md)
- [ACP Protocol Overview](https://agentclientprotocol.com/protocol/v1/overview)
- [ACP Initialization and Capabilities](https://agentclientprotocol.com/protocol/v1/initialization)

这些链接指向上游可变文档。M0 与 Phase 2 分别记录 Pi 基础能力和委派能力的验证版本，Phase 3 记录采用的 ACP 规范、后端版本及能力差异。各阶段核对适用的 tag、commit 或对应资料。

---

**最终目标**：Pikachu 是独立的 Agent 工作台。UI 和 Runtime 可以更换，Subagent 编排与产品能力由 Pikachu 自主掌控。三个阶段依次验证单任务交互、Subagent 产品闭环和执行后端替换。
