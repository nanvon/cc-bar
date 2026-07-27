import Foundation

/// 扫 `~/.grok/sessions/**/updates.jsonl`，把 `turn_completed` 的 usage 解析成 UsageEntry。
///
/// 数据源与 Grok Build CLI 一致：
/// - 路径：`~/.grok/sessions/<url-encoded-cwd>/<session-id>/updates.jsonl`
/// - 子 agent：`.../subagents/<id>/updates.jsonl`
/// - 事件：`method` 为 `_x.ai/session/update`，`sessionUpdate == turn_completed`
/// - 去重：`prompt_id`（同一 turn 只计一次）
/// - 花费：优先 `costUsdTicks`（1 tick = 1e-9 USD），否则走 `Pricing` 本地表
enum GrokJSONLScanner {
    /// costUsdTicks → USD 的换算：1e9 ticks = $1
    nonisolated static let ticksPerUSD: Decimal = 1_000_000_000

    struct Result: Sendable {
        var entries: [UsageEntry]
        var conversationSeeds: [ConversationSeed]
        var newState: [String: ScanFileState]
        var newSeenIds: [String]
        var filesScanned: Int
        var linesParsed: Int
    }

    nonisolated static func scan(previous: [String: ScanFileState], seenPromptIds: [String]) -> Result {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent(".grok/sessions", isDirectory: true)
        return scan(previous: previous, seenPromptIds: seenPromptIds, root: root)
    }

    /// 可注入 root，供测试。
    nonisolated static func scan(
        previous: [String: ScanFileState],
        seenPromptIds: [String],
        root: URL
    ) -> Result {
        let allJSONL = JSONLDirectoryEnumerator.files(at: root)
        // 只扫 updates.jsonl（主会话与 subagent 均用此文件名）
        let files = allJSONL.filter { $0.lastPathComponent == "updates.jsonl" }

        var newState: [String: ScanFileState] = previous
        var entries: [UsageEntry] = []
        var linesParsed = 0
        var seeds: [String: ConversationSeed] = [:]
        var seen = Set(seenPromptIds)

        for url in files {
            let path = url.path
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0

            var state = previous[path] ?? ScanFileState(mtime: 0, offset: 0)
            if state.mtime == mtime, state.offset == size {
                newState[path] = state
                // 未变文件也补 seed，便于对话列表展示标题/项目
                if let id = state.conversationID {
                    let key = "grok:\(id)"
                    if seeds[key] == nil {
                        seeds[key] = seed(
                            sessionID: id,
                            path: path,
                            title: state.fallbackTitle,
                            cwd: state.conversationCwd
                        )
                    }
                }
                continue
            }
            if state.offset > size {
                state.offset = 0
            }

            guard let read = JSONLLineReader.read(url: url, fromOffset: state.offset) else {
                newState[path] = state
                continue
            }

            let meta = sessionMeta(for: url)
            if state.conversationID == nil {
                state.conversationID = meta.sessionID
            }
            if state.conversationCwd == nil || state.conversationCwd?.isEmpty == true {
                state.conversationCwd = meta.cwd
            }
            if state.fallbackTitle == nil {
                state.fallbackTitle = meta.title
            }
            let sessionID = state.conversationID ?? meta.sessionID
            let conversationKey = "grok:\(sessionID)"
            seeds[conversationKey] = seed(
                sessionID: sessionID,
                path: path,
                title: state.fallbackTitle ?? meta.title,
                cwd: state.conversationCwd ?? meta.cwd
            )

            for line in read.lines {
                linesParsed += 1
                guard let turns = parseTurnCompleted(line) else { continue }
                for turn in turns {
                    if seen.contains(turn.promptID) { continue }
                    seen.insert(turn.promptID)

                    let day = UsageDay.startOfDay(for: turn.timestamp)
                    for modelUsage in turn.models {
                        let model = Pricing.normalize(model: modelUsage.model)
                        let cacheRead = modelUsage.cacheReadTokens
                        // Grok 的 inputTokens 含 cachedRead；用量表记非缓存输入。
                        let input = max(0, modelUsage.inputTokens - cacheRead)
                        let output = modelUsage.outputTokens + modelUsage.reasoningTokens
                        let costUSD = resolveCost(
                            ticks: modelUsage.costUsdTicks ?? turn.totalCostUsdTicks,
                            model: model,
                            input: input,
                            output: output,
                            cacheRead: cacheRead,
                            at: turn.timestamp
                        )
                        entries.append(UsageEntry(
                            app: .grok,
                            conversationKey: conversationKey,
                            model: model,
                            speed: .standard,
                            day: day,
                            timestamp: turn.timestamp,
                            inputTokens: input,
                            outputTokens: output,
                            cacheReadTokens: cacheRead,
                            cacheCreationTokens: 0,
                            costUSD: costUSD,
                            costBreakdown: nil
                        ))
                    }
                }
            }

            state.mtime = mtime
            state.offset = read.newOffset
            newState[path] = state
        }

        // 清理已消失的文件 watermark
        let live = Set(files.map(\.path))
        newState = newState.filter { live.contains($0.key) }

        return Result(
            entries: entries,
            conversationSeeds: Array(seeds.values),
            newState: newState,
            newSeenIds: Array(seen),
            filesScanned: files.count,
            linesParsed: linesParsed
        )
    }

