import AppKit
import SwiftUI
import AgentRuntimeCore
import OrchestrationCore

private enum ACPConfigurationField: Hashable {
    case executable, arguments, tools, enabled, environment
}

@MainActor @Observable final class ACPAgentSettingsPresentation {
    var environmentDraft = ACPEnvironmentDraft()
    var showsAdvanced = false
    var showsEnvironment = false
    let modelDirectory = ModelDirectoryState()
}

struct ACPAgentSettingsView: View {
    let workspace: WorkspaceController
    @Bindable var settings: AppSettings
    let agentID: String
    @Bindable var presentation: ACPAgentSettingsPresentation
    let connectionRequest: ProviderConnectionRequest?
    let scroll: ScrollViewProxy
    let consumeConnection: (ProviderConnectionRequest) -> Bool
    let onRemoved: () -> Void

    @State private var argumentsDraft = ""
    @State private var showsAuthentication = false
    @State private var revealsValues = false
    @State private var hasInvalidToolPath = false
    @State private var showsRemoveConfirmation = false
    @State private var removalError: String?
    @State private var repairTarget: ACPConfigurationField?
    @FocusState private var focusedField: ACPConfigurationField?
    @AccessibilityFocusState private var accessibleField: ACPConfigurationField?

    private var agent: RuntimeAgentProfile? {
        settings.acpAgents.first { $0.id == agentID }
    }

    private var editingDisabled: Bool {
        workspace.isShuttingDown || workspace.hasPendingExecutionControls || settings.isWritingACPSettings(for: agentID)
    }

    private var hasUnsavedEnvironment: Bool {
        guard let rows = presentation.environmentDraft.rows else { return false }
        let saved = settings.environment(for: agentID)
        return ACPEnvironmentRow.values(from: rows) != saved
    }

