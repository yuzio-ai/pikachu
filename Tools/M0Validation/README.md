# M0 验证工具

这是独立的 Swift/C 命令行实验工程，不是 Pikachu App，也不包含 M1 实现。
要求 macOS 27+、Swift 6、Pi **1.5.2** 和 Node。无外部 Swift 依赖。

```sh
swift test --disable-sandbox --package-path Tools/M0Validation
swift build --disable-sandbox --package-path Tools/M0Validation
Tools/M0Validation/.build/debug/m0-verify --suite local
Tools/M0Validation/.build/debug/m0-verify --suite extended
Tools/M0Validation/.build/debug/m0-verify --suite supervision
Tools/M0Validation/.build/debug/m0-verify --suite real --proxy http://127.0.0.1:7897
Tools/M0Validation/.build/debug/m0-verify --suite continuation --proxy http://127.0.0.1:7897
Tools/M0Validation/.build/debug/m0-verify --suite agent-crash --proxy http://127.0.0.1:7897
```

`--disable-sandbox` 只关闭 SwiftPM 的嵌套构建沙箱，外层执行环境的文件和网络权限仍然有效。
代理参数仅在机器实际配置相应代理时使用；不是安装代理或改变系统设置。

可选参数：`--pi`、`--node`、`--provider`、`--model`、`--proxy`、`--output`。
默认 Pi 为 `~/bin/pi`，Node 为本机已验证的 `~/.nvm/versions/node/v24.12.0/bin/node`，默认模型为 `openai/gpt-6.1-sol`。
其他模型或 Pi 版本不能沿用本报告的兼容结论。

| Suite | 内容 | 模型调用 |
|---|---|---|
| local | 启动环境、真实 RPC、模型查询、扩展交互、直接 Bash 停止、空闲崩溃 | 无 |
| extended | 构造分支/压缩历史、EOF、直接 Bash 崩溃、10 MiB 输出 | 无 |
| supervision | 脱离后代、宿主 SIGKILL、实例隔离、监督失效与 SIGTERM 升级 | 无 |
| real | 三轮真实缺陷修复、三轮 Agent 队列清空及停止 | 有 |
| continuation | 补充和 follow-up 的实际交付 | 有 |
| agent-crash | 三轮真实 Agent Bash 运行期间终止 Pi | 有 |
| all | 上述全部 | 有 |

默认启用独立的 `m0-supervisor`，须先运行 `swift build` 构建两个可执行文件，并将其放在同一目录。
监督进程为运行时注入每实例随机标记，按同用户进程的标记、已观测谱系和启动时间维护所有权；Pi 或 RPC 宿主退出后清理对应进程，等待终态。
不会按进程名全局匹配或读取夹具 PID 来决定清理对象。

`extended` 和 `agent-crash` 会故意终止受控 Pi。验收要求监督清理后心跳和进程均停止，且返回 clean；夹具 PID 只用于独立核验与失败时的测试救援。**退出码 1 仍表示验证失败**。
`--unsupervised` 仅供研究原始行为，不可用于监督策略验收；进程树专项始终启用监督。

监督报告缺失、状态未确认或监督进程失效时，拒绝释放执行槽位并拒绝新命令。监督进程本身被 SIGKILL 的负向测试会刻意进入该路径，再由测试救援清理夹具。
当前策略要求同用户进程可检查，覆盖继承标记的后代及已观测谱系；不是操作系统沙箱，不保证主动清除标记后立即脱离所有可观测关系或提权执行的进程。

每轮使用独立临时目录、专用 Session 目录，关闭扩展/skills/模板/主题自动发现；交互案例显式加载 `Fixtures/control.ts`。
默认认证仅复制到权限 0700 的临时配置目录，文件权限 0600，正常收尾删除配置目录，不写入证据、不修改日常 Pi 配置。
若强制终止验证工具本身，需清理对应临时目录中的 `private-config`；不要将其加入版本控制。

输出在项目根目录 `.m0-runs/<UTC-run-id>/`，包含案例结果和专用测试协议样本。
`local`、`extended` 不使用真实模型；其中的构造历史、故障注入与真实进程行为分别在报告标记。
`HistoryProbe` 只验证 v3 活动分支与格式边界，不是完整的产品历史/上下文实现。

原始测试 Session 可能包含工具输出，只用于本地测试证据，不作为产品诊断日志设计。对外提交样本前必须扫描凭据并确认只包含测试内容。

首轮阻塞见 [历史报告](../../docs/m0/REPORT.md)，当前监督策略与复验结果见 [M0 监督收口报告](../../docs/m0/SUPERVISION.md)。该工具从不启动 M1，也不创建 macOS App 工程。
