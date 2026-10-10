import Foundation

/// 扫 `~/.pi/agent/sessions/**/*.jsonl`（pi coding agent 的会话日志）。
///
/// pi 的会话文件是 append-only JSONL，assistant 消息自带 `usage`（token 明细）
/// 与可选的 `cost`（USD 费用）字段。有效日志价格优先；价格缺失或为 0 时复用统一
/// Pricing 的在线目录 / 本地价格表补算。
///
/// 解析规则：
///   - `type=session`：取 `cwd` / `id` 作为会话元数据（对话统计用）。
///   - `type=message` 且 `message.role == "assistant"`：读 `message.usage` / `message.cost`、
///     `message.provider` / `message.model`，计入用量与费用。
///   - `type=message` 且 `message.role == "user"`：首条消息文本作为会话标题兜底。
///   - `type=compaction` / `type=branch_summary`：带 `usage` 时计入（对齐 pi `/session`
///     的 token/cost 合计口径）。
///   - 其余类型（toolResult 嵌套 usage、label、model_change 等）不参与用量。
///
/// 增量逻辑：file mtime + byte offset；跨文件按 (entryID + entry ISO timestamp) 全局去重，
/// 覆盖 `/fork` `/clone` 把旧行复制进新文件导致的重复计费。
enum PiJSONLScanner {
    struct Result: Sendable {
        var entries: [UsageEntry]
        var conversationSeeds: [ConversationSeed]
        var newState: [String: ScanFileState]
        var newSeenIds: [String]
        var filesScanned: Int
        var linesParsed: Int
        /// 本轮计入的去重键摘要，按对话 key 分组（见 `UsageMessageLedger`）。
        var ledger: [String: [UInt64]] = [:]
    }

    nonisolated static func scan(
        previous: [String: ScanFileState],
        seenEntryIds: [String],
        onProgress: ScanProgressCallback? = nil
    ) -> Result {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent(".pi/agent/sessions", isDirectory: true)
        return scan(
            previous: previous,
            seenEntryIds: seenEntryIds,
            root: root,
            onProgress: onProgress
        )
    }

