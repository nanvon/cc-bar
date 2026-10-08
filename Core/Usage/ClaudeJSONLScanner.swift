import Foundation

/// 扫 `~/.claude/projects/**/*.jsonl`，把 assistant 行解析成 UsageEntry。
/// 增量逻辑：file mtime + byte offset；同一条 message.id 跨调用只计一次（持久化到 ScanFileState.seenMessageIds）。
enum ClaudeJSONLScanner {
    struct Result: Sendable {
        var entries: [UsageEntry]
        var conversationSeeds: [ConversationSeed]
        var newState: [String: ScanFileState]
        var newSeenIds: [String]
        var filesScanned: Int
        var linesParsed: Int
        var failedFileCount: Int
        /// 本轮计入的消息 ID 摘要，按对话 key 分组（见 `UsageMessageLedger`）。
        var ledger: [String: [UInt64]] = [:]
    }

    nonisolated static func defaultRoot() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    nonisolated static func scan(
        previous: [String: ScanFileState],
        seenMessageIds: [String],
        onProgress: ScanProgressCallback? = nil
    ) -> Result {
        return scan(
            previous: previous,
            seenMessageIds: seenMessageIds,
            root: defaultRoot(),
            conversationIndex: ConversationTitleIndex.claudeIndex(),
            onProgress: onProgress
        )
    }

