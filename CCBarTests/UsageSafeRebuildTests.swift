import XCTest
import SQLite3
@testable import CCBar

/// 安全重算的端到端测试（执行计划 A10～A16、A19～A23、A25）。
///
/// 手动 / 自动重算以现有日志为准，日志已删除的对话保留原用量并按现价重新计费；只在来源不完整、
/// 候选持久化失败时拒绝。另覆盖：费用按新价重算、重复重算幂等、续接对话不重复计入（消息账本）、
/// 价格与统计规则变化后的自动重建、周期与 DSH 分区自洽。用量向量逐项比对只用于受限恢复
/// （见 UsageHistoryRecoveryTests）。
@MainActor
final class UsageSafeRebuildTests: XCTestCase {
    private var environment: UsageTestEnvironment!

    override func setUpWithError() throws {
        environment = try UsageTestEnvironment(name: "usage-safe-rebuild")
    }

    override func tearDownWithError() throws {
        environment = nil
    }

    // MARK: - fixture

    private let model = "ccbar-safe-model"

    private struct ScanResult {
        var day: [UsageBucket]
        var conversation: [ConversationUsageBucket]
        var cycle: [CycleUsageBucket]
        var infos: [ConversationInfo]
    }

    /// 周期桶按真实窗口归属，因此日志时间必须相对 `now` 生成而不是写死日期。
    private var claudeEntries: [(id: String, offsetHours: Double, input: Int, output: Int)] {
        [
            ("safe-3d", -72, 1_000, 100),
            ("safe-3h", -3, 2_000, 200),
            ("safe-30m", -0.5, 500, 50),
        ]
    }

