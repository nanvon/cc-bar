import Foundation

/// 单个 JSONL 文件的扫描 watermark。
nonisolated struct ScanFileState: Sendable, Equatable, Codable {
    var mtime: Double          // file modification time, epoch seconds
    var offset: UInt64         // 已扫到的字节数
    /// Codex 用：当前会话最近一次 `turn_context` 里的模型，用于给后续 token_count 打标签。
    var lastModel: String?
    /// Codex 用：最近一次 thread_settings_applied 的速度档位，用于增量续扫时给后续 token_count 打标签。
    var lastServiceTier: UsageSpeed?
    /// Codex 用：最近一次累计 total_token_usage 的稳定签名，过滤切换设置时重复发出的旧 token_count。
    var lastCodexTotalUsageSignature: String?
    /// 对话元数据：Codex 用于跨 active/archive 复用 watermark；Claude 用于未变化文件的轻量项目重解析。
    var conversationID: String?
    var conversationCwd: String?
    var conversationGitBranch: String?
    var conversationIsSidechain: Bool?
    var fallbackTitle: String?
}

nonisolated struct ScanState: Sendable, Equatable, Codable {
    /// version 管「结构变更」（字段增减导致解码不兼容时 bump）；价格变更由 pricingFingerprint 接管。
    /// v10: 接入 Grok Build 本地用量扫描（`~/.grok/sessions/**/updates.jsonl`）。
    static let currentVersion: Int = 10
    var version: Int = ScanState.currentVersion
    var generationID: String = ""
    /// 写盘时记录的价格指纹；load 时与当前 `Pricing.fingerprint(knownModels:)` 不一致即视为缓存失效、全量重扫重算。
    var pricingFingerprint: String = ""
    var claude: [String: ScanFileState] = [:]
    var codex: [String: ScanFileState] = [:]
    var grok: [String: ScanFileState] = [:]
    /// 跨文件的 Claude message.id 去重集合（同一条 assistant 消息可能被 sidechain / subagent 在多个 jsonl 里重复引用）。
    var claudeSeenMessageIds: [String] = []
    /// Grok turn_completed 的 prompt_id 去重（主会话 / subagent 可能重复写同一 turn）。
    var grokSeenPromptIds: [String] = []
}

/// 扫描缓存的读取结论。缓存文件缺失、损坏、版本不符或价格指纹变化都必须显式标为失效，
/// 由调用方在全量扫描前清空内存聚合，不能把它们和「本来就为空的有效状态」混为一谈。
nonisolated enum ScanCacheLoadResult: Sendable {
    case valid(ScanState)
    case invalidated

    var state: ScanState {
        switch self {
        case .valid(let state):
            return state
        case .invalidated:
            return ScanState()
        }
    }
}

enum ScanCache {
    nonisolated private static let fileName = "scan-state.json"
    nonisolated private static let bundleDirectory = "CCBar"

    /// - Parameter knownModels: 用于比对价格指纹的「当前已知模型集合」，通常传
    ///   `Set(aggregator.snapshot().map(\.model))`（调用方 `UsageService.scanNow()` 传入）。
    nonisolated static func load(knownModels: Set<String>) -> ScanCacheLoadResult {
        let url = cacheFileURL()
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(ScanState.self, from: data),
              state.version == ScanState.currentVersion,
              state.pricingFingerprint == Pricing.fingerprint(knownModels: knownModels)
        else {
            return .invalidated
        }
        return .valid(state)
    }

    nonisolated static func save(_ state: ScanState) throws {
        let url = cacheFileURL()
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 纯机器读的缓存文件，不用 sortedKeys：省掉每轮写盘时的全量键排序。
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: [.atomic])
    }

    /// 聚合缓存保存失败时移除已提交 watermark，确保下次只能走全量重建。
    nonisolated static func invalidate() throws {
        let url = cacheFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    nonisolated static func cacheFileURL() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches", isDirectory: true)
        return caches
            .appendingPathComponent(bundleDirectory, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }
}

/// 聚合结果磁盘缓存，启动后立刻 UI 有数。
nonisolated struct UsageRollupPayload: Sendable, Codable {
    /// version 管「结构变更」；价格变更由 pricingFingerprint 接管。
    /// v9: 配合 ScanState v10 接入 Grok 本地用量。
    static let currentVersion: Int = 9
    var version: Int = UsageRollupPayload.currentVersion
    var generationID: String = ""
    /// 写盘时记录的价格指纹；load 时与当前 `Pricing.fingerprint(knownModels:)` 不一致即丢弃，全量重扫重建。
    var pricingFingerprint: String = ""
    var buckets: [UsageBucket] = []
    var updatedAt: Date = Date()
}

enum UsageRollupCache {
    nonisolated private static let fileName = "usage-rollup.json"
    nonisolated private static let bundleDirectory = "CCBar"

    /// 自包含校验：用 payload 自带的 `buckets` 推导「已知模型集合」现算指纹去比对，
    /// 不需要外部传参——等价于「用这份缓存自己包含的模型集合，检验它的指纹在今天的价格下是否还成立」。
    nonisolated static func load() -> UsageRollupPayload {
        let url = cacheFileURL()
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(UsageRollupPayload.self, from: data),
              payload.version == UsageRollupPayload.currentVersion
        else {
            return UsageRollupPayload()
        }
        let knownModels = Set(payload.buckets.map { $0.model })
        guard payload.pricingFingerprint == Pricing.fingerprint(knownModels: knownModels) else {
            return UsageRollupPayload()
        }
        return payload
    }

    nonisolated static func save(_ payload: UsageRollupPayload) throws {
        let url = cacheFileURL()
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(payload)
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
}
