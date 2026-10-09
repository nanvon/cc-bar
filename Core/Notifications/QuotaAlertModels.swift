import CryptoKit
import Foundation

nonisolated struct QuotaAlertIdentity: Codable, Equatable, Hashable, Sendable {
    let app: QuotaApp
    let accountDigest: String
    let userDigest: String?
    let key: String

    init?(app: QuotaApp = .codex, accountID: String?, userID: String?) {
        guard let account = Self.normalized(accountID) else { return nil }
        let user = Self.normalized(userID)
        self.app = app
        accountDigest = Self.digest([app.rawValue, account])
        userDigest = user.map { Self.digest(["\(app.rawValue)-user", $0]) }
        key = Self.digest([app.rawValue, account, user ?? ""])
    }

    private enum CodingKeys: String, CodingKey { case app, accountDigest, userDigest, key }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // v1 仅有 Codex；保留原摘要，升级不能重新获得提醒机会。
        app = try values.decodeIfPresent(QuotaApp.self, forKey: .app) ?? .codex
        accountDigest = try values.decode(String.self, forKey: .accountDigest)
        userDigest = try values.decodeIfPresent(String.self, forKey: .userDigest)
        key = try values.decode(String.self, forKey: .key)
    }

    static func digest(_ parts: [String]) -> String {
        // JSON 数组保留字段边界，避免用分隔符拼接造成身份碰撞。
        let data = try! JSONEncoder().encode(parts)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

nonisolated struct QuotaAlertPreferences: Equatable, Sendable {
    var enabled = false
    var threshold = 20
    var fiveHour = true
    var weekly = true
    var billingCycle = true
    var sound = false

    func includes(_ kind: QuotaLimitKind) -> Bool {
        switch kind {
        case .fiveHour: fiveHour
        case .weekly, .modelWeekly: weekly
        case .unknown: billingCycle
        }
    }

    static func validThreshold(_ value: Int) -> Int {
        (5...50).contains(value) && value.isMultiple(of: 5) ? value : 20
    }
}

nonisolated struct QuotaAlertObservation: Sendable {
    let id: UUID
    let identity: QuotaAlertIdentity
    let entry: String
    let entryVersion: UInt64
    let settingsVersion: UInt64
    let observedAt: Date
    let raw: QuotaSnapshot
    let display: QuotaSnapshot
}

nonisolated struct QuotaAlertRecovery: Codable, Equatable, Sendable {
    var observationID: UUID
    var observedAt: Date
    var reset: Date?
    var threshold: Int
}

nonisolated struct QuotaAlertSubmission: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case prepared, accepted }
    var id: UUID
    var status: Status
    var submittedAt: Date
}

nonisolated struct QuotaAlertRecord: Codable, Equatable, Sendable {
    var cycleID = UUID()
    var anchor: Date?
    var windowSeconds: Int?
    var alertedThreshold: Int?
    var submission: QuotaAlertSubmission?
    var retryID: UUID?
    var retryAfter: Date?
    var recovery: QuotaAlertRecovery?
    var lastSeenAt: Date

    var occupied: Bool { submission != nil }
}

nonisolated struct QuotaAlertAccountState: Codable, Equatable, Sendable {
    var identity: QuotaAlertIdentity
    var windows: [String: QuotaAlertRecord] = [:]
}

nonisolated struct QuotaAlertPayload: Codable, Equatable, Sendable {
    var version = 2
    var accounts: [String: QuotaAlertAccountState] = [:]
    // 仅重建时使用：入口也只保存摘要。每个窗口的第一次真实观察建立基线。
    var baselineEntries: [String: Set<String>] = [:]
}

nonisolated struct QuotaNotificationPermission: Equatable, Sendable {
    enum Authorization: String, Sendable { case notDetermined, denied, allowed }
    var authorization: Authorization
    var alerts: Bool
    var sound: Bool
    var canSubmit: Bool { authorization == .allowed && alerts }
}

nonisolated struct QuotaNotificationMessage: Sendable {
    var identifier: String
    var title: String
    var body: String
    var sound: Bool
    var accountKey: String? = nil
    var entryKey: String? = nil
}

struct QuotaAlertDisplayContext {
    var name: String
    var privacyKey: String
}
