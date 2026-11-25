import AppKit
import CoreText
import SwiftUI
import OrchestrationCore

private extension EnvironmentValues {
    @Entry var markdownInteractiveLinks: Set<URL> = []
}

private func isPreviewWebOrMailLink(_ url: URL) -> Bool {
    guard url.scheme != nil, !url.isFileURL else { return false }
    return TranscriptFileOpener.clickedLink(for: url, workspaceDirectory: nil) == .system
}

enum MarkdownLinkPolicy {
    case transcript
    case projectPreview
}

struct MarkdownContent: View {
    @Environment(\.pikachuTypography) private var typography
    @State private var cache = MarkdownContentCache()
    @State private var liveCache = MarkdownContentCache()
    @State private var live = MarkdownStreamingState()
    let text: String
    let streaming: Bool
    let width: CGFloat
    var profile: MarkdownProfile = .conversation
    var hostWidth: CGFloat? = nil
    var workspaceDirectory: URL? = nil
    var onOpenFile: ((URL) -> Void)? = nil
    var linkPolicy: MarkdownLinkPolicy = .transcript
    var imageLoader: MarkdownImageLoader? = nil
    var markdownStore: TranscriptMarkdownStore? = nil
    var contentChanged: (() -> Void)? = nil

    var body: some View {
        let style = MarkdownStyle(profile: profile, width: MarkdownWidth(hostWidth ?? width), typography: typography)
        let snapshot = live.snapshot
        let finalSnapshot = !streaming && snapshot?.matches(text) == true ? snapshot : nil
        let interim = streaming || (live.isActive && finalSnapshot == nil)
        let layout = resolvedLayout(interim: interim, snapshot: interim ? snapshot : finalSnapshot)
        Group {
            if let layout, !layout.blocks.isEmpty {
                MarkdownBlockStack(blocks: layout.blocks, width: width, style: style, tableWidths: layout.tableWidths,
                                   tracksReadingPosition: profile == .editorial)
            } else {
                Text(verbatim: text)
                    .font(Font(style.body.font))
                    .lineSpacing(style.body.lineSpacing())
                    .textSelection(.enabled)
            }
        }
        .foregroundStyle(MarkdownColors.text)
        .environment(\.markdownInteractiveLinks, layout?.interactiveLinks ?? [])
        .environment(\.markdownImageLoader, imageLoader)
        .environment(\.openURL, linkPolicy == .projectPreview ? Self.previewLinks :
            TranscriptFileOpener.openAction(workspaceDirectory: workspaceDirectory, openFile: onOpenFile))
        .onChange(of: MarkdownInput(text: text, streaming: streaming), initial: true) { _, input in
            live.submit(input)
        }
        .onChange(of: snapshot?.revision) { _, revision in
            if revision != nil { contentChanged?() }
        }
        .onChange(of: finalSnapshot?.revision) { _, revision in
            // resolvedLayout has already transferred the final parse to the completed cache.
            if let revision, live.releaseCompletedSnapshot(revision: revision) {
                liveCache.removeAll()
            }
        }
        .onDisappear {
            live.reset()
            liveCache.removeAll()
        }
    }

    private func resolvedLayout(interim: Bool, snapshot: MarkdownStreamingState.Snapshot?) -> MarkdownContentCache.Layout? {
        if interim {
            guard let snapshot else { return nil }
            // Keep just one live layout. File-system link enrichment is applied
            // through the completed store when the original source settles.
            return liveCache.layout(for: snapshot.source, typography: typography,
                                    enrichFileLinks: false, parsedBlocks: snapshot.blocks)
        }
        let enrichFileLinks = linkPolicy == .transcript
        let parsedBlocks = snapshot?.blocks
        if let markdownStore {
            let result = markdownStore.layout(for: text, typography: typography, workspaceDirectory: workspaceDirectory,
                                              enrichFileLinks: enrichFileLinks, parsedBlocks: parsedBlocks)
            _ = result.revision.version
            return result.layout
        }
        return cache.layout(for: text, typography: typography, workspaceDirectory: workspaceDirectory,
                            enrichFileLinks: enrichFileLinks, parsedBlocks: parsedBlocks)
    }

    // Disk previews render without resolving references to local files. Only
    // explicitly clicked web and mail links can leave the preview.
    private static let previewLinks = OpenURLAction { url in
        isPreviewWebOrMailLink(url) ? .systemAction : .discarded
    }
}

/// Shared cross-reuse Markdown layout cache with TTL-cached async file-link validation.
@MainActor final class TranscriptMarkdownStore {
    @MainActor @Observable final class LinkRevision {
        var version = 0
    }

