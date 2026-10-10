import Foundation
import Observation

nonisolated enum CycleUsageQuality: String, Sendable, Codable, Equatable {
    case exact
    case estimated
    case incomplete

    var rank: Int {
        switch self {
        case .exact: return 0
        case .estimated: return 1
        case .incomplete: return 2
        }
    }

    static func worst(_ lhs: Self, _ rhs: Self) -> Self {
        lhs.rank >= rhs.rank ? lhs : rhs
    }
}

nonisolated struct CycleUsageBucket: Sendable, Codable, Equatable {
    var cycleID: String
    var allowanceSegmentID: String?
    var app: UsageApp
    var model: String
    var speed: UsageSpeed
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheCreationTokens: Int
    var costUSD: Decimal
    var requestCount: Int
    var hasUnpricedUsage: Bool
    var quality: CycleUsageQuality
    /// 来源对话；额度页按项目拆分周期进度时用。旧版本写入的桶没有该字段（nil），拆分时计入「其他」。
    /// 不参与 `UsageHistoryConsistency.cycleVector` 的键，安全重算的周期对账口径不变。
    var conversationKey: String?

    enum CodingKeys: String, CodingKey {
        case cycleID, allowanceSegmentID, app, model, speed
        case inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens
        case costUSD, requestCount, hasUnpricedUsage, quality, conversationKey
    }

    init(
        cycleID: String,
        allowanceSegmentID: String?,
        app: UsageApp,
        model: String,
        speed: UsageSpeed,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int,
        costUSD: Decimal,
        requestCount: Int,
        hasUnpricedUsage: Bool,
        quality: CycleUsageQuality,
        conversationKey: String? = nil
    ) {
        self.cycleID = cycleID
        self.allowanceSegmentID = allowanceSegmentID
        self.app = app
        self.model = model
        self.speed = speed
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.costUSD = costUSD
        self.requestCount = requestCount
        self.hasUnpricedUsage = hasUnpricedUsage
        self.quality = quality
        self.conversationKey = conversationKey
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cycleID = try c.decode(String.self, forKey: .cycleID)
        allowanceSegmentID = try c.decodeIfPresent(String.self, forKey: .allowanceSegmentID)
        app = try c.decode(UsageApp.self, forKey: .app)
        model = try c.decode(String.self, forKey: .model)
        speed = try c.decode(UsageSpeed.self, forKey: .speed)
        inputTokens = try c.decode(Int.self, forKey: .inputTokens)
        outputTokens = try c.decode(Int.self, forKey: .outputTokens)
        cacheReadTokens = try c.decode(Int.self, forKey: .cacheReadTokens)
        cacheCreationTokens = try c.decode(Int.self, forKey: .cacheCreationTokens)
        costUSD = Decimal(plainString: try c.decode(String.self, forKey: .costUSD)) ?? 0
        requestCount = try c.decode(Int.self, forKey: .requestCount)
        hasUnpricedUsage = try c.decode(Bool.self, forKey: .hasUnpricedUsage)
        quality = try c.decode(CycleUsageQuality.self, forKey: .quality)
        conversationKey = try c.decodeIfPresent(String.self, forKey: .conversationKey)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cycleID, forKey: .cycleID)
        try c.encodeIfPresent(allowanceSegmentID, forKey: .allowanceSegmentID)
        try c.encode(app, forKey: .app)
        try c.encode(model, forKey: .model)
        try c.encode(speed, forKey: .speed)
        try c.encode(inputTokens, forKey: .inputTokens)
        try c.encode(outputTokens, forKey: .outputTokens)
        try c.encode(cacheReadTokens, forKey: .cacheReadTokens)
        try c.encode(cacheCreationTokens, forKey: .cacheCreationTokens)
        try c.encode(costUSD.asPlainString, forKey: .costUSD)
        try c.encode(requestCount, forKey: .requestCount)
        try c.encode(hasUnpricedUsage, forKey: .hasUnpricedUsage)
        try c.encode(quality, forKey: .quality)
        try c.encodeIfPresent(conversationKey, forKey: .conversationKey)
    }
}

