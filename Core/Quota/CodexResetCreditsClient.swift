import Foundation

// MARK: - CodexResetCreditsClient
//
// 拉取 Codex 账号的额外「Full reset」credit（wham/rate-limit-reset-credits）。
// 与 CodexQuotaClient(wham/usage) 是独立接口,不参与常规额度快照,
// 仅供设置页「其他 Codex 账号」按需(懒加载)查询,不接入 Scheduler 定时刷新。

enum CodexResetCreditsClient {
    nonisolated static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!

    struct Credit: Sendable, Identifiable {
        var id: String { "\(title)-\(status)-\(grantedAt?.timeIntervalSince1970 ?? 0)" }
        var status: String
        var title: String
        var grantedAt: Date?
        var expiresAt: Date?
    }

    struct Fetched: Sendable {
        var availableCount: Int
        var credits: [Credit]
    }

    nonisolated static func fetch(
        accessToken: String,
        accountId: String?
    ) async -> Result<Fetched, QuotaError> {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        if let accountId, !accountId.isEmpty {
            req.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { return .failure(.from(transport: error)) }
        guard let http = resp as? HTTPURLResponse else {
            return .failure(.transport("non-http"))
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            return .failure(.http(http.statusCode, msg))
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.decode("not json object"))
        }
        return .success(parse(root: root))
    }

    nonisolated private static func parse(root: [String: Any]) -> Fetched {
        let availableCount = (root["available_count"] as? Int)
            ?? (root["available_count"] as? Double).map(Int.init)
            ?? 0
        let rawCredits = (root["credits"] as? [[String: Any]]) ?? []
        let credits = rawCredits.map { dict in
            Credit(
                status: dict["status"] as? String ?? "",
                title: dict["title"] as? String ?? "",
                grantedAt: parseDate(dict["granted_at"]),
                expiresAt: parseDate(dict["expires_at"])
            )
        }
        return Fetched(availableCount: availableCount, credits: credits)
    }

    nonisolated private static func parseDate(_ value: Any?) -> Date? {
        if let n = value as? Double { return Date(timeIntervalSince1970: n) }
        if let i = value as? Int { return Date(timeIntervalSince1970: Double(i)) }
        guard let s = value as? String, !s.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s)
    }
}
