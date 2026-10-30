import XCTest
import SQLite3
@testable import CCBar

/// AntigravityScanner 的 SQLite + protobuf fixture 测试：生成行与重试计数、step 去重、
/// 模型推断、时间回退、增量签名、多根副本去重、坏库保留，以及对话贡献替换和 Gemini 价格。
final class AntigravityScannerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-scan-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Protobuf 编码

    private enum PB {
        static func varint(_ value: UInt64) -> [UInt8] {
            var value = value
            var bytes: [UInt8] = []
            while value >= 0x80 {
                bytes.append(UInt8(value & 0x7f) | 0x80)
                value >>= 7
            }
            bytes.append(UInt8(value))
            return bytes
        }

        static func int(_ number: Int, _ value: UInt64) -> [UInt8] {
            varint(UInt64(number) << 3) + varint(value)
        }

        static func bytes(_ number: Int, _ value: [UInt8]) -> [UInt8] {
            varint(UInt64(number) << 3 | 2) + varint(UInt64(value.count)) + value
        }

        static func text(_ number: Int, _ value: String) -> [UInt8] {
            bytes(number, Array(value.utf8))
        }

        static func timestamp(_ number: Int, _ seconds: UInt64) -> [UInt8] {
            bytes(number, int(1, seconds))
        }

        /// `ModelUsageStats`：2 未缓存输入、3 输出、4 缓存写入、5 缓存读取、11 响应 ID。
        static func usage(
            input: UInt64, output: UInt64, cacheRead: UInt64 = 0, cacheCreation: UInt64 = 0,
            responseID: String? = nil, modelID: UInt64? = nil
        ) -> [UInt8] {
            var data: [UInt8] = []
            if let modelID { data += int(1, modelID) }
            data += int(2, input) + int(3, output)
            if cacheCreation > 0 { data += int(4, cacheCreation) }
            if cacheRead > 0 { data += int(5, cacheRead) }
            if let responseID { data += text(11, responseID) }
            return data
        }
    }

    // MARK: - Fixture helpers

    private let baseTime: UInt64 = 1_792_000_000 // 2026-10-15 UTC 附近

    private func root(_ name: String) -> URL {
        tempDir.appendingPathComponent(name, isDirectory: true)
    }

    @discardableResult
    private func createDatabase(root: URL, id: String) throws -> OpaquePointer {
        let directory = root.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(id).db")
        var opened: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        let db = opened!
        for sql in [
            "CREATE TABLE IF NOT EXISTS gen_metadata (idx INTEGER PRIMARY KEY, data BLOB)",
            "CREATE TABLE IF NOT EXISTS steps (idx INTEGER PRIMARY KEY, metadata BLOB, step_payload BLOB)",
            "CREATE TABLE IF NOT EXISTS trajectory_metadata_blob (id TEXT PRIMARY KEY, data BLOB)",
        ] {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        }
        return db
    }

    private func insert(_ db: OpaquePointer, _ sql: String, idx: Int64, blob: [UInt8]) {
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
        sqlite3_bind_int64(stmt, 1, idx)
        blob.withUnsafeBytes { pointer in
            _ = sqlite3_bind_blob(stmt, 2, pointer.baseAddress, Int32(blob.count),
                                  unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        sqlite3_finalize(stmt)
    }

    /// 生成行：根字段 1 为调用消息，4 用量、9.4 时间、17 重试、19 模型名、20 键值属性。
    private func insertGeneration(
        _ db: OpaquePointer, idx: Int64, model: String? = nil, usage: [UInt8],
        time: UInt64? = nil, retries: [[UInt8]] = [], attributes: [String: String] = [:],
        streamingDuration: [UInt8]? = nil
    ) {
        var chat: [UInt8] = []
        if let model { chat += PB.text(19, model) }
        chat += PB.bytes(4, usage)
        if let streamingDuration { chat += PB.bytes(12, streamingDuration) }
        if let time { chat += PB.bytes(9, PB.timestamp(4, time)) }
        for retry in retries { chat += PB.bytes(17, PB.bytes(2, retry)) }
        for (key, value) in attributes.sorted(by: { $0.key < $1.key }) {
            chat += PB.bytes(20, PB.text(1, key) + PB.text(2, value))
        }
        insert(db, "INSERT INTO gen_metadata (idx, data) VALUES (?, ?)", idx: idx, blob: PB.bytes(1, chat))
    }

    /// step 元数据：1 时间、9 用量、28 重试。
    private func insertStep(
        _ db: OpaquePointer, idx: Int64, time: UInt64, usage: [UInt8]? = nil, retries: [[UInt8]] = []
    ) {
        var metadata = PB.timestamp(1, time)
        if let usage { metadata += PB.bytes(9, usage) }
        for retry in retries { metadata += PB.bytes(28, PB.bytes(2, retry)) }
        insert(db, "INSERT INTO steps (idx, metadata) VALUES (?, ?)", idx: idx, blob: metadata)
    }

    private func insertTrajectory(_ db: OpaquePointer, workspace: String, branch: String, created: UInt64) {
        let blob = PB.bytes(1, PB.text(1, workspace) + PB.text(4, branch)) + PB.timestamp(2, created)
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO trajectory_metadata_blob (id, data) VALUES ('t', ?)", -1, &stmt, nil), SQLITE_OK)
        blob.withUnsafeBytes { pointer in
            _ = sqlite3_bind_blob(stmt, 1, pointer.baseAddress, Int32(blob.count),
                                  unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        sqlite3_finalize(stmt)
    }

    private func sum(_ entries: [UsageEntry], _ keyPath: KeyPath<UsageEntry, Int>) -> Int {
        entries.reduce(0) { $0 + $1[keyPath: keyPath] }
    }

    func testOutputSpeedUsesStreamingDurationOnlyForMatchingRequest() throws {
        let app = root("antigravity")
        let db = try createDatabase(root: app, id: "timed-conversation")
        let main = PB.usage(input: 100, output: 300, responseID: "main")
        insertGeneration(
            db, idx: 0, model: "gemini-3.8-flash", usage: main, time: baseTime,
            retries: [main, PB.usage(input: 100, output: 1000, responseID: "retry")],
            streamingDuration: PB.int(1, 2) + PB.int(2, 500_000_000)
        )
        insertGeneration(
            db, idx: 1, usage: PB.usage(input: 100, output: 300, responseID: "zero"),
            streamingDuration: []
        )
        insertGeneration(
            db, idx: 2, usage: PB.usage(input: 100, output: 300, responseID: "invalid-nanos"),
            streamingDuration: PB.int(1, 2) + PB.int(2, 1_000_000_000)
        )
        insertGeneration(
            db, idx: 3, usage: PB.usage(input: 100, output: 300, responseID: "too-long"),
            streamingDuration: PB.int(1, 3601)
        )
        sqlite3_close(db)

        let result = AntigravityScanner.scan(previous: nil, roots: [app])
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.entries.count, 5, "同响应去重，独立重试与异常耗时记录仍保留用量")
        XCTAssertEqual(result.entries.filter { $0.timing != nil }.count, 1)
        let timed = try XCTUnwrap(result.entries.first { $0.timing != nil })
        XCTAssertEqual(timed.outputTokens, 300)
        XCTAssertEqual(timed.timing, RequestTiming(firstTokenMs: nil, generationMs: 2500))
        var timing = GenerationTiming.zero
        for entry in result.entries { timing.add(entry.timing, outputTokens: entry.outputTokens) }
        XCTAssertEqual(timing.outputTokensPerSecond, 120)
        XCTAssertNil(timing.averageFirstTokenSeconds)
    }

    // MARK: - 生成行、重试与 step 去重

    func testGUITitleUsesAnnotationsAndUpdatesWithoutDatabaseChanges() throws {
        let app = root("antigravity")
        let db = try createDatabase(root: app, id: "gui-conversation")
        insertGeneration(db, idx: 0, model: "gemini-3.8-flash", usage: PB.usage(input: 100, output: 50), time: baseTime)
        sqlite3_close(db)
        let annotation = app.appendingPathComponent("annotations/gui-conversation.pbtxt")
        try FileManager.default.createDirectory(at: annotation.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"title: "GUI 对话标题""#.utf8).write(to: annotation)
        let first = AntigravityScanner.scan(previous: nil, roots: [app])
        XCTAssertEqual(first.conversationSeeds.first?.title, "GUI 对话标题")
        let unchanged = AntigravityScanner.scan(previous: first.newState, roots: [app])
        XCTAssertTrue(unchanged.entries.isEmpty)

        try Data(#"title: "GUI 中修改后的标题""#.utf8).write(to: annotation)
        let updated = AntigravityScanner.scan(previous: first.newState, roots: [app])
        XCTAssertEqual(updated.refreshedConversationIDs, ["gui-conversation"])
        XCTAssertEqual(updated.conversationSeeds.first?.title, "GUI 中修改后的标题")
        XCTAssertEqual(sum(updated.entries, \.inputTokens), 100, "标题变化只替换原会话贡献")
    }

    func testGUIAnnotationTitleSupportsUnicodeAndProtobufEscapes() {
        XCTAssertEqual(AntigravityScanner.parseAnnotationTitle(Data(#"title: "修复 \"登录\"\n问题""#.utf8)), "修复 \"登录\" 问题")
        XCTAssertEqual(AntigravityScanner.parseAnnotationTitle(Data(#"title: "\344\270\255\346\226\207""#.utf8)), "中文")
        XCTAssertNil(AntigravityScanner.parseAnnotationTitle(Data(#"title: "\777""#.utf8)))
        XCTAssertNil(AntigravityScanner.parseAnnotationTitle(Data(#"archived: true"#.utf8)))
    }

    func testGUITitleWritesTriggerUsageRefreshWithoutWatchingSQLiteSharedMemory() {
        let matcher = UsageLogPathMatcher.standard()
        let app = AntigravityScanner.defaultRoots()[0]
        for path in ["annotations/conversation.pbtxt", "agyhub_summaries_proto.pb", "conversation_summaries.db-wal"] {
            XCTAssertTrue(matcher.matches(app.appendingPathComponent(path).path))
        }
        XCTAssertFalse(matcher.matches(app.appendingPathComponent("conversation_summaries.db-shm").path))
        XCTAssertFalse(matcher.matches(app.appendingPathComponent("settings.json").path))
    }

    func testGUIAutomaticSummaryTitlesDoNotRequireCLIAndOnlyChangedTitleIsRescanned() throws {
        let app = root("antigravity")
        for id in ["gui-a", "gui-b"] {
            let db = try createDatabase(root: app, id: id)
            insertGeneration(db, idx: 0, usage: PB.usage(input: 10, output: 5), time: baseTime)
            sqlite3_close(db)
        }
        func summary(_ title: String) -> Data {
            Data(PB.bytes(1, PB.text(1, "gui-a") + PB.bytes(2, PB.text(1, title)))
                 + PB.bytes(1, PB.text(1, "gui-b") + PB.bytes(2, PB.text(1, "另一个 GUI 对话"))))
        }
        let url = app.appendingPathComponent("agyhub_summaries_proto.pb")
        try summary("GUI 自动标题").write(to: url)
        let first = AntigravityScanner.scan(previous: nil, roots: [app])
        XCTAssertEqual(first.conversationSeeds.first { $0.id == "gui-a" }?.title, "GUI 自动标题")
        try summary("已更新的 GUI 自动标题").write(to: url)
        let updated = AntigravityScanner.scan(previous: first.newState, roots: [app])
        XCTAssertEqual(updated.refreshedConversationIDs, ["gui-a"])
        XCTAssertEqual(updated.conversationSeeds.first?.title, "已更新的 GUI 自动标题")
    }

    func testGenerationRetriesAndStepOnlyRetriesCountOnce() throws {
        let app = root("antigravity-cli")
        let db = try createDatabase(root: app, id: "conv-1")
        insertGeneration(
            db, idx: 0, model: "gemini-3.8-flash-high",
            usage: PB.usage(input: 100, output: 50, cacheRead: 200, responseID: "r1"),
            time: baseTime,
            retries: [PB.usage(input: 10, output: 5, responseID: "r1-retry")]
        )
        // step 0 与生成行是同一次调用（同响应 ID），不能再计一次。
        insertStep(db, idx: 0, time: baseTime, usage: PB.usage(input: 100, output: 50, cacheRead: 200, responseID: "r1"))
        // step 1 的重试只在 step 里出现，要补计。
        insertStep(db, idx: 1, time: baseTime + 60, retries: [PB.usage(input: 7, output: 3, responseID: "r2-retry")])
        // 没有 ID 的 step 用量无法和生成行区分，不计。
        insertStep(db, idx: 2, time: baseTime + 120, usage: PB.usage(input: 999, output: 999))
        sqlite3_close(db)

        let result = AntigravityScanner.scan(previous: nil, roots: [app])
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.failedDatabaseCount, 0)
        XCTAssertEqual(result.refreshedConversationIDs, ["conv-1"])
        XCTAssertEqual(result.entries.count, 3)
        XCTAssertEqual(sum(result.entries, \.inputTokens), 117)
        XCTAssertEqual(sum(result.entries, \.outputTokens), 58)
        XCTAssertEqual(sum(result.entries, \.cacheReadTokens), 200)
        XCTAssertEqual(Set(result.entries.map(\.model)), ["gemini-3.8-flash"])
        XCTAssertTrue(result.entries.allSatisfy { $0.app == .antigravity && $0.conversationKey == "antigravity:conv-1" })
        XCTAssertTrue(result.entries.allSatisfy { $0.costUSD != nil }, "gemini-3.8-flash 应有本地价")
    }

    func testOutputFallsBackToThinkingPlusResponse() throws {
        let app = root("antigravity")
        let db = try createDatabase(root: app, id: "conv-1")
        // 字段 3 缺失时用 9 思考 + 10 正文。
        let usage = PB.int(2, 40) + PB.int(9, 30) + PB.int(10, 12) + PB.text(11, "r1")
        insertGeneration(db, idx: 0, model: "gemini-3.1-pro", usage: usage, time: baseTime)
        sqlite3_close(db)

        let result = AntigravityScanner.scan(previous: nil, roots: [app])
        XCTAssertEqual(result.entries.first?.outputTokens, 42)
        XCTAssertEqual(result.entries.first?.inputTokens, 40)
    }

    // MARK: - 模型推断

    func testModelResolutionPrefersConcreteNameThenIDsThenDisplayName() {
        XCTAssertEqual(AntigravityScanner.resolveModel(
            name: "gemini-3.7-flash-thinking", modelID: 1418, placeholder: nil, displayName: nil
        ), "gemini-3.7-flash")
        XCTAssertEqual(AntigravityScanner.resolveModel(
            name: "gemini-pro-default", modelID: 1418, placeholder: nil, displayName: nil
        ), "gemini-4-argon")
        XCTAssertEqual(AntigravityScanner.resolveModel(
            name: nil, modelID: nil, placeholder: "MODEL_PLACEHOLDER_M318", displayName: nil
        ), "gemini-3.8-flash")
        XCTAssertEqual(AntigravityScanner.resolveModel(
            name: "gemini-internal-model", modelID: nil, placeholder: nil, displayName: "Gemini 3.8 Flash (High)"
        ), "gemini-3.8-flash")
        XCTAssertEqual(AntigravityScanner.resolveModel(
            name: nil, modelID: 246, placeholder: nil, displayName: nil
        ), "gemini-2.5-pro")
        XCTAssertEqual(AntigravityScanner.resolveModel(
            name: "gemini-pro-default", modelID: nil, placeholder: nil, displayName: nil
        ), "gemini-3.1-pro")
        XCTAssertNil(AntigravityScanner.resolveModel(
            name: "gemini-internal-model", modelID: nil, placeholder: nil, displayName: nil
        ))
    }

    func testLaterRowsInheritModelWhenNameIsMissing() throws {
        let app = root("antigravity")
        let db = try createDatabase(root: app, id: "conv-1")
        insertGeneration(db, idx: 0, model: "gemini-3.6-flash",
                         usage: PB.usage(input: 1, output: 1, responseID: "r1"), time: baseTime)
        insertGeneration(db, idx: 1, usage: PB.usage(input: 2, output: 2, responseID: "r2"), time: baseTime + 1)
        sqlite3_close(db)

        let result = AntigravityScanner.scan(previous: nil, roots: [app])
        XCTAssertEqual(result.entries.map(\.model), ["gemini-3.6-flash", "gemini-3.6-flash"])
    }

    // MARK: - 时间、项目与标题

    func testTimestampFallsBackToLinkedStepThenConversationCreation() throws {
        let app = root("antigravity")
        let db = try createDatabase(root: app, id: "conv-1")
        insertTrajectory(db, workspace: "file:///tmp/ag-project", branch: "main", created: baseTime - 3600)
        insertStep(db, idx: 4, time: baseTime + 500)
        insertGeneration(db, idx: 0, model: "gemini-3.1-pro", usage: PB.usage(input: 1, output: 1, responseID: "r1"),
                         attributes: ["last_step_index": "4"])
        insertGeneration(db, idx: 1, model: "gemini-3.1-pro", usage: PB.usage(input: 1, output: 1, responseID: "r2"))
        sqlite3_close(db)

        let result = AntigravityScanner.scan(previous: nil, roots: [app])
        let byTime = Dictionary(grouping: result.entries, by: { $0.timestamp.timeIntervalSince1970 })
        XCTAssertNotNil(byTime[Double(baseTime + 500)], "有关联 step 时用 step 时间")
        XCTAssertNotNil(byTime[Double(baseTime - 3600)], "都没有时用对话创建时间")
        XCTAssertEqual(result.conversationSeeds.count, 1)
        XCTAssertEqual(result.conversationSeeds.first?.gitBranch, "main")
        XCTAssertEqual(result.conversationSeeds.first?.key, "antigravity:conv-1")
    }

    // MARK: - 增量与副本

    func testUnchangedConversationIsSkippedAndChangedOneIsFullyReread() throws {
        let app = root("antigravity")
        let db = try createDatabase(root: app, id: "conv-1")
        insertGeneration(db, idx: 0, model: "gemini-3.1-pro",
                         usage: PB.usage(input: 10, output: 1, responseID: "r1"), time: baseTime)
        sqlite3_close(db)

        let first = AntigravityScanner.scan(previous: nil, roots: [app])
        let state = try JSONDecoder().decode(
            AntigravityScanner.State.self,
            from: JSONEncoder().encode(try XCTUnwrap(first.newState))
        )
        let unchanged = AntigravityScanner.scan(previous: state, roots: [app])
        XCTAssertTrue(unchanged.isComplete)
        XCTAssertTrue(unchanged.entries.isEmpty)
        XCTAssertTrue(unchanged.refreshedConversationIDs.isEmpty)
        XCTAssertEqual(unchanged.databasesRead, 0)
        XCTAssertEqual(unchanged.newState, first.newState)

        let db2 = try createDatabase(root: app, id: "conv-1")
        insertGeneration(db2, idx: 1, model: "gemini-3.1-pro",
                         usage: PB.usage(input: 20, output: 2, responseID: "r2"), time: baseTime + 10)
        sqlite3_close(db2)
        let changed = AntigravityScanner.scan(previous: state, roots: [app])
        XCTAssertEqual(changed.refreshedConversationIDs, ["conv-1"])
        // 变化的对话整段重读，返回完整贡献而不是增量。
        XCTAssertEqual(changed.entries.count, 2)
        XCTAssertEqual(sum(changed.entries, \.inputTokens), 30)
    }

    func testSameConversationInTwoRootsCountsOnce() throws {
        for name in ["antigravity", "antigravity-ide"] {
            let db = try createDatabase(root: root(name), id: "conv-1")
            insertGeneration(db, idx: 0, model: "gemini-3.1-pro",
                             usage: PB.usage(input: 10, output: 1, responseID: "r1"), time: baseTime)
            sqlite3_close(db)
        }
        let result = AntigravityScanner.scan(previous: nil, roots: [root("antigravity"), root("antigravity-ide")])
        XCTAssertEqual(result.databasesRead, 2)
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.newState?.conversations["conv-1"]?.count, 2)
    }

    func testUnreadableDatabaseIsCountedAndRetriedNextScan() throws {
        let app = root("antigravity")
        let directory = app.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: directory.appendingPathComponent("broken.db"))

        let result = AntigravityScanner.scan(previous: nil, roots: [app])
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.failedDatabaseCount, 1)
        XCTAssertTrue(result.refreshedConversationIDs.isEmpty)
        XCTAssertNil(result.newState?.conversations["broken"], "读失败不记签名，下一轮重试")
    }

    // MARK: - 对话贡献替换

    @MainActor
    func testReplacementKeepsConversationsWhoseDatabaseWasDeleted() throws {
        let app = root("antigravity")
        for (id, input) in [("conv-a", UInt64(10)), ("conv-b", UInt64(100))] {
            let db = try createDatabase(root: app, id: id)
            insertGeneration(db, idx: 0, model: "gemini-3.1-pro",
                             usage: PB.usage(input: input, output: 1, responseID: "\(id)-r1"), time: baseTime)
            sqlite3_close(db)
        }
        let daily = UsageAggregator()
        let conversations = ConversationAggregator()
        let first = AntigravityScanner.scan(previous: nil, roots: [app])
        XCTAssertTrue(UsageService.applyAntigravityScan(first, aggregator: daily, conversations: conversations))

        try FileManager.default.removeItem(
            at: app.appendingPathComponent("conversations/conv-b.db", isDirectory: false)
        )
        let db = try createDatabase(root: app, id: "conv-a")
        insertGeneration(db, idx: 1, model: "gemini-3.1-pro",
                         usage: PB.usage(input: 5, output: 1, responseID: "conv-a-r2"), time: baseTime + 1)
        sqlite3_close(db)
        let second = AntigravityScanner.scan(previous: first.newState, roots: [app])
        XCTAssertEqual(second.refreshedConversationIDs, ["conv-a"])
        XCTAssertTrue(UsageService.applyAntigravityScan(second, aggregator: daily, conversations: conversations))

        let input = daily.snapshot().filter { $0.app == .antigravity }.reduce(0) { $0 + $1.inputTokens }
        XCTAssertEqual(input, 115, "conv-a 替换为 15，已删除的 conv-b 保留 100")
        let keys = Set(conversations.snapshot().buckets.filter { $0.app == .antigravity }.map(\.conversationKey))
        XCTAssertEqual(keys, ["antigravity:conv-a", "antigravity:conv-b"])

        let unchanged = AntigravityScanner.scan(previous: second.newState, roots: [app])
        XCTAssertFalse(UsageService.applyAntigravityScan(unchanged, aggregator: daily, conversations: conversations))
    }

    // MARK: - Gemini 价格

    private func utc(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func inputCost(_ model: String, tokens: Int, at date: Date) -> Double? {
        Pricing.cost(app: .antigravity, model: model, speed: .standard, input: tokens, output: 0,
                     cacheRead: 0, cacheCreation: 0, at: date)
            .map { NSDecimalNumber(decimal: $0).doubleValue }
    }

    func testGemini4ArgonPromoEndsOnDecemberFirst() {
        XCTAssertEqual(inputCost("gemini-4-argon", tokens: 1_000_000, at: utc(2026, 11, 30)) ?? -1, 2, accuracy: 1e-9)
        XCTAssertEqual(inputCost("gemini-4-argon", tokens: 1_000_000, at: utc(2026, 12, 1)) ?? -1, 4, accuracy: 1e-9)
    }

    func testGemini25ProUsesLongContextAbove200K() {
        // 100K 走短上下文 $1.25 / 1M，1M 走长上下文 $2.50 / 1M。
        XCTAssertEqual(inputCost("gemini-2.5-pro", tokens: 100_000, at: utc(2026, 10, 19)) ?? -1, 0.125, accuracy: 1e-9)
        XCTAssertEqual(inputCost("gemini-2.5-pro", tokens: 1_000_000, at: utc(2026, 10, 19)) ?? -1, 2.5, accuracy: 1e-9)
    }

    func testNewGeminiModelsArePriced() {
        let expected: [String: Double] = [
            "gemini-3-flash-preview": 0.50,
            "gemini-3.5-flash-lite": 0.30,
            "gemini-3.1-flash-lite": 0.25,
            "gemini-2.5-flash": 0.30,
            "gemini-2.5-flash-lite": 0.10,
        ]
        for (model, rate) in expected {
            XCTAssertEqual(inputCost(model, tokens: 1_000_000, at: utc(2026, 10, 19)) ?? -1, rate, accuracy: 1e-9, model)
        }
    }
}
