import Foundation
import XCTest
import AgentRuntimeCore
@testable import OrchestrationCore
@testable import Pikachu

private struct SidebarConnectionProbe: AgentRuntime {
    let runtime = FakeRuntime()
    let onConnect: @MainActor @Sendable () -> Void
    var instanceID: UUID { runtime.instanceID }
    var events: AsyncStream<RuntimeEnvelope> { runtime.events }

    func connect() async throws -> RuntimeSession {
        await onConnect()
        return try await runtime.connect()
    }

    func send(_ prompt: UserPrompt) async throws -> PromptDisposition { try await runtime.send(prompt) }
    func stop() async throws { try await runtime.stop() }
    func close(force: Bool) async throws { try await runtime.close(force: force) }
}

final class SidebarTests: XCTestCase {
    func testHoverPanelStaysBesideRowAndInsideScreen() {
        let screen = CGRect(x: 100, y: 50, width: 800, height: 500)
        let size = CGSize(width: 244, height: 120)
        let middleRow = CGRect(x: 110, y: 360, width: 220, height: 50)
        XCTAssertEqual(SidebarHoverPanelPlacement.frame(for: size, beside: middleRow, within: screen),
                       CGRect(x: 338, y: 290, width: 244, height: 120))
        let lowerRightRow = CGRect(x: 650, y: 56, width: 220, height: 50)
        XCTAssertEqual(SidebarHoverPanelPlacement.frame(for: size, beside: lowerRightRow, within: screen),
                       CGRect(x: 398, y: 58, width: 244, height: 120))
    }

    @MainActor func testSidebarStatusPrefersPendingApprovalThenRunningThenDraft() async {
        let runtime = FakeRuntime()
        let controller = SessionController()
        await controller.connect(runtime)
        func receive(_ event: AgentEvent) { controller.receive(.init(instanceID: runtime.instanceID, event: event)) }
        func status(hasDraft: Bool = true) -> SidebarSessionStatus? {
            SidebarSessionStatus.resolve(execution: controller, needsReview: false, hasDraft: hasDraft)
        }
        XCTAssertNil(status(hasDraft: false))
        XCTAssertEqual(status(), .draft)
        receive(.phase(.running))
        XCTAssertEqual(status(), .running)

        let input = RuntimeInteraction(instanceID: runtime.instanceID, requestID: "input", kind: .input, title: "Input")
        receive(.interaction(input))
        XCTAssertEqual(status(), .awaitingInput)
        let approval = RuntimeInteraction(instanceID: runtime.instanceID, requestID: "approval", kind: .confirm, title: "Approve",
                                          toolApproval: .init(workingDirectory: "/fixture", operation: .inspect(.read, arguments: [])))
        receive(.interaction(approval))
        XCTAssertEqual(status(), .awaitingApproval)
        receive(.interactionEnded(approval.id, .expired))
        XCTAssertEqual(status(), .awaitingInput)
        receive(.interactionEnded(input.id, .answered))
        XCTAssertEqual(status(), .running)
        receive(.phase(.idle))
        XCTAssertEqual(status(), .draft)
        XCTAssertEqual(SidebarSessionStatus.resolve(execution: nil, needsReview: true, hasDraft: true), .review)
        _ = await controller.disconnect(force: true)
    }

