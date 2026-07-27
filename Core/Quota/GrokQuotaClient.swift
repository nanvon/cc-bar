import Foundation

/// 拉取 Grok Build / SuperGrok 统一计费额度与订阅档位。
///
/// - 额度：`GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`
/// - 订阅：`GET https://grok.com/rest/subscriptions`（`tier` 如 `SUBSCRIPTION_TIER_GROK_PRO`）
///
/// 部分 credits 响应会附带 `subscriptionTier`（与 Grok CLI 日志一致）；没有时回退到 subscriptions 接口。
nonisolated enum GrokQuotaClient {
    static let billingEndpoint = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    static let subscriptionsEndpoint = URL(string: "https://grok.com/rest/subscriptions")!
    private static let userAgent = "GrokCLI/0.2.112"

    struct Fetched: Sendable {
        var snapshot: QuotaSnapshot
        var planType: String?
    }

    nonisolated static func fetch(accessToken: String) async -> Result<Fetched, QuotaError> {
        async let billingResult = fetchJSON(url: billingEndpoint, accessToken: accessToken)
        async let planResult = fetchSubscriptionDisplayName(accessToken: accessToken)

        let billing: [String: Any]
        switch await billingResult {
        case .success(let root):
            billing = root
        case .failure(let err):
            return .failure(err)
        }

        var fetched = parse(root: billing)
        // credits 响应里可能没有 subscriptionTier；用 subscriptions 接口补全。
        if fetched.planType == nil, case .success(let plan) = await planResult {
            fetched.planType = plan
            var snapshot = fetched.snapshot
            snapshot.planType = plan
            fetched.snapshot = snapshot
        }
        return .success(fetched)
    }

    /// 单独拉订阅档位，供账号加载后尽快在设置页展示（不必等额度刷新）。
    nonisolated static func fetchSubscriptionDisplayName(
        accessToken: String
    ) async -> Result<String, QuotaError> {
        switch await fetchJSON(url: subscriptionsEndpoint, accessToken: accessToken) {
        case .success(let root):
            if let name = parseSubscriptionDisplayName(root: root) {
                return .success(name)
            }
            return .failure(.decode("no active subscription tier"))
        case .failure(let err):
            return .failure(err)
        }
    }

    nonisolated static func parse(root: [String: Any]) -> Fetched {
        let config = root["config"] as? [String: Any] ?? root
        let usedPercent = number(config["creditUsagePercent"]) ?? 0
        let period = config["currentPeriod"] as? [String: Any]
        let periodEnd = parseDate(period?["end"])
            ?? parseDate(config["billingPeriodEnd"])
        let periodStart = parseDate(period?["start"])
            ?? parseDate(config["billingPeriodStart"])
        let windowSeconds: Int? = {
            guard let start = periodStart, let end = periodEnd else {
                // SuperGrok 统一计费默认周窗口
                return 7 * 24 * 60 * 60
            }
            return max(1, Int(end.timeIntervalSince(start)))
        }()

        let weeklyWindow = QuotaWindow(
            usedPercent: usedPercent,
            resetsAt: periodEnd,
            windowSeconds: windowSeconds
        )
        let primary = QuotaLimit.standard(
            kind: .weekly,
            window: weeklyWindow,
            displayName: "Weekly credits"
        )

        var modelLimits: [QuotaLimit] = []
        if let products = config["productUsage"] as? [[String: Any]] {
            for row in products {
                guard let product = nonEmpty(row["product"] as? String) else { continue }
                // 部分产品只有名称、没有 usagePercent（未使用）
                let pct = number(row["usagePercent"]) ?? 0
                let limit = QuotaLimit.model(
                    id: product.lowercased(),
                    displayName: displayName(forProduct: product),
                    window: QuotaWindow(
                        usedPercent: pct,
                        resetsAt: periodEnd,
                        windowSeconds: windowSeconds
                    ),
                    isActive: true
                )
                modelLimits.append(limit)
            }
            modelLimits.sort { ($0.displayName ?? $0.id) < ($1.displayName ?? $1.id) }
        }

        let planType = nonEmpty(root["subscriptionTier"] as? String)
            .map(displayName(forTier:))
            ?? nonEmpty(config["subscriptionTier"] as? String).map(displayName(forTier:))
            ?? parseSubscriptionDisplayName(root: root)

        let snapshot = QuotaSnapshot(
            app: .grok,
            primaryLimit: primary,
            secondaryLimit: nil,
            modelLimits: modelLimits,
            planType: planType,
            fetchedAt: Date()
        )
        return Fetched(snapshot: snapshot, planType: planType)
    }

    /// 解析 `GET /rest/subscriptions` 或内嵌 subscriptions 数组，返回展示用订阅名。
    nonisolated static func parseSubscriptionDisplayName(root: [String: Any]) -> String? {
        let rows = root["subscriptions"] as? [[String: Any]] ?? []
        // 优先 ACTIVE，其次取第一条有 tier 的
        let ordered = rows.sorted { a, b in
            let aActive = (a["status"] as? String)?.uppercased().contains("ACTIVE") == true
            let bActive = (b["status"] as? String)?.uppercased().contains("ACTIVE") == true
            if aActive != bActive { return aActive && !bActive }
            return false
        }
        for row in ordered {
            if let tier = nonEmpty(row["tier"] as? String) {
                return displayName(forTier: tier)
            }
            if let apple = row["apple"] as? [String: Any],
               let productId = nonEmpty(apple["productId"] as? String) {
                return displayName(forProductId: productId)
            }
        }
        return nil
    }

    /// `SUBSCRIPTION_TIER_GROK_PRO` / `SuperGrok` / `pro` → 设置页展示名。
    nonisolated static func displayName(forTier raw: String) -> String {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "-", with: "_")
        let stripped = normalized
            .replacingOccurrences(of: "SUBSCRIPTION_TIER_", with: "")
            .replacingOccurrences(of: "SUBSCRIPTION_", with: "")

        switch stripped {
        case "GROK_PRO", "PRO", "SUPERGROK", "SUPER_GROK":
            return "SuperGrok"
        case "GROK_PRO_HEAVY", "PRO_HEAVY", "SUPERGROK_HEAVY", "HEAVY":
            return "SuperGrok Heavy"
        case "GROK_BASIC", "BASIC", "X_BASIC":
            return "Basic"
        case "FREE", "GROK_FREE":
            return "Free"
        default:
            if stripped.isEmpty { return raw }
            return stripped
                .lowercased()
                .split(separator: "_")
                .map { $0.capitalized }
                .joined(separator: " ")
        }
    }

    nonisolated static func displayName(forProductId productId: String) -> String {
        let id = productId.lowercased()
        if id.contains("heavy") { return "SuperGrok Heavy" }
        if id.contains("pro") || id.contains("super") { return "SuperGrok" }
        if id.contains("basic") { return "Basic" }
        if id.contains("free") { return "Free" }
        return displayName(forTier: productId)
    }

    // MARK: - HTTP

    nonisolated private static func fetchJSON(
        url: URL,
        accessToken: String
    ) async -> Result<[String: Any], QuotaError> {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("cli", forHTTPHeaderField: "x-grok-client-mode")
        req.setValue("0.2.112", forHTTPHeaderField: "x-grok-client-version")
        req.timeoutInterval = 30

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            return .failure(.transport("\(error)"))
        }
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
        return .success(root)
    }

    nonisolated private static func displayName(forProduct product: String) -> String {
        switch product.lowercased() {
        case "grokbuild": return "Grok Build"
        case "grokchat": return "Grok Chat"
        case "api": return "API"
        default: return product
        }
    }

    nonisolated private static func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String, let d = Double(s) { return d }
        return nil
    }

    nonisolated private static func parseDate(_ any: Any?) -> Date? {
        if let s = any as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: s)
        }
        if let n = any as? Double { return Date(timeIntervalSince1970: n) }
        if let n = any as? Int { return Date(timeIntervalSince1970: Double(n)) }
        return nil
    }

    nonisolated private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