    /// 可注入日志根目录与标题索引，供脱敏 JSONL fixture 测试真实 byte-offset 扫描链路。
    /// - Parameter knownIDs: 消息账本里已计入的 message.id 摘要，与 `seenMessageIds` 一起去重。
    /// - Parameter minimumMtime: 非 nil 时只扫修改时间不早于该时刻的文件（周期受限重建用）。
    /// - Parameter onProgress: 非 nil 时按约每 50 个文件回报一次扫描进度。
    nonisolated static func scan(
        previous: [String: ScanFileState],
        seenMessageIds: [String],
        knownIDs: Set<UInt64> = [],
        root: URL,
        conversationIndex: ConversationTitleIndex.ClaudeIndex,
        minimumMtime: Date? = nil,
        onProgress: ScanProgressCallback? = nil
    ) -> Result {
        let enumeration = JSONLDirectoryEnumerator.enumerate(at: root, minimumMtime: minimumMtime)
        // 续接 / 分叉对话会把原对话的消息（同一 message.id）复制进新文件。全局去重只计第一次
        // 读到的那条，所以按创建时间读文件，让消息归给原对话；增量扫描先读到原对话也是这个结果，
        // 两条路径的对话归属才一致。
        let files = enumeration.files.sorted {
            $0.creationTime == $1.creationTime ? $0.path < $1.path : $0.creationTime < $1.creationTime
        }

        var newState: [String: ScanFileState] = previous
        var entries: [UsageEntry] = []
        var linesParsed = 0
        var failedFileCount = enumeration.accessFailed ? 1 : 0
        var seeds: [String: ConversationSeed] = [:]
        var projectCandidates: [String: [ProjectCandidate]] = [:]
        // 跨文件全局去重：同一 message.id 在 sidechain / subagent 文件中会反复出现。
        var seen = SeenIDSet(seenMessageIds, known: knownIDs)
        var ledger: [String: [UInt64]] = [:]

        let totalFiles = files.count
        for (index, file) in files.enumerated() {
            if index % 50 == 0 || index == totalFiles - 1 {
                onProgress?(ScanProgress(
                    app: .claude,
                    filesCompleted: index + 1,
                    filesTotal: totalFiles,
                    linesParsed: linesParsed
                ))
            }
            let url = file.url
            let path = file.path
            let projectContainer = projectContainerName(root: root, file: url)
            let mtime = file.modificationTime
            let size = file.size

            var state = previous[path] ?? ScanFileState(mtime: 0, offset: 0)
            // mtime 没变 & size 没变 → 跳过
            if state.mtime == mtime, state.offset == size {
                newState[path] = state
                if let id = state.conversationID {
                    let key = "claude:\(id)"
                    let candidate = ProjectCandidate(
                        path: state.conversationCwd ?? "",
                        isSidechain: state.conversationIsSidechain ?? path.contains("/subagents/"),
                        container: projectContainer
                    )
                    if !projectCandidates[key, default: []].contains(candidate) {
                        projectCandidates[key, default: []].append(candidate)
                    }
                    let discoveredSeed = ConversationSeed(
                        key: key,
                        id: id,
                        app: .claude,
                        title: conversationIndex.titles[id] ?? state.fallbackTitle,
                        project: .unassigned,
                        gitBranch: state.conversationGitBranch,
                        sourcePath: path,
                        includesSubtasks: state.conversationIsSidechain ?? path.contains("/subagents/"),
                        cacheCreationAvailable: true
                    )
                    if var existing = seeds[key] {
                        existing.includesSubtasks = existing.includesSubtasks || discoveredSeed.includesSubtasks
                        if existing.title == nil { existing.title = discoveredSeed.title }
                        if existing.sourcePath.contains("/subagents/") && !discoveredSeed.sourcePath.contains("/subagents/") {
                            existing.sourcePath = discoveredSeed.sourcePath
                        }
                        seeds[key] = existing
                    } else {
                        seeds[key] = discoveredSeed
                    }
                }
                continue
            }
            // 文件被截断：offset 回到 0 重扫（此时仍由全局 seen 兜底防重复计费）
            if state.offset > size {
                state.offset = 0
            }

            // 本批次内按 id 收集 candidate，最后挑 stop_reason != nil 的；最终再与全局 seen 比对。
            var candidates: [String: ParsedAssistant] = [:]
            var fallbackTitles: [String: String] = [:]
            var fileConversationID = state.conversationID
            var fileCwd = state.conversationCwd ?? ""
            var fileGitBranch = state.conversationGitBranch
            var fileIsSidechain = state.conversationIsSidechain
            var fileFallbackTitle = state.fallbackTitle
            if let fileConversationID, let fileFallbackTitle {
                fallbackTitles[fileConversationID] = fileFallbackTitle
            }
            // 按批流式解析：单文件不再把整份内容和全部行同时读进内存。
            let outcome = JSONLLineReader.streamLines(url: url, fromOffset: state.offset) { batch in
                for line in batch {
                    linesParsed += 1
                    if let title = parseUserTitle(line) {
                        fallbackTitles[title.sessionID] = fallbackTitles[title.sessionID] ?? title.title
                        if fileFallbackTitle == nil { fileFallbackTitle = title.title }
                    }
                    guard let parsed = parseAssistantLine(line) else { continue }
                    fileConversationID = parsed.sessionID
                    if fileCwd.isEmpty || (fileIsSidechain == true && !parsed.isSidechain) {
                        fileCwd = parsed.cwd
                    }
                    if fileGitBranch == nil { fileGitBranch = parsed.gitBranch }
                    fileIsSidechain = (fileIsSidechain ?? true) && parsed.isSidechain
                    let conversationKey = "claude:\(parsed.sessionID)"
                    let candidate = ProjectCandidate(
                        path: parsed.cwd,
                        isSidechain: parsed.isSidechain,
                        container: projectContainer
                    )
                    if !projectCandidates[conversationKey, default: []].contains(candidate) {
                        projectCandidates[conversationKey, default: []].append(candidate)
                    }
                    let discoveredSeed = ConversationSeed(
                        key: conversationKey,
                        id: parsed.sessionID,
                        app: .claude,
                        title: conversationIndex.titles[parsed.sessionID] ?? fallbackTitles[parsed.sessionID],
                        project: .unassigned,
                        gitBranch: parsed.gitBranch,
                        sourcePath: path,
                        includesSubtasks: parsed.isSidechain,
                        cacheCreationAvailable: true
                    )
                    if var existing = seeds[conversationKey] {
                        existing.includesSubtasks = existing.includesSubtasks || discoveredSeed.includesSubtasks
                        if existing.title == nil { existing.title = discoveredSeed.title }
                        if existing.sourcePath.contains("/subagents/") && !discoveredSeed.sourcePath.contains("/subagents/") {
                            existing.sourcePath = discoveredSeed.sourcePath
                        }
                        seeds[conversationKey] = existing
                    } else {
                        seeds[conversationKey] = discoveredSeed
                    }
                    if seen.contains(parsed.messageId) { continue }
                    mergeCandidate(parsed, into: &candidates)
                }
            }
            // 打开 / 读取失败时丢弃本文件本轮解析出的候选，watermark 保持原值，下轮重来。
            let newOffset: UInt64
            switch outcome {
            case let .success(offset):
                newOffset = offset
            case .missing:
                // 枚举后被归档或清理是正常并发变化；本轮保留旧 watermark 且不弹告警，
                // 下轮枚举不到原路径时再由 alive 清理。
                newState[path] = state
                continue
            case .failed:
                newState[path] = state
                failedFileCount += 1
                continue
            }

            for (id, p) in candidates {
                // 流式中间行可能暂时没有 speed / stop_reason。此时既不能入账，也不能把
                // message.id 放进全局 seen；等待后续完整行追加后再由下一次增量扫描接收。
                guard isComplete(p) else { continue }
                seen.insert(id)
                ledger["claude:\(p.sessionID)", default: []].append(SeenIDSet.digest(id))
                let day = UsageDay.startOfDay(for: p.timestamp)
                let cost = Pricing.costBreakdown(
                    app: .claude,
                    model: p.model,
                    speed: p.speed,
                    input: p.inputTokens,
                    output: p.outputTokens,
                    cacheRead: p.cacheReadTokens,
                    cacheCreation: p.cacheCreation5mTokens,
                    cacheCreation1h: p.cacheCreation1hTokens,
                    at: p.timestamp
                )
                entries.append(UsageEntry(
                    app: .claude,
                    conversationKey: "claude:\(p.sessionID)",
                    model: Pricing.normalize(model: p.model),
                    speed: p.speed,
                    day: day,
                    timestamp: p.timestamp,
                    inputTokens: p.inputTokens,
                    outputTokens: p.outputTokens,
                    cacheReadTokens: p.cacheReadTokens,
                    cacheCreationTokens: p.cacheCreationTokens,
                    costUSD: cost?.total,
                    costBreakdown: cost
                ))
                // advisor 与主调用同属一条 message.id，随主调用只入账一次；不算作独立请求。
                for advisor in p.advisorUsages {
                    let advisorCost = Pricing.costBreakdown(
                        app: .claude,
                        model: advisor.model,
                        speed: .standard,
                        input: advisor.inputTokens,
                        output: advisor.outputTokens,
                        cacheRead: advisor.cacheReadTokens,
                        cacheCreation: advisor.cacheCreation.fiveMinuteTokens,
                        cacheCreation1h: advisor.cacheCreation.oneHourTokens,
                        at: p.timestamp
                    )
                    entries.append(UsageEntry(
                        app: .claude,
                        conversationKey: "claude:\(p.sessionID)",
                        model: Pricing.normalize(model: advisor.model),
                        speed: .standard,
                        day: day,
                        timestamp: p.timestamp,
                        inputTokens: advisor.inputTokens,
                        outputTokens: advisor.outputTokens,
                        cacheReadTokens: advisor.cacheReadTokens,
                        cacheCreationTokens: advisor.cacheCreation.totalTokens,
                        requestCount: 0,
                        costUSD: advisorCost?.total,
                        costBreakdown: advisorCost
                    ))
                }
                let key = "claude:\(p.sessionID)"
                let seed = ConversationSeed(
                    key: key,
                    id: p.sessionID,
                    app: .claude,
                    title: conversationIndex.titles[p.sessionID] ?? fallbackTitles[p.sessionID],
                    project: .unassigned,
                    gitBranch: p.gitBranch,
                    sourcePath: path,
                    includesSubtasks: p.isSidechain,
                    cacheCreationAvailable: true
                )
                if var existing = seeds[key] {
                    existing.includesSubtasks = existing.includesSubtasks || seed.includesSubtasks
                    if existing.title == nil { existing.title = seed.title }
                    seeds[key] = existing
                } else {
                    seeds[key] = seed
                }
            }

            state.mtime = mtime
            state.offset = newOffset
            state.conversationID = fileConversationID
            state.conversationCwd = fileCwd
            state.conversationGitBranch = fileGitBranch
            state.conversationIsSidechain = fileIsSidechain
            state.fallbackTitle = fileFallbackTitle
            newState[path] = state
        }

        // 删除已不存在的文件 watermark
        let alive = Set(files.map(\.path))
        for key in newState.keys where !alive.contains(key) {
            newState.removeValue(forKey: key)
        }

        // 控制全局 seen 集合大小：按插入顺序保留最近 N 条（见 SeenIDSet）。
        let cappedSeen = seen.capped(to: SeenIDSet.defaultLimit)

        var projectResolver = ConversationProjectResolver()
        for key in Array(seeds.keys) {
            guard var seed = seeds[key] else { continue }
            let candidates = (projectCandidates[key] ?? []).map {
                (path: $0.path, isSidechain: $0.isSidechain, container: $0.container)
            }
            seed.project = projectResolver.resolveClaude(
                historyPath: conversationIndex.projects[seed.id],
                candidates: candidates
            )
            seeds[key] = seed
        }

        return Result(
            entries: entries,
            conversationSeeds: Array(seeds.values),
            newState: newState,
            newSeenIds: cappedSeen,
            filesScanned: files.count,
            linesParsed: linesParsed,
            failedFileCount: failedFileCount,
            ledger: ledger
        )
    }

