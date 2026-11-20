import SwiftUI

struct AccountQuotaWindow: Identifiable {
    let id: String
    let provider: String
    let account: String
    let period: String
    let remaining: Int?
    let limit: Int?
    let resetAt: Date?
    let observedAt: Date
    var expiresAt: Date? = nil

    func isStale(at date: Date) -> Bool {
        [resetAt, expiresAt].compactMap { $0 }.contains { $0 <= date }
    }

    var value: String? {
        guard let remaining, remaining >= 0 else { return nil }
        guard let limit, limit > 0, remaining <= limit else { return remaining.formatted() }
        let percent = limit == 100 ? remaining : Int((Double(remaining) / Double(limit) * 100).rounded(.down))
        return percent == 0 && remaining > 0 ? "<1%" : "\(percent)%"
    }
}

struct SidebarQuotaSummary {
    let windows: [AccountQuotaWindow]

    func value(at date: Date) -> String? {
        guard windows.count == 1, let window = windows.first, !window.isStale(at: date) else { return nil }
        return window.value
    }

    func showsLowQuotaWarning(at date: Date) -> Bool {
        guard windows.count == 1, let window = windows.first,
              window.observedAt <= date,
              window.resetAt != nil || window.expiresAt != nil,
              !window.isStale(at: date),
              let remaining = window.remaining, let limit = window.limit,
              limit > 0, remaining >= 0 else { return false }
        return remaining <= limit / 10
    }
}

struct SidebarQuotaButton: View {
    var toolSearchPaths: [String] = []
    @State private var windows: [AccountQuotaWindow] = []
    @State private var showsDetails = false
    @State private var loading = false
    @State private var lastAttempt: Date?
    @State private var issue: String?

    var body: some View {
        let now = Date.now
        let deadlines = windows.flatMap { [$0.resetAt, $0.expiresAt].compactMap { $0 } }.filter { $0 > now }
        TimelineView(.explicit(Array(Set([now] + deadlines)).sorted())) { timeline in
            let summary = SidebarQuotaSummary(windows: windows)
            let value = summary.value(at: timeline.date)
            let warns = summary.showsLowQuotaWarning(at: timeline.date)
            let warningText = warns ? String(localized: "额度偏低：\(value ?? "")") : nil
            let quotaText = value.map { String(localized: "额度：\($0)") }
            Button { showsDetails.toggle() } label: {
                IconButtonLabel(systemName: warns ? "exclamationmark.triangle" : "gauge.with.dots.needle.33percent")
                    .foregroundStyle(warns ? PikachuTheme.warningText : PikachuTheme.secondaryText)
            }
            .buttonStyle(FlatControlButtonStyle(isOpen: showsDetails, inset: false))
            .help(warningText ?? quotaText ?? "账户额度")
            .accessibilityLabel("账户额度")
            .accessibilityValue(warningText ?? value ?? String(localized: "查看明细"))
            .accessibilityIdentifier("account-quota")
            .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
                SidebarQuotaDetails(windows: windows, date: timeline.date, loading: loading, issue: issue) {
                    Task { await refresh(force: true) }
                }
            }
        }
        .task { await refresh(force: false) }
        .onChange(of: showsDetails) { _, open in
            if open { Task { await refresh(force: false) } }
        }
    }

    private func refresh(force: Bool) async {
        guard !loading else { return }
        let now = Date.now
        if !force, let lastAttempt, now.timeIntervalSince(lastAttempt) < 30 { return }
        if !force, issue == nil, !windows.isEmpty, windows.allSatisfy({ !$0.isStale(at: now) }) { return }
        loading = true
        defer { loading = false; lastAttempt = .now }
        do {
            windows = try await CodexQuotaClient.fetch(searchPaths: toolSearchPaths)
            issue = nil
        } catch CodexQuotaClient.Failure.notInstalled {
            windows = []
            issue = String(localized: "未找到本机 Codex CLI。")
        } catch CodexQuotaClient.Failure.notSignedIn {
            windows = []
            issue = String(localized: "本机 Codex 未使用 ChatGPT 账号登录。")
        } catch {
            for index in windows.indices { windows[index].expiresAt = .now }
            issue = String(localized: "暂时无法查询 Codex 额度。")
        }
    }
}

