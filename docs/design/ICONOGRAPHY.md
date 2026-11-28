# 图标系统规范（Iconography）

本规范定义应用自有图标的网格、描边、颜色令牌、两类图标映射边界、RTL 镜像、无障碍与新增流程。

## 1. 网格、描边与颜色令牌

| 属性 | 规范值 | 实现位置 |
| --- | --- | --- |
| ViewBox | `0 0 24 24` | `Zivvi/Resources/LightningIcons.xcassets`、`LightningBrandIcons.xcassets` |
| 基准描边 | `1.65 pt`，`round` lineCap / lineJoin | 全部矢量 SVG 源资产 |
| 渲染模式 | 单色 `template` + 主题 tint | `LightningIconView`、`LightningBrandIconView` |
| 概念品牌黄 (`brandYellow`) | `#FFCC00`（主 Logo 原图不重新着色） | `ZivviTheme.brandYellow` |
| 图标黄 · 浅色 (`iconYellow.light`) | `#A87900` | `ZivviTheme.iconYellow` |
| 图标黄 · 深色 (`iconYellow.dark`) | `#FFD22B` | `ZivviTheme.iconYellow` |
| 默认 / 紧凑 / 工具栏尺寸 | `16 pt` / `12–14 pt` / `16–20 pt` | 按场景匹配，点击区保持原规范 |

- **禁止**在业务页面硬编码独立黄/灰色值；统一引用 `ZivviTheme.iconYellow`。
- **对比度与状态**：默认主题黄，禁用态通过环境 `isEnabled` 自动降至 45% 不透明度；hover/selected 由外层 `FlatControlButtonStyle` 与状态结构传达。禁止黄底黄字：在 `#FFCC00` 实底按钮（如启用态发送按钮）上使用 `ZivviTheme.brandBadgeText`（`#222222`）。
- **状态语义**：成功、失败与告警图标同样保持统一黄色，通过图标形态（勾、三角、圆叉）与相邻语义色文字及操作按钮区分状态。

## 2. 两类资产与使用优先级

1. **83 项功能图标（`LightningIcon` / `lightning_` 前缀）**：与原应用使用的 83 个 SF Symbols 一对一映射，覆盖箭头导航（15）、折叠箭头（5）、编辑操作（15）、面板与工具栏（12）、文件媒体代码（11）、状态与告警（25）。定义见 [LightningIcons.swift](../../Zivvi/DesignSystem/LightningIcons.swift)。
2. **21 项品牌专属图标（`LightningBrandIcon` / `lightning_brand_` 前缀）**：独立于 83 项映射，专用于明确的品牌与 Agent 编排语境，不与普通功能图标重复堆叠在同一控件上：
   - `new-session`：侧栏项目级新建会话入口、对话标签栏新建会话按钮
   - `send` / `stop`：输入区主发送（黄底深墨）与停止按钮
   - `agent` / `multi-agent` / `active`：单 Agent 响应头与菜单栏图标、多会话并行运行标识、执行流状态
   - `complete` / `error` / `approval` / `pause`：响应头与错误块的真实状态语义标识
   - `steer` / `queue`：输入区运行中发送方式切换胶囊（中途调整 / 排队执行）
   - `sessions` / `files`：左侧项目导航器 `S / F` 切换与设置侧栏项目页
   - `settings` / `energy` / `context` / `model`：全局状态栏（设置 / 仪表盘）、用量面板累计词元、设置侧栏智能体页
   - `retry` / `tools` / `activity`：已纳入独立 `LightningBrandIcons.xcassets` 供重试、工具与活动面板按需调用

## 3. 保留原有工具与自定义画布图标

- 既有的 6 个工具调用 SVG（`ToolCallIcon`）与 3 个 Git/文件画布图标（`GitBranchIcon`、`GitCommitIcon`、`FileTextIcon`）及 `IconButtonLabel(assetName:)` 保持原几何造型，统一使用 `ZivviTheme.iconYellow` 着色。

## 4. 平台与第三方例外（不强制改黄）

- macOS 原生红黄绿窗口控制按钮与系统菜单栏 Chrome
- 通过 `NSWorkspace.shared.icon(forFile:)` 获取的外部应用真实图标（Finder、编辑器等；无已安装应用时回退到黄色 `LightningIcon`）
- 第三方模型与智能体服务商 Logo（`ProviderLogos/`、`ACPAgentLogos/`、`AntigravityAgentLogo`；无匹配时回退到黄色 `LightningIcon.cpu`）

## 5. RTL 镜像与无障碍

- 仅语义方向图标 `chevron.forward`（`lightning_chevron_forward`）与 `arrow.up.forward.square`（`lightning_arrow_up_forward_square`）在 `layoutDirection == .rightToLeft` 时水平镜像；显式 `left`/`right` 符号不翻转。
- `LightningIconView` 与 `LightningBrandIconView` 默认 `.accessibilityHidden(true)`；父按钮必须提供语义化 `.accessibilityLabel` 与 `.help`。独立传达状态的图标（如任务勾选框、文件变更类型、收藏星标）显式恢复可访问性标签。

## 6. 新增图标流程

1. 按 24 × 24 网格、1.65 pt round 描边产出纯单色模板 SVG。
2. 归类判断：通用功能加入 `LightningIcons.xcassets`（`lightning_<name>`）与 `LightningIcon` 枚举；品牌编排专属加入 `LightningBrandIcons.xcassets`（`lightning_brand_<name>`）与 `LightningBrandIcon` 枚举。
3. 配置 `Contents.json` 为 `preserves-vector-representation: true` 与 `template-rendering-intent: "template"`。
4. 运行 `BrandSystemTests` 验证全部资产加载与唯一命名。
