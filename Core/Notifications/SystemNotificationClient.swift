import AppKit
import Foundation
import UserNotifications

@MainActor
protocol QuotaNotificationClient: AnyObject {
    func permission() async throws -> QuotaNotificationPermission
    func requestAuthorization(sound: Bool) async throws
    func submit(_ message: QuotaNotificationMessage) async throws
    func removeNotifications(accountKey: String?) async
}

@MainActor
final class SystemNotificationClient: QuotaNotificationClient {
    static let prefix = "ccbar.quota-alert."
    private let center = UNUserNotificationCenter.current()

    func permission() async -> QuotaNotificationPermission {
        let settings = await center.notificationSettings()
        let authorization: QuotaNotificationPermission.Authorization
        switch settings.authorizationStatus {
        case .notDetermined: authorization = .notDetermined
        case .authorized, .provisional: authorization = .allowed
        default: authorization = .denied
        }
        return QuotaNotificationPermission(
            authorization: authorization,
            alerts: settings.alertSetting == .enabled || settings.notificationCenterSetting == .enabled,
            sound: settings.soundSetting == .enabled
        )
    }

    func requestAuthorization(sound: Bool) async throws {
        let options: UNAuthorizationOptions = sound ? [.alert, .sound] : [.alert]
        _ = try await center.requestAuthorization(options: options)
    }

    func submit(_ message: QuotaNotificationMessage) async throws {
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        content.sound = message.sound ? .default : nil
        content.userInfo = ["type": "quota-alert"]
        if let accountKey = message.accountKey { content.userInfo["account"] = accountKey }
        if let entryKey = message.entryKey { content.userInfo["entry"] = entryKey }
        try await center.add(UNNotificationRequest(identifier: message.identifier, content: content, trigger: nil))
    }

    func removeNotifications(accountKey: String? = nil) async {
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        func matches(_ request: UNNotificationRequest) -> Bool {
            request.identifier.hasPrefix(Self.prefix)
                && (accountKey == nil || request.content.userInfo["account"] as? String == accountKey
                    || request.content.userInfo["entry"] as? String == accountKey)
        }
        center.removePendingNotificationRequests(withIdentifiers: pending.filter(matches).map(\.identifier))
        center.removeDeliveredNotifications(withIdentifiers: delivered.map(\.request).filter(matches).map(\.identifier))
    }
}

/// AppDelegate 在启动早期持有；SDK 回调不依赖设置 View 的生命周期。
final class QuotaNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let openStatistics: @MainActor () -> Void

    init(openStatistics: @escaping @MainActor () -> Void) {
        self.openStatistics = openStatistics
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let identifier = notification.request.identifier
        let hasSound = notification.request.content.sound != nil
        return await MainActor.run {
            guard identifier.hasPrefix(SystemNotificationClient.prefix),
                  SettingsStore.shared.quotaAlertsEnabled else { return [] }
            var options: UNNotificationPresentationOptions = [.banner, .list]
            if hasSound && SettingsStore.shared.quotaAlertSoundEnabled { options.insert(.sound) }
            return options
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let identifier = response.notification.request.identifier
        let isOpen = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        guard isOpen else { return }
        await MainActor.run {
            guard identifier.hasPrefix(SystemNotificationClient.prefix) else { return }
            openStatistics()
        }
    }
}
