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
        let percent = Int((Double(remaining) / Double(limit) * 100).rounded(.down))
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
    let windows: [AccountQuotaWindow]
    @State private var showsDetails = false

    var body: some View {
        let now = Date.now
        let deadlines = windows.flatMap { [$0.resetAt, $0.expiresAt].compactMap { $0 } }.filter { $0 > now }
        TimelineView(.explicit(Array(Set([now] + deadlines)).sorted())) { timeline in
            let summary = SidebarQuotaSummary(windows: windows)
            let value = summary.value(at: timeline.date)
            let warns = summary.showsLowQuotaWarning(at: timeline.date)
            let symbol = warns ? "exclamationmark.triangle" : "gauge.with.dots.needle.33percent"
            Button { showsDetails.toggle() } label: {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        Image(systemName: symbol)
                        Text("额度")
                        if let value { Text(value).monospacedDigit() }
                    }
                    .fixedSize()
                    if let value {
                        HStack(spacing: 3) {
                            Image(systemName: symbol)
                            Text(value).monospacedDigit()
                        }
                        .fixedSize()
                    }
                    Image(systemName: symbol)
                }
                .pikachuFont(.caption)
                .foregroundStyle(warns ? PikachuTheme.warningText : PikachuTheme.secondaryText)
                .padding(.horizontal, 6)
                .frame(height: 26)
            }
            .buttonStyle(FlatControlButtonStyle(isOpen: showsDetails, inset: false))
            .help("账户额度")
            .accessibilityLabel("账户额度")
            .accessibilityValue(warns ? String(localized: "额度偏低：\(value ?? "")") :
                value ?? (windows.isEmpty ? String(localized: "暂不可用") : String(localized: "查看明细")))
            .accessibilityIdentifier("account-quota")
            .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
                SidebarQuotaDetails(windows: windows, date: timeline.date)
            }
        }
    }
}

private struct SidebarQuotaDetails: View {
    let windows: [AccountQuotaWindow]
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("账户额度").pikachuFont(.headline)
            if windows.isEmpty {
                Text("没有可用的账户额度数据。").foregroundStyle(.secondary)
            }
            ForEach(windows) { window in
                PikachuDivider()
                Text("\(window.provider) · \(window.account)").pikachuFont(.subheadline, weight: .medium)
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
        .pikachuFont(.callout)
        .padding(14)
        .frame(width: 274, alignment: .leading)
        .flatPanelContent()
    }
}
