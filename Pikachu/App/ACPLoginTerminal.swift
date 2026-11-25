import AppKit
import Darwin
import SwiftTerm
import SwiftUI
import AgentRuntimeCore
import ProcessSupervision

@MainActor final class ACPLoginTerminal {
    private var attempt: ACPLoginAttempt?

    private var shuttingDown = false

    var hasPendingLogin: Bool {
        if attempt?.confirmCleanup() == true { attempt = nil }
        return attempt != nil
    }

    var hasUnconfirmedCleanup: Bool { hasPendingLogin && attempt?.completed == true }

    func beginShutdown() { shuttingDown = true }
    func resume() { shuttingDown = false }

    func stopAndConfirmCleanup() async -> Bool {
        guard let attempt else { return true }
        attempt.cancel()
        let clean = await attempt.waitForCleanup()
        if clean, self.attempt === attempt { self.attempt = nil }
        return clean
    }

    var authenticator: RuntimeTerminalAuthenticator? {
        guard let helper = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("pikachu-supervisor"),
              FileManager.default.isExecutableFile(atPath: helper.path) else { return nil }
        return { [self] launch in
            try Task.checkCancellation()
            guard !shuttingDown else { throw CancellationError() }
            if hasPendingLogin, let attempt {
                if attempt.completed { throw ACPLoginAttempt.cleanupFailure }
                throw RuntimeFailure(.setup, String(localized: "已有终端登录正在进行。"))
            }
            let login = ACPLoginAttempt(launch: launch, helper: helper)
            attempt = login
            defer { if login.confirmCleanup(), attempt === login { attempt = nil } }
            try await withTaskCancellationHandler {
                try await login.present()
            } onCancel: {
                Task { @MainActor in login.cancel() }
            }
        }
    }
}

@MainActor @Observable private final class ACPLoginAttempt: NSObject, NSWindowDelegate,
                                                          TerminalViewDelegate, @preconcurrency LocalProcessDelegate {
    let launch: RuntimeTerminalAuthenticationLaunch
    private let helper: URL
    private var panel: NSPanel?
    @ObservationIgnored private var continuation: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var statusDirectory: URL?
    @ObservationIgnored private var cancelDeadline: Task<Void, Never>?
    @ObservationIgnored private var process: LocalProcess?
    @ObservationIgnored private var environmentTransfer: Task<Void, Error>?
    @ObservationIgnored private var supervisorExited = false
    @ObservationIgnored private var launchFailed = false
    private(set) var completed = false
    private(set) var terminal: TerminalView?
    private(set) var cancelling = false

    init(launch: RuntimeTerminalAuthenticationLaunch, helper: URL) {
        self.launch = launch
        self.helper = helper
    }

    func present() async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 410),
                                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = String(localized: "ACP 终端登录")
            panel.contentMinSize = NSSize(width: 460, height: 320)
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.delegate = self
            panel.contentView = NSHostingView(rootView: ACPLoginTerminalContent(attempt: self))
            self.panel = panel
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func start(environmentApproved: Bool) {
        guard process == nil, continuation != nil, !cancelling,
              !launch.requiresEnvironmentConsent || environmentApproved else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pikachu-login-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            statusDirectory = directory
            let pipe = try TerminalLoginEnvironment.create(in: directory)
            let terminal = TerminalView(frame: .init(x: 0, y: 0, width: 620, height: 340), options: .init(scrollback: 0))
            terminal.terminalDelegate = self
            terminal.setAccessibilityLabel(String(localized: "ACP 登录终端"))
            let process = LocalProcess(delegate: self, dispatchQueue: .main)
            let arguments = [
                directory.appendingPathComponent("status.json").path,
                UUID().uuidString, String(getpid()), "--terminal-login", launch.executable.path
            ] + launch.arguments
            self.terminal = terminal
            try process.startProcessChecked(executable: helper.path, args: arguments,
                                            environment: ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "TERM=xterm-256color"],
                                            currentDirectory: launch.workingDirectory.path).get()
            self.process = process
            let environment = launch.environment
            let transfer = Task.detached { try TerminalLoginEnvironment.send(environment, through: pipe) }
            environmentTransfer = transfer
            Task { [weak self] in
                guard case .failure = await transfer.result,
                      let self, !self.cancelling, !self.completed else { return }
                self.launchFailed = true
                self.cancel()
            }
        } catch {
            finish(.failure(Self.launchFailure))
        }
    }

    func cancel() {
        guard !completed, !cancelling else { return }
        guard let process else {
            finish(.failure(CancellationError()))
            return
        }
        cancelling = true
        environmentTransfer?.cancel()
        process.terminate()
        cancelDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            self?.finishWithUnconfirmedCleanup()
        }
    }

    func waitForCleanup() async -> Bool {
        while !completed {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
        }
        return confirmCleanup()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancel()
        return false
    }

    private struct Report: Decodable {
        let state: String
        let remaining: Int
        let supervisionID: String
        let reason: String
        let runtimeExitStatus: Int?
        let runtimeExitBySignal: Bool?
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        guard source === process else { return }
        supervisorExited = true
        environmentTransfer?.cancel()
        if completed {
            _ = confirmCleanup()
            return
        }
        guard let report = cleanReport() else {
            finishWithUnconfirmedCleanup()
            return
        }
        if launchFailed || report.reason == "terminalLaunchFailed" {
            finish(.failure(Self.launchFailure))
        } else if cancelling || report.reason == "supervisorStopRequested" {
            finish(.failure(CancellationError()))
        } else if exitCode == 0, report.runtimeExitStatus == 0, report.runtimeExitBySignal == false {
            finish(.success(()))
        } else {
            finish(.failure(RuntimeFailure(.authentication, String(localized: "ACP 终端登录未成功。请重试。"))))
        }
    }

    static var cleanupFailure: RuntimeFailure {
        .init(.supervision, String(localized: "ACP 登录终端的进程清理未确认。"))
    }

    private static var launchFailure: RuntimeFailure {
        .init(.setup, String(localized: "无法启动 ACP 登录终端。"))
    }

    private func cleanReport() -> Report? {
        guard let directory = statusDirectory,
              let data = try? Data(contentsOf: directory.appendingPathComponent("status.json")),
              let report = try? JSONDecoder().decode(Report.self, from: data),
              report.supervisionID == directory.lastPathComponent,
              report.state == "clean", report.remaining == 0 else { return nil }
        return report
    }

    func confirmCleanup() -> Bool {
        guard completed, process == nil || (supervisorExited && cleanReport() != nil) else { return false }
        process = nil
        if let statusDirectory { try? FileManager.default.removeItem(at: statusDirectory) }
        statusDirectory = nil
        return true
    }

    private func finishWithUnconfirmedCleanup() {
        finish(.failure(RuntimeTerminalCleanupPending(failure: Self.cleanupFailure) { [self] in confirmCleanup() }))
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        completed = true
        cancelDeadline?.cancel()
        environmentTransfer?.cancel()
        cancelDeadline = nil
        environmentTransfer = nil
        panel?.delegate = nil
        panel?.close()
        panel?.contentView = nil
        panel = nil
        terminal = nil
        _ = confirmCleanup()
        continuation.resume(with: result)
    }

    func dataReceived(slice: ArraySlice<UInt8>) { terminal?.feed(byteArray: slice) }

    func getWindowSize() -> winsize {
        guard let options = terminal?.terminalDimensions else { return winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0) }
        return winsize(ws_row: UInt16(clamping: options.rows), ws_col: UInt16(clamping: options.cols),
                       ws_xpixel: 0, ws_ypixel: 0)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        var size = winsize(ws_row: UInt16(clamping: newRows), ws_col: UInt16(clamping: newCols), ws_xpixel: 0, ws_ypixel: 0)
        _ = process?.updateWindowSize(&size)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) { process?.send(data: data) }
    func scrolled(source: TerminalView, position: Double) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func requestOpenLink(source: TerminalView, request: TerminalLinkRequest) {
        guard let scheme = URL(string: request.link)?.scheme?.lowercased(),
              ["https", "http"].contains(scheme) else { return }
        request.openDefault()
    }
}

