import Foundation

/// 扫 `~/.codex/sessions/**/*.jsonl` + `~/.codex/archived_sessions/**/*.jsonl`。
/// 关键事件：
///   - `type=turn_context`，`payload.model` 提供当前模型（保留渠道前缀，兼容日期后缀）。
///   - `type=event_msg/payload.type=thread_settings_applied`，嵌套 `service_tier` 提供当前 Fast 档位。
///   - `type=event_msg`，`payload.type=token_count`，`payload.info.last_token_usage` 是本次调用的真实 token；
///     使用 last_token_usage 直接累计；累计 total_token_usage 未变化的设置回显事件跳过。
/// Codex `input_tokens` 含 cache_read；GPT-5.6 若日志提供 `cache_write_tokens` 也需从普通输入扣掉。
///
/// fork 会话（`session_meta.payload.forked_from_id`）的 JSONL 会把父会话已有的整段历史
/// **逐字节重放**进新文件（只改写 timestamp），其中包含父会话全部 `token_count`；同一份历史
/// 因此出现在多个文件里。重放段没有任何事件级标记，也不能靠「`session_meta.id` 与文件自身
/// 不符」判定——fork 之后的新调用不会再写自己的 `session_meta`，同样挂在父 id 下。
/// 唯一可靠的判据是跨文件按 `(发出该记录的会话 id, 累计用量签名)` 去重：重放行与父文件里
/// 的原始行同键，fork 之后的新调用累计值更高、键不同，正常入账（做法同 Pi 的 `/fork` 去重）。
enum CodexJSONLScanner {
    /// 存储身份与定价键分开：保留整个渠道链，裸模型和末段仍沿用日期 / 大小写规则。
    nonisolated static func storageModel(_ model: String) -> String {
        guard let slash = model.lastIndex(of: "/") else { return Pricing.normalize(model: model) }
        let end = model.index(after: slash)
        return String(model[..<end]) + Pricing.normalize(model: String(model[end...]))
    }

    struct ThreadSettings: Sendable, Equatable {
        var model: String?
        var speed: UsageSpeed
    }

    struct Result: Sendable {
        var entries: [UsageEntry]
        var conversationSeeds: [ConversationSeed]
        var newState: [String: ScanFileState]
        var newSeenIds: [String]
        var filesScanned: Int
        var linesParsed: Int
        var failedFileCount: Int
        /// 仅 `historicalBoundary` 模式：根目录不可访问、文件读取失败或扫描中被移走的数量。
        /// 这类失败可重试，调用方不能把缺失的证据当成确定结果提交。
        var historicalTransientFailureCount = 0
    }

    /// 文件级并发解析的最大并发数。codex 日志文件独立（会话互不重叠），
    /// 全量重扫 / 强制重算是主要耗时场景，多核并行收益明显；受限为 4 避免 IO 争抢过激。
    nonisolated private static let maxConcurrentFiles = 4

    nonisolated static func scan(
        previous: [String: ScanFileState],
        seenTokenIds: [String],
        onProgress: ScanProgressCallback? = nil
    ) async -> Result {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [
            home.appendingPathComponent(".codex/sessions", isDirectory: true),
            home.appendingPathComponent(".codex/archived_sessions", isDirectory: true)
        ]
        return await scan(
            previous: previous,
            seenTokenIds: seenTokenIds,
            roots: roots,
            indexedTitles: ConversationTitleIndex.codexTitles(),
            onProgress: onProgress
        )
    }

