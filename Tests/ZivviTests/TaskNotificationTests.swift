import Foundation
import UserNotifications
import XCTest
import AgentRuntimeCore
import OrchestrationCore
@testable import Zivvi

final class TaskNotificationTests: XCTestCase {
    @MainActor func testEnabledNotificationsPlayForegroundCueByOutcome() async throws {
        let suiteName = "TaskNotificationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var played: [TaskNotificationSound] = []
        let notifications = TaskNotifications(
            defaults: defaults,
            isAppActive: { true },
            playCue: { played.append($0) }
        )
        let sessionID = UUID()

        // Disabled by default: nothing plays.
        notifications.post(TurnRecord(status: .completed, endedAt: .now), sessionID: sessionID)
        XCTAssertTrue(played.isEmpty)

        // Turn on without triggering UNUserNotificationCenter prompt in unit test:
        defaults.set(true, forKey: "task-end-notifications-enabled")
        let enabledNotifications = TaskNotifications(
            defaults: defaults,
            isAppActive: { true },
            playCue: { played.append($0) }
        )

        enabledNotifications.post(TurnRecord(status: .completed, endedAt: .now), sessionID: sessionID)
        enabledNotifications.post(TurnRecord(status: .failed, endedAt: .now), sessionID: sessionID)
        enabledNotifications.post(TurnRecord(status: .stopped, endedAt: .now), sessionID: sessionID)
        enabledNotifications.post(TurnRecord(status: .completed, endedAt: nil), sessionID: sessionID)
        XCTAssertEqual(played, [.completed, .failed])

        let runtime = FakeRuntime()
        let controller = SessionController()
        await controller.connect(runtime)
        let approval = RuntimeInteraction(
            instanceID: runtime.instanceID,
            requestID: "req-1",
            kind: .confirm,
            title: "Run bash",
            message: "",
            expiresAt: .now.addingTimeInterval(60)
        )
        let expired = RuntimeInteraction(
            instanceID: runtime.instanceID,
            requestID: "req-2",
            kind: .confirm,
            title: "Expired",
            message: "",
            expiresAt: .now.addingTimeInterval(-10)
        )
        controller.receive(.init(instanceID: runtime.instanceID, event: .interaction(approval)))
        enabledNotifications.postApproval(approval, sessionID: sessionID, from: controller)
        enabledNotifications.postApproval(expired, sessionID: sessionID, from: controller)
        XCTAssertEqual(played, [.completed, .failed, .approval])
        _ = await controller.disconnect(force: true)
    }
    func testDefaultClickUsesSessionFromPayload() throws {
        let project = UUID()
        let selected = SessionReference(projectID: project, runtimeID: RuntimeAgentProfile.antigravityRuntimeID)
        let target = SessionReference(projectID: project, runtimeID: RuntimeAgentProfile.antigravityRuntimeID)
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
        var target = SessionReference(projectID: UUID(), runtimeID: RuntimeAgentProfile.antigravityRuntimeID)
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
