import Foundation

nonisolated enum QuotaCycleBoundaryQuality: String, Sendable, Codable, Equatable {
    case observed
    case inferred
}

nonisolated enum QuotaAllowanceSegmentStartReason: String, Sendable, Codable, Equatable {
    case initial
    case extraReset
}

nonisolated struct QuotaCycleAllowanceSegment: Sendable, Codable, Equatable, Identifiable {
    var id: String
    var startAt: Date
    var endAt: Date?
    var baselineUsedPercent: Double
    var latestUsedPercent: Double
    var maximumUsedPercent: Double
    var firstSampleAt: Date
    var lastSampleAt: Date
    var startReason: QuotaAllowanceSegmentStartReason

    var observedUsedPercent: Double {
        max(0, maximumUsedPercent - baselineUsedPercent)
    }

    func contains(_ date: Date) -> Bool {
        date >= startAt && (endAt == nil || date < endAt!)
    }
}

nonisolated struct QuotaCycleRecord: Sendable, Codable, Equatable, Identifiable {
    var id: String
    var accountKey: String
    var app: UsageApp
    var limitID: String
    var limitKind: QuotaLimitKind
    var startAt: Date
    var endAt: Date
    var scheduledEndAt: Date
    var firstSampleAt: Date?
    var lastSampleAt: Date?
    var latestUsedPercent: Double
    var allowanceSegments: [QuotaCycleAllowanceSegment]
    var source: QuotaSnapshotSource
    var boundaryQuality: QuotaCycleBoundaryQuality

    private enum CodingKeys: String, CodingKey {
        case id, accountKey, app, limitID, limitKind
        case startAt, endAt, scheduledEndAt, firstSampleAt, lastSampleAt
        case latestUsedPercent, maximumUsedPercent, allowanceSegments
        case source, boundaryQuality
    }

    init(
        id: String,
        accountKey: String,
        app: UsageApp,
        limitID: String,
        limitKind: QuotaLimitKind,
        startAt: Date,
        endAt: Date,
        scheduledEndAt: Date,
        firstSampleAt: Date?,
        lastSampleAt: Date?,
        latestUsedPercent: Double,
        allowanceSegments: [QuotaCycleAllowanceSegment],
        source: QuotaSnapshotSource,
        boundaryQuality: QuotaCycleBoundaryQuality
    ) {
        self.id = id
        self.accountKey = accountKey
        self.app = app
        self.limitID = limitID
        self.limitKind = limitKind
        self.startAt = startAt
        self.endAt = endAt
        self.scheduledEndAt = scheduledEndAt
        self.firstSampleAt = firstSampleAt
        self.lastSampleAt = lastSampleAt
        self.latestUsedPercent = latestUsedPercent
        self.allowanceSegments = allowanceSegments
        self.source = source
        self.boundaryQuality = boundaryQuality
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        accountKey = try c.decode(String.self, forKey: .accountKey)
        app = try c.decode(UsageApp.self, forKey: .app)
        limitID = try c.decode(String.self, forKey: .limitID)
        limitKind = try c.decode(QuotaLimitKind.self, forKey: .limitKind)
        startAt = try c.decode(Date.self, forKey: .startAt)
        endAt = try c.decode(Date.self, forKey: .endAt)
        scheduledEndAt = try c.decodeIfPresent(Date.self, forKey: .scheduledEndAt) ?? endAt
        firstSampleAt = try c.decodeIfPresent(Date.self, forKey: .firstSampleAt)
        lastSampleAt = try c.decodeIfPresent(Date.self, forKey: .lastSampleAt)
        let legacyMaximum = try c.decodeIfPresent(Double.self, forKey: .maximumUsedPercent)
        latestUsedPercent = try c.decodeIfPresent(Double.self, forKey: .latestUsedPercent)
            ?? legacyMaximum
            ?? 0
        allowanceSegments = try c.decodeIfPresent(
            [QuotaCycleAllowanceSegment].self,
            forKey: .allowanceSegments
        ) ?? [QuotaCycleAllowanceSegment(
            id: "\(id)|allowance|legacy",
            startAt: startAt,
            endAt: nil,
            baselineUsedPercent: 0,
            latestUsedPercent: latestUsedPercent,
            maximumUsedPercent: legacyMaximum ?? latestUsedPercent,
            firstSampleAt: firstSampleAt ?? startAt,
            lastSampleAt: lastSampleAt ?? firstSampleAt ?? startAt,
            startReason: .initial
        )]
        source = try c.decode(QuotaSnapshotSource.self, forKey: .source)
        boundaryQuality = try c.decode(QuotaCycleBoundaryQuality.self, forKey: .boundaryQuality)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(accountKey, forKey: .accountKey)
        try c.encode(app, forKey: .app)
        try c.encode(limitID, forKey: .limitID)
        try c.encode(limitKind, forKey: .limitKind)
        try c.encode(startAt, forKey: .startAt)
        try c.encode(endAt, forKey: .endAt)
        try c.encode(scheduledEndAt, forKey: .scheduledEndAt)
        try c.encodeIfPresent(firstSampleAt, forKey: .firstSampleAt)
        try c.encodeIfPresent(lastSampleAt, forKey: .lastSampleAt)
        try c.encode(latestUsedPercent, forKey: .latestUsedPercent)
        try c.encode(allowanceSegments, forKey: .allowanceSegments)
        try c.encode(source, forKey: .source)
        try c.encode(boundaryQuality, forKey: .boundaryQuality)
    }

    var extraResetCount: Int {
        allowanceSegments.filter { $0.startReason == .extraReset }.count
    }

    var totalObservedUsedPercent: Double {
        allowanceSegments.reduce(0) { $0 + $1.observedUsedPercent }
    }

    /// 历史表展示的服务端额度消耗：初始额度取最高一次，重置后的每个新额度段再累加。
    /// 旧版重复 initial 段只取最大值，避免把迁移残留重复计算成 200%。
    var reportedUsedPercent: Double {
        let initialMaximum = allowanceSegments
            .filter { $0.startReason == .initial }
            .map { max(0, min(100, $0.maximumUsedPercent)) }
            .max() ?? max(0, latestUsedPercent)
        let extraResetMaximum = allowanceSegments
            .filter { $0.startReason == .extraReset }
            .reduce(0) { partial, segment in
                partial + max(0, min(100, segment.maximumUsedPercent))
            }
        return initialMaximum + extraResetMaximum
    }

    var latestAllowanceSegment: QuotaCycleAllowanceSegment? {
        allowanceSegments.max { $0.startAt < $1.startAt }
    }

    func contains(_ date: Date) -> Bool {
        date >= startAt && date < endAt
    }

    func isCurrent(at date: Date = Date()) -> Bool {
        contains(date)
    }

    func isComplete(at date: Date = Date()) -> Bool {
        endAt <= date
    }
}

