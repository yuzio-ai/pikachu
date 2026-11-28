# Zivvi 设计令牌

## 平铺布局

平铺布局是 Zivvi 现代极简风格的基础，适用于工作台、对话、设置、检查器、列表和浮层内容。

- 同一界面层的连续内容与普通分组直接铺在共用底色上，省去额外的卡片底色、圆角、描边和阴影。工作台与应用面板的颜色见[页面底色](#页面底色)。
- 用标题、对齐、稳定的行间节奏和组间留白建立层级。需要区分相邻区域或分组时，使用 `ZivviTheme.subtleDivider` 或现有的面板分隔线。
- 输入框、按钮、消息和状态反馈沿用各自的组件样式。菜单、预览和模态面板使用表达前景层级所需的轮廓和表面，内部普通分组继续平铺。

[工作台与应用面板统一底色](docs/design/workbench-unified-background.md) · [智能体设置定稿](docs/design/provider-settings.md#视觉规范)

### 设置行与分组

| 用途 | 令牌 | 间距 |
| --- | --- | --- |
| 通用、项目和已归档的常规设置行 | `dialogItemGap` | 行内上下各留 8 pt。 |
| 分组标题与说明 | `dialogLabelGap` | 相邻内容间隔 4 pt。 |
| 通用、项目和已归档的独立分组 | `dialogSectionGap` | 组间距为 16 pt。 |
| 智能体的连接状态、模型和高级设置 | `dialogItemGap` | 主要分隔线两侧各留 8 pt。 |

[设置分组与交互设计](docs/design/settings-organization.md#共用视觉规范) · [间距定义](Zivvi/DesignSystem/ZivviTheme.swift)

## 对话框间距

确认对话框与审批等应用内 sheet 按内容关系使用同一组垂直间距。标题与说明合为一组，再排列正文、表单和操作区。普通分组直接铺在面板底色上。布局代码直接引用 `ZivviSpacing` 中对应的令牌。

| 用途 | 令牌 | 值 |
| --- | --- | ---: |
| 标签与对应正文 | `dialogLabelGap` | 4 pt |
| 标题与说明、同一组内的相邻内容 | `dialogItemGap` | 8 pt |
| 标题区、正文区和独立内容分组之间 | `dialogSectionGap` | 16 pt |
| 嵌入面板的内容内边距 | `contentInset` | 12 pt |

确认弹窗的多行正文在系统字体行高基础上增加 3 pt 行距。 [确认弹窗](Zivvi/DesignSystem/FlatConfirmation.swift)

[间距定义](Zivvi/DesignSystem/ZivviTheme.swift)

## 阅读列与消息组

| 用途 | 值与适用边界 |
| --- | --- |
| 阅读列 | 最大 800 pt，最少两侧各 24 pt。用户、助手与 Composer 共用。 |
| 消息组 | 用户消息气泡上方及新轮次（未紧随用户消息）的组间总距 32 pt（首组沿用视口边距），紧随用户消息操作栏后补充至 16 pt。常规事件行各有上下 3 pt 内边距，行间 4 pt。组边界只补差额。 |
| 用户正文 | 已接受或已处理的消息使用 `ZivviTheme.userMessageSurface`（浅色 `#EEEEEE`、深色 `#303030`）按内容自适应宽度（Fit Content）的连续 12 pt 圆角气泡，外框与助手正文共用阅读列左缘，内部正文保持左对齐；横向 16 pt、顶部 16–17 pt（避让悬浮徽标）、底部 13 pt 留白，常规对比度下无描边和阴影，提高对比度模式下保留 1 pt `ZivviTheme.border` 轮廓；最小宽度 72 pt（随大字号适配以容纳徽标），最大宽度与当前阅读列一致（宽屏上限 800 pt），不通过缩小正文字号适应宽度。待确认、排队等无底色状态同步左对齐以避免状态切换跳动；队列提示与悬停操作栏左对齐并预留页脚位置。交接「上次请求」共用 `userMessageSurface`，无悬浮徽标，使用纵向 12 pt 留白。 |
| 功能内容内边距 | 浮层、Composer 和反馈面板中相同用途的内边距共用 12 pt。Composer 圆角 14 pt。 |
| 普通分隔线 | 一物理像素，随当前窗口显示倍率更新。输入焦点、功能轮廓和可拖拽边界各使用自身尺寸。 |
| Diff | 添加使用 `diffAddition`（浅色 `#226B51`，深色 `#7AC9A6`），删除使用 `diffDeletion`（浅色 `#AC343F`，深色 `#F38E97`）。保留增减符号。 |
| 系统偏好 | 拖拽边界保留 9 pt 热区和 2 pt 高亮。减少动态效果下直接切换。明暗、非活动选中和辅助功能需用真实窗口核对。 |

标准档 `callout` 为 13 pt，`body` 为 14 pt。设置分组标题使用 `headline`（14 pt），设置页标题使用 `title3`（16 pt）。界面保留四档字号和系统中文回退。 [字号定义](Zivvi/DesignSystem/ZivviTypography.swift)

聊天回复的 Markdown 使用 Conversation，文件格式预览使用 Editorial。标准档正文均为 14 pt，目标行高分别为 22 pt 和 23 pt。两处共用元素语义和主题颜色。标题、代码、块间距和窄栏参数由排版实现统一解析。 [Markdown 排版规格](docs/design/markdown-rendering/typography-profiles.md) · [排版实现](Zivvi/DesignSystem/MarkdownStyle.swift)

## 品牌交互语言

品牌核心理念为 **Many minds. One spark.**（签名发声：`Zip. Zap. Zing.`）。界面采用统一的 Z 开头拟声词表达任务生命节律，同时在审批、输入、暂停、停止、排队、介入与错误详情中保持真实功能语义。拟声词跨语言原样保留，仅在 UI 表示层渲染，不进入草稿、提交内容、复制文本、协议或历史数据。[品牌词定义](Zivvi/DesignSystem/BrandCopy.swift)

| 场景 | 固定词 | 呈现 |
| --- | --- | --- |
| 冷启动 | 无文字 | 非阻塞单次 800 ms 四生命体汇聚动效，静息定格为母版透明 Logo；不阻塞窗口加载与交互。 |
| 新会话欢迎页 | `Ready to Zip?` | 居中展示 104 pt 宽四生命体母版 Logo（支持 5 s 低频 `Alive` 呼吸，输入或聚焦时收敛静态）与系统字体 `hero` Semibold 标题，不添加额外副标题或宣传卡片。 |
| 输入框占位 | 无角色前缀 | 前置 `lightning_brand_agent` 黄色品牌 glyph + 本地化提示「告诉我你想实现什么…」／`Tell me what you'd like to build…`。 |
| 用户消息 | `Zip!` | `.accepted`、`.handled` 及历史投影中已接受的用户消息。悬浮品牌徽标始终相对于用户消息气泡左上角定位，垂直中心对齐气泡顶边，距气泡左侧 14 pt。使用 `brandYellow`（`#FFCC00`）背景、`brandBadgeText`（`#222222`）文字、`caption` Semibold Italic，高度 22–24 pt、连续圆角 7 pt，外加 2.5 pt `pageBackground` 隔离描边；仅作标识、不参与正文布局流。 |
| Agent 开始 | `Zap!` | 真实 `.runStarted` 初始阶段（首 0.8 s 内、输出/思考到达前）短暂展示，不增加额外消息行。 |
| Agent 执行中 | `Zap…` | 同一响应头持续执行（运行中／思考中／流式输出中）；使用省略号字符 `…`（U+2026），搭配 1800 ms `Flow` 品牌能量图标与实时耗时。 |
| Subagent 完成 | `Zing!` | 预留用于真实 Subagent 子任务成功终态，保留具体 Agent 名称与结果；子任务失败不得误标为 `Zing!`。 |
| 整体任务完成 | `Zzzap!` | 主任务真实完成；搭配 `lightning_brand_complete` 图标与单次 450 ms `Discharge` 释放动效（按 `turn.id` 去重，历史回放与切换会话不重播）。 |
| 执行异常 | `Zzzzt…` | 真实失败终态；搭配 `lightning_brand_error` 图标、单次 ≤220 ms 能量中断过渡及可操作错误详情块（切换模型／设置／安全重试）。 |
| 等待审批 / 输入 / 暂停 / 停止 / 待核实 / 历史未记录 | 无拟声词 | 展示真实本地化语义（「等待审批」「等待输入」「已暂停」「已停止」「待核实」「历史结果未记录」），停止运行循环，不播放完成或失败动效。 |

- 颜色令牌：`brandYellow` = `#FFCC00`（`lightningYellow` 别名指向此令牌），`iconYellow.light` = `#A87900`，`iconYellow.dark` = `#FFD22B`，`iconYellowHoverSurface` = `iconYellow.opacity(0.10)`，`iconYellowSelectedSurface` = `iconYellow.opacity(0.16)`，`userMessageSurface` = 浅色 `#EEEEEE`／深色 `#303030`。
- 避让黄底黄字：发送按钮启用态在 `#FFCC00` 实底上使用 `#222222`（`brandBadgeText`）前景图标；禁用态在 `mutedSurface` 上使用降透明度 `iconYellow`。
- VoiceOver 读取语义化角色、本地化状态名称（如「智能体正在执行」「智能体执行完成」「智能体执行失败」「智能体正在等待审批」）与可读取耗时值，不让 VoiceOver 只读拟声词。装饰性 Logo 与动画图层对辅助功能隐藏。

[图标规范](docs/design/ICONOGRAPHY.md) · [动效规范](docs/design/MOTION.md) · [会话工作区](docs/design/session-detail-ui-v5.md) · [运行时间线](docs/design/session-run-timeline.md)

## 图标

应用自有图标统一采用 24 × 24 网格、1.65 pt 描边（round cap/join）、模板渲染 + `ZivviTheme.iconYellow` 着色。分为 83 个一对一功能图标（`LightningIcons.xcassets`，`lightning_` 前缀）与 21 个品牌专属图标（`LightningBrandIcons.xcassets`，`lightning_brand_` 前缀）。原生 macOS 红黄绿窗口按钮、系统菜单与第三方服务商 Logo 保留平台/品牌原色。完整映射、RTL 镜像与新增流程见[图标规范](docs/design/ICONOGRAPHY.md)。

### 尺寸与点击区域

| 用途 | 默认尺寸 | 紧凑／默认／较大／超大 | 点击区域或容器 | 适用位置 |
|---|---:|---|---|---|
| 展开指示 | 8 pt | 8／8／8／8 pt | 单箭头随整行点击。双箭头按钮为 26 × 26 pt | 侧栏「已处理」、文件夹、工具调用、用量明细、设置下拉、全部展开／收起 |
| 行内辅助 | 11.5 pt | 10／11.5／12.5／13.5 pt（`caption`） | 使用所在行或现有行内按钮的点击区域 | 文件状态、选中勾、时钟、附件标记、行内复制、编辑和移除 |
| 独立操作 | 13 pt | 12／13／14／15 pt（`callout`） | 常规纯图标按钮为 26 × 26 pt。发送和停止按钮边长为 28／28／30／32 pt | 搜索、筛选、新建、刷新、更多、面板关闭、发送和停止 |
| 空状态主图标 | 18 pt | 17／18／19／20 pt（`title2`） | 底框为 42 × 42 pt | 无项目、新会话和启动失败 |
| 品牌与状态 | 按组件 | 见下表 | 使用组件自身的框和点击区域 | 服务商 Logo、Zivvi 品牌标记、状态点和用量环 |

### 品牌与状态

| 组件 | 尺寸 |
|---|---|
| 服务商 Logo | 13 × 13 pt 渲染框。保留原始比例，校准透明留白，使可见标记在同一行内视觉均衡。方形和粗笔画标记用 12 pt，宽扁、细笔画或细节密集的标记（Gemini、DeepSeek、Qwen）占满 13 pt 渲染框。位图按大于或等于渲染尺寸的 2 倍出图，避免下行抽样后细笔画发糊。 |
| 标题栏 Zivvi 品牌标记 | 16 × 16 pt 渲染框。 |
| 状态点 | 待处理会话卡片、后台执行和提醒为 6 pt。消息发送等待点每颗 3 pt。会话状态位置见[运行时间线](docs/design/session-run-timeline.md#顶栏与会话卡片)。 |
| 加载环 | `mini` 为 12 pt，`small` 为 14 pt，其余为 16 pt。 |
| 输入区上下文用量环 | 紧凑／默认／较大／超大分别为 14／14／15／16 pt。 |

### 使用规则

- 按动作归类。文件和图片附件的叉号属于行内移除。设置面板的叉号属于独立关闭。
- 复用项目的字号档位。品牌与状态组件按各自的尺寸规则绘制。
- 工具调用 SVG 与同行的文件、状态图标对照实际轮廓和线宽。调整画布尺寸前先校准图形留白。
- 独立图标按钮提供可读的操作名称。折叠控件向辅助功能报告展开或收起状态。

[字号与输入区按钮定义](Zivvi/DesignSystem/ZivviTypography.swift) · [图标与服务商标记定义](Zivvi/DesignSystem/SymbolIcons.swift) · [品牌资源](docs/design/app-icon/README.md)

## 鼠标悬停

| 类型 | 统一规则 | 典型位置 |
|---|---|---|
| 控件反馈 | 立即反馈，不改变尺寸。常规控件使用中性底色；图片和已有专用底色的按钮用轻量叠色；高密度工具调用行和消息导航标记只强调前景。禁用控件不产生悬停高亮，已选中／已打开的状态不会被普通悬停色覆盖。 | 工具栏、菜单项、工具调用行、会话卡片、图片缩略图、发送和停止 |
| 面板边界 | 悬停或拖拽可调宽度边界时，立即切换水平调整指针并将分隔线高亮为 2 pt 中性强调色，不改变相邻面板布局尺寸。 | 左侧会话栏边界、右侧编辑区边界 |
| 行内操作显隐 | 悬停或相关键盘焦点立即显示；弹出菜单打开或复制反馈期间按需保留。预留操作位置，隐藏时不拦截鼠标点击。 | 侧栏提醒和处理、消息编辑和复制、图片移除、失败提示关闭、会话标题箭头 |
| 富预览 | 停留 500 ms 后展示；移出、滚动预览所在列表、激活预览锚点或窗口失焦时取消等待并立即收起。切换会话时重置消息导航的悬停状态；预览不接收点击或焦点。视觉样式见下方「锚定浮层」。 | 侧栏会话详情、消息导航摘要 |
| 系统提示 | 短标签、快捷键、完整路径和时间使用原生 `.help`，延时与外观交给 macOS。 | 图标按钮、截断路径、状态点、时间 |

悬停可以补充说明或显示快捷操作，但不应成为访问主要操作的唯一途径。

## 选中、打开和焦点

- 工具栏文字按钮标准档高 28 pt，左右各留 8 pt，圆角 8 pt。高度跟随输入栏的字号档位。图标按钮沿用图标表的点击区域。
- 按钮底色优先级依次为按下、浮层打开、当前选中、悬停、常态。键盘焦点独立使用 1 pt 描边。状态变化沿用同一布局和点击区域。
- 工具栏开关和选中行使用中性浅底。分段控件的选中滑块使用面板底色和细描边。菜单的当前选项使用浅底与勾选。文件树的当前文件保持浅底，方向键移动的位置使用焦点描边。
- 同类导航项复用选中令牌。智能体设置的栏目和标签沿用工作台会话卡片的 `ZivviTheme.selected`，「新会话默认」标记单独表达默认状态。
- 应用窗口的菜单沿用锚定浮层、共用菜单行及选中样式。菜单栏继续使用系统样式。

## 锚定浮层

锚定浮层使用 8 pt 圆角和 12 pt 内容留白，标题使用 `callout` 中等字重。功能浮层使用页面底色，纯选项菜单与悬停预览使用原有面板底色。纯选项菜单用 6 pt 留白，复杂表单和分组保留适合自身内容的宽度和间距。 [列表行距](#列表行距)

悬停预览不接收点击或焦点，使用自绘细边框。可交互浮层沿用原生 popover，由系统处理指向、外轮廓和阴影，内容层不叠画边框。系统工具提示、对话框和 sheet 不用这套样式。

[锚定卡片定义](Zivvi/DesignSystem/ZivviTheme.swift)

## 列表行距

| 组件 | 垂直尺寸 |
| --- | --- |
| 纯选项菜单 | 相邻项间隔 3 pt。 |
| 锚定浮层 | 常规信息行间隔 7 pt。 |
| 文件树 | 条目最小行高 25 pt，行后留 1 pt。 |
| 会话侧栏 | 待处理行间隔 8 pt，已处理行间隔 4 pt。 |

[菜单行](Zivvi/DesignSystem/FlatMenu.swift) · [文件树](Zivvi/Features/Sessions/ProjectNavigatorFilesView.swift) · [会话侧栏](Zivvi/Features/Sessions/SessionSidebar.swift)

## 页面底色

工作台、设置和应用内功能面板共用不透明的页面底色 `ZivviTheme.pageBackground`，浅色为 sRGB `#F4F4F4`，深色为 sRGB `#202020`。SwiftUI 内容与 AppKit 窗口使用同一颜色定义。 [统一底色设计](docs/design/workbench-unified-background.md)

## 工作台 2.0 布局与功能组件尺寸

| 组件 | 尺寸与约束 | 适用说明 |
| --- | --- | --- |
| 原生标题栏 | 高度随 macOS 原生标准 | 左侧承载 Zivvi 品牌和侧栏切换，右侧承载并排的会话与编辑区标签组。 |
| 左侧项目导航器 | 最小宽度 `220 pt`；窄于 `205 pt` 时 `S/F/G` 折叠为紧凑菜单 | 按项目分组；每组右侧为 `S/F/G` 图标切换器（`20 × 20 pt`）与项目级 `+` 新建会话；底部汇总「已完成」并保留项目徽标。 |
| 双标签页栏（Conversation / Editor） | 高度随字号使用 `titlebarControlHeight`；连续圆角 `6 pt`，会话标签宽 `88–200 pt`，编辑区标签宽 `88–210 pt` | 底部使用 `1 px` `ZivviTheme.subtleDivider`；关闭按钮与脏标记（实心圆点 `6 pt`）预留固定槽位，避免悬停抖动；会话组尾部使用 `12 pt` 渐隐。各组超过 4 个标签时提供标签列表菜单。 |
| 右侧编辑区 | 默认占主内容区宽度的 `45%`，最小 `360 pt`，为对话保留至少 `420 pt` 与 `1 pt` 分隔线；上下文条最小高 `32 pt` | Markdown 默认以 Editorial 预览打开，支持 `预览 \| 编辑` 切换；编辑保存前执行 `ProjectFileRevision` 哈希校验，外部冲突展示顶部 `warningSurface` 非破坏性冲突条。 |
| 全局状态栏（Global Status Bar） | 全宽锚定窗口底部，固定高度 `28 pt`；顶部 `1 px` `subtleDivider` | 左侧承载「设置 / 仪表盘 / 升级」（宽 `< 680 pt` 降级为纯图标）；右侧展示真实模型配额（Codex、Antigravity）最低剩余窗口百分比与 `38 × 4 pt` 进度条（`≤ 25%` 警示黄，`≤ 10%` 红色）。 |
| 渐进式 Markdown 语义骨架 | 解析合并窗口 `140 ms`；骨架延后呈现 `300 ms`；条高 `12 pt`、圆角 `4 pt` | 仅用于流式尾部未闭合块（Text / List / Code / Table），采用静态低对比 `mutedSurface` / `border`，禁止闪烁与跑马灯；流结束或中断立即清空。 |
| 自适应输入停靠区与提示栈 | 正常垂直流位于滚动对话区下方；提示区上限 `max(84, viewport × 25%)`，编辑区上限 `max(80, viewport × 30%)` | 无提示时提示栈高度为 `0`；可点击整行使用 `mutedSurface` 圆角 `6 pt` + 常驻右箭头 `chevron.right`；显式操作行使用 `FlatControlButtonStyle(.outlined)` 尾部按钮。 |
| 工具调用行与结构化错误块 | 工具行最小高 `24 pt`，悬停呈现中性 `controlHover` 底色；结构化错误块平铺于阅读列内 | 工具行遵循「摘要优先」并预留右侧展开指示槽位；结构化错误块包含语义标题、自然语言说明、重置时间提示、安全恢复按钮与默认折叠的 `Provider Response`（支持复制）。 |
