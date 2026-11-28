# 品牌动效规范（Motion）

本规范定义原生 SwiftUI 2D 品牌动效系统。所有动效坚持纯 2D、克制、默认静音、由真实运行时状态驱动，并严格遵守系统「减少动态效果（Reduce Motion）」。实现位于 [BrandMotion.swift](../../Zivvi/DesignSystem/BrandMotion.swift)。

## 1. 四类品牌动效总览

| 动效 | 场景 | 时长 / 周期 | 播放模式 | 核心触发条件 |
| --- | --- | --- | --- | --- |
| **Convergence（汇聚）** | 冷启动 | `800 ms` | 单次 | 进程冷启动首帧，由 `BrandTurnMotionTracker.consumeColdLaunch()` 保证单次 |
| **Alive（呼吸）** | 新建空会话欢迎页 | `5000 ms` 周期 | 低频循环 | 空草稿新会话且输入框未聚焦、草稿为空、窗口活跃 |
| **Flow（能量流动）** | Agent 执行中 | `1800 ms` 周期 | 活跃循环 | 真实 `TurnStatus.running` 且非 `waitingApproval`，窗口活跃 |
| **Discharge（能量释放）** | 整体任务完成 | `450 ms` | 单次 | 仅实时观测到的 `.running → .completed` 转换，按 `turn.id` 去重 |

## 2. 详细行为与真实事件约束

### 2.1 冷启动 Convergence（800 ms）

- 使用与 `BrandMasterLogo` 共享 `759 × 830` 画布的 6 个分层资产（`agent-top/main/left/bottom`、`energy-trail/rays`），四生命体错峰从各自方向汇聚回母版锚点（0–180 ms 出现 → 180–450 ms 加速汇聚 → 450–650 ms 锚点回弹稳定 → 650–800 ms 能量线点亮并交叉淡入静态 `BrandMasterLogo`）。
- 冷启动汇聚期间不显示多余文字；全过程 `.allowsHitTesting(false)`，与后台工作台初始化并行执行，不阻塞点击、输入、设置或系统权限弹窗。
- 仅在进程冷启动首次播放；重开窗口、切换会话或从后台切回时不重播。

### 2.2 新建会话 Alive（5000 ms）

- 欢迎页居中展示 104 pt 宽四生命体母版 Logo（固定外框 `104 × 114 pt`）与 `Ready to Zip?` 标题，无副标题卡片。
- 5 s 周期微浮动（最大 2 pt）与 `agent-top` / `agent-left` / `agent-bottom` / `energy-rays` 错峰微呼吸。
- 当输入框获得焦点或输入任意草稿文本时，立即收敛为静态 `BrandMasterLogo`（零布局位移）；清空草稿且失焦后仍为空会话时恢复。首条消息提交后退出欢迎态。
- 眼部眨眼暂未实现（原交付包未含矢量眼部分离层，禁止用不匹配画风重绘）。

### 2.3 执行中 Flow（1800 ms）

- **单 Agent 响应头**：使用紧凑 16–18 pt `BrandStateIconView`（`lightning_brand_active` 柔和能量脉动），完全隔离在叶子视图中，不触发外层对话列表布局或重算。
- **多 Agent / 并行运行**：使用 `BrandMotionView(mode: .flow)` 四层错峰（0 / 350 / 700 / 1050 ms 相位间隔）能量流动。四个生命体为群体智能隐喻，不映射具体 Agent 数量。
- 流式文本 delta 与工具收起不会重置动画相位；进入 `waitingApproval`、停止、失败或完成时立即停止循环。

### 2.4 完成 Discharge（450 ms）与失败中断（≤220 ms）

- **完成 `Zzzap!`**：`0% → 22%` 轻微蓄力收缩（`0.92x`），`22% → 52%` 能量释放（`1.18x` + 微提亮），`52% → 100%` 回归 `1.0x`，固定容器尺寸不引发任何布局移动。
- **失败 `Zzzzt…`**：单次 220 ms 能量中断淡落回稳，随后保持静态错误图标与真实错误详情，禁止持续抖动。
- **去重与防回放**：通过 `BrandTurnMotionTracker` 记录实时进入 `.running` 的 `turn.id`；历史回放、重新打开会话、恢复窗口或来回切换会话绝不重播旧任务的完成或失败动效。用户主动停止（`.stopped`）与结果待核实（`.uncertain`）不播放庆祝或异常动效。

## 3. Reduce Motion、生命周期与性能

- 开启 `accessibilityReduceMotion` 后，禁用空间位移、缩放与循环脉动，直接呈现静态 `BrandMasterLogo` 或静态品牌状态图标。
- 所有循环 `TimelineView` 均绑定 `appearsActive` 与状态开关（`paused: !animate`），窗口隐藏、失焦、视图卸载或任务结束时自动暂停，避免无效 CPU/GPU 消耗。
- 所有动画默认静音；装饰图层设置 `.accessibilityHidden(true)`，不干扰 VoiceOver 与键盘操作。