    func testCardIndicatorPrioritizesActionThenRunningThenUnread() {
        func indicators(_ status: SidebarSessionStatus? = nil, review: Bool = false,
                        draft: Bool = false, unread: Bool = false, reminder: SessionReminderState = .none) -> [SidebarCardIndicator] {
            SidebarCardIndicator.ordered(execution: status, needsReview: review, hasDraft: draft,
                                         unread: unread, reminder: reminder)
        }

        XCTAssertEqual(indicators(.awaitingApproval, review: true, draft: true, unread: true, reminder: .due),
                       [.status(.awaitingApproval), .status(.review), .reminderDue, .unreadCompletion, .status(.draft)])
        XCTAssertEqual(indicators(.running, review: true, unread: true), [.status(.review), .status(.running), .unreadCompletion])
        XCTAssertEqual(indicators(.running, unread: true, reminder: .due), [.reminderDue, .status(.running), .unreadCompletion])
        XCTAssertEqual(indicators(.running, draft: true, unread: true), [.status(.running), .unreadCompletion, .status(.draft)])
        let deadline = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(indicators(.compacting, draft: true, unread: true, reminder: .snoozed(until: deadline)),
                       [.unreadCompletion, .status(.compacting), .status(.draft), .reminderSnoozed(deadline)])
        XCTAssertEqual(indicators(.review, review: true), [.status(.review)])
        XCTAssertTrue(indicators().isEmpty)
    }

    @MainActor func testSidebarStatusShowsConnectionAndFailuresButOmitsReady() async {
        let controller = SessionController()
        let runtime = SidebarConnectionProbe {
            XCTAssertEqual(SidebarSessionStatus.resolve(execution: controller, needsReview: false, hasDraft: false), .connecting)
        }
        await controller.connect(runtime)
        XCTAssertNil(SidebarSessionStatus.resolve(execution: controller, needsReview: false, hasDraft: false))

        controller.receive(.init(instanceID: runtime.instanceID, event: .failure(.init(.model, "Test error"))))
        XCTAssertEqual(SidebarSessionStatus.resolve(execution: controller, needsReview: false, hasDraft: true), .failed)
        controller.receive(.init(instanceID: runtime.instanceID, event: .disconnected(cleanupConfirmed: false)))
        XCTAssertEqual(SidebarSessionStatus.resolve(execution: controller, needsReview: false, hasDraft: true), .blocked)
        XCTAssertEqual(SidebarSessionStatus.resolve(execution: nil, needsReview: false, hasDraft: true,
                                                   hasExecutionError: true), .failed)
        _ = await controller.disconnect(force: true)
    }

    func testNewCardStatusesPreservePriorityAndSecondaryIndicators() {
        let deadline = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(SidebarCardIndicator.ordered(execution: .blocked, needsReview: true, hasDraft: true,
                                                    unread: true, reminder: .due, hasHistoryIssue: true),
                       [.status(.blocked), .status(.review), .status(.historyIssue), .reminderDue,
                        .unreadCompletion, .status(.draft)])
        XCTAssertEqual(SidebarCardIndicator.ordered(execution: .connecting, needsReview: false, hasDraft: false,
                                                    unread: true, reminder: .snoozed(until: deadline)),
                       [.unreadCompletion, .status(.connecting), .reminderSnoozed(deadline)])
    }

    func testFilterAndCollapsedGroupsOnlyExposeTheEligibleSelection() {
        let first = ProjectRecord(path: "/tmp/导航")
        let second = ProjectRecord(path: "/tmp/测试")
        let timestamp = Date(timeIntervalSince1970: 100)
        let lowID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let highID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        var open = SessionReference(id: lowID, projectID: first.id, runtimeID: RuntimeAgentProfile.antigravityRuntimeID, title: "后台工作")
        open.sidebarActivity = SessionActivity(date: timestamp)
        var later = SessionReference(id: highID, projectID: first.id, runtimeID: RuntimeAgentProfile.antigravityRuntimeID, title: "前台浏览")
        later.sidebarActivity = SessionActivity(date: timestamp)
        var settled = SessionReference(projectID: first.id, runtimeID: RuntimeAgentProfile.antigravityRuntimeID, title: "完成列表")
        settled.processingStatus = .settled
        let other = SessionReference(projectID: second.id, runtimeID: RuntimeAgentProfile.antigravityRuntimeID, title: "完成查询")
        let sessions = [other, later, settled, open]

        let library = SidebarSessionGroups(sessions: sessions, projects: [first, second], filter: .init(query: " 导航 "))
        XCTAssertEqual(library.visibleRows(in: .open, expanded: true, selected: open.id).map(\.id), [open.id, later.id])
        XCTAssertEqual(library.visibleRows(in: .open, expanded: false, selected: later.id).map(\.id), [later.id])
        XCTAssertTrue(library.visibleRows(in: .open, expanded: false, selected: nil).isEmpty)
        XCTAssertEqual(library.visibleRows(in: .settled, expanded: false, selected: settled.id).map(\.id), [settled.id])
        XCTAssertTrue(library.visibleRows(in: .settled, expanded: false, selected: later.id).isEmpty)

        let filtered = SidebarSessionGroups(sessions: sessions, projects: [first, second], filter: .init(query: "完成", projectID: first.id))
        XCTAssertEqual(filtered.count(in: .open), 0)
        XCTAssertEqual(filtered.visibleRows(in: .settled, expanded: true, selected: other.id).map(\.id), [settled.id])
        XCTAssertTrue(filtered.visibleRows(in: .open, expanded: false, selected: other.id).isEmpty)
    }

