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

enum PikachuTheme {
    static let lightningYellow = Color(red: 240 / 255, green: 181 / 255, blue: 36 / 255)
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var workspace: WorkspaceController?
    private var approved = false
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !approved, let workspace, workspace.initialized else { return .terminateNow }
        if workspace.active != nil {
            let alert = NSAlert()
            alert.messageText = String(localized: "停止任务并退出？")
            alert.informativeText = String(localized: "Pikachu 将保留草稿、停止当前运行并清理受管工具进程。")
            alert.addButton(withTitle: String(localized: "停止并退出")); alert.addButton(withTitle: String(localized: "取消"))
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        Task {
            await workspace.active?.cancelInteractions()
            let until = Date().addingTimeInterval(6)
            while (workspace.active?.commandPending == true || workspace.busy) && Date() < until { try? await Task.sleep(for: .milliseconds(50)) }
            var clean = await workspace.disconnect()
            if !clean, workspace.active == nil {
                let storage = NSAlert(); storage.alertStyle = .warning
                storage.messageText = String(localized: "草稿尚未保存")
                storage.informativeText = String(localized: "本地保存失败。App 将保持打开，请修复存储后重试保存。")
                storage.addButton(withTitle: String(localized: "返回工作台")); storage.runModal()
                sender.reply(toApplicationShouldTerminate: false); return
            }
            if !clean {
                let force = NSAlert(); force.alertStyle = .warning
                force.messageText = String(localized: "尚未确认停止")
                force.informativeText = String(localized: "可以结束运行时，并等待独立监督进程清理工具；清理未确认时将保持 App 打开。")
                force.addButton(withTitle: String(localized: "结束进程并退出")); force.addButton(withTitle: String(localized: "取消"))
                if force.runModal() == .alertFirstButtonReturn { clean = await workspace.disconnect(force: true) }
            }
            approved = clean
            sender.reply(toApplicationShouldTerminate: clean)
        }
        return .terminateLater
    }
}