    var body: some View {
        if let agent {
            VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
                ProviderConnectionGroup(runtimeID: agent.id, request: connectionRequest, scroll: scroll,
                                        consume: consumeConnection, title: "连接状态") { heading in
                    ACPConnectionCheckView(heading: heading, settings: settings, agent: agent,
                                           hasUnsavedEnvironment: hasUnsavedEnvironment,
                                           showConfiguration: revealConfiguration,
                                           authenticate: editingDisabled ? nil : { showsAuthentication = true })
                        .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                        .disabled(workspace.isShuttingDown)
                }

                if agent.enabled {
                    SettingsDivider()
                    ACPRuntimeModelSettingsView(
                        workspace: workspace,
                        settings: settings,
                        runtimeID: agent.id,
                        directory: presentation.modelDirectory,
                        scroll: scroll
                    )
                    .id(agent.id)
                }

                SettingsDivider()
                DisclosureGroup(isExpanded: $presentation.showsAdvanced) {
                    advancedSettings(agent)
                        .padding(.top, ZivviSpacing.dialogSectionGap)
                        .task(id: repairTarget) {
                            guard let target = repairTarget else { return }
                            await Task.yield()
                            guard !Task.isCancelled else { return }
                            scroll.scrollTo(target, anchor: .top)
                            focusedField = target
                            accessibleField = target
                            repairTarget = nil
                        }
                } label: {
                    VStack(alignment: .leading, spacing: ZivviSpacing.dialogLabelGap) {
                        Text("高级设置").zivviFont(.headline)
                        Text("运行环境、环境变量与管理").settingsDetailLines()
                    }
                }
                .disclosureGroupStyle(FlatDisclosureStyle(chevronEdge: .trailing))
                .onChange(of: presentation.showsAdvanced) { _, expanded in
                    if !expanded { repairTarget = nil }
                }
                .accessibilityIdentifier("acp-advanced-settings")
            }
            .task(id: agentID) {
                argumentsDraft = ACPArgumentsParser.format(agent.arguments)
            }
            .sheet(isPresented: $showsAuthentication) {
                ACPAuthenticationView(settings: settings, agentID: agent.id)
                    .flatPanelContent()
            }
            .sheet(isPresented: $showsRemoveConfirmation) {
                FlatConfirmation(
                    request: ConfirmationRequest(
                        title: "移除「\(agent.name)」？",
                        message: "将从 Zivvi 中移除该 ACP Agent 及其环境变量配置。",
                        confirmTitle: "移除",
                        destructive: true,
                        cancelTitle: "取消"
                    ) {
                        showsRemoveConfirmation = false
                        Task {
                            if await settings.removeACPAgent(id: agent.id) { onRemoved() }
                            else { removalError = String(localized: "无法移除 Agent。请重试。") }
                        }
                    },
                    cancel: { showsRemoveConfirmation = false }
                )
                .presentationBackground(ZivviTheme.pageBackground)
            }
            .accessibilityIdentifier("acp-agent-settings-\(agent.id)")
        }
    }

    private func revealConfiguration(_ field: ACPConfigurationField) {
        presentation.showsAdvanced = true
        if field == .environment { presentation.showsEnvironment = true }
        repairTarget = field
    }

    private func advancedSettings(_ agent: RuntimeAgentProfile) -> some View {
        VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
            Text("运行环境").zivviFont(.headline).accessibilityAddTraits(.isHeader)
            acpConfigurationRows(agent).disabled(editingDisabled)

            SettingsDivider()
            DisclosureGroup(isExpanded: $presentation.showsEnvironment) {
                ACPEnvironmentEditor(settings: settings, agentID: agent.id, draft: $presentation.environmentDraft.rows,
                                     revealsValues: $revealsValues, validationError: $presentation.environmentDraft.validationError)
                    .padding(.top, ZivviSpacing.dialogItemGap)
                    .disabled(editingDisabled)
            } label: {
                Text("环境变量").zivviFont(.headline)
                    .accessibilityFocused($accessibleField, equals: .environment)
            }
            .disclosureGroupStyle(FlatDisclosureStyle(chevronEdge: .trailing))
            .focused($focusedField, equals: .environment)
            .id(ACPConfigurationField.environment)

            if agent.enabled {
                SettingsDivider()
                VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
                    Text("客户端权限").zivviFont(.headline).accessibilityAddTraits(.isHeader)
                    clientPermissionToggle("读取项目文件", agent: agent, permission: .readFiles)
                    clientPermissionToggle("写入项目文件", agent: agent, permission: .writeFiles)
                    clientPermissionToggle("运行终端命令", agent: agent, permission: .terminals)
                    Text("命令以当前 macOS 用户权限运行。项目目录只决定启动位置。")
                        .settingsDetailLines()
                }
                .disabled(workspace.isShuttingDown || settings.isWritingACPSettings(for: agentID))
            }

            SettingsDivider()
            Text("管理").zivviFont(.headline).accessibilityAddTraits(.isHeader)
            SettingsControlRow {
                Text("移除后不会删除已有会话记录，但该会话将无法继续运行，除非重新添加同 ID 配置。")
                    .settingsDetailLines()
            } control: {
                Button("移除 Agent…", role: .destructive) {
                    removalError = nil
                    showsRemoveConfirmation = true
                }
                .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                .disabled(editingDisabled)
                .accessibilityIdentifier("remove-acp-agent-\(agent.id)")
            }
            if let removalError { FeedbackBanner(text: removalError, warning: true) }
        }
    }

    private func acpConfigurationRows(_ agent: RuntimeAgentProfile) -> some View {
        VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
            SettingsControlRow {
                Text("显示名称").accessibilityHidden(true)
            } control: {
                TextField("显示名称", text: Binding(
                    get: { agent.name },
                    set: { newValue in
                        update(agent) { $0.name = newValue }
                    }
                ))
                .flatInputSurface()
                .frame(maxWidth: 480)
                .accessibilityIdentifier("acp-agent-name")
            }

            SettingsDivider()

            SettingsControlRow {
                Text("可执行文件").accessibilityHidden(true)
            } control: {
                HStack(spacing: 8) {
                    TextField("可执行文件路径", text: Binding(
                        get: { agent.executablePath },
                        set: { newValue in
                            update(agent) { $0.executablePath = newValue }
                        }
                    ))
                    .flatInputSurface()
                    .focused($focusedField, equals: .executable)
                    .accessibilityFocused($accessibleField, equals: .executable)
                    .accessibilityIdentifier("acp-agent-executable")
                    Button("选择文件…") {
                        if let path = settings.chooseACPExecutable(currentPath: agent.executablePath) {
                            update(agent) { $0.executablePath = path }
                        }
                    }
                    .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                }
                .frame(maxWidth: 480)
            }
            .id(ACPConfigurationField.executable)

            SettingsDivider()

            SettingsControlRow {
                Text("启动参数").accessibilityHidden(true)
            } control: {
                TextField("例如 acp", text: $argumentsDraft)
                    .flatInputSurface()
                    .frame(maxWidth: 480)
                    .focused($focusedField, equals: .arguments)
                    .accessibilityFocused($accessibleField, equals: .arguments)
                    .accessibilityIdentifier("acp-agent-arguments")
                    .onChange(of: argumentsDraft) { _, newValue in
                        let parsed = ACPArgumentsParser.parse(newValue)
                        if parsed != agent.arguments {
                            update(agent) { $0.arguments = parsed }
                        }
                    }
            }
            .id(ACPConfigurationField.arguments)

            SettingsDivider()

            SettingsControlRow {
                Text("工具搜索目录")
            } control: {
                Button("添加工具目录…") { addToolDirectories(to: agent) }
                    .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                    .fixedSize(horizontal: true, vertical: false)
                    .focused($focusedField, equals: .tools)
                    .accessibilityFocused($accessibleField, equals: .tools)
                    .accessibilityIdentifier("add-acp-tool-directory")
            }
            .id(ACPConfigurationField.tools)
            ForEach(agent.toolSearchPaths, id: \.self) { path in
                HStack(spacing: 8) {
                    Text(verbatim: path)
                        .zivviFont(.callout, design: .monospaced)
                        .lineLimit(1).truncationMode(.middle).help(path)
                    Button {
                        update(agent) { $0.toolSearchPaths.removeAll { $0 == path } }
                    } label: {
                        Label("移除 \(path)", systemImage: "minus.circle").labelStyle(.iconOnly)
                            .zivviFont(.caption)
                    }
                    .buttonStyle(FlatControlButtonStyle())
                    .help("移除 \(path)")
                }
            }
            if hasInvalidToolPath {
                FeedbackBanner(text: String(localized: "工具目录必须是绝对路径，且不能包含冒号。"), warning: true)
            }

            SettingsDivider()

            Toggle(isOn: Binding(
                get: { agent.enabled },
                set: { enabled in
                    update(agent) { $0.enabled = enabled }
                }
            )) {
                VStack(alignment: .leading, spacing: ZivviSpacing.dialogLabelGap) {
                    Text("启用此 Agent").zivviFont(.body, weight: .medium)
                    Text("停用后将不能用于新建会话，也不能继续启动关联会话。")
                        .zivviFont(.caption)
                        .foregroundStyle(ZivviTheme.secondaryText)
                }
            }
            .toggleStyle(FlatToggleStyle())
            .focused($focusedField, equals: .enabled)
            .accessibilityFocused($accessibleField, equals: .enabled)
            .id(ACPConfigurationField.enabled)
            .accessibilityIdentifier("acp-agent-enabled")

            SettingsDivider()

            Toggle(isOn: Binding(
                get: { settings.defaultRuntimeID == agent.id },
                set: { isDefault in
                    guard isDefault else { return }
                    settings.defaultRuntimeID = agent.id
                    workspace.setPreferences(settings.preferences)
                }
            )) {
                VStack(alignment: .leading, spacing: ZivviSpacing.dialogLabelGap) {
                    Text("设为新会话默认 Agent").zivviFont(.body, weight: .medium)
                    Text("新建会话将默认使用此 Agent，已有会话不受影响。")
                        .zivviFont(.caption)
                        .foregroundStyle(ZivviTheme.secondaryText)
                }
            }
            .toggleStyle(FlatToggleStyle())
            .disabled(!agent.enabled || settings.defaultRuntimeID == agent.id)
            .accessibilityIdentifier("acp-agent-default")

            Button("登录与登出") { showsAuthentication = true }
                .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                .disabled(!agent.enabled)

            if agent.isAntigravityPreset {
                Text("认证复用本机 Antigravity CLI 登录态；如需重新登录，请在终端执行 agy acp --login。")
                    .zivviFont(.caption)
                    .foregroundStyle(ZivviTheme.secondaryText)
            } else {
                Text("权限审批由该 ACP Agent 在运行时通过 ACP 协议弹窗确认。")
                    .zivviFont(.caption)
                    .foregroundStyle(ZivviTheme.secondaryText)
            }
        }
    }

    private func clientPermissionToggle(_ title: LocalizedStringKey, agent: RuntimeAgentProfile,
                                        permission: RuntimeACPClientPermissions) -> some View {
        Toggle(title, isOn: Binding(
            get: { agent.clientPermissions.contains(permission) },
            set: { enabled in
                update(agent) { profile in
                    if enabled { profile.clientPermissions.insert(permission) }
                    else { profile.clientPermissions.remove(permission) }
                }
            }
        ))
        .toggleStyle(FlatToggleStyle())
    }

    private func update(_ agent: RuntimeAgentProfile, mutate: (inout RuntimeAgentProfile) -> Void) {
        var copy = agent
        mutate(&copy)
        settings.updateACPAgent(copy)
        workspace.setPreferences(settings.preferences)
    }

    private func addToolDirectories(to agent: RuntimeAgentProfile) {
        let paths = settings.pickACPToolDirectories()
        guard !paths.isEmpty else { return }
        let valid = paths.filter(AppSettings.isValidACPToolSearchPath)
        hasInvalidToolPath = valid.count != paths.count
        var seen = Set(agent.toolSearchPaths)
        let appended = valid.filter { seen.insert($0).inserted }
        guard !appended.isEmpty else { return }
        update(agent) { $0.toolSearchPaths += appended }
    }
}

