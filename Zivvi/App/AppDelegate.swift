import AppKit
import Observation
import OrchestrationCore
import OSLog
import SwiftUI
import UserNotifications

@MainActor @Observable final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private static let logger = Logger(subsystem: "ai.yuzio.zivvi", category: "WorkspaceStartup")
    private static let revealRequest = Notification.Name("ai.yuzio.zivvi.reveal-workbench")
    private static let revealTarget = String(ProcessInfo.processInfo.processIdentifier)

    let isHostingUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    let settings = AppSettings()
    let tabsModel = WorkbenchTabsModel()
    @ObservationIgnored var reopenWorkbenchWindow: (() -> Void)?
    private(set) var workspace: WorkspaceController?
    private(set) var startupError: String?
    private(set) var quitRequest = 0
    private(set) var showsQuitShortcutHint = false
    @ObservationIgnored private var quitShortcutMonitor: Any?
    @ObservationIgnored private var quitHintExpiry: Task<Void, Never>?
    @ObservationIgnored private var quitHintDeadline: ContinuousClock.Instant?
    @ObservationIgnored private var quitHold: Task<Void, Never>?
    @ObservationIgnored private var heldQuitKey: UInt16?
    @ObservationIgnored private var workspaceLock: WorkspaceLaunchLock?
    @ObservationIgnored private var taskStatusMenu: TaskStatusMenu?
    @ObservationIgnored private weak var workbenchWindow: NSWindow?
    @ObservationIgnored private var pendingReveal = false
    @ObservationIgnored private var pendingNotificationDestination: TaskNotificationDestination?
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
                // Register before launch completes so a notification can open the app from a cold start.
                UNUserNotificationCenter.current().delegate = self
                settings.isWorkbenchForegroundActive = { [weak self] in
                    self?.isWorkbenchForegroundActive ?? false
                }
                Task {
                    do {
                        workspace = try await settings.bootstrap(with: lock)
                        if let destination = pendingNotificationDestination {
                            pendingNotificationDestination = nil
                            await openNotificationDestination(destination)
                        }
                    } catch { reportStartupError(error) }
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isHostingUnitTests else { return }
        if workspaceLock != nil || startupError != nil { taskStatusMenu = TaskStatusMenu(appDelegate: self) }
        quitShortcutMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.consumeQuitShortcut(event) == true }
            return consumed ? nil : event
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        cancelQuitShortcut()
    }

    func applicationWillTerminate(_ notification: Notification) {
        taskStatusMenu?.remove()
        taskStatusMenu = nil
        cancelQuitShortcut()
        if let quitShortcutMonitor { NSEvent.removeMonitor(quitShortcutMonitor) }
        quitShortcutMonitor = nil
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let request = response.notification.request
        guard let destination = TaskNotificationDestination(actionIdentifier: response.actionIdentifier,
                                                            requestIdentifier: request.identifier,
                                                            userInfo: request.content.userInfo) else { return }
        await openNotificationDestination(destination)
    }

    private func openNotificationDestination(_ destination: TaskNotificationDestination) async {
        guard !terminating, !approved else { return }
        if let workspace {
            if let id = destination.sessionID(in: workspace.state.sessions) {
                await workspace.openSessionForReview(id, acknowledging: destination.turnID)
            }
        } else if startupError == nil {
            pendingNotificationDestination = destination
        }
        revealWorkbench(in: NSApp)
    }

    func openWorkbenchFromStatusMenu(sessionID: UUID? = nil, acknowledgesCompletion: Bool = false) {
        guard !terminating, !approved else { return }
        revealWorkbench(in: NSApp)
        if let workspace, let sessionID {
            Task {
                if acknowledgesCompletion { await workspace.openSessionForReview(sessionID) }
                else { await workspace.select(sessionID) }
            }
        }
    }

    var isWorkbenchForegroundActive: Bool {
        guard let window = workbenchWindow,
              window.isVisible,
              !window.isMiniaturized,
              window.isKeyWindow,
              window.attachedSheet == nil else { return false }
        return NSApp.isActive && NSApp.modalWindow == nil && !terminating && !approved
    }

    func toggleWorkbenchFullScreen() {
        guard let window = workbenchWindow, window.isKeyWindow, window.attachedSheet == nil else { return }
        window.toggleFullScreen(nil)
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        guard tabsModel.hasUnsavedFileEdits || tabsModel.isSavingFile else { return true }
        requestTermination(restarting: false) { [weak self] in self?.reopenWorkbenchWindow?() }
        return false
    }

    func quitFromMenu() {
        cancelQuitShortcut()
        if workspace != nil { quitRequest += 1 }
        else { NSApp.terminate(nil) }
    }

    func cancelQuitShortcut() {
        cancelQuitHold()
        quitHintExpiry?.cancel()
        quitHintExpiry = nil
        quitHintDeadline = nil
        showsQuitShortcutHint = false
    }

    private func cancelQuitHold() {
        quitHold?.cancel()
        quitHold = nil
        heldQuitKey = nil
    }

    private var canShowQuitShortcut: Bool {
        guard let window = workbenchWindow, window.isKeyWindow, window.attachedSheet == nil else { return false }
        return NSApp.isActive && NSApp.modalWindow == nil && !terminating && !approved && terminationRequest == nil
    }

    private var canUseIdleQuitShortcut: Bool {
        guard canShowQuitShortcut, let workspace, workspace.initialized else { return false }
        return !workspace.terminationWouldInterruptWork && !tabsModel.hasUnsavedFileEdits && !tabsModel.isSavingFile
    }

    private func consumeQuitShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.type {
        case .flagsChanged:
            if modifiers != .command { cancelQuitHold() }
        case .keyUp:
            if event.keyCode == heldQuitKey { cancelQuitHold() }
        case .keyDown:
            guard modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "q" else {
                cancelQuitShortcut()
                return false
            }
            // A repeat is neither a fresh confirmation nor evidence of a second press.
            if event.isARepeat { return true }
            guard canUseIdleQuitShortcut, let window = workbenchWindow else {
                cancelQuitShortcut()
                return false // The normal menu action still handles active work and startup.
            }
            let now = ContinuousClock.now
            if let quitHintDeadline, now >= quitHintDeadline {
                cancelQuitShortcut()
            }
            if showsQuitShortcutHint, heldQuitKey == nil {
                quitFromMenu()
            } else if !showsQuitShortcutHint {
                let deadline = now.advanced(by: .seconds(2))
                quitHintDeadline = deadline
                showsQuitShortcutHint = true
                heldQuitKey = event.keyCode
                NSAccessibility.post(
                    element: window, notification: .announcementRequested,
                    userInfo: [.announcement: String(localized: "按住 ⌘Q，或再按一次退出"),
                               .priority: NSAccessibilityPriorityLevel.medium.rawValue]
                )
                quitHold = Task { [weak self] in
                    do { try await Task.sleep(until: now.advanced(by: .milliseconds(650)), clock: .continuous) } catch { return }
                    guard !Task.isCancelled, let self else { return }
                    guard ContinuousClock.now < deadline, canUseIdleQuitShortcut else {
                        cancelQuitShortcut()
                        return
                    }
                    quitFromMenu()
                }
                quitHintExpiry = Task { [weak self] in
                    do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                    guard !Task.isCancelled else { return }
                    self?.cancelQuitShortcut()
                }
            }
            return true
        default:
            cancelQuitShortcut()
        }
        return false
    }

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
        cancelQuitShortcut()
        terminating = true
        tabsModel.isPreparingToTerminate = true
        guard let workspace, workspace.initialized else {
            if !settings.hasPendingTerminalLogin, !settings.hasAuthenticationControl, !settings.hasHistoryControls {
                return finishTermination(clean: true, in: sender) ? .terminateNow : .terminateCancel
            }
            settings.beginAuthenticationShutdown()
            Task {
                let authenticationClean = await settings.stopAndConfirmAuthenticationCleanup()
                let historyClean = await settings.stopAndConfirmHistoryCleanup()
                let clean = authenticationClean && historyClean
                let terminate = finishTermination(clean: clean, in: sender)
                if !terminate { settings.resumeAuthentication() }
                sender.reply(toApplicationShouldTerminate: terminate)
            }
            return .terminateLater
        }
        let restarting = terminationRequest?.restarting == true
        if tabsModel.isSavingFile {
            _ = runConfirmation(title: "正在保存文件", message: "请等待保存完成后再退出或重新启动。",
                                confirmTitle: "返回工作台", allowsCancel: false, in: sender)
            _ = finishTermination(clean: false, in: sender)
            return .terminateCancel
        }
        let interruptsWork = workspace.terminationWouldInterruptWork || settings.hasPendingTerminalLogin
        let discardsFileEdits = tabsModel.hasUnsavedFileEdits
        workspace.beginShutdown()
        if discardsFileEdits {
            guard runConfirmation(
                title: restarting ? "放弃未保存的文件更改并重新启动？" : "放弃未保存的文件更改并退出？",
                message: interruptsWork
                    ? "未保存的文件更改将丢失，当前任务将停止。会话草稿会保留。"
                    : "未保存的文件更改将丢失。会话草稿会保留。",
                confirmTitle: restarting ? "放弃并重新启动" : "放弃并退出",
                cancelTitle: "继续工作", defaultsToCancel: true, in: sender
            ) else {
                workspace.cancelShutdown()
                _ = finishTermination(clean: false, in: sender)
                return .terminateCancel
            }
        } else if interruptsWork {
            guard runConfirmation(
                title: restarting ? "停止任务并重新启动？" : "停止任务并退出？",
                message: restarting
                    ? "Zivvi 将保留草稿、停止当前任务并清理受管工具进程，然后重新打开。"
                    : "退出会停止任务，草稿会保留。",
                confirmTitle: restarting ? "停止并重新启动" : "停止并退出",
                cancelTitle: restarting ? "取消" : "继续工作",
                defaultsToCancel: !restarting,
                width: restarting ? 448 : 360,
                in: sender
            ) else {
                workspace.cancelShutdown()
                _ = finishTermination(clean: false, in: sender)
                return .terminateCancel
            }
        }
        settings.beginAuthenticationShutdown()
        Task {
            let authenticationClean = await settings.stopAndConfirmAuthenticationCleanup()
            let historyClean = await settings.stopAndConfirmHistoryCleanup()
            let until = ContinuousClock.now.advanced(by: .seconds(6))
            repeat {
                for id in workspace.executionIDs { await workspace.execution(for: id)?.cancelInteractions() }
                if !workspace.hasPendingExecutionControls { break }
                try? await Task.sleep(for: .milliseconds(50))
            } while ContinuousClock.now < until
            var clean = await workspace.disconnectAll()
            if clean { clean = await settings.stopACPConnections() && historyClean }
            if !authenticationClean {
                _ = runConfirmation(title: "ACP 登录进程清理未确认",
                                    message: "Zivvi 将保持打开，直到登录进程的清理得到确认。",
                                    confirmTitle: "返回工作台", allowsCancel: false, in: sender)
            } else if !clean, workspace.executionIDs.isEmpty, workspace.storageError != nil {
                _ = runConfirmation(title: "草稿尚未保存",
                                    message: "本地保存失败。Zivvi 将保持打开，请修复存储后重试保存。",
                                    confirmTitle: "返回工作台", allowsCancel: false, in: sender)
            } else if !clean {
                if runConfirmation(title: "尚未确认停止",
                                   message: "可以结束运行时，并等待独立监督进程清理工具；清理未确认时将保持 Zivvi 打开。",
                                   confirmTitle: restarting ? "结束进程并重新启动" : "结束进程并退出", in: sender) {
                    clean = await workspace.disconnectAll(force: true)
                    let connectionsClean = await settings.stopACPConnections(force: true)
                    let historyClean = await settings.stopAndConfirmHistoryCleanup()
                    clean = clean && connectionsClean && historyClean
                }
            }
            let terminate = finishTermination(clean: authenticationClean && clean, in: sender)
            if !terminate {
                settings.resumeAuthentication()
                workspace.cancelShutdown()
                await settings.resumeACPConnections()
            }
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
                _ = runConfirmation(title: "无法重新启动 Zivvi",
                                    message: "语言设置已保存。请稍后手动退出并重新打开 Zivvi。",
                                    confirmTitle: "返回工作台", allowsCancel: false, in: application)
                canTerminate = false
            }
        }
        approved = canTerminate
        terminating = false
        let onCancel = terminationRequest?.onCancel
        terminationRequest = nil
        if !canTerminate {
            tabsModel.isPreparingToTerminate = false
            onCancel?()
        }
        return canTerminate
    }

    private func launchRestartHelper() throws {
        guard let helperURL = Bundle.main.url(forAuxiliaryExecutable: "zivvi-supervisor") else {
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
                                 cancelTitle: LocalizedStringKey = "取消", defaultsToCancel: Bool = false,
                                 width: CGFloat = 448, in application: NSApplication) -> Bool {
        let request = ConfirmationRequest(title: title, message: message, confirmTitle: confirmTitle,
                                          destructive: allowsCancel, allowsCancel: allowsCancel,
                                          cancelTitle: cancelTitle, defaultsToCancel: defaultsToCancel) {
            application.stopModal(withCode: .OK)
        }
        let content = FlatConfirmation(request: request, cancel: { application.stopModal(withCode: .cancel) }, width: width)
            .zivviTypography(settings.interfaceFontSize)
        let panel = ConfirmationPanel.make(rootView: content)
        panel.makeKeyAndOrderFront(nil)
        defer { panel.orderOut(nil) }
        return application.runModal(for: panel) == .OK
    }
}

extension WorkspaceController {
    var terminationWouldInterruptWork: Bool {
        hasPendingExecutionControls || executionIDs.contains { id in
            guard let active = execution(for: id) else { return false }
            return active.phase.isActive || active.commandPending || !active.queue.isEmpty ||
                !active.interactions.isEmpty || active.connection != .connected
        }
    }
}
