import Foundation
import XCTest
@testable import OrchestrationCore
@testable import Pikachu

final class SidebarTests: XCTestCase {
    func testFilterAndCollapsedGroupsOnlyExposeTheEligibleSelection() {
        let first = ProjectRecord(path: "/tmp/导航")
        let second = ProjectRecord(path: "/tmp/测试")
        let timestamp = Date(timeIntervalSince1970: 100)
        let lowID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let highID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        var open = SessionReference(id: lowID, projectID: first.id, title: "后台工作")
        open.sidebarActivity = SessionActivity(date: timestamp)
        var later = SessionReference(id: highID, projectID: first.id, title: "前台浏览")
        later.sidebarActivity = SessionActivity(date: timestamp)
        var settled = SessionReference(projectID: first.id, title: "完成列表")
        settled.processingStatus = .settled
        let other = SessionReference(projectID: second.id, title: "完成查询")
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
    }
}
