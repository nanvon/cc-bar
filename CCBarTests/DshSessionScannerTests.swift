import XCTest
@testable import CCBar

/// DshSessionScanner 的脱敏合成 fixture 测试。
///
/// 依据：`docs/草案-DSH本地用量-技术方案.md` §2.3（目录与记录）、§3.2（watermark 与失败处理）、
/// §4.1（子代理父链）、§7 S2（验证）、§8（覆盖清单）。全部走真实字节偏移扫描链路，
/// 日志由 `DshTestFixtures` 用 libzstd 现场编码，不读本机真实会话日志。
final class DshSessionScannerTests: XCTestCase {
    private var logs: DshTempLogRoot!

    override func setUpWithError() throws {
        logs = try DshTempLogRoot(name: "dsh-scanner-test")
    }

    override func tearDownWithError() throws {
        logs = nil
    }

    private func scan(_ previous: [String: ScanFileState] = [:]) -> DshSessionScanner.Result {
        DshSessionScanner.scan(previous: previous, root: logs.root)
    }

    // MARK: - 命名与 generation 选择

    func testCanonicalLogNameRules() {
        XCTAssertEqual(DshSessionScanner.canonicalLogName("session.jsonl.zstd"), .init(version: 0, isZstd: true))
        XCTAssertEqual(DshSessionScanner.canonicalLogName("session.jsonl"), .init(version: 0, isZstd: false))
        XCTAssertEqual(DshSessionScanner.canonicalLogName("session.v3.jsonl.zstd"), .init(version: 3, isZstd: true))
        XCTAssertEqual(DshSessionScanner.canonicalLogName("session.v12.jsonl"), .init(version: 12, isZstd: false))

        // 非规范名一律忽略：大写、v0、前导零、锁文件与临时文件
        XCTAssertNil(DshSessionScanner.canonicalLogName("session.jsonl.ZSTD"))
        XCTAssertNil(DshSessionScanner.canonicalLogName("session.v0.jsonl.zstd"))
        XCTAssertNil(DshSessionScanner.canonicalLogName("session.v01.jsonl.zstd"))
        XCTAssertNil(DshSessionScanner.canonicalLogName("session.jsonl.zstd.lock"))
        XCTAssertNil(DshSessionScanner.canonicalLogName("session.v1.jsonl.zstd.tmp"))
        XCTAssertNil(DshSessionScanner.canonicalLogName("session.v.jsonl"))
        XCTAssertNil(DshSessionScanner.canonicalLogName("other.jsonl"))
    }

