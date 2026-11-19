# Pikachu macOS 主图标

用户于 2026-11-18 选定两张附件中的第一张，作为 Pikachu macOS 主图标的设计方向。以下参考图保留用户提供的原始 PNG。

![选定的 Pikachu 主图标参考图](reference.png)

## 制作要求

- 保留由倾斜环带和长闪电构成的 **P**。环带围出字腔，左下的长尖端构成字干。缩小预览时保留尖端长度和闪电折角。
- 环带上半部以金黄为主，经橙粉过渡到右下的紫色。保留深色底和标记周围的局部光晕。方形 AppIcon 源图将深色底铺到画布边缘，圆角由 macOS 的图标遮罩生成。[Apple 图标规范](https://developer.apple.com/design/human-interface-guidelines/app-icons)
- 图标内的金紫配色按参考图处理。应用界面的品牌强调色沿用[项目视觉方向](../../../DESIGN.md#45-视觉方向)。

## 制作与验证

- [方形 AppIcon 源图](pikachu-appicon-square-1024.png)为 1024 × 1024 px 的不透明 PNG，背景铺满画布。
- [独立展示图](pikachu-logo-1024.png)为 1024 × 1024 px 的 sRGB PNG，带深色圆角底，底板外透明。

`python3 Scripts/build-app.py` 从方形源图生成各尺寸，编译成 `AppIcon` 并写入 `dist/Pikachu.app`。签名校验成功后更新应用包目录的修改时间。已验证包内资源和注册字段。用户确认 Dock 显示了新图标，刷新应用包目录的修改时间后，Finder 也显示了新图标。

来源为用户同轮附件 `codex-clipboard-356cadb2-5f0f-4006-af36-bc29bfc35069.png`。选择由用户确认，本文由 Codex 整理。Vistra 0.1.5，产物契约 1。
