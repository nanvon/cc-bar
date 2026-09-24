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
    /// Codex 用：最近一条 `session_meta` 的会话 ID。fork 会话的 JSONL 里混有父会话原样重放的
    /// session_meta，它与文件自身的会话 ID 不同；续扫时要接上这个上下文才能生成正确的跨文件去重键。
    var lastCodexEmittingSessionID: String?
    /// 对话元数据：Codex 用于跨 active/archive 复用 watermark；Claude 用于未变化文件的轻量项目重解析。
    var conversationID: String?
    var conversationCwd: String?
    var conversationGitBranch: String?
    var conversationIsSidechain: Bool?
    var fallbackTitle: String?
    /// DSH 用：`session` 记录里的 `parentSession`，用于把子代理归到所属根会话（§4.1）。
    var conversationParentSession: String?
    /// DSH 用：文件身份（device + inode）。同路径被原地替换时 inode 会变，
    /// 此时不能从旧 offset 续读，必须从 0 重扫并替换该会话贡献（§3.3）。
    var fileIdentity: ScanFileIdentity?
    /// DSH 用：上次扫描时的大小，用于「offset > size 即被截断」的判定。
    var fileSize: UInt64?
}

/// 文件身份。刻意不用 mtime：追加写会让 mtime 变化，但那是正常增量而不是替换。
nonisolated struct ScanFileIdentity: Sendable, Equatable, Codable {
    var device: UInt64
    var inode: UInt64

    /// 读取路径的 device / inode；文件不存在或读取失败返回 nil。
    nonisolated static func read(atPath path: String) -> ScanFileIdentity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value
        else { return nil }
        return ScanFileIdentity(device: device, inode: inode)
    }
}

nonisolated struct ScanState: Sendable, Equatable, Codable {
    /// version 管「结构变更」（字段增减或费用口径改变时 bump）；价格变化不触发自动失效，
    /// 历史费用保持旧价，由设置页「重新计算用量」手动对齐。
    /// 因此**修正本地价格表（`Pricing.table` 等）后若要让已发布用户的历史费用自动对齐，
    /// 必须一并 bump 本版本号**——没有指纹兜底了，忘了 bump 就只有手动重算才会生效。
    /// v9: Claude 流式半成品不再入账；旧 seen / rollup 可能已污染，必须全量重建。
    /// v10: 新增 pi 扫描 watermark（`pi` / `piSeenEntryIds`）。
    /// v11: 新增 opencode 扫描 watermark（`opencodeLastMessageTime` / `opencodeSeenMessageIds`）。
    /// v12: Pi/OpenCode 统一费用解析规则改变，旧扫描结果必须全量重算。
    /// v13: 项目归属隐私分级——受 TCC 保护目录不再做文件系统检查，旧项目归组必须全量重算。
    /// v14: Codex fork 会话重放父会话历史导致的重复计费（`codexSeenTokenIds`），
    ///      且 fork 文件的用量此前错归到父会话 key；旧桶已被污染，必须全量重建。
    /// v15: 新增 DSH 本地用量服务（`dsh` watermark 与逐会话贡献缓存）。
    ///      日 / 对话 rollup 同步 bump（10 / 8），首版落地使旧扫描状态与旧 rollup 一起失效（§7 S4）。
    static let currentVersion: Int = 15
    var version: Int = ScanState.currentVersion
    var generationID: String = ""
    /// 写盘时记录的价格指纹，仅作诊断；加载不因指纹不一致失效（价格变化不自动重算）。
    var pricingFingerprint: String = ""
    var claude: [String: ScanFileState] = [:]
    var codex: [String: ScanFileState] = [:]
    /// 跨文件的 Claude message.id 去重集合（同一条 assistant 消息可能被 sidechain / subagent 在多个 jsonl 里重复引用）。
    var claudeSeenMessageIds: [String] = []
    /// 跨文件的 Codex token_count 去重集合，键为 `发出该记录的会话 id#累计用量签名`；
    /// 覆盖 fork 会话把父会话整段历史重放进新 JSONL 导致的重复计费。
    var codexSeenTokenIds: [String] = []
    /// pi 扫描 watermark；pi 会话树分支/复制场景按 (entryID@ISO timestamp) 全局去重。
    var pi: [String: ScanFileState] = [:]
    var piSeenEntryIds: [String] = []
    /// opencode 扫描 watermark：max(message.time_created)（Unix 毫秒），消息只追加。
    var opencodeLastMessageTime: Int64 = 0
    /// 跨会话的 opencode message.id 去重集合（compaction 重写 / 时间戳回跳兜底）。
    var opencodeSeenMessageIds: [String] = []
    /// DSH 扫描 watermark：按规范日志文件路径记录；generation 切换淘汰的文件不再续扫。
    var dsh: [String: ScanFileState] = [:]
}

