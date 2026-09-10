import CryptoKit
import Foundation

nonisolated enum QuotaHistoryAccountKind: String, Sendable, Codable {
    case codexPrimary
    case codexImported
    case claudePrimary
    case antigravityPrimary
}

nonisolated struct QuotaHistorySample: Sendable, Equatable, Codable {
    var accountKey: String
    var app: QuotaApp
    var kind: QuotaHistoryAccountKind
    var sampledAt: Date
    var limitID: String
    var limitKind: QuotaLimitKind
    var remainingPercent: Int
    var resetsAt: Date?
}

nonisolated struct QuotaChangeEvent: Sendable, Equatable, Codable, Identifiable {
    var id: String
    var accountKey: String
    var app: QuotaApp
    var kind: QuotaHistoryAccountKind
    var sampledAt: Date
    var limitID: String
    var limitKind: QuotaLimitKind
    var beforeRemainingPercent: Int
    var afterRemainingPercent: Int
    var deltaPercent: Int
    var resetsAt: Date?
}

/// 时间线的展示点。变动事件与最新采样分开建模：额度跨周期重置时不应伪造消耗事件，
/// 但最新采样仍必须出现在时间线上，避免界面停在上一周期的最后一次变动。
nonisolated struct QuotaTimelineEntry: Sendable, Equatable, Identifiable {
    enum Source: Sendable, Equatable {
        case change
        case sample
    }

    var id: String
    var source: Source
    var sampledAt: Date
    var remainingPercent: Int
    /// 仅真实变动事件有差值；普通刷新采样显示为「—」。
    var deltaPercent: Int?
    var resetsAt: Date?
    /// 同一段时间线内的额度窗口序号（5H 的一天横跨约 5 个窗口）。跨窗重置不产生变动
    /// 事件，折线必须按此分段断开，否则会画出「额度自己涨回去」的假斜线。
    var windowIndex: Int = 0
}

nonisolated enum QuotaTimelinePeriodKind: String, Sendable, Equatable, Hashable {
    case today
    case currentCycle
    case previousCycle
}

/// 固定自然日或一个真实额度周期的投影。历史文件仍只保存原始样本和变动事件，
/// 此类型仅在读取时生成，不改变持久化格式。
nonisolated struct QuotaTimelinePeriod: Sendable, Equatable, Identifiable {
    var id: String
    var kind: QuotaTimelinePeriodKind
    var start: Date
    var end: Date
    var entries: [QuotaTimelineEntry]

    var totalDelta: Int {
        entries.reduce(0) { result, entry in
            guard let delta = entry.deltaPercent, delta < 20 else { return result }
            return result + delta
        }
    }
}

nonisolated struct QuotaHistoryPayload: Sendable, Equatable, Codable {
    static let currentVersion = 3

    var version: Int = Self.currentVersion
    var dayStart: Date = QuotaHistoryStore.todayStart()
    /// key = `seriesKey(accountKey:limitKind:)`，每个账号的 5H / 每周窗口各一个最新样本。
    var lastSamples: [String: QuotaHistorySample] = [:]
    var events: [QuotaChangeEvent] = []
}

enum QuotaHistoryAccountKey {
    nonisolated static func codexPrimary(accountId: String?) -> String {
        if let id = nonEmpty(accountId) {
            return "codex:primary:\(id)"
        }
        return "codex:primary"
    }

    nonisolated static func codexImported(id: String) -> String {
        "codex:imported:\(id)"
    }

    /// Claude 主账号的历史 / 周期数据 key。
    ///
    /// 邮箱优先，且**有邮箱时的取值与历史版本完全一致**——绝不能因为新增回退路径
    /// 就改变老用户的 key，那会让既有时间线与周期记录整条断裂。
    ///
    /// `accountUuid` 回退是给纯 Claude Desktop 用户的：他们从没跑过 `claude`，
    /// 没有 `~/.claude.json`，因而拿不到邮箱，但 Desktop 的凭据缓存里带着
    /// accountUuid。用独立前缀区分，避免和邮箱派生的 key 撞上。
    nonisolated static func claudePrimary(email: String?, accountUuid: String? = nil) -> String {
        if let email = nonEmpty(email)?.lowercased() {
            let digest = SHA256.hash(data: Data(email.utf8))
            return "claude:primary:\(digest.map { String(format: "%02x", $0) }.joined())"
        }
        if let uuid = nonEmpty(accountUuid)?.lowercased() {
            let digest = SHA256.hash(data: Data(uuid.utf8))
            return "claude:primary:uuid:\(digest.map { String(format: "%02x", $0) }.joined())"
        }
        return "claude:primary"
    }

