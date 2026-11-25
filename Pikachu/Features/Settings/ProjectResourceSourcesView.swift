import SwiftUI

struct ProjectResourceSourcesView: View {
    private struct Request: Equatable {
        let directory: URL
        let revision: Int
    }

    let directory: URL
    @State private var revision = 0
    @State private var loaded: (Request, ProjectResourceSources)?
    @State private var rulesExpanded = false
    @State private var skillsExpanded = false

    var body: some View {
        let request = Request(directory: directory, revision: revision)
        let sources = loaded.flatMap { $0.0 == request ? $0.1 : nil }
        ResourceSourceRow(title: "规则", report: sources?.rules, expanded: $rulesExpanded,
                          locations: "选定目录及其父目录中的上下文文件。")
            .accessibilityIdentifier("project-rule-sources")
            .settingsRowInsets()
        SettingsDivider()
        ResourceSourceRow(title: "Skills", report: sources?.skills, expanded: $skillsExpanded,
                          locations: "检查仓库和用户目录下的 .agents/skills。",
                          note: "Pikachu 会话不自动加载。")
            .accessibilityIdentifier("project-skill-sources")
            .settingsRowInsets()
        SettingsDivider()
        HStack {
            Spacer(minLength: 0)
            Button("刷新来源") { revision += 1 }
                .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                .disabled(sources == nil)
                .accessibilityIdentifier("refresh-project-sources")
        }
        .settingsRowInsets()
        .task(id: request) {
            let result = await ProjectResourceSources.inspect(directory: request.directory)
            guard !Task.isCancelled else { return }
            loaded = (request, result)
        }
    }
}

private struct ResourceSourceRow: View {
    let title: LocalizedStringKey
    let report: ProjectResourceSources.Report?
    @Binding var expanded: Bool
    let locations: LocalizedStringKey
    var note: LocalizedStringKey? = nil

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text(locations).settingsDetailLines()
                if let report {
                    ForEach(report.entries) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(entry.name) · \(Text(scope(entry.scope)))").pikachuFont(.callout)
                            Text(verbatim: entry.url.path).settingsDetailLines().textSelection(.enabled)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(status).settingsDetailLines()
                if let note { Text(note).settingsDetailLines() }
                if let report, report.failedLocations > 0, !report.failed, !report.entries.isEmpty {
                    Text("部分目录无法读取。").settingsDetailLines()
                }
                if report?.truncated == true { Text("已达到检查上限，仅显示部分来源。").settingsDetailLines() }
            }
        }
        .disclosureGroupStyle(FlatDisclosureStyle(chevronEdge: .trailing))
    }

    private var status: LocalizedStringKey {
        guard let report else { return "正在检查…" }
        if report.failed { return "无法检查来源。" }
        if !report.entries.isEmpty { return "\(report.entries.count) 个候选来源" }
        if report.failedLocations > 0 { return "部分目录无法读取。" }
        if report.truncated { return "检查范围受限。" }
        return "未发现候选来源。"
    }

    private func scope(_ scope: ProjectResourceSources.Scope) -> LocalizedStringResource {
        switch scope {
        case .project: "项目"
        case .parent: "父目录"
        case .user: "用户级"
        }
    }
}
