import XCTest
@testable import CCBar

/// DSH 跨轮聚合回归与中断写盘一致性测试。
///
/// 依据：`docs/草案-DSH本地用量-技术方案.md` §8（必须做四条跨轮聚合回归——单测扫描器返回值
/// 不足以发现这些问题）与中断写盘验收。这里**按 UsageService 的提交路径驱动**：
/// 扫描 → 合入逐会话贡献 → 从全部贡献重新归并 → 整体替换两个聚合器的 DSH 分区，
/// 断言的是聚合器快照，而不是扫描器返回值。
@MainActor
final class DshAggregationRegressionTests: XCTestCase {
    private var logs: DshTempLogRoot!
    private var dshState: [String: ScanFileState] = [:]
    private var contributions: [String: DshContribution] = [:]
    private let aggregator = UsageAggregator()
    private let conversationAggregator = ConversationAggregator()

    override func setUpWithError() throws {
        logs = try DshTempLogRoot(name: "dsh-regression-test")
        dshState = [:]
        contributions = [:]
    }

    override func tearDownWithError() throws {
        logs = nil
    }

    // MARK: - 驱动一轮扫描（等价于 UsageService 的提交路径）

    @discardableResult
    private func runRound() -> DshSessionScanner.Result {
        let scan = DshSessionScanner.scan(previous: dshState, root: logs.root)
        contributions = DshContributionStore.apply(scan: scan, to: contributions).contributions
        dshState = scan.newState
        let rollup = DshContributionRollup.reduce(contributions)
        aggregator.replaceLocal(app: .dsh, buckets: rollup.dayBuckets)
        conversationAggregator.replaceLocal(
            app: .dsh,
            infos: rollup.conversationInfos,
            buckets: rollup.conversationBuckets
        )
        return scan
    }

    private func dshTotals() -> UsageTotals {
        var totals = UsageTotals.zero
        for bucket in aggregator.snapshot() where bucket.app == .dsh {
            totals.add(bucket)
        }
        return totals
    }

    private func dshConversationKeys() -> [String] {
        conversationAggregator.snapshot().buckets.filter { $0.app == .dsh }.map(\.conversationKey).sorted()
    }

    // MARK: - fixture

    /// 每轮把会话日志写到 `<project>/<session>/session[.vN].jsonl.zstd`。
    private func log(
        session id: String,
        parent: String? = nil,
        inputs: [Int],
        title: String? = nil
    ) throws -> Data {
        var records: [[String: Any]] = [DshTestFixtures.session(id: id, parentSession: parent)]
        if let title { records.append(DshTestFixtures.title(title)) }
        for (index, input) in inputs.enumerated() {
            records.append(DshTestFixtures.assistant(
                time: DshTestFixtures.baseTime + Double(index) * 1_000,
                input: input,
                output: 0,
                cacheRead: 0,
                cacheWrite: 0
            ))
        }
        return try DshTestFixtures.log(lines: records)
    }

    private func write(_ bytes: Data, project: String = "p", session: String, file: String) throws {
        try logs.write(project: project, session: session, file: file, bytes: bytes)
    }

    // MARK: - ① generation 切换：总 token 与请求数都不变

    func testGenerationSwitchKeepsTokensAndRequestCount() throws {
        try write(try log(session: "s1", inputs: [100, 50]), session: "s", file: "session.jsonl.zstd")
        runRound()
        let before = dshTotals()
        XCTAssertEqual(before.inputTokens, 150)
        XCTAssertEqual(before.requestCount, 2)

        // 官方 migration：v3 保留同一段逻辑历史，旧 generation 仍在磁盘上
        try write(try log(session: "s1", inputs: [100, 50]), session: "s", file: "session.v3.jsonl.zstd")
        runRound()

        let after = dshTotals()
        XCTAssertEqual(after.inputTokens, 150, "generation 切换不得把等价历史再加一遍")
        XCTAssertEqual(after.requestCount, 2, "请求数同样不得翻倍")
        XCTAssertEqual(aggregator.snapshot().filter { $0.app == .dsh }.count, 1, "同一天同一模型只应有一个桶")
    }