    struct Result {
        let layout: MarkdownContentCache.Layout
        let revision: LinkRevision
    }

    private struct CacheKey: Hashable {
        let utf8Count: Int
        let utf8Hash: Int
        let workspaceDirectory: URL?
        let enrichFileLinks: Bool

        init(text: String, workspaceDirectory: URL?, enrichFileLinks: Bool) {
            var count = 0
            var hasher = Hasher()
            for byte in text.utf8 {
                count += 1
                hasher.combine(byte)
            }
            self.utf8Count = count
            self.utf8Hash = hasher.finalize()
            self.workspaceDirectory = workspaceDirectory
            self.enrichFileLinks = enrichFileLinks
        }
    }

    @MainActor private final class Entry {
        let key: CacheKey
        let source: String
        let baseBlocks: [MarkdownBlock]
        var tableWidths: [Int: [CGFloat]]
        var typography: PikachuTypography
        let workspaceDirectory: URL?
        let enrichFileLinks: Bool
        var layout: MarkdownContentCache.Layout
        var pendingPaths: Set<String>
        let revision: LinkRevision
        var lastAccess: UInt64

        init(
            key: CacheKey,
            source: String,
            baseBlocks: [MarkdownBlock],
            tableWidths: [Int: [CGFloat]],
            typography: PikachuTypography,
            workspaceDirectory: URL?,
            enrichFileLinks: Bool,
            layout: MarkdownContentCache.Layout,
            pendingPaths: Set<String>,
            lastAccess: UInt64
        ) {
            self.key = key
            self.source = source
            self.baseBlocks = baseBlocks
            self.tableWidths = tableWidths
            self.typography = typography
            self.workspaceDirectory = workspaceDirectory
            self.enrichFileLinks = enrichFileLinks
            self.layout = layout
            self.pendingPaths = pendingPaths
            self.revision = LinkRevision()
            self.lastAccess = lastAccess
        }
    }

    private let capacity: Int
    private let pathTTL: Duration
    private let checkFileExists: @Sendable (String) -> Bool
    private var accessCounter: UInt64 = 0
    private var entries: [CacheKey: [Entry]] = [:]
    private var entryCount = 0
    private var pathExistence: [String: (exists: Bool, checkedAt: ContinuousClock.Instant)] = [:]
    private var inFlightPaths: Set<String> = []
    private var verificationTasks: [UUID: Task<Void, Never>] = [:]

    var cachedLayoutCount: Int { entryCount }
    var hasPendingLinkChecks: Bool { !inFlightPaths.isEmpty }

    init(
        capacity: Int = 256,
        pathTTL: Duration = .seconds(5),
        checkFileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.capacity = max(1, capacity)
        self.pathTTL = pathTTL
        self.checkFileExists = checkFileExists
    }

    func clear() {
        for task in verificationTasks.values { task.cancel() }
        verificationTasks.removeAll()
        entries.removeAll()
        entryCount = 0
        pathExistence.removeAll()
        inFlightPaths.removeAll()
    }

    func clearPathCache() {
        pathExistence.removeAll()
    }

    func layout(
        for text: String,
        typography: PikachuTypography,
        workspaceDirectory: URL? = nil,
        enrichFileLinks: Bool = true,
        parsedBlocks: [MarkdownBlock]? = nil
    ) -> Result {
        let key = CacheKey(text: text, workspaceDirectory: workspaceDirectory, enrichFileLinks: enrichFileLinks)
        accessCounter &+= 1
        if let bucket = entries[key],
           let existing = bucket.first(where: { $0.source.utf8.elementsEqual(text.utf8) }) {
            existing.lastAccess = accessCounter
            if existing.typography != typography {
                var tableWidths: [Int: [CGFloat]] = [:]
                MarkdownContentCache.measureTables(in: existing.baseBlocks, typography: typography, widths: &tableWidths)
                existing.typography = typography
                existing.tableWidths = tableWidths
                existing.layout = .init(blocks: existing.layout.blocks, tableWidths: tableWidths,
                                        interactiveLinks: existing.layout.interactiveLinks)
            }
            return Result(layout: existing.layout, revision: existing.revision)
        }

        let baseBlocks = parsedBlocks ?? MarkdownBlocks.parse(text)
        var tableWidths: [Int: [CGFloat]] = [:]
        MarkdownContentCache.measureTables(in: baseBlocks, typography: typography, widths: &tableWidths)

        var pending: Set<String> = []
        let now = ContinuousClock.now
        let resolved = enrichAndCollectPending(
            baseBlocks: baseBlocks,
            tableWidths: tableWidths,
            workspaceDirectory: workspaceDirectory,
            enrichFileLinks: enrichFileLinks,
            now: now,
            pending: &pending
        )

        let entry = Entry(
            key: key,
            source: text,
            baseBlocks: baseBlocks,
            tableWidths: tableWidths,
            typography: typography,
            workspaceDirectory: workspaceDirectory,
            enrichFileLinks: enrichFileLinks,
            layout: resolved,
            pendingPaths: pending,
            lastAccess: accessCounter
        )
        entries[key, default: []].append(entry)
        entryCount += 1
        evictIfNeeded()
        scheduleVerificationIfNeeded(for: pending)
        return Result(layout: entry.layout, revision: entry.revision)
    }

