import XCTest
@testable import CCBar

/// 统计页概览的单次遍历派生（`StatsOverviewModel.build`）必须与重构前「每个面板各自过滤
/// 全表再聚合」的口径逐项一致。这里用一份朴素参考实现逐项对照，覆盖范围 / 上期 / 图表窗口、
/// 服务过滤、可见性与日 / 周 / 月粒度的组合。
@MainActor
final class StatsOverviewModelTests: XCTestCase {
    private let calendar = Calendar.current

    // MARK: - 等价对照

    func testBuildMatchesNaiveReferenceAcrossScopes() {
        let buckets = makeFixtureBuckets()
        let intervals: [(current: StatsDateInterval, previous: StatsDateInterval?, chart: StatsDateInterval)] = [
            (interval(day(2026, 3, 1), day(2026, 4, 1)),
             interval(day(2026, 1, 30), day(2026, 3, 1)),
             interval(day(2026, 3, 1), day(2026, 4, 1))),
            (interval(day(2026, 3, 10), day(2026, 3, 11)),
             interval(day(2026, 3, 9), day(2026, 3, 10)),
             interval(day(2026, 2, 25), day(2026, 3, 11))),
            (interval(.distantPast, .distantFuture), nil, interval(.distantPast, .distantFuture))
        ]
        let serviceApps: [UsageApp?] = [nil, .codex, .claude, .cursor]
        let visibleSets: [[UsageApp]] = [
            UsageApp.allCases,
            [.codex, .claude, .pi],
            []
        ]

        for (current, previous, chart) in intervals {
            for granularity in StatsGranularity.allCases {
                for serviceApp in serviceApps {
                    for visibleApps in visibleSets {
                        let input = StatsOverviewInput(
                            revision: 1,
                            current: current,
                            previous: previous,
                            chart: chart,
                            granularity: granularity,
                            serviceApp: serviceApp,
                            visibleApps: visibleApps,
                            highlightedPeriodStart: nil
                        )
                        let context = "\(current) \(granularity) \(String(describing: serviceApp)) \(visibleApps)"
                        assertMatchesReference(StatsOverviewModel.build(buckets: buckets, input: input),
                                               buckets: buckets, input: input, context: context)
                    }
                }
            }
        }
    }

    /// 上期分服务合计只看可见性、不看侧栏服务过滤（与重构前 `previousTotals(app)` 一致）。
    func testPreviousTotalsPerAppIgnoreServiceFilter() {
        let buckets = [
            bucket(.codex, "gpt-5", day(2026, 3, 1), tokens: 100, cost: 1),
            bucket(.claude, "claude-sonnet-4", day(2026, 3, 1), tokens: 200, cost: 2),
            bucket(.claude, "claude-sonnet-4", day(2026, 3, 2), tokens: 50, cost: 3)
        ]
        let model = StatsOverviewModel.build(buckets: buckets, input: StatsOverviewInput(
            revision: 1,
            current: interval(day(2026, 3, 2), day(2026, 3, 3)),
            previous: interval(day(2026, 3, 1), day(2026, 3, 2)),
            chart: interval(day(2026, 3, 2), day(2026, 3, 3)),
            granularity: .day,
            serviceApp: .claude,
            visibleApps: [.codex, .claude],
            highlightedPeriodStart: nil
        ))

        XCTAssertEqual(model.previousTotalsAll.inputTokens, 200)
        XCTAssertEqual(model.previousTotals(.codex).inputTokens, 100)
        XCTAssertEqual(model.totals(.codex), .zero)
        XCTAssertEqual(model.totals(.claude).inputTokens, 50)
        XCTAssertTrue(model.hasPreviousRange)
    }