    func testBothGroupsSortByRecentActivityWithStableSessionIDs() throws {
        let project = ProjectRecord(path: "/tmp/Sidebar")
        func row(_ suffix: String, _ seconds: TimeInterval, _ status: SessionProcessingStatus) throws -> SessionReference {
            let id = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-0000000000\(suffix)"))
            var session = SessionReference(id: id, projectID: project.id, runtimeID: RuntimeAgentProfile.antigravityRuntimeID)
            session.sidebarActivity = SessionActivity(date: Date(timeIntervalSince1970: seconds))
            session.processingStatus = status
            return session
        }
        let openOld = try row("01", 80, .open)
        let openNew = try row("02", 100, .open)
        let settledOld = try row("03", 80, .settled)
        let settledNew = try row("04", 100, .settled)
        let settledTie = try row("05", 100, .settled)
        let groups = SidebarSessionGroups(sessions: [settledTie, settledOld, openOld, settledNew, openNew],
                                          projects: [project], filter: .init())

        XCTAssertEqual(groups.visibleRows(in: .open, expanded: true, selected: nil).map(\.id), [openNew.id, openOld.id])
        for selected in [openNew.id, settledNew.id] {
            XCTAssertEqual(groups.visibleRows(in: .settled, expanded: true, selected: selected).map(\.id),
                           [settledNew.id, settledTie.id, settledOld.id])
        }
        XCTAssertEqual(groups.visibleRows(in: .settled, expanded: false, selected: settledNew.id).map(\.id), [settledNew.id])
        XCTAssertTrue(groups.visibleRows(in: .settled, expanded: false, selected: openNew.id).isEmpty)
    }

    func testSettledBatchesUseCompleteCountAndAppendContiguousHistory() {
        let (project, sessions) = settledHistory(count: 159)
        let filter = SessionSidebarFilter()
        for count in [0, 10, 11, 35, 36, 159] {
            let input = Array(sessions.prefix(count))
            let groups = SidebarSessionGroups(sessions: input, projects: [project], filter: filter)
            var batches = SidebarSettledBatches()
            var limit = batches.limit(for: filter)
            var rows = groups.visibleRows(in: .settled, expanded: true, selected: nil, settledLimit: limit)
            XCTAssertEqual(groups.count(in: .settled), count)
            XCTAssertEqual(rows.map(\.id), input.prefix(10).map(\.id))

            while rows.count < count {
                let shown = rows.count
                let next = SidebarSettledBatches.remainingInNextBatch(total: count, limit: limit)
                XCTAssertEqual(next, min(25, count - shown))
                XCTAssertEqual(groups.settledID(at: limit), input[shown].id)
                batches.remember(limit + SidebarSettledBatches.batchSize, for: filter)
                limit = batches.limit(for: filter)
                let appended = groups.visibleRows(in: .settled, expanded: true, selected: nil, settledLimit: limit)
                guard appended.count == shown + next else {
                    XCTFail("Batch did not append the expected number of sessions")
                    break
                }
                XCTAssertEqual(appended.prefix(shown).map(\.id), rows.map(\.id))
                rows = appended
            }
            XCTAssertEqual(rows.map(\.id), input.map(\.id))
            XCTAssertEqual(SidebarSettledBatches.remainingInNextBatch(total: count, limit: limit), 0)
        }
    }

