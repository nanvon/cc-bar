import XCTest
import SQLite3
@testable import CCBar

/// 历史保护与安全恢复的测试隔离环境。
///
/// 所有生产路径都走真实 `UsageService` / `UsageSnapshotStore`，只通过依赖注入换掉目录与
/// 日志根：临时根下建 `support/`（Application Support 替代）、`cache/`（Caches 替代）、
/// 各来源日志目录。真实 `~/Library/...`、`~/.codex`、`~/.claude`、`~/.pi`、`~/.dsh`
/// 与 OpenCode 库不会被读写。
@MainActor
final class UsageTestEnvironment {
    let root: URL
    let supportDirectory: URL
    let cacheDirectory: URL
    let faults = UsageSnapshotStore.FaultInjector()
    let stats = UsageSnapshotStore.CommitStats()
    private(set) var store: UsageSnapshotStore!
    var appState = AppState()

    var historyDirectory: URL {
        supportDirectory.appendingPathComponent("usage-history", isDirectory: true)
    }

    var claudeRoot: URL { root.appendingPathComponent("claude-projects", isDirectory: true) }
    var codexSessionsRoot: URL { root.appendingPathComponent("codex-sessions", isDirectory: true) }
    var codexArchivedRoot: URL { root.appendingPathComponent("codex-archived", isDirectory: true) }
    var piRoot: URL { root.appendingPathComponent("pi-sessions", isDirectory: true) }
    var dshRoot: URL { root.appendingPathComponent("dsh-sessions", isDirectory: true) }
    var opencodeDatabaseURL: URL { root.appendingPathComponent("opencode.db", isDirectory: false) }
    /// 个人历史补录文件位置：指向临时目录下一个不存在的文件，保证测试不读用户真实补录。
    var backfillURL: URL { root.appendingPathComponent("imported-usage-backfill.json", isDirectory: false) }
    /// Cursor 远端缓存目录：临时目录，避免读写用户真实缓存。
    var cursorCacheDirectory: URL { root.appendingPathComponent("cursor-cache", isDirectory: true) }

    var legacyLocations: LegacyUsageHistoryLocations {
        LegacyUsageHistoryLocations(
            supportDirectory: supportDirectory,
            cacheDirectory: cacheDirectory
        )
    }

