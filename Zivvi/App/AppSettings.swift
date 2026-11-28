import AppKit
import SwiftUI
import Observation
import AgentRuntimeCore
import ACPRuntimeAdapter
import OrchestrationCore
import WorkspacePersistence

enum InterfaceLanguage: String, CaseIterable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    static let preference = "interface-language"

    static var saved: Self {
        UserDefaults.standard.string(forKey: preference).flatMap(Self.init(rawValue:)) ?? .system
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(rawValue, forKey: Self.preference)
        if self == .system {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([rawValue], forKey: "AppleLanguages")
        }
    }
}

enum ComposerSendShortcut: String, CaseIterable {
    case commandReturn, returnKey

    static let preference = "composer-send-shortcut"

    static var saved: Self {
        UserDefaults.standard.string(forKey: preference).flatMap(Self.init(rawValue:)) ?? .commandReturn
    }

    func save() { UserDefaults.standard.set(rawValue, forKey: Self.preference) }

    var title: LocalizedStringResource {
        switch self {
        case .commandReturn: "⌘↩ 发送"
        case .returnKey: "↩ 发送"
        }
    }

    var sendHelp: LocalizedStringResource {
        switch self {
        case .commandReturn: "发送（⌘↩）"
        case .returnKey: "发送（↩ 或 ⌘↩）"
        }
    }

    var keyHint: LocalizedStringResource {
        switch self {
        case .commandReturn: "按 ↩ 或 ⇧↩ 换行，按 ⌘↩ 发送。"
        case .returnKey: "按 ⇧↩ 换行，按 ↩ 或 ⌘↩ 发送。"
        }
    }
}

@MainActor @Observable final class AppSettings {
    nonisolated static func isValidACPToolSearchPath(_ path: String) -> Bool {
        ACPConfiguration.isValidToolSearchPath(path)
    }

    nonisolated static func acpEnvironmentKey(_ raw: String) -> String? {
        ACPConfiguration.environmentKey(raw)
    }