    /// 保持为 internal，供脱敏 JSONL fixture 单测验证日志字段兼容性。
    struct ParsedAssistant {
        var messageId: String
        var sessionID: String
        var cwd: String
        var gitBranch: String?
        var isSidechain: Bool
        var model: String
        var speed: UsageSpeed
        var timestamp: Date
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int
        var cacheCreationTokens: Int
        var cacheCreation5mTokens: Int
        var cacheCreation1hTokens: Int
        var stopReason: String?
        /// advisor 在服务端另起的推理；顶层 usage 不含这部分，只出现在 `usage.iterations`。
        var advisorUsages: [AdvisorUsage] = []
    }

    struct AdvisorUsage: Sendable, Equatable {
        var model: String
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int
        var cacheCreation: CacheCreationUsage
    }

    struct CacheCreationUsage: Sendable, Equatable {
        var totalTokens: Int
        var fiveMinuteTokens: Int
        var oneHourTokens: Int
    }

    private struct ProjectCandidate: Equatable {
        var path: String
        var isSidechain: Bool
        var container: String
    }

    nonisolated static func parseAssistantLine(_ line: String) -> ParsedAssistant? {
        guard let data = line.data(using: .utf8) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard (root["type"] as? String) == "assistant" else { return nil }
        guard let sessionID = root["sessionId"] as? String else { return nil }
        guard let message = root["message"] as? [String: Any] else { return nil }
        guard let messageId = message["id"] as? String else { return nil }
        guard let usage = message["usage"] as? [String: Any] else { return nil }
        let outputTokens = (usage["output_tokens"] as? Int) ?? 0
        if outputTokens == 0 { return nil }
        let inputTokens = (usage["input_tokens"] as? Int) ?? 0
        let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
        let cacheCreation = cacheCreationUsage(in: usage)
        let model = (message["model"] as? String) ?? "unknown"
        let speed: UsageSpeed
        switch usage["speed"] as? String {
        case "fast": speed = .fast
        case "standard": speed = .standard
        default: speed = .unknown
        }
        let stopReason = message["stop_reason"] as? String

        let ts: Date
        if let s = root["timestamp"] as? String, let parsed = JSONLTimestamp.parse(s) {
            ts = parsed
        } else {
            ts = Date()
        }

        return ParsedAssistant(
            messageId: messageId,
            sessionID: sessionID,
            cwd: (root["cwd"] as? String) ?? "",
            gitBranch: root["gitBranch"] as? String,
            isSidechain: (root["isSidechain"] as? Bool) ?? false,
            model: model,
            speed: speed,
            timestamp: ts,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheCreation.totalTokens,
            cacheCreation5mTokens: cacheCreation.fiveMinuteTokens,
            cacheCreation1hTokens: cacheCreation.oneHourTokens,
            stopReason: stopReason,
            advisorUsages: advisorUsages(in: usage)
        )
    }