    private func enrichAndCollectPending(
        baseBlocks: [MarkdownBlock],
        tableWidths: [Int: [CGFloat]],
        workspaceDirectory: URL?,
        enrichFileLinks: Bool,
        now: ContinuousClock.Instant,
        pending: inout Set<String>
    ) -> MarkdownContentCache.Layout {
        let fileExistsClosure: (String) -> Bool = { path in
            if let cached = self.pathExistence[path], now - cached.checkedAt < self.pathTTL {
                return cached.exists
            }
            pending.insert(path)
            return false
        }
        let blocks = enrichFileLinks
            ? TranscriptFileLinks.enrich(baseBlocks, workspaceDirectory: workspaceDirectory, fileExists: fileExistsClosure)
            : baseBlocks
        let interactiveLinks = MarkdownContentCache.resolveInteractiveLinks(
            in: blocks,
            workspaceDirectory: workspaceDirectory,
            enrichFileLinks: enrichFileLinks,
            fileExists: fileExistsClosure
        )
        return MarkdownContentCache.Layout(blocks: blocks, tableWidths: tableWidths, interactiveLinks: interactiveLinks)
    }

    private func scheduleVerificationIfNeeded(for paths: Set<String>) {
        let newPaths = paths.filter { !inFlightPaths.contains($0) }
        guard !newPaths.isEmpty else { return }
        inFlightPaths.formUnion(newPaths)
        let batch = Array(newPaths)
        let check = checkFileExists
        let taskID = UUID()
        let task = Task { [weak self] in
            let results = await Task.detached(priority: .utility) {
                batch.map { ($0, check($0)) }
            }.value
            guard !Task.isCancelled, let self else { return }
            self.verificationTasks.removeValue(forKey: taskID)
            self.applyVerificationResults(results)
        }
        verificationTasks[taskID] = task
    }

    private func applyVerificationResults(_ results: [(String, Bool)]) {
        let now = ContinuousClock.now
        var resolvedPaths: Set<String> = []
        var existingPaths: Set<String> = []
        for (path, exists) in results {
            inFlightPaths.remove(path)
            pathExistence[path] = (exists, now)
            resolvedPaths.insert(path)
            if exists { existingPaths.insert(path) }
        }
        if pathExistence.count > 4_096 {
            pathExistence = pathExistence.filter { now - $0.value.checkedAt < pathTTL }
        }

        for bucket in entries.values {
            for entry in bucket where !entry.pendingPaths.isEmpty {
                let intersection = entry.pendingPaths.intersection(resolvedPaths)
                guard !intersection.isEmpty else { continue }
                entry.pendingPaths.subtract(intersection)
                guard !intersection.isDisjoint(with: existingPaths) else { continue }
                var stillPending: Set<String> = []
                entry.layout = enrichAndCollectPending(
                    baseBlocks: entry.baseBlocks,
                    tableWidths: entry.tableWidths,
                    workspaceDirectory: entry.workspaceDirectory,
                    enrichFileLinks: entry.enrichFileLinks,
                    now: now,
                    pending: &stillPending
                )
                entry.pendingPaths.formUnion(stillPending)
                entry.revision.version &+= 1
                scheduleVerificationIfNeeded(for: stillPending)
            }
        }
    }

    private func evictIfNeeded() {
        while entryCount > capacity {
            var oldestKey: CacheKey?
            var oldestIndex: Int?
            var oldestStamp = UInt64.max
            for (key, bucket) in entries {
                for (index, entry) in bucket.enumerated() where entry.lastAccess < oldestStamp {
                    oldestStamp = entry.lastAccess
                    oldestKey = key
                    oldestIndex = index
                }
            }
            guard let key = oldestKey, let index = oldestIndex else { break }
            entries[key]?.remove(at: index)
            if entries[key]?.isEmpty == true {
                entries.removeValue(forKey: key)
            }
            entryCount -= 1
        }
    }
}

@MainActor final class MarkdownContentCache {
    struct Layout {
        let blocks: [MarkdownBlock]
        let tableWidths: [Int: [CGFloat]]
        let interactiveLinks: Set<URL>
    }

