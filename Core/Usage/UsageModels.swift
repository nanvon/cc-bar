import Foundation

nonisolated enum UsageApp: String, Sendable, Codable, Hashable, CaseIterable {
    case codex
    case claude
    case grok
}

/// 单次请求实际使用的服务速度档位。`unknown` 只用于日志缺失或出现未来新值时，不能静默按 Standard 计价。
nonisolated enum UsageSpeed: String, Sendable, Codable, Hashable, CaseIterable {
    case standard
    case fast
    case unknown
}

/// 聚合后的速度状态；对话同时含 Fast 与其他档位时为 mixed。
nonisolated enum UsageSpeedSummary: String, Sendable, Equatable {
    case standard
    case fast
    case mixed
    case unknown
}

/// 单次 API 调用解析出的用量记录（内存中流转，不直接持久化）。
nonisolated struct UsageEntry: Sendable, Equatable {
    var app: UsageApp
    var conversationKey: String
    var model: String
    var speed: UsageSpeed
    var day: Date              // 本地时区 0 点
    var timestamp: Date
    var inputTokens: Int       // 已扣 cacheRead（Codex 解析时已处理）
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheCreationTokens: Int
    var requestCount: Int = 1
    /// `nil` = 没有可靠价格；聚合和 UI 金额按 0，桶内标记仅供诊断。
    var costUSD: Decimal?
    var costBreakdown: CostBreakdown?
}

/// (day, app, model, speed) 聚合桶；UsageAggregator 内存表的值。
nonisolated struct UsageBucket: Sendable, Equatable, Codable {
    var app: UsageApp
    var model: String
    var speed: UsageSpeed
    var day: Date
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheCreationTokens: Int
    var costUSD: Decimal
    var requestCount: Int
    var hasUnpricedUsage: Bool
}

nonisolated struct UsageTotals: Sendable, Equatable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var costUSD: Decimal = 0
    var requestCount: Int = 0
    var hasUnpricedUsage = false

    static let zero = UsageTotals()

    mutating func add(_ bucket: UsageBucket) {
        inputTokens += bucket.inputTokens
        outputTokens += bucket.outputTokens
        cacheReadTokens += bucket.cacheReadTokens
        cacheCreationTokens += bucket.cacheCreationTokens
        costUSD += bucket.costUSD
        requestCount += bucket.requestCount
        hasUnpricedUsage = hasUnpricedUsage || bucket.hasUnpricedUsage
    }

    mutating func add(_ other: UsageTotals) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheReadTokens += other.cacheReadTokens
        cacheCreationTokens += other.cacheCreationTokens
        costUSD += other.costUSD
        requestCount += other.requestCount
        hasUnpricedUsage = hasUnpricedUsage || other.hasUnpricedUsage
    }

    /// 含缓存的输入侧 token(input + cache_read + cache_creation)。与 cc-switch / ccusage 的 input 口径一致。
    var inputWithCacheTokens: Int {
        inputTokens + cacheReadTokens + cacheCreationTokens
    }

    /// 全量 token(输入含缓存 + 输出)。与 cc-switch / ccusage 的总量口径一致。
    var totalTokens: Int {
        inputWithCacheTokens + outputTokens
    }

    /// 缓存命中率:缓存读取 token 占「输入侧 token(含缓存)」的比例,0~1。口径参考 cc-switch:
    /// cacheRead / (input + cacheCreation + cacheRead),即 cacheRead / inputWithCacheTokens。
    var cacheHitRate: Double {
        guard inputWithCacheTokens > 0 else { return 0 }
        return Double(cacheReadTokens) / Double(inputWithCacheTokens)
    }
}