    /// 顶层 usage 等于各 `type: "message"` 迭代之和，只需额外计入 `advisor_message` 项。
    nonisolated static func advisorUsages(in usage: [String: Any]) -> [AdvisorUsage] {
        guard let iterations = usage["iterations"] as? [[String: Any]] else { return [] }
        return iterations.compactMap { item in
            guard (item["type"] as? String) == "advisor_message" else { return nil }
            let input = (item["input_tokens"] as? Int) ?? 0
            let output = (item["output_tokens"] as? Int) ?? 0
            if input == 0 && output == 0 { return nil }
            return AdvisorUsage(
                model: (item["model"] as? String) ?? "unknown",
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: (item["cache_read_input_tokens"] as? Int) ?? 0,
                cacheCreation: cacheCreationUsage(in: item)
            )
        }
    }

    /// `cache_creation_input_tokens` 是 UI/聚合使用的总口径；TTL 明细只影响计价。
    /// 明细与合计不一致时保留合计，并把无法分类的剩余部分按价格更低的 5m 处理。
    nonisolated static func cacheCreationUsage(in usage: [String: Any]) -> CacheCreationUsage {
        let details = usage["cache_creation"] as? [String: Any]
        let detailed5m = max(0, (details?["ephemeral_5m_input_tokens"] as? Int) ?? 0)
        let detailed1h = max(0, (details?["ephemeral_1h_input_tokens"] as? Int) ?? 0)

        if let aggregate = usage["cache_creation_input_tokens"] as? Int {
            let total = max(0, aggregate)
            guard details != nil else {
                return CacheCreationUsage(totalTokens: total, fiveMinuteTokens: total, oneHourTokens: 0)
            }
            let oneHour = min(detailed1h, total)
            return CacheCreationUsage(
                totalTokens: total,
                fiveMinuteTokens: total - oneHour,
                oneHourTokens: oneHour
            )
        }

        return CacheCreationUsage(
            totalTokens: detailed5m + detailed1h,
            fiveMinuteTokens: detailed5m,
            oneHourTokens: detailed1h
        )
    }