    /// 可注入日志根目录，供脱敏 JSONL fixture 测试真实 byte-offset 扫描链路。
    /// - Parameter knownIDs: 消息账本里已计入的去重键摘要，与 `seenEntryIds` 一起去重。
    /// - Parameter minimumMtime: 非 nil 时只扫修改时间不早于该时刻的文件（周期受限重建用）。
    /// - Parameter onProgress: 非 nil 时按约每 50 个文件回报一次扫描进度。
    nonisolated static func scan(
        previous: [String: ScanFileState],
        seenEntryIds: [String],
        knownIDs: Set<UInt64> = [],
        root: URL,
        minimumMtime: Date? = nil,
        onProgress: ScanProgressCallback? = nil
    ) -> Result {
        let files = JSONLDirectoryEnumerator.files(at: root, minimumMtime: minimumMtime)

        var newState: [String: ScanFileState] = previous
        var entries: [UsageEntry] = []
        var linesParsed = 0
        var seeds: [String: ConversationSeed] = [:]
        var seen = SeenIDSet(seenEntryIds, known: knownIDs)
        var ledger: [String: [UInt64]] = [:]
        var projectResolver = ConversationProjectResolver()

        let totalFiles = files.count
        for (index, file) in files.enumerated() {
            if index % 50 == 0 || index == totalFiles - 1 {
                onProgress?(ScanProgress(
                    app: .pi,
                    filesCompleted: index + 1,
                    filesTotal: totalFiles,
                    linesParsed: linesParsed
                ))
            }
            let url = file.url
            let path = file.path
            let mtime = file.modificationTime
            let size = file.size

            var state = previous[path] ?? ScanFileState(mtime: 0, offset: 0)
            // mtime 没变 & size 没变 → 跳过，用 state 里的会话元数据补种子。
            if state.mtime == mtime, state.offset == size {
                newState[path] = state
                if let id = state.conversationID {
                    seeds["pi:\(id)"] = seed(id: id, state: state, path: path, resolver: &projectResolver)
                }
                continue
            }
            // 文件被截断（append-only 下不应发生，防御处理）：offset 回 0 重扫，全局 seen 兜底防重复计费。
            if state.offset > size {
                state.offset = 0
            }

            var sessionID = state.conversationID
            var sessionCwd = state.conversationCwd ?? ""
            var fallbackTitle = state.fallbackTitle
            // 最近一条 assistant 消息的 provider/model；compaction / branch_summary 无模型字段时沿用。
            var currentModel = state.lastModel

            // 本文件解析出的条目和去重键先局部收集：中途读失败时整份丢弃，
            // 与 Claude / Codex 一致——不推进 watermark 就不能留下半份结果。
            var fileEntries: [UsageEntry] = []
            var fileSeenKeys: [String] = []
            var fileLedger: [(conversationKey: String, id: UInt64)] = []
            // 按批流式解析：单文件不再把整份内容和全部行同时读进内存。
            let outcome = JSONLLineReader.streamLines(url: url, fromOffset: state.offset) { batch in
                for line in batch {
                    linesParsed += 1
                    guard let data = line.data(using: .utf8),
                          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    let type = root["type"] as? String

                    if type == "session" {
                        sessionID = (root["id"] as? String) ?? sessionID
                        sessionCwd = (root["cwd"] as? String) ?? sessionCwd
                        continue
                    }

                    guard type == "message" || type == "compaction" || type == "branch_summary" else { continue }
                    // 去重键依赖 entry 必填的 id + ISO timestamp；缺失的防御性跳过（pi 总会写）。
                    guard let entryID = root["id"] as? String,
                          let entryTimestamp = root["timestamp"] as? String else { continue }

                    if type == "message" {
                        guard let message = root["message"] as? [String: Any] else { continue }
                        let role = message["role"] as? String
                        if role == "user" {
                            if fallbackTitle == nil, let title = ConversationTitleIndex.userMessage(from: message["content"]) {
                                fallbackTitle = title
                            }
                            continue
                        }
                        guard role == "assistant" else { continue }
                        guard let usage = message["usage"] as? [String: Any] else { continue }

                        let dedupeKey = "\(entryID)@\(entryTimestamp)"
                        if seen.contains(dedupeKey) { continue }
                        seen.insert(dedupeKey)
                        fileSeenKeys.append(dedupeKey)

                        let provider = message["provider"] as? String
                        let model = message["model"] as? String ?? "unknown"
                        currentModel = modelLabel(provider: provider, model: model)
                        let ts = messageTimestamp(message: message, fallback: entryTimestamp)
                        guard let resolvedID = sessionID ?? fileNameUUID(from: url) else { continue }

                        guard let parsed = parseUsage(usage) else { continue }
                        let hasPositiveLoggedCost = (parsed.cost?.total ?? 0) > 0
                        if parsed.totalTokens <= 0 && !hasPositiveLoggedCost { continue }
                        fileEntries.append(makeEntry(
                            app: .pi,
                            conversationID: resolvedID,
                            model: currentModel ?? "unknown/unknown",
                            speed: .standard,
                            timestamp: ts,
                            usage: parsed
                        ))
                        fileLedger.append(("pi:\(resolvedID)", SeenIDSet.digest(dedupeKey)))
                    } else {
                        // compaction / branch_summary：仅当带 usage 字段时计入（生成摘要的 LLM 开销）。
                        guard let usage = root["usage"] as? [String: Any] else { continue }
                        let dedupeKey = "\(entryID)@\(entryTimestamp)"
                        if seen.contains(dedupeKey) { continue }
                        seen.insert(dedupeKey)
                        fileSeenKeys.append(dedupeKey)

                        let ts = JSONLTimestamp.parse(entryTimestamp) ?? Date()
                        guard let resolvedID = sessionID ?? fileNameUUID(from: url) else { continue }
                        guard let parsed = parseUsage(usage) else { continue }
                        let hasPositiveLoggedCost = (parsed.cost?.total ?? 0) > 0
                        if parsed.totalTokens <= 0 && !hasPositiveLoggedCost { continue }
                        fileEntries.append(makeEntry(
                            app: .pi,
                            conversationID: resolvedID,
                            model: currentModel ?? "unknown/unknown",
                            speed: .standard,
                            timestamp: ts,
                            usage: parsed
                        ))
                        fileLedger.append(("pi:\(resolvedID)", SeenIDSet.digest(dedupeKey)))
                    }
                }
            }
            // 打开 / 读取失败时丢弃本文件本轮结果、保留原 watermark，下轮重来（不计失败数）。
            guard case let .success(newOffset) = outcome else {
                seen.remove(contentsOf: fileSeenKeys)
                newState[path] = state
                continue
            }
            entries.append(contentsOf: fileEntries)
            for item in fileLedger {
                ledger[item.conversationKey, default: []].append(item.id)
            }

            state.mtime = mtime
            state.offset = newOffset
            state.conversationID = sessionID
            state.conversationCwd = sessionCwd
            state.fallbackTitle = fallbackTitle
            state.lastModel = currentModel
            newState[path] = state
            if let id = sessionID {
                seeds["pi:\(id)"] = seed(id: id, state: state, path: path, resolver: &projectResolver)
            }
        }

        // 清理已删除文件的残留 watermark。
        let alive = Set(files.map(\.path))
        for key in newState.keys where !alive.contains(key) {
            newState.removeValue(forKey: key)
        }

        // 控制全局 seen 集合大小：按插入顺序保留最近 N 条（与 Claude scanner 一致）。
        let cappedSeen = seen.capped(to: SeenIDSet.defaultLimit)

        return Result(
            entries: entries,
            conversationSeeds: Array(seeds.values),
            newState: newState,
            newSeenIds: cappedSeen,
            filesScanned: files.count,
            linesParsed: linesParsed,
            ledger: ledger
        )
    }

