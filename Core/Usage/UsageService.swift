import Foundation
import Observation

/// 协调 JSONL 扫描 → 聚合 → 持久化 → 通知 AppState 的入口。
@MainActor
@Observable
final class UsageService {
    let aggregator = UsageAggregator()
    let conversationAggregator = ConversationAggregator()
    let cycleAggregator = CycleUsageAggregator()
    private(set) var isScanning = false
    private(set) var isCycleRebuilding = false
    private(set) var isRefreshingPricingCatalog = false
    private(set) var lastScanAt: Date?
    private(set) var lastError: String?
    /// 进行中的全量重算 / 周期重建进度；空闲时为 nil。设置页"重新计算"期间展示。
    private(set) var scanProgress: ScanProgress?

    private weak var appState: AppState?
    private var scanQueued = false
    private var requiresFullRebuild = false
    private var loadedRollupGeneration: String?
    private var loadedCycleGeneration: String?
    private var cycleInitialRebuildCompletedAt: Date?
    private var cycleInitialRebuildCompletedApps: Set<UsageApp> = []
    /// 启动时丢弃过孤儿周期桶，且它们落在受限重建窗口内；由 AppState 在 bootstrap
    /// 末尾触发一次窗口重建补回。
    private(set) var hasPendingOrphanCycleRebuild = false
    /// 存在窗口之外、受限重建补不回的周期用量缺口。设置页据此提示用户手动重算；
    /// 手动「重新计算用量」成功后清除。
    private(set) var cycleUsageNeedsManualRecalculation = false
    /// Cursor 远端日桶独立于本地 scan-state / usage-rollup 的持久化状态。
    private var cursorUsageCache = CursorUsageCachePayload()
    private var cursorRemoteAccountID: String?
    private var cursorRemoteBackoffUntil: Date?
    private(set) var isRefreshingCursorRemoteUsage = false
    private(set) var cursorRemoteUsageError: String?

    /// 统计页读取的完整 Cursor 自然日覆盖范围。只有身份匹配的独立远端缓存会进入此集合。
    var cursorUsageCoveredDayRanges: [CursorUsageDayRange] {
        cursorUsageCache.coveredDayRanges
    }

    func isCursorRemoteUsageCovered(_ range: Range<Date>) -> Bool {
        cursorUsageCache.coveredDayRanges.missingRanges(in: range).isEmpty
    }

    /// 只要当前账号已有与目标区间相交的 Cursor 远端快照，界面就可先展示已知金额；
    /// 完整覆盖只用于安排后台补拉，不能把已有数据变成空值。
    func hasCursorRemoteUsage(in range: Range<Date>) -> Bool {
        guard cursorRemoteAccountID != nil, range.lowerBound < range.upperBound else { return false }
        return cursorUsageCache.coveredDayRanges.contains {
            $0.startDay < range.upperBound && range.lowerBound < $0.endDay
        }
    }
    /// rollup 写盘节流：距上次成功落盘不足这个间隔时，本轮只更新内存聚合，
    /// 不重写磁盘快照。三份 rollup 都是全量快照（本机实测 conversation-rollup 3.4MB、
    /// scan-state 2.6MB），活跃编码时按 5 分钟扫描周期写等于每小时数十 MB。
    /// 代价只是 App 意外退出后下次启动多重扫这段窗口内的增量日志（秒级），不丢数据：
    /// 未落盘期间 watermark 一并压住，盘上永远是「rollup 与 scan-state 同代同进度」。
    nonisolated private static let rollupWriteInterval: TimeInterval = 15 * 60
    /// 已进入内存聚合但尚未落盘的用量变化。
    private var hasUnwrittenRollupChanges = false
    private var lastRollupWriteAt: Date?

    /// 上一轮成功提交的 ScanState 常驻内存，避免每轮扫描都从磁盘重读重解码
    /// scan-state.json（随文件数和 seen ID 增长，本地实测已近 1MB）。
    /// 冷启动首轮才从磁盘恢复；持久化失败时清空内存副本，
    /// 由 requiresFullRebuild 强制下轮全量重建。
    private var cachedScanState: ScanState?

    func bootstrap(appState: AppState) async {
        self.appState = appState
        // 日聚合与对话两份主 rollup 必须同代；周期 rollup 也只在同代时恢复。
        // rollup 可能较大（conversation-rollup 实测可达数 MB），三个 load 都是磁盘读取 +
        // JSON 解码，统一放到后台线程，避免启动时阻塞主线程、菜单栏图标卡顿。
        let (payload, conversationPayload, cyclePayload, cursorPayload) = await Task.detached(priority: .utility) {
            (
                UsageRollupCache.load(),
                ConversationRollupCache.load(),
                CycleUsageRollupCache.load(),
                CursorUsageCache.load()
            )
        }.value
        cursorUsageCache = cursorPayload
        let generationsMatch = !payload.generationID.isEmpty
            && payload.generationID == conversationPayload.generationID
        if generationsMatch {
            aggregator.load(from: payload.buckets)
            conversationAggregator.load(infos: conversationPayload.infos, buckets: conversationPayload.buckets)
            loadedRollupGeneration = payload.generationID
            let validCycleIDs = Set(appState.quotaCycles.records.map(\.id))
            if cyclePayload.generationID == payload.generationID {
                // 周期记录每次载入都会被 `cleaningUpLegacyPayload` 剔除残片 / 合并重叠，
                // rollup 里因此常残留指向已消失 cycleID 的孤儿桶。旧实现把这看作整份
                // rollup 失效，清空聚合器并触发一次不带窗口的全历史重建（实测 2.4GB、
                // 约 100 秒 CPU），而实际只有孤儿桶是脏的：其余桶与初始重建标记都仍
                // 有效。这里只丢弃孤儿桶，落在重建窗口内的那部分交给受限重建补回，
                // 窗口之外的置位提示、等用户手动重算，不再自动全量重扫。
                let orphanedCycleIDs = Set(cyclePayload.buckets.map(\.cycleID))
                    .subtracting(validCycleIDs)
                cycleAggregator.load(from: cyclePayload.buckets.filter {
                    validCycleIDs.contains($0.cycleID)
                })
                loadedCycleGeneration = cyclePayload.generationID
                cycleInitialRebuildCompletedAt = cyclePayload.initialRebuildCompletedAt
                cycleInitialRebuildCompletedApps = cyclePayload.effectiveInitialRebuildCompletedApps
                classifyOrphanedCycleBuckets(orphanedCycleIDs)
            } else {
                // 代次不一致说明周期 rollup 与主 rollup 不是同一次扫描的产物，
                // 无从判断哪些桶可信，只能整份丢弃、由初始重建重灌。
                cycleAggregator.load(from: [])
                loadedCycleGeneration = nil
                cycleInitialRebuildCompletedAt = nil
                cycleInitialRebuildCompletedApps = []
            }
            lastScanAt = max(payload.updatedAt, conversationPayload.updatedAt)
        } else {
            aggregator.load(from: [])
            conversationAggregator.load(infos: [], buckets: [])
            cycleAggregator.load(from: [])
            requiresFullRebuild = true
            loadedRollupGeneration = nil
            loadedCycleGeneration = nil
            cycleInitialRebuildCompletedAt = nil
            cycleInitialRebuildCompletedApps = []
            lastScanAt = nil
        }
        // 个人历史用量一次性补录：见 ImportedUsageBackfill 注释。这里先合并一次保证扫描前即可展示；
        // runScan 每轮还会按同样规则重新合并，兜底缓存失效清空聚合器的情况。文件不存在时是纯 no-op。
        let existingClaudeDays = Set(aggregator.snapshotLocal().filter { $0.app == .claude }.map(\.day))
        aggregator.ingestLocal(ImportedUsageBackfill.loadMissingEntries(app: .claude, existingDays: existingClaudeDays))
        publishTotals()
        // 远端价格目录后台刷新：非阻塞，isDue 内部判断是否真的需要发请求，刷新结果由下次扫描自然拾取。
        PricingCatalogStore.shared.refreshIfNeeded()
    }

