import SwiftUI
import OrchestrationCore

/// Full-width Global Status Bar anchored at the bottom of the Zivvi Workbench 2.0 window.
/// Left: Settings, Dashboard (session stats), Upgrade.
/// Right: Real connected model quota pools (Codex + Antigravity) with remaining progress bars.
struct GlobalStatusBar: View {
    let workspace: WorkspaceController
    let toolSearchPaths: [String]
    let showsAntigravityQuota: Bool
    let openSettings: () -> Void
    let toggleDashboard: () -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var barWidth: CGFloat = 1040

    // Quota states
    @State private var codexState = QuotaPoolState(id: "codex", provider: "Codex", providerKey: "openai-codex")
    @State private var antigravityState = QuotaPoolState(id: "antigravity", provider: "Antigravity", providerKey: "antigravity")
    @State private var openQuotaPopoverID: String?
    @State private var antigravityQuery: Task<Void, Never>?
    @State private var antigravityQueryID: UUID?

    // Release check state
    @State private var availableVersion: String?
    @State private var lastReleaseCheck: Date?
    @State private var checkingRelease = false
    @State private var releaseCheckFailed = false
    @State private var showsReleaseResult = false

    private var isCompact: Bool { barWidth < 680 }
    private var canQueryAntigravity: Bool { showsAntigravityQuota && scenePhase == .active }

    private var visibleQuotaPools: [QuotaPoolState] {
        var pools: [QuotaPoolState] = []
        if codexState.hasDataOrAttemptedAvailable { pools.append(codexState) }
        if showsAntigravityQuota { pools.append(antigravityState) }
        if pools.isEmpty {
            // Keep at least Codex entry accessible so user can inspect or refresh status.
            pools.append(codexState)
        }
        return pools
    }

    var body: some View {
        HStack(spacing: 12) {
            leftActions
            Spacer(minLength: 8)
            rightQuotas
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(ZivviTheme.pageBackground)
        .overlay(alignment: .top) {
            ZivviDivider(color: ZivviTheme.subtleDivider)
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { barWidth = $0 }
        .task {
            await refreshCodexQuota(force: false)
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            if lastReleaseCheck.map({ Date.now.timeIntervalSince($0) >= 6 * 60 * 60 }) ?? true {
                await checkRelease(showResult: false)
            }
            await refreshCodexQuota(force: false)
        }
        .onChange(of: canQueryAntigravity, initial: true) { _, enabled in
            if enabled { requestAntigravityQuota(force: false) }
            else { cancelAntigravityQuota() }
        }
        .onChange(of: showsAntigravityQuota) { _, enabled in
            guard !enabled else { return }
            cancelAntigravityQuota()
            if openQuotaPopoverID == antigravityState.id { openQuotaPopoverID = nil }
            antigravityState = QuotaPoolState(id: "antigravity", provider: "Antigravity", providerKey: "antigravity")
        }
        .onChange(of: toolSearchPaths) { _, _ in
            cancelAntigravityQuota()
            antigravityState = QuotaPoolState(id: "antigravity", provider: "Antigravity", providerKey: "antigravity")
            requestAntigravityQuota(force: false)
        }
        .onDisappear { cancelAntigravityQuota() }
        .accessibilityIdentifier("global-status-bar")
    }

    // MARK: - Left Actions

    private var leftActions: some View {
        HStack(spacing: 4) {
            statusBarButton(
                title: "设置",
                brandIcon: .settings,
                showsLabel: !isCompact,
                id: "status-bar-settings",
                action: openSettings
            )
            statusBarButton(
                title: "仪表盘",
                brandIcon: .energy,
                showsLabel: !isCompact,
                isSelected: workspace.usageExpanded,
                disabled: workspace.viewed == nil,
                helpText: workspace.viewed == nil ? String(localized: "打开会话后查看上下文与用量统计") : String(localized: "当前会话统计（⇧⌘U）"),
                id: "status-bar-dashboard",
                action: toggleDashboard
            )
            upgradeButton
        }
    }

    private func statusBarButton(
        title: LocalizedStringKey,
        brandIcon: LightningBrandIcon,
        showsLabel: Bool,
        isSelected: Bool = false,
        disabled: Bool = false,
        helpText: String? = nil,
        id: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                LightningBrandIconView(brandIcon, size: 13)
                if showsLabel {
                    Text(title)
                        .zivviFont(.caption2)
                }
            }
            .foregroundStyle(isSelected ? ZivviTheme.primaryText : ZivviTheme.secondaryText)
            .padding(.horizontal, 6)
            .frame(height: 22)
        }
        .buttonStyle(FlatControlButtonStyle(isSelected: isSelected, inset: false, cornerRadius: 5))
        .disabled(disabled)
        .help(helpText.map(Text.init) ?? Text(title))
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }

