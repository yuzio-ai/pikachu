# 应用主图标与品牌母版（Master Logo & AppIcon）

当前唯一已批准的品牌主标识为四生命体 2D 闪电 Logo（**Many minds. One spark.**）。

## 1. 唯一母版与派生资产

| 文件 / 资产 | 规格 | 用途与约束 |
| --- | --- | --- |
| [master-logo-original.png](master-logo-original.png) | `1254 × 1254 px` 原始 PNG（SHA-256 `f9165d9dc8db2aa48be53fd803900b6cf4e1ba59a7af105241e30a860de2a56a`） | 不可变原始基准；不重画、不更改生命体数量/眼神/原色/能量线。直接作为 `AppIcon.appiconset` 源图。 |
| `Assets.xcassets/BrandMasterLogo.imageset` | `759 × 830 px` 透明 PNG（已对半透明边缘执行 `#FAF9F7` 去白边净化） | UI 静息定格与深浅外观透明底展示基准；不拉伸、不裁切闪电尾与外围能量线。 |
| `Assets.xcassets/BrandLayer*.imageset`（6 组） | 共用 `759 × 830 px` 透明画布（`AgentTop/Main/Left/Bottom`、`EnergyRays/Trail`，同样已去白边净化） | 仅用于原生 SwiftUI 动效过渡帧；所有动效定格后切回 `BrandMasterLogo`。 |
| `Assets.xcassets/AppIcon.appiconset` | `16/32/64/128/256/512/1024 px` PNG | 由 `master-logo-original.png` 等比高质量重采样生成，无嵌入文字，适配 macOS Dock/Finder 图标遮罩。 |
| `Assets.xcassets/SidebarBrandMark.imageset` | `128 × 128 px` 透明方形居中 PNG | 标题栏 16 pt 品牌标记；菜单栏状态图标在极小单色模板场景改用简化矢量 `lightning_brand_agent`。 |

## 2. 矢量化与合规说明

- 当前分层 PNG 为人工近似切分原型，正式生产如后续升级精确矢量母版，须严格保持原图形、眼睛神态、原色与能量线，并经视觉对比验收后替换。
- 正式产品名称已确立为 **Zivvi**（Bundle ID `ai.yuzio.zivvi`）；本图标不含产品文字。公开发布前需另行完成商标与知识产权检索。
