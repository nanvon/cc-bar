import XCTest
@testable import CCBar

/// DSH 逐会话贡献缓存与两个聚合器替换接口的测试。
///
/// 依据：`docs/草案-DSH本地用量-技术方案.md` §3.3（贡献、generation 切换、失败保留）、
/// §4.1（子代理归根与父链变化）、§6 决策 2（缓存落 Application Support）、
/// §7 S3（验证：替换而非相加、父链变化重归并、缓存损坏回退）、§8（跨轮聚合清单）。
final class DshContributionTests: XCTestCase {
    private var logs: DshTempLogRoot!

    override func setUpWithError() throws {
        logs = try DshTempLogRoot(name: "dsh-contribution-test")
    }

    override func tearDownWithError() throws {
        logs = nil
    }

    // MARK: - 辅助

    /// 一个会话日志：`session` 头 + 若干条 input 指定的 assistant 记录（output / 缓存读写恒 0，便于算总量）。
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

    private func scan(_ previous: [String: ScanFileState] = [:]) -> DshSessionScanner.Result {
        DshSessionScanner.scan(previous: previous, root: logs.root)
    }

    /// 全量 token：日桶口径（与归根无关）。
    private func totalTokens(_ output: DshContributionRollup.Output) -> Int {
        output.dayBuckets.reduce(0) {
            $0 + $1.inputTokens + $1.outputTokens + $1.cacheReadTokens + $1.cacheCreationTokens
        }
    }

    // MARK: - generation 切换与替换语义

    func testGenerationSwitchReplacesInsteadOfAdding() throws {
        let v0 = try log(session: "s1", inputs: [100])
        try logs.write(project: "p", session: "s", file: "session.jsonl.zstd", bytes: v0)
        let round1 = scan()
        var contributions = DshContributionStore.apply(scan: round1, to: [:]).contributions
        XCTAssertEqual(totalTokens(DshContributionRollup.reduce(contributions)), 100)

        // 官方 migration：v3 保留同一段逻辑历史，旧 generation 仍在磁盘上
        let v3 = try log(session: "s1", inputs: [100])
        try logs.write(project: "p", session: "s", file: "session.v3.jsonl.zstd", bytes: v3)

        let round2 = scan(round1.newState)
        contributions = DshContributionStore.apply(scan: round2, to: contributions).contributions
        XCTAssertEqual(
            totalTokens(DshContributionRollup.reduce(contributions)),
            100,
            "generation 切换必须替换该会话贡献，不能把等价历史再加一遍"
        )
        XCTAssertEqual(contributions["s1"]?.sourcePath.hasSuffix("session.v3.jsonl.zstd"), true)
    }

    func testInPlaceReplacementRestartsFromZero() throws {
        let original = try log(session: "s", inputs: [10])
        let url = try logs.write(project: "p", session: "s", file: "session.v1.jsonl.zstd", bytes: original)
        let round1 = scan()
        var contributions = DshContributionStore.apply(scan: round1, to: [:]).contributions
        XCTAssertEqual(totalTokens(DshContributionRollup.reduce(contributions)), 10)
        let previousState = round1.newState

        // 原地替换成**更长**的文件（inode 变了、大小更大）：只看大小完全看不出问题，
        // 必须靠文件身份判定，否则会从旧 offset 续读并算错。
        let replacement = try log(session: "s", inputs: [5, 5])
        XCTAssertGreaterThan(replacement.count, original.count)
        let staging = url.deletingLastPathComponent().appendingPathComponent("staging")
        try replacement.write(to: staging)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: staging, to: url)