    private var upgradeButton: some View {
        let available = availableVersion != nil
        let hint: String = if let availableVersion {
            String(localized: "新版 \(availableVersion) 可用，点击前往发布页升级")
        } else if checkingRelease {
            String(localized: "正在检查应用更新…")
        } else {
            String(localized: "检查应用更新")
        }

        return Button {
            if available {
                openURL(ZivviReleaseCheck.releasePage)
            } else {
                Task { await checkRelease(showResult: true) }
            }
        } label: {
            HStack(spacing: 4) {
                LightningIconView(available ? .arrowUpCircleFill : .arrowUpCircle, size: 13)
                if !isCompact {
                    Text(available ? "有新版本" : "升级")
                        .zivviFont(.caption2, weight: available ? .medium : .regular)
                        .foregroundStyle(available ? ZivviTheme.primaryText : ZivviTheme.secondaryText)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
        }
        .buttonStyle(FlatControlButtonStyle(isOpen: showsReleaseResult, inset: false, cornerRadius: 5))
        .disabled(checkingRelease && !available)
        .help(hint)
        .accessibilityLabel("升级")
        .accessibilityValue(hint)
        .accessibilityIdentifier("app-upgrade")
        .popover(isPresented: $showsReleaseResult, arrowEdge: .top) {
            Text(releaseCheckFailed ? "暂时无法检查更新，请稍后重试。" : "当前已是最新版本。")
                .zivviFont(.callout)
                .anchoredPopoverCard(width: 225)
        }
    }

    // MARK: - Right Quotas

    private var rightQuotas: some View {
        let now = Date.now
        let allDeadlines = (codexState.windows + antigravityState.windows)
            .flatMap { [$0.resetAt, $0.expiresAt].compactMap { $0 } }
            .filter { $0 > now }
        return TimelineView(.explicit(Array(Set([now] + allDeadlines)).sorted())) { timeline in
            let pools = visibleQuotaPools
            if isCompact && pools.count > 1 {
                HStack(spacing: 10) {
                    quotaPill(for: pools[0], at: timeline.date)
                    FlatMenu(width: 240) {
                        HStack(spacing: 3) {
                            Text("+\(pools.count - 1)")
                                .zivviFont(.caption2, design: .monospaced)
                            LightningIconView(.chevronUp, size: 10)
                        }
                        .foregroundStyle(ZivviTheme.secondaryText)
                        .padding(.horizontal, 6)
                        .frame(height: 22)
                    } content: { select in
                        ForEach(pools.dropFirst()) { pool in
                            Button {
                                select { openQuotaPopoverID = pool.id }
                            } label: {
                                let metric = pool.metric(at: timeline.date)
                                FlatMenuRow(title: Text(verbatim: "\(pool.provider) · \(metric.displayValue)"))
                            }
                        }
                    }
                }
            } else {
                HStack(spacing: 16) {
                    ForEach(pools) { pool in
                        quotaPill(for: pool, at: timeline.date)
                    }
                }
            }
        }
    }

    private func quotaPill(for pool: QuotaPoolState, at date: Date) -> some View {
        let metric = pool.metric(at: date)
        let isOpen = Binding<Bool>(
            get: { openQuotaPopoverID == pool.id },
            set: { open in
                openQuotaPopoverID = open ? pool.id : (openQuotaPopoverID == pool.id ? nil : openQuotaPopoverID)
                if open {
                    requestQuota(poolID: pool.id, force: false)
                }
            }
        )
        return Button {
            isOpen.wrappedValue.toggle()
        } label: {
            HStack(spacing: 6) {
                ProviderLogo(provider: pool.providerKey)
                Text(verbatim: pool.provider)
                    .zivviFont(.caption2, weight: .medium)
                    .foregroundStyle(ZivviTheme.secondaryText)
                QuotaRemainingBar(fraction: metric.remainingFraction, severity: metric.severity)
                Text(verbatim: metric.displayValue)
                    .zivviFont(.caption2, design: .monospaced)
                    .monospacedDigit()
                    .foregroundStyle(metric.textColor)
                if metric.severity == .critical {
                    LightningIconView(.exclamationmarkTriangleFill, size: 11)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(FlatControlButtonStyle(isOpen: isOpen.wrappedValue, inset: false, cornerRadius: 5))
        .help("\(pool.provider) 剩余额度：\(metric.displayValue)")
        .accessibilityLabel("\(pool.provider) 额度")
        .accessibilityValue(metric.accessibilityValue)
        .accessibilityIdentifier("quota-pill-\(pool.id)")
        .popover(isPresented: isOpen, arrowEdge: .top) {
            QuotaPoolDetailPopover(
                pool: pool,
                date: date,
                refresh: { requestQuota(poolID: pool.id, force: true) }
            )
        }
    }

    // MARK: - Refresh Logic

    private func requestQuota(poolID: String, force: Bool) {
        if poolID == antigravityState.id {
            requestAntigravityQuota(force: force)
        } else {
            Task { await refreshCodexQuota(force: force) }
        }
    }

    private func refreshCodexQuota(force: Bool) async {
        let now = Date.now
        guard !codexState.loading else { return }
        if !force, let last = codexState.lastAttempt, now.timeIntervalSince(last) < 60 { return }
        if !force, codexState.issue == nil, !codexState.windows.isEmpty,
           codexState.windows.allSatisfy({ !$0.isStale(at: now) }) { return }
        codexState.loading = true
        defer { codexState.loading = false; codexState.lastAttempt = .now }
        do {
            codexState.windows = try await CodexQuotaClient.fetch(searchPaths: toolSearchPaths)
            codexState.issue = nil
            codexState.isInstalled = true
        } catch CodexQuotaClient.Failure.notInstalled {
            codexState.windows = []
            codexState.isInstalled = false
            codexState.issue = String(localized: "未找到本机 Codex CLI。")
        } catch CodexQuotaClient.Failure.notSignedIn {
            codexState.windows = []
            codexState.isInstalled = true
            codexState.issue = String(localized: "本机 Codex 未使用 ChatGPT 账号登录。")
        } catch {
            for index in codexState.windows.indices { codexState.windows[index].expiresAt = .now }
            codexState.issue = String(localized: "暂时无法查询 Codex 额度。")
        }
    }

    private func requestAntigravityQuota(force: Bool) {
        guard canQueryAntigravity, antigravityQuery == nil else { return }
        let now = Date.now
        if !force, let last = antigravityState.lastAttempt, now.timeIntervalSince(last) < 60 { return }
        if !force, antigravityState.issue == nil, !antigravityState.windows.isEmpty,
           antigravityState.windows.allSatisfy({ !$0.isStale(at: now) }) { return }

        let request = UUID()
        antigravityQueryID = request
        antigravityState.loading = true
        antigravityQuery = Task {
            defer {
                if antigravityQueryID == request {
                    antigravityState.loading = false
                    antigravityState.lastAttempt = .now
                    antigravityQueryID = nil
                    antigravityQuery = nil
                }
            }
            do {
                let windows = try await AntigravityQuotaClient.fetch(searchPaths: toolSearchPaths)
                guard !Task.isCancelled, antigravityQueryID == request else { return }
                antigravityState.windows = windows
                antigravityState.issue = nil
                antigravityState.isInstalled = true
            } catch {
                guard !Task.isCancelled, antigravityQueryID == request else { return }
                antigravityState.windows = []
                antigravityState.isInstalled = (error as? AntigravityQuotaClient.Failure) != .notInstalled
                switch error {
                case AntigravityQuotaClient.Failure.notInstalled:
                    antigravityState.issue = String(localized: "未找到本机 Antigravity CLI。")
                case AntigravityQuotaClient.Failure.notSignedIn:
                    antigravityState.issue = String(localized: "本机 Antigravity CLI 尚未登录。")
                case AntigravityQuotaClient.Failure.unsupportedVersion:
                    antigravityState.issue = String(localized: "当前 Antigravity CLI 版本不支持只读额度查询。")
                default:
                    antigravityState.issue = String(localized: "暂时无法查询 Antigravity 额度。")
                }
            }
        }
    }

    private func cancelAntigravityQuota() {
        antigravityQueryID = nil
        antigravityQuery?.cancel()
        antigravityQuery = nil
        antigravityState.loading = false
    }

    private func checkRelease(showResult: Bool) async {
        guard !checkingRelease,
              let installed = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else { return }
        checkingRelease = true
        defer { checkingRelease = false }
        do {
            let version = try await ZivviReleaseCheck.latestVersion(installed: installed)
            guard !Task.isCancelled else { return }
            availableVersion = version
            releaseCheckFailed = false
            if showResult, version != nil { openURL(ZivviReleaseCheck.releasePage) }
            else if showResult { showsReleaseResult = true }
        } catch {
            guard !Task.isCancelled else { return }
            releaseCheckFailed = true
            if showResult { showsReleaseResult = true }
        }
        lastReleaseCheck = .now
    }
}

struct QuotaPoolState: Identifiable {
    enum Severity { case normal, warning, critical, unavailable }

    struct Metric {
        let remainingFraction: Double?
        let displayValue: String
        let severity: Severity
        let accessibilityValue: String

        var textColor: Color {
            switch severity {
            case .critical: ZivviTheme.errorText
            case .warning: ZivviTheme.warningText
            case .normal: ZivviTheme.primaryText
            case .unavailable: ZivviTheme.tertiaryText
            }
        }
    }

    let id: String
    let provider: String
    let providerKey: String
    var windows: [AccountQuotaWindow] = []
    var loading = false
    var isInstalled = true
    var lastAttempt: Date?
    var issue: String?

    var hasDataOrAttemptedAvailable: Bool {
        !windows.isEmpty || isInstalled
    }

    /// Selects the lowest valid remaining ratio across active (non-stale) windows.
    func metric(at date: Date) -> Metric {
        let valid = windows.compactMap { window -> (window: AccountQuotaWindow, ratio: Double)? in
            guard !window.isStale(at: date),
                  let rem = window.remaining, let lim = window.limit,
                  lim > 0, rem >= 0 else { return nil }
            return (window, min(1.0, max(0.0, Double(rem) / Double(lim))))
        }
        guard let lowest = valid.min(by: { $0.ratio < $1.ratio }) else {
            return Metric(
                remainingFraction: nil,
                displayValue: "—",
                severity: .unavailable,
                accessibilityValue: issue ?? String(localized: "暂无可用额度数据")
            )
        }
        let valueText = lowest.window.value ?? "—"
        let severity: Severity = if lowest.ratio <= 0.10 {
            .critical
        } else if lowest.ratio <= 0.25 {
            .warning
        } else {
            .normal
        }
        let a11y: String = switch severity {
        case .critical: String(localized: "剩余 \(valueText)，额度接近耗尽")
        case .warning: String(localized: "剩余 \(valueText)，额度偏低")
        case .normal: String(localized: "剩余 \(valueText)")
        case .unavailable: String(localized: "暂无可用额度数据")
        }
        return Metric(remainingFraction: lowest.ratio, displayValue: valueText, severity: severity, accessibilityValue: a11y)
    }
}

private struct QuotaRemainingBar: View {
    let fraction: Double?
    let severity: QuotaPoolState.Severity

    private var fillColor: Color {
        switch severity {
        case .critical: ZivviTheme.errorText
        case .warning: ZivviTheme.lightningYellow
        case .normal: ZivviTheme.secondaryText
        case .unavailable: Color.clear
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(ZivviTheme.subtleDivider)
                if let fraction {
                    Capsule()
                        .fill(fillColor)
                        .frame(width: max(fraction > 0 ? 2 : 0, proxy.size.width * fraction))
                }
            }
        }
        .frame(width: 38, height: 4)
        .accessibilityHidden(true)
    }
}

private struct QuotaPoolDetailPopover: View {
    let pool: QuotaPoolState
    let date: Date
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AnchoredCardStyle.spacing) {
            HStack {
                HStack(spacing: 6) {
                    ProviderLogo(provider: pool.providerKey)
                    Text(verbatim: "\(pool.provider) 额度")
                        .anchoredCardTitle()
                }
                Spacer()
                if pool.loading { FlatProgressView().controlSize(.mini) }
                Button("刷新", action: refresh)
                    .buttonStyle(FlatControlButtonStyle())
                    .disabled(pool.loading)
            }
            Text("进度条表示剩余额度；多个周期同时存在时状态栏展示最低有效余量。")
                .zivviFont(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let issue = pool.issue {
                Text(verbatim: issue)
                    .zivviFont(.caption)
                    .foregroundStyle(ZivviTheme.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            } else if pool.windows.isEmpty && !pool.loading {
                Text("暂无可用额度数据。")
                    .zivviFont(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(pool.windows) { window in
                ZivviDivider()
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(verbatim: window.period)
                            .zivviFont(.caption, weight: .medium)
                            .foregroundStyle(ZivviTheme.primaryText)
                        Spacer(minLength: 8)
                        Text(verbatim: window.value ?? String(localized: "未知"))
                            .zivviFont(.caption, weight: .semibold, design: .monospaced)
                            .monospacedDigit()
                    }
                    if window.isStale(at: date) {
                        Text("数据已过期，待刷新")
                            .zivviFont(.caption2)
                            .foregroundStyle(ZivviTheme.warningText)
                    }
                    if let reset = window.resetAt {
                        Text("重置：\(reset, format: .dateTime.month().day().hour().minute())")
                            .zivviFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text("同步于 \(window.observedAt, format: .dateTime.month().day().hour().minute())")
                        .zivviFont(.caption2)
                        .foregroundStyle(ZivviTheme.tertiaryText)
                }
            }
        }
        .anchoredPopoverCard(width: 288)
    }
}
