import Foundation
import UserNotifications
import XCTest
import OrchestrationCore
@testable import Pikachu

final class TaskNotificationTests: XCTestCase {
    func testDefaultClickUsesSessionFromPayload() throws {
        let project = UUID()
        let selected = SessionReference(projectID: project)
        let target = SessionReference(projectID: project)
        let destination = try XCTUnwrap(TaskNotificationDestination(
            actionIdentifier: UNNotificationDefaultActionIdentifier, requestIdentifier: "approval:request",
            userInfo: TaskNotificationDestination.payload(sessionID: target.id)))
        XCTAssertEqual(destination.sessionID(in: [selected, target]), target.id)
        XCTAssertNil(destination.sessionID(in: [selected]))
        XCTAssertNil(destination.turnID, "An approval must not acknowledge a completion")

        let turnID = UUID()
        let completion = TaskNotificationDestination(actionIdentifier: UNNotificationDefaultActionIdentifier,
                                                     requestIdentifier: turnID.uuidString,
                                                     userInfo: TaskNotificationDestination.payload(sessionID: target.id))
        XCTAssertEqual(completion?.turnID, turnID)
    }

    func testLegacyCompletionClickFindsTheRecordedTurn() throws {
        let turn = RecordedTurnRecord(status: .completed)
        var target = SessionReference(projectID: UUID())
        target.recordedTurns = [turn]
        let destination = try XCTUnwrap(TaskNotificationDestination(
            actionIdentifier: UNNotificationDefaultActionIdentifier, requestIdentifier: turn.id.uuidString, userInfo: [:]))
        XCTAssertEqual(destination.sessionID(in: [target]), target.id)
        XCTAssertEqual(destination.turnID, turn.id)
    }

    func testDismissalAndInvalidPayloadDoNotNavigate() {
        XCTAssertNil(TaskNotificationDestination(actionIdentifier: UNNotificationDismissActionIdentifier,
                                                requestIdentifier: UUID().uuidString,
                                                userInfo: TaskNotificationDestination.payload(sessionID: UUID())))
        XCTAssertNil(TaskNotificationDestination(actionIdentifier: UNNotificationDefaultActionIdentifier,
                                                requestIdentifier: UUID().uuidString, userInfo: ["sessionID": "invalid"]))
    }
}
