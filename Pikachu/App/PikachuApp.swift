import SwiftUI
import AppKit
import OrchestrationCore

@main struct PikachuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var workspace: WorkspaceController?
    @State private var startupError: String?
    @State private var settings = AppSettings()
    @State private var quitRequest = 0
    var body: some Scene {
        Window("Pikachu", id: "main") {
            VStack {
                if let workspace { WorkbenchView(workspace: workspace, settings: settings, quitRequest: quitRequest) }
                else if let startupError { ContentUnavailableView("工作台无法打开", systemImage: "exclamationmark.triangle", description: Text(startupError)) }
                else { ProgressView("正在读取本地工作台…") }
            }
            .frame(minWidth: 860, minHeight: 620)
            .preferredColorScheme(settings.diagnosticAppearance)
            .task {
                guard workspace == nil else { return }
                do { let loaded = try await settings.bootstrap(); workspace = loaded; delegate.workspace = loaded }
                catch { startupError = "本地存储无法打开。原文件未覆盖，请检查磁盘与访问权限。" }
            }
        }
        .defaultSize(width: settings.diagnosticWindowWidth ?? 1120, height: 780)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("退出 Pikachu") {
                    if workspace != nil { quitRequest += 1 }
                    else { NSApp.terminate(nil) }
                }.keyboardShortcut("q")
            }
            CommandGroup(replacing: .newItem) {
                Button("打开项目…") {
                    workspace?.openProjectRequest += 1
                }.keyboardShortcut("o").disabled(workspace?.canManageProjects != true)
                Button("新建会话") {
                    workspace?.newSessionRequest += 1
                }.keyboardShortcut("n").disabled(workspace?.state.projects.isEmpty != false || workspace?.canManageProjects != true)
            }
            CommandMenu("会话") {
                Button("聚焦任务输入") { workspace?.focusInput() }.keyboardShortcut("l").disabled(workspace?.viewed == nil)
                Button("返回执行会话") { if let workspace, let id = workspace.activeID { Task { await workspace.select(id) } } }
                    .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(workspace?.activeID == nil)
                Button("模型与推理强度…") { workspace?.configurationRequest += 1 }
                    .keyboardShortcut("m", modifiers: [.command, .shift]).disabled(workspace?.selected == nil || workspace?.busy == true)
                Button("查看 / 关闭会话用量") { workspace?.usageExpanded.toggle() }
                    .keyboardShortcut("u", modifiers: [.command, .shift]).disabled(workspace?.selected == nil)
                Divider()
                Button("停止当前执行") { if let workspace { Task { await workspace.stop() } } }
                    .keyboardShortcut(".", modifiers: .command).disabled(workspace?.busy == true || workspace?.active?.canStop != true)
            }
        }
    }
}