nonisolated struct CycleUsageRollupPayload: Sendable, Codable {
    static let currentVersion = 4

    var version: Int = Self.currentVersion
    var generationID: String = ""
    var pricingFingerprint: String = ""
    var buckets: [CycleUsageBucket] = []
    var initialRebuildCompletedAt: Date?
    /// nil 表示旧 v4 payload；此时用 `initialRebuildCompletedAt` 兼容推导。
    var initialRebuildCompletedApps: Set<UsageApp>?
    var updatedAt: Date = Date()

    var effectiveInitialRebuildCompletedApps: Set<UsageApp> {
        if let initialRebuildCompletedApps { return initialRebuildCompletedApps }
        return initialRebuildCompletedAt == nil ? [] : [.codex, .claude]
    }
}

nonisolated enum CycleForecastConfidence: Sendable, Equatable {
    case early
    case rough
    case reference
    case reliable
}

nonisolated struct CycleUsageSummary: Sendable, Equatable, Identifiable {
    var cycle: QuotaCycleRecord
    var totals: UsageTotals
    var currentAllowanceTotals: UsageTotals
    var quality: CycleUsageQuality

    init(
        cycle: QuotaCycleRecord,
        totals: UsageTotals,
        currentAllowanceTotals: UsageTotals = .zero,
        quality: CycleUsageQuality
    ) {
        self.cycle = cycle
        self.totals = totals
        self.currentAllowanceTotals = currentAllowanceTotals
        self.quality = quality
    }

    var id: String { cycle.id }

    var hasLocalUsage: Bool {
        totals.requestCount > 0
            || totals.totalTokens > 0
            || totals.costUSD > 0
            || totals.hasUnpricedUsage
    }

    var forecastObservedPercent: Double {
        cycle.latestAllowanceSegment?.observedUsedPercent ?? 0
    }

    var forecastConfidence: CycleForecastConfidence? {
        guard forecastObservedPercent > 0,
              currentAllowanceTotals.totalTokens > 0 || currentAllowanceTotals.costUSD > 0
        else { return nil }
        switch forecastObservedPercent {
        case 80...: return .reliable
        case 30..<80: return .reference
        case 10..<30: return .rough
        default: return .early
        }
    }

    var estimatedFullAllowanceTokens: Int? {
        guard forecastObservedPercent > 0,
              currentAllowanceTotals.totalTokens > 0
        else { return nil }
        let estimate = Double(currentAllowanceTotals.totalTokens) * 100 / forecastObservedPercent
        guard estimate.isFinite, estimate <= Double(Int.max) else { return nil }
        return Int(estimate.rounded())
    }

    var estimatedFullAllowanceCostUSD: Decimal? {
        guard forecastObservedPercent > 0,
              currentAllowanceTotals.costUSD > 0
        else { return nil }
        return currentAllowanceTotals.costUSD * 100 / Decimal(forecastObservedPercent)
    }

    var projectedFullCycleTokens: Int? {
        guard let estimatedFullAllowanceTokens else { return nil }
        let priorActual = max(0, totals.totalTokens - currentAllowanceTotals.totalTokens)
        return priorActual + estimatedFullAllowanceTokens
    }

    var projectedFullCycleCostUSD: Decimal? {
        guard let estimatedFullAllowanceCostUSD else { return nil }
        let priorActual = max(0, totals.costUSD - currentAllowanceTotals.costUSD)
        return priorActual + estimatedFullAllowanceCostUSD
    }
}

enum CycleUsageRollupCache {
    nonisolated private static let fileName = "cycle-usage-rollup.json"
    nonisolated private static let bundleDirectory = "CCBar"

    nonisolated static func load(in directory: URL? = nil) -> CycleUsageRollupPayload {
        let url = fileURL(in: directory)
        guard let data = try? Data(contentsOf: url),
              let payload = decode(data)
        else {
            return CycleUsageRollupPayload()
        }
        return payload
    }

    /// 版本不匹配时拒绝恢复派生 rollup，让启动流程按现有机制自动完整重建。
    nonisolated static func decode(_ data: Data) -> CycleUsageRollupPayload? {
        guard let payload = try? JSONDecoder().decode(CycleUsageRollupPayload.self, from: data),
              payload.version == CycleUsageRollupPayload.currentVersion
        else { return nil }
        return payload
    }

