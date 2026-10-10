import XCTest
import SQLite3
@testable import CCBar

/// OpencodeScanner 的 SQLite fixture 测试：全量解析、会话增量、迁移去重、
/// reasoning 并入 output、日志价格优先与统一 Pricing 补算、空标题 part 兜底、项目与 branch。
final class OpencodeScannerTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-scan-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("opencode.db")
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Fixture helpers

    /// 创建与 OpenCode 一致的 session / message / part / workspace / project 表结构。
    @discardableResult
    private func createSchema() throws -> OpaquePointer {
        var opened: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(dbURL.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        let db = opened!
        let statements = [
            "CREATE TABLE IF NOT EXISTS project (id TEXT PRIMARY KEY, worktree TEXT NOT NULL, vcs TEXT, name TEXT, time_created INTEGER NOT NULL)",
            "CREATE TABLE IF NOT EXISTS workspace (id TEXT PRIMARY KEY, type TEXT NOT NULL, name TEXT DEFAULT '' NOT NULL, branch TEXT, directory TEXT, extra TEXT, project_id TEXT NOT NULL, time_used INTEGER NOT NULL)",
            "CREATE TABLE IF NOT EXISTS session (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, workspace_id TEXT, title TEXT NOT NULL, cost REAL DEFAULT 0 NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, directory TEXT NOT NULL)",
            "CREATE TABLE IF NOT EXISTS message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL)",
            "CREATE TABLE IF NOT EXISTS part (id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL)",
        ]
        for sql in statements {
            var stmt: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
            sqlite3_finalize(stmt)
        }
        return db
    }

    private func exec(_ db: OpaquePointer, _ sql: String, _ args: [Any]) {
        var prepared: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &prepared, nil), SQLITE_OK)
        let stmt = prepared!
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case let s as String:
                sqlite3_bind_text(stmt, idx, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case let i as Int: sqlite3_bind_int64(stmt, idx, Int64(i))
            case let d as Double: sqlite3_bind_double(stmt, idx, d)
            default: XCTFail("unsupported fixture arg \(arg)")
            }
        }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        sqlite3_finalize(stmt)
    }

    private func insertSession(
        _ db: OpaquePointer,
        id: String,
        title: String,
        directory: String,
        workspace: String? = "ws-1",
        timeCreated: Int = 1_786_075_934_005
    ) {
        exec(db, "INSERT INTO session (id, project_id, workspace_id, title, time_created, time_updated, directory) VALUES (?, 'p1', ?, ?, ?, ?, ?)",
             [id, workspace ?? "", title, timeCreated, timeCreated, directory])
    }

    private func insertMessage(
        _ db: OpaquePointer,
        id: String,
        sessionID: String,
        timeCreated: Int,
        data: String
    ) {
        exec(db, "INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?)",
             [id, sessionID, timeCreated, timeCreated, data])
    }

    private func insertPart(
        _ db: OpaquePointer,
        id: String,
        messageID: String,
        sessionID: String,
        timeCreated: Int,
        data: String
    ) {
        exec(db, "INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?, ?)",
             [id, messageID, sessionID, timeCreated, timeCreated, data])
    }

    private func userMessageData(modelID: String = "deepseek-v4-flash", providerID: String = "opencode-go") -> String {
        #"{"role":"user","time":{"created":1786075934005},"agent":"build","model":{"providerID":"\#(providerID)","modelID":"\#(modelID)","variant":"max"},"summary":{"diffs":[]}}"#
    }

    private func assistantMessageData(
        cost: Double? = 0.00148148,
        input: Int = 10_546,
        output: Int = 18,
        reasoning: Int = 0,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        providerID: String? = "opencode-go",
        modelID: String? = "deepseek-v4-flash"
    ) -> String {
        let total = input + output + reasoning + cacheRead + cacheWrite
        let modelPart: String
        if let providerID, let modelID {
            modelPart = #","providerID":"\#(providerID)","modelID":"\#(modelID)""#
        } else {
            modelPart = ""
        }
        let costPart = cost.map { "\"cost\":\($0),"} ?? ""
        return "{\"role\":\"assistant\",\"time\":{\"completed\":1786075934005},\(costPart)\"tokens\":{\"total\":\(total),\"input\":\(input),\"output\":\(output),\"reasoning\":\(reasoning),\"cache\":{\"write\":\(cacheWrite),\"read\":\(cacheRead)}}\(modelPart)}"
    }

    private func scan() -> OpencodeScanner.Result {
        OpencodeScanner.scan(previous: nil, databaseURL: dbURL)
    }

    // MARK: - 全量扫描

    func testFullScanParsesModelTokensAndCost() throws {
        let db = try createSchema()
        insertSession(db, id: "ses-1", title: "ccbar 对 OpenCode 用量监测探讨", directory: "/Users/nanvon/Code/cc-bar")
        insertMessage(db, id: "msg-u1", sessionID: "ses-1", timeCreated: 1_786_075_932_000, data: userMessageData())
        insertMessage(db, id: "msg-a1", sessionID: "ses-1", timeCreated: 1_786_075_934_000, data: assistantMessageData())
        insertMessage(db, id: "msg-a2", sessionID: "ses-1", timeCreated: 1_786_075_936_000,
                      data: assistantMessageData(cost: 0.00183008, input: 12_696, output: 137, reasoning: 51))
        sqlite3_close(db)

        let result = scan()

        XCTAssertEqual(result.entries.count, 2)
        XCTAssertEqual(result.newState?.sessions["ses-1"]?.legacy?.created, 1_786_075_936_000)
        XCTAssertEqual(result.newState?.sessions["ses-1"]?.legacy?.count, 3)

        let first = result.entries[0]
        XCTAssertEqual(first.app, .opencode)
        XCTAssertEqual(first.conversationKey, "opencode:ses-1")
        // 模型标签从最近 user 消息继承。
        XCTAssertEqual(first.model, "opencode-go/deepseek-v4-flash")
        XCTAssertEqual(first.speed, .standard)
        XCTAssertEqual(first.inputTokens, 10_546)
        XCTAssertEqual(first.outputTokens, 18)
        XCTAssertEqual(first.cacheReadTokens, 0)
        XCTAssertEqual(first.cacheCreationTokens, 0)
        XCTAssertEqual(first.costUSD, Decimal(string: "0.00148148"))
        // 有效日志总价优先，不能被本地或在线价格表覆盖；分项总额必须与其一致。
        XCTAssertEqual(first.costBreakdown?.total, Decimal(string: "0.00148148"))
        XCTAssertGreaterThan(first.costBreakdown?.input ?? 0, 0)
        XCTAssertGreaterThan(first.costBreakdown?.output ?? 0, 0)
        XCTAssertNotEqual(first.costBreakdown?.output, first.costUSD)

        // reasoning 并入 output：137 + 51 = 188。
        let second = result.entries[1]
        XCTAssertEqual(second.outputTokens, 188)
        XCTAssertEqual(second.inputTokens, 12_696)

        // seed：官方标题 + 项目路径归一。
        XCTAssertEqual(result.conversationSeeds.count, 1)
        let seed = result.conversationSeeds[0]
        XCTAssertEqual(seed.key, "opencode:ses-1")
        XCTAssertEqual(seed.app, .opencode)
        XCTAssertEqual(seed.title, "ccbar 对 OpenCode 用量监测探讨")
        XCTAssertEqual(seed.project.path, "/Users/nanvon/Code/cc-bar")
        XCTAssertEqual(seed.project.status, .available)
    }

    func testZeroOrMissingCostFallsBackToSharedPricing() throws {
        let db = try createSchema()
        insertSession(db, id: "ses-1", title: "T1", directory: "/tmp/a")
        insertMessage(
            db,
            id: "msg-a1",
            sessionID: "ses-1",
            timeCreated: 1_786_075_934_000,
            data: assistantMessageData(
                cost: 0,
                input: 1_000,
                output: 1_000,
                providerID: "openai-codex",
                modelID: "gpt-5.5-codex"
            )
        )
        insertMessage(
            db,
            id: "msg-a2",
            sessionID: "ses-1",
            timeCreated: 1_786_075_936_000,
            data: assistantMessageData(
                cost: nil,
                input: 1_000,
                output: 1_000,
                providerID: "openai-codex",
                modelID: "gpt-5.5-codex"
            )
        )
        sqlite3_close(db)

        let result = scan()
        XCTAssertEqual(result.entries.count, 2)

        let expected = Decimal(string: "0.035")
        for entry in result.entries {
            XCTAssertEqual(entry.costUSD, expected)
            XCTAssertEqual(entry.costBreakdown?.total, expected)
        }
    }

    func testMissingCostForUnknownModelKeepsTokensAndShowsZeroCost() throws {
        let db = try createSchema()
        insertSession(db, id: "ses-1", title: "T1", directory: "/tmp/a")
        insertMessage(
            db,
            id: "msg-a1",
            sessionID: "ses-1",
            timeCreated: 1_786_075_934_000,
            data: assistantMessageData(
                cost: nil,
                input: 100,
                output: 50,
                providerID: "ccbar-test-provider",
                modelID: "ccbar-test-model-without-price-019fc5c5"
            )
        )
        sqlite3_close(db)

        let result = scan()
        let entry = try XCTUnwrap(result.entries.first)

        XCTAssertEqual(entry.inputTokens, 100)
        XCTAssertEqual(entry.outputTokens, 50)
        XCTAssertNil(entry.costUSD)
        XCTAssertNil(entry.costBreakdown)
    }

    // MARK: - 增量扫描

    func testIncrementalScanReplacesChangedSession() throws {
        let db = try createSchema()
        insertSession(db, id: "ses-1", title: "T1", directory: "/tmp/a")
        insertMessage(db, id: "msg-a1", sessionID: "ses-1", timeCreated: 1_786_075_934_000,
                      data: assistantMessageData())
        sqlite3_close(db)

        let first = OpencodeScanner.scan(previous: nil, databaseURL: dbURL)
        XCTAssertEqual(first.entries.count, 1)
        XCTAssertEqual(first.newState?.sessions["ses-1"]?.legacy?.created, 1_786_075_934_000)

        // 追加新消息后增量扫描。
        let db2 = try createSchema()
        insertMessage(db2, id: "msg-a2", sessionID: "ses-1", timeCreated: 1_786_075_940_000,
                      data: assistantMessageData(cost: 0.0005, input: 100, output: 5))
        sqlite3_close(db2)

        let second = OpencodeScanner.scan(
            previous: first.newState,
            databaseURL: dbURL
        )
        XCTAssertEqual(second.entries.count, 2)
        XCTAssertEqual(second.entries.last?.inputTokens, 100)
        XCTAssertEqual(second.newState?.sessions["ses-1"]?.legacy?.created, 1_786_075_940_000)
        // 产出完整会话，调用方替换贡献。
        XCTAssertEqual(second.refreshedSessionIDs, ["ses-1"])
    }

    // MARK: - 空扫描与缓存恢复

    func testUnchangedSessionDoesNotReadMessagesAfterCacheRestore() throws {
        let db = try createSchema()
        insertSession(db, id: "ses-1", title: "T1", directory: "/tmp/a")
        insertMessage(db, id: "msg-a1", sessionID: "ses-1", timeCreated: 1_786_075_934_000,
                      data: assistantMessageData())
        sqlite3_close(db)
        let first = scan()
        let state = try JSONDecoder().decode(OpencodeScanner.State.self,
                                            from: JSONEncoder().encode(try XCTUnwrap(first.newState)))
        let second = OpencodeScanner.scan(previous: state, databaseURL: dbURL)
        XCTAssertTrue(second.isComplete)
        XCTAssertTrue(second.entries.isEmpty)
        XCTAssertTrue(second.refreshedSessionIDs.isEmpty)
        XCTAssertEqual(second.messagesRead, 0)
        XCTAssertEqual(second.newState, first.newState)
    }

    // MARK: - 增量扫描只追加 assistant 时模型标签不丢失

    func testIncrementalAssistantOnlyKeepsModelLabel() throws {
        let db = try createSchema()
        insertSession(db, id: "ses-1", title: "T1", directory: "/tmp/a")
        insertMessage(db, id: "msg-u1", sessionID: "ses-1", timeCreated: 1_786_075_932_000,
                      data: userMessageData())
        insertMessage(db, id: "msg-a1", sessionID: "ses-1", timeCreated: 1_786_075_934_000,
                      data: assistantMessageData())
        sqlite3_close(db)

        let first = OpencodeScanner.scan(previous: nil, databaseURL: dbURL)
        XCTAssertEqual(first.entries.count, 1)
        XCTAssertEqual(first.entries[0].model, "opencode-go/deepseek-v4-flash")

        // 只追加 assistant 消息（无新 user 消息），且该消息自身带顶层 providerID/modelID。
        let db2 = try createSchema()
        insertMessage(db2, id: "msg-a2", sessionID: "ses-1", timeCreated: 1_786_075_940_000,
                      data: assistantMessageData(cost: 0.0005, input: 100, output: 5))
        sqlite3_close(db2)

        let second = OpencodeScanner.scan(
            previous: first.newState,
            databaseURL: dbURL
        )
        XCTAssertEqual(second.entries.count, 2)
        // 变动会话完整重读；assistant 自身模型字段优先。
        XCTAssertEqual(second.entries[0].model, "opencode-go/deepseek-v4-flash")
        XCTAssertEqual(second.entries.last?.inputTokens, 100)
    }

    // MARK: - 无模型字段的 assistant 回退到会话继承

    func testAssistantWithoutModelFallsBackToSessionModel() throws {
        let db = try createSchema()
        insertSession(db, id: "ses-1", title: "T1", directory: "/tmp/a")
        insertMessage(db, id: "msg-u1", sessionID: "ses-1", timeCreated: 1_786_075_932_000,
                      data: userMessageData())
        insertMessage(db, id: "msg-a1", sessionID: "ses-1", timeCreated: 1_786_075_934_000,
                      data: assistantMessageData(providerID: nil, modelID: nil))
        sqlite3_close(db)

        let result = scan()
        XCTAssertEqual(result.entries.count, 1)
        // 全量扫描继承 user 消息模型；无顶层字段时回退成功。
        XCTAssertEqual(result.entries[0].model, "opencode-go/deepseek-v4-flash")
    }

    // MARK: - cost=0 / total=0 的消息不产生幽灵用量

    func testZeroCostZeroTokenMessageIsSkipped() throws {
        let db = try createSchema()
        insertSession(db, id: "ses-1", title: "T1", directory: "/tmp/a")
        insertMessage(db, id: "msg-u1", sessionID: "ses-1", timeCreated: 1_786_075_932_000,
                      data: userMessageData())
        // 工具调用收尾：官方 cost=0 且 tokens 全 0。
        insertMessage(db, id: "msg-a1", sessionID: "ses-1", timeCreated: 1_786_075_934_000,
                      data: assistantMessageData(cost: 0, input: 0, output: 0, reasoning: 0))
        insertMessage(db, id: "msg-a2", sessionID: "ses-1", timeCreated: 1_786_075_936_000,
                      data: assistantMessageData())
        sqlite3_close(db)

        let result = scan()
        // 只有带真实用量的 msg-a2 入账。
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries[0].costUSD, Decimal(string: "0.00148148"))
    }

    // MARK: - 空标题 part 兜底

    func testEmptyTitleFallsBackToFirstTextPart() throws {
        let db = try createSchema()
        insertSession(db, id: "ses-1", title: "", directory: "/tmp/a")
        insertMessage(db, id: "msg-u1", sessionID: "ses-1", timeCreated: 1_786_075_932_000,
                      data: userMessageData())
        insertPart(db, id: "part-1", messageID: "msg-u1", sessionID: "ses-1", timeCreated: 1_786_075_932_100,
                   data: #"{"type":"text","text":"帮我重构一下登录模块","time":{"created":1786075932100}}"#)
        insertMessage(db, id: "msg-a1", sessionID: "ses-1", timeCreated: 1_786_075_934_000,
                      data: assistantMessageData())
        sqlite3_close(db)

        let result = scan()
        XCTAssertEqual(result.conversationSeeds.count, 1)
        XCTAssertEqual(result.conversationSeeds[0].title, "帮我重构一下登录模块")
    }

    // MARK: - 项目与 branch

    func testProjectAndBranchPropagation() throws {
        let db = try createSchema()
        exec(db, "INSERT INTO project (id, worktree, vcs, time_created) VALUES ('p1', '/Users/nanvon/Code/cc-bar', 'git', 1)", [])
        exec(db, "INSERT INTO workspace (id, type, name, branch, directory, project_id, time_used) VALUES ('ws-1', 'git', 'cc-bar', 'feature/opencode', '/Users/nanvon/Code/cc-bar', 'p1', 1)", [])
        insertSession(db, id: "ses-1", title: "T1", directory: "/Users/nanvon/Code/cc-bar", workspace: "ws-1")
        insertMessage(db, id: "msg-a1", sessionID: "ses-1", timeCreated: 1_786_075_934_000,
                      data: assistantMessageData())
        sqlite3_close(db)

        let result = scan()
        XCTAssertEqual(result.conversationSeeds.count, 1)
        XCTAssertEqual(result.conversationSeeds[0].gitBranch, "feature/opencode")
        XCTAssertEqual(result.conversationSeeds[0].project.path, "/Users/nanvon/Code/cc-bar")
    }

    // MARK: - OpenCode v2 / 迁移共存

    @discardableResult
    private func createV2Schema() throws -> OpaquePointer {
        var opened: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(dbURL.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        let db = opened!
        exec(db, "CREATE TABLE IF NOT EXISTS session_v2 (id TEXT PRIMARY KEY, title TEXT, directory TEXT NOT NULL, time_updated INTEGER NOT NULL)", [])
        exec(db, "CREATE TABLE IF NOT EXISTS session_message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, type TEXT NOT NULL, seq INTEGER NOT NULL DEFAULT 0, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL)", [])
        exec(db, "INSERT OR IGNORE INTO session_v2 VALUES ('ses-1', '', '/tmp/a', 1000)", [])
        return db
    }

    private func v2Assistant(input: Int = 100, completed: Bool = true, cost: Double = 0.25) -> String {
        let time = completed ? #"{"created":1000,"completed":1100}"# : #"{"created":1000}"#
        return #"{"time":\#(time),"model":{"providerID":"opencode-go","id":"deepseek-v4-flash","variant":"default"},"tokens":{"input":\#(input),"output":20,"reasoning":5,"cache":{"read":30,"write":4}},"cost":\#(cost)}"#
    }

    private func insertV2Message(_ db: OpaquePointer, id: String, type: String = "assistant",
                                 created: Int = 1000, updated: Int = 1100, data: String) {
        exec(db, "INSERT INTO session_message (id, session_id, type, time_created, time_updated, data) VALUES (?, 'ses-1', ?, ?, ?, ?)",
             [id, type, created, updated, data])
    }

    func testV2OnlyParsesTypeModelTokensCostAndUserTitle() throws {
        let db = try createV2Schema()
        insertV2Message(db, id: "msg-u1", type: "user", created: 900, data: #"{"text":"v2 title"}"#)
        insertV2Message(db, id: "msg-a1", data: v2Assistant())
        insertV2Message(db, id: "msg-compaction", type: "compaction", data: #"{"summary":"ignored"}"#)
        sqlite3_close(db)
        let result = scan()
        XCTAssertTrue(result.isComplete)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.entries.count, 1)
        let entry = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(entry.model, "opencode-go/deepseek-v4-flash")
        XCTAssertEqual(entry.inputTokens, 100)
        XCTAssertEqual(entry.outputTokens, 25)
        XCTAssertEqual(entry.cacheReadTokens, 30)
        XCTAssertEqual(entry.cacheCreationTokens, 4)
        XCTAssertEqual(entry.costUSD, Decimal(string: "0.25"))
        XCTAssertEqual(entry.costBreakdown?.total, entry.costUSD)
        XCTAssertEqual(result.conversationSeeds.first?.title, "v2 title")
    }

    func testMigratedDatabaseWithoutBranchReadsBothFormatsOnce() throws {
        let db = try createSchema()
        insertSession(db, id: "ses-1", title: "legacy", directory: "/tmp/a")
        insertMessage(db, id: "msg-shared", sessionID: "ses-1", timeCreated: 1000,
                      data: assistantMessageData(input: 999))
        insertMessage(db, id: "msg-legacy", sessionID: "ses-1", timeCreated: 900,
                      data: assistantMessageData(input: 10))
        // v2 的 workspace 表存在，但没有 branch。
        exec(db, "DROP TABLE workspace", [])
        exec(db, "CREATE TABLE workspace (id TEXT PRIMARY KEY, provider TEXT, binding TEXT)", [])
        sqlite3_close(db)
        let db2 = try createV2Schema()
        insertV2Message(db2, id: "msg-shared", data: v2Assistant(input: 100))
        insertV2Message(db2, id: "msg-v2", created: 1200, updated: 1300, data: v2Assistant(input: 20))
        sqlite3_close(db2)
        let result = scan()
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.entries.count, 3)
        XCTAssertEqual(result.entries.reduce(0) { $0 + $1.inputTokens }, 130)
        XCTAssertNil(result.conversationSeeds.first?.gitBranch)
    }

    func testPendingMessageCompletesAfterLaterMessagesHaveBeenScanned() throws {
        let db = try createV2Schema()
        insertV2Message(db, id: "msg-pending", updated: 1000, data: v2Assistant(completed: false))
        insertV2Message(db, id: "msg-later", created: 2000, updated: 2100, data: v2Assistant(input: 20))
        sqlite3_close(db)
        let first = scan()
        XCTAssertEqual(first.entries.count, 1)
        XCTAssertEqual(first.newState?.sessions["ses-1"]?.hasPendingMessages, true)
        let unchanged = OpencodeScanner.scan(previous: first.newState, databaseURL: dbURL)
        XCTAssertEqual(unchanged.messagesRead, 0)
        let db2 = try createV2Schema()
        exec(db2, "UPDATE session_message SET data = ?, time_updated = 1500 WHERE id = 'msg-pending'",
             [v2Assistant()])
        sqlite3_close(db2)
        let second = OpencodeScanner.scan(previous: first.newState, databaseURL: dbURL)
        // 老消息更新仍早于其他消息的 max(time_updated)，SUM 签名也能发现变化。
        XCTAssertEqual(second.entries.count, 2)
        XCTAssertEqual(second.entries.reduce(0) { $0 + $1.inputTokens }, 120)
        XCTAssertEqual(second.newState?.sessions["ses-1"]?.hasPendingMessages, false)
    }

    @MainActor
    func testV1ToV2MigrationReplacesExistingHistoryWithoutDoubleCounting() throws {
        let db = try createSchema()
        insertSession(db, id: "ses-1", title: "legacy", directory: "/tmp/a")
        insertMessage(db, id: "msg-shared", sessionID: "ses-1", timeCreated: 1000,
                      data: assistantMessageData(input: 100))
        sqlite3_close(db)
        let first = scan()
        let daily = UsageAggregator()
        let conversations = ConversationAggregator()
        UsageService.applyOpenCodeScan(first, aggregator: daily, conversations: conversations)
        let db2 = try createV2Schema()
        insertV2Message(db2, id: "msg-shared", data: v2Assistant(input: 100))
        insertV2Message(db2, id: "msg-new", created: 1200, updated: 1300, data: v2Assistant(input: 20))
        sqlite3_close(db2)
        // 模拟已发布旧缓存没有新签名，首轮只重建 OpenCode。
        let migrated = OpencodeScanner.scan(previous: nil, databaseURL: dbURL)
        UsageService.applyOpenCodeScan(migrated, aggregator: daily, conversations: conversations)
        XCTAssertEqual(daily.snapshot().reduce(0) { $0 + $1.inputTokens }, 120)
        XCTAssertEqual(conversations.detail(key: "opencode:ses-1")?.totals.requestCount, 2)
        let unchanged = OpencodeScanner.scan(previous: migrated.newState, databaseURL: dbURL)
        XCTAssertEqual(unchanged.messagesRead, 0)
        XCTAssertFalse(UsageService.applyOpenCodeScan(unchanged, aggregator: daily, conversations: conversations))
    }

    @MainActor
    func testUpdatedContributionReplacesTotalsAndKeepsOtherServicesAndDeletedSessions() throws {
        let db = try createV2Schema()
        insertV2Message(db, id: "msg-a1", data: v2Assistant(input: 100))
        sqlite3_close(db)
        let first = scan()
        let daily = UsageAggregator()
        let conversations = ConversationAggregator()
        XCTAssertTrue(UsageService.applyOpenCodeScan(first, aggregator: daily, conversations: conversations))
        var other = try XCTUnwrap(first.entries.first)
        other.app = .codex
        other.conversationKey = "codex:other"
        daily.ingestLocal([other])
        var deleted = try XCTUnwrap(first.entries.first)
        deleted.conversationKey = "opencode:deleted"
        daily.ingestLocal([deleted])
        var deletedSeed = try XCTUnwrap(first.conversationSeeds.first)
        deletedSeed.key = deleted.conversationKey
        deletedSeed.id = "deleted"
        conversations.ingest(entries: [other, deleted], seeds: [deletedSeed])

        let db2 = try createV2Schema()
        exec(db2, "UPDATE session_message SET data = ?, time_updated = 1200 WHERE id = 'msg-a1'",
             [v2Assistant(input: 200, cost: 0.5)])
        sqlite3_close(db2)
        let second = OpencodeScanner.scan(previous: first.newState, databaseURL: dbURL)
        XCTAssertTrue(UsageService.applyOpenCodeScan(second, aggregator: daily, conversations: conversations))
        let rows = daily.snapshot()
        XCTAssertEqual(rows.filter { $0.app == .opencode }.reduce(0) { $0 + $1.inputTokens }, 300)
        XCTAssertEqual(rows.filter { $0.app == .opencode }.reduce(0) { $0 + $1.requestCount }, 2)
        XCTAssertEqual(rows.filter { $0.app == .opencode }.reduce(Decimal.zero) { $0 + $1.costUSD }, Decimal(string: "0.75"))
        XCTAssertEqual(rows.filter { $0.app == .codex }.reduce(0) { $0 + $1.inputTokens }, 100)
        XCTAssertEqual(conversations.detail(key: "opencode:ses-1")?.totals.inputTokens, 200)
        XCTAssertEqual(conversations.detail(key: "opencode:deleted")?.totals.inputTokens, 100)
        let revision = daily.revision
        XCTAssertFalse(UsageService.applyOpenCodeScan(second, aggregator: daily, conversations: conversations))
        XCTAssertEqual(daily.revision, revision)

        // 同代 rollup 和签名一起恢复后，空扫描不重复计入。
        var state = ScanState(generationID: "same", opencode: second.newState)
        state.codexSeenTokenIds = ["unchanged"]
        try ScanCache.save(state, in: tempDir)
        let snapshot = conversations.snapshot()
        try UsageRollupCache.save(UsageRollupPayload(generationID: "same", buckets: daily.snapshotLocal()), in: tempDir)
        try ConversationRollupCache.save(ConversationRollupPayload(generationID: "same", infos: snapshot.infos,
                                                                 buckets: snapshot.buckets), in: tempDir)
        guard case .valid(let restored) = ScanCache.load(in: tempDir) else { return XCTFail("valid scan state") }
        let restoredDaily = UsageAggregator()
        restoredDaily.load(from: UsageRollupCache.load(in: tempDir).buckets)
        let restoredConversations = ConversationAggregator()
        let restoredRollup = ConversationRollupCache.load(in: tempDir)
        restoredConversations.load(infos: restoredRollup.infos, buckets: restoredRollup.buckets)
        let next = OpencodeScanner.scan(previous: restored.opencode, databaseURL: dbURL)
        XCTAssertFalse(UsageService.applyOpenCodeScan(next, aggregator: restoredDaily, conversations: restoredConversations))
        XCTAssertEqual(restoredDaily.snapshot().filter { $0.app == .opencode }.reduce(0) { $0 + $1.inputTokens }, 300)
    }

    func testLegacyScanCacheLoadsWithoutInvalidatingOtherServices() throws {
        let original = ScanState(generationID: "legacy", codexSeenTokenIds: ["keep"],
                                 opencodeLastMessageTime: 999, opencodeSeenMessageIds: ["msg-old"])
        // 可选字段 nil 编码时不写 opencode，等同已发布 v15 缓存。
        try ScanCache.save(original, in: tempDir)
        guard case .valid(let loaded) = ScanCache.load(in: tempDir) else { return XCTFail("legacy cache must load") }
        XCTAssertNil(loaded.opencode)
        XCTAssertEqual(loaded.codexSeenTokenIds, ["keep"])
        XCTAssertEqual(loaded.generationID, "legacy")
    }

    @MainActor
    func testInvalidSchemaAndPartialReadKeepStateAndExistingTotals() throws {
        let db = try createV2Schema()
        insertV2Message(db, id: "msg-a1", data: v2Assistant())
        sqlite3_close(db)
        let first = scan()
        let daily = UsageAggregator()
        let conversations = ConversationAggregator()
        UsageService.applyOpenCodeScan(first, aggregator: daily, conversations: conversations)
        let before = daily.snapshot()
        let db2 = try createV2Schema()
        insertV2Message(db2, id: "msg-a2", created: 1200, updated: 1300, data: "invalid JSON")
        sqlite3_close(db2)
        let partial = OpencodeScanner.scan(previous: first.newState, databaseURL: dbURL)
        XCTAssertFalse(partial.isComplete)
        XCTAssertTrue(partial.entries.isEmpty)
        XCTAssertNotNil(partial.error)
        XCTAssertEqual(partial.newState, first.newState)
        XCTAssertFalse(UsageService.applyOpenCodeScan(partial, aggregator: daily, conversations: conversations))
        XCTAssertEqual(daily.snapshot(), before)
        let db3 = try createV2Schema()
        exec(db3, "ALTER TABLE session_message RENAME COLUMN time_updated TO changed", [])
        sqlite3_close(db3)
        let invalid = OpencodeScanner.scan(previous: first.newState, databaseURL: dbURL)
        XCTAssertFalse(invalid.isComplete)
        XCTAssertNotNil(invalid.error)
        XCTAssertEqual(invalid.newState, first.newState)
    }

    // MARK: - 失败保留状态

    func testMissingDatabasePreservesState() {
        let previous = OpencodeScanner.State(sourcePath: dbURL.path)
        let result = OpencodeScanner.scan(previous: previous, databaseURL: dbURL)
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.newState, previous)
        XCTAssertNil(result.error)
    }

    func testCorruptDatabasePreservesStateAndReportsError() throws {
        try Data("not a sqlite file".utf8).write(to: dbURL)
        let previous = OpencodeScanner.State(sourcePath: dbURL.path)
        let result = OpencodeScanner.scan(previous: previous, databaseURL: dbURL)
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.newState, previous)
        XCTAssertNotNil(result.error)
    }

    /// OpenCode 退出后 WAL 库只剩主文件；系统 SQLite 只读打开会报 SQLITE_CANTOPEN，需回退 immutable。
    func testCheckpointedWALDatabaseWithoutSidecarsIsReadable() throws {
        let db = try createV2Schema()
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil), SQLITE_OK)
        insertV2Message(db, id: "msg-a1", data: v2Assistant())
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        try? FileManager.default.removeItem(atPath: dbURL.path + "-wal")
        try? FileManager.default.removeItem(atPath: dbURL.path + "-shm")

        let result = scan()
        XCTAssertNil(result.error)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.path + "-wal"))
    }
}
