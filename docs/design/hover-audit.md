# 鼠标悬停代码审查

依据：[Pikachu 设计令牌 · 鼠标悬停](../../DESIGN_TOKEN.md#鼠标悬停)。范围包括工作台、侧栏、输入区、附件、对话、设置、用量、设计系统共享组件和 AppKit 菜单／工具栏。按钮是否合规按实际生效的样式判断，也检查了父容器继承的 `.buttonStyle`。

下表是审查时的发现与整改方案。已实施代码整改；桌面确认项仍保留，不按已复现缺陷处理。

## 已实施的整改

| 优先级 | 类别与位置 | 现状 | 建议 |
|---|---|---|---|
| P1 | 富预览 · [对话消息导航](../../Pikachu/Features/Transcript/TranscriptView.swift#L190) | 已使用 500 ms 延时，但仅在移出或标记销毁时清理。滚动不会主动取消延时；点击跳转也未清掉预览。懒加载标记可能仍存在，不能把销毁当作滚动退出。侧栏已有点按、滚动、窗口失焦时取消的逻辑。 | 先统一取消规则：移出、滚动、点击、切会话或窗口失焦时取消 pending task 并收起；再统一延时状态管理。侧栏继续使用 AppKit 面板，消息导航继续用就地浮层，不必合并渲染实现。 |
| P1 | 行内操作 · [输入区失败提示](../../Pikachu/Features/Composer/ComposerView.swift#L76) | 整个提示在 `panelsBlocked` 时被禁用，但叉号是否显示只看 hover 或焦点，因此禁用时仍可能出现一个不可用的叉号。主按钮拿到键盘焦点时也不会显示叉号，只在叉号自己获得焦点时才显示。 | 用同一组焦点状态覆盖主按钮和叉号；禁用时不揭示操作。保留固定留白，验证 Tab 能到达叉号，并通过可访问性显式提供关闭动作。 |
| P2 | 控件反馈 · [扩展交互选项](../../Pikachu/Features/Composer/InteractionView.swift#L867) | 把“已选中”当成 `.prominent` 主操作。它悬停时会从 `selected` 切到 `prominentControlHover`，而项目、模型等选项都用 `isOpen: selected` 保留选中底色。 | 改为 `FlatControlButtonStyle(isOpen: selected)`，保留勾选和键盘方向键。若还要保留选中描边，给样式增加独立选中配置，不复用主操作语义。 |
| P2 | 控件反馈 · [运行环境、受信扩展、环境变量](../../Pikachu/Features/Settings/SettingsPanel.swift#L741) | “选择 Pi”“添加工具目录”“添加信任的扩展”“移除扩展”“添加变量”“显示／遮蔽变量值”“重试读取环境变量”未指定或继承 `FlatControlButtonStyle`，与同行的移除目录、保存变量等动作混用系统默认按钮。 | 普通浏览、添加和重试统一用 `.outlined`；行内移除和显示切换用 `.quiet`，保存保留 `.prominent`。切换项如需表达持续开启状态，应单独传状态。 |
| P2 | 控件反馈 · [工作树浮层](../../Pikachu/Features/Composer/ComposerWorkingDirectoryButton.swift#L129)、[会话重命名](../../Pikachu/Features/Workbench/WorkbenchView.swift#L835) | 复核发现，工作树的“新建”“返回”“创建并选择”已继承整板 `.outlined` 样式，但创建没有主操作强调。重命名的“取消”“保存”没有继承菜单列表的样式。 | 保留工作树的默认描边样式，在重命名编辑页补上默认样式，创建／保存显式用 `.prominent`。保留动作角色、键盘快捷键和禁用条件。 |
| P2 | 控件反馈 · [模型可见性开关](../../Pikachu/Features/Settings/ModelSettingsView.swift#L150) | 使用原生 `.switch`，同一设置面板的通知和项目配置开关用 `FlatToggleStyle`，后者有自定义行级 hover。 | 给 `FlatToggleStyle` 增加紧凑、仅开关的用法，不在模型行插入全宽 `Spacer`；继续保留模型专属辅助功能标签。若产品决定保留原生开关，应在令牌中显式声明例外。 |
| P3 | 系统提示 · [附件移除](../../Pikachu/Features/Attachments/ImageAttachmentThumbnail.swift#L149) | 图片移除叉号只有辅助功能标签，外层提示为文件路径，不说明叉号动作。 | 给叉号加本地化的 `.help`（例如“移除附件”），缩略图区域保留原路径提示。 |

复审补修：消息导航独立记录指针下的标记；滚动时只取消预览，重新计算指针下的标记，滚动停止后对仍命中的标记重新等待 500 ms，不要求鼠标移出再移入。

## 需要在桌面上确认，不按已复现缺陷处理

- **工具栏提示**：[侧栏切换](../../Pikachu/Features/Workbench/WorkbenchTitlebar.swift#L205) 在 AppKit 工具栏项和 SwiftUI 按钮都注册了同文案提示，两层可能分别服务于不同位置。先核对普通、窄窗和溢出状态，再决定是否去掉重复来源。

- **键盘与行内操作**：[消息页脚](../../Pikachu/Features/Transcript/TranscriptView.swift#L152)、[附件移除](../../Pikachu/Features/Attachments/ImageAttachmentThumbnail.swift#L149) 的 `revealedAction` 保留控件节点，只显式关闭鼠标命中。实测全键盘访问下 Tab 能否到达初始隐藏的按钮，VoiceOver 是否出现重复动作；不要统一给隐藏按钮加 `.disabled` 或 `.accessibilityHidden(true)`，以免封死靠焦点显示的路径。侧栏已有选中按钮焦点触发和辅助功能备用动作，可用作对照。
- **富预览边界**：[消息导航](../../Pikachu/Features/Transcript/TranscriptView.swift#L212) 用固定 `106` pt 估计卡高。窄窗、超大字体和三行摘要应检查是否被裁掉或遮住输入区；复现后按实测卡高约束位置。[侧栏预览](../../Pikachu/Features/Sessions/SidebarHoverPanel.swift#L39) 在非活动窗口下不启动；核对窗口重新激活、指针没移动时是否应重新计时。
- **布局与交接**：在窄侧栏和不同字号下对照悬停前后的运行状态、项目文字和时间槽；从气泡、最后一段回复或文件变更行移向操作按钮，确认页脚不会误收起。检查缩略图与发送／停止按钮的叠色、明暗和禁用态。自绘滚动条保留系统滚动行为，不套用按钮样式。

## 不建议改动

- 工作台常规按钮、输入区配置、用量、确认弹窗和大多数设置按钮已使用共有样式；`FlatMenuPanel` 统一菜单行样式，`FlatDisclosureStyle` 统一普通展开行。
- 工具调用行、消息导航标记和会话卡片虽然用了 `.plain`，但有专用反馈，并非遗漏。发送／停止和可点击图片已用共享叠色样式。系统菜单栏、系统菜单、文件面板、原生 `.help`／AppKit `toolTip` 保持系统交互；不可点击的状态点或标签不应画出按钮反馈。
- 普通按钮无须全部显示工具提示；优先给只有图标、文本截断或需要补充快捷键的位置提供原生提示，避免大范围重复可见文字。

建议实施顺序：先修富预览取消逻辑和行内操作可达性，再统一遗漏的按钮样式与选中态，最后做提示和明暗／窄窗实测。验收应包含短停留不显示、长停留才显示、滚动／点击后不闪回、键盘可触发、隐藏时不能点中、布局不挪动。
