import XCTest
@testable import CCBar

final class CursorUsageFetcherTests: XCTestCase {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testCursorUsagePageMapsTokensAndMeteredCostWithoutLocalPricing() throws {
        let data = Data("""
        {
          "totalUsageEventsCount": "2",
          "usageEventsDisplay": [
            {
              "timestamp": "1725148800000",
              "model": "claude-4.5-sonnet",
              "chargedCents": "25.5",
              "tokenUsage": {
                "inputTokens": "100",
                "outputTokens": 20,
                "cacheWriteTokens": "5",
                "cacheReadTokens": "10"
              }
            },
            {
              "timestamp": 1725148801000,
              "model": "claude-4.5-sonnet",
              "tokenUsage": {
                "inputTokens": 3,
                "outputTokens": 4,
                "cacheWriteTokens": 0,
                "cacheReadTokens": 0
              }
            }
          ]
        }
        """.utf8)

        let page = try CursorUsageFetcher.parsePage(data: data)
        let buckets = try CursorUsageFetcher.makeBuckets(events: page.events, calendar: utcCalendar)
        let bucket = try XCTUnwrap(buckets.first)

        XCTAssertEqual(page.totalUsageEventsCount, 2)
        XCTAssertEqual(bucket.app, .cursor)
        XCTAssertEqual(bucket.speed, .standard)
        XCTAssertEqual(bucket.inputTokens, 103)
        XCTAssertEqual(bucket.outputTokens, 24)
        XCTAssertEqual(bucket.cacheCreationTokens, 5)
        XCTAssertEqual(bucket.cacheReadTokens, 10)
        XCTAssertEqual(bucket.requestCount, 2)
        XCTAssertEqual(bucket.costUSD, Decimal(string: "0.255")!)
        XCTAssertTrue(bucket.costIncomplete)
        XCTAssertFalse(bucket.hasUnpricedUsage)
    }

    @MainActor
    func testCursorIncompleteMeteringStillFormatsKnownCost() {
        XCTAssertEqual(
            StatsFormatter.tierCost(
                Decimal(string: "0.255")!,
                hasUnpricedUsage: false,
                costIncomplete: true
            ),
            "$0.26"
        )
    }

    /// Free 账号常见形态：整页只有 1 条事件、chargedCents 为 0、token 计数出现 1。
    /// 这些 0 / 1 会命中 NSNumber→Bool 桥接，早期实现下 totalUsageEventsCount 被判成
    /// 布尔导致整页解析失败，用量永远拉不下来；chargedCents 则被错标成费用不完整。
    func testCursorUsagePageAcceptsZeroAndOneNumerics() throws {
        let data = Data("""
        {
          "totalUsageEventsCount": 1,
          "usageEventsDisplay": [
            {
              "timestamp": 1725148800000,
              "model": "default",
              "chargedCents": 0,
              "isChargeable": true,
              "tokenUsage": {
                "inputTokens": 1,
                "outputTokens": 0,
                "cacheReadTokens": 1
              }
            }
          ]
        }
        """.utf8)

        let page = try CursorUsageFetcher.parsePage(data: data)
        let buckets = try CursorUsageFetcher.makeBuckets(events: page.events, calendar: utcCalendar)
        let bucket = try XCTUnwrap(buckets.first)

        XCTAssertEqual(page.totalUsageEventsCount, 1)
        XCTAssertEqual(bucket.inputTokens, 1)
        XCTAssertEqual(bucket.outputTokens, 0)
        XCTAssertEqual(bucket.cacheReadTokens, 1)
        XCTAssertEqual(bucket.cacheCreationTokens, 0)
        XCTAssertEqual(bucket.requestCount, 1)
        XCTAssertEqual(bucket.costUSD, 0)
        XCTAssertFalse(bucket.costIncomplete)
    }

    func testCursorUsageInvalidTimestampFailsBeforeReplacingAWindow() throws {
        let data = Data("""
        {
          "totalUsageEventsCount": 1,
          "usageEventsDisplay": [
            {"timestamp": "not-a-timestamp", "chargedCents": 1, "tokenUsage": {}}
          ]
        }
        """.utf8)

        let page = try CursorUsageFetcher.parsePage(data: data)

        XCTAssertThrowsError(try CursorUsageFetcher.makeBuckets(events: page.events, calendar: utcCalendar)) {
            guard let error = $0 as? CursorUsageError else {
                return XCTFail("expected CursorUsageError, got \($0)")
            }
            XCTAssertEqual(error, .invalidTimestamp)
        }
    }

    @MainActor
    func testRemoteReplacementDoesNotAccumulateAndKeepsLocalBuckets() {
        let day = Date(timeIntervalSince1970: 1_725_148_800)
        let nextDay = day.addingTimeInterval(24 * 60 * 60)
        let local = UsageEntry(
            app: .codex,
            conversationKey: "local",
            model: "gpt-5",
            speed: .standard,
            day: day,
            timestamp: day,
            inputTokens: 10,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            costUSD: 1,
            costBreakdown: nil
        )
        let remote = UsageBucket(
            app: .cursor,
            model: "cursor-model",
            speed: .standard,
            day: day,
            inputTokens: 20,
            outputTokens: 2,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            costUSD: Decimal(string: "0.2")!,
            requestCount: 1,
            hasUnpricedUsage: false,
            costIncomplete: true
        )
        let aggregator = UsageAggregator()

        aggregator.ingestLocal([local])
        aggregator.replaceRemote(app: .cursor, dayRange: day..<nextDay, buckets: [remote])
        aggregator.replaceRemote(app: .cursor, dayRange: day..<nextDay, buckets: [remote])

        XCTAssertEqual(aggregator.snapshotLocal().count, 1)
        XCTAssertEqual(aggregator.snapshotRemote(app: .cursor).count, 1)
        XCTAssertEqual(aggregator.totals(app: .cursor, from: day, to: nextDay).requestCount, 1)
        XCTAssertTrue(aggregator.totals(app: .cursor, from: day, to: nextDay).costIncomplete)

        aggregator.replaceRemote(app: .cursor, dayRange: day..<nextDay, buckets: [])
        XCTAssertTrue(aggregator.snapshotRemote(app: .cursor).isEmpty)
        XCTAssertEqual(aggregator.snapshotLocal().first?.app, .codex)
    }

