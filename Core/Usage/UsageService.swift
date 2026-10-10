import Foundation
import Observation

/// 本地扫描器使用的日志根目录与标题索引。
///
/// 生产走家目录下的真实路径；测试注入临时目录与空索引，避免任何一次扫描碰到用户真实日志。
nonisolated struct UsageScanRoots: Sendable {
    var claudeRoot: URL
    var claudeConversationIndex: @Sendable () -> ConversationTitleIndex.ClaudeIndex
    var codexRoots: [URL]
    var codexTitles: @Sendable () -> [String: String]
    var piRoot: URL
    var opencodeDatabaseURL: URL
    var dshRoot: URL

    static var production: UsageScanRoots {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return UsageScanRoots(
            claudeRoot: ClaudeJSONLScanner.defaultRoot(),
            claudeConversationIndex: { ConversationTitleIndex.claudeIndex() },
            codexRoots: [
                home.appendingPathComponent(".codex/sessions", isDirectory: true),
                home.appendingPathComponent(".codex/archived_sessions", isDirectory: true),
            ],
            codexTitles: { ConversationTitleIndex.codexTitles() },
            piRoot: home.appendingPathComponent(".pi/agent/sessions", isDirectory: true),
            opencodeDatabaseURL: OpencodeScanner.defaultDatabaseURL(),
            dshRoot: DshSessionScanner.defaultRoot
        )
    }
}

/// 本次启动的历史来源，供诊断与 UI 区分「正常」「回退上一份」「迁移旧文件」「首装」。
nonisolated enum UsageHistoryLoadSource: Sendable, Equatable {
    case current
    /// 回退到上一份完整提交。`committedAt` 是它能保证的最新时点：
    /// 该时点之后被删除的日志无法从备份补回，必须如实展示这个边界。
    case previous(reason: String, committedAt: Date)
    case migratedLegacy
    case firstInstall
    /// current 是更新版本格式：只读展示，禁止写入。
    case unsupportedCurrent(String)
    /// 已有历史无法加载，保留全部文件并禁止采集、迁移和覆盖。
    case unavailable(String)

    var isRestored: Bool {
        switch self {
        case .previous, .migratedLegacy: return true
        case .current, .firstInstall, .unsupportedCurrent, .unavailable: return false
        }
    }
}

/// UI 需要的恢复状态摘要。服务只给结构化状态，文案在展示层拼装（`tr`）。
nonisolated struct UsageHistoryRecoveryNotice: Sendable, Equatable {
    /// 回退到的提交时点；与本次启动的 current 无关，nil 表示没有发生回退。
    var restoredFromPreviousAt: Date?
    /// 历史可用但无法安全续扫：核对通过后才能恢复采集。
    var isRestricted: Bool
    /// 快照由更新版本写入：只读展示，重算也无法写入。
    var isReadOnly: Bool

    var isDshFrozen: Bool = false
    var isUnavailable: Bool = false
    var verificationRejected: Bool = false

    /// 允许重试核对，不承诺日志变化或缺失时能恢复。
    var canRetryVerification: Bool { isRestricted && !isReadOnly }
}

nonisolated struct UsageHistoryLoad: Sendable {
    var snapshot: UsageSnapshot?
    var source: UsageHistoryLoadSource
    var degradeReasons: [UsageSnapshotDegradeReason] = []
    var writeDisabled = false
    var diagnostic: String?
}

