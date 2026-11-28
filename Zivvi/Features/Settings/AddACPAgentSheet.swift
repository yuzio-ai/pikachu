import SwiftUI
import AgentRuntimeCore

enum ACPArgumentsParser {
    static func parse(_ input: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        var hasArgument = false

        for character in input {
            if escaping {
                current.append(character)
                escaping = false
            } else if character == "\\", quote != "'" {
                escaping = true
                hasArgument = true
            } else if let activeQuote = quote {
                if character == activeQuote { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                hasArgument = true
            } else if character.isWhitespace {
                if hasArgument {
                    result.append(current)
                    current = ""
                    hasArgument = false
                }
            } else {
                current.append(character)
                hasArgument = true
            }
        }
        if escaping { current.append("\\") }
        if hasArgument { result.append(current) }
        return result
    }

    static func format(_ arguments: [String]) -> String {
        arguments.map { argument in
            if argument.isEmpty || argument.contains(where: { $0.isWhitespace || "\"'\\".contains($0) }) {
                let escaped = argument.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                return "\"\(escaped)\""
            }
            return argument
        }.joined(separator: " ")
    }
}

struct ACPAgentDraft {
    var name = ""
    var executable = ""
    var arguments = ""
    var toolSearchPaths: [String] = []
    var registryAgent: ACPRegistryAgent?

    init() {}

    init(agent: ACPRegistryAgent, defaults: ACPRegistryAgent.LaunchDefaults) {
        registryAgent = agent
        name = agent.name
        executable = defaults.executable
        arguments = ACPArgumentsParser.format(defaults.arguments)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var checkInput: ACPInstallCheckInput {
        ACPInstallCheckInput(
            executable: executable.trimmingCharacters(in: .whitespacesAndNewlines),
            arguments: arguments,
            toolSearchPaths: toolSearchPaths
        )
    }

    var usesPackageLauncher: Bool {
        registryAgent != nil && ACPExecutableLookup.isPackageLauncher(checkInput.executable)
    }

    var canSubmit: Bool {
        !trimmedName.isEmpty && !checkInput.executable.isEmpty && !usesPackageLauncher
    }

    func profile(existingAgents: [RuntimeAgentProfile]) -> RuntimeAgentProfile? {
        guard canSubmit else { return nil }
        let arguments = ACPArgumentsParser.parse(arguments)
        if registryAgent?.isAntigravity == true {
            let hasDefault = existingAgents.contains { $0.id == RuntimeAgentProfile.antigravityRuntimeID }
            return RuntimeAgentProfile(
                id: hasDefault ? "acp:antigravity-\(UUID().uuidString.prefix(8).lowercased())" : RuntimeAgentProfile.antigravityRuntimeID,
                name: trimmedName,
                preset: .antigravity,
                executablePath: checkInput.executable,
                arguments: arguments,
                toolSearchPaths: toolSearchPaths,
                registryID: registryAgent?.id
            )
        }
        return .customACP(
            name: trimmedName,
            executablePath: checkInput.executable,
            arguments: arguments,
            toolSearchPaths: toolSearchPaths,
            registryID: registryAgent?.id
        )
    }
}

struct ACPInstallCheckInput: Equatable, Sendable {
    let executable: String
    let arguments: String
    let toolSearchPaths: [String]

    func installedPath(using lookup: ACPExecutableLookup = ACPExecutableLookup()) -> String? {
        lookup.installed(executable, toolDirectories: toolSearchPaths)?.path
    }
}

struct AddACPAgentSheet: View {
    let settings: AppSettings
    let existingAgents: [RuntimeAgentProfile]
    let onAdd: (RuntimeAgentProfile) -> Void
    let onCancel: () -> Void

    private enum Source: CaseIterable { case registry, manual }
    private enum RegistryState {
        case loading
        case loaded(ACPAgentRegistry)
        case failed
    }

    @State private var source: Source = .registry
    @State private var registryState: RegistryState = .loading
    @State private var retry = 0
    @State private var query = ""
    @State private var registryDraft = ACPAgentDraft()
    @State private var manualDraft = ACPAgentDraft()

