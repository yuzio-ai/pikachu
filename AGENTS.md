# Pikachu 项目 Agent 规范

本文件适用于仓库内的开发、审查、整改和验收。使用与构建入口见 [README](README.md)，架构与阶段规划见 [DESIGN](DESIGN.md)。

## 工程入口与代码位置

- 使用 [Pikachu.xcodeproj](Pikachu.xcodeproj) 的共享 scheme。主应用和两组单元测试均通过 `Pikachu` scheme 构建或运行。新增源码、资源或测试时，确认目标 target 已包含该文件。
- [Pikachu/](Pikachu/) 包含应用入口（`App/`）、界面功能（`Features/`）、设计组件（[DesignSystem](Pikachu/DesignSystem/)）、本地服务（`Services/`）和诊断代码（`Diagnostics/`）。界面变更沿用 [DesignSystem](Pikachu/DesignSystem/) 和 [设计令牌](DESIGN_TOKEN.md)。`Features/` 只依赖 `AgentRuntimeCore` 和 `OrchestrationCore`，不直接引用 `ACPRuntimeAdapter`、解析后端会话文件或持有 SwiftData 模型。
- Runtime 抽象、领域模型与 `FakeRuntime` 在 [AgentRuntimeCore](Modules/AgentRuntimeCore/)，会话与工作台编排在 [OrchestrationCore](Modules/OrchestrationCore/)，工作台索引和草稿持久化在 [WorkspacePersistence](Modules/WorkspacePersistence/)。ACP 协议和会话回放在 [ACPRuntimeAdapter](Modules/ACPRuntimeAdapter/)。进程监督由 [ProcessSupervision](Modules/ProcessSupervision/)、[CProcessInspection](Modules/CProcessInspection/) 和 [PikachuSupervisor](PikachuSupervisor/) 负责。
- 本地化目录 `Localizable.xcstrings` 分布在 `Pikachu`、`OrchestrationCore`、`ACPRuntimeAdapter` 和 `AgentRuntimeCore`，新增或删改用户可见文案时同步维护所属 target 的词条并清理过期键。变更第三方图标或服务商标识时同步更新 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。
- 设计、实现或审查桌面界面时，读取 [极简桌面界面审查 Skill](.agents/skills/minimal-desktop-ui-review/SKILL.md)。界面改动在交付前按 Skill 自查本次变更，说明需要运行证据才能确认的事项。

## 构建与验证

- 默认只做工程交付。完成代码修改，按改动需要执行工程验证，并说明改动范围、验证结果和已知风险。工程验证包括编译、运行 [单元测试](Tests/) 和集成测试、验证构建产物，以及运行 [隔离验证脚本](Scripts/run-isolated-verify.sh)。
- 原生 macOS 验收须经用户在当前任务中明确授权，并按授权范围执行。适用范围包括启动应用核对窗口、滚动、交互或辅助功能，以及采集原生运行性能证据。测试或验证脚本涉及上述原生验收时，其中的原生验收步骤同样须经授权。
- 命令行工程验证默认使用 [隔离验证脚本](Scripts/run-isolated-verify.sh)。编译和测试用 `--scheme` / `--action`，集成验证用 `--tool`。需要增量构建或保留本地调试 App 时，复用仓库根目录下的 `build/`，命令行传入 `-derivedDataPath build`。`build/` 和 `.verification-runs/` 均已被 Git 忽略。
- 每次验证结束后，只保留交付、复核或排查所需的摘要、必要日志片段和截图。内置和自定义结果包均需显式使用 `--save-xcresult`，并通过 Xcode 的引用对象检查后才导出。取消时跳过结果包。验证重跑后，及时清理被替代且没有证据引用的结果包、日志和夹具。
- 交付前检查本任务生成的验证目录和构建产物。导出必要证据后，删除临时构建目录、导出的 `.app` 和无需保留的运行输出。共享 `build/` 在本任务最后一次构建或测试后清理，清理前确认其他任务没有使用它。确需保留的产物应写明路径、原因和清理条件。
- 按改动选择 [集成验证工具](Verification/README.md)。获授权的原生验收应以原生 macOS 运行证据核对相应行为。性能结论应对应实际测量的构建、场景和数据规模。
- 优先用合成夹具或无推理用例验证。使用真实 ACP 智能体的推理用例会使用本机认证并产生模型调用费用。诊断 App 使用独立 Bundle Identifier 与隔离数据目录。证据和诊断配置中不要写入凭据或钥匙串环境变量的值。

## 隔离验证与临时目录清理

以下流程适用于工程验证和已获授权的原生验收。

隔离验证脚本默认使用当前工作区快照。用 `--archive` 或 `--source-dir` 指定其他源码，按需传入 `--patch` 和 `--overlay`。脚本将源码、DerivedData、结果包和夹具收拢在单一临时目录，退出时默认清理。收到 `SIGINT` 或 `SIGTERM` 时，先终止当前验证进程组，再清理。用 `--evidence-dir` 指定本次运行的新目录，证据复制成功后才发布到该目录。

使用 `--scheme` / `--action` 运行内置构建或测试时，脚本遇到首个失败就停止并返回该次 `xcodebuild` 的退出码。通过 `-- <command...>` 可运行自定义命令并获知其退出码。自定义构建使用脚本提供的 `PIKACHU_DERIVED_DATA`。完整参数见脚本的 `--help`。

无法使用包装脚本时，按以下方式手动隔离。

1. 用 `mktemp -d "${TMPDIR:-/tmp}/pikachu-<task>-XXXXXX"` 创建单一根目录。将临时源码、DerivedData、App、夹具、日志和测试结果放在该目录内。
2. 绑定退出清理 `trap 'rm -rf "$SANDBOX_DIR"' EXIT`。退出前按上面的保留规则导出证据。任务交接证据放在对应的 `.yuzio/cohestra/handoffs/<task>/`，其他需保留的本地证据可放在 `.verification-runs/`。正式文档和交付物引用导出后的路径。
3. 交付前确认临时目录及其中编译出的 `Pikachu.app` 已删除；若验证过程中启动过临时路径或非标准目录里的 `Pikachu.app`，删除前或清理后需同步从 LaunchServices 注销（`lsregister -u <app-path>`）或清理失效注册，避免系统「打开」/ Spotlight 残留大量重复图标。若因阻塞必须保留现场，交付时写明保留的路径和清理条件。脚本的 `--keep-on-failure` 也仅用于这种情况。
