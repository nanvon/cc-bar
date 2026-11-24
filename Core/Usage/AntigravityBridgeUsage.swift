import Foundation
import Observation

/// Magpie 的 agy 插件（magpie-agy-bridge）对话库里的 Antigravity 用量。
///
/// Claude 3p、Pi、DSH 等经 Magpie 使用 Antigravity 订阅时，agy 把每次真实调用写进插件自己的数据根，
/// 库结构与 `AntigravityScanner` 读取的相同。这里只供额度页预估与 Popover 花费使用：这些请求在
/// 各 Agent 日志里已有记录，进入日桶会让统计页重复，因此独立保存，不写入日桶、对话桶和周期桶。
/// 源库删除后已读到的用量保留。
@MainActor
@Observable
final class AntigravityBridgeUsage {
    /// 对话库不含账号，归属取 Antigravity 当时的账号时间段。
    nonisolated struct Record: Sendable, Codable, Equatable {
        var t: Date
        var m: String
        var i: Int
        var o: Int
        var r: Int
        var w: Int

        init(_ entry: UsageEntry) {
            t = entry.timestamp
            m = entry.model
            i = entry.inputTokens
            o = entry.outputTokens
            r = entry.cacheReadTokens
            w = entry.cacheCreationTokens
        }
    }

    nonisolated struct Payload: Sendable, Codable {
        /// 解析或模型映射规则变化时提高，触发现存对话库整体重读；已删除对话的记录保留。
        static let currentVersion = 1
        var version = Self.currentVersion
        var scanState: AntigravityScanner.State?
        var conversations: [String: [Record]] = [:]
    }

    private nonisolated struct Update: Sendable {
        var payload: Payload
        var entries: [UsageEntry]
        var fingerprint: String
        var failedDatabaseCount: Int
        var recordsChanged: Bool
        var stateChanged: Bool
    }

    private struct BucketCache {
        var revision: UInt64
        var cycles: [QuotaCycleRecord]
        var accountSegments: [QuotaCycleAccountSegment]
        var buckets: [CycleUsageBucket]
    }

    /// 只含 Gemini 共享池，按时间升序。
    private(set) var entries: [UsageEntry] = []
    private(set) var revision: UInt64 = 0

    @ObservationIgnored private let roots: [URL]
    @ObservationIgnored private let cacheDirectory: URL?
    @ObservationIgnored private var payload: Payload?
    @ObservationIgnored private var pricingFingerprint: String?
    @ObservationIgnored private var lastWriteAt: Date?
    @ObservationIgnored private var hasUnwrittenChanges = false
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var bucketCache: [QuotaLimitKind: BucketCache] = [:]

    private nonisolated static let fileName = "antigravity-bridge-usage.json"
    private nonisolated static let writeInterval: TimeInterval = 5 * 60

    init(roots: [URL], cacheDirectory: URL? = nil) {
        self.roots = roots
        self.cacheDirectory = cacheDirectory
    }