private struct ACPConnectionCheckView: View {
    let heading: ProviderSettingsHeading
    let settings: AppSettings
    let agent: RuntimeAgentProfile
    let hasUnsavedEnvironment: Bool
    let showConfiguration: (ACPConfigurationField) -> Void
    let authenticate: (() -> Void)?
    @State private var showsDetails = false

    private var isChecking: Bool { settings.isCheckingACP(agent.id) }
    private var isOutdated: Bool { settings.acpCheckIsOutdated(agent.id) }
    private var finishedAt: Date? { settings.acpCheckFinishedAt(for: agent.id) }
    private var result: RuntimeConnectionCheckResult? { settings.acpCheckResult(for: agent.id) }
    private var configurationWriteInProgress: Bool { settings.isChangingACPConfiguration(for: agent.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
            SettingsControlRow {
                HStack(spacing: 12) {
                    heading.fixedSize()
                    summary
                }
            } control: {
                if agent.enabled {
                    Button {
                        settings.checkACPConnection(for: agent)
                    } label: {
                        Text(finishedAt == nil && !isOutdated ? "检查连接" : "重新检查")
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(isChecking || configurationWriteInProgress)
                    .accessibilityIdentifier("check-acp-connection-\(agent.id)")
                } else {
                    Button("查看配置") { showConfiguration(.enabled) }
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            if let live = settings.acpPoolStatuses[agent.id] {
                HStack(spacing: 8) {
                    Text("运行时连接").foregroundStyle(.secondary)
                    Text(live.label)
                    Spacer(minLength: 0)
                    if case .failed = live {
                        Button("重试连接") { Task { await settings.retryACPConnection(agent.id) } }
                    } else if case .needsLogin = live, let authenticate {
                        Button("登录与登出", action: authenticate)
                    }
                }
                .zivviFont(.callout)
                if case .failed(let detail) = live {
                    Text(detail).settingsDetailLines()
                } else if case .dedicated(let reason) = live {
                    if reason == .missingSessionClose {
                        Text("此智能体未声明会话关闭能力。每个会话将启动独立进程。").settingsDetailLines()
                    } else {
                        Text("此配置的共享连接出现协议不兼容。新会话将启动独立进程。").settingsDetailLines()
                    }
                }
            }

            if hasUnsavedEnvironment {
                Text("环境变量有未保存的编辑。自检使用已保存的值。")
                    .zivviFont(.caption)
                    .foregroundStyle(ZivviTheme.secondaryText)
            }

            if agent.enabled, !isChecking, !isOutdated, let result {
                if result.isReady {
                    DisclosureGroup(isExpanded: $showsDetails) {
                        details(result).padding(.top, ZivviSpacing.dialogItemGap)
                    } label: {
                        Text("检查详情").zivviFont(.callout)
                    }
                    .disclosureGroupStyle(FlatDisclosureStyle())
                } else {
                    details(result)
                    if let field = repairField(result) {
                        Button("查看配置") { showConfiguration(field) }
                    }
                    if result.authRequired {
                        Button("登录与登出") { authenticate?() }
                            .disabled(authenticate == nil)
                    }
                }
            }
        }
        .accessibilityIdentifier("acp-connection-check")
    }

    @ViewBuilder private var summary: some View {
        if !agent.enabled {
            status("已停用", tone: .neutral)
        } else if isChecking {
            FlatProgressView("正在检查连接…").controlSize(.small)
        } else if isOutdated {
            status("配置已变更，请重新检查。", tone: .warning)
        } else if let result {
            status(result.isReady ? "检查通过" : "检查发现问题", tone: result.isReady ? .passed : .warning)
        } else {
            status("尚未检查", tone: .neutral)
        }
    }

    private func status(_ text: LocalizedStringKey, tone: ACPCheckTone) -> some View {
        HStack(spacing: 6) {
            LightningIconView(systemName: tone == .neutral ? "circle.fill" : tone.icon, size: 11)
            Text(text).zivviFont(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(tone.color)
    }

    private func details(_ result: RuntimeConnectionCheckResult) -> some View {
        VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
            if let finishedAt {
                Text("检查于 \(finishedAt, format: .dateTime.hour().minute())")
                    .zivviFont(.caption).foregroundStyle(ZivviTheme.secondaryText)
            }
            ACPConnectionCheckDetails(result: result)
        }
    }

    private func repairField(_ result: RuntimeConnectionCheckResult) -> ACPConfigurationField? {
        switch result.dependencyFailure {
        case .executable: return .executable
        case .tools: return .tools
        case .environment: return .environment
        case .supervisor, nil: break
        }
        switch result.protocolVersion {
        case .unsupported: return .executable
        case .timedOut, .failed: return result.authRequired ? nil : .arguments
        case .notChecked, .compatible: return nil
        }
    }
}

private struct ACPConnectionCheckDetails: View {
    let result: RuntimeConnectionCheckResult

    var body: some View {
        ZivviDivider()
        ACPCheckRow(title: "可执行文件与环境", status: dependencyStatus, tone: result.dependencyFailure == nil ? .passed : .warning) {
            if !result.executablePath.isEmpty {
                Text(verbatim: result.executablePath)
                    .zivviFont(.caption, design: .monospaced)
                    .foregroundStyle(ZivviTheme.secondaryText)
                    .textSelection(.enabled)
            }
        }
        ZivviDivider()
        ACPCheckRow(title: "ACP 协议握手", status: protocolStatus, tone: protocolTone) {
            if let name = result.agentName, !name.isEmpty {
                let versionText = result.agentVersion.map { " \($0)" } ?? ""
                Text(verbatim: "\(name)\(versionText)")
                    .zivviFont(.caption, design: .monospaced)
                    .foregroundStyle(ZivviTheme.secondaryText)
            }
        }
        if case .compatible = result.protocolVersion {
            ZivviDivider()
            ACPCheckRow(title: "协商能力", status: capabilitiesStatus, tone: .passed) {
                let summary = result.capabilitiesSummary
                Text("会话恢复：\(summary.loadSession ? String(localized: "支持") : String(localized: "不支持")) · 图片附件：\(summary.imagePrompt ? String(localized: "支持") : String(localized: "不支持")) · 模式 \(summary.modesCount) 个 · 模型 \(summary.modelsCount) 个")
                    .zivviFont(.caption)
                    .foregroundStyle(ZivviTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if result.authRequired {
            ZivviDivider()
            ACPCheckRow(title: "认证状态", status: "需要认证", tone: .warning) {
                if let hint = result.authHint, !hint.isEmpty {
                    Text(verbatim: hint)
                        .zivviFont(.caption)
                        .foregroundStyle(ZivviTheme.secondaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        if let detail = result.detail, !detail.isEmpty {
            Text(verbatim: detail)
                .zivviFont(.caption)
                .foregroundStyle(result.isReady ? ZivviTheme.secondaryText : ZivviTheme.warningText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        if result.cleanupUnconfirmed {
            Text("探测进程清理未确认。")
                .zivviFont(.caption)
                .foregroundStyle(ZivviTheme.warningText)
        }
    }

    private var dependencyStatus: LocalizedStringResource {
        switch result.dependencyFailure {
        case nil: "可执行"
        case .executable: "可执行文件无效或不可执行。"
        case .tools: "工具搜索目录无效。"
        case .environment: "无法读取或装配环境变量。"
        case .supervisor: "无法启动进程监督器。"
        }
    }

    private var protocolStatus: LocalizedStringResource {
        switch result.protocolVersion {
        case .notChecked: "未检查"
        case .compatible(let version): "ACP v\(version) · 兼容"
        case .unsupported(let version?): "ACP v\(version) · 需要 ACP v1"
        case .unsupported(nil): "协议版本不兼容（需要 ACP v1）"
        case .timedOut: "协议握手超时。"
        case .failed: "协议握手失败。"
        }
    }

    private var protocolTone: ACPCheckTone {
        switch result.protocolVersion {
        case .notChecked: .neutral
        case .compatible: .passed
        default: .warning
        }
    }

    private var capabilitiesStatus: LocalizedStringResource {
        result.capabilitiesSummary.modelsCount > 0 ? "已就绪" : "握手成功"
    }
}

private enum ACPCheckTone: Equatable {
    case neutral, passed, warning

    var icon: String {
        switch self {
        case .neutral: "minus.circle"
        case .passed: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle"
        }
    }

    var color: Color {
        switch self {
        case .neutral: ZivviTheme.secondaryText
        case .passed: ZivviTheme.runningText
        case .warning: ZivviTheme.warningText
        }
    }
}

private struct ACPCheckRow<Content: View>: View {
    let title: LocalizedStringResource
    let status: LocalizedStringResource
    let tone: ACPCheckTone
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            LightningIconView(systemName: tone.icon, size: 15)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).zivviFont(.body, weight: .semibold)
                    Spacer(minLength: 8)
                    Text(status).foregroundStyle(tone.color)
                }
                content()
            }
        }
    }
}

struct ACPEnvironmentDraft {
    var rows: [ACPEnvironmentRow]? {
        didSet { if rows != oldValue { validationError = nil } }
    }
    var validationError: String?
}

struct ACPEnvironmentRow: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var value: String

    static func values(from rows: [Self]) -> [String: String]? {
        var values: [String: String] = [:]
        for row in rows {
            guard let key = AppSettings.acpEnvironmentKey(row.name),
                  values[key] == nil, !row.value.utf8.contains(0) else { return nil }
            values[key] = row.value
        }
        return values
    }
}

private struct ACPEnvironmentEditor: View {
    let settings: AppSettings
    let agentID: String
    @Binding var draft: [ACPEnvironmentRow]?
    @Binding var revealsValues: Bool
    @Binding var validationError: String?
    @Environment(\.settingsCompactRows) private var compactRows

    private var savedValues: [String: String] { settings.environment(for: agentID) }
    private var envError: String? { settings.environmentSaveErrors[agentID] }

    var body: some View {
        VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
            if let rows = Binding($draft) {
                let fields = compactRows ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                    : AnyLayout(HStackLayout(spacing: 8))
                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        fields {
                            TextField("变量名", text: row.name)
                                .autocorrectionDisabled()
                                .flatInputSurface()
                            Group {
                                if revealsValues {
                                    TextField("变量值", text: row.value).autocorrectionDisabled()
                                } else {
                                    SecureField("变量值", text: row.value)
                                }
                            }
                            .flatInputSurface()
                        }
                        Button {
                            draft?.removeAll { $0.id == row.wrappedValue.id }
                        } label: {
                            LightningIconView(.minusCircle, size: 14)
                        }
                        .buttonStyle(FlatControlButtonStyle())
                        .accessibilityLabel("移除变量")
                        .help("移除变量")
                    }
                    .zivviFont(.callout, design: .monospaced)
                }
                HStack {
                    Button("添加变量") { draft?.append(.init(name: "", value: "")) }
                        .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                    if !rows.wrappedValue.isEmpty {
                        Button {
                            revealsValues.toggle()
                        } label: {
                            Text(revealsValues ? "遮蔽变量值" : "显示变量值")
                        }
                        .buttonStyle(FlatControlButtonStyle(isSelected: revealsValues))
                    }
                    Spacer()
                    Button("保存环境变量", action: save)
                        .buttonStyle(FlatControlButtonStyle(treatment: .prominent))
                        .disabled(parsedValues() == savedValues)
                }
            }
            Text("普通变量保存在本地设置中，下次启动子进程时生效。从旧版升级后，请重新录入需要的变量。请在 Agent 中配置凭据。")
                .zivviFont(.caption)
                .foregroundStyle(ZivviTheme.secondaryText)
            if let error = validationError ?? envError {
                FeedbackBanner(text: error, warning: true)
            }
        }
        .task(id: agentID) { loadDraft() }
    }

    private func loadDraft() {
        if draft == nil {
            draft = savedValues.keys.sorted().map { key in
                ACPEnvironmentRow(name: key, value: savedValues[key] ?? "")
            }
        }
    }

    private func parsedValues() -> [String: String]? {
        ACPEnvironmentRow.values(from: draft ?? [])
    }

    private func save() {
        guard let values = parsedValues() else {
            validationError = String(localized: "请检查变量名。名称必须有效且唯一，PATH 由应用管理。")
            return
        }
        validationError = nil
        Task { _ = await settings.saveEnvironment(values, for: agentID) }
    }
}

private struct ACPRuntimeModelSettingsView: View {
    let workspace: WorkspaceController
    let settings: AppSettings
    let runtimeID: String
    var directory: ModelDirectoryState
    let scroll: ScrollViewProxy

    @State private var reload = 0
    @State private var failureToReveal: ModelDirectoryState.SaveFailure?
    @FocusState private var focus: Focus?

    private enum Focus: Hashable {
        case search, hiddenModels, actions(String)
    }

    private enum DefaultChoice: Hashable {
        case followAgent, model(String)
    }

    private struct SaveFailureAnchor: Hashable {
        let runtimeID: String
        let source: ModelDirectoryState.SaveSource
    }

    private var preferences: WorkspaceModelPreferences {
        workspace.modelPreferences(forRuntime: runtimeID)
    }

    private var configurationRevision: Int { settings.acpConfigurationRevision(for: runtimeID) }
    private var loadStatus: ModelDirectoryState.LoadStatus { directory.loadStatus(for: configurationRevision) }
    private var verified: Bool { loadStatus == .ready }
    private var configurationWriteInProgress: Bool { settings.isChangingACPConfiguration(for: runtimeID) }
    private var settingsWriteInProgress: Bool { settings.isWritingACPSettings(for: runtimeID) }
    private var modelEditsDisabled: Bool {
        workspace.isShuttingDown || settingsWriteInProgress
    }

    private var inlineSaveFailure: ModelDirectoryState.SaveFailure? {
        guard let failure = directory.saveFailure, failure == failureToReveal,
              case .model = failure.source else { return nil }
        return failure
    }

    var body: some View {
        let catalogue = ModelSettingsCatalogue(models: directory.models, preferences: preferences)
        VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
            Text("模型").zivviFont(.headline).accessibilityAddTraits(.isHeader)
            defaultModel(catalogue)
            if let saveFailure = directory.saveFailure, inlineSaveFailure == nil {
                saveFeedback(saveFailure)
            }
            SettingsDivider()
            catalogueBody(catalogue)
        }
        .accessibilityIdentifier("model-settings")
        .task(id: reload) {
            if !configurationWriteInProgress, reload > 0 || loadStatus == .loading { await loadModels() }
        }
        .onChange(of: configurationWriteInProgress) { _, saving in
            if !saving, loadStatus == .loading { reload += 1 }
        }
        .onChange(of: directory.saveFailure) { _, failure in failureToReveal = failure }
        .task(id: failureToReveal) {
            guard let failure = failureToReveal else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            scroll.scrollTo(SaveFailureAnchor(runtimeID: runtimeID, source: failure.source))
        }
        .onChange(of: directory.query) { directory.resetSearchExpansion() }
    }

    private func defaultModel(_ catalogue: ModelSettingsCatalogue) -> some View {
        SettingsControlRow {
            VStack(alignment: .leading, spacing: ZivviSpacing.dialogLabelGap) {
                Text("新会话默认模型").zivviFont(.body, weight: .medium)
                if let model = preferences.defaultModel {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            Text(verbatim: model.name)
                            modelIdentifier(model.id)
                        }
                        .fixedSize(horizontal: true, vertical: false)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: model.name).lineLimit(1).truncationMode(.middle)
                            modelIdentifier(model.id)
                        }
                    }
                    .help(model.id)
                    .accessibilityElement(children: .combine)
                    .contextMenu {
                        Button("复制模型 ID") { copyModelID(model.id) }
                    }
                    .accessibilityAction(named: Text("复制模型 ID")) { copyModelID(model.id) }
                    if let title = catalogue.rowStatus(for: model.id, verified: verified).availability.title {
                        Text(title).settingsDetailLines()
                    }
                } else {
                    Text("跟随 Agent 默认").settingsDetailLines()
                }
            }
        } control: {
            defaultModelMenu(catalogue)
        }
    }

    private func defaultModelMenu(_ catalogue: ModelSettingsCatalogue) -> some View {
        FlatMenu(width: 340, triggerTreatment: .outlined, restoresTriggerFocus: true) {
            Text("更换默认模型…")
                .padding(.horizontal, 8).padding(.vertical, 5)
        } content: { select in
            let currentID = preferences.defaultModel?.id
            let followAgent = FlatMenuItem(id: DefaultChoice.followAgent, title: Text("跟随 Agent 默认"),
                                           selected: currentID == nil, accessibilityID: "clear-default-model") {
                select { changeDefaultModel(nil, from: .defaultModel) }
            }
            let choices = verified ? catalogue.all.filter { catalogue.available.contains($0.id) } : []
            let items = choices.map { model in
                FlatMenuItem(id: DefaultChoice.model(model.id), title: Text(verbatim: "\(model.name) · \(model.id)"),
                             selected: currentID == model.id) {
                    select { changeDefaultModel(model, from: .defaultModel) }
                }
            }
            FlatMenuItems(items: [followAgent] + items)
        }
        .fixedSize(horizontal: true, vertical: false)
        .disabled(modelEditsDisabled
                  || (preferences.defaultModel == nil && (!verified || catalogue.available.isEmpty)))
        .accessibilityIdentifier("change-default-model")
    }

    private func changeDefaultModel(_ model: RuntimeModel?, from source: ModelDirectoryState.SaveSource,
                                    afterSaving: @escaping @MainActor () -> Void = {}) {
        guard preferences.defaultModel?.id != model?.id else { return }
        save(from: source, requiresAvailableModel: model,
             { await workspace.setDefaultModel(model, forRuntime: runtimeID) }, afterSaving: afterSaving)
    }

    private func catalogueBody(_ catalogue: ModelSettingsCatalogue) -> some View {
        @Bindable var directory = directory
        let listed = catalogue.all.filter { ModelPresentation.matches($0, query: directory.query) }
        let groups = ModelListSection.group(listed, favorites: catalogue.favorites, hidden: catalogue.hidden)
        return VStack(alignment: .leading, spacing: ZivviSpacing.dialogItemGap) {
            HStack(spacing: 8) {
                TextField("搜索模型", text: $directory.search)
                    .flatInputSurface()
                    .frame(maxWidth: .infinity)
                    .focused($focus, equals: .search)
                    .accessibilityIdentifier("search-model-settings")
                Button("重新读取") { reload += 1 }
                    .buttonStyle(FlatControlButtonStyle(treatment: .outlined))
                    .fixedSize()
                    .disabled(loadStatus == .loading || modelEditsDisabled)
            }
            if settingsWriteInProgress {
                FlatProgressView("智能体设置正在更新…").controlSize(.small)
            } else {
                catalogueStatus(catalogue, listed: listed)
            }

            if let saveFailure = inlineSaveFailure, case .model(let id) = saveFailure.source,
               !listed.contains(where: { $0.id == id && (!catalogue.hidden.contains(id) || directory.hiddenExpanded) }) {
                saveFeedback(saveFailure)
            }

            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(groups, id: \.section) { group in
                    sectionHeading(group.section, count: group.models.count)
                    if group.section != .hidden || directory.hiddenExpanded {
                        ForEach(group.models) { model in
                            VStack(alignment: .leading, spacing: 4) {
                                modelRow(model, visible: group.section != .hidden,
                                         status: catalogue.rowStatus(for: model.id, verified: verified))
                                if let saveFailure = inlineSaveFailure, saveFailure.source == .model(model.id) {
                                    saveFeedback(saveFailure)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func catalogueStatus(_ catalogue: ModelSettingsCatalogue, listed: [RuntimeModel]) -> some View {
        switch loadStatus {
        case .loading:
            FlatProgressView("正在读取模型…").controlSize(.small)
        case .outdated:
            FeedbackBanner(text: String(localized: "智能体配置已变更，请重新读取模型。"), warning: true)
        case .failed(let detail):
            FeedbackBanner(text: detail, warning: true)
        case .ready:
            let favorites = catalogue.favorites.subtracting(catalogue.hidden).count
            let hidden = catalogue.all.filter { catalogue.hidden.contains($0.id) }.count
            Text("\(catalogue.all.count) 个模型 · \(favorites) 个收藏 · \(hidden) 个隐藏")
                .zivviFont(.caption).foregroundStyle(ZivviTheme.secondaryText)
            if directory.models.isEmpty {
                Text("此 Agent 未提供可选模型列表，或需先完成认证。").settingsDetailLines()
            }
            if listed.isEmpty, !catalogue.all.isEmpty || !directory.query.isEmpty {
                Text("没有匹配的模型。").settingsDetailLines()
            }
        }
    }

    private func saveFeedback(_ failure: ModelDirectoryState.SaveFailure) -> some View {
        FeedbackBanner(text: failure.message, warning: true)
            .id(SaveFailureAnchor(runtimeID: runtimeID, source: failure.source))
    }

    @ViewBuilder private func sectionHeading(_ section: ModelListSection, count: Int) -> some View {
        if section == .hidden {
            Button { directory.toggleHidden() } label: {
                HStack(spacing: 6) {
                    FlatDisclosureChevron(expanded: directory.hiddenExpanded)
                    Text("已从选择器隐藏（\(count)）").zivviFont(.callout, weight: .semibold)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(FlatControlButtonStyle(inset: false))
            .focused($focus, equals: .hiddenModels)
            .accessibilityValue(directory.hiddenExpanded ? Text("已展开") : Text("已折叠"))
            .accessibilityIdentifier("model-settings-hidden")
            .padding(.top, ZivviSpacing.dialogItemGap)
        } else {
            Text(section.title).zivviFont(.caption, weight: .semibold)
                .foregroundStyle(ZivviTheme.secondaryText)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, ZivviSpacing.dialogItemGap)
        }
    }

    private func modelRow(_ model: RuntimeModel, visible: Bool, status: ModelSettingsRowStatus) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(verbatim: model.name).lineLimit(1).truncationMode(.middle)
                    if status.favorite {
                        LightningIconView(.starFill, size: 12)
                            .accessibilityHidden(false)
                            .accessibilityLabel("已收藏")
                    }
                    if status.isDefault {
                        Text("默认模型").zivviFont(.caption, weight: .medium)
                            .foregroundStyle(ZivviTheme.secondaryText)
                            .fixedSize()
                    }
                }
                modelIdentifier(model.id)
            }
            .foregroundStyle(visible ? ZivviTheme.primaryText : ZivviTheme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(model.id)
            .accessibilityElement(children: .combine)

            if let title = status.availability.title {
                Text(title).settingsDetailLines()
            }
            modelActions(model, visible: visible, status: status)
        }
        .padding(.vertical, 2)
    }

    private func modelActions(_ model: RuntimeModel, visible: Bool, status: ModelSettingsRowStatus) -> some View {
        let title = Text("模型操作：\(model.name)")
        return FlatMenu(width: 190, onDismiss: {
            if focus == nil { restoreModelFocus(model.id) }
        }) {
            IconButtonLabel(systemName: "ellipsis")
        } content: { select in
            let available = status.availability == .available
            FlatMenuItems(items: [
                FlatMenuItem(id: "visibility", title: Text(visible ? "从选择器隐藏" : "启用"),
                             enabled: !visible || available) {
                    select {
                        save(from: .model(model.id), requiresAvailableModel: visible ? model : nil, {
                            await workspace.setModelVisible(model, isVisible: !visible, forRuntime: runtimeID)
                        }) {
                            restoreModelFocus(model.id)
                        }
                    }
                },
                FlatMenuItem(id: "default", title: Text("设为默认"), enabled: available && !status.isDefault) {
                    select { changeDefaultModel(model, from: .model(model.id)) { restoreModelFocus(model.id) } }
                },
                FlatMenuItem(id: "favorite", title: Text(status.favorite ? "取消收藏" : "收藏模型"),
                             enabled: available || status.favorite) {
                    select {
                        save(from: .model(model.id), requiresAvailableModel: status.favorite ? nil : model, {
                            await workspace.setFavoriteModel(model, isFavorite: !status.favorite, forRuntime: runtimeID)
                        }) {
                            restoreModelFocus(model.id)
                        }
                    }
                },
                FlatMenuItem(id: "copy-id", title: Text("复制模型 ID"), dividerBefore: true) {
                    select { copyModelID(model.id) }
                }
            ])
        }
        .fixedSize()
        .disabled(modelEditsDisabled)
        .focused($focus, equals: .actions(model.id))
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("model-actions-\(model.id)")
    }

    private func modelIdentifier(_ id: String) -> some View {
        Text(verbatim: id).lineLimit(1).truncationMode(.middle)
            .zivviFont(.caption, design: .monospaced)
            .foregroundStyle(ZivviTheme.secondaryText)
    }

    private func copyModelID(_ id: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(id, forType: .string)
    }

    private func restoreModelFocus(_ id: String) {
        guard focus == nil || focus == .actions(id) else { return }
        if !directory.models.contains(where: { $0.id == id }),
           !preferences.savedModelReferences.contains(where: { $0.id == id }) {
            focus = .search
        } else if preferences.hiddenModelIDs.contains(id) && !directory.hiddenExpanded {
            focus = .hiddenModels
        } else {
            focus = .actions(id)
        }
    }

    private func save(from source: ModelDirectoryState.SaveSource, requiresAvailableModel model: RuntimeModel?,
                      _ operation: @escaping @MainActor () async -> Bool,
                      afterSaving: @escaping @MainActor () -> Void = {}) {
        guard !workspace.isShuttingDown, settings.beginACPModelPreferencesWrite(for: runtimeID) else { return }
        directory.saveFailure = nil
        Task {
            defer { settings.endACPModelPreferencesWrite(for: runtimeID) }
            if let model, !verified || !directory.models.contains(where: { $0.id == model.id }) {
                directory.saveFailure = .init(source: source, message: String(localized: "模型目录尚未确认，请重新读取后重试。"))
                return
            }
            let saved = await operation()
            if saved {
                await Task.yield()
                afterSaving()
            } else {
                let message = workspace.storageError ?? String(localized: "无法保存模型设置，请重试。")
                directory.saveFailure = .init(source: source, message: message)
            }
        }
    }

    private func loadModels() async {
        let revision = configurationRevision
        directory.beginLoad(revision: revision)
        let result: ModelDirectoryState.LoadResult
        do {
            result = .models(try await workspace.modelCatalogue(forRuntime: runtimeID))
        } catch {
            let message = (error as? RuntimeFailure)?.detail ?? String(localized: "模型目录读取失败，请检查连接设置。")
            result = .failed(message)
        }
        guard !Task.isCancelled else { return }
        directory.finishLoad(result, requested: revision, current: configurationRevision)
    }
}
