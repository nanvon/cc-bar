import Foundation

/// 把 DSH 扫描结果合入逐会话贡献缓存（草案 §3.3）。
///
/// 三种情形刻意分开处理：
///   - **普通增量**：新帧的条目按会话累加进已有贡献。
///   - **换 generation 或源文件被原地替换/截断**：本轮条目就是该会话的完整内容，
///     必须**整体替换**该会话贡献（`usage = []` 后重新 merge），否则历史会翻倍。
///   - **本轮扫描失败的文件**：扫描器保留旧 watermark 且不产出条目，
///     因此这里天然保留旧贡献；已删除会话的路径不再出现在状态里，贡献同样保留（历史不倒扣）。
nonisolated enum DshContributionStore {
    struct Update: Sendable, Equatable {
        var contributions: [String: DshContribution]
        /// 是否有会话的用量或元数据发生变化。调用方据此决定这轮要不要落盘
        /// （未落盘就不能把结果计入内存聚合，否则下一轮重扫会重复计费）。
        var changed: Bool
    }

    /// - Parameter contributions: 上一轮的贡献缓存。
    /// - Returns: 新一轮贡献缓存与「是否有变化」；只改动本轮出现过的会话。
    static func apply(
        scan: DshSessionScanner.Result,
        to contributions: [String: DshContribution]
    ) -> Update {
        var updated = contributions
        var changed = false

        // 扫描器给的 conversationKey 是 `dsh:<会话自身 id>`：子代理归根由 rollup 负责，这里只按自身 id 分组。
        var entriesBySession: [String: [UsageEntry]] = [:]
        for entry in scan.entries where entry.app == .dsh {
            let id = sessionID(from: entry.conversationKey)
            guard !id.isEmpty else { continue }
            entriesBySession[id, default: []].append(entry)
        }

        for (path, state) in scan.newState {
            guard let id = state.conversationID else { continue }
            let previous = updated[id]
            var contribution = previous ?? DshContribution(
                sessionID: id,
                sourcePath: path,
                fileIdentity: nil,
                fileSize: 0,
                watermark: 0,
                cwd: nil,
                parentSession: nil,
                title: nil,
                usage: []
            )

            let generationChanged = contribution.sourcePath != path
            let restarted = scan.restartedSessionIDs.contains(id)
            if generationChanged || restarted {
                contribution.usage = []
            }

            contribution.sourcePath = path
            contribution.fileIdentity = state.fileIdentity
            contribution.fileSize = state.fileSize ?? 0
            contribution.watermark = state.offset
            // 头部元数据只增不减：`_no-cwd` 会话没有 cwd 时不要把已知值抹掉。
            contribution.cwd = state.conversationCwd ?? contribution.cwd
            contribution.parentSession = state.conversationParentSession ?? contribution.parentSession
            contribution.title = state.fallbackTitle ?? contribution.title
            contribution.merge(entriesBySession[id] ?? [])
            updated[id] = contribution
            if contribution != previous { changed = true }
        }

        // 状态里没有、却有用量的会话（正常流程不该出现）：保留用量，避免静默丢量。
        for (id, entries) in entriesBySession where updated[id] == nil {
            var contribution = DshContribution(
                sessionID: id,
                sourcePath: "",
                fileIdentity: nil,
                fileSize: 0,
                watermark: 0,
                cwd: nil,
                parentSession: nil,
                title: nil,
                usage: []
            )
            contribution.merge(entries)
            updated[id] = contribution
            changed = true
        }

        return Update(contributions: updated, changed: changed)
    }

    /// 从现存日志从零重建：调用方必须以**空扫描状态**跑一轮全量扫描，
    /// 这样每个文件的条目才是完整的（缓存缺失、版本不符或代次不一致时走这条路）。
    /// 已删除的会话文件无法恢复，这是第一版已知限制（§3.3）。
    static func rebuild(from scan: DshSessionScanner.Result) -> [String: DshContribution] {
        apply(scan: scan, to: [:]).contributions
    }

    private static func sessionID(from conversationKey: String) -> String {
        let prefix = "dsh:"
        guard conversationKey.hasPrefix(prefix) else { return "" }
        return String(conversationKey.dropFirst(prefix.count))
    }
}