    func testWeekAndMonthSamplesMergeIntoPeriodStart() {
        // 2026-03-02 是周一；03-02 ~ 03-08 同属一周，03-09 进入下一周。
        let buckets = [
            bucket(.codex, "gpt-5", day(2026, 3, 2), tokens: 10, cost: 1),
            bucket(.codex, "gpt-5", day(2026, 3, 8), tokens: 20, cost: 1),
            bucket(.claude, "claude-opus-4", day(2026, 3, 9), tokens: 40, cost: 1),
            bucket(.claude, "claude-opus-4", day(2026, 4, 1), tokens: 80, cost: 1)
        ]
        let all = interval(.distantPast, .distantFuture)
        func build(_ granularity: StatsGranularity) -> StatsOverviewModel {
            StatsOverviewModel.build(buckets: buckets, input: StatsOverviewInput(
                revision: 1, current: all, previous: nil, chart: all,
                granularity: granularity, serviceApp: nil,
                visibleApps: UsageApp.allCases, highlightedPeriodStart: nil
            ))
        }

        let weekly = build(.week)
        XCTAssertEqual(weekly.samples.map(\.key), ["2026-03-02", "2026-03-09", "2026-03-30"])
        XCTAssertEqual(weekly.samples.first?.codex.inputTokens, 30)

        let monthly = build(.month)
        XCTAssertEqual(monthly.samples.map(\.key), ["2026-03-01", "2026-04-01"])
        XCTAssertEqual(monthly.samples.first?.totalUsage.inputTokens, 70)
        XCTAssertFalse(monthly.hasPreviousRange)
    }

    func testAxisKeysAndBarWidthFollowSampleCount() {
        let buckets = (0..<60).map { offset in
            bucket(.codex, "gpt-5", calendar.date(byAdding: .day, value: offset, to: day(2026, 1, 1))!, tokens: 1, cost: 0)
        }
        let all = interval(.distantPast, .distantFuture)
        let model = StatsOverviewModel.build(buckets: buckets, input: StatsOverviewInput(
            revision: 1, current: all, previous: nil, chart: all,
            granularity: .day, serviceApp: nil,
            visibleApps: UsageApp.allCases, highlightedPeriodStart: nil
        ))

        XCTAssertEqual(model.samples.count, 60)
        XCTAssertEqual(model.barWidth, 5)

        let keys = model.samples.map(\.key)
        let axis = StatsOverviewModel.axisKeys(from: keys, maxCount: 7)
        XCTAssertEqual(axis.count, 7)
        XCTAssertEqual(axis.first, "2026-01-01")
        XCTAssertTrue(axis.allSatisfy(keys.contains))
        XCTAssertEqual(StatsOverviewModel.axisKeys(from: keys, maxCount: 100), keys)
        XCTAssertEqual(StatsOverviewModel.axisKeys(from: keys, maxCount: 0), ["2026-01-01"])
    }

    // MARK: - 提供商排序

    func testProviderGroupsSortOtherLastAndModelsBySortKey() {
        let buckets = [
            bucket(.pi, "unknown-model", day(2026, 3, 1), tokens: 10_000, cost: 99),
            bucket(.codex, "gpt-5", day(2026, 3, 1), tokens: 100, cost: 5),
            bucket(.codex, "gpt-5-mini", day(2026, 3, 1), tokens: 900, cost: 1),
            bucket(.claude, "claude-sonnet-4", day(2026, 3, 1), tokens: 50, cost: 10)
        ]
        let all = interval(.distantPast, .distantFuture)
        let model = StatsOverviewModel.build(buckets: buckets, input: StatsOverviewInput(
            revision: 1, current: all, previous: nil, chart: all,
            granularity: .day, serviceApp: nil,
            visibleApps: UsageApp.allCases, highlightedPeriodStart: nil
        ))

        let byCost = ProviderGroup.sorted(model.providerGroups, by: .cost)
        XCTAssertEqual(byCost.map(\.provider), [.anthropic, .openAI, .other])
        XCTAssertEqual(byCost[1].models.map(\.model), ["gpt-5", "gpt-5-mini"])

        let byTokens = ProviderGroup.sorted(model.providerGroups, by: .tokens)
        XCTAssertEqual(byTokens.map(\.provider), [.openAI, .anthropic, .other])
        XCTAssertEqual(byTokens[0].models.map(\.model), ["gpt-5-mini", "gpt-5"])
    }

