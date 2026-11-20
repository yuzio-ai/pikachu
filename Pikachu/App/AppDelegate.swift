import AppKit
import Observation
import OrchestrationCore
import OSLog
import SwiftUI

@MainActor @Observable final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "ai.yuzio.pikachu", category: "WorkspaceStartup")
    private static let revealRequest = Notification.Name("ai.yuzio.pikachu.reveal-workbench")
    private static let revealTarget = String(ProcessInfo.processInfo.processIdentifier)

    let isHostingUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    let settings = AppSettings()
    private(set) var workspace: WorkspaceController?
    private(set) var startupError: String?
    @ObservationIgnored private var workspaceLock: WorkspaceLaunchLock?
    @ObservationIgnored private weak var workbenchWindow: NSWindow?
    @ObservationIgnored private var pendingReveal = false
    @ObservationIgnored private var approved = false
    @ObservationIgnored private var terminating = false
    @ObservationIgnored private var terminationRequest: (restarting: Bool, onCancel: () -> Void)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !isHostingUnitTests, let application = notification.object as? NSApplication else { return }
        // Register before taking the lock so concurrent launches can reach the first owner.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(revealFromDuplicate), name: Self.revealRequest,
            object: Self.revealTarget, suspensionBehavior: .deliverImmediately
        )
        do {
            guard settings.launchDirectoryRestored else { throw CocoaError(.fileReadNoSuchFile) }
            var acquisition = try WorkspaceLaunchLock.acquire(for: settings.stateURL)
            if case .heldBy(let pid) = acquisition,
               NSRunningApplication(processIdentifier: pid)?.isTerminated != false {
                acquisition = try WorkspaceLaunchLock.acquire(for: settings.stateURL)
            }
            switch acquisition {
            case .acquired(let lock):
                workspaceLock = lock
                Task {
                    do { workspace = try await settings.bootstrap(with: lock) }
                    catch { reportStartupError(error) }
                }
            case .heldBy(let pid):
                if let owner = NSRunningApplication(processIdentifier: pid) {
                    application.yieldActivation(to: owner)
                    _ = owner.activate(from: .current, options: [])
                }
                DistributedNotificationCenter.default().postNotificationName(
                    Self.revealRequest, object: String(pid), userInfo: nil, deliverImmediately: true
                )
                application.terminate(nil)
            }
        } catch {
            reportStartupError(error)
        }
    }

    func attachWorkbenchWindow(_ window: NSWindow) {
        workbenchWindow = window
        if pendingReveal {
            Task { revealWorkbench(in: NSApp) }
        }
    }

    @objc private func revealFromDuplicate(_ notification: Notification) {
        guard workspaceLock != nil else { return }
        revealWorkbench(in: NSApp)
    }

    private func revealWorkbench(in application: NSApplication) {
        guard let window = workbenchWindow else {
            pendingReveal = true
            return
        }
        pendingReveal = false
        if application.isHidden { application.unhide(nil) }
        if window.isMiniaturized { window.deminiaturize(nil) }
        (application.modalWindow ?? window.attachedSheet ?? window).makeKeyAndOrderFront(nil)
        if !application.isActive { application.activate() }
    }

    private func reportStartupError(_ error: Error) {
        let details = error as NSError
        Self.logger.error("Could not start the workspace (\(details.domain, privacy: .public) \(details.code)): \(details.localizedDescription, privacy: .private)")
        startupError = String(localized: "本地存储无法打开。原文件未覆盖，请检查磁盘与访问权限。")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func requestTermination(restarting: Bool, onCancel: @escaping () -> Void) {
        guard terminationRequest == nil, !terminating, !approved else { onCancel(); return }
        terminationRequest = (restarting, onCancel)
        // AppKit runs a nested event loop for terminateLater. Start it from
        // a run-loop timer so the async cleanup can use the main actor.
        perform(#selector(terminateFromWorkbench), with: nil, afterDelay: 0,
                inModes: [.default, .modalPanel, .eventTracking])
    }

    @objc private func terminateFromWorkbench() {
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !approved else { return .terminateNow }
        guard !terminating else { return .terminateCancel }
        terminating = true
        guard let workspace, workspace.initialized else {
            return finishTermination(clean: true, in: sender) ? .terminateNow : .terminateCancel
        }
        let restarting = terminationRequest?.restarting == true
        let needsConfirmation = restarting ? workspace.restartWouldInterruptWork :
            (!workspace.executionIDs.isEmpty || workspace.hasPendingExecutionControls)
        workspace.beginShutdown()
        if needsConfirmation {
            guard runConfirmation(
                title: restarting ? "停止任务并重新启动？" : "停止任务并退出？",
                message: restarting
                    ? "Pikachu 将保留草稿、停止当前任务并清理受管工具进程，然后重新打开。"
                    : "Pikachu 将保留草稿、停止当前运行并清理受管工具进程。",
                confirmTitle: restarting ? "停止并重新启动" : "停止并退出",
                in: sender
            ) else {
                workspace.cancelShutdown()
                _ = finishTermination(clean: false, in: sender)
                return .terminateCancel
            }
        }
        Task {
            let until = ContinuousClock.now.advanced(by: .seconds(6))
            repeat {
                for id in workspace.executionIDs { await workspace.execution(for: id)?.cancelInteractions() }
                if !workspace.hasPendingExecutionControls { break }
                try? await Task.sleep(for: .milliseconds(50))
            } while ContinuousClock.now < until
            var clean = await workspace.disconnectAll()
            if !clean, workspace.executionIDs.isEmpty, workspace.storageError != nil {
                _ = runConfirmation(title: "草稿尚未保存",
                                    message: "本地保存失败。App 将保持打开，请修复存储后重试保存。",
                                    confirmTitle: "返回工作台", allowsCancel: false, in: sender)
            } else if !clean {
                if runConfirmation(title: "尚未确认停止",
                                   message: "可以结束运行时，并等待独立监督进程清理工具；清理未确认时将保持 App 打开。",
                                   confirmTitle: restarting ? "结束进程并重新启动" : "结束进程并退出", in: sender) {
                    clean = await workspace.disconnectAll(force: true)
                }
            }
            let terminate = finishTermination(clean: clean, in: sender)
            if !terminate { workspace.cancelShutdown() }
            sender.reply(toApplicationShouldTerminate: terminate)
        }
        return .terminateLater
    }

    private func finishTermination(clean: Bool, in application: NSApplication) -> Bool {
        var canTerminate = clean
        if canTerminate, terminationRequest?.restarting == true {
            do {
                try launchRestartHelper()
            } catch {
                Self.logger.error("Could not start the relaunch helper: \(error.localizedDescription, privacy: .private)")
                _ = runConfirmation(title: "无法重新启动 Pikachu",
                                    message: "语言设置已保存。请稍后手动退出并重新打开 Pikachu。",
                                    confirmTitle: "返回工作台", allowsCancel: false, in: application)
                canTerminate = false
            }
        }
        approved = canTerminate
        terminating = false
        let onCancel = terminationRequest?.onCancel
        terminationRequest = nil
        if !canTerminate { onCancel?() }
        return canTerminate
    }

    private func launchRestartHelper() throws {
        guard let helperURL = Bundle.main.url(forAuxiliaryExecutable: "pikachu-supervisor") else {
            throw CocoaError(.fileNoSuchFile)
        }
        var arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
        // A launch-time language override would take precedence over the saved choice.
        while let index = arguments.firstIndex(of: "-AppleLanguages") {
            arguments.removeSubrange(index..<min(index + 2, arguments.endIndex))
        }
        let helper = Process()
        helper.executableURL = helperURL
        helper.currentDirectoryURL = settings.launchDirectory
        helper.arguments = ["--relaunch-app", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath] + arguments
        helper.standardInput = FileHandle.nullDevice
        try helper.run()
    }

    private func runConfirmation(title: LocalizedStringKey, message: LocalizedStringKey,
                                 confirmTitle: LocalizedStringKey, allowsCancel: Bool = true,
                                 in application: NSApplication) -> Bool {
        let request = ConfirmationRequest(title: title, message: message, confirmTitle: confirmTitle,
                                          destructive: allowsCancel, allowsCancel: allowsCancel) {
            application.stopModal(withCode: .OK)
        }
        let content = FlatConfirmation(request: request, cancel: { application.stopModal(withCode: .cancel) })
            .pikachuTypography(settings.interfaceFontSize)
        let host = NSHostingView(rootView: content)
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Pikachu"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.hidesOnDeactivate = false
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        defer { panel.orderOut(nil) }
        return application.runModal(for: panel) == .OK
    }
}

extension WorkspaceController {
    var restartWouldInterruptWork: Bool {
        hasPendingExecutionControls || executionIDs.contains { id in
            guard let active = execution(for: id) else { return false }
            return active.phase.isActive || active.commandPending || !active.queue.isEmpty ||
                !active.interactions.isEmpty || active.connection != .connected
        }
    }
}
