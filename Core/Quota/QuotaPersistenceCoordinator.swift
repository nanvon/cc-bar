import Foundation

/// 批次 C（草案 §4.4）：额度持久化的统一提交入口。
///
/// - 一轮刷新内的多次内存更新只标脏，刷新 / bootstrap / 设置操作末尾构造
///   不可变 snapshot 提交一次，同一文件一轮最多写一次。
/// - actor 串行执行写入；写入进行中到达的新 snapshot 合并为 pending，当前
///   写入完成后继续写最新版本，保证「后发的新版本不得被先发但较晚完成的
///   旧 snapshot 覆盖」。
/// - 失败只记录日志，不回滚内存快照与 UI；下一次成功刷新会重新生成完整
///   payload 并覆盖。
/// - 不持有 AppState，输入必须是不可变、Sendable 的值快照。
actor QuotaPersistenceCoordinator {
    /// 本轮需要落盘的 quota 文件；字段为 nil 表示该文件本轮没有变化。
    /// `sequence` 由 AppState 在 MainActor 上单调递增分配，用于丢弃乱序到达的
    /// 过期提交：`Task.detached` 的执行顺序无语言保证，两个 flush 可能乱序到达
    /// actor，旧快照若后到会覆盖新快照，必须按序列号裁决。
    struct Snapshot: Sendable {
        var sequence: UInt64
        var cache: QuotaCachePayload?
        var history: QuotaHistoryPayload?
        var cycles: QuotaCyclePayload?
    }

    typealias Writer = @Sendable (Snapshot) throws -> Void

    private let writer: Writer
    private var pending: Snapshot?
    private var writing = false
    /// 已成功写入的最新序列号；序列号不高于它的提交直接忽略。
    private var lastWrittenSequence: UInt64 = 0

    init(writer: @escaping Writer = QuotaPersistenceCoordinator.defaultWriter) {
        self.writer = writer
    }

    /// 默认写入器：把三个文件分别编码后原子落盘（对应各自 store 的 save）。
    /// 三个文件彼此不是一套 generation 事务，各自独立保存。
    nonisolated static func defaultWriter(_ snapshot: Snapshot) throws {
        if let cache = snapshot.cache {
            try QuotaCache.save(cache)
        }
        if let history = snapshot.history {
            try QuotaHistoryStore.save(history)
        }
        if let cycles = snapshot.cycles {
            try QuotaCycleStore.save(cycles)
        }
    }

    /// 提交一次快照。串行执行；写入中到达的新快照合并后只写最新版本。
    func submit(_ snapshot: Snapshot) async {
        // 乱序防护：已写过更新的、或已有更新的在排队，都直接丢弃。
        guard snapshot.sequence > lastWrittenSequence else { return }
        if let pending, pending.sequence >= snapshot.sequence { return }
        pending = merged(pending, with: snapshot)
        if writing { return }
        writing = true
        defer { writing = false }
        while let next = pending {
            pending = nil
            do {
                try writer(next)
                lastWrittenSequence = max(lastWrittenSequence, next.sequence)
            } catch {
                AppLog.error(.persistence, "quota write failed: \(Redact.error(error))")
            }
        }
    }

    private func merged(_ current: Snapshot?, with incoming: Snapshot) -> Snapshot {
        Snapshot(
            sequence: incoming.sequence,
            cache: incoming.cache ?? current?.cache,
            history: incoming.history ?? current?.history,
            cycles: incoming.cycles ?? current?.cycles
        )
    }
}

/// 额度持久化文件标记（AppState 内本轮标脏用）。
enum QuotaFile: String, Sendable {
    case cache
    case history
    case cycles
}