    nonisolated static func save(_ payload: CycleUsageRollupPayload, in directory: URL? = nil) throws {
        let url = fileURL(in: directory)
        let fileDirectory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: fileDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(payload)
        try data.write(to: url, options: [.atomic])
    }

    nonisolated static func fileURL(in directory: URL? = nil) -> URL {
        if let directory {
            return directory.appendingPathComponent(fileName, isDirectory: false)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent(bundleDirectory, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }
}

@MainActor
@Observable
final class CycleUsageAggregator {
    private struct BucketKey: Hashable {
        var cycleID: String
        var allowanceSegmentID: String?
        var app: UsageApp
        var model: String
        var speed: UsageSpeed
        var quality: CycleUsageQuality
        var conversationKey: String?
    }

    private var buckets: [BucketKey: CycleUsageBucket] = [:]

    /// 可归入 Codex 周期的其他 Agent。桶的 `app` 记来源 Agent，展示层按设置决定是否计入。
    nonisolated static let otherAgentSourceApps: Set<UsageApp> = [.pi, .opencode, .dsh]

    /// 请求归属的额度周期服务；nil 表示不进入周期统计。
    /// Pi / DSH 只认订阅渠道 `openai-codex/`（Pi 的 `openai/` 是 API Key）；OpenCode 的订阅和 API Key
    /// 都记作 `openai/`，日志无法区分，一律视为订阅。
    nonisolated static func cycleApp(for entry: UsageEntry) -> UsageApp? {
        cycleApp(app: entry.app, model: entry.model)
    }

    /// 同 `cycleApp(for:)`，供只有 (app, model) 的日桶复用（弹出面板的订阅花费）。
    nonisolated static func cycleApp(app: UsageApp, model: String) -> UsageApp? {
        switch app {
        case .codex, .claude:
            return app
        case .pi, .dsh:
            return model.lowercased().hasPrefix("openai-codex/") ? .codex : nil
        case .opencode:
            return model.lowercased().hasPrefix("openai/") ? .codex : nil
        case .cursor:
            return nil
        }
    }

    func load(from snapshot: [CycleUsageBucket]) {
        buckets.removeAll(keepingCapacity: true)
        for bucket in snapshot {
            buckets[key(for: bucket)] = bucket
        }
    }

    func snapshot() -> [CycleUsageBucket] {
        Array(buckets.values)
    }

    @discardableResult
    func ingest(
        entries: [UsageEntry],
        cycles: [QuotaCycleRecord],
        accountSegments: [QuotaCycleAccountSegment],
        quality: CycleUsageQuality = .exact
    ) -> Bool {
        var changed = false
        for entry in entries {
            guard let cycleApp = Self.cycleApp(for: entry),
                  let accountKey = accountKey(
                      for: entry.timestamp,
                      app: cycleApp,
                      segments: accountSegments
                  ) else { continue }
            for kind in [QuotaLimitKind.weekly, .fiveHour] {
                guard let cycle = bestCycle(
                    for: entry.timestamp,
                    app: cycleApp,
                    accountKey: accountKey,
                    kind: kind,
                    cycles: cycles
                ) else { continue }
                let allowanceSegmentID = bestAllowanceSegment(for: entry.timestamp, cycle: cycle)?.id
                add(
                    cycleID: cycle.id,
                    allowanceSegmentID: allowanceSegmentID,
                    app: entry.app,
                    model: entry.model,
                    speed: entry.speed,
                    inputTokens: entry.inputTokens,
                    outputTokens: entry.outputTokens,
                    cacheReadTokens: entry.cacheReadTokens,
                    cacheCreationTokens: entry.cacheCreationTokens,
                    costUSD: entry.costUSD ?? 0,
                    requestCount: entry.requestCount,
                    hasUnpricedUsage: entry.costUSD == nil,
                    quality: quality,
                    conversationKey: entry.conversationKey
                )
                changed = true
            }
        }
        return changed
    }

    func rebuild(
        exactEntries: [UsageEntry],
        cycles: [QuotaCycleRecord],
        accountSegments: [QuotaCycleAccountSegment]
    ) {
        buckets.removeAll(keepingCapacity: true)
        _ = ingest(entries: exactEntries, cycles: cycles, accountSegments: accountSegments)
    }

    /// 受限重建：只重算 `affectedCycleIDs` 内的桶，其余历史桶原样保留。
    /// 用于周期窗口滚动后的增量修正——窗口外的历史归属早已固化，不需要重扫，
    /// 只需把受影响周期内已聚合的数据清掉，用最近窗口扫描出的 entries 重新灌入。
    /// 注意：`exactEntries` 只应包含能归属到受影响周期的条目（调用方按时间范围过滤扫描）。
    /// - Parameter sourceApps: 非 nil 时只清除并重灌这些来源 Agent 的桶；本轮没有重扫的来源原样保留。
    func rebuildRange(
        exactEntries: [UsageEntry],
        cycles: [QuotaCycleRecord],
        accountSegments: [QuotaCycleAccountSegment],
        affectedCycleIDs: Set<String>,
        sourceApps: Set<UsageApp>? = nil
    ) {
        guard !affectedCycleIDs.isEmpty else { return }
        buckets = buckets.filter {
            !affectedCycleIDs.contains($0.value.cycleID)
                || !(sourceApps?.contains($0.value.app) ?? true)
        }
        let affectedCycles = cycles.filter { affectedCycleIDs.contains($0.id) }
        _ = ingest(
            entries: sourceApps.map { apps in exactEntries.filter { apps.contains($0.app) } } ?? exactEntries,
            cycles: affectedCycles,
            accountSegments: accountSegments
        )
    }

    /// 按会话整体替换某个来源的周期桶（OpenCode 每轮给出刷新会话的完整用量，不能累加；
    /// DSH 换 generation、文件被替换或截断时同理）。
    @discardableResult
    func replaceConversations(
        app: UsageApp,
        conversationKeys: Set<String>,
        entries: [UsageEntry],
        cycles: [QuotaCycleRecord],
        accountSegments: [QuotaCycleAccountSegment]
    ) -> Bool {
        guard !conversationKeys.isEmpty else { return false }
        let before = buckets
        buckets = buckets.filter {
            $0.value.app != app || !conversationKeys.contains($0.value.conversationKey ?? "")
        }
        _ = ingest(
            entries: entries.filter { $0.app == app && conversationKeys.contains($0.conversationKey) },
            cycles: cycles,
            accountSegments: accountSegments
        )
        return buckets != before
    }

    /// - Parameter includeOtherAgents: false 时只计周期服务自己的日志（如 Codex 周期只算 Codex 自己的日志）。
    func summaries(
        cycles: [QuotaCycleRecord],
        kind: QuotaLimitKind,
        app: UsageApp?,
        includeOtherAgents: Bool = false,
        now: Date = Date()
    ) -> [CycleUsageSummary] {
        let grouped = Dictionary(grouping: buckets.values, by: \.cycleID)
        return cycles
            .filter { $0.limitKind == kind }
            .filter { app == nil || $0.app == app }
            .map { cycle in
                var totals = UsageTotals.zero
                var currentAllowanceTotals = UsageTotals.zero
                var quality: CycleUsageQuality = cycle.boundaryQuality == .observed ? .exact : .estimated
                for bucket in grouped[cycle.id] ?? []
                    where includeOtherAgents || bucket.app == cycle.app {
                    totals.add(bucket.usageTotals)
                    if bucket.allowanceSegmentID == cycle.latestAllowanceSegment?.id {
                        currentAllowanceTotals.add(bucket.usageTotals)
                    }
                    quality = .worst(quality, bucket.quality)
                }
                if cycle.extraResetCount > 0 {
                    quality = .worst(quality, .estimated)
                }
                if cycle.boundaryQuality == .observed,
                   let firstSampleAt = cycle.firstSampleAt,
                   firstSampleAt.timeIntervalSince(cycle.startAt) > 10 * 60 {
                    quality = .incomplete
                }
                if cycle.isComplete(at: now),
                   let lastSampleAt = cycle.lastSampleAt,
                   cycle.endAt.timeIntervalSince(lastSampleAt) > 10 * 60 {
                    quality = .incomplete
                }
                return CycleUsageSummary(
                    cycle: cycle,
                    totals: totals,
                    currentAllowanceTotals: currentAllowanceTotals,
                    quality: quality
                )
            }
            .sorted { $0.cycle.endAt > $1.cycle.endAt }
    }

    private func bestAllowanceSegment(
        for date: Date,
        cycle: QuotaCycleRecord
    ) -> QuotaCycleAllowanceSegment? {
        cycle.allowanceSegments
            .filter { $0.contains(date) }
            .max { $0.startAt < $1.startAt }
    }

    private func bestCycle(
        for date: Date,
        app: UsageApp,
        accountKey: String,
        kind: QuotaLimitKind,
        cycles: [QuotaCycleRecord]
    ) -> QuotaCycleRecord? {
        cycles
            .filter {
                $0.app == app
                    && $0.accountKey == accountKey
                    && $0.limitKind == kind
                    && $0.contains(date)
            }
            .sorted {
                if $0.boundaryQuality == $1.boundaryQuality { return $0.startAt > $1.startAt }
                return $0.boundaryQuality == .observed
            }
            .first
    }

    private func accountKey(
        for date: Date,
        app: UsageApp,
        segments: [QuotaCycleAccountSegment]
    ) -> String? {
        segments
            .filter { $0.app == app && $0.contains(date) }
            .max { $0.startAt < $1.startAt }?
            .accountKey
    }

    private func add(
        cycleID: String,
        allowanceSegmentID: String?,
        app: UsageApp,
        model: String,
        speed: UsageSpeed,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int,
        costUSD: Decimal,
        requestCount: Int,
        hasUnpricedUsage: Bool,
        quality: CycleUsageQuality,
        conversationKey: String?
    ) {
        let key = BucketKey(
            cycleID: cycleID,
            allowanceSegmentID: allowanceSegmentID,
            app: app,
            model: model,
            speed: speed,
            quality: quality,
            conversationKey: conversationKey
        )
        if var bucket = buckets[key] {
            bucket.inputTokens += inputTokens
            bucket.outputTokens += outputTokens
            bucket.cacheReadTokens += cacheReadTokens
            bucket.cacheCreationTokens += cacheCreationTokens
            bucket.costUSD += costUSD
            bucket.requestCount += requestCount
            bucket.hasUnpricedUsage = bucket.hasUnpricedUsage || hasUnpricedUsage
            buckets[key] = bucket
        } else {
            buckets[key] = CycleUsageBucket(
                cycleID: cycleID,
                allowanceSegmentID: allowanceSegmentID,
                app: app,
                model: model,
                speed: speed,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheCreationTokens: cacheCreationTokens,
                costUSD: costUSD,
                requestCount: requestCount,
                hasUnpricedUsage: hasUnpricedUsage,
                quality: quality,
                conversationKey: conversationKey
            )
        }
    }

    private func key(for bucket: CycleUsageBucket) -> BucketKey {
        BucketKey(
            cycleID: bucket.cycleID,
            allowanceSegmentID: bucket.allowanceSegmentID,
            app: bucket.app,
            model: bucket.model,
            speed: bucket.speed,
            quality: bucket.quality,
            conversationKey: bucket.conversationKey
        )
    }

    /// 某个周期内按来源对话汇总的用量；key 为 nil 的一项是旧版本写入、没有对话信息的桶。
    func usageByConversation(cycleID: String) -> [String?: UsageTotals] {
        var result: [String?: UsageTotals] = [:]
        for bucket in buckets.values where bucket.cycleID == cycleID {
            result[bucket.conversationKey, default: .zero].add(bucket.usageTotals)
        }
        return result
    }
}

private extension CycleUsageBucket {
    var usageTotals: UsageTotals {
        UsageTotals(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens,
            costUSD: costUSD,
            requestCount: requestCount,
            hasUnpricedUsage: hasUnpricedUsage
        )
    }
}
