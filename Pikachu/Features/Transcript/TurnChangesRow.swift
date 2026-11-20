import SwiftUI
import AgentRuntimeCore
import OrchestrationCore

@MainActor @Observable final class TurnChangesExpansion {
    private(set) var expandedFolders: [String: Set<String>] = [:]

    func folder(_ name: String, in turn: String) -> Binding<Bool> {
        Binding { self.expandedFolders[turn]?.contains(name) == true } set: { expanded in
            if expanded { self.expandedFolders[turn, default: []].insert(name) }
            else { self.expandedFolders[turn]?.remove(name) }
        }
    }

    func allExpanded(_ folders: Set<String>, in turn: String) -> Bool {
        !folders.isEmpty && (expandedFolders[turn]?.isSuperset(of: folders) == true)
    }

    func toggleAll(_ folders: Set<String>, in turn: String) {
        guard !folders.isEmpty else { return }
        expandedFolders[turn] = allExpanded(folders, in: turn) ? [] : folders
    }
}

struct TurnChangesRow: View {
    let changes: TurnFileChanges
    let id: String
    let expansion: TurnChangesExpansion
    var workspaceDirectory: URL? = nil
    var onOpenFile: ((URL) -> Void)? = nil
    let contentChanged: () -> Void

    static func openableURL(for file: TurnFileChanges.File, workspaceDirectory: URL?) -> URL? {
        guard file.kind != .deleted else { return nil }
        return TranscriptFileLinks.openableFileURL(forRelativePath: file.path, workspaceDirectory: workspaceDirectory)
    }

    var body: some View {
        let byFolder = Dictionary(grouping: changes.files) { file in
            file.path.firstIndex(of: "/").map { String(file.path[..<$0]) } ?? ""
        }
        let names = Set(byFolder.keys.filter { !$0.isEmpty })
        let orderedNames = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let expandedFolders = expansion.expandedFolders[id] ?? []
        VStack(alignment: .leading, spacing: 8) {
            TurnChangesHeader(files: changes.files, folderCount: names.count,
                              expandedFolderCount: names.intersection(expandedFolders).count) {
                expansion.toggleAll(names, in: id)
            }
            TurnChangedFileList(folders: orderedNames, filesByFolder: byFolder, turnID: id, expansion: expansion,
                                workspaceDirectory: workspaceDirectory, onOpenFile: onOpenFile)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PikachuTheme.mutedSurface.opacity(0.44), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier(id)
        .onChange(of: expandedFolders) { _, _ in contentChanged() }
    }
}

private struct TurnChangesHeader: View {
    let files: [TurnFileChanges.File]
    let folderCount: Int
    let expandedFolderCount: Int
    let toggle: () -> Void

    private var expansionState: Text {
        if expandedFolderCount == 0 { return Text("已折叠") }
        if expandedFolderCount == folderCount { return Text("已展开") }
        return Text("部分展开")
    }

    var body: some View {
        let allExpanded = expandedFolderCount == folderCount
        let title: LocalizedStringKey = allExpanded ? "全部收起" : "全部展开"
        HStack(spacing: 10) {
            Text("本轮 \(files.count) 个文件变更")
                .pikachuFont(.callout, weight: .medium)
                .lineLimit(1)
            TurnChangeCounts(files: files, showsUnit: true)
            Spacer(minLength: 4)
            if folderCount > 0 {
                Button(action: toggle) {
                    VStack(spacing: 1) {
                        FlatDisclosureChevron(allExpanded ? .down : .up)
                        FlatDisclosureChevron(allExpanded ? .up : .down)
                    }
                    .frame(width: IconButtonLabel.side, height: IconButtonLabel.side)
                }
                .buttonStyle(FlatControlButtonStyle(inset: false, cornerRadius: 6))
                .help(title)
                .accessibilityLabel(title)
                .accessibilityValue(expansionState)
                .accessibilityIdentifier("turn-toggle-all-folders")
            }
        }
        .frame(minHeight: 29)
    }
}

private struct TurnChangedFileList: View {
    let folders: [String]
    let filesByFolder: [String: [TurnFileChanges.File]]
    let turnID: String
    let expansion: TurnChangesExpansion
    let workspaceDirectory: URL?
    let onOpenFile: ((URL) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(folders, id: \.self) { name in
                let files = filesByFolder[name, default: []]
                DisclosureGroup(isExpanded: expansion.folder(name, in: turnID)) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(files) {
                            TurnChangedFileRow(file: $0, folder: name, workspaceDirectory: workspaceDirectory, onOpenFile: onOpenFile)
                        }
                    }
                    .padding(.leading, 38)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "folder")
                            .frame(width: 15)
                            .accessibilityHidden(true)
                        Text(name).lineLimit(1)
                        Spacer(minLength: 8)
                        TurnChangeCounts(files: files)
                    }
                    .foregroundStyle(PikachuTheme.secondaryText)
                    .frame(minHeight: 27)
                }
            }
            ForEach(filesByFolder["", default: []]) { file in
                TurnChangedFileRow(file: file, workspaceDirectory: workspaceDirectory, onOpenFile: onOpenFile)
                    .padding(.leading, 19)
            }
        }
        .disclosureGroupStyle(FlatDisclosureStyle())
        .pikachuFont(.caption, design: .monospaced)
    }
}

