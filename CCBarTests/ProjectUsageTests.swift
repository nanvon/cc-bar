import XCTest
@testable import CCBar

/// 统计页改版的数据口径：项目汇总、worktree 归入主仓库、未归属残差、构成合并规则、周期对话维度。
final class ProjectUsageTests: XCTestCase {
    private let calendar = Calendar.current
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectUsageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        // /var → /private/var：与 ConversationProjectResolver 的规范路径保持一致。
        tempRoot = tempRoot.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - worktree 识别

    func testWorktreeResolvesToMainRepositoryWithBranch() throws {
        let (main, worktree) = try makeRepositoryWithWorktree(name: "wt1", branch: "feature/x")
        let resolver = ProjectWorktreeResolver(home: tempRoot.path)

        let link = resolver.link(forProjectPath: worktree)
        XCTAssertEqual(link?.mainPath, main)
        XCTAssertEqual(link?.branch, "feature/x")
        XCTAssertNil(resolver.link(forProjectPath: main), "主仓库本身不是 worktree")
        XCTAssertEqual(resolver.isGitRepository(worktree), true)
        XCTAssertEqual(resolver.isGitRepository(main), true)
    }

    func testWorktreeInProtectedFolderIsNotRead() throws {
        let documents = tempRoot.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let (_, worktree) = try makeRepositoryWithWorktree(name: "wt2", branch: "main", parent: documents)
        let resolver = ProjectWorktreeResolver(home: tempRoot.path)

        XCTAssertNil(resolver.link(forProjectPath: worktree), "受保护目录按独立项目处理，不读取 .git")
        XCTAssertNil(resolver.isGitRepository(worktree))
    }

    func testPlainFolderIsNotGitRepository() throws {
        let folder = tempRoot.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let resolver = ProjectWorktreeResolver(home: tempRoot.path)
        XCTAssertEqual(resolver.isGitRepository(folder.path), false)
        XCTAssertNil(resolver.link(forProjectPath: folder.path))
    }

    // MARK: - 项目汇总

    func testOverviewBreakdownGroupsProjectsAndSkipsMissingInfos() {
        let aggregator = ConversationAggregator(worktreeResolver: ProjectWorktreeResolver(home: tempRoot.path))
        aggregator.load(
            infos: [
                info("a1", app: .claude, project: "/x/alpha"),
                info("a2", app: .codex, project: "/x/alpha"),
                info("b1", app: .claude, project: "/x/beta"),
                info("home", app: .claude, project: nil)
            ],
            buckets: [
                bucket("a1", .claude, day(2026, 3, 1), tokens: 100, cost: 3),
                bucket("a2", .codex, day(2026, 3, 1), tokens: 50, cost: 1),
                bucket("b1", .claude, day(2026, 3, 2), tokens: 400, cost: 10),
                bucket("home", .claude, day(2026, 3, 2), tokens: 7, cost: 7),
                // 缺档案：不计入任何项目，也不计入 attributed。
                bucket("orphan", .claude, day(2026, 3, 2), tokens: 999, cost: 99),
                // 范围外。
                bucket("a1", .claude, day(2026, 2, 1), tokens: 1_000, cost: 100)
            ]
        )

        let result = aggregator.overviewBreakdown(ConversationOverviewRequest(
            revision: 0, from: day(2026, 3, 1), to: day(2026, 3, 3),
            apps: [.claude, .codex], topConversationLimit: 2
        ))

        XCTAssertEqual(result.projects.map(\.name), ["beta", "alpha", ""], "按金额降序，无明确项目固定在最后")
        let alpha = result.projects[1]
        XCTAssertEqual(alpha.totals.totalTokens, 150)
        XCTAssertEqual(alpha.totals.costUSD, 4)
        XCTAssertEqual(alpha.conversationCount, 2)
        XCTAssertEqual(alpha.totalsByApp[.codex]?.totalTokens, 50)
        XCTAssertEqual(result.attributedByApp[.claude]?.totalTokens, 507)
        XCTAssertEqual(result.attributedByApp[.codex]?.totalTokens, 50)
        XCTAssertEqual(result.topConversations.map(\.id), ["b1", "home"])

        let claudeOnly = aggregator.overviewBreakdown(ConversationOverviewRequest(
            revision: 0, from: day(2026, 3, 1), to: day(2026, 3, 3),
            apps: [.claude], topConversationLimit: 5
        ))
        XCTAssertEqual(claudeOnly.projects.first { $0.name == "alpha" }?.totals.totalTokens, 100)
        XCTAssertNil(claudeOnly.attributedByApp[.codex])
    }