nonisolated struct QuotaCycleAccountSegment: Sendable, Codable, Equatable, Identifiable {
    var id: String
    var accountKey: String
    var app: UsageApp
    var startAt: Date
    var endAt: Date?

    func contains(_ date: Date) -> Bool {
        date >= startAt && (endAt == nil || date < endAt!)
    }
}

nonisolated struct QuotaCyclePayload: Sendable, Codable, Equatable {
    static let currentVersion = 4

    var version: Int = Self.currentVersion
    var trackingStartedAt: Date = Date()
    var records: [QuotaCycleRecord] = []
    var accountSegments: [QuotaCycleAccountSegment] = []
}

enum QuotaCycleStore {
    nonisolated private static let fileName = "quota-cycle-history.json"
    nonisolated private static let bundleDirectory = "CCBar"
    nonisolated private static let extraResetMinimumDrop = 10.0
    nonisolated private static let nearZeroUsedPercent = 2.0
    nonisolated private static let nearZeroMinimumDrop = 3.0
    /// Codex 服务端返回的 reset_at 有秒级抖动（实测 1~3 秒）。周期 ID 内含秒级
    /// 时间戳，抖动会让精确 ID 匹配落空并误建重复周期；此容差用于把同一次重置
    /// 的相邻采样归并到同一条记录。
    nonisolated private static let resetJitterTolerance: TimeInterval = 60
    /// 活跃周期 resets_at 分钟级漂移时允许继续命中原记录；
    /// 新旧周期边界差超过半小时则必须视为真实滚动，防止低用量提前重置串期。
    nonisolated private static let activeResetDriftTolerance: TimeInterval = 30 * 60
    /// 活跃周期的 scheduledEndAt 抖动容差。服务端每次返回的 resets_at 都会小幅漂移
    /// （实测 Claude 亚秒级、Codex 1~3 秒），若逐次写入记录，`cycleUsagePartition`
    /// 会把它当成周期边界滚动，触发本不该发生的全量重建。容差内保留既有边界，
    /// 取值远小于真实窗口长度（最短 5 小时），不影响真实滚动的识别。
    nonisolated private static let scheduledEndJitterTolerance: TimeInterval = 5
    /// 半开区间收口后，相邻片段边界可能刚好相差 1 秒。
    nonisolated private static let resetDriftAdjacencyTolerance: TimeInterval = 1
    /// 短于此长度的记录视为被 closeOverlappingCycles 截断的残片（正常窗口最短 5 小时）。
    nonisolated private static let minimumShardDuration: TimeInterval = 60
    /// 判定「重复周期记录」所需的最小重叠时长。相邻的两个真实周期，其边界分别由
    /// 各自采样时刻的 resets_at 推出，两侧抖动叠加会让边界错开亚秒到数秒（实测
    /// Claude 0.2~0.4 秒、Codex 1~3 秒），这只是边界毛刺，不是重复记录。而真正的
    /// 重复来自同一周期的 resetAt 漂移，重叠接近整个窗口（≥5 小时），两者量级相差
    /// 数千倍。低于此阈值不做去重——`merging` 只保留 base 的 startAt / endAt，
    /// 一旦误判，被吞记录覆盖的整段周期历史会永久丢失且无法从日志重建。
    nonisolated private static let overlapDeduplicationMinimum: TimeInterval = 60
    /// 同窗对齐容差：漂移残片（秒级抖动 / 低用量分钟级漂移）与所属周期的
    /// scheduledEndAt 只差在容差量级；服务端窗口制式换档（如周四 11:34 → 周一 09:01）
    /// 让相邻片段差出数天。两处合并逻辑都以它判定「同窗」，换档片段保留为独立周期。
    nonisolated private static let windowAlignmentTolerance: TimeInterval = 30 * 60
    /// 周期时长超过「窗口长度 × 该系数」视为被漂移/合并污染的超长记录，
    /// 启动与每次采样时按「恢复时刻 − 窗口长度」回写起点。正常 7 天窗口只会
    /// 有亚秒~分钟级抖动，系数 1.15 绝不误伤。
    nonisolated private static let oversizedCycleFactor = 1.15