    private var entry: (source: String, typography: PikachuTypography, workspaceDirectory: URL?,
                        enrichFileLinks: Bool, layout: Layout)?
    private var tableMeasurements: [Int: TableMeasurement] = [:]

    func removeAll() {
        entry = nil
        tableMeasurements.removeAll()
    }

    func layout(for text: String, typography: PikachuTypography, workspaceDirectory: URL? = nil,
                enrichFileLinks: Bool = true, parsedBlocks: [MarkdownBlock]? = nil) -> Layout {
        let previous = entry.flatMap {
            $0.workspaceDirectory == workspaceDirectory && $0.enrichFileLinks == enrichFileLinks
                && $0.source.utf8.elementsEqual(text.utf8) ? $0 : nil
        }
        if let previous, previous.typography == typography {
            return previous.layout
        }

        let blocks: [MarkdownBlock]
        if let previous {
            blocks = previous.layout.blocks
        } else {
            let parsed = parsedBlocks ?? MarkdownBlocks.parse(text)
            blocks = enrichFileLinks ? TranscriptFileLinks.enrich(parsed, workspaceDirectory: workspaceDirectory) : parsed
        }
        let interactiveLinks = previous?.layout.interactiveLinks
            ?? Self.resolveInteractiveLinks(in: blocks, workspaceDirectory: workspaceDirectory, enrichFileLinks: enrichFileLinks)
        let previousMeasurements = entry?.typography == typography ? tableMeasurements : [:]
        tableMeasurements = Self.tableMeasurements(in: blocks, typography: typography, reusing: previousMeasurements)
        let layout = Layout(blocks: blocks, tableWidths: tableMeasurements.mapValues(\.widths), interactiveLinks: interactiveLinks)
        entry = (source: text, typography: typography, workspaceDirectory: workspaceDirectory,
                 enrichFileLinks: enrichFileLinks, layout: layout)
        return layout
    }

    static func resolveInteractiveLinks(
        in blocks: [MarkdownBlock],
        workspaceDirectory: URL?,
        enrichFileLinks: Bool,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Set<URL> {
        var links: Set<URL> = []
        collectLinkTargets(in: blocks, into: &links)
        return links.filter { url in
            if !enrichFileLinks { return isPreviewWebOrMailLink(url) }
            return TranscriptFileOpener.clickedLink(for: url, workspaceDirectory: workspaceDirectory,
                                                    fileExists: fileExists) != .ignored
        }
    }

    private static func collectLinkTargets(in blocks: [MarkdownBlock], into links: inout Set<URL>) {
        for block in blocks {
            switch block.kind {
            case .paragraph, .heading:
                links.formUnion(block.content.runs.compactMap(\.link))
            case .table(let table):
                for row in table.rows {
                    for cell in row.cells {
                        links.formUnion(cell.runs.compactMap(\.link))
                    }
                }
            case .quote(let children):
                collectLinkTargets(in: children, into: &links)
            case .list(_, let items):
                for item in items {
                    collectLinkTargets(in: item.blocks, into: &links)
                }
            case .code, .divider:
                break
            }
        }
    }

    static func measureTables(in blocks: [MarkdownBlock], typography: PikachuTypography, widths: inout [Int: [CGFloat]]) {
        widths = tableMeasurements(in: blocks, typography: typography).mapValues(\.widths)
    }

    private struct TableMeasurement {
        let table: MarkdownTable
        let widths: [CGFloat]
    }

    private static func tableMeasurements(in blocks: [MarkdownBlock], typography: PikachuTypography,
                                          reusing previous: [Int: TableMeasurement] = [:]) -> [Int: TableMeasurement] {
        var measurements: [Int: TableMeasurement] = [:]
        collectTableMeasurements(in: blocks, typography: typography, reusing: previous, into: &measurements)
        return measurements
    }

    private static func collectTableMeasurements(in blocks: [MarkdownBlock], typography: PikachuTypography,
                                                 reusing previous: [Int: TableMeasurement],
                                                 into measurements: inout [Int: TableMeasurement]) {
        for block in blocks {
            switch block.kind {
            case .table(let table):
                if let existing = previous[block.id], existing.table == table {
                    measurements[block.id] = existing
                } else {
                    measurements[block.id] = TableMeasurement(
                        table: table, widths: MarkdownTableLayout.naturalWidths(of: table, typography: typography)
                    )
                }
            case .quote(let children):
                collectTableMeasurements(in: children, typography: typography, reusing: previous, into: &measurements)
            case .list(_, let items):
                for item in items {
                    collectTableMeasurements(in: item.blocks, typography: typography, reusing: previous, into: &measurements)
                }
            default:
                break
            }
        }
    }
}

enum MarkdownBlockSpacing {
    static func between(_ previous: MarkdownBlock.Kind?, _ next: MarkdownBlock.Kind, style: MarkdownStyle,
                        paragraphGap: CGFloat? = nil) -> CGFloat {
        guard let previous else { return 0 }
        if case .heading = previous, case .heading = next { return style.consecutiveHeadingGap }
        let spacing = max(preferred(for: previous, before: false, style: style),
                          preferred(for: next, before: true, style: style))
        return spacing == 0 ? paragraphGap ?? style.paragraphGap : spacing
    }

