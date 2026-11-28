import AppKit
import SwiftUI
import AgentRuntimeCore
import OrchestrationCore

struct ToolRow: View {
    let item: TranscriptItem
    @Binding var expanded: Bool
    var workspaceDirectory: URL? = nil
    var onOpenFile: ((URL) -> Void)? = nil
    var onOpenToolDiff: ((TranscriptItem) -> Void)? = nil
    var onShowOutput: ((ToolOutputSelection) -> Void)? = nil
    var onPreviewImage: ((ImagePreviewSelection) -> Void)? = nil
    var showsRunningEffect = false
    var contentChanged: () -> Void = {}

    var body: some View {
        if let tool = item.toolSummary {
            let presentation = ToolCallPresentation(tool)
            ToolCallDisclosure(isExpanded: $expanded, isRunning: showsRunningEffect && tool.state == .running) {
                TranscriptToolDetails(
                    item: item,
                    presentation: presentation,
                    workspaceDirectory: workspaceDirectory,
                    onOpenFile: onOpenFile,
                    onOpenToolDiff: onOpenToolDiff,
                    onShowOutput: onShowOutput,
                    onPreviewImage: onPreviewImage,
                    contentChanged: contentChanged
                )
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
                    .foregroundStyle(emphasized || isExpanded ? ZivviTheme.primaryText : ZivviTheme.secondaryText)
                    .padding(.horizontal, 6)
                    .frame(minHeight: 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        emphasized ? ZivviTheme.controlHover : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .overlay {
                        if isRunning && !reduceMotion { ToolCallLightning() }
                    }
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
                        : ZivviTheme.iconYellow
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
        let summaryText = presentation.primarySummaryText
        HStack(spacing: 7) {
            ToolCallIcon(glyph: ToolCallKind(name: tool.name).glyph)
                .foregroundStyle(emphasized || expanded ? ZivviTheme.primaryText : ZivviTheme.tertiaryText)
            Text(verbatim: summaryText)
                .zivviFont(.callout)
                .foregroundStyle(emphasized || expanded || tool.state == .running ? ZivviTheme.primaryText : ZivviTheme.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 6)
            // Always reserve space for the disclosure chevron to eliminate horizontal jitter on hover/expand.
            FlatDisclosureChevron(expanded: expanded)
                .frame(width: 12, alignment: .center)
                .opacity(expanded || emphasized ? 1 : 0)
            statusIndicator(for: tool.state)
                .frame(width: 16, alignment: .center)
        }
        .padding(.vertical, 2)
        .help(summaryText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityDescription)
    }

    @ViewBuilder
    private func statusIndicator(for state: ToolState) -> some View {
        switch state {
        case .running:
            FlatProgressView()
                .controlSize(.mini)
                .accessibilityLabel("执行中")
        case .failed:
            LightningIconView(.exclamationmarkCircleFill, size: 13)
                .accessibilityHidden(false)
                .accessibilityLabel("失败")
        case .interrupted:
            LightningIconView(.stopCircle, size: 13)
                .accessibilityHidden(false)
                .accessibilityLabel("已中断")
        case .completed:
            Color.clear.frame(width: 1, height: 1)
        }
    }
}

private struct TranscriptToolDetails: View {
    let item: TranscriptItem
    let presentation: ToolCallPresentation
    let workspaceDirectory: URL?
    let onOpenFile: ((URL) -> Void)?
    let onOpenToolDiff: ((TranscriptItem) -> Void)?
    let onShowOutput: ((ToolOutputSelection) -> Void)?
    let onPreviewImage: ((ImagePreviewSelection) -> Void)?
    let contentChanged: () -> Void
    @State private var rawExpanded = false

    private func openableURL(for rawPath: String) -> URL? {
        if rawPath.hasPrefix("/") {
            return URL(fileURLWithPath: rawPath)
        }
        return TranscriptFileLinks.openableFileURL(forRelativePath: rawPath, workspaceDirectory: workspaceDirectory)
    }

    private func displayPath(_ rawPath: String) -> String {
        guard let dir = workspaceDirectory?.standardizedFileURL.path else { return rawPath }
        let prefix = dir.hasSuffix("/") ? dir : dir + "/"
        if rawPath.hasPrefix(prefix) {
            return String(rawPath.dropFirst(prefix.count))
        }
        return rawPath
    }

    @ViewBuilder
    private func pathRow(_ rawPath: String) -> some View {
        let shown = displayPath(rawPath)
        let url = openableURL(for: rawPath)
        HStack(spacing: 6) {
            if let url, let onOpenFile {
                Button {
                    onOpenFile(url)
                } label: {
                    Text(verbatim: shown)
                        .zivviFont(.caption, design: .monospaced)
                        .underline()
                        .foregroundStyle(MarkdownColors.link)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .help(rawPath)
            } else {
                ToolMonospaceText(text: shown)
                    .help(rawPath)
            }
            Spacer(minLength: 4)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(rawPath, forType: .string)
            } label: {
                LightningIconView(.docOnDoc, size: 12)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(FlatControlButtonStyle(inset: false, cornerRadius: 5))
            .help("复制完整路径")
            .accessibilityLabel("复制完整路径")
        }
    }

    var body: some View {
        if let tool = item.tool {
            let output = ToolOutputPresentation(output: tool.output, failed: tool.state == .failed)
            VStack(alignment: .leading, spacing: 8) {
                if tool.state == .failed {
                    if let diagnostic = output.diagnostic {
                        ToolMonospaceText(text: diagnostic).foregroundStyle(ZivviTheme.errorText)
                            .accessibilityIdentifier("tool-diagnostic")
                    } else {
                        Text(tool.state.statusLabel).zivviFont(.callout, weight: .semibold)
                            .foregroundStyle(ZivviTheme.errorText)
                    }
                }

                switch presentation.parameters {
                case .command(let command):
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            ToolDetailLabel(title: "Shell")
                            Spacer(minLength: 0)
                            ToolTextCopyButton(text: command, kind: .command).labelStyle(.iconOnly)
                        }
                        ToolMonospaceText(text: command)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .edit(let edit):
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            ToolDetailLabel(title: "文件")
                            Spacer(minLength: 4)
                            if let onOpenToolDiff, !ToolEditDiff.preview(for: edit).isEmpty {
                                Button("在编辑区查看历史变更") {
                                    onOpenToolDiff(item)
                                }
                                .buttonStyle(FlatControlButtonStyle(treatment: .outlined, height: 22))
                                .zivviFont(.caption2)
                            }
                        }
                        pathRow(edit.path)
                        ToolEditDetails(edit: edit, completed: tool.state == .completed).equatable()
                    }
                case .read(let read):
                    ToolDetailLabel(title: "读取文件")
                    pathRow(read.path)
                    if !read.rangeLabels.isEmpty {
                        Text(verbatim: read.rangeLabels.map { String(localized: $0) }.joined(separator: " · "))
                            .zivviFont(.caption).foregroundStyle(ZivviTheme.secondaryText)
                    }
                case .list(let directory):
                    ToolDetailLabel(title: "目录")
                    ToolMonospaceText(text: presentation.object)
                    if let limit = directory.limit, limit >= 0 {
                        Text("最多 \(limit) 个条目").zivviFont(.caption).foregroundStyle(ZivviTheme.secondaryText)
                    }
                case .write(let path):
                    if let path {
                        ToolDetailLabel(title: "写入文件")
                        pathRow(path)
                    }
                case .search(let search), .find(let search):
                    ToolDetailLabel(title: "搜索条件")
                    ToolMonospaceText(text: search.pattern)
                    if let path = search.path, !path.isEmpty {
                        ToolDetailLabel(title: "范围")
                        ToolMonospaceText(text: path)
                    }
                    if let glob = search.glob, !glob.isEmpty {
                        ToolDetailLabel(title: "文件筛选")
                        ToolMonospaceText(text: glob)
                    }
                    if let limit = search.limit, limit >= 0 {
                        Text("最多 \(limit) 条匹配").zivviFont(.caption).foregroundStyle(ZivviTheme.secondaryText)
                    }
                case .raw:
                    let entries = presentation.structuredRawEntries
                    if !entries.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(entries.prefix(6), id: \.key) { entry in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(verbatim: entry.key)
                                        .zivviFont(.caption2, weight: .medium, design: .monospaced)
                                        .foregroundStyle(ZivviTheme.secondaryText)
                                    Text(verbatim: entry.value)
                                        .zivviFont(.caption, design: .monospaced)
                                        .foregroundStyle(ZivviTheme.primaryText)
                                        .lineLimit(3)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }

                if !tool.output.isEmpty || tool.truncated {
                    ZivviDivider(color: ZivviTheme.subtleDivider)
                    ToolOutputSection(item: item, tool: tool, presentation: output, onShowOutput: onShowOutput)
                } else if tool.state != .running && tool.outputImage == nil {
                    Text("无输出").zivviFont(.caption).foregroundStyle(ZivviTheme.tertiaryText)
                }
                if let image = tool.outputImage {
                    TranscriptImageThumbnail(data: image, name: presentation.object, identifier: "tool-image-thumbnail",
                                             onPreviewImage: onPreviewImage.map { preview in
                                                 { preview($0.trackingToolOutput(item)) }
                                             }, contentChanged: contentChanged)
                }

                if !tool.arguments.isEmpty {
                    DisclosureGroup(isExpanded: $rawExpanded) {
                        if rawExpanded {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: "Tool: \(tool.name)")
                                    .zivviFont(.caption2, design: .monospaced)
                                    .foregroundStyle(ZivviTheme.tertiaryText)
                                if tool.argumentsTruncated == true {
                                    Text("原始参数过长，仅显示开头。").zivviFont(.caption)
                                        .foregroundStyle(ZivviTheme.warningText)
                                }
                                ToolMonospaceText(text: tool.arguments)
                            }
                            .padding(.top, 4)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            FlatDisclosureChevron(expanded: rawExpanded)
                            Text("技术详情")
                                .foregroundStyle(ZivviTheme.secondaryText)
                        }
                    }
                    .zivviFont(.caption)
                    .disclosureGroupStyle(FlatDisclosureStyle(chevronEdge: nil))
                    .accessibilityIdentifier("tool-raw-parameters")
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ZivviTheme.mutedSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.leading, 6)
            .padding(.vertical, 3)
            .accessibilityIdentifier("tool-details-\(item.id)")
            .onChange(of: tool) { _, _ in contentChanged() }
            .onChange(of: rawExpanded) { _, _ in contentChanged() }
        }
    }
}

struct TranscriptImageThumbnail: View {
    let data: Data
    let name: String
    let identifier: String
    var size: CGFloat = ImageAttachmentThumbnail.defaultSize
    var onPreviewImage: ((ImagePreviewSelection) -> Void)? = nil
    let contentChanged: () -> Void
    @State private var thumbnail: (request: Request, image: CGImage?)?