    nonisolated static func load() -> (payload: QuotaCyclePayload, repairedCycleIDs: Set<String>) {
        let url = fileURL()
        guard let data = try? Data(contentsOf: url),
              var payload = try? JSONDecoder().decode(QuotaCyclePayload.self, from: data),
              payload.version == QuotaCyclePayload.currentVersion || payload.version == 2 || payload.version == 3
        else {
            return (QuotaCyclePayload(), [])
        }
        // v4 之后仍可能收到会缓慢漂移的 Codex resetAt。每次载入都做幂等清理，
        // 让已经落盘的短周期残片也能在升级后立即恢复成一个真实周期。
        payload = cleaningUpLegacyPayload(payload)
        payload.version = QuotaCyclePayload.currentVersion
        return repairingOversizedCycles(payload)
    }

    nonisolated static func save(_ payload: QuotaCyclePayload) throws {
        let url = fileURL()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(payload)
        try data.write(to: url, options: [.atomic])
    }

    /// 旧版 Claude 周期和账号段无法区分真实账号；首次取得当前账号键时
    /// 将旧常量键归入当前账号。保留 cycle / segment ID，避免已有 rollup 失去关联。
    nonisolated static func migratingLegacyClaudeAccountKey(
        _ payload: QuotaCyclePayload,
        to accountKey: String
    ) -> QuotaCyclePayload {
        let legacyKey = "claude:primary"
        guard accountKey != legacyKey else { return payload }
        var next = payload
        for index in next.records.indices
            where next.records[index].app == .claude
                && next.records[index].accountKey == legacyKey
        {
            next.records[index].accountKey = accountKey
        }
        for index in next.accountSegments.indices
            where next.accountSegments[index].app == .claude
                && next.accountSegments[index].accountKey == legacyKey
        {
            next.accountSegments[index].accountKey = accountKey
        }
        return next
    }

    /// 历史数据可能因 reset_at 漂移产生同一周期的重复记录：
    /// 部分记录被 closeOverlappingCycles 截断成残片，另有部分完整周期彼此重叠。
    /// 清理时删除秒级残片、合并重叠记录，并把「额度未回落、只是 resetAt 向后移动」
    /// 的相邻片段重新接回同一周期。真实额度回落仍保留为新周期。
    nonisolated static func cleaningUpLegacyPayload(_ payload: QuotaCyclePayload) -> QuotaCyclePayload {
        var next = payload
        next.records = next.records.filter { record in
            record.endAt.timeIntervalSince(record.startAt) >= Self.minimumShardDuration
        }
        next.records = Self.deduplicatingOverlapping(next.records)
        next.records = Self.coalescingResetDriftFragments(next.records)
        return next
    }

    /// 超长记录自检：正常周期时长 ≈ 窗口长度（±漂移抖动）；若漂移累积 / 换档合并
    /// 把记录拉长超过 `窗口 × oversizedCycleFactor`，按「恢复时刻 − 窗口长度」回写
    /// 起点。返回值中的 `repairedCycleIDs` 供调用方触发聚合重算（起点变了，
    /// 旧 rollup 桶已按旧窗口切分，必须重灌）。
    nonisolated static func repairingOversizedCycles(
        _ payload: QuotaCyclePayload
    ) -> (payload: QuotaCyclePayload, repairedCycleIDs: Set<String>) {
        var next = payload
        var repaired = Set<String>()
        for index in next.records.indices {
            let record = next.records[index]
            guard let seconds = windowSeconds(forKind: record.limitKind),
                  seconds > 0
            else { continue }
            let duration = record.endAt.timeIntervalSince(record.startAt)
            guard duration > TimeInterval(seconds) * Self.oversizedCycleFactor else { continue }
            let fixedStart = record.scheduledEndAt.addingTimeInterval(-TimeInterval(seconds))
            guard fixedStart > record.startAt else { continue }
            next.records[index].startAt = fixedStart
            if let firstSampleAt = next.records[index].firstSampleAt, firstSampleAt < fixedStart {
                next.records[index].firstSampleAt = fixedStart
            }
            repaired.insert(record.id)
        }
        return (next, repaired)
    }

