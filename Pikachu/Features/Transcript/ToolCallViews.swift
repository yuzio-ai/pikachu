import AppKit
import SwiftUI
import AgentRuntimeCore
import OrchestrationCore

struct ToolRow: View {
    let item: TranscriptItem
    @Binding var expanded: Bool
    var onShowOutput: ((ToolOutputSelection) -> Void)? = nil
    var onPreviewImage: ((ImagePreviewSelection) -> Void)? = nil
    var showsRunningEffect = false
    var contentChanged: () -> Void = {}

    var body: some View {
        if let tool = item.toolSummary {
            let presentation = ToolCallPresentation(tool)
            ToolCallDisclosure(isExpanded: $expanded, isRunning: showsRunningEffect && tool.state == .running) {
                TranscriptToolDetails(item: item, presentation: presentation, onShowOutput: onShowOutput,
                                      onPreviewImage: onPreviewImage, contentChanged: contentChanged)
            } label: { emphasized in
                ToolRowLabel(presentation: presentation, expanded: expanded, emphasized: emphasized)
            }
            .accessibilityIdentifier(item.id)
            .onChange(of: expanded) { _, _ in contentChanged() }
        }
    }
}

struct ToolCallDisclosure<Content: View, Label: View>: View {
    @Binding var isExpanded: Bool
    var isRunning = false
    @ViewBuilder let content: () -> Content
    @ViewBuilder let label: (Bool) -> Label
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        let emphasized = isEnabled && (isHovered || isFocused)
        VStack(alignment: .leading, spacing: 0) {
            Button { isExpanded.toggle() } label: {
                label(emphasized)
                    .foregroundStyle(emphasized ? PikachuTheme.primaryText : PikachuTheme.tertiaryText)
                    .overlay {
                        if isRunning && !reduceMotion { ToolCallLightning() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onHover { isHovered = $0 }
            }
            .buttonStyle(.plain)
            .focused($isFocused)
            .accessibilityValue(isExpanded ? Text("已展开") : Text("已折叠"))

            if isExpanded { content() }
        }
    }
}

private struct ToolCallLightning: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var startedAt = Date.now
    @State private var seed = UInt64.random(in: UInt64.min...UInt64.max)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(startedAt))
            let cycle = UInt64(elapsed / ToolCallLightningPattern.period)
            let phase = elapsed.truncatingRemainder(dividingBy: ToolCallLightningPattern.period)
            Canvas { context, size in
                guard size.width >= 36, size.height >= 12 else { return }
                for arc in ToolCallLightningPattern.arcs(seed: seed, cycle: cycle) {
                    let opacity = arc.opacity(at: phase)
                    guard opacity > 0 else { continue }
                    let path = arc.path(in: size)
                    let tint: Color = arc.isBlue
                        ? (colorScheme == .dark ? Color(red: 0.43, green: 0.84, blue: 1) : Color(red: 0.06, green: 0.54, blue: 0.74))
                        : (colorScheme == .dark ? PikachuTheme.lightningYellow : Color(red: 0.77, green: 0.46, blue: 0.05))
                    let stroke = StrokeStyle(lineWidth: 1.45, lineCap: .round, lineJoin: .round)
                    context.drawLayer { glow in
                        glow.addFilter(.blur(radius: 2.2))
                        glow.stroke(path, with: .color(tint.opacity(opacity * 0.8)), lineWidth: 3.5)
                    }
                    context.stroke(path, with: .color(tint.opacity(opacity)), style: stroke)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A cycle's geometry is seeded, so an arc stays put while its brightness changes.
enum ToolCallLightningPattern {
    static let period: TimeInterval = 1.65

    struct Arc: Equatable {
        let start: TimeInterval
        let duration: TimeInterval
        let position: Double
        let angle: Double
        let isBlue: Bool
        let hasBranch: Bool
        let offsets: [Double]

        func opacity(at phase: TimeInterval) -> Double {
            let age = phase - start
            guard age >= 0, age < duration else { return 0 }
            // A discharge is visible on its first frame, even for short-lived calls.
            let hold = 0.09
            if age < hold { return 1 }
            return pow((duration - age) / (duration - hold), 1.5)
        }

        func path(in size: CGSize) -> Path {
            let radians = CGFloat(angle)
            let dx = cos(radians), dy = sin(radians)
            // Fit near-vertical arcs into the same compact title line.
            let jitter = min(3.5, size.height * 0.17)
            let halfLength = min(23, size.width * 0.22, max(0, size.height / 2 - jitter - 1) / max(0.1, abs(dy)))
            let margin = halfLength * abs(dx) + jitter + 1
            let center = CGPoint(x: margin + (size.width - margin * 2) * CGFloat(position), y: size.height / 2)
            let points = offsets.enumerated().map { index, offset in
                let along = (2 * CGFloat(index) / CGFloat(offsets.count - 1) - 1) * halfLength
                let across = CGFloat(offset) * jitter
                return CGPoint(x: center.x + dx * along - dy * across, y: center.y + dy * along + dx * across)
            }
            return Path { path in
                path.addLines(points)
                if hasBranch {
                    let branch = points[3]
                    path.move(to: branch)
                    path.addLine(to: CGPoint(x: branch.x + dx * 3 - dy * 2, y: branch.y + dy * 3 + dx * 2))
                    path.addLine(to: CGPoint(x: branch.x + dx * 6 - dy * jitter, y: branch.y + dy * 6 + dx * jitter))
                }
            }
        }
    }

    static func arcs(seed: UInt64, cycle: UInt64) -> [Arc] {
        var random = Generator(state: seed &+ (cycle &* 0xD2B74407B1CE6E93))
        let count = Int.random(in: 2...4, using: &random)
        let angles = [0.0, Double.pi / 2, Double.pi / 4, -Double.pi / 4].shuffled(using: &random)
        let starts = [cycle == 0 ? 0 : Double.random(in: 0.02...0.11, using: &random),
                      Double.random(in: 0.75...0.90, using: &random)]
        // Two beats per cycle, with spare arcs sharing a beat on the other half of the title.
        return (0..<count).map { index in
            let left = (index < 2) == (index.isMultiple(of: 2))
            return Arc(start: starts[index % 2],
                duration: Double.random(in: 0.43...0.56, using: &random),
                position: Double.random(in: left ? 0.05...0.45 : 0.55...0.95, using: &random),
                angle: angles[index] + Double.random(in: -0.16...0.16, using: &random),
                isBlue: Int.random(in: 0..<3, using: &random) == 0,
                hasBranch: Bool.random(using: &random),
                offsets: [0] + (0..<5).map { _ in Double.random(in: -1...1, using: &random) } + [0])
        }
    }

    private struct Generator: RandomNumberGenerator {
        var state: UInt64

        // SplitMix64: reproduce the same geometry on every frame of this cycle.
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
            value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
            return value ^ (value >> 31)
        }
    }
}

private struct ToolRowLabel: View {
    let presentation: ToolCallPresentation
    let expanded: Bool
    let emphasized: Bool

    var body: some View {
        let tool = presentation.summary
        let object = presentation.object
        let qualifiers = presentation.qualifiers
        let secondary = emphasized ? PikachuTheme.secondaryText : PikachuTheme.tertiaryText
        let objectColor = emphasized && presentation.isFileOperation ? PikachuTheme.primaryText : secondary
        HStack(spacing: 7) {
            ToolCallIcon(tool: tool.name)
            if let operation = presentation.operationLabel {
                Text(operation).pikachuFont(.callout).fixedSize()
            } else {
                Text(verbatim: tool.name).pikachuFont(.callout, weight: .medium, design: .monospaced)
                    .lineLimit(1).layoutPriority(1)
            }
            if !object.isEmpty {
                Text(verbatim: object)
                    .pikachuFont(.caption, design: .monospaced)
                    .foregroundStyle(objectColor)
                    .lineLimit(1).truncationMode(presentation.isFileOperation ? .middle : .tail)
                    .layoutPriority(1)
            }
            if !qualifiers.isEmpty {
                ViewThatFits(in: .horizontal) {
                    Text(verbatim: qualifiers.map { String(localized: $0) }.joined(separator: " · "))
                        .pikachuFont(.caption)
                            .foregroundStyle(secondary)
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            if tool.state != .completed {
                Text(tool.state.statusLabel).pikachuFont(.caption).foregroundStyle(tool.state.statusColor).fixedSize()
            }
            FlatDisclosureChevron(expanded: expanded).opacity(emphasized ? 1 : 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityDescription)
    }
}

private struct TranscriptToolDetails: View {
    let item: TranscriptItem
    let presentation: ToolCallPresentation
    let onShowOutput: ((ToolOutputSelection) -> Void)?
    let onPreviewImage: ((ImagePreviewSelection) -> Void)?
    let contentChanged: () -> Void
    @State private var rawExpanded = false

    var body: some View {
        if let tool = item.tool {
            let output = ToolOutputPresentation(output: tool.output, failed: tool.state == .failed)
            VStack(alignment: .leading, spacing: 8) {
                if tool.state == .failed {
                    if let diagnostic = output.diagnostic {
                        ToolMonospaceText(text: diagnostic).foregroundStyle(PikachuTheme.errorText)
                            .accessibilityIdentifier("tool-diagnostic")
                    } else {
                        Text(tool.state.statusLabel).pikachuFont(.callout, weight: .semibold)
                            .foregroundStyle(PikachuTheme.errorText)
                    }
                }

                switch presentation.parameters {
                case .command(let command):
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            ToolDetailLabel(title: "命令")
                            Spacer(minLength: 0)
                            ToolTextCopyButton(text: command, kind: .command).labelStyle(.iconOnly)
                        }
                        ToolMonospaceText(text: command)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .edit(let edit):
                    ToolEditDetails(edit: edit, completed: tool.state == .completed).equatable()
                case .read(let read):
                    ToolDetailLabel(title: "文件")
                    ToolMonospaceText(text: read.path)
                    if !read.rangeLabels.isEmpty {
                        Text(verbatim: read.rangeLabels.map { String(localized: $0) }.joined(separator: " · "))
                            .pikachuFont(.caption).foregroundStyle(PikachuTheme.secondaryText)
                    }
                case .list(let directory):
                    ToolDetailLabel(title: "目录")
                    ToolMonospaceText(text: presentation.object)
                    if let limit = directory.limit, limit >= 0 {
                        Text("最多 \(limit) 个条目").pikachuFont(.caption).foregroundStyle(PikachuTheme.secondaryText)
                    }
                case .write(let path):
                    if let path {
                        ToolDetailLabel(title: "文件")
                        ToolMonospaceText(text: path)
                    }
                case .search(let search), .find(let search):
                    ToolDetailLabel(title: "搜索模式")
                    ToolMonospaceText(text: search.pattern)
                    if let path = search.path, !path.isEmpty {
                        ToolDetailLabel(title: "搜索范围")
                        ToolMonospaceText(text: path)
                    }
                    if let glob = search.glob, !glob.isEmpty {
                        ToolDetailLabel(title: "文件筛选")
                        ToolMonospaceText(text: glob)
                    }
                    if let limit = search.limit, limit >= 0 {
                        Text("最多 \(limit) 条匹配").pikachuFont(.caption).foregroundStyle(PikachuTheme.secondaryText)
                    }
                case .raw:
                    EmptyView()
                }

                if tool.state == .completed {
                    Text(tool.state.statusLabel).pikachuFont(.caption).foregroundStyle(PikachuTheme.secondaryText)
                }
                if !tool.output.isEmpty || tool.truncated {
                    PikachuDivider()
                    ToolOutputSection(tool: tool, presentation: output, onShowOutput: onShowOutput)
                } else if tool.state != .running && tool.outputImage == nil {
                    Text("无输出").pikachuFont(.caption).foregroundStyle(PikachuTheme.secondaryText)
                }
                if let image = tool.outputImage {
                    ToolReadImageThumbnail(data: image, name: presentation.object,
                                           onPreviewImage: onPreviewImage, contentChanged: contentChanged)
                }

                if !tool.arguments.isEmpty {
                    DisclosureGroup(isExpanded: $rawExpanded) {
                        if rawExpanded {
                            if tool.argumentsTruncated == true {
                                Text("原始参数过长，仅显示开头。").pikachuFont(.caption)
                                    .foregroundStyle(PikachuTheme.warningText)
                                    .padding(.top, 4)
                            }
                            ToolMonospaceText(text: tool.arguments).padding(.top, 4)
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Text("原始参数")
                            FlatDisclosureChevron(expanded: rawExpanded)
                        }
                    }
                    .pikachuFont(.caption)
                    .disclosureGroupStyle(FlatDisclosureStyle(chevronEdge: nil))
                    .accessibilityIdentifier("tool-raw-parameters")
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .flatSurface(PikachuTheme.mutedSurface)
            .padding(.vertical, 4)
            .accessibilityIdentifier("tool-details-\(item.id)")
            .onChange(of: tool) { _, _ in contentChanged() }
            .onChange(of: rawExpanded) { _, _ in contentChanged() }
        }
    }
}

private struct ToolReadImageThumbnail: View {
    let data: Data
    let name: String
    var onPreviewImage: ((ImagePreviewSelection) -> Void)? = nil
    let contentChanged: () -> Void
    @State private var thumbnail: CGImage?
    @State private var thumbnailFailed = false

    private struct Request: Equatable {
        let data: Data
        let maxPixels: Int
    }
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let size: CGFloat = 120
        let request = Request(data: data, maxPixels: Int((size * displayScale).rounded(.up)))
        VStack(alignment: .leading, spacing: 0) {
            if let thumbnail {
                let imageView = Image(decorative: thumbnail, scale: displayScale)
                    .resizable().scaledToFit()
                    .frame(width: size, height: size)
                    .flatSurface(PikachuTheme.surface, radius: 8)
                    .contentShape(.rect(cornerRadius: 8))
                if let onPreviewImage {
                    Button { onPreviewImage(.toolResult(data, name: name)) } label: {
                        imageView
                    }
                    .buttonStyle(OverlayFeedbackButtonStyle(shape: RoundedRectangle(cornerRadius: 8)))
                    .accessibilityLabel("预览 \(name)")
                    .accessibilityIdentifier("tool-image-thumbnail")
                } else {
                    imageView
                        .accessibilityLabel(name)
                        .accessibilityIdentifier("tool-image-thumbnail")
                }
            } else if thumbnailFailed {
                Text("无法预览此图片。")
                    .pikachuFont(.caption)
                    .foregroundStyle(PikachuTheme.secondaryText)
            }
        }
        .task(id: request) {
            let image = await Task.detached(priority: .utility) {
                ImageAttachmentThumbnail.loadThumbnail(from: request.data, maxPixels: request.maxPixels)
            }.value
            guard !Task.isCancelled else { return }
            thumbnail = image
            thumbnailFailed = image == nil
            contentChanged()
        }
    }
}

private struct ToolEditDetails: View, Equatable {
    let edit: RuntimeTool.EditArguments
    let completed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ToolDetailLabel(title: "文件")
            ToolMonospaceText(text: edit.path)
            ToolDetailLabel(title: completed ? "修改前后" : "请求的修改")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(edit.edits.enumerated()), id: \.offset) { index, replacement in
                    if index > 0 { PikachuDivider() }
                    if let lines = ToolEditDiff.lines(for: replacement), !lines.isEmpty {
                        ToolDiffBlock(lines: lines)
                    } else {
                        Text("这处修改没有可显示的差异。").pikachuFont(.caption)
                            .foregroundStyle(PikachuTheme.secondaryText)
                            .padding(8)
                    }
                }
                if edit.omittedPreviewCount > 0 {
                    if !edit.edits.isEmpty { PikachuDivider() }
                    Text("有 \(edit.omittedPreviewCount) 处修改超出差异预览上限。")
                        .pikachuFont(.caption)
                        .foregroundStyle(PikachuTheme.secondaryText)
                        .padding(8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(.rect(cornerRadius: 6))
            .flatSurface(PikachuTheme.surface, radius: 6)
        }
    }
}

private struct ToolDiffBlock: View {
    let lines: [ToolEditDiff.Line]
    @State private var viewportWidth: CGFloat = 0

    var body: some View {
        TranscriptHorizontalScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // A diff snapshot is immutable. Offsets distinguish duplicate context lines.
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    let tint = color(for: line.kind)
                    let ending = line.ending.map { " [\($0.label)]" } ?? ""
                    Text(verbatim: marker(for: line.kind) + " " + line.text + ending)
                        .pikachuFont(.caption, design: .monospaced)
                        .foregroundStyle(tint)
                        .padding(.horizontal, 8)
                        .frame(minWidth: viewportWidth, maxWidth: .infinity, alignment: .leading)
                        .background {
                            Rectangle().fill(line.kind == .context ? Color.clear : tint.opacity(0.10))
                        }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .textSelection(.enabled)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.containerSize.width
        } action: { _, width in
            viewportWidth = width
        }
        .defaultScrollAnchor(.leading, for: .initialOffset)
        .defaultScrollAnchor(.leading, for: .alignment)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    private func color(for kind: ToolEditDiff.Line.Kind) -> Color {
        switch kind {
        case .context: PikachuTheme.secondaryText
        case .removal: PikachuTheme.errorText
        case .insertion: PikachuTheme.runningText
        }
    }

    private func marker(for kind: ToolEditDiff.Line.Kind) -> String {
        switch kind {
        case .context: " "
        case .removal: "−"
        case .insertion: "+"
        }
    }
}

private struct ToolDetailLabel: View {
    let title: LocalizedStringResource

    var body: some View {
        Text(title).pikachuFont(.caption, weight: .semibold).foregroundStyle(PikachuTheme.secondaryText)
    }
}

private struct ToolMonospaceText: View {
    let text: String

    var body: some View {
        TranscriptHorizontalScrollView {
            Text(verbatim: text).pikachuFont(.caption, design: .monospaced)
                .fixedSize(horizontal: true, vertical: false).textSelection(.enabled)
        }
        .defaultScrollAnchor(.leading)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }
}

private struct ToolOutputSection: View {
    let tool: RuntimeTool
    let presentation: ToolOutputPresentation
    let onShowOutput: ((ToolOutputSelection) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ToolDetailLabel(title: "输出")
                Spacer(minLength: 0)
                if !tool.output.isEmpty {
                    ToolTextCopyButton(text: tool.output, kind: .output).labelStyle(.iconOnly)
                }
            }
            if !presentation.preview.isEmpty {
                ToolMonospaceText(text: presentation.preview)
                    .accessibilityIdentifier("tool-output-preview")
            }
            if tool.truncated { ToolOutputTruncationNotice() }
            if (presentation.hasMore || tool.truncated), let onShowOutput, !tool.output.isEmpty {
                Button {
                    onShowOutput(.init(output: tool.output, truncated: tool.truncated))
                } label: {
                    HStack(spacing: 7) {
                        Text(tool.truncated ? "已保留输出" : "完整输出")
                        Image(systemName: "chevron.forward")
                            .accessibilityHidden(true)
                    }
                    .padding(.vertical, 5)
                }
                .buttonStyle(FlatControlButtonStyle(inset: false))
                .pikachuFont(.caption)
                .accessibilityIdentifier("tool-show-output")
            }
        }
    }
}

struct ToolOutputSelection: Identifiable {
    let id = UUID()
    let output: String
    let truncated: Bool
}

struct ToolOutputPanel: View {
    let selection: ToolOutputSelection
    @Environment(\.dismiss) private var dismiss
    @State private var wrapsLines = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(selection.truncated ? "已保留的工具输出" : "工具输出")
                    .pikachuFont(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button("自动换行") { wrapsLines.toggle() }
                    .pikachuFont(.caption)
                    .buttonStyle(FlatControlButtonStyle(isSelected: wrapsLines))
                    .accessibilityValue(wrapsLines ? Text("已开启") : Text("已关闭"))
                    .accessibilityAddTraits(wrapsLines ? .isSelected : [])
                    .accessibilityIdentifier("tool-output-wrap-lines")
                ToolTextCopyButton(text: selection.output, kind: .output).labelStyle(.iconOnly)
                Button { dismiss() } label: {
                    IconButtonLabel(systemName: "xmark", weight: .medium)
                }
                    .buttonStyle(FlatControlButtonStyle(inset: false))
                    .keyboardShortcut(.cancelAction)
                    .help("关闭输出")
                    .accessibilityLabel("关闭输出")
                    .accessibilityIdentifier("tool-close-output")
            }
            if selection.truncated { ToolOutputTruncationNotice() }
            ToolOutputTextView(text: selection.output, wrapsLines: wrapsLines)
                .clipShape(.rect(cornerRadius: 8))
                .flatSurface(PikachuTheme.mutedSurface)
        }
        .padding(16)
        .frame(minWidth: 360, idealWidth: 680, minHeight: 260, idealHeight: 440)
        .background(PikachuTheme.pageBackground)
        .presentationBackground(PikachuTheme.pageBackground)
    }
}

private struct ToolOutputTruncationNotice: View {
    var body: some View {
        Text("输出过长，仅显示部分内容。").pikachuFont(.caption)
            .foregroundStyle(PikachuTheme.warningText)
            .accessibilityIdentifier("tool-output-truncated")
    }
}

struct ToolTextCopyButton: View {
    enum Kind {
        case command, output

        var label: LocalizedStringResource {
            switch self {
            case .command: "复制命令"
            case .output: "复制输出"
            }
        }

        var identifier: String {
            switch self {
            case .command: "tool-copy-command"
            case .output: "tool-copy-output"
            }
        }
    }

    let text: String
    let kind: Kind

    var body: some View {
        Button { copy(to: .general) } label: {
            Label { Text(kind.label) } icon: { Image(systemName: "doc.on.doc") }
                .pikachuFont(.caption)
        }
        .buttonStyle(FlatControlButtonStyle())
        .help(Text(kind.label))
        .accessibilityLabel(Text(kind.label))
        .accessibilityIdentifier(kind.identifier)
    }

    func copy(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