    // MARK: - ② 父文件后到：总量不变、对话桶迁到根

    func testLateParentRefoldsConversationWithoutChangingTotals() throws {
        try write(try log(session: "child-1", parent: "root-1", inputs: [30, 20]), session: "child", file: "session.v1.jsonl.zstd")
        runRound()
        XCTAssertEqual(dshConversationKeys(), ["dsh:child-1"], "父文件暂缺时子会话先作为根")
        let childTotals = dshTotals()
        XCTAssertEqual(childTotals.inputTokens, 50)

        try write(try log(session: "root-1", inputs: [7]), session: "root", file: "session.v1.jsonl.zstd")
        runRound()

        XCTAssertEqual(dshConversationKeys(), ["dsh:root-1"], "子代理用量必须迁到根会话")
        XCTAssertEqual(dshTotals().inputTokens, 57, "归根不改变总量")
        XCTAssertEqual(dshTotals().requestCount, 3)
        let infos = conversationAggregator.snapshot().infos.filter { $0.app == .dsh }
        XCTAssertEqual(infos.count, 1)
        XCTAssertTrue(infos[0].includesSubtasks)
        XCTAssertEqual(infos[0].key, "dsh:root-1")
    }

    // MARK: - ③ 新 generation 损坏：旧贡献保留，其他会话与其他服务照常提交

    func testCorruptNewGenerationKeepsOldContributionAndOtherTraffic() throws {
        try write(try log(session: "a", inputs: [11]), session: "a", file: "session.v1.jsonl.zstd")
        try write(try log(session: "b", inputs: [22]), session: "b", file: "session.v1.jsonl.zstd")
        runRound()
        XCTAssertEqual(dshTotals().inputTokens, 33)

        // 其他服务在同期的增量：DSH 出问题不得影响它
        aggregator.ingestLocal([Self.entry(app: .codex, input: 5)])

        // 会话 a 发布损坏的新 generation；会话 b 追加一条正常新记录
        var broken = try log(session: "a", inputs: [11])
        broken[broken.startIndex + 4] |= 0x08  // 保留位 → 损坏
        try write(broken, session: "a", file: "session.v2.jsonl.zstd")
        try write(try log(session: "b", inputs: [22, 4]), session: "b", file: "session.v2.jsonl.zstd")

        let scan = runRound()
        XCTAssertEqual(scan.failedFileCount, 1, "坏文件要能浮出来（决策 4 → lastError）")

        XCTAssertEqual(dshTotals().inputTokens, 37, "a 保留旧贡献 11，b 换成等价 v2 后新增 4")
        XCTAssertEqual(
            aggregator.snapshot().filter { $0.app == .codex }.reduce(0) { $0 + $1.inputTokens },
            5,
            "其他服务分区不受 DSH 失败影响"
        )
    }

    // MARK: - ④ 已删除会话的历史留存 + 另一会话切换 generation

    func testDeletedSessionHistorySurvivesAnotherSessionGenerationSwitch() throws {
        try write(try log(session: "a", inputs: [10]), session: "a", file: "session.v1.jsonl.zstd")
        let bURL = try logs.write(
            project: "p",
            session: "b",
            file: "session.v1.jsonl.zstd",
            bytes: try log(session: "b", inputs: [20])
        )
        runRound()
        XCTAssertEqual(dshTotals().inputTokens, 30)

        // b 的日志被清理：扫描状态丢掉该路径，贡献必须留下
        try FileManager.default.removeItem(at: bURL)
        runRound()
        XCTAssertEqual(dshTotals().inputTokens, 30, "已清理会话的历史不得倒扣")
        XCTAssertEqual(contributions.count, 2)

        // a 切换到内容等价的 v3：只替换 a 的贡献，b 的历史仍在
        try write(try log(session: "a", inputs: [10]), session: "a", file: "session.v3.jsonl.zstd")
        runRound()
        XCTAssertEqual(dshTotals().inputTokens, 30)
        XCTAssertEqual(dshConversationKeys(), ["dsh:a", "dsh:b"])
    }