    // MARK: - Parse

    private struct TurnModelUsage: Sendable {
        var model: String
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int
        var reasoningTokens: Int
        var costUsdTicks: Int64?
    }

    private struct TurnUsage: Sendable {
        var promptID: String
        var timestamp: Date
        var models: [TurnModelUsage]
        var totalCostUsdTicks: Int64?
    }

    nonisolated private static func parseTurnCompleted(_ line: String) -> [TurnUsage]? {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // 兼容 method 字段形态；实际线上为 `_x.ai/session/update`
        let method = root["method"] as? String ?? ""
        if !method.isEmpty, !method.contains("session/update") {
            return nil
        }

        guard let params = root["params"] as? [String: Any],
              let update = params["update"] as? [String: Any],
              let kind = update["sessionUpdate"] as? String,
              kind == "turn_completed"
        else { return nil }

        let promptID = nonEmpty(update["prompt_id"] as? String)
            ?? nonEmpty(update["promptId"] as? String)
        guard let promptID else { return nil }

        let usage = update["usage"] as? [String: Any] ?? [:]
        let totalTicks = int64(usage["costUsdTicks"])
        let timestamp = parseTimestamp(root["timestamp"]) ?? Date()

        var models: [TurnModelUsage] = []
        if let modelUsage = usage["modelUsage"] as? [String: Any], !modelUsage.isEmpty {
            for (model, raw) in modelUsage {
                guard let dict = raw as? [String: Any] else { continue }
                models.append(TurnModelUsage(
                    model: model,
                    inputTokens: int(dict["inputTokens"]),
                    outputTokens: int(dict["outputTokens"]),
                    cacheReadTokens: int(dict["cachedReadTokens"]),
                    reasoningTokens: int(dict["reasoningTokens"]),
                    costUsdTicks: int64(dict["costUsdTicks"])
                ))
            }
        } else if usage["inputTokens"] != nil || usage["totalTokens"] != nil {
            // 无 modelUsage 时退回顶层 usage + 缺省模型名
            models.append(TurnModelUsage(
                model: "grok-4.5",
                inputTokens: int(usage["inputTokens"]),
                outputTokens: int(usage["outputTokens"]),
                cacheReadTokens: int(usage["cachedReadTokens"]),
                reasoningTokens: int(usage["reasoningTokens"]),
                costUsdTicks: totalTicks
            ))
        }

        guard !models.isEmpty else { return nil }
        // 过滤全零用量（取消过早的 turn）
        models = models.filter {
            $0.inputTokens + $0.outputTokens + $0.cacheReadTokens + $0.reasoningTokens > 0
        }
        guard !models.isEmpty else { return nil }

        return [TurnUsage(
            promptID: promptID,
            timestamp: timestamp,
            models: models,
            totalCostUsdTicks: totalTicks
        )]
    }

    nonisolated private static func resolveCost(
        ticks: Int64?,
        model: String,
        input: Int,
        output: Int,
        cacheRead: Int,
        at date: Date
    ) -> Decimal? {
        if let ticks, ticks > 0 {
            return Decimal(ticks) / ticksPerUSD
        }
        return Pricing.cost(
            app: .grok,
            model: model,
            speed: .standard,
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheCreation: 0,
            at: date
        )
    }