    private var activeDraft: ACPAgentDraft { source == .manual ? manualDraft : registryDraft }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: ZivviSpacing.dialogSectionGap) {
                Text("添加 ACP 智能体")
                    .zivviFont(.title2, weight: .semibold)
                    .accessibilityAddTraits(.isHeader)

                FlatSegmentedControl(title: "添加方式", values: Source.allCases, selection: $source) { option in
                    switch option {
                    case .registry: Text("从目录添加")
                    case .manual: Text("手动添加")
                    }
                }
                .accessibilityIdentifier("add-acp-source")

                if source == .manual {
                    ACPAgentDraftForm(draft: $manualDraft, settings: settings)
                } else if let agent = registryDraft.registryAgent {
                    VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
                        HStack(spacing: 8) {
                            ACPAgentLogo(name: agent.name, registryID: agent.id, side: 22)
                            Text(verbatim: agent.name)
                                .zivviFont(.body, weight: .semibold)
                                .accessibilityAddTraits(.isHeader)
                            Spacer()
                            Button("更换 Agent") { registryDraft = ACPAgentDraft() }
                                .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                        }
                        ACPAgentDraftForm(draft: $registryDraft, settings: settings)
                            .id(agent.id)
                    }
                } else {
                    registryPicker
                }
            }
            .padding(20)

            ZivviDivider()
            HStack(spacing: 8) {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                    .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                    .keyboardShortcut(.cancelAction)
                Button("添加") {
                    if let profile = activeDraft.profile(existingAgents: existingAgents) { onAdd(profile) }
                }
                .buttonStyle(FlatControlButtonStyle(treatment: .prominent))
                .disabled(!activeDraft.canSubmit)
                .accessibilityIdentifier("confirm-add-acp-agent")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 520)
        .accessibilityIdentifier("add-acp-agent-sheet")
        .task(id: retry) {
            registryState = .loading
            do {
                let registry = try await ACPAgentRegistry.load()
                guard !Task.isCancelled else { return }
                registryState = .loaded(registry)
            } catch {
                guard !Task.isCancelled else { return }
                registryState = .failed
            }
        }
    }

    @ViewBuilder private var registryPicker: some View {
        switch registryState {
        case .loading:
            ProgressView("正在加载 ACP Agent 目录…")
                .controlSize(.small)
        case .failed:
            HStack(alignment: .firstTextBaseline) {
                Text("无法加载 ACP Agent 目录。可以重试或手动添加。")
                    .zivviFont(.callout)
                    .foregroundStyle(ZivviTheme.secondaryText)
                Spacer(minLength: 8)
                Button("重试") { retry += 1 }
                    .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                    .accessibilityIdentifier("retry-acp-registry")
            }
        case .loaded(let registry):
            ACPRegistryPicker(query: $query, agents: registry.matching(query)) { agent in
                registryDraft = ACPAgentDraft(agent: agent, defaults: agent.launchDefaults())
            }
        }
    }
}

private struct ACPRegistryPicker: View {
    @Binding var query: String
    let agents: [ACPRegistryAgent]
    let onSelect: (ACPRegistryAgent) -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
            TextField("按名称或 ID 搜索 Agent", text: $query)
                .flatInputSurface()
                .focused($searchFocused)
                .accessibilityIdentifier("search-acp-registry")
                .onAppear { searchFocused = true }

            if agents.isEmpty {
                Text("没有找到匹配的 Agent。")
                    .zivviFont(.callout)
                    .foregroundStyle(ZivviTheme.secondaryText)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(agents) { agent in
                            Button { onSelect(agent) } label: {
                                HStack(spacing: 8) {
                                    ACPAgentLogo(name: agent.name, registryID: agent.id, side: 22)
                                    VStack(alignment: .leading, spacing: ZivviSpacing.dialogLabelGap) {
                                        Text(verbatim: agent.name)
                                            .zivviFont(.callout, weight: .medium)
                                        Text(verbatim: agent.description)
                                            .zivviFont(.caption)
                                            .foregroundStyle(ZivviTheme.secondaryText)
                                            .lineLimit(2)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(FlatControlButtonStyle(treatment: .quiet))
                            .accessibilityIdentifier("acp-registry-agent-\(agent.id)")
                        }
                    }
                }
                .frame(height: 216)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }
}

private struct ACPAgentDraftForm: View {
    @Binding var draft: ACPAgentDraft
    let settings: AppSettings
    @State private var hasInvalidToolPath = false
    @State private var checkRequest: UUID?
    @State private var checkedInput: ACPInstallCheckInput?
    @State private var installedPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
            VStack(alignment: .leading, spacing: ZivviSpacing.dialogLabelGap) {
                Text("显示名称").zivviFont(.callout, weight: .medium)
                TextField("显示名称", text: $draft.name)
                    .flatInputSurface()
                    .accessibilityIdentifier("add-acp-name")
            }

