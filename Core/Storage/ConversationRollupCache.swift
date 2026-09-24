import Foundation

nonisolated struct ConversationRollupPayload: Sendable, Codable {
    /// v5: 配合 ScanState v9 清除曾被提前入账的 Claude 流式半成品。
    /// v6: Pi/OpenCode 统一费用解析规则改变，旧聚合结果必须全量重算。
    /// v7: 配合 ScanState v13（项目归属隐私分级），受保护目录项目改为字符串归组，旧归组必须全量重算。
    /// v8: 新增 DSH 本地用量对话（配合 ScanState v15）；旧快照没有 DSH 档案，必须全量重建。
    static let currentVersion = 8
    var version = Self.currentVersion
    var generationID = ""
    /// 写盘时记录的价格指纹，仅作诊断；加载不因指纹不一致丢弃（价格变化不自动重算）。
    var pricingFingerprint = ""
    var infos: [ConversationInfo] = []
    var buckets: [ConversationUsageBucket] = []
    var updatedAt = Date.distantPast
}

enum ConversationRollupCache {
    nonisolated private static let fileName = "conversation-rollup.json"
    nonisolated private static let bundleDirectory = "CCBar"

    /// - Parameter directory: 缓存所在目录，nil 走生产路径。测试必须注入临时目录：
    ///   直接读写生产路径会覆盖用户真机的对话 rollup。
    nonisolated static func load(in directory: URL? = nil) -> ConversationRollupPayload {
        let url = cacheFileURL(in: directory)
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(ConversationRollupPayload.self, from: data),
              payload.version == ConversationRollupPayload.currentVersion else {
            return ConversationRollupPayload()
        }
        return payload
    }

    nonisolated static func save(_ payload: ConversationRollupPayload, in directory: URL? = nil) throws {
        let url = cacheFileURL(in: directory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(payload).write(to: url, options: [.atomic])
    }

    nonisolated static func cacheFileURL(in directory: URL? = nil) -> URL {
        if let directory {
            return directory.appendingPathComponent(fileName, isDirectory: false)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent(bundleDirectory, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }
}
