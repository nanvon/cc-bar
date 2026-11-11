import CryptoKit
import XCTest
@testable import CCBar

/// 价格规则文件的加载校验、验签和 revision 采纳。
///
/// 只读 App 内置的 `pricing-rules.json`，不读用户目录，不联网。
final class PricingRulesTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PricingCatalogStore.shared.resetCatalogForTesting()
        PricingRulesStore.shared.resetToBundledForTesting()
    }

    override func tearDown() {
        PricingRulesStore.shared.resetToBundledForTesting()
        super.tearDown()
    }

    private func bundledData() throws -> Data {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "pricing-rules", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    /// 改写内置文件的某一部分，用来构造不合格的规则。
    private func mutated(_ change: (inout [String: Any]) -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bundledData()) as? [String: Any])
        change(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func section(_ object: inout [String: Any], _ name: String, _ change: (inout [String: Any]) -> Void) {
        var value = object[name] as? [String: Any] ?? [:]
        change(&value)
        object[name] = value
    }

    // MARK: - 内置文件

    func testBundledRulesPassValidation() throws {
        let rules = try PricingRules.decode(bundledData())
        XCTAssertGreaterThanOrEqual(rules.revision, 1)
        XCTAssertFalse(rules.table.isEmpty)
        XCTAssertEqual(PricingRulesStore.loadBundled(), rules)
    }

    /// 字符串价格按十进制精确解析，不经 Double。
    func testPricesAreParsedAsExactDecimals() throws {
        let rules = try PricingRules.decode(bundledData())
        XCTAssertEqual(rules.table["deepseek-v4-flash"]?.cacheRead, Decimal(string: "0.0028"))
        XCTAssertEqual(rules.table["deepseek-v4-pro"]?.cacheRead, Decimal(string: "0.003625"))
        XCTAssertEqual(rules.claudeCacheCreation1hMultiplier, 2)
    }

    /// 按 UTC 时刻生效的分段：DeepSeek 精确到小时。
    func testTimedPeriodsUseUTCInstants() throws {
        let rules = try PricingRules.decode(bundledData())
        let periods = try XCTUnwrap(rules.timedOverrides["deepseek-v4-flash"])
        var components = DateComponents(year: 2026, month: 8, day: 16, hour: 16)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        let expected = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: components))
        XCTAssertEqual(periods.first?.from, expected)
    }

    // MARK: - 校验

    func testRejectsNewerSchemaVersion() throws {
        let data = try mutated { $0["schemaVersion"] = PricingRules.supportedSchemaVersion + 1 }
        XCTAssertThrowsError(try PricingRules.decode(data)) { error in
            guard case PricingRulesError.unsupportedSchema = error else { return XCTFail("\(error)") }
        }
    }

    func testRejectsNumericPrice() throws {
        let data = try mutated { object in
            section(&object, "standard") { standard in
                var prices = standard["prices"] as? [String: Any] ?? [:]
                prices["claude-opus-5"] = ["input": 5, "output": "25", "cacheRead": "0.5", "cacheCreation": "6.25"]
                standard["prices"] = prices
            }
        }
        XCTAssertThrowsError(try PricingRules.decode(data))
    }

    func testRejectsPriceWithTrailingGarbage() throws {
        let data = try mutated { object in
            section(&object, "standard") { standard in
                var prices = standard["prices"] as? [String: Any] ?? [:]
                prices["claude-opus-5"] = ["input": "5x", "output": "25", "cacheRead": "0.5", "cacheCreation": "6.25"]
                standard["prices"] = prices
            }
        }
        XCTAssertThrowsError(try PricingRules.decode(data))
    }

    /// 原来的 `precondition`：分段价的 key 必须在基础表里有最早时段的价格。
    func testRejectsTimedPriceWithoutBasePrice() throws {
        let data = try mutated { object in
            section(&object, "standard") { standard in
                var timed = standard["timedPrices"] as? [String: Any] ?? [:]
                timed["model-without-base"] = [[
                    "from": "2026-01-01T00:00:00Z",
                    "input": "1", "output": "2", "cacheRead": "0.1", "cacheCreation": "0"
                ]]
                standard["timedPrices"] = timed
            }
        }
        XCTAssertThrowsError(try PricingRules.decode(data)) { error in
            guard case PricingRulesError.invalid = error else { return XCTFail("\(error)") }
        }
    }

    func testRejectsFixedKeyWithoutPrice() throws {
        let data = try mutated { object in
            section(&object, "fast") { $0["fixedKeys"] = ["model-without-fast-price"] }
        }
        XCTAssertThrowsError(try PricingRules.decode(data))
    }

    func testRejectsPeriodsOutOfOrder() throws {
        let data = try mutated { object in
            section(&object, "standard") { standard in
                var timed = standard["timedPrices"] as? [String: Any] ?? [:]
                timed["claude-sonnet-5-5"] = [
                    ["from": "2026-10-07T00:00:00Z", "input": "2", "output": "10", "cacheRead": "0.1", "cacheCreation": "2.5"],
                    ["from": "2026-09-01T00:00:00Z", "input": "2", "output": "10", "cacheRead": "0.2", "cacheCreation": "2.5"]
                ]
                standard["timedPrices"] = timed
            }
        }
        XCTAssertThrowsError(try PricingRules.decode(data))
    }

    func testRejectsZeroRevision() throws {
        let data = try mutated { $0["revision"] = 0 }
        XCTAssertThrowsError(try PricingRules.decode(data))
    }

    /// 说明文字不参与指纹：只改 note 不会触发历史重建。
    func testNotesDoNotAffectFingerprint() throws {
        let original = try PricingRules.decode(bundledData())
        let data = try mutated { object in
            object["notes"] = ["changed"]
            section(&object, "standard") { standard in
                var prices = standard["prices"] as? [String: Any] ?? [:]
                var entry = prices["claude-opus-5"] as? [String: Any] ?? [:]
                entry["note"] = "changed"
                prices["claude-opus-5"] = entry
                standard["prices"] = prices
            }
        }
        XCTAssertEqual(try PricingRules.decode(data).localPriceBody, original.localPriceBody)
    }

    // MARK: - 验签

    func testVerifiedRulesRequiresMatchingSignature() throws {
        let key = Curve25519.Signing.PrivateKey()
        let data = try bundledData()
        let signature = Data(try key.signature(for: data).base64EncodedString().utf8)
        XCTAssertNoThrow(try PricingRulesStore.verifiedRules(data: data, signature: signature, publicKey: key.publicKey))

        let otherKey = Curve25519.Signing.PrivateKey().publicKey
        XCTAssertThrowsError(try PricingRulesStore.verifiedRules(data: data, signature: signature, publicKey: otherKey)) { error in
            guard case PricingRulesError.badSignature = error else { return XCTFail("\(error)") }
        }

        var tampered = data
        tampered.append(contentsOf: Array(" ".utf8))
        XCTAssertThrowsError(try PricingRulesStore.verifiedRules(data: tampered, signature: signature, publicKey: key.publicKey))
    }

    // MARK: - 采纳与切换

    func testStageAdoptsOnlyHigherRevisionAndCommitsAtBoundary() throws {
        let store = PricingRulesStore.shared
        let bundled = store.current().rules
        let before = Pricing.localPricingFingerprint()

        let same = try PricingRules.decode(mutated { $0["revision"] = bundled.revision })
        XCTAssertFalse(store.stage(same), "相同 revision 不采纳")

        let newer = try PricingRules.decode(mutated { object in
            object["revision"] = bundled.revision + 1
            section(&object, "standard") { standard in
                var prices = standard["prices"] as? [String: Any] ?? [:]
                prices["claude-opus-5"] = ["input": "6", "output": "30", "cacheRead": "0.6", "cacheCreation": "7.5"]
                standard["prices"] = prices
            }
        })
        XCTAssertTrue(store.stage(newer))
        // pending 不影响本轮计价，扫描开始前才切换。
        XCTAssertEqual(Pricing.localPricingFingerprint(), before)
        XCTAssertTrue(store.commitPending())
        XCTAssertNotEqual(Pricing.localPricingFingerprint(), before)
        XCTAssertEqual(store.current().rules.revision, bundled.revision + 1)

        let cost = Pricing.cost(
            app: .claude, model: "claude-opus-5", speed: .standard,
            input: 1_000_000, output: 0, cacheRead: 0, cacheCreation: 0, at: Date()
        )
        XCTAssertEqual(cost, 6)

        // 远端回滚到旧 revision 不会被采纳。
        XCTAssertFalse(store.stage(bundled))
        XCTAssertFalse(store.commitPending())
    }
}