    /// 同窗对齐校验：只有恢复时刻差在容差内才是同一窗口的漂移残片；
    /// 服务端制式换档（数天级）的相邻片段不得合并。
    nonisolated private static func sameWindowAlignment(
        _ a: QuotaCycleRecord,
        _ b: QuotaCycleRecord
    ) -> Bool {
        abs(a.scheduledEndAt.timeIntervalSince(b.scheduledEndAt))
            <= Self.windowAlignmentTolerance
    }

    nonisolated private static func coalescingResetDriftFragments(
        _ records: [QuotaCycleRecord]
    ) -> [QuotaCycleRecord] {
        let grouped = Dictionary(grouping: records) { record in
            "\(record.accountKey)|\(record.app.rawValue)|\(record.limitKind.rawValue)|\(record.limitID)"
        }
        var result: [QuotaCycleRecord] = []
        for group in grouped.values {
            let sorted = group.sorted { lhs, rhs in
                if lhs.startAt == rhs.startAt { return lhs.endAt < rhs.endAt }
                return lhs.startAt < rhs.startAt
            }
            guard var current = sorted.first else { continue }
            for next in sorted.dropFirst() {
                if isResetDriftContinuation(earlier: current, later: next) {
                    current = mergingResetDriftContinuation(earlier: current, later: next)
                } else {
                    result.append(current)
                    current = next
                }
            }
            result.append(current)
        }
        return result.sorted { lhs, rhs in
            if lhs.endAt == rhs.endAt { return lhs.id < rhs.id }
            return lhs.endAt > rhs.endAt
        }
    }

    nonisolated private static func isResetDriftContinuation(
        earlier: QuotaCycleRecord,
        later: QuotaCycleRecord
    ) -> Bool {
        let isAdjacent = abs(earlier.endAt.timeIntervalSince(later.startAt))
            <= Self.resetDriftAdjacencyTolerance
        // 真实 resetAt 漂移造成的残片会被提前截断数分钟；
        // 相邻真实周期只会因独立的秒级边界抖动差 1~3 秒。
        let truncation = earlier.scheduledEndAt.timeIntervalSince(earlier.endAt)
        let isMeaningfullyTruncated = truncation > Self.resetJitterTolerance
        let usageDidNotReset = !isExtraReset(
            previousUsedPercent: earlier.latestUsedPercent,
            usedPercent: later.latestUsedPercent
        )
        // 同窗漂移的恢复时刻差在容差内；服务端制式换档（数天级）不得归并成伪长周期。
        let sameWindowAt = sameWindowAlignment(earlier, later)
        return isAdjacent && isMeaningfullyTruncated && usageDidNotReset && sameWindowAt
    }

    nonisolated private static func mergingResetDriftContinuation(
        earlier: QuotaCycleRecord,
        later: QuotaCycleRecord
    ) -> QuotaCycleRecord {
        // 保留较新的 ID，让当前 rollup 与后续采样继续命中同一条记录；边界则向前
        // 扩回第一个片段，额度段也在伪切点处合并，避免把同一额度误当重置。
        var merged = later
        // 恢复时刻纪元取最早片段（漂移后片段会越记越晚），否则链式合并时后段
        // 的漂移值会覆盖原始窗口起点。
        merged.scheduledEndAt = min(earlier.scheduledEndAt, later.scheduledEndAt)
        if let seconds = windowSeconds(forKind: merged.limitKind) {
            merged.startAt = merged.scheduledEndAt.addingTimeInterval(-TimeInterval(seconds))
        } else {
            merged.startAt = min(earlier.startAt, later.startAt)
        }
        if let earlierFirst = earlier.firstSampleAt {
            merged.firstSampleAt = min(merged.firstSampleAt ?? earlierFirst, earlierFirst)
        }
        if let earlierLast = earlier.lastSampleAt {
            merged.lastSampleAt = max(merged.lastSampleAt ?? earlierLast, earlierLast)
        }
        merged.allowanceSegments = mergingContinuationAllowanceSegments(
            earlier.allowanceSegments,
            later.allowanceSegments
        )
        merged.source = preferredSource(earlier.source, later.source)
        if earlier.boundaryQuality == .observed {
            merged.boundaryQuality = .observed
        }
        return merged
    }

