import AppKit
import SwiftUI
import XCTest
import AgentRuntimeCore
@testable import OrchestrationCore
@testable import Zivvi

final class BrandSystemTests: XCTestCase {

    func testAll83FunctionalAnd21BrandIconsLoadAsTemplateAssets() {
        XCTAssertEqual(LightningIcon.allCases.count, 83)
        XCTAssertEqual(LightningBrandIcon.allCases.count, 21)

        var allNames = Set<String>()
        for icon in LightningIcon.allCases {
            XCTAssertTrue(icon.assetName.hasPrefix("lightning_"))
            XCTAssertTrue(allNames.insert(icon.assetName).inserted, "Duplicate asset name \(icon.assetName)")
            let image = NSImage.lightningTemplateImage(icon, bundle: .main)
            XCTAssertNotNil(image, "Failed to load functional icon \(icon.assetName) for \(icon.rawValue)")
            XCTAssertEqual(image?.isTemplate, true)
        }

        for brandIcon in LightningBrandIcon.allCases {
            XCTAssertTrue(brandIcon.assetName.hasPrefix("lightning_brand_"))
            XCTAssertTrue(allNames.insert(brandIcon.assetName).inserted, "Duplicate asset name \(brandIcon.assetName)")
            let image = NSImage.lightningBrandTemplateImage(brandIcon, bundle: .main)
            XCTAssertNotNil(image, "Failed to load brand icon \(brandIcon.assetName)")
            XCTAssertEqual(image?.isTemplate, true)
        }
    }

    func testDirectionalIconRTLMirroringRules() {
        let mirrored = LightningIcon.allCases.filter(\.mirrorsInRTL)
        XCTAssertEqual(Set(mirrored), [.chevronForward, .arrowUpForwardSquare])
        XCTAssertFalse(LightningIcon.chevronLeft.mirrorsInRTL)
        XCTAssertFalse(LightningIcon.chevronRight.mirrorsInRTL)
        XCTAssertFalse(LightningIcon.arrowUpRightSquare.mirrorsInRTL)
    }

    func testMasterLogoAndSixLayersShareIdenticalCanvasDimensions() throws {
        let names = [
            "BrandMasterLogo",
            "BrandLayerAgentTop",
            "BrandLayerAgentMain",
            "BrandLayerAgentLeft",
            "BrandLayerAgentBottom",
            "BrandLayerEnergyRays",
            "BrandLayerEnergyTrail",
        ]
        for name in names {
            let image = try XCTUnwrap(Bundle.main.image(forResource: name), "Missing brand asset \(name)")
            let rep = try XCTUnwrap(image.representations.first)
            XCTAssertEqual(rep.pixelsWide, 759, "Unexpected width for \(name)")
            XCTAssertEqual(rep.pixelsHigh, 830, "Unexpected height for \(name)")
        }
    }

    func testBrandCopyRemovesLegacyCharacterStrings() {
        XCTAssertEqual(BrandCopy.welcome, "Ready to Zip?")
        XCTAssertEqual(BrandCopy.userMessage, "Zip!")
        XCTAssertEqual(BrandCopy.agentStarted, "Zap!")
        XCTAssertEqual(BrandCopy.agentRunning, "Zap…")
        XCTAssertEqual(BrandCopy.subagentCompleted, "Zing!")
        XCTAssertEqual(BrandCopy.completed, "Zzzap!")
        XCTAssertEqual(BrandCopy.failed, "Zzzzt…")
        XCTAssertFalse(BrandCopy.agentRunning.contains("..."), "Must use ellipsis character … instead of three periods")
        XCTAssertFalse(BrandCopy.failed.contains("..."), "Must use ellipsis character … instead of three periods")
    }

    @MainActor
    func testTurnHeaderBrandPresentationStatesFollowRealRuntimeEvents() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        // Fresh live start -> Zap!
        let starting = TurnRecord(status: .running, startedAt: now)
        let startSummary = TurnHeaderSummary(turn: starting, relativeTo: now.addingTimeInterval(0.2))
        XCTAssertEqual(startSummary.brandState, .starting)
        XCTAssertEqual(startSummary.title, "Zap!")

        // Ongoing running -> Zap…
        let runningSummary = TurnHeaderSummary(turn: starting, relativeTo: now.addingTimeInterval(2.5))
        XCTAssertEqual(runningSummary.brandState, .running)
        XCTAssertEqual(runningSummary.title, "Zap…")

        // Awaiting approval -> real semantic status, NOT flowing Zap…
        starting.liveStage = .waitingApproval
        let approvalSummary = TurnHeaderSummary(turn: starting, relativeTo: now.addingTimeInterval(3.0))
        XCTAssertEqual(approvalSummary.brandState, .awaitingApproval)
        XCTAssertFalse(approvalSummary.brandState.isActivelyFlowing)
        XCTAssertEqual(approvalSummary.title, "")

