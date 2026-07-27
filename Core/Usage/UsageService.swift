import Foundation
import Observation

/// 协调 JSONL 扫描 → 聚合 → 持久化 → 通知 AppState 的入口。
@MainActor
@Observable
final class UsageService {
    let aggregator = UsageAggregator()
    let conversationAggregator = ConversationAggregator()
    private(set) var isScanning = false
    private(set) var lastScanAt: Date?
    private(set) var lastError: String?

    private weak var appState: AppState?
    private var scanQueued = false
    private var requiresFullRebuild = false
    private var loadedRollupGeneration: String?
    /// 上一轮成功提交的 ScanState 常驻内存，避免每轮扫描都从磁盘重读重解码
    /// scan-state.json（随文件数和 seen ID 增长，本地实测已近 1MB）。
    /// 冷启动首轮才从磁盘恢复；持久化失败时清空内存副本，
    /// 由 requiresFullRebuild 强制下轮全量重建。
    private var cachedScanState: ScanState?

    func bootstrap(appState: AppState) {
        self.appState = appState
        // 只有两份 rollup 同代才允许恢复，避免部分写入后把旧桶和新 watermark 混用。
        let payload = UsageRollupCache.load()
        let conversationPayload = ConversationRollupCache.load()
        let generationsMatch = !payload.generationID.isEmpty
            && payload.generationID == conversationPayload.generationID
        if generationsMatch {
            aggregator.load(from: payload.buckets)
            conversationAggregator.load(infos: conversationPayload.infos, buckets: conversationPayload.buckets)
            loadedRollupGeneration = payload.generationID
            lastScanAt = max(payload.updatedAt, conversationPayload.updatedAt)
        } else {
            aggregator.load(from: [])
            conversationAggregator.load(infos: [], buckets: [])
            requiresFullRebuild = true
            loadedRollupGeneration = nil
            lastScanAt = nil
        }
        // 个人历史用量一次性补录：见 ImportedUsageBackfill 注释。这里先合并一次保证扫描前即可展示；
        // runScan 每轮还会按同样规则重新合并，兜底缓存失效清空聚合器的情况。文件不存在时是纯 no-op。
        let existingClaudeDays = Set(aggregator.snapshot().filter { $0.app == .claude }.map(\.day))
        aggregator.ingest(ImportedUsageBackfill.loadMissingEntries(app: .claude, existingDays: existingClaudeDays))
        publishTotals()
        // 远端价格目录后台刷新：非阻塞，isDue 内部判断是否真的需要发请求，刷新结果由下次扫描自然拾取。
        PricingCatalogStore.shared.refreshIfNeeded()
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
            let knownModels = Set(aggregator.snapshot().map { $0.model })
            let cacheResult = await resolveScanState(knownModels: knownModels)
            if case .invalidated = cacheResult {
                cachedScanState = nil
                aggregator.load(from: [])
                conversationAggregator.load(infos: [], buckets: [])
                loadedRollupGeneration = nil
                publishTotals()
            }
            if await runScan(prev: cacheResult.state) {
                requiresFullRebuild = false
            }
        } while scanQueued
    }

    /// 决定本轮扫描的起点状态。优先用内存里上一轮已提交的 ScanState；
    /// 内存路径与磁盘路径执行同样的校验——generationID 须与已加载 rollup 同代、
    /// 价格指纹须与当前 active 价格目录一致（commitPending 提交新价格后指纹变化，
    /// 照旧触发全量重建）。只有冷启动且两份 rollup 恢复成功时，
    /// 首轮需要读盘取得与它们同代的 ScanState。
    private func resolveScanState(knownModels: Set<String>) async -> ScanCacheLoadResult {
        if requiresFullRebuild { return .invalidated }
        if let cached = cachedScanState {
            if cached.generationID == loadedRollupGeneration,
               cached.pricingFingerprint == Pricing.fingerprint(knownModels: knownModels) {
                return .valid(cached)
            }
            return .invalidated
        }
        let loaded = await Task.detached(priority: .utility) {
            ScanCache.load(knownModels: knownModels)
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
        defer { isScanning = false }
        PricingCatalogStore.shared.refreshIfNeeded()
        // 手动重算同样是一次完整扫描：先提交已经刷好的 pending，避免用户刚点击重算
        // 却仍按旧 active 价格扫描；本次刚发起的网络刷新则留给下一次扫描。
        PricingCatalogStore.shared.commitPending()
        cachedScanState = nil
        aggregator.load(from: [])
        conversationAggregator.load(infos: [], buckets: [])
        loadedRollupGeneration = nil
        publishTotals()
        requiresFullRebuild = true
        if await runScan(prev: ScanState()) {
            requiresFullRebuild = false
        }
    }

    @discardableResult
    private func runScan(prev: ScanState) async -> Bool {
        let started = Date()
        let prevSeen = prev.claudeSeenMessageIds
        let prevGrokSeen = prev.grokSeenPromptIds
        async let claudeTask = Task.detached(priority: .utility) {
            ClaudeJSONLScanner.scan(previous: prev.claude, seenMessageIds: prevSeen)
        }.value
        async let codexTask = Task.detached(priority: .utility) {
            CodexJSONLScanner.scan(previous: prev.codex)
        }.value
        async let grokTask = Task.detached(priority: .utility) {
            GrokJSONLScanner.scan(previous: prev.grok, seenPromptIds: prevGrokSeen)
        }.value

        let claude = await claudeTask
        let codex = await codexTask
        let grok = await grokTask

        aggregator.ingest(claude.entries)
        aggregator.ingest(codex.entries)
        aggregator.ingest(grok.entries)
        let conversationChanged = conversationAggregator.ingest(
            entries: claude.entries + codex.entries + grok.entries,
            seeds: claude.conversationSeeds + codex.conversationSeeds + grok.conversationSeeds
        )

        // 个人历史用量一次性补录：缓存失效路径会清空聚合器，若只在 bootstrap 合并，
        // 这里落盘的 rollup / 指纹将不含补录模型，下次启动指纹比对再失效、补录被反复冲掉。
        // 每轮扫描都按天去重重新合并，保证快照与指纹始终包含补录数据。
        let existingClaudeDays = Set(aggregator.snapshot().filter { $0.app == .claude }.map(\.day))
        aggregator.ingest(ImportedUsageBackfill.loadMissingEntries(app: .claude, existingDays: existingClaudeDays))

        // 没有真实用量或档案变化时沿用现有代次，只提交轻量 watermark。
        let buckets = aggregator.snapshot()
        let fingerprint = Pricing.fingerprint(knownModels: Set(buckets.map { $0.model }))
        let hasNewEntries = !claude.entries.isEmpty || !codex.entries.isEmpty || !grok.entries.isEmpty
        let shouldWriteRollups = loadedRollupGeneration == nil || hasNewEntries || conversationChanged
        let generationID = shouldWriteRollups ? UUID().uuidString : loadedRollupGeneration!
        let newScanState = ScanState(
            generationID: generationID,
            pricingFingerprint: fingerprint,
            claude: claude.newState,
            codex: codex.newState,
            grok: grok.newState,
            claudeSeenMessageIds: claude.newSeenIds,
            grokSeenPromptIds: grok.newSeenIds
        )
        let shouldWriteScanState = newScanState != prev

        let rollup: UsageRollupPayload?
        let conversationRollup: ConversationRollupPayload?
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
        } else {
            rollup = nil
            conversationRollup = nil
        }

        let persistenceError: String? = await Task.detached(priority: .utility) {
            do {
                if let rollup, let conversationRollup {
                    // 聚合结果先落盘，watermark 最后提交；generationID 用于启动时识别中断写入。
                    try UsageRollupCache.save(rollup)
                    try ConversationRollupCache.save(conversationRollup)
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

        loadedRollupGeneration = generationID
        cachedScanState = newScanState
        lastScanAt = Date()
        lastError = nil
        publishTotals()

        let elapsed = String(format: "%.2fs", Date().timeIntervalSince(started))
        print("[UsageScan 用量扫描] claude files=\(claude.filesScanned) lines=\(claude.linesParsed) new=\(claude.entries.count); codex files=\(codex.filesScanned) lines=\(codex.linesParsed) new=\(codex.entries.count); grok files=\(grok.filesScanned) lines=\(grok.linesParsed) new=\(grok.entries.count); elapsed=\(elapsed)")
        return true
    }

    private func publishTotals() {
        guard let appState else { return }
        appState.codexTodayCost = aggregator.todayCost(for: .codex)
        appState.claudeTodayCost = aggregator.todayCost(for: .claude)
        appState.grokTodayCost = aggregator.todayCost(for: .grok)
    }
}