    init(name: String) throws {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        root = raw.path.withCString { path in
            guard let resolved = realpath(path, nil) else { return raw }
            defer { free(resolved) }
            return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        }
        supportDirectory = root.appendingPathComponent("support", isDirectory: true)
        cacheDirectory = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        store = UsageSnapshotStore(directory: historyDirectory, faults: faults, stats: stats)
        // 单测绝不能打真实价格源，也不能让宿主进程留下的远端目录影响计价断言。
        PricingCatalogStore.shared.disableNetworkForTesting()
        PricingCatalogStore.shared.installCatalogForTesting(PricingCatalogCachePayload())
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    var scanRoots: UsageScanRoots {
        UsageScanRoots(
            claudeRoot: claudeRoot,
            claudeConversationIndex: { ConversationTitleIndex.ClaudeIndex(titles: [:], projects: [:]) },
            codexRoots: [codexSessionsRoot, codexArchivedRoot],
            codexTitles: { [:] },
            piRoot: piRoot,
            opencodeDatabaseURL: opencodeDatabaseURL,
            dshRoot: dshRoot
        )
    }

    func makeService(
        localUsageApps: @escaping @MainActor () -> Set<UsageApp> = { Set(UsageApp.localApps) }
    ) -> UsageService {
        UsageService(
            historyStore: store,
            roots: scanRoots,
            legacyLocations: legacyLocations,
            backfillURL: backfillURL,
            cursorCacheDirectory: cursorCacheDirectory,
            localUsageApps: localUsageApps
        )
    }

    /// 新建一个 service + AppState（模拟重启）。AppState 只承载周期记录与今日费用，
    /// 不调用它自己的 bootstrap，因此不会触发真实采集。
    func makeRestartedService() -> (UsageService, AppState) {
        let state = AppState()
        return (makeService(), state)
    }

    func bootstrap(_ service: UsageService) async {
        await service.bootstrap(appState: appState)
    }

    // MARK: - 价格 fixture

    func installPricing(
        model: String,
        input: Decimal,
        output: Decimal,
        cacheRead: Decimal = 0,
        cacheCreation: Decimal = 0
    ) {
        var payload = PricingCatalogCachePayload()
        payload.liteLLM.fetchedAt = Date()
        payload.liteLLM.standardRates[Pricing.normalize(model: model)] = ModelPrice(
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheCreation: cacheCreation
        )
        PricingCatalogStore.shared.installCatalogForTesting(payload)
    }

    // MARK: - 日志 fixture

    private func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func append(_ text: String, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        let data = Data((text + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url)
        }
    }

    /// Claude assistant 行。`stop_reason` 必填，避免被当成流式半成品跳过。
    func claudeLine(
        id: String,
        session: String,
        model: String,
        timestamp: String,
        input: Int,
        output: Int,
        cacheRead: Int = 0,
        cacheCreation: Int = 0,
        speed: String? = nil
    ) -> String {
        var usage = #""input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":\#(cacheRead),"cache_creation_input_tokens":\#(cacheCreation)"#
        if let speed {
            usage += #","speed":"\#(speed)""#
        }
        return """
        {"type":"assistant","sessionId":"\(session)","cwd":"/tmp/ccbar-fixture","timestamp":"\(timestamp)","message":{"id":"\(id)","model":"\(model)","stop_reason":"end_turn","usage":{\(usage)}}}
        """
    }

    @discardableResult
    func writeClaudeLog(session: String, lines: [String], file: String? = nil) throws -> URL {
        let url = claudeRoot
            .appendingPathComponent("fixture-project", isDirectory: true)
            .appendingPathComponent(file ?? "\(session).jsonl", isDirectory: false)
        try ensureDirectory(url.deletingLastPathComponent())
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    /// Codex 会话文件：session_meta + turn_context + token_count。
    func codexLines(
        id: String,
        model: String,
        timestampPrefix: String,
        input: Int,
        cachedInput: Int,
        output: Int,
        serviceTier: String = "default"
    ) -> [String] {
        let total = input + output
        return [
            #"{"timestamp":"\#(timestampPrefix)Z","type":"session_meta","payload":{"id":"\#(id)","cwd":"/tmp/ccbar-fixture"}}"#,
            #"{"timestamp":"\#(timestampPrefix)Z","type":"turn_context","payload":{"model":"\#(model)"}}"#,
            #"{"timestamp":"\#(timestampPrefix)Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"\#(model)","service_tier":"\#(serviceTier)"}}}"#,
            #"{"timestamp":"\#(timestampPrefix)Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cachedInput),"output_tokens":\#(output),"reasoning_output_tokens":0,"total_tokens":\#(total)},"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cachedInput),"output_tokens":\#(output),"reasoning_output_tokens":0,"total_tokens":\#(total)}}}}"#,
        ]
    }

    @discardableResult
    func writeCodexLog(id: String, lines: [String]) throws -> URL {
        let url = codexSessionsRoot.appendingPathComponent("rollout-\(id).jsonl", isDirectory: false)
        try ensureDirectory(codexSessionsRoot)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    /// pi 会话文件：session 头 + assistant message。
    func piLines(
        session: String,
        entryID: String,
        timestamp: String,
        model: String,
        input: Int,
        output: Int,
        cacheRead: Int = 0,
        cacheWrite: Int = 0
    ) -> [String] {
        [
            #"{"type":"session","version":3,"id":"\#(session)","timestamp":"\#(timestamp)","cwd":"/tmp/ccbar-fixture"}"#,
            #"{"type":"message","id":"\#(entryID)","parentId":null,"timestamp":"\#(timestamp)","message":{"role":"assistant","content":[{"type":"text","text":"hi"}],"provider":"deepseek","model":"\#(model)","usage":{"input":\#(input),"output":\#(output),"cacheRead":\#(cacheRead),"cacheWrite":\#(cacheWrite),"totalTokens":\#(input + output + cacheRead + cacheWrite)},"stopReason":"stop"}}"#,
        ]
    }

    @discardableResult
    func writePiLog(session: String, lines: [String]) throws -> URL {
        let url = piRoot.appendingPathComponent("\(session).jsonl", isDirectory: false)
        try ensureDirectory(piRoot)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    // MARK: - DSH fixture

    @discardableResult
    func writeDshLog(
        project: String,
        session: String,
        file: String = "session.jsonl",
        records: [[String: Any]]
    ) throws -> URL {
        let directory = dshRoot
            .appendingPathComponent(project, isDirectory: true)
            .appendingPathComponent(session, isDirectory: true)
        try ensureDirectory(directory)
        let url = directory.appendingPathComponent(file, isDirectory: false)
        let data = records.map { DshTestFixtures.line($0) }.reduce(into: Data()) { $0.append($1) }
        try data.write(to: url)
        return url
    }

    // MARK: - OpenCode fixture

    @discardableResult
    func openOpencodeDatabase() throws -> OpaquePointer {
        var opened: OpaquePointer?
        guard sqlite3_open_v2(
            opencodeDatabaseURL.path,
            &opened,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        ) == SQLITE_OK, let db = opened else {
            throw UsageTestEnvironmentError.sqliteOpenFailed
        }
        let statements = [
            "CREATE TABLE IF NOT EXISTS project (id TEXT PRIMARY KEY, worktree TEXT NOT NULL, vcs TEXT, name TEXT, time_created INTEGER NOT NULL)",
            "CREATE TABLE IF NOT EXISTS workspace (id TEXT PRIMARY KEY, type TEXT NOT NULL, name TEXT DEFAULT '' NOT NULL, branch TEXT, directory TEXT, extra TEXT, project_id TEXT NOT NULL, time_used INTEGER NOT NULL)",
            "CREATE TABLE IF NOT EXISTS session (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, workspace_id TEXT, title TEXT NOT NULL, cost REAL DEFAULT 0 NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, directory TEXT NOT NULL)",
            "CREATE TABLE IF NOT EXISTS message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL)",
            "CREATE TABLE IF NOT EXISTS part (id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL)",
        ]
        for sql in statements {
            guard let db = opened else { break }
            sqlite3_exec(db, sql, nil, nil, nil)
        }
        return db
    }

    func opencodeExec(_ db: OpaquePointer, _ sql: String, _ args: [Any]) {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK, let stmt = prepared else {
            XCTFail("sqlite prepare failed: \(sql)")
            return
        }
        for (index, arg) in args.enumerated() {
            let position = Int32(index + 1)
            switch arg {
            case let value as String:
                sqlite3_bind_text(stmt, position, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case let value as Int:
                sqlite3_bind_int64(stmt, position, Int64(value))
            default:
                XCTFail("unsupported fixture arg \(arg)")
            }
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            XCTFail("sqlite step failed: \(sql)")
            sqlite3_finalize(stmt)
            return
        }
        sqlite3_finalize(stmt)
    }

    func insertOpencodeSession(
        _ db: OpaquePointer,
        id: String,
        title: String,
        directory: String = "/tmp/ccbar-fixture",
        timeCreated: Int = 1_786_075_934_005
    ) {
        opencodeExec(
            db,
            "INSERT INTO session (id, project_id, workspace_id, title, time_created, time_updated, directory) VALUES (?, 'p1', 'ws-1', ?, ?, ?, ?)",
            [id, title, timeCreated, timeCreated, directory]
        )
    }

    func insertOpencodeMessage(
        _ db: OpaquePointer,
        id: String,
        sessionID: String,
        timeCreated: Int,
        timeUpdated: Int? = nil,
        data: String
    ) {
        opencodeExec(
            db,
            "INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?)",
            [id, sessionID, timeCreated, timeUpdated ?? timeCreated, data]
        )
    }

    func opencodeAssistantData(
        input: Int,
        output: Int,
        reasoning: Int = 0,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        cost: Double?,
        providerID: String? = "opencode-go",
        modelID: String? = "ccbar-test-model"
    ) -> String {
        // 形状取自 v1 真实消息：`time.completed` 是入账前提，用量在顶层 `tokens`，
        // legacy 的模型从顶层 `providerID` / `modelID` 解析。
        let total = input + output + reasoning + cacheRead + cacheWrite
        let modelPart: String
        if let providerID, let modelID {
            modelPart = #","providerID":"\#(providerID)","modelID":"\#(modelID)""#
        } else {
            modelPart = ""
        }
        let costPart = cost.map { "\"cost\":\($0)," } ?? ""
        return "{\"role\":\"assistant\",\"time\":{\"completed\":1786075934005},\(costPart)\"tokens\":{\"total\":\(total),\"input\":\(input),\"output\":\(output),\"reasoning\":\(reasoning),\"cache\":{\"write\":\(cacheWrite),\"read\":\(cacheRead)}}\(modelPart)}"
    }

    /// 把日志与 OpenCode 库从另一个隔离环境拷过来（模拟「同一台机器，换了存储/缓存」）。
    func copySources(from other: UsageTestEnvironment) throws {
        let fileManager = FileManager.default
        for (source, destination) in [
            (other.claudeRoot, claudeRoot),
            (other.codexSessionsRoot, codexSessionsRoot),
            (other.codexArchivedRoot, codexArchivedRoot),
            (other.piRoot, piRoot),
            (other.dshRoot, dshRoot),
        ] where fileManager.fileExists(atPath: source.path) {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
        }
        if fileManager.fileExists(atPath: other.opencodeDatabaseURL.path) {
            try fileManager.copyItem(at: other.opencodeDatabaseURL, to: opencodeDatabaseURL)
        }
        // 旧文件 / 快照目录不拷贝：由调用方自己决定要写哪些。
    }

    // MARK: - 断言辅助

    /// 完整键集合 + 分项用量 + 请求数；费用不参与（价格变化是重算的正常结果）。
    func dayVector(_ buckets: [UsageBucket]) -> [UsageVectorKey: UsageVectorCounts] {
        UsageHistoryConsistency.dayVector(buckets)
    }

    func conversationVector(_ buckets: [ConversationUsageBucket]) -> [ConversationVectorKey: UsageVectorCounts] {
        UsageHistoryConsistency.conversationVector(buckets)
    }

    func dayCost(_ buckets: [UsageBucket], app: UsageApp? = nil) -> Decimal {
        buckets.filter { app == nil || $0.app == app }.reduce(Decimal(0)) { $0 + $1.costUSD }
    }

    func totals(_ buckets: [UsageBucket], app: UsageApp? = nil) -> UsageTotals {
        var result = UsageTotals.zero
        for bucket in buckets where app == nil || bucket.app == app {
            result.add(bucket)
        }
        return result
    }

    func fileBytes(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    /// 只读副本：把某个真实文件复制到临时目录用于测试，不修改原文件。
    func legacyPath(_ name: String) -> URL {
        supportDirectory.appendingPathComponent(name, isDirectory: false)
    }

    func cachePath(_ name: String) -> URL {
        cacheDirectory.appendingPathComponent(name, isDirectory: false)
    }
}

nonisolated enum UsageTestEnvironmentError: Error {
    case sqliteOpenFailed
}