    nonisolated private static func mergingContinuationAllowanceSegments(
        _ earlier: [QuotaCycleAllowanceSegment],
        _ later: [QuotaCycleAllowanceSegment]
    ) -> [QuotaCycleAllowanceSegment] {
        guard var earlierLast = earlier.last, var laterFirst = later.first else {
            return earlier + later
        }
        earlierLast.id = laterFirst.id
        earlierLast.endAt = laterFirst.endAt
        earlierLast.latestUsedPercent = laterFirst.latestUsedPercent
        earlierLast.maximumUsedPercent = max(
            earlierLast.maximumUsedPercent,
            laterFirst.maximumUsedPercent
        )
        earlierLast.firstSampleAt = min(earlierLast.firstSampleAt, laterFirst.firstSampleAt)
        earlierLast.lastSampleAt = max(earlierLast.lastSampleAt, laterFirst.lastSampleAt)
        laterFirst = earlierLast
        return Array(earlier.dropLast()) + [laterFirst] + Array(later.dropFirst())
    }

    nonisolated private static func deduplicatingOverlapping(_ records: [QuotaCycleRecord]) -> [QuotaCycleRecord] {
        var result: [QuotaCycleRecord] = []
        var consumed = Set<String>()
        for record in records.sorted(by: { $0.endAt > $1.endAt }) {
            guard !consumed.contains(record.id) else { continue }
            var merged = record
            consumed.insert(record.id)
            for other in records where !consumed.contains(other.id) {
                // 同窗对齐：同一周期的漂移副本恢复时刻几乎相同；不同窗口（换档）的
                // 重叠是两条独立周期，去重合并会把历史吞成伪长周期，必须拒绝。
                guard other.accountKey == merged.accountKey,
                      other.app == merged.app,
                      other.limitKind == merged.limitKind,
                      intervalsOverlap(merged, other),
                      sameWindowAlignment(merged, other)
                else { continue }
                consumed.insert(other.id)
                merged = merging(base: merged, other: other)
            }
            result.append(merged)
        }
        return result
    }

    nonisolated private static func intervalsOverlap(_ a: QuotaCycleRecord, _ b: QuotaCycleRecord) -> Bool {
        let overlap = min(a.endAt, b.endAt).timeIntervalSince(max(a.startAt, b.startAt))
        return overlap > Self.overlapDeduplicationMinimum
    }

    nonisolated private static func merging(base: QuotaCycleRecord, other: QuotaCycleRecord) -> QuotaCycleRecord {
        var merged = base
        if let otherFirst = other.firstSampleAt {
            merged.firstSampleAt = min(merged.firstSampleAt ?? otherFirst, otherFirst)
        }
        if let otherLast = other.lastSampleAt {
            merged.lastSampleAt = max(merged.lastSampleAt ?? otherLast, otherLast)
        }
        if let baseLast = merged.lastSampleAt,
           let otherLast = other.lastSampleAt,
           otherLast > baseLast
        {
            merged.latestUsedPercent = other.latestUsedPercent
        }
        // 恢复时刻纪元取最早片段、起点以「恢复时刻 − 窗口长度」反推：
        // 重复记录的边界来自同一周期的 resetAt 漂移视图，各片只差秒/分钟级，
        // 最早者对应窗口起点。
        merged.scheduledEndAt = min(merged.scheduledEndAt, other.scheduledEndAt)
        if let seconds = windowSeconds(forKind: merged.limitKind) {
            merged.startAt = merged.scheduledEndAt.addingTimeInterval(-TimeInterval(seconds))
        }
        merged.allowanceSegments = mergedAllowanceSegments(merged.allowanceSegments, other.allowanceSegments)
        merged.source = preferredSource(merged.source, other.source)
        if other.boundaryQuality == .observed {
            merged.boundaryQuality = .observed
        }
        return merged
    }

    nonisolated private static func mergedAllowanceSegments(
        _ a: [QuotaCycleAllowanceSegment],
        _ b: [QuotaCycleAllowanceSegment]
    ) -> [QuotaCycleAllowanceSegment] {
        let all = (a + b).sorted { $0.startAt < $1.startAt }
        var result: [QuotaCycleAllowanceSegment] = []
        for segment in all {
            if var last = result.last {
                if abs(last.startAt.timeIntervalSince(segment.startAt)) < 1 {
                    if segment.lastSampleAt >= last.lastSampleAt {
                        result[result.count - 1] = segment
                    }
                    continue
                }
                if last.endAt == nil {
                    result[result.count - 1].endAt = segment.startAt
                }
            }
            result.append(segment)
        }
        return result
    }