    func testCursorCoverageMergesOverlappingAndAdjacentDays() throws {
        let day = Date(timeIntervalSince1970: 1_725_148_800)
        let day2 = day.addingTimeInterval(24 * 60 * 60)
        let day3 = day2.addingTimeInterval(24 * 60 * 60)
        let first = try XCTUnwrap(CursorUsageDayRange(range: day..<day2))
        let second = try XCTUnwrap(CursorUsageDayRange(range: day2..<day3))

        let merged = [first].merged(with: second)

        XCTAssertEqual(merged.count, 1)
        let range = try XCTUnwrap(merged.first).range
        XCTAssertEqual(range.lowerBound, day)
        XCTAssertEqual(range.upperBound, day3)
    }

    func testCursorCoverageFindsOnlyUncoveredGaps() throws {
        let day = Date(timeIntervalSince1970: 1_725_148_800)
        let day2 = day.addingTimeInterval(24 * 60 * 60)
        let day3 = day2.addingTimeInterval(24 * 60 * 60)
        let day4 = day3.addingTimeInterval(24 * 60 * 60)
        let day5 = day4.addingTimeInterval(24 * 60 * 60)
        let first = try XCTUnwrap(CursorUsageDayRange(range: day..<day2))
        let second = try XCTUnwrap(CursorUsageDayRange(range: day3..<day4))

        let missing = [first, second].missingRanges(in: day..<day5)

        XCTAssertEqual(missing.count, 2)
        XCTAssertEqual(missing[0].lowerBound, day2)
        XCTAssertEqual(missing[0].upperBound, day3)
        XCTAssertEqual(missing[1].lowerBound, day4)
        XCTAssertEqual(missing[1].upperBound, day5)
    }

    func testCursorRefreshRangesBackfillCurrentWeekGapBeforeRecentWindow() throws {
        let monday = Date(timeIntervalSince1970: 1_725_840_000) // 2024-09-09 00:00 UTC
        let now = monday.addingTimeInterval(4 * 24 * 60 * 60 + 12 * 60 * 60) // Friday noon
        let wednesday = monday.addingTimeInterval(2 * 24 * 60 * 60)
        let saturday = monday.addingTimeInterval(5 * 24 * 60 * 60)
        let covered = try XCTUnwrap(CursorUsageDayRange(range: wednesday..<saturday))

        let ranges = UsageService.cursorRefreshRanges(
            now: now,
            billingWindow: nil,
            coveredDayRanges: [covered],
            calendar: utcCalendar
        )

        XCTAssertEqual(ranges, [monday..<now])
    }

    func testCursorRefreshRangesBackfillBillingCycleGapBeforeCurrentWeek() throws {
        let monday = Date(timeIntervalSince1970: 1_725_840_000) // 2024-09-09 00:00 UTC
        let now = monday.addingTimeInterval(4 * 24 * 60 * 60 + 12 * 60 * 60) // Friday noon
        let cycleStart = monday.addingTimeInterval(-10 * 24 * 60 * 60)
        let cycleEnd = cycleStart.addingTimeInterval(30 * 24 * 60 * 60)
        let saturday = monday.addingTimeInterval(5 * 24 * 60 * 60)
        let covered = try XCTUnwrap(CursorUsageDayRange(range: monday..<saturday))

        let ranges = UsageService.cursorRefreshRanges(
            now: now,
            billingWindow: cycleStart..<cycleEnd,
            coveredDayRanges: [covered],
            calendar: utcCalendar
        )

        XCTAssertEqual(ranges.first, cycleStart..<monday)
    }

    func testCursorInitialRefreshStartsAtWeekStartWhenBillingCycleStartsMidweek() {
        let monday = Date(timeIntervalSince1970: 1_725_840_000) // 2024-09-09 00:00 UTC
        let now = monday.addingTimeInterval(4 * 24 * 60 * 60 + 12 * 60 * 60) // Friday noon
        let wednesday = monday.addingTimeInterval(2 * 24 * 60 * 60)
        let nextWednesday = wednesday.addingTimeInterval(7 * 24 * 60 * 60)

        let ranges = UsageService.cursorRefreshRanges(
            now: now,
            billingWindow: wednesday..<nextWednesday,
            coveredDayRanges: [],
            calendar: utcCalendar
        )

        XCTAssertEqual(ranges, [monday..<now])
    }

    func testLegacyUsageBucketDefaultsCostIncompleteToFalse() throws {
        let data = Data("""
        {
          "app": "codex",
          "model": "gpt-5",
          "speed": "standard",
          "day": 0,
          "inputTokens": 1,
          "outputTokens": 2,
          "cacheReadTokens": 0,
          "cacheCreationTokens": 0,
          "costUSD": "0.1",
          "requestCount": 1,
          "hasUnpricedUsage": false
        }
        """.utf8)

        let bucket = try JSONDecoder().decode(UsageBucket.self, from: data)

        XCTAssertFalse(bucket.costIncomplete)
    }
}
