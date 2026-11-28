import AppKit
import SwiftUI
import AgentRuntimeCore
import OrchestrationCore

/// Structured, flat execution error block displayed in the transcript for a failed/uncertain turn
/// (Workbench 2.0 Section 14.2 & 14.3). Preserves copyable raw provider response in a collapsed disclosure.
struct ExecutionErrorPresentation: Equatable {
    enum Category: Equatable {
        case quotaExceeded
        case rateLimited
        case authentication
        case contextExceeded
        case connectionLost
        case modelUnavailable
        case permissionDenied
        case unknown
    }

    let category: Category
    let title: String
    let message: String
    let resetHint: String?
    let rawDetail: String

    init(failure: RuntimeFailure) {
        let raw = failure.rawDetail ?? failure.detail
        let lower = (raw + " " + failure.detail).lowercased()
        let parsedReset = failure.resetHint ?? Self.extractResetHint(from: raw)
        self.resetHint = parsedReset
        self.rawDetail = raw

        if lower.contains("quota") || lower.contains("usage limit") || lower.contains("额度") {
            self.category = .quotaExceeded
            self.title = String(localized: "模型额度已耗尽")
            self.message = String(localized: "当前账号的使用额度已达到上限。")
        } else if lower.contains("429") || lower.contains("rate limit") || lower.contains("限流") {
            self.category = .rateLimited
            self.title = String(localized: "请求频率受限")
            self.message = String(localized: "模型服务暂时限流，请稍后再试或切换其他模型。")
        } else if failure.kind == .authentication || lower.contains("401") || lower.contains("unauthorized") || lower.contains("认证") {
            self.category = .authentication
            self.title = String(localized: "认证失败")
            self.message = String(localized: "当前 Agent 或模型账号需要重新认证。")
        } else if lower.contains("context length") || lower.contains("too long") || lower.contains("too large") || lower.contains("超出运行时的输入限制") {
            self.category = .contextExceeded
            self.title = String(localized: "上下文超出限制")
            self.message = String(localized: "当前请求或历史上下文超出模型窗口上限，请精简输入或切换更大上下文模型。")
        } else if failure.kind == .connection || failure.kind == .supervision || lower.contains("disconnected") || lower.contains("连接") {
            self.category = .connectionLost
            self.title = String(localized: "连接已中断")
            self.message = failure.detail
        } else if failure.kind == .model {
            self.category = .modelUnavailable
            self.title = String(localized: "模型服务不可用")
            self.message = failure.detail
        } else if lower.contains("permission") || lower.contains("权限") {
            self.category = .permissionDenied
            self.title = String(localized: "操作权限不足")
            self.message = failure.detail
        } else {
            self.category = .unknown
            self.title = String(localized: "执行失败")
            self.message = failure.detail
        }
    }

    /// Extracts human-readable reset duration hints like "Resets in 2h25m10s" if present in provider response.
    static func extractResetHint(from raw: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(?i)resets?\s+in\s+([0-9]+h)?\s*([0-9]+m)?\s*([0-9]+s)?"#),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..<raw.endIndex, in: raw)),
              let range = Range(match.range, in: raw) else { return nil }
        let matched = String(raw[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard matched.rangeOfCharacter(from: .decimalDigits) != nil else { return nil }
        return matched
    }
}

struct TurnExecutionErrorView: View {
    let failure: RuntimeFailure
    let occurredAt: Date?
    var onSwitchModel: (() -> Void)? = nil
    var onOpenSettings: (() -> Void)? = nil
    var onSafeRetry: (() -> Void)? = nil
    var contentChanged: () -> Void = {}

    @State private var detailsExpanded = false
    @State private var copied = false

    var body: some View {
        let presentation = ExecutionErrorPresentation(failure: failure)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                LightningBrandIconView(.error, size: 15)
                Text(verbatim: presentation.title)
                    .zivviFont(.body, weight: .semibold)
                    .foregroundStyle(ZivviTheme.primaryText)
            }

            Text(verbatim: presentation.message)
                .zivviFont(.callout)
                .foregroundStyle(ZivviTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if let resetHint = presentation.resetHint {
                HStack(spacing: 5) {
                    LightningIconView(.clock, size: 12)
                    Text(occurredAt.map { "发生时提示：\(resetHint)（\(TranscriptTimestampFormatter.shortTime($0))）" } ?? resetHint)
                        .zivviFont(.caption)
                        .foregroundStyle(ZivviTheme.secondaryText)
                }
            }

            recoveryActions(for: presentation.category)

            DisclosureGroup(isExpanded: $detailsExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Provider Response")
                            .zivviFont(.caption2, weight: .medium)
                            .foregroundStyle(ZivviTheme.tertiaryText)
                        Spacer(minLength: 4)
                        Button(copied ? "已复制" : "复制") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(presentation.rawDetail, forType: .string)
                            copied = true
                            Task {
                                try? await Task.sleep(for: .seconds(1.5))
                                copied = false
                            }
                        }
                        .buttonStyle(FlatControlButtonStyle(treatment: .outlined, height: 22))
                        .zivviFont(.caption2)
                    }
                    Text(verbatim: presentation.rawDetail)
                        .zivviFont(.caption, design: .monospaced)
                        .foregroundStyle(ZivviTheme.secondaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .background(ZivviTheme.mutedSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.top, 4)
            } label: {
                HStack(spacing: 5) {
                    FlatDisclosureChevron(expanded: detailsExpanded)
                    Text("错误详情")
                        .zivviFont(.caption)
                        .foregroundStyle(ZivviTheme.secondaryText)
                }
            }
            .disclosureGroupStyle(FlatDisclosureStyle(chevronEdge: nil))
            .onChange(of: detailsExpanded) { _, _ in contentChanged() }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("turn-execution-error")
    }

    @ViewBuilder
    private func recoveryActions(for category: ExecutionErrorPresentation.Category) -> some View {
        let showsSwitchModel = onSwitchModel != nil && (category == .quotaExceeded || category == .rateLimited || category == .contextExceeded || category == .modelUnavailable)
        let showsSettings = onOpenSettings != nil && (category == .authentication || category == .connectionLost)
        let showsRetry = onSafeRetry != nil && (category == .rateLimited || category == .modelUnavailable)

        if showsSwitchModel || showsSettings || showsRetry {
            HStack(spacing: 8) {
                if showsSwitchModel, let onSwitchModel {
                    Button("切换模型", action: onSwitchModel)
                        .buttonStyle(FlatControlButtonStyle(treatment: .outlined, height: 26))
                        .zivviFont(.caption, weight: .medium)
                }
                if showsSettings, let onOpenSettings {
                    Button("打开连接设置…", action: onOpenSettings)
                        .buttonStyle(FlatControlButtonStyle(treatment: .outlined, height: 26))
                        .zivviFont(.caption, weight: .medium)
                }
                if showsRetry, let onSafeRetry {
                    Button("安全重试…", action: onSafeRetry)
                        .buttonStyle(FlatControlButtonStyle(treatment: .outlined, height: 26))
                        .zivviFont(.caption, weight: .medium)
                }
            }
            .padding(.top, 2)
        }
    }
}
