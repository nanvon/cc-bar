import Foundation

enum CommandCodeQuotaClient {
    private static let baseURL = URL(string: "https://api.commandcode.ai")!

    struct FetchResult: Sendable {
        var snapshot: QuotaSnapshot
        var accountDetails: AccountDetails
    }

    struct AccountDetails: Sendable {
        var login: String?
        var name: String?
        var email: String?
        var orgID: String?
        var planType: String?
    }

    struct WhoamiResponse: Codable {
        struct User: Codable {
            var id: String?
            var name: String?
            var email: String?
            var userName: String?
        }
        struct Org: Codable {
            var id: String?
            var name: String?
        }
        var user: User?
        var org: Org?
    }

    struct CreditsResponse: Codable {
        struct Window: Codable {
            var cap: Double?
            var used: Double?
            var resetAt: Double?

            var resetDate: Date? {
                guard let resetAt, resetAt > 0 else { return nil }
                if resetAt > 1_000_000_000_000 {
                    return Date(timeIntervalSince1970: resetAt / 1000.0)
                }
                return Date(timeIntervalSince1970: resetAt)
            }
        }
        var fiveHour: Window?
        var weekly: Window?
        var monthlyCredits: Double?
    }

    struct SubscriptionResponse: Codable {
        var id: String?
        var planId: String?
        var status: String?
        var currentPeriodEnd: String?
    }

    static func fetch(
        accessToken: String,
        session: URLSession = .shared
    ) async -> Result<FetchResult, QuotaError> {
        // 1. 请求 whoami 识别账号与 org
        let whoamiResult = await request(
            path: "/alpha/whoami",
            accessToken: accessToken,
            session: session
        )

        guard case .success(let whoamiData) = whoamiResult else {
            if case .failure(let err) = whoamiResult { return .failure(err) }
            return .failure(.transport("whoami failed"))
        }

        let whoamiJson = (try? JSONSerialization.jsonObject(with: whoamiData)) as? [String: Any]
        let whoamiDataDict = whoamiJson?["data"] as? [String: Any] ?? whoamiJson

        let userDict = whoamiDataDict?["user"] as? [String: Any]
        let orgDict = whoamiDataDict?["org"] as? [String: Any]

        let login = userDict?["userName"] as? String
        let name = userDict?["name"] as? String
        let email = userDict?["email"] as? String
        let orgID = orgDict?["id"] as? String

        // 2. 并发拉取 credits 与 subscriptions
        var creditsQueryItems: [URLQueryItem] = []
        if let orgID, !orgID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            creditsQueryItems.append(URLQueryItem(name: "orgId", value: orgID))
        }

        async let creditsResult = request(
            path: "/alpha/billing/credits",
            queryItems: creditsQueryItems,
            accessToken: accessToken,
            session: session
        )
        async let subsResult = request(
            path: "/alpha/billing/subscriptions",
            accessToken: accessToken,
            session: session
        )

        let creditsDataRes = await creditsResult
        guard case .success(let creditsData) = creditsDataRes else {
            if case .failure(let err) = creditsDataRes { return .failure(err) }
            return .failure(.transport("credits failed"))
        }

        let subsData = (try? (await subsResult).get())

