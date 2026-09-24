import Foundation
import os

/// LiteLLM / models.dev 远端价格目录：内存快照 + 磁盘缓存 + 后台刷新（stale-while-revalidate）。
///
/// 用锁保护的普通 class（不用 `actor`）：`rate(for:app:speed:)` 必须保持同步调用，因为它被 `Pricing.cost()`
/// 同步调用，而 `Pricing.cost()` 又被两个 JSONL Scanner 同步调用——接远端价格目录不应该把整条
/// 计价链路改成 async。刷新（网络 I/O）本身仍然是 `Task.detached` 里的 async 工作，只是读侧保持同步。
nonisolated final class PricingCatalogStore: @unchecked Sendable {
    static let shared = PricingCatalogStore()

    /// `active` 是当前扫描可读取的冻结价格快照；后台刷新只更新 `pending`，由下一次
    /// 扫描开始时统一提交，避免同一批 JSONL 前后读到不同价格。
    private struct CatalogState {
        var active: PricingCatalogCachePayload
        var pending: PricingCatalogCachePayload?
    }

    private enum Source: Sendable {
        case liteLLM
        case modelsDev

        func state(in payload: PricingCatalogCachePayload) -> PricingSourceState {
            switch self {
            case .liteLLM: payload.liteLLM
            case .modelsDev: payload.modelsDev
            }
        }

        func update(
            _ payload: inout PricingCatalogCachePayload,
            _ body: (inout PricingSourceState) -> Void
        ) {
            switch self {
            case .liteLLM: body(&payload.liteLLM)
            case .modelsDev: body(&payload.modelsDev)
            }
        }
    }

    private let refreshInterval: TimeInterval = 24 * 3600
    private let failureRetryInterval: TimeInterval = 30 * 60
    private let missingRefreshInterval: TimeInterval = 30 * 60
    private let suspiciousShrinkMinimumExistingCount = 20
    private let missingRefreshRetention: TimeInterval = 7 * 24 * 3600

    private let state: OSAllocatedUnfairLock<CatalogState>
    private let refreshRunning = OSAllocatedUnfairLock(initialState: false)

    private static let liteLLMURL = URL(
        string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
    )!
    private static let modelsDevURL = URL(string: "https://models.dev/api.json")!

    private init() {
        state = OSAllocatedUnfairLock(initialState: CatalogState(active: PricingCatalogCache.load()))
    }

    /// 快速同步读取，零 I/O，不阻塞调用方。Standard 沿用 LiteLLM 优先；
    /// Fast 统一 models.dev 优先（其官方 provider 的显式 fast mode 已核对），LiteLLM Priority 只兜底。
    func rate(for normalizedKey: String, app: UsageApp, speed: UsageSpeed) -> ModelPrice? {
        state.withLock { catalog in
            switch speed {
            case .standard:
                return catalog.active.liteLLM.standardRates[normalizedKey]
                    ?? catalog.active.modelsDev.standardRates[normalizedKey]
            case .fast:
                switch app {
                case .codex:
                    return catalog.active.modelsDev.codexFastRates[normalizedKey]
                        ?? catalog.active.liteLLM.codexFastRates[normalizedKey]
                case .claude:
                    return catalog.active.modelsDev.claudeFastRates[normalizedKey]
                        ?? catalog.active.liteLLM.claudeFastRates[normalizedKey]
                case .cursor:
                    return nil
                case .pi:
                    return nil
                case .opencode:
                    return nil
                case .dsh:
                    // DSH 没有 Fast 档位概念。
                    return nil
                }
            case .unknown:
                return nil
            }
        }
    }

    /// 扫描开始前提交已完成刷新的目录。扫描进行中产生的新目录继续留在 pending，
    /// 留给下一次扫描使用，保证 `Pricing.cost()` 和最终 fingerprint 读取同一份价格表。
    @discardableResult
    func commitPending() -> Bool {
        state.withLock { catalog -> Bool in
            guard let pending = catalog.pending else { return false }
            catalog.active = pending
            catalog.pending = nil
            return true
        }
    }

    /// App 启动、以及每次用量扫描开始时调用。非阻塞：内部判断是否到期，真正到期才会
    /// 发起网络请求；已有刷新在跑则直接返回，不重复起任务。
    func refreshIfNeeded() {
        let now = Date()
        let due = state.withLock { catalog in
            let payload = catalog.pending ?? catalog.active
            return isDue(payload.liteLLM, now: now) || isDue(payload.modelsDev, now: now)
        }
        guard due else { return }

        guard beginRefresh() else { return }

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            _ = await self.performRefresh(force: false)
            self.refreshRunning.withLock { $0 = false }
        }
    }

    #if DEBUG
    /// 单元测试隔离用：丢弃内存中的远端目录快照。测试进程宿主是 CCBar.app，会加载开发者机器
    /// Application Support 下的真实磁盘缓存，使计价断言漂移；先清空内存态并删除磁盘缓存，
    /// 保证断言只基于内置本地表（在线优先的模型在无缓存时回落到本地兜底价）。
    func resetCatalogForTesting() {
        refreshRunning.withLock { $0 = false }
        state.withLock {
            $0 = CatalogState(active: PricingCatalogCachePayload(), pending: nil)
        }
        try? PricingCatalogCache.save(PricingCatalogCachePayload())
    }
    #endif

    /// 用户手动更新：绕过 24 小时与失败退避。若常规刷新正在进行，等它完成后再强制刷新，
    /// 避免只复用「其中一个源到期」的常规结果而漏掉另一个源。
    func forceRefresh() async -> Bool {
        while !beginRefresh() {
            await waitForRefreshCompletion()
        }
        let succeeded = await performRefresh(force: true)
        refreshRunning.withLock { $0 = false }
        return succeeded
    }

    /// 扫描发现缺价时触发。每个 app/model/speed 持久化 30 分钟冷却，避免上游尚未收录时反复下载。
    func refreshForMissing(_ keys: Set<PricingUsageKey>) async -> Bool {
        let now = Date()
        let eligible = state.withLock { catalog -> Bool in
            var payload = catalog.pending ?? catalog.active
            payload.missingRefreshAttempts = payload.missingRefreshAttempts.filter {
                now.timeIntervalSince($0.value) < missingRefreshRetention
            }
            let dueKeys = keys.filter { key in
                guard let attemptedAt = payload.missingRefreshAttempts[key.persistedKey] else { return true }
                return now.timeIntervalSince(attemptedAt) >= missingRefreshInterval
            }
            guard !dueKeys.isEmpty else { return false }
            for key in dueKeys {
                payload.missingRefreshAttempts[key.persistedKey] = now
            }
            catalog.pending = payload
            return true
        }
        guard eligible else { return false }
        persist()
        return await forceRefresh()
    }

    private func beginRefresh() -> Bool {
        refreshRunning.withLock { running -> Bool in
            if running { return false }
            running = true
            return true
        }
    }

    private func waitForRefreshCompletion() async {
        while refreshRunning.withLock({ $0 }) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func isDue(_ source: PricingSourceState, now: Date) -> Bool {
        if let failedAt = source.failedAt, now.timeIntervalSince(failedAt) < failureRetryInterval {
            return false
        }
        guard let fetchedAt = source.fetchedAt else { return true }
        return now.timeIntervalSince(fetchedAt) >= refreshInterval
    }

    private func performRefresh(force: Bool) async -> Bool {
        let liteLLM = await refreshSource(
            url: Self.liteLLMURL,
            source: .liteLLM,
            force: force,
            decode: LiteLLMPricingDecoder.decode
        )
        let modelsDev = await refreshSource(
            url: Self.modelsDevURL,
            source: .modelsDev,
            force: force,
            decode: ModelsDevPricingDecoder.decode
        )
        return liteLLM || modelsDev
    }

    private func refreshSource(
        url: URL,
        source: Source,
        force: Bool,
        decode: @Sendable (Data) throws -> DecodedPricingRates
    ) async -> Bool {
        let now = Date()
        let (due, previousSource) = state.withLock { catalog -> (Bool, PricingSourceState) in
            let payload = catalog.pending ?? catalog.active
            let sourceState = source.state(in: payload)
            return (force || isDue(sourceState, now: now), sourceState)
        }
        guard due else { return false }

        switch await PricingCatalogClient.fetch(url: url, etag: previousSource.etag) {
        case .success(.notModified):
            mutatePending { payload in
                source.update(&payload) {
                    $0.fetchedAt = now
                    $0.failedAt = nil
                }
            }
            persist()
            return true

        case .success(.updated(let data, let newEtag)):
            do {
                // 解码即校验；结果为空也会被 decode 抛出（emptyFeed），一并走 catch。
                let rates = try decode(data)
                guard !isSuspiciousShrink(rates.standard, comparedTo: previousSource.standardRates) else {
                    // 可疑的部分目录不能覆盖旧数据。清掉 ETag，确保退避后是一次完整拉取，
                    // 而不是对这份可疑内容收到 304 后把旧 Standard rates 误标为新鲜。
                    mutatePending { payload in
                        source.update(&payload) {
                            $0.etag = nil
                            $0.failedAt = now
                        }
                    }
                    persist()
                    AppLog.warn(.pricing, """
                        suspicious shrink, kept old cache: \(url.lastPathComponent) \
                        old=\(previousSource.standardRates.count) new=\(rates.standard.count)
                        """)
                    return false
                }
                mutatePending { payload in
                    source.update(&payload) {
                        $0.standardRates = rates.standard
                        // Fast 支持可能下线，但历史日志仍需按最后可靠价格计费；新增/改价覆盖，缺失不删除。
                        $0.codexFastRates.merge(rates.codexFast) { _, new in new }
                        $0.claudeFastRates.merge(rates.claudeFast) { _, new in new }
                        $0.etag = newEtag
                        $0.fetchedAt = now
                        $0.failedAt = nil
                    }
                }
                persist()
                return true
            } catch {
                // 远端请求成功不等于价格正确：解析失败/结果为空一律保留旧缓存，只记退避时间戳。
                mutatePending { payload in
                    source.update(&payload) {
                        $0.etag = nil
                        $0.failedAt = now
                    }
                }
                persist()
                AppLog.warn(.pricing, "decode failed, kept old cache: \(url.lastPathComponent) \(Redact.error(error))")
                return false
            }

        case .failure(let err):
            mutatePending { payload in
                source.update(&payload) { $0.failedAt = now }
            }
            persist()
            AppLog.warn(.pricing, "fetch failed, kept old cache: \(url.lastPathComponent) \(Redact.error(err))")
            return false
        }
    }

    private func mutatePending(_ update: (inout PricingCatalogCachePayload) -> Void) {
        state.withLock { catalog in
            var payload = catalog.pending ?? catalog.active
            update(&payload)
            catalog.pending = payload
        }
    }

    private func isSuspiciousShrink(_ newRates: [String: ModelPrice], comparedTo oldRates: [String: ModelPrice]) -> Bool {
        oldRates.count >= suspiciousShrinkMinimumExistingCount && newRates.count * 2 < oldRates.count
    }

    private func persist() {
        // pending 是最近一次成功或失败刷新后的最新磁盘态；下次 App 启动可直接把它作为 active。
        let snapshot = state.withLock { $0.pending ?? $0.active }
        do {
            try PricingCatalogCache.save(snapshot)
        } catch {
            AppLog.error(.pricing, "price catalog save failed: \(Redact.error(error))")
        }
    }
}

