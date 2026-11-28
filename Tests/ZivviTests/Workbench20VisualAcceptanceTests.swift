import AppKit
import Foundation
import SwiftUI
import XCTest
import AgentRuntimeCore
@testable import OrchestrationCore
@testable import Zivvi

private actor VisualMemoryStore: WorkspaceStore {
    var snapshot: WorkspaceSnapshot
    init(_ snapshot: WorkspaceSnapshot = .init()) { self.snapshot = snapshot }
    func load() -> WorkspaceSnapshot { snapshot }
    func save(_ value: WorkspaceSnapshot) {
        if value.revision > snapshot.revision { snapshot = value }
    }
}

private final class VisualStubRuntime: AgentRuntime, @unchecked Sendable {
    let instanceID = UUID()
    let events: AsyncStream<RuntimeEnvelope>
    let continuation: AsyncStream<RuntimeEnvelope>.Continuation

    init() {
        let pair = AsyncStream<RuntimeEnvelope>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    func connect() async throws -> RuntimeSession {
        .init(id: "visual-session", model: "Gemini 3.1 Pro", thinking: "high",
              capabilities: [.streaming, .tools, .interruption, .queuedPrompts],
              provider: "antigravity", modelID: "gemini-3.1-pro", runtimeID: RuntimeAgentProfile.antigravityRuntimeID)
    }
    func send(_ prompt: UserPrompt) async throws -> PromptDisposition { .started }
    func stop() async throws { emit(.settled(aborted: true)) }
    func close(force: Bool) async throws { emit(.disconnected(cleanupConfirmed: true)); continuation.finish() }
    func configurationOptions() async throws -> RuntimeConfigurationOptions {
        .init(models: [.init(provider: "antigravity", modelID: "gemini-3.1-pro", name: "Gemini 3.1 Pro")], thinkingLevels: ["low", "high"])
    }
    func applyConfiguration(_ selection: RuntimeSelection) async throws -> RuntimeSession {
        .init(id: "visual-session", model: selection.modelID, thinking: selection.thinking ?? "high",
              capabilities: [.streaming, .tools, .interruption, .queuedPrompts],
              provider: selection.provider, modelID: selection.modelID)
    }
    func usage() async throws -> RuntimeUsage { RuntimeUsage(sessionID: "visual-session") }
    func emit(_ event: AgentEvent) { continuation.yield(.init(instanceID: instanceID, event: event)) }
}

final class Workbench20VisualAcceptanceTests: XCTestCase {