    func testSelectionBeyondFirstBatchAndSearchKeepIndependentLimits() {
        let (project, sessions) = settledHistory(count: 70)
        let oldest = sessions[69].id
        let all = SessionSidebarFilter()
        let keyword = SessionSidebarFilter(query: "  archive 69 ")
        let projectFilter = SessionSidebarFilter(projectID: project.id)
        let groups = SidebarSessionGroups(sessions: sessions, projects: [project], filter: all)
        var batches = SidebarSettledBatches()

        let containingSelection = batches.limit(for: all, including: groups.settledIndex(of: oldest))
        XCTAssertEqual(containingSelection, 85)
        XCTAssertEqual(batches.limit(for: all, including: 9), 10)
        XCTAssertEqual(batches.limit(for: all, including: 10), 35)
        XCTAssertEqual(batches.limit(for: all, including: 34), 35)
        XCTAssertEqual(batches.limit(for: all, including: 35), 60)
        batches.remember(containingSelection, for: all)
        XCTAssertEqual(groups.visibleRows(in: .settled, expanded: false, selected: oldest).map(\.id), [oldest])
        XCTAssertEqual(groups.visibleRows(in: .settled, expanded: true, selected: oldest,
                                          settledLimit: batches.limit(for: all)).last?.id, oldest)

        let matches = SidebarSessionGroups(sessions: sessions, projects: [project], filter: keyword)
        XCTAssertEqual(matches.count(in: .settled), 1)
        XCTAssertEqual(matches.visibleRows(in: .settled, expanded: true, selected: oldest).map(\.id), [oldest])
        XCTAssertEqual(batches.limit(for: keyword), 10)

        batches.remember(35, for: projectFilter)
        XCTAssertEqual(batches.limit(for: projectFilter), 35)
        batches.updateFilter(keyword)
        XCTAssertEqual(batches.limit(for: projectFilter), 10)
        XCTAssertEqual(batches.limit(for: all), 85)
    }

    func testCollapsedSelectionFollowsSessionAcrossGroups() {
        let (project, history) = settledHistory(count: 1)
        var session = history[0]
        let id = session.id
        let historyGroups = SidebarSessionGroups(sessions: [session], projects: [project], filter: .init())
        XCTAssertEqual(historyGroups.visibleRows(in: .settled, expanded: false, selected: id).map(\.id), [id])

        session.processingStatus = .open
        let openGroups = SidebarSessionGroups(sessions: [session], projects: [project], filter: .init())
        XCTAssertEqual(openGroups.visibleRows(in: .open, expanded: false, selected: id).map(\.id), [id])
        XCTAssertTrue(openGroups.visibleRows(in: .settled, expanded: false, selected: id).isEmpty)
    }