            VStack(alignment: .leading, spacing: ZivviSpacing.dialogLabelGap) {
                Text("可执行文件").zivviFont(.callout, weight: .medium)
                HStack(spacing: 8) {
                    TextField("命令名称或完整路径", text: $draft.executable)
                        .flatInputSurface()
                        .accessibilityIdentifier("add-acp-executable")
                    Button("选择文件…") {
                        if let chosen = settings.chooseACPExecutable(currentPath: draft.executable) {
                            draft.executable = chosen
                        }
                    }
                    .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                }
                if draft.registryAgent != nil && draft.checkInput.executable.isEmpty {
                    Text("未能确定本地启动入口。请先安装此 Agent，或选择已安装的可执行文件。")
                        .zivviFont(.caption)
                        .foregroundStyle(ZivviTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if draft.usesPackageLauncher {
                    Text("请选择 Agent 的本地可执行文件。")
                        .zivviFont(.caption)
                        .foregroundStyle(ZivviTheme.warningText)
                }
            }

            VStack(alignment: .leading, spacing: ZivviSpacing.dialogLabelGap) {
                Text("启动参数").zivviFont(.callout, weight: .medium)
                TextField("例如 acp（空格分隔）", text: $draft.arguments)
                    .flatInputSurface()
                    .accessibilityIdentifier("add-acp-arguments")
                Text("多个参数以空格分隔；包含空格的值请使用引号包裹。")
                    .zivviFont(.caption)
                    .foregroundStyle(ZivviTheme.secondaryText)
            }

            if draft.registryAgent?.isAntigravity == true {
                Text("提示：Antigravity CLI 使用本机登录态，如尚未认证可在终端运行 agy acp --login。")
                    .zivviFont(.caption)
                    .foregroundStyle(ZivviTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                toolDirectories
            }

            HStack(spacing: 8) {
                Button("检查本机安装") {
                    checkedInput = nil
                    checkRequest = UUID()
                }
                    .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                    .disabled(draft.usesPackageLauncher || (draft.checkInput.executable.isEmpty && draft.registryAgent == nil))
                    .accessibilityIdentifier("check-acp-local-installation")
                if checkRequest != nil { ProgressView().controlSize(.small) }
            }
            if checkedInput == draft.checkInput {
                if let installedPath {
                    Text("找到可执行文件：\(installedPath)")
                        .zivviFont(.caption)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("acp-installation-found")
                } else {
                    Text("未找到可执行文件。请安装此 Agent 或选择正确的路径。")
                        .zivviFont(.caption)
                        .foregroundStyle(ZivviTheme.warningText)
                        .accessibilityIdentifier("acp-installation-missing")
                }
            }
        }
        .onChange(of: draft.checkInput) { _, input in
            guard checkedInput != input else { return }
            checkRequest = nil
            checkedInput = nil
        }
        .task(id: checkRequest) {
            guard let request = checkRequest else { return }
            let input = draft.checkInput
            let agent = draft.registryAgent
            let foundPath = await Task.detached { () -> String? in
                guard input.executable.isEmpty, let agent else { return input.installedPath() }
                let defaults = agent.launchDefaults(toolDirectories: input.toolSearchPaths)
                return ACPExecutableLookup().installed(defaults.executable, toolDirectories: input.toolSearchPaths)?.path
            }.value
            guard !Task.isCancelled, checkRequest == request, draft.checkInput == input else { return }
            if input.executable.isEmpty, let foundPath { draft.executable = foundPath }
            installedPath = foundPath
            checkedInput = draft.checkInput
            checkRequest = nil
        }
    }

    private var toolDirectories: some View {
        VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
            HStack {
                Text("工具搜索目录（可选）").zivviFont(.callout, weight: .medium)
                Spacer()
                Button("添加目录…", action: addToolDirectories)
                    .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
            }
            ForEach(draft.toolSearchPaths, id: \.self) { path in
                HStack(spacing: 8) {
                    Text(verbatim: path)
                        .zivviFont(.caption, design: .monospaced)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button {
                        draft.toolSearchPaths.removeAll { $0 == path }
                    } label: {
                        Label("移除 \(path)", systemImage: "minus.circle").labelStyle(.iconOnly)
                            .zivviFont(.caption)
                    }
                    .buttonStyle(FlatControlButtonStyle())
                }
            }
            if hasInvalidToolPath {
                FeedbackBanner(text: String(localized: "工具目录必须是绝对路径，且不能包含冒号。"), warning: true)
            }
        }
    }

    private func addToolDirectories() {
        let paths = settings.pickACPToolDirectories()
        guard !paths.isEmpty else { return }
        let valid = paths.filter(AppSettings.isValidACPToolSearchPath)
        hasInvalidToolPath = valid.count != paths.count
        var seen = Set(draft.toolSearchPaths)
        draft.toolSearchPaths += valid.filter { seen.insert($0).inserted }
    }
}