    // MARK: - 缓存与 revision

    func testCacheReusesModelUntilInputChanges() {
        let cache = StatsOverviewCache()
        let all = interval(.distantPast, .distantFuture)
        var input = StatsOverviewInput(
            revision: 1, current: all, previous: nil, chart: all,
            granularity: .day, serviceApp: nil,
            visibleApps: UsageApp.allCases, highlightedPeriodStart: nil
        )
        var snapshotCalls = 0
        let buckets = [bucket(.codex, "gpt-5", day(2026, 3, 1), tokens: 1, cost: 1)]

        _ = cache.model(for: input) { snapshotCalls += 1; return buckets }
        _ = cache.model(for: input) { snapshotCalls += 1; return buckets }
        XCTAssertEqual(snapshotCalls, 1)

        input = StatsOverviewInput(
            revision: 2, current: all, previous: nil, chart: all,
            granularity: .day, serviceApp: nil,
            visibleApps: UsageApp.allCases, highlightedPeriodStart: nil
        )
        _ = cache.model(for: input) { snapshotCalls += 1; return buckets }
        XCTAssertEqual(snapshotCalls, 2)
    }

    func testAggregatorRevisionAdvancesOnlyOnWrites() {
        let aggregator = UsageAggregator()
        let start = aggregator.revision

        aggregator.ingestLocal([])
        XCTAssertEqual(aggregator.revision, start)

        aggregator.ingestLocal([UsageEntry(
            app: .codex, conversationKey: "c", model: "gpt-5", speed: .standard,
            day: day(2026, 3, 1), timestamp: day(2026, 3, 1),
            inputTokens: 1, outputTokens: 1, cacheReadTokens: 0, cacheCreationTokens: 0,
            costUSD: 1
        )])
        XCTAssertNotEqual(aggregator.revision, start)

        let afterIngest = aggregator.revision
        aggregator.replaceRemote(app: .cursor, dayRange: day(2026, 3, 1)..<day(2026, 3, 2), buckets: [])
        XCTAssertNotEqual(aggregator.revision, afterIngest)
    }

    // MARK: - 参考实现（重构前各面板的过滤聚合口径）