/// Standard / Fast / 未识别三档聚合。原始 Tokens 永不乘倍率；Fast 计费等效 Tokens 单独保存。
nonisolated struct UsageSpeedBreakdown: Sendable, Equatable {
    var standard = UsageTotals.zero
    var fast = UsageTotals.zero
    var unknown = UsageTotals.zero
    var fastBillingEquivalentTokens: Decimal = 0
    var fastMinimumMultiplier: Decimal?
    var fastMaximumMultiplier: Decimal?
    var hasUnpricedFastEquivalent = false
    var standardHasUnpricedCost = false
    var fastHasUnpricedCost = false
    var unknownHasUnpricedCost = false

    var summary: UsageSpeedSummary {
        if fast.requestCount > 0 {
            return standard.requestCount > 0 || unknown.requestCount > 0 ? .mixed : .fast
        }
        return unknown.requestCount > 0 ? .unknown : .standard
    }

    mutating func add(_ bucket: UsageBucket) {
        var totals = UsageTotals.zero
        totals.add(bucket)
        add(
            speed: bucket.speed,
            totals: totals,
            app: bucket.app,
            model: bucket.model,
            hasUnpricedCost: bucket.hasUnpricedUsage
        )
    }

    mutating func add(
        speed: UsageSpeed,
        totals: UsageTotals,
        app: UsageApp,
        model: String,
        hasUnpricedCost: Bool = false
    ) {
        var tierTotals = totals
        tierTotals.hasUnpricedUsage = tierTotals.hasUnpricedUsage || hasUnpricedCost
        switch speed {
        case .standard:
            standard.add(tierTotals)
            standardHasUnpricedCost = standardHasUnpricedCost || hasUnpricedCost
        case .fast:
            fast.add(tierTotals)
            fastHasUnpricedCost = fastHasUnpricedCost || hasUnpricedCost
            if let multiplier = Pricing.billingEquivalentMultiplier(app: app, model: model, speed: speed) {
                fastBillingEquivalentTokens += Decimal(tierTotals.totalTokens) * multiplier
                fastMinimumMultiplier = min(fastMinimumMultiplier ?? multiplier, multiplier)
                fastMaximumMultiplier = max(fastMaximumMultiplier ?? multiplier, multiplier)
            } else {
                hasUnpricedFastEquivalent = true
            }
        case .unknown:
            unknown.add(tierTotals)
            unknownHasUnpricedCost = unknownHasUnpricedCost || hasUnpricedCost
        }
    }
}

/// Decimal <-> String 编解码，避免 Double 精度漂。
extension Decimal {
    nonisolated var asPlainString: String {
        var copy = self
        return NSDecimalString(&copy, Locale(identifier: "en_US_POSIX"))
    }

    nonisolated init?(plainString: String) {
        self.init(string: plainString, locale: Locale(identifier: "en_US_POSIX"))
    }
}

/// UsageBucket 的 Codable 用 Decimal 字符串。
extension UsageBucket {
    nonisolated enum CodingKeys: String, CodingKey {
        case app, model, speed, day, inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens, costUSD, requestCount
        case hasUnpricedUsage
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.app = try c.decode(UsageApp.self, forKey: .app)
        self.model = try c.decode(String.self, forKey: .model)
        self.speed = try c.decode(UsageSpeed.self, forKey: .speed)
        self.day = try c.decode(Date.self, forKey: .day)
        self.inputTokens = try c.decode(Int.self, forKey: .inputTokens)
        self.outputTokens = try c.decode(Int.self, forKey: .outputTokens)
        self.cacheReadTokens = try c.decode(Int.self, forKey: .cacheReadTokens)
        self.cacheCreationTokens = try c.decode(Int.self, forKey: .cacheCreationTokens)
        let costStr = try c.decode(String.self, forKey: .costUSD)
        self.costUSD = Decimal(plainString: costStr) ?? 0
        self.requestCount = try c.decodeIfPresent(Int.self, forKey: .requestCount) ?? 0
        self.hasUnpricedUsage = try c.decode(Bool.self, forKey: .hasUnpricedUsage)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(app, forKey: .app)
        try c.encode(model, forKey: .model)
        try c.encode(speed, forKey: .speed)
        try c.encode(day, forKey: .day)
        try c.encode(inputTokens, forKey: .inputTokens)
        try c.encode(outputTokens, forKey: .outputTokens)
        try c.encode(cacheReadTokens, forKey: .cacheReadTokens)
        try c.encode(cacheCreationTokens, forKey: .cacheCreationTokens)
        try c.encode(costUSD.asPlainString, forKey: .costUSD)
        try c.encode(requestCount, forKey: .requestCount)
        try c.encode(hasUnpricedUsage, forKey: .hasUnpricedUsage)
    }
}

nonisolated enum UsageDay {
    /// 本地时区 0 点。
    static func startOfDay(for date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }
}