    /// 与插件的默认数据根一致（`<状态目录>/magpie-agy-bridge/agy-home`）。
    nonisolated static func defaultRoots() -> [URL] {
        [FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/magpie-agy-bridge/agy-home/antigravity-cli", isDirectory: true)]
    }

    /// 最早一条用量的时间：之后经 Magpie 的 agy 用量以这里为准，不再计各 Agent 日志里的同一批请求。
    var coverageStart: Date? { entries.first?.timestamp }

    // MARK: - 刷新

    /// 读取变动的对话库。`scans` 为 false 时只恢复已保存的用量。
    func refresh(scans: Bool) async {
        guard !roots.isEmpty, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let roots = self.roots
        let url = Self.fileURL(in: cacheDirectory)
        let previous = payload
        let previousFingerprint = pricingFingerprint
        let update = await Task.detached(priority: .utility) {
            Self.makeUpdate(
                payload: previous ?? Self.load(from: url),
                isFirstLoad: previous == nil,
                previousFingerprint: previousFingerprint,
                roots: scans ? roots : []
            )
        }.value

        payload = update.payload
        pricingFingerprint = update.fingerprint
        if update.recordsChanged, entries != update.entries {
            entries = update.entries
            revision &+= 1
        }
        if update.failedDatabaseCount > 0 {
            AppLog.warn(.usage, "antigravity bridge unreadable databases=\(update.failedDatabaseCount)")
        }
        if update.stateChanged { hasUnwrittenChanges = true }
        guard hasUnwrittenChanges,
              lastWriteAt.map({ Date().timeIntervalSince($0) >= Self.writeInterval }) ?? true
        else { return }
        // 进度与记录同文件原子写入；未写成功时下次启动从旧进度重读，不会重复累计。
        let snapshot = update.payload
        let error = await Task.detached(priority: .utility) { () -> String? in
            do {
                try Self.save(snapshot, to: url)
                return nil
            } catch {
                return "\(error)"
            }
        }.value
        if let error {
            AppLog.error(.usage, "antigravity bridge save failed: \(Redact.message(error))")
        } else {
            hasUnwrittenChanges = false
            lastWriteAt = Date()
        }
    }

    private nonisolated static func makeUpdate(
        payload: Payload,
        isFirstLoad: Bool,
        previousFingerprint: String?,
        roots: [URL]
    ) -> Update {
        var next = payload
        let scan = AntigravityScanner.scan(previous: payload.scanState, roots: roots)
        let grouped = Dictionary(grouping: scan.entries, by: \.conversationKey)
        for id in scan.refreshedConversationIDs {
            next.conversations[id] = grouped["antigravity:\(id)"]?.map(Record.init) ?? []
        }
        let stateChanged = scan.newState != (payload.scanState ?? AntigravityScanner.State())
        next.scanState = scan.newState

        let models = Set(next.conversations.values.joined().map(\.m))
        let fingerprint = Pricing.fingerprint(knownUsage: Set(models.map {
            PricingUsageKey(app: .antigravity, model: $0, speed: .standard)
        }))
        let recordsChanged = isFirstLoad || !scan.refreshedConversationIDs.isEmpty
            || fingerprint != previousFingerprint
        // 费用不落盘，按当前价格计算，价格更新后自动跟随。
        let entries = recordsChanged ? makeEntries(next.conversations) : []
        return Update(
            payload: next,
            entries: entries,
            fingerprint: fingerprint,
            failedDatabaseCount: scan.failedDatabaseCount,
            recordsChanged: recordsChanged,
            stateChanged: stateChanged || !scan.refreshedConversationIDs.isEmpty
        )
    }

    private nonisolated static func makeEntries(_ conversations: [String: [Record]]) -> [UsageEntry] {
        var entries: [UsageEntry] = []
        for (id, records) in conversations {
            for record in records where CycleUsageAggregator.countsTowardAntigravityGeminiPool(model: record.m) {
                entries.append(AntigravityScanner.makeEntry(
                    conversationID: id,
                    record: AntigravityScanner.UsageRecord(
                        identity: "", model: record.m, timestamp: record.t,
                        input: record.i, output: record.o, cacheRead: record.r, cacheCreation: record.w
                    )
                ))
            }
        }
        return entries.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - 取数

    /// `[from, to)` 内的等值费用；缺价的请求按 0 计。
    func cost(from: Date, to: Date) -> Decimal {
        entries[index(of: from)..<max(index(of: from), index(of: to))]
            .reduce(Decimal(0)) { $0 + ($1.costUSD ?? 0) }
    }

    /// 归入 Antigravity 周期的用量，归属规则与 `CycleUsageAggregator.ingest` 相同。
    /// 周期边界随采样修正，因此按当前周期现算，不落盘。
    func cycleBuckets(
        cycles: [QuotaCycleRecord],
        kind: QuotaLimitKind,
        accountSegments: [QuotaCycleAccountSegment]
    ) -> [CycleUsageBucket] {
        guard !entries.isEmpty else { return [] }
        let cycles = cycles.filter { $0.app == .antigravity && $0.limitKind == kind }
        let segments = accountSegments.filter { $0.app == .antigravity }
        if let cache = bucketCache[kind], cache.revision == revision,
           cache.cycles == cycles, cache.accountSegments == segments {
            return cache.buckets
        }
        var buckets: [CycleUsageBucket] = []
        for cycle in cycles {
            let lower = index(of: cycle.startAt)
            let upper = max(lower, index(of: cycle.endAt))
            guard lower < upper else { continue }
            let overlapping = cycles.filter { $0.startAt < cycle.endAt && $0.endAt > cycle.startAt }
            let aggregator = CycleUsageAggregator()
            aggregator.ingest(
                entries: Array(entries[lower..<upper]), cycles: overlapping, accountSegments: segments
            )
            buckets += aggregator.snapshot().filter { $0.cycleID == cycle.id }
        }
        bucketCache[kind] = BucketCache(
            revision: revision, cycles: cycles, accountSegments: segments, buckets: buckets
        )
        return buckets
    }

    /// 第一条不早于 `date` 的下标。
    private func index(of date: Date) -> Int {
        var low = 0
        var high = entries.count
        while low < high {
            let middle = (low + high) / 2
            if entries[middle].timestamp < date { low = middle + 1 } else { high = middle }
        }
        return low
    }

    // MARK: - 持久化

    private nonisolated static func load(from url: URL) -> Payload {
        guard let data = try? Data(contentsOf: url),
              var payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return Payload() }
        if payload.version != Payload.currentVersion {
            payload.version = Payload.currentVersion
            payload.scanState = nil
        }
        return payload
    }

    private nonisolated static func save(_ payload: Payload, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder().encode(payload).write(to: url, options: [.atomic])
    }

    private nonisolated static func fileURL(in directory: URL?) -> URL {
        let directory = directory ?? (FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true))
            .appendingPathComponent("CCBar", isDirectory: true)
        return directory.appendingPathComponent(fileName, isDirectory: false)
    }
}
