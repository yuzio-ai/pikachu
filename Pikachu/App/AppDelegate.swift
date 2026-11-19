import AppKit
import OrchestrationCore

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