    func testWorktreeConversationsCountTowardMainRepository() throws {
        let (main, worktree) = try makeRepositoryWithWorktree(name: "wt1", branch: "feature/x")
        let aggregator = ConversationAggregator(worktreeResolver: ProjectWorktreeResolver(home: tempRoot.path))
        var mainInfo = info("m", app: .claude, project: main)
        mainInfo.gitBranch = "main"
        var worktreeInfo = info("w", app: .codex, project: worktree)
        worktreeInfo.gitBranch = "feature/x"
        aggregator.load(
            infos: [mainInfo, worktreeInfo],
            buckets: [
                bucket("m", .claude, day(2026, 3, 1), tokens: 10, cost: 1),
                bucket("w", .codex, day(2026, 3, 1), tokens: 30, cost: 5)
            ]
        )

        let overview = aggregator.overviewBreakdown(ConversationOverviewRequest(
            revision: 0, from: day(2026, 3, 1), to: day(2026, 3, 2),
            apps: [.claude, .codex], topConversationLimit: 5
        ))
        XCTAssertEqual(overview.projects.count, 1)
        XCTAssertEqual(overview.projects.first?.key, "path:\(main)")
        XCTAssertEqual(overview.projects.first?.totals.totalTokens, 40)
        XCTAssertEqual(overview.projects.first?.worktreeCount, 1)

        let detail = try XCTUnwrap(aggregator.projectDetail(ProjectDetailRequest(
            revision: 0, projectKey: "path:\(main)",
            from: day(2026, 3, 1), to: day(2026, 3, 2), previous: nil,
            apps: [.claude, .codex]
        )))
        XCTAssertEqual(detail.worktrees.map(\.path), [main, worktree])
        XCTAssertEqual(detail.worktrees.last?.branch, "feature/x")
        XCTAssertEqual(detail.worktrees.last?.totals.totalTokens, 30)
        XCTAssertEqual(Set(detail.branches.compactMap(\.branch)), ["main", "feature/x"])

        // 对话页按主仓库筛选时，worktree 里的对话也在其中。
        let query = aggregator.query(ConversationQueryRequest(
            revision: 0, app: nil, projectKey: "path:\(main)",
            from: day(2026, 3, 1), to: day(2026, 3, 2), search: "", sort: .cost
        ))
        XCTAssertEqual(Set(query.rows.map(\.id)), ["m", "w"])
        XCTAssertEqual(query.projectOptions.map(\.key), ["path:\(main)"])
    }

    func testProjectDetailRangeAllTimeAndPrevious() throws {
        let aggregator = ConversationAggregator(worktreeResolver: ProjectWorktreeResolver(home: tempRoot.path))
        aggregator.load(
            infos: [info("a", app: .claude, project: "/x/alpha")],
            buckets: [
                bucket("a", .claude, day(2026, 3, 1), tokens: 10, cost: 1),
                bucket("a", .claude, day(2026, 3, 3), tokens: 20, cost: 2),
                bucket("a", .claude, day(2026, 3, 5), tokens: 40, cost: 4)
            ]
        )
        let detail = try XCTUnwrap(aggregator.projectDetail(ProjectDetailRequest(
            revision: 0, projectKey: "path:/x/alpha",
            from: day(2026, 3, 3), to: day(2026, 3, 6),
            previous: day(2026, 2, 28)..<day(2026, 3, 3),
            apps: [.claude]
        )))
        XCTAssertEqual(detail.totals.totalTokens, 60)
        XCTAssertEqual(detail.previousTotals?.totalTokens, 10)
        XCTAssertEqual(detail.allTimeTotals.totalTokens, 70)
        XCTAssertEqual(detail.firstUsedDay, day(2026, 3, 1))
        XCTAssertEqual(detail.activeDays, 2)
        XCTAssertEqual(detail.conversationCount, 1)
    }

