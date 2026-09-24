import Foundation

/// DSH 单会话贡献里按 (日, 模型, 速度) 汇总的一桶用量。
/// 它是**本地派生数据**：只存 token / 请求数 / 费用分项与首末时间，不含消息正文、提示词或凭据。
nonisolated struct DshContributionBucket: Sendable, Codable, Equatable {
    var day: Date
    var model: String
    var speed: UsageSpeed
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheCreationTokens: Int
    var requestCount: Int
    var costInput: Decimal
    var costOutput: Decimal
    var costCacheRead: Decimal
    var costCacheCreation: Decimal
    /// 该桶内有条目缺可靠价格（`costUSD == nil`），只作诊断，金额按已知部分计。
    var hasUnpricedUsage: Bool
    var firstAt: Date
    var lastAt: Date

    var costUSD: Decimal { costInput + costOutput + costCacheRead + costCacheCreation }
}

/// 一个 DSH 会话（含子代理会话）对总量的贡献。
///
/// 存在的意义（草案 §3.3）：generation 切换、父链变化、源文件被删都不能让历史用量翻倍或消失。
/// 主 rollup 是「全部贡献重新归并」的结果，而贡献本身按会话替换或累加。
nonisolated struct DshContribution: Sendable, Codable, Equatable {
    var sessionID: String
    /// 当前选中的日志路径（generation 切换后会指向新文件）。
    var sourcePath: String
    var fileIdentity: ScanFileIdentity?
    var fileSize: UInt64
    var watermark: UInt64
    /// 头部元数据：用于对话展示与父链归并。
    var cwd: String?
    var parentSession: String?
    var title: String?
    var usage: [DshContributionBucket]

    /// 把一轮新增条目按 (日, 模型, 速度) 合入。
    mutating func merge(_ entries: [UsageEntry]) {
        for entry in entries where entry.app == .dsh {
            let key = BucketKey(day: entry.day, model: entry.model, speed: entry.speed)
            if let index = usage.firstIndex(where: { $0.key == key }) {
                usage[index].inputTokens += entry.inputTokens
                usage[index].outputTokens += entry.outputTokens
                usage[index].cacheReadTokens += entry.cacheReadTokens
                usage[index].cacheCreationTokens += entry.cacheCreationTokens
                usage[index].requestCount += entry.requestCount
                usage[index].costInput += entry.costBreakdown?.input ?? 0
                usage[index].costOutput += entry.costBreakdown?.output ?? 0
                usage[index].costCacheRead += entry.costBreakdown?.cacheRead ?? 0
                usage[index].costCacheCreation += entry.costBreakdown?.cacheCreation ?? 0
                usage[index].hasUnpricedUsage = usage[index].hasUnpricedUsage || entry.costBreakdown == nil
                usage[index].firstAt = min(usage[index].firstAt, entry.timestamp)
                usage[index].lastAt = max(usage[index].lastAt, entry.timestamp)
            } else {
                usage.append(DshContributionBucket(
                    day: entry.day,
                    model: entry.model,
                    speed: entry.speed,
                    inputTokens: entry.inputTokens,
                    outputTokens: entry.outputTokens,
                    cacheReadTokens: entry.cacheReadTokens,
                    cacheCreationTokens: entry.cacheCreationTokens,
                    requestCount: entry.requestCount,
                    costInput: entry.costBreakdown?.input ?? 0,
                    costOutput: entry.costBreakdown?.output ?? 0,
                    costCacheRead: entry.costBreakdown?.cacheRead ?? 0,
                    costCacheCreation: entry.costBreakdown?.cacheCreation ?? 0,
                    hasUnpricedUsage: entry.costBreakdown == nil,
                    firstAt: entry.timestamp,
                    lastAt: entry.timestamp
                ))
            }
        }
        usage.sort { $0.key < $1.key }
    }

    struct BucketKey: Equatable {
        var day: Date
        var model: String
        var speed: UsageSpeed

        static func < (lhs: BucketKey, rhs: BucketKey) -> Bool {
            if lhs.day != rhs.day { return lhs.day < rhs.day }
            if lhs.model != rhs.model { return lhs.model < rhs.model }
            return lhs.speed.rawValue < rhs.speed.rawValue
        }
    }
}

private extension DshContributionBucket {
    var key: DshContribution.BucketKey {
        DshContribution.BucketKey(day: day, model: model, speed: speed)
    }
}

nonisolated struct DshContributionPayload: Sendable, Codable {
    /// v1: 首版。DSH 解析规则或价格口径变化时 bump，并重新归并受影响贡献。
    static let currentVersion = 1
    var version = Self.currentVersion
    /// 与 scan-state、日 rollup、对话 rollup 共用的代次；不一致就整体重建（§3.3）。
    var generationID = ""
    var pricingFingerprint = ""
    var contributions: [String: DshContribution] = [:]
    var updatedAt = Date.distantPast
}

/// DSH 逐会话贡献缓存的读取结论。缓存缺失、版本不符或代次不一致都必须显式标为需要重建，
/// 不能把不匹配的贡献和旧桶混用（§3.3）。
nonisolated enum DshContributionLoadResult: Sendable {
    case valid([String: DshContribution])
    /// 需要从现存 DSH 日志重建；已删除会话的历史无法恢复，属第一版已知限制。
    case rebuild
}

/// 落 `~/Library/Application Support/CCBar/`，与日 / 对话 rollup 同级——
/// 这份缓存的全部意义就是保住已删除会话文件的历史，放 Caches 等于交给系统清理（§6 决策 2）。
enum DshContributionCache {
    nonisolated private static let fileName = "dsh-contributions.json"
    nonisolated private static let bundleDirectory = "CCBar"

    nonisolated static func load(
        generationID: String,
        in directory: URL? = nil
    ) -> DshContributionLoadResult {
        let url = cacheFileURL(in: directory)
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(DshContributionPayload.self, from: data),
              payload.version == DshContributionPayload.currentVersion,
              !payload.generationID.isEmpty,
              payload.generationID == generationID
        else {
            return .rebuild
        }
        return .valid(payload.contributions)
    }

    nonisolated static func save(
        _ contributions: [String: DshContribution],
        generationID: String,
        pricingFingerprint: String,
        in directory: URL? = nil
    ) throws {
        let url = cacheFileURL(in: directory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var payload = DshContributionPayload()
        payload.generationID = generationID
        payload.pricingFingerprint = pricingFingerprint
        payload.contributions = contributions
        payload.updatedAt = Date()
        try JSONEncoder().encode(payload).write(to: url, options: [.atomic])
    }

    nonisolated static func cacheFileURL(in directory: URL? = nil) -> URL {
        if let directory {
            return directory.appendingPathComponent(fileName)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent(bundleDirectory, isDirectory: true)
            .appendingPathComponent(fileName)
    }
}