    @MainActor
    func testCaptureWorkbench20NativeScreenshots() async throws {
        guard let outputDirPath = ProcessInfo.processInfo.environment["ZIVVI_CAPTURE_DIR"],
              !outputDirPath.isEmpty else {
            throw XCTSkip("Set ZIVVI_CAPTURE_DIR to capture native Workbench 2.0 visual acceptance screenshots.")
        }

        let outputDir = URL(fileURLWithPath: outputDirPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // Create two real temporary Git repositories on disk for authentic File Tree + Git stats + Diff + Commits.
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zivvi-visual-20-\(UUID().uuidString)", isDirectory: true)
        let repoA = fixtureRoot.appendingPathComponent("zivvi-core", isDirectory: true)
        let repoB = fixtureRoot.appendingPathComponent("design-docs", isDirectory: true)
        try FileManager.default.createDirectory(at: repoA.appendingPathComponent("Sources/Workbench", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoB.appendingPathComponent("specs", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        func runGit(_ args: [String], in dir: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = dir
            var env = ProcessInfo.processInfo.environment
            env["GIT_AUTHOR_NAME"] = "Bowen Zhu"
            env["GIT_AUTHOR_EMAIL"] = "bowen@zivvi.local"
            env["GIT_COMMITTER_NAME"] = "Bowen Zhu"
            env["GIT_COMMITTER_EMAIL"] = "bowen@zivvi.local"
            process.environment = env
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }

        // Seed Repo A (ZivviCore)
        try runGit(["init", "-b", "main"], in: repoA)
        let appSwiftURL = repoA.appendingPathComponent("Sources/Workbench/WorkbenchView.swift")
        let readmeURL = repoA.appendingPathComponent("README.md")
        try """
        import SwiftUI

        struct WorkbenchLayout {
            let sidebarWidth: CGFloat = 240
            let usesOverlayComposer: Bool = true
            let showsBottomStatusBar: Bool = false
        }
        """.write(to: appSwiftURL, atomically: true, encoding: .utf8)
        try """
        # Zivvi Workbench 2.0

        Modern Minimalist Flat Layout × Swiss Typography × Native macOS.

        ## 核心变更

        | 模块 | 2.0 架构 | 状态 |
        | --- | --- | --- |
        | 左侧导航器 | 按项目分组的 S / F / G 视图切换 | 已完成 |
        | 双标签页组 | 对话区与编辑区独立标签栏 | 已完成 |
        | 渐进式 Markdown | 稳定块即时渲染 + 语义骨架 | 已完成 |
        | 全局状态栏 | 设置 / 仪表盘 / 升级 + 多源额度 | 已完成 |

        ```swift
        let split = ProgressiveMarkdownSplitter.split(stream, isStreaming: true)
        ```
        """.write(to: readmeURL, atomically: true, encoding: .utf8)
        try runGit(["add", "."], in: repoA)
        try runGit(["commit", "-m", "feat(workbench): initialize baseline layout"], in: repoA)

        // Commit 2
        try """
        import SwiftUI

        struct WorkbenchLayout {
            let sidebarWidth: CGFloat = 250
            let usesOverlayComposer: Bool = false
            let showsBottomStatusBar: Bool = true
            let readingColumnMaxWidth: CGFloat = 800
        }
        """.write(to: appSwiftURL, atomically: true, encoding: .utf8)
        try runGit(["add", "Sources/Workbench/WorkbenchView.swift"], in: repoA)
        try runGit(["commit", "-m", "refactor(composer): migrate to adaptive vertical dock"], in: repoA)

        // Unstaged + Staged + Untracked working tree changes in Repo A
        try """
        import SwiftUI

        struct WorkbenchLayout {
            let sidebarWidth: CGFloat = 252
            let editorMinWidth: CGFloat = 340
            let usesOverlayComposer: Bool = false
            let showsBottomStatusBar: Bool = true
            let readingColumnMaxWidth: CGFloat = 800
        }
        """.write(to: appSwiftURL, atomically: true, encoding: .utf8)
        let newFileURL = repoA.appendingPathComponent("Sources/Workbench/GlobalStatusBar.swift")
        try """
        import SwiftUI

        struct GlobalStatusBarSpec {
            static let height: CGFloat = 28
        }
        """.write(to: newFileURL, atomically: true, encoding: .utf8)
        try runGit(["add", "Sources/Workbench/GlobalStatusBar.swift"], in: repoA)

        let untrackedURL = repoA.appendingPathComponent("Sources/Workbench/MarkdownSkeleton.swift")
        try "// Static semantic skeleton\nlet delayMS = 300\nlet mergeWindowMS = 140\n".write(to: untrackedURL, atomically: true, encoding: .utf8)

        // Seed Repo B (DesignDocs)
        try runGit(["init", "-b", "main"], in: repoB)
        let specURL = repoB.appendingPathComponent("specs/workbench-2.0.md")
        try "# Design Spec\n\n- Flat by default\n- Native macOS\n".write(to: specURL, atomically: true, encoding: .utf8)
        try runGit(["add", "."], in: repoB)
        try runGit(["commit", "-m", "docs: add Workbench 2.0 spec"], in: repoB)
        try "# Design Spec\n\n- Flat by default\n- Native macOS\n- Swiss Typography\n".write(to: specURL, atomically: true, encoding: .utf8)

        // Build WorkspaceController with 2 projects and active + settled sessions
        let projectA = ProjectRecord(path: repoA.path)
        let projectB = ProjectRecord(path: repoB.path)
        var s1 = SessionReference(projectID: projectA.id, runtimeID: RuntimeAgentProfile.antigravityRuntimeID)
        s1.title = "重构工作台 2.0 布局与双标签页"
        var s2 = SessionReference(projectID: projectA.id, runtimeID: RuntimeAgentProfile.antigravityRuntimeID)
        s2.title = "实现渐进式 Markdown 语义骨架"
        var s3 = SessionReference(projectID: projectB.id, runtimeID: RuntimeAgentProfile.antigravityRuntimeID)
        s3.title = "同步 DESIGN.md 与设计令牌"
        var sSettled = SessionReference(projectID: projectA.id, runtimeID: RuntimeAgentProfile.antigravityRuntimeID)
        sSettled.title = "统一操作审批弹窗 DS-27"
        sSettled.processingStatus = .settled

        var snapshot = WorkspaceSnapshot()
        snapshot.projects = [projectA, projectB]
        snapshot.sessions = [s1, s2, s3, sSettled]
        snapshot.selectedSessionID = s1.id

        let stubRuntime = VisualStubRuntime()
        let workspace = WorkspaceController(store: VisualMemoryStore(snapshot)) { _, _ in stubRuntime }
        await workspace.start()
        workspace.setACPAgents([.antigravityPreset()])
        await workspace.select(s1.id)
        _ = await workspace.activate(s1.id)

        let controller = try XCTUnwrap(workspace.viewed?.controller)

        // Populate rich Turn 1 (user + 2 completed tools with summaries + rich Markdown response)
        await controller.sendDraft(UserPrompt(text: "请按 Workbench 2.0 规范重构左侧项目导航器、双标签页组与渐进式 Markdown 渲染。"))
        stubRuntime.emit(.runStarted)
        stubRuntime.emit(.tool(RuntimeTool(
            id: "t-read", name: "read", summary: "读取 WorkbenchView.swift 布局定义",
            arguments: #"{"path":"Sources/Workbench/WorkbenchView.swift"}"#, output: "OK", state: .completed
        )))
        stubRuntime.emit(.tool(RuntimeTool(
            id: "t-edit", name: "edit", summary: "重构 Adaptive Composer Dock 为垂直布局",
            arguments: #"{"path":"Sources/Workbench/WorkbenchView.swift","edits":[{"oldText":"let usesOverlayComposer = true","newText":"let usesOverlayComposer = false"}]}"#,
            output: "Applied", state: .completed
        )))
        let replyID1 = UUID()
        stubRuntime.emit(.assistantStarted(replyID1))
        stubRuntime.emit(.assistantCompleted(replyID1, """
        已完成 **Zivvi Workbench 2.0** 的核心重构：

        ### 已交付模块

        | 区域 | 实现要点 |
        | --- | --- |
        | 左侧项目导航器 | 按项目独立记忆 `S / F / G` 模式，支持净 HEAD 变更行统计 |
        | 双标签页组 | 对话与编辑区独立标签，支持跨项目共存与安全编辑冲突检测 |
        | 渐进式 Markdown | 140 ms 合并解析，300 ms 延迟静态语义骨架，零闪烁 |

        ```swift
        let split = ProgressiveMarkdownSplitter.split(source, isStreaming: true)
        ```
        """))
        stubRuntime.emit(.settled(aborted: false))

        // Populate Turn 2 (quota exhausted structured error + task plan notice)
        await controller.sendDraft(UserPrompt(text: "继续验证高并发工具调用与异常配额耗尽的错误态展示。"))
        stubRuntime.emit(.runStarted)
        stubRuntime.emit(.plan([
            .init(id: "p1", content: "重构左侧项目导航器 S/F/G", status: .completed),
            .init(id: "p2", content: "实现双标签页组与安全编辑", status: .completed),
            .init(id: "p3", content: "完成原生界面视觉验收", status: .inProgress)
        ]))
        stubRuntime.emit(.failure(RuntimeFailure(
            .model, "Provider quota exhausted",
            rawDetail: "HTTP 429: Model quota exhausted for gemini-3.1-pro. Resets in 2h25m10s."
        )))
        stubRuntime.emit(.settled(aborted: false))
        try await Task.sleep(for: .milliseconds(100))

        // Pre-populate GitStore, NavigatorModel, and TabsModel
        let gitStore = GitStatusStore()
        gitStore.refresh(directory: repoA.path, force: true)
        gitStore.refresh(directory: repoB.path, force: true)
        gitStore.refreshCommits(directory: repoA.path)
        try await Task.sleep(for: .milliseconds(350))

        let navigatorModel = ProjectNavigatorModel()
        navigatorModel.setMode(.files, for: projectB, gitStore: gitStore)

        let tabsModel = WorkbenchTabsModel()
        tabsModel.syncActiveConversation(s1.id)
        tabsModel.syncActiveConversation(s2.id)
        tabsModel.syncActiveConversation(s3.id)
        tabsModel.syncActiveConversation(s1.id)

        let readmeRel = try XCTUnwrap(ProjectFilePath.relativePath(from: readmeURL, within: repoA.path))
        tabsModel.openFile(project: projectA, entry: ProjectFileEntry(path: readmeRel, kind: .file))
        let diffChange = GitFileChange(path: "Sources/Workbench/WorkbenchView.swift", previousPath: nil,
                                       status: .modified, scope: .unstagedVsIndex,
                                       stat: GitLineStat(added: 3, deleted: 1, isBinary: false))
        tabsModel.openGitDiff(project: projectA, change: diffChange, checkoutRoot: projectA.path)
        tabsModel.activateEditorTab(tabsModel.editorTabs[0].id)
        try await Task.sleep(for: .milliseconds(350))

        let projectFiles = ProjectFilesControls()
        projectFiles.open()
        let settings = AppSettings()

        func capture(
            name: String,
            size: NSSize,
            appearance: NSAppearance.Name,
            sidebarVisibility: NavigationSplitViewVisibility
        ) async throws {
            var vis = sidebarVisibility
            let root = WorkbenchView(
                workspace: workspace,
                settings: settings,
                quitRequest: 0,
                openSettingsRequest: 0,
                terminate: { _, cancel in cancel() },
                sidebarVisibility: Binding(get: { vis }, set: { vis = $0 }),
                projectFiles: projectFiles,
                gitStore: gitStore,
                navigatorModel: navigatorModel,
                tabsModel: tabsModel
            )
            .preferredColorScheme(appearance == .darkAqua ? .dark : .light)
            .zivviTypography(.standard)

            let host = NSHostingView(rootView: root)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.appearance = NSAppearance(named: appearance)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil }

            for _ in 0..<8 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(75))
            }

            let targetView = window.contentView?.superview ?? host
            let bounds = targetView.bounds
            guard let rep = targetView.bitmapImageRepForCachingDisplay(in: bounds) else {
                XCTFail("Failed to allocate bitmap for \(name)")
                return
            }
            targetView.cacheDisplay(in: bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                XCTFail("Failed to encode PNG for \(name)")
                return
            }
            try png.write(to: outputDir.appendingPathComponent(name))
        }

        // 1. Wide 3-column Light Mode
        try await capture(name: "01-wide-3col-light.png", size: NSSize(width: 1440, height: 860),
                          appearance: .aqua, sidebarVisibility: .all)

        // 2. Wide 3-column Dark Mode
        try await capture(name: "02-wide-3col-dark.png", size: NSSize(width: 1440, height: 860),
                          appearance: .darkAqua, sidebarVisibility: .all)

        // 3. Project Navigator Git Mode + Editor Unified Diff View
        navigatorModel.setMode(.git, for: projectA, gitStore: gitStore)
        tabsModel.activateEditorTab(tabsModel.editorTabs[1].id)
        try await Task.sleep(for: .milliseconds(250))
        try await capture(name: "03-navigator-git-diff-light.png", size: NSSize(width: 1440, height: 860),
                          appearance: .aqua, sidebarVisibility: .all)

        // 4. Editor Markdown Edit Mode + Dirty Dot + External Conflict Banner
        navigatorModel.setMode(.files, for: projectA, gitStore: gitStore)
        let mdTab = tabsModel.editorTabs[0]
        tabsModel.activateEditorTab(mdTab.id)
        mdTab.isMarkdownPreview = false
        tabsModel.updateDraft("# Zivvi Workbench 2.0\n\n本地未保存的编辑草稿…\n", for: mdTab)
        mdTab.externalConflict = WorkbenchTabsModel.ExternalConflict(
            message: "文件已被外部或 Agent 修改。请先确认处理方式，不会静默覆盖磁盘内容。",
            diskDocument: nil,
            diskRevision: nil
        )
        try await Task.sleep(for: .milliseconds(200))
        try await capture(name: "04-editor-md-edit-conflict-light.png", size: NSSize(width: 1380, height: 820),
                          appearance: .aqua, sidebarVisibility: .all)

        // 5. Focus Mode with Live Progressive Markdown + Semantic Code Skeleton
        mdTab.externalConflict = nil
        tabsModel.isEditorVisible = false
        projectFiles.close()
        let streamReplyID = UUID()
        await controller.sendDraft(UserPrompt(text: "帮我实现渐进式 Markdown 渲染器，稳定块即时呈现，未闭合代码块用静态骨架占位。"))
        stubRuntime.emit(.runStarted)
        stubRuntime.emit(.assistantStarted(streamReplyID))
        stubRuntime.emit(.textDelta(streamReplyID, 0, """
        ### 渐进式流式解析方案

        已提交的段落和标题在流式到达换行或块边界时立即渲染，不会等待整条回复结束：

        - 稳定块解析采用 **140 ms** 合并窗口
        - 尾部未闭合代码块延后 **300 ms** 呈现低对比静态语义骨架

        ```swift
        struct ProgressiveMarkdownSplitter {
            static func split(_ text: String, isStreaming: Bool) -> ProgressiveMarkdownSplit {
                // streaming in progress...
        """))
        try await Task.sleep(for: .milliseconds(550))
        try await capture(name: "05-focus-streaming-skeleton-light.png", size: NSSize(width: 1120, height: 780),
                          appearance: .aqua, sidebarVisibility: .detailOnly)

        // 6. Narrow Window 860 pt
        try await capture(name: "06-narrow-860-light.png", size: NSSize(width: 860, height: 680),
                          appearance: .aqua, sidebarVisibility: .all)

        _ = await workspace.disconnectAll()
    }
}