    // MARK: - 中断写盘：四份快照不得出现「同代但不同进度」

    func testInterruptedWriteNeverMixesGenerations() throws {
        let directory = try XCTUnwrap(logs.root)
        var rollup = UsageRollupPayload()
        rollup.generationID = "gen-B"
        rollup.buckets = [Self.bucket()]
        var conversation = ConversationRollupPayload()
        conversation.generationID = "gen-B"
        var scanState = ScanState(generationID: "gen-A")

        // 中断点一：主 rollup 已写（gen-B），DSH 贡献缓存与 scan-state 还停在 gen-A
        try UsageRollupCache.save(rollup, in: directory)
        try ConversationRollupCache.save(conversation, in: directory)
        try ScanCache.save(scanState, in: directory)
        try DshContributionCache.save([:], generationID: "gen-A", pricingFingerprint: "fp", in: directory)

        XCTAssertEqual(UsageRollupCache.load(in: directory).generationID, "gen-B")
        XCTAssertEqual(ConversationRollupCache.load(in: directory).generationID, "gen-B")
        guard case .rebuild = DshContributionCache.load(generationID: "gen-B", in: directory) else {
            return XCTFail("贡献缓存代次落后时必须重建，不能与领先的主 rollup 混用")
        }
        if case .valid(let loaded) = ScanCache.load(in: directory) {
            XCTAssertNotEqual(loaded.generationID, "gen-B", "落后的 scan-state 必须被判为不同代")
        }

        // 中断点二：贡献缓存已写（gen-B），主 rollup 还停在 gen-A
        var staleRollup = UsageRollupPayload()
        staleRollup.generationID = "gen-A"
        try UsageRollupCache.save(staleRollup, in: directory)
        try DshContributionCache.save([:], generationID: "gen-B", pricingFingerprint: "fp", in: directory)
        guard case .rebuild = DshContributionCache.load(generationID: "gen-A", in: directory) else {
            return XCTFail("贡献缓存领先于主 rollup 时同样必须重建")
        }

        // 全部同代：三份都有效
        scanState.generationID = "gen-C"
        try ScanCache.save(scanState, in: directory)
        var alignedRollup = UsageRollupPayload()
        alignedRollup.generationID = "gen-C"
        try UsageRollupCache.save(alignedRollup, in: directory)
        var alignedConversation = ConversationRollupPayload()
        alignedConversation.generationID = "gen-C"
        try ConversationRollupCache.save(alignedConversation, in: directory)
        try DshContributionCache.save([:], generationID: "gen-C", pricingFingerprint: "fp", in: directory)

        guard case .valid = DshContributionCache.load(generationID: "gen-C", in: directory) else {
            return XCTFail("同代时贡献缓存应当有效")
        }
        if case .valid(let loaded) = ScanCache.load(in: directory) {
            XCTAssertEqual(loaded.generationID, "gen-C")
        } else {
            XCTFail("同代时 scan-state 应当有效")
        }
    }

    // MARK: - 构造辅助

    private static func entry(app: UsageApp, input: Int) -> UsageEntry {
        let timestamp = Date(timeIntervalSince1970: 1_780_000_000)
        return UsageEntry(
            app: app,
            conversationKey: "\(app.rawValue):k",
            model: app == .codex ? "gpt-5.5-codex" : "deepseek-v4.1-flash",
            speed: .standard,
            day: UsageDay.startOfDay(for: timestamp),
            timestamp: timestamp,
            inputTokens: input,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            costUSD: nil,
            costBreakdown: nil
        )
    }

    private static func bucket() -> UsageBucket {
        UsageBucket(
            app: .dsh,
            model: "deepseek-v4.1-flash",
            speed: .standard,
            day: UsageDay.startOfDay(for: Date(timeIntervalSince1970: 1_780_000_000)),
            inputTokens: 1,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            costUSD: 0,
            requestCount: 1,
            hasUnpricedUsage: true
        )
    }
}