enum PikachuReleaseCheck {
    private static let endpoint = URL(string: "https://api.github.com/repos/yuzio-ai/pikachu/releases/latest")!
    static let releasePage = URL(string: "https://github.com/yuzio-ai/pikachu/releases/latest")!

    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
    }

    static func newerVersion(tag: String, installed: String) -> String? {
        func components(_ value: String) -> (String, [Int])? {
            let version = value.hasPrefix("v") ? String(value.dropFirst()) : value
            let parts = version.split(separator: ".", omittingEmptySubsequences: false)
            guard (1...3).contains(parts.count) else { return nil }
            let numbers = parts.compactMap { part in
                part.utf8.allSatisfy { (48...57).contains($0) } ? Int(part) : nil
            }
            guard numbers.count == parts.count else { return nil }
            return (version, numbers + Array(repeating: 0, count: 3 - numbers.count))
        }
        guard let (version, candidate) = components(tag), let (_, current) = components(installed),
              current.lexicographicallyPrecedes(candidate) else { return nil }
        return version
    }

    static func latestVersion(installed: String) async throws -> String? {
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 404 { return nil } // No public stable release yet.
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease else { return nil }
        return newerVersion(tag: release.tag_name, installed: installed)
    }
}

struct SidebarUpgradeButton: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var availableVersion: String?
    @State private var lastCheck: Date?
    @State private var checking = false
    @State private var checkFailed = false
    @State private var showsResult = false

    var body: some View {
        let available = availableVersion != nil
        Button {
            if available {
                openURL(PikachuReleaseCheck.releasePage)
            } else {
                Task { await check(showResult: true) }
            }
        } label: {
            IconButtonLabel(systemName: available ? "arrow.up.circle.fill" : "arrow.up.circle")
                .foregroundStyle(available ? PikachuTheme.accentText : PikachuTheme.secondaryText)
        }
        .buttonStyle(FlatControlButtonStyle(treatment: available ? .prominent : .quiet, inset: false))
        .disabled(checking && !available)
        .help(hint)
        .accessibilityLabel("升级")
        .accessibilityValue(hint)
        .accessibilityIdentifier("app-upgrade")
        .popover(isPresented: $showsResult, arrowEdge: .bottom) {
            Text(checkFailed ? "暂时无法检查更新，请稍后重试。" : "没有可用的更新。")
                .pikachuFont(.callout)
                .anchoredPopoverCard(width: 225)
        }
        .task(id: scenePhase) {
            guard scenePhase == .active,
                  lastCheck.map({ Date.now.timeIntervalSince($0) >= 6 * 60 * 60 }) ?? true else { return }
            await check(showResult: false)
        }
    }

    private var hint: String {
        if let availableVersion { return String(localized: "新版 \(availableVersion) 可用，点击升级") }
        if checking { return String(localized: "正在检查更新…") }
        return String(localized: "检查更新")
    }

    private func check(showResult: Bool) async {
        guard !checking, let installed = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else { return }
        checking = true
        defer { checking = false }
        do {
            let version = try await PikachuReleaseCheck.latestVersion(installed: installed)
            guard !Task.isCancelled else { return }
            availableVersion = version
            checkFailed = false
            if showResult, version != nil { openURL(PikachuReleaseCheck.releasePage) }
            else if showResult { showsResult = true }
        } catch {
            guard !Task.isCancelled else { return }
            checkFailed = true
            if showResult { showsResult = true }
        }
        lastCheck = .now
    }
}

private struct SidebarQuotaDetails: View {
    let windows: [AccountQuotaWindow]
    let date: Date
    let loading: Bool
    let issue: String?
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AnchoredCardStyle.spacing) {
            HStack {
                Text("本机 Codex 账号").anchoredCardTitle()
                Spacer()
                if loading { FlatProgressView().controlSize(.mini) }
                Button("刷新", action: refresh).buttonStyle(FlatControlButtonStyle()).disabled(loading)
            }
            Text("仅显示本机 Codex 额度，未与当前会话关联。")
                .pikachuFont(.caption).foregroundStyle(.secondary)
            if let issue {
                Text(issue).foregroundStyle(.secondary)
            } else if windows.isEmpty && !loading {
                Text("没有可用的账户额度数据。").foregroundStyle(.secondary)
            }
            ForEach(windows) { window in
                PikachuDivider()
                Text(window.period).foregroundStyle(.secondary)
                Text("剩余：\(window.value ?? String(localized: "未知"))")
                if window.isStale(at: date) { Text("待更新").foregroundStyle(.secondary) }
                if let reset = window.resetAt {
                    Text("重置：\(reset, format: .dateTime.month().day().hour().minute())")
                }
                Text("查询于 \(window.observedAt, format: .dateTime.month().day().hour().minute())")
                    .foregroundStyle(.secondary)
            }
        }
        .anchoredPopoverCard(width: 274)
    }
}
