import Foundation

nonisolated enum ClaudeQuotaClient {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let userAgent = "claude-code/2.1.0"

    nonisolated static func fetch(
        accessToken: String
    ) async -> Result<QuotaSnapshot, QuotaError> {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30

        let data: Data, resp: URLResponse
        do { (data, resp) = try await NetworkProxy.data(for: req) }
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

    static let profileEndpoint = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    /// profile 里界面用得到的两项。
    nonisolated struct Profile: Sendable, Equatable {
        /// 认不出套餐时为 nil。
        var planName: String?
        /// 只用于显示，不参与账号键与提醒身份，见 `AppState.claudeDisplayEmail`。
        var email: String?
    }

    /// 从服务端查当前订阅的套餐名与邮箱。本地凭据里的 `subscriptionType` 只在签发 token 时
    /// 写入，Claude Desktop 的 token 有效期接近一年，升级 Max 后仍可能显示 Pro；
    /// 只用 Desktop 的用户本地也拿不到邮箱。
    nonisolated static func fetchProfile(
        accessToken: String
    ) async -> Result<Profile, QuotaError> {
        var req = URLRequest(url: profileEndpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30

        let data: Data, resp: URLResponse
        do { (data, resp) = try await NetworkProxy.data(for: req) }
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
        return .success(parseProfile(root: root))
    }

    nonisolated static func parseProfile(root: [String: Any]) -> Profile {
        let account = root["account"] as? [String: Any]
        return Profile(
            planName: parsePlanName(root: root),
            email: nonEmpty(account?["email"] as? String)
        )
    }

    /// `organization.organization_type`（`claude_pro` / `claude_max` / `claude_team` …）；
    /// 缺类型时退回 `account.has_claude_max` / `has_claude_pro`。
    /// 2026-10-30 起原 Max 20x 改名 Ultra，按 `rate_limit_tier` 含 `max_20x` 识别。
    nonisolated static func parsePlanName(root: [String: Any]) -> String? {
        let organization = root["organization"] as? [String: Any]
        let account = root["account"] as? [String: Any]
        if let tier = organization?["rate_limit_tier"] as? String,
           tier.lowercased().contains("max_20x") {
            return "Ultra"
        }
        var type = nonEmpty(organization?["organization_type"] as? String)
        if type == nil {
            if account?["has_claude_max"] as? Bool == true {
                type = "max"
            } else if account?["has_claude_pro"] as? Bool == true {
                type = "pro"
            }
        }
        return ClaudeAccount.planName(type)
    }

    nonisolated static func parse(root: [String: Any]) -> QuotaSnapshot {
        let legacySession = parseWindow(root["five_hour"] as? [String: Any])
        let legacyWeekly = parseWindow(root["seven_day"] as? [String: Any])
        let generic = parseGenericLimits(root["limits"] as? [[String: Any]] ?? [])

        let session = merge(
            preferred: generic.session,
            fallback: legacySession.map {
                QuotaLimit.standard(kind: .fiveHour, window: $0, displayName: "Current session")
            }
        )
        let weekly = merge(
            preferred: generic.weekly,
            fallback: legacyWeekly.map {
                QuotaLimit.standard(kind: .weekly, window: $0, displayName: "All models")
            }
        )

        var modelLimits = generic.models
        appendLegacyModel(
            name: "Opus",
            window: parseWindow(root["seven_day_opus"] as? [String: Any]),
            to: &modelLimits
        )
        appendLegacyModel(
            name: "Sonnet",
            window: parseWindow(root["seven_day_sonnet"] as? [String: Any]),
            to: &modelLimits
        )

        return QuotaSnapshot(
            app: .claude,
            primaryLimit: session ?? weekly,
            secondaryLimit: session == nil ? nil : weekly,
            modelLimits: modelLimits,
            planType: nil,
            fetchedAt: Date()
        )
    }

    nonisolated private struct GenericLimits {
        var session: QuotaLimit?
        var weekly: QuotaLimit?
        var models: [QuotaLimit] = []
    }

    nonisolated private static func parseGenericLimits(_ rows: [[String: Any]]) -> GenericLimits {
        var result = GenericLimits()
        for row in rows {
            guard let kind = row["kind"] as? String,
                  let percent = number(row["percent"])
            else { continue }
            let window = QuotaWindow(
                usedPercent: percent,
                resetsAt: parseResetDate(row["resets_at"]),
                windowSeconds: kind == "session" ? 5 * 60 * 60 : 7 * 24 * 60 * 60
            )
            let isActive = row["is_active"] as? Bool
            switch kind {
            case "session":
                result.session = .standard(
                    kind: .fiveHour,
                    window: window,
                    displayName: "Current session",
                    isActive: isActive
                )
            case "weekly_all":
                result.weekly = .standard(
                    kind: .weekly,
                    window: window,
                    displayName: "All models",
                    isActive: isActive
                )
            case "weekly_scoped":
                guard let scope = row["scope"] as? [String: Any] else { continue }
                let model = scope["model"] as? [String: Any]
                let surface = scope["surface"] as? [String: Any]
                let name = nonEmpty(model?["display_name"] as? String)
                    ?? nonEmpty(surface?["display_name"] as? String)
                    ?? nonEmpty(surface?["name"] as? String)
                    ?? nonEmpty(scope["surface"] as? String)
                guard let name else { continue }
                let rawID = nonEmpty(model?["id"] as? String)
                    ?? nonEmpty(surface?["id"] as? String)
                let limit = QuotaLimit.model(
                    id: rawID,
                    displayName: name,
                    window: window,
                    isActive: isActive
                )
                if let index = result.models.firstIndex(where: { $0.id == limit.id }) {
                    result.models[index] = limit
                } else {
                    result.models.append(limit)
                }
            default:
                continue
            }
        }
        return result
    }

    nonisolated private static func merge(
        preferred: QuotaLimit?,
        fallback: QuotaLimit?
    ) -> QuotaLimit? {
        guard var preferred else { return fallback }
        if preferred.window.resetsAt == nil {
            preferred.window.resetsAt = fallback?.window.resetsAt
        }
        if preferred.window.windowSeconds == nil {
            preferred.window.windowSeconds = fallback?.window.windowSeconds
        }
        return preferred
    }

    nonisolated private static func appendLegacyModel(
        name: String,
        window: QuotaWindow?,
        to limits: inout [QuotaLimit]
    ) {
        guard let window else { return }
        if let index = limits.firstIndex(where: {
            $0.displayName?.localizedCaseInsensitiveContains(name) == true
        }) {
            if limits[index].window.resetsAt == nil {
                limits[index].window.resetsAt = window.resetsAt
            }
            return
        }
        limits.append(.model(id: nil, displayName: name, window: window, isActive: nil))
    }

    nonisolated private static func parseWindow(_ dict: [String: Any]?) -> QuotaWindow? {
        guard let dict else { return nil }
        let used: Double = {
            if let d = dict["utilization"] as? Double { return d }
            if let i = dict["utilization"] as? Int { return Double(i) }
            return 0
        }()
        var resetsAt: Date?
        resetsAt = parseResetDate(dict["resets_at"])
        return QuotaWindow(usedPercent: used, resetsAt: resetsAt, windowSeconds: nil)
    }

    nonisolated private static func parseResetDate(_ value: Any?) -> Date? {
        if let s = value as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: s) { return date }
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: s)
        }
        if let n = value as? Double { return Date(timeIntervalSince1970: n) }
        if let i = value as? Int { return Date(timeIntervalSince1970: Double(i)) }
        return nil
    }

    nonisolated private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        return nil
    }

    nonisolated private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