    private struct Request: Equatable {
        let data: Data
        let maxPixels: Int
    }
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let request = Request(data: data, maxPixels: Int((size * displayScale).rounded(.up)))
        VStack(alignment: .leading, spacing: 0) {
            if let thumbnail, thumbnail.request == request, let image = thumbnail.image {
                let imageView = Image(decorative: image, scale: displayScale)
                    .resizable().scaledToFit()
                    .frame(width: size, height: size)
                    .flatSurface(ZivviTheme.surface, radius: 8)
                    .contentShape(.rect(cornerRadius: 8))
                if let onPreviewImage {
                    Button { onPreviewImage(.embedded(data, name: name)) } label: {
                        imageView
                    }
                    .buttonStyle(OverlayFeedbackButtonStyle(shape: RoundedRectangle(cornerRadius: 8)))
                    .accessibilityLabel("预览 \(name)")
                    .accessibilityIdentifier(identifier)
                } else {
                    imageView
                        .accessibilityLabel(name)
                        .accessibilityIdentifier(identifier)
                }
            } else if thumbnail?.request == request {
                Text("无法预览此图片。")
                    .zivviFont(.caption)
                    .foregroundStyle(ZivviTheme.secondaryText)
            }
        }
        .task(id: request) {
            let image = await Task.detached(priority: .utility) {
                ImageAttachmentThumbnail.loadThumbnail(from: request.data, maxPixels: request.maxPixels)
            }.value
            guard !Task.isCancelled else { return }
            thumbnail = (request, image)
            contentChanged()
        }
    }
}

