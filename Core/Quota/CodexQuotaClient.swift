import Foundation

nonisolated enum CodexQuotaClient {
    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    /// 取数结果。`wham/usage` 响应除配额外还自带身份字段，
    /// 对不透明的 personal access token（解不出 JWT）尤为关键，用于回填账号身份。
    struct Fetched: Sendable {
        var snapshot: QuotaSnapshot
        var accountId: String?
        var userId: String?
        var email: String?
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

    nonisolated static func parse(root: [String: Any]) -> Fetched {
        let planType = root["plan_type"] as? String
        let rate = root["rate_limit"] as? [String: Any] ?? [:]
        let primaryWindow = parseWindow(rate["primary_window"] as? [String: Any])
        let secondaryWindow = parseWindow(rate["secondary_window"] as? [String: Any])
        let snapshot = QuotaSnapshot(
            app: .codex,
            primaryLimit: primaryWindow.map {
                QuotaLimit.standard(kind: QuotaSnapshot.kind(for: $0), window: $0)
            },
            secondaryLimit: secondaryWindow.map {
                QuotaLimit.standard(kind: QuotaSnapshot.kind(for: $0), window: $0)
            },
            planType: planType,
            fetchedAt: Date()
        )
        return Fetched(
            snapshot: snapshot,
            accountId: nonEmpty(root["account_id"] as? String),
            userId: nonEmpty(root["user_id"] as? String),
            email: nonEmpty(root["email"] as? String)
        )
    }

    nonisolated private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    nonisolated private static func parseWindow(_ dict: [String: Any]?) -> QuotaWindow? {
        guard let dict else { return nil }
        let used: Double = {
            if let d = dict["used_percent"] as? Double { return d }
            if let i = dict["used_percent"] as? Int { return Double(i) }
            return 0
        }()
        var resetAt: Date?
        if let n = dict["reset_at"] as? Double {
            resetAt = Date(timeIntervalSince1970: n)
        } else if let i = dict["reset_at"] as? Int {
            resetAt = Date(timeIntervalSince1970: Double(i))
        } else if let secs = dict["reset_after_seconds"] as? Double {
            resetAt = Date(timeIntervalSinceNow: secs)
        } else if let secs = dict["reset_after_seconds"] as? Int {
            resetAt = Date(timeIntervalSinceNow: Double(secs))
        }
        let window: Int? = (dict["limit_window_seconds"] as? Int)
            ?? (dict["limit_window_seconds"] as? Double).map { Int($0) }
        return QuotaWindow(usedPercent: used, resetsAt: resetAt, windowSeconds: window)
    }
}
