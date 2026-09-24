import Foundation

/// 扫 `~/.dsh/sessions/**` 的 DSH 会话日志（草案 §2.3、§3.1、§3.2）。
///
/// 目录形态是 `sessions/<项目段>/<会话段>/<日志文件>`；段名经过编码，**不从目录名反推**
/// cwd 或 session id，会话元数据一律取自文件内的 `session` 记录。
///
/// 一个会话目录只认规范名里**版本号最高**的那个日志：
/// v0 = `session.jsonl[.zstd]`，vN = `session.vN.jsonl[.zstd]`（N 为正整数）；
/// 忽略大写、`v0`、前导零、锁文件与临时文件。同版本两种编码并存属于异常，固定优先 zstd
/// 并计一次 `duplicateEncodingCount`（宽容读取不代表 DSH 可以继续写该目录）。
///
/// `session` 与 `session/end-seed` 确定 fork 继承边界，继承段只用于恢复请求路由，不重复计费。
/// `request/header` / `request/context` 提供失败尝试的模型；`llm/retry-started` 结束同一步骤的替换槽。
/// `assistant/message` / `assistant/attempt` 都可结算用量，优先取消息顶层 usage，
/// 否则取 stream 最后一条 usage。同一结算槽的后续样本替换前样本；不同 retry 另计。
///
/// 增量语义（§3.2）：zstd 的 watermark 恒落在上一个**成功入账的完整帧**末尾，明文落在最后一个
/// 完整换行末尾；尾部撕裂帧不算失败、本轮不消费。解码、UTF-8、JSON 或读取失败时丢弃**该文件
/// 本轮结果**并保留旧 watermark，其他文件照常处理，失败数由调用方计入 `lastError`（§6 决策 4）。
///
/// 本类型只做「文件 → 条目」，不做跨会话归并：`conversationKey` 用会话自身 id 占位（`dsh:<id>`），
/// 子代理归根、generation 切换后的贡献替换由逐会话贡献缓存负责（§3.3、§4.1）。
enum DshSessionScanner {
    /// 单个 zstd 帧解压输出上限，防损坏文件造成无界分配。
    nonisolated static let maxFrameOutput = DshZstdDecoder.defaultOutputLimit

    struct Result: Sendable {
        var entries: [UsageEntry]
        /// 按来源文件隔离条目，避免不同目录的同一会话 ID 相互污染。
        var entriesByPath: [String: [UsageEntry]]
        var previousPaths: Set<String>
        var duplicateSessionIDs: Set<String>
        var conversationSeeds: [ConversationSeed]
        var newState: [String: ScanFileState]
        /// 参与判定的规范日志文件数（每个会话目录至多一个）。
        var filesScanned: Int
        /// 本轮结果被丢弃的文件数：读取、解码、UTF-8 或 JSON 失败。
        var failedFileCount: Int
        var failedDirectoryCount: Int
        var duplicateSessionCount: Int
        var isComplete: Bool {
            failedFileCount == 0 && failedDirectoryCount == 0 && duplicateSessionCount == 0
        }
        /// 同一会话目录里同版本两种编码并存的次数（异常，仅计数，不含路径）。
        var duplicateEncodingCount: Int
        /// 因文件被截断而**从 0 重扫**的会话 id：调用方必须用本轮该会话的条目整体替换旧贡献。
        var restartedSessionIDs: Set<String>
        /// `totalTokens` 与四项之和不一致的次数（该校验字段不参与二次求和，仅供诊断）。
        var totalTokensMismatchCount: Int
    }