private struct ToolEditDetails: View, Equatable {
    let edit: RuntimeTool.EditArguments
    let completed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ToolDetailLabel(title: completed ? "修改前后" : "请求的修改")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(edit.edits.enumerated()), id: \.offset) { index, replacement in
                    if index > 0 { ZivviDivider() }
                    if let lines = ToolEditDiff.lines(for: replacement), !lines.isEmpty {
                        ToolDiffBlock(lines: lines)
                    } else {
                        Text("这处修改没有可显示的差异。").zivviFont(.caption)
                            .foregroundStyle(ZivviTheme.secondaryText)
                            .padding(8)
                    }
                }
                if edit.omittedPreviewCount > 0 {
                    if !edit.edits.isEmpty { ZivviDivider() }
                    Text("有 \(edit.omittedPreviewCount) 处修改超出差异预览上限。")
                        .zivviFont(.caption)
                        .foregroundStyle(ZivviTheme.secondaryText)
                        .padding(8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(.rect(cornerRadius: 6))
            .flatSurface(ZivviTheme.surface, radius: 6)
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
                        .zivviFont(.caption, design: .monospaced)
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
        case .context: ZivviTheme.secondaryText
        case .removal: ZivviTheme.diffDeletion
        case .insertion: ZivviTheme.diffAddition
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
        Text(title).zivviFont(.caption, weight: .semibold).foregroundStyle(ZivviTheme.secondaryText)
    }
}

