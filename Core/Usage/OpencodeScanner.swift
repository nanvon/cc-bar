import Foundation
import SQLite3

/// 只读 OpenCode v1 / v2 会话库。变动会话重读全部已完成消息，调用方替换该会话贡献。
/// 两套表共存时按消息 ID 优先采用 v2；缓存只存变动签名，不保存消息正文。
enum OpencodeScanner {
    nonisolated struct MessageSignature: Sendable, Codable, Equatable {
        var count: Int64
        var updated: Int64
        var updatedSum: Int64
        var created: Int64
    }

    nonisolated struct SessionState: Sendable, Codable, Equatable {
        var legacy: MessageSignature?
        var v2: MessageSignature?
        var title: String?
        var directory: String
        var branch: String?
        var updated: Int64
        /// 未完成 assistant 不入账；更新签名变化后重新读取，供诊断保留待完成状态。
        var hasPendingMessages = false
    }

    nonisolated struct State: Sendable, Codable, Equatable {
        static let currentVersion = 1
        var version = Self.currentVersion
        var sourcePath: String
        var sessions: [String: SessionState] = [:]
    }

    struct Result: Sendable {
        /// 本轮刷新会话的完整贡献，不能作为新增条目累加。
        var entries: [UsageEntry] = []
        var conversationSeeds: [ConversationSeed] = []
        var refreshedSessionIDs: Set<String> = []
        var newState: State?
        var messagesRead = 0
        var error: String?
        var isComplete = false
    }