    // MARK: - 构成与未归属

    func testCompositionProjectRowsSumToOverviewTotal() {
        let aggregator = ConversationAggregator(worktreeResolver: ProjectWorktreeResolver(home: tempRoot.path))
        let projects = ["p1", "p2", "p3", "p4", "p5", "p6"]
        var infos = projects.enumerated().map { index, name in
            info("c\(index)", app: .claude, project: "/x/\(name)")
        }
        infos.append(info("sys", app: .claude, project: nil))
        var conversationBuckets = projects.indices.map { index in
            bucket("c\(index)", .claude, day(2026, 3, 1), tokens: 100 * (index + 1), cost: Decimal(index + 1))
        }
        conversationBuckets.append(bucket("sys", .claude, day(2026, 3, 1), tokens: 5000, cost: 50))
        aggregator.load(infos: infos, buckets: conversationBuckets)

        // 日桶 = 对话桶合计 + 补录（只在日桶里）+ Cursor 远端。
        let claudeTokens = conversationBuckets.reduce(0) { $0 + $1.inputTokens }
        let claudeCost = conversationBuckets.reduce(Decimal(0)) { $0 + $1.costUSD }
        let daily = [
            usageBucket(.claude, "claude-sonnet-4", day(2026, 3, 1), tokens: claudeTokens + 700, cost: claudeCost + 7),
            usageBucket(.cursor, "auto", day(2026, 3, 1), tokens: 300, cost: 3)
        ]
        let all = StatsDateInterval(from: .distantPast, to: .distantFuture)
        let apps: [UsageApp] = [.claude, .cursor]
        let overview = aggregator.overviewBreakdown(ConversationOverviewRequest(
            revision: 0, from: all.from, to: all.to, apps: Set(apps), topConversationLimit: 5
        ))
        let model = StatsOverviewModel.build(buckets: daily, input: StatsOverviewInput(
            revision: 1, current: all, previous: nil, chart: all,
            granularity: .day, serviceApp: nil, visibleApps: apps, highlightedPeriodStart: nil
        ), conversationOverview: overview)

        let rows = model.composition[.project] ?? []
        XCTAssertEqual(rows.count, 8, "全部列出：6 个项目 + 无明确项目 + 未归属")
        XCTAssertEqual(rows.prefix(6).map(\.title), ["p6", "p5", "p4", "p3", "p2", "p1"])
        XCTAssertEqual(rows[6].kind, .item)
        XCTAssertEqual(rows[6].color, .rest, "无明确项目不参与排名，固定在项目之后")
        XCTAssertEqual(rows.last?.kind, .unattributed)
        XCTAssertEqual(model.unattributed.totalTokens, 1000)
        XCTAssertEqual(model.unattributed.costUSD, 10)

        var sum = UsageTotals.zero
        for row in rows { sum.add(row.totals) }
        XCTAssertEqual(sum.totalTokens, model.totalsAll.totalTokens)
        XCTAssertEqual(sum.costUSD, model.totalsAll.costUSD)
        XCTAssertEqual(rows.reduce(0) { $0 + model.share(of: $1.totals) }, 1, accuracy: 1e-9)
    }