private struct ACPLoginTerminalContent: View {
    let attempt: ACPLoginAttempt
    @State private var approvesEnvironment = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(attempt.launch.name).pikachuFont(.title3, weight: .semibold)
            if let terminal = attempt.terminal {
                ACPLoginTerminalSurface(terminal: terminal)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ACPLoginTerminalPreview(launch: attempt.launch)
                if attempt.launch.requiresEnvironmentConsent {
                    Toggle("允许登录进程应用上述运行环境更改", isOn: $approvesEnvironment)
                }
            }
            HStack {
                Button("取消", role: .cancel, action: attempt.cancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(attempt.cancelling)
                Spacer()
                if attempt.cancelling {
                    FlatProgressView("正在结束登录…")
                } else if attempt.terminal == nil {
                    Button("启动登录终端") { attempt.start(environmentApproved: approvesEnvironment) }
                        .disabled(attempt.launch.requiresEnvironmentConsent && !approvesEnvironment)
                        .buttonStyle(FlatControlButtonStyle(treatment: .prominent))
                }
            }
        }
        .padding(16)
        .frame(minWidth: 460, minHeight: 320)
        .background(PikachuTheme.pageBackground)
    }
}

private struct ACPLoginTerminalPreview: View {
    let launch: RuntimeTerminalAuthenticationLaunch
    @State private var showsValues = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("确认 Agent 请求的启动参数和环境覆盖。登录凭据由 Agent 处理。")
                    .pikachuFont(.callout)
                Text(launch.executable.path).pikachuFont(.callout, design: .monospaced)
                if !launch.appendedArguments.isEmpty {
                    Text("追加参数").pikachuFont(.callout, weight: .semibold)
                    Text(launch.appendedArguments.map { String(reflecting: $0) }.joined(separator: "\n"))
                        .pikachuFont(.callout, design: .monospaced)
                }
                if !launch.environmentOverrides.isEmpty {
                    Toggle("显示环境覆盖值", isOn: $showsValues)
                    Text(launch.environmentOverrides.sorted(by: { $0.key < $1.key }).map {
                        showsValues ? "\($0.key)=\(String(reflecting: $0.value))" : $0.key
                    }.joined(separator: "\n"))
                    .pikachuFont(.callout, design: .monospaced)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ACPLoginTerminalSurface: NSViewRepresentable {
    let terminal: TerminalView

    func makeNSView(context: Context) -> TerminalView {
        Task { @MainActor [weak terminal] in
            guard let terminal else { return }
            terminal.window?.makeFirstResponder(terminal)
        }
        return terminal
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}
}
