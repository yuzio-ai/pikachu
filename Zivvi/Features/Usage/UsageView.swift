import SwiftUI
import AgentRuntimeCore
import OrchestrationCore

struct UsagePresentationSnapshot {
    let summaryRatio: Double?
    let summaryText: String
    let isContextPending: Bool
    let isOverCapacity: Bool
    let isStale: Bool
    let percentText: String
    let detailFractionText: String
    let observedAtText: String?
    let totalTokensText: String
    let cacheHitRateText: String?
    let inputTitle: LocalizedStringResource
    let costText: String

    init(usage: RuntimeUsage?, isConnected: Bool, isStale: Bool, isLoading: Bool, isCompacting: Bool) {
        self.isStale = isStale
        let context = usage?.context
        let window = context?.window
        let tokens = context?.tokens

        if let tokens, let window, window > 0 {
            let ratio = Double(tokens) / Double(window)
            self.summaryRatio = min(1.0, max(0.0, ratio))
            self.isOverCapacity = tokens > window
            let pct = context?.percent ?? (ratio * 100)
            let formattedPercent = "\(pct.formatted(.number.precision(.fractionLength(0...1))))%"
            self.percentText = formattedPercent
            self.isContextPending = false
            self.summaryText = "\(Self.formatCompact(tokens)) / \(Self.formatCompact(window))"
            self.detailFractionText = "\(Self.formatDetail(tokens)) / \(Self.formatDetail(window))"
        } else {
            self.summaryRatio = nil
            self.isOverCapacity = false
            self.isContextPending = isCompacting || (isConnected && (isLoading || isStale || window != nil))
            let status = isContextPending ? String(localized: "待更新") : String(localized: "不可用")
            self.percentText = status
            self.summaryText = status
            if let window, window > 0 {
                self.detailFractionText = "— / \(Self.formatDetail(window))"
            } else {
                self.detailFractionText = "—"
            }
        }

        if let observed = usage?.observedAt {
            self.observedAtText = observed.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        } else {
            self.observedAtText = nil
        }

        if let total = usage?.tokens.total {
            self.totalTokensText = Self.formatTotal(total)
        } else {
            self.totalTokensText = String(localized: "未知")
        }

        if let tok = usage?.tokens, tok.inputIsUncached,
           let cacheRead = tok.cacheRead, let uncachedInput = tok.input,
           cacheRead >= 0, uncachedInput >= 0, cacheRead + uncachedInput > 0 {
            let hitRate = Double(cacheRead) / Double(cacheRead + uncachedInput) * 100
            self.cacheHitRateText = String(localized: "缓存命中 \(hitRate.formatted(.number.precision(.fractionLength(1))))%")
        } else {
            self.cacheHitRateText = nil
        }

        self.inputTitle = (usage?.tokens.inputIsUncached == true) ? "未缓存输入" : "输入"

        if let cost = usage?.estimatedCostUSD {
            self.costText = "US$" + cost.formatted(.number.precision(.fractionLength(4)))
        } else {
            self.costText = String(localized: "无法估算")
        }
    }

    static func formatCompact(_ value: Int) -> String {
        if value >= 1_000_000 {
            return "\((Double(value) / 1_000_000).formatted(.number.precision(.fractionLength(1))))M"
        }
        if value >= 1_000 {
            return "\(Int((Double(value) / 1_000).rounded()))k"
        }
        return "\(value)"
    }

    static func formatDetail(_ value: Int) -> String {
        if value >= 1_000_000 {
            return "\((Double(value) / 1_000_000).formatted(.number.precision(.fractionLength(2))))M"
        }
        if value >= 1_000 {
            return "\((Double(value) / 1_000).formatted(.number.precision(.fractionLength(1))))k"
        }
        return "\(value)"
    }

    static func formatTotal(_ value: Int) -> String {
        if value >= 1_000_000 {
            return "\((Double(value) / 1_000_000).formatted(.number.precision(.fractionLength(2))))M"
        }
        if value >= 10_000 {
            return "\((Double(value) / 1_000).formatted(.number.precision(.fractionLength(1))))k"
        }
        return value.formatted()
    }
}

struct UsageView: View {
    @Environment(\.zivviTypography) private var typography
    let controller: SessionController
    @Binding var isPresented: Bool
    @State private var breakdownExpanded = true

    private var snapshot: UsagePresentationSnapshot {
        UsagePresentationSnapshot(
            usage: controller.usage,
            isConnected: controller.connection == .connected,
            isStale: controller.usageStale,
            isLoading: controller.usageLoading,
            isCompacting: controller.phase == .compacting
        )
    }

    private var accessibilityValueText: String {
        var parts: [String] = []
        if let ratio = snapshot.summaryRatio, let context = controller.usage?.context,
           let tokens = context.tokens, let window = context.window {
            let pct = context.percent ?? (ratio * 100)
            parts.append(String(localized: "已用 \(pct.formatted(.number.precision(.fractionLength(0...1))))%"))
            parts.append("\(tokens.formatted()) / \(window.formatted()) Token")
        } else {
            parts.append(snapshot.summaryText)
        }
        if let observed = controller.usage?.observedAt {
            parts.append(String(localized: "最近更新 \(TranscriptTimestampFormatter.fullTimeWithZone(observed))"))
        }
        return parts.joined(separator: String(localized: "，"))
    }