private struct TurnChangedFileRow: View {
    let file: TurnFileChanges.File
    var folder: String?
    var workspaceDirectory: URL? = nil
    var onOpenFile: ((URL) -> Void)? = nil

    private var path: String {
        let destination = folder.map { String(file.path.dropFirst($0.count + 1)) } ?? file.path
        return file.previousPath.map { "\($0) → \(destination)" } ?? destination
    }

    private var openableURL: URL? {
        TurnChangesRow.openableURL(for: file, workspaceDirectory: workspaceDirectory)
    }

    private var tooltip: String {
        file.previousPath.map { "\($0) → \(file.path)" } ?? file.path
    }

    var body: some View {
        let rowContent = HStack(spacing: 9) {
            Image(systemName: icon)
                .frame(width: 15)
                .foregroundStyle(PikachuTheme.secondaryText)
                .accessibilityLabel(kind)
            Text(verbatim: path)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            TurnChangeCounts(added: file.added, deleted: file.deleted)
        }
        .frame(minHeight: 27)
        .contentShape(Rectangle())

        if let openableURL {
            Button {
                TranscriptFileOpener.open(openableURL, handler: onOpenFile)
            } label: {
                rowContent
            }
            .buttonStyle(FlatControlButtonStyle(inset: false, cornerRadius: 6))
            .help(tooltip)
            .accessibilityIdentifier("turn-changed-file:\(file.path)")
            .accessibilityHint("点击打开文件")
        } else {
            rowContent
                .help(tooltip)
                .accessibilityElement(children: .combine)
        }
    }

    private var icon: String {
        switch file.kind {
        case .added: "plus.circle"
        case .modified: "doc.text"
        case .deleted: "minus.circle"
        case .renamed: "arrow.right.circle"
        }
    }

    private var kind: LocalizedStringKey {
        switch file.kind {
        case .added: "新增"
        case .modified: "修改"
        case .deleted: "删除"
        case .renamed: "重命名"
        }
    }
}

private struct TurnChangeCounts: View {
    let added: Int?
    let deleted: Int?
    let showsUnit: Bool

    init(files: [TurnFileChanges.File], showsUnit: Bool = false) {
        let counts = files.reduce(into: (added: 0, deleted: 0, hasText: false)) { total, file in
            total.added += file.added ?? 0
            total.deleted += file.deleted ?? 0
            total.hasText = total.hasText || file.added != nil || file.deleted != nil
        }
        self.init(added: counts.hasText ? counts.added : nil, deleted: counts.hasText ? counts.deleted : nil,
                  showsUnit: showsUnit)
    }

    init(added: Int?, deleted: Int?, showsUnit: Bool = false) {
        self.added = added
        self.deleted = deleted
        self.showsUnit = showsUnit
    }

    var body: some View {
        HStack(spacing: 6) {
            if let added {
                Text(verbatim: "+\(added.formatted())")
                    .foregroundStyle(PikachuTheme.runningText)
                    .accessibilityLabel("新增 \(added) 行")
            }
            if let deleted {
                Text(verbatim: "−\(deleted.formatted())")
                    .foregroundStyle(PikachuTheme.errorText)
                    .accessibilityLabel("删除 \(deleted) 行")
            }
            if showsUnit, added != nil || deleted != nil {
                Text("行")
                    .foregroundStyle(PikachuTheme.tertiaryText)
                    .accessibilityHidden(true)
            }
        }
        .fixedSize()
        .pikachuFont(.caption, design: .monospaced)
    }
}