/// 保留插入顺序的去重集合，供三个扫描器做跨文件 ID 去重并按「最近 N 条」截断。
///
/// 旧实现是 `Array(Set(...)).suffix(n)`：`Array(Set)` 给出的是哈希桶顺序、与插入顺序
/// 无关，因此截断保留的是随机 n 条而非最近 n 条（可能把刚插入的新 ID 丢掉，文件被截断
/// 重扫时就会重复计费）；而且集合扩容 rehash 后整个数组顺序重排，会让内容等价的
/// `ScanState` 每轮都被判为已变化，白白重写数 MB 的 scan-state.json。这里显式维护顺序：
/// 没有新 ID 时输出数组与输入逐元素相同，`ScanState` 比较即可判等、跳过写盘。
nonisolated struct SeenIDSet {
    /// 三个扫描器共用的保留条数上限。
    static let defaultLimit = 20000

    /// 旧 → 新。
    private var ordered: [String]
    private var index: Set<String>

    /// - Parameter existing: 上一轮持久化的 ID，已按旧 → 新排列；重复项按首次出现保留。
    init(_ existing: [String]) {
        var index = Set<String>()
        index.reserveCapacity(existing.count)
        var ordered: [String] = []
        ordered.reserveCapacity(existing.count)
        for id in existing where index.insert(id).inserted {
            ordered.append(id)
        }
        self.ordered = ordered
        self.index = index
    }

    func contains(_ id: String) -> Bool {
        index.contains(id)
    }

    mutating func insert(_ id: String) {
        guard index.insert(id).inserted else { return }
        ordered.append(id)
    }

    /// 批量撤销插入。Pi scanner 在文件读取失败时要回滚本文件本轮记下的 key，
    /// 逐个删会在两万级数组上做多次线性查找，这里合并成一次扫描。
    mutating func remove(contentsOf ids: [String]) {
        let dropped = Set(ids.filter { index.remove($0) != nil })
        guard !dropped.isEmpty else { return }
        ordered.removeAll { dropped.contains($0) }
    }

    /// 保留最近 `limit` 条（新的在后）。
    func capped(to limit: Int) -> [String] {
        ordered.count > limit ? Array(ordered.suffix(limit)) : ordered
    }
}

/// 扫描缓存的读取结论。缓存文件缺失、损坏或版本不符必须显式标为失效，
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

    /// - Parameter directory: 缓存所在目录，nil 走生产路径。测试必须注入临时目录：
    ///   直接读写生产路径会删掉用户真机 watermark，害得下次启动全量重扫 GB 级日志。
    nonisolated static func load(in directory: URL? = nil) -> ScanCacheLoadResult {
        let url = cacheFileURL(in: directory)
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(ScanState.self, from: data),
              state.version == ScanState.currentVersion
        else {
            return .invalidated
        }
        return .valid(state)
    }

    nonisolated static func save(_ state: ScanState, in directory: URL? = nil) throws {
        let url = cacheFileURL(in: directory)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 纯机器读的缓存文件，不用 sortedKeys：省掉每轮写盘时的全量键排序。
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: [.atomic])
    }

    /// 聚合缓存保存失败时移除已提交 watermark，确保下次只能走全量重建。
    nonisolated static func invalidate(in directory: URL? = nil) throws {
        let url = cacheFileURL(in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    nonisolated static func cacheFileURL(in directory: URL? = nil) -> URL {
        if let directory {
            return directory.appendingPathComponent(fileName, isDirectory: false)
        }
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
    /// version 管「结构变更或费用口径改变」；价格变化不触发自动失效，由手动重算对齐。
    /// v8: 配合 ScanState v9 清除曾被提前入账的 Claude 流式半成品。
    /// v9: Pi/OpenCode 统一费用解析规则改变，旧聚合结果必须全量重算。
    /// v10: 新增 DSH 本地用量服务（配合 ScanState v15）；旧快照没有 DSH 分区，必须全量重建。
    static let currentVersion: Int = 10
    var version: Int = UsageRollupPayload.currentVersion
    var generationID: String = ""
    /// 写盘时记录的价格指纹，仅作诊断；加载不因指纹不一致丢弃（价格变化不自动重算）。
    var pricingFingerprint: String = ""
    var buckets: [UsageBucket] = []
    var updatedAt: Date = Date()
}

enum UsageRollupCache {
    nonisolated private static let fileName = "usage-rollup.json"
    nonisolated private static let bundleDirectory = "CCBar"

    /// - Parameter directory: 缓存所在目录，nil 走生产路径；测试注入临时目录，理由同 `ScanCache`。
    nonisolated static func load(in directory: URL? = nil) -> UsageRollupPayload {
        let url = cacheFileURL(in: directory)
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(UsageRollupPayload.self, from: data),
              payload.version == UsageRollupPayload.currentVersion
        else {
            return UsageRollupPayload()
        }
        return payload
    }

    nonisolated static func save(_ payload: UsageRollupPayload, in directory: URL? = nil) throws {
        let url = cacheFileURL(in: directory)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(payload)
        try data.write(to: url, options: [.atomic])
    }

    nonisolated static func cacheFileURL(in directory: URL? = nil) -> URL {
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