    nonisolated static func antigravityPrimary(email: String?) -> String {
        guard let email = nonEmpty(email)?.lowercased() else {
            return "antigravity:primary"
        }
        let digest = SHA256.hash(data: Data(email.utf8))
        return "antigravity:primary:\(digest.map { String(format: "%02x", $0) }.joined())"
    }

    nonisolated private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

enum QuotaHistoryStore {
    nonisolated private static let fileName = "quota-history-today.json"
    nonisolated private static let bundleDirectory = "CCBar"
    /// 保留天数：覆盖完整滚动周窗口（7 天）+ 上一轮周窗口对比 + 5H 重叠缓冲。
    /// 老版本事件只存在「当天」，升级后只能从当天开始积累，不回补历史。
    nonisolated private static let retentionDays = 15
    /// 同窗对齐容差：服务端每次返回的 resets_at 都有亚秒~秒级抖动（实测 Claude
    /// 0.2~0.4 秒、Codex 1~3 秒），同窗口的相邻采样差在容差量级；差出半小时以上
    /// 必须视为窗口已滚动（跨周 / 制式换档）。与 `QuotaCycleStore`
    /// 的 `windowAlignmentTolerance` 语义一致。
    nonisolated private static let windowAlignmentTolerance: TimeInterval = 30 * 60
    /// 周额度窗口长度，用于由 `resets_at` 反推周期起点。
    nonisolated private static let weeklyWindowSeconds: TimeInterval = 7 * 24 * 60 * 60

    nonisolated static func seriesKey(accountKey: String, limitKind: QuotaLimitKind) -> String {
        "\(accountKey)|\(limitKind.rawValue)"
    }

    /// 将持久化的变动事件与该系列最新采样投影为时间线。
    ///
    /// - 5H：始终为本地自然日的 00:00–24:00，坐标轴不会跟随额度重置时间漂移。
    /// - 周：用服务返回的 `resetsAt` 划分当前额度周期与上一额度周期；这不是自然周。
    nonisolated static func timelinePeriods(
        payload: QuotaHistoryPayload,
        accountKey: String,
        limitKind: QuotaLimitKind,
        now: Date = Date()
    ) -> [QuotaTimelinePeriod] {
        let events = payload.events
            .filter { $0.accountKey == accountKey && $0.limitKind == limitKind }
            .sorted { $0.sampledAt < $1.sampledAt }
        let sample = payload.lastSamples[seriesKey(accountKey: accountKey, limitKind: limitKind)]

        switch limitKind {
        case .fiveHour:
            let start = todayStart(now: now)
            let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
            let todayEvents = events.filter { $0.sampledAt >= start && $0.sampledAt < end }
            return [QuotaTimelinePeriod(
                id: "\(accountKey)|fiveHour|today|\(Int(start.timeIntervalSinceReferenceDate))",
                kind: .today,
                start: start,
                end: end,
                entries: timelineEntries(
                    events: todayEvents,
                    latestSample: sample,
                    includesSample: { $0.sampledAt >= start && $0.sampledAt < end }
                )
            )]

        case .weekly:
            guard let currentEnd = sample?.resetsAt ?? events.last?.resetsAt else { return [] }
            let currentStart = currentEnd.addingTimeInterval(-weeklyWindowSeconds)
            let currentEvents = events.filter {
                belongsToWindow(
                    sampledAt: $0.sampledAt,
                    resetsAt: $0.resetsAt,
                    windowStart: currentStart,
                    windowEnd: currentEnd
                )
            }
            // 上一周期的边界取事件自己的 resets_at：窗口重新起算（长时间停用、套餐变更、
            // 服务端调整重置点）后新旧周期不一定正好相差 7 天，硬按 currentStart 推导会把
            // 整段真实数据判成空态。旧窗口本就落在 currentStart 附近（秒级抖动）时归一化为
            // currentStart，两段严格衔接；没有可用旧窗口时同样退回 7 天推导。
            let observedPreviousEnd = events
                .compactMap(\.resetsAt)
                .filter { $0 < currentEnd && !isSameWindow($0, currentEnd) }
                .max()
            let previousEnd = observedPreviousEnd.flatMap {
                isSameWindow($0, currentStart) ? currentStart : $0
            } ?? currentStart
            let previousStart = previousEnd.addingTimeInterval(-weeklyWindowSeconds)
            // 当前周期先认领；resets_at 缺失的老事件只能按时间判定，认领后不再重复计入上一周期。
            let claimed = Set(currentEvents.map(\.id))
            let previousEvents = events.filter {
                !claimed.contains($0.id)
                    && belongsToWindow(
                        sampledAt: $0.sampledAt,
                        resetsAt: $0.resetsAt,
                        windowStart: previousStart,
                        windowEnd: previousEnd
                    )
            }
            return [
                QuotaTimelinePeriod(
                    id: "\(accountKey)|weekly|current|\(Int(currentEnd.timeIntervalSinceReferenceDate))",
                    kind: .currentCycle,
                    start: currentStart,
                    end: currentEnd,
                    entries: timelineEntries(
                        events: currentEvents,
                        latestSample: sample,
                        includesSample: {
                            belongsToWindow(
                                sampledAt: $0.sampledAt,
                                resetsAt: $0.resetsAt,
                                windowStart: currentStart,
                                windowEnd: currentEnd
                            )
                        }
                    )
                ),
                QuotaTimelinePeriod(
                    id: "\(accountKey)|weekly|previous|\(Int(previousEnd.timeIntervalSinceReferenceDate))",
                    kind: .previousCycle,
                    start: previousStart,
                    end: previousEnd,
                    entries: timelineEntries(events: previousEvents, latestSample: nil, includesSample: { _ in false })
                ),
            ]

        case .modelWeekly, .unknown:
            return []
        }
    }