    private func timestamp(_ offsetHours: Double, from reference: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: reference.addingTimeInterval(offsetHours * 3_600))
    }

    @discardableResult
    private func seed(_ env: UsageTestEnvironment, reference: Date = Date()) async throws -> UsageService {
        try env.writeClaudeLog(
            session: "safe-session",
            lines: claudeEntries.map { entry in
                env.claudeLine(
                    id: entry.id,
                    session: "safe-session",
                    model: model,
                    timestamp: timestamp(entry.offsetHours, from: reference),
                    input: entry.input,
                    output: entry.output,
                    speed: "standard"
                )
            }
        )
        try env.writeCodexLog(
            id: "safe-codex",
            lines: env.codexLines(
                id: "safe-codex",
                model: model,
                timestampPrefix: timestamp(-1, from: reference),
                input: 3_000,
                cachedInput: 0,
                output: 300
            )
        )
        try env.writeDshLog(
            project: "project-safe",
            session: "dsh-safe",
            records: [
                DshTestFixtures.session(id: "dsh-safe"),
                DshTestFixtures.assistant(time: DshTestFixtures.baseTime + 1_000, input: 700, output: 70),
            ]
        )
        let service = env.makeService()
        await env.bootstrap(service)
        await service.scanNow()
        return service
    }

    /// 期望费用：价格单位是「每 100 万 token 的 USD」，与 `Pricing.costBreakdown` 同口径。
    /// 只对被计价模型（fixture 的 standard 档）求和；cache 费率在 fixture 里是 0。
    private func dayCost(_ buckets: [UsageBucket], model: String) -> Decimal {
        buckets.filter { $0.model == model }.reduce(Decimal(0)) { $0 + $1.costUSD }
    }

    private func expectedCost(_ buckets: [UsageBucket], input: Decimal, output: Decimal) -> Decimal {
        UsageHistoryConsistency.dayVector(buckets)
            .filter { $0.key.model == model && $0.key.speed == .standard }
            .values
            .reduce(Decimal(0)) { total, counts in
                total
                    + Decimal(counts.inputTokens) * input / 1_000_000
                    + Decimal(counts.outputTokens) * output / 1_000_000
            }
    }

    private func result(_ service: UsageService) -> ScanResult {
        let conversation = service.conversationAggregator.snapshot()
        return ScanResult(
            day: service.aggregator.snapshotLocal(),
            conversation: conversation.buckets,
            cycle: service.cycleAggregator.snapshot(),
            infos: conversation.infos
        )
    }

    private func committed(_ env: UsageTestEnvironment) throws -> UsageSnapshot {
        switch env.store.loadCurrent() {
        case .valid(let snapshot): return snapshot
        case .missing:
            XCTFail("store has no current snapshot")
            throw UsageSafeRebuildTestsError.missingSnapshot
        case .invalid(let reason):
            XCTFail("current snapshot invalid: \(reason)")
            throw UsageSafeRebuildTestsError.missingSnapshot
        }
    }

    private func makeCycle(
        id: String,
        app: UsageApp,
        accountKey: String,
        kind: QuotaLimitKind,
        startAt: Date,
        endAt: Date
    ) -> QuotaCycleRecord {
        QuotaCycleRecord(
            id: id,
            accountKey: accountKey,
            app: app,
            limitID: "\(app.rawValue)-\(kind.rawValue)",
            limitKind: kind,
            startAt: startAt,
            endAt: endAt,
            scheduledEndAt: endAt,
            firstSampleAt: startAt,
            lastSampleAt: startAt,
            latestUsedPercent: 10,
            allowanceSegments: [
                QuotaCycleAllowanceSegment(
                    id: "\(id)-seg",
                    startAt: startAt,
                    endAt: endAt,
                    baselineUsedPercent: 0,
                    latestUsedPercent: 10,
                    maximumUsedPercent: 12,
                    firstSampleAt: startAt,
                    lastSampleAt: startAt,
                    startReason: .initial
                )
            ],
            source: .api,
            boundaryQuality: .observed
        )
    }

    // MARK: - A10 价格变化：用量不变、费用按新价重算

    func testRebuildRecomputesCostsWithNewPriceAndKeepsEveryCount() async throws {
        let env = environment!
        env.installPricing(model: model, input: 1, output: 10)
        let service = try await seed(env)
        let before = result(service)
        let beforeCost = dayCost(before.day, model: model)
        XCTAssertEqual(beforeCost, expectedCost(before.day, input: 1, output: 10))
        XCTAssertGreaterThan(beforeCost, 0)
        try assertSameDayVector(before.day, try committed(env).usageRollup.buckets, env: env)

        // 价格目录整体换价（全部档位 ×10）：重算必须逐键重算金额，但不得改变任何计数。
        env.installPricing(model: model, input: 10, output: 100, cacheRead: 1, cacheCreation: 5)
        await service.forceRescan()
        XCTAssertEqual(service.lastRebuildOutcome, .replaced(cycleVerified: true), service.lastRebuildDiagnostic ?? "")
        let after = result(service)
        XCTAssertEqual(
            dayCost(after.day, model: model),
            expectedCost(after.day, input: 10, output: 100),
            "新价必须整体生效（不是只改新桶）"
        )
        XCTAssertEqual(dayCost(after.day, model: model), beforeCost * 10, "同一批 token 在 ×10 价格下金额必须正好 ×10")
        XCTAssertNotEqual(dayCost(after.day, model: model), beforeCost)
        try assertSameDayVector(before.day, after.day, env: env)
        XCTAssertEqual(
            env.conversationVector(before.conversation),
            env.conversationVector(after.conversation)
        )
        XCTAssertEqual(
            UsageHistoryConsistency.dayVector(after.day),
            UsageHistoryConsistency.dayVector(try committed(env).usageRollup.buckets),
            "提交后的磁盘快照必须与内存一致"
        )
    }

    // MARK: - A11 / A13 来源不完整或读取失败：保留历史并明确报告

    func testUnreadableSourceRejectsRebuildAndPreservesHistory() async throws {
        let env = environment!
        env.installPricing(model: model, input: 1, output: 10)
        let service = try await seed(env)
        let before = result(service)
        let committedBefore = try committed(env)

        // 让 Claude 目录里出现一个无法读取的文件：候选从根上不完整。
        let blocked = env.claudeRoot.appendingPathComponent("fixture-project/permission-denied.jsonl")
        try Data("[]".utf8).write(to: blocked)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: blocked.path)
        }

        await service.forceRescan()
        XCTAssertEqual(service.lastRebuildOutcome, .rejectedIncompleteSources("Claude Code"))
        XCTAssertNotNil(service.lastRebuildDiagnostic)
        XCTAssertEqual(env.dayCost(result(service).day), env.dayCost(before.day), "拒绝后金额也不得变化")
        try assertSameDayVector(before.day, result(service).day, env: env)
        try assertSameDayVector(before.day, try committed(env).usageRollup.buckets, env: env)
        try assertSameDayVector(committedBefore.usageRollup.buckets, try committed(env).usageRollup.buckets, env: env)

        // 恢复正常后同一份历史仍能重算通过。
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: blocked.path)
        try FileManager.default.removeItem(at: blocked)
        await service.forceRescan()
        XCTAssertEqual(service.lastRebuildOutcome, .replaced(cycleVerified: true), service.lastRebuildDiagnostic ?? "")
        try assertSameDayVector(before.day, result(service).day, env: env)
    }

    func testMissingDshLogPreservesHistoryInsteadOfClearing() async throws {
        let env = environment!
        let service = try await seed(env)
        let before = result(service)
        let dshBefore = env.totals(before.day, app: .dsh)
        XCTAssertGreaterThan(dshBefore.inputTokens, 0)

        // DSH 目录整个消失（等价于日志被清理）：历史不得被清空。
        try FileManager.default.removeItem(at: env.dshRoot)
        await service.scanNow()
        XCTAssertEqual(env.totals(result(service).day, app: .dsh).inputTokens, dshBefore.inputTokens)
        try assertSameDayVector(before.day, result(service).day, env: env)
    }

    // MARK: - A12 / A15 写盘中断：不切换内存、重启只看到完整提交

    func testCommitFaultDuringRebuildKeepsCurrentResultAndDisk() async throws {
        let env = environment!
        env.installPricing(model: model, input: 1, output: 10)
        let service = try await seed(env)
        let before = result(service)
        let diskBefore = try committed(env)

        env.installPricing(model: model, input: 100, output: 1_000)
        env.faults.fail(at: .beforeCurrentReplace)
        await service.forceRescan()
        XCTAssertEqual(service.lastRebuildOutcome, .commitFailed("injected fault at beforeCurrentReplace"))
        try assertSameDayVector(before.day, result(service).day, env: env)
        XCTAssertEqual(try committed(env).snapshotID, diskBefore.snapshotID)
        XCTAssertEqual(
            env.dayCost(result(service).day),
            env.dayCost(diskBefore.usageRollup.buckets),
            "提交失败后内存必须回滚到与磁盘一致"
        )

        // 重启：只看到上一份完整提交。
        let restarted = env.makeService()
        await env.bootstrap(restarted)
        try assertSameDayVector(before.day, result(restarted).day, env: env)
    }

    func testFaultAfterCurrentReplaceStillYieldsOneCompleteSnapshot() async throws {
        let env = environment!
        env.installPricing(model: model, input: 1, output: 10)
        let service = try await seed(env)
        let before = result(service)
        let oldID = try committed(env).snapshotID
        env.installPricing(model: model, input: 10, output: 100)
        // 候选阶段才注入，避免先被 drain 的提交消耗。
        service.candidateReadyForTesting = { env.faults.fail(at: .afterCurrentReplace) }
        await service.forceRescan()
        XCTAssertEqual(service.lastRebuildOutcome, .replaced(cycleVerified: true))
        XCTAssertNotEqual(try committed(env).snapshotID, oldID)
        XCTAssertEqual(dayCost(result(service).day, model: model), dayCost(before.day, model: model) * 10)
        let restarted = env.makeService()
        await env.bootstrap(restarted)
        try assertSameDayVector(before.day, result(restarted).day, env: env)
        XCTAssertEqual(dayCost(result(restarted).day, model: model), dayCost(result(service).day, model: model))
    }

    func testEveryCandidateCommitFaultKeepsOneDurableGeneration() async throws {
        for point in UsageSnapshotStore.FaultPoint.allCases {
            let env = try UsageTestEnvironment(name: "service-fault-\(point.rawValue)")
            env.installPricing(model: model, input: 1, output: 10)
            let service = try await seed(env)
            let old = try committed(env)
            let oldCost = dayCost(old.usageRollup.buckets, model: model)
            env.installPricing(model: model, input: 10, output: 100)
            var baselineID = old.snapshotID
            service.candidateReadyForTesting = {
                // forceRescan 会先提交 pending 进度；以真正候选切换前的提交为基准。
                baselineID = env.store.loadCurrent().snapshot?.snapshotID ?? "missing"
                env.faults.fail(at: point)
            }
            await service.forceRescan()
            let saved = try committed(env)
            let didCommit = point == .afterCurrentReplace
            XCTAssertEqual(service.lastRebuildOutcome,
                didCommit ? .replaced(cycleVerified: true) : .commitFailed("injected fault at \(point.rawValue)"))
            XCTAssertEqual(dayCost(saved.usageRollup.buckets, model: model), didCommit ? oldCost * 10 : oldCost)
            XCTAssertEqual(dayCost(result(service).day, model: model), dayCost(saved.usageRollup.buckets, model: model))
            XCTAssertEqual(saved.snapshotID == baselineID, !didCommit, point.rawValue)
            let restarted = env.makeService()
            await env.bootstrap(restarted)
            await restarted.scanNow()
            try assertSameDayVector(old.usageRollup.buckets, result(restarted).day, env: env)
            XCTAssertEqual(dayCost(result(restarted).day, model: model), dayCost(saved.usageRollup.buckets, model: model))
            await restarted.forceRescan()
            XCTAssertEqual(restarted.lastRebuildOutcome, .replaced(cycleVerified: true))
            XCTAssertEqual(dayCost(result(restarted).day, model: model), oldCost * 10)
        }
    }

    func testCycleCommitQueuesAppendedUsageAndMatchesIndependentScan() async throws {
        let env = environment!
        let now = Date()
        env.appState.quotaCycles.records = [makeCycle(id: "interleaved", app: .claude, accountKey: "a", kind: .fiveHour,
            startAt: now.addingTimeInterval(-3600), endAt: now.addingTimeInterval(3600))]
        env.appState.quotaCycles.accountSegments = [QuotaCycleAccountSegment(id: "account", accountKey: "a", app: .claude,
            startAt: now.addingTimeInterval(-86400 * 30), endAt: nil)]
        let service = try await seed(env, reference: now)
        let before = env.totals(result(service).day, app: .claude).inputTokens
        let finished = expectation(description: "ordinary scan after cycle commit")
        service.cycleReadyForTesting = { [weak service] in
            guard let service else { return }
            do {
                try env.append(env.claudeLine(id: "during-cycle", session: "safe-session", model: self.model,
                    timestamp: self.timestamp(-0.1, from: now), input: 333, output: 33),
                    to: env.claudeRoot.appendingPathComponent("fixture-project/safe-session.jsonl"))
            } catch { XCTFail("append failed: \(error)") }
            await service.scanNow()
            service.cycleReadyForTesting = nil
            Task { @MainActor in
                for _ in 0..<500 {
                    if !service.isScanning && env.totals(self.result(service).day, app: .claude).inputTokens == before + 333 {
                        finished.fulfill()
                        return
                    }
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
            }
        }
        await service.rebuildCycleUsageForRecentChanges()
        await fulfillment(of: [finished], timeout: 8)
        XCTAssertEqual(env.totals(result(service).day, app: .claude).inputTokens, before + 333)
        let clean = try UsageTestEnvironment(name: "cycle-authority")
        try clean.copySources(from: env)
        clean.appState.quotaCycles = env.appState.quotaCycles
        let authority = clean.makeService()
        await clean.bootstrap(authority)
        await authority.scanNow()
        try assertSameDayVector(result(authority).day, result(service).day, env: env)
        XCTAssertEqual(UsageHistoryConsistency.cycleVector(result(authority).cycle), UsageHistoryConsistency.cycleVector(result(service).cycle))
        await service.flushPendingRollupChangesForTesting()
        let restarted = env.makeService()
        await env.bootstrap(restarted)
        await restarted.scanNow()
        XCTAssertEqual(UsageHistoryConsistency.cycleVector(result(authority).cycle), UsageHistoryConsistency.cycleVector(result(restarted).cycle))
    }

    func testRebuildRestoresCycleUsageFromLogsAndClearsIncompleteHint() async throws {
        let env = environment!
        let now = Date()
        env.appState.quotaCycles.records = [makeCycle(id: "cycle-difference", app: .claude, accountKey: "a", kind: .fiveHour,
            startAt: now.addingTimeInterval(-3600), endAt: now.addingTimeInterval(3600))]
        env.appState.quotaCycles.accountSegments = [QuotaCycleAccountSegment(id: "account", accountKey: "a", app: .claude,
            startAt: now.addingTimeInterval(-86400 * 30), endAt: nil)]
        _ = try await seed(env, reference: now)
        var saved = try committed(env)
        XCTAssertFalse(saved.cycleRollup.buckets.isEmpty)
        let logCycles = saved.cycleRollup.buckets
        saved.cycleRollup.buckets[0].inputTokens += 1
        // 周期记录里已不存在、且反解不出重置时刻的旧桶：载入时提示「周期用量不完整」。
        var stale = saved.cycleRollup.buckets[0]
        stale.cycleID = "stale-cycle"
        saved.cycleRollup.buckets.append(stale)
        try env.store.commit(saved)
        let service = env.makeService()
        await env.bootstrap(service)
        XCTAssertTrue(service.cycleUsageNeedsManualRecalculation)
        await service.forceRescan()
        // 周期用量以日志为准：被改动的桶恢复成日志结果，差异只记入诊断；重算后不再提示补齐。
        XCTAssertEqual(service.lastRebuildOutcome, .replaced(cycleVerified: false))
        XCTAssertFalse(service.cycleUsageNeedsManualRecalculation)
        XCTAssertTrue(service.lastRebuildDiagnostic?.contains("cycle_keys_changed") == true)
        XCTAssertEqual(
            UsageHistoryConsistency.cycleVector(logCycles),
            UsageHistoryConsistency.cycleVector(result(service).cycle)
        )
        try assertSameDayVector(saved.usageRollup.buckets, result(service).day, env: env)
    }

    func testInitialCycleRebuildCannotCommitEmptyProgressAfterScanFailure() async throws {
        let env = environment!
        let now = Date()
        env.appState.quotaCycles.records = [makeCycle(id: "first", app: .claude, accountKey: "a", kind: .fiveHour,
            startAt: now.addingTimeInterval(-3600), endAt: now.addingTimeInterval(3600))]
        try env.writeClaudeLog(session: "first", lines: [env.claudeLine(id: "first", session: "first", model: model,
            timestamp: timestamp(-0.1, from: now), input: 123, output: 12)])
        let service = env.makeService()
        await env.bootstrap(service)
        env.faults.fail(at: .beforeEncode)
        await service.scanNow()
        env.faults.fail(at: .beforeEncode)
        await service.rebuildCycleUsageIfNeeded()
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.store.currentFileURL.path))
        await service.rebuildCycleUsageIfNeeded()
        let saved = try committed(env)
        XCTAssertFalse(saved.scanState.claude.isEmpty)
        XCTAssertEqual(env.totals(saved.usageRollup.buckets, app: .claude).inputTokens, 123)
        let restarted = env.makeService()
        await env.bootstrap(restarted)
        await restarted.scanNow()
        XCTAssertEqual(env.totals(result(restarted).day, app: .claude).inputTokens, 123)
    }

    // MARK: - A14 日志被原地改写：重算以日志为准，差异写入诊断

    func testRebuildFollowsLogsRewrittenInPlace() async throws {
        let env = environment!
        let service = try await seed(env)
        let before = result(service)

        // 「内容变了但 mtime 没变」：增量扫描看不到变化，全量重扫读到新内容。
        // 日志还在的对话以日志为准，重算采用新内容，差异只写入诊断。
        let logURL = env.claudeRoot.appendingPathComponent("fixture-project/safe-session.jsonl")
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: logURL.path)
        let originalText = try XCTUnwrap(String(data: Data(contentsOf: logURL), encoding: .utf8))
        let rewritten = originalText.replacingOccurrences(
            of: #""input_tokens":2000"#,
            with: #""input_tokens":9000"#
        )
        XCTAssertEqual(rewritten.count, originalText.count, "等长改写才能保证文件大小不变")
        try Data(rewritten.utf8).write(to: logURL)
        if let mtime = originalAttributes[.modificationDate] as? Date {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: logURL.path)
        }
        await service.forceRescan()
        XCTAssertEqual(service.lastRebuildOutcome, .replaced(cycleVerified: true), service.lastRebuildDiagnostic ?? "")
        XCTAssertEqual(
            env.totals(result(service).day, app: .claude).inputTokens,
            env.totals(before.day, app: .claude).inputTokens + 7_000
        )
        let diagnostic = try XCTUnwrap(service.lastRebuildDiagnostic)
        XCTAssertTrue(diagnostic.contains("day_keys"), "诊断必须给出可读的差异类别：\(diagnostic)")
        try assertSameDayVector(result(service).day, try committed(env).usageRollup.buckets, env: env)
    }

    // MARK: - A16 DSH 全量重扫：整体替换、不翻倍、结果稳定

    func testDshFullRescanReplacesContributionWithoutDoubling() async throws {
        let env = environment!
        let service = try await seed(env)
        let before = result(service)
        let dshBefore = env.totals(before.day, app: .dsh)

        // 让贡献缓存需要从零重扫：删缓存文件模拟代次丢失。
        await service.forceRescan()
        XCTAssertEqual(env.totals(result(service).day, app: .dsh).inputTokens, dshBefore.inputTokens)
        await service.forceRescan()
        XCTAssertEqual(
            env.totals(result(service).day, app: .dsh).inputTokens,
            dshBefore.inputTokens,
            "重复全量重扫不能让 DSH 历史翻倍"
        )
        XCTAssertEqual(
            env.dayVector(before.day),
            env.dayVector(result(service).day),
            "两次重算后的完整向量必须一致（幂等）"
        )
    }

    func testDeletedDshSessionContributionSurvivesRebuild() async throws {
        let env = environment!
        let service = try await seed(env)
        let dshBefore = env.totals(result(service).day, app: .dsh)

        try env.writeDshLog(
            project: "project-safe",
            session: "dsh-deleted",
            records: [
                DshTestFixtures.session(id: "dsh-deleted"),
                DshTestFixtures.assistant(time: DshTestFixtures.baseTime + 2_000, input: 1_234, output: 100),
            ]
        )
        await service.scanNow()
        // 常规扫描按节流只更新内存；DSH 贡献同样要等落盘那一轮才生效。
        await service.flushPendingRollupChangesForTesting()
        let withExtra = env.totals(result(service).day, app: .dsh)
        XCTAssertEqual(withExtra.inputTokens, dshBefore.inputTokens + 1_234)
        XCTAssertEqual(service.dshTrackedSessionCount, 2, "新增会话必须进入贡献缓存")
        let committedDsh = try committed(env).dshContributions.contributions
        let committedExtra = committedDsh.values.reduce(0) { $0 + $1.usage.reduce(0) { $0 + $1.inputTokens } }
        XCTAssertEqual(committedExtra, withExtra.inputTokens, "落盘后的 DSH 贡献必须与内存一致")

        // 删除日志后再重算：已删除会话的历史贡献必须保留。
        try FileManager.default.removeItem(
            at: env.dshRoot.appendingPathComponent("project-safe/dsh-deleted/session.jsonl")
        )
        await service.forceRescan()
        XCTAssertEqual(service.dshTrackedSessionCount, 2, "已删除会话的贡献不得从缓存消失")
        XCTAssertEqual(env.totals(result(service).day, app: .dsh).inputTokens, withExtra.inputTokens)
    }

    func testDshGenerationMismatchTriggersFullRescanWithoutDoubling() async throws {
        let env = environment!
        let service = try await seed(env)
        let before = result(service)

        // 伪造错代的 DSH 贡献缓存：必须触发从零重扫，且不翻倍。
        var payload = try committed(env).dshContributions
        payload.generationID = "generation-from-nowhere"
        try DshContributionCache.save(
            payload.contributions,
            generationID: payload.generationID,
            pricingFingerprint: payload.pricingFingerprint,
            requiresRebuild: true,
            in: env.supportDirectory
        )
        // 直接改 current 里的 DSH 分区等价于「缓存代次错位」。
        var snapshot = try committed(env)
        snapshot.dshContributions.generationID = ""
        snapshot.dshContributions.requiresRebuild = true
        env.faults.clear()
        try env.store.commit(snapshot)

        let restarted = env.makeService()
        await env.bootstrap(restarted)
        XCTAssertEqual(restarted.isDshHistoryFrozen, false)
        await restarted.scanNow()
        await restarted.forceRescan()
        try assertSameDayVector(before.day, result(restarted).day, env: env)
    }

    // MARK: - A21～A23 / A25 周期重算

    func testCycleRebuildAttributesUsageToMatchingCyclesOnly() async throws {
        let env = environment!
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let currentStart = calendar.date(byAdding: .hour, value: -1, to: now) ?? now
        let currentEnd = calendar.date(byAdding: .hour, value: 1, to: now) ?? now
        let oldStart = calendar.date(byAdding: .hour, value: -6, to: now) ?? now
        let oldEnd = calendar.date(byAdding: .hour, value: -2, to: now) ?? now

        // 账号段与周期：claude 当前周期 + 已滚动的旧周期；codex 当前周期。
        env.appState.quotaCycles.records = [
            makeCycle(id: "claude-5h-current", app: .claude, accountKey: "acct-a", kind: .fiveHour, startAt: currentStart, endAt: currentEnd),
            makeCycle(id: "claude-5h-old", app: .claude, accountKey: "acct-a", kind: .fiveHour, startAt: oldStart, endAt: oldEnd),
            makeCycle(id: "codex-5h-current", app: .codex, accountKey: "acct-b", kind: .fiveHour, startAt: currentStart, endAt: currentEnd),
        ]
        env.appState.quotaCycles.accountSegments = [
            QuotaCycleAccountSegment(id: "seg-a", accountKey: "acct-a", app: .claude, startAt: calendar.date(byAdding: .day, value: -30, to: now) ?? now, endAt: nil),
            QuotaCycleAccountSegment(id: "seg-b", accountKey: "acct-b", app: .codex, startAt: calendar.date(byAdding: .day, value: -30, to: now) ?? now, endAt: nil),
        ]

        let service = try await seed(env)
        let before = result(service)
        XCTAssertFalse(before.cycle.isEmpty, "周期桶必须建立")
        for bucket in before.cycle {
            XCTAssertTrue(["claude-5h-current", "claude-5h-old", "codex-5h-current"].contains(bucket.cycleID))
            let expected = bucket.cycleID.hasPrefix("claude") ? UsageApp.claude : UsageApp.codex
            XCTAssertEqual(bucket.app, expected, "周期桶不得跨账号/跨 Provider 串期")
            XCTAssertEqual(bucket.quality, .exact)
        }

        await service.forceRescan()
        XCTAssertEqual(service.lastRebuildOutcome, .replaced(cycleVerified: true), service.lastRebuildDiagnostic ?? "")
        // A23：重复重算幂等。
        await service.forceRescan()
        XCTAssertEqual(
            UsageHistoryConsistency.cycleVector(before.cycle),
            UsageHistoryConsistency.cycleVector(result(service).cycle),
            "重复重算后周期向量必须一致"
        )
        // 周期用量与主历史一致：周期桶的 token 总量不小于同 Provider 主历史中被周期覆盖的部分。
        try assertSameDayVector(before.day, result(service).day, env: env)
    }

    func testCycleBucketsSurviveWindowRolloverWithoutLosingHistory() async throws {
        let env = environment!
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        // 旧周期已结束、新周期刚开始：滚动后旧周期桶必须保留。
        env.appState.quotaCycles.records = [
            makeCycle(
                id: "claude-week-old",
                app: .claude,
                accountKey: "acct-a",
                kind: .weekly,
                startAt: calendar.date(byAdding: .day, value: -8, to: now) ?? now,
                endAt: calendar.date(byAdding: .day, value: -1, to: now) ?? now
            ),
            makeCycle(
                id: "claude-week-current",
                app: .claude,
                accountKey: "acct-a",
                kind: .weekly,
                startAt: calendar.date(byAdding: .hour, value: -1, to: now) ?? now,
                endAt: calendar.date(byAdding: .day, value: 6, to: now) ?? now
            ),
        ]
        env.appState.quotaCycles.accountSegments = [
            QuotaCycleAccountSegment(id: "seg-a", accountKey: "acct-a", app: .claude, startAt: calendar.date(byAdding: .day, value: -60, to: now) ?? now, endAt: nil)
        ]

        let service = try await seed(env)
        let before = result(service)
        XCTAssertTrue(before.cycle.contains { $0.cycleID == "claude-week-old" })

        await service.rebuildCycleUsageForRecentChanges()
        let after = result(service)
        XCTAssertTrue(after.cycle.contains { $0.cycleID == "claude-week-old" }, "窗口滚动不得丢掉旧周期历史")
        XCTAssertEqual(
            UsageHistoryConsistency.cycleVector(before.cycle),
            UsageHistoryConsistency.cycleVector(after.cycle),
            "窗口滚动重建后周期向量必须一致"
        )
    }

    func testRebuildWithoutCycleRecordsKeepsCycleAggregatorEmpty() async throws {
        let env = environment!
        env.appState.quotaCycles.records = []
        let service = try await seed(env)
        XCTAssertTrue(result(service).cycle.isEmpty)
        await service.forceRescan()
        XCTAssertEqual(service.lastRebuildOutcome, .replaced(cycleVerified: true), service.lastRebuildDiagnostic ?? "")
        XCTAssertTrue(result(service).cycle.isEmpty)
    }

    // MARK: - A11 同一天两个会话，删除其中一个再重算

    func testDeletedClaudeSessionKeepsDayAndConversationHistoryOnRebuild() async throws {
        let env = environment!
        env.installPricing(model: model, input: 1, output: 10)
        let service = try await seed(env)
        // 同一天再放一个会话，并让它进入历史。
        let second = try env.writeClaudeLog(
            session: "safe-second",
            lines: [
                env.claudeLine(
                    id: "safe-second-1",
                    session: "safe-second",
                    model: model,
                    timestamp: timestamp(-3, from: Date()),
                    input: 4_000,
                    output: 400,
                    speed: "standard"
                )
            ]
        )
        await service.scanNow()
        await service.flushPendingRollupChangesForTesting()
        let withTwo = result(service)
        XCTAssertTrue(withTwo.infos.contains { $0.key == "claude:safe-session" })
        XCTAssertTrue(withTwo.infos.contains { $0.key == "claude:safe-second" })

        // 删除其中一个会话文件：普通增量与重算都必须保留它的历史，重算按新价重新计费。
        try FileManager.default.removeItem(at: second)
        await service.scanNow()
        try assertSameDayVector(withTwo.day, result(service).day, env: env)
        env.installPricing(model: model, input: 2, output: 20)
        await service.forceRescan()
        XCTAssertEqual(service.lastRebuildOutcome, .replaced(cycleVerified: true), service.lastRebuildDiagnostic ?? "")
        XCTAssertNil(service.lastRebuildDiagnostic, "保留已删除会话后，用量必须与重算前完全一致")
        let keptCost = result(service).conversation
            .filter { $0.conversationKey == "claude:safe-second" }
            .reduce(Decimal(0)) { $0 + $1.costUSD }
        XCTAssertEqual(keptCost, Decimal(4_000) * 2 / 1_000_000 + Decimal(400) * 20 / 1_000_000, "已删除会话按新价重新计费")
        XCTAssertEqual(dayCost(result(service).day, model: model), expectedCost(result(service).day, input: 2, output: 20))
        XCTAssertEqual(Set(result(service).infos.map(\.key)), Set(withTwo.infos.map(\.key)), "对话档案不得因重算被删")
        XCTAssertEqual(
            env.conversationVector(result(service).conversation),
            env.conversationVector(withTwo.conversation),
            "对话用量桶不得因重算被删"
        )
        try assertSameDayVector(withTwo.day, try committed(env).usageRollup.buckets, env: env)
    }

    // MARK: - A12 删除旧会话、新增等量会话：旧会话保留，新会话照常计入

    func testDeletedSessionIsKeptAlongsideEqualNewSession() async throws {
        let env = environment!
        env.installPricing(model: model, input: 1, output: 10)
        try env.writeClaudeLog(
            session: "swap-a",
            lines: [
                env.claudeLine(id: "swap-a-1", session: "swap-a", model: model, timestamp: timestamp(-3, from: Date()), input: 1_000, output: 100, speed: "standard")
            ]
        )
        let service = env.makeService()
        await env.bootstrap(service)
        await service.scanNow()
        let baseline = result(service)
        let baselineTokens = env.totals(baseline.day)

        // 删除旧会话，新增一个等量（同一天、同模型、同档位）的新会话：总量不变，键不同。
        try FileManager.default.removeItem(at: env.claudeRoot.appendingPathComponent("fixture-project/swap-a.jsonl"))
        try env.writeClaudeLog(
            session: "swap-b",
            lines: [
                env.claudeLine(id: "swap-b-1", session: "swap-b", model: model, timestamp: timestamp(-3, from: Date()), input: 1_000, output: 100, speed: "standard")
            ]
        )
        await service.forceRescan()
        XCTAssertEqual(service.lastRebuildOutcome, .replaced(cycleVerified: true), service.lastRebuildDiagnostic ?? "")
        // 同一天同桶的等量新会话不能被当成已删除会话的替身：两者都在。
        XCTAssertTrue(result(service).infos.contains { $0.key == "claude:swap-a" }, "已删除会话的历史不得消失")
        XCTAssertTrue(result(service).infos.contains { $0.key == "claude:swap-b" })
        XCTAssertEqual(
            env.totals(result(service).day, app: .claude).inputTokens,
            baselineTokens.inputTokens + 1_000,
            "保留的旧会话 + 新收集的会话，两者都在"
        )

        // 再换成「总量相同但落在另一天」：日键不同，仍必须拒绝。
        try FileManager.default.removeItem(at: env.claudeRoot.appendingPathComponent("fixture-project/swap-b.jsonl"))
        try env.writeClaudeLog(
            session: "swap-c",
            lines: [
                env.claudeLine(id: "swap-c-1", session: "swap-c", model: model, timestamp: timestamp(-4, from: Date()), input: 1_000, output: 100, speed: "standard")
            ]
        )
        await service.forceRescan()
        XCTAssertEqual(service.lastRebuildOutcome, .replaced(cycleVerified: true), service.lastRebuildDiagnostic ?? "")
        XCTAssertEqual(env.totals(result(service).day, app: .claude).inputTokens, baselineTokens.inputTokens + 2_000)
        XCTAssertTrue(result(service).infos.contains { $0.key == "claude:swap-a" })
        XCTAssertTrue(result(service).infos.contains { $0.key == "claude:swap-b" })
        XCTAssertTrue(result(service).infos.contains { $0.key == "claude:swap-c" })
    }

    /// A13 的可辨识性限制：同一天同一完整桶内的事件替换，只要聚合向量不变就无法识别。
    /// 记录为已知限制：日志只提供聚合事实，代理层不可能复原「哪些事件构成这批 token」。
    func testEqualReplacementInsideSameBucketIsIndistinguishable() async throws {
        let env = environment!
        env.installPricing(model: model, input: 1, output: 10)
        let logURL = env.claudeRoot.appendingPathComponent("fixture-project/safe-session.jsonl")
        try env.writeClaudeLog(
            session: "safe-session",
            lines: [
                env.claudeLine(id: "safe-1", session: "safe-session", model: model, timestamp: timestamp(-3, from: Date()), input: 1_000, output: 100, speed: "standard"),
                env.claudeLine(id: "safe-2", session: "safe-session", model: model, timestamp: timestamp(-3, from: Date()), input: 2_000, output: 200, speed: "standard"),
            ]
        )
        let service = env.makeService()
        await env.bootstrap(service)
        await service.scanNow()
        let before = result(service)
        let attributes = try FileManager.default.attributesOfItem(atPath: logURL.path)

        // 等长原地改写：把两条消息的 token 互换（1000/2000 → 2000/1000），
        // 聚合向量完全相同，文件大小与 mtime 保持不变，增量与全量都无法分辨。
        var text = try XCTUnwrap(String(data: Data(contentsOf: logURL), encoding: .utf8))
        text = text.replacingOccurrences(of: #""input_tokens":1000"#, with: #""input_tokens":2002"#)
        text = text.replacingOccurrences(of: #""input_tokens":2000"#, with: #""input_tokens":1000"#)
        text = text.replacingOccurrences(of: #""input_tokens":2002"#, with: #""input_tokens":2000"#)
        try Data(text.utf8).write(to: logURL)
        if let mtime = attributes[.modificationDate] as? Date {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: logURL.path)
        }

        await service.forceRescan()
        XCTAssertEqual(
            service.lastRebuildOutcome,
            .replaced(cycleVerified: true),
            "同桶等量替换在向量层面不可辨识，重算会照常通过——已知限制，不是校验回归"
        )
        try assertSameDayVector(before.day, result(service).day, env: env)
        XCTAssertEqual(
            env.conversationVector(before.conversation),
            env.conversationVector(result(service).conversation)
        )
    }

    // MARK: - A15 / A21 提交失败后重试与普通扫描不重复累计

    func testCommitFaultThenOrdinaryScanAppliesOnceAndSurvivesRestart() async throws {
        let env = environment!
        env.installPricing(model: model, input: 1, output: 10)
        let service = try await seed(env)
        let before = result(service)
        let diskBefore = try committed(env)

        // 换价（计数不变，金额要变）后让提交失败：内存与磁盘都保持旧价。
        env.installPricing(model: model, input: 10, output: 100, cacheRead: 1, cacheCreation: 5)
        env.faults.fail(at: .beforeCurrentReplace)
        await service.forceRescan()
        XCTAssertEqual(service.lastRebuildOutcome, .commitFailed("injected fault at beforeCurrentReplace"))
        XCTAssertEqual(dayCost(result(service).day, model: model), dayCost(before.day, model: model))
        XCTAssertEqual(try committed(env).snapshotID, diskBefore.snapshotID)
        try assertSameDayVector(before.day, result(service).day, env: env)

        // 重试成功：只提交一次，金额换成新价，计数不变。
        env.faults.clear()
        await service.forceRescan()
        XCTAssertEqual(service.lastRebuildOutcome, .replaced(cycleVerified: true), service.lastRebuildDiagnostic ?? "")
        XCTAssertEqual(dayCost(result(service).day, model: model), dayCost(before.day, model: model) * 10)
        try assertSameDayVector(before.day, result(service).day, env: env)

        // 之后普通增量与重启都不能重复累计。
        await service.scanNow()
        try assertSameDayVector(before.day, result(service).day, env: env)
        let restarted = env.makeService()
        await env.bootstrap(restarted)
        await restarted.scanNow()
        try assertSameDayVector(before.day, result(restarted).day, env: env)
        XCTAssertEqual(dayCost(result(restarted).day, model: model), dayCost(before.day, model: model) * 10)
    }

    // MARK: - A16 缺价刷新的第二轮失败

    func testPricingRefreshSecondRoundFailureKeepsFirstResultAndReportsPartial() async throws {
        let env = environment!
        let unpricedModel = "ccbar-unpriced-model"
        try env.writeClaudeLog(
            session: "unpriced-session",
            lines: [
                env.claudeLine(
                    id: "unpriced-1",
                    session: "unpriced-session",
                    model: unpricedModel,
                    timestamp: timestamp(-3, from: Date()),
                    input: 1_000,
                    output: 100,
                    speed: "standard"
                )
            ]
        )
        let service = env.makeService()
        await env.bootstrap(service)
        await service.scanNow()
        let before = result(service)
        XCTAssertGreaterThan(env.totals(before.day, app: .claude).inputTokens, 0)
        XCTAssertEqual(dayCost(before.day, model: unpricedModel), 0, "无价格时该桶金额为 0")

        // 缺价刷新在第二轮拿到新价格，但第二轮提交失败。
        PricingCatalogStore.shared.setMissingRefreshHandlerForTesting { _ in
            await env.installPricing(model: unpricedModel, input: 100, output: 1_000)
            return true
        }
        defer { PricingCatalogStore.shared.setMissingRefreshHandlerForTesting(nil) }
        env.faults.fail(at: .beforeCurrentReplace, occurrence: 2)
        await service.forceRescan()

        guard case .partiallyCommitted = service.lastRebuildOutcome else {
            return XCTFail("第二轮失败必须报告为部分完成，实际：\(String(describing: service.lastRebuildOutcome))")
        }
        XCTAssertNotEqual(service.lastRebuildOutcome, .replaced(cycleVerified: true), "不能显示为完整成功")
        try assertSameDayVector(before.day, result(service).day, env: env)
        // 第一轮已经生效并被回滚到该轮状态：金额仍是第一轮（未刷价前 0），磁盘与内存一致。
        XCTAssertEqual(dayCost(result(service).day, model: unpricedModel), 0)
        XCTAssertTrue(
            result(service).day.contains { $0.model == unpricedModel && $0.hasUnpricedUsage },
            "缺价标记必须随回滚一起保留"
        )
        try assertSameDayVector(result(service).day, try committed(env).usageRollup.buckets, env: env)
    }

    // MARK: - A19 周期重建提交失败

    func testCycleRebuildCommitFailureKeepsCycleBucketsAndMarkers() async throws {
        let env = environment!
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        env.appState.quotaCycles.records = [
            makeCycle(
                id: "claude-cycle",
                app: .claude,
                accountKey: "acct-a",
                kind: .fiveHour,
                startAt: calendar.date(byAdding: .hour, value: -1, to: now) ?? now,
                endAt: calendar.date(byAdding: .hour, value: 1, to: now) ?? now
            )
        ]
        env.appState.quotaCycles.accountSegments = [
            QuotaCycleAccountSegment(id: "seg-a", accountKey: "acct-a", app: .claude, startAt: calendar.date(byAdding: .day, value: -30, to: now) ?? now, endAt: nil)
        ]
        let service = try await seed(env)
        let before = result(service)
        let diskBefore = try committed(env)
        XCTAssertFalse(before.cycle.isEmpty)

        env.faults.fail(at: .beforeCurrentReplace)
        await service.rebuildCycleUsageForRecentChanges()
        XCTAssertEqual(
            UsageHistoryConsistency.cycleVector(before.cycle),
            UsageHistoryConsistency.cycleVector(result(service).cycle),
            "周期重建提交失败后周期桶必须与提交前一致"
        )
        try assertSameDayVector(before.day, result(service).day, env: env)
        let diskAfter = try committed(env)
        XCTAssertEqual(diskAfter.snapshotID, diskBefore.snapshotID, "失败不得提前更新磁盘")
        XCTAssertEqual(
            diskAfter.cycleRollup.effectiveInitialRebuildCompletedApps,
            diskBefore.cycleRollup.effectiveInitialRebuildCompletedApps,
            "失败不得提前写入周期初始重建完成标记"
        )
        XCTAssertEqual(diskAfter.cycleRollup.initialRebuildCompletedAt, diskBefore.cycleRollup.initialRebuildCompletedAt)

        // 新实例可对账。
        env.faults.clear()
        let restarted = env.makeService()
        await env.bootstrap(restarted)
        await restarted.scanNow()
        try assertSameDayVector(before.day, result(restarted).day, env: env)
        XCTAssertEqual(
            UsageHistoryConsistency.cycleVector(before.cycle),
            UsageHistoryConsistency.cycleVector(result(restarted).cycle)
        )
    }

    // MARK: - A20 一次性历史补录

    func testImportedBackfillCountsOnceAcrossScanRebuildAndRestart() async throws {
        let env = environment!
        env.installPricing(model: model, input: 1, output: 10)
        // 补录文件：一天有、一天没有（后者由真实日志覆盖，补录必须让位）。
        let scannedDay = UsageDay.startOfDay(for: Date())
        let backfillOnlyDay = UsageDay.startOfDay(
            for: Calendar(identifier: .gregorian).date(byAdding: .day, value: -200, to: Date()) ?? Date()
        )
        let backfill = [
            UsageBucket(
                app: .claude,
                model: model,
                speed: .standard,
                day: backfillOnlyDay,
                inputTokens: 12_345,
                outputTokens: 678,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                costUSD: 0,
                requestCount: 7,
                hasUnpricedUsage: true
            ),
            UsageBucket(
                app: .claude,
                model: model,
                speed: .standard,
                day: scannedDay,
                inputTokens: 999_999,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                costUSD: 0,
                requestCount: 1,
                hasUnpricedUsage: true
            ),
        ]
        try JSONEncoder().encode(backfill).write(to: env.backfillURL)

        let service = try await seed(env)
        let scanned = result(service)
        let backfillEntry = env.dayVector(scanned.day)[
            UsageVectorKey(app: .claude, day: backfillOnlyDay, model: model, speed: .standard)
        ]
        XCTAssertEqual(backfillEntry?.inputTokens, 12_345, "补录历史必须恰好计入一次")
        XCTAssertEqual(backfillEntry?.requestCount, 7)
        // 既有边界（本轮不改行为）：补录只进日聚合，不虚构不存在的会话档案与对话桶。
        XCTAssertFalse(result(service).infos.contains { $0.key.hasPrefix("imported:") })
        XCTAssertFalse(result(service).conversation.contains { $0.conversationKey.hasPrefix("imported:") })
        // 去重语义直接验证：聚合器里已有该日期时，补录不再返回这一天。
        XCTAssertTrue(
            ImportedUsageBackfill.loadMissingEntries(
                app: .claude,
                existingDays: [backfillOnlyDay, scannedDay],
                from: env.backfillURL
            ).isEmpty,
            "补录必须按日期让位，不能与已有日期的数据叠加"
        )
        XCTAssertEqual(
            ImportedUsageBackfill.loadMissingEntries(
                app: .claude,
                existingDays: [],
                from: env.backfillURL
            ).count,
            2
        )

        await service.forceRescan()
        XCTAssertEqual(service.lastRebuildOutcome, .replaced(cycleVerified: true), service.lastRebuildDiagnostic ?? "")
        XCTAssertEqual(
            env.dayVector(result(service).day)[UsageVectorKey(app: .claude, day: backfillOnlyDay, model: model, speed: .standard)]?.inputTokens,
            12_345,
            "重算后补录不得翻倍"
        )

        let restarted = env.makeService()
        await env.bootstrap(restarted)
        await restarted.scanNow()
        XCTAssertEqual(
            env.dayVector(result(restarted).day)[UsageVectorKey(app: .claude, day: backfillOnlyDay, model: model, speed: .standard)]?.inputTokens,
            12_345,
            "重启后补录不得翻倍"
        )
        try assertSameDayVector(result(service).day, result(restarted).day, env: env)
    }

    // MARK: - A22 并发手动重算 / 普通扫描

    func testConcurrentScanAndRebuildProcessNewEventsExactlyOnce() async throws {
        let env = environment!
        env.installPricing(model: model, input: 1, output: 10)
        let service = try await seed(env)
        let before = env.totals(result(service).day, app: .claude).inputTokens
        let queuedScan = expectation(description: "queued scan consumed appended event")
        service.candidateReadyForTesting = { [weak service] in
            guard let service else { return }
            // 此时候选已读完旧日志，但重算尚未提交。明确在这段窗口追加并排队普通扫描。
            do {
                try env.append(
                    env.claudeLine(id: "concurrent-1", session: "safe-session", model: self.model, timestamp: self.timestamp(-0.25, from: Date()), input: 1_111, output: 111, speed: "standard"),
                    to: env.claudeRoot.appendingPathComponent("fixture-project/safe-session.jsonl")
                )
            } catch { XCTFail("append failed: \(error)") }
            await service.scanNow()
            XCTAssertTrue(service.isScanning)
            service.candidateReadyForTesting = nil
            Task { @MainActor in
                // 等待生产排队任务完成，不能用测试主动再扫掩盖漏排队。
                for _ in 0..<500 {
                    if !service.isScanning && env.totals(self.result(service).day, app: .claude).inputTokens == before + 1_111 {
                        queuedScan.fulfill()
                        return
                    }
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
            }
        }
        await service.forceRescan()
        await fulfillment(of: [queuedScan], timeout: 8)
        XCTAssertEqual(env.totals(result(service).day, app: .claude).inputTokens, before + 1_111)

        // 独立目录、无快照、仅复制日志，真正从零建立对照。
        let clean = try UsageTestEnvironment(name: "independent-authority")
        try clean.copySources(from: env)
        clean.installPricing(model: model, input: 1, output: 10)
        let authority = clean.makeService()
        await clean.bootstrap(authority)
        await authority.scanNow()
        try assertSameDayVector(result(authority).day, result(service).day, env: env)
        XCTAssertEqual(env.conversationVector(result(authority).conversation), env.conversationVector(result(service).conversation))
        await service.flushPendingRollupChangesForTesting()
        let restarted = env.makeService()
        await env.bootstrap(restarted)
        await restarted.scanNow()
        try assertSameDayVector(result(authority).day, result(restarted).day, env: env)
    }

    func testWatermarkOnlyChangesAreDeferredAndExplicitDrainCommitsThem() async throws {
        let env = environment!
        let service = try await seed(env)
        let count = env.stats.commitCount
        let before = try committed(env).scanState
        let url = env.claudeRoot.appendingPathComponent("fixture-project/safe-session.jsonl")
        try env.append("{\"type\":\"user\",\"sessionId\":\"safe-session\"}", to: url)
        await service.scanNow()
        await service.scanNow()
        XCTAssertEqual(env.stats.commitCount, count)
        XCTAssertEqual(try committed(env).scanState, before)
        await service.flushPendingRollupChangesForTesting()
        XCTAssertEqual(env.stats.commitCount, count + 1)
        XCTAssertNotEqual(try committed(env).scanState, before)
        let restarted = env.makeService()
        await env.bootstrap(restarted)
        await restarted.scanNow()
        try assertSameDayVector(result(service).day, result(restarted).day, env: env)
    }

    func testDshConflictRejectsCandidateWithoutChangingCommittedHistory() async throws {
        let env = environment!
        let service = try await seed(env)
        let before = try committed(env)
        try env.writeDshLog(project: "other-project", session: "dsh-safe", records: [
            DshTestFixtures.session(id: "dsh-safe"),
            DshTestFixtures.assistant(time: DshTestFixtures.baseTime + 1_000, input: 1, output: 1),
        ])
        let scan = DshSessionScanner.scan(previous: [:], root: env.dshRoot)
        XCTAssertGreaterThan(scan.duplicateSessionCount, 0)
        await service.forceRescan()
        XCTAssertEqual(service.lastRebuildOutcome, .rejectedIncompleteSources("DSH"))
        try assertSameDayVector(before.usageRollup.buckets, result(service).day, env: env)
        XCTAssertEqual(env.conversationVector(before.conversationRollup.buckets), env.conversationVector(result(service).conversation))
    }

    func testCorruptOpenCodeDatabaseRejectsCandidate() async throws {
        let env = environment!
        let service = try await seed(env)
        let before = result(service)
        try Data("invalid sqlite database".utf8).write(to: env.opencodeDatabaseURL)
        await service.forceRescan()
        XCTAssertEqual(service.lastRebuildOutcome, .rejectedIncompleteSources("OpenCode"))
        try assertSameDayVector(before.day, result(service).day, env: env)
    }

    func testTerminationPersistsPendingUsageWithoutScanningNewLogEntries() async throws {
        let env = environment!
        let service = try await seed(env)
        let before = try committed(env)
        let initialTokens = env.totals(before.usageRollup.buckets, app: .claude).inputTokens
        let url = env.claudeRoot.appendingPathComponent("fixture-project/safe-session.jsonl")
        try env.append(
            env.claudeLine(id: "quit-read", session: "safe-session", model: model,
                           timestamp: timestamp(-0.1, from: Date()), input: 1_111, output: 111),
            to: url
        )
        await service.scanNow()
        XCTAssertEqual(try committed(env).snapshotID, before.snapshotID)
        try env.append(
            env.claudeLine(id: "quit-unread", session: "safe-session", model: model,
                           timestamp: timestamp(-0.05, from: Date()), input: 2_222, output: 222),
            to: url
        )
        service.suspendForTermination()
        try await service.persistPendingForTermination()
        let saved = try committed(env)
        XCTAssertEqual(env.totals(saved.usageRollup.buckets, app: .claude).inputTokens, initialTokens + 1_111,
                       "退出只保存已经读取的状态，不能额外扫描后追加的日志")
        let restarted = env.makeService()
        await env.bootstrap(restarted)
        await restarted.scanNow()
        XCTAssertEqual(env.totals(result(restarted).day, app: .claude).inputTokens, initialTokens + 3_333,
                       "退出时保存的 watermark 必须与汇总一致，重启可补齐未读取的日志")
    }

    func testFailedTerminationSavePreservesPendingUsageForRetry() async throws {
        let env = environment!
        let service = try await seed(env)
        let before = try committed(env)
        let initialTokens = env.totals(before.usageRollup.buckets, app: .claude).inputTokens
        try env.append(
            env.claudeLine(id: "quit-retry", session: "safe-session", model: model,
                           timestamp: timestamp(-0.1, from: Date()), input: 1_111, output: 111),
            to: env.claudeRoot.appendingPathComponent("fixture-project/safe-session.jsonl")
        )
        await service.scanNow()
        service.suspendForTermination()
        env.faults.fail(at: .beforeCurrentReplace)
        do {
            try await service.persistPendingForTermination()
            XCTFail("保存失败必须取消退出")
        } catch {}
        XCTAssertEqual(try committed(env).snapshotID, before.snapshotID)
        XCTAssertEqual(env.totals(result(service).day, app: .claude).inputTokens, initialTokens + 1_111)
        try await service.persistPendingForTermination()
        XCTAssertEqual(env.totals(try committed(env).usageRollup.buckets, app: .claude).inputTokens,
                       initialTokens + 1_111, "取消退出后的重试必须保留并保存 pending 用量")
    }

    // MARK: - A23 写盘窗口内不重复写大快照

    func testUnchangedScanDoesNotRewriteSnapshotAndDeferredChangesSurviveRestart() async throws {
        let env = environment!
        env.installPricing(model: model, input: 1, output: 10)
        let service = try await seed(env)
        let commitsAfterSeed = env.stats.commitCount
        let encodesAfterSeed = env.stats.encodeCount

        // 无变化轮次：既不重复编码也不写盘。
        await service.scanNow()
        XCTAssertEqual(env.stats.commitCount, commitsAfterSeed, "无变化不得重写大快照")
        XCTAssertEqual(env.stats.encodeCount, encodesAfterSeed)

        // 未到写盘窗口的新增：只更新内存，进度一并压住。
        try env.append(
            env.claudeLine(id: "deferred-1", session: "safe-session", model: model, timestamp: timestamp(-0.1, from: Date()), input: 2_222, output: 222, speed: "standard") + "\n",
            to: env.claudeRoot.appendingPathComponent("fixture-project/safe-session.jsonl")
        )
        await service.scanNow()
        XCTAssertEqual(env.stats.commitCount, commitsAfterSeed, "节流窗口内不得写盘")
        let inMemory = result(service)

        // 重启：磁盘是「旧汇总 + 旧进度」，重扫同一批日志后结果与内存一致（不丢不重）。
        let restarted = env.makeService()
        await env.bootstrap(restarted)
        await restarted.scanNow()
        try assertSameDayVector(inMemory.day, result(restarted).day, env: env)
        XCTAssertEqual(env.totals(result(restarted).day, app: .claude).inputTokens, env.totals(inMemory.day, app: .claude).inputTokens)
    }

    // MARK: - A25 日志在两次重算之间变化：重算以当时的日志为准，普通增量继续工作

    func testRebuildAppliesCurrentLogsAndIncrementalScanContinues() async throws {
        let env = environment!
        env.installPricing(model: model, input: 1, output: 10)
        let service = try await seed(env)
        let before = result(service)
        let logURL = env.claudeRoot.appendingPathComponent("fixture-project/safe-session.jsonl")
        let attributes = try FileManager.default.attributesOfItem(atPath: logURL.path)
        var text = try XCTUnwrap(String(data: Data(contentsOf: logURL), encoding: .utf8))
        text = text.replacingOccurrences(of: #""input_tokens":2000"#, with: #""input_tokens":9000"#)
        try Data(text.utf8).write(to: logURL)
        if let mtime = attributes[.modificationDate] as? Date {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: logURL.path)
        }

        await service.forceRescan()
        XCTAssertEqual(service.lastRebuildOutcome, .replaced(cycleVerified: true), service.lastRebuildDiagnostic ?? "")
        XCTAssertEqual(service.historyRecoveryState, .complete)
        XCTAssertEqual(
            env.totals(result(service).day, app: .claude).inputTokens,
            env.totals(before.day, app: .claude).inputTokens + 7_000
        )

        // 重算后普通增量从新的进度继续，追加的条目只计一次。
        try env.append(
            env.claudeLine(id: "settled-1", session: "safe-session", model: model, timestamp: timestamp(-0.05, from: Date()), input: 333, output: 33, speed: "standard") + "\n",
            to: logURL
        )
        await service.scanNow()
        let afterIncrement = result(service)
        XCTAssertEqual(
            env.totals(afterIncrement.day, app: .claude).inputTokens,
            env.totals(before.day, app: .claude).inputTokens + 7_000 + 333
        )

        // 日志不再变化时重复重算，结果与增量一致（幂等）。
        await service.forceRescan()
        XCTAssertEqual(service.lastRebuildOutcome, .replaced(cycleVerified: true), service.lastRebuildDiagnostic ?? "")
        XCTAssertNil(service.lastRebuildDiagnostic)
        try assertSameDayVector(afterIncrement.day, result(service).day, env: env)
    }

    // MARK: - 续接 / 分叉对话

    /// 续接出来的会话会复制原会话的消息（同一 message.id）。重算必须和增量扫描一样把它们
    /// 归给原会话，否则日志都在也会出现对话归属差异。
    func testForkedSessionMessagesStayWithOriginalConversationOnRebuild() async throws {
        let env = environment!
        env.installPricing(model: model, input: 1, output: 10)
        // 原会话的文件名排在后面，证明归属靠创建先后而不是路径顺序。
        try env.writeClaudeLog(session: "fork-original", lines: forkOriginalLines(env, session: "fork-original"), file: "zz-original.jsonl")
        let service = env.makeService()
        await env.bootstrap(service)
        await service.scanNow()
        try env.writeClaudeLog(session: "fork-continued", lines: forkContinuedLines(env), file: "aa-continued.jsonl")
        await service.scanNow()
        let before = result(service)
        XCTAssertEqual(env.totals(before.day, app: .claude).inputTokens, 7_000)

        await service.forceRescan()
        XCTAssertEqual(service.lastRebuildOutcome, .replaced(cycleVerified: true), service.lastRebuildDiagnostic ?? "")
        XCTAssertNil(service.lastRebuildDiagnostic, "续接对话的归属必须与增量扫描一致")
        XCTAssertEqual(env.conversationVector(before.conversation), env.conversationVector(result(service).conversation))
    }

    /// 原会话日志被删、续接会话还在：账本里有原会话的消息 ID，重算时续接会话不会再计入
    /// 复制过去的消息，原会话的用量原样保留，归属与增量扫描一致。
    func testForkedMessagesAreNotCountedTwiceAfterOriginalLogIsDeleted() async throws {
        let env = environment!
        env.installPricing(model: model, input: 1, output: 10)
        let original = try env.writeClaudeLog(session: "fork-original", lines: forkOriginalLines(env, session: "fork-original"))
        let service = env.makeService()
        await env.bootstrap(service)
        await service.scanNow()
        try env.writeClaudeLog(session: "fork-continued", lines: forkContinuedLines(env))
        await service.scanNow()
        let before = result(service)
        XCTAssertEqual(env.totals(before.day, app: .claude).inputTokens, 7_000)

        try FileManager.default.removeItem(at: original)
        await service.forceRescan()
        XCTAssertEqual(service.lastRebuildOutcome, .replaced(cycleVerified: true), service.lastRebuildDiagnostic ?? "")
        XCTAssertNil(service.lastRebuildDiagnostic, "有账本时被删原会话的用量与归属都不变")
        try assertSameDayVector(before.day, result(service).day, env: env)
        XCTAssertEqual(env.conversationVector(before.conversation), env.conversationVector(result(service).conversation))
        XCTAssertTrue(result(service).infos.contains { $0.key == "claude:fork-original" })
    }

    /// 账本建立之前就删除的会话没有消息 ID，只能按日核对：续接会话在重扫里计入了复制的消息，
    /// 同一键上已不少于历史，被删的原会话不再叠加。
    func testDeletedConversationWithoutLedgerFallsBackToDayGuard() async throws {
        let env = environment!
        env.installPricing(model: model, input: 1, output: 10)
        let original = try env.writeClaudeLog(session: "fork-original", lines: forkOriginalLines(env, session: "fork-original"))
        let service = env.makeService()
        await env.bootstrap(service)
        await service.scanNow()
        try env.writeClaudeLog(session: "fork-continued", lines: forkContinuedLines(env))
        await service.scanNow()
        await service.flushPendingRollupChangesForTesting()
        let before = result(service)

        // 模拟旧版本写的快照：没有账本与基准。
        try stripRebuildState(env)
        let restarted = env.makeService()
        await env.bootstrap(restarted)
        try FileManager.default.removeItem(at: original)
        await restarted.forceRescan()
        XCTAssertEqual(restarted.lastRebuildOutcome, .replaced(cycleVerified: true), restarted.lastRebuildDiagnostic ?? "")
        try assertSameDayVector(before.day, result(restarted).day, env: env)
        XCTAssertFalse(result(restarted).infos.contains { $0.key == "claude:fork-original" })
        XCTAssertEqual(
            result(restarted).conversation
                .filter { $0.conversationKey == "claude:fork-continued" }
                .reduce(0) { $0 + $1.inputTokens },
            7_000
        )
        // 重算后账本从现有日志补齐。
        XCTAssertNotNil(try committed(env).rebuildBasis)
        XCTAssertNotNil(try committed(env).messageLedger)
    }

    // MARK: - 消息账本

    /// 基准建立后不再保存 2 万条上限的 seen 列表；账本随快照保存，重启后照样去重续接会话复制的消息。
    func testLedgerReplacesSeenListsAndSurvivesRestart() async throws {
        let env = environment!
        env.installPricing(model: model, input: 1, output: 10)
        try env.writeClaudeLog(session: "fork-original", lines: forkOriginalLines(env, session: "fork-original"))
        let service = env.makeService()
        await env.bootstrap(service)
        await service.scanNow()

        let snapshot = try committed(env)
        XCTAssertNotNil(snapshot.rebuildBasis)
        XCTAssertTrue(snapshot.scanState.claudeSeenMessageIds.isEmpty)
        let ledger = UsageMessageLedger(payload: snapshot.messageLedger)
        XCTAssertEqual(
            ledger.ids(for: ["claude:fork-original"], app: .claude),
            [SeenIDSet.digest("fork-1"), SeenIDSet.digest("fork-2")]
        )

        let restarted = env.makeService()
        await env.bootstrap(restarted)
        try env.writeClaudeLog(session: "fork-continued", lines: forkContinuedLines(env))
        await restarted.scanNow()
        XCTAssertEqual(env.totals(result(restarted).day, app: .claude).inputTokens, 7_000, "复制过去的消息不得重复计入")
        XCTAssertEqual(
            result(restarted).conversation
                .filter { $0.conversationKey == "claude:fork-continued" }
                .reduce(0) { $0 + $1.inputTokens },
            4_000
        )
    }

    /// 按日核对的缺口：同一天同一模型有两个被删会话、其中一个被续接时，按日核对会重复计入。
    /// 有账本时两个被删会话都原样保留，续接会话只计自己的新消息。
    func testTwoDeletedConversationsOnSameDayAreKeptExactlyWithLedger() async throws {
        let env = environment!
        env.installPricing(model: model, input: 1, output: 10)
        let first = try env.writeClaudeLog(session: "gone-a", lines: forkOriginalLines(env, session: "gone-a"))
        let second = try env.writeClaudeLog(session: "gone-b", lines: [
            env.claudeLine(id: "gone-b-1", session: "gone-b", model: model, timestamp: timestamp(-0.4, from: forkReference), input: 8_000, output: 800, speed: "standard"),
        ])
        let service = env.makeService()
        await env.bootstrap(service)
        await service.scanNow()
        try env.writeClaudeLog(session: "fork-continued", lines: forkContinuedLines(env))
        await service.scanNow()
        let before = result(service)
        XCTAssertEqual(env.totals(before.day, app: .claude).inputTokens, 15_000)

        try FileManager.default.removeItem(at: first)
        try FileManager.default.removeItem(at: second)
        await service.forceRescan()
        XCTAssertEqual(service.lastRebuildOutcome, .replaced(cycleVerified: true), service.lastRebuildDiagnostic ?? "")
        XCTAssertEqual(env.totals(result(service).day, app: .claude).inputTokens, 15_000)
        XCTAssertEqual(env.conversationVector(before.conversation), env.conversationVector(result(service).conversation))
    }

    /// 补录只填没有任何 Claude 用量的天：被删会话保留下来的那天不能再叠加补录。
    func testBackfillDoesNotStackOnPreservedConversation() async throws {
        let env = environment!
        env.installPricing(model: model, input: 1, output: 10)
        let day = UsageDay.startOfDay(for: forkReference.addingTimeInterval(-0.6 * 3_600))
        try JSONEncoder().encode([
            UsageBucket(
                app: .claude, model: model, speed: .standard, day: day,
                inputTokens: 999_999, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0,
                costUSD: 0, requestCount: 1, hasUnpricedUsage: true
            ),
        ]).write(to: env.backfillURL)
        let original = try env.writeClaudeLog(session: "fork-original", lines: forkOriginalLines(env, session: "fork-original"))
        let service = env.makeService()
        await env.bootstrap(service)
        await service.scanNow()
        XCTAssertEqual(env.totals(result(service).day, app: .claude).inputTokens, 3_000)

        try FileManager.default.removeItem(at: original)
        await service.forceRescan()
        XCTAssertEqual(service.lastRebuildOutcome, .replaced(cycleVerified: true), service.lastRebuildDiagnostic ?? "")
        XCTAssertEqual(env.totals(result(service).day, app: .claude).inputTokens, 3_000)
    }

    func testLedgerDigestIsStableAndPayloadRoundTrips() {
        // SHA-256("abc") 前 8 字节按小端序；改动摘要算法会让已保存的账本全部失效。
        XCTAssertEqual(SeenIDSet.digest("abc"), 0xeacf_018f_bf16_78ba)
        var ledger = UsageMessageLedger()
        ledger.record(["claude:a": [1, 2], "claude:b": [3]], app: .claude)
        ledger.record(["codex:c": [UInt64.max]], app: .codex)
        let restored = UsageMessageLedger(payload: ledger.payload)
        XCTAssertEqual(restored.conversations[.claude]?["claude:a"], [1, 2])
        XCTAssertEqual(restored.conversations[.claude]?["claude:b"], [3])
        XCTAssertEqual(restored.knownIDs(for: .codex), [UInt64.max])
        var unknown = ledger.payload
        unknown.version = UsageMessageLedgerPayload.currentVersion + 1
        XCTAssertTrue(UsageMessageLedger(payload: unknown).isEmpty)
    }

    // MARK: - 自动重建

    /// 旧版本快照没有基准：升级后第一次扫描自动重建一次，补齐账本；之后不再重复。
    func testAutomaticRebuildRunsOnceAfterUpgrade() async throws {
        let env = environment!
        env.installPricing(model: model, input: 1, output: 10)
        let service = try await seed(env)
        await service.flushPendingRollupChangesForTesting()
        let before = result(service)
        try stripRebuildState(env)

        let restarted = env.makeService()
        restarted.automaticRebuildEnabled = true
        await env.bootstrap(restarted)
        await restarted.scanNow()
        let snapshot = try committed(env)
        XCTAssertNotNil(snapshot.rebuildBasis)
        XCTAssertNotNil(snapshot.messageLedger)
        XCTAssertTrue(snapshot.scanState.claudeSeenMessageIds.isEmpty)
        XCTAssertTrue(snapshot.scanState.codexSeenTokenIds.isEmpty)
        try assertSameDayVector(before.day, result(restarted).day, env: env)

        let commits = env.stats.commitCount
        await restarted.scanNow()
        XCTAssertEqual(env.stats.commitCount, commits, "基准与现行规则一致后不再重建")
    }

    /// 原来缺价的用量拿到价格后立即自动重算，不等 24 小时。
    func testAutomaticRebuildRepricesNewlyPricedUsage() async throws {
        let env = environment!
        try env.writeClaudeLog(session: "fork-original", lines: forkOriginalLines(env, session: "fork-original"))
        let service = env.makeService()
        service.automaticRebuildEnabled = true
        await env.bootstrap(service)
        await service.scanNow()
        XCTAssertTrue(result(service).day.allSatisfy(\.hasUnpricedUsage))

        env.installPricing(model: model, input: 1, output: 10)
        await service.scanNow()
        XCTAssertFalse(result(service).day.contains(where: \.hasUnpricedUsage))
        XCTAssertEqual(dayCost(result(service).day, model: model), expectedCost(result(service).day, input: 1, output: 10))
    }

    /// 已定价模型的远端价格变化：距上次完整重建不足 24 小时先不重建，新价格只用于新记录。
    func testRemotePriceChangeWithinIntervalDoesNotRebuild() async throws {
        let env = environment!
        env.installPricing(model: model, input: 1, output: 10)
        try env.writeClaudeLog(session: "fork-original", lines: forkOriginalLines(env, session: "fork-original"))
        let service = env.makeService()
        service.automaticRebuildEnabled = true
        await env.bootstrap(service)
        await service.scanNow()

        env.installPricing(model: model, input: 2, output: 20)
        await service.scanNow()
        XCTAssertEqual(dayCost(result(service).day, model: model), expectedCost(result(service).day, input: 1, output: 10))
    }

    func testRebuildReasonFollowsRulesPricesAndInterval() {
        let env = environment!
        env.installPricing(model: model, input: 1, output: 10)
        let key = PricingUsageKey(app: .claude, model: model, speed: .standard)
        let now = Date()
        let recent = UsageRebuildBasis.current(usageKeys: [key], at: now.addingTimeInterval(-3_600))
        func reason(
            _ basis: UsageRebuildBasis?,
            keys: Set<PricingUsageKey> = [key],
            unpriced: Set<PricingUsageKey> = [],
            user: Bool = false
        ) -> UsageAutomaticRebuildReason? {
            UsageRebuildBasis.rebuildReason(
                basis: basis, usageKeys: keys, unpricedKeys: unpriced,
                userRequestedCatalog: user, now: now, minimumInterval: 24 * 3_600
            )
        }

        XCTAssertNil(reason(recent))
        XCTAssertEqual(reason(nil), .statsRules)
        var oldRules = recent
        oldRules.statsRules = [:]
        XCTAssertEqual(reason(oldRules), .statsRules)
        var oldLocal = recent
        oldLocal.localPricing = "older"
        XCTAssertEqual(reason(oldLocal), .localPricing)
        // 新出现的键按当时价格计价，不触发重建。
        XCTAssertNil(reason(recent, keys: [key, PricingUsageKey(app: .codex, model: model, speed: .standard)]))

        env.installPricing(model: model, input: 2, output: 20)
        XCTAssertNil(reason(recent), "24 小时内的普通价格变化先不重建")
        XCTAssertEqual(reason(recent, unpriced: [key]), .newlyPriced)
        XCTAssertEqual(reason(recent, user: true), .catalogUpdatedByUser)
        var stale = recent
        stale.rebuiltAt = now.addingTimeInterval(-25 * 3_600)
        XCTAssertEqual(reason(stale), .remotePricing)
    }

    /// 把快照改成旧版本写的样子：去掉账本与基准。
    private func stripRebuildState(_ env: UsageTestEnvironment) throws {
        var snapshot = try committed(env)
        snapshot.messageLedger = nil
        snapshot.rebuildBasis = nil
        try env.store.commit(snapshot)
    }

    private let forkReference = Date()

    private func forkOriginalLines(_ env: UsageTestEnvironment, session: String) -> [String] {
        [
            env.claudeLine(id: "fork-1", session: session, model: model, timestamp: timestamp(-0.6, from: forkReference), input: 1_000, output: 100, speed: "standard"),
            env.claudeLine(id: "fork-2", session: session, model: model, timestamp: timestamp(-0.5, from: forkReference), input: 2_000, output: 200, speed: "standard"),
        ]
    }

    private func forkContinuedLines(_ env: UsageTestEnvironment) -> [String] {
        forkOriginalLines(env, session: "fork-continued") + [
            env.claudeLine(id: "fork-3", session: "fork-continued", model: model, timestamp: timestamp(-0.1, from: forkReference), input: 4_000, output: 400, speed: "standard"),
        ]
    }

    // MARK: - 断言辅助

    /// 只比较「完整键 + 四类 Tokens + 请求数」。金额不参与：价格变化正是重算要处理的事，
    /// 用金额相等当门槛会掩盖「按新价重算」这一目标。
    private func assertSameDayVector(
        _ lhs: [UsageBucket],
        _ rhs: [UsageBucket],
        env: UsageTestEnvironment,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(env.dayVector(lhs), env.dayVector(rhs), file: file, line: line)
    }
}

private enum UsageSafeRebuildTestsError: Error {
    case missingSnapshot
}
