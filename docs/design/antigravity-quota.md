# Codex 与 Antigravity 额度

## 入口与展示

全局状态栏横跨窗口底部。左侧提供设置、会话用量和升级入口，右侧展示本机 CLI 账号额度。窄窗把第二个额度入口收进溢出菜单。

- Codex 随状态栏加载。Antigravity 可在「设置 → 通用 → 额度」开启，默认关闭。关闭时隐藏入口并取消该来源的在途查询。
- 摘要取该服务各个有效窗口中的最低剩余比例。极小的正值显示「<1%」，明确耗尽显示「0%」，未知或过期显示「—」。余量不高于 25% 时警示，不高于 10% 时显示为严重。详情展示各窗口的余量、重置时间和同步时间，可独立刷新。
- 账户额度使用本机 CLI 的登录态。对话的 Token、上下文占用和费用仍在会话用量中展示。

[全局状态栏](../../Zivvi/Features/Workbench/GlobalStatusBar.swift) · [额度设置](../../Zivvi/Features/Settings/SettingsPanel.swift)

## 读取与更新

- Codex 通过本机 CLI 读取账号额度。状态栏加载、窗口回到前台或用户手动刷新时查询，自动查询跳过仍有效的缓存。
- Antigravity 在窗口处于前台且开关开启时查询。客户端检查 CLI 版本，再执行 `agy -p /usage --output-format json`。解析使用 `command.data.groups[].buckets[]`，接收 0–1 的有效余量。Antigravity 快照最多保留 10 分钟，窗口提前重置时以重置时间为准。后台、关闭开关和工具路径变化都会取消旧查询。
- 缺少 CLI、登录态异常、版本不支持或查询失败时，按可用信息展示对应状态。过期窗口不参与摘要。

[Codex 客户端](../../Zivvi/Services/CodexQuotaClient.swift) · [Antigravity 客户端](../../Zivvi/Services/AntigravityQuotaClient.swift)

## 验证

用合成输入核对解析、过期、多窗口摘要、零额度和不足 1% 的显示。原生验证覆盖宽窄窗口、设置切换、刷新、键盘和 VoiceOver，按项目规范单独确认授权。真实 CLI 响应需通过对应本机账号验证。

2026-11-24 的 r03 记录了旧侧栏方案，可在 Git 历史中查阅。
