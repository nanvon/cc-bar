import XCTest
@testable import CCBar

/// DeepSeek 分段价与 DSH 取价路径测试。
///
/// 依据：`docs/草案-DSH本地用量-技术方案.md` §6 决策 1（四组 Flash key 共用同一套分段规则；
/// `deepseek-v4-pro` 一并纳入）、§7 S5（验证：其他服务金额不变）。
/// 断言方式：用「100 万 token 的成本 == 单价」把费率读出来，避免直接依赖私有价格表。
final class DshPricingTests: XCTestCase {
    /// 官方公告用 UTC 时刻，测试也必须按 UTC 构造，避免本地时区把边界算错。
    private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.timeZone = TimeZone(secondsFromGMT: 0)
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    /// 每百万 token 的费率（单位 USD），命中不到价格时为 nil。
    private func rates(
        _ model: String,
        at date: Date,
        app: UsageApp = .dsh
    ) -> (input: Decimal?, output: Decimal?, cacheRead: Decimal?)? {
        let one = 1_000_000
        let input = Pricing.cost(app: app, model: model, speed: .standard, input: one, output: 0, cacheRead: 0, cacheCreation: 0, at: date)
        let output = Pricing.cost(app: app, model: model, speed: .standard, input: 0, output: one, cacheRead: 0, cacheCreation: 0, at: date)
        let cacheRead = Pricing.cost(app: app, model: model, speed: .standard, input: 0, output: 0, cacheRead: one, cacheCreation: 0, at: date)
        return (input, output, cacheRead)
    }

    /// 价格表里的字面量是 Double → Decimal，直接比 Decimal 会差在 1e-16 量级，因此按 double 值带容差比较。
    private func assertClose(
        _ actual: Decimal?,
        _ expected: Double,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else {
            return XCTFail("\(label) 未定价", file: file, line: line)
        }
        XCTAssertEqual(
            NSDecimalNumber(decimal: actual).doubleValue,
            expected,
            accuracy: 1e-9,
            label,
            file: file,
            line: line
        )
    }

    private func assertRates(
        _ model: String,
        at date: Date,
        input: Double,
        output: Double,
        cacheRead: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let rates = rates(model, at: date) else {
            return XCTFail("\(model) 在 \(date) 未定价", file: file, line: line)
        }
        assertClose(rates.input, input, "\(model) input @\(date)", file: file, line: line)
        assertClose(rates.output, output, "\(model) output @\(date)", file: file, line: line)
        assertClose(rates.cacheRead, cacheRead, "\(model) cacheRead @\(date)", file: file, line: line)
    }

    // MARK: - Flash 四 key 共用同一套分段价

    func testFlashKeysShareTieredPrices() {
        let keys = [
            "deepseek-flash",
            "deepseek-v4-flash",
            "deepseek-v4-flash-vision-exp",
            "deepseek-v4.1-flash",
        ]
        // 第一段：官方 2026-08-16 16:00 UTC 之前沿用表内现值
        for key in keys {
            assertRates(key, at: utc(2026, 8, 1), input: 0.14, output: 0.28, cacheRead: 0.0028)
        }
        // 第二段：2026-08-16 16:00 UTC 起的峰谷价（取高峰价，估算上界）
        for key in keys {
            assertRates(key, at: utc(2026, 8, 20), input: 0.44, output: 1.32, cacheRead: 0.014)
        }
        // 第三段：2026-09-10 04:00 UTC 起降价
        for key in keys {
            assertRates(key, at: utc(2026, 9, 15), input: 0.30, output: 1.20, cacheRead: 0.006)
        }
    }

    func testTierBoundariesAreExactUTCInstants() {
        let key = "deepseek-v4.1-flash"
        assertRates(key, at: utc(2026, 8, 16, 15, 59), input: 0.14, output: 0.28, cacheRead: 0.0028)
        assertRates(key, at: utc(2026, 8, 16, 16, 0), input: 0.44, output: 1.32, cacheRead: 0.014)
        assertRates(key, at: utc(2026, 9, 10, 3, 59), input: 0.44, output: 1.32, cacheRead: 0.014)
        assertRates(key, at: utc(2026, 9, 10, 4, 0), input: 0.30, output: 1.20, cacheRead: 0.006)
    }

    // MARK: - V4-Pro 一并纳入

