import AppKit
import SwiftUI
import Observation
import CryptoKit
import AgentRuntimeCore
import PiRuntimeAdapter
import OrchestrationCore
import WorkspacePersistence

@MainActor @Observable final class AppSettings {
    let notifications = TaskNotifications()
    var interfaceLanguage: InterfaceLanguage {
        didSet { interfaceLanguage.save() }
    }
    var interfaceFontSize: InterfaceFontSize {
        didSet { interfaceFontSize.save() }
    }
    var piPath: String
    var nodeDirectory: String
    private let agentDirectory: String
    private let detectedProxy: String
    private let launchProxyOverride: String?
    private let initialWorkspace: URL?
    private let environmentKeychain: PiEnvironmentKeychain
    private var legacyProxy = ""
    private(set) var piEnvironment: [String: String] = [:]
    private(set) var piEnvironmentLoaded = false
    private(set) var piEnvironmentUpdating = false
    private(set) var piEnvironmentError: String?
    var extensionPaths: [String] = []
    var toolSearchPaths: [String] = []
    let diagnosticAppearance: ColorScheme?
    let diagnosticWindowWidth: CGFloat?
    let fake: Bool
    private let sessionRoot: URL
    let pastedImagesDirectory: URL
    private let fixture: URL?
    let stateURL: URL
    let launchDirectory: URL
    let launchDirectoryRestored: Bool
    private let overridden: Set<String>
    init() {
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
        let paths = PiConfiguration.detectedPaths()
        piPath = option("--pi") ?? paths.pi
        nodeDirectory = option("--node-dir") ?? paths.node
        agentDirectory = option("--agent-dir") ?? paths.agent
        detectedProxy = paths.proxy
        launchProxyOverride = option("--proxy")
        fake = args.contains("--fake") || diagnostic["--fake"] == "true"
        overridden = Set(args.filter { $0.hasPrefix("--") }).union(diagnostic.keys)
        initialWorkspace = option("--workspace").map { URL(fileURLWithPath: $0) }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        sessionRoot = option("--sessions").map { URL(fileURLWithPath: $0) } ?? support.appendingPathComponent("Pikachu/Sessions")
        let stateDirectory = option("--state-dir").map { URL(fileURLWithPath: $0).standardizedFileURL }
        stateURL = (stateDirectory ?? support.appendingPathComponent("Pikachu/Workspace")).appendingPathComponent("workspace.store")
        pastedImagesDirectory = Self.defaultPastedImagesDirectory(stateDirectory: stateDirectory, applicationSupport: support)
        let namespace = Bundle.main.bundleIdentifier ?? "ai.yuzio.pikachu"
        let scope = stateDirectory.map {
            SHA256.hash(data: Data($0.path.utf8)).map { String(format: "%02x", $0) }.joined()
        } ?? "default"
        environmentKeychain = PiEnvironmentKeychain(service: "\(namespace).pi-environment.\(scope)")
        fixture = option("--extension-fixture").map { URL(fileURLWithPath: $0) }
    }