    func testBroadenedFilterRevealsOnlyNewlyMatchingSettledSelection() {
        let (project, history) = settledHistory(count: 159)
        let selected = history[120].id
        let open = SessionReference(projectID: project.id, runtimeID: RuntimeAgentProfile.antigravityRuntimeID, title: "Archive open")
        let sessions = history + [open]
        let projectOnly = SessionSidebarFilter(projectID: project.id)
        let broad = SessionSidebarFilter(query: " Archive ", projectID: project.id)
        let groups = SidebarSessionGroups(sessions: sessions, projects: [project], filter: broad)
        for previous in [SessionSidebarFilter(query: "no matches"), .init(query: "Archive 119"),
                         .init(projectID: UUID())] {
            XCTAssertEqual(groups.newlyMatchingSettledID(selected, previousFilter: previous), selected)
        }
        XCTAssertNil(groups.newlyMatchingSettledID(selected, previousFilter: .init(query: "  archive 120  ")))
        XCTAssertNil(groups.newlyMatchingSettledID(selected, previousFilter: projectOnly))
        XCTAssertNil(groups.newlyMatchingSettledID(open.id, previousFilter: .init(query: "no matches")))

        let excludesSelection = SidebarSessionGroups(sessions: sessions, projects: [project], filter: .init(query: "Archive 119"))
        XCTAssertNil(excludesSelection.newlyMatchingSettledID(selected, previousFilter: .init(query: "no matches")))
        let limit = SidebarSettledBatches().limit(for: broad, including: groups.settledIndex(of: selected))
        XCTAssertEqual(limit, 135)
        let visible = groups.visibleRows(in: .settled, expanded: true, selected: selected, settledLimit: limit)
        XCTAssertEqual(visible.firstIndex(where: { $0.id == selected }), 120)
        XCTAssertEqual(groups.visibleRows(in: .settled, expanded: false, selected: selected).map(\.id), [selected])
    }

    private func settledHistory(count: Int) -> (ProjectRecord, [SessionReference]) {
        let project = ProjectRecord(path: "/tmp/Sidebar")
        let sessions = (0..<count).map { index in
            var session = SessionReference(projectID: project.id, runtimeID: RuntimeAgentProfile.antigravityRuntimeID, title: "Archive \(index)")
            session.sidebarActivity = SessionActivity(date: Date(timeIntervalSince1970: Double(1_000 - index)))
            session.processingStatus = .settled
            return session
        }
        return (project, sessions)
    }

    func testQuotaDoesNotUseZeroForMissingSmallOrStaleValues() {
        let now = Date(timeIntervalSince1970: 100)
        func window(_ balance: Int?, _ limit: Int?, reset: Date? = nil, id: String = "daily") -> AccountQuotaWindow {
            .init(id: id, provider: "Test", account: "Example", period: "Daily",
                  remaining: balance, limit: limit, resetAt: reset, observedAt: now)
        }
        XCTAssertNil(SidebarQuotaSummary(windows: []).value(at: now))
        XCTAssertNil(SidebarQuotaSummary(windows: [window(nil, 100)]).value(at: now))
        XCTAssertEqual(SidebarQuotaSummary(windows: [window(62, 100)]).value(at: now), "62%")
        XCTAssertEqual(SidebarQuotaSummary(windows: [window(0, 100)]).value(at: now), "0%")
        XCTAssertEqual(SidebarQuotaSummary(windows: [window(1, 1_000)]).value(at: now), "<1%")
        XCTAssertEqual(SidebarQuotaSummary(windows: [window(2, nil)]).value(at: now), "2")
        XCTAssertNil(SidebarQuotaSummary(windows: [window(62, 100, reset: now)]).value(at: now))
        XCTAssertNil(SidebarQuotaSummary(windows: [window(62, 100), window(18, 100, id: "weekly")]).value(at: now))

        let future = now.addingTimeInterval(60)
        func warns(_ windows: [AccountQuotaWindow]) -> Bool {
            SidebarQuotaSummary(windows: windows).showsLowQuotaWarning(at: now)
        }
        XCTAssertTrue(warns([window(10, 100, reset: future)]))
        XCTAssertTrue(warns([window(0, 100, reset: future)]))
        XCTAssertFalse(warns([window(11, 100, reset: future)]))
        XCTAssertFalse(warns([window(0, 100, reset: now)]))
        XCTAssertFalse(warns([window(0, 100)]))
        XCTAssertFalse(warns([window(nil, 100, reset: future)]))
        XCTAssertFalse(warns([window(0, nil, reset: future)]))
        XCTAssertFalse(warns([window(0, 100, reset: future), window(0, 100, reset: future, id: "weekly")]))
        XCTAssertFalse(warns([]))
    }
}