    private func assertMatchesReference(
        _ model: StatsOverviewModel,
        buckets: [UsageBucket],
        input: StatsOverviewInput,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let visible = Set(input.visibleApps)
        func filtered(_ interval: StatsDateInterval) -> [UsageBucket] {
            buckets
                .filter { $0.day >= interval.from && $0.day < interval.to }
                .filter { visible.contains($0.app) }
                .filter { input.serviceApp == nil || $0.app == input.serviceApp }
        }
        func sum(_ items: [UsageBucket]) -> UsageTotals {
            var t = UsageTotals.zero
            for b in items { t.add(b) }
            return t
        }

        let current = filtered(input.current)
        XCTAssertEqual(model.totalsAll, sum(current), context, file: file, line: line)

        var speed = UsageSpeedBreakdown()
        for b in current { speed.add(b) }
        XCTAssertEqual(model.speedAll, speed, context, file: file, line: line)

        let previous = input.previous.map(filtered) ?? []
        XCTAssertEqual(model.previousTotalsAll, sum(previous), context, file: file, line: line)

        for app in UsageApp.allCases {
            XCTAssertEqual(model.totals(app), sum(current.filter { $0.app == app }), "\(context) \(app)", file: file, line: line)

            var appSpeed = UsageSpeedBreakdown()
            for b in current where b.app == app { appSpeed.add(b) }
            XCTAssertEqual(model.speed(app), appSpeed, "\(context) \(app)", file: file, line: line)

            let expectedPrevious: UsageTotals
            if let prev = input.previous, visible.contains(app) {
                expectedPrevious = sum(buckets.filter { $0.app == app && $0.day >= prev.from && $0.day < prev.to })
            } else {
                expectedPrevious = .zero
            }
            XCTAssertEqual(model.previousTotals(app), expectedPrevious, "\(context) \(app)", file: file, line: line)

            var byModel: [String: UsageTotals] = [:]
            for b in current where b.app == app { byModel[b.model, default: .zero].add(b) }
            let expectedRows = byModel.sorted {
                $0.value.costUSD == $1.value.costUSD ? $0.key < $1.key : $0.value.costUSD > $1.value.costUSD
            }
            XCTAssertEqual(model.modelRows(app).map(\.model), expectedRows.map(\.key), "\(context) \(app)", file: file, line: line)
            XCTAssertEqual(model.modelRows(app).map(\.totals), expectedRows.map(\.value), "\(context) \(app)", file: file, line: line)
        }

        var byPeriod: [Date: [UsageBucket]] = [:]
        for b in filtered(input.chart) {
            byPeriod[input.granularity.bucketStart(for: b.day), default: []].append(b)
        }
        let expectedDays = byPeriod.keys.sorted()
        XCTAssertEqual(model.samples.map(\.day), expectedDays, context, file: file, line: line)
        for sample in model.samples {
            let items = byPeriod[sample.day] ?? []
            XCTAssertEqual(sample.key, StatsPeriodKey.key(for: sample.day), context, file: file, line: line)
            for app in UsageApp.allCases {
                XCTAssertEqual(sample.totals(for: app), sum(items.filter { $0.app == app }),
                               "\(context) \(sample.key) \(app)", file: file, line: line)
            }
        }

        var providerTotals: [ModelProvider: UsageTotals] = [:]
        for b in current { providerTotals[ModelProvider.resolve(app: b.app, model: b.model), default: .zero].add(b) }
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: model.providerGroups.map { ($0.provider, $0.totals) }),
            providerTotals,
            context, file: file, line: line
        )
    }

    // MARK: - Fixtures

    /// 横跨 2026-01 ~ 2026-04、覆盖全部服务与多种模型 / 速度档位的日桶。
    private func makeFixtureBuckets() -> [UsageBucket] {
        let models: [UsageApp: [String]] = [
            .codex: ["gpt-5", "gpt-5-mini"],
            .claude: ["claude-sonnet-4", "claude-opus-4"],
            .cursor: ["auto"],
            .pi: ["anthropic/claude-sonnet-4", "deepseek/deepseek-chat"],
            .opencode: ["opencode-go/kimi"],
            .dsh: ["deepseek-reasoner"]
        ]
        var result: [UsageBucket] = []
        var seed = 7
        for offset in stride(from: 0, to: 110, by: 1) {
            let date = calendar.date(byAdding: .day, value: offset, to: day(2026, 1, 1))!
            for app in UsageApp.allCases {
                for (index, model) in (models[app] ?? []).enumerated() {
                    seed = (seed * 1_103_515_245 + 12_345) % 2_147_483_648
                    guard seed % 3 != 0 else { continue }
                    let speed: UsageSpeed = app == .codex && index == 0 && offset % 5 == 0 ? .fast : .standard
                    var b = bucket(app, model, date, tokens: seed % 50_000, cost: Decimal(seed % 700) / 100)
                    b.speed = speed
                    b.hasUnpricedUsage = seed % 11 == 0
                    b.costIncomplete = app == .cursor && seed % 13 == 0
                    result.append(b)
                }
            }
        }
        return result
    }

    private func bucket(_ app: UsageApp, _ model: String, _ day: Date, tokens: Int, cost: Decimal) -> UsageBucket {
        UsageBucket(
            app: app,
            model: model,
            speed: .standard,
            day: day,
            inputTokens: tokens,
            outputTokens: tokens / 3,
            cacheReadTokens: tokens / 2,
            cacheCreationTokens: tokens / 7,
            costUSD: cost,
            requestCount: max(1, tokens / 1_000),
            hasUnpricedUsage: false
        )
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.startOfDay(for: calendar.date(from: DateComponents(year: year, month: month, day: day))!)
    }

    private func interval(_ from: Date, _ to: Date) -> StatsDateInterval {
        StatsDateInterval(from: from, to: to)
    }
}