    func testCompositionMergeRulesForProvidersAndModels() {
        let daily = [
            usageBucket(.codex, "gpt-5", day(2026, 3, 1), tokens: 10, cost: 9),
            usageBucket(.codex, "gpt-5-mini", day(2026, 3, 1), tokens: 10, cost: 8),
            usageBucket(.claude, "claude-sonnet-4", day(2026, 3, 1), tokens: 10, cost: 7),
            usageBucket(.claude, "claude-opus-4", day(2026, 3, 1), tokens: 10, cost: 6),
            usageBucket(.pi, "deepseek-chat", day(2026, 3, 1), tokens: 10, cost: 5),
            usageBucket(.pi, "opencode-go/kimi", day(2026, 3, 1), tokens: 10, cost: 4),
            usageBucket(.pi, "mystery", day(2026, 3, 1), tokens: 10, cost: 30),
            usageBucket(.dsh, "gpt-5", day(2026, 3, 1), tokens: 10, cost: 1)
        ]
        let all = StatsDateInterval(from: .distantPast, to: .distantFuture)
        let model = StatsOverviewModel.build(buckets: daily, input: StatsOverviewInput(
            revision: 1, current: all, previous: nil, chart: all,
            granularity: .day, serviceApp: nil, visibleApps: UsageApp.allCases, highlightedPeriodStart: nil
        ))

        let providers = model.composition[.provider] ?? []
        XCTAssertEqual(
            providers.map(\.id),
            ["provider:openAI", "provider:anthropic", "provider:deepseek", "provider:opencodeGo", "provider:other"],
            "全部列出；「其他」提供商不参与排名，固定在最后"
        )
        XCTAssertEqual(providers.first?.totals.costUSD, 18)
        XCTAssertEqual(providers.last?.color, .rest)
        XCTAssertEqual(providers.last?.totals.costUSD, 30)

        let models = model.composition[.model] ?? []
        XCTAssertEqual(models.count, 7, "全部列出，不合并其余")
        XCTAssertEqual(models.first?.title, "mystery")
        XCTAssertEqual(models[1].title, "gpt-5", "同名模型跨服务合并")
        XCTAssertEqual(models[1].totals.costUSD, 10)
        XCTAssertEqual(models.last?.title, "opencode-go/kimi")

        let services = model.composition[.service] ?? []
        XCTAssertEqual(services.count, UsageApp.allCases.count, "服务维度全部列出")
        XCTAssertEqual(services.first?.id, "service:pi")
    }

    func testUnattributedBreakdownSplitsCursorAndLocal() {
        let buckets = [
            usageBucket(.claude, "m", day(2026, 3, 1), tokens: 100, cost: 10),
            usageBucket(.claude, "m", day(2026, 3, 2), tokens: 50, cost: 5),
            usageBucket(.cursor, "auto", day(2026, 3, 2), tokens: 30, cost: 3),
            usageBucket(.codex, "gpt-5", day(2026, 3, 2), tokens: 20, cost: 2)
        ]
        var attributed: [UsageDayAppKey: UsageTotals] = [:]
        attributed[UsageDayAppKey(day: day(2026, 3, 1), app: .claude)] = totals(tokens: 100, cost: 10)
        attributed[UsageDayAppKey(day: day(2026, 3, 2), app: .claude)] = totals(tokens: 10, cost: 1)

        let result = UnattributedBreakdown.build(
            buckets: buckets, apps: [.claude, .cursor],
            from: day(2026, 3, 1), to: day(2026, 3, 3),
            attributedByDayApp: attributed
        )
        XCTAssertEqual(result.cursor.totalTokens, 30)
        XCTAssertEqual(result.local.totalTokens, 40)
        XCTAssertEqual(result.total.totalTokens, 70)
        XCTAssertEqual(result.cursor.costUSD + result.local.costUSD, result.total.costUSD)
        XCTAssertEqual(result.localApps, [.claude])
        XCTAssertEqual(result.localFirstDay, day(2026, 3, 2))
        XCTAssertEqual(result.overviewTotals.totalTokens, 180)
    }

    // MARK: - 周期对话维度

    func testCycleBucketsKeepConversationKeyWithoutChangingVector() {
        let start = day(2026, 3, 1)
        let end = day(2026, 3, 8)
        let cycle = QuotaCycleRecord(
            id: "cycle-1",
            accountKey: "acct",
            app: .claude,
            limitID: "claude-weekly",
            limitKind: .weekly,
            startAt: start,
            endAt: end,
            scheduledEndAt: end,
            firstSampleAt: start,
            lastSampleAt: start,
            latestUsedPercent: 10,
            allowanceSegments: [
                QuotaCycleAllowanceSegment(
                    id: "cycle-1-seg",
                    startAt: start,
                    endAt: end,
                    baselineUsedPercent: 0,
                    latestUsedPercent: 10,
                    maximumUsedPercent: 10,
                    firstSampleAt: start,
                    lastSampleAt: start,
                    startReason: .initial
                )
            ],
            source: .api,
            boundaryQuality: .observed
        )
        let segment = QuotaCycleAccountSegment(id: "account", accountKey: "acct", app: .claude, startAt: day(2026, 2, 1), endAt: nil)
        let aggregator = CycleUsageAggregator()
        aggregator.ingest(
            entries: [
                entry(.claude, conversation: "a", at: day(2026, 3, 2), tokens: 10),
                entry(.claude, conversation: "b", at: day(2026, 3, 2), tokens: 30)
            ],
            cycles: [cycle],
            accountSegments: [segment]
        )
        let byConversation = aggregator.usageByConversation(cycleID: cycle.id)
        XCTAssertEqual(byConversation["a"]?.inputTokens, 10)
        XCTAssertEqual(byConversation["b"]?.inputTokens, 30)

        let vector = UsageHistoryConsistency.cycleVector(aggregator.snapshot())
        XCTAssertEqual(vector.count, 1, "对话维度不进入周期对账键")
        XCTAssertEqual(vector.values.first?.inputTokens, 40)
    }

