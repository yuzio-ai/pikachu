import SwiftUI
import AppKit
import OrchestrationCore

struct HandoffContextEditor: View {
    let preview: SessionHandoffPreview
    let target: String?
    @Binding var draft: SessionHandoffDraft?
    @Binding var context: String
    @Binding var omitHistory: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HandoffEditorHeader(source: preview.sourceAgent, target: target, directory: preview.directory)
            if preview.coverage == .partial {
                Text("原会话仅有部分历史可用。").foregroundStyle(PikachuTheme.warningText)
            } else if preview.coverage == .unavailable {
                Text("原会话没有可读取的历史。").foregroundStyle(PikachuTheme.warningText)
            }

            if !omitHistory {
                if let draft = Binding($draft) {
                    HandoffRequestEditor(request: draft.userRequest)
                    HandoffFilePicker(files: draft.wrappedValue.files,
                                      segmentCount: draft.wrappedValue.segmentCount,
                                      incomplete: draft.wrappedValue.hasIncompleteFileHistory,
                                      excluded: draft.excludedPaths)
                    HandoffNotesEditor(excerpts: preview.excerpts, notes: draft.notes)
                } else {
                    TextEditor(text: $context).frame(height: 92).accessibilityLabel("交接上下文")
                    HandoffExcerptMenu(excerpts: preview.excerpts, text: $context)
                }
            }
        }
        .pikachuFont(.caption)
        .accessibilityIdentifier("handoff-context-editor")
    }
}

private struct HandoffEditorHeader: View {
    let source: String
    let target: String?
    let directory: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("交接上下文").pikachuFont(.title3, weight: .semibold)
                Spacer(minLength: 4)
                if let target {
                    Text(verbatim: "\(source) → \(target)")
                        .pikachuFont(.callout)
                        .foregroundStyle(PikachuTheme.secondaryText)
                        .multilineTextAlignment(.trailing)
                }
            }
            Text("随首条消息一起发送").foregroundStyle(PikachuTheme.secondaryText)
        }
        .help(directory)
    }
}

private struct HandoffRequestEditor: View {
    @Binding var request: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近的用户请求").pikachuFont(.callout, weight: .semibold)
            TextEditor(text: $request)
                .pikachuFont(.callout)
                .scrollContentBackground(.hidden)
                .padding(5)
                .frame(height: 54)
                .flatSurface(PikachuTheme.workspace)
                .accessibilityLabel("最近的用户请求")
                .accessibilityIdentifier("handoff-user-request")
        }
    }
}

private struct HandoffNotesEditor: View {
    let excerpts: [SessionHandoffPreview.Excerpt]
    @Binding var notes: String

    var body: some View {
        DisclosureGroup("其他交接内容") {
            TextEditor(text: $notes).frame(height: 64).accessibilityLabel("其他交接内容")
            HandoffExcerptMenu(excerpts: excerpts, text: $notes)
        }
        .disclosureGroupStyle(FlatDisclosureStyle())
    }
}

private struct HandoffExcerptMenu: View {
    let excerpts: [SessionHandoffPreview.Excerpt]
    @Binding var text: String

    var body: some View {
        if !excerpts.isEmpty {
            Menu("添加消息摘录") {
                ForEach(excerpts) { excerpt in
                    Button(String(excerpt.text.prefix(80))) {
                        text += (text.isEmpty ? "" : "\n\n") + excerpt.text
                    }
                }
            }
            .fixedSize()
        }
    }
}

private struct HandoffFilePicker: View {
    let files: [SessionHandoffFile]
    let segmentCount: Int
    let incomplete: Bool
    @Binding var excluded: Set<String>
    @Environment(\.pikachuTypography) private var typography

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Text("文件改动").pikachuFont(.callout, weight: .semibold).fixedSize()
                    Spacer(minLength: 8)
                    if !files.isEmpty { selectionControls }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("文件改动").pikachuFont(.callout, weight: .semibold)
                    if !files.isEmpty { selectionControls }
                }
            }
            if incomplete {
                Text("部分回合缺少文件改动记录。").foregroundStyle(PikachuTheme.warningText)
            }
            if files.isEmpty {
                Text(incomplete ? "没有可用的文件改动记录。" : "本次会话没有记录到文件改动。")
                    .foregroundStyle(.secondary)
            } else {
                let rowHeight = typography.pointSize(for: .caption) + 20
                Text("来自本会话的 \(segmentCount) 个执行段。取消勾选可从本次交接移除。")
                    .foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(files) { file in
                            VStack(spacing: 0) {
                                Toggle(isOn: Binding(get: { !excluded.contains(file.id) }, set: { included in
                                    if included { excluded.remove(file.id) }
                                    else { excluded.insert(file.id) }
                                })) {
                                    HandoffFileLabel(file: file)
                                        .opacity(excluded.contains(file.id) ? 0.62 : 1)
                                }
                                .toggleStyle(.checkbox)
                                .frame(minHeight: rowHeight - 1)
                                .accessibilityIdentifier("handoff-file:\(file.id)")
                                if file.id != files.last?.id { PikachuDivider() }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .frame(height: CGFloat(min(6, files.count)) * rowHeight)
                .flatSurface(PikachuTheme.workspace)
            }
        }
    }

    private var selectionControls: some View {
        HStack(spacing: 8) {
            Text("已选 \(files.count - excluded.count) / \(files.count)")
                .monospacedDigit().foregroundStyle(PikachuTheme.secondaryText)
            Button("全选") { excluded.removeAll() }.disabled(excluded.isEmpty)
            Button("取消全选") { excluded = Set(files.map(\.id)) }.disabled(excluded.count == files.count)
        }
        .fixedSize()
    }
}

private struct HandoffFileLabel: View {
    let file: SessionHandoffFile

    private var kind: LocalizedStringKey {
        switch file.kind {
        case .added: "新增"
        case .modified: "修改"
        case .deleted: "删除"
        case .renamed: "重命名"
        }
    }

    var body: some View {
        let path = (file.previousPaths + [file.path]).joined(separator: " → ")
        HStack(spacing: 6) {
            Text(verbatim: path)
                .pikachuFont(.caption, design: .monospaced)
                .lineLimit(1)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .help(path)
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                Text(kind).fixedSize()
                if let added = file.added, added > 0 { Text("+\(added)").fixedSize() }
                if let deleted = file.deleted, deleted > 0 { Text("−\(deleted)").fixedSize() }
                if file.added == nil || file.deleted == nil { Text("统计不全").fixedSize() }
            }
            .foregroundStyle(PikachuTheme.secondaryText)
        }
        .foregroundStyle(PikachuTheme.primaryText)
        .pikachuFont(.caption)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(Text(verbatim: path))，\(Text(kind))"))
        .accessibilityValue(accessibilityCounts)
        .contextMenu {
            Button("复制路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            }
        }
    }

    private var accessibilityCounts: Text {
        if let added = file.added, let deleted = file.deleted { return Text("新增 \(added) 行，删除 \(deleted) 行") }
        return Text("统计不全")
    }
}
