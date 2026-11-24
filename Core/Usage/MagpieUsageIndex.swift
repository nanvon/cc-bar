import Foundation

/// Magpie 网关的请求记录（`~/.config/magpie/usage.jsonl`）：按消息 ID 查一次请求实际走的渠道和模型。
///
/// Claude 3p 的对话日志只有模型名，没有渠道；Magpie 改派请求时，日志里还是请求的模型名。
/// Magpie 把返回给客户端的 `message.id` 记作 `response_id`，据此还原。只读取匹配所需的字段，
/// 不读取账号、用量与其他内容，也不写入这个文件。
nonisolated final class MagpieUsageIndex: @unchecked Sendable {
    /// 一次请求实际走的渠道和模型。
    struct Route: Sendable, Equatable {
        var provider: String
        var model: String

        /// 查价用的完整标识。`claude` 渠道就是 Claude 订阅，与直连使用同一标识。
        var identity: String {
            provider == "claude" ? model : "magpie/\(provider)/\(model)"
        }

        /// 存储用的模型标识。
        var storageModel: String {
            provider == "claude"
                ? Pricing.normalize(model: model)
                : CodexJSONLScanner.storageModel(identity)
        }
    }

    /// 一轮扫描使用的只读快照。
    struct Snapshot: Sendable {
        var routes: [String: Route] = [:]
        /// 记录文件可用；不可用时不等待尚未写入的记录。
        var isAvailable = false
        /// 读取记录的时刻，之后写入的记录不在 `routes` 里。
        var loadedAt = Date()

        /// 记录在请求结束后才写入，可能晚于对话日志。
        static let maximumDelay: TimeInterval = 2 * 60

        /// 消息刚产生、记录可能还没写入，应留到下一轮再入账。
        func isAwaitingRecord(messageTime: Date) -> Bool {
            isAvailable && loadedAt.timeIntervalSince(messageTime) < Self.maximumDelay
        }
    }

    static let shared = MagpieUsageIndex()

    private struct FileState {
        var offset: UInt64 = 0
        var inode: UInt64?
        var routes: [String: Route] = [:]
    }

    private let lock = NSLock()
    private var files: [String: FileState] = [:]

    static func defaultURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/magpie/usage.jsonl")
    }

    /// 读入新增的记录并返回快照。文件不存在或读不出时沿用已读到的记录。
    func snapshot(url: URL?) -> Snapshot {
        guard let url else { return Snapshot() }
        lock.lock()
        defer { lock.unlock() }

        let loadedAt = Date()
        var state = files[url.path] ?? FileState()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return Snapshot(routes: state.routes, isAvailable: false, loadedAt: loadedAt)
        }
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        // 文件被替换或截断时从头读；已读到的记录保留。
        if inode != state.inode || size < state.offset { state.offset = 0 }
        state.inode = inode

        let outcome = JSONLLineReader.streamLines(url: url, fromOffset: state.offset) { batch in
            for line in batch {
                guard let (id, route) = Self.parse(line) else { continue }
                state.routes[id] = route
            }
        }
        var isAvailable = false
        if case let .success(newOffset) = outcome {
            state.offset = newOffset
            isAvailable = true
        }
        files[url.path] = state
        return Snapshot(routes: state.routes, isAvailable: isAvailable, loadedAt: loadedAt)
    }

    /// 只取 Claude 客户端（`claude` / `claude-desktop`）的请求。
    static func parse(_ line: String) -> (id: String, route: Route)? {
        guard line.contains("\"response_id\""), line.contains("\"agent\":\"claude"),
              let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["agent"] as? String)?.hasPrefix("claude") == true,
              let id = root["response_id"] as? String, !id.isEmpty,
              let provider = root["provider"] as? String, !provider.isEmpty,
              let model = root["model"] as? String, !model.isEmpty
        else { return nil }
        return (id, Route(provider: provider, model: model))
    }
}