    // MARK: - Codex 分支

    func testCodexSessionMetaBranch() {
        XCTAssertEqual(CodexJSONLScanner.gitBranch(inSessionMeta: ["git": ["branch": "main"]]), "main")
        XCTAssertNil(CodexJSONLScanner.gitBranch(inSessionMeta: ["git": ["branch": ""]]))
        XCTAssertNil(CodexJSONLScanner.gitBranch(inSessionMeta: ["cwd": "/x"]))
    }

    // MARK: - Codex 子任务并入父对话

    func testCodexSessionMetaParentThread() {
        XCTAssertEqual(CodexJSONLScanner.parentThreadID(inSessionMeta: ["id": "child", "parent_thread_id": "root"]), "root")
        XCTAssertEqual(CodexJSONLScanner.parentThreadID(inSessionMeta: [
            "id": "child",
            "source": ["subagent": ["thread_spawn": ["parent_thread_id": "root", "depth": 1]]]
        ]), "root")
        XCTAssertNil(CodexJSONLScanner.parentThreadID(inSessionMeta: ["id": "fork", "forked_from_id": "root"]),
                     "用户手动 fork 是独立对话")
        XCTAssertNil(CodexJSONLScanner.parentThreadID(inSessionMeta: ["id": "self", "parent_thread_id": "self"]))
        XCTAssertNil(CodexJSONLScanner.parentThreadID(inSessionMeta: ["id": "a", "parent_thread_id": ""]))
    }

    func testSubtaskConversationsMergeIntoRootRow() throws {
        let aggregator = ConversationAggregator(worktreeResolver: ProjectWorktreeResolver(home: tempRoot.path))
        let root = info("r", app: .codex, project: "/x/alpha")
        var child = info("c", app: .codex, project: "/x/alpha")
        child.parentKey = "r"
        child.lastAt = day(2026, 3, 9)
        var grandchild = info("g", app: .codex, project: "/x/alpha")
        grandchild.parentKey = "c"
        var orphan = info("o", app: .codex, project: "/x/alpha")
        orphan.parentKey = "missing"
        aggregator.load(
            infos: [root, child, grandchild, orphan],
            buckets: [
                bucket("r", .codex, day(2026, 3, 1), tokens: 10, cost: 1),
                bucket("c", .codex, day(2026, 3, 1), tokens: 20, cost: 2),
                bucket("g", .codex, day(2026, 3, 2), tokens: 30, cost: 3),
                bucket("o", .codex, day(2026, 3, 1), tokens: 40, cost: 4)
            ]
        )

        let query = aggregator.query(ConversationQueryRequest(
            revision: 0, app: nil, projectKey: nil,
            from: day(2026, 3, 1), to: day(2026, 3, 3), search: "", sort: .cost
        ))
        XCTAssertEqual(Set(query.rows.map(\.id)), ["r", "o"], "子任务并入根对话，父档案缺失的保持独立")
        let rootRow = try XCTUnwrap(query.rows.first { $0.id == "r" })
        XCTAssertEqual(rootRow.totals.totalTokens, 60)
        XCTAssertTrue(rootRow.info.includesSubtasks)
        XCTAssertEqual(rootRow.info.lastAt, day(2026, 3, 9))
        XCTAssertFalse(try XCTUnwrap(query.rows.first { $0.id == "o" }).info.includesSubtasks)

        let detail = try XCTUnwrap(aggregator.detail(key: "c"))
        XCTAssertEqual(detail.info.key, "r", "旧的子对话选中项落到根对话")
        XCTAssertEqual(detail.totals.totalTokens, 60)

        let overview = aggregator.overviewBreakdown(ConversationOverviewRequest(
            revision: 0, from: day(2026, 3, 1), to: day(2026, 3, 3),
            apps: [.codex], topConversationLimit: 5
        ))
        XCTAssertEqual(overview.topConversations.count, 2)
        XCTAssertEqual(overview.projects.first?.conversationCount, 2)
        XCTAssertEqual(overview.projects.first?.totals.totalTokens, 100)

        let project = try XCTUnwrap(aggregator.projectDetail(ProjectDetailRequest(
            revision: 0, projectKey: "path:/x/alpha",
            from: day(2026, 3, 1), to: day(2026, 3, 3), previous: nil, apps: [.codex]
        )))
        XCTAssertEqual(project.conversationCount, 2)
        XCTAssertEqual(project.totals.totalTokens, 100)
    }

