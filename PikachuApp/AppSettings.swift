import AppKit
import SwiftUI
import Observation
import AgentRuntimeCore
import PiRuntimeAdapter
import OrchestrationCore
import WorkspacePersistence

@MainActor @Observable final class AppSettings {
    var workspace: URL?
    var piPath: String
    var nodeDirectory: String
    var agentDirectory: String
    var proxy: String
    var extensionPaths: [String] = []
    var validationMessage: String?
    let diagnosticAppearance: ColorScheme?
    let diagnosticWindowWidth: CGFloat?
    let fake: Bool
    private let sessionRoot: URL
    private let fixture: URL?
    private let stateURL: URL
    private let overridden: Set<String>
    init() {
        let args = CommandLine.arguments
        let diagnostic = Bundle.main.url(forResource: "M3Diagnostics", withExtension: "json").flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String:String].self, from: $0) } ?? [:]
        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), args.indices.contains(i+1) else { return diagnostic[name] }
            return args[i+1]
        }
        diagnosticAppearance = diagnostic["--appearance"].flatMap { $0 == "dark" ? .dark : $0 == "light" ? .light : nil }
        diagnosticWindowWidth = diagnostic["--window-width"].flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 ? CGFloat($0) : nil }
        let paths = PiConfiguration.detectedPaths()
        piPath = option("--pi") ?? paths.pi
        nodeDirectory = option("--node-dir") ?? paths.node
        agentDirectory = option("--agent-dir") ?? paths.agent
        proxy = option("--proxy") ?? paths.proxy
        fake = args.contains("--fake") || diagnostic["--fake"] == "true"
        overridden = Set(args.filter { $0.hasPrefix("--") }).union(diagnostic.keys)
        workspace = option("--workspace").map { URL(fileURLWithPath: $0) }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        sessionRoot = option("--sessions").map { URL(fileURLWithPath: $0) } ?? support.appendingPathComponent("Pikachu/Sessions")
        stateURL = (option("--state-dir").map { URL(fileURLWithPath: $0) } ?? support.appendingPathComponent("Pikachu/Workspace")).appendingPathComponent("workspace.store")
        fixture = option("--extension-fixture").map { URL(fileURLWithPath: $0) }
    }
    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "选择项目")
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { workspace = panel.url; validationMessage = nil }
    }
    func choosePi() {
        let panel = NSOpenPanel(); panel.title = String(localized: "选择 Pi 可执行文件")
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: piPath).deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { piPath = url.path }
    }
    func makeRuntime() -> (any AgentRuntime)? {
        guard let workspace else { validationMessage = String(localized: "请先选择本地项目。") ; return nil }
        validationMessage = nil
        if fake { return FakeRuntime() }
        return PiRuntime(configuration: .init(executable: URL(fileURLWithPath: piPath), nodeDirectory: URL(fileURLWithPath: nodeDirectory),
            workspace: workspace, agentDirectory: URL(fileURLWithPath: agentDirectory),
            sessionDirectory: sessionRoot.appendingPathComponent(UUID().uuidString), proxy: proxy, extensionFixture: fixture))
    }
    func bootstrap() async throws -> WorkspaceController {
        let url = stateURL
        let store = try await Task.detached { try SwiftDataWorkspaceStore(url: url) }.value
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let reader = PiHistoryReader(roots: [URL(fileURLWithPath: agentDirectory).appendingPathComponent("sessions"), support.appendingPathComponent("Pikachu/M1Sessions"), sessionRoot])
        let workspace = WorkspaceController(store: store, reader: reader, inspectModels: { [self] model in
            if fake { return FakeRuntime.options(for: model) }
            let temporary = FileManager.default.temporaryDirectory
            return try await PiRuntime.inspectModels(.init(executable: URL(fileURLWithPath: piPath),
                nodeDirectory: URL(fileURLWithPath: nodeDirectory), workspace: temporary,
                agentDirectory: URL(fileURLWithPath: agentDirectory), sessionDirectory: temporary, proxy: proxy), model: model)
        }) { [self] project, reference in
            if fake { return FakeRuntime() }
            return PiRuntime(configuration: .init(executable: URL(fileURLWithPath: piPath), nodeDirectory: URL(fileURLWithPath: nodeDirectory),
                workspace: URL(fileURLWithPath: project.path), agentDirectory: URL(fileURLWithPath: agentDirectory),
                sessionDirectory: sessionRoot.appendingPathComponent(project.id.uuidString), proxy: proxy, extensionFixture: fixture,
                resumeFile: reference.file, expectedSessionID: reference.runtimeSessionID, nativeDialogs: true,
                extensionPaths: extensionPaths.map { URL(fileURLWithPath: $0) }, agentMode: reference.executionMode))
        }
        await workspace.start()
        let preferences = workspace.state.preferences
        if !overridden.contains("--pi"), !preferences.piPath.isEmpty { piPath = preferences.piPath }
        if !overridden.contains("--node-dir"), !preferences.nodeDirectory.isEmpty { nodeDirectory = preferences.nodeDirectory }
        if !overridden.contains("--proxy"), !preferences.proxy.isEmpty { proxy = preferences.proxy }
        extensionPaths = preferences.extensionPaths ?? []
        if let initial = self.workspace, workspace.initialized { _ = await workspace.addProject(initial) }
        return workspace
    }
    var preferences: WorkspacePreferences { .init(piPath: piPath, nodeDirectory: nodeDirectory, proxy: proxy, extensionPaths: extensionPaths) }
    func chooseExtension() {
        let panel = NSOpenPanel(); panel.title = String(localized: "选择信任的 Pi 扩展")
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url, !extensionPaths.contains(url.path), extensionPaths.count < 16 { extensionPaths.append(url.path) }
    }
    func pickProject() -> URL? {
        let panel = NSOpenPanel(); panel.title = String(localized: "选择项目")
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
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