/// 远端价格 JSON 的网络请求封装，风格对齐 `Core/Quota/CodexQuotaClient.swift`。
enum PricingCatalogClient {
    enum FetchOutcome: Sendable {
        case notModified
        case updated(Data, etag: String?)
    }

    enum FetchError: Error, Sendable {
        case transport(String)
        case http(Int)
    }

    nonisolated static func fetch(url: URL, etag: String?) async -> Result<FetchOutcome, FetchError> {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag, !etag.isEmpty {
            req.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { return .failure(.transport("\(error)")) }
        guard let http = resp as? HTTPURLResponse else { return .failure(.transport("non-http")) }

        switch http.statusCode {
        case 304:
            return .success(.notModified)
        case 200..<300:
            return .success(.updated(data, etag: http.value(forHTTPHeaderField: "Etag")))
        default:
            return .failure(.http(http.statusCode))
        }
    }
}

/// `pricing-catalog.json` 磁盘缓存，风格对齐 `Core/Storage/QuotaCache.swift`。
enum PricingCatalogCache {
    nonisolated private static let fileName = "pricing-catalog.json"
    nonisolated private static let bundleDirectory = "CCBar"

    nonisolated static func load() -> PricingCatalogCachePayload {
        let url = cacheFileURL()
        guard let data = try? Data(contentsOf: url) else {
            return PricingCatalogCachePayload()
        }
        if let payload = try? JSONDecoder().decode(PricingCatalogCachePayload.self, from: data),
           payload.version == PricingCatalogCachePayload.currentVersion {
            return payload
        }
        // v1 只有 Standard rates；迁移时保留离线缓存，但清掉 ETag/刷新时间，
        // 否则上游持续返回 304 会让新版永远没有机会解析 Fast 字段。
        if let legacy = try? JSONDecoder().decode(LegacyPayloadV1.self, from: data),
           legacy.version == 1 {
            return PricingCatalogCachePayload(
                liteLLM: legacy.liteLLM.migrated,
                modelsDev: legacy.modelsDev.migrated
            )
        }
        return PricingCatalogCachePayload()
    }

    nonisolated static func save(_ payload: PricingCatalogCachePayload) throws {
        let url = cacheFileURL()
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: url, options: [.atomic])
    }

    nonisolated static func cacheFileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent(bundleDirectory, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private struct LegacySourceV1: Codable {
        var rates: [String: ModelPrice]

        var migrated: PricingSourceState {
            PricingSourceState(
                standardRates: rates
            )
        }
    }

    private struct LegacyPayloadV1: Codable {
        var version: Int
        var liteLLM: LegacySourceV1
        var modelsDev: LegacySourceV1
    }
}
