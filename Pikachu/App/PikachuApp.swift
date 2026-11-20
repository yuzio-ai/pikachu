import SwiftUI
import AppKit
import OrchestrationCore

@main struct PikachuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var quitRequest = 0
    @State private var openSettingsRequest = 0
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    private var workspace: WorkspaceController? { delegate.workspace }
    private var settings: AppSettings { delegate.settings }

    var body: some Scene {
        Window("Pikachu", id: "main") {
            VStack {
                if delegate.isHostingUnitTests { EmptyView() }
                else if let workspace {
                    WorkbenchView(workspace: workspace, settings: settings, quitRequest: quitRequest,
                                  openSettingsRequest: openSettingsRequest, terminate: delegate.requestTermination,
                                  sidebarVisibility: $sidebarVisibility)
                }
                else if let startupError = delegate.startupError {
                    FlatEmptyState("工作台无法打开", systemImage: "exclamationmark.triangle",
                                   description: Text(startupError), iconColor: PikachuTheme.errorText)
                }
                else { FlatProgressView("正在读取本地工作台…") }
            }
            .frame(minWidth: 860, minHeight: 620)
            .background(PikachuTheme.workspace)
            .background {
                WorkbenchWindowAttachment(delegate: delegate)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                Button("") {
                    settings.interfaceFontSize = settings.interfaceFontSize.increased()
                }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(!settings.interfaceFontSize.canIncrease)
                .opacity(0)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .pikachuTypography(settings.interfaceFontSize)
            .preferredColorScheme(settings.diagnosticAppearance)
        }
        .defaultSize(width: settings.diagnosticWindowWidth ?? 1120, height: 780)
        .commands {
            CommandGroup(after: .sidebar) {
                Button(sidebarVisibility == .detailOnly ? "显示侧栏" : "隐藏侧栏") {
                    sidebarVisibility = sidebarVisibility == .detailOnly ? .all : .detailOnly
                }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(workspace == nil)
                Divider()
                Button("放大字体") {
                    settings.interfaceFontSize = settings.interfaceFontSize.increased()
                }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!settings.interfaceFontSize.canIncrease)
                Button("缩小字体") {
                    settings.interfaceFontSize = settings.interfaceFontSize.decreased()
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!settings.interfaceFontSize.canDecrease)
                Button("恢复默认字体大小") {
                    settings.interfaceFontSize = .standard
                }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(settings.interfaceFontSize == .standard)
            }
            CommandGroup(after: .windowSize) {
                Button("切换工作台全屏") { delegate.toggleWorkbenchFullScreen() }
                    .keyboardShortcut("f", modifiers: [.control, .command])
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { openSettingsRequest += 1 }
                    .keyboardShortcut(",", modifiers: .command)
                    .disabled(workspace == nil)
            }
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
                if let workspace, workspace.executionIDs.count == 1, let id = workspace.executionIDs.first {
                    Button("返回执行会话") { Task { await workspace.select(id) } }
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                } else if let workspace, !workspace.executionIDs.isEmpty {
                    Menu("执行会话") {
                        ForEach(workspace.executionIDs, id: \.self) { id in
                            if let session = workspace.state.sessions.first(where: { $0.id == id }) {
                                Button(session.displayTitle) { Task { await workspace.select(id) } }
                            }
                        }
                    }
                }
                Button("模型与推理强度…") { workspace?.configurationRequest += 1 }
                    .keyboardShortcut("m", modifiers: [.command, .shift]).disabled(workspace?.selected == nil || workspace?.viewed.map { workspace?.isOperating(on: $0.id) == true } == true)
                Button("查看 / 关闭会话用量") { workspace?.usageExpanded.toggle() }
                    .keyboardShortcut("u", modifiers: [.command, .shift]).disabled(workspace?.selected == nil)
                Divider()
                let selectedID = workspace?.selected?.id
                Button("停止当前执行") {
                    if let workspace { Task { await workspace.stopViewedSession() } }
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(selectedID.map { workspace?.canStop($0) == true } != true)
            }
        }
    }
}

private struct WorkbenchWindowAttachment: NSViewRepresentable {
    let delegate: AppDelegate

    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.appDelegate = delegate
        return view
    }

    func updateNSView(_ nsView: AttachmentView, context: Context) {}

    final class AttachmentView: NSView {
        weak var appDelegate: AppDelegate?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { appDelegate?.attachWorkbenchWindow(window) }
        }
    }
}