    private static func preferred(for kind: MarkdownBlock.Kind, before: Bool, style: MarkdownStyle) -> CGFloat {
        switch kind {
        case .heading(let level): style.headingGap(level, before: before)
        case .code, .table: style.richBlockGap
        case .divider: style.dividerGap
        case .paragraph, .list, .quote: 0
        }
    }
}

enum MarkdownBlockID: Hashable, Sendable {
    case source(Int, occurrence: Int)
    case parser(Int)
    case document(String, occurrence: Int)

    struct Entry<Value>: Identifiable {
        let id: MarkdownBlockID
        let value: Value
    }

    static func entries<Value: Identifiable>(_ values: [Value], sourceOffset: KeyPath<Value, Int?>,
                                              documentKey: ((Value) -> String)? = nil) -> [Entry<Value>] where Value.ID == Int {
        var offsets: [Int: Int] = [:]
        var keys: [String: Int] = [:]
        return values.map { value in
            if let key = documentKey?(value) {
                let occurrence = keys[key, default: 0]
                keys[key] = occurrence + 1
                return Entry(id: .document(key, occurrence: occurrence), value: value)
            }
            guard let offset = value[keyPath: sourceOffset] else { return Entry(id: .parser(value.id), value: value) }
            let occurrence = offsets[offset, default: 0]
            offsets[offset] = occurrence + 1
            return Entry(id: .source(offset, occurrence: occurrence), value: value)
        }
    }

    static func documentEntries(_ blocks: [MarkdownBlock]) -> [Entry<MarkdownBlock>] {
        entries(blocks, sourceOffset: \.sourceOffset) { $0.readingKey }
    }
}

private extension MarkdownBlock {
    var readingKey: String {
        let prefix = String(content.characters.prefix(96))
        switch kind {
        case .paragraph: return "p:\(prefix)"
        case .heading(let level): return "h\(level):\(prefix)"
        case .code(let language): return "code:\(language):\(prefix)"
        case .quote(let children): return "quote:\(children.first?.readingKey ?? "")"
        case .list(let ordered, let items): return "list:\(ordered):\(items.first?.blocks.first?.readingKey ?? "")"
        case .table(let table):
            return "table:" + (table.rows.first?.cells.first.map { String($0.characters.prefix(96)) } ?? "")
        case .divider: return "divider"
        }
    }

    var isStandaloneImage: Bool {
        guard case .paragraph = kind, let imageURL = content.runs.first?.imageURL else { return false }
        return content.runs.allSatisfy { $0.imageURL == imageURL && $0.link == nil }
    }
}

private struct MarkdownBlockStack: View {
    let blocks: [MarkdownBlock]
    let width: CGFloat
    let style: MarkdownStyle
    let tableWidths: [Int: [CGFloat]]
    var paragraphGap: CGFloat? = nil
    var tracksReadingPosition = false

    var body: some View {
        let entries = tracksReadingPosition ? MarkdownBlockID.documentEntries(blocks)
            : MarkdownBlockID.entries(blocks, sourceOffset: \.sourceOffset)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries.enumerated(), id: \.element.id) { index, entry in
                let spacing = spacing(before: index)
                MarkdownBlockView(block: entry.value, width: width, style: style, tableWidths: tableWidths)
                    .padding(.top, spacing)
            }
        }
        .scrollTargetLayout(isEnabled: tracksReadingPosition)
    }

    private func spacing(before index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        let previous = blocks[index - 1]
        let next = blocks[index]
        if previous.isStandaloneImage || next.isStandaloneImage {
            return max(style.richBlockGap, MarkdownBlockSpacing.between(previous.kind, next.kind, style: style))
        }
        return MarkdownBlockSpacing.between(previous.kind, next.kind, style: style, paragraphGap: paragraphGap)
    }
}

