import XCTest
@testable import CCBar

/// PiJSONLScanner 脱敏 fixture 测试：全量解析、增量 watermark、跨文件去重、compaction 计入。
final class PiJSONLScannerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = Self.canonicalTempDirectory("pi-scan-test")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    /// enumerator 返回的 URL 是 realpath 形式（/var → /private/var），
    /// 测试目录统一规范化，避免路径前缀差异导致比较失败。
    private static func canonicalTempDirectory(_ name: String) -> URL {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        return raw.path.withCString { cpath in
            guard let resolved = realpath(cpath, nil) else { return raw }
            defer { free(resolved) }
            return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        }
    }

    private func write(_ name: String, _ content: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        // 真实 pi 会话文件每行（含末行）都以 \n 结尾；JSONLLineReader 依赖整行消费。
        try (content + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let header = #"{"type":"session","version":3,"id":"019fc5c5-db1f-7e9a-acbd-6762c05e364e","timestamp":"2026-08-03T03:58:26.079Z","cwd":"/Users/nanvon/Code/cc-bar"}"#

    private func assistantLine(
        id: String,
        timestamp: String = "2026-08-03T03:58:27.906Z",
        input: Int = 100,
        output: Int = 50,
        cacheRead: Int = 20,
        cacheWrite: Int = 0,
        costTotal: Double? = 0.0017,
        provider: String = "deepseek",
        model: String = "deepseek-v4-flash"
    ) -> String {
        let costPart: String
        if let costTotal {
            costPart = #","cost":{"input":0.001,"output":0.0005,"cacheRead":0.0002,"cacheWrite":0,"total":\#(costTotal)}"#
        } else {
            costPart = ""
        }
        return """
        {"type":"message","id":"\(id)","parentId":null,"timestamp":"\(timestamp)","message":{"role":"assistant","content":[{"type":"text","text":"hi"}],"provider":"\(provider)","model":"\(model)","usage":{"input":\(input),"output":\(output),"cacheRead":\(cacheRead),"cacheWrite":\(cacheWrite),"totalTokens":\(input + output + cacheRead + cacheWrite)\(costPart)},"stopReason":"stop","timestamp":1784270307906}}
        """
    }

    private func userLine(id: String, text: String) -> String {
        #"{"type":"message","id":"\#(id)","parentId":null,"timestamp":"2026-08-03T03:58:26.500Z","message":{"role":"user","content":"\#(text)"}}"#
    }

    // MARK: - 全量扫描

    func testDirectoryEnumeratorReturnsMetadataAndAppliesMinimumMtime() throws {
        let oldFile = try write("old.jsonl", header)
        let newFile = try write("new.jsonl", header + "\n" + userLine(id: "a1b2c3d1", text: "hello"))
        try "ignored".write(
            to: tempDir.appendingPathComponent("ignored.txt"),
            atomically: true,
            encoding: .utf8
        )
        let oldDate = Date(timeIntervalSince1970: 1_000)
        let newDate = Date(timeIntervalSince1970: 2_000)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldFile.path)
        try FileManager.default.setAttributes([.modificationDate: newDate], ofItemAtPath: newFile.path)

        let all = JSONLDirectoryEnumerator.files(at: tempDir)
        XCTAssertEqual(Set(all.map(\.url)), Set([oldFile, newFile]))
        XCTAssertEqual(
            all.first(where: { $0.url == oldFile })?.size,
            UInt64(try Data(contentsOf: oldFile).count)
        )
        XCTAssertEqual(all.first(where: { $0.url == newFile })?.modificationTime, newDate.timeIntervalSince1970)

        let recent = JSONLDirectoryEnumerator.files(
            at: tempDir,
            minimumMtime: Date(timeIntervalSince1970: 1_500)
        )
        XCTAssertEqual(recent.map(\.url), [newFile])
    }

    func testFullScanParsesAssistantMessagesAndSeed() throws {
        let content = [
            header,
            userLine(id: "a1b2c3d1", text: "帮我重构一下登录模块"),
            assistantLine(id: "a1b2c3d2"),
            assistantLine(id: "a1b2c3d3", input: 200, output: 80, cacheRead: 0, costTotal: 0.001),
        ].joined(separator: "\n")
        try write("2026-08-03T03-58-26-079Z_019fc5c5-db1f-7e9a-acbd-6762c05e364e.jsonl", content)

        let result = PiJSONLScanner.scan(previous: [:], seenEntryIds: [], root: tempDir)

        XCTAssertEqual(result.entries.count, 2)
        let first = result.entries[0]
        XCTAssertEqual(first.app, .pi)
        XCTAssertEqual(first.conversationKey, "pi:019fc5c5-db1f-7e9a-acbd-6762c05e364e")
        XCTAssertEqual(first.model, "deepseek/deepseek-v4-flash")
        XCTAssertEqual(first.speed, .standard)
        XCTAssertEqual(first.inputTokens, 100)
        XCTAssertEqual(first.outputTokens, 50)
        XCTAssertEqual(first.cacheReadTokens, 20)
        XCTAssertEqual(first.cacheCreationTokens, 0)
        XCTAssertEqual(first.costUSD, Decimal(string: "0.0017"))
        XCTAssertEqual(first.costBreakdown?.total, Decimal(string: "0.0017"))

        let second = result.entries[1]
        XCTAssertEqual(second.inputTokens, 200)
        XCTAssertEqual(second.outputTokens, 80)

        XCTAssertEqual(result.conversationSeeds.count, 1)
        let seed = result.conversationSeeds[0]
        XCTAssertEqual(seed.key, "pi:019fc5c5-db1f-7e9a-acbd-6762c05e364e")
        XCTAssertEqual(seed.title, "帮我重构一下登录模块")
        XCTAssertEqual(seed.project.name, "cc-bar")
        // source 取决于测试机文件系统（cwd 为真实 git 仓库时是 .gitRoot），只验证 name。

        XCTAssertEqual(result.newState.count, 1)
        XCTAssertEqual(result.newSeenIds.count, 2)
    }

    func testPositiveLoggedCostWinsOverPricingTable() throws {
        let content = [
            header,
            assistantLine(
                id: "a1b2c3e0",
                input: 1_000,
                output: 1_000,
                costTotal: 0.123456,
                provider: "openai-codex",
                model: "gpt-5.5-codex"
            ),
        ].joined(separator: "\n")
        try write("2026-08-03T03-58-26-079Z_019fc5c5-db1f-7e9a-acbd-6762c05e364e.jsonl", content)

        let result = PiJSONLScanner.scan(previous: [:], seenEntryIds: [], root: tempDir)
        let entry = try XCTUnwrap(result.entries.first)

        XCTAssertEqual(entry.costUSD, Decimal(string: "0.123456"))
        XCTAssertEqual(entry.costBreakdown?.total, Decimal(string: "0.123456"))
        XCTAssertNotEqual(entry.costUSD, Pricing.cost(
            app: .pi,
            model: entry.model,
            speed: .standard,
            input: entry.inputTokens,
            output: entry.outputTokens,
            cacheRead: entry.cacheReadTokens,
            cacheCreation: entry.cacheCreationTokens,
            at: entry.timestamp
        ))
    }

    func testLoggedCostFloatTailPreservesComponentBreakdown() throws {
        let content = [
            header,
            assistantLine(
                id: "a1b2c3e5",
                costTotal: 0.0017000000000000001
            ),
        ].joined(separator: "\n")
        try write("2026-08-03T03-58-26-079Z_019fc5c5-db1f-7e9a-acbd-6762c05e364e.jsonl", content)

        let result = PiJSONLScanner.scan(previous: [:], seenEntryIds: [], root: tempDir)
        let entry = try XCTUnwrap(result.entries.first)
        let breakdown = try XCTUnwrap(entry.costBreakdown)

        XCTAssertEqual(breakdown.input, Decimal(string: "0.001"))
        XCTAssertEqual(breakdown.cacheRead, Decimal(string: "0.0002"))
        XCTAssertGreaterThan(breakdown.output, 0)
        XCTAssertEqual(breakdown.total, Decimal(string: "0.0017000000000000001"))
        XCTAssertEqual(entry.costUSD, breakdown.total)
    }

    func testZeroOrMissingLoggedCostFallsBackToSharedPricing() throws {
        let content = [
            header,
            assistantLine(
                id: "a1b2c3e1",
                input: 1_000,
                output: 1_000,
                costTotal: 0,
                provider: "openai-codex",
                model: "gpt-5.5-codex"
            ),
            assistantLine(
                id: "a1b2c3e2",
                input: 1_000,
                output: 1_000,
                costTotal: nil,
                provider: "openai-codex",
                model: "gpt-5.5-codex"
            ),
        ].joined(separator: "\n")
        try write("2026-08-03T03-58-26-079Z_019fc5c5-db1f-7e9a-acbd-6762c05e364e.jsonl", content)

        let result = PiJSONLScanner.scan(previous: [:], seenEntryIds: [], root: tempDir)
        XCTAssertEqual(result.entries.count, 2)

        // gpt-5.5-codex 标准价：input $5 / output $30 / cacheRead $0.50 每百万 token。
        // assistantLine 默认还带 20 个 cacheRead token，总价 0.005 + 0.03 + 0.00001。
        let expected = Decimal(string: "0.03501")
        for entry in result.entries {
            XCTAssertEqual(entry.costUSD, expected)
            XCTAssertEqual(entry.costBreakdown?.total, expected)
        }
    }

    func testUnknownModelKeepsTokensAndShowsZeroCost() throws {
        let content = [
            header,
            assistantLine(
                id: "a1b2c3e3",
                input: 100,
                output: 50,
                costTotal: nil,
                provider: "ccbar-test-provider",
                model: "ccbar-test-model-without-price-019fc5c5"
            ),
        ].joined(separator: "\n")
        try write("2026-08-03T03-58-26-079Z_019fc5c5-db1f-7e9a-acbd-6762c05e364e.jsonl", content)

        let result = PiJSONLScanner.scan(previous: [:], seenEntryIds: [], root: tempDir)
        let entry = try XCTUnwrap(result.entries.first)

        XCTAssertEqual(entry.inputTokens, 100)
        XCTAssertEqual(entry.outputTokens, 50)
        XCTAssertNil(entry.costUSD)
        XCTAssertNil(entry.costBreakdown)
    }

    func testZeroCostZeroTokenMessageIsSkipped() throws {
        let content = [
            header,
            assistantLine(
                id: "a1b2c3e4",
                input: 0,
                output: 0,
                cacheRead: 0,
                cacheWrite: 0,
                costTotal: 0
            ),
        ].joined(separator: "\n")
        try write("2026-08-03T03-58-26-079Z_019fc5c5-db1f-7e9a-acbd-6762c05e364e.jsonl", content)

        let result = PiJSONLScanner.scan(previous: [:], seenEntryIds: [], root: tempDir)
        XCTAssertTrue(result.entries.isEmpty)
    }

    // MARK: - 增量扫描

    func testIncrementalScanSkipsUnchangedFileAndPicksUpAppends() throws {
        let initial = [
            header,
            userLine(id: "a1b2c3d1", text: "hello"),
            assistantLine(id: "a1b2c3d2"),
        ].joined(separator: "\n")
        let url = try write("2026-08-03T03-58-26-079Z_019fc5c5-db1f-7e9a-acbd-6762c05e364e.jsonl", initial)

        let first = PiJSONLScanner.scan(previous: [:], seenEntryIds: [], root: tempDir)
        XCTAssertEqual(first.entries.count, 1)

        // 文件未变化 → 无新条目
        let second = PiJSONLScanner.scan(previous: first.newState, seenEntryIds: first.newSeenIds, root: tempDir)
        XCTAssertEqual(second.entries.count, 0)
        XCTAssertEqual(second.linesParsed, 0)

        // 追加一条 assistant 消息 → 只解析新增行
        sleep(1)
        var appended = initial
        appended += "\n" + assistantLine(id: "a1b2c3d3", output: 30, costTotal: 0.0005)
        try (appended + "\n").write(to: url, atomically: true, encoding: .utf8)

        let third = PiJSONLScanner.scan(previous: second.newState, seenEntryIds: second.newSeenIds, root: tempDir)
        XCTAssertEqual(third.entries.count, 1)
        XCTAssertEqual(third.entries[0].outputTokens, 30)
        XCTAssertEqual(third.entries[0].costUSD, Decimal(string: "0.0005"))
    }

    // MARK: - 跨文件去重（fork / clone 复制旧行）

    func testForkCopyDoesNotDoubleCount() throws {
        let line = assistantLine(id: "a1b2c3d2")
        let original = [
            header,
            userLine(id: "a1b2c3d1", text: "hello"),
            line,
            // 原文件独有的消息，保证两个会话都有 ≥1 条用量（去重归属不依赖文件枚举顺序）
            assistantLine(id: "a1b2c3d5", costTotal: 0.0009),
        ].joined(separator: "\n")
        try write("2026-08-03T03-58-26-079Z_019fc5c5-db1f-7e9a-acbd-6762c05e364e.jsonl", original)
        // fork 出的新会话文件复制了旧行（同 entry id + ISO timestamp）
        let forkHeader = #"{"type":"session","version":3,"id":"019fc5d0-aaaa-4bbb-8ccc-000000000000","timestamp":"2026-08-03T04:00:00.000Z","cwd":"/Users/nanvon/Code/cc-bar","parentSession":"/original/path.jsonl"}"#
        let fork = [
            forkHeader,
            userLine(id: "a1b2c3d1", text: "hello"),
            line,
            assistantLine(id: "e1f2a3b4", costTotal: 0.001),
        ].joined(separator: "\n")
        try write("2026-08-03T04-00-00-000Z_019fc5d0-aaaa-4bbb-8ccc-000000000000.jsonl", fork)

        let result = PiJSONLScanner.scan(previous: [:], seenEntryIds: [], root: tempDir)

        // 重复的 a1b2c3d2 只计一次：2 个文件共 4 条 assistant，去重后 3 条
        XCTAssertEqual(result.entries.count, 3)
        let conversations = Set(result.entries.map(\.conversationKey))
        XCTAssertEqual(conversations, ["pi:019fc5c5-db1f-7e9a-acbd-6762c05e364e", "pi:019fc5d0-aaaa-4bbb-8ccc-000000000000"])
    }

    // MARK: - compaction / branch_summary 计入

    func testCompactionUsageCounted() throws {
        let compaction = #"{"type":"compaction","id":"f6g7h8i9","parentId":"a1b2c3d2","timestamp":"2026-08-03T04:10:00.000Z","summary":"...","tokensBefore":50000,"usage":{"input":3000,"output":200,"cacheRead":500,"cacheWrite":0,"totalTokens":3700,"cost":{"input":0.01,"output":0.002,"cacheRead":0.001,"cacheWrite":0,"total":0.013}}}"#
        let branchSummary = #"{"type":"branch_summary","id":"g7h8i9j0","parentId":"a1b2c3d1","timestamp":"2026-08-03T04:15:00.000Z","fromId":"a1b2c3d2","summary":"...","usage":{"input":100,"output":50,"cacheRead":0,"cacheWrite":0,"totalTokens":150,"cost":{"input":0.001,"output":0.0005,"cacheRead":0,"cacheWrite":0,"total":0.0015}}}"#
        let content = [
            header,
            userLine(id: "a1b2c3d1", text: "hello"),
            assistantLine(id: "a1b2c3d2"),
            compaction,
            branchSummary,
        ].joined(separator: "\n")
        try write("2026-08-03T03-58-26-079Z_019fc5c5-db1f-7e9a-acbd-6762c05e364e.jsonl", content)

        let result = PiJSONLScanner.scan(previous: [:], seenEntryIds: [], root: tempDir)

        XCTAssertEqual(result.entries.count, 3)
        let totalTokens = result.entries.reduce(0) { $0 + $1.inputTokens + $1.outputTokens + $1.cacheReadTokens + $1.cacheCreationTokens }
        XCTAssertEqual(totalTokens, 170 + 3700 + 150)
        let totalCost = result.entries.reduce(Decimal(0)) { $0 + ($1.costUSD ?? 0) }
        XCTAssertEqual(totalCost, Decimal(string: "0.0017")! + Decimal(string: "0.013")! + Decimal(string: "0.0015")!)
        // compaction / branch_summary 沿用最近 assistant 的模型标签
        XCTAssertTrue(result.entries.dropFirst().allSatisfy { $0.model == "deepseek/deepseek-v4-flash" })
    }

    // MARK: - 非 assistant 消息忽略

    func testIgnoresToolResultAndOtherEntryTypes() throws {
        let toolResult = #"{"type":"message","id":"c3d4e5f6","parentId":"a1b2c3d2","timestamp":"2026-08-03T03:58:28.000Z","message":{"role":"toolResult","toolCallId":"call_1","toolName":"bash","content":[{"type":"text","text":"ok"}],"isError":false,"timestamp":1784270308000}}"#
        let modelChange = #"{"type":"model_change","id":"d4e5f6g7","parentId":"c3d4e5f6","timestamp":"2026-08-03T03:59:00.000Z","provider":"deepseek","modelId":"deepseek-v4-flash"}"#
        let content = [
            header,
            userLine(id: "a1b2c3d1", text: "hello"),
            assistantLine(id: "a1b2c3d2"),
            toolResult,
            modelChange,
        ].joined(separator: "\n")
        try write("2026-08-03T03-58-26-079Z_019fc5c5-db1f-7e9a-acbd-6762c05e364e.jsonl", content)

        let result = PiJSONLScanner.scan(previous: [:], seenEntryIds: [], root: tempDir)

        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.linesParsed, 5)
    }

    // MARK: - JSONLTimestamp 手写解析与 formatter 等价

    /// 手写 fast 路径必须与 ISO8601DateFormatter(.withInternetDateTime) 逐一对拍一致，
    /// 包括 fast 不认识的形状（缺时区、缺小数、空格分隔、闰秒）要交回 formatter
    /// 并保持其拒绝语义，不能比 formatter 更宽容。
    func testJSONLTimestampParseMatchesISO8601Formatter() {
        let shapes: [String] = [
            "2026-08-03T03:58:26.079Z",
            "2026-08-03T03:58:26Z",
            "2026-08-03T03:58:26z",
            "2026-08-03T03:58:26.079+08:00",
            "2026-08-03T03:58:26.079+0800",
            "2026-08-03T03:58:26-05:30",
            "2026-08-03T03:58:26.123456789+08:00",
            "2024-02-29T12:00:00Z",
            "2016-12-31T23:59:59Z",
            "2016-12-31T23:59:60Z",
            "2026-08-03T03:58:26",
            "2026-08-03T03:58:26.079",
            "2026-08-03 03:58:26Z",
            "2026-08-03T03:58",
            "2026-08-03T03:58:60Z",
            "2021-02-29T12:00:00Z",
        ]
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fractional.timeZone = TimeZone(secondsFromGMT: 0)
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        plain.timeZone = TimeZone(secondsFromGMT: 0)

        for s in shapes {
            let expected = fractional.date(from: s) ?? plain.date(from: s)
            let actual = JSONLTimestamp.parse(s)
            // ISO8601DateFormatter 小数秒只解析到毫秒，fast 路径保留到纳秒；
            // 毫秒级一致即视为等价（fast 只是更精确，不构成行为差异）。
            XCTAssertEqual(
                actual?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude,
                expected?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude,
                accuracy: 0.001,
                "时间戳 [\(s)] 与 ISO8601DateFormatter 结果不一致"
            )
        }
    }

    /// 手写解析的语义抽查：epoch 值、时区偏移换算、闰日、拒绝缺时区与闰秒。
    func testJSONLTimestampParseSemantics() throws {
        let utc = try XCTUnwrap(JSONLTimestamp.parse("2026-08-03T03:58:26.079Z"))
        XCTAssertEqual(utc.timeIntervalSince1970, 1_785_729_506.079, accuracy: 0.000_5)

        let noFraction = try XCTUnwrap(JSONLTimestamp.parse("2026-08-03T03:58:26Z"))
        XCTAssertEqual(noFraction.timeIntervalSince1970, 1_785_729_506, accuracy: 0.000_5)

        // +08:00 与 +0800 两种写法等价，且表示同一时刻的本地早 8 小时。
        let plusColon = try XCTUnwrap(JSONLTimestamp.parse("2026-08-03T03:58:26.079+08:00"))
        let plusBare = try XCTUnwrap(JSONLTimestamp.parse("2026-08-03T03:58:26.079+0800"))
        XCTAssertEqual(plusColon, plusBare)
        XCTAssertEqual(utc.timeIntervalSince1970 - plusColon.timeIntervalSince1970, 8 * 3_600, accuracy: 0.000_5)

        // 负时区向 UTC 以西。
        let minus = try XCTUnwrap(JSONLTimestamp.parse("2026-08-03T03:58:26.079-05:30"))
        XCTAssertEqual(utc.timeIntervalSince1970 - minus.timeIntervalSince1970, -5.5 * 3_600, accuracy: 0.000_5)

        // 闰日有效；缺时区与闰秒被拒绝（与 withInternetDateTime 一致）。
        XCTAssertNotNil(JSONLTimestamp.parse("2024-02-29T12:00:00Z"))
        XCTAssertNil(JSONLTimestamp.parse("2026-08-03T03:58:26"))
        XCTAssertNil(JSONLTimestamp.parse("2016-12-31T23:59:60Z"))
    }
}