        let round2 = scan(previousState)
        XCTAssertEqual(round2.restartedSessionIDs, ["s"])
        contributions = DshContributionStore.apply(scan: round2, to: contributions).contributions
        XCTAssertEqual(
            totalTokens(DshContributionRollup.reduce(contributions)),
            10,
            "替换后的贡献是重算结果（5+5），不是与旧值相加"
        )
    }

    func testFailedFileKeepsPreviousContribution() throws {
        let good = try log(session: "s", inputs: [10])
        let url = try logs.write(project: "p", session: "s", file: "session.v1.jsonl.zstd", bytes: good)
        let round1 = scan()
        var contributions = DshContributionStore.apply(scan: round1, to: [:]).contributions
        XCTAssertEqual(totalTokens(DshContributionRollup.reduce(contributions)), 10)

        // 追加一段坏字节：该文件本轮整份作废，旧贡献与旧 watermark 都保留
        var broken = good
        broken.append(contentsOf: [0x00, 0x01, 0x02, 0x03])
        try broken.write(to: url)

        let round2 = scan(round1.newState)
        XCTAssertEqual(round2.failedFileCount, 1)
        XCTAssertTrue(round2.entries.isEmpty)
        contributions = DshContributionStore.apply(scan: round2, to: contributions).contributions
        XCTAssertEqual(contributions.count, 1)
        XCTAssertEqual(totalTokens(DshContributionRollup.reduce(contributions)), 10)
    }

    func testDeletedSessionKeepsItsHistory() throws {
        try logs.write(project: "p", session: "a", file: "session.v1.jsonl.zstd", bytes: try log(session: "a", inputs: [10]))
        let bURL = try logs.write(project: "p", session: "b", file: "session.v1.jsonl.zstd", bytes: try log(session: "b", inputs: [20]))
        let round1 = scan()
        var contributions = DshContributionStore.apply(scan: round1, to: [:]).contributions
        XCTAssertEqual(contributions.count, 2)

        // 日志被清理：扫描状态丢掉该路径，但贡献必须留下（这正是贡献缓存存在的理由）
        try FileManager.default.removeItem(at: bURL)
        let round2 = scan(round1.newState)
        XCTAssertEqual(round2.filesScanned, 1)
        contributions = DshContributionStore.apply(scan: round2, to: contributions).contributions
        XCTAssertEqual(contributions.count, 2, "已删除会话的贡献不得被倒扣")
        XCTAssertEqual(totalTokens(DshContributionRollup.reduce(contributions)), 30)
    }

    func testDeletedFileReappearingAtSamePathReplacesContribution() throws {
        let url = try logs.write(project: "p", session: "s", file: "session.v1.jsonl.zstd", bytes: try log(session: "s", inputs: [10]))
        let first = scan()
        var contributions = DshContributionStore.apply(scan: first, to: [:]).contributions
        try FileManager.default.removeItem(at: url)
        let missing = scan(first.newState)
        contributions = DshContributionStore.apply(scan: missing, to: contributions).contributions
        XCTAssertEqual(totalTokens(DshContributionRollup.reduce(contributions)), 10)

        try logs.write(project: "p", session: "s", file: "session.v1.jsonl.zstd", bytes: try log(session: "s", inputs: [7]))
        let restored = scan(missing.newState)
        contributions = DshContributionStore.apply(scan: restored, to: contributions).contributions
        XCTAssertEqual(totalTokens(DshContributionRollup.reduce(contributions)), 7)
    }

    func testDuplicateSessionIDAcrossProjectsDoesNotChangeContribution() throws {
        try logs.write(project: "p", session: "s", file: "session.v1.jsonl.zstd", bytes: try log(session: "s", inputs: [10]))
        let first = scan()
        let original = DshContributionStore.apply(scan: first, to: [:]).contributions
        try logs.write(project: "q", session: "other", file: "session.v1.jsonl.zstd", bytes: try log(session: "s", inputs: [20]))

        let conflict = scan(first.newState)
        XCTAssertEqual(conflict.duplicateSessionCount, 1)
        XCTAssertFalse(conflict.isComplete)
        XCTAssertTrue(conflict.entries.isEmpty)
        XCTAssertEqual(DshContributionStore.apply(scan: conflict, to: original).contributions, original)
    }

    func testUnreadableRootPreservesPreviousWatermarks() throws {
        let fileRoot = logs.root.appendingPathComponent("not-a-directory")
        let path = fileRoot.appendingPathComponent("session.v1.jsonl.zstd").path
        let previous = [path: ScanFileState(mtime: 1, offset: 42)]
        try Data("x".utf8).write(to: fileRoot)

        let result = DshSessionScanner.scan(previous: previous, root: fileRoot)
        XCTAssertEqual(result.failedDirectoryCount, 1)
        XCTAssertEqual(result.newState, previous)
        XCTAssertFalse(result.isComplete)
    }

    // MARK: - 子代理归根

    func testParentAppearingLaterRefoldsExistingContributions() throws {
        try logs.write(
            project: "p",
            session: "child",
            file: "session.v1.jsonl.zstd",
            bytes: try log(session: "child-1", parent: "root-1", inputs: [50])
        )
        let round1 = scan()
        var contributions = DshContributionStore.apply(scan: round1, to: [:]).contributions
        var output = DshContributionRollup.reduce(contributions)
        XCTAssertEqual(output.conversationInfos.map(\.key), ["dsh:child-1"], "父文件暂缺时子会话先作为根")
        XCTAssertFalse(output.conversationInfos[0].includesSubtasks)

        // 父文件后来出现：已有贡献必须重新归根，而不是只给未来条目换 key
        try logs.write(
            project: "p",
            session: "root",
            file: "session.v1.jsonl.zstd",
            bytes: try log(session: "root-1", inputs: [20])
        )
        let round2 = scan(round1.newState)
        contributions = DshContributionStore.apply(scan: round2, to: contributions).contributions
        output = DshContributionRollup.reduce(contributions)

        XCTAssertEqual(output.conversationInfos.map(\.key), ["dsh:root-1"])
        XCTAssertTrue(output.conversationInfos[0].includesSubtasks)
        XCTAssertTrue(
            output.conversationBuckets.allSatisfy { $0.conversationKey == "dsh:root-1" },
            "子代理用量必须迁到根会话，不能留在旧 key"
        )
        XCTAssertEqual(totalTokens(output), 70, "总量不因归并改变")
    }

    func testParentChainFoldsToRootAndGuardsCycles() throws {
        // 三层：grand ← parent ← child，全部归到 grand
        try logs.write(project: "p", session: "g", file: "session.v1.jsonl.zstd", bytes: try log(session: "grand", inputs: [1]))
        try logs.write(project: "p", session: "p", file: "session.v1.jsonl.zstd", bytes: try log(session: "parent", parent: "grand", inputs: [2]))
        try logs.write(project: "p", session: "c", file: "session.v1.jsonl.zstd", bytes: try log(session: "child", parent: "parent", inputs: [4]))
        let result = scan()
        let contributions = DshContributionStore.apply(scan: result, to: [:]).contributions
        var output = DshContributionRollup.reduce(contributions)
        XCTAssertEqual(output.conversationInfos.map(\.key), ["dsh:grand"])
        XCTAssertEqual(totalTokens(output), 7)

        // 环：a → b → a。必须终止，且两个会话归到同一个根
        try logs.write(project: "q", session: "a", file: "session.v1.jsonl.zstd", bytes: try log(session: "a", parent: "b", inputs: [8]))
        try logs.write(project: "q", session: "b", file: "session.v1.jsonl.zstd", bytes: try log(session: "b", parent: "a", inputs: [16]))
        let cycleResult = DshSessionScanner.scan(previous: [:], root: logs.root)
        let cycleContributions = DshContributionStore.apply(scan: cycleResult, to: [:]).contributions
        output = DshContributionRollup.reduce(cycleContributions)
        XCTAssertEqual(Set(output.conversationInfos.map(\.key)).count, 2, "正常会话与成环会话各自一行")
        XCTAssertEqual(totalTokens(output), 31)
    }

    // MARK: - 缓存读写

    func testCacheRequiresMatchingGenerationAndVersion() throws {
        let directory = logs.root.appendingPathComponent("cache", isDirectory: true)
        var contribution = DshContribution(
            sessionID: "s",
            sourcePath: "/tmp/session.v1.jsonl.zstd",
            fileIdentity: ScanFileIdentity(device: 1, inode: 2),
            fileSize: 10,
            watermark: 10,
            cwd: "/Users/tester/Code/demo",
            parentSession: nil,
            title: "标题",
            usage: []
        )
        contribution.merge([
            UsageEntry(
                app: .dsh,
                conversationKey: "dsh:s",
                model: "deepseek/deepseek-v4.1-flash",
                speed: .standard,
                day: UsageDay.startOfDay(for: Date(timeIntervalSince1970: 1_780_000_000)),
                timestamp: Date(timeIntervalSince1970: 1_780_000_000),
                inputTokens: 10,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                costUSD: nil,
                costBreakdown: nil
            )
        ])
        try DshContributionCache.save(["s": contribution], generationID: "gen-1", pricingFingerprint: "fp", in: directory)

        guard case .valid(let loaded) = DshContributionCache.load(generationID: "gen-1", in: directory) else {
            return XCTFail("代次一致时应当读到有效缓存")
        }
        XCTAssertEqual(loaded["s"]?.usage.first?.inputTokens, 10)
        XCTAssertEqual(loaded["s"]?.title, "标题")

        // 代次不一致：不能和旧桶混用，必须重建
        guard case .rebuild = DshContributionCache.load(generationID: "gen-2", in: directory) else {
            return XCTFail("代次不一致必须判定为需要重建")
        }

        // 内容损坏
        try Data("{".utf8).write(to: DshContributionCache.cacheFileURL(in: directory))
        guard case .rebuild = DshContributionCache.load(generationID: "gen-1", in: directory) else {
            return XCTFail("缓存损坏必须判定为需要重建")
        }
    }

    func testV1ContributionCacheLoadsAsPendingMigration() throws {
        let directory = logs.root.appendingPathComponent("legacy-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var payload = DshContributionPayload()
        payload.version = 1
        payload.generationID = "legacy-generation"
        payload.contributions = ["old": DshContribution(
            sessionID: "old", sourcePath: "/deleted/session.jsonl.zstd",
            fileIdentity: nil, fileSize: 4, watermark: 4,
            cwd: nil, parentSession: nil, title: nil, usage: []
        )]
        try JSONEncoder().encode(payload).write(to: DshContributionCache.cacheFileURL(in: directory))

        guard case .pending(let loaded) = DshContributionCache.load(generationID: "legacy-generation", in: directory) else {
            return XCTFail("v1 贡献应保留并等待重建")
        }
        XCTAssertEqual(loaded["old"]?.needsVerification, true)
    }

    func testRebuildFromLogsRestoresAllSessions() throws {
        try logs.write(project: "p", session: "a", file: "session.v1.jsonl.zstd", bytes: try log(session: "a", inputs: [3]))
        try logs.write(project: "p", session: "b", file: "session.v1.jsonl.zstd", bytes: try log(session: "b", inputs: [5]))
        // 缓存缺失时以空状态全量扫描重建
        let result = scan()
        let contributions = DshContributionStore.rebuild(from: result)
        XCTAssertEqual(contributions.count, 2)
        XCTAssertEqual(totalTokens(DshContributionRollup.reduce(contributions)), 8)
    }

    // MARK: - 落盘门控（模拟 UsageService 的提交判定）

    func testUnchangedRoundReportsNoChange() throws {
        try logs.write(project: "p", session: "s", file: "session.v1.jsonl.zstd", bytes: try log(session: "s", inputs: [12]))

        let round1 = DshSessionScanner.scan(previous: [:], root: logs.root)
        let first = DshContributionStore.apply(scan: round1, to: [:])
        XCTAssertTrue(first.changed)

        // 未变化的一轮：不该触发落盘，也不该改动贡献
        let round2 = DshSessionScanner.scan(previous: round1.newState, root: logs.root)
        let second = DshContributionStore.apply(scan: round2, to: first.contributions)
        XCTAssertFalse(second.changed, "未变化的一轮必须报告 no-change，否则会白白重写 rollup")
        XCTAssertEqual(second.contributions, first.contributions)
    }

    func testDeferredRoundRescanIsIdempotent() throws {
        // UsageService 的节流语义：未落盘的一轮丢弃试算结果、watermark 也停在上一轮，
        // 下一轮会把同样的帧再扫一遍。这里验证「重扫 + 只提交一次」与「只扫一次」等价。
        try logs.write(project: "p", session: "s", file: "session.v1.jsonl.zstd", bytes: try log(session: "s", inputs: [40]))

        var contributions: [String: DshContribution] = [:]
        var dshState: [String: ScanFileState] = [:]

        // 第 1 轮：决定暂不落盘 → 试算结果与 watermark 都不采纳
        let round1 = DshSessionScanner.scan(previous: dshState, root: logs.root)
        let trial = DshContributionStore.apply(scan: round1, to: contributions)
        XCTAssertTrue(trial.changed)
        XCTAssertTrue(contributions.isEmpty)

        // 第 2 轮：同样的状态重扫一遍，这次落盘
        let round2 = DshSessionScanner.scan(previous: dshState, root: logs.root)
        let committed = DshContributionStore.apply(scan: round2, to: contributions)
        contributions = committed.contributions
        dshState = round2.newState

        XCTAssertEqual(
            totalTokens(DshContributionRollup.reduce(contributions)),
            40,
            "未落盘导致的重扫不得把同一段用量算两遍"
        )
    }

    // MARK: - 聚合器替换接口

    @MainActor
    func testUsageAggregatorReplaceLocalSwapsOnlyThatService() {
        let aggregator = UsageAggregator()
        aggregator.ingestLocal([Self.entry(app: .codex, model: "gpt-5", input: 7)])
        aggregator.replaceLocal(app: .dsh, buckets: [Self.bucket(input: 10)])
        aggregator.replaceLocal(app: .dsh, buckets: [Self.bucket(input: 30)])

        let snapshot = aggregator.snapshot()
        XCTAssertEqual(snapshot.filter { $0.app == .dsh }.reduce(0) { $0 + $1.inputTokens }, 30, "替换而不是累加")
        XCTAssertEqual(snapshot.filter { $0.app == .codex }.reduce(0) { $0 + $1.inputTokens }, 7, "其他服务分区不受影响")
    }

    @MainActor
    func testConversationAggregatorReplaceLocalSwapsOnlyThatService() {
        let aggregator = ConversationAggregator()
        aggregator.ingest(
            entries: [Self.entry(app: .pi, model: "deepseek-v4-flash", input: 9)],
            seeds: []
        )
        aggregator.replaceLocal(
            app: .dsh,
            infos: [Self.info(key: "dsh:root", title: "DSH 会话")],
            buckets: [Self.conversationBucket(key: "dsh:root", input: 12)]
        )
        var snapshot = aggregator.snapshot()
        XCTAssertEqual(snapshot.infos.map(\.key), ["dsh:root"])
        XCTAssertEqual(snapshot.buckets.reduce(0) { $0 + $1.inputTokens }, 21)

        // DSH 重算结果为空（例如日志全被清理）：只清 DSH 分区
        aggregator.replaceLocal(app: .dsh, infos: [], buckets: [])
        snapshot = aggregator.snapshot()
        XCTAssertTrue(snapshot.infos.isEmpty)
        XCTAssertEqual(snapshot.buckets.reduce(0) { $0 + $1.inputTokens }, 9, "其他服务对话桶保留")
    }

    // MARK: - 构造辅助

    private static func entry(app: UsageApp, model: String, input: Int) -> UsageEntry {
        let timestamp = Date(timeIntervalSince1970: 1_780_000_000)
        return UsageEntry(
            app: app,
            conversationKey: "\(app.rawValue):k",
            model: model,
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

    private static func bucket(input: Int) -> UsageBucket {
        UsageBucket(
            app: .dsh,
            model: "deepseek/deepseek-v4.1-flash",
            speed: .standard,
            day: UsageDay.startOfDay(for: Date(timeIntervalSince1970: 1_780_000_000)),
            inputTokens: input,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            costUSD: 0,
            requestCount: 1,
            hasUnpricedUsage: true
        )
    }

    private static func info(key: String, title: String) -> ConversationInfo {
        ConversationInfo(
            key: key,
            conversationID: key,
            app: .dsh,
            title: title,
            projectKey: "p",
            projectName: "demo",
            projectPath: "/Users/tester/Code/demo",
            projectStatus: .available,
            projectSource: .cwd,
            gitBranch: nil,
            sourcePaths: ["/tmp/log"],
            firstAt: Date(timeIntervalSince1970: 1_780_000_000),
            lastAt: Date(timeIntervalSince1970: 1_780_000_000),
            includesSubtasks: false,
            cacheCreationAvailable: true
        )
    }

    private static func conversationBucket(key: String, input: Int) -> ConversationUsageBucket {
        ConversationUsageBucket(
            conversationKey: key,
            app: .dsh,
            day: UsageDay.startOfDay(for: Date(timeIntervalSince1970: 1_780_000_000)),
            model: "deepseek/deepseek-v4.1-flash",
            speed: .standard,
            firstAt: Date(timeIntervalSince1970: 1_780_000_000),
            lastAt: Date(timeIntervalSince1970: 1_780_000_000),
            inputTokens: input,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            requestCount: 1,
            costUSD: 0,
            inputCostUSD: 0,
            outputCostUSD: 0,
            cacheReadCostUSD: 0,
            cacheCreationCostUSD: 0,
            hasUnpricedUsage: true
        )
    }
}