    var body: some View {
        let buttonHeight = typography.composerActionButtonSize
        return Button {
            isPresented.toggle()
        } label: {
            ContextProgressRing(
                ratio: snapshot.summaryRatio,
                isHighlighted: isPresented,
                isOverCapacity: snapshot.isOverCapacity
            )
            .frame(width: buttonHeight / 2, height: buttonHeight / 2)
            .accessibilityHidden(true)
        }
        .buttonStyle(FlatControlButtonStyle(isOpen: isPresented, height: buttonHeight))
        .fixedSize()
        .help(snapshot.isContextPending ? String(localized: "待更新") : String(localized: "查看上下文与会话用量（⇧⌘U）"))
        .accessibilityLabel("上下文与会话用量")
        .accessibilityValue(accessibilityValueText)
        .accessibilityIdentifier("session-usage")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            details.lineLimit(nil)
                .anchoredPopoverCard(width: 360)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    HStack(spacing: 6) {
                        Text("上下文已用").anchoredCardTitle()
                        Text(snapshot.percentText)
                            .zivviFont(.callout, weight: .medium)
                            .monospacedDigit()
                            .foregroundStyle(snapshot.isOverCapacity ? ZivviTheme.warningText : Color.primary)
                    }
                    Spacer()
                    Text(snapshot.detailFractionText)
                        .zivviFont(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ContextProgressTrack(
                    ratio: snapshot.summaryRatio,
                    isHighlighted: true,
                    isOverCapacity: snapshot.isOverCapacity
                )
                .frame(height: 6)
                HStack(spacing: 6) {
                    if let observed = snapshot.observedAtText {
                        Text("最近记录 · \(observed) 更新")
                    } else {
                        Text("尚无上下文记录")
                    }
                    if snapshot.isOverCapacity {
                        Text("· 已超出窗口容量").foregroundStyle(ZivviTheme.warningText)
                    } else if controller.usageStale && controller.connection == .connected {
                        Text("· 待更新").foregroundStyle(ZivviTheme.warningText)
                    }
                }
                .zivviFont(.caption)
                .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    breakdownExpanded.toggle()
                } label: {
                    HStack(spacing: 8) {
                        LightningBrandIconView(.context, size: 14)
                        Text("累计词元")
                            .fontWeight(.medium)
                        Spacer()
                        Text(snapshot.totalTokensText)
                            .zivviFont(.headline)
                            .monospacedDigit()
                        Spacer()
                        if let hit = snapshot.cacheHitRateText {
                            Text(hit)
                                .zivviFont(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        FlatDisclosureChevron(breakdownExpanded ? .up : .down)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .buttonStyle(FlatControlButtonStyle(treatment: .outlined, inset: false))
                .accessibilityValue(breakdownExpanded ? Text("已展开") : Text("已折叠"))

                if breakdownExpanded {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("用量明细")
                            .zivviFont(.caption, weight: .semibold)
                        if let usage = controller.usage {
                            UsageDetailRow(title: "缓存读取", value: usage.tokens.cacheRead)
                            UsageDetailRow(title: snapshot.inputTitle, value: usage.tokens.input)
                            UsageDetailRow(title: "缓存写入", value: usage.tokens.cacheWrite)
                            UsageDetailRow(title: "输出", value: usage.tokens.output)
                        } else {
                            Text(controller.usageNotice ?? String(localized: "统计尚不可用；缺失数据未计为零。"))
                                .zivviFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }

            ZivviDivider()

            HStack {
                Text("模型调用费用（估算）")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(snapshot.costText)
                    .monospacedDigit()
                    .foregroundStyle(controller.usage?.estimatedCostUSD == nil ? .secondary : .primary)
            }
            .zivviFont(.callout)

            if let note = controller.usage?.note {
                Text(note)
                    .zivviFont(.caption)
                    .foregroundStyle(.secondary)
            }
            if controller.usage != nil, let notice = controller.usageNotice {
                Text(notice)
                    .zivviFont(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if controller.connection != .connected {
                    Text("历史查看不启动运行时")
                        .zivviFont(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if controller.usageLoading {
                    FlatProgressView().controlSize(.mini)
                }
                Button("刷新统计") { Task { await controller.refreshUsage() } }
                    .buttonStyle(FlatControlButtonStyle())
                    .zivviFont(.callout, weight: .medium)
                    .disabled(controller.connection != .connected || controller.usageLoading)
            }
        }
        .textSelection(.enabled)
        .accessibilityIdentifier("session-usage-details")
    }
}

private struct ContextProgressRing: View {
    let ratio: Double?
    let isHighlighted: Bool
    let isOverCapacity: Bool

    var body: some View {
        let tint = isOverCapacity ? ZivviTheme.warningText : (isHighlighted ? ZivviTheme.accentText : Color.secondary)
        Circle()
            .strokeBorder(ZivviTheme.border, lineWidth: 2)
            .overlay {
                if let ratio, ratio > 0 {
                    Circle()
                        .inset(by: 1)
                        .trim(from: 0, to: CGFloat(ratio))
                        .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
    }
}

private struct ContextProgressTrack: View {
    let ratio: Double?
    let isHighlighted: Bool
    let isOverCapacity: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(ZivviTheme.border)
                if let ratio {
                    Capsule()
                        .fill(isOverCapacity ? ZivviTheme.warningText : (isHighlighted ? ZivviTheme.accentText : Color.secondary))
                        .frame(width: max(ratio > 0 ? 3 : 0, width * CGFloat(ratio)))
                }
            }
        }
    }
}

private struct UsageDetailRow: View {
    let title: LocalizedStringResource
    let value: Int?

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value.map { $0.formatted() } ?? String(localized: "未知"))
                .monospacedDigit()
        }
        .zivviFont(.callout)
    }
}