    /// 可注入日志根目录与标题索引，供脱敏 JSONL fixture 测试真实 byte-offset 扫描链路。
    /// 文件间并行解析（`maxConcurrentFiles` 路），结果按会话 UUID 升序合并，
    /// 解析结果与串行实现完全一致。
    /// - Parameter seenTokenIds: 上一轮持久化的跨文件去重键；缺省为空表示本轮从零建集合
    ///   （全量重扫走这条，测试同理）。
    /// - Parameter minimumMtime: 非 nil 时只扫修改时间不早于该时刻的文件（周期受限重建用）。
    /// - Parameter historicalBoundary: 标识迁移用，从零重放到各文件已提交 offset；不定价，
    ///   截断 / 无效记录 / 末尾上下文不符的文件不产出证据；读取失败、根目录不可访问、
    ///   扫描中被移走的文件另计入 `historicalTransientFailureCount`。其返回进度不可用于增量续扫。
    /// - Parameter onProgress: 非 nil 时按批回报一次扫描进度。
    nonisolated static func scan(
        previous: [String: ScanFileState],
        seenTokenIds: [String] = [],
        roots: [URL],
        indexedTitles: [String: String],
        minimumMtime: Date? = nil,
        historicalBoundary: [String: ScanFileState]? = nil,
        onProgress: ScanProgressCallback? = nil
    ) async -> Result {
        var filesByID: [String: JSONLFileDescriptor] = [:]
        var failedRootCount = 0
        for root in roots {
            let enumeration = JSONLDirectoryEnumerator.enumerate(
                at: root,
                minimumMtime: minimumMtime
            )
            if enumeration.accessFailed { failedRootCount += 1 }
            for file in enumeration.files {
                let id = conversationID(from: file.url) ?? file.path
                if let historicalBoundary, (historicalBoundary[id]?.offset ?? 0) == 0 { continue }
                if let existing = filesByID[id] {
                    if file.modificationTime > existing.modificationTime {
                        filesByID[id] = file
                    }
                } else {
                    filesByID[id] = file
                }
            }
        }
        // 按会话 ID 升序：Codex 会话 ID 是 UUIDv7，前 48 位就是创建时刻的毫秒时间戳，
        // 字典序即会话创建序，父会话一定排在由它 fork 出的会话之前。跨文件去重只保留
        // 首次出现的那条，顺序不确定时会改成丢掉父文件里的原始记录、留下 fork 重放的
        // 副本——后者的 timestamp 被改写成 fork 时刻，用量会归错天。
        let files = filesByID.values.sorted { lhs, rhs in
            let l = conversationID(from: lhs.url) ?? lhs.path
            let r = conversationID(from: rhs.url) ?? rhs.path
            return l == r ? lhs.path < rhs.path : l < r
        }

        var newState: [String: ScanFileState] = previous
        var entries: [UsageEntry] = []
        var seeds: [String: ConversationSeed] = [:]
        var linesParsed = 0
        var failedFileCount = failedRootCount
        var historicalTransientFailureCount = historicalBoundary == nil ? 0 : failedRootCount
        // 跨文件去重：fork 会话把父会话的整段 token_count 历史重放进自己的 JSONL，
        // 同一条记录因此出现在多个文件里。键为 `发出该记录的会话 id#累计用量签名`。
        var seen = SeenIDSet(seenTokenIds)
        // 本批次内出现过 cache_write 的会话 key；避免每个文件收尾时对全部
        // 已累积 entries 做线性 contains（全量重扫时是平方级开销）。
        var cacheCreationKeys: Set<String> = []

        // 文件间并行解析：每批 maxConcurrentFiles 个，批内结果合并后再取下一批。
        // 合并严格按文件原始顺序进行：跨文件去重只保留首次出现的记录，顺序必须确定，
        // 否则 fork 重放行与父文件原始行谁被保留会随机漂移。cacheCreationKeys 同样在
        // 合并阶段收集——只有真正入账的记录才给会话补标。
        let totalFiles = files.count
        let maxConcurrent = Self.maxConcurrentFiles
        var offset = 0
        while offset < totalFiles {
            let end = min(offset + maxConcurrent, totalFiles)
            var batchResults: [(index: Int, result: CodexFileScanResult)] = []
            await withTaskGroup(of: (Int, CodexFileScanResult).self) { group in
                for index in offset..<end {
                    let file = files[index]
                    let stateKey = conversationID(from: file.url) ?? file.path
                    let state = previous[stateKey]
                    if state?.mtime == file.modificationTime, state?.offset == file.size {
                        batchResults.append((
                            index,
                            scanSingleFile(file: file, previous: previous, indexedTitles: indexedTitles,
                                           boundary: historicalBoundary?[stateKey])
                        ))
                    } else {
                        group.addTask {
                            (index, scanSingleFile(
                                file: file,
                                previous: previous,
                                indexedTitles: indexedTitles,
                                boundary: historicalBoundary?[stateKey]
                            ))
                        }
                    }
                }
                for await item in group {
                    batchResults.append(item)
                }
            }
            // 按文件原始顺序合并，保证 entries / seeds 顺序与串行实现一致
            batchResults.sort { $0.index < $1.index }
            for item in batchResults {
                let result = item.result
                if historicalBoundary != nil,
                   result.fileDisappeared || (result.readFailed && !result.evidenceRejected) {
                    historicalTransientFailureCount += 1
                }
                if result.fileDisappeared {
                    // sessions → archived_sessions 移动时会话 ID 不变；保留旧状态才能让
                    // 下轮从原 offset 续扫，不能删除后把整份归档从 0 重复计入。
                    newState[result.stateKey] = result.state
                    continue
                }
                newState[result.stateKey] = result.state
                linesParsed += result.linesParsed
                if result.readFailed { failedFileCount += 1 }
                // 去重放在合并阶段：单文件解析是并发的，不能共享 seen 集合；
                // batchResults 已按文件原始顺序排好，这里的插入顺序仍是确定的。
                for pending in result.entries {
                    if let key = pending.dedupeKey {
                        if seen.contains(key) { continue }
                        seen.insert(key)
                    }
                    entries.append(pending.entry)
                    if pending.hasCacheCreation {
                        cacheCreationKeys.insert(pending.entry.conversationKey)
                    }
                }
                if let seedKey = result.seedKey, let seed = result.seed {
                    seeds[seedKey] = seed
                }
            }
            offset = end
            if offset == totalFiles {
                onProgress?(ScanProgress(
                    app: .codex,
                    filesCompleted: totalFiles,
                    filesTotal: totalFiles,
                    linesParsed: linesParsed
                ))
            } else if onProgress != nil {
                onProgress?(ScanProgress(
                    app: .codex,
                    filesCompleted: offset,
                    filesTotal: totalFiles,
                    linesParsed: linesParsed
                ))
            }
        }

        // 批次内任意文件为该会话写过 cache_creation 的，统一补标（与串行全局集合语义一致）
        for key in seeds.keys where cacheCreationKeys.contains(key) {
            if var seed = seeds[key], !seed.cacheCreationAvailable {
                seed.cacheCreationAvailable = true
                seeds[key] = seed
            }
        }

        let alive = Set(files.map { conversationID(from: $0.url) ?? $0.path })
        for key in newState.keys where !alive.contains(key) {
            newState.removeValue(forKey: key)
        }

        return Result(
            entries: entries,
            conversationSeeds: Array(seeds.values),
            newState: newState,
            // 控制集合大小：按插入顺序保留最近 N 条（见 SeenIDSet）。
            newSeenIds: seen.capped(to: SeenIDSet.defaultLimit),
            filesScanned: files.count,
            linesParsed: linesParsed,
            failedFileCount: failedFileCount,
            historicalTransientFailureCount: historicalTransientFailureCount
        )
    }

