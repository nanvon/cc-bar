import Foundation

/// 拉取 Grok Build / SuperGrok 统一计费额度。
///
/// 端点与 Grok CLI 一致：`GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`
/// 响应核心字段：`config.creditUsagePercent` + 周窗口起止；可选 `productUsage` 分产品拆分。
nonisolated enum GrokQuotaClient {
    static let endpoint = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private static let userAgent = "GrokCLI/0.2.112"

    struct Fetched: Sendable {
        var snapshot: QuotaSnapshot
        var planType: String?
    }

    nonisolated static func fetch(accessToken: String) async -> Result<Fetched, QuotaError> {
        var req = URLRequest(url: endpoint)
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
        return .success(parse(root: root))
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
            ?? nonEmpty(config["subscriptionTier"] as? String)

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
