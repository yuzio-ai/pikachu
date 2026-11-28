import AppKit
import Observation
import UserNotifications
import AgentRuntimeCore
import OrchestrationCore

enum TaskNotificationDestination: Equatable, Sendable {
    case session(UUID, turnID: UUID?), legacyTurn(UUID)

    private static let sessionKey = "sessionID"

    static func payload(sessionID: UUID) -> [String: String] {
        [sessionKey: sessionID.uuidString]
    }

    init?(actionIdentifier: String, requestIdentifier: String, userInfo: [AnyHashable: Any]) {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier else { return nil }
        if let value = userInfo[Self.sessionKey] {
            guard let raw = value as? String, let id = UUID(uuidString: raw) else { return nil }
            self = .session(id, turnID: UUID(uuidString: requestIdentifier))
        } else if let id = UUID(uuidString: requestIdentifier) {
            // Previously delivered completion notifications used the turn ID as their only identifier.
            self = .legacyTurn(id)
        } else {
            return nil
        }
    }

    var turnID: UUID? {
        switch self {
        case .session(_, let turnID): turnID
        case .legacyTurn(let id): id
        }
    }

    func sessionID(in sessions: [SessionReference]) -> UUID? {
        switch self {
        case .session(let id, _): sessions.first(where: { $0.id == id })?.id
        case .legacyTurn(let id): sessions.first(where: { $0.recordedTurns?.contains(where: { $0.id == id }) == true })?.id
        }
    }
}

enum TaskNotificationSound: Equatable, Sendable {
    case completed, failed, approval

    var soundName: NSSound.Name {
        switch self {
        case .completed: NSSound.Name("Glass")
        case .failed: NSSound.Name("Basso")
        case .approval: NSSound.Name("Ping")
        }
    }
}

@MainActor @Observable final class TaskNotifications {
    static let preference = "task-end-notifications-enabled"
    private let defaults: UserDefaults
    private let center = UNUserNotificationCenter.current()
    private let isAppActive: @MainActor () -> Bool
    private let playCue: @MainActor (TaskNotificationSound) -> Void
    private var permissionRequest: Task<Void, Never>?
    private var refreshID = UUID()
    private(set) var enabled: Bool
    private(set) var authorization: UNAuthorizationStatus?
    private(set) var soundSetting: UNNotificationSetting?
    private(set) var requestFailed = false

    init(
        defaults: UserDefaults = .standard,
        isAppActive: @escaping @MainActor () -> Bool = { NSApp.isActive },
        playCue: (@MainActor (TaskNotificationSound) -> Void)? = nil
    ) {
        self.defaults = defaults
        self.isAppActive = isAppActive
        self.playCue = playCue ?? Self.defaultPlayCue
        enabled = defaults.bool(forKey: Self.preference)
    }

    private static func defaultPlayCue(_ kind: TaskNotificationSound) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              let sound = NSSound(named: kind.soundName) else { return }
        sound.stop()
        sound.volume = 0.7
        sound.play()
    }

    @discardableResult func refreshAuthorization() async -> UNAuthorizationStatus {
        let id = UUID()
        refreshID = id
        let settings = await center.notificationSettings()
        if refreshID == id {
            authorization = settings.authorizationStatus
            soundSetting = settings.soundSetting
        }
        return settings.authorizationStatus
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        defaults.set(enabled, forKey: Self.preference)
        if enabled { requestAuthorization() }
    }

    func requestAuthorization() {
        guard enabled, permissionRequest == nil else { return }
        requestFailed = false
        permissionRequest = Task {
            defer { permissionRequest = nil }
            let current = await refreshAuthorization()
            guard enabled, current == .notDetermined else { return }
            do { _ = try await center.requestAuthorization(options: [.alert, .sound]) }
            catch { requestFailed = true }
            await refreshAuthorization()
        }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func post(_ turn: TurnRecord, sessionID: UUID) {
        guard turn.endedAt != nil else { return }
        switch turn.status {
        case .completed:
            post(id: turn.id.uuidString, sessionID: sessionID, title: String(localized: "任务已完成"),
                 body: String(localized: "返回 Zivvi 查看任务结果。"), sound: .completed)
        case .failed:
            post(id: turn.id.uuidString, sessionID: sessionID, title: String(localized: "任务执行失败"),
                 body: String(localized: "返回 Zivvi 查看失败详情。"), sound: .failed)
        case .running, .stopped, .uncertain: break
        }
    }

    func postApproval(_ approval: RuntimeInteraction, sessionID: UUID, from controller: SessionController) {
        post(id: "approval:\(approval.id)", sessionID: sessionID, title: String(localized: "等待工具审批"),
             body: String(localized: "工具调用已暂停，请返回 Zivvi 审批。"), sound: .approval) { [weak controller] in
            guard let controller, !controller.isStopping, approval.expiresAt > .now else { return false }
            return controller.interactions.contains { $0.id == approval.id }
        }
    }

    private func post(id: String, sessionID: UUID, title: String, body: String,
                      sound: TaskNotificationSound,
                      isRelevant: @escaping @MainActor () -> Bool = { true }) {
        guard enabled, isRelevant() else { return }
        if isAppActive() {
            if soundSetting != .disabled {
                playCue(sound)
            }
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = TaskNotificationDestination.payload(sessionID: sessionID)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        Task {
            let settings = await center.notificationSettings()
            let status = settings.authorizationStatus
            guard enabled, !isAppActive(), isRelevant() else { return }
            if status == .authorized || status == .provisional {
                try? await center.add(request)
            } else if status == .notDetermined && settings.soundSetting != .disabled {
                playCue(sound)
            }
        }
    }
}
