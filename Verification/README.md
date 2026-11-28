# Zivvi 工程验证

在仓库根目录运行以下命令。默认使用临时目录，结束后自动清理。

```sh
Scripts/run-isolated-verify.sh --tool runtime-verify
Scripts/run-isolated-verify.sh --tool runtime-verify -- --baseline
Scripts/run-isolated-verify.sh --tool acp-compat-probe -- --suite fake
```

`runtime-verify` 通过 FakeRuntime 验证连接和清理。`--baseline` 测量领域事件投影耗时。

## 单元测试

按测试方法选择纯逻辑用例，例如目录分页和额度投影。可重复传入 `--only-testing`。

```sh
Scripts/run-isolated-verify.sh --scheme Zivvi --action test \
  --only-testing ZivviTests/ProjectFilesTests/testProjectNavigatorPaginatesWithinTheExpandedDirectory \
  --only-testing ZivviTests/Workbench20Tests/testQuotaMetricDistinguishesUnknownZeroSmallAndExpiredWindows
```

全量命令为 `Scripts/run-isolated-verify.sh --scheme Zivvi --action test`，会执行打开原生窗口的用例。按[项目规范](../AGENTS.md#构建与验证)取得原生验收授权后再运行这些用例。只编译测试使用 `--action build-for-testing`。

XCTest 进程通过 `QuotaCLIProcessPolicy` 跳过 Codex 和 Antigravity 额度探测。其他诊断可使用 `--fake` 或 `ZIVVI_DISABLE_QUOTA_PROBES=1`。

## ACP 兼容性探针

独立验证 ACP v1（`protocolVersion: 1`）客户端传输、握手、模型/模式探测、权限交互、取消中断、会话恢复（`session/load`）及 `zivvi-supervisor` 进程树监督清理。支持无外部依赖的合成夹具 `Verification/Fixtures/fake-acp.py` 以及真实 ACP v1 Agent（默认自动探测 Antigravity CLI `agy acp`）。

```sh
Scripts/run-isolated-verify.sh --tool acp-compat-probe -- --suite fake
Scripts/run-isolated-verify.sh --tool acp-compat-probe -- --suite local --command /opt/homebrew/bin/agy --arg acp
Scripts/run-isolated-verify.sh --tool acp-compat-probe -- --suite real --command /opt/homebrew/bin/agy --arg acp --proxy http://127.0.0.1:7897
```

可选参数：`--suite <fake|local|real>`、`--command <可执行文件路径>`、`--arg <参数>`（可重复传入）、`--cwd <目录>`、`--proxy <代理地址>`、`--allow-permissions`（仅 `real` 用例允许自动放行权限请求）、`--prompt <自定义提示词>`、`--output <输出目录>`、`--unsupervised`（仅供研究原始行为）。

| Suite | 内容 | 模型调用 |
|---|---|---|
| `fake` | 基于 `Verification/Fixtures/fake-acp.py` 回归握手、版本不兼容、流式回合、工具与 Diff 映射、权限审批/取消、取消中断、`session/load` 回放与监督清理 | 无 |
| `local` | 针对本机真实 ACP v1 Agent（默认 `agy acp`）执行无推理 `initialize` / `session/new` / 能力与模式/模型字段探测及监督退出清洁度检查 | 无 |
| `real` | 显式授权后的真实模型对话、工具执行、权限交互、取消与恢复验证 | 有 |