private struct MarkdownBlockView: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let block: MarkdownBlock
    let width: CGFloat
    let style: MarkdownStyle
    let tableWidths: [Int: [CGFloat]]

    var body: some View {
        switch block.kind {
        case .paragraph:
            if block.isStandaloneImage, let url = block.content.runs.first?.imageURL {
                MarkdownImageReference(url: url, alt: block.text, width: width, style: style)
                    .id(url)
            } else {
                MarkdownInlineText(content: block.content, role: style.body, codeSize: style.code.size)
                    .equatable()
            }
        case .heading(let level):
            let heading = style.heading(level)
            MarkdownInlineText(content: block.content, role: heading, codeSize: max(style.code.size, heading.size - style.scale))
                .equatable()
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(headingLevel(for: level))
        case .code(let language):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(language.isEmpty ? String(localized: "代码") : language)
                        .font(Font(style.caption.font))
                        .foregroundStyle(MarkdownColors.secondary)
                    Spacer()
                    CopyCodeButton(text: block.text)
                }
                TranscriptHorizontalScrollView {
                    Text(verbatim: block.text)
                        .lineSpacing(style.code.lineSpacing(monospaced: true))
                        .font(Font(style.code.codeFont))
                        .fixedSize(horizontal: true, vertical: false)
                        .textSelection(.enabled)
                }
            }
            .padding(style.codeInset)
            .flatSurface(MarkdownColors.code, radius: 8)
        case .list(let ordered, let items):
            MarkdownListView(ordered: ordered, items: items, width: width, style: style,
                             loose: block.isLooseList, tableWidths: tableWidths)
        case .table(let table):
            MarkdownTableView(table: table, width: width, style: style, naturalWidths: tableWidths[block.id])
        case .quote(let children):
            let inset = style.quoteInset + style.quoteRule
            MarkdownBlockStack(blocks: children, width: max(1, width - inset), style: style, tableWidths: tableWidths)
                .padding(.leading, inset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) {
                    Rectangle().fill(MarkdownColors.quote(contrast)).frame(width: style.quoteRule)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
        case .divider:
            Rectangle().fill(MarkdownColors.divider(contrast)).frame(height: 1).accessibilityHidden(true)
        }
    }

    private func headingLevel(for level: Int) -> AccessibilityHeadingLevel {
        switch level {
        case 1: .h1
        case 2: .h2
        case 3: .h3
        case 4: .h4
        case 5: .h5
        default: .h6
        }
    }
}

private struct MarkdownListView: View {
    let ordered: Bool
    let items: [MarkdownListItem]
    let width: CGFloat
    let style: MarkdownStyle
    let loose: Bool
    let tableWidths: [Int: [CGFloat]]