    /// 同一 message.id 的流式行只保留最终完成态；供扫描器与脱敏 fixture 单测共用。
    nonisolated static func mergeCandidate(
        _ parsed: ParsedAssistant,
        into candidates: inout [String: ParsedAssistant]
    ) {
        if let existing = candidates[parsed.messageId] {
            let prefer = (parsed.stopReason != nil && existing.stopReason == nil)
                || (parsed.outputTokens > existing.outputTokens && existing.stopReason == nil)
            if prefer { candidates[parsed.messageId] = parsed }
        } else {
            candidates[parsed.messageId] = parsed
        }
    }

    /// Claude 只有带 stop_reason 的最终 assistant 行才代表一次完成的模型调用。
    nonisolated static func isComplete(_ parsed: ParsedAssistant) -> Bool {
        parsed.stopReason != nil
    }

    private nonisolated static func parseUserTitle(_ line: String) -> (sessionID: String, title: String)? {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["type"] as? String) == "user",
              (root["isSidechain"] as? Bool) != true,
              let sessionID = root["sessionId"] as? String,
              let message = root["message"] as? [String: Any],
              let title = ConversationTitleIndex.userMessage(from: message["content"]) else { return nil }
        return (sessionID, title)
    }

    private nonisolated static func projectContainerName(root: URL, file: URL) -> String {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard file.path.hasPrefix(prefix) else { return "" }
        return file.path.dropFirst(prefix.count).split(separator: "/").first.map(String.init) ?? ""
    }
}
