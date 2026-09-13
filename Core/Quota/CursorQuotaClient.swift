import Foundation

/// Cursor 个人账号额度兼容层。
///
/// Cursor 没有面向个人套餐的公开稳定额度 API；这里集中处理 Dashboard
/// `usage-summary` 的非公开响应，调用方负责从 Cursor.app 只读登录态构造 Cookie。
nonisolated enum CursorQuotaClient {
    static let endpoint = URL(string: "https://cursor.com/api/usage-summary")!

    static func fetch(cookieHeader: String) async -> Result<QuotaSnapshot, QuotaError> {
        let cookie = cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cookie.isEmpty else { return .failure(.missingToken) }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return .failure(.from(transport: error))
        }

        guard let http = response as? HTTPURLResponse else {
            return .failure(.transport("non-http"))
        }
        guard (200..<300).contains(http.statusCode) else {
            return .failure(.http(http.statusCode, "cursor usage-summary failed"))
        }

        do {
            return .success(try parse(data: data))
        } catch {
            return .failure(.decode(String(describing: error)))
        }
    }

    static func parse(data: Data, fetchedAt: Date = Date()) throws -> QuotaSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CursorQuotaParseError.notJSONObject
        }
        return parse(root: root, fetchedAt: fetchedAt)
    }

    static func parse(root: [String: Any], fetchedAt: Date = Date()) -> QuotaSnapshot {
        let individual = root["individualUsage"] as? [String: Any]
        let plan = individual?["plan"] as? [String: Any]
        let overall = individual?["overall"] as? [String: Any]
        let team = root["teamUsage"] as? [String: Any]
        let pooled = team?["pooled"] as? [String: Any]

        let cycleStart = date(root["billingCycleStart"])
        let cycleEnd = date(root["billingCycleEnd"])
        let windowSeconds = cycleDuration(start: cycleStart, end: cycleEnd)

        let totalUsedPercent: Double? = {
            let limitType = string(root["limitType"])?.lowercased()
            if limitType == "team", let value = ratioPercent(pooled) { return value }
            if let value = number(plan?["totalPercentUsed"]) { return value }
            if let value = ratioPercent(plan) { return value }
            if let value = ratioPercent(overall) { return value }
            return ratioPercent(pooled)
        }()

        let total = totalUsedPercent.map {
            limit(
                id: "cursor-total",
                displayName: "Total",
                usedPercent: $0,
                resetsAt: cycleEnd,
                windowSeconds: windowSeconds
            )
        }
        let auto = number(plan?["autoPercentUsed"]).map {
            limit(
                id: "cursor-auto",
                displayName: "Auto",
                usedPercent: $0,
                resetsAt: cycleEnd,
                windowSeconds: windowSeconds
            )
        }
        let api = number(plan?["apiPercentUsed"]).map {
            limit(
                id: "cursor-api",
                displayName: "API",
                usedPercent: $0,
                resetsAt: cycleEnd,
                windowSeconds: windowSeconds
            )
        }

        return QuotaSnapshot(
            app: .cursor,
            primaryLimit: total,
            secondaryLimit: auto,
            auxiliaryLimits: api.map { [$0] } ?? [],
            isUnlimited: root["isUnlimited"] as? Bool,
            planType: formattedPlanType(string(root["membershipType"])),
            fetchedAt: fetchedAt
        )
    }

    private static func limit(
        id: String,
        displayName: String,
        usedPercent: Double,
        resetsAt: Date?,
        windowSeconds: Int?
    ) -> QuotaLimit {
        QuotaLimit(
            id: id,
            kind: .unknown,
            displayName: displayName,
            window: QuotaWindow(
                usedPercent: usedPercent,
                resetsAt: resetsAt,
                windowSeconds: windowSeconds
            ),
            isActive: nil
        )
    }

    private static func ratioPercent(_ bucket: [String: Any]?) -> Double? {
        guard bucket?["enabled"] as? Bool != false,
              let used = number(bucket?["used"]),
              let limit = number(bucket?["limit"]),
              limit > 0
        else { return nil }
        let percent = used / limit * 100
        return percent.isFinite ? percent : nil
    }

    /// JSONSerialization 把 JSON 数字解析成 NSNumber，而 Swift 里 `NSNumber(0/1) is Bool`
    /// 会命中 NSNumber→Bool 的条件桥接返回 true。直接用 `is Bool` 会把 `totalPercentUsed: 1`、
    /// `apiPercentUsed: 0` 当成布尔丢弃，Total / API 两档就整个消失，只剩 Auto。
    /// 真正的 JSON `true` / `false` 是 CFBoolean，只能按类型 ID 判定。
    private static func isBoolean(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func number(_ value: Any?) -> Double? {
        if isBoolean(value) { return nil }
        let parsed: Double?
        switch value {
        case let number as NSNumber:
            parsed = number.doubleValue
        case let string as String:
            parsed = Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            parsed = nil
        }
        guard let parsed, parsed.isFinite else { return nil }
        return parsed
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func date(_ value: Any?) -> Date? {
        guard let value = string(value) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func cycleDuration(start: Date?, end: Date?) -> Int? {
        guard let start, let end, end > start else { return nil }
        let duration = end.timeIntervalSince(start)
        guard duration.isFinite, duration <= Double(Int.max) else { return nil }
        return Int(duration)
    }

    private static func formattedPlanType(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let words = raw.split { $0 == "_" || $0 == "-" || $0.isWhitespace }
        guard !words.isEmpty else { return nil }
        return words.map { $0.lowercased().capitalized }.joined(separator: " ")
    }
}

nonisolated enum CursorQuotaParseError: Error {
    case notJSONObject
}