    /// 单文件解析出的一条待入账记录。是否真正入账由合并阶段的跨文件去重决定，
    /// 因此 `hasCacheCreation` 也要跟着记录走——被去掉的重放行不该给会话打上
    /// 「有 cache_creation」的标记，那条信息由保留下来的原始记录提供。
    private nonisolated struct PendingCodexEntry: Sendable {
        var entry: UsageEntry
        /// `发出该记录的会话 id#累计用量签名`；签名缺失时为 nil（不参与去重）。
        var dedupeKey: String?
        var hasCacheCreation: Bool
    }

    /// 单个文件的解析结果，供并发批处理合并。
    private nonisolated struct CodexFileScanResult: Sendable {
        var stateKey: String
        var state: ScanFileState
        var entries: [PendingCodexEntry]
        var seedKey: String?
        var seed: ConversationSeed?
        var linesParsed: Int
        var readFailed: Bool
        var fileDisappeared: Bool = false
        /// 历史证据与已提交边界不符（内容层面的确定结果），区别于可重试的读取失败。
        var evidenceRejected: Bool = false
    }

    /// 解析单个 JSONL 文件（无共享可变状态，可并发执行）。
    /// seed 的 cacheCreationAvailable 一律留给调用方在合并后统一补标：
    /// 本文件是否写过 cache_creation，要等跨文件去重筛掉重放行之后才算数。
    private nonisolated static func scanSingleFile(
        file: JSONLFileDescriptor,
        previous: [String: ScanFileState],
        indexedTitles: [String: String],
        boundary: ScanFileState? = nil
    ) -> CodexFileScanResult {
        let url = file.url
        let path = file.path
        let filenameID = conversationID(from: url)
        let stateKey = filenameID ?? path
        let mtime = file.modificationTime
        let size = file.size

        var state = previous[stateKey] ?? ScanFileState(mtime: 0, offset: 0)
        // mtime 没变 & size 没变 → 跳过，用 state 元数据补种子。
        if boundary == nil, state.mtime == mtime, state.offset == size {
            if let id = state.conversationID ?? filenameID {
                // 旧版本扫描过的文件没有记录分支 / 父对话：只读一次首行的 session_meta 补齐，
                // 读到或确认没有后写回（空串表示已检查），之后不再读。
                if state.conversationGitBranch == nil || state.conversationParentSession == nil {
                    let meta = firstLineSessionMeta(url: url)
                    if state.conversationGitBranch == nil {
                        state.conversationGitBranch = meta.flatMap(gitBranch(inSessionMeta:)) ?? ""
                    }
                    if state.conversationParentSession == nil {
                        state.conversationParentSession = meta.flatMap(parentThreadID(inSessionMeta:)) ?? ""
                    }
                }
                var projectResolver = ConversationProjectResolver()
                return CodexFileScanResult(
                    stateKey: stateKey,
                    state: state,
                    entries: [],
                    seedKey: "codex:\(id)",
                    seed: ConversationSeed(
                        key: "codex:\(id)",
                        id: id,
                        app: .codex,
                        title: indexedTitles[id] ?? state.fallbackTitle,
                        project: projectResolver.resolve(rawPath: state.conversationCwd ?? "", source: .cwd),
                        gitBranch: nonEmpty(state.conversationGitBranch),
                        sourcePath: path,
                        includesSubtasks: false,
                        cacheCreationAvailable: false,
                        parentKey: nonEmpty(state.conversationParentSession).map { "codex:\($0)" }
                    ),
                    linesParsed: 0,
                    readFailed: false
                )
            }
            return CodexFileScanResult(
                stateKey: stateKey,
                state: state,
                entries: [],
                seedKey: nil,
                seed: nil,
                linesParsed: 0,
                readFailed: false
            )
        }
        // 文件被截断：offset 回到 0 重扫（此时仍由全局 seen 兜底防重复计费）
        if state.offset > size {
            resetForTruncation(&state)
        }
        let startsFromBeginning = state.offset == 0

        var linesParsed = 0
        var currentModel = state.lastModel
        var currentSpeed = state.lastServiceTier ?? .standard
        var lastTotalUsageSignature = state.lastCodexTotalUsageSignature
        // 本文件自身的会话 ID：只由首条 session_meta（或文件名 UUID）决定，
        // 决定用量与会话种子的归属，绝不被 fork 重放进来的父会话 session_meta 覆盖。
        var ownSessionID = state.conversationID ?? filenameID
        // 发出当前这批记录的会话 ID：跟随每条 session_meta 变化，重放段里指向父会话。
        // 只用于生成跨文件去重键，让重放行与父文件里的原始行同键。
        var emittingSessionID = state.lastCodexEmittingSessionID ?? ownSessionID
        var sessionCwd = state.conversationCwd ?? ""
        var sessionBranch = nonEmpty(state.conversationGitBranch)
        var parentThread = nonEmpty(state.conversationParentSession)
        var fallbackTitle = state.fallbackTitle
        var entries: [PendingCodexEntry] = []
        var invalidHistoricalRecord = false
        // 按批流式解析：单文件不再把整份内容和全部行同时读进内存。
        let outcome = JSONLLineReader.streamLines(url: url, fromOffset: state.offset,
                                                 throughOffset: boundary?.offset) { batch in
            for line in batch {
                linesParsed += 1
                guard let data = line.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    invalidHistoricalRecord = true
                    continue
                }
                let type = root["type"] as? String

                if type == "session_meta", let payload = root["payload"] as? [String: Any] {
                    let metaID = (payload["id"] as? String) ?? (payload["session_id"] as? String)
                    if ownSessionID == nil { ownSessionID = metaID }
                    if let metaID { emittingSessionID = metaID }
                    // fork 文件里混着父会话原样重放的 session_meta，只有自身那条能定义会话元数据。
                    if metaID == nil || metaID == ownSessionID {
                        sessionCwd = (payload["cwd"] as? String) ?? sessionCwd
                        sessionBranch = Self.gitBranch(inSessionMeta: payload) ?? sessionBranch
                        parentThread = Self.parentThreadID(inSessionMeta: payload) ?? parentThread
                    }
                    continue
                }

                if type == "event_msg",
                   let payload = root["payload"] as? [String: Any],
                   (payload["type"] as? String) == "user_message",
                   fallbackTitle == nil {
                    fallbackTitle = ConversationTitleIndex.clean(payload["message"] as? String)
                    continue
                }

                if type == "turn_context" {
                    if let payload = root["payload"] as? [String: Any],
                       let m = payload["model"] as? String {
                        currentModel = m
                    }
                    continue
                }
                if let settings = threadSettings(from: root) {
                    if let model = settings.model {
                        currentModel = model
                    }
                    currentSpeed = settings.speed
                    continue
                }
                guard type == "event_msg",
                      let payload = root["payload"] as? [String: Any],
                      (payload["type"] as? String) == "token_count" else {
                    continue
                }
                guard let info = payload["info"] as? [String: Any],
                      let last = info["last_token_usage"] as? [String: Any] else {
                    continue
                }
                let totalSignature = totalUsageSignature(info["total_token_usage"] as? [String: Any])
                if totalSignature == lastTotalUsageSignature, totalSignature != nil { continue }
                let inputTotal = (last["input_tokens"] as? Int) ?? 0
                let cachedInput = (last["cached_input_tokens"] as? Int) ?? 0
                let cacheWrite = cacheWriteTokens(in: last)
                let output = (last["output_tokens"] as? Int) ?? 0
                let billableInput = max(0, inputTotal - cachedInput - cacheWrite)
                if output == 0 && billableInput == 0 && cachedInput == 0 && cacheWrite == 0 { continue }

                let ts: Date
                if let s = root["timestamp"] as? String,
                   let parsed = JSONLTimestamp.parse(s) {
                    ts = parsed
                } else {
                    invalidHistoricalRecord = true
                    ts = Date()
                }
                let model = currentModel ?? "unknown"
                guard let resolvedID = ownSessionID else { continue }
                if let totalSignature { lastTotalUsageSignature = totalSignature }
                let cost = boundary == nil ? Pricing.costBreakdown(
                    app: .codex,
                    model: model,
                    speed: currentSpeed,
                    input: billableInput,
                    output: output,
                    cacheRead: cachedInput,
                    cacheCreation: cacheWrite,
                    at: ts,
                    inputTotal: inputTotal
                ) : nil
                let entry = UsageEntry(
                    app: .codex,
                    conversationKey: "codex:\(resolvedID)",
                    model: storageModel(model),
                    speed: currentSpeed,
                    day: UsageDay.startOfDay(for: ts),
                    timestamp: ts,
                    inputTokens: billableInput,
                    outputTokens: output,
                    cacheReadTokens: cachedInput,
                    cacheCreationTokens: cacheWrite,
                    costUSD: cost?.total,
                    costBreakdown: cost
                )
                entries.append(PendingCodexEntry(
                    entry: entry,
                    dedupeKey: dedupeKey(
                        emittingSessionID: emittingSessionID,
                        totalUsageSignature: totalSignature
                    ),
                    hasCacheCreation: cacheWrite > 0
                ))
            }
        }
        // 打开 / 读取失败时丢弃本文件已解析的部分，watermark 保持原值，下轮重来。
        let newOffset: UInt64
        switch outcome {
        case let .success(offset):
            if let boundary,
               invalidHistoricalRecord || offset != boundary.offset
                || lastTotalUsageSignature != boundary.lastCodexTotalUsageSignature
                || currentModel != boundary.lastModel
                || currentSpeed != (boundary.lastServiceTier ?? .standard)
                || ownSessionID != boundary.conversationID {
                return CodexFileScanResult(stateKey: stateKey, state: state, entries: [],
                                           seedKey: nil, seed: nil, linesParsed: linesParsed, readFailed: true,
                                           evidenceRejected: true)
            }
            newOffset = offset
        case .missing:
            return CodexFileScanResult(
                stateKey: stateKey,
                state: state,
                entries: [],
                seedKey: nil,
                seed: nil,
                linesParsed: 0,
                readFailed: false,
                fileDisappeared: true
            )
        case .failed:
            return CodexFileScanResult(
                stateKey: stateKey,
                state: state,
                entries: [],
                seedKey: nil,
                seed: nil,
                linesParsed: 0,
                readFailed: true
            )
        }