    nonisolated private static func timelineEntries(
        events: [QuotaChangeEvent],
        latestSample: QuotaHistorySample?,
        includesSample: (QuotaHistorySample) -> Bool
    ) -> [QuotaTimelineEntry] {
        var entries = events.map {
            QuotaTimelineEntry(
                id: "event|\($0.id)",
                source: .change,
                sampledAt: $0.sampledAt,
                remainingPercent: $0.afterRemainingPercent,
                deltaPercent: $0.deltaPercent,
                resetsAt: $0.resetsAt
            )
        }
        if let latestSample, includesSample(latestSample), !entries.contains(where: {
            $0.sampledAt == latestSample.sampledAt
                && $0.remainingPercent == latestSample.remainingPercent
                && isSameWindow($0.resetsAt, latestSample.resetsAt)
        }) {
            entries.append(QuotaTimelineEntry(
                id: "sample|\(latestSample.accountKey)|\(latestSample.limitKind.rawValue)|\(Int(latestSample.sampledAt.timeIntervalSinceReferenceDate))|\(latestSample.remainingPercent)",
                source: .sample,
                sampledAt: latestSample.sampledAt,
                remainingPercent: latestSample.remainingPercent,
                deltaPercent: nil,
                resetsAt: latestSample.resetsAt
            ))
        }
        return assignWindowIndexes(entries.sorted { $0.sampledAt < $1.sampledAt })
    }

    /// 周期归属：`resets_at` 存在时按窗口对齐判定，跨周期的采样绝不混进相邻周期；
    /// 缺失时无从判定窗口，只能退回时间范围，并用半开区间避免边界样本同时落进两个周期。
    nonisolated private static func belongsToWindow(
        sampledAt: Date,
        resetsAt: Date?,
        windowStart: Date,
        windowEnd: Date
    ) -> Bool {
        guard sampledAt >= windowStart, sampledAt <= windowEnd else { return false }
        guard let resetsAt else { return sampledAt < windowEnd }
        return isSameWindow(resetsAt, windowEnd)
    }