private struct ToolMonospaceText: View {
    let text: String

    var body: some View {
        TranscriptHorizontalScrollView {
            Text(verbatim: text).zivviFont(.caption, design: .monospaced)
                .fixedSize(horizontal: true, vertical: false).textSelection(.enabled)
        }
        .defaultScrollAnchor(.leading)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }
}

private struct ToolOutputSection: View {
    let item: TranscriptItem
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
                    onShowOutput(.init(item: item))
                } label: {
                    HStack(spacing: 7) {
                        Text(tool.truncated ? "已保留输出" : "完整输出")
                        LightningIconView(.chevronForward, size: 11)
                    }
                    .padding(.vertical, 5)
                }
                .buttonStyle(FlatControlButtonStyle(inset: false))
                .zivviFont(.caption)
                .accessibilityIdentifier("tool-show-output")
            }
        }
    }
}

@MainActor struct ToolOutputSelection: Identifiable {
    let id = UUID()
    var source: ToolResultSource
    var output: String { source.current?.tool?.output ?? "" }
    var truncated: Bool { source.current?.tool?.truncated == true }

    init(item: TranscriptItem) {
        source = ToolResultSource(item: item)
    }
}

struct ToolOutputPanel: View {
    let selection: ToolOutputSelection
    @Environment(\.dismiss) private var dismiss
    @State private var wrapsLines = true

    var body: some View {
        VStack(alignment: .leading, spacing: ZivviSpacing.dialogSectionGap) {
            VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
                header
                if selection.truncated { ToolOutputTruncationNotice() }
            }
            if selection.output.isEmpty {
                Text("无输出")
                    .zivviFont(.callout)
                    .foregroundStyle(ZivviTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ToolOutputTextView(text: selection.output, wrapsLines: wrapsLines)
                    .clipShape(.rect(cornerRadius: 8))
                    .flatSurface(ZivviTheme.mutedSurface)
            }
        }
        .padding(16)
        .frame(minWidth: 360, idealWidth: 680, minHeight: 260, idealHeight: 440)
        .background(ZivviTheme.pageBackground)
        .presentationBackground(ZivviTheme.pageBackground)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(selection.truncated ? "已保留的工具输出" : "工具输出")
                .zivviFont(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Button("自动换行") { wrapsLines.toggle() }
                .zivviFont(.caption)
                .buttonStyle(FlatControlButtonStyle(isSelected: wrapsLines))
                .accessibilityValue(wrapsLines ? Text("已开启") : Text("已关闭"))
                .accessibilityAddTraits(wrapsLines ? .isSelected : [])
                .accessibilityIdentifier("tool-output-wrap-lines")
                .disabled(selection.output.isEmpty)
            if !selection.output.isEmpty {
                ToolTextCopyButton(text: selection.output, kind: .output).labelStyle(.iconOnly)
            }
            Button { dismiss() } label: {
                IconButtonLabel(systemName: "xmark", weight: .medium)
            }
                .buttonStyle(FlatControlButtonStyle(inset: false))
                .keyboardShortcut(.cancelAction)
                .help("关闭输出")
                .accessibilityLabel("关闭输出")
                .accessibilityIdentifier("tool-close-output")
        }
    }
}

private struct ToolOutputTruncationNotice: View {
    var body: some View {
        Text("输出过长，仅显示部分内容。").zivviFont(.caption)
            .foregroundStyle(ZivviTheme.warningText)
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
            LightningLabel(icon: .docOnDoc, size: 12) { Text(kind.label) }
                .zivviFont(.caption)
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