    /// 只记录主账号的标准 5 小时 / 周窗口；导入账号和模型专项窗口由调用方排除。
    nonisolated static func record(
        payload: QuotaCyclePayload,
        accountKey: String,
        app: UsageApp,
        snapshot: QuotaSnapshot,
        source: QuotaSnapshotSource,
        sampledAt: Date
    ) -> QuotaCyclePayload {
        var next = payload
        updateAccountSegments(
            in: &next,
            accountKey: accountKey,
            app: app,
            sampledAt: sampledAt
        )
        let limits = [snapshot.primaryLimit, snapshot.secondaryLimit].compactMap { $0 }
        // 不按 is_active 过滤：is_active 只表示「当前哪个限制在起约束作用」，
        // 非当前约束的窗口（如 5 小时未满时的 weekly）同样返回有效的 percent / resets_at，
        // 过滤会导致周期记录停更，页面停留在旧值。
        for limit in limits where limit.kind == .fiveHour || limit.kind == .weekly {
            guard let scheduledEndAt = limit.window.resetsAt,
                  let seconds = windowSeconds(for: limit),
                  seconds > 0
            else { continue }

            let startAt = scheduledEndAt.addingTimeInterval(-TimeInterval(seconds))
            let usedPercent = normalizedPercent(limit.window.usedPercent)
            let boundaryQuality: QuotaCycleBoundaryQuality = limit.window.windowSeconds == nil
                ? .inferred
                : .observed
            let id = cycleID(
                accountKey: accountKey,
                limitID: limit.id,
                endAt: scheduledEndAt
            )
            let matchIndex = next.records.firstIndex(where: { $0.id == id })
                ?? next.records.firstIndex(where: { candidate in
                    candidate.accountKey == accountKey
                        && candidate.app == app
                        && candidate.limitKind == limit.kind
                        && candidate.endAt > sampledAt
                        && abs(candidate.endAt.timeIntervalSince(scheduledEndAt)) < Self.resetJitterTolerance
                })
                ?? next.records.indices
                    .filter { index in
                        let candidate = next.records[index]
                        return candidate.accountKey == accountKey
                            && candidate.app == app
                            && candidate.limitKind == limit.kind
                            && candidate.endAt > sampledAt
                            && abs(candidate.scheduledEndAt.timeIntervalSince(scheduledEndAt))
                                <= Self.activeResetDriftTolerance
                            && !isExtraReset(
                                previousUsedPercent: candidate.latestUsedPercent,
                                usedPercent: usedPercent
                            )
                    }
                    .max { lhs, rhs in
                        let lhsSample = next.records[lhs].lastSampleAt ?? .distantPast
                        let rhsSample = next.records[rhs].lastSampleAt ?? .distantPast
                        return lhsSample < rhsSample
                    }
                // 采样时刻已晚于旧周期结束、但服务端仍返回漂移的旧窗口 resets_at
                // （与旧记录 endAt 差在容差内、用量未回落）时，这是同一周期的漂移视图：
                // 更新该记录而不是新建，避免 closeOverlappingCycles 把它误砍成残片。
                // 真实滚动后新旧周期起点相差整个窗口（5 小时 / 7 天），远大于容差，不会误匹配。
                ?? next.records.indices
                    .filter { index in
                        let candidate = next.records[index]
                        return candidate.accountKey == accountKey
                            && candidate.app == app
                            && candidate.limitKind == limit.kind
                            && abs(candidate.endAt.timeIntervalSince(scheduledEndAt)) < Self.resetJitterTolerance
                            && !isExtraReset(
                                previousUsedPercent: candidate.latestUsedPercent,
                                usedPercent: usedPercent
                            )
                    }
                    .max { lhs, rhs in
                        let lhsSample = next.records[lhs].lastSampleAt ?? .distantPast
                        let rhsSample = next.records[rhs].lastSampleAt ?? .distantPast
                        return lhsSample < rhsSample
                    }
            if let index = matchIndex {
                let wasActive = next.records[index].endAt > sampledAt
                next.records[index].limitKind = limit.kind
                next.records[index].startAt = min(next.records[index].startAt, startAt)
                // 容差内的 resets_at 漂移视为同一边界，保留既有值；只有真正滚动才写入新边界。
                if abs(scheduledEndAt.timeIntervalSince(next.records[index].scheduledEndAt))
                    >= Self.scheduledEndJitterTolerance
                {
                    next.records[index].scheduledEndAt = scheduledEndAt
                }
                let stableEndAt = next.records[index].scheduledEndAt
                next.records[index].endAt = wasActive
                    ? stableEndAt
                    : min(next.records[index].endAt, stableEndAt)
                next.records[index].firstSampleAt = min(next.records[index].firstSampleAt ?? sampledAt, sampledAt)
                next.records[index].lastSampleAt = max(next.records[index].lastSampleAt ?? sampledAt, sampledAt)
                updateAllowanceSegments(
                    record: &next.records[index],
                    usedPercent: usedPercent,
                    sampledAt: sampledAt,
                    trackingStartedAt: next.trackingStartedAt
                )
                next.records[index].source = preferredSource(next.records[index].source, source)
                if boundaryQuality == .observed {
                    next.records[index].boundaryQuality = .observed
                }
            } else {
                closeOverlappingCycles(
                    in: &next,
                    accountKey: accountKey,
                    app: app,
                    limitKind: limit.kind,
                    newCycleStartAt: startAt
                )
                next.records.append(QuotaCycleRecord(
                    id: id,
                    accountKey: accountKey,
                    app: app,
                    limitID: limit.id,
                    limitKind: limit.kind,
                    startAt: startAt,
                    endAt: scheduledEndAt,
                    scheduledEndAt: scheduledEndAt,
                    firstSampleAt: sampledAt,
                    lastSampleAt: sampledAt,
                    latestUsedPercent: usedPercent,
                    allowanceSegments: [initialAllowanceSegment(
                        cycleID: id,
                        cycleStartAt: startAt,
                        trackingStartedAt: next.trackingStartedAt,
                        usedPercent: usedPercent,
                        sampledAt: sampledAt
                    )],
                    source: source,
                    boundaryQuality: boundaryQuality
                ))
            }
        }
        next.records.sort { lhs, rhs in
            if lhs.endAt == rhs.endAt { return lhs.id < rhs.id }
            return lhs.endAt > rhs.endAt
        }
        // 超长自检：漂移累积/换档合并可能把周期拉长，按窗口语义回写起点；
        // 起点变化会让调用方的 partition 比对触发受限重建，无需额外钩子。
        return repairingOversizedCycles(next).payload
    }