    /// 按 `resets_at` 给相邻点分段：跨窗重置不产生变动事件，折线若把两个窗口直连，
    /// 就会画出一条「额度自己涨回去」的假斜线。`resets_at` 缺失时无从判定，延续当前段。
    nonisolated private static func assignWindowIndexes(_ entries: [QuotaTimelineEntry]) -> [QuotaTimelineEntry] {
        var result: [QuotaTimelineEntry] = []
        result.reserveCapacity(entries.count)
        var index = 0
        var windowEnd: Date?
        for entry in entries {
            if let resetsAt = entry.resetsAt {
                if let windowEnd, !isSameWindow(windowEnd, resetsAt) { index += 1 }
                windowEnd = resetsAt
            }
            var next = entry
            next.windowIndex = index
            result.append(next)
        }
        return result
    }

    nonisolated static func load(now: Date = Date()) -> QuotaHistoryPayload {
        let url = fileURL()
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(QuotaHistoryPayload.self, from: data)
        else {
            return QuotaHistoryPayload(dayStart: todayStart(now: now))
        }
        switch payload.version {
        case 2:
            // 老格式：lastSamples key 只有账号维度；按样本里的 limitKind 扩为窗口系列。
            return prune(migratingV2(payload), now: now)
        case QuotaHistoryPayload.currentVersion:
            return prune(payload, now: now)
        default:
            return QuotaHistoryPayload(dayStart: todayStart(now: now))
        }
    }

    nonisolated static func save(_ payload: QuotaHistoryPayload) throws {
        let url = fileURL()
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: url, options: [.atomic])
    }

    /// v2 → v3：每个账号的 lastSamples 从「主额度唯一」扩展成按窗口系列（5H / 每周）分别存储。
    nonisolated private static func migratingV2(_ payload: QuotaHistoryPayload) -> QuotaHistoryPayload {
        var next = payload
        next.version = QuotaHistoryPayload.currentVersion
        var migrated: [String: QuotaHistorySample] = [:]
        for (key, sample) in next.lastSamples {
            migrated[seriesKey(accountKey: key, limitKind: sample.limitKind)] = sample
        }
        next.lastSamples = migrated
        return next
    }

    /// 旧版 Claude 主账号恒用 `claude:primary`，历史无法再拆分。
    /// 首次取得当前邮箱后将这批当日数据一次性归入当前账号。
    nonisolated static func migratingLegacyClaudeAccountKey(
        _ payload: QuotaHistoryPayload,
        to accountKey: String
    ) -> QuotaHistoryPayload {
        let legacyKey = "claude:primary"
        guard accountKey != legacyKey else { return payload }
        var next = payload
        // seriesKey = "\(accountKey)|\(kind)"；仅迁移恰好是旧常量键 "claude:primary" 的条目，
        // 与下方 events 的迁移条件一致；已哈希账号键（"claude:primary:hash"）与
        // 其他账号的系列（如 "codex:primary:*"）一律保留，不能误迁。
        next.lastSamples = next.lastSamples.reduce(into: [:]) { result, entry in
            guard entry.value.accountKey == legacyKey else {
                result[entry.key] = entry.value
                return
            }
            var sample = entry.value
            sample.accountKey = accountKey
            result[seriesKey(accountKey: accountKey, limitKind: sample.limitKind)] = sample
        }
        // 事件只有 v2 常量键 "claude:primary" 需要迁移；v3 起事件会落已哈希键，不能误迁。
        for index in next.events.indices where next.events[index].accountKey == legacyKey {
            next.events[index].accountKey = accountKey
        }
        return next
    }

    /// 同时记录快照中的标准 5 小时 / 每周主次窗口，每个窗口独立成系列
    /// （各自的最新样本、变动事件与窗口边界互不影响）。
    nonisolated static func record(
        payload: QuotaHistoryPayload,
        accountKey: String,
        app: QuotaApp,
        kind: QuotaHistoryAccountKind,
        snapshot: QuotaSnapshot,
        sampledAt: Date
    ) -> QuotaHistoryPayload {
        let limits = [snapshot.primaryLimit, snapshot.secondaryLimit]
            .compactMap { $0 }
            .filter { $0.kind == .fiveHour || $0.kind == .weekly }
        guard !limits.isEmpty else {
            return prune(payload, now: sampledAt)
        }

        var next = prune(payload, now: sampledAt)
        for limit in limits {
            next = recordingSeries(
                payload: next,
                accountKey: accountKey,
                app: app,
                kind: kind,
                limit: limit,
                sampledAt: sampledAt
            )
        }
        return next
    }