    // MARK: - Helpers

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func totals(tokens: Int, cost: Decimal) -> UsageTotals {
        var t = UsageTotals.zero
        t.inputTokens = tokens
        t.costUSD = cost
        t.requestCount = 1
        return t
    }

    private func identity(_ name: String) -> StatsProjectIdentity {
        StatsProjectIdentity(key: "path:/x/\(name)", name: name, path: "/x/\(name)", status: .available)
    }

    private func info(_ key: String, app: UsageApp, project: String?) -> ConversationInfo {
        ConversationInfo(
            key: key,
            conversationID: key,
            app: app,
            title: "title \(key)",
            projectKey: project.map { "path:\($0)" } ?? "special:unassigned",
            projectName: project.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "",
            projectPath: project ?? "",
            projectStatus: project == nil ? .unassigned : .available,
            projectSource: project == nil ? .unassigned : .gitRoot,
            gitBranch: nil,
            sourcePaths: [],
            firstAt: day(2026, 1, 1),
            lastAt: day(2026, 3, 5),
            includesSubtasks: false,
            cacheCreationAvailable: true
        )
    }

    private func bucket(_ key: String, _ app: UsageApp, _ day: Date, tokens: Int, cost: Decimal) -> ConversationUsageBucket {
        ConversationUsageBucket(
            conversationKey: key, app: app, day: day, model: "m", speed: .standard,
            firstAt: day, lastAt: day,
            inputTokens: tokens, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0,
            requestCount: 1, costUSD: cost,
            inputCostUSD: cost, outputCostUSD: 0, cacheReadCostUSD: 0, cacheCreationCostUSD: 0,
            hasUnpricedUsage: false
        )
    }

    private func usageBucket(_ app: UsageApp, _ model: String, _ day: Date, tokens: Int, cost: Decimal) -> UsageBucket {
        UsageBucket(
            app: app, model: model, speed: .standard, day: day,
            inputTokens: tokens, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0,
            costUSD: cost, requestCount: 1, hasUnpricedUsage: false
        )
    }

    private func entry(_ app: UsageApp, conversation: String, at date: Date, tokens: Int) -> UsageEntry {
        UsageEntry(
            app: app, conversationKey: conversation, model: "m", speed: .standard,
            day: calendar.startOfDay(for: date), timestamp: date.addingTimeInterval(3600),
            inputTokens: tokens, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0,
            costUSD: 1
        )
    }

    /// 在 tempRoot（或 parent）下建一个主仓库和一个 worktree，返回两者规范路径。
    private func makeRepositoryWithWorktree(
        name: String,
        branch: String,
        parent: URL? = nil
    ) throws -> (main: String, worktree: String) {
        let fm = FileManager.default
        let base = parent ?? tempRoot!
        let main = base.appendingPathComponent("repo-\(name)", isDirectory: true)
        let gitDir = main.appendingPathComponent(".git/worktrees/\(name)", isDirectory: true)
        try fm.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: main.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        try "../..\n".write(to: gitDir.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/\(branch)\n".write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        let worktree = base.appendingPathComponent("\(name)", isDirectory: true)
        try fm.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(gitDir.path)\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        return (main.standardizedFileURL.path, worktree.standardizedFileURL.path)
    }
}