        state.mtime = mtime
        state.offset = newOffset
        state.lastModel = currentModel
        state.lastServiceTier = currentSpeed
        state.lastCodexTotalUsageSignature = lastTotalUsageSignature
        state.lastCodexEmittingSessionID = emittingSessionID
        state.conversationID = ownSessionID
        state.conversationCwd = sessionCwd
        // 从头读过仍没有分支时记空串，避免之后按「未检查」再读首行。
        state.conversationGitBranch = sessionBranch ?? (startsFromBeginning ? "" : state.conversationGitBranch)
        // 父对话同理；旧版本从中途续扫、从没检查过的文件，补读一次首行。
        if let parentThread {
            state.conversationParentSession = parentThread
        } else if startsFromBeginning {
            state.conversationParentSession = ""
        } else if state.conversationParentSession == nil {
            state.conversationParentSession = firstLineSessionMeta(url: url).flatMap(Self.parentThreadID(inSessionMeta:)) ?? ""
        }
        state.fallbackTitle = fallbackTitle

        var seedKey: String?
        var seed: ConversationSeed?
        if let id = ownSessionID {
            seedKey = "codex:\(id)"
            var projectResolver = ConversationProjectResolver()
            seed = ConversationSeed(
                key: seedKey!,
                id: id,
                app: .codex,
                title: indexedTitles[id] ?? fallbackTitle,
                project: projectResolver.resolve(rawPath: sessionCwd, source: .cwd),
                gitBranch: sessionBranch,
                sourcePath: path,
                includesSubtasks: false,
                // 由调用方在跨文件去重之后统一补标（见 scan 收尾）。
                cacheCreationAvailable: false,
                parentKey: nonEmpty(state.conversationParentSession).map { "codex:\($0)" }
            )
        }
        return CodexFileScanResult(
            stateKey: stateKey,
            state: state,
            entries: entries,
            seedKey: seedKey,
            seed: seed,
            linesParsed: linesParsed,
            readFailed: false
        )
    }

    private nonisolated static func conversationID(from url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#
        guard let range = name.range(of: pattern, options: .regularExpression) else { return nil }
        return String(name[range])
    }

    /// GPT-5.6 的 API usage 可将该字段放在顶层或 input / prompt token details。
    /// 当前 Codex 本地日志未提供时返回 0，不对未记录的缓存写入做推测。
    private nonisolated static func cacheWriteTokens(in usage: [String: Any]) -> Int {
        if let value = usage["cache_write_tokens"] as? Int {
            return value
        }
        for key in ["input_tokens_details", "prompt_tokens_details", "token_details"] {
            if let details = usage[key] as? [String: Any],
               let value = details["cache_write_tokens"] as? Int {
                return value
            }
        }
        return 0
    }

    /// 保持为 internal，供脱敏 JSONL fixture 单测验证设置切换与未知值处理。
    nonisolated static func speed(fromServiceTier value: String?) -> UsageSpeed {
        switch value?.lowercased() {
        case "priority", "fast": return .fast
        case "default": return .standard
        default: return .unknown
        }
    }

    /// 解析 Codex 实际 JSONL 的嵌套设置事件；未知档位仍返回设置对象并标成 unknown。
    nonisolated static func threadSettings(from root: [String: Any]) -> ThreadSettings? {
        guard (root["type"] as? String) == "event_msg",
              let payload = root["payload"] as? [String: Any],
              (payload["type"] as? String) == "thread_settings_applied",
              let settings = payload["thread_settings"] as? [String: Any] else {
            return nil
        }
        return ThreadSettings(
            model: settings["model"] as? String,
            speed: speed(fromServiceTier: settings["service_tier"] as? String)
        )
    }

    /// 累计用量的稳定签名。Codex 切换线程设置时可能原样回显上一条 token_count；累计值相同即不是新请求。
    nonisolated static func totalUsageSignature(_ usage: [String: Any]?) -> String? {
        guard let usage else { return nil }
        let keys = [
            "input_tokens",
            "cached_input_tokens",
            "cache_write_tokens",
            "output_tokens",
            "reasoning_output_tokens",
            "total_tokens"
        ]
        let values = keys.map { String((usage[$0] as? Int) ?? 0) }
        guard values.contains(where: { $0 != "0" }) else { return nil }
        return values.joined(separator: ":")
    }

    /// 跨文件去重键：`发出该记录的会话 id#累计用量签名`。
    ///
    /// 用 `totalUsageSignature` 的完整六字段而不是单个 `total_tokens`：会话内累计值本该单调
    /// 递增（切换设置时回显的重复记录已由 `lastCodexTotalUsageSignature` 在解析阶段滤掉），
    /// 但 compact / 上下文重置若让累计值回落，单字段键就可能让两条真实记录撞键、误删其一。
    /// 六字段全部相同才判为同一条记录，代价只是每个键多约 35 字节。
    ///
    /// fork 重放的行连同父会话的 session_meta 一起搬过来，`emittingSessionID` 与累计签名都与
    /// 父文件里的原始行一致，因此天然同键。签名缺失（累计用量全 0 或没有该字段）时返回 nil，
    /// 不参与去重——宁可重复也不误删。
    nonisolated static func dedupeKey(
        emittingSessionID: String?,
        totalUsageSignature: String?
    ) -> String? {
        guard let emittingSessionID, let totalUsageSignature else { return nil }
        return "\(emittingSessionID)#\(totalUsageSignature)"
    }

    /// 文件被截断后，offset 与依赖前文的 Codex 解析上下文必须一起重置。
    nonisolated static func resetForTruncation(_ state: inout ScanFileState) {
        state.offset = 0
        state.lastModel = nil
        state.lastServiceTier = nil
        state.lastCodexTotalUsageSignature = nil
        state.lastCodexEmittingSessionID = nil
    }

    /// `session_meta.payload.git.branch`；字段缺失或为空时返回 nil。
    nonisolated static func gitBranch(inSessionMeta payload: [String: Any]) -> String? {
        guard let git = payload["git"] as? [String: Any] else { return nil }
        return nonEmpty(git["branch"] as? String)
    }

    /// 子代理 / Guardian 审查在自身 `session_meta` 里记录的父对话 ID：优先 `parent_thread_id`，
    /// 其次 `source.subagent.thread_spawn.parent_thread_id`；指向自身或缺失时返回 nil。
    /// 只认 `parent_thread_id`：用户手动 fork（只有 `forked_from_id`）是独立对话，不并入。
    nonisolated static func parentThreadID(inSessionMeta payload: [String: Any]) -> String? {
        let subagent = (payload["source"] as? [String: Any])?["subagent"] as? [String: Any]
        let spawn = subagent?["thread_spawn"] as? [String: Any]
        guard let parent = nonEmpty(payload["parent_thread_id"] as? String)
                ?? nonEmpty(spawn?["parent_thread_id"] as? String),
              parent != (payload["id"] as? String) else { return nil }
        return parent
    }

    private nonisolated static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// 只读文件首行（Codex 首行固定是本会话的 session_meta）。
    /// 首行含完整 base_instructions，可能有几十 KB；超过 2MB 仍无换行视为异常，放弃。
    private nonisolated static func firstLineSessionMeta(url: URL) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var data = Data()
        let newline = UInt8(ascii: "\n")
        while data.count < 2 << 20 {
            guard let chunk = try? handle.read(upToCount: 256 << 10), !chunk.isEmpty else { break }
            if let index = chunk.firstIndex(of: newline) {
                data.append(chunk[chunk.startIndex..<index])
                break
            }
            data.append(chunk)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["type"] as? String) == "session_meta",
              let payload = root["payload"] as? [String: Any]
        else { return nil }
        return payload
    }
}