    nonisolated static func defaultDatabaseURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db", isDirectory: false)
    }

    nonisolated static func scan(
        previous: State?,
        databaseURL: URL = defaultDatabaseURL(),
        onProgress: ScanProgressCallback? = nil
    ) -> Result {
        // 未安装或暂时移走数据库时保留统计与状态；不把“缺文件”误报成空库。
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return Result(newState: previous)
        }
        let attempt = scan(previous: previous, databaseURL: databaseURL, immutable: false, onProgress: onProgress)
        // OpenCode 退出时会 checkpoint 并删除 -wal / -shm；系统 SQLite 的只读连接打开
        // 没有 sidecar 的 WAL 库会报 SQLITE_CANTOPEN。此时没有写入方，改用 immutable 重读。
        guard attempt.sqliteCode.map({ $0 & 0xff }) == SQLITE_CANTOPEN,
              walSidecarsAreMissing(databaseURL) else {
            return attempt.result
        }
        return scan(previous: previous, databaseURL: databaseURL, immutable: true, onProgress: onProgress).result
    }

    private nonisolated static func walSidecarsAreMissing(_ databaseURL: URL) -> Bool {
        !FileManager.default.fileExists(atPath: databaseURL.path + "-wal")
            && !FileManager.default.fileExists(atPath: databaseURL.path + "-shm")
    }

    /// `sqliteCode` 只在 SQLite 调用失败时携带，供外层判断是否改用 immutable 重试。
    private nonisolated static func scan(
        previous: State?,
        databaseURL: URL,
        immutable: Bool,
        onProgress: ScanProgressCallback?
    ) -> (result: Result, sqliteCode: Int32?) {
        var opened: OpaquePointer?
        let filename = immutable
            ? "\(databaseURL.absoluteURL.absoluteString)?immutable=1"
            : databaseURL.path
        let flags = immutable ? SQLITE_OPEN_READONLY | SQLITE_OPEN_URI : SQLITE_OPEN_READONLY
        let openResult = sqlite3_open_v2(filename, &opened, flags, nil)
        guard openResult == SQLITE_OK, let db = opened else {
            if let opened { sqlite3_close(opened) }
            return (Result(newState: previous, error: "OpenCode database could not be opened"), openResult)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)

        do {
            // 元数据签名和正文必须来自同一个 WAL 读快照，避免扫描期间写入导致漏算。
            try execute(db, sql: "BEGIN")
            defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
            let legacy = try source(db, messageTable: "message", sessionTable: "session", isV2: false)
            let v2 = try source(db, messageTable: "session_message", sessionTable: "session_v2", isV2: true)
            guard legacy != nil || v2 != nil else { throw ReadFailure(detail: "unsupported session schema") }
            let sources = [legacy, v2].compactMap { $0 }
            let workspaceColumns = try columns(db, table: "workspace")
            let hasBranch = workspaceColumns.isSuperset(of: ["id", "branch"])
            var sessions: [String: SessionState] = [:]
            for source in sources {
                try readSessions(db, source: source, hasBranch: hasBranch, into: &sessions)
            }

            let baseline = previous?.version == State.currentVersion
                && previous?.sourcePath == databaseURL.path ? previous : nil
            // 源库中删除的会话保留旧签名和 rollup；历史不因源文件清理而倒扣。
            var state = baseline ?? State(sourcePath: databaseURL.path)
            var result = Result(newState: previous)
            var projectResolver = ConversationProjectResolver()
            for id in sessions.keys.sorted() {
                guard var session = sessions[id] else { continue }
                if let old = baseline?.sessions[id] {
                    session.hasPendingMessages = old.hasPendingMessages
                    if old == session { continue }
                }
                session.hasPendingMessages = false
                var entries: [UsageEntry] = []
                var inheritedModel: String?
                var fallbackTitle: String?
                for source in sources {
                    let exclusion = !source.isV2 && v2 != nil
                        ? "AND NOT EXISTS (SELECT 1 FROM session_message v JOIN session_v2 s ON s.id = v.session_id WHERE v.id = m.id)"
                        : ""
                    let role = source.isV2 ? "m.type" : "NULL"
                    let sql = """
                    SELECT m.id, m.time_created, m.data, \(role)
                    FROM \(source.messageTable) m
                    WHERE m.session_id = ?1 \(exclusion)
                    ORDER BY m.time_created, m.id
                    """
                    try rows(db, sql: sql, sessionID: id) { stmt in
                        result.messagesRead += 1
                        if result.messagesRead % 200 == 0 {
                            onProgress?(ScanProgress(app: .opencode, filesCompleted: result.messagesRead,
                                                     filesTotal: 0, linesParsed: result.messagesRead))
                        }
                        guard let data = columnText(stmt, 2),
                              let json = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any]
                        else { throw ReadFailure(detail: "invalid message JSON") }
                        let role = columnText(stmt, 3) ?? (json["role"] as? String)
                        if role == "user" {
                            inheritedModel = parseModel(json["model"]) ?? inheritedModel
                            if fallbackTitle == nil {
                                fallbackTitle = ConversationTitleIndex.clean(json["text"] as? String)
                            }
                            return
                        }
                        guard role == "assistant" else { return }
                        // v1 的真实消息也有 time.completed；流式半成品不提前入账。
                        let time = json["time"] as? [String: Any]
                        guard (time?["completed"] as? NSNumber)?.int64Value != nil else {
                            session.hasPendingMessages = true
                            return
                        }
                        // 已完成但没有用量的失败请求属于正常记录。
                        guard let tokens = json["tokens"] as? [String: Any] else { return }
                        let input = intValue(tokens["input"])
                        let output = intValue(tokens["output"]) + intValue(tokens["reasoning"])
                        let cache = tokens["cache"] as? [String: Any] ?? [:]
                        let read = intValue(cache["read"])
                        let write = intValue(cache["write"])
                        let total = max(intValue(tokens["total"]), input + output + read + write)
                        let cost = decimalValue(json["cost"])
                        guard total > 0 || (cost ?? 0) > 0 else { return }
                        let model = parseModel(source.isV2 ? json["model"] : json)
                            ?? inheritedModel ?? "unknown/unknown"
                        entries.append(makeEntry(
                            conversationID: id, model: model,
                            timestamp: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 1)) / 1000),
                            input: input, output: output, cacheRead: read, cacheWrite: write,
                            totalTokens: total, cost: cost
                        ))
                    }
                }
                if fallbackTitle == nil, nonEmpty(session.title) == nil, legacy != nil {
                    fallbackTitle = try legacyTitle(db, sessionID: id)
                }
                result.entries.append(contentsOf: entries)
                result.refreshedSessionIDs.insert(id)
                if !entries.isEmpty {
                    result.conversationSeeds.append(ConversationSeed(
                        key: "opencode:\(id)", id: id, app: .opencode,
                        title: nonEmpty(session.title) ?? fallbackTitle,
                        project: projectResolver.resolve(rawPath: session.directory, source: .cwd),
                        gitBranch: nonEmpty(session.branch), sourcePath: databaseURL.path,
                        includesSubtasks: false, cacheCreationAvailable: true
                    ))
                }
                state.sessions[id] = session
            }
            result.newState = state
            result.isComplete = true
            return (result, nil)
        } catch {
            // 部分查询成功也不能提交部分贡献或签名；下轮从原状态重试。
            return (Result(newState: previous, error: "OpenCode database read failed: \(error)"),
                    (error as? ReadFailure)?.code)
        }
    }

    private nonisolated struct Source {
        var messageTable: String
        var sessionTable: String
        var isV2: Bool
        var hasWorkspaceID: Bool
        var hasSessionUpdated: Bool
    }

    private nonisolated struct ReadFailure: Error, CustomStringConvertible {
        var detail: String
        /// SQLite 错误码；数据内容不合法等非 SQLite 失败为 nil。
        var code: Int32?
        var description: String { detail }
    }

    private nonisolated static func source(
        _ db: OpaquePointer, messageTable: String, sessionTable: String, isV2: Bool
    ) throws -> Source? {
        let messages = try columns(db, table: messageTable)
        let sessions = try columns(db, table: sessionTable)
        guard !messages.isEmpty || !sessions.isEmpty else { return nil }
        var required: Set<String> = ["id", "session_id", "time_created", "time_updated", "data"]
        if isV2 { required.insert("type") }
        guard messages.isSuperset(of: required),
              sessions.isSuperset(of: ["id", "title", "directory"])
        else { throw ReadFailure(detail: "unsupported \(messageTable) schema") }
        return Source(messageTable: messageTable, sessionTable: sessionTable, isV2: isV2,
                      hasWorkspaceID: sessions.contains("workspace_id"),
                      hasSessionUpdated: sessions.contains("time_updated"))
    }

    private nonisolated static func readSessions(
        _ db: OpaquePointer, source: Source, hasBranch: Bool, into sessions: inout [String: SessionState]
    ) throws {
        let branch = hasBranch && source.hasWorkspaceID ? "w.branch" : "NULL"
        let join = hasBranch && source.hasWorkspaceID ? "LEFT JOIN workspace w ON w.id = s.workspace_id" : ""
        let updated = source.hasSessionUpdated ? "s.time_updated" : "0"
        let sql = """
        SELECT s.id, s.title, s.directory, \(branch), \(updated),
               COUNT(m.id), COALESCE(MAX(m.time_updated), 0), COALESCE(SUM(m.time_updated), 0),
               COALESCE(MAX(m.time_created), 0)
        FROM \(source.sessionTable) s
        LEFT JOIN \(source.messageTable) m ON m.session_id = s.id
        \(join)
        GROUP BY s.id
        """
        try rows(db, sql: sql) { stmt in
            guard let id = columnText(stmt, 0) else { throw ReadFailure(detail: "missing session ID") }
            let signature = MessageSignature(count: sqlite3_column_int64(stmt, 5),
                                             updated: sqlite3_column_int64(stmt, 6),
                                             updatedSum: sqlite3_column_int64(stmt, 7),
                                             created: sqlite3_column_int64(stmt, 8))
            var state = sessions[id] ?? SessionState(directory: "", updated: 0)
            if source.isV2 { state.v2 = signature } else { state.legacy = signature }
            // v2 元数据优先；空 title / directory 可沿用旧版。
            state.title = nonEmpty(columnText(stmt, 1)) ?? state.title
            state.directory = nonEmpty(columnText(stmt, 2)) ?? state.directory
            state.branch = nonEmpty(columnText(stmt, 3)) ?? state.branch
            state.updated = max(state.updated, sqlite3_column_int64(stmt, 4))
            sessions[id] = state
        }
    }

    private nonisolated static func columns(_ db: OpaquePointer, table: String) throws -> Set<String> {
        var result: Set<String> = []
        try rows(db, sql: "PRAGMA table_info(\(table))") { stmt in
            if let name = columnText(stmt, 1) { result.insert(name) }
        }
        return result
    }

    private nonisolated static func rows(
        _ db: OpaquePointer, sql: String, sessionID: String? = nil,
        body: (OpaquePointer) throws -> Void
    ) throws {
        guard let stmt = prepare(db, sql: sql, bind: { stmt in
            if let sessionID { sqlite3_bind_text(stmt, 1, sessionID, -1, sqliteTransient) }
        }) else { throw ReadFailure(detail: String(cString: sqlite3_errmsg(db)), code: sqlite3_errcode(db)) }
        defer { sqlite3_finalize(stmt) }
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            try autoreleasepool { try body(stmt) }
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else { throw ReadFailure(detail: String(cString: sqlite3_errmsg(db)), code: sqlite3_errcode(db)) }
    }

    private nonisolated static func execute(_ db: OpaquePointer, sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw ReadFailure(detail: String(cString: sqlite3_errmsg(db)), code: sqlite3_errcode(db))
        }
    }

    private nonisolated static func legacyTitle(_ db: OpaquePointer, sessionID: String) throws -> String? {
        guard try columns(db, table: "part").isSuperset(of: ["session_id", "time_created", "id", "data"]) else {
            return nil
        }
        var title: String?
        try rows(db, sql: "SELECT data FROM part WHERE session_id = ?1 ORDER BY time_created, id LIMIT 1",
                 sessionID: sessionID) { stmt in
            if let data = columnText(stmt, 0),
               let json = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
               json["type"] as? String == "text" {
                title = ConversationTitleIndex.clean(json["text"] as? String)
            }
        }
        return title
    }

    /// SQLITE_TRANSIENT 是 C 宏，Swift 中须经 unsafeBitCast 表达「SQLite 自行拷贝文本」。
    private nonisolated static let sqliteTransient: sqlite3_destructor_type =
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private nonisolated static func prepare(
        _ db: OpaquePointer,
        sql: String,
        bind: (OpaquePointer) -> Void
    ) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        bind(stmt)
        return stmt
    }

    private nonisolated static func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    private nonisolated static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// v1 使用 providerID/modelID，v2 嵌套 model 使用 providerID/id。
    /// 标签格式 `providerID/modelID`；variant 不拼入。
    private nonisolated static func parseModel(_ value: Any?) -> String? {
        let dict = value as? [String: Any]
        guard let providerID = dict?["providerID"] as? String, !providerID.isEmpty,
              let modelID = (dict?["modelID"] ?? dict?["id"]) as? String, !modelID.isEmpty else { return nil }
        return "\(providerID)/\(modelID)"
    }

    private nonisolated static func makeEntry(
        conversationID: String,
        model: String,
        timestamp: Date,
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheWrite: Int,
        totalTokens: Int,
        cost: Decimal?
    ) -> UsageEntry {
        let breakdown = Pricing.resolveCostBreakdown(
            app: .opencode,
            model: model,
            speed: .standard,
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheCreation: cacheWrite,
            totalTokens: totalTokens,
            reportedCost: cost,
            reportedBreakdown: nil,
            at: timestamp
        )
        return UsageEntry(
            app: .opencode,
            conversationKey: "opencode:\(conversationID)",
            model: model,
            speed: .standard,
            day: UsageDay.startOfDay(for: timestamp),
            timestamp: timestamp,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheWrite,
            requestCount: 1,
            costUSD: breakdown?.total,
            costBreakdown: breakdown
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
}