    nonisolated private static func updateAllowanceSegments(
        record: inout QuotaCycleRecord,
        usedPercent: Double,
        sampledAt: Date,
        trackingStartedAt: Date
    ) {
        let previousUsedPercent = record.latestUsedPercent
        record.latestUsedPercent = usedPercent
        guard !record.allowanceSegments.isEmpty else {
            record.allowanceSegments = [initialAllowanceSegment(
                cycleID: record.id,
                cycleStartAt: record.startAt,
                trackingStartedAt: trackingStartedAt,
                usedPercent: usedPercent,
                sampledAt: sampledAt
            )]
            return
        }

        if isExtraReset(previousUsedPercent: previousUsedPercent, usedPercent: usedPercent) {
            let lastIndex = record.allowanceSegments.index(before: record.allowanceSegments.endIndex)
            record.allowanceSegments[lastIndex].endAt = sampledAt
            record.allowanceSegments.append(QuotaCycleAllowanceSegment(
                id: allowanceSegmentID(cycleID: record.id, startAt: sampledAt),
                startAt: sampledAt,
                endAt: nil,
                baselineUsedPercent: usedPercent,
                latestUsedPercent: usedPercent,
                maximumUsedPercent: usedPercent,
                firstSampleAt: sampledAt,
                lastSampleAt: sampledAt,
                startReason: .extraReset
            ))
            return
        }

        let lastIndex = record.allowanceSegments.index(before: record.allowanceSegments.endIndex)
        record.allowanceSegments[lastIndex].latestUsedPercent = usedPercent
        record.allowanceSegments[lastIndex].maximumUsedPercent = max(
            record.allowanceSegments[lastIndex].maximumUsedPercent,
            usedPercent
        )
        record.allowanceSegments[lastIndex].lastSampleAt = max(
            record.allowanceSegments[lastIndex].lastSampleAt,
            sampledAt
        )
    }

    nonisolated private static func initialAllowanceSegment(
        cycleID: String,
        cycleStartAt: Date,
        trackingStartedAt: Date,
        usedPercent: Double,
        sampledAt: Date
    ) -> QuotaCycleAllowanceSegment {
        let trackedFromCycleStart = trackingStartedAt <= cycleStartAt
        let startAt = trackedFromCycleStart ? cycleStartAt : sampledAt
        let baselineUsedPercent = trackedFromCycleStart ? 0 : usedPercent
        return QuotaCycleAllowanceSegment(
            id: allowanceSegmentID(cycleID: cycleID, startAt: startAt),
            startAt: startAt,
            endAt: nil,
            baselineUsedPercent: baselineUsedPercent,
            latestUsedPercent: usedPercent,
            maximumUsedPercent: usedPercent,
            firstSampleAt: sampledAt,
            lastSampleAt: sampledAt,
            startReason: .initial
        )
    }