    /// 生产根：`~/.dsh/sessions`。Desktop 自定义数据目录、显式 `DSH_HOME`、Beta home
    /// 与自定义持久化 root 都不做自动发现（§1）。
    nonisolated static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/sessions", isDirectory: true)
    }

    nonisolated static func scan(
        previous: [String: ScanFileState],
        onProgress: ScanProgressCallback? = nil
    ) -> Result {
        scan(previous: previous, root: defaultRoot, onProgress: onProgress)
    }

    /// 可注入日志根目录，供脱敏 fixture 测试真实字节偏移扫描链路。
    nonisolated static func scan(
        previous: [String: ScanFileState],
        root: URL,
        onProgress: ScanProgressCallback? = nil
    ) -> Result {
        var result = Result(
            entries: [],
            entriesByPath: [:],
            previousPaths: Set(previous.keys),
            duplicateSessionIDs: [],
            conversationSeeds: [],
            newState: [:],
            filesScanned: 0,
            failedFileCount: 0,
            failedDirectoryCount: 0,
            duplicateSessionCount: 0,
            duplicateEncodingCount: 0,
            restartedSessionIDs: [],
            totalTokensMismatchCount: 0
        )

        let selection = selectedLogs(under: root, hadPreviousLogs: !previous.isEmpty)
        let logs = selection.logs
        result.failedDirectoryCount = selection.failedPrefixes.count
        var linesParsed = 0
        let total = logs.count

        for (index, log) in logs.enumerated() {
            if index % 50 == 0 || index == total - 1 {
                onProgress?(ScanProgress(
                    app: .dsh,
                    filesCompleted: index + 1,
                    filesTotal: total,
                    linesParsed: linesParsed
                ))
            }
            result.filesScanned += 1
            if log.duplicateEncoding {
                result.duplicateEncodingCount += 1
            }

            var state = previous[log.fileURL.path] ?? ScanFileState(mtime: 0, offset: 0)
            // 未变化（mtime 与大小都没动）→ 跳过，用状态里的会话元数据补种子。
            if state.mtime == log.modificationTime,
               state.offset == log.size,
               state.fileIdentity == nil || state.fileIdentity == log.identity
            {
                result.newState[log.fileURL.path] = state
                continue
            }
            // 文件被截断或**原地替换**（inode 变了）：不能把旧 offset 当有效起点继续累加，
            // 从 0 重扫并请调用方整体替换该会话贡献（§3.3）。
            var restarted = false
            if state.offset > log.size {
                state = ScanFileState(mtime: 0, offset: 0)
                restarted = true
            } else if let previousIdentity = state.fileIdentity,
                      let currentIdentity = log.identity,
                      previousIdentity != currentIdentity
            {
                state = ScanFileState(mtime: 0, offset: 0)
                restarted = true
            }

            var scan = FileScan(state: state)
            var mismatch = 0
            func read(from offset: UInt64) -> FileOutcome {
                let onLine: (String) -> Bool = { line in
                    linesParsed += 1
                    return ingest(line: line, into: &scan, mismatch: &mismatch)
                }
                return log.isZstd
                    ? scanZstdFile(url: log.fileURL, from: offset, onLine: onLine)
                    : scanPlainFile(url: log.fileURL, from: offset, onLine: onLine)
            }
            var outcome = read(from: state.offset)
            if scan.restartNeeded {
                // 前一轮已经计入的同一结算槽被新事件替换；只在此少见情形重读该会话。
                restarted = true
                state = ScanFileState(mtime: 0, offset: 0)
                scan = FileScan(state: state)
                mismatch = 0
                outcome = read(from: 0)
            }

            switch outcome {
            case .failed:
                // 丢弃该文件本轮结果、保留旧 watermark，其他文件继续。
                result.failedFileCount += 1
                result.newState[log.fileURL.path] = previous[log.fileURL.path] ?? ScanFileState(mtime: 0, offset: 0)
                continue
            case .missing:
                // 枚举后消失也可能是临时拒绝访问；本轮不能据此宣布全量重建完整。
                result.failedFileCount += 1
                result.newState[log.fileURL.path] = previous[log.fileURL.path] ?? ScanFileState(mtime: 0, offset: 0)
                continue
            case .success(let newOffset):
                if scan.sessionID == nil || (scan.isSeeded && scan.seedCut == nil && !scan.seedComplete) {
                    result.failedFileCount += 1
                    result.newState[log.fileURL.path] = previous[log.fileURL.path] ?? ScanFileState(mtime: 0, offset: 0)
                    continue
                }
                result.totalTokensMismatchCount += mismatch
                state.mtime = log.modificationTime
                state.offset = newOffset
                state.fileIdentity = log.identity
                state.fileSize = log.size
                state.conversationID = scan.sessionID
                state.conversationCwd = scan.cwd
                state.conversationParentSession = scan.parentSession
                state.fallbackTitle = scan.title
                state.dshSeedCut = scan.seedCut
                state.dshIsSeeded = scan.isSeeded
                state.dshSeedComplete = scan.seedComplete
                state.dshRouteProvider = scan.routeProvider
                state.dshRouteModel = scan.routeModel
                state.dshLastTurn = scan.lastTurn
                state.dshLastStep = scan.lastStep
                state.dshLastSlotOpen = scan.lastSlotOpen
                result.newState[log.fileURL.path] = state
                result.entriesByPath[log.fileURL.path] = scan.entries
                if restarted, let id = scan.sessionID {
                    result.restartedSessionIDs.insert(id)
                }
            }
        }

        // 枚举失败的子树不是删除：保留其中全部旧 watermark，等待访问恢复。
        for (path, state) in previous where selection.failedPrefixes.contains(where: { path.hasPrefix($0) }) {
            result.newState[path] = state
        }

        // 同一 ID 同时出现在不同会话目录时，两份都不提交；不可读子树的旧状态也参与防冲突。
        var pathsByID: [String: [String]] = [:]
        for (path, state) in result.newState {
            if let id = state.conversationID { pathsByID[id, default: []].append(path) }
        }
        let selectedPaths = Set(logs.map { $0.fileURL.path })
        for (id, paths) in pathsByID where paths.count > 1 && paths.contains(where: { selectedPaths.contains($0) }) {
            result.duplicateSessionCount += 1
            result.duplicateSessionIDs.insert(id)
            result.restartedSessionIDs.remove(id)
            for path in paths {
                result.entriesByPath.removeValue(forKey: path)
                if let old = previous[path] {
                    result.newState[path] = old
                } else {
                    result.newState.removeValue(forKey: path)
                }
            }
        }
        result.entries = logs.flatMap { result.entriesByPath[$0.fileURL.path] ?? [] }
        var seeds: [String: ConversationSeed] = [:]
        var projectResolver = ConversationProjectResolver()
        for (path, state) in result.newState {
            guard let id = state.conversationID, !result.duplicateSessionIDs.contains(id) else { continue }
            seeds["dsh:\(id)"] = seed(id: id, state: state, path: path, resolver: &projectResolver)
        }
        result.conversationSeeds = Array(seeds.values)
        return result
    }

    // MARK: - 目录与命名

    struct LogName: Equatable, Sendable {
        var version: Int
        var isZstd: Bool
    }

    /// 解析规范日志名。非规范名（大写、`v0`、前导零、锁文件、临时文件等）返回 nil。
    nonisolated static func canonicalLogName(_ name: String) -> LogName? {
        var stem = name
        var isZstd = false
        if stem.hasSuffix(".zstd") {
            isZstd = true
            stem.removeLast(".zstd".count)
        }
        guard stem.hasSuffix(".jsonl") else { return nil }
        stem.removeLast(".jsonl".count)
        if stem == "session" { return LogName(version: 0, isZstd: isZstd) }

        guard stem.hasPrefix("session.v") else { return nil }
        let digits = stem.dropFirst("session.v".count)
        guard !digits.isEmpty,
              digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              digits.first != "0",
              let version = Int(digits),
              version > 0
        else { return nil }
        return LogName(version: version, isZstd: isZstd)
    }

    struct SelectedLog: Equatable, Sendable {
        var fileURL: URL
        var isZstd: Bool
        var modificationTime: Double
        var size: UInt64
        /// device + inode：同路径被原地替换时用它判定必须从 0 重扫。
        var identity: ScanFileIdentity?
        /// 同版本两种编码并存（异常）。
        var duplicateEncoding: Bool
    }

    struct LogSelection: Sendable {
        var logs: [SelectedLog]
        var failedPrefixes: [String]
    }

    /// 枚举 `root/<项目段>/<会话段>/` 并挑出每个会话目录的规范日志。
    nonisolated static func selectedLogs(under root: URL, hadPreviousLogs: Bool = false) -> LogSelection {
        let fileManager = FileManager.default
        let projects: [URL]
        do {
            projects = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            // 默认根从未创建是正常的；存在但不可枚举才是失败。
            let failed = hadPreviousLogs || fileManager.fileExists(atPath: root.path)
            return LogSelection(logs: [], failedPrefixes: failed ? [root.path + "/"] : [])
        }

        var selected: [SelectedLog] = []
        var failedPrefixes: [String] = []
        for project in projects {
            guard let isProject = try? project.resourceValues(forKeys: [.isDirectoryKey]).isDirectory else {
                failedPrefixes.append(project.path + "/")
                continue
            }
            guard isProject else { continue }
            guard let sessions = try? fileManager.contentsOfDirectory(
                at: project,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                failedPrefixes.append(project.path + "/")
                continue
            }

            for session in sessions {
                guard let isSession = try? session.resourceValues(forKeys: [.isDirectoryKey]).isDirectory else {
                    failedPrefixes.append(session.path + "/")
                    continue
                }
                guard isSession else { continue }
                guard let entries = try? fileManager.contentsOfDirectory(
                    at: session,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    failedPrefixes.append(session.path + "/")
                    continue
                }
                do {
                    if let log = try selectLog(in: entries) { selected.append(log) }
                } catch {
                    failedPrefixes.append(session.path + "/")
                }
            }
        }
        return LogSelection(logs: selected.sorted { $0.fileURL.path < $1.fileURL.path }, failedPrefixes: failedPrefixes)
    }

    /// 选版本号最高的规范日志；同版本优先 zstd，两者并存时标记异常。
    private enum SelectionError: Error { case missingFileIdentity }

    nonisolated static func selectLog(in entries: [URL]) throws -> SelectedLog? {
        var best: (name: LogName, url: URL)?
        var duplicate = false

        for url in entries {
            guard let name = canonicalLogName(url.lastPathComponent) else { continue }
            guard let current = best else {
                best = (name, url)
                continue
            }
            if name.version > current.name.version {
                best = (name, url)
                duplicate = false
                continue
            }
            guard name.version == current.name.version else { continue }
            if name.isZstd == current.name.isZstd {
                continue
            }
            // 同版本两种编码并存：固定 zstd，记一次异常。
            duplicate = true
            if name.isZstd {
                best = (name, url)
            }
        }

        guard let best else { return nil }
        let values = try best.url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        guard let modifiedAt = values.contentModificationDate,
              let fileSize = values.fileSize,
              fileSize >= 0,
              let identity = ScanFileIdentity.read(atPath: best.url.path)
        else { throw SelectionError.missingFileIdentity }
        return SelectedLog(
            fileURL: best.url,
            isZstd: best.name.isZstd,
            modificationTime: modifiedAt.timeIntervalSince1970,
            size: UInt64(fileSize),
            identity: identity,
            duplicateEncoding: duplicate
        )
    }

    // MARK: - 字节读取

    private enum FileOutcome {
        case success(newOffset: UInt64)
        case missing
        case failed
    }

    /// zstd 单次读盘块大小。
    nonisolated static let chunkSize = 1 << 20

    /// 多帧 zstd 日志的分块增量扫描：只缓存尾部未完成帧，已入账前缀不驻留内存。
    private nonisolated static func scanZstdFile(
        url: URL,
        from offset: UInt64,
        onLine: (String) -> Bool
    ) -> FileOutcome {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return failureOutcome(url)
        }
        defer { try? handle.close() }

        let end: UInt64
        do {
            end = try handle.seekToEnd()
        } catch {
            return failureOutcome(url)
        }
        if offset >= end { return .success(newOffset: end) }
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return failureOutcome(url)
        }

        var pending = Data()
        var consumed: UInt64 = 0
        var corrupted = false

        while true {
            var failure = false
            var reachedEOF = false
            autoreleasepool {
                let chunk: Data?
                do {
                    chunk = try handle.read(upToCount: chunkSize)
                } catch {
                    failure = true
                    return
                }
                guard let chunk, !chunk.isEmpty else {
                    reachedEOF = true
                    return
                }
                pending.append(chunk)

                switch DshZstdFrames.scan(pending) {
                case .corrupt:
                    corrupted = true
                case .scanned(let scan):
                    for frame in scan.frames {
                        let payload = pending.subdata(in: frame.start..<frame.end)
                        guard let decoded = try? DshZstdDecoder.decodeFrame(payload, outputLimit: maxFrameOutput),
                              let text = String(data: decoded, encoding: .utf8)
                        else {
                            corrupted = true
                            return
                        }
                        for line in text.split(separator: "\n") where !line.isEmpty {
                            guard onLine(String(line)) else {
                                corrupted = true
                                return
                            }
                        }
                    }
                    consumed += UInt64(scan.frames.last?.end ?? 0)
                    if let tornStart = scan.tornStart {
                        pending = pending.subdata(in: (pending.startIndex + tornStart)..<pending.endIndex)
                    } else {
                        pending.removeAll(keepingCapacity: true)
                    }
                }
            }
            if failure { return failureOutcome(url) }
            if corrupted { return .failed }
            if reachedEOF { break }
        }
        return .success(newOffset: offset + consumed)
    }

    /// 明文日志增量扫描：复用 `JSONLLineReader` 的整行规则（只消费到最后一个换行）。
    private nonisolated static func scanPlainFile(
        url: URL,
        from offset: UInt64,
        onLine: (String) -> Bool
    ) -> FileOutcome {
        switch JSONLLineReader.readOutcome(url: url, fromOffset: offset) {
        case .success(let lines, let newOffset):
            for line in lines where !onLine(line) {
                return .failed
            }
            return .success(newOffset: newOffset)
        case .missing:
            return .missing
        case .failed:
            return .failed
        }
    }

    private nonisolated static func failureOutcome(_ url: URL) -> FileOutcome {
        FileManager.default.fileExists(atPath: url.path) ? .failed : .missing
    }

    // MARK: - 记录解析

    /// 单文件本轮的暂存结果；只有整份文件成功时才提交给调用方。
    private struct FileScan {
        var sessionID: String?
        var cwd: String?
        var parentSession: String?
        var title: String?
        var isSeeded = false
        var seedCut: Int?
        var seedComplete = true
        var resumedSeed = false
        var routeProvider: String?
        var routeModel: String?
        var lastTurn: Int?
        var lastStep: Int?
        var lastSlotOpen = false
        var lastEntryIndex: Int?
        var restartNeeded = false
        var entries: [UsageEntry] = []

        init(state: ScanFileState) {
            sessionID = state.conversationID
            cwd = state.conversationCwd
            parentSession = state.conversationParentSession
            title = state.fallbackTitle
            seedCut = state.dshSeedCut
            seedComplete = state.dshSeedComplete ?? true
            isSeeded = state.dshIsSeeded ?? (!seedComplete || seedCut != nil)
            resumedSeed = state.offset > 0 && isSeeded && seedComplete
            routeProvider = state.dshRouteProvider
            routeModel = state.dshRouteModel
            lastTurn = state.dshLastTurn
            lastStep = state.dshLastStep
            lastSlotOpen = state.dshLastSlotOpen ?? false
        }
    }

    /// - Returns: 该行是否可继续处理；`false` 表示整份文件本轮作废。
    private nonisolated static func ingest(
        line: String,
        into scan: inout FileScan,
        mismatch: inout Int
    ) -> Bool {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }
        guard let type = root["type"] as? String else { return true }
        if type != "session", let cut = scan.seedCut,
           let seq = (root["seq"] as? NSNumber)?.intValue, seq >= cut {
            scan.seedComplete = true
        }

        switch type {
        case "session":
            if let id = root["id"] as? String { scan.sessionID = id }
            if let cwd = root["cwd"] as? String { scan.cwd = cwd }
            if let parent = root["parentSession"] as? String { scan.parentSession = parent }
            scan.isSeeded = (root["isSeeded"] as? Bool) == true || root["seedLength"] != nil
            if root["seedLength"] != nil {
                guard let cut = (root["seedLength"] as? NSNumber)?.intValue, cut >= 0 else { return false }
                scan.seedCut = cut
            } else {
                scan.seedCut = nil
            }
            scan.seedComplete = !scan.isSeeded || scan.seedCut == 0
            return true

        case "session/end-seed":
            if let body = root["data"] as? [String: Any], body["inherited"] as? Bool == true {
                guard scan.isSeeded else { return false }
                if scan.resumedSeed {
                    scan.restartNeeded = true
                    return false
                }
                // 嵌套 fork 的种子中可能已有父会话的标记；最后一个标记才是本会话的 cut。
                scan.entries.removeAll()
                scan.title = nil
                scan.lastTurn = nil
                scan.lastStep = nil
                scan.lastSlotOpen = false
                scan.lastEntryIndex = nil
                scan.seedComplete = true
            }
            return true

        case "request/context":
            if let body = root["data"] as? [String: Any] {
                scan.routeProvider = body["provider"] as? String
                scan.routeModel = body["model"] as? String
            }
            return true

        case "request/header":
            if let body = root["data"] as? [String: Any],
               let header = body["header"] as? [String: Any],
               let config = header["config"] as? [String: Any] {
                scan.routeProvider = config["provider"] as? String
                scan.routeModel = config["model"] as? String
            }
            return true

        case "llm/retry-started":
            if let body = root["data"] as? [String: Any],
               scan.lastTurn == (body["turn"] as? NSNumber)?.intValue,
               scan.lastStep == (body["step"] as? NSNumber)?.intValue {
                scan.lastSlotOpen = false
                scan.lastEntryIndex = nil
            }
            return true

        case "session/title":
            guard scan.seedComplete else { return true }
            guard let body = root["data"] as? [String: Any],
                  let title = body["title"] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return true }
            // 最后一个有效标题胜出（空标题不覆盖已有标题）。
            scan.title = title
            return true

        case "assistant/message", "assistant/attempt":
            guard scan.seedComplete else { return true }
            guard let body = root["data"] as? [String: Any],
                  let usage = tokenUsage(in: body),
                  let sessionID = scan.sessionID,
                  let time = (root["time"] as? NSNumber)?.doubleValue, time > 0
            else { return true }

            let turn = (body["turn"] as? NSNumber)?.intValue
            let step = (body["step"] as? NSNumber)?.intValue
            if let turn, let step, scan.lastSlotOpen,
               scan.lastTurn == turn, scan.lastStep == step,
               scan.lastEntryIndex == nil {
                scan.restartNeeded = true
                return false
            }

            let timestamp = Date(timeIntervalSince1970: time / 1000)
            if let reported = (usage["totalTokens"] as? NSNumber)?.intValue {
                let sum = intValue(usage["inputTokens"])
                    + intValue(usage["outputTokens"])
                    + intValue(usage["cacheReadTokens"])
                    + intValue(usage["cacheWriteTokens"])
                if reported != sum { mismatch += 1 }
            }
            let model: String
            if type == "assistant/message" {
                let source = (body["message"] as? [String: Any])?["source"] as? [String: Any]
                model = modelLabel(
                    provider: (source?["provider"] as? String) ?? scan.routeProvider,
                    model: (source?["model"] as? String) ?? scan.routeModel
                )
            } else {
                model = modelLabel(provider: scan.routeProvider, model: scan.routeModel)
            }
            let entry = makeEntry(
                conversationID: sessionID,
                model: model,
                timestamp: timestamp,
                usage: usage
            )
            if let turn, let step, scan.lastSlotOpen,
               scan.lastTurn == turn, scan.lastStep == step,
               let index = scan.lastEntryIndex {
                scan.entries[index] = entry
            } else {
                scan.entries.append(entry)
                scan.lastEntryIndex = scan.entries.count - 1
            }
            scan.lastTurn = turn
            scan.lastStep = step
            scan.lastSlotOpen = turn != nil && step != nil
            return true

        default:
            return true
        }
    }

    /// 用量优先取 `data.usage`，缺失时取 `data.stream` 里最后一个 usage chunk；两处不可相加。
    private nonisolated static func tokenUsage(in body: [String: Any]) -> [String: Any]? {
        if let usage = body["usage"] as? [String: Any], hasRequiredFields(usage) {
            return usage
        }
        guard let stream = body["stream"] as? [Any] else { return nil }
        for element in stream.reversed() {
            guard let record = element as? [String: Any] else { continue }
            if let nested = record["chunk"] as? [String: Any],
               let type = nested["type"] as? String, type != "usage" {
                continue
            }
            let candidate = (record["chunk"] as? [String: Any])?["usage"] as? [String: Any]
                ?? record["usage"] as? [String: Any]
            if let candidate, hasRequiredFields(candidate) {
                return candidate
            }
        }
        return nil
    }

    /// DSH 的 `tokenUsageValue` 要求 `inputTokens` / `outputTokens` 必填。
    private nonisolated static func hasRequiredFields(_ usage: [String: Any]) -> Bool {
        usage["inputTokens"] != nil && usage["outputTokens"] != nil
    }

    /// 模型标签 `provider/model`；provider 自身可能已含 `/`（转发商），只加一次。
    private nonisolated static func modelLabel(provider: String?, model: String?) -> String {
        let model = model.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        guard let provider, !provider.isEmpty else {
            return model
        }
        return "\(provider)/\(model)"
    }

    private nonisolated static func makeEntry(
        conversationID: String,
        model: String,
        timestamp: Date,
        usage: [String: Any]
    ) -> UsageEntry {
        // inputTokens 已排除缓存读写，不再扣减；reasoningTokens 属于 output 子集，不重复计数。
        let input = intValue(usage["inputTokens"])
        let output = intValue(usage["outputTokens"])
        let cacheRead = intValue(usage["cacheReadTokens"])
        let cacheCreation = intValue(usage["cacheWriteTokens"])
        let totalTokens = input + output + cacheRead + cacheCreation

        // DSH 日志没有可当作真实账单的费用，只有 token usage（§4.2）。
        let breakdown = Pricing.resolveCostBreakdown(
            app: .dsh,
            model: model,
            speed: .standard,
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheCreation: cacheCreation,
            totalTokens: totalTokens,
            reportedCost: nil,
            reportedBreakdown: nil,
            at: timestamp
        )
        return UsageEntry(
            app: .dsh,
            conversationKey: "dsh:\(conversationID)",
            model: model,
            speed: .standard,
            day: UsageDay.startOfDay(for: timestamp),
            timestamp: timestamp,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheCreation,
            costUSD: breakdown?.total,
            costBreakdown: breakdown
        )
    }

    private nonisolated static func seed(
        id: String,
        state: ScanFileState,
        path: String,
        resolver: inout ConversationProjectResolver
    ) -> ConversationSeed {
        ConversationSeed(
            key: "dsh:\(id)",
            id: id,
            app: .dsh,
            title: state.fallbackTitle,
            project: resolver.resolve(rawPath: state.conversationCwd ?? "", source: .cwd),
            gitBranch: nil,
            sourcePath: path,
            includesSubtasks: false,
            cacheCreationAvailable: true
        )
    }

    private nonisolated static func intValue(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }
}