    /// 仅在 Cursor 身份确认后恢复与该身份绑定的远端快照。缓存身份不匹配时，
    /// 立即从内存隔离旧桶；下一次完整远端拉取才会写入新账号数据。
    func activateCursorRemoteUsage(accountID: String) {
        let normalizedID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return }
        guard cursorRemoteAccountID?.caseInsensitiveCompare(normalizedID) != .orderedSame else { return }

        cursorRemoteAccountID = normalizedID
        if cursorUsageCache.accountID?.caseInsensitiveCompare(normalizedID) == .orderedSame {
            aggregator.loadRemote(from: cursorUsageCache.buckets)
        } else {
            aggregator.loadRemote(from: [])
            cursorUsageCache = CursorUsageCachePayload(accountID: normalizedID)
        }
        cursorRemoteUsageError = nil
        cursorRemoteBackoffUntil = nil
        publishTotals()
    }

    /// 拉取 Cursor 最近变动的远端日桶。首次请求覆盖计费周期起点、当前自然周与最近修正窗口的较早者；
    /// 后续重拉今天及其前两天，并补齐当前自然周的覆盖缺口。所有结果都按完整自然日替换，
    /// 绝不累计重复窗口。
    ///
    /// 返回 401 时由 AppState 负责只读重载 Cursor.app 登录态并最多重试一次。
    @discardableResult
    func refreshCursorRemoteUsage(
        session: CursorAuthSession,
        billingWindow: Range<Date>?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async -> CursorUsageError? {
        activateCursorRemoteUsage(accountID: session.userID)
        guard !isRefreshingCursorRemoteUsage else { return nil }
        if let backoffUntil = cursorRemoteBackoffUntil, backoffUntil > now {
            cursorRemoteUsageError = "Cursor usage rate limited; retry later"
            return nil
        }

        let ranges = Self.cursorRefreshRanges(
            now: now,
            billingWindow: billingWindow,
            coveredDayRanges: cursorUsageCache.coveredDayRanges,
            calendar: calendar
        )
        guard !ranges.isEmpty else { return nil }

        isRefreshingCursorRemoteUsage = true
        defer { isRefreshingCursorRemoteUsage = false }
        for range in ranges {
            let result = await CursorUsageFetcher.fetch(
                cookieHeader: session.cookieHeader,
                from: range.lowerBound,
                to: range.upperBound,
                calendar: calendar
            )
            switch result {
            case .failure(let error):
                cursorRemoteUsageError = error.description
                if error.isRateLimited {
                    cursorRemoteBackoffUntil = now.addingTimeInterval(10 * 60)
                }
                return error
            case .success(let fetched):
                await storeCursorRemoteUsage(fetched, accountID: session.userID, updatedAt: now)
            }
        }
        return nil
    }

    /// Popover 固定展示自然周，刷新不能因已有任意缓存就遗忘本周前半段。
    /// 近期窗口负责修正迟到事件；周内缺口单独补拉，重叠或相邻时合并成一次请求。
    nonisolated static func cursorRefreshRanges(
        now: Date,
        billingWindow: Range<Date>?,
        coveredDayRanges: [CursorUsageDayRange],
        calendar: Calendar = .current
    ) -> [Range<Date>] {
        let today = calendar.startOfDay(for: now)
        let recentStart = calendar.date(byAdding: .day, value: -2, to: today) ?? today
        guard !coveredDayRanges.isEmpty else {
            var weekCalendar = calendar
            weekCalendar.firstWeekday = 2
            let weekComponents = weekCalendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            let weekStart = weekCalendar.date(from: weekComponents) ?? today
            let billingStart = billingWindow.map { calendar.startOfDay(for: $0.lowerBound) }
            let initialStart = min(min(billingStart ?? weekStart, weekStart), recentStart)
            return initialStart < now ? [initialStart..<now] : []
        }

        var weekCalendar = calendar
        weekCalendar.firstWeekday = 2
        let weekComponents = weekCalendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        let weekStart = weekCalendar.date(from: weekComponents) ?? today
        let weekGaps = coveredDayRanges.missingRanges(in: weekStart..<now)
        let ranges = weekGaps + [recentStart..<now]
        return mergeCursorRefreshRanges(ranges)
    }

    nonisolated private static func mergeCursorRefreshRanges(_ ranges: [Range<Date>]) -> [Range<Date>] {
        let sorted = ranges
            .filter { $0.lowerBound < $0.upperBound }
            .sorted { $0.lowerBound < $1.lowerBound }
        var result: [Range<Date>] = []
        for range in sorted {
            guard let previous = result.last else {
                result.append(range)
                continue
            }
            if range.lowerBound <= previous.upperBound {
                result[result.count - 1] = previous.lowerBound..<max(previous.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// Stats 选择到未覆盖的有限时间范围时，按月补拉缺口。`all` 不会传入这里，
    /// 以免后台无界回溯；界面只消费现有缓存，不展示覆盖状态。
    @discardableResult
    func loadCursorRemoteUsageHistory(
        session: CursorAuthSession,
        range: Range<Date>,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async -> CursorUsageError? {
        activateCursorRemoteUsage(accountID: session.userID)
        guard let requestedRange = normalizedCursorHistoryRange(range, now: now, calendar: calendar) else {
            return nil
        }

        // 与周期刷新共用一个远端槽，避免相同日桶并发覆盖。这里等待正在进行的短刷新，
        // 让用户切换历史范围时的请求不会被悄悄丢弃。
        while isRefreshingCursorRemoteUsage {
            guard !Task.isCancelled else { return nil }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        let missing = cursorUsageCache.coveredDayRanges.missingRanges(in: requestedRange)
        guard !missing.isEmpty else { return nil }

        if let backoffUntil = cursorRemoteBackoffUntil, backoffUntil > now {
            cursorRemoteUsageError = "Cursor usage rate limited; retry later"
            return nil
        }

        isRefreshingCursorRemoteUsage = true
        defer { isRefreshingCursorRemoteUsage = false }

        for chunk in missing.flatMap({ cursorHistoryMonthChunks(for: $0, calendar: calendar) }) {
            guard !Task.isCancelled else { return nil }
            let fetchEnd = min(chunk.upperBound, now)
            guard chunk.lowerBound < fetchEnd else { continue }

            let result = await CursorUsageFetcher.fetch(
                cookieHeader: session.cookieHeader,
                from: chunk.lowerBound,
                to: fetchEnd,
                calendar: calendar
            )
            switch result {
            case .failure(let error):
                cursorRemoteUsageError = error.description
                if error.isRateLimited {
                    cursorRemoteBackoffUntil = now.addingTimeInterval(10 * 60)
                }
                return error
            case .success(let fetched):
                await storeCursorRemoteUsage(fetched, accountID: session.userID, updatedAt: now)
            }
        }
        return nil
    }

    private func storeCursorRemoteUsage(
        _ fetched: CursorUsageFetchResult,
        accountID: String,
        updatedAt: Date
    ) async {
        aggregator.replaceRemote(app: .cursor, dayRange: fetched.dayRange, buckets: fetched.buckets)
        cursorUsageCache.accountID = accountID
        cursorUsageCache.buckets = aggregator.snapshotRemote(app: .cursor)
        if let range = CursorUsageDayRange(range: fetched.dayRange) {
            cursorUsageCache.coveredDayRanges = cursorUsageCache.coveredDayRanges.merged(with: range)
        }
        cursorUsageCache.updatedAt = updatedAt
        cursorRemoteUsageError = nil
        cursorRemoteBackoffUntil = nil
        publishTotals()

        let cacheSnapshot = cursorUsageCache
        do {
            try await Task.detached(priority: .utility) {
                try CursorUsageCache.save(cacheSnapshot)
            }.value
        } catch {
            // 远端内存快照仍可展示；下一轮成功刷新会再次尝试原子写缓存。
            cursorRemoteUsageError = "Cursor usage cache save failed: \(error)"
        }
    }

    private func normalizedCursorHistoryRange(
        _ range: Range<Date>,
        now: Date,
        calendar: Calendar
    ) -> Range<Date>? {
        guard range.lowerBound != .distantPast, range.upperBound != .distantFuture else {
            return nil
        }

        let start = calendar.startOfDay(for: range.lowerBound)
        let effectiveEnd = min(range.upperBound, now)
        guard start < effectiveEnd else { return nil }

        let endDay = calendar.startOfDay(for: effectiveEnd)
        let end: Date
        if effectiveEnd == endDay {
            end = endDay
        } else {
            end = calendar.date(byAdding: .day, value: 1, to: endDay) ?? effectiveEnd
        }
        return start < end ? start..<end : nil
    }

    private func cursorHistoryMonthChunks(
        for range: Range<Date>,
        calendar: Calendar
    ) -> [Range<Date>] {
        var chunks: [Range<Date>] = []
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            let month = calendar.dateComponents([.year, .month], from: cursor)
            guard let monthStart = calendar.date(from: month),
                  let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart)
            else {
                return chunks
            }
            let end = min(nextMonth, range.upperBound)
            guard cursor < end else { return chunks }
            chunks.append(cursor..<end)
            cursor = end
        }
        return chunks
    }

    /// Scheduler 的周期扫描入口：日志目录自上次扫描以来没有变化时整轮跳过。
    /// 手动刷新（`refreshNow`）与强制重算（`forceRescan`）直接走 `scanNow` / 全量路径，
    /// 不受门控影响，用户点了就一定扫。
    func scanPeriodically() async {
        guard UsageLogWatcher.shared.shouldScan() else { return }
        await scanNow()
    }

    /// 由 Scheduler / 手动触发；防重入。
    func scanNow() async {
        if isScanning {
            scanQueued = true
            return
        }
        isScanning = true
        defer { isScanning = false }

        repeat {
            scanQueued = false
            // 借用量扫描的既有节奏当远端价格目录 24h 到期检查的心跳，不新开定时器；非阻塞。
            PricingCatalogStore.shared.refreshIfNeeded()
            PricingCatalogStore.shared.commitPending()
            let cacheResult = await resolveScanState()
            if case .invalidated = cacheResult {
                clearUsageAggregatesForFullRebuild()
            }
            if await runScan(prev: cacheResult.state, allowDeferredWrite: true) {
                requiresFullRebuild = false
            }
        } while scanQueued
    }

    /// 受限重建的日志回溯窗口。5h / weekly 周期滚动涉及的条目必然落在最近一个周期内，
    /// 窗口外（大于此天数）的历史归属早已固化，不需要重扫，给足余量即可。
    nonisolated private static let rebuildWindowDays = 8

    /// 孤儿周期桶分流。能被受限重建窗口覆盖的记下来、启动后补算一次；窗口之外的
    /// 只能靠用户手动「重新计算用量」，置位提示标记而不是自动全量重扫。
    /// cycleID 末段是该周期 `endAt` 的 epoch 秒，据此把孤儿桶定位到时间轴上。
    private func classifyOrphanedCycleBuckets(_ orphanedCycleIDs: Set<String>) {
        guard !orphanedCycleIDs.isEmpty else { return }
        let windowStart = Calendar(identifier: .gregorian)
            .date(byAdding: .day, value: -Self.rebuildWindowDays, to: Date())
            ?? Date()
        for id in orphanedCycleIDs {
            // 反解不出重置时刻的 ID 一律按窗口外处理：宁可提示用户重算，
            // 也不要静默少算一段用量。
            if let resetAt = QuotaCycleStore.resetInstant(fromCycleID: id), resetAt >= windowStart {
                hasPendingOrphanCycleRebuild = true
            } else {
                cycleUsageNeedsManualRecalculation = true
            }
        }
    }

    /// 周期窗口滚动 / 账号段变化后的受限重建：只重扫最近 `rebuildWindowDays` 天的日志，
    /// 仅重算受影响周期内的桶，历史桶保留。
    /// 触发频率高（5h / weekly 滚动，每天数次），必须保持轻量；
    /// 全量重建只在冷启动且 cycle rollup 无效时发生一次（见 `rebuildCycleUsageIfNeeded`）。
    func rebuildCycleUsageForRecentChanges() async {
        guard let appState, !appState.quotaCycles.records.isEmpty else { return }
        while isScanning || isCycleRebuilding {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        isCycleRebuilding = true
        isScanning = true
        defer {
            isCycleRebuilding = false
            isScanning = false
            scanProgress = nil
            if scanQueued {
                Task { await scanNow() }
            }
        }
        // 先提交上次常规扫描之后新追加的日志，推进主 watermark。
        // 否则它们会先被下面的窗口重扫灌入，再被下一次常规增量扫描重复计入。
        guard await drainPendingUsageBeforeCycleRebuild() else { return }
        // 本轮窗口重建即将覆盖启动时被丢弃的窗口内孤儿桶；drain 失败提前返回时
        // 不清标记，留给下一次触发。
        hasPendingOrphanCycleRebuild = false

        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let rebuildWindowStart = calendar.date(
            byAdding: .day,
            value: -Self.rebuildWindowDays,
            to: now
        ) ?? now
        let cycles = appState.quotaCycles.records
        let accountSegments = appState.quotaCycles.accountSegments
        let affectedCycleIDs = Self.affectedCycleIDs(
            cycles: cycles,
            since: rebuildWindowStart,
            until: now
        )
        let dateFrom = Self.rebuildScanStart(
            windowStart: rebuildWindowStart,
            cycles: cycles,
            affectedCycleIDs: affectedCycleIDs
        )
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexRoots = [
            home.appendingPathComponent(".codex/sessions", isDirectory: true),
            home.appendingPathComponent(".codex/archived_sessions", isDirectory: true),
        ]
        let progress: ScanProgressCallback? = { [weak self] progress in
            DispatchQueue.main.async { self?.scanProgress = progress }
        }

        async let claudeTask = Task.detached(priority: .utility) {
            ClaudeJSONLScanner.scan(
                previous: [:],
                seenMessageIds: [],
                root: ClaudeJSONLScanner.defaultRoot(),
                // 重建只需要 entries，跳过标题索引构建（省一次索引文件解析）
                conversationIndex: ConversationTitleIndex.ClaudeIndex(titles: [:], projects: [:]),
                minimumMtime: dateFrom,
                onProgress: progress
            )
        }.value
        async let codexTask = Task.detached(priority: .utility) {
            await CodexJSONLScanner.scan(
                previous: [:],
                // 本轮从空 seen 起扫，跨文件去重只在本次扫到的文件之间生效。
                // 若 fork 会话的父文件 mtime 落在窗口外没被扫到，其重放段会重复计入本周期桶；
                // 主界面的日用量/费用走全量增量路径，不受影响。
                seenTokenIds: [],
                roots: codexRoots,
                indexedTitles: [:],
                minimumMtime: dateFrom,
                onProgress: progress
            )
        }.value
        let claude = await claudeTask
        let codex = await codexTask
        let affectedCycles = cycles.filter { affectedCycleIDs.contains($0.id) }
        let failedApps = Self.cycleRebuildFailedApps(
            claude: claude,
            codex: codex,
            cycles: affectedCycles
        )
        let rebuildableCycleIDs = Self.cycleRebuildableCycleIDs(
            cycles: affectedCycles,
            requestedCycleIDs: affectedCycleIDs,
            failedApps: failedApps
        )
        await commitCycleAggregation(
            exactEntries: (claude.entries + codex.entries).filter { !failedApps.contains($0.app) },
            cycles: cycles,
            accountSegments: accountSegments,
            failedApps: failedApps,
            rebuildRange: rebuildableCycleIDs
        )
    }

    /// 返回与重建扫描区间相交的周期。周期可能开始于 dateFrom 之前、结束于其后，
    /// 这类跨界周期同样会接收到本轮扫描条目，必须先清桶再重灌。
    nonisolated static func affectedCycleIDs(
        cycles: [QuotaCycleRecord],
        since dateFrom: Date,
        until dateTo: Date
    ) -> Set<String> {
        Set(cycles.filter {
            $0.endAt > dateFrom && $0.startAt < dateTo
        }.map(\.id))
    }

    /// 清桶前必须扫到受影响周期的真实起点，避免跨窗口周期只灌回后半段。
    nonisolated static func rebuildScanStart(
        windowStart: Date,
        cycles: [QuotaCycleRecord],
        affectedCycleIDs: Set<String>
    ) -> Date {
        cycles.lazy
            .filter { affectedCycleIDs.contains($0.id) }
            .map(\.startAt)
            .reduce(windowStart, min)
    }

    /// 只有根目录或文件实际读取失败才冻结对应 Provider；目录从未存在表示本机没有
    /// 该 Provider 的日志，是可成功重建为空的正常状态，不能阻塞另一侧。
    nonisolated static func cycleRebuildFailedApps(
        claude: ClaudeJSONLScanner.Result?,
        codex: CodexJSONLScanner.Result?,
        cycles: [QuotaCycleRecord]
    ) -> Set<UsageApp> {
        let apps = Set(cycles.map(\.app))
        var failedApps: Set<UsageApp> = []
        if apps.contains(.claude), let claude, claude.failedFileCount > 0 {
            failedApps.insert(.claude)
        }
        if apps.contains(.codex), let codex, codex.failedFileCount > 0 {
            failedApps.insert(.codex)
        }
        return failedApps
    }

    nonisolated static func pendingInitialCycleRebuildApps(
        cycles: [QuotaCycleRecord],
        completedApps: Set<UsageApp>
    ) -> Set<UsageApp> {
        Set(cycles.map(\.app))
            .intersection([.codex, .claude])
            .subtracting(completedApps)
    }

    nonisolated static func updatedInitialCycleRebuildApps(
        completedApps: Set<UsageApp>,
        requestedApps: Set<UsageApp>,
        failedApps: Set<UsageApp>
    ) -> Set<UsageApp> {
        completedApps.union(requestedApps.subtracting(failedApps))
    }

    /// 读取失败时只排除对应 Provider 的周期，保留其已有桶；其余 Provider 继续清桶重灌。
    nonisolated static func cycleRebuildableCycleIDs(
        cycles: [QuotaCycleRecord],
        requestedCycleIDs: Set<String>,
        failedApps: Set<UsageApp>
    ) -> Set<String> {
        Set(cycles.lazy
            .filter { requestedCycleIDs.contains($0.id) && !failedApps.contains($0.app) }
            .map(\.id))
    }

    /// 周期重建只能覆盖或清除自己产生的错误，不能抹掉前置增量扫描刚发现的告警。
    nonisolated static func lastErrorAfterCycleRebuild(
        current: String?,
        rebuildWarning: String?
    ) -> String? {
        if let rebuildWarning { return rebuildWarning }
        if current?.hasPrefix("cycle usage rebuild") == true { return nil }
        return current
    }

    /// 受限重建前用主扫描状态做一次常规增量提交，保证窗口重扫后
    /// watermark 不会再返回同一批条目。失效状态沿用常规扫描的全量重建语义。
    private func drainPendingUsageBeforeCycleRebuild() async -> Bool {
        let cacheResult = await resolveScanState()
        if case .invalidated = cacheResult {
            clearUsageAggregatesForFullRebuild()
        }
        guard await runScan(prev: cacheResult.state) else { return false }
        requiresFullRebuild = false
        return true
    }

    private func clearUsageAggregatesForFullRebuild() {
        cachedScanState = nil
        // 待落盘的变化随聚合器一起作废；`lastRollupWriteAt` 归零让重建后的首轮立刻落盘。
        hasUnwrittenRollupChanges = false
        lastRollupWriteAt = nil
        aggregator.load(from: [])
        conversationAggregator.load(infos: [], buckets: [])
        cycleAggregator.load(from: [])
        loadedRollupGeneration = nil
        loadedCycleGeneration = nil
        cycleInitialRebuildCompletedAt = nil
        cycleInitialRebuildCompletedApps = []
        publishTotals()
    }

    /// 周期用量重建的公共收尾：聚合 → 落盘 rollup → 更新内存状态。
    /// - Parameter initialRebuildApps: 本轮执行初始重建的 Provider；成功侧会独立置位，
    ///   失败侧保持待重试，不会让已完成 Provider 在下次启动重复全量扫描。
    /// - Parameter rebuildRange: 非 nil 表示受限重建，只重算这些周期内的桶。
    private func commitCycleAggregation(
        exactEntries: [UsageEntry],
        cycles: [QuotaCycleRecord],
        accountSegments: [QuotaCycleAccountSegment],
        initialRebuildApps: Set<UsageApp> = [],
        failedApps: Set<UsageApp> = [],
        rebuildRange affectedCycleIDs: Set<String>? = nil
    ) async {
        let failedProviderNames = [UsageApp.codex, .claude]
            .filter { failedApps.contains($0) }
            .map { $0 == .codex ? "Codex" : "Claude Code" }
            .joined(separator: ", ")
        let rebuildWarning = failedApps.isEmpty
            ? nil
            : "cycle usage rebuild incomplete: \(failedProviderNames) logs unreadable; previous data preserved"
        if let affectedCycleIDs, affectedCycleIDs.isEmpty, !failedApps.isEmpty {
            lastError = rebuildWarning
            print("[CycleUsage 周期用量] rebuild deferred providers=\(failedProviderNames)")
            return
        }
        let started = Date()
        if let affectedCycleIDs {
            cycleAggregator.rebuildRange(
                exactEntries: exactEntries,
                cycles: cycles,
                accountSegments: accountSegments,
                affectedCycleIDs: affectedCycleIDs
            )
        } else {
            cycleAggregator.rebuild(
                exactEntries: exactEntries,
                cycles: cycles,
                accountSegments: accountSegments
            )
        }
        let completedAt = Date()
        let completedApps = Self.updatedInitialCycleRebuildApps(
            completedApps: cycleInitialRebuildCompletedApps,
            requestedApps: initialRebuildApps,
            failedApps: failedApps
        )
        let requiredApps = Set(cycles.map(\.app)).intersection([.codex, .claude])
        let completedInitialRebuild = !initialRebuildApps.isEmpty
            && !requiredApps.isEmpty
            && completedApps.isSuperset(of: requiredApps)
        let generationID = loadedRollupGeneration ?? UUID().uuidString
        let fingerprint = Pricing.fingerprint(knownUsage: pricingUsageKeys(from: aggregator.snapshotLocal()))
        let rollup = CycleUsageRollupPayload(
            generationID: generationID,
            pricingFingerprint: fingerprint,
            buckets: cycleAggregator.snapshot(),
            initialRebuildCompletedAt: completedInitialRebuild ? completedAt : cycleInitialRebuildCompletedAt,
            initialRebuildCompletedApps: completedApps,
            updatedAt: completedAt
        )
        do {
            try await Task.detached(priority: .utility) {
                try CycleUsageRollupCache.save(rollup)
            }.value
            loadedCycleGeneration = generationID
            cycleInitialRebuildCompletedApps = completedApps
            if completedInitialRebuild {
                cycleInitialRebuildCompletedAt = completedAt
            }
            lastError = Self.lastErrorAfterCycleRebuild(
                current: lastError,
                rebuildWarning: rebuildWarning
            )
            let elapsed = String(format: "%.2fs", Date().timeIntervalSince(started))
            let tag = initialRebuildApps.isEmpty ? "range rebuild" : "initial rebuild"
            let status = failedApps.isEmpty ? "completed" : "partially completed"
            print("[CycleUsage 周期用量] \(tag) \(status) elapsed=\(elapsed)")
        } catch {
            lastError = "cycle usage rebuild failed: \(error)"
            print("[CycleUsage 周期用量] cycle usage rebuild failed: \(error)")
        }
    }

    func rebuildCycleUsageIfNeeded() async {
        guard let appState, !appState.quotaCycles.records.isEmpty else { return }
        guard !Self.pendingInitialCycleRebuildApps(
            cycles: appState.quotaCycles.records,
            completedApps: cycleInitialRebuildCompletedApps
        ).isEmpty else { return }
        while isScanning || isCycleRebuilding {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Self.pendingInitialCycleRebuildApps(
                cycles: appState.quotaCycles.records,
                completedApps: cycleInitialRebuildCompletedApps
            ).isEmpty { return }
        }

        isCycleRebuilding = true
        isScanning = true
        defer {
            isCycleRebuilding = false
            isScanning = false
            scanProgress = nil
            if scanQueued {
                Task { await scanNow() }
            }
        }
        let progress: ScanProgressCallback? = { [weak self] progress in
            DispatchQueue.main.async { self?.scanProgress = progress }
        }
        let cycles = appState.quotaCycles.records
        let pendingApps = Self.pendingInitialCycleRebuildApps(
            cycles: cycles,
            completedApps: cycleInitialRebuildCompletedApps
        )
        guard !pendingApps.isEmpty else { return }
        let claudeTask: Task<ClaudeJSONLScanner.Result, Never>? = pendingApps.contains(.claude)
            ? Task.detached(priority: .utility) {
                ClaudeJSONLScanner.scan(
                    previous: [:],
                    seenMessageIds: [],
                    onProgress: progress
                )
            }
            : nil
        let codexTask: Task<CodexJSONLScanner.Result, Never>? = pendingApps.contains(.codex)
            ? Task.detached(priority: .utility) {
                await CodexJSONLScanner.scan(previous: [:], seenTokenIds: [], onProgress: progress)
            }
            : nil
        let claude = await claudeTask?.value
        let codex = await codexTask?.value
        let pendingCycles = cycles.filter { pendingApps.contains($0.app) }
        let failedApps = Self.cycleRebuildFailedApps(
            claude: claude,
            codex: codex,
            cycles: pendingCycles
        )
        let pendingCycleIDs = Set(pendingCycles.map(\.id))
        let rebuildableCycleIDs = Self.cycleRebuildableCycleIDs(
            cycles: pendingCycles,
            requestedCycleIDs: pendingCycleIDs,
            failedApps: failedApps
        )
        await commitCycleAggregation(
            exactEntries: ((claude?.entries ?? []) + (codex?.entries ?? []))
                .filter { !failedApps.contains($0.app) },
            cycles: cycles,
            accountSegments: appState.quotaCycles.accountSegments,
            initialRebuildApps: pendingApps,
            failedApps: failedApps,
            rebuildRange: rebuildableCycleIDs
        )
    }

    /// 决定本轮扫描的起点状态。优先用内存里上一轮已提交的 ScanState；
    /// 内存路径与磁盘路径执行同样的结构校验——generationID 须与已加载 rollup 同代。
    /// 价格指纹不参与失效判定：价格目录更新后自动扫描按现价计新条目，
    /// 历史桶保持旧价，等用户在设置页「重新计算用量」手动全量重扫对齐。
    /// 只有冷启动且日聚合、对话两份主 rollup 恢复成功时，
    /// 首轮需要读盘取得与它们同代的 ScanState。
    private func resolveScanState() async -> ScanCacheLoadResult {
        if requiresFullRebuild { return .invalidated }
        if let cached = cachedScanState {
            if cached.generationID == loadedRollupGeneration {
                return .valid(cached)
            }
            return .invalidated
        }
        let loaded = await Task.detached(priority: .utility) {
            ScanCache.load()
        }.value
        if case .valid(let state) = loaded, state.generationID == loadedRollupGeneration {
            return loaded
        }
        return .invalidated
    }

    /// 用户在设置页手动触发的强制重算：无视已有 watermark 和 fingerprint，
    /// 清空内存聚合并把本地全部日志按当前已提交的价格目录重新解析、重新计费。
    /// 用于「定价表改错后修复，想立刻重算」这类场景，不必等下次价格表变动或重启 App。
    func forceRescan() async {
        // 撞上另一次进行中的扫描(常见于 App 冷启动自动扫描、或 Scheduler 定时扫描)时,
        // 不再静默丢弃这次操作:等它跑完再真正强制重算,保证用户点的这次一定生效。
        // 设置页按钮的 spinner 在等待期间会一直转,用户感知不到差异,只是变"诚实"了。
        while isScanning {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        isScanning = true
        defer {
            isScanning = false
            scanProgress = nil
        }
        PricingCatalogStore.shared.refreshIfNeeded()
        // 手动重算同样是一次完整扫描：先提交已经刷好的 pending，避免用户刚点击重算
        // 却仍按旧 active 价格扫描；本次刚发起的网络刷新则留给下一次扫描。
        PricingCatalogStore.shared.commitPending()
        cachedScanState = nil
        aggregator.load(from: [])
        conversationAggregator.load(infos: [], buckets: [])
        cycleAggregator.load(from: [])
        loadedRollupGeneration = nil
        loadedCycleGeneration = nil
        cycleInitialRebuildCompletedAt = nil
        cycleInitialRebuildCompletedApps = []
        publishTotals()
        requiresFullRebuild = true
        if await runScan(prev: ScanState(), reportProgress: true) {
            requiresFullRebuild = false
            // 全量重扫已按现有周期记录重灌全部桶，窗口外的缺口就此补齐。
            cycleUsageNeedsManualRecalculation = false
            hasPendingOrphanCycleRebuild = false
            if await refreshMissingPricingIfNeeded() {
                // 强制重算没有 scanNow 的 repeat 循环；缺价刷新拿到新价格后就在这里
                // 立即再做一次全量扫描，避免必须等待下一次定时扫描。
                cachedScanState = nil
                aggregator.load(from: [])
                conversationAggregator.load(infos: [], buckets: [])
                cycleAggregator.load(from: [])
                loadedRollupGeneration = nil
                loadedCycleGeneration = nil
                publishTotals()
                requiresFullRebuild = true
                if await runScan(prev: ScanState(), reportProgress: true) {
                    requiresFullRebuild = false
                }
            }
        }
    }

    /// 设置页手动更新在线价格目录：绕过 24 小时拉取最新目录，新价格在下一轮扫描的
    /// 安全边界提交生效。只更新价格表，不触发重算；历史费用保持旧价，
    /// 需要对齐历史时用「重新计算用量」（forceRescan）。
    @discardableResult
    func refreshPricingCatalog() async -> Bool {
        guard !isRefreshingPricingCatalog else { return false }
        isRefreshingPricingCatalog = true
        defer { isRefreshingPricingCatalog = false }
        return await PricingCatalogStore.shared.forceRefresh()
    }

    /// - Parameter allowDeferredWrite: 允许把本轮聚合结果留在内存里、等到节流窗口到期
    ///   再统一落盘。只有常规周期扫描（`scanNow`）传 true；强制重算与周期重建前的
    ///   drain 必须立刻提交，否则后续步骤会基于未落盘的状态继续推进。
    @discardableResult
    private func runScan(
        prev: ScanState,
        reportProgress: Bool = false,
        allowDeferredWrite: Bool = false
    ) async -> Bool {
        let started = Date()
        let prevSeen = prev.claudeSeenMessageIds
        let progress: ScanProgressCallback?
        if reportProgress {
            progress = { [weak self] (p: ScanProgress) in
                DispatchQueue.main.async {
                    self?.scanProgress = p
                }
            }
        } else {
            progress = nil
        }
        async let claudeTask = Task.detached(priority: .utility) {
            ClaudeJSONLScanner.scan(
                previous: prev.claude,
                seenMessageIds: prevSeen,
                onProgress: progress
            )
        }.value
        async let codexTask = Task.detached(priority: .utility) {
            await CodexJSONLScanner.scan(
                previous: prev.codex,
                seenTokenIds: prev.codexSeenTokenIds,
                onProgress: progress
            )
        }.value
        async let piTask = Task.detached(priority: .utility) {
            PiJSONLScanner.scan(
                previous: prev.pi,
                seenEntryIds: prev.piSeenEntryIds,
                onProgress: progress
            )
        }.value
        async let opencodeTask = Task.detached(priority: .utility) {
            OpencodeScanner.scan(
                lastMessageTime: prev.opencodeLastMessageTime,
                seenMessageIds: prev.opencodeSeenMessageIds,
                onProgress: progress
            )
        }.value

        let claude = await claudeTask
        let codex = await codexTask
        let pi = await piTask
        let opencode = await opencodeTask
        let failedFileCount = claude.failedFileCount + codex.failedFileCount

        aggregator.ingestLocal(claude.entries)
        aggregator.ingestLocal(codex.entries)
        aggregator.ingestLocal(pi.entries)
        aggregator.ingestLocal(opencode.entries)
        let cycleEntries = claude.entries + codex.entries
        let conversationChanged = conversationAggregator.ingest(
            entries: claude.entries + codex.entries + pi.entries + opencode.entries,
            seeds: claude.conversationSeeds + codex.conversationSeeds + pi.conversationSeeds + opencode.conversationSeeds
        )

        // 个人历史用量一次性补录：缓存失效路径会清空聚合器，若只在 bootstrap 合并，
        // 清空后落盘的 rollup 将丢失补录数据。每轮扫描都按天去重重新合并，
        // 保证任何一次落盘的快照都包含补录用量。
        let existingClaudeDays = Set(aggregator.snapshotLocal().filter { $0.app == .claude }.map(\.day))
        aggregator.ingestLocal(ImportedUsageBackfill.loadMissingEntries(app: .claude, existingDays: existingClaudeDays))

        let cycles = appState?.quotaCycles.records ?? []
        let cycleChanged: Bool
        if prev.generationID.isEmpty, !cycles.isEmpty {
            let initialApps = Self.pendingInitialCycleRebuildApps(
                cycles: cycles,
                completedApps: cycleInitialRebuildCompletedApps
            )
            let initialCycles = cycles.filter { initialApps.contains($0.app) }
            let failedApps = Self.cycleRebuildFailedApps(
                claude: claude,
                codex: codex,
                cycles: initialCycles
            )
            let initialCycleIDs = Set(initialCycles.map(\.id))
            let rebuildableCycleIDs = Self.cycleRebuildableCycleIDs(
                cycles: initialCycles,
                requestedCycleIDs: initialCycleIDs,
                failedApps: failedApps
            )
            cycleAggregator.rebuildRange(
                exactEntries: cycleEntries.filter { !failedApps.contains($0.app) },
                cycles: cycles,
                accountSegments: appState?.quotaCycles.accountSegments ?? [],
                affectedCycleIDs: rebuildableCycleIDs
            )
            cycleInitialRebuildCompletedApps = Self.updatedInitialCycleRebuildApps(
                completedApps: cycleInitialRebuildCompletedApps,
                requestedApps: initialApps,
                failedApps: failedApps
            )
            let requiredApps = Set(cycles.map(\.app)).intersection([.codex, .claude])
            if cycleInitialRebuildCompletedApps.isSuperset(of: requiredApps) {
                cycleInitialRebuildCompletedAt = Date()
            }
            cycleChanged = true
        } else {
            cycleChanged = cycleAggregator.ingest(
                entries: cycleEntries,
                cycles: cycles,
                accountSegments: appState?.quotaCycles.accountSegments ?? []
            )
        }

        // 没有真实用量或档案变化时沿用现有代次，只提交轻量 watermark。
        let buckets = aggregator.snapshotLocal()
        let fingerprint = Pricing.fingerprint(knownUsage: pricingUsageKeys(from: buckets))
        let hasNewEntries = !claude.entries.isEmpty || !codex.entries.isEmpty || !pi.entries.isEmpty || !opencode.entries.isEmpty
        if hasNewEntries || conversationChanged { hasUnwrittenRollupChanges = true }
        // 尚未建立代次时必须立刻落盘，否则内存与磁盘无从对齐。
        let mustWriteRollups = loadedRollupGeneration == nil
        let throttleElapsed = lastRollupWriteAt.map {
            started.timeIntervalSince($0) >= Self.rollupWriteInterval
        } ?? true
        let shouldWriteRollups = mustWriteRollups
            || (hasUnwrittenRollupChanges && (!allowDeferredWrite || throttleElapsed))
        let generationID = shouldWriteRollups ? UUID().uuidString : loadedRollupGeneration!
        let newScanState = ScanState(
            generationID: generationID,
            pricingFingerprint: fingerprint,
            claude: claude.newState,
            codex: codex.newState,
            claudeSeenMessageIds: claude.newSeenIds,
            codexSeenTokenIds: codex.newSeenIds,
            pi: pi.newState,
            piSeenEntryIds: pi.newSeenIds,
            opencodeLastMessageTime: opencode.newLastMessageTime,
            opencodeSeenMessageIds: opencode.newSeenMessageIds
        )
        // watermark 绝不能单独越过尚未落盘的聚合数据：那样重启后会拿到
        // 「新 watermark + 旧 rollup」的同代组合，中间那段用量永久丢失。
        // 因此只有本轮真的写 rollup、或压根没有待落盘数据时，才允许提交 watermark。
        let commitsThisRound = shouldWriteRollups || !hasUnwrittenRollupChanges
        let shouldWriteScanState = commitsThisRound && newScanState != prev

        let rollup: UsageRollupPayload?
        let conversationRollup: ConversationRollupPayload?
        let cycleRollup: CycleUsageRollupPayload?
        if shouldWriteRollups {
            let updatedAt = Date()
            let conversationSnapshot = conversationAggregator.snapshot()
            rollup = UsageRollupPayload(
                generationID: generationID,
                pricingFingerprint: fingerprint,
                buckets: buckets,
                updatedAt: updatedAt
            )
            conversationRollup = ConversationRollupPayload(
                generationID: generationID,
                pricingFingerprint: fingerprint,
                infos: conversationSnapshot.infos,
                buckets: conversationSnapshot.buckets,
                updatedAt: updatedAt
            )
            cycleRollup = CycleUsageRollupPayload(
                generationID: generationID,
                pricingFingerprint: fingerprint,
                buckets: cycleAggregator.snapshot(),
                initialRebuildCompletedAt: cycleInitialRebuildCompletedAt,
                initialRebuildCompletedApps: cycleInitialRebuildCompletedApps,
                updatedAt: updatedAt
            )
        } else {
            rollup = nil
            conversationRollup = nil
            // 周期桶同理：领先于 watermark 会在下轮增量扫描时被重复灌入。
            if commitsThisRound, cycleChanged || loadedCycleGeneration == nil {
                cycleRollup = CycleUsageRollupPayload(
                    generationID: generationID,
                    pricingFingerprint: fingerprint,
                    buckets: cycleAggregator.snapshot(),
                    initialRebuildCompletedAt: cycleInitialRebuildCompletedAt,
                    initialRebuildCompletedApps: cycleInitialRebuildCompletedApps,
                    updatedAt: Date()
                )
            } else {
                cycleRollup = nil
            }
        }

        let persistenceError: String? = await Task.detached(priority: .utility) {
            do {
                if let rollup, let conversationRollup {
                    // 聚合结果先落盘，watermark 最后提交；generationID 用于启动时识别中断写入。
                    try UsageRollupCache.save(rollup)
                    try ConversationRollupCache.save(conversationRollup)
                }
                if let cycleRollup {
                    try CycleUsageRollupCache.save(cycleRollup)
                }
                if shouldWriteScanState {
                    try ScanCache.save(newScanState)
                }
                return nil
            } catch {
                let saveError = error
                do {
                    try ScanCache.invalidate()
                } catch {
                    return "\(saveError); scan-state invalidate failed: \(error)"
                }
                return String(describing: saveError)
            }
        }.value

        if let persistenceError {
            requiresFullRebuild = true
            cachedScanState = nil
            lastError = persistenceError
            print("[UsageScan 用量扫描] 持久化失败 persistence failed: \(persistenceError)")
            return false
        }

        if shouldWriteRollups {
            hasUnwrittenRollupChanges = false
            lastRollupWriteAt = Date()
        }
        loadedRollupGeneration = generationID
        if cycleRollup != nil {
            loadedCycleGeneration = generationID
        }
        cachedScanState = newScanState
        lastScanAt = Date()
        lastError = failedFileCount > 0
            ? "usage scan incomplete: \(failedFileCount) log source(s) unreadable; retrying next scan"
            : nil
        publishTotals()

        let elapsed = String(format: "%.2fs", Date().timeIntervalSince(started))
        print("[UsageScan 用量扫描] claude files=\(claude.filesScanned) lines=\(claude.linesParsed) new=\(claude.entries.count); codex files=\(codex.filesScanned) lines=\(codex.linesParsed) new=\(codex.entries.count); pi files=\(pi.filesScanned) lines=\(pi.linesParsed) new=\(pi.entries.count); opencode messages=\(opencode.messagesRead) new=\(opencode.entries.count); unreadable=\(failedFileCount); elapsed=\(elapsed)")
        return true
    }

    /// 只把“已有 Standard/Fast 用量但当前所有可靠价格源都未命中”的桶视为刷新候选。
    /// Unknown 档位和已知模型的请求级限制（例如 Codex Fast >272K）不会造成无休止刷新。
    /// 仅手动重算（forceRescan）路径调用；自动扫描不做缺价刷新、也不因缺价排队重算。
    private func refreshMissingPricingIfNeeded() async -> Bool {
        let buckets = aggregator.snapshotLocal()
        let missing = Set(buckets.compactMap { bucket -> PricingUsageKey? in
            guard bucket.hasUnpricedUsage else { return nil }
            guard Pricing.needsRemotePriceRefresh(
                model: bucket.model,
                app: bucket.app,
                speed: bucket.speed
            ) else { return nil }
            return PricingUsageKey(app: bucket.app, model: bucket.model, speed: bucket.speed)
        })
        guard !missing.isEmpty else { return false }

        let knownUsage = pricingUsageKeys(from: buckets)
        let before = Pricing.fingerprint(knownUsage: knownUsage)
        guard await PricingCatalogStore.shared.refreshForMissing(missing) else { return false }
        PricingCatalogStore.shared.commitPending()
        let after = Pricing.fingerprint(knownUsage: knownUsage)
        return before != after
    }

    private func pricingUsageKeys(from buckets: [UsageBucket]) -> Set<PricingUsageKey> {
        Set(buckets.map {
            PricingUsageKey(app: $0.app, model: $0.model, speed: $0.speed)
        })
    }

    private func publishTotals() {
        guard let appState else { return }
        appState.codexTodayCost = aggregator.todayCost(for: .codex)
        appState.claudeTodayCost = aggregator.todayCost(for: .claude)
        appState.cursorTodayCost = aggregator.todayCost(for: .cursor)
        appState.piTodayCost = aggregator.todayCost(for: .pi)
        appState.opencodeTodayCost = aggregator.todayCost(for: .opencode)
    }
}
