import SwiftUI
import AgentRuntimeCore
import OrchestrationCore

struct UsagePresentationSnapshot {
    let summaryRatio: Double?
    let summaryText: String
    let compactSummaryText: String
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
            self.percentText = "\(pct.formatted(.number.precision(.fractionLength(0...1))))%"
            self.summaryText = "\(Self.formatCompact(tokens)) / \(Self.formatCompact(window))"
            self.compactSummaryText = "\(Self.formatCompact(tokens))/\(Self.formatCompact(window))"
            self.detailFractionText = "\(Self.formatDetail(tokens)) / \(Self.formatDetail(window))"
        } else {
            self.summaryRatio = nil
            self.isOverCapacity = false
            if isCompacting || (isConnected && (isLoading || isStale || window != nil)) {
                self.percentText = String(localized: "待更新")
                self.summaryText = String(localized: "待更新")
                self.compactSummaryText = String(localized: "待更新")
            } else {
                self.percentText = String(localized: "不可用")
                self.summaryText = String(localized: "不可用")
                self.compactSummaryText = String(localized: "不可用")
            }
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
    let controller: SessionController
    @Bindable var workspace: WorkspaceController
    var compactNumbers = false
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
            parts.append("已用 \(pct.formatted(.number.precision(.fractionLength(0...1))))%")
            parts.append("\(tokens.formatted()) / \(window.formatted()) Token")
        } else {
            parts.append(snapshot.summaryText)
        }
        if let observed = controller.usage?.observedAt {
            parts.append("最近更新 \(TranscriptTimestampFormatter.fullTimeWithZone(observed))")
        }
        return parts.joined(separator: "，")
    }

    var body: some View {
        Button {
            workspace.usageExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Text("上下文")
                    .foregroundStyle(.secondary)
                    .fixedSize()
                ContextProgressTrack(
                    ratio: snapshot.summaryRatio,
                    isHighlighted: workspace.usageExpanded,
                    isOverCapacity: snapshot.isOverCapacity
                )
                .frame(width: 44, height: 5)
                Text(compactNumbers ? snapshot.compactSummaryText : snapshot.summaryText)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                Image(systemName: workspace.usageExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(ComposerControlButtonStyle(isOpen: workspace.usageExpanded))
        .fixedSize()
        .help("查看上下文与会话用量（⇧⌘U）")
        .accessibilityLabel("上下文与会话用量")
        .accessibilityValue(accessibilityValueText)
        .accessibilityIdentifier("session-usage")
        .popover(isPresented: $workspace.usageExpanded, arrowEdge: .bottom) {
            details.lineLimit(nil).padding(16).frame(width: 360)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    HStack(spacing: 6) {
                        Text("上下文已用").font(.headline)
                        Text(snapshot.percentText)
                            .font(.headline)
                            .monospacedDigit()
                            .foregroundStyle(snapshot.isOverCapacity ? Color.orange : Color.primary)
                    }
                    Spacer()
                    Text(snapshot.detailFractionText)
                        .font(.callout)
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
                        Text("· 已超出窗口容量").foregroundStyle(.orange)
                    } else if controller.usageStale && controller.connection == .connected {
                        Text("· 待更新").foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    breakdownExpanded.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "cylinder.split.1x2")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("累计 Token")
                            .fontWeight(.medium)
                        Spacer()
                        Text(snapshot.totalTokensText)
                            .font(.headline)
                            .monospacedDigit()
                        Spacer()
                        if let hit = snapshot.cacheHitRateText {
                            Text(hit)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Image(systemName: breakdownExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 8))
                    .contentShape(.rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                if breakdownExpanded {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("用量明细")
                            .font(.caption.weight(.semibold))
                        if let usage = controller.usage {
                            UsageDetailRow(title: "缓存读取", value: usage.tokens.cacheRead)
                            UsageDetailRow(title: snapshot.inputTitle, value: usage.tokens.input)
                            UsageDetailRow(title: "缓存写入", value: usage.tokens.cacheWrite)
                            UsageDetailRow(title: "输出", value: usage.tokens.output)
                        } else {
                            Text(controller.usageNotice ?? "统计尚不可用；缺失数据未计为零。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }

            Divider()

            HStack {
                Text("API 费用（估算）")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(snapshot.costText)
                    .monospacedDigit()
                    .foregroundStyle(controller.usage?.estimatedCostUSD == nil ? .secondary : .primary)
            }
            .font(.callout)

            if let note = controller.usage?.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if controller.usage != nil, let notice = controller.usageNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if controller.connection != .connected {
                    Text("历史查看不启动运行时")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if controller.usageLoading {
                    ProgressView().controlSize(.mini)
                }
                Button("刷新统计") { Task { await controller.refreshUsage() } }
                    .buttonStyle(.borderless)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(controller.connection == .connected && !controller.usageLoading ? Color.accentColor : Color.secondary)
                    .disabled(controller.connection != .connected || controller.usageLoading)
            }
        }
        .textSelection(.enabled)
        .accessibilityIdentifier("session-usage-details")
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
                    .fill(Color.primary.opacity(0.12))
                if let ratio {
                    Capsule()
                        .fill(isOverCapacity ? Color.orange : (isHighlighted ? Color.accentColor : Color.primary.opacity(0.62)))
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
            Text(value.map { $0.formatted() } ?? "未知")
                .monospacedDigit()
        }
        .font(.callout)
    }
}