    var body: some View {
        let markerFont = NSFont.monospacedDigitSystemFont(ofSize: style.body.size, weight: .regular)
        let lastMarker = "\(items.last?.ordinal ?? 1)." as NSString
        let hasTasks = items.contains { $0.taskChecked != nil }
        let boxWidth = hasTasks ? ceil(style.body.size + 2) : style.listMarkerWidth
        let numberWidth = ceil(lastMarker.size(withAttributes: [.font: markerFont]).width)
        let markerWidth = ordered ? numberWidth + (hasTasks ? boxWidth + 4 : 0) : boxWidth
        let gap = style.listMarkerGap

        VStack(alignment: .leading, spacing: loose ? style.looseListGap : style.tightListGap) {
            ForEach(MarkdownBlockID.entries(items, sourceOffset: \.sourceOffset)) { entry in
                let item = entry.value
                HStack(alignment: .firstTextBaseline, spacing: gap) {
                    marker(for: item)
                        .font(Font(markerFont))
                        .foregroundStyle(MarkdownColors.secondary)
                        .frame(width: markerWidth, alignment: .trailing)

                    MarkdownBlockStack(blocks: item.blocks, width: max(1, width - markerWidth - gap),
                                       style: style, tableWidths: tableWidths, paragraphGap: style.looseListGap)
                }
                .accessibilityElement(children: .contain)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func marker(for item: MarkdownListItem) -> some View {
        if let checked = item.taskChecked {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if ordered { Text(verbatim: "\(item.ordinal).") }
                Text(Image(systemName: checked ? "checkmark.square" : "square"))
                    .accessibilityLabel(checked ? Text("已勾选") : Text("未勾选"))
            }
        } else if ordered {
            Text(verbatim: "\(item.ordinal).")
        } else {
            Text(verbatim: "•").accessibilityHidden(true)
        }
    }

}

struct MarkdownTableLayout {
    static let columnSpacing: CGFloat = 18

    let columnWidths: [CGFloat]
    let needsHorizontalScroll: Bool

    init(naturalWidths: [CGFloat], bodySize: CGFloat, availableWidth: CGFloat, columnGap: CGFloat = Self.columnSpacing) {
        let spacing = columnGap * CGFloat(max(0, naturalWidths.count - 1))
        var widths = naturalWidths.map { min($0, 6 * bodySize) }
        let minimumWidth = widths.reduce(0, +) + spacing
        needsHorizontalScroll = minimumWidth > availableWidth
        var remaining = availableWidth - minimumWidth
        let weights = naturalWidths.indices.map { min(naturalWidths[$0], 28 * bodySize) - widths[$0] }
        var flexibleColumns = widths.indices.filter { weights[$0] > 0 }

        while remaining > 0.01, !flexibleColumns.isEmpty {
            let weightTotal = flexibleColumns.reduce(CGFloat.zero) { $0 + weights[$1] }
            let budget = remaining
            for column in flexibleColumns {
                let extra = min(budget * weights[column] / weightTotal, naturalWidths[column] - widths[column])
                widths[column] += extra
                remaining -= extra
            }
            flexibleColumns.removeAll { naturalWidths[$0] - widths[$0] < 0.01 }
        }
        columnWidths = widths
    }

    @MainActor static func naturalWidths(of table: MarkdownTable, typography: PikachuTypography) -> [CGFloat] {
        let role = MarkdownStyle(profile: .conversation, width: .standard, typography: typography).table
        let headerFonts = MarkdownTextFonts(bodySize: role.size, codeSize: role.size, weight: .semibold)
        let bodyFonts = MarkdownTextFonts(bodySize: role.size, codeSize: role.size, weight: .regular)
        var widths = Array(repeating: CGFloat.zero, count: table.columns.count)
        for row in table.rows {
            let fonts = row.isHeader ? headerFonts : bodyFonts
            for (column, cell) in row.cells.enumerated() {
                widths[column] = max(widths[column], fonts.naturalWidth(of: cell))
            }
        }
        return widths
    }
}

private struct MarkdownTableView: View {
    @Environment(\.pikachuTypography) private var typography
    let table: MarkdownTable
    let width: CGFloat
    let style: MarkdownStyle
    let naturalWidths: [CGFloat]?

    var body: some View {
        let layout = MarkdownTableLayout(naturalWidths: naturalWidths ?? MarkdownTableLayout.naturalWidths(of: table, typography: typography),
                                         bodySize: style.table.size, availableWidth: width, columnGap: style.tableColumnGap)
        let rows = MarkdownTableRows(table: table, widths: layout.columnWidths, style: style)

        if layout.needsHorizontalScroll {
            TranscriptHorizontalScrollView(showsIndicators: true) {
                rows
            }
            .frame(width: width)
        } else {
            rows
        }
    }
}

private struct MarkdownTableRows: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let table: MarkdownTable
    let widths: [CGFloat]
    let style: MarkdownStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(MarkdownBlockID.entries(table.rows, sourceOffset: \.sourceOffset).enumerated(), id: \.element.id) { index, entry in
                if index > 0 {
                    Rectangle().fill(MarkdownColors.divider(contrast)).frame(height: 1).accessibilityHidden(true)
                }
                MarkdownTableRow(row: entry.value, columns: table.columns, widths: widths, style: style)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct MarkdownTableRow: View {
    let row: MarkdownTable.Row
    let columns: [PresentationIntent.TableColumn]
    let widths: [CGFloat]
    let style: MarkdownStyle

    var body: some View {
        let table = style.table
        let role = MarkdownStyle.TypeStyle(size: table.size, lineHeight: table.lineHeight, weight: row.isHeader ? .semibold : .regular)
        HStack(alignment: .top, spacing: style.tableColumnGap) {
            ForEach(columns.indices, id: \.self) { column in
                let alignment = columns[column].alignment
                MarkdownInlineText(content: row.cells[column], role: role, codeSize: style.code.size)
                    .equatable()
                    .multilineTextAlignment(alignment == .right ? .trailing : alignment == .center ? .center : .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: widths[column],
                           alignment: alignment == .right ? .trailing : alignment == .center ? .center : .leading)
                    .accessibilityAddTraits(row.isHeader ? .isHeader : [])
            }
        }
        .frame(minHeight: ceil(role.font.ascender - role.font.descender + role.font.leading), alignment: .top)
        .padding(.vertical, style.tableRowInset)
        .accessibilityElement(children: .contain)
    }
}

private struct MarkdownInlineText: View, Equatable {
    @Environment(\.markdownInteractiveLinks) private var interactiveLinks
    let content: AttributedString
    let role: MarkdownStyle.TypeStyle
    let codeSize: CGFloat

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.role == rhs.role && lhs.codeSize == rhs.codeSize && lhs.content == rhs.content
    }

    var body: some View {
        let fonts = MarkdownTextFonts(bodySize: role.size, codeSize: codeSize, weight: role.weight)
        let styled = fonts.stylingInlineText(in: content, interactiveLinks: interactiveLinks)
        Group {
            if content.runs.contains(where: { $0.inlinePresentationIntent?.contains(.code) == true }) {
                markedText(styled)
                    .textRenderer(MarkdownInlineCodeRenderer())
            } else {
                Text(styled)
            }
        }
        .font(Font(fonts.body))
        .lineSpacing(role.lineSpacing())
        .textSelection(.enabled)
    }

    private func markedText(_ content: AttributedString) -> Text {
        var interpolation = LocalizedStringKey.StringInterpolation(literalCapacity: 0, interpolationCount: content.runs.count)
        for run in content.runs {
            let span = Text(AttributedString(content[run.range]))
            if run.inlinePresentationIntent?.contains(.code) == true {
                interpolation.appendInterpolation(span.customAttribute(MarkdownInlineCode()))
            } else {
                interpolation.appendInterpolation(span)
            }
        }
        return Text(LocalizedStringKey(stringInterpolation: interpolation))
    }
}

@MainActor struct MarkdownTextFonts {
    let body: NSFont
    let code: NSFont

    init(typography: PikachuTypography, weight: NSFont.Weight = .regular) {
        self.init(bodySize: typography.pointSize(for: .body), codeSize: typography.pointSize(for: .callout), weight: weight)
    }

    init(bodySize: CGFloat, codeSize: CGFloat, weight: NSFont.Weight) {
        body = .systemFont(ofSize: bodySize, weight: weight)
        code = .monospacedSystemFont(ofSize: codeSize, weight: weight)
    }

    private func font(for intent: InlinePresentationIntent) -> NSFont {
        let isCode = intent.contains(.code)
        var font = isCode ? code : body
        if intent.contains(.stronglyEmphasized) {
            let weight: NSFont.Weight = body.fontDescriptor.symbolicTraits.contains(.bold) ? .bold : .semibold
            font = isCode
                ? .monospacedSystemFont(ofSize: code.pointSize, weight: weight)
                : .systemFont(ofSize: body.pointSize, weight: weight)
        }
        if intent.contains(.emphasized) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }

    func naturalWidth(of cell: AttributedString) -> CGFloat {
        let text = NSMutableAttributedString()
        for run in cell.runs {
            let font = font(for: run.inlinePresentationIntent ?? [])
            let value = String(cell[run.range].characters)
            let visible = run.imageURL != nil && value == "\u{FFFC}" ? String(localized: "图片") : value
            text.append(NSAttributedString(string: visible, attributes: [.font: font]))
        }

        let string = text.string
        var width: CGFloat = 0
        string.enumerateSubstrings(in: string.startIndex..<string.endIndex, options: [.byLines, .substringNotRequired]) {
            _, range, _, _ in
            let line = CTLineCreateWithAttributedString(text.attributedSubstring(from: NSRange(range, in: string)))
            width = max(width, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        }
        return ceil(width)
    }

    func stylingInlineText(in content: AttributedString, interactiveLinks: Set<URL>) -> AttributedString {
        guard content.runs.contains(where: {
            $0.link != nil || $0.imageURL != nil
                || $0.inlinePresentationIntent?.intersection([.code, .stronglyEmphasized]).isEmpty == false
        }) else {
            return content
        }
        var styled = AttributedString()
        for run in content.runs {
            var span = AttributedString(content[run.range])
            let intent = run.inlinePresentationIntent ?? []
            if !intent.intersection([.code, .stronglyEmphasized]).isEmpty {
                span.swiftUI.font = Font(font(for: intent))
            }
            if run.imageURL != nil {
                if String(span.characters) == "\u{FFFC}" { span = AttributedString(String(localized: "图片")) }
                span.imageURL = nil
            }
            if let link = run.link {
                if interactiveLinks.contains(link) {
                    span.swiftUI.foregroundColor = MarkdownColors.link
                    span.swiftUI.underlineStyle = .single
                } else {
                    span.link = nil
                    span.swiftUI.foregroundColor = nil
                    span.swiftUI.underlineStyle = nil
                }
            }
            styled.append(span)
        }
        return styled
    }
}

private struct MarkdownInlineCode: TextAttribute {}

private struct MarkdownInlineCodeRenderer: TextRenderer {
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line where run[MarkdownInlineCode.self] != nil {
                let bounds = run.typographicBounds.rect.insetBy(dx: 0, dy: -1)
                    context.fill(Path(roundedRect: bounds, cornerRadius: 4), with: .color(MarkdownColors.inlineCode))
            }
            context.draw(line)
        }
    }
}