    nonisolated private static func closeOverlappingCycles(
        in payload: inout QuotaCyclePayload,
        accountKey: String,
        app: UsageApp,
        limitKind: QuotaLimitKind,
        newCycleStartAt: Date
    ) {
        for index in payload.records.indices {
            guard payload.records[index].accountKey == accountKey,
                  payload.records[index].app == app,
                  payload.records[index].limitKind == limitKind,
                  payload.records[index].startAt < newCycleStartAt,
                  payload.records[index].endAt > newCycleStartAt
            else { continue }
            // 新周期起点与旧记录起点几乎重合（同一周期的 resets_at 漂移视图）时跳过收口，
            // 避免把整段真实周期误砍成秒级残片。真实滚动时新起点与旧起点相差整个窗口，不会命中。
            guard abs(payload.records[index].startAt.timeIntervalSince(newCycleStartAt))
                    >= Self.resetJitterTolerance
            else { continue }

            // 相邻真实周期的起止边界由各自 resets_at 推导，可能产生数秒重叠。
            // 这种抖动不是真实重叠，不应把旧周期截短成后续清理的合并候选。
            let overlap = payload.records[index].endAt.timeIntervalSince(newCycleStartAt)
            guard overlap > Self.resetJitterTolerance else { continue }

            payload.records[index].endAt = newCycleStartAt
            if let segmentIndex = payload.records[index].allowanceSegments.indices.last,
               payload.records[index].allowanceSegments[segmentIndex].endAt == nil
            {
                payload.records[index].allowanceSegments[segmentIndex].endAt = newCycleStartAt
            }
        }
    }

    nonisolated private static func isExtraReset(
        previousUsedPercent: Double,
        usedPercent: Double
    ) -> Bool {
        let drop = previousUsedPercent - usedPercent
        return drop >= extraResetMinimumDrop
            || (usedPercent <= nearZeroUsedPercent && drop >= nearZeroMinimumDrop)
    }

    nonisolated private static func normalizedPercent(_ value: Double) -> Double {
        max(0, min(100, value))
    }

    nonisolated private static func allowanceSegmentID(cycleID: String, startAt: Date) -> String {
        "\(cycleID)|allowance|\(Int(startAt.timeIntervalSince1970.rounded()))"
    }

    nonisolated private static func updateAccountSegments(
        in payload: inout QuotaCyclePayload,
        accountKey: String,
        app: UsageApp,
        sampledAt: Date
    ) {
        if let activeIndex = payload.accountSegments.lastIndex(where: { $0.app == app && $0.endAt == nil }) {
            if payload.accountSegments[activeIndex].accountKey == accountKey {
                return
            }
            payload.accountSegments[activeIndex].endAt = sampledAt
        }

        let isFirstAccount = !payload.accountSegments.contains { $0.app == app }
        let startAt = isFirstAccount ? payload.trackingStartedAt : sampledAt
        payload.accountSegments.append(QuotaCycleAccountSegment(
            id: "\(app.rawValue)|\(accountKey)|\(Int(sampledAt.timeIntervalSince1970.rounded()))",
            accountKey: accountKey,
            app: app,
            startAt: startAt,
            endAt: nil
        ))
    }

    nonisolated static func fileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent(bundleDirectory, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    nonisolated private static func windowSeconds(forKind kind: QuotaLimitKind) -> Int? {
        switch kind {
        case .fiveHour: return 5 * 60 * 60
        case .weekly: return 7 * 24 * 60 * 60
        case .modelWeekly, .unknown: return nil
        }
    }

    nonisolated private static func windowSeconds(for limit: QuotaLimit) -> Int? {
        if let seconds = limit.window.windowSeconds { return seconds }
        return windowSeconds(forKind: limit.kind)
    }

    nonisolated private static func cycleID(
        accountKey: String,
        limitID: String,
        endAt: Date
    ) -> String {
        let resetSecond = Int(endAt.timeIntervalSince1970.rounded())
        return "\(accountKey)|\(limitID)|\(resetSecond)"
    }

    /// 从 `cycleID` 反解该周期的重置时刻。ID 形如 `accountKey|limitID|resetSecond`，
    /// 末段是 `endAt` 的 epoch 秒（见 `cycleID(accountKey:limitID:endAt:)`）。
    /// 周期记录被 `cleaningUpLegacyPayload` 合并 / 剔除后，用量 rollup 里会残留只剩
    /// cycleID 的孤儿桶；用它把这段用量定位到时间轴上，判断能否由受限重建补回。
    nonisolated static func resetInstant(fromCycleID id: String) -> Date? {
        guard let second = id.split(separator: "|").last.flatMap({ Int($0) }) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(second))
    }

    nonisolated private static func preferredSource(
        _ current: QuotaSnapshotSource,
        _ incoming: QuotaSnapshotSource
    ) -> QuotaSnapshotSource {
        func rank(_ source: QuotaSnapshotSource) -> Int {
            switch source {
            case .api: return 4
            case .cliFallback: return 3
            case .local: return 2
            case .cache: return 1
            }
        }
        return rank(incoming) >= rank(current) ? incoming : current
    }
}
