# M1 最小原生交互交付报告

> 历史归档：本报告与证据保留验收时的原始命名与路径；当前工程路径及工具名对照见 [Verification/README.md](../../../Verification/README.md)。

- 日期：2026-11-18（Asia/Shanghai）
- 结论：M1 功能验收通过，保留 M0 已验证的监督策略；停在 M1。
- 环境：macOS 27.2.1 / arm64、Xcode 27.2、Swift 6.4.2、Node 24.12.0、Pi 1.5.2；真实任务使用既有 openai / gpt-6.1-sol 配置与本机系统代理。
- 构建：SwiftPM debug、单窗口原生 SwiftUI + AppKit、最低 macOS 27，App 与 helper 均为 ad-hoc 签名。

## 交付范围

| 层 | 已实现 |
|---|---|
| AgentRuntimeCore | 与 Pi / SwiftUI 无关的 Session、Prompt、Queue、Tool、Event、Failure；AgentRuntime 与 FakeRuntime |
| PiRuntimeAdapter | 直接 JSONL / stdio RPC；版本与路径检查、无推理状态读取、后台协议投影、超时、扩展取消及受管关闭 |
| OrchestrationCore | 单执行槽位；连接 / 执行 / 队列分离；消息投递状态、最终文本校正、迟到事件隔离、草稿恢复 |
| PikachuApp | 本地目录选择、多行输入与快捷键、流式聊天、基础 Markdown 与代码复制、可折叠工具、模型及思考级别只读显示、停止与退出确认 |
| 工具 | App 打包脚本、故障协议夹具、真实任务验证器和领域投影基线 |

View 不读取 Pi JSON，也不直接管理 Process。原始历史继续由 Pi 保存；App 没有新建第二份对话数据库。模型读回不等于模型切换，当前未实现模型选择或统计。

停止先清队列，再中断执行。清出的输入保持模式和各队列内顺序，退回待发送列表；不覆盖编辑框，也不自动发送。放回编辑框时追加到已有内容之后。发送结果不明时保留明确标记，不自动重试。清理未确认时阻止继续执行。

## 监督策略保留

根工程通过 SwiftPM 直接共享 M0 的 `CM0Process`、`M0Support` 和 `M0Supervisor` 源码。App bundle 内置 `m0-supervisor`，通过同一监督路径启动 Pi。

监督主体、C 进程检查和 PID / 启动时间所有权实现与 M0 冻结指纹完全一致。`RPC.swift` 仅新增线程安全的游标观察方法，供适配层消费已接收记录；去除该新增方法后的 SHA-256 与 M0 一致。对比结果记录于 [证据清单](evidence/manifest.json)。

每实例标记、谱系登记、身份复核、宿主丢失检测、TERM → KILL、有界清理和未知状态拒绝释放槽位均保留。仍受 [M0 边界](../pi-rpc-compatibility/SUPERVISION.md#3-适用边界) 限制。GUI 受控退出已验证；没有把系统 Force Quit、App Sandbox 或公证分发视为已验证。

## 验证结果

| 验证 | 结果 | 证据 |
|---|---|---|
| 领域及适配单元测试 | 17 / 17 | [测试输出](evidence/swift-test.txt) |
| M1 最终集成 | 13 / 13 | [结果](evidence/integration/results.json) |
| M0 全量回归 | 40 / 40 | [结果](evidence/m0-regression/results.json) |
| M0 单元回归 | 9 / 9 | [测试输出](evidence/m0-swift-test.txt) |
| 原生交互 | 真实编码、工具展开、Markdown、排队 / 停止 / 草稿合并、取消退出与受控退出通过 | [原生观察与独立断言](evidence/native/final.json) |
| 打包与签名 | 构建成功，codesign deep / strict 验证通过 | [构建输出](evidence/build.txt) |
| 首轮本地基线 | 100 / 5,000 条消息，各三轮 | [边界、数据和冻结目标](PERFORMANCE.md) |

最终集成编号 `2026-11-17T21-18-27Z`。九项离线 / 合成检查覆盖 Fake Runtime、正常流、明确拒绝、认证失败、发送超时、协议损坏、进程崩溃、未知版本和启动超时。四项真实 Pi 检查包括四种 Extension UI 取消、两轮编码修复、停止及崩溃清理。

四种对话依次返回 `[null,false,null,null]`，证明 select、confirm、input、editor 均取消且没有无限等待。真实编码任务由独立 Node 测试确认从失败变为通过，并检查测试文件未被修改。停止后的工具心跳不再增长，清出的输入标记为 recovered，编辑草稿保持不变。超时夹具只收到一次 Prompt，未自动重发。

原生验收使用一次性项目，实际完成 read / edit / bash 修复及测试。最终构建再次核对“排队中 → 已退回草稿”、编辑框不变、恢复时追加以及清理后断连。UI 观察来自原生辅助功能树与截图；独立文件 / 进程断言见证据，不以单元测试代替原生观察。

## 验证中修正的问题

- 原生工具行的辅助功能标签引发 SwiftUI 标签解析递归与崩溃。改为具体容器、分离子元素并移除重复标签；重跑工具展开、代码块及停止验收。[脱敏崩溃摘要](evidence/native/accessibility-crash.json) 保留，未导出完整系统诊断。
- 排队响应可能先于 queue_update 到达。旧快照曾把刚排队的输入标为已接受。增加快照序号判断和回归测试，停止清出的输入显示为已退回草稿。中间集成失败保留在 [修正前结果](evidence/intermediate-results.json)，最终真实停止复验通过。
- 领域投影每次查找都遍历历史。改为按稳定 ID 索引，5,000 条消息投影由约 2.6 秒降为 14–19 毫秒。该结果只覆盖领域层，不能宣称原生输入或滚动达标。

## 范围与限制

- 每次连接建立新会话；仅一份内存中的当前对话和草稿。没有项目索引、历史浏览、持久化、恢复或会话切换，没有进入 M2。
- 当前仅允许已验证的 Pi 1.5.2。自动扩展、技能、主题与 Prompt 模板使用关闭的兼容配置；测试扩展通过显式夹具注入。未知版本没有开放试用入口。
- 仅取消四种已知 Extension UI 对话，完整原生对话属于 M3。未知阻塞交互显式报错并要求停止或结束进程。
- Markdown 支持段落、标题、行内格式和代码围栏；不是完整 CommonMark 编辑器或语法高亮器。工具展示限 65,536 字符，参数限 16,384 字符。
- 协议观察仍复用 M0 的记录保留方式；大输出展示截断不等于整个进程内存有界。长运行的记录保留、背压、原生长列表、VoiceOver 完整覆盖与量化 UI 性能留待 M3，不能根据本轮结果宣称全部达标。
- 自用 debug 包未做公开签名、公证或其他设备兼容验证。既有 M0 证据未被覆盖；本轮未提交或推送 Git。

源码、构建产物及证据 SHA-256 见 [manifest.json](evidence/manifest.json)。导出证据检查未包含已知凭据值，临时复制的认证目录已删除；最终原生工具 PID 已退出且心跳停止。