    // MARK: - Session meta

    private struct SessionMeta {
        var sessionID: String
        var cwd: String?
        var title: String?
    }

    /// `.../<encoded-cwd>/<session-id>/updates.jsonl` 或 `.../subagents/<id>/updates.jsonl`
    nonisolated private static func sessionMeta(for updatesURL: URL) -> SessionMeta {
        let sessionDir = updatesURL.deletingLastPathComponent()
        var sessionID = sessionDir.lastPathComponent
        var cwdDir = sessionDir.deletingLastPathComponent()

        if sessionDir.lastPathComponent != "subagents",
           sessionDir.deletingLastPathComponent().lastPathComponent == "subagents" {
            // .../<cwd>/<parent>/subagents/<id>/updates.jsonl
            let parentSession = sessionDir.deletingLastPathComponent().deletingLastPathComponent()
            sessionID = parentSession.lastPathComponent
            cwdDir = parentSession.deletingLastPathComponent()
        } else if sessionDir.lastPathComponent == "subagents" {
            sessionID = cwdDir.lastPathComponent
            cwdDir = cwdDir.deletingLastPathComponent()
        }

        let cwdEncoded = cwdDir.lastPathComponent
        let cwd = cwdEncoded.removingPercentEncoding ?? cwdEncoded

        var title: String?
        let summaryURL = sessionDir.appendingPathComponent("summary.json")
        // subagent 用父会话 summary；若当前目录无 summary 再试父
        let summaryCandidates = [
            summaryURL,
            sessionDir.deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("summary.json")
        ]
        for url in summaryCandidates {
            if let data = try? Data(contentsOf: url),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                title = nonEmpty(root["generated_title"] as? String)
                    ?? nonEmpty(root["session_summary"] as? String)
                if title != nil { break }
            }
        }

        return SessionMeta(sessionID: sessionID, cwd: cwd, title: title)
    }

    nonisolated private static func seed(
        sessionID: String,
        path: String,
        title: String?,
        cwd: String?
    ) -> ConversationSeed {
        let project: ConversationProject
        if let cwd, !cwd.isEmpty {
            let name = URL(fileURLWithPath: cwd).lastPathComponent
            project = ConversationProject(
                key: "cwd:\(cwd)",
                name: name.isEmpty ? cwd : name,
                path: cwd,
                status: .available,
                source: .cwd
            )
        } else {
            project = .unassigned
        }
        return ConversationSeed(
            key: "grok:\(sessionID)",
            id: sessionID,
            app: .grok,
            title: title,
            project: project,
            gitBranch: nil,
            sourcePath: path,
            includesSubtasks: path.contains("/subagents/"),
            cacheCreationAvailable: false
        )
    }

    // MARK: - Helpers

    nonisolated private static func parseTimestamp(_ any: Any?) -> Date? {
        if let n = any as? Double {
            // Grok updates 用秒级 epoch（约 1.78e9）；兼容毫秒
            if n > 1e12 { return Date(timeIntervalSince1970: n / 1000) }
            return Date(timeIntervalSince1970: n)
        }
        if let n = any as? Int {
            let d = Double(n)
            if d > 1e12 { return Date(timeIntervalSince1970: d / 1000) }
            return Date(timeIntervalSince1970: d)
        }
        if let s = any as? String {
            return JSONLTimestamp.parse(s)
        }
        return nil
    }

    nonisolated private static func int(_ any: Any?) -> Int {
        if let i = any as? Int { return max(0, i) }
        if let d = any as? Double { return max(0, Int(d)) }
        if let n = any as? NSNumber { return max(0, n.intValue) }
        if let s = any as? String, let i = Int(s) { return max(0, i) }
        return 0
    }

    nonisolated private static func int64(_ any: Any?) -> Int64? {
        if let i = any as? Int64 { return i }
        if let i = any as? Int { return Int64(i) }
        if let d = any as? Double { return Int64(d) }
        if let n = any as? NSNumber { return n.int64Value }
        if let s = any as? String, let i = Int64(s) { return i }
        return nil
    }

    nonisolated private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