    private static let antigravityQuotaPreference = "show-antigravity-quota"
    let notifications: TaskNotifications
    var showsAntigravityQuota: Bool {
        didSet { UserDefaults.standard.set(showsAntigravityQuota, forKey: Self.antigravityQuotaPreference) }
    }
    var composerSendShortcut: ComposerSendShortcut {
        didSet { composerSendShortcut.save() }
    }
    var interfaceLanguage: InterfaceLanguage {
        didSet { interfaceLanguage.save() }
    }
    var interfaceFontSize: InterfaceFontSize {
        didSet { interfaceFontSize.save() }
    }
    var fileOpen: FileOpenConfiguration {
        didSet { fileOpen.save() }
    }
    private let detectedProxy: String
    private let launchProxyOverride: String?
    private let initialWorkspace: URL?
    private weak var workspace: WorkspaceController?
    @ObservationIgnored var isWorkbenchForegroundActive: @MainActor () -> Bool = { false }
    private let acpClientPermissions = ACPClientPermissionStore()
    private let acpPool = ACPConnectionPool()
    @ObservationIgnored private var acpReceiptRoot: URL?
    @ObservationIgnored private var acpPoolSequence = 0
    @ObservationIgnored private var acpPoolObserver: Task<Void, Never>?
    @ObservationIgnored private var acpRetirementObserver: Task<Void, Never>?
    var acpPoolStatuses: [String: ACPPoolStatus] { workspace?.agentConnectionStatuses ?? [:] }
    private let loginTerminal = ACPLoginTerminal()
    @ObservationIgnored private var authenticationControl: ACPAgentConnection?
    @ObservationIgnored private var historyControls: [ObjectIdentifier: ACPAgentConnection] = [:]
    @ObservationIgnored private var openingAuthenticationControl = false
    @ObservationIgnored private var authenticationShuttingDown = false
    var acpAgents: [RuntimeAgentProfile] = [] {
        didSet {
            acpClientPermissions.update(acpAgents)
            reconcileACPAgentChanges(from: oldValue)
            let current = Dictionary(uniqueKeysWithValues: acpAgents.map { ($0.id, $0) })
            let changed = oldValue.filter { previous in
                guard let agent = current[previous.id] else { return true }
                return previous.executablePath != agent.executablePath || previous.arguments != agent.arguments ||
                    previous.toolSearchPaths != agent.toolSearchPaths || previous.enabled != agent.enabled ||
                    previous.clientPermissions != agent.clientPermissions
            }
            scheduleACPConnectionSync(retiring: Set(changed.map(\.id)))
        }
    }
    var defaultRuntimeID: String?
    private enum ACPSettingsOperation: Equatable {
        case configuration, modelPreferences, authentication
    }
    private var acpSettingsOperations: [String: ACPSettingsOperation] = [:]
    @ObservationIgnored private var acpTerminalCleanups: [String: RuntimeTerminalCleanupPending] = [:]
    private(set) var environmentSaveErrors: [String: String] = [:]
    private var acpConfigurationRevisionCounter = 0
    private var acpConfigurationRevisions: [String: Int] = [:]
    private var checkedACPRevisions: [String: Int] = [:]
    private struct ACPCheckRequest {
        let id: UUID
        let task: Task<Void, Never>
    }
    private var acpCheckTasks: [String: ACPCheckRequest] = [:]
    private(set) var acpCheckResults: [String: RuntimeConnectionCheckResult] = [:]
    private(set) var acpCheckFinishedAt: [String: Date] = [:]
    let diagnosticAppearance: ColorScheme?
    let diagnosticWindowWidth: CGFloat?
    let fake: Bool
    let pastedImagesDirectory: URL
    let stateURL: URL
    let launchDirectory: URL
    let launchDirectoryRestored: Bool
    init(composerSendShortcut: ComposerSendShortcut? = nil) {
        let defaults = UserDefaults.standard
        if Bundle.main.bundleIdentifier == "ai.yuzio.zivvi",
           ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            Self.migrateLegacyPreferences(in: defaults, to: "ai.yuzio.zivvi")
        }
        self.composerSendShortcut = composerSendShortcut ?? .saved
        notifications = TaskNotifications(defaults: defaults)
        showsAntigravityQuota = defaults.bool(forKey: Self.antigravityQuotaPreference)
        launchDirectoryRestored = RelaunchWorkingDirectory.restore()
        launchDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let args = CommandLine.arguments
        let diagnostic = Bundle.main.url(forResource: "DiagnosticsConfiguration", withExtension: "json").flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String:String].self, from: $0) } ?? [:]
        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), args.indices.contains(i+1) else { return diagnostic[name] }
            return args[i+1]
        }
        diagnosticAppearance = diagnostic["--appearance"].flatMap { $0 == "dark" ? .dark : $0 == "light" ? .light : nil }
        diagnosticWindowWidth = diagnostic["--window-width"].flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 ? CGFloat($0) : nil }
        interfaceLanguage = InterfaceLanguage.saved
        interfaceFontSize = InterfaceFontSize.saved()
        fileOpen = .saved
        detectedProxy = ACPConfiguration.detectedProxy()
        launchProxyOverride = option("--proxy")
        fake = args.contains("--fake") || diagnostic["--fake"] == "true"
        initialWorkspace = option("--workspace").map { URL(fileURLWithPath: $0) }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let stateDirectory = option("--state-dir").map { URL(fileURLWithPath: $0).standardizedFileURL }
        stateURL = Self.workspaceStoreURL(stateDirectory: stateDirectory, applicationSupport: support)
        pastedImagesDirectory = Self.defaultPastedImagesDirectory(stateDirectory: stateDirectory, applicationSupport: support)
    }

    static func migrateLegacyPreferences(in defaults: UserDefaults, from source: String = "ai.yuzio.pikachu",
                                         to destination: String) {
        let marker = "did-import-pikachu-preferences"
        var current = defaults.persistentDomain(forName: destination) ?? [:]
        guard current[marker] == nil else { return }
        let legacy = defaults.persistentDomain(forName: source) ?? [:]
        if current[InterfaceLanguage.preference] == nil, current["AppleLanguages"] == nil {
            current[InterfaceLanguage.preference] = legacy[InterfaceLanguage.preference]
            current["AppleLanguages"] = legacy["AppleLanguages"]
        }
        if current[FileOpenConfiguration.preferenceKey] == nil, current[FileOpenConfiguration.commandKey] == nil {
            current[FileOpenConfiguration.commandKey] = legacy[FileOpenConfiguration.commandKey]
        }
        for key in [ComposerSendShortcut.preference, InterfaceFontSize.preferenceKey,
                   FileOpenConfiguration.preferenceKey, TaskNotifications.preference] where current[key] == nil {
            current[key] = legacy[key]
        }
        current[marker] = true
        defaults.setPersistentDomain(current, forName: destination)
    }

    nonisolated static func workspaceStoreURL(stateDirectory: URL?, applicationSupport: URL) -> URL {
        let directory = stateDirectory ?? workspaceSupportDirectory(in: applicationSupport)
            .appendingPathComponent("Workspace", isDirectory: true)
        return directory.appendingPathComponent("workspace.store", isDirectory: false)
    }

    private nonisolated static func workspaceSupportDirectory(in applicationSupport: URL) -> URL {
        // Reopen the original store in place, including its WAL, history, and cleanup receipts.
        let legacy = applicationSupport.appendingPathComponent("Pikachu", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacy.appendingPathComponent("Workspace/workspace.store").path) {
            return legacy
        }
        return applicationSupport.appendingPathComponent("Zivvi", isDirectory: true)
    }

    nonisolated static func defaultPastedImagesDirectory(
        stateDirectory: URL?,
        applicationSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    ) -> URL {
        (stateDirectory ?? workspaceSupportDirectory(in: applicationSupport))
            .appendingPathComponent("Pasted Images", isDirectory: true)
    }
    func chooseACPExecutable(currentPath: String = "") -> String? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "选择 ACP Agent 可执行文件")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        let trimmed = currentPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let expanded = (trimmed as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") {
                panel.directoryURL = URL(fileURLWithPath: expanded).deletingLastPathComponent()
            }
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
    func pickACPToolDirectories() -> [String] {
        let panel = NSOpenPanel()
        panel.title = String(localized: "选择工具搜索目录")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls.map(\.standardizedFileURL.path) : []
    }
    func bootstrap(with lock: WorkspaceLaunchLock) async throws -> WorkspaceController {
        let url = lock.storeURL
        let cleanupRoot = url.appendingPathExtension("handoff-cleanup")
        let store = try await Task.detached { try SwiftDataWorkspaceStore(url: url) }.value
        let workspace = WorkspaceController(store: store, validateWorktree: { project, path in
            await GitRepositoryInspector.isUsableWorktree(path, in: project)
        }, verifyHandoffCleanup: { id in
            ACPHandoffCleanup(root: cleanupRoot, id: id).isConfirmed
        }, inspectRuntimeModels: { [self] runtimeID, model in
            try await inspectACPModels(for: runtimeID, model: model)
        }, runtimeFactory: { [self] project, reference, launch in
            if fake { return FakeRuntime() }
            guard let agent = acpAgents.first(where: { $0.id == reference.runtimeID && $0.enabled }) else {
                let name = CodingAgentLabel.displayName(for: reference.runtimeID, agents: acpAgents)
                return UnavailableAgentRuntime(detail: String(localized: "无法启动「\(name)」：该 ACP Agent 未配置或已停用。请在「设置 → 智能体」中启用或重新配置。"))
            }
            var config = acpConfiguration(for: agent, workspace: URL(fileURLWithPath: launch.workingDirectory))
            config.expectedSessionID = reference.runtimeSessionID
            config.initialModeID = reference.runtimeModeID
            config.clientPermissions = agent.clientPermissions
            config.permissionStore = acpClientPermissions
            if let id = launch.handoffCleanupID { config.handoffCleanup = .init(root: cleanupRoot, id: id) }
            return ACPRuntime(
                configuration: config,
                pool: acpPool,
                authenticationTransaction: acpAuthenticationTransaction(for: agent.id),
                terminalAuthenticator: trackedACPTerminalAuthenticator(for: agent.id, using: loginTerminal.authenticator)
            )
        })
        workspace.generateSessionTitle = { [weak self] settings, text in
            await self?.generateTitle(settings, text: text)
        }
        workspace.isForegroundWindowActive = { [weak self] in
            self?.isWorkbenchForegroundActive() ?? false
        }
        self.workspace = workspace
        await workspace.start()
        if workspace.initialized, workspace.storageError == nil {
            let ids = Set(workspace.state.sessions.compactMap(\.handoffCleanupID))
            await Task.detached { ACPHandoffCleanup.pruneConfirmed(in: cleanupRoot, retaining: ids) }.value
        }
        let preferences = workspace.state.preferences
        acpAgents = preferences.acpAgents ?? []
        defaultRuntimeID = preferences.resolvedDefaultRuntimeID
        if workspace.initialized, workspace.storageError == nil, !fake {
            acpReceiptRoot = cleanupRoot
            acpPoolObserver?.cancel()
            acpPoolObserver = Task { [weak self, acpPool] in
                for await (id, status) in acpPool.statuses {
                    guard let self else { return }
                    self.workspace?.setAgentConnectionStatus(status, for: id)
                }
            }
            acpRetirementObserver?.cancel()
            acpRetirementObserver = Task { [weak self, acpPool] in
                for await ids in acpPool.retirements {
                    guard let self else { return }
                    self.workspace?.retireACPExecutions(withRuntimeIDs: ids)
                }
            }
            await syncACPConnections()
        }
        workspace.onLiveTurnFinished = { [weak notifications] sessionID, turn in
            notifications?.post(turn, sessionID: sessionID)
        }
        workspace.onLiveApprovalRequested = { [weak notifications] sessionID, request, controller in
            notifications?.postApproval(request, sessionID: sessionID, from: controller)
        }
        if let initialWorkspace, workspace.initialized { _ = await workspace.addProject(initialWorkspace) }
        return workspace
    }
    func environment(for runtimeID: String) -> [String: String] {
        workspace?.runtimeEnvironment(for: runtimeID) ?? [:]
    }

    private var titleGenerationAgents: [RuntimeAgentProfile] {
        acpAgents.filter { agent in
            agent.enabled && (agent.registryID == "claude-acp"
                || (agent.executablePath as NSString).lastPathComponent == "claude-agent-acp")
        }
    }

    func titleModelCatalogue() async throws -> [SessionTitleModel] {
        var choices: [SessionTitleModel] = []
        var failure: Error?
        for agent in titleGenerationAgents {
            try Task.checkCancellation()
            do {
                let config = acpConfiguration(for: agent, workspace: FileManager.default.temporaryDirectory)
                let models = fake ? FakeRuntime.models : try await ACPRuntime.titleModels(config) ?? []
                choices += models.map { .init(runtimeID: agent.id, model: $0) }
            } catch {
                failure = error
            }
        }
        if choices.isEmpty, let failure { throw failure }
        return choices
    }

    private func generateTitle(_ settings: SessionTitleSettings, text: String) async -> String? {
        guard !fake, settings.mode != .disabled else { return nil }
        let configurations = titleGenerationAgents.map { acpConfiguration(for: $0, workspace: FileManager.default.temporaryDirectory) }
        return await Self.generateTitle(settings, text: text, configurations: configurations) { [weak self] runtimeID in
            self?.workspace?.modelPreferences(forRuntime: runtimeID).defaultModel
        }
    }

    static func generateTitle(_ settings: SessionTitleSettings, text: String, configurations: [ACPConfiguration],
                              defaultModel: (String) -> RuntimeModel?) async -> String? {
        guard settings.mode != .disabled else { return nil }
        for config in configurations {
            if Task.isCancelled { return nil }
            if settings.mode == .specified && settings.model?.runtimeID != config.runtimeID { continue }
            guard FileManager.default.isExecutableFile(atPath: config.executable.path) else { continue }
            let model = settings.mode == .specified ? settings.model?.model : defaultModel(config.runtimeID)
            do {
                switch try await ACPRuntime.generateSessionTitle(config, model: model, rules: settings.rules, text: text) {
                case .unsupported: continue
                case .finished(let title): return title
                }
            } catch {
                // Only readiness errors throw. A selected model's title attempt
                // returns a finished result even if inference fails.
                continue
            }
        }
        return nil
    }

    private func acpConfiguration(for agent: RuntimeAgentProfile, workspace: URL) -> ACPConfiguration {
        var config = ACPConfiguration(
            executable: ACPExecutableLookup().launchURL(for: agent.executablePath, toolDirectories: agent.toolSearchPaths),
            arguments: agent.arguments,
            workspace: workspace,
            runtimeID: agent.id,
            environmentOverrides: environment(for: agent.id),
            proxy: detectedProxy,
            launchProxyOverride: launchProxyOverride,
            toolSearchPaths: agent.toolSearchPaths
        )
        config.clientPermissions = agent.clientPermissions
        config.permissionStore = acpClientPermissions
        return config
    }

    private func scheduleACPConnectionSync(retiring: Set<String> = []) {
        guard acpReceiptRoot != nil else { return }
        workspace?.retireACPExecutions(for: retiring)
        Task { await syncACPConnections() }
    }

    private func syncACPConnections() async {
        guard let receipts = acpReceiptRoot else { return }
        acpPoolSequence += 1
        let directory = receipts.appendingPathComponent("working-directory", isDirectory: true)
        let configs = acpAgents.filter(\.enabled).map { acpConfiguration(for: $0, workspace: directory) }
        await acpPool.configure(configs, receipts: receipts, sequence: acpPoolSequence)
    }

    func retryACPConnection(_ agentID: String) async { await acpPool.retry(agentID) }

    func refreshACPAfterExternalAuthentication(_ agentID: String) async {
        await acpPool.refreshAfterExternalAuthentication(agentID)
    }

    func stopACPConnections(force: Bool = false) async -> Bool { await acpPool.shutdown(force: force) }

    func resumeACPConnections() async {
        await acpPool.resume()
        await syncACPConnections()
    }

    func inspectACPModels(for agentID: String, model: RuntimeModel?) async throws -> RuntimeConfigurationOptions {
        if let failure = acpTerminalCleanupFailure(for: agentID) { throw failure }
        guard !isChangingACPConfiguration(for: agentID) else {
            throw RuntimeFailure(.setup, String(localized: "智能体设置正在更新，请稍后重试。"))
        }
        if fake { return FakeRuntime.options(for: model) }
        guard let agent = acpAgents.first(where: { $0.id == agentID && $0.enabled }) else {
            throw RuntimeFailure(.setup, String(localized: "所选 ACP Agent 未配置或已停用。请在「设置 → 智能体」中检查。"))
        }
        let configuration = acpConfiguration(for: agent, workspace: FileManager.default.temporaryDirectory)
        return try await ACPRuntime.inspectModels(configuration, model: model)
    }

    var hasPendingTerminalLogin: Bool { loginTerminal.hasPendingLogin }
    var hasAuthenticationControl: Bool { authenticationControl != nil }
    var hasHistoryControls: Bool { !historyControls.isEmpty }

    func beginAuthenticationShutdown() {
        authenticationShuttingDown = true
        loginTerminal.beginShutdown()
    }

    func resumeAuthentication() {
        authenticationShuttingDown = false
        loginTerminal.resume()
    }

    func stopAndConfirmAuthenticationCleanup() async -> Bool {
        let terminalClean = await loginTerminal.stopAndConfirmCleanup()
        do {
            if let authenticationControl { try await closeAuthenticationControl(authenticationControl) }
            return terminalClean
        } catch {
            return false
        }
    }

    func stopAndConfirmHistoryCleanup() async -> Bool {
        var clean = true
        for control in Array(historyControls.values) {
            do { try await closeACPHistoryControl(control) }
            catch { clean = false }
        }
        return clean
    }

    func openACPControl(agentID: String, directory: URL? = nil) async throws -> any RuntimeAgentControl {
        guard !authenticationShuttingDown else { throw CancellationError() }
        guard let agent = acpAgents.first(where: { $0.id == agentID && $0.enabled }) else {
            throw RuntimeFailure(.setup, String(localized: "所选 ACP Agent 未配置或已停用。请在「设置 → 智能体」中检查。"))
        }
        if let directory {
            let current = ACPAgentConnection(configuration: acpConfiguration(for: agent, workspace: directory),
                terminalAuthenticator: acpReceiptRoot == nil ? nil : trackedACPTerminalAuthenticator(for: agentID, using: loginTerminal.authenticator),
                pool: acpReceiptRoot == nil ? nil : acpPool)
            historyControls[ObjectIdentifier(current)] = current
            do {
                try await current.connect()
                try Task.checkCancellation()
                guard !authenticationShuttingDown else { throw CancellationError() }
                return current
            } catch {
                try await closeACPHistoryControl(current)
                throw error
            }
        }
        guard !openingAuthenticationControl else {
            throw RuntimeFailure(.connection, String(localized: "ACP 登录连接正在打开或关闭，请重试。"))
        }
        openingAuthenticationControl = true
        defer { openingAuthenticationControl = false }
        if let authenticationControl { try await closeAuthenticationControl(authenticationControl) }
        try Task.checkCancellation()
        guard !authenticationShuttingDown else { throw CancellationError() }
        if loginTerminal.hasUnconfirmedCleanup {
            throw RuntimeFailure(.supervision, String(localized: "ACP 登录终端的进程清理未确认。"))
        }
        let current = ACPAgentConnection(
            configuration: acpConfiguration(for: agent, workspace: FileManager.default.temporaryDirectory),
            terminalAuthenticator: trackedACPTerminalAuthenticator(for: agentID, using: loginTerminal.authenticator)
        )
        authenticationControl = current
        do {
            try await current.connect()
            try Task.checkCancellation()
            guard !authenticationShuttingDown else { throw CancellationError() }
            return current
        } catch {
            try await closeAuthenticationControl(current)
            throw error
        }
    }

    func withACPHistoryControl(agentID: String, directory: URL, revision: Int,
                               operation: (any RuntimeAgentControl) async throws -> Void) async throws {
        guard acpConfigurationRevision(for: agentID) == revision,
              beginACPSettingsOperation(.configuration, for: agentID) else {
            throw RuntimeFailure(.setup, String(localized: "智能体设置正在更新，请稍后重试。"))
        }
        defer { acpSettingsOperations[agentID] = nil }
        let control = try await openACPControl(agentID: agentID, directory: directory)
        do { try await operation(control) }
        catch { try? await closeACPHistoryControl(control); throw error }
        try await closeACPHistoryControl(control)
    }

    func closeACPHistoryControl(_ control: any RuntimeAgentControl) async throws {
        try await control.close()
        if let control = control as? ACPAgentConnection { historyControls.removeValue(forKey: ObjectIdentifier(control)) }
    }

    func closeACPAuthenticationControl(_ control: any RuntimeAgentControl) async throws {
        guard let control = control as? ACPAgentConnection else { return try await control.close() }
        try await closeAuthenticationControl(control)
    }

    private func closeAuthenticationControl(_ control: ACPAgentConnection) async throws {
        try await control.close()
        if authenticationControl === control { authenticationControl = nil }
    }

    func isCheckingACP(_ agentID: String) -> Bool { acpCheckTasks[agentID] != nil }

    func acpConfigurationRevision(for agentID: String) -> Int { acpConfigurationRevisions[agentID] ?? 0 }

    func isWritingACPSettings(for agentID: String) -> Bool { acpSettingsOperations[agentID] != nil }

    func isChangingACPConfiguration(for agentID: String) -> Bool {
        guard let operation = acpSettingsOperations[agentID] else { return false }
        return operation != .modelPreferences
    }

    func beginACPModelPreferencesWrite(for agentID: String) -> Bool {
        guard acpAgents.contains(where: { $0.id == agentID && $0.enabled }) else { return false }
        return beginACPSettingsOperation(.modelPreferences, for: agentID)
    }

    func endACPModelPreferencesWrite(for agentID: String) {
        if acpSettingsOperations[agentID] == .modelPreferences { acpSettingsOperations[agentID] = nil }
    }

    func performACPAuthentication(for agentID: String, operation: () async throws -> Void) async throws {
        guard acpAgents.contains(where: { $0.id == agentID && $0.enabled }) else {
            throw RuntimeFailure(.setup, String(localized: "所选 ACP Agent 未配置或已停用。请在「设置 → 智能体」中检查。"))
        }
        if let failure = acpTerminalCleanupFailure(for: agentID) { throw failure }
        guard beginACPSettingsOperation(.authentication, for: agentID) else {
            throw RuntimeFailure(.setup, String(localized: "智能体设置正在更新，请稍后重试。"))
        }
        // Login may change credentials before reconnecting succeeds.
        advanceACPConfigurationRevision(for: agentID)
        defer {
            advanceACPConfigurationRevision(for: agentID)
            acpSettingsOperations[agentID] = nil
        }
        try Task.checkCancellation()
        try await operation()
    }

    func acpAuthenticationTransaction(for agentID: String) -> ACPRuntime.AuthenticationTransaction {
        { [weak self] operation in
            guard let self else { throw CancellationError() }
            try await self.performACPAuthentication(for: agentID, operation: operation)
        }
    }

    func trackedACPTerminalAuthenticator(for agentID: String,
                                         using authenticator: RuntimeTerminalAuthenticator?) -> RuntimeTerminalAuthenticator? {
        guard let authenticator else { return nil }
        return { [weak self] launch in
            do { try await authenticator(launch) }
            catch let pending as RuntimeTerminalCleanupPending {
                self?.acpTerminalCleanups[agentID] = pending
                throw pending
            }
        }
    }

    private func acpTerminalCleanupFailure(for agentID: String) -> RuntimeFailure? {
        guard let pending = acpTerminalCleanups[agentID] else { return nil }
        guard pending.confirm() else { return pending.failure }
        acpTerminalCleanups[agentID] = nil
        return nil
    }

    private func beginACPSettingsOperation(_ operation: ACPSettingsOperation, for agentID: String) -> Bool {
        guard !isWritingACPSettings(for: agentID) else { return false }
        acpSettingsOperations[agentID] = operation
        return true
    }

    func acpCheckIsOutdated(_ agentID: String) -> Bool {
        guard let checked = checkedACPRevisions[agentID] else { return false }
        return checked != acpConfigurationRevision(for: agentID)
    }

    func acpCheckResult(for agentID: String) -> RuntimeConnectionCheckResult? { acpCheckResults[agentID] }

    func acpCheckFinishedAt(for agentID: String) -> Date? { acpCheckFinishedAt[agentID] }

    @discardableResult
    func checkACPConnection(for agent: RuntimeAgentProfile,
                            probe: @escaping @Sendable (ACPConfiguration) async -> RuntimeConnectionCheckResult = ACPRuntime.checkConnection
    ) -> Task<Void, Never>? {
        let agentID = agent.id
        guard !isCheckingACP(agentID), !isChangingACPConfiguration(for: agentID) else { return nil }
        let revision = acpConfigurationRevision(for: agentID)
        let requestID = UUID()
        let task = Task<Void, Never> { [weak self] in
            guard let self, self.acpCheckTasks[agentID]?.id == requestID else { return }
            defer {
                if self.acpCheckTasks[agentID]?.id == requestID { self.acpCheckTasks[agentID] = nil }
            }
            guard !Task.isCancelled, !self.isChangingACPConfiguration(for: agentID),
                  self.acpConfigurationRevision(for: agentID) == revision,
                  let currentAgent = self.acpAgents.first(where: { $0.id == agentID && $0.enabled }) else { return }
            self.checkedACPRevisions[agentID] = revision
            self.acpCheckResults[agentID] = nil
            self.acpCheckFinishedAt[agentID] = nil
            let configuration = self.acpConfiguration(for: currentAgent, workspace: FileManager.default.temporaryDirectory)
            let result: RuntimeConnectionCheckResult
            if let failure = self.acpTerminalCleanupFailure(for: agentID) {
                result = .init(runtimeID: agentID, executablePath: configuration.executable.path,
                               cleanupUnconfirmed: true, detail: failure.detail)
            } else {
                result = await probe(configuration)
            }
            guard !Task.isCancelled, self.acpCheckTasks[agentID]?.id == requestID,
                  self.acpConfigurationRevision(for: agentID) == revision,
                  !self.isChangingACPConfiguration(for: agentID) else { return }
            self.acpCheckResults[agentID] = result
            self.acpCheckFinishedAt[agentID] = .now
        }
        acpCheckTasks[agentID] = ACPCheckRequest(id: requestID, task: task)
        return task
    }

    func addACPAgent(_ profile: RuntimeAgentProfile) {
        guard !isWritingACPSettings(for: profile.id) else { return }
        if let index = acpAgents.firstIndex(where: { $0.id == profile.id }) {
            acpAgents[index] = profile
        } else {
            acpAgents.append(profile)
        }
    }

    func updateACPAgent(_ profile: RuntimeAgentProfile) {
        guard !isWritingACPSettings(for: profile.id),
              let index = acpAgents.firstIndex(where: { $0.id == profile.id }) else { return }
        acpAgents[index] = profile
        if !profile.enabled && defaultRuntimeID == profile.id {
            defaultRuntimeID = acpAgents.first(where: \.enabled)?.id
        }
    }

    func removeACPAgent(id: String) async -> Bool {
        guard let workspace, beginACPSettingsOperation(.configuration, for: id) else { return false }
        defer { acpSettingsOperations[id] = nil }
        guard await workspace.removeACPAgent(id: id) else { return false }
        acpAgents.removeAll { $0.id == id }
        return true
    }

    func saveEnvironment(_ values: [String: String], for runtimeID: String) async -> Bool {
        guard let workspace, beginACPSettingsOperation(.configuration, for: runtimeID) else { return false }
        defer { acpSettingsOperations[runtimeID] = nil }
        guard await workspace.setRuntimeEnvironment(values, for: runtimeID) else {
            environmentSaveErrors[runtimeID] = String(localized: "无法保存环境变量。已保留上次保存的配置。")
            return false
        }
        environmentSaveErrors.removeValue(forKey: runtimeID)
        advanceACPConfigurationRevision(for: runtimeID)
        scheduleACPConnectionSync(retiring: [runtimeID])
        return true
    }

    private func reconcileACPAgentChanges(from oldAgents: [RuntimeAgentProfile]) {
        let oldByID = Dictionary(uniqueKeysWithValues: oldAgents.map { ($0.id, $0) })
        let currentIDs = Set(acpAgents.map(\.id))
        for id in oldByID.keys where !currentIDs.contains(id) {
            acpCheckTasks.removeValue(forKey: id)?.task.cancel()
            acpCheckResults.removeValue(forKey: id)
            acpCheckFinishedAt.removeValue(forKey: id)
            checkedACPRevisions.removeValue(forKey: id)
            acpConfigurationRevisions.removeValue(forKey: id)
            environmentSaveErrors.removeValue(forKey: id)
        }
        for agent in acpAgents {
            guard let old = oldByID[agent.id] else {
                advanceACPConfigurationRevision(for: agent.id)
                continue
            }
            if old.executablePath != agent.executablePath || old.arguments != agent.arguments
                || old.toolSearchPaths != agent.toolSearchPaths || old.enabled != agent.enabled || old.clientPermissions != agent.clientPermissions {
                advanceACPConfigurationRevision(for: agent.id)
            }
        }
        if !acpAgents.contains(where: { $0.id == defaultRuntimeID && $0.enabled }) {
            defaultRuntimeID = acpAgents.first(where: \.enabled)?.id
        }
    }

    private func advanceACPConfigurationRevision(for agentID: String) {
        acpConfigurationRevisionCounter += 1
        acpConfigurationRevisions[agentID] = acpConfigurationRevisionCounter
    }

    var preferences: WorkspacePreferences {
        .init(
            acpAgents: acpAgents.isEmpty ? nil : acpAgents,
            defaultRuntimeID: defaultRuntimeID
        )
    }

    func pickProject() -> URL? {
        let panel = projectPanel()
        return panel.runModal() == .OK ? panel.url : nil
    }
    func pickProjectFromSettings(current: String? = nil) async -> URL? {
        let panel = projectPanel()
        panel.directoryURL = current.map { URL(fileURLWithPath: $0) }
        return await withCheckedContinuation { continuation in
            let complete: (NSApplication.ModalResponse) -> Void = { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
            if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: complete) }
            else { panel.begin(completionHandler: complete) }
        }
    }
    private func projectPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = String(localized: "选择项目")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        return panel
    }
    func pickFiles(in directory: URL?) async -> [URL] {
        let panel = NSOpenPanel()
        panel.title = String(localized: "添加文件引用")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = directory
        return await withCheckedContinuation { continuation in
            let complete: (NSApplication.ModalResponse) -> Void = { response in
                continuation.resume(returning: response == .OK ? panel.urls : [])
            }
            if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: complete) }
            else { panel.begin(completionHandler: complete) }
        }
    }
}

private actor UnavailableAgentRuntime: AgentRuntime {
    nonisolated let instanceID = UUID()
    nonisolated let events: AsyncStream<RuntimeEnvelope>
    private let continuation: AsyncStream<RuntimeEnvelope>.Continuation
    private let detail: String

    init(detail: String) {
        self.detail = detail
        var captured: AsyncStream<RuntimeEnvelope>.Continuation!
        events = AsyncStream { continuation in
            captured = continuation
        }
        continuation = captured
    }

    func connect() async throws -> RuntimeSession {
        throw RuntimeFailure(.setup, detail)
    }

    func send(_ prompt: UserPrompt) async throws -> PromptDisposition {
        throw RuntimeFailure(.setup, detail)
    }

    func stop() async throws {}

    func close(force: Bool) async throws {
        continuation.finish()
    }
}