    nonisolated private static func recordingSeries(
        payload: QuotaHistoryPayload,
        accountKey: String,
        app: QuotaApp,
        kind: QuotaHistoryAccountKind,
        limit: QuotaLimit,
        sampledAt: Date
    ) -> QuotaHistoryPayload {
        let series = seriesKey(accountKey: accountKey, limitKind: limit.kind)
        var next = payload
        let remaining = roundedPercent(limit.window.remainingPercent)
        let previous = next.lastSamples[series]
        let sameLimitPrevious = previous.flatMap {
            $0.limitID == limit.id && $0.limitKind == limit.kind ? $0 : nil
        }

        // 服务端把该窗口重置为不同类型 / 新 ID 时不是同一条曲线，清掉该系列
        // 的旧基准与事件，从新窗口重新采样，避免制造虚假涨跌。
        if let previous,
           previous.limitID != limit.id || previous.limitKind != limit.kind
        {
            next.events.removeAll { $0.accountKey == accountKey && $0.limitKind == limit.kind }
            next.lastSamples.removeValue(forKey: series)
        }

        next.lastSamples[series] = QuotaHistorySample(
            accountKey: accountKey,
            app: app,
            kind: kind,
            sampledAt: sampledAt,
            limitID: limit.id,
            limitKind: limit.kind,
            remainingPercent: remaining,
            resetsAt: limit.window.resetsAt
        )

        guard let previous = sameLimitPrevious else { return next }

        // 断链自愈：lastSample 与同系列最后一条事件脱节（同窗、采样晚于链尾且值不同）
        // 时，基线已被旧值/残留污染（现象是链上出现连续「before 恒定」的假差值）。
        // 以链尾为有效基线，本次采样与链尾相等时不产事件，等于直接把链条接回真值；
        // 等值或后续变化采样则按链尾差分，虚假涨跌无法继续发生。
        var baseline = previous
        if let tail = next.events.last(where: { $0.accountKey == accountKey && $0.limitKind == limit.kind }),
           isSameWindow(previous.resetsAt, tail.resetsAt),
           previous.sampledAt >= tail.sampledAt,
           previous.remainingPercent != tail.afterRemainingPercent
        {
            baseline = QuotaHistorySample(
                accountKey: tail.accountKey,
                app: tail.app,
                kind: tail.kind,
                sampledAt: tail.sampledAt,
                limitID: tail.limitID,
                limitKind: tail.limitKind,
                remainingPercent: tail.afterRemainingPercent,
                resetsAt: tail.resetsAt
            )
        }

        guard baseline.remainingPercent != remaining else { return next }

        // 跨窗闸：基线窗口与本次采样窗口不同窗（resets_at 偏移超出抖动容差）时，
        // 视为窗口已滚动（跨周重置）或旧窗口残留值窜入，不产变动事件，仅把本次
        // 采样写为新基线；旧窗口事件保持独立历史，互不差分。
        guard isSameWindow(baseline.resetsAt, limit.window.resetsAt) else { return next }

        let delta = remaining - baseline.remainingPercent
        next.events.append(QuotaChangeEvent(
            id: eventId(
                accountKey: accountKey,
                limitID: limit.id,
                sampledAt: sampledAt,
                before: baseline.remainingPercent,
                after: remaining
            ),
            accountKey: accountKey,
            app: app,
            kind: kind,
            sampledAt: sampledAt,
            limitID: limit.id,
            limitKind: limit.kind,
            beforeRemainingPercent: baseline.remainingPercent,
            afterRemainingPercent: remaining,
            deltaPercent: delta,
            resetsAt: limit.window.resetsAt
        ))
        return next
    }

