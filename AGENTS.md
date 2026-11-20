# Pikachu 项目 Agent 规范

本文件约束在本仓库内执行开发、审查（`review`）、整改（`fix`）与验收（`validate`）的所有智能体。

## 1. 构建与验证目录约定

- 日常工作区编译与测试输出统一使用仓库根目录下的 `build/`（已由 `.gitignore` 忽略），运行态验证输出统一写入 `.verification-runs/`，不要在工作区根目录或 `/tmp` 散落临时构建目录。
- 常规构建与验证入口见 [README.md](README.md) 与 [Verification/README.md](Verification/README.md)。

## 2. 隔离验证与 `/tmp` 强制收尾（必守）

当任务需要**脱离当前工作区**验证固定候选快照（如 `.yuzio/cohestra/handoffs/<task>/.../source.tar.gz`）、注入一次性探针测试、编译隔离 `DerivedData` / `.app` 或构造独立运行夹具时：

1. **优先使用统一包装脚本**：调用 [Scripts/run-isolated-verify.sh](Scripts/run-isolated-verify.sh)（支持 `--archive` / `--source-dir`、`--patch`、`--overlay`、`--evidence-dir` 以及自定义 `-- <command...>`）。脚本内置 `mktemp -d` 与 `trap ... EXIT`，会在导出指定证据后自动删除临时沙盒（包含隔离源码、`DerivedData`、`.xcresult`、夹具与原始日志）。
2. **禁止散落无清理的 `/tmp` 产物**：不得直接在 `/tmp`（或 `/private/tmp`）平铺多个独立目录或零散 `.log` / `.xcresult` / `DerivedData-*`。
3. **手动 `/tmp` 沙盒的最低收尾要求**（仅在无法通过 `Scripts/run-isolated-verify.sh` 完成的特殊场景下适用）：
   - 必须用 `mktemp -d "${TMPDIR:-/tmp}/pikachu-<task>-XXXXXX"` 创建**单一根临时目录**，将临时源码、`DerivedData`、`.app`、夹具及一次性探针脚本全部收拢在其中；
   - 必须绑定退出清理（`trap 'rm -rf "$SANDBOX_DIR"' EXIT`），在删除前先将需要保留的精简日志、截图或摘要拷贝至目标证据目录（如 `.yuzio/cohestra/handoffs/<task>/` 或 `.verification-runs/`）；
   - **交付或结束回合前必须确认该 `/tmp` 临时目录已删除**；仅当任务因受阻必须保留现场供人工排查时才可跳过删除，且必须在交付说明中明确写出保留路径与清理条件。
4. **禁止将 `/tmp` 路径作为持久依据**：正式文档（`docs/`）与阶段交付物中不得仅链接 `/tmp/...` 路径作为证据来源。