        // Stopped -> NOT completed, NOT failed
        let stopped = TurnRecord(status: .stopped, durationSeconds: 4)
        let stoppedSummary = TurnHeaderSummary(turn: stopped)
        XCTAssertEqual(stoppedSummary.brandState, .stopped)
        XCTAssertEqual(stoppedSummary.title, "")

        // Failed -> Zzzzt…
        let failed = TurnRecord(status: .failed, durationSeconds: 5)
        let failedSummary = TurnHeaderSummary(turn: failed)
        XCTAssertEqual(failedSummary.brandState, .failed)
        XCTAssertEqual(failedSummary.title, "Zzzzt…")

        // Completed -> Zzzap!
        let completed = TurnRecord(status: .completed, durationSeconds: 6)
        let completedSummary = TurnHeaderSummary(turn: completed)
        XCTAssertEqual(completedSummary.brandState, .completed)
        XCTAssertEqual(completedSummary.title, "Zzzap!")

        // Historical missing -> no false completion or running cue
        let historical = TurnRecord(status: .uncertain)
        historical.isHistoricalOutcomeMissing = true
        let historicalSummary = TurnHeaderSummary(turn: historical)
        XCTAssertEqual(historicalSummary.brandState, .historicalOutcomeMissing)
        XCTAssertEqual(historicalSummary.title, "")
    }

    @MainActor
    func testMotionTrackerDeduplicatesOneShotAnimationsAndBlocksHistoryReplay() {
        let tracker = BrandTurnMotionTracker.shared
        tracker.resetForTesting()
        defer { tracker.resetForTesting() }

        // Cold launch plays strictly once
        XCTAssertTrue(tracker.consumeColdLaunch())
        XCTAssertFalse(tracker.consumeColdLaunch())

        // Historical completed turn (never observed running) never replays Discharge
        let historicalID = UUID()
        XCTAssertFalse(tracker.consumeCompletionDischarge(for: historicalID))
        XCTAssertFalse(tracker.consumeFailureCutoff(for: historicalID))

        // Live running -> completed plays Discharge strictly once
        let liveSuccessID = UUID()
        tracker.markRunning(liveSuccessID)
        XCTAssertTrue(tracker.consumeCompletionDischarge(for: liveSuccessID))
        XCTAssertFalse(tracker.consumeCompletionDischarge(for: liveSuccessID))

        // Live running -> failed plays cutoff strictly once
        let liveFailID = UUID()
        tracker.markRunning(liveFailID)
        XCTAssertTrue(tracker.consumeFailureCutoff(for: liveFailID))
        XCTAssertFalse(tracker.consumeFailureCutoff(for: liveFailID))
    }

    @MainActor
    func testCaptureBrandVisualAcceptanceScreenshots() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment["ZIVVI_BRAND_CAPTURE_DIR"],
              !outputPath.isEmpty else {
            throw XCTSkip("Set ZIVVI_BRAND_CAPTURE_DIR to capture native Brand Visual Acceptance screenshots.")
        }
        let outputDir = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        func capture<V: View>(_ view: V, name: String, size: NSSize, appearance: NSAppearance.Name) async throws {
            let root = view
                .preferredColorScheme(appearance == .darkAqua ? .dark : .light)
                .zivviTypography(.standard)
                .background(ZivviTheme.pageBackground)
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

            for _ in 0..<6 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
            }
            let target = window.contentView?.superview ?? host
            let rep = try XCTUnwrap(target.bitmapImageRepForCachingDisplay(in: target.bounds))
            target.cacheDisplay(in: target.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: outputDir.appendingPathComponent(name))
        }

        // 1 & 2: New Session Welcome Screen (Light & Dark)
        let project = ProjectRecord(path: "/tmp/lightning-workspace")
        let session = SessionReference(projectID: project.id, runtimeID: RuntimeAgentProfile.antigravityRuntimeID)
        let workspace = WorkspaceController(store: BrandMemoryStore()) { _, _ in FakeRuntime() }
        let controller = SessionController()
        let welcomeView = VStack(spacing: 0) {
            Spacer()
            SessionStarterTitle(isIdlePaused: true)
            ComposerView(
                controller: controller,
                workspace: workspace,
                isViewedSessionActive: false,
                sessionConfigurationDisabled: false,
                model: ComposerModel(provider: "antigravity", name: "Gemini 3.1 Pro", thinking: "high", pending: false),
                reference: session,
                project: project,
                panelsBlocked: false,
                onPickFiles: {},
                onSend: {},
                onStop: {},
                sendEnabled: true,
                isStarter: true
            )
            .frame(maxWidth: 740)
            .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        try await capture(welcomeView, name: "01-brand-welcome-light.png",
                          size: NSSize(width: 980, height: 640), appearance: .aqua)
        try await capture(welcomeView, name: "02-brand-welcome-dark.png",
                          size: NSSize(width: 980, height: 640), appearance: .darkAqua)

        // 3 & 4: Conversation States Showcase (Zip!, Zap!, Zap…, Zzzap!, Zzzzt…, Approval, Stopped)
        let userMsg = TranscriptItem(id: "u1", kind: .user, text: "帮我检查全黄色图标、品牌状态语与动效系统的视觉一致性。")
        let startTurn = TurnRecord(status: .running, startedAt: Date.now)
        let runningTurn = TurnRecord(status: .running, startedAt: Date.now.addingTimeInterval(-14))
        let approvalTurn = TurnRecord(status: .running, startedAt: Date.now.addingTimeInterval(-20))
        approvalTurn.liveStage = .waitingApproval
        let completedTurn = TurnRecord(status: .completed, durationSeconds: 8.4)
        let stoppedTurn = TurnRecord(status: .stopped, durationSeconds: 3.1)
        let failedTurn = TurnRecord(status: .failed, durationSeconds: 2.2)

        let statesView = VStack(alignment: .leading, spacing: 14) {
            TranscriptRow(item: userMsg, width: 700, contentChanged: {})
            TurnHeaderView(turn: startTurn)
            TurnHeaderView(turn: runningTurn)
            TurnHeaderView(turn: approvalTurn)
            TurnHeaderView(turn: completedTurn)
            TurnHeaderView(turn: stoppedTurn)
            TurnHeaderView(turn: failedTurn)
            TurnExecutionErrorView(
                failure: RuntimeFailure(.model, "模型服务暂时限流，请稍后再试或切换其他模型。",
                                        rawDetail: "HTTP 429: Rate limit exceeded. Resets in 1m30s."),
                occurredAt: Date.now,
                onSwitchModel: {},
                onSafeRetry: {}
            )
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        try await capture(statesView, name: "03-brand-states-light.png",
                          size: NSSize(width: 780, height: 680), appearance: .aqua)
        try await capture(statesView, name: "04-brand-states-dark.png",
                          size: NSSize(width: 780, height: 680), appearance: .darkAqua)

        // 5 & 6: Brand Logo + 21 Brand Icons + Functional Icons Sheet (Light & Dark)
        let iconSheet = VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 24) {
                BrandMark(width: 96)
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: BrandCopy.slogan).zivviFont(.title2, weight: .semibold)
                    Text(verbatim: "\(BrandCopy.signature) · \(BrandCopy.welcome)")
                        .zivviFont(.callout).foregroundStyle(ZivviTheme.secondaryText)
                    HStack(spacing: 12) {
                        LightningIconView(.chevronForward, size: 16)
                        LightningIconView(.arrowUpForwardSquare, size: 16)
                        LightningIconView(.gearshape, size: 16).disabled(true)
                        Text("Disabled 45%").zivviFont(.caption).foregroundStyle(ZivviTheme.tertiaryText)
                    }
                }
            }
            Text("21 Brand Icons").zivviFont(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 7), spacing: 12) {
                ForEach(LightningBrandIcon.allCases, id: \.self) { icon in
                    VStack(spacing: 4) {
                        LightningBrandIconView(icon, size: 20)
                        Text(verbatim: icon.rawValue).zivviFont(.micro).foregroundStyle(ZivviTheme.secondaryText).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .flatSurface(ZivviTheme.surface, radius: 6)
                }
            }
            Text("Functional Icons Sample (83 Total)").zivviFont(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 12), spacing: 10) {
                ForEach(Array(LightningIcon.allCases.prefix(36)), id: \.self) { icon in
                    LightningIconView(icon, size: 16)
                        .frame(width: 28, height: 28)
                        .flatSurface(ZivviTheme.surface, radius: 6)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        try await capture(iconSheet, name: "05-brand-icons-light.png",
                          size: NSSize(width: 820, height: 640), appearance: .aqua)
        try await capture(iconSheet, name: "06-brand-icons-dark.png",
                          size: NSSize(width: 820, height: 640), appearance: .darkAqua)
    }
}

private actor BrandMemoryStore: WorkspaceStore {
    var snapshot = WorkspaceSnapshot()
    func load() -> WorkspaceSnapshot { snapshot }
    func save(_ value: WorkspaceSnapshot) { snapshot = value }
}