    func testProPriceChangesAtAugustBoundary() {
        assertRates("deepseek-v4-pro", at: utc(2026, 8, 1), input: 0.435, output: 0.87, cacheRead: 0.003625)
        assertRates("deepseek-v4-pro", at: utc(2026, 8, 20), input: 1.32, output: 3.96, cacheRead: 0.044)
        // 此后官方未再调整：12 月仍是同一价
        assertRates("deepseek-v4-pro", at: utc(2026, 12, 1), input: 1.32, output: 3.96, cacheRead: 0.044)
    }

    // MARK: - DSH 实际取价路径

    func testDSHForwarderPrefixedModelHitsTheSamePrice() {
        // DSH 的模型标签形如 `commandcode/deepseek/deepseek-v4.1-flash`，归一化后必须命中同一价
        assertRates("commandcode/deepseek/deepseek-v4.1-flash", at: utc(2026, 9, 15), input: 0.30, output: 1.20, cacheRead: 0.006)
        assertRates("deepseek/deepseek-v4-flash", at: utc(2026, 9, 15), input: 0.30, output: 1.20, cacheRead: 0.006)
    }

    func testDSHEntryCostMatchesExpectedUSD() {
        // 2026-09-15：input 1M + output 0.5M + cacheRead 2M
        // 0.30 + 0.5×1.20 + 2×0.006 = 0.912
        let breakdown = Pricing.costBreakdown(
            app: .dsh,
            model: "deepseek/deepseek-v4.1-flash",
            speed: .standard,
            input: 1_000_000,
            output: 500_000,
            cacheRead: 2_000_000,
            cacheCreation: 0,
            at: utc(2026, 9, 15)
        )
        assertClose(breakdown?.total, 0.912, "flash 汇总")
        assertClose(breakdown?.input, 0.30, "flash input")
        assertClose(breakdown?.cacheRead, 0.012, "flash cacheRead")
    }

    func testDSHCacheWriteIsFreeForFlash() {
        // 官方 Flash 不收缓存写入费；cacheCreation 行必须是 0，不能把未知费用伪装成已知价格
        let breakdown = Pricing.costBreakdown(
            app: .dsh,
            model: "deepseek-v4.1-flash",
            speed: .standard,
            input: 0,
            output: 0,
            cacheRead: 0,
            cacheCreation: 1_000_000,
            at: utc(2026, 9, 15)
        )
        assertClose(breakdown?.cacheCreation, 0, "cacheCreation")
    }

    // MARK: - 其他服务不受影响

    func testOtherModelsKeepTheirPricesAcrossDeepSeekBoundaries() {
        // 同为 DeepSeek 但未纳入分段价的型号：现值不变（避免顺手改动其他价目）
        assertRates("deepseek-v3.2", at: utc(2026, 8, 1), input: 0.28, output: 0.42, cacheRead: 0.028)
        assertRates("deepseek-v3.2", at: utc(2026, 9, 15), input: 0.28, output: 0.42, cacheRead: 0.028)
        // 跨服务：Gemini / Claude 在 DeepSeek 调价时点前后完全一致
        assertRates("gemini-3.1-pro", at: utc(2026, 8, 1), input: 1.25, output: 5.00, cacheRead: 0.3125)
        assertRates("gemini-3.1-pro", at: utc(2026, 9, 15), input: 1.25, output: 5.00, cacheRead: 0.3125)
        assertRates("claude-sonnet-5", at: utc(2026, 8, 1), input: 2, output: 10, cacheRead: 0.2)
        assertRates("claude-sonnet-5", at: utc(2026, 9, 15), input: 2, output: 10, cacheRead: 0.2)
    }

    func testUnknownModelStaysUnpriced() {
        XCTAssertNil(Pricing.cost(
            app: .dsh,
            model: "ccbar-test-model-without-price",
            speed: .standard,
            input: 100,
            output: 50,
            cacheRead: 0,
            cacheCreation: 0,
            at: utc(2026, 9, 15)
        ), "未定价模型必须返回 nil，不能折成真实 $0")
    }

    func testFastSpeedStaysUnpricedForDeepSeek() {
        // DSH 没有 Fast 档位；分段价只作用于 standard，不应顺带给 DeepSeek 造出 Fast 价
        XCTAssertNil(Pricing.cost(
            app: .dsh,
            model: "deepseek-v4.1-flash",
            speed: .fast,
            input: 1_000_000,
            output: 0,
            cacheRead: 0,
            cacheCreation: 0,
            at: utc(2026, 9, 15)
        ))
    }
}