    /// 同窗判定：两端 resets_at 都给定时差在 `windowAlignmentTolerance`（半小时）内；
    /// 任一端缺失时无从判定，按同窗处理（断链自愈规则仍兜底异常值）。
    nonisolated private static func isSameWindow(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return true }
        return abs(a.timeIntervalSince(b)) <= windowAlignmentTolerance
    }

    nonisolated static func todayStart(now: Date = Date()) -> Date {
        Calendar.current.startOfDay(for: now)
    }

    nonisolated static func fileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent(bundleDirectory, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// 只保留最近 `retentionDays` 个自然日（含今天）的数据；更老的样本和事件清理，
    /// 保证完整的滚动周窗口（7 天）与上一轮周窗口对比始终可用。
    /// 先做一次幂等的断链清洗（见 `cleanupInconsistentChains`），再按时间窗裁剪。
    nonisolated private static func prune(_ payload: QuotaHistoryPayload, now: Date) -> QuotaHistoryPayload {
        let cleaned = cleanupInconsistentChains(payload)
        let start = todayStart(now: now)
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -(Self.retentionDays - 1),
            to: start
        ) ?? start
        var next = cleaned
        next.dayStart = start
        next.events = next.events.filter { $0.sampledAt >= cutoff }
        next.lastSamples = next.lastSamples.filter { $0.value.sampledAt >= cutoff }
        return next
    }

    /// 幂等清洗：跨窗差分与断链差分的事件基于「窗口边界变化」或「被旧值污染的基线」
    /// 生成，都是虚假变动。按系列保留「链首」与「与前一保留事件同窗且数值衔接」的事件，
    /// 删除其余；并把同窗内与链尾脱节的 lastSample 回滚为链尾值，保证后续采样从干净
    /// 基线继续（链首事件无法可靠判定真伪，保留）。
    nonisolated static func cleanupInconsistentChains(_ payload: QuotaHistoryPayload) -> QuotaHistoryPayload {
        var keptBySeries: [String: QuotaChangeEvent] = [:]
        var cleaned: [QuotaChangeEvent] = []
        for event in payload.events {
            let series = "\(event.accountKey)|\(event.limitKind.rawValue)"
            let keep: Bool
            if let prev = keptBySeries[series] {
                if isSameWindow(prev.resetsAt, event.resetsAt) {
                    // 同窗：必须与前一保留事件数值衔接，否则是被污染基线产生的假差值。
                    keep = prev.afterRemainingPercent == event.beforeRemainingPercent
                } else {
                    // 跨窗：判据与同窗相反。`before` 恰好衔接上一窗口链尾，说明这条 delta
                    // 是拿旧窗口的剩余值跨窗求差得来的（周期滚动时额度跳回满额），属虚假变动，删除。
                    // 不衔接则说明新窗口已由 recordingSeries 的跨窗闸建立了自己的基线，
                    // 这是新链的链首，必须保留——额度周期滚动（5H 一天约 5 个窗口、周窗每 7 天
                    // 一轮）是常态，若在此删掉，keptBySeries 会永远停在旧窗口链尾，新周期的
                    // 每个事件都会被逐个删光，时间线的「当前周期」只剩一个采样点。
                    keep = prev.afterRemainingPercent != event.beforeRemainingPercent
                }
            } else {
                keep = true
            }
            if keep {
                cleaned.append(event)
                keptBySeries[series] = event
            }
        }

        var next = payload
        next.events = cleaned

        var samples = payload.lastSamples
        for sample in samples.values {
            guard sample.limitKind == .fiveHour || sample.limitKind == .weekly else { continue }
            guard let tail = cleaned.last(where: {
                $0.accountKey == sample.accountKey
                    && $0.limitKind == sample.limitKind
                    && $0.sampledAt <= sample.sampledAt
            }) else { continue }
            guard tail.limitID == sample.limitID,
                  isSameWindow(tail.resetsAt, sample.resetsAt),
                  sample.remainingPercent != tail.afterRemainingPercent
            else { continue }
            var fixed = sample
            fixed.remainingPercent = tail.afterRemainingPercent
            samples[seriesKey(accountKey: sample.accountKey, limitKind: sample.limitKind)] = fixed
        }
        next.lastSamples = samples
        return next
    }

    nonisolated private static func roundedPercent(_ value: Double) -> Int {
        max(0, min(100, Int(value.rounded())))
    }

    nonisolated private static func eventId(
        accountKey: String,
        limitID: String,
        sampledAt: Date,
        before: Int,
        after: Int
    ) -> String {
        "\(accountKey)|\(limitID)|\(Int(sampledAt.timeIntervalSince1970))|\(before)|\(after)"
    }
}