    nonisolated static func defaultPastedImagesDirectory(
        stateDirectory: URL?,
        applicationSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    ) -> URL {
        (stateDirectory ?? applicationSupport.appendingPathComponent("Pikachu", isDirectory: true))
            .appendingPathComponent("Pasted Images", isDirectory: true)
    }
    func choosePi() {
        let panel = NSOpenPanel(); panel.title = String(localized: "选择 Pi 可执行文件")
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: piPath).deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { piPath = url.path }
    }
    func pickToolDirectories() -> [String] {
        let panel = NSOpenPanel()
        panel.title = String(localized: "选择 Pi 工具目录")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls.map(\.standardizedFileURL.path) : []
    }
    func bootstrap(with lock: WorkspaceLaunchLock) async throws -> WorkspaceController {
        let url = lock.storeURL
        let store = try await Task.detached { try SwiftDataWorkspaceStore(url: url) }.value
        let reader = PiHistoryReader(roots: [URL(fileURLWithPath: agentDirectory).appendingPathComponent("sessions"), sessionRoot])
        let workspace = WorkspaceController(store: store, reader: reader, validateWorktree: { project, path in
            await GitRepositoryInspector.isUsableWorktree(path, in: project)
        }, inspectModels: { [self] model in
            if fake { return FakeRuntime.options(for: model) }
            let temporary = FileManager.default.temporaryDirectory
            return try await PiRuntime.inspectModels(.init(executable: URL(fileURLWithPath: piPath),
                nodeDirectory: URL(fileURLWithPath: nodeDirectory), workspace: temporary,
                agentDirectory: URL(fileURLWithPath: agentDirectory), sessionDirectory: temporary,
                proxy: detectedProxy, environmentOverrides: launchEnvironment, launchProxyOverride: launchProxyOverride,
                toolSearchPaths: toolSearchPaths), model: model)
        }, runtimeFactory: { [self] project, reference, launch in
            if fake { return FakeRuntime() }
            return PiRuntime(configuration: .init(executable: URL(fileURLWithPath: piPath), nodeDirectory: URL(fileURLWithPath: nodeDirectory),
                workspace: URL(fileURLWithPath: launch.workingDirectory), agentDirectory: URL(fileURLWithPath: agentDirectory),
                sessionDirectory: sessionRoot.appendingPathComponent(project.id.uuidString), proxy: detectedProxy,
                environmentOverrides: launchEnvironment, launchProxyOverride: launchProxyOverride, extensionFixture: fixture,
                resumeFile: reference.file, expectedSessionID: reference.runtimeSessionID, nativeDialogs: true,
                extensionPaths: extensionPaths.map { URL(fileURLWithPath: $0) }, agentMode: reference.executionMode,
                toolApproval: reference.executionPolicy.approval,
                toolSearchPaths: toolSearchPaths,
                approveProjectConfiguration: launch.approveProjectConfiguration))
        })
        await workspace.start()
        let preferences = workspace.state.preferences
        if !overridden.contains("--pi"), !preferences.piPath.isEmpty { piPath = preferences.piPath }
        if !overridden.contains("--node-dir"), !preferences.nodeDirectory.isEmpty { nodeDirectory = preferences.nodeDirectory }
        legacyProxy = preferences.proxy
        extensionPaths = preferences.extensionPaths ?? []
        toolSearchPaths = preferences.toolSearchPaths ?? []
        await reloadPiEnvironment()
        if workspace.initialized, legacyProxy.isEmpty, !preferences.proxy.isEmpty {
            var migrated = preferences
            migrated.proxy = ""
            workspace.setPreferences(migrated)
            _ = await workspace.flush()
        }
        workspace.onLiveTurnFinished = { [weak notifications] turn in
            notifications?.post(turn)
        }
        workspace.onLiveApprovalRequested = { [weak notifications] request, controller in
            notifications?.postApproval(request, from: controller)
        }
        if let initialWorkspace, workspace.initialized { _ = await workspace.addProject(initialWorkspace) }
        return workspace
    }
    private var launchEnvironment: [String: String]? { piEnvironmentLoaded ? piEnvironment : nil }

    var preferences: WorkspacePreferences {
        .init(piPath: piPath, nodeDirectory: nodeDirectory, proxy: legacyProxy, extensionPaths: extensionPaths,
              toolSearchPaths: toolSearchPaths)
    }

    func reloadPiEnvironment() async {
        guard !piEnvironmentUpdating else { return }
        piEnvironmentUpdating = true
        defer { piEnvironmentUpdating = false }
        let keychain = environmentKeychain
        let legacy = legacyProxy
        do {
            let values = try await Task.detached {
                if let saved = try keychain.load() { return saved }
                guard !legacy.isEmpty else { return [:] }
                // An empty dictionary saved by the editor also suppresses future migration.
                return try keychain.migrateIfAbsent(PiConfiguration.proxyEnvironment(legacy))
            }.value
            piEnvironment = values
            piEnvironmentLoaded = true
            legacyProxy = ""
            piEnvironmentError = nil
        } catch {
            piEnvironmentError = String(localized: "无法读取 Pi 环境变量。请重试。")
        }
    }

    func savePiEnvironment(_ values: [String: String]) async -> Bool {
        guard piEnvironmentLoaded, !piEnvironmentUpdating else { return false }
        piEnvironmentUpdating = true
        defer { piEnvironmentUpdating = false }
        let keychain = environmentKeychain
        do {
            try await Task.detached { try keychain.save(values) }.value
            piEnvironment = values
            piEnvironmentError = nil
            return true
        } catch {
            piEnvironmentError = String(localized: "无法保存 Pi 环境变量。已保留上次保存的配置。")
            return false
        }
    }
    func chooseExtension() {
        let panel = NSOpenPanel(); panel.title = String(localized: "选择信任的 Pi 扩展")
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url, !extensionPaths.contains(url.path), extensionPaths.count < 16 { extensionPaths.append(url.path) }
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