    /// 用文件内最近一条 assistant 的模型给 compaction 摘要打标签；格式 `provider/model`。
    private nonisolated static func modelLabel(provider: String?, model: String) -> String {
        if let provider, !provider.isEmpty {
            return "\(provider)/\(model)"
        }
        return model
    }

    private nonisolated static func seed(
        id: String,
        state: ScanFileState,
        path: String,
        resolver: inout ConversationProjectResolver
    ) -> ConversationSeed {
        ConversationSeed(
            key: "pi:\(id)",
            id: id,
            app: .pi,
            title: state.fallbackTitle,
            project: resolver.resolve(rawPath: state.conversationCwd ?? "", source: .cwd),
            gitBranch: nil,
            sourcePath: path,
            includesSubtasks: false,
            cacheCreationAvailable: true
        )
    }

    /// assistant 消息时间戳优先用 `message.timestamp`（Unix ms），缺失时退回 entry ISO 时间。
    private nonisolated static func messageTimestamp(message: [String: Any], fallback: String) -> Date {
        if let ms = (message["timestamp"] as? NSNumber)?.doubleValue, ms > 0 {
            return Date(timeIntervalSince1970: ms / 1000)
        }
        return JSONLTimestamp.parse(fallback) ?? Date()
    }

    /// 文件名 `2026-08-03T03-27-31-685Z_019fc5a9-....jsonl` 里的 UUID 段。
    private nonisolated static func fileNameUUID(from url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#
        guard let range = name.range(of: pattern, options: .regularExpression) else { return nil }
        return String(name[range])
    }

    /// pi 的 `usage` 结构：input/output/cacheRead/cacheWrite/totalTokens + cost{...}。
    private nonisolated static func parseUsage(_ usage: [String: Any]) -> ParsedUsage? {
        let input = intValue(usage["input"])
        let output = intValue(usage["output"])
        let cacheRead = intValue(usage["cacheRead"])
        let cacheWrite = intValue(usage["cacheWrite"])
        let totalTokens = max(
            intValue(usage["totalTokens"]),
            input + output + cacheRead + cacheWrite
        )
        let cost = (usage["cost"] as? [String: Any]).flatMap { parseCost($0) }
        return ParsedUsage(
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            totalTokens: totalTokens,
            cost: cost
        )
    }

    private nonisolated static func parseCost(_ cost: [String: Any]) -> ParsedCost? {
        guard let total = decimalValue(cost["total"]) else { return nil }
        return ParsedCost(
            input: decimalValue(cost["input"]) ?? 0,
            output: decimalValue(cost["output"]) ?? 0,
            cacheRead: decimalValue(cost["cacheRead"]) ?? 0,
            cacheWrite: decimalValue(cost["cacheWrite"]) ?? 0,
            total: total
        )
    }

    private nonisolated static func intValue(_ value: Any?) -> Int {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) ?? 0 }
        return 0
    }

    /// 经 String 中转避免 Double → Decimal 的二进制浮点误差。
    private nonisolated static func decimalValue(_ value: Any?) -> Decimal? {
        if let n = value as? NSNumber {
            return Decimal(string: n.stringValue)
        }
        if let s = value as? String {
            return Decimal(string: s)
        }
        return nil
    }

    private nonisolated static func makeEntry(
        app: UsageApp,
        conversationID: String,
        model: String,
        speed: UsageSpeed,
        timestamp: Date,
        usage: ParsedUsage
    ) -> UsageEntry {
        let reportedBreakdown = usage.cost.map {
            CostBreakdown(
                input: $0.input,
                output: $0.output,
                cacheRead: $0.cacheRead,
                cacheCreation: $0.cacheWrite
            )
        }
        let breakdown = Pricing.resolveCostBreakdown(
            app: app,
            model: model,
            speed: speed,
            input: usage.input,
            output: usage.output,
            cacheRead: usage.cacheRead,
            cacheCreation: usage.cacheWrite,
            totalTokens: usage.totalTokens,
            reportedCost: usage.cost?.total,
            reportedBreakdown: reportedBreakdown,
            at: timestamp
        )
        return UsageEntry(
            app: app,
            conversationKey: "pi:\(conversationID)",
            model: model,
            speed: speed,
            day: UsageDay.startOfDay(for: timestamp),
            timestamp: timestamp,
            inputTokens: usage.input,
            outputTokens: usage.output,
            cacheReadTokens: usage.cacheRead,
            cacheCreationTokens: usage.cacheWrite,
            costUSD: breakdown?.total,
            costBreakdown: breakdown
        )
    }

    private nonisolated struct ParsedUsage: Sendable {
        var input: Int
        var output: Int
        var cacheRead: Int
        var cacheWrite: Int
        var totalTokens: Int
        var cost: ParsedCost?
    }

    private nonisolated struct ParsedCost: Sendable {
        var input: Decimal
        var output: Decimal
        var cacheRead: Decimal
        var cacheWrite: Decimal
        var total: Decimal
    }
}
