import AppKit
import Observation
import UserNotifications
import AgentRuntimeCore
import OrchestrationCore

enum InterfaceLanguage: String, CaseIterable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    private static let preference = "interface-language"

    static var saved: Self {
        UserDefaults.standard.string(forKey: preference).flatMap(Self.init(rawValue:)) ?? .system
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(rawValue, forKey: Self.preference)
        if self == .system {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([rawValue], forKey: "AppleLanguages")
        }
    }
}

@MainActor @Observable final class TaskNotifications {
    private static let preference = "task-end-notifications-enabled"
    private let center = UNUserNotificationCenter.current()
    private var permissionRequest: Task<Void, Never>?
    private var refreshID = UUID()
    private(set) var enabled: Bool
    private(set) var authorization: UNAuthorizationStatus?
    private(set) var requestFailed = false

    init() {
        enabled = UserDefaults.standard.bool(forKey: Self.preference)
    }

    @discardableResult func refreshAuthorization() async -> UNAuthorizationStatus {
        let id = UUID()
        refreshID = id
        let current = await center.notificationSettings().authorizationStatus
        if refreshID == id { authorization = current }
        return current
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.preference)
        if enabled { requestAuthorization() }
    }

    func requestAuthorization() {
        guard enabled, permissionRequest == nil else { return }
        requestFailed = false
        permissionRequest = Task {
            defer { permissionRequest = nil }
            let current = await refreshAuthorization()
            guard enabled, current == .notDetermined else { return }
            do { _ = try await center.requestAuthorization(options: [.alert]) }
            catch { requestFailed = true }
            await refreshAuthorization()
        }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func post(_ turn: TurnRecord) {
        guard turn.endedAt != nil else { return }
        switch turn.status {
        case .completed:
            post(id: turn.id.uuidString, title: String(localized: "任务已完成"),
                 body: String(localized: "返回 Pikachu 查看任务结果。"))
        case .failed:
            post(id: turn.id.uuidString, title: String(localized: "任务执行失败"),
                 body: String(localized: "返回 Pikachu 查看失败详情。"))
        case .running, .stopped, .uncertain: break
        }
    }

    func postApproval(_ approval: RuntimeInteraction, from controller: SessionController) {
        post(id: "approval:\(approval.id)", title: String(localized: "等待工具审批"),
             body: String(localized: "工具调用已暂停，请返回 Pikachu 审批。")) { [weak controller] in
            guard let controller, !controller.isStopping, approval.expiresAt > .now else { return false }
            return controller.interactions.contains { $0.id == approval.id }
        }
    }

    private func post(id: String, title: String, body: String, isRelevant: @escaping @MainActor () -> Bool = { true }) {
        guard enabled, !NSApp.isActive, isRelevant() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        Task {
            let status = await center.notificationSettings().authorizationStatus
            guard enabled, !NSApp.isActive, status == .authorized || status == .provisional, isRelevant() else { return }
            try? await center.add(request)
        }
    }
}