        // 3. 解析为 QuotaSnapshot
        let creditsJson = (try? JSONSerialization.jsonObject(with: creditsData)) as? [String: Any]
        let subsJson = subsData.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }

        let parsed = parse(
            creditsRoot: creditsJson?["data"] as? [String: Any] ?? creditsJson ?? [:],
            subscriptionsRoot: subsJson,
            fetchedAt: Date()
        )

        let details = AccountDetails(
            login: login,
            name: name,
            email: email,
            orgID: orgID,
            planType: parsed.planType
        )

        return .success(FetchResult(snapshot: parsed.snapshot, accountDetails: details))
    }

    private static func request(
        path: String,
        queryItems: [URLQueryItem] = [],
        accessToken: String,
        session: URLSession
    ) async -> Result<Data, QuotaError> {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !queryItems.isEmpty {
            components?.queryItems = queryItems
        }
        guard let url = components?.url else {
            return .failure(.transport("invalid url"))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("cc-bar", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.transport("non-http response"))
            }
            guard (200...299).contains(http.statusCode) else {
                let msg = String(data: data, encoding: .utf8) ?? "status \(http.statusCode)"
                return .failure(.http(http.statusCode, msg))
            }
            return .success(data)
        } catch {
            return .failure(.from(transport: error))
        }
    }

    static func parse(
        creditsRoot: [String: Any],
        subscriptionsRoot: [String: Any]?,
        fetchedAt: Date = Date()
    ) -> (snapshot: QuotaSnapshot, planType: String?) {
        let subsData = subscriptionsRoot?["data"] as? [String: Any]
        let rawPlanId = subsData?["planId"] as? String
        let formattedPlan = formatPlanId(rawPlanId)

        // 1. 解析 windowLimits (5H & Weekly)，兼容嵌套在 windowLimits 下或直接平铺
        let windowLimits = creditsRoot["windowLimits"] as? [String: Any]
        let fiveHourDict = windowLimits?["fiveHour"] as? [String: Any]
            ?? creditsRoot["fiveHour"] as? [String: Any]
        let weeklyDict = windowLimits?["weekly"] as? [String: Any]
            ?? creditsRoot["weekly"] as? [String: Any]

        let fiveHour = parseWindow(
            dict: fiveHourDict,
            id: "command-code-five-hour",
            displayName: "5HOUR",
            kind: .fiveHour,
            windowSeconds: 18_000,
            fetchedAt: fetchedAt
        )
        let weekly = parseWindow(
            dict: weeklyDict,
            id: "command-code-weekly",
            displayName: "WEEKLY",
            kind: .weekly,
            windowSeconds: 604_800,
            fetchedAt: fetchedAt
        )

        // 2. 解析 Monthly Credits，兼容嵌套在 credits 字典下或直接平铺
        var auxiliaryLimits: [QuotaLimit] = []
        let creditsDict = creditsRoot["credits"] as? [String: Any]
        let monthlyRaw = creditsDict?["monthlyCredits"] ?? creditsRoot["monthlyCredits"]
        if let monthlyCredits = parseNumber(monthlyRaw) {
            // GOAT 套餐月总额度 70
            let monthlyCap: Double = (formattedPlan == "GOAT") ? 70 : 0
            if monthlyCap > 0 {
                let used = max(0, monthlyCap - monthlyCredits)
                let usedPercent = min(100, max(0, (used / monthlyCap) * 100))
                let currentPeriodEnd = parseDate(subsData?["currentPeriodEnd"])
                let monthlyLimit = QuotaLimit(
                    id: "command-code-monthly",
                    kind: .unknown,
                    displayName: "MONTHLY",
                    window: QuotaWindow(
                        usedPercent: usedPercent,
                        resetsAt: currentPeriodEnd,
                        windowSeconds: 30 * 86_400
                    )
                )
                auxiliaryLimits.append(monthlyLimit)
            }
        }

        let snapshot = QuotaSnapshot(
            app: .commandCode,
            primaryLimit: fiveHour,
            secondaryLimit: weekly,
            auxiliaryLimits: auxiliaryLimits,
            modelLimits: [],
            planType: formattedPlan,
            fetchedAt: fetchedAt
        )

        return (snapshot, formattedPlan)
    }

    private static func parseWindow(
        dict: [String: Any]?,
        id: String,
        displayName: String,
        kind: QuotaLimitKind,
        windowSeconds: Int,
        fetchedAt: Date
    ) -> QuotaLimit? {
        guard let dict else { return nil }
        guard let cap = parseNumber(dict["cap"]), cap > 0 else { return nil }
        let used = parseNumber(dict["used"]) ?? 0
        let usedPercent = min(100, max(0, (used / cap) * 100))
        var resetsAt = parseDate(dict["resetAt"])

        // 若周期未开始（used == 0 且无有效未来重置时间），按窗口长度预估重置时间（如 5 小时），与 Codex/Claude 对齐
        if usedPercent == 0, resetsAt == nil || (resetsAt != nil && resetsAt! <= fetchedAt) {
            resetsAt = fetchedAt.addingTimeInterval(Double(windowSeconds))
        }

        return QuotaLimit(
            id: id,
            kind: kind,
            displayName: displayName,
            window: QuotaWindow(
                usedPercent: usedPercent,
                resetsAt: resetsAt,
                windowSeconds: windowSeconds
            )
        )
    }

    // MARK: - 辅助解析

    private static func parseNumber(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String, let d = Double(s) { return d }
        return nil
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let value else { return nil }
        if let num = parseNumber(value) {
            guard num > 0 else { return nil }
            if num > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: num / 1000.0)
            }
            return Date(timeIntervalSince1970: num)
        }
        if let str = value as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = formatter.date(from: str) {
                guard d.timeIntervalSince1970 > 0 else { return nil }
                return d
            }
            formatter.formatOptions = [.withInternetDateTime]
            if let d = formatter.date(from: str) {
                guard d.timeIntervalSince1970 > 0 else { return nil }
                return d
            }
        }
        return nil
    }

    private static func formatPlanId(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        if lower.contains("goat") { return "GOAT" }
        if lower.contains("pro") { return "Pro" }
        if lower.contains("team") { return "Team" }
        if lower.contains("enterprise") { return "Enterprise" }
        return raw.capitalized
    }
}