    func testPicksHighestGenerationAndIgnoresNonCanonical() throws {
        // v0 与 v2 并存：官方在 migration 后保留旧 generation，必须只读版本号最高的那个
        let old = try DshTestFixtures.log([
            DshTestFixtures.session(id: "s"),
            DshTestFixtures.assistant(time: DshTestFixtures.baseTime, input: 1, output: 1)
        ])
        let new = try DshTestFixtures.log([
            DshTestFixtures.session(id: "s"),
            DshTestFixtures.assistant(time: DshTestFixtures.baseTime, input: 7, output: 3)
        ])
        try logs.write(project: "p", session: "s", file: "session.jsonl.zstd", bytes: old)
        try logs.write(project: "p", session: "s", file: "session.v2.jsonl.zstd", bytes: new)
        try logs.write(project: "p", session: "s", file: "session.V9.jsonl.zstd", bytes: old)
        try logs.write(project: "p", session: "s", file: "session.v09.jsonl.zstd", bytes: old)
        try logs.write(project: "p", session: "s", file: "session.v1.jsonl.zstd.lock", bytes: old)

        let result = scan()
        XCTAssertEqual(result.filesScanned, 1)
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries.first?.inputTokens, 7)
        XCTAssertEqual(result.duplicateEncodingCount, 0)
    }

    func testSameVersionBothEncodingsPrefersZstdAndReportsDuplicate() throws {
        var lines = Data()
        lines.append(DshTestFixtures.line(DshTestFixtures.session(id: "s1")))
        lines.append(DshTestFixtures.line(DshTestFixtures.assistant(time: DshTestFixtures.baseTime, input: 5, output: 5)))
        let zstdBytes = try DshTestFixtures.log(lines: [
            DshTestFixtures.session(id: "s1"),
            DshTestFixtures.assistant(time: DshTestFixtures.baseTime, input: 5, output: 5)
        ])

        try logs.write(project: "p", session: "s", file: "session.v1.jsonl", bytes: lines)
        try logs.write(project: "p", session: "s", file: "session.v1.jsonl.zstd", bytes: zstdBytes)

        let result = scan()
        XCTAssertEqual(result.duplicateEncodingCount, 1, "同版本两种编码并存必须记一次异常")
        XCTAssertEqual(result.entries.count, 1, "固定优先 zstd，明文那份不重复计费")
        XCTAssertEqual(result.entries.first?.inputTokens, 5)
    }

    // MARK: - 明文日志

    func testPlaintextLogIsParsedWithLineWatermark() throws {
        var bytes = Data()
        bytes.append(DshTestFixtures.line(DshTestFixtures.session(id: "plain")))
        bytes.append(DshTestFixtures.line(DshTestFixtures.title("明文会话")))
        bytes.append(DshTestFixtures.line(DshTestFixtures.assistant(time: DshTestFixtures.baseTime, input: 20, output: 4)))
        // 末行不完整：不得消费，也就不得入账
        bytes.append(Data(#"{"type":"assistant/message","time":1780000001000,"data":{"usa"#.utf8))
        try logs.write(project: "p", session: "s", file: "session.jsonl", bytes: bytes)

        let result = scan()
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries.first?.inputTokens, 20)
        XCTAssertEqual(result.failedFileCount, 0)

        let state = try XCTUnwrap(result.newState.values.first)
        XCTAssertEqual(state.conversationID, "plain")
        XCTAssertEqual(state.fallbackTitle, "明文会话")
        XCTAssertLessThan(Int(state.offset), bytes.count, "半截行不得推进 watermark")
    }

    // MARK: - 记录映射

    func testRecordsMapToEntryAndSeed() throws {
        let bytes = try DshTestFixtures.log(lines: [
            DshTestFixtures.session(id: "root-1", cwd: "/Users/tester/Code/demo"),
            DshTestFixtures.title("标题一"),
            DshTestFixtures.assistant(
                time: DshTestFixtures.baseTime,
                provider: "commandcode/deepseek",
                model: "deepseek-v4.1-flash",
                input: 1000,
                output: 200,
                cacheRead: 30,
                cacheWrite: 5
            )
        ])
        try logs.write(project: "p", session: "s", file: "session.v1.jsonl.zstd", bytes: bytes)

        let result = scan()
        let entry = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(entry.app, .dsh)
        XCTAssertEqual(entry.conversationKey, "dsh:root-1")
        // 外层 provider 只加一次
        XCTAssertEqual(entry.model, "commandcode/deepseek/deepseek-v4.1-flash")
        XCTAssertEqual(entry.speed, .standard)
        XCTAssertEqual(entry.inputTokens, 1000, "inputTokens 已排除缓存读写，不再扣减")
        XCTAssertEqual(entry.outputTokens, 200)
        XCTAssertEqual(entry.cacheReadTokens, 30)
        XCTAssertEqual(entry.cacheCreationTokens, 5)
        XCTAssertEqual(entry.requestCount, 1)
        XCTAssertEqual(entry.timestamp, Date(timeIntervalSince1970: DshTestFixtures.baseTime / 1000))
        XCTAssertEqual(entry.day, UsageDay.startOfDay(for: entry.timestamp))

        let seed = try XCTUnwrap(result.conversationSeeds.first)
        XCTAssertEqual(seed.key, "dsh:root-1")
        XCTAssertEqual(seed.id, "root-1")
        XCTAssertEqual(seed.app, .dsh)
        XCTAssertEqual(seed.title, "标题一")
        XCTAssertEqual(seed.project.path, "/Users/tester/Code/demo")
        XCTAssertFalse(seed.includesSubtasks, "子代理归根由贡献缓存决定，扫描器不预先标记")
        XCTAssertTrue(seed.cacheCreationAvailable)
    }

    func testLastValidTitleWins() throws {
        let bytes = try DshTestFixtures.log(lines: [
            DshTestFixtures.session(id: "s"),
            DshTestFixtures.title("旧标题"),
            DshTestFixtures.title("   "),
            DshTestFixtures.title("新标题")
        ])
        try logs.write(project: "p", session: "s", file: "session.v1.jsonl.zstd", bytes: bytes)
        let seed = try XCTUnwrap(scan().conversationSeeds.first)
        XCTAssertEqual(seed.title, "新标题", "空标题不覆盖已有标题，最后一个有效标题胜出")
    }

    func testParentSessionIsPersistedForSubagentFolding() throws {
        let bytes = try DshTestFixtures.log(lines: [
            DshTestFixtures.session(id: "child-1", parentSession: "root-1", delegationDepth: 1)
        ])
        try logs.write(project: "p", session: "s", file: "session.v1.jsonl.zstd", bytes: bytes)
        let state = try XCTUnwrap(scan().newState.values.first)
        XCTAssertEqual(state.conversationParentSession, "root-1")
    }

    func testUsageIsTakenOnceFromEitherLocation() throws {
        // 两处同时存在：只认 data.usage，绝不相加
        let both = DshTestFixtures.assistantWithBoth(
            time: DshTestFixtures.baseTime,
            usage: ["inputTokens": 100, "outputTokens": 50],
            streamUsage: ["inputTokens": 999, "outputTokens": 999]
        )
        // 只有 stream：取最后一个 usage chunk
        let streamOnly = DshTestFixtures.assistant(
            time: DshTestFixtures.baseTime + 1_000,
            input: 40,
            output: 4,
            streamOnly: true
        )
        let bytes = try DshTestFixtures.log(lines: [
            DshTestFixtures.session(id: "s"),
            both,
            streamOnly
        ])
        try logs.write(project: "p", session: "s", file: "session.v1.jsonl.zstd", bytes: bytes)

        let result = scan()
        XCTAssertEqual(result.entries.count, 2)
        XCTAssertEqual(result.entries[0].inputTokens, 100)
        XCTAssertEqual(result.entries[1].inputTokens, 40)
    }

    func testRecordWithoutUsageCountsNeitherTokensNorRequest() throws {
        var record = DshTestFixtures.assistant(time: DshTestFixtures.baseTime)
        var body = record["data"] as? [String: Any] ?? [:]
        body.removeValue(forKey: "usage")
        record["data"] = body

        let bytes = try DshTestFixtures.log(lines: [DshTestFixtures.session(id: "s"), record])
        try logs.write(project: "p", session: "s", file: "session.v1.jsonl.zstd", bytes: bytes)

        let result = scan()
        XCTAssertTrue(result.entries.isEmpty, "两处都缺失时既不计 token 也不计请求")
        XCTAssertEqual(result.failedFileCount, 0, "缺 usage 不是失败")
    }

    func testTotalTokensMismatchIsCountedButNotSummed() throws {
        // totalTokens 是校验字段：与四项之和不一致时只计数，不参与二次求和
        let bytes = try DshTestFixtures.log(lines: [
            DshTestFixtures.session(id: "s"),
            DshTestFixtures.assistant(
                time: DshTestFixtures.baseTime,
                input: 100,
                output: 50,
                cacheRead: 10,
                cacheWrite: 0,
                totalTokens: 999
            )
        ])
        try logs.write(project: "p", session: "s", file: "session.v1.jsonl.zstd", bytes: bytes)

        let result = scan()
        XCTAssertEqual(result.totalTokensMismatchCount, 1)
        XCTAssertEqual(result.entries.first?.inputTokens, 100)
        XCTAssertEqual(result.entries.first?.outputTokens, 50)
    }

    // MARK: - 增量与失败隔离

    func testIncrementalScanOnlyCountsNewFrames() throws {
        let first = try DshTestFixtures.log(lines: [DshTestFixtures.session(id: "s")])
        let second = try DshTestFixtures.frame(DshTestFixtures.line(
            DshTestFixtures.assistant(time: DshTestFixtures.baseTime, input: 10, output: 1)
        ))
        let third = try DshTestFixtures.frame(DshTestFixtures.line(
            DshTestFixtures.assistant(time: DshTestFixtures.baseTime + 1_000, input: 20, output: 2)
        ))

        let url = try logs.write(project: "p", session: "s", file: "session.v1.jsonl.zstd", bytes: first + second)
        let round1 = scan()
        XCTAssertEqual(round1.entries.count, 1)
        XCTAssertEqual(round1.entries.first?.inputTokens, 10)

        // 未变化：整份跳过，不重复计费
        let round2 = scan(round1.newState)
        XCTAssertTrue(round2.entries.isEmpty)

        // 追加一个完整帧：只计新增
        try (first + second + third).write(to: url)
        let round3 = scan(round2.newState)
        XCTAssertEqual(round3.entries.count, 1)
        XCTAssertEqual(round3.entries.first?.inputTokens, 20)
        XCTAssertEqual(round3.entries.first?.conversationKey, "dsh:s", "续扫靠状态里的会话 id 补上下文")
    }

    func testTornTailIsConsumedAfterBytesArrive() throws {
        let head = try DshTestFixtures.log(lines: [DshTestFixtures.session(id: "s")])
        let full = try DshTestFixtures.frame(DshTestFixtures.line(
            DshTestFixtures.assistant(time: DshTestFixtures.baseTime, input: 33, output: 3)
        ))
        let url = try logs.write(
            project: "p",
            session: "s",
            file: "session.v1.jsonl.zstd",
            bytes: head + full.prefix(full.count - 4)
        )

        let round1 = scan()
        XCTAssertTrue(round1.entries.isEmpty, "撕裂尾帧本轮不消费")
        XCTAssertEqual(round1.failedFileCount, 0, "正常撕裂不算失败")
        let state = try XCTUnwrap(round1.newState.values.first)
        XCTAssertEqual(Int(state.offset), head.count, "watermark 落在最后一个完整帧末尾")

        try (head + full).write(to: url)
        let round2 = scan(round1.newState)
        XCTAssertEqual(round2.entries.count, 1, "补齐后正常入账")
        XCTAssertEqual(round2.entries.first?.inputTokens, 33)
    }

    func testCorruptFileIsIsolatedAndKeepsWatermark() throws {
        let good = try DshTestFixtures.log(lines: [
            DshTestFixtures.session(id: "good"),
            DshTestFixtures.assistant(time: DshTestFixtures.baseTime, input: 12, output: 2)
        ])
        try logs.write(project: "p", session: "good", file: "session.v1.jsonl.zstd", bytes: good)

        var broken = try DshTestFixtures.log(lines: [
            DshTestFixtures.session(id: "broken"),
            DshTestFixtures.assistant(time: DshTestFixtures.baseTime, input: 99, output: 9)
        ])
        broken[broken.startIndex + 4] |= 0x08  // 置保留位 → 损坏
        try logs.write(project: "p", session: "broken", file: "session.v1.jsonl.zstd", bytes: broken)

        let result = scan()
        XCTAssertEqual(result.filesScanned, 2)
        XCTAssertEqual(result.failedFileCount, 1)
        XCTAssertEqual(result.entries.map(\.inputTokens), [12], "坏文件整份丢弃，好文件照常入账")

        let brokenPath = logs.root.appendingPathComponent("p/broken/session.v1.jsonl.zstd").path
        let brokenState = try XCTUnwrap(result.newState[brokenPath])
        XCTAssertEqual(brokenState.offset, 0, "损坏不推进 watermark，下轮重试")
    }

    func testTruncatedFileRestartsFromZeroAndIsReported() throws {
        let longer = try DshTestFixtures.log(lines: [
            DshTestFixtures.session(id: "s"),
            DshTestFixtures.assistant(time: DshTestFixtures.baseTime, input: 10, output: 1),
            DshTestFixtures.assistant(time: DshTestFixtures.baseTime + 1_000, input: 20, output: 2)
        ])
        let url = try logs.write(project: "p", session: "s", file: "session.v1.jsonl.zstd", bytes: longer)
        let round1 = scan()
        XCTAssertEqual(round1.entries.count, 2)

        // 原地替换成更短的文件：不能从旧 offset 续读，必须从 0 重扫并请调用方替换该会话贡献
        let shorter = try DshTestFixtures.log(lines: [
            DshTestFixtures.session(id: "s"),
            DshTestFixtures.assistant(time: DshTestFixtures.baseTime + 2_000, input: 7, output: 1)
        ])
        try shorter.write(to: url)

        let round2 = scan(round1.newState)
        XCTAssertEqual(round2.restartedSessionIDs, ["s"])
        XCTAssertEqual(round2.entries.map(\.inputTokens), [7])
    }

    func testSeededForkSkipsInheritedUsage() throws {
        var header = DshTestFixtures.session(id: "child", parentSession: "parent")
        header["isSeeded"] = true
        var inherited = DshTestFixtures.assistant(time: DshTestFixtures.baseTime, input: 100, output: 0)
        inherited["seq"] = 0
        var own = DshTestFixtures.assistant(time: DshTestFixtures.baseTime + 1_000, input: 5, output: 0)
        own["seq"] = 2
        let marker: [String: Any] = ["type": "session/end-seed", "seq": 1, "time": DshTestFixtures.baseTime, "data": ["inherited": true]]
        try logs.write(project: "p", session: "child", file: "session.v3.jsonl.zstd", bytes: try DshTestFixtures.log(lines: [header, inherited, marker, own]))

        let result = scan()
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.entries.map(\.inputTokens), [5])
    }

    func testNestedForkUsesLastInheritedMarker() throws {
        var header = DshTestFixtures.session(id: "grandchild", parentSession: "child")
        header["isSeeded"] = true
        let firstMarker: [String: Any] = ["type": "session/end-seed", "seq": 0, "time": DshTestFixtures.baseTime, "data": ["inherited": true]]
        var copied = DshTestFixtures.assistant(time: DshTestFixtures.baseTime, input: 100, output: 0)
        copied["seq"] = 1
        let finalMarker: [String: Any] = ["type": "session/end-seed", "seq": 2, "time": DshTestFixtures.baseTime, "data": ["inherited": true]]
        var own = DshTestFixtures.assistant(time: DshTestFixtures.baseTime + 1_000, input: 5, output: 0)
        own["seq"] = 3
        try logs.write(project: "p", session: "grandchild", file: "session.v3.jsonl.zstd", bytes: try DshTestFixtures.log(lines: [header, firstMarker, copied, finalMarker, own]))

        XCTAssertEqual(scan().entries.map(\.inputTokens), [5])
    }

    func testReleasedV0SeedLengthSkipsInheritedUsage() throws {
        var header = DshTestFixtures.session(id: "child", parentSession: "parent")
        header["version"] = 0
        header.removeValue(forKey: "isSeeded")
        header["seedLength"] = 1
        var inherited = DshTestFixtures.assistant(time: DshTestFixtures.baseTime, input: 100, output: 0)
        inherited["seq"] = 0
        var own = DshTestFixtures.assistant(time: DshTestFixtures.baseTime + 1_000, input: 5, output: 0)
        own["seq"] = 1
        try logs.write(project: "p", session: "child", file: "session.jsonl.zstd", bytes: try DshTestFixtures.log(lines: [header, inherited, own]))

        XCTAssertEqual(scan().entries.map(\.inputTokens), [5])
    }

    func testAttemptAndRetryAreCountedAsSeparateRequests() throws {
        let route: [String: Any] = ["type": "request/context", "time": DshTestFixtures.baseTime, "data": ["provider": "deepseek", "model": "deepseek-v4.1-flash"]]
        let attempt: [String: Any] = [
            "type": "assistant/attempt", "time": DshTestFixtures.baseTime, "data": [
                "turn": 1, "step": 1,
                "stream": [["chunk": ["type": "usage", "usage": ["inputTokens": 3, "outputTokens": 0]]]]
            ]
        ]
        let retry: [String: Any] = ["type": "llm/retry-started", "time": DshTestFixtures.baseTime, "data": ["turn": 1, "step": 1]]
        let success = DshTestFixtures.assistant(time: DshTestFixtures.baseTime + 1_000, input: 4, output: 0, turn: 1)
        try logs.write(project: "p", session: "s", file: "session.v3.jsonl.zstd", bytes: try DshTestFixtures.log(lines: [DshTestFixtures.session(id: "s"), route, attempt, retry, success]))

        let result = scan()
        XCTAssertEqual(result.entries.map(\.inputTokens), [3, 4])
        XCTAssertEqual(result.entries.first?.model, "deepseek/deepseek-v4.1-flash")
    }

    func testLaterSettlementReplacesSameSlotAcrossScans() throws {
        let attempt: [String: Any] = [
            "type": "assistant/attempt", "time": DshTestFixtures.baseTime, "data": [
                "turn": 1, "step": 1,
                "stream": [["chunk": ["type": "usage", "usage": ["inputTokens": 3, "outputTokens": 0]]]]
            ]
        ]
        let url = try logs.write(project: "p", session: "s", file: "session.v3.jsonl.zstd", bytes: try DshTestFixtures.log(lines: [DshTestFixtures.session(id: "s"), attempt]))
        let first = scan()
        XCTAssertEqual(first.entries.map(\.inputTokens), [3])
        let oldContributions = DshContributionStore.apply(scan: first, to: [:]).contributions

        let handle = try FileHandle(forWritingTo: url)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: DshTestFixtures.log(lines: [
            DshTestFixtures.assistant(time: DshTestFixtures.baseTime + 1_000, input: 4, output: 0, turn: 1)
        ]))
        try handle.close()
        let second = scan(first.newState)
        XCTAssertEqual(second.restartedSessionIDs, ["s"])
        XCTAssertEqual(second.entries.map(\.inputTokens), [4])
        let updated = DshContributionStore.apply(scan: second, to: oldContributions).contributions
        XCTAssertEqual(updated["s"]?.usage.reduce(0) { $0 + $1.inputTokens }, 4)
    }
}