/// 一次候选重算的完整结果。
private struct RebuildCandidate {
    var dayBuckets: [UsageBucket]
    var conversationInfos: [ConversationInfo]
    var conversationBuckets: [ConversationUsageBucket]
    var cycleBuckets: [CycleUsageBucket]
    var cycleInitialRebuildCompletedAt: Date?
    var cycleInitialRebuildCompletedApps: Set<UsageApp>
    var dshContributions: [String: DshContribution]
    var dshRequiresRebuild: Bool
    var scanState: ScanState
    /// 非 nil 表示来源不完整，候选不可提交。
    var incompleteSources: String?
    /// 与重建前历史的差异。受限恢复据此拒绝；手动 / 自动重建只作诊断记录。
    var mismatch: UsageRebuildMismatch
    /// 重扫计入的消息 ID，加上被保留的已删除对话原有的 ID。
    var messageLedger: UsageMessageLedger
    var rebuildBasis: UsageRebuildBasis
    /// 保留的已删除日志对话数，以及因重扫已覆盖而没有叠加的桶数。
    var preservedConversations = 0
    var skippedBuckets = 0
}

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

    /// 历史恢复状态。受限时不再自动全量重扫，历史照常展示。
    private(set) var historyRecoveryState: UsageHistoryRecoveryState = .complete
    /// 本次启动的历史来源与可恢复边界（含回退时点）。
    private(set) var historyLoadSource: UsageHistoryLoadSource = .firstInstall
    /// 加载时记录的降级原因（透明报告，不阻塞展示）。
    private(set) var historyDegradeReasons: [UsageSnapshotDegradeReason] = []
    /// 最近一次手动重算 / 受限核对的结构化结果。
    private(set) var lastRebuildOutcome: UsageRebuildOutcome?
    /// 最近一次重算被拒的脱敏摘要（键数量级），供 UI 与诊断说明拒绝原因。
    private(set) var lastRebuildDiagnostic: String?
    /// 主历史含 DSH 分区但逐会话贡献不可用：冻结该分区，既不增量也不重建。
    private(set) var isDshHistoryFrozen = false
    /// 正在完整重建历史（手动或自动）。设置页据此禁用「重新计算」并显示进度。
    private(set) var isRebuildingHistory = false
    /// 价格或统计规则变化后自动重建历史。单测默认关闭，避免干扰既有用例的提交次数与快照断言；
    /// 覆盖自动重建的用例显式打开。
    var automaticRebuildEnabled = !AppRuntime.isRunningUnitTests

    /// 按对话记录的已计入消息 ID，与汇总同代提交、同步回滚。
    private var messageLedger = UsageMessageLedger()
    /// 现有历史对应的统计规则与价格。nil 表示还没有建立（升级后首次）：
    /// 此时账本不完整，增量去重仍沿用 seen 列表，并尽快自动重建一次。
    private var rebuildBasis: UsageRebuildBasis?
    /// 用户刚手动更新过价格目录：价格有变化就立即重建，不等 24 小时。
    private var catalogUpdateRequestedByUser = false
    /// 本进程最近一次自动重建未提交的时间；之后 24 小时内不再自动重试。
    private var lastAutomaticRebuildFailureAt: Date?
    private var isRefreshingMissingPricing = false
    /// 远端价格普通变化的自动重建间隔、自动失败后的重试间隔、自动补价的同模型间隔。
    nonisolated private static let automaticRebuildInterval: TimeInterval = 24 * 3600

    private let historyStore: UsageSnapshotStore
    private let roots: UsageScanRoots
    private let legacyLocations: LegacyUsageHistoryLocations
    /// 个人历史补录文件位置；nil 走生产路径。测试注入不存在的路径，保证不读用户真实数据。
    private let backfillURL: URL?
    /// Cursor 远端缓存目录；nil 走生产路径。测试注入临时目录。
    private let cursorCacheDirectory: URL?

    /// 上一份成功提交的快照。写入失败时用它把内存回滚到与磁盘一致的状态。
    private var committedSnapshot: UsageSnapshot?
    /// 存储不可写（current 是更新版本格式）时只读运行。
    private var storeWriteDisabled = false
    /// 受限恢复的一次核对是否已在本进程尝试过，避免每轮都发起昂贵全量扫描。
    private var restrictedVerificationAttempted = false
    /// Codex 标识迁移因可重试的读取失败本进程已推迟；下次启动再试，避免每轮全量重放。
    private var codexModelIdentityMigrationDeferred = false

    #if DEBUG
    /// 在真实扫描完成、提交之前控制交错；只用于隔离测试。
    var candidateReadyForTesting: (() async -> Void)?
    var cycleReadyForTesting: (() async -> Void)?
    #endif

    private weak var appState: AppState?
    private var scanQueued = false
    private var suspendedForTermination = false
    private var isPersistingForTermination = false
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
    private var cursorCacheNeedsPersistence = false
    private var cursorRemoteAccountID: String?
    private var cursorRemoteBackoffUntil: Date?
    private(set) var isRefreshingCursorRemoteUsage = false
    private(set) var cursorRemoteUsageError: String?

    init(
        historyStore: UsageSnapshotStore = .production,
        roots: UsageScanRoots = .production,
        legacyLocations: LegacyUsageHistoryLocations = .production,
        backfillURL: URL? = nil,
        cursorCacheDirectory: URL? = nil
    ) {
        self.historyStore = historyStore
        self.roots = roots
        self.legacyLocations = legacyLocations
        self.backfillURL = backfillURL
        self.cursorCacheDirectory = cursorCacheDirectory
    }

    /// 统计页读取的完整 Cursor 自然日覆盖范围。只有身份匹配的独立远端缓存会进入此集合。
    var cursorUsageCoveredDayRanges: [CursorUsageDayRange] {
        cursorUsageCache.coveredDayRanges
    }

    /// 诊断用：DSH 逐会话贡献缓存里的会话数（不含会话路径、标题与正文）。
    var dshTrackedSessionCount: Int {
        dshContributions.count
    }

    /// 展示层的恢复摘要；正常启动时为 nil。
    var historyRecoveryNotice: UsageHistoryRecoveryNotice? {
        var restoredAt: Date?
        if case .previous(_, let committedAt) = historyLoadSource {
            restoredAt = committedAt
        }
        let readOnly = storeWriteDisabled
        if readOnly, let snapshot = committedSnapshot { restoredAt = snapshot.committedAt }
        let restricted = historyRecoveryState != .complete
        guard restoredAt != nil || restricted || readOnly || isDshHistoryFrozen else { return nil }
        return UsageHistoryRecoveryNotice(
            restoredFromPreviousAt: restoredAt,
            isRestricted: restricted,
            isReadOnly: readOnly,
            isDshFrozen: isDshHistoryFrozen,
            isUnavailable: historyRecoveryState == .unavailable,
            verificationRejected: historyRecoveryState == .verificationRejected
        )
    }

    /// 测试缝：仍待复核的 DSH 会话 ID 集合（不含路径、标题与正文）。
    func dshUnverifiedSessionIDsForTesting() -> Set<String> {
        Set(dshContributions.filter { $0.value.needsVerification == true }.keys)
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
    /// 不重写磁盘快照。整份快照是本机实测数 MB 级（conversation 3.4MB + scan-state 2.6MB
    /// 量级），活跃编码时按 5 分钟扫描周期写等于每小时数十 MB。
    /// 代价只是 App 意外退出后下次启动多重扫这段窗口内的增量日志（秒级），不丢数据：
    /// 未落盘期间 watermark 一并压住，盘上永远是「汇总与进度同代同进度」。
    nonisolated private static let rollupWriteInterval: TimeInterval = 15 * 60
    /// 已进入内存聚合但尚未落盘的用量变化。
    private var hasUnwrittenRollupChanges = false
    private var lastRollupWriteAt: Date?

    /// 上一轮成功提交的 ScanState 常驻内存，避免每轮扫描都从磁盘重读重解码。
    /// 冷启动首轮才从快照恢复；快照没有可信进度时为 nil，此时不允许续扫。
    private var cachedScanState: ScanState?

    var hasActiveOperationsForTermination: Bool {
        isScanning || isCycleRebuilding || isRefreshingPricingCatalog
            || isRefreshingCursorRemoteUsage || isPersistingForTermination
    }

    func suspendForTermination() {
        suspendedForTermination = true
        scanQueued = false
    }

    func resumeAfterCancelledTermination() {
        suspendedForTermination = false
    }

    /// 提交已经聚合的用量与对应 watermark，不重新读取日志、不改变计价口径。
    /// 保存失败保留内存中的 pending，用户可在取消退出后重试。
    func persistPendingForTermination() async throws {
        guard !hasActiveOperationsForTermination else { throw AppTerminationError.busy }
        isPersistingForTermination = true
        defer { isPersistingForTermination = false }
        if cursorCacheNeedsPersistence {
            let cache = cursorUsageCache
            let directory = cursorCacheDirectory
            try await Task.detached(priority: .utility) {
                try CursorUsageCache.save(cache, in: directory)
            }.value
            cursorCacheNeedsPersistence = false
        }
        guard !storeWriteDisabled else { return }
        let hasUnwrittenProgress = cachedScanState != nil && cachedScanState != committedSnapshot?.scanState
        guard hasUnwrittenRollupChanges || hasUnwrittenProgress else { return }
        guard let previousState = cachedScanState ?? committedSnapshot?.scanState else { return }

        // 没有可信进度的迁移历史按原 snapshot 保存，不能在退出时标成完整历史。
        if cachedScanState == nil, let snapshot = committedSnapshot {
            if let error = await persistExistingSnapshot(snapshot) {
                throw AppTerminationError.saveFailed(Redact.message(error))
            }
            hasUnwrittenRollupChanges = false
            lastRollupWriteAt = Date()
            return
        }
        var scanState = previousState
        let snapshotID = UUID().uuidString
        scanState.generationID = snapshotID
        let conversation = conversationAggregator.snapshot()
        let error = await persistSnapshot(
            snapshotID: snapshotID,
            fingerprint: scanState.pricingFingerprint,
            hasScanProgress: true,
            // 退出只保存现状，不能把尚未核对的降级原因当成已经修复。
            integrity: committedSnapshot?.integrity ?? .complete,
            degradeReasons: committedSnapshot?.degradeReasons ?? historyDegradeReasons,
            dshHistoryFrozen: isDshHistoryFrozen,
            scanState: scanState,
            buckets: aggregator.snapshotLocal(),
            conversationInfos: conversation.infos,
            conversationBuckets: conversation.buckets,
            cycleBuckets: cycleAggregator.snapshot(),
            cycleInitialRebuildCompletedAt: cycleInitialRebuildCompletedAt,
            cycleInitialRebuildCompletedApps: cycleInitialRebuildCompletedApps,
            dshContributions: dshContributions,
            dshRequiresRebuild: dshNeedsFullRescan
        )
        if let error { throw AppTerminationError.saveFailed(Redact.message(error)) }
        cachedScanState = scanState
        loadedRollupGeneration = snapshotID
        loadedCycleGeneration = snapshotID
        hasUnwrittenRollupChanges = false
        lastRollupWriteAt = Date()
    }

    /// DSH 逐会话贡献缓存（常驻内存副本）。它是 DSH 日 / 对话分区的唯一来源：
    /// 每轮从全部贡献重新归并并**整体替换** DSH 分区，避免 generation 切换或父链变化把历史加两遍。
    private var dshContributions: [String: DshContribution] = [:]
    /// 贡献缓存缺失、版本不符或代次不一致：下一轮 DSH 必须从零全量重扫（§3.3）。
    private var dshNeedsFullRescan = true

    // MARK: - 启动

    func bootstrap(appState: AppState) async {
        self.appState = appState
        let store = historyStore
        let legacyLocations = self.legacyLocations
        let load = await Task.detached(priority: .utility) {
            Self.loadInitialHistory(store: store, legacyLocations: legacyLocations)
        }.value

        storeWriteDisabled = load.writeDisabled
        historyLoadSource = load.source
        historyDegradeReasons = load.degradeReasons
        if let diagnostic = load.diagnostic {
            AppLog.warn(.usage, "usage history load: \(diagnostic)")
        }
        if let snapshot = load.snapshot {
            apply(snapshot: snapshot)
            // 迁移结果要先成为新的真源，下一次启动不再回读旧文件。
            if load.source == .migratedLegacy, !storeWriteDisabled {
                if let error = await persistExistingSnapshot(snapshot) {
                    lastError = "usage history migration could not be saved: \(error)"
                    hasUnwrittenRollupChanges = true
                    lastRollupWriteAt = nil
                    AppLog.error(.usage, "usage history migration commit failed: \(Redact.message(error))")
                }
            }
        } else {
            requiresFullRebuild = true
        }
        switch load.source {
        case .previous(let reason, _):
            AppLog.warn(.usage, "usage history restored from previous snapshot reason=\(Redact.message(reason))")
        case .migratedLegacy:
            AppLog.info(.usage, "usage history migrated from legacy caches")
        case .unavailable(let reason):
            historyRecoveryState = .unavailable
            lastError = "usage history unavailable; local collection paused: \(reason)"
        case .unsupportedCurrent:
            lastError = "usage history format unsupported; running read-only"
            AppLog.error(.usage, "usage history current snapshot version unsupported; read-only")
        case .current, .firstInstall:
            break
        }

        let cursorCacheDirectory = self.cursorCacheDirectory
        let cursorPayload = await Task.detached(priority: .utility) {
            CursorUsageCache.load(in: cursorCacheDirectory)
        }.value
        cursorUsageCache = cursorPayload

        // 个人历史用量一次性补录：见 ImportedUsageBackfill 注释。这里先合并一次保证扫描前即可展示；
        // runScan 每轮还会按同样规则重新合并，兜底缓存失效清空聚合器的情况。文件不存在时是纯 no-op。
        mergeImportedBackfill()
        if historyRecoveryState != .complete, !storeWriteDisabled {
            lastError = Self.restrictedHistoryMessage
        }
        publishTotals()
        // 远端价格目录后台刷新：非阻塞，isDue 内部判断是否真的需要发请求，刷新结果由下次扫描自然拾取。
        PricingCatalogStore.shared.refreshIfNeeded()
    }

    /// 只有从未建立新存储且没有新快照证据时，才允许旧格式迁移。
    private nonisolated static func loadInitialHistory(
        store: UsageSnapshotStore,
        legacyLocations: LegacyUsageHistoryLocations
    ) -> UsageHistoryLoad {
        let current = store.loadCurrent()
        if case .valid(let snapshot) = current {
            return UsageHistoryLoad(snapshot: snapshot, source: .current)
        }
        let previous = store.loadPrevious()
        if let reason = current.invalidReason, reason.isUnsupported {
            return UsageHistoryLoad(
                snapshot: previous.snapshot,
                source: .unsupportedCurrent(reason.description),
                writeDisabled: true,
                diagnostic: reason.description
            )
        }
        if case .valid(let snapshot) = previous {
            let reason = current.invalidReason?.description ?? "current missing"
            // 只有已确认备份可用才隔离 current；全部不可用时原文件留在原处。
            if current.invalidReason != nil { store.quarantineCurrent() }
            return UsageHistoryLoad(
                snapshot: snapshot,
                source: .previous(reason: reason, committedAt: snapshot.committedAt),
                diagnostic: "previous restored: \(reason)"
            )
        }
        if let reason = previous.invalidReason, reason.isUnsupported {
            return UsageHistoryLoad(
                snapshot: nil, source: .unsupportedCurrent(reason.description),
                writeDisabled: true, diagnostic: reason.description
            )
        }
        if store.hasHistoryEvidence {
            let reason = "no usable snapshot; current=\(current.invalidReason?.description ?? "missing"), previous=\(previous.invalidReason?.description ?? "missing")"
            return UsageHistoryLoad(
                snapshot: nil, source: .unavailable(reason),
                writeDisabled: true, diagnostic: reason
            )
        }
        return fallBackToLegacy(legacyLocations: legacyLocations, diagnostic: nil)
    }

    private nonisolated static func fallBackToLegacy(
        legacyLocations: LegacyUsageHistoryLocations,
        diagnostic: String?
    ) -> UsageHistoryLoad {
        switch LegacyUsageHistoryImport.makeSnapshot(locations: legacyLocations) {
        case .firstInstall:
            return UsageHistoryLoad(
                snapshot: nil,
                source: .firstInstall,
                diagnostic: diagnostic
            )
        case .imported(let snapshot):
            return UsageHistoryLoad(
                snapshot: snapshot,
                source: .migratedLegacy,
                degradeReasons: snapshot.degradeReasons,
                diagnostic: diagnostic
            )
        case .unusable(let reason, let detail):
            return UsageHistoryLoad(
                snapshot: nil,
                source: .unavailable(detail),
                degradeReasons: [reason],
                writeDisabled: true,
                diagnostic: diagnostic.map { "\($0); legacy \(detail)" } ?? "legacy \(detail)"
            )
        }
    }

    /// 把一份快照装进内存聚合器。只做状态装载，不写盘。
    private func apply(snapshot: UsageSnapshot) {
        historyDegradeReasons = snapshot.degradeReasons
        aggregator.load(from: snapshot.usageRollup.buckets)
        conversationAggregator.load(
            infos: snapshot.conversationRollup.infos,
            buckets: snapshot.conversationRollup.buckets
        )
        let validCycleIDs = Set(appState?.quotaCycles.records.map(\.id) ?? [])
        let orphanedCycleIDs = Set(snapshot.cycleRollup.buckets.map(\.cycleID))
            .subtracting(validCycleIDs)
        cycleAggregator.load(from: snapshot.cycleRollup.buckets.filter {
            validCycleIDs.contains($0.cycleID)
        })
        classifyOrphanedCycleBuckets(orphanedCycleIDs)

        loadedRollupGeneration = snapshot.snapshotID
        loadedCycleGeneration = snapshot.cycleRollup.generationID.isEmpty
            ? nil
            : snapshot.cycleRollup.generationID
        cycleInitialRebuildCompletedAt = snapshot.cycleRollup.initialRebuildCompletedAt
        cycleInitialRebuildCompletedApps = snapshot.cycleRollup.effectiveInitialRebuildCompletedApps
        cachedScanState = snapshot.hasScanProgress ? snapshot.scanState : nil
        // 没有可信进度时不能续扫：这条路径不允许被当成「空状态全量重建」。
        requiresFullRebuild = !snapshot.hasScanProgress
        if snapshot.hasScanProgress {
            historyRecoveryState = .complete
        } else {
            historyRecoveryState = .pendingVerification
        }
        restrictedVerificationAttempted = false
        isDshHistoryFrozen = snapshot.dshHistoryFrozen
        dshContributions = snapshot.dshHistoryFrozen ? [:] : snapshot.dshContributions.contributions
        dshNeedsFullRescan = snapshot.dshHistoryFrozen
            || snapshot.dshContributions.generationID.isEmpty
            || snapshot.dshContributions.requiresRebuild == true
        loadRebuildState(from: snapshot)
        hasUnwrittenRollupChanges = false
        lastRollupWriteAt = snapshot.committedAt
        lastScanAt = max(snapshot.usageRollup.updatedAt, snapshot.conversationRollup.updatedAt)
        committedSnapshot = snapshot
    }

    /// 账本不可用（旧快照、版本不认识、没有可信进度）时基准一并作废，启动后自动重建一次补齐。
    private func loadRebuildState(from snapshot: UsageSnapshot) {
        let ledgerUsable = snapshot.hasScanProgress
            && snapshot.messageLedger?.version == UsageMessageLedgerPayload.currentVersion
        messageLedger = ledgerUsable ? UsageMessageLedger(payload: snapshot.messageLedger) : UsageMessageLedger()
        rebuildBasis = ledgerUsable ? snapshot.rebuildBasis : nil
    }

    nonisolated private static let restrictedHistoryMessage =
        "usage history preserved without verified scan progress; automatic rescan paused"

    private func mergeImportedBackfill() {
        let existingClaudeDays = Set(aggregator.snapshotLocal().filter { $0.app == .claude }.map(\.day))
        aggregator.ingestLocal(
            ImportedUsageBackfill.loadMissingEntries(
                app: .claude,
                existingDays: existingClaudeDays,
                from: backfillURL
            )
        )
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
            cursorCacheNeedsPersistence = false
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
        guard !suspendedForTermination, !isPersistingForTermination else { return nil }
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
            guard !suspendedForTermination else { return nil }
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

    /// Popover 展示本计费周期（拿不到周期时回退自然周），刷新不能因已有任意缓存就遗忘
    /// 周期或本周的前半段。近期窗口负责修正迟到事件；周期 / 周内缺口单独补拉，
    /// 重叠或相邻时合并成一次请求。
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
        let billingStart = billingWindow.map { calendar.startOfDay(for: $0.lowerBound) }
        let gapStart = min(billingStart ?? weekStart, weekStart)
        let gaps = coveredDayRanges.missingRanges(in: gapStart..<now)
        let ranges = gaps + [recentStart..<now]
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
        guard !suspendedForTermination, !isPersistingForTermination else { return nil }
        activateCursorRemoteUsage(accountID: session.userID)
        guard let requestedRange = normalizedCursorHistoryRange(range, now: now, calendar: calendar) else {
            return nil
        }

        // 与周期刷新共用一个远端槽，避免相同日桶并发覆盖。这里等待正在进行的短刷新，
        // 让用户切换历史范围时的请求不会被悄悄丢弃。
        while isRefreshingCursorRemoteUsage {
            guard !Task.isCancelled, !suspendedForTermination, !isPersistingForTermination else { return nil }
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
            guard !Task.isCancelled, !suspendedForTermination else { return nil }
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

    /// 测试缝：走与生产完全相同的远端日桶落盘路径，但目录已注入临时路径。
    func storeCursorRemoteUsageForTesting(
        buckets: [UsageBucket],
        dayRange: Range<Date>,
        accountID: String
    ) async {
        await storeCursorRemoteUsage(
            CursorUsageFetchResult(buckets: buckets, dayRange: dayRange),
            accountID: accountID,
            updatedAt: Date()
        )
    }

    /// 远端日桶落盘路径；测试注入临时目录时不会写用户真实缓存。
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

        cursorCacheNeedsPersistence = true
        let cacheSnapshot = cursorUsageCache
        let cursorCacheDirectory = self.cursorCacheDirectory
        do {
            try await Task.detached(priority: .utility) {
                try CursorUsageCache.save(cacheSnapshot, in: cursorCacheDirectory)
            }.value
            cursorCacheNeedsPersistence = false
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

    // MARK: - 常规扫描

    /// Scheduler 的周期扫描入口：日志目录自上次扫描以来没有变化时整轮跳过。
    /// 手动刷新（`refreshNow`）与强制重算（`forceRescan`）直接走 `scanNow` / 全量路径，
    /// 不受门控影响，用户点了就一定扫。
    func scanPeriodically() async {
        guard !suspendedForTermination, !isPersistingForTermination else { return }
        guard UsageLogWatcher.shared.shouldScan() else {
            AppLog.debug(.usage, "usage scan skipped; no log changes since last scan")
            return
        }
        await scanNow()
    }

    /// 由 Scheduler / 手动触发；防重入。
    func scanNow() async {
        guard !suspendedForTermination, !isPersistingForTermination else { return }
        if isScanning {
            scanQueued = true
            return
        }
        isScanning = true
        defer { isScanning = false }

        if storeWriteDisabled { return }
        repeat {
            scanQueued = false
            // 借用量扫描的既有节奏当远端价格目录 24h 到期检查的心跳，不新开定时器；非阻塞。
            PricingCatalogStore.shared.refreshIfNeeded()
            PricingCatalogStore.shared.commitPending()
            if historyRecoveryState != .complete {
                await handleRestrictedRecovery()
                continue
            }
            let cacheResult = await resolveScanState()
            if case .invalidated = cacheResult {
                clearUsageAggregatesForFullRebuild()
            }
            if await runScan(prev: cacheResult.state, allowDeferredWrite: true) {
                requiresFullRebuild = false
                await rebuildAutomaticallyIfNeeded()
            }
        } while scanQueued && !suspendedForTermination
    }

    /// 受限恢复：历史可用但进度不可信。
    /// 本进程只做一次完整核对；不通过就保留历史并停止自动重扫，避免每轮发起昂贵全量扫描。
    private func handleRestrictedRecovery() async {
        guard restrictedVerificationAttempted == false else { return }
        restrictedVerificationAttempted = true
        let outcome = await runCandidateRebuild(purpose: .restrictedRecovery)
        switch outcome {
        case .replaced:
            historyRecoveryState = .complete
            historyDegradeReasons = []
            lastRebuildOutcome = .recoveredFromRestrictedHistory
            AppLog.info(.usage, "usage history restored: scanned candidate matches preserved history")
        default:
            historyRecoveryState = .verificationRejected
            lastRebuildOutcome = .restrictedRecoveryRejected
            lastError = Self.restrictedHistoryMessage
            AppLog.warn(.usage, "usage history recovery verification rejected; history preserved")
        }
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
        guard !suspendedForTermination, !isPersistingForTermination else { return }
        guard let appState, !appState.quotaCycles.records.isEmpty else { return }
        while isScanning || isCycleRebuilding {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !suspendedForTermination, !isPersistingForTermination else { return }
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
        let progress: ScanProgressCallback? = { [weak self] progress in
            DispatchQueue.main.async { self?.scanProgress = progress }
        }

        let claudeRoot = roots.claudeRoot
        let codexRoots = roots.codexRoots
        let piRoot = roots.piRoot
        let opencodeDatabaseURL = roots.opencodeDatabaseURL
        let dshRoot = roots.dshRoot
        let dshFrozen = isDshHistoryFrozen
        async let claudeTask = Task.detached(priority: .utility) {
            ClaudeJSONLScanner.scan(
                previous: [:],
                seenMessageIds: [],
                root: claudeRoot,
                // 重建只需要 entries，跳过标题索引构建（省一次索引文件解析）
                conversationIndex: ConversationTitleIndex.ClaudeIndex(titles: [:], projects: [:]),
                minimumMtime: dateFrom,
                onProgress: progress
            )
        }.value
        // Pi / OpenCode / DSH 里的 Codex 订阅用量同样归入 Codex 周期，要一起重灌。
        // OpenCode 是 SQLite 库，没有按文件时间过滤的入口，只能整库读取。
        async let piTask = Task.detached(priority: .utility) {
            PiJSONLScanner.scan(
                previous: [:],
                seenEntryIds: [],
                root: piRoot,
                minimumMtime: dateFrom,
                onProgress: progress
            )
        }.value
        async let opencodeTask = Task.detached(priority: .utility) {
            OpencodeScanner.scan(
                previous: nil,
                databaseURL: opencodeDatabaseURL,
                onProgress: progress
            )
        }.value
        // DSH 冻结时常规扫描不采集新用量，这里也不重灌，保留其旧桶。
        async let dshTask = Task.detached(priority: .utility) { () -> DshSessionScanner.Result? in
            dshFrozen
                ? nil
                : DshSessionScanner.scan(
                    previous: [:],
                    root: dshRoot,
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
        var codex = await codexTask
        if usesLegacyCodexModels { codex = Self.legacyCodexResult(codex) }
        let pi = await piTask
        let opencode = await opencodeTask
        let dsh = await dshTask
        let affectedCycles = cycles.filter { affectedCycleIDs.contains($0.id) }
        let failedApps = Self.cycleSourceFailedApps(
            Self.cycleRebuildFailedApps(
                claude: claude,
                codex: codex,
                cycles: affectedCycles
            ),
            opencode: opencode,
            opencodeDatabaseURL: opencodeDatabaseURL,
            dshFailed: dsh.map { !$0.isComplete } ?? false
        )
        let rebuildableCycleIDs = Self.cycleRebuildableCycleIDs(
            cycles: affectedCycles,
            requestedCycleIDs: affectedCycleIDs,
            failedApps: failedApps
        )
        await commitCycleAggregation(
            exactEntries: (claude.entries + codex.entries + pi.entries + opencode.entries + (dsh?.entries ?? []))
                .filter { !failedApps.contains($0.app) },
            cycles: cycles,
            accountSegments: accountSegments,
            failedApps: failedApps,
            rebuildRange: rebuildableCycleIDs,
            sourceApps: Set<UsageApp>([.claude, .codex])
                .union(CycleUsageAggregator.otherAgentSourceApps)
                .subtracting(failedApps)
                .subtracting(dshFrozen ? [.dsh] : [])
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

    /// 周期重建的来源失败集合。OpenCode 库从未存在（本机没装）是正常状态，库在却读不全才算失败；
    /// DSH 由调用方判定（扫描不完整、冻结等），默认目录从未创建时扫描本身就是完整的。
    /// 其他 Agent 只归入 Codex 周期，Codex 周期本轮不能重建时它们也不能算完成。
    nonisolated static func cycleSourceFailedApps(
        _ failedApps: Set<UsageApp>,
        opencode: OpencodeScanner.Result?,
        opencodeDatabaseURL: URL,
        dshFailed: Bool = false
    ) -> Set<UsageApp> {
        var result = failedApps
        if let opencode, opencode.error != nil || !opencode.isComplete,
           FileManager.default.fileExists(atPath: opencodeDatabaseURL.path) {
            result.insert(.opencode)
        }
        if dshFailed {
            result.insert(.dsh)
        }
        if result.contains(.codex) {
            result.formUnion(CycleUsageAggregator.otherAgentSourceApps)
        }
        return result
    }

    /// 周期统计需要覆盖的来源。有 Codex 周期时，Pi / OpenCode / DSH 里的 Codex 订阅用量也要归集。
    nonisolated static func requiredCycleSourceApps(cycles: [QuotaCycleRecord]) -> Set<UsageApp> {
        let apps = Set(cycles.map(\.app)).intersection([.codex, .claude])
        return apps.contains(.codex) ? apps.union(CycleUsageAggregator.otherAgentSourceApps) : apps
    }

    /// 重建这些来源时要清桶重灌的周期：来源本身的周期，加上其他 Agent 归入的 Codex 周期。
    nonisolated static func cyclesToRebuild(
        _ cycles: [QuotaCycleRecord],
        for sourceApps: Set<UsageApp>
    ) -> [QuotaCycleRecord] {
        let includesOtherAgents = !sourceApps.isDisjoint(with: CycleUsageAggregator.otherAgentSourceApps)
        return cycles.filter { sourceApps.contains($0.app) || (includesOtherAgents && $0.app == .codex) }
    }

    nonisolated static func pendingInitialCycleRebuildApps(
        cycles: [QuotaCycleRecord],
        completedApps: Set<UsageApp>
    ) -> Set<UsageApp> {
        requiredCycleSourceApps(cycles: cycles).subtracting(completedApps)
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
        guard !storeWriteDisabled, historyRecoveryState == .complete else { return false }
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
        // DSH 分区同属被清空的聚合结果：贡献缓存与 watermark 一并作废，下轮从零重建。
        resetDshContributions()
        messageLedger = UsageMessageLedger()
        rebuildBasis = nil
        loadedRollupGeneration = nil
        loadedCycleGeneration = nil
        cycleInitialRebuildCompletedAt = nil
        cycleInitialRebuildCompletedApps = []
        committedSnapshot = nil
        publishTotals()
    }

    /// 丢弃内存里的 DSH 贡献并安排一次从零全量重扫。
    /// 必须与清空聚合器同时发生：只清桶不清贡献会让下一轮的增量条目被当成新增再加一遍。
    private func resetDshContributions() {
        dshContributions = [:]
        dshNeedsFullRescan = true
    }

    /// 周期用量重建的公共收尾：聚合 → 落盘快照 → 更新内存状态。
    /// - Parameter initialRebuildApps: 本轮执行初始重建的 Provider；成功侧会独立置位，
    ///   失败侧保持待重试，不会让已完成 Provider 在下次启动重复全量扫描。
    /// - Parameter rebuildRange: 非 nil 表示受限重建，只重算这些周期内的桶。
    /// - Parameter sourceApps: 受限重建时只清除并重灌这些来源的桶。
    private func commitCycleAggregation(
        exactEntries: [UsageEntry],
        cycles: [QuotaCycleRecord],
        accountSegments: [QuotaCycleAccountSegment],
        initialRebuildApps: Set<UsageApp> = [],
        failedApps: Set<UsageApp> = [],
        rebuildRange affectedCycleIDs: Set<String>? = nil,
        sourceApps: Set<UsageApp>? = nil
    ) async {
        guard !storeWriteDisabled, historyRecoveryState == .complete,
              let scanState = cachedScanState,
              let generationID = loadedRollupGeneration,
              scanState.generationID == generationID else {
            lastError = "cycle usage rebuild deferred: no verified scan progress"
            return
        }
        #if DEBUG
        await cycleReadyForTesting?()
        #endif
        // Pi 自身不会读取失败，只会随 Codex 一起推迟，不单独列名。
        let failedProviderNames = [UsageApp.codex, .claude, .opencode, .dsh]
            .filter { failedApps.contains($0) }
            .map { app -> String in
                switch app {
                case .codex: return "Codex"
                case .claude: return "Claude Code"
                case .dsh: return "DSH"
                default: return "OpenCode"
                }
            }
            .joined(separator: ", ")
        let rebuildWarning = failedApps.isEmpty
            ? nil
            : "cycle usage rebuild incomplete: \(failedProviderNames) logs unreadable; previous data preserved"
        if let affectedCycleIDs, affectedCycleIDs.isEmpty, !failedApps.isEmpty {
            lastError = rebuildWarning
            AppLog.warn(.usage, "cycle usage rebuild deferred providers=\(failedProviderNames)")
            return
        }
        let started = Date()
        if let affectedCycleIDs {
            cycleAggregator.rebuildRange(
                exactEntries: exactEntries,
                cycles: cycles,
                accountSegments: accountSegments,
                affectedCycleIDs: affectedCycleIDs,
                sourceApps: sourceApps
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
        let requiredApps = Self.requiredCycleSourceApps(cycles: cycles)
        let completedInitialRebuild = !initialRebuildApps.isEmpty
            && !requiredApps.isEmpty
            && completedApps.isSuperset(of: requiredApps)
        let fingerprint = Pricing.fingerprint(knownUsage: pricingUsageKeys(from: aggregator.snapshotLocal()))
        let conversation = conversationAggregator.snapshot()
        let error = await persistSnapshot(
            snapshotID: generationID,
            fingerprint: fingerprint,
            hasScanProgress: true,
            integrity: .complete,
            degradeReasons: [],
            dshHistoryFrozen: isDshHistoryFrozen,
            scanState: scanState,
            buckets: aggregator.snapshotLocal(),
            conversationInfos: conversation.infos,
            conversationBuckets: conversation.buckets,
            cycleBuckets: cycleAggregator.snapshot(),
            cycleInitialRebuildCompletedAt: completedInitialRebuild ? completedAt : cycleInitialRebuildCompletedAt,
            cycleInitialRebuildCompletedApps: completedApps,
            dshContributions: dshContributions,
            dshRequiresRebuild: dshNeedsFullRescan
        )
        if let error {
            // 内存（含周期桶与完成标记）回滚到上一份提交，避免「周期领先于主历史」。
            rollbackToCommittedSnapshot()
            lastError = "cycle usage rebuild failed: \(error)"
            AppLog.error(.usage, "cycle usage rebuild failed: \(Redact.message(error))")
            return
        }
        hasUnwrittenRollupChanges = false
        lastRollupWriteAt = Date()
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
        AppLog.info(.usage, "cycle usage \(tag) \(status) elapsed=\(elapsed)")
    }

    func rebuildCycleUsageIfNeeded() async {
        guard !suspendedForTermination, !isPersistingForTermination else { return }
        guard let appState, !appState.quotaCycles.records.isEmpty else { return }
        guard !storeWriteDisabled, historyRecoveryState == .complete else { return }
        guard !Self.pendingInitialCycleRebuildApps(
            cycles: appState.quotaCycles.records,
            completedApps: cycleInitialRebuildCompletedApps
        ).isEmpty else { return }
        while isScanning || isCycleRebuilding {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !suspendedForTermination, !isPersistingForTermination else { return }
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
        guard await drainPendingUsageBeforeCycleRebuild() else { return }
        let progress: ScanProgressCallback? = { [weak self] progress in
            DispatchQueue.main.async { self?.scanProgress = progress }
        }
        let cycles = appState.quotaCycles.records
        let pendingApps = Self.pendingInitialCycleRebuildApps(
            cycles: cycles,
            completedApps: cycleInitialRebuildCompletedApps
        )
        guard !pendingApps.isEmpty else { return }
        let claudeRoot = roots.claudeRoot
        let claudeIndex = roots.claudeConversationIndex()
        let codexRoots = roots.codexRoots
        let codexTitles = roots.codexTitles()
        let claudeTask: Task<ClaudeJSONLScanner.Result, Never>? = pendingApps.contains(.claude)
            ? Task.detached(priority: .utility) {
                ClaudeJSONLScanner.scan(
                    previous: [:],
                    seenMessageIds: [],
                    root: claudeRoot,
                    conversationIndex: claudeIndex,
                    onProgress: progress
                )
            }
            : nil
        let codexTask: Task<CodexJSONLScanner.Result, Never>? = pendingApps.contains(.codex)
            ? Task.detached(priority: .utility) {
                await CodexJSONLScanner.scan(
                    previous: [:],
                    seenTokenIds: [],
                    roots: codexRoots,
                    indexedTitles: codexTitles,
                    onProgress: progress
                )
            }
            : nil
        let piRoot = roots.piRoot
        let opencodeDatabaseURL = roots.opencodeDatabaseURL
        let piTask: Task<PiJSONLScanner.Result, Never>? = pendingApps.contains(.pi)
            ? Task.detached(priority: .utility) {
                PiJSONLScanner.scan(
                    previous: [:],
                    seenEntryIds: [],
                    root: piRoot,
                    onProgress: progress
                )
            }
            : nil
        let opencodeTask: Task<OpencodeScanner.Result, Never>? = pendingApps.contains(.opencode)
            ? Task.detached(priority: .utility) {
                OpencodeScanner.scan(
                    previous: nil,
                    databaseURL: opencodeDatabaseURL,
                    onProgress: progress
                )
            }
            : nil
        // 从零扫描与逐会话贡献无关，DSH 冻结时也能补算一次现存日志。
        let dshRoot = roots.dshRoot
        let dshTask: Task<DshSessionScanner.Result, Never>? = pendingApps.contains(.dsh)
            ? Task.detached(priority: .utility) {
                DshSessionScanner.scan(previous: [:], root: dshRoot, onProgress: progress)
            }
            : nil
        let claude = await claudeTask?.value
        var codex = await codexTask?.value
        if usesLegacyCodexModels { codex = codex.map(Self.legacyCodexResult) }
        let pi = await piTask?.value
        let opencode = await opencodeTask?.value
        let dsh = await dshTask?.value
        let pendingCycles = Self.cyclesToRebuild(cycles, for: pendingApps)
        let failedApps = Self.cycleSourceFailedApps(
            Self.cycleRebuildFailedApps(
                claude: claude,
                codex: codex,
                cycles: pendingCycles
            ),
            opencode: opencode,
            opencodeDatabaseURL: opencodeDatabaseURL,
            dshFailed: dsh.map { !$0.isComplete } ?? false
        )
        let pendingCycleIDs = Set(pendingCycles.map(\.id))
        let rebuildableCycleIDs = Self.cycleRebuildableCycleIDs(
            cycles: pendingCycles,
            requestedCycleIDs: pendingCycleIDs,
            failedApps: failedApps
        )
        let entries = (claude?.entries ?? []) + (codex?.entries ?? [])
            + (pi?.entries ?? []) + (opencode?.entries ?? []) + (dsh?.entries ?? [])
        await commitCycleAggregation(
            exactEntries: entries.filter { !failedApps.contains($0.app) },
            cycles: cycles,
            accountSegments: appState.quotaCycles.accountSegments,
            initialRebuildApps: pendingApps,
            failedApps: failedApps,
            rebuildRange: rebuildableCycleIDs,
            sourceApps: pendingApps.subtracting(failedApps)
        )
    }

    /// 决定本轮扫描的起点状态。进度随快照一起加载，与已加载汇总同代；
    /// 价格指纹不参与失效判定：价格变化后新条目按现价计，历史费用由扫描后的
    /// 自动重建（`rebuildAutomaticallyIfNeeded`）按新价格重算，不清空重扫。
    private func resolveScanState() async -> ScanCacheLoadResult {
        if requiresFullRebuild { return .invalidated }
        guard let cached = cachedScanState,
              cached.generationID == loadedRollupGeneration
        else {
            return .invalidated
        }
        return .valid(cached)
    }

    // MARK: - 安全重算

    /// 用户在设置页手动触发的强制重算，与自动重建走同一流程。候选在独立的聚合器上从现有日志完整重建，
    /// 日志已删除的对话按 `UsageRebuildMerge` 保留原用量、按现价重新计费；
    /// 来源读取不完整或持久化失败时一律保留原历史。历史受限时只做受限恢复的核对。
    func forceRescan() async {
        guard !suspendedForTermination, !isPersistingForTermination else { return }
        // 撞上另一次进行中的扫描(常见于 App 冷启动自动扫描、或 Scheduler 定时扫描)时,
        // 不再静默丢弃这次操作:等它跑完再真正强制重算,保证用户点的这次一定生效。
        // 设置页按钮的 spinner 在等待期间会一直转,用户感知不到差异,只是变"诚实"了。
        while isScanning {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !suspendedForTermination, !isPersistingForTermination else { return }
        }
        isScanning = true
        defer {
            isScanning = false
            scanProgress = nil
            if scanQueued { Task { await scanNow() } }
        }
        lastRebuildOutcome = nil
        PricingCatalogStore.shared.refreshIfNeeded()
        // 手动重算同样是一次完整扫描：先提交已经刷好的 pending，避免用户刚点击重算
        // 却仍按旧 active 价格扫描；本次刚发起的网络刷新则留给下一次扫描。
        PricingCatalogStore.shared.commitPending()
        guard !storeWriteDisabled else {
            lastRebuildOutcome = .commitFailed("usage history store is read-only")
            return
        }

        if historyRecoveryState != .complete {
            let outcome = await runCandidateRebuild(purpose: .restrictedRecovery)
            switch outcome {
            case .replaced:
                historyRecoveryState = .complete
                historyDegradeReasons = []
                lastRebuildOutcome = .recoveredFromRestrictedHistory
            default:
                historyRecoveryState = .verificationRejected
                lastRebuildOutcome = .restrictedRecoveryRejected
                lastError = Self.restrictedHistoryMessage
            }
            return
        }

        isRebuildingHistory = true
        defer { isRebuildingHistory = false }
        // 基准必须与磁盘一致：先把上一次常规扫描之后积压的增量提交掉。
        guard await drainPendingIncrements() else {
            lastRebuildOutcome = .commitFailed(lastError ?? "pending changes could not be committed")
            return
        }

        let first = await runCandidateRebuild(purpose: .manualRecalculation)
        var outcome = first
        if case .replaced = first, await refreshMissingPricingIfNeeded() {
            // 缺价刷新拿到新价格后必须再走一遍完整候选；第二轮失败时保留第一轮有效结果。
            switch await runCandidateRebuild(purpose: .pricingRefresh) {
            case .replaced(let cycleVerified):
                outcome = .replaced(cycleVerified: cycleVerified)
            case .rejectedUsageChanged, .rejectedIncompleteSources:
                outcome = .partiallyCommitted("pricing refresh round rejected; first round kept")
            case .commitFailed(let detail):
                // 第一轮已提交且有效；第二轮失败不能伪装成整轮成功。
                outcome = .partiallyCommitted("pricing refresh round failed: \(detail); first round kept")
            case .recoveredFromRestrictedHistory, .restrictedRecoveryRejected, .partiallyCommitted:
                outcome = first
            }
        }
        lastRebuildOutcome = outcome
        if case .replaced = first { didCommitFullRebuild() }
    }

    /// 完整重建提交后的收尾。周期桶已按全部现有日志和周期记录重建（日志已删除的部分原样保留），
    /// 再重算也补不出更多数据，不能继续提示「周期用量不完整」；自动重建的待办随之清除。
    private func didCommitFullRebuild() {
        cycleUsageNeedsManualRecalculation = false
        hasPendingOrphanCycleRebuild = false
        catalogUpdateRequestedByUser = false
        lastAutomaticRebuildFailureAt = nil
    }

    // MARK: - 自动重建

    /// 常规扫描提交后调用（调用方持有 isScanning）：统计规则或价格与现有历史不一致时，
    /// 按手动「重新计算用量」同一流程自动重建一次。触发与间隔规则见 `UsageRebuildBasis.rebuildReason`；
    /// 没有提交成功时，本进程 24 小时内不再自动重试。
    private func rebuildAutomaticallyIfNeeded() async {
        guard automaticRebuildEnabled, !suspendedForTermination, !storeWriteDisabled,
              historyRecoveryState == .complete, committedSnapshot != nil else { return }
        refreshMissingPricingInBackground()
        let now = Date()
        if let failedAt = lastAutomaticRebuildFailureAt,
           now.timeIntervalSince(failedAt) < Self.automaticRebuildInterval { return }
        let buckets = aggregator.snapshotLocal()
        let reason = UsageRebuildBasis.rebuildReason(
            basis: rebuildBasis,
            usageKeys: pricingUsageKeys(from: buckets),
            unpricedKeys: pricingUsageKeys(from: buckets.filter(\.hasUnpricedUsage)),
            userRequestedCatalog: catalogUpdateRequestedByUser,
            now: now,
            minimumInterval: Self.automaticRebuildInterval
        )
        catalogUpdateRequestedByUser = false
        guard let reason else { return }

        AppLog.info(.usage, "usage automatic rebuild started reason=\(reason.rawValue)")
        isRebuildingHistory = true
        defer {
            isRebuildingHistory = false
            scanProgress = nil
        }
        guard await drainPendingIncrements() else {
            lastAutomaticRebuildFailureAt = now
            return
        }
        let outcome = await runCandidateRebuild(purpose: .automatic(reason))
        if case .replaced = outcome {
            didCommitFullRebuild()
            // 设置页上一次手动重算的失败提示已被这次重建取代。
            lastRebuildOutcome = nil
        } else {
            lastAutomaticRebuildFailureAt = now
            AppLog.warn(.usage, "usage automatic rebuild not committed reason=\(reason.rawValue); retry after 24h")
        }
    }

    /// 有缺价用量时后台查一次远端价格目录（同一用量键 24 小时最多一次）。查到后立即再扫描一轮，
    /// 由自动重建按新价格重算这些用量。不阻塞当前扫描。
    private func refreshMissingPricingInBackground() {
        guard !isRefreshingMissingPricing else { return }
        let missing = missingPricingKeys(in: aggregator.snapshotLocal())
        guard !missing.isEmpty else { return }
        isRefreshingMissingPricing = true
        Task { [weak self] in
            let refreshed = await PricingCatalogStore.shared.refreshForMissing(
                missing,
                minimumInterval: Self.automaticRebuildInterval
            )
            guard let self else { return }
            self.isRefreshingMissingPricing = false
            if refreshed { await self.scanNow() }
        }
    }

    /// 测试缝：把内存里待落盘的增量立刻提交。语义等价于写盘节流窗口到期后的那一轮常规扫描。
    func flushPendingRollupChangesForTesting() async {
        _ = await drainPendingIncrements()
    }

    /// 提交尚未落盘的增量，得到可对账的基准。失败时保证内存与磁盘仍然一致。
    private func drainPendingIncrements() async -> Bool {
        let cacheResult = await resolveScanState()
        if case .invalidated = cacheResult {
            clearUsageAggregatesForFullRebuild()
        }
        guard await runScan(prev: cacheResult.state) else { return false }
        requiresFullRebuild = false
        return true
    }

    private enum RebuildPurpose: Equatable {
        case manualRecalculation
        case pricingRefresh
        case restrictedRecovery
        /// 价格或统计规则变化后的自动重建，行为与手动重算相同。
        case automatic(UsageAutomaticRebuildReason)
    }

    /// 候选隔离重算：完整扫描 → 独立聚合 → 完整性门槛 → 对账（仅受限恢复） → 提交 → 发布。
    private func runCandidateRebuild(purpose: RebuildPurpose) async -> UsageRebuildOutcome {
        guard !storeWriteDisabled else {
            return .commitFailed("usage history store is read-only")
        }
        // 标识迁移尚未提交时（含没有可信进度的旧快照）按旧 Codex 身份严格核对。
        let candidate = await buildRebuildCandidate(
            useLegacyCodexModels: usesLegacyCodexModels,
            preserveDeletedConversations: purpose != .restrictedRecovery
        )
        #if DEBUG
        await candidateReadyForTesting?()
        #endif
        if let incomplete = candidate.incompleteSources {
            lastRebuildDiagnostic = "sources=(\(incomplete))"
            AppLog.warn(.usage, "usage rebuild rejected sources=\(incomplete)")
            return .rejectedIncompleteSources(incomplete)
        }
        // 只有受限恢复要求逐项相等：它的作用是证明旧历史与日志一致，才能采纳新进度。
        // 手动重建以现有日志为准、保留日志已删除的对话，差异是预期结果，只记录不拒绝。
        if purpose == .restrictedRecovery, candidate.mismatch.hasUsageDifference {
            lastRebuildDiagnostic = candidate.mismatch.summary
            AppLog.warn(.usage, "usage rebuild rejected mismatch=\(candidate.mismatch.summary)")
            return .rejectedUsageChanged
        }
        let cycleVerified = !candidate.mismatch.hasCycleDifference
        let changed = candidate.mismatch.hasUsageDifference || !cycleVerified
        lastRebuildDiagnostic = changed ? candidate.mismatch.summary : nil
        let error = await persistSnapshot(
            snapshotID: candidate.scanState.generationID,
            fingerprint: candidate.scanState.pricingFingerprint,
            hasScanProgress: true,
            integrity: .complete,
            degradeReasons: [],
            dshHistoryFrozen: isDshHistoryFrozen,
            scanState: candidate.scanState,
            buckets: candidate.dayBuckets,
            conversationInfos: candidate.conversationInfos,
            conversationBuckets: candidate.conversationBuckets,
            cycleBuckets: candidate.cycleBuckets,
            cycleInitialRebuildCompletedAt: candidate.cycleInitialRebuildCompletedAt,
            cycleInitialRebuildCompletedApps: candidate.cycleInitialRebuildCompletedApps,
            dshContributions: candidate.dshContributions,
            dshRequiresRebuild: candidate.dshRequiresRebuild,
            rebuildState: (candidate.messageLedger, candidate.rebuildBasis)
        )
        if let error {
            lastRebuildDiagnostic = "commit=\(error)"
            AppLog.error(.usage, "usage rebuild commit failed: \(Redact.message(error))")
            return .commitFailed(error)
        }
        // 提交成功后才切换内存与 UI。
        aggregator.load(from: candidate.dayBuckets)
        conversationAggregator.load(
            infos: candidate.conversationInfos,
            buckets: candidate.conversationBuckets
        )
        cycleAggregator.load(from: candidate.cycleBuckets)
        dshContributions = candidate.dshContributions
        dshNeedsFullRescan = candidate.dshRequiresRebuild
        messageLedger = candidate.messageLedger
        rebuildBasis = candidate.rebuildBasis
        cachedScanState = candidate.scanState
        loadedRollupGeneration = candidate.scanState.generationID
        loadedCycleGeneration = candidate.scanState.generationID
        cycleInitialRebuildCompletedAt = candidate.cycleInitialRebuildCompletedAt
        cycleInitialRebuildCompletedApps = candidate.cycleInitialRebuildCompletedApps
        hasUnwrittenRollupChanges = false
        lastRollupWriteAt = Date()
        requiresFullRebuild = false
        lastScanAt = Date()
        let unverified = dshContributions.values.filter { $0.needsVerification == true }.count
        if isDshHistoryFrozen {
            lastError = "DSH usage history preserved; per-session contributions unavailable so new DSH usage is not collected"
        } else if unverified > 0 {
            lastError = "DSH historical usage for \(unverified) deleted session(s) could not be verified"
        } else {
            lastError = nil
        }
        publishTotals()
        let tag: String
        switch purpose {
        case .manualRecalculation: tag = "manual"
        case .pricingRefresh: tag = "pricing refresh"
        case .restrictedRecovery: tag = "restricted recovery"
        case .automatic(let reason): tag = "automatic reason=\(reason.rawValue)"
        }
        AppLog.info(
            .usage,
            "usage rebuild \(tag) committed cycle_verified=\(cycleVerified)"
                + " changes=\(candidate.mismatch.summary)"
                + " preserved_conversations=\(candidate.preservedConversations)"
                + " skipped_buckets=\(candidate.skippedBuckets)"
        )
        return .replaced(cycleVerified: cycleVerified)
    }

    /// 用独立聚合器构造完整候选。读取期间当前结果继续展示；这里不修改任何线上状态。
    /// - Parameter preserveDeletedConversations: 手动重建传 true，按 `UsageRebuildMerge` 保留日志已删除的对话；
    ///   受限恢复的核对传 false，候选只来自现有日志，才能和基准逐项比对。
    private func buildRebuildCandidate(
        useLegacyCodexModels: Bool = false,
        preserveDeletedConversations: Bool
    ) async -> RebuildCandidate {
        let progress: ScanProgressCallback? = { [weak self] progress in
            DispatchQueue.main.async { self?.scanProgress = progress }
        }
        let claudeRoot = roots.claudeRoot
        let claudeIndex = roots.claudeConversationIndex()
        let codexRoots = roots.codexRoots
        let codexTitles = roots.codexTitles()
        let piRoot = roots.piRoot
        let opencodeDatabaseURL = roots.opencodeDatabaseURL
        let dshRoot = roots.dshRoot
        let dshFrozen = isDshHistoryFrozen
        let preservedDshState = cachedScanState?.dsh ?? [:]

        // 日志已删除、且账本里有消息 ID 的对话：先把这些 ID 放进去重集合，续接 / 分叉对话复制过去的
        // 同一批消息就不会被重扫再计一次，合并时原用量可以全部保留。基准建立之前账本不完整，不能这样用。
        var ledgerBackedKeys: [UsageApp: Set<String>] = [:]
        if preserveDeletedConversations, rebuildBasis != nil {
            let deleted = UsageRebuildMerge.deletedConversations(
                conversationAggregator.snapshot().infos,
                sourceExists: { FileManager.default.fileExists(atPath: $0) }
            )
            for info in deleted where messageLedger.contains(info.key, app: info.app) {
                ledgerBackedKeys[info.app, default: []].insert(info.key)
            }
        }
        let claudeKnown = messageLedger.ids(for: ledgerBackedKeys[.claude] ?? [], app: .claude)
        let codexKnown = messageLedger.ids(for: ledgerBackedKeys[.codex] ?? [], app: .codex)
        let piKnown = messageLedger.ids(for: ledgerBackedKeys[.pi] ?? [], app: .pi)

        async let claudeTask = Task.detached(priority: .utility) {
            ClaudeJSONLScanner.scan(
                previous: [:],
                seenMessageIds: [],
                knownIDs: claudeKnown,
                root: claudeRoot,
                conversationIndex: claudeIndex,
                onProgress: progress
            )
        }.value
        async let codexTask = Task.detached(priority: .utility) {
            await CodexJSONLScanner.scan(
                previous: [:],
                seenTokenIds: [],
                knownIDs: codexKnown,
                roots: codexRoots,
                indexedTitles: codexTitles,
                onProgress: progress
            )
        }.value
        async let piTask = Task.detached(priority: .utility) {
            PiJSONLScanner.scan(
                previous: [:],
                seenEntryIds: [],
                knownIDs: piKnown,
                root: piRoot,
                onProgress: progress
            )
        }.value
        async let opencodeTask = Task.detached(priority: .utility) {
            OpencodeScanner.scan(
                previous: nil,
                databaseURL: opencodeDatabaseURL,
                onProgress: progress
            )
        }.value
        async let dshTask = Task.detached(priority: .utility) {
            dshFrozen
                ? DshSessionScanner.frozenResult(preserving: preservedDshState)
                : DshSessionScanner.scan(previous: [:], root: dshRoot, onProgress: progress)
        }.value

        let claude = await claudeTask
        var codex = await codexTask
        if useLegacyCodexModels { codex = Self.legacyCodexResult(codex) }
        let pi = await piTask
        let opencode = await opencodeTask
        let dsh = await dshTask

        var incomplete: [String] = []
        if claude.failedFileCount > 0 { incomplete.append("Claude Code") }
        if codex.failedFileCount > 0 { incomplete.append("Codex") }
        // OpenCode 库从未存在（本机没装）是正常状态；只有库在却读不开才算来源不完整。
        let opencodeProblem = opencode.error != nil || !opencode.isComplete
        if opencodeProblem, FileManager.default.fileExists(atPath: opencodeDatabaseURL.path) {
            incomplete.append("OpenCode")
        }
        if !dshFrozen, !dsh.isComplete { incomplete.append("DSH") }

        // 需要保留的历史分区（源库中已删除会话、DSH 历史贡献）先按基准装载，
        // 再由完整扫描结果覆盖；不能用空聚合器直接覆盖历史。
        let baselineDay = aggregator.snapshotLocal()
        let baselineConversation = conversationAggregator.snapshot()
        let baselineCycles = cycleAggregator.snapshot()
        let candidateDaily = UsageAggregator()
        let candidateConversations = ConversationAggregator()
        candidateDaily.load(from: baselineDay.filter { $0.app == .opencode || $0.app == .dsh })
        candidateConversations.load(
            infos: baselineConversation.infos.filter { $0.app == .opencode || $0.app == .dsh },
            buckets: baselineConversation.buckets.filter { $0.app == .opencode || $0.app == .dsh }
        )

        candidateDaily.ingestLocal(claude.entries)
        candidateDaily.ingestLocal(codex.entries)
        candidateDaily.ingestLocal(pi.entries)
        _ = Self.applyOpenCodeScan(
            opencode,
            aggregator: candidateDaily,
            conversations: candidateConversations
        )
        _ = candidateConversations.ingest(
            entries: claude.entries + codex.entries + pi.entries,
            seeds: claude.conversationSeeds + codex.conversationSeeds + pi.conversationSeeds
        )
        // OpenCode / DSH 从空状态扫描，给出的是现存会话的完整用量；DSH 冻结时不重灌。
        let cycleEntries = claude.entries + codex.entries + pi.entries + opencode.entries
            + (dshFrozen ? [] : dsh.entries)
        let freshDshContributions = dshFrozen
            ? dshContributions
            : DshContributionStore.apply(scan: dsh, to: dshContributions).contributions
        let dshRollup = DshContributionRollup.reduce(freshDshContributions)
        if !dshFrozen {
            candidateDaily.replaceLocal(app: .dsh, buckets: dshRollup.dayBuckets)
            candidateConversations.replaceLocal(
                app: .dsh,
                infos: dshRollup.conversationInfos,
                buckets: dshRollup.conversationBuckets
            )
        }

        let cycles = appState?.quotaCycles.records ?? []
        let accountSegments = appState?.quotaCycles.accountSegments ?? []
        let candidateCycles = CycleUsageAggregator()
        if !cycles.isEmpty {
            candidateCycles.rebuild(
                exactEntries: cycleEntries,
                cycles: cycles,
                accountSegments: accountSegments
            )
            // 与日桶一致：源库中已删除的 OpenCode 会话、日志已删除的 DSH 会话保留原周期桶；
            // DSH 冻结时整份保留。
            let refreshedOpencodeKeys = Set(opencode.refreshedSessionIDs.map { "opencode:\($0)" })
            let refreshedDshKeys = Set(dsh.newState.values.compactMap(\.conversationID).map { "dsh:\($0)" })
            let preserved = baselineCycles.filter {
                switch $0.app {
                case .opencode:
                    return !refreshedOpencodeKeys.contains($0.conversationKey ?? "")
                case .dsh:
                    return dshFrozen || !refreshedDshKeys.contains($0.conversationKey ?? "")
                default:
                    return false
                }
            }
            if !preserved.isEmpty {
                candidateCycles.load(from: candidateCycles.snapshot() + preserved)
            }
        }

        let conversationSnapshot = candidateConversations.snapshot()
        var merged = UsageRebuildMerge.Result(
            dayBuckets: candidateDaily.snapshotLocal(),
            conversationInfos: conversationSnapshot.infos,
            conversationBuckets: conversationSnapshot.buckets,
            cycleBuckets: candidateCycles.snapshot()
        )
        if preserveDeletedConversations {
            var cycleStartByID: [String: Date] = [:]
            for cycle in cycles where cycleStartByID[cycle.id] == nil {
                cycleStartByID[cycle.id] = cycle.startAt
            }
            merged = UsageRebuildMerge.preserveDeletedConversations(
                baselineDay: baselineDay,
                baselineInfos: baselineConversation.infos,
                baselineConversation: baselineConversation.buckets,
                baselineCycles: baselineCycles,
                candidateDay: merged.dayBuckets,
                candidateInfos: merged.conversationInfos,
                candidateConversation: merged.conversationBuckets,
                candidateCycles: merged.cycleBuckets,
                cycleStartByID: cycleStartByID,
                ledgerBackedKeys: ledgerBackedKeys.values.reduce(into: Set<String>()) { $0.formUnion($1) },
                sourceExists: { FileManager.default.fileExists(atPath: $0) }
            )
        }
        // 补录只填没有任何 Claude 用量的天，必须在保留已删除对话之后判断，否则同一天会补录和保留各算一次。
        let finalDaily = UsageAggregator()
        finalDaily.load(from: merged.dayBuckets)
        finalDaily.ingestLocal(
            ImportedUsageBackfill.loadMissingEntries(
                app: .claude,
                existingDays: Set(merged.dayBuckets.filter { $0.app == .claude }.map(\.day)),
                from: backfillURL
            )
        )
        let candidateDay = finalDaily.snapshotLocal()
        var mismatch = UsageHistoryConsistency.compareUsage(
            baseline: baselineDay,
            candidateDay: candidateDay,
            baselineConversation: baselineConversation.buckets,
            candidateConversation: merged.conversationBuckets,
            baselineInfos: baselineConversation.infos,
            candidateInfos: merged.conversationInfos
        )
        UsageHistoryConsistency.compareCycle(
            baseline: baselineCycles,
            candidate: merged.cycleBuckets,
            into: &mismatch
        )

        let usageKeys = pricingUsageKeys(from: candidateDay)
        let fingerprint = Pricing.fingerprint(knownUsage: usageKeys)
        // 账本从完整重扫建立，再带上被保留的已删除对话原有的 ID；有了账本，seen 列表不再保存。
        var candidateLedger = UsageMessageLedger()
        candidateLedger.record(claude.ledger, app: .claude)
        candidateLedger.record(codex.ledger, app: .codex)
        candidateLedger.record(pi.ledger, app: .pi)
        let keptKeys = Set(merged.conversationInfos.map(\.key))
        for (app, keys) in ledgerBackedKeys {
            candidateLedger.record(messageLedger.filtered(keys.intersection(keptKeys), app: app), app: app)
        }
        let scanState = ScanState(
            generationID: UUID().uuidString,
            pricingFingerprint: fingerprint,
            claude: claude.newState,
            codex: codex.newState,
            pi: pi.newState,
            opencode: opencode.newState,
            dsh: dshFrozen ? preservedDshState : dsh.newState
        )
        let requiredApps = Self.requiredCycleSourceApps(cycles: cycles)
        let completedApps = incomplete.isEmpty
            ? cycleInitialRebuildCompletedApps.union(requiredApps)
            : cycleInitialRebuildCompletedApps
        return RebuildCandidate(
            dayBuckets: candidateDay,
            conversationInfos: merged.conversationInfos,
            conversationBuckets: merged.conversationBuckets,
            cycleBuckets: merged.cycleBuckets,
            cycleInitialRebuildCompletedAt: incomplete.isEmpty ? Date() : cycleInitialRebuildCompletedAt,
            cycleInitialRebuildCompletedApps: completedApps,
            dshContributions: freshDshContributions,
            dshRequiresRebuild: dshFrozen ? true : !dsh.isComplete,
            scanState: scanState,
            incompleteSources: incomplete.isEmpty ? nil : incomplete.joined(separator: ", "),
            mismatch: mismatch,
            messageLedger: candidateLedger,
            rebuildBasis: .current(usageKeys: usageKeys, at: Date()),
            preservedConversations: merged.preservedConversations,
            skippedBuckets: merged.skippedBuckets
        )
    }

    /// 设置页手动更新在线价格目录：绕过 24 小时拉取最新目录，新价格在下一轮扫描的
    /// 安全边界提交生效。成功后立即扫描一轮；用到的模型价格有变化时，自动重建不等 24 小时间隔。
    @discardableResult
    func refreshPricingCatalog() async -> Bool {
        guard !suspendedForTermination, !isPersistingForTermination else { return false }
        guard !isRefreshingPricingCatalog else { return false }
        isRefreshingPricingCatalog = true
        defer { isRefreshingPricingCatalog = false }
        let succeeded = await PricingCatalogStore.shared.forceRefresh()
        if succeeded, automaticRebuildEnabled {
            catalogUpdateRequestedByUser = true
            Task { await scanNow() }
        }
        return succeeded
    }

    // MARK: - 常规扫描实现

    /// - Parameter allowDeferredWrite: 允许把本轮聚合结果留在内存里、等到节流窗口到期
    ///   再统一落盘。只有常规周期扫描（`scanNow`）传 true；强制重算与周期重建前的
    ///   drain 必须立刻提交，否则后续步骤会基于未落盘的状态继续推进。
    @discardableResult
    private func runScan(
        prev: ScanState,
        reportProgress: Bool = false,
        allowDeferredWrite: Bool = false
    ) async -> Bool {
        guard await migrateCodexModelIdentityIfNeeded() else { return false }
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
        let claudeRoot = roots.claudeRoot
        let claudeIndex = roots.claudeConversationIndex()
        let codexRoots = roots.codexRoots
        let codexTitles = roots.codexTitles()
        let piRoot = roots.piRoot
        let opencodeDatabaseURL = roots.opencodeDatabaseURL
        let dshRoot = roots.dshRoot
        let dshFrozen = isDshHistoryFrozen
        // 账本里的 ID 没有条数上限；基准建立之前账本不完整，旧 seen 列表照常参与去重。
        let claudeKnown = messageLedger.knownIDs(for: .claude)
        let codexKnown = messageLedger.knownIDs(for: .codex)
        let piKnown = messageLedger.knownIDs(for: .pi)

        async let claudeTask = Task.detached(priority: .utility) {
            ClaudeJSONLScanner.scan(
                previous: prev.claude,
                seenMessageIds: prevSeen,
                knownIDs: claudeKnown,
                root: claudeRoot,
                conversationIndex: claudeIndex,
                onProgress: progress
            )
        }.value
        async let codexTask = Task.detached(priority: .utility) {
            await CodexJSONLScanner.scan(
                previous: prev.codex,
                seenTokenIds: prev.codexSeenTokenIds,
                knownIDs: codexKnown,
                roots: codexRoots,
                indexedTitles: codexTitles,
                onProgress: progress
            )
        }.value
        async let piTask = Task.detached(priority: .utility) {
            PiJSONLScanner.scan(
                previous: prev.pi,
                seenEntryIds: prev.piSeenEntryIds,
                knownIDs: piKnown,
                root: piRoot,
                onProgress: progress
            )
        }.value
        async let opencodeTask = Task.detached(priority: .utility) {
            OpencodeScanner.scan(
                previous: prev.opencode,
                databaseURL: opencodeDatabaseURL,
                onProgress: progress
            )
        }.value
        // 贡献缓存不可用时 DSH 必须从零全量重扫：只靠 watermark 增量拿不回历史贡献。
        let dshPrevious = dshNeedsFullRescan ? [:] : prev.dsh
        async let dshTask = Task.detached(priority: .utility) {
            dshFrozen
                ? DshSessionScanner.frozenResult(preserving: prev.dsh)
                : DshSessionScanner.scan(previous: dshPrevious, root: dshRoot, onProgress: progress)
        }.value

        let claude = await claudeTask
        var codex = await codexTask
        if usesLegacyCodexModels { codex = Self.legacyCodexResult(codex) }
        let pi = await piTask
        let opencode = await opencodeTask
        let dsh = await dshTask
        // DSH 的坏帧、坏文件也要能浮出来（§6 决策 4）；pi / opencode 的既有行为不动。
        let failedFileCount = claude.failedFileCount + codex.failedFileCount
            + dsh.failedFileCount + dsh.failedDirectoryCount + dsh.duplicateSessionCount

        aggregator.ingestLocal(claude.entries)
        aggregator.ingestLocal(codex.entries)
        aggregator.ingestLocal(pi.entries)
        messageLedger.record(claude.ledger, app: .claude)
        messageLedger.record(codex.ledger, app: .codex)
        messageLedger.record(pi.ledger, app: .pi)
        let cycleEntries = claude.entries + codex.entries + pi.entries
        let opencodeChanged = Self.applyOpenCodeScan(
            opencode, aggregator: aggregator, conversations: conversationAggregator
        )
        let conversationChanged = conversationAggregator.ingest(
            entries: claude.entries + codex.entries + pi.entries,
            seeds: claude.conversationSeeds + codex.conversationSeeds + pi.conversationSeeds
        )

        // 个人历史用量一次性补录：缓存失效路径会清空聚合器，若只在 bootstrap 合并，
        // 清空后落盘的 rollup 将丢失补录数据。每轮扫描都按天去重重新合并，
        // 保证任何一次落盘的快照都包含补录用量。
        mergeImportedBackfill()

        let cycles = appState?.quotaCycles.records ?? []
        var cycleChanged: Bool
        // 本轮初始重建已用 DSH 完整扫描重灌周期桶时，落盘阶段不再按贡献更新归集一次。
        var dshCycleRebuilt = false
        if prev.generationID.isEmpty, !cycles.isEmpty {
            let initialApps = Self.pendingInitialCycleRebuildApps(
                cycles: cycles,
                completedApps: cycleInitialRebuildCompletedApps
            )
            let initialCycles = Self.cyclesToRebuild(cycles, for: initialApps)
            let failedApps = Self.cycleSourceFailedApps(
                Self.cycleRebuildFailedApps(
                    claude: claude,
                    codex: codex,
                    cycles: initialCycles
                ),
                opencode: opencode,
                opencodeDatabaseURL: opencodeDatabaseURL,
                // DSH 只有从零完整扫描才能直接灌入；冻结或带旧 watermark 时留给补算。
                dshFailed: dshFrozen || !dsh.isComplete || !dshPrevious.isEmpty
            )
            let initialCycleIDs = Set(initialCycles.map(\.id))
            let rebuildableCycleIDs = Self.cycleRebuildableCycleIDs(
                cycles: initialCycles,
                requestedCycleIDs: initialCycleIDs,
                failedApps: failedApps
            )
            dshCycleRebuilt = initialApps.contains(.dsh) && !failedApps.contains(.dsh)
            // 从零扫描时 OpenCode / DSH 给出的是全部会话的完整用量，可以直接灌入。
            cycleAggregator.rebuildRange(
                exactEntries: (cycleEntries + opencode.entries + dsh.entries)
                    .filter { !failedApps.contains($0.app) },
                cycles: cycles,
                accountSegments: appState?.quotaCycles.accountSegments ?? [],
                affectedCycleIDs: rebuildableCycleIDs,
                sourceApps: initialApps.subtracting(failedApps)
            )
            cycleInitialRebuildCompletedApps = Self.updatedInitialCycleRebuildApps(
                completedApps: cycleInitialRebuildCompletedApps,
                requestedApps: initialApps,
                failedApps: failedApps
            )
            let requiredApps = Self.requiredCycleSourceApps(cycles: cycles)
            if cycleInitialRebuildCompletedApps.isSuperset(of: requiredApps) {
                cycleInitialRebuildCompletedAt = Date()
            }
            cycleChanged = true
        } else {
            let ingested = cycleAggregator.ingest(
                entries: cycleEntries,
                cycles: cycles,
                accountSegments: appState?.quotaCycles.accountSegments ?? []
            )
            // OpenCode 刷新会话给出的是完整用量，按会话替换，不能累加。
            let opencodeReplaced = opencode.isComplete && cycleAggregator.replaceConversations(
                app: .opencode,
                conversationKeys: Set(opencode.refreshedSessionIDs.map { "opencode:\($0)" }),
                entries: opencode.entries,
                cycles: cycles,
                accountSegments: appState?.quotaCycles.accountSegments ?? []
            )
            cycleChanged = ingested || opencodeReplaced
        }

        // DSH 不像其他扫描器那样靠 seen 集合兜底去重：本轮若不落盘，watermark 会一并压住，
        // 下一轮会把同样的帧再扫一遍。因此先纯内存试算贡献，只有本轮真的落盘才把它计入聚合，
        // 让「未落盘就重扫」天然幂等。
        let dshRebuildReady = !dshFrozen && dshNeedsFullRescan && dsh.isComplete
        let canCommitDsh = !dshFrozen && (!dshNeedsFullRescan || dsh.isComplete)
        let dshUpdate = canCommitDsh
            ? DshContributionStore.apply(scan: dsh, to: dshContributions)
            : DshContributionStore.Update(contributions: dshContributions, changed: false)

        // 没有用量或档案变化时仍统一保存完整快照，watermark 也受写盘节流约束。
        let hasNewEntries = !claude.entries.isEmpty || !codex.entries.isEmpty
            || !pi.entries.isEmpty || opencodeChanged || dshUpdate.changed || dshRebuildReady
        if hasNewEntries || conversationChanged { hasUnwrittenRollupChanges = true }
        // 尚未建立代次时必须立刻落盘，否则内存与磁盘无从对齐。
        let mustWriteRollups = loadedRollupGeneration == nil
        let throttleElapsed = lastRollupWriteAt.map {
            started.timeIntervalSince($0) >= Self.rollupWriteInterval
        } ?? true
        let shouldWriteRollups = mustWriteRollups || dshRebuildReady
            || (hasUnwrittenRollupChanges && (!allowDeferredWrite || throttleElapsed))

        if shouldWriteRollups {
            // 贡献有变化就整体重归并并替换 DSH 分区：日桶、对话桶与档案只换 DSH 那一份，
            // 其他服务分区原样保留（§3.3）。父子归属变化也在这里生效。
            if canCommitDsh {
                // 周期桶与贡献同步提交：未落盘的一轮不归集，否则下一轮重扫会重复计入。
                if !dshCycleRebuilt, applyDshCycleUpdate(
                    dshUpdate,
                    cycles: cycles,
                    accountSegments: appState?.quotaCycles.accountSegments ?? []
                ) {
                    cycleChanged = true
                }
                dshContributions = dshUpdate.contributions
                dshNeedsFullRescan = false
                let dshRollup = DshContributionRollup.reduce(dshContributions)
                aggregator.replaceLocal(app: .dsh, buckets: dshRollup.dayBuckets)
                conversationAggregator.replaceLocal(
                    app: .dsh,
                    infos: dshRollup.conversationInfos,
                    buckets: dshRollup.conversationBuckets
                )
            }
        }

        let buckets = aggregator.snapshotLocal()
        let usageKeys = pricingUsageKeys(from: buckets)
        let fingerprint = Pricing.fingerprint(knownUsage: usageKeys)
        // 从零全量扫描（首装、进度失效）的结果本身就按现行规则和价格算出，直接建立基准；
        // 增量扫描新出现的用量键按当时价格计价，补记进基准。
        if prev.generationID.isEmpty {
            rebuildBasis = .current(usageKeys: usageKeys, at: started)
        } else if var basis = rebuildBasis, basis.recordNewKeys(usageKeys) {
            rebuildBasis = basis
        }
        // 基准建立后账本完整，seen 列表不再保存（账本没有条数上限）。
        let ledgerComplete = rebuildBasis != nil
        let claudeSeen = ledgerComplete ? [] : claude.newSeenIds
        let codexSeen = ledgerComplete ? [] : codex.newSeenIds
        let piSeen = ledgerComplete ? [] : pi.newSeenIds
        let dshStateForScan = shouldWriteRollups && canCommitDsh ? dsh.newState : prev.dsh
        // watermark 绝不能单独越过尚未落盘的聚合数据：进度落后一轮只是多扫一次，
        // 进度领先则会在重启后拿到「新 watermark + 旧汇总」，中间那段用量永久丢失。
        let probeGenerationID = loadedRollupGeneration ?? ""
        let probeScanState = ScanState(
            generationID: probeGenerationID,
            pricingFingerprint: fingerprint,
            claude: claude.newState,
            codex: codex.newState,
            claudeSeenMessageIds: claudeSeen,
            codexSeenTokenIds: codexSeen,
            pi: pi.newState,
            piSeenEntryIds: piSeen,
            opencode: opencode.newState,
            dsh: dshStateForScan
        )
        let cycleNeedsWrite = cycleChanged || loadedCycleGeneration == nil
        // 任何一次落盘都是「汇总 + 进度 + 周期 + DSH」的整份提交：不能只写其中一份。
        // watermark-only 变化也遵守整份快照节流；与磁盘进度比较，防止下一轮无变化时遗忘待提交进度。
        let progressNeedsWrite = probeScanState != committedSnapshot?.scanState
        let shouldCommitSnapshot = shouldWriteRollups
            || (!hasUnwrittenRollupChanges && (progressNeedsWrite || cycleNeedsWrite)
                && (!allowDeferredWrite || throttleElapsed))
        let generationID = shouldCommitSnapshot
            ? UUID().uuidString
            : (loadedRollupGeneration ?? UUID().uuidString)
        let newScanState = ScanState(
            generationID: generationID,
            pricingFingerprint: fingerprint,
            claude: claude.newState,
            codex: codex.newState,
            claudeSeenMessageIds: claudeSeen,
            codexSeenTokenIds: codexSeen,
            pi: pi.newState,
            piSeenEntryIds: piSeen,
            opencode: opencode.newState,
            dsh: dshStateForScan
        )

        if shouldCommitSnapshot {
            let conversation = conversationAggregator.snapshot()
            let error = await persistSnapshot(
                snapshotID: generationID,
                fingerprint: fingerprint,
                hasScanProgress: true,
                integrity: .complete,
                degradeReasons: [],
                dshHistoryFrozen: dshFrozen,
                scanState: newScanState,
                buckets: buckets,
                conversationInfos: conversation.infos,
                conversationBuckets: conversation.buckets,
                cycleBuckets: cycleAggregator.snapshot(),
                cycleInitialRebuildCompletedAt: cycleInitialRebuildCompletedAt,
                cycleInitialRebuildCompletedApps: cycleInitialRebuildCompletedApps,
                dshContributions: dshContributions,
                dshRequiresRebuild: dshNeedsFullRescan
            )
            if let error {
                // 提交失败：内存回滚到上一份已提交快照，下一轮从同一 watermark 重扫，
                // 不重复累计。磁盘上的 current 没有被替换过，仍是一份完整提交。
                rollbackToCommittedSnapshot()
                lastError = error
                AppLog.error(.usage, "usage scan persistence failed: \(Redact.message(error))")
                return false
            }
            hasUnwrittenRollupChanges = false
            lastRollupWriteAt = Date()
            loadedCycleGeneration = generationID
        }
        loadedRollupGeneration = generationID
        cachedScanState = newScanState
        lastScanAt = Date()
        let unverifiedDshCount = dshContributions.values.filter { $0.needsVerification == true }.count
        if let error = opencode.error {
            lastError = error
            AppLog.warn(.usage, Redact.message(error))
        } else if failedFileCount > 0 {
            lastError = "usage scan incomplete: \(failedFileCount) log source(s) unreadable or conflicting; retrying next scan"
        } else if dshFrozen {
            lastError = "DSH usage history preserved; per-session contributions unavailable so new DSH usage is not collected"
        } else if unverifiedDshCount > 0 {
            lastError = "DSH historical usage for \(unverifiedDshCount) deleted session(s) could not be verified"
        } else {
            lastError = nil
        }
        publishTotals()

        let elapsed = String(format: "%.2fs", Date().timeIntervalSince(started))
        AppLog.info(.usage, """
            usage scan claude files=\(claude.filesScanned) lines=\(claude.linesParsed) new=\(claude.entries.count); \
            codex files=\(codex.filesScanned) lines=\(codex.linesParsed) new=\(codex.entries.count); \
            pi files=\(pi.filesScanned) lines=\(pi.linesParsed) new=\(pi.entries.count); \
            opencode messages=\(opencode.messagesRead) sessions=\(opencode.refreshedSessionIDs.count) entries=\(opencode.entries.count); \
            dsh files=\(dsh.filesScanned) new=\(dsh.entries.count) unreadable=\(dsh.failedFileCount) directories=\(dsh.failedDirectoryCount) duplicateIDs=\(dsh.duplicateSessionCount); \
            unreadable=\(failedFileCount); elapsed=\(elapsed)
            """)
        return true
    }

    /// DSH 的 Codex 订阅用量按逐会话贡献同一口径归入周期桶：贡献被整体替换的会话
    /// （换 generation、替换 / 截断重扫、新建）按会话替换周期桶，其余会话追加本轮新条目。
    private func applyDshCycleUpdate(
        _ update: DshContributionStore.Update,
        cycles: [QuotaCycleRecord],
        accountSegments: [QuotaCycleAccountSegment]
    ) -> Bool {
        guard !cycles.isEmpty else { return false }
        let replacedKeys = Set(update.replacedSessionIDs.map { "dsh:\($0)" })
        let appended = cycleAggregator.ingest(
            entries: update.entries.filter { !replacedKeys.contains($0.conversationKey) },
            cycles: cycles,
            accountSegments: accountSegments
        )
        let replaced = cycleAggregator.replaceConversations(
            app: .dsh,
            conversationKeys: replacedKeys,
            entries: update.entries,
            cycles: cycles,
            accountSegments: accountSegments
        )
        return appended || replaced
    }

    // MARK: - 提交与回滚

    /// 构造并提交一份完整快照。成功返回 nil，失败返回脱敏错误描述。
    private func persistSnapshot(
        snapshotID: String,
        fingerprint: String,
        hasScanProgress: Bool,
        integrity: UsageSnapshotIntegrity,
        degradeReasons: [UsageSnapshotDegradeReason],
        dshHistoryFrozen: Bool,
        scanState: ScanState,
        buckets: [UsageBucket],
        conversationInfos: [ConversationInfo],
        conversationBuckets: [ConversationUsageBucket],
        cycleBuckets: [CycleUsageBucket],
        cycleInitialRebuildCompletedAt: Date?,
        cycleInitialRebuildCompletedApps: Set<UsageApp>,
        dshContributions: [String: DshContribution],
        dshRequiresRebuild: Bool,
        rebuildState: (ledger: UsageMessageLedger, basis: UsageRebuildBasis)? = nil
    ) async -> String? {
        guard !storeWriteDisabled else { return "usage history store is read-only" }
        let now = Date()
        var snapshot = UsageSnapshot()
        // 账本与基准随汇总同代提交；不传时取内存里的当前值（增量、周期、退出保存）。
        let ledger = rebuildState?.ledger ?? messageLedger
        let basis = rebuildState?.basis ?? rebuildBasis
        snapshot.messageLedger = basis == nil && ledger.isEmpty ? nil : ledger.payload
        snapshot.rebuildBasis = basis
        // 首装没有旧标识；既有迁移结果必须跨增量、重算与周期提交保留。
        snapshot.codexModelIdentityMigration = committedSnapshot?.codexModelIdentityMigration
            ?? (committedSnapshot == nil ? CodexModelIdentityMigrationState() : nil)
        snapshot.snapshotID = snapshotID
        snapshot.createdAt = committedSnapshot?.createdAt ?? now
        snapshot.committedAt = now
        snapshot.integrity = integrity
        snapshot.degradeReasons = degradeReasons
        snapshot.hasScanProgress = hasScanProgress
        snapshot.scanState = scanState
        snapshot.usageRollup = UsageRollupPayload(
            generationID: snapshotID,
            pricingFingerprint: fingerprint,
            buckets: buckets,
            updatedAt: now
        )
        snapshot.conversationRollup = ConversationRollupPayload(
            generationID: snapshotID,
            pricingFingerprint: fingerprint,
            infos: conversationInfos,
            buckets: conversationBuckets,
            updatedAt: now
        )
        snapshot.cycleRollup = CycleUsageRollupPayload(
            generationID: snapshotID,
            pricingFingerprint: fingerprint,
            buckets: cycleBuckets,
            initialRebuildCompletedAt: cycleInitialRebuildCompletedAt,
            initialRebuildCompletedApps: cycleInitialRebuildCompletedApps,
            updatedAt: now
        )
        snapshot.dshContributions = DshContributionPayload(
            generationID: dshHistoryFrozen ? "" : snapshotID,
            pricingFingerprint: fingerprint,
            contributions: dshHistoryFrozen ? [:] : dshContributions,
            requiresRebuild: dshHistoryFrozen ? nil : dshRequiresRebuild,
            updatedAt: now
        )
        snapshot.dshHistoryFrozen = dshHistoryFrozen

        let store = historyStore
        let error: String? = await Task.detached(priority: .utility) {
            do {
                try store.commit(snapshot)
                return nil
            } catch {
                if let saved = store.loadCurrent().snapshot,
                   saved.snapshotID == snapshot.snapshotID,
                   saved.committedAt == snapshot.committedAt {
                    return nil
                }
                return String(describing: error)
            }
        }.value
        if let error { return error }
        committedSnapshot = snapshot
        return nil
    }

    /// 直接把一份已经构造好的快照提交到存储（迁移导入用）。
    private func persistExistingSnapshot(_ snapshot: UsageSnapshot) async -> String? {
        let store = historyStore
        let error: String? = await Task.detached(priority: .utility) {
            do {
                try store.commit(snapshot)
                return nil
            } catch {
                if let saved = store.loadCurrent().snapshot,
                   saved.snapshotID == snapshot.snapshotID,
                   saved.committedAt == snapshot.committedAt {
                    return nil
                }
                return String(describing: error)
            }
        }.value
        if let error { return error }
        committedSnapshot = snapshot
        return nil
    }

    /// 在第一次增量之前修复旧 Codex 身份；用量读取到旧 watermark 即止，进度不重置。
    /// 所有调用都已持有 isScanning，失败时不继续追加；下一次扫描可从同一旧快照重试。
    private func migrateCodexModelIdentityIfNeeded() async -> Bool {
        guard let baseline = committedSnapshot, baseline.codexModelIdentityMigration == nil else { return true }
        guard !storeWriteDisabled, baseline.hasScanProgress, historyRecoveryState == .complete,
              !codexModelIdentityMigrationDeferred else { return true }
        let codexRoots = roots.codexRoots
        let evidence = await Task.detached(priority: .utility) {
            await CodexJSONLScanner.scan(previous: [:], roots: codexRoots, indexedTitles: [:],
                                         historicalBoundary: baseline.scanState.codex)
        }.value
        // 读取失败 / 根目录不可访问 / 扫描中被移走可能下次就恢复，不能当成确定结果提交。
        // 本进程不再重试；在迁移提交前，新调用继续按旧身份入账（见 usesLegacyCodexModels），
        // 下次启动以届时的进度为边界重试，旧键对账仍然成立。
        guard evidence.historicalTransientFailureCount == 0 else {
            codexModelIdentityMigrationDeferred = true
            AppLog.warn(.usage, "Codex model identity migration deferred until next launch transient=\(evidence.historicalTransientFailureCount)")
            return true
        }
        do {
            let candidate: CodexModelIdentityMigration.Candidate
            do {
                candidate = try CodexModelIdentityMigration.makeCandidate(
                    baseline: baseline, evidence: evidence,
                    cycles: appState?.quotaCycles.records ?? [],
                    accountSegments: appState?.quotaCycles.accountSegments ?? []
                )
            } catch {
                // 候选被拒是确定性结果，重试不会变；保留全部旧桶并记录，不能让它阻塞增量采集。
                AppLog.info(.usage, "Codex model identity migration candidate rejected; retaining all legacy models: \(error)")
                candidate = try CodexModelIdentityMigration.makeRetainingCandidate(baseline: baseline)
            }
            if let error = await persistExistingSnapshot(candidate.snapshot) {
                lastError = "Codex model identity migration commit failed: \(error)"
                return false
            }
            let snapshot = candidate.snapshot
            aggregator.load(from: snapshot.usageRollup.buckets)
            conversationAggregator.load(infos: snapshot.conversationRollup.infos, buckets: snapshot.conversationRollup.buckets)
            let validCycles = Set(appState?.quotaCycles.records.map(\.id) ?? [])
            cycleAggregator.load(from: snapshot.cycleRollup.buckets.filter { validCycles.contains($0.cycleID) })
            cachedScanState = snapshot.scanState
            loadRebuildState(from: snapshot)
            loadedRollupGeneration = snapshot.snapshotID
            loadedCycleGeneration = snapshot.cycleRollup.generationID.isEmpty ? nil : snapshot.cycleRollup.generationID
            lastRollupWriteAt = snapshot.committedAt
            let result = snapshot.codexModelIdentityMigration!
            AppLog.info(.usage, "Codex model identity migration committed migrated=\(result.migratedModels.count) retained=\(result.retainedModels.count) unreadable=\(evidence.failedFileCount)")
            publishTotals()
            return true
        } catch {
            lastError = "Codex model identity migration rejected; history preserved: \(error)"
            return false
        }
    }

    /// 已有历史但标识迁移尚未提交时，Codex 新条目沿用旧存储身份，保证迁移重试时仍能按旧键逐桶对账。
    /// 首装或清空重建（没有已提交快照）直接使用完整渠道身份。
    private var usesLegacyCodexModels: Bool {
        guard let snapshot = committedSnapshot else { return false }
        return snapshot.codexModelIdentityMigration == nil
    }

    private nonisolated static func legacyCodexResult(_ result: CodexJSONLScanner.Result) -> CodexJSONLScanner.Result {
        var legacy = result
        legacy.entries = result.entries.map { entry in
            var old = entry
            old.model = Pricing.normalize(model: entry.model)
            return old
        }
        return legacy
    }

    /// 回滚到上一份成功提交的完整快照。没有提交过（首装）时清空内存。
    private func rollbackToCommittedSnapshot() {
        guard let snapshot = committedSnapshot else {
            clearUsageAggregatesForFullRebuild()
            return
        }
        aggregator.load(from: snapshot.usageRollup.buckets)
        conversationAggregator.load(
            infos: snapshot.conversationRollup.infos,
            buckets: snapshot.conversationRollup.buckets
        )
        cycleAggregator.load(from: snapshot.cycleRollup.buckets)
        loadedRollupGeneration = snapshot.snapshotID
        loadedCycleGeneration = snapshot.cycleRollup.generationID.isEmpty
            ? nil
            : snapshot.cycleRollup.generationID
        cycleInitialRebuildCompletedAt = snapshot.cycleRollup.initialRebuildCompletedAt
        cycleInitialRebuildCompletedApps = snapshot.cycleRollup.effectiveInitialRebuildCompletedApps
        cachedScanState = snapshot.hasScanProgress ? snapshot.scanState : nil
        dshContributions = snapshot.dshHistoryFrozen ? [:] : snapshot.dshContributions.contributions
        dshNeedsFullRescan = snapshot.dshHistoryFrozen
            || snapshot.dshContributions.generationID.isEmpty
            || snapshot.dshContributions.requiresRebuild == true
        loadRebuildState(from: snapshot)
        hasUnwrittenRollupChanges = false
        publishTotals()
    }

    // MARK: - 共用工具

    /// 刷新会话的完整贡献替换旧贡献，再从对话桶归并 OpenCode 日桶。
    /// 使用现有两个聚合器；不存在于源库的历史会话保留，其他服务分区不变。
    @discardableResult
    static func applyOpenCodeScan(
        _ scan: OpencodeScanner.Result,
        aggregator: UsageAggregator,
        conversations: ConversationAggregator
    ) -> Bool {
        guard scan.isComplete, !scan.refreshedSessionIDs.isEmpty else { return false }
        let refreshedKeys = Set(scan.refreshedSessionIDs.map { "opencode:\($0)" })
        let old = conversations.snapshot()
        let refreshed = ConversationAggregator()
        refreshed.ingest(entries: scan.entries, seeds: scan.conversationSeeds)
        let replacement = refreshed.snapshot()
        let infos = old.infos.filter {
            $0.app == .opencode && !refreshedKeys.contains($0.key)
        } + replacement.infos
        let buckets = old.buckets.filter {
            $0.app == .opencode && !refreshedKeys.contains($0.conversationKey)
        } + replacement.buckets

        // 签名改变但用量未变（如流式正文更新）时，不推进 UI revision 或重写 rollup。
        func bucketOrder(_ lhs: ConversationUsageBucket, _ rhs: ConversationUsageBucket) -> Bool {
            if lhs.conversationKey != rhs.conversationKey { return lhs.conversationKey < rhs.conversationKey }
            if lhs.day != rhs.day { return lhs.day < rhs.day }
            if lhs.model != rhs.model { return lhs.model < rhs.model }
            return lhs.speed.rawValue < rhs.speed.rawValue
        }
        let sameInfos = old.infos.filter { $0.app == .opencode }.sorted { $0.key < $1.key }
            == infos.sorted { $0.key < $1.key }
        let sameBuckets = old.buckets.filter { $0.app == .opencode }.sorted(by: bucketOrder)
            == buckets.sorted(by: bucketOrder)
        guard !sameInfos || !sameBuckets else { return false }

        struct DayKey: Hashable {
            var day: Date
            var model: String
            var speed: UsageSpeed
        }
        var dayBuckets: [DayKey: UsageBucket] = [:]
        for bucket in buckets {
            let key = DayKey(day: bucket.day, model: bucket.model, speed: bucket.speed)
            if var dayBucket = dayBuckets[key] {
                dayBucket.inputTokens += bucket.inputTokens
                dayBucket.outputTokens += bucket.outputTokens
                dayBucket.cacheReadTokens += bucket.cacheReadTokens
                dayBucket.cacheCreationTokens += bucket.cacheCreationTokens
                dayBucket.costUSD += bucket.costUSD
                dayBucket.requestCount += bucket.requestCount
                dayBucket.hasUnpricedUsage = dayBucket.hasUnpricedUsage || bucket.hasUnpricedUsage
                dayBuckets[key] = dayBucket
            } else {
                dayBuckets[key] = UsageBucket(
                    app: .opencode, model: bucket.model, speed: bucket.speed, day: bucket.day,
                    inputTokens: bucket.inputTokens, outputTokens: bucket.outputTokens,
                    cacheReadTokens: bucket.cacheReadTokens, cacheCreationTokens: bucket.cacheCreationTokens,
                    costUSD: bucket.costUSD, requestCount: bucket.requestCount,
                    hasUnpricedUsage: bucket.hasUnpricedUsage
                )
            }
        }
        aggregator.replaceLocal(app: .opencode, buckets: Array(dayBuckets.values))
        conversations.replaceLocal(app: .opencode, infos: infos, buckets: buckets)
        return true
    }

    /// 只把“已有 Standard/Fast 用量但当前所有可靠价格源都未命中”的桶视为刷新候选。
    /// Unknown 档位和已知模型的请求级限制（例如 Codex Fast >272K）不会造成无休止刷新。
    private func missingPricingKeys(in buckets: [UsageBucket]) -> Set<PricingUsageKey> {
        Set(buckets.compactMap { bucket -> PricingUsageKey? in
            guard bucket.hasUnpricedUsage else { return nil }
            guard Pricing.needsRemotePriceRefresh(
                model: bucket.model,
                app: bucket.app,
                speed: bucket.speed
            ) else { return nil }
            return PricingUsageKey(app: bucket.app, model: bucket.model, speed: bucket.speed)
        })
    }

    /// 手动重算路径的缺价刷新：等刷新完成，价格有变化时由调用方再做一轮完整重算。
    /// 自动路径走 `refreshMissingPricingInBackground`，不阻塞扫描。
    private func refreshMissingPricingIfNeeded() async -> Bool {
        let buckets = aggregator.snapshotLocal()
        let missing = missingPricingKeys(in: buckets)
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
    }
}
