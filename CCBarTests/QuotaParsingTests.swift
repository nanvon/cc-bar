import XCTest
@testable import CCBar

final class QuotaParsingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // 测试宿主是 CCBar.app，PricingCatalogStore 单例启动时会读开发者机器的磁盘缓存；
        // 清空内存态与磁盘缓存，让计价断言稳定基于内置本地表，不被本机远端价格目录漂移。
        PricingCatalogStore.shared.resetCatalogForTesting()
    }

    func testCodexNormalResponseKeepsFiveHourPrimaryAndWeeklySecondary() {
        let fetched = CodexQuotaClient.parse(root: codexRoot(
            primarySeconds: 18_000,
            secondarySeconds: 604_800
        ))

        XCTAssertEqual(fetched.snapshot.primaryLimit?.kind, .fiveHour)
        XCTAssertEqual(fetched.snapshot.secondaryLimit?.kind, .weekly)
        XCTAssertEqual(fetched.snapshot.primaryWindow?.remainingPercent, 68)
    }

    // MARK: - Antigravity retrieveUserQuota buckets

    private func antigravityBucket(
        modelId: String,
        remaining: Double,
        reset: String? = nil,
        bucketId: String? = nil,
        tokenType: String? = "WTUS"
    ) -> [String: Any] {
        var b: [String: Any] = ["modelId": modelId, "remainingFraction": remaining]
        if let tokenType { b["tokenType"] = tokenType }
        if let reset { b["resetTime"] = reset }
        if let bucketId { b["bucketId"] = bucketId }
        return b
    }

    private func antigravityFetch(buckets: [[String: Any]], at time: Date = Date(timeIntervalSince1970: 1_750_000_000)) -> AntigravityQuotaClient.Fetched {
        AntigravityQuotaClient.parse(root: ["buckets": buckets], fetchedAt: time)
    }

    // MARK: - Antigravity retrieveUserQuotaSummary groups（真实 free-tier 响应）

    /// 真实 `retrieveUserQuotaSummary`（免费版账号实测，2026-09-02）：
    /// Gemini Models 组含 gemini-weekly（已用 15.6%）/ gemini-5h；
    /// Claude and GPT models 组含 3p-weekly（已用 33.8%）/ 3p-5h。
    private func antigravitySummaryGroups() -> [[String: Any]] {
        [
            [
                "description": "Models within this group: Gemini Flash, Gemini Pro",
                "displayName": "Gemini Models",
                "buckets": [
                    [
                        "bucketId": "gemini-weekly",
                        "displayName": "Weekly Limit Remaining",
                        "description": "You have used some of your weekly limit, it will fully refresh in 6 days.",
                        "remainingFraction": 0.8439504,
                        "resetTime": "2026-09-08T07:27:48Z",
                        "window": "weekly",
                    ],
                    [
                        "bucketId": "gemini-5h",
                        "displayName": "Five Hour Limit Remaining",
                        "description": "",
                        "remainingFraction": 1,
                        "resetTime": "2026-09-02T11:23:08Z",
                        "window": "5h",
                    ],
                ],
            ],
            [
                "description": "Models within this group: Claude Opus, Claude Sonnet, GPT-OSS",
                "displayName": "Claude and GPT models",
                "buckets": [
                    [
                        "bucketId": "3p-weekly",
                        "displayName": "Weekly Limit Remaining",
                        "description": "You have used some of your weekly limit, it will fully refresh in 6 days, 2 hours.",
                        "remainingFraction": 0.6616248,
                        "resetTime": "2026-09-08T09:29:14Z",
                        "window": "weekly",
                    ],
                    [
                        "bucketId": "3p-5h",
                        "displayName": "Five Hour Limit Remaining",
                        "description": "",
                        "remainingFraction": 1,
                        "resetTime": "2026-09-02T11:50:29Z",
                        "window": "5h",
                    ],
                ],
            ],
        ]
    }

    /// 真实免费版账号的 retrieveUserQuotaSummary：应解析出第三方主 5h、第三方周、
    /// Gemini 5h、Gemini 周四个窗口，且 Gemini 周与第三方周分别落到各自槽位。
    func testAntigravitySummaryGroupsParseFourWindows() {
        let fetched = AntigravityQuotaClient.parse(
            root: ["groups": antigravitySummaryGroups()],
            fetchedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let snap = fetched.snapshot

        // 主条 = Gemini 5h（未用，100%），标签 Gemini 5H
        XCTAssertEqual(snap.primaryLimit?.kind, .fiveHour)
        XCTAssertEqual(snap.primaryLimit?.displayName, "Gemini 5H")
        XCTAssertEqual(snap.primaryWindow?.usedPercent ?? 0, 0, accuracy: 0.01)
        XCTAssertNotNil(snap.primaryWindow?.resetsAt)
        // 副条 = Gemini 周（15.6% 已用），标签 Gemini WK
        XCTAssertEqual(snap.secondaryLimit?.kind, .weekly)
        XCTAssertEqual(snap.secondaryLimit?.displayName, "Gemini WK")
        XCTAssertEqual(snap.secondaryWindow?.usedPercent ?? 0, 15.6, accuracy: 0.1)
        XCTAssertEqual(snap.secondaryWindow?.windowSeconds, 7 * 24 * 3600)
        XCTAssertNotNil(snap.secondaryWindow?.resetsAt)
        // 辅助两行 = Claude 5H + Claude WK（33.8% 已用）
        XCTAssertEqual(snap.auxiliaryLimits.count, 2)
        XCTAssertEqual(snap.auxiliaryLimits[0].displayName, "Claude 5H")
        XCTAssertEqual(snap.auxiliaryLimits[0].kind, .fiveHour)
        XCTAssertEqual(snap.auxiliaryLimits[0].window.usedPercent ?? 0, 0, accuracy: 0.01)
        XCTAssertEqual(snap.auxiliaryLimits[1].displayName, "Claude WK")
        XCTAssertEqual(snap.auxiliaryLimits[1].kind, .weekly)
        XCTAssertEqual(snap.auxiliaryLimits[1].window.usedPercent ?? 0, 33.8, accuracy: 0.1)
        XCTAssertEqual(snap.auxiliaryLimits[1].window.windowSeconds, 7 * 24 * 3600)
        // 不再使用 gemini 细行字段
        XCTAssertNil(snap.geminiWindow)
        XCTAssertNil(snap.geminiWeekly)
    }

    /// 无前缀（缺 gemini-/3p-）的旧结构：靠组 displayName 区分 Gemini 与第三方。
    func testAntigravitySummaryGroupsFallbackToGroupNameWhenPrefixMissing() {
        let groups: [[String: Any]] = [
            ["displayName": "Gemini Models", "buckets": [
                ["bucketId": "week", "window": "weekly", "remainingFraction": 0.9],
                ["bucketId": "five_hour", "window": "5h", "remainingFraction": 0.8],
            ]],
            ["displayName": "Claude and GPT models", "buckets": [
                ["bucketId": "week", "window": "weekly", "remainingFraction": 0.7],
                ["bucketId": "five_hour", "window": "5h", "remainingFraction": 0.6],
            ]],
        ]
        let fetched = AntigravityQuotaClient.parse(root: ["groups": groups], fetchedAt: Date(timeIntervalSince1970: 1_750_000_000))
        let snap = fetched.snapshot

        // 主条 = Gemini 5h（20% used）
        XCTAssertEqual(snap.primaryWindow?.usedPercent ?? 0, 20, accuracy: 0.01)
        XCTAssertEqual(snap.primaryLimit?.displayName, "Gemini 5H")
        // 副条 = Gemini WK（10% used）
        XCTAssertEqual(snap.secondaryWindow?.usedPercent ?? 0, 10, accuracy: 0.01)
        XCTAssertEqual(snap.secondaryLimit?.displayName, "Gemini WK")
        // 辅助 = Claude 5H（40% used）+ Claude WK（30% used）
        XCTAssertEqual(snap.auxiliaryLimits.map(\.displayName), ["Claude 5H", "Claude WK"])
        XCTAssertEqual(snap.auxiliaryLimits[0].window.usedPercent ?? 0, 40, accuracy: 0.01)
        XCTAssertEqual(snap.auxiliaryLimits[1].window.usedPercent ?? 0, 30, accuracy: 0.01)
    }

    /// Pro 账号会同时返回基础 currentTier=free-tier；会员身份应取 paidTier。
    func testAntigravityLoadCodeAssistPrefersPaidTierOverCurrentTier() {
        let root: [String: Any] = [
            "currentTier": ["id": "free-tier", "name": "Antigravity"],
            "paidTier": ["id": "g1-pro-tier", "name": "Google AI Pro"],
        ]
        let fetched = AntigravityQuotaClient.parse(root: root, fetchedAt: Date(timeIntervalSince1970: 1_750_000_000))
        XCTAssertEqual(fetched.snapshot.planType, "Google AI Pro")
    }

    /// 没有付费订阅时仍保留 currentTier 作为套餐兜底。
    func testAntigravityLoadCodeAssistFallsBackToCurrentTier() {
        let root: [String: Any] = [
            "currentTier": ["id": "free-tier", "name": "Antigravity"],
        ]
        let fetched = AntigravityQuotaClient.parse(root: root, fetchedAt: Date(timeIntervalSince1970: 1_750_000_000))
        XCTAssertEqual(fetched.snapshot.planType, "free-tier")
    }

    /// 服务端未给 resetTime 时只展示额度，不按窗口长度虚构重置时间。
    func testAntigravitySummaryDoesNotSynthesizeMissingResetTime() {
        let groups: [[String: Any]] = [[
            "displayName": "Gemini Models",
            "buckets": [[
                "bucketId": "gemini-5h",
                "window": "5h",
                "remainingFraction": 1.0,
            ]],
        ]]
        let fetched = AntigravityQuotaClient.parse(root: ["groups": groups], fetchedAt: Date(timeIntervalSince1970: 1_750_000_000))
        XCTAssertEqual(fetched.snapshot.primaryWindow?.usedPercent, 0)
        XCTAssertNil(fetched.snapshot.primaryWindow?.resetsAt)
    }

    /// Free 账号真实响应：第三方（Claude/GPT）模型与 Gemini 模型各有 5h 轮换 reset，
    /// 内部桶（chat_/tab_ 等无 reset、remaining=1）不代表额度窗口。
    func testAntigravityRetrieveUserQuotaBucketsClassifiesThirdPartyAndGemini() {
        let fetched = antigravityFetch(buckets: [
            antigravityBucket(modelId: "chat_20706", remaining: 1),
            antigravityBucket(modelId: "chat_23310", remaining: 1),
            antigravityBucket(modelId: "claude-opus-4-6-thinking", remaining: 0.55, reset: "2026-09-02T11:04:10Z"),
            antigravityBucket(modelId: "gpt-oss-120b-medium", remaining: 0.8, reset: "2026-09-02T11:04:10Z"),
            antigravityBucket(modelId: "gemini-2.5-pro", remaining: 0.97, reset: "2026-09-02T06:23:08Z"),
            antigravityBucket(modelId: "gemini-3.5-flash-low", remaining: 0.97, reset: "2026-09-02T06:23:08Z"),
        ])

        // 第三方 5h 主条：Claude 更紧张（45% used）
        XCTAssertEqual(fetched.snapshot.primaryLimit?.kind, .fiveHour)
        XCTAssertEqual(fetched.snapshot.primaryWindow?.usedPercent ?? 0, 45, accuracy: 0.01)
        XCTAssertNotNil(fetched.snapshot.primaryWindow?.resetsAt)
        // Gemini 轮换 5h（remaining 96.7 → 3.3% used）
        XCTAssertEqual(fetched.snapshot.geminiWindow?.usedPercent ?? 0, 3, accuracy: 0.01)
        XCTAssertNotNil(fetched.snapshot.geminiWindow?.resetsAt)
        // 内部 / 未消耗桶不产生窗口
        XCTAssertNil(fetched.snapshot.geminiWeekly)
        XCTAssertNil(fetched.snapshot.secondaryLimit)
        XCTAssertNil(fetched.snapshot.weekly)
    }

    /// 未消耗（remaining=1 且无 reset）的第三方桶，不应被当成有效额度窗口。
    func testAntigravityRetrieveUserQuotaIgnoresUnconsumedPlaceholders() {
        let fetched = antigravityFetch(buckets: [
            antigravityBucket(modelId: "claude-sonnet-4-6", remaining: 1),
            antigravityBucket(modelId: "gemini-2.5-pro", remaining: 1),
        ])

        XCTAssertNil(fetched.snapshot.primaryLimit)
        XCTAssertNil(fetched.snapshot.secondaryLimit)
        XCTAssertNil(fetched.snapshot.geminiWindow)
        XCTAssertNil(fetched.snapshot.geminiWeekly)
    }

    /// 同一窗口多个模型：只取最紧张（remaining 最小）的一个作为主额度。
    func testAntigravityRetrieveUserQuotaTakesTightestBucket() {
        let fetched = antigravityFetch(buckets: [
            antigravityBucket(modelId: "claude-sonnet-4-6", remaining: 0.85, reset: "2026-09-02T11:04:10Z"),
            antigravityBucket(modelId: "claude-opus-4-6-thinking", remaining: 0.45, reset: "2026-09-02T11:04:10Z"),
        ])

        XCTAssertEqual(fetched.snapshot.primaryLimit?.kind, .fiveHour)
        XCTAssertEqual(fetched.snapshot.primaryWindow?.usedPercent ?? 0, 55, accuracy: 0.01)
    }

    /// 富化补齐周额度：主条已是 5h 时，周额度应落在 secondary 而不是被丢掉。
    func testAntigravityRetrieveUserQuotaWeeklyFillsSecondarySlot() {
        let fetched = antigravityFetch(buckets: [
            antigravityBucket(modelId: "claude-opus-4-6-thinking", remaining: 0.55, reset: "2026-09-02T11:04:10Z"),
            antigravityBucket(modelId: "gemini-2.5-pro", remaining: 0.97, reset: "2026-09-02T06:23:08Z"),
            antigravityBucket(modelId: "claude-opus-4-6", remaining: 0.9, reset: "2026-09-07T00:00:00Z", bucketId: "WEEKLY"),
        ])

        XCTAssertEqual(fetched.snapshot.primaryLimit?.kind, .fiveHour)
        XCTAssertEqual(fetched.snapshot.primaryWindow?.usedPercent ?? 0, 45, accuracy: 0.01)
        XCTAssertEqual(fetched.snapshot.secondaryLimit?.kind, .weekly)
        XCTAssertEqual(fetched.snapshot.secondaryWindow?.usedPercent ?? 0, 10, accuracy: 0.01)
        XCTAssertEqual(fetched.snapshot.weekly?.usedPercent ?? 0, 10, accuracy: 0.01)
    }

    /// merge 语义：base 已有 primary(5h)，富化只含 weekly 时 secondary 应被补齐且保持周语义。
    func testAntigravityMergeFillsSecondaryWeeklyWithoutOverwritingPrimary() {
        // base: 5h 第三方窗口（claude-opus…5h）
        let base = antigravityFetch(buckets: [
            antigravityBucket(modelId: "claude-opus-4-6-thinking", remaining: 0.55, reset: "2026-09-02T11:04:10Z"),
        ])
        XCTAssertEqual(base.snapshot.primaryLimit?.kind, .fiveHour)
        XCTAssertNil(base.snapshot.secondaryLimit)

        // enrichment: 只有 weekly 桶（无 5h）
        let enrichment = antigravityFetch(buckets: [
            antigravityBucket(modelId: "claude-opus-4-6", remaining: 0.9, reset: "2026-09-07T00:00:00Z", bucketId: "WEEKLY"),
        ])
        XCTAssertEqual(enrichment.snapshot.primaryLimit?.kind, .weekly, "只有 weekly 时主条应为 weekly")

        // merge 应把 weekly 挂到 secondary，同时保留 base 的 5h 主条
        let merged = AntigravityQuotaClient.merge(base: base, enrichment: enrichment)

        XCTAssertEqual(merged.snapshot.primaryLimit?.kind, .fiveHour)
        XCTAssertEqual(merged.snapshot.primaryWindow?.usedPercent ?? 0, 45, accuracy: 0.01)
        XCTAssertEqual(merged.snapshot.secondaryLimit?.kind, .weekly)
        XCTAssertEqual(merged.snapshot.secondaryLimit?.window.usedPercent ?? 0, 10, accuracy: 0.01)
    }

    /// merge 时 base（loadCodeAssist）无 aux，富化（retrieveUserQuotaSummary）带
    /// Claude 5H / Claude WK 两行：aux 必须被补进快照，否则 UI 只剩 Gemini 两行。
    func testAntigravityMergeCarriesAuxiliaryLimitsFromSummary() {
        // base：loadCodeAssist 无任何额度窗口
        let base = AntigravityQuotaClient.parse(
            root: ["currentTier": ["id": "free-tier"]],
            fetchedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
        XCTAssertNil(base.snapshot.primaryLimit)
        XCTAssertTrue(base.snapshot.auxiliaryLimits.isEmpty)

        // enrichment：retrieveUserQuotaSummary 分组源
        let enrichment = AntigravityQuotaClient.parse(
            root: ["groups": antigravitySummaryGroups()],
            fetchedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
        XCTAssertEqual(enrichment.snapshot.auxiliaryLimits.map(\.displayName), ["Claude 5H", "Claude WK"])

        let merged = AntigravityQuotaClient.merge(base: base, enrichment: enrichment)

        XCTAssertEqual(merged.snapshot.primaryLimit?.displayName, "Gemini 5H")
        XCTAssertEqual(merged.snapshot.secondaryLimit?.displayName, "Gemini WK")
        XCTAssertEqual(merged.snapshot.auxiliaryLimits.map(\.displayName), ["Claude 5H", "Claude WK"])
    }

    func testCodexTemporaryWeeklyOnlyResponseUsesWeeklyAsPrimary() {
        let fetched = CodexQuotaClient.parse(root: codexRoot(
            primarySeconds: 604_800,
            secondarySeconds: nil
        ))

        XCTAssertEqual(fetched.snapshot.primaryLimit?.kind, .weekly)
        XCTAssertNil(fetched.snapshot.secondaryLimit)
        XCTAssertNil(fetched.snapshot.fiveHour)
        XCTAssertEqual(fetched.snapshot.weekly?.remainingPercent, 68)
    }

    func testCodexUnknownWindowDoesNotPretendToBeFiveHour() {
        let fetched = CodexQuotaClient.parse(root: codexRoot(
            primarySeconds: 86_400,
            secondarySeconds: nil
        ))

        XCTAssertEqual(fetched.snapshot.primaryLimit?.kind, .unknown)
        XCTAssertNil(fetched.snapshot.fiveHour)
        XCTAssertNil(fetched.snapshot.weekly)
    }

    func testCursorSummaryMapsStableTotalAutoAndAPILimits() throws {
        let data = Data("""
        {
          "billingCycleStart": "2026-08-01T00:00:00Z",
          "billingCycleEnd": "2026-09-01T00:00:00Z",
          "membershipType": "pro_plus",
          "limitType": "individual",
          "isUnlimited": false,
          "individualUsage": {
            "plan": {
              "used": 2500,
              "limit": 20000,
              "totalPercentUsed": 12.5,
              "autoPercentUsed": 4.25,
              "apiPercentUsed": 8.25
            }
          }
        }
        """.utf8)

        let fetchedAt = Date(timeIntervalSince1970: 1_000)
        let snapshot = try CursorQuotaClient.parse(data: data, fetchedAt: fetchedAt)

        XCTAssertEqual(snapshot.app, .cursor)
        XCTAssertEqual(snapshot.primaryLimit?.id, "cursor-total")
        XCTAssertEqual(snapshot.secondaryLimit?.id, "cursor-auto")
        XCTAssertEqual(snapshot.auxiliaryLimits.map(\.id), ["cursor-api"])
        XCTAssertEqual(snapshot.primaryLimit?.window.usedPercent, 12.5)
        XCTAssertEqual(snapshot.secondaryLimit?.window.usedPercent, 4.25)
        XCTAssertEqual(snapshot.auxiliaryLimits.first?.window.usedPercent, 8.25)
        XCTAssertEqual(snapshot.primaryLimit?.window.windowSeconds, 31 * 24 * 60 * 60)
        XCTAssertEqual(snapshot.planType, "Pro Plus")
        XCTAssertEqual(snapshot.isUnlimited, false)
        XCTAssertEqual(snapshot.fetchedAt, fetchedAt)
    }

    func testCursorTeamPooledLimitTakesPrecedenceOverPlanTotal() throws {
        let data = Data("""
        {
          "limitType": "team",
          "individualUsage": {
            "plan": {"totalPercentUsed": 12}
          },
          "teamUsage": {
            "pooled": {"enabled": true, "used": 250, "limit": 1000, "remaining": 750}
          }
        }
        """.utf8)

        let snapshot = try CursorQuotaClient.parse(data: data)

        XCTAssertEqual(snapshot.primaryLimit?.window.usedPercent, 25)
    }

    func testCursorPlanRatioFallsBackWhenTotalPercentIsMissing() throws {
        let data = Data("""
        {
          "individualUsage": {
            "plan": {"used": "375", "limit": "1500"}
          }
        }
        """.utf8)

        let snapshot = try CursorQuotaClient.parse(data: data)

        XCTAssertEqual(snapshot.primaryLimit?.window.usedPercent, 25)
    }

    func testCursorDoesNotInferTotalFromAutoAndAPI() throws {
        let data = Data("""
        {
          "individualUsage": {
            "plan": {"autoPercentUsed": 10, "apiPercentUsed": 30}
          }
        }
        """.utf8)

        let snapshot = try CursorQuotaClient.parse(data: data)

        XCTAssertNil(snapshot.primaryLimit)
        XCTAssertEqual(snapshot.secondaryLimit?.id, "cursor-auto")
        XCTAssertEqual(snapshot.auxiliaryLimits.first?.id, "cursor-api")
    }

    /// Free 账号的真实响应里 totalPercentUsed 是 1、apiPercentUsed 是 0。
    /// JSON 数字 0 / 1 解析出的 NSNumber 会命中 `is Bool` 桥接，早期实现把这两档整个丢掉，
    /// Popover 只剩 AUTO，Total 位退化成 "--" / "CURRENT"。
    func testCursorFreePlanKeepsZeroAndOnePercentLimits() throws {
        let data = Data("""
        {
          "billingCycleStart": "2026-08-22T07:26:49.214Z",
          "billingCycleEnd": "2026-09-22T07:26:49.214Z",
          "membershipType": "free",
          "limitType": "user",
          "isUnlimited": false,
          "individualUsage": {
            "plan": {
              "enabled": true,
              "used": 0,
              "limit": 0,
              "remaining": 0,
              "autoPercentUsed": 2,
              "apiPercentUsed": 0,
              "totalPercentUsed": 1
            }
          },
          "teamUsage": {}
        }
        """.utf8)

        let snapshot = try CursorQuotaClient.parse(data: data)

        XCTAssertEqual(snapshot.primaryLimit?.id, "cursor-total")
        XCTAssertEqual(snapshot.primaryLimit?.window.usedPercent, 1)
        XCTAssertEqual(snapshot.secondaryLimit?.window.usedPercent, 2)
        XCTAssertEqual(snapshot.auxiliaryLimits.map(\.id), ["cursor-api"])
        XCTAssertEqual(snapshot.auxiliaryLimits.first?.window.usedPercent, 0)
        XCTAssertEqual(snapshot.planType, "Free")
        XCTAssertEqual(snapshot.isUnlimited, false)
    }

    func testCursorUnlimitedDoesNotFabricateZeroPercent() throws {
        let data = Data("""
        {
          "membershipType": "enterprise",
          "isUnlimited": true
        }
        """.utf8)

        let snapshot = try CursorQuotaClient.parse(data: data)

        XCTAssertNil(snapshot.primaryLimit)
        XCTAssertEqual(snapshot.isUnlimited, true)
        XCTAssertEqual(snapshot.planType, "Enterprise")
    }

    func testQuotaSnapshotWithoutCursorFieldsKeepsBackwardCompatibleDefaults() throws {
        let data = Data("""
        {
          "app": "codex",
          "primaryLimit": null,
          "secondaryLimit": null,
          "modelLimits": [],
          "planType": "plus",
          "fetchedAt": 0
        }
        """.utf8)

        let snapshot = try JSONDecoder().decode(QuotaSnapshot.self, from: data)

        XCTAssertTrue(snapshot.auxiliaryLimits.isEmpty)
        XCTAssertNil(snapshot.isUnlimited)
    }

    func testCursorQuotaCacheRoundTripsAccountBinding() throws {
        let snapshot = QuotaSnapshot(
            app: .cursor,
            primaryLimit: nil,
            secondaryLimit: nil,
            planType: "Pro",
            fetchedAt: Date(timeIntervalSince1970: 1_000)
        )
        let payload = QuotaCachePayload(providers: [
            .cursor: QuotaCacheRecord(
                snapshot: snapshot,
                source: .api,
                updatedAt: Date(timeIntervalSince1970: 1_000),
                accountID: "cursor-user"
            ),
        ])

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(QuotaCachePayload.self, from: data)

        XCTAssertEqual(decoded.version, QuotaCachePayload.currentVersion)
        XCTAssertEqual(decoded.cursor?.accountID, "cursor-user")
        XCTAssertEqual(decoded.cursor?.snapshot, snapshot)
    }

    func testLegacyCursorQuotaCacheWithoutAccountBindingStillDecodes() throws {
        let data = Data("""
        {
          "version": 3,
          "providers": {
            "cursor": {
              "snapshot": {
                "app": "cursor",
                "primaryLimit": null,
                "secondaryLimit": null,
                "modelLimits": [],
                "planType": "Pro",
                "fetchedAt": 0
              },
              "source": "api",
              "updatedAt": 0
            }
          }
        }
        """.utf8)

        let payload = try JSONDecoder().decode(QuotaCachePayload.self, from: data)

        XCTAssertEqual(payload.version, QuotaCachePayload.currentVersion)
        XCTAssertEqual(payload.cursor?.snapshot.app, .cursor)
        XCTAssertNil(payload.cursor?.accountID)
    }

    func testCursorAuxiliaryLimitCarriesForwardFutureReset() {
        let now = Date(timeIntervalSince1970: 1_000)
        let reset = Date(timeIntervalSince1970: 2_000)
        let previous = QuotaSnapshot(
            app: .cursor,
            primaryLimit: nil,
            secondaryLimit: nil,
            auxiliaryLimits: [QuotaLimit(
                id: "cursor-api",
                kind: .unknown,
                displayName: "API",
                window: QuotaWindow(usedPercent: 1, resetsAt: reset, windowSeconds: 1000),
                isActive: nil
            )],
            planType: "Pro",
            fetchedAt: now
        )
        let current = QuotaSnapshot(
            app: .cursor,
            primaryLimit: nil,
            secondaryLimit: nil,
            auxiliaryLimits: [QuotaLimit(
                id: "cursor-api",
                kind: .unknown,
                displayName: "API",
                window: QuotaWindow(usedPercent: 2, resetsAt: nil, windowSeconds: 1000),
                isActive: nil
            )],
            planType: "Pro",
            fetchedAt: now
        )

        let preserved = current.preservingFutureResetDates(from: previous, now: now)

        XCTAssertEqual(preserved.auxiliaryLimits.first?.window.resetsAt, reset)
    }

    func testClaudeMergesLegacyWindowsAndDynamicFableLimit() {
        let root: [String: Any] = [
            "five_hour": ["utilization": 2.0, "resets_at": "2026-07-13T02:30:00.424333+00:00"],
            "seven_day": ["utilization": 0.0, "resets_at": NSNull()],
            "seven_day_opus": NSNull(),
            "seven_day_sonnet": NSNull(),
            "limits": [
                [
                    "kind": "session",
                    "percent": 2,
                    "resets_at": "2026-07-13T02:30:00.424333+00:00",
                    "is_active": true,
                    "scope": NSNull(),
                ],
                [
                    "kind": "weekly_all",
                    "percent": 0,
                    "resets_at": NSNull(),
                    "is_active": false,
                    "scope": NSNull(),
                ],
                [
                    "kind": "weekly_scoped",
                    "percent": 0,
                    "resets_at": NSNull(),
                    "is_active": false,
                    "scope": [
                        "model": ["display_name": "Fable", "id": NSNull()],
                        "surface": NSNull(),
                    ],
                ],
            ],
        ]

        let snapshot = ClaudeQuotaClient.parse(root: root)

        XCTAssertEqual(snapshot.primaryLimit?.kind, .fiveHour)
        XCTAssertEqual(snapshot.secondaryLimit?.kind, .weekly)
        XCTAssertEqual(snapshot.modelLimits.count, 1)
        XCTAssertEqual(snapshot.modelLimits.first?.displayName, "Fable")
        XCTAssertEqual(snapshot.modelLimits.first?.kind, .modelWeekly)
        XCTAssertEqual(snapshot.modelLimits.first?.window.remainingPercent, 100)
    }

    func testMissingResetCarriesOnlyStillValidMatchingReset() {
        let now = Date(timeIntervalSince1970: 1_000)
        let old = snapshot(
            kind: .weekly,
            usedPercent: 1,
            reset: Date(timeIntervalSince1970: 2_000)
        )
        let fresh = snapshot(kind: .weekly, usedPercent: 2, reset: nil)

        XCTAssertEqual(
            fresh.preservingFutureResetDates(from: old, now: now).primaryWindow?.resetsAt,
            Date(timeIntervalSince1970: 2_000)
        )
        XCTAssertNil(
            fresh.preservingFutureResetDates(
                from: old,
                now: Date(timeIntervalSince1970: 3_000)
            ).primaryWindow?.resetsAt
        )
    }

    func testLegacyCodexCacheReclassifiesSevenDayFiveHourSlot() throws {
        let data = Data("""
        {
          "app": "codex",
          "fiveHour": {"usedPercent": 1, "resetsAt": null, "windowSeconds": 604800},
          "weekly": null,
          "weeklyOpus": null,
          "weeklySonnet": null,
          "planType": "plus",
          "fetchedAt": 0
        }
        """.utf8)

        let snapshot = try JSONDecoder().decode(QuotaSnapshot.self, from: data)

        XCTAssertEqual(snapshot.primaryLimit?.kind, .weekly)
        XCTAssertNil(snapshot.secondaryLimit)
    }

    func testMenuBarBothDoesNotDuplicateWeeklyOnlyPrimary() {
        let weeklyOnly = snapshot(kind: .weekly, usedPercent: 1, reset: nil)
        XCTAssertEqual(MenuBarQuotaSelection.limits(in: weeklyOnly, choice: .primary).count, 1)
        XCTAssertEqual(MenuBarQuotaSelection.limits(in: weeklyOnly, choice: .weekly).count, 1)
        XCTAssertEqual(MenuBarQuotaSelection.limits(in: weeklyOnly, choice: .both).count, 1)
    }

    func testMenuBarCursorUsesOnlyTotalForEveryDisplayChoice() {
        let total = QuotaLimit(
            id: "cursor-total",
            kind: .unknown,
            displayName: "Total",
            window: QuotaWindow(usedPercent: 12, resetsAt: nil, windowSeconds: nil),
            isActive: nil
        )
        let auto = QuotaLimit(
            id: "cursor-auto",
            kind: .unknown,
            displayName: "Auto",
            window: QuotaWindow(usedPercent: 34, resetsAt: nil, windowSeconds: nil),
            isActive: nil
        )
        let api = QuotaLimit(
            id: "cursor-api",
            kind: .unknown,
            displayName: "API",
            window: QuotaWindow(usedPercent: 56, resetsAt: nil, windowSeconds: nil),
            isActive: nil
        )
        let cursor = QuotaSnapshot(
            app: .cursor,
            primaryLimit: total,
            secondaryLimit: auto,
            auxiliaryLimits: [api],
            planType: "Pro",
            fetchedAt: .now
        )

        for choice in MenuBarWindowChoice.allCases {
            XCTAssertEqual(
                MenuBarQuotaSelection.limits(in: cursor, choice: choice).map(\.id),
                ["cursor-total"]
            )
        }
    }

    func testHistoryKeepsSeriesSeparatelyWhenPrimaryKindChanges() {
        let start = Date(timeIntervalSince1970: 1_000)
        var payload = QuotaHistoryPayload(dayStart: QuotaHistoryStore.todayStart(now: start))
        payload = QuotaHistoryStore.record(
            payload: payload,
            accountKey: "codex:primary",
            app: .codex,
            kind: .codexPrimary,
            snapshot: snapshot(kind: .weekly, usedPercent: 1, reset: nil),
            sampledAt: start
        )
        payload = QuotaHistoryStore.record(
            payload: payload,
            accountKey: "codex:primary",
            app: .codex,
            kind: .codexPrimary,
            snapshot: snapshot(kind: .weekly, usedPercent: 2, reset: nil),
            sampledAt: start.addingTimeInterval(60)
        )
        XCTAssertEqual(payload.events.count, 1)

        // 主额度从 WK 切成 5H：两条窗口是不同系列，仅 5H 系列重建基准，WK 系列事件保留。
        payload = QuotaHistoryStore.record(
            payload: payload,
            accountKey: "codex:primary",
            app: .codex,
            kind: .codexPrimary,
            snapshot: snapshot(kind: .fiveHour, usedPercent: 40, reset: nil),
            sampledAt: start.addingTimeInterval(120)
        )

        XCTAssertEqual(payload.events.count, 1, "仅重排基准，不抹掉其他窗口的事件")
        XCTAssertEqual(payload.events.first?.limitKind, .weekly)
        let fiveHourSeries = QuotaHistoryStore.seriesKey(accountKey: "codex:primary", limitKind: .fiveHour)
        XCTAssertEqual(payload.lastSamples[fiveHourSeries]?.limitKind, .fiveHour)
    }

    func testHistoryRecordsFiveHourAndWeeklySeriesInParallel() {
        let sampledAt = Date(timeIntervalSince1970: 1_000)
        var payload = QuotaHistoryPayload(dayStart: QuotaHistoryStore.todayStart(now: sampledAt))
        let fiveHourEnd = sampledAt.addingTimeInterval(18_000)
        let weeklyEnd = sampledAt.addingTimeInterval(604_800)
        payload = QuotaHistoryStore.record(
            payload: payload,
            accountKey: "claude:primary",
            app: .claude,
            kind: .claudePrimary,
            snapshot: snapshot(
                fiveHour: 88,
                weekly: 65,
                fiveHourEnd: fiveHourEnd,
                weeklyEnd: weeklyEnd
            ),
            sampledAt: sampledAt
        )
        payload = QuotaHistoryStore.record(
            payload: payload,
            accountKey: "claude:primary",
            app: .claude,
            kind: .claudePrimary,
            snapshot: snapshot(
                fiveHour: 80,
                weekly: 62,
                fiveHourEnd: fiveHourEnd,
                weeklyEnd: weeklyEnd
            ),
            sampledAt: sampledAt.addingTimeInterval(60)
        )

        XCTAssertEqual(payload.events.count, 2, "两个窗口各自产生一条变动事件")
        XCTAssertEqual(
            Set(payload.events.map(\.limitKind)),
            Set([.fiveHour, .weekly])
        )
        let fiveHourKey = QuotaHistoryStore.seriesKey(accountKey: "claude:primary", limitKind: .fiveHour)
        let weeklyKey = QuotaHistoryStore.seriesKey(accountKey: "claude:primary", limitKind: .weekly)
        // 样本记录的是剩余比例（remaining = 100 − used）。
        XCTAssertEqual(payload.lastSamples[fiveHourKey]?.remainingPercent, 20)
        XCTAssertEqual(payload.lastSamples[weeklyKey]?.remainingPercent, 38)
    }

    func testFiveHourTimelineUsesTodayFixedAxisAndKeepsLatestSampleAfterReset() {
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let todayStart = QuotaHistoryStore.todayStart(now: now)
        let yesterdaySample = todayStart.addingTimeInterval(-60 * 60)
        let todaySample = todayStart.addingTimeInterval(60 * 60)
        let key = "codex:primary"
        var payload = QuotaHistoryPayload(dayStart: todayStart)

        // 重置前的 0% 留在昨天；重置后的 70% 是今天的新基线，不应制造伪消耗事件。
        payload = QuotaHistoryStore.record(
            payload: payload,
            accountKey: key,
            app: .codex,
            kind: .codexPrimary,
            snapshot: snapshot(kind: .fiveHour, usedPercent: 100, reset: todayStart),
            sampledAt: yesterdaySample
        )
        payload = QuotaHistoryStore.record(
            payload: payload,
            accountKey: key,
            app: .codex,
            kind: .codexPrimary,
            snapshot: snapshot(kind: .fiveHour, usedPercent: 30, reset: todayStart.addingTimeInterval(5 * 60 * 60)),
            sampledAt: todaySample
        )

        let periods = QuotaHistoryStore.timelinePeriods(
            payload: payload,
            accountKey: key,
            limitKind: .fiveHour,
            now: now
        )

        XCTAssertEqual(periods.count, 1)
        XCTAssertEqual(periods[0].kind, .today)
        XCTAssertEqual(periods[0].start, todayStart)
        XCTAssertEqual(
            Calendar.current.dateComponents([.day], from: periods[0].start, to: periods[0].end).day,
            1
        )
        XCTAssertEqual(periods[0].entries.count, 1)
        XCTAssertEqual(periods[0].entries[0].source, .sample)
        XCTAssertEqual(periods[0].entries[0].sampledAt, todaySample)
        XCTAssertEqual(periods[0].entries[0].remainingPercent, 70)
        XCTAssertNil(periods[0].entries[0].deltaPercent)
    }

    func testFiveHourTimelineSplitsLineSeriesAtEachQuotaWindow() {
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let todayStart = QuotaHistoryStore.todayStart(now: now)
        let firstReset = todayStart.addingTimeInterval(5 * 60 * 60)
        let secondReset = firstReset.addingTimeInterval(5 * 60 * 60)
        let key = "codex:primary"
        var payload = QuotaHistoryPayload(dayStart: todayStart)

        // 第一个 5H 窗口：80% → 10%。
        for (used, offset) in [(20.0, 30.0), (90.0, 120.0)] {
            payload = QuotaHistoryStore.record(
                payload: payload,
                accountKey: key,
                app: .codex,
                kind: .codexPrimary,
                snapshot: snapshot(kind: .fiveHour, usedPercent: used, reset: firstReset),
                sampledAt: todayStart.addingTimeInterval(offset * 60)
            )
        }
        // 第二个 5H 窗口：重置回 100%，随后消耗到 60%。跨窗不产生变动事件。
        for (used, offset) in [(0.0, 310.0), (40.0, 360.0)] {
            payload = QuotaHistoryStore.record(
                payload: payload,
                accountKey: key,
                app: .codex,
                kind: .codexPrimary,
                snapshot: snapshot(kind: .fiveHour, usedPercent: used, reset: secondReset),
                sampledAt: todayStart.addingTimeInterval(offset * 60)
            )
        }

        let periods = QuotaHistoryStore.timelinePeriods(
            payload: payload,
            accountKey: key,
            limitKind: .fiveHour,
            now: now
        )

        XCTAssertEqual(periods.count, 1)
        let entries = periods[0].entries
        // 两个窗口必须落在不同的折线 series，否则图上会出现 10% → 100% 的假回升斜线。
        let indexesByReset = Dictionary(grouping: entries) { $0.windowIndex }
            .mapValues { Set($0.compactMap(\.resetsAt)) }
        XCTAssertEqual(indexesByReset.count, 2)
        XCTAssertEqual(entries.first?.windowIndex, 0)
        XCTAssertEqual(entries.last?.windowIndex, 1)
        XCTAssertTrue(entries.filter { $0.windowIndex == 0 }.allSatisfy { $0.resetsAt == firstReset })
        XCTAssertTrue(entries.filter { $0.windowIndex == 1 }.allSatisfy { $0.resetsAt == secondReset })
    }

    func testWeeklyTimelineKeepsPreviousCycleWhenResetPointShifted() {
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let currentEnd = now.addingTimeInterval(3 * 24 * 60 * 60)
        let currentStart = currentEnd.addingTimeInterval(-7 * 24 * 60 * 60)
        // 上一周期的重置点比「currentEnd − 7 天」早 2 天：停用一段时间后窗口重新起算。
        let previousEnd = currentStart.addingTimeInterval(-2 * 24 * 60 * 60)
        let key = "claude:primary"
        var payload = QuotaHistoryPayload(dayStart: QuotaHistoryStore.todayStart(now: now))

        for (used, offset) in [(30.0, -6.0), (45.0, -5.0)] {
            payload = QuotaHistoryStore.record(
                payload: payload,
                accountKey: key,
                app: .claude,
                kind: .claudePrimary,
                snapshot: snapshot(kind: .weekly, usedPercent: used, reset: previousEnd),
                sampledAt: previousEnd.addingTimeInterval(offset * 24 * 60 * 60)
            )
        }
        for (used, offset) in [(10.0, 1.0), (25.0, 2.0)] {
            payload = QuotaHistoryStore.record(
                payload: payload,
                accountKey: key,
                app: .claude,
                kind: .claudePrimary,
                snapshot: snapshot(kind: .weekly, usedPercent: used, reset: currentEnd),
                sampledAt: currentStart.addingTimeInterval(offset * 24 * 60 * 60)
            )
        }

        let periods = QuotaHistoryStore.timelinePeriods(
            payload: payload,
            accountKey: key,
            limitKind: .weekly,
            now: now
        )

        XCTAssertEqual(periods.map(\.kind), [.currentCycle, .previousCycle])
        // 上一周期的边界跟随事件自身的 resets_at，而不是「当前周期起点」硬推。
        XCTAssertEqual(periods[1].end, previousEnd)
        XCTAssertEqual(periods[1].start, previousEnd.addingTimeInterval(-7 * 24 * 60 * 60))
        XCTAssertTrue(periods[1].entries.contains { $0.source == .change && $0.deltaPercent == -15 })
        XCTAssertTrue(periods[0].entries.contains { $0.source == .change && $0.deltaPercent == -15 })
        // 两个周期不共享事件。
        let currentIDs = Set(periods[0].entries.map(\.id))
        let previousIDs = Set(periods[1].entries.map(\.id))
        XCTAssertTrue(currentIDs.isDisjoint(with: previousIDs))
    }

    func testWeeklyTimelineSeparatesCurrentAndPreviousQuotaCycles() {
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let currentEnd = now.addingTimeInterval(3 * 24 * 60 * 60)
        let currentStart = currentEnd.addingTimeInterval(-7 * 24 * 60 * 60)
        let previousStart = currentStart.addingTimeInterval(-7 * 24 * 60 * 60)
        let key = "claude:primary"
        var payload = QuotaHistoryPayload(dayStart: QuotaHistoryStore.todayStart(now: now))

        // 上一额度周期：50% → 40%。
        payload = QuotaHistoryStore.record(
            payload: payload,
            accountKey: key,
            app: .claude,
            kind: .claudePrimary,
            snapshot: snapshot(kind: .weekly, usedPercent: 50, reset: currentStart),
            sampledAt: previousStart.addingTimeInterval(60 * 60)
        )
        payload = QuotaHistoryStore.record(
            payload: payload,
            accountKey: key,
            app: .claude,
            kind: .claudePrimary,
            snapshot: snapshot(kind: .weekly, usedPercent: 60, reset: currentStart.addingTimeInterval(1)),
            sampledAt: previousStart.addingTimeInterval(2 * 60 * 60)
        )

        // 当前额度周期：75% → 65%，首个样本是跨周期新基线。
        payload = QuotaHistoryStore.record(
            payload: payload,
            accountKey: key,
            app: .claude,
            kind: .claudePrimary,
            snapshot: snapshot(kind: .weekly, usedPercent: 25, reset: currentEnd),
            sampledAt: currentStart.addingTimeInterval(60 * 60)
        )
        payload = QuotaHistoryStore.record(
            payload: payload,
            accountKey: key,
            app: .claude,
            kind: .claudePrimary,
            snapshot: snapshot(kind: .weekly, usedPercent: 35, reset: currentEnd.addingTimeInterval(1)),
            sampledAt: currentStart.addingTimeInterval(2 * 60 * 60)
        )
        payload = QuotaHistoryStore.record(
            payload: payload,
            accountKey: key,
            app: .claude,
            kind: .claudePrimary,
            snapshot: snapshot(kind: .weekly, usedPercent: 35, reset: currentEnd.addingTimeInterval(1)),
            sampledAt: now
        )

        let periods = QuotaHistoryStore.timelinePeriods(
            payload: payload,
            accountKey: key,
            limitKind: .weekly,
            now: now
        )

        XCTAssertEqual(periods.map(\.kind), [.currentCycle, .previousCycle])
        // 周期边界跟随最新采样的 resets_at，含服务端的秒级抖动，按同窗语义做容差比较。
        XCTAssertEqual(periods[0].start.timeIntervalSince(currentStart), 0, accuracy: 60)
        XCTAssertEqual(periods[0].end.timeIntervalSince(currentEnd), 0, accuracy: 60)
        XCTAssertEqual(periods[1].start.timeIntervalSince(previousStart), 0, accuracy: 60)
        XCTAssertEqual(periods[1].end.timeIntervalSince(currentStart), 0, accuracy: 60)
        XCTAssertTrue(periods[0].entries.contains { $0.source == .sample && $0.remainingPercent == 65 })
        XCTAssertTrue(periods[0].entries.contains { $0.source == .change && $0.deltaPercent == -10 })
        XCTAssertTrue(periods[1].entries.contains { $0.source == .change && $0.deltaPercent == -10 })
    }

    func testHistoryPrunesSamplesOlderThanRetentionWindow() {
        let old = Date(timeIntervalSince1970: 2_000) - 20 * 86_400
        var payload = QuotaHistoryPayload(dayStart: QuotaHistoryStore.todayStart(now: old))
        payload = QuotaHistoryStore.record(
            payload: payload,
            accountKey: "codex:primary",
            app: .codex,
            kind: .codexPrimary,
            snapshot: snapshot(kind: .weekly, usedPercent: 60, reset: nil),
            sampledAt: old
        )
        payload = QuotaHistoryStore.record(
            payload: payload,
            accountKey: "codex:primary",
            app: .codex,
            kind: .codexPrimary,
            snapshot: snapshot(kind: .weekly, usedPercent: 40, reset: nil),
            sampledAt: old.addingTimeInterval(60)
        )
        XCTAssertEqual(payload.events.count, 1)

        // 下次采样回到「现在」：20 天前的老事件与样本被 15 天保留窗口清掉。
        let now = Date()
        payload = QuotaHistoryStore.record(
            payload: payload,
            accountKey: "codex:primary",
            app: .codex,
            kind: .codexPrimary,
            snapshot: snapshot(kind: .weekly, usedPercent: 90, reset: nil),
            sampledAt: now
        )
        XCTAssertTrue(
            payload.events.allSatisfy { $0.sampledAt >= now.addingTimeInterval(-15 * 86_400) }
        )
        XCTAssertTrue(
            payload.lastSamples.values.allSatisfy { $0.sampledAt >= now.addingTimeInterval(-15 * 86_400) }
        )
    }

    func testHistorySkipsCrossWindowDelta() {
        let start = Date(timeIntervalSince1970: 1_000)
        let oldEnd = start.addingTimeInterval(604_800)
        let newEnd = oldEnd.addingTimeInterval(604_800)
        let key = "codex:primary"
        var payload = QuotaHistoryPayload(dayStart: QuotaHistoryStore.todayStart(now: start))

        // 旧窗内：已用 56% → 58%（剩余 44 → 42），正常同窗差分
        payload = QuotaHistoryStore.record(
            payload: payload,
            accountKey: key,
            app: .codex,
            kind: .codexPrimary,
            snapshot: snapshot(kind: .weekly, usedPercent: 56, reset: oldEnd),
            sampledAt: start
        )
        payload = QuotaHistoryStore.record(
            payload: payload,
            accountKey: key,
            app: .codex,
            kind: .codexPrimary,
            snapshot: snapshot(kind: .weekly, usedPercent: 58, reset: oldEnd.addingTimeInterval(1)),
            sampledAt: start.addingTimeInterval(60)
        )
        XCTAssertEqual(payload.events.count, 1)
        XCTAssertEqual(payload.events.first?.deltaPercent, -2)

        // 跨周滚动（resets_at 偏移一个窗口、剩余回到 100）：不产变动事件，仅更新基线
        payload = QuotaHistoryStore.record(
            payload: payload,
            accountKey: key,
            app: .codex,
            kind: .codexPrimary,
            snapshot: snapshot(kind: .weekly, usedPercent: 0, reset: newEnd),
            sampledAt: start.addingTimeInterval(120)
        )
        XCTAssertEqual(payload.events.count, 1, "跨窗滚动不产生变动事件")
        let series = QuotaHistoryStore.seriesKey(accountKey: key, limitKind: .weekly)
        XCTAssertEqual(payload.lastSamples[series]?.remainingPercent, 100)

        // 新窗内首次变化：before 必须取新窗基线 100，而不是旧窗的 42
        payload = QuotaHistoryStore.record(
            payload: payload,
            accountKey: key,
            app: .codex,
            kind: .codexPrimary,
            snapshot: snapshot(kind: .weekly, usedPercent: 2, reset: newEnd.addingTimeInterval(2)),
            sampledAt: start.addingTimeInterval(180)
        )
        XCTAssertEqual(payload.events.count, 2)
        XCTAssertEqual(payload.events.last?.beforeRemainingPercent, 100)
        XCTAssertEqual(payload.events.last?.deltaPercent, -2)
    }

    func testHistorySticksToTailWhenLastSampleBroken() {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = start.addingTimeInterval(604_800)
        let key = "codex:primary"
        var payload = QuotaHistoryPayload(dayStart: QuotaHistoryStore.todayStart(now: start))
        payload = QuotaHistoryStore.record(
            payload: payload,
            accountKey: key,
            app: .codex,
            kind: .codexPrimary,
            snapshot: snapshot(kind: .weekly, usedPercent: 20, reset: end),
            sampledAt: start
        )
        payload = QuotaHistoryStore.record(
            payload: payload,
            accountKey: key,
            app: .codex,
            kind: .codexPrimary,
            snapshot: snapshot(kind: .weekly, usedPercent: 21, reset: end.addingTimeInterval(1)),
            sampledAt: start.addingTimeInterval(60)
        )
        XCTAssertEqual(payload.events.count, 1)
        XCTAssertEqual(payload.events.first?.deltaPercent, -1)

        // 模拟旧值污染：lastSample 被改写成 44%，与链尾（79）脱节
        let series = QuotaHistoryStore.seriesKey(accountKey: key, limitKind: .weekly)
        var polluted = payload
        polluted.lastSamples[series]?.remainingPercent = 44

        // 采样值未变（剩余 79）：不产虚假事件，链条接回链尾
        let same = QuotaHistoryStore.record(
            payload: polluted,
            accountKey: key,
            app: .codex,
            kind: .codexPrimary,
            snapshot: snapshot(kind: .weekly, usedPercent: 21, reset: end.addingTimeInterval(1)),
            sampledAt: start.addingTimeInterval(120)
        )
        XCTAssertEqual(same.events.count, 1, "污染基线不产虚假变动事件")

        // 后续真实变化：before 应为链尾指回的 79，而不是 44
        let next = QuotaHistoryStore.record(
            payload: same,
            accountKey: key,
            app: .codex,
            kind: .codexPrimary,
            snapshot: snapshot(kind: .weekly, usedPercent: 22, reset: end.addingTimeInterval(1)),
            sampledAt: start.addingTimeInterval(180)
        )
        XCTAssertEqual(next.events.count, 2)
        XCTAssertEqual(next.events.last?.beforeRemainingPercent, 79)
        XCTAssertEqual(next.events.last?.deltaPercent, -1)
    }

    func testHistoryKeepsSameWindowJitterEvents() {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = start.addingTimeInterval(604_800)
        let key = "codex:primary"
        var payload = QuotaHistoryPayload(dayStart: QuotaHistoryStore.todayStart(now: start))
        payload = QuotaHistoryStore.record(
            payload: payload,
            accountKey: key,
            app: .codex,
            kind: .codexPrimary,
            snapshot: snapshot(kind: .weekly, usedPercent: 40, reset: end),
            sampledAt: start
        )
        XCTAssertEqual(payload.events.count, 0)

        // resets_at 秒级抖动（2 秒）：仍视为同窗，正常产事件
        payload = QuotaHistoryStore.record(
            payload: payload,
            accountKey: key,
            app: .codex,
            kind: .codexPrimary,
            snapshot: snapshot(kind: .weekly, usedPercent: 41, reset: end.addingTimeInterval(2)),
            sampledAt: start.addingTimeInterval(60)
        )
        XCTAssertEqual(payload.events.count, 1)
        XCTAssertEqual(payload.events.first?.deltaPercent, -1)
    }

    func testCleanupInconsistentChainsRemovesBrokenDeltas() {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = start.addingTimeInterval(604_800)
        let endNew = end.addingTimeInterval(604_800)

        // 断链链：before 恒为 44，与「前一事件 after」不衔接 → 除链首外全部删除
        func event(_ t: TimeInterval, before: Int, after: Int, resetsAt: Date = end) -> QuotaChangeEvent {
            QuotaChangeEvent(
                id: "\(t)",
                accountKey: "claude:primary",
                app: .claude,
                kind: .claudePrimary,
                sampledAt: start.addingTimeInterval(t),
                limitID: "weekly",
                limitKind: .weekly,
                beforeRemainingPercent: before,
                afterRemainingPercent: after,
                deltaPercent: after - before,
                resetsAt: resetsAt
            )
        }
        var payload = QuotaHistoryPayload(dayStart: start)
        payload.events = [
            event(0, before: 44, after: 80),
            event(60, before: 44, after: 79),
            event(120, before: 79, after: 78),
            event(180, before: 78, after: 77),
        ]
        let cleaned = QuotaHistoryStore.cleanupInconsistentChains(payload)
        XCTAssertEqual(cleaned.events.map(\.afterRemainingPercent), [80])

        // 跨窗差分：相邻事件 resets_at 差一个窗口 → 后者删除
        var cross = QuotaHistoryPayload(dayStart: start)
        cross.events = [
            event(0, before: 44, after: 42, resetsAt: end),
            event(60, before: 42, after: 100, resetsAt: endNew),
        ]
        let cleaned2 = QuotaHistoryStore.cleanupInconsistentChains(cross)
        XCTAssertEqual(cleaned2.events.count, 1)
        XCTAssertEqual(cleaned2.events.first?.afterRemainingPercent, 42)
    }

    func testClaudePrimaryAccountKeyNormalizesAndHashesEmail() {
        let first = QuotaHistoryAccountKey.claudePrimary(email: " User@Example.COM ")
        let same = QuotaHistoryAccountKey.claudePrimary(email: "user@example.com")
        let other = QuotaHistoryAccountKey.claudePrimary(email: "other@example.com")

        XCTAssertEqual(first, same)
        XCTAssertNotEqual(first, other)
        XCTAssertTrue(first.hasPrefix("claude:primary:"))
        XCTAssertFalse(first.contains("example.com"), "账号键不应落盘明文邮箱")
        XCTAssertEqual(QuotaHistoryAccountKey.claudePrimary(email: nil), "claude:primary")
    }

    func testQuotaHistoryMigratesLegacyClaudeKeyToCurrentAccount() {
        let start = Date(timeIntervalSince1970: 1_000)
        let accountKey = QuotaHistoryAccountKey.claudePrimary(email: "user@example.com")
        var payload = QuotaHistoryPayload(dayStart: QuotaHistoryStore.todayStart(now: start))
        for (offset, used) in [(0.0, 10.0), (60.0, 20.0)] {
            payload = QuotaHistoryStore.record(
                payload: payload,
                accountKey: "claude:primary",
                app: .claude,
                kind: .claudePrimary,
                snapshot: snapshot(kind: .fiveHour, usedPercent: used, reset: start.addingTimeInterval(18_000)),
                sampledAt: start.addingTimeInterval(offset)
            )
        }

        let migrated = QuotaHistoryStore.migratingLegacyClaudeAccountKey(payload, to: accountKey)

        let series = QuotaHistoryStore.seriesKey(accountKey: accountKey, limitKind: .fiveHour)
        XCTAssertNil(migrated.lastSamples["claude:primary"])
        XCTAssertEqual(migrated.lastSamples[series]?.accountKey, accountKey)
        XCTAssertTrue(migrated.events.allSatisfy { $0.accountKey == accountKey })
    }

    func testQuotaHistoryMigrationKeepsCodexSeriesUntouched() {
        let start = Date(timeIntervalSince1970: 1_000)
        let codexKey = "codex:primary:505d1da1-4b83-4209-bae2-8fe138250019"
        let accountKey = QuotaHistoryAccountKey.claudePrimary(email: "user@example.com")
        var payload = QuotaHistoryPayload(dayStart: QuotaHistoryStore.todayStart(now: start))
        for (offset, used) in [(0.0, 10.0), (60.0, 20.0)] {
            payload = QuotaHistoryStore.record(
                payload: payload,
                accountKey: codexKey,
                app: .codex,
                kind: .codexPrimary,
                snapshot: snapshot(kind: .fiveHour, usedPercent: used, reset: start.addingTimeInterval(18_000)),
                sampledAt: start.addingTimeInterval(offset)
            )
        }

        let migrated = QuotaHistoryStore.migratingLegacyClaudeAccountKey(payload, to: accountKey)

        let codexSeries = QuotaHistoryStore.seriesKey(accountKey: codexKey, limitKind: .fiveHour)
        XCTAssertEqual(migrated.lastSamples[codexSeries]?.accountKey, codexKey, "Codex 系列不能被 Claude 迁移改写")
        XCTAssertEqual(migrated.events.count, 1)
        XCTAssertTrue(migrated.events.allSatisfy { $0.accountKey == codexKey })
    }

    func testCycleStoreRecordsFiveHourAndWeeklyButExcludesModelWeekly() {
        let sampledAt = Date(timeIntervalSince1970: 1_000)
        let fiveHourEnd = sampledAt.addingTimeInterval(18_000)
        let weeklyEnd = sampledAt.addingTimeInterval(604_800)
        let snapshot = QuotaSnapshot(
            app: .claude,
            primaryLimit: .standard(
                kind: .fiveHour,
                window: QuotaWindow(usedPercent: 12, resetsAt: fiveHourEnd, windowSeconds: 18_000)
            ),
            secondaryLimit: .standard(
                kind: .weekly,
                window: QuotaWindow(usedPercent: 34, resetsAt: weeklyEnd, windowSeconds: 604_800)
            ),
            modelLimits: [
                .model(
                    id: "opus",
                    displayName: "Opus",
                    window: QuotaWindow(usedPercent: 50, resetsAt: weeklyEnd, windowSeconds: 604_800),
                    isActive: true
                )
            ],
            planType: nil,
            fetchedAt: sampledAt
        )

        let result = QuotaCycleStore.record(
            payload: QuotaCyclePayload(trackingStartedAt: sampledAt),
            accountKey: "claude:primary",
            app: .claude,
            snapshot: snapshot,
            source: .api,
            sampledAt: sampledAt
        )

        XCTAssertEqual(Set(result.records.map(\.limitKind)), Set([.fiveHour, .weekly]))
        XCTAssertEqual(result.records.count, 2)
    }

    func testCycleStoreRecordsInactiveWeeklyWindow() {
        // is_active 只表示「当前哪个限制在起约束作用」；非当前约束的 weekly
        // 窗口同样返回有效 percent，周期记录必须继续采样，否则页面停在旧值。
        let sampledAt = Date(timeIntervalSince1970: 1_000)
        let weeklyEnd = sampledAt.addingTimeInterval(604_800)
        let snapshot = QuotaSnapshot(
            app: .claude,
            primaryLimit: .standard(
                kind: .fiveHour,
                window: QuotaWindow(usedPercent: 12, resetsAt: sampledAt.addingTimeInterval(18_000), windowSeconds: 18_000),
                isActive: true
            ),
            secondaryLimit: .standard(
                kind: .weekly,
                window: QuotaWindow(usedPercent: 34, resetsAt: weeklyEnd, windowSeconds: 604_800),
                isActive: false
            ),
            modelLimits: [],
            planType: nil,
            fetchedAt: sampledAt
        )

        let result = QuotaCycleStore.record(
            payload: QuotaCyclePayload(trackingStartedAt: sampledAt),
            accountKey: "claude:primary",
            app: .claude,
            snapshot: snapshot,
            source: .api,
            sampledAt: sampledAt
        )

        let weeklyRecord = result.records.first { $0.limitKind == .weekly }
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(weeklyRecord?.latestUsedPercent, 34)
        XCTAssertEqual(weeklyRecord?.allowanceSegments.first?.maximumUsedPercent, 34)
    }

    func testCycleStoreDeduplicatesSnapshotsAndRollsAtNewReset() {
        let sampledAt = Date(timeIntervalSince1970: 1_000)
        let firstReset = sampledAt.addingTimeInterval(18_000)
        var payload = QuotaCyclePayload(trackingStartedAt: sampledAt)
        payload = QuotaCycleStore.record(
            payload: payload,
            accountKey: "codex:primary:test",
            app: .codex,
            snapshot: snapshot(kind: .fiveHour, usedPercent: 10, reset: firstReset),
            source: .api,
            sampledAt: sampledAt
        )
        payload = QuotaCycleStore.record(
            payload: payload,
            accountKey: "codex:primary:test",
            app: .codex,
            snapshot: snapshot(kind: .fiveHour, usedPercent: 25, reset: firstReset),
            source: .api,
            sampledAt: sampledAt.addingTimeInterval(60)
        )
        XCTAssertEqual(payload.records.count, 1)
        XCTAssertEqual(payload.records.first?.latestUsedPercent, 25)
        XCTAssertEqual(payload.records.first?.latestAllowanceSegment?.maximumUsedPercent, 25)

        payload = QuotaCycleStore.record(
            payload: payload,
            accountKey: "codex:primary:test",
            app: .codex,
            snapshot: snapshot(
                kind: .fiveHour,
                usedPercent: 1,
                reset: firstReset.addingTimeInterval(18_000)
            ),
            source: .api,
            sampledAt: firstReset.addingTimeInterval(60)
        )
        XCTAssertEqual(payload.records.count, 2)
    }

    func testCycleStoreCreatesNewAllowanceWhenUsageResetsWithoutChangingResetTime() throws {
        let sampledAt = Date(timeIntervalSince1970: 1_000)
        let resetAt = sampledAt.addingTimeInterval(18_000)
        var payload = QuotaCycleStore.record(
            payload: QuotaCyclePayload(trackingStartedAt: sampledAt),
            accountKey: "claude:primary",
            app: .claude,
            snapshot: snapshot(kind: .fiveHour, usedPercent: 80, reset: resetAt),
            source: .api,
            sampledAt: sampledAt
        )
        let benefitResetAt = sampledAt.addingTimeInterval(60)
        payload = QuotaCycleStore.record(
            payload: payload,
            accountKey: "claude:primary",
            app: .claude,
            snapshot: snapshot(kind: .fiveHour, usedPercent: 0, reset: resetAt),
            source: .api,
            sampledAt: benefitResetAt
        )

        let cycle = try XCTUnwrap(payload.records.first)
        XCTAssertEqual(payload.records.count, 1)
        XCTAssertEqual(cycle.latestUsedPercent, 0)
        XCTAssertEqual(cycle.extraResetCount, 1)
        XCTAssertEqual(cycle.allowanceSegments.count, 2)
        XCTAssertEqual(cycle.allowanceSegments[0].endAt, benefitResetAt)
        XCTAssertEqual(cycle.allowanceSegments[1].startReason, .extraReset)
        XCTAssertEqual(cycle.allowanceSegments[1].baselineUsedPercent, 0)
    }

    func testCycleStoreDoesNotTreatSmallPercentageCorrectionAsExtraReset() throws {
        let sampledAt = Date(timeIntervalSince1970: 1_000)
        let resetAt = sampledAt.addingTimeInterval(18_000)
        var payload = QuotaCycleStore.record(
            payload: QuotaCyclePayload(trackingStartedAt: sampledAt),
            accountKey: "claude:primary",
            app: .claude,
            snapshot: snapshot(kind: .fiveHour, usedPercent: 25, reset: resetAt),
            source: .api,
            sampledAt: sampledAt
        )
        payload = QuotaCycleStore.record(
            payload: payload,
            accountKey: "claude:primary",
            app: .claude,
            snapshot: snapshot(kind: .fiveHour, usedPercent: 24, reset: resetAt),
            source: .api,
            sampledAt: sampledAt.addingTimeInterval(60)
        )

        let cycle = try XCTUnwrap(payload.records.first)
        XCTAssertEqual(cycle.extraResetCount, 0)
        XCTAssertEqual(cycle.latestUsedPercent, 24)
        XCTAssertEqual(cycle.latestAllowanceSegment?.maximumUsedPercent, 25)
    }

    func testCycleStoreClosesOverlappingCycleWhenOfficialResetTimeChanges() throws {
        let firstStart = Date(timeIntervalSince1970: 100_000)
        let firstReset = firstStart.addingTimeInterval(604_800)
        var payload = QuotaCycleStore.record(
            payload: QuotaCyclePayload(trackingStartedAt: firstStart),
            accountKey: "codex:primary:test",
            app: .codex,
            snapshot: snapshot(kind: .weekly, usedPercent: 40, reset: firstReset),
            source: .api,
            sampledAt: firstStart
        )
        let newStart = firstStart.addingTimeInterval(3_600)
        payload = QuotaCycleStore.record(
            payload: payload,
            accountKey: "codex:primary:test",
            app: .codex,
            snapshot: snapshot(
                kind: .weekly,
                usedPercent: 0,
                reset: newStart.addingTimeInterval(604_800)
            ),
            source: .api,
            sampledAt: newStart
        )

        XCTAssertEqual(payload.records.count, 2)
        let oldCycle = try XCTUnwrap(payload.records.first { $0.scheduledEndAt == firstReset })
        XCTAssertEqual(oldCycle.endAt, newStart)
        XCTAssertEqual(oldCycle.allowanceSegments.last?.endAt, newStart)
    }

    func testCycleStoreMergesSameCycleWhenResetAtJitters() {
        let sampledAt = Date(timeIntervalSince1970: 1_000)
        let firstReset = sampledAt.addingTimeInterval(604_800)
        var payload = QuotaCyclePayload(trackingStartedAt: sampledAt)
        // Codex 服务端 reset_at 秒级抖动：每次返回相差 1~3 秒。
        let jitters: [(TimeInterval, Double)] = [(3, 10), (1, 25), (2, 40)]
        for (index, jitter) in jitters.enumerated() {
            payload = QuotaCycleStore.record(
                payload: payload,
                accountKey: "codex:primary:test",
                app: .codex,
                snapshot: snapshot(
                    kind: .weekly,
                    usedPercent: jitter.1,
                    reset: firstReset.addingTimeInterval(jitter.0)
                ),
                source: .api,
                sampledAt: sampledAt.addingTimeInterval(TimeInterval(index) * 60)
            )
        }

        XCTAssertEqual(payload.records.count, 1, "reset_at 抖动不应产生重复周期记录")
        XCTAssertEqual(payload.records.first?.latestUsedPercent, 40)
    }

    func testCycleStoreKeepsActiveCycleWhenResetAtDriftsWithoutUsageReset() throws {
        let sampledAt = Date(timeIntervalSince1970: 100_000)
        let firstReset = sampledAt.addingTimeInterval(604_800)
        var payload = QuotaCyclePayload(trackingStartedAt: sampledAt)
        let samples: [(minutes: TimeInterval, usedPercent: Double)] = [
            (0, 0),
            (17, 0),
            (19, 0),
            (21, 20),
        ]

        for sample in samples {
            payload = QuotaCycleStore.record(
                payload: payload,
                accountKey: "codex:primary:test",
                app: .codex,
                snapshot: snapshot(
                    kind: .weekly,
                    usedPercent: sample.usedPercent,
                    reset: firstReset.addingTimeInterval(sample.minutes * 60)
                ),
                source: .api,
                sampledAt: sampledAt.addingTimeInterval(sample.minutes * 60)
            )
        }

        let cycle = try XCTUnwrap(payload.records.first)
        XCTAssertEqual(payload.records.count, 1, "额度未回落时 reset_at 分钟级漂移仍属于同一周期")
        XCTAssertEqual(cycle.startAt, sampledAt)
        XCTAssertEqual(cycle.endAt, firstReset.addingTimeInterval(21 * 60))
        XCTAssertEqual(cycle.latestUsedPercent, 20)
        XCTAssertEqual(cycle.allowanceSegments.count, 1)
    }

    func testCycleStoreDoesNotMergeLowUsageEarlyWeeklyReset() throws {
        let sampledAt = Date(timeIntervalSince1970: 100_000)
        let week: TimeInterval = 604_800
        let firstReset = sampledAt.addingTimeInterval(week)
        var payload = QuotaCycleStore.record(
            payload: QuotaCyclePayload(trackingStartedAt: sampledAt),
            accountKey: "codex:primary:test",
            app: .codex,
            snapshot: snapshot(kind: .weekly, usedPercent: 4, reset: firstReset),
            source: .api,
            sampledAt: sampledAt
        )
        let earlyResetAt = sampledAt.addingTimeInterval(2 * 86_400)
        payload = QuotaCycleStore.record(
            payload: payload,
            accountKey: "codex:primary:test",
            app: .codex,
            snapshot: snapshot(
                kind: .weekly,
                usedPercent: 2,
                reset: earlyResetAt.addingTimeInterval(week)
            ),
            source: .api,
            sampledAt: earlyResetAt
        )

        XCTAssertEqual(payload.records.count, 2, "低用量提前重置不能被第三重活跃匹配串成一期")
        let old = try XCTUnwrap(payload.records.first { $0.scheduledEndAt == firstReset })
        XCTAssertEqual(old.endAt, earlyResetAt)
    }

    func testCycleStoreKeepsScheduledEndAtUnderSubsecondJitter() throws {
        let sampledAt = Date(timeIntervalSince1970: 1_000)
        let firstReset = sampledAt.addingTimeInterval(18_000)
        var payload = QuotaCycleStore.record(
            payload: QuotaCyclePayload(trackingStartedAt: sampledAt),
            accountKey: "claude:primary",
            app: .claude,
            snapshot: snapshot(kind: .fiveHour, usedPercent: 10, reset: firstReset),
            source: .api,
            sampledAt: sampledAt
        )
        // Claude 服务端 resets_at 亚秒级抖动：容差内应保留既有边界，
        // 否则 cycleUsagePartition 会把漂移误判为周期滚动并触发全量重建。
        let jitters: [(TimeInterval, Double)] = [(0.1, 15), (0.9, 20)]
        for (index, jitter) in jitters.enumerated() {
            payload = QuotaCycleStore.record(
                payload: payload,
                accountKey: "claude:primary",
                app: .claude,
                snapshot: snapshot(
                    kind: .fiveHour,
                    usedPercent: jitter.1,
                    reset: firstReset.addingTimeInterval(jitter.0)
                ),
                source: .api,
                sampledAt: sampledAt.addingTimeInterval(TimeInterval(index + 1) * 60)
            )
        }

        let cycle = try XCTUnwrap(payload.records.first)
        XCTAssertEqual(payload.records.count, 1, "亚秒抖动不应产生重复周期记录")
        XCTAssertEqual(cycle.scheduledEndAt, firstReset, "亚秒抖动不应改写 scheduledEndAt")
        XCTAssertEqual(cycle.endAt, firstReset, "亚秒抖动不应滚动 endAt")
        XCTAssertEqual(cycle.latestUsedPercent, 20)
    }

    func testCycleStoreRollsScheduledEndAtWhenDriftReachesTolerance() throws {
        let sampledAt = Date(timeIntervalSince1970: 1_000)
        let firstReset = sampledAt.addingTimeInterval(18_000)
        var payload = QuotaCycleStore.record(
            payload: QuotaCyclePayload(trackingStartedAt: sampledAt),
            accountKey: "claude:primary",
            app: .claude,
            snapshot: snapshot(kind: .fiveHour, usedPercent: 10, reset: firstReset),
            source: .api,
            sampledAt: sampledAt
        )
        // 5s 为容差边界（≥5s 即写入新边界），随后再从 5s 处漂移 6s 应继续更新。
        for (index, drift) in [5, 11].enumerated() {
            let newReset = firstReset.addingTimeInterval(TimeInterval(drift))
            payload = QuotaCycleStore.record(
                payload: payload,
                accountKey: "claude:primary",
                app: .claude,
                snapshot: snapshot(
                    kind: .fiveHour,
                    usedPercent: 10 + Double(index) * 5,
                    reset: newReset
                ),
                source: .api,
                sampledAt: sampledAt.addingTimeInterval(TimeInterval(index + 2) * 60)
            )
        }

        let cycle = try XCTUnwrap(payload.records.first)
        XCTAssertEqual(payload.records.count, 1, "真实滚动仍应复用同一条周期记录")
        XCTAssertEqual(cycle.scheduledEndAt, firstReset.addingTimeInterval(11))
        XCTAssertEqual(cycle.endAt, firstReset.addingTimeInterval(11))
        XCTAssertEqual(cycle.latestUsedPercent, 15)
    }

    func testCycleStoreReusesFinishedCycleWhenServerReportsLateDriftedWindow() throws {
        let sampledAt = Date(timeIntervalSince1970: 100_000)
        let firstReset = sampledAt.addingTimeInterval(604_800)
        var payload = QuotaCycleStore.record(
            payload: QuotaCyclePayload(trackingStartedAt: sampledAt),
            accountKey: "claude:primary",
            app: .claude,
            snapshot: snapshot(kind: .weekly, usedPercent: 10, reset: firstReset),
            source: .api,
            sampledAt: sampledAt
        )
        // 采样时刻已过周期结束、服务端仍返回漂移的旧窗口 resets_at（差 <60s）、用量未回落：
        // 应视为同一周期的漂移视图更新原记录，而不是新建周期把旧记录误砍成残片。
        payload = QuotaCycleStore.record(
            payload: payload,
            accountKey: "claude:primary",
            app: .claude,
            snapshot: snapshot(kind: .weekly, usedPercent: 30, reset: firstReset.addingTimeInterval(0.5)),
            source: .api,
            sampledAt: firstReset.addingTimeInterval(120)
        )

        let cycle = try XCTUnwrap(payload.records.first)
        XCTAssertEqual(payload.records.count, 1, "晚到的旧窗口采样不应新建周期记录")
        XCTAssertEqual(cycle.endAt, firstReset, "不应滚动或收口已结束周期的边界")
        XCTAssertEqual(cycle.latestUsedPercent, 30)
        XCTAssertEqual(cycle.allowanceSegments.count, 1)
        XCTAssertEqual(cycle.allowanceSegments.first?.maximumUsedPercent, 30)
        XCTAssertNil(cycle.allowanceSegments.first?.endAt, "segment 不应被收口")
    }

    func testCloseOverlappingCyclesSkipsNearIdenticalStartRecord() throws {
        let start = Date(timeIntervalSince1970: 100_000)
        let week: TimeInterval = 604_800
        let oldStart = start.addingTimeInterval(0.3)
        var existing = cycleRecord(id: "drift-a", accountKey: "claude:primary", app: .claude,
                                   start: oldStart, end: oldStart.addingTimeInterval(week))
        var payload = QuotaCyclePayload(trackingStartedAt: start)
        payload.records = [existing]

        // 新采样 resets_at 与旧记录 endAt 差 0.5s（漂移），但用量明显回落，看起来像真重置：
        // record() 走新建分支，closeOverlappingCycles 不应把起点仅差毫秒级的旧记录误砍成残片。
        let driftedEnd = oldStart.addingTimeInterval(week).addingTimeInterval(0.5)
        payload = QuotaCycleStore.record(
            payload: payload,
            accountKey: "claude:primary",
            app: .claude,
            snapshot: snapshot(kind: .weekly, usedPercent: 2, reset: driftedEnd),
            source: .api,
            sampledAt: oldStart.addingTimeInterval(week + 120)
        )

        let kept = try XCTUnwrap(payload.records.first { $0.id == "drift-a" })
        XCTAssertEqual(kept.endAt, oldStart.addingTimeInterval(week), "起点漂移的旧记录不应被收口成残片")
        XCTAssertNil(kept.allowanceSegments.first?.endAt, "旧记录 segment 不应被收口")
        XCTAssertEqual(payload.records.count, 2, "回落采样应新建周期，但旧记录保持完整")
    }

    func testCloseOverlappingCyclesKeepsAdjacentCyclesWithSecondLevelOverlap() throws {
        let start = Date(timeIntervalSince1970: 100_000)
        let week: TimeInterval = 604_800
        let boundary = start.addingTimeInterval(week)
        let existing = cycleRecord(
            id: "earlier",
            accountKey: "claude:primary",
            app: .claude,
            start: start,
            end: boundary,
            usedPercent: 40
        )
        var payload = QuotaCyclePayload(trackingStartedAt: start)
        payload.records = [existing]

        // 新周期起点因独立 resets_at 抖动比旧周期终点早 1 秒。
        // 用量明显回落会走新建分支，但不应截短前一真实周期。
        let newStart = boundary.addingTimeInterval(-1)
        payload = QuotaCycleStore.record(
            payload: payload,
            accountKey: "claude:primary",
            app: .claude,
            snapshot: snapshot(
                kind: .weekly,
                usedPercent: 0,
                reset: newStart.addingTimeInterval(week)
            ),
            source: .api,
            sampledAt: newStart
        )

        let kept = try XCTUnwrap(payload.records.first { $0.id == "earlier" })
        XCTAssertEqual(payload.records.count, 2)
        XCTAssertEqual(kept.endAt, boundary, "秒级边界重叠不应截短旧周期")
        XCTAssertNil(kept.allowanceSegments.first?.endAt)
    }

    func testCleaningUpLegacyPayloadDropsShardsAndMergesOverlaps() throws {
        let start = Date(timeIntervalSince1970: 100_000)
        let week: TimeInterval = 604_800
        var payload = QuotaCyclePayload(version: 3, trackingStartedAt: start)
        payload.records = [
            cycleRecord(id: "dup-b", accountKey: "codex:primary:a", app: .codex,
                        start: start.addingTimeInterval(3), end: start.addingTimeInterval(3 + week)),
            cycleRecord(id: "dup-a", accountKey: "codex:primary:a", app: .codex,
                        start: start, end: start.addingTimeInterval(week)),
            cycleRecord(id: "shard-1", accountKey: "codex:primary:a", app: .codex,
                        start: start.addingTimeInterval(1), end: start.addingTimeInterval(2)),
            cycleRecord(id: "shard-2", accountKey: "codex:primary:a", app: .codex,
                        start: start.addingTimeInterval(week + 1), end: start.addingTimeInterval(week + 2)),
        ]

        let cleaned = QuotaCycleStore.cleaningUpLegacyPayload(payload)

        XCTAssertEqual(cleaned.records.count, 1, "残片应被删除、重叠完整周期应合并为一条")
        let kept = try XCTUnwrap(cleaned.records.first)
        XCTAssertEqual(kept.endAt, start.addingTimeInterval(3 + week), "应保留 endAt 最晚的周期")
        XCTAssertEqual(kept.firstSampleAt, start)
        XCTAssertEqual(kept.lastSampleAt, start.addingTimeInterval(3 + week))
        XCTAssertEqual(kept.reportedUsedPercent, 25, "重复 initial 段不能把额度百分比累加")
    }

    func testCleaningUpPayloadKeepsAdjacentCyclesWithSubsecondBoundaryOverlap() throws {
        let start = Date(timeIntervalSince1970: 100_000)
        let week: TimeInterval = 604_800
        // 相邻的两个真实周期，边界分别由各自采样时刻的 resets_at 推出，两侧抖动叠加
        // 会让后一周期的起点比前一周期的终点略早。这种亚秒毛刺不是重复记录：若按
        // 重叠去重，merging 只保留 base 的 startAt / endAt，较早那整段周期历史会被
        // 永久吞掉且无法从日志重建。
        var payload = QuotaCyclePayload(version: 3, trackingStartedAt: start)
        payload.records = [
            cycleRecord(id: "earlier", accountKey: "claude:primary", app: .claude,
                        start: start, end: start.addingTimeInterval(week + 0.67)),
            cycleRecord(id: "later", accountKey: "claude:primary", app: .claude,
                        start: start.addingTimeInterval(week + 0.51),
                        end: start.addingTimeInterval(2 * week)),
        ]

        let cleaned = QuotaCycleStore.cleaningUpLegacyPayload(payload)

        XCTAssertEqual(cleaned.records.count, 2, "亚秒级边界重叠只是抖动毛刺，两个周期都应保留")
        let earlier = try XCTUnwrap(cleaned.records.first { $0.id == "earlier" })
        XCTAssertEqual(earlier.startAt, start, "较早周期的时间段不应被吞掉")
        XCTAssertEqual(earlier.endAt, start.addingTimeInterval(week + 0.67))
    }

    func testCleaningUpPayloadDoesNotMergeAdjacentCyclesAfterOneSecondTruncation() throws {
        let start = Date(timeIntervalSince1970: 100_000)
        let week: TimeInterval = 604_800
        let scheduledBoundary = start.addingTimeInterval(week)
        let jitteredBoundary = scheduledBoundary.addingTimeInterval(-1)
        var earlier = cycleRecord(
            id: "earlier",
            accountKey: "claude:primary",
            app: .claude,
            start: start,
            end: jitteredBoundary,
            usedPercent: 30
        )
        earlier.scheduledEndAt = scheduledBoundary
        let later = cycleRecord(
            id: "later",
            accountKey: "claude:primary",
            app: .claude,
            start: jitteredBoundary,
            end: jitteredBoundary.addingTimeInterval(week),
            usedPercent: 35
        )

        let cleaned = QuotaCycleStore.cleaningUpLegacyPayload(QuotaCyclePayload(
            version: 4,
            trackingStartedAt: start,
            records: [earlier, later]
        ))

        XCTAssertEqual(cleaned.records.count, 2, "1 秒边界截断不是 reset 漂移残片")
        XCTAssertNotNil(cleaned.records.first { $0.id == "earlier" })
        XCTAssertNotNil(cleaned.records.first { $0.id == "later" })
    }

    func testCleaningUpPayloadCoalescesResetDriftButKeepsRealUsageReset() throws {
        let start = Date(timeIntervalSince1970: 100_000)
        let trueReset = start.addingTimeInterval(2 * 24 * 60 * 60)
        let minute: TimeInterval = 60

        var beforeReset = cycleRecord(
            id: "before-reset",
            accountKey: "codex:primary:a",
            app: .codex,
            start: start,
            end: trueReset,
            usedPercent: 100
        )
        beforeReset.scheduledEndAt = start.addingTimeInterval(604_800)

        var fragmentA = cycleRecord(
            id: "fragment-a",
            accountKey: "codex:primary:a",
            app: .codex,
            start: trueReset,
            end: trueReset.addingTimeInterval(17 * minute),
            usedPercent: 0
        )
        fragmentA.scheduledEndAt = trueReset.addingTimeInterval(604_800)

        var fragmentB = cycleRecord(
            id: "fragment-b",
            accountKey: "codex:primary:a",
            app: .codex,
            start: fragmentA.endAt,
            end: fragmentA.endAt.addingTimeInterval(2 * minute),
            usedPercent: 0
        )
        fragmentB.scheduledEndAt = fragmentB.startAt.addingTimeInterval(604_800)

        let current = cycleRecord(
            id: "current",
            accountKey: "codex:primary:a",
            app: .codex,
            start: fragmentB.endAt.addingTimeInterval(1),
            end: fragmentB.endAt.addingTimeInterval(604_801),
            usedPercent: 20
        )

        let cleaned = QuotaCycleStore.cleaningUpLegacyPayload(QuotaCyclePayload(
            version: 4,
            trackingStartedAt: start,
            records: [current, fragmentB, fragmentA, beforeReset]
        ))

        XCTAssertEqual(cleaned.records.count, 2)
        XCTAssertNotNil(cleaned.records.first { $0.id == "before-reset" }, "100% → 0% 是真实重置")
        let merged = try XCTUnwrap(cleaned.records.first { $0.id == "current" })
        XCTAssertEqual(merged.startAt, trueReset, "相邻片段相差 1 秒仍应合并")
        XCTAssertEqual(merged.latestUsedPercent, 20)
        XCTAssertEqual(merged.reportedUsedPercent, 20)
        XCTAssertEqual(merged.allowanceSegments.count, 1)
    }

    func testCycleStoreKeepsSeparateCyclesWhenWindowScheduleShifts() {
        // 服务端制式换档（如周四 11:34 → 周一 09:01）：新旧窗口的恢复时刻差数天。
        // 旧周期残片与新建周期不得归并，否则聚合被伪长周期污染。
        let start = Date(timeIntervalSince1970: 100_000)
        let week: TimeInterval = 604_800
        var earlier = cycleRecord(
            id: "legacy-truncated",
            accountKey: "codex:primary:a",
            app: .codex,
            start: start.addingTimeInterval(-4 * 86_400),
            end: start,
            usedPercent: 38
        )
        earlier.scheduledEndAt = start.addingTimeInterval(3 * 86_400)
        let later = cycleRecord(
            id: "shifted-window",
            accountKey: "codex:primary:a",
            app: .codex,
            start: start,
            end: start.addingTimeInterval(week),
            usedPercent: 40
        )

        let cleaned = QuotaCycleStore.cleaningUpLegacyPayload(QuotaCyclePayload(
            version: 4,
            trackingStartedAt: start,
            records: [earlier, later]
        ))

        XCTAssertEqual(cleaned.records.count, 2, "恢复时刻差数天的换档片段不得合并")
        XCTAssertNotNil(cleaned.records.first { $0.id == "legacy-truncated" })
        XCTAssertNotNil(cleaned.records.first { $0.id == "shifted-window" })
    }

    func testCycleStoreRepairsOversizedCycleWindowStart() {
        let start = Date(timeIntervalSince1970: 100_000)
        let week: TimeInterval = 604_800
        var oversized = cycleRecord(
            id: "oversized",
            accountKey: "codex:primary:a",
            app: .codex,
            start: start,
            end: start.addingTimeInterval(week + 4 * 86_400),
            usedPercent: 56
        )
        oversized.scheduledEndAt = start.addingTimeInterval(week + 4 * 86_400)

        let (repaired, ids) = QuotaCycleStore.repairingOversizedCycles(QuotaCyclePayload(
            version: 4,
            trackingStartedAt: start,
            records: [oversized]
        ))
        XCTAssertEqual(ids, ["oversized"])
        XCTAssertEqual(
            repaired.records.first?.startAt,
            start.addingTimeInterval(4 * 86_400),
            "超长记录起点 = 恢复时刻 − 窗口长度"
        )

        let (again, secondIDs) = QuotaCycleStore.repairingOversizedCycles(repaired)
        XCTAssertTrue(secondIDs.isEmpty, "修复后应幂等")
    }

    func testCycleStoreCreatesAccountSegmentsWithoutBackdatingSwitchedAccount() {
        let firstSample = Date(timeIntervalSince1970: 100_000)
        var payload = QuotaCycleStore.record(
            payload: QuotaCyclePayload(trackingStartedAt: firstSample),
            accountKey: "codex:primary:a",
            app: .codex,
            snapshot: snapshot(
                kind: .weekly,
                usedPercent: 20,
                reset: firstSample.addingTimeInterval(604_800)
            ),
            source: .api,
            sampledAt: firstSample
        )
        let switchedAt = firstSample.addingTimeInterval(3_600)
        payload = QuotaCycleStore.record(
            payload: payload,
            accountKey: "codex:primary:b",
            app: .codex,
            snapshot: snapshot(
                kind: .weekly,
                usedPercent: 5,
                reset: firstSample.addingTimeInterval(604_800)
            ),
            source: .api,
            sampledAt: switchedAt
        )

        XCTAssertEqual(payload.accountSegments.count, 2)
        XCTAssertEqual(payload.accountSegments[0].startAt, firstSample)
        XCTAssertEqual(payload.accountSegments[0].endAt, switchedAt)
        XCTAssertEqual(payload.accountSegments[1].startAt, switchedAt)
        XCTAssertNil(payload.accountSegments[1].endAt)
    }

    func testCycleStoreMigratesLegacyClaudeKeyWithoutChangingCycleID() throws {
        let sampledAt = Date(timeIntervalSince1970: 100_000)
        let accountKey = QuotaHistoryAccountKey.claudePrimary(email: "user@example.com")
        let payload = QuotaCycleStore.record(
            payload: QuotaCyclePayload(trackingStartedAt: sampledAt),
            accountKey: "claude:primary",
            app: .claude,
            snapshot: snapshot(
                kind: .fiveHour,
                usedPercent: 20,
                reset: sampledAt.addingTimeInterval(18_000)
            ),
            source: .api,
            sampledAt: sampledAt
        )
        let legacyID = try XCTUnwrap(payload.records.first?.id)

        let migrated = QuotaCycleStore.migratingLegacyClaudeAccountKey(payload, to: accountKey)

        XCTAssertEqual(migrated.records.first?.id, legacyID, "保留 cycleID 才能继续命中已有 rollup")
        XCTAssertEqual(migrated.records.first?.accountKey, accountKey)
        XCTAssertEqual(migrated.accountSegments.first?.accountKey, accountKey)
    }

    func testCycleStoreRequiresResetAndMarksMissingWindowLengthAsInferred() {
        let sampledAt = Date(timeIntervalSince1970: 100_000)
        let missingReset = QuotaSnapshot(
            app: .codex,
            primaryLimit: .standard(
                kind: .weekly,
                window: QuotaWindow(usedPercent: 10, resetsAt: nil, windowSeconds: 604_800)
            ),
            secondaryLimit: nil,
            planType: nil,
            fetchedAt: sampledAt
        )
        var payload = QuotaCycleStore.record(
            payload: QuotaCyclePayload(trackingStartedAt: sampledAt),
            accountKey: "codex:primary:a",
            app: .codex,
            snapshot: missingReset,
            source: .api,
            sampledAt: sampledAt
        )
        XCTAssertTrue(payload.records.isEmpty)

        let missingLength = QuotaSnapshot(
            app: .codex,
            primaryLimit: .standard(
                kind: .weekly,
                window: QuotaWindow(
                    usedPercent: 10,
                    resetsAt: sampledAt.addingTimeInterval(604_800),
                    windowSeconds: nil
                )
            ),
            secondaryLimit: nil,
            planType: nil,
            fetchedAt: sampledAt
        )
        payload = QuotaCycleStore.record(
            payload: payload,
            accountKey: "codex:primary:a",
            app: .codex,
            snapshot: missingLength,
            source: .api,
            sampledAt: sampledAt
        )
        XCTAssertEqual(payload.records.first?.boundaryQuality, .inferred)
    }

    func testQuotaCycleV2RecordMigratesIntoInitialAllowanceSegment() throws {
        let data = Data(#"""
        {
          "id": "legacy",
          "accountKey": "codex:primary:test",
          "app": "codex",
          "limitID": "weekly",
          "limitKind": "weekly",
          "startAt": 0,
          "endAt": 604800,
          "firstSampleAt": 0,
          "lastSampleAt": 60,
          "maximumUsedPercent": 37,
          "source": "api",
          "boundaryQuality": "observed"
        }
        """#.utf8)

        let cycle = try JSONDecoder().decode(QuotaCycleRecord.self, from: data)
        XCTAssertEqual(cycle.scheduledEndAt, cycle.endAt)
        XCTAssertEqual(cycle.latestUsedPercent, 37)
        XCTAssertEqual(cycle.allowanceSegments.count, 1)
        XCTAssertEqual(cycle.latestAllowanceSegment?.maximumUsedPercent, 37)
    }

    @MainActor
    func testCycleUsageUsesHalfOpenBoundariesAndDoesNotCrossAccounts() {
        let start = Date(timeIntervalSince1970: 10_000)
        let first = cycleRecord(
            id: "first",
            accountKey: "codex:primary:a",
            app: .codex,
            start: start,
            end: start.addingTimeInterval(100)
        )
        let second = cycleRecord(
            id: "second",
            accountKey: "codex:primary:a",
            app: .codex,
            start: first.endAt,
            end: first.endAt.addingTimeInterval(100)
        )
        let otherAccount = cycleRecord(
            id: "other",
            accountKey: "codex:primary:b",
            app: .codex,
            start: start,
            end: second.endAt
        )
        let entry = UsageEntry(
            app: .codex,
            conversationKey: "codex:test",
            model: "gpt-5.6",
            speed: .standard,
            day: UsageDay.startOfDay(for: first.endAt),
            timestamp: first.endAt,
            inputTokens: 100,
            outputTokens: 20,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            costUSD: 1,
            costBreakdown: nil
        )
        let aggregator = CycleUsageAggregator()
        aggregator.ingest(
            entries: [entry],
            cycles: [first, second, otherAccount],
            accountSegments: [QuotaCycleAccountSegment(
                id: "a",
                accountKey: "codex:primary:a",
                app: .codex,
                startAt: start,
                endAt: nil
            )]
        )

        XCTAssertEqual(aggregator.snapshot().count, 1)
        XCTAssertEqual(aggregator.snapshot().first?.cycleID, "second")
    }

    @MainActor
    func testCycleUsageRebuildKeepsEntriesInTheirAccountSegments() {
        let start = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 200_000))
        let switchedAt = start.addingTimeInterval(3_600)
        let end = start.addingTimeInterval(7_200)
        let oldCycle = cycleRecord(
            id: "old-account",
            accountKey: "codex:primary:a",
            app: .codex,
            start: start,
            end: end
        )
        let newCycle = cycleRecord(
            id: "new-account",
            accountKey: "codex:primary:b",
            app: .codex,
            start: start,
            end: end
        )
        func entry(at timestamp: Date) -> UsageEntry {
            UsageEntry(
                app: .codex,
                conversationKey: "codex:test",
                model: "gpt-5.6",
                speed: .standard,
                day: start,
                timestamp: timestamp,
                inputTokens: 10,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                costUSD: 1,
                costBreakdown: nil
            )
        }
        let aggregator = CycleUsageAggregator()
        aggregator.ingest(
            entries: [entry(at: start.addingTimeInterval(60)), entry(at: switchedAt.addingTimeInterval(60))],
            cycles: [oldCycle, newCycle],
            accountSegments: [
                QuotaCycleAccountSegment(
                    id: "a",
                    accountKey: oldCycle.accountKey,
                    app: .codex,
                    startAt: start,
                    endAt: switchedAt
                ),
                QuotaCycleAccountSegment(
                    id: "b",
                    accountKey: newCycle.accountKey,
                    app: .codex,
                    startAt: switchedAt,
                    endAt: nil
                ),
            ]
        )

        XCTAssertEqual(Set(aggregator.snapshot().map(\.cycleID)), Set(["old-account", "new-account"]))
        XCTAssertEqual(aggregator.snapshot().reduce(0) { $0 + $1.inputTokens }, 20)
    }

    func testCycleForecastStartsWithAnyObservedUsage() {
        let cycle = cycleRecord(
            id: "forecast",
            accountKey: "claude:primary",
            app: .claude,
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000),
            usedPercent: 20
        )
        var totals = UsageTotals.zero
        totals.inputTokens = 1_000
        totals.costUSD = 40
        let summary = CycleUsageSummary(
            cycle: cycle,
            totals: totals,
            currentAllowanceTotals: totals,
            quality: .exact
        )
        XCTAssertEqual(summary.projectedFullCycleTokens, 5_000)
        XCTAssertEqual(summary.projectedFullCycleCostUSD, 200)
        XCTAssertEqual(summary.forecastConfidence, .rough)

        var lowUsage = cycle
        lowUsage.latestUsedPercent = 9.9
        lowUsage.allowanceSegments[0].latestUsedPercent = 9.9
        lowUsage.allowanceSegments[0].maximumUsedPercent = 9.9
        let lowSummary = CycleUsageSummary(
            cycle: lowUsage,
            totals: totals,
            currentAllowanceTotals: totals,
            quality: .exact
        )
        XCTAssertEqual(lowSummary.projectedFullCycleTokens, 10_101)
        if let projectedCost = lowSummary.projectedFullCycleCostUSD {
            XCTAssertEqual(
                NSDecimalNumber(decimal: projectedCost).doubleValue,
                404.04,
                accuracy: 0.01
            )
        } else {
            XCTFail("Low-observation cost should still be forecast")
        }
        XCTAssertEqual(lowSummary.forecastConfidence, .early)
    }

    func testCycleForecastUsesObservedDeltaAfterNonzeroBaseline() {
        var cycle = cycleRecord(
            id: "baseline",
            accountKey: "claude:primary",
            app: .claude,
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000),
            usedPercent: 40
        )
        cycle.allowanceSegments[0].baselineUsedPercent = 20
        var totals = UsageTotals.zero
        totals.inputTokens = 1_000
        totals.costUSD = 20
        let summary = CycleUsageSummary(
            cycle: cycle,
            totals: totals,
            currentAllowanceTotals: totals,
            quality: .exact
        )

        XCTAssertEqual(summary.forecastObservedPercent, 20)
        XCTAssertEqual(summary.projectedFullCycleTokens, 5_000)
        XCTAssertEqual(summary.projectedFullCycleCostUSD, 100)

        let incompleteSummary = CycleUsageSummary(
            cycle: cycle,
            totals: totals,
            currentAllowanceTotals: totals,
            quality: .incomplete
        )
        XCTAssertEqual(incompleteSummary.projectedFullCycleTokens, 5_000)
        XCTAssertEqual(incompleteSummary.projectedFullCycleCostUSD, 100)
        XCTAssertEqual(incompleteSummary.forecastConfidence, .rough)
    }

    func testCycleForecastRequiresObservedUsageAndAValueBasis() {
        var cycle = cycleRecord(
            id: "forecast-basis",
            accountKey: "claude:primary",
            app: .claude,
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000),
            usedPercent: 0
        )
        var totals = UsageTotals.zero
        totals.inputTokens = 1_000
        totals.costUSD = 20

        let noObservedUsage = CycleUsageSummary(
            cycle: cycle,
            totals: totals,
            currentAllowanceTotals: totals,
            quality: .exact
        )
        XCTAssertNil(noObservedUsage.projectedFullCycleTokens)
        XCTAssertNil(noObservedUsage.projectedFullCycleCostUSD)
        XCTAssertNil(noObservedUsage.forecastConfidence)

        cycle.latestUsedPercent = 20
        cycle.allowanceSegments[0].latestUsedPercent = 20
        cycle.allowanceSegments[0].maximumUsedPercent = 20

        var tokensOnly = totals
        tokensOnly.costUSD = 0
        let noCostBasis = CycleUsageSummary(
            cycle: cycle,
            totals: tokensOnly,
            currentAllowanceTotals: tokensOnly,
            quality: .exact
        )
        XCTAssertEqual(noCostBasis.projectedFullCycleTokens, 5_000)
        XCTAssertNil(noCostBasis.projectedFullCycleCostUSD)

        let noTokenBasis = CycleUsageSummary(
            cycle: cycle,
            totals: .zero,
            currentAllowanceTotals: .zero,
            quality: .exact
        )
        XCTAssertNil(noTokenBasis.projectedFullCycleTokens)
        XCTAssertNil(noTokenBasis.projectedFullCycleCostUSD)
        XCTAssertNil(noTokenBasis.forecastConfidence)
    }

    func testCycleForecastRequiresObservedIncreaseWhenBaselineIsFull() {
        // 首次采样已为 100%、之后没有继续增长时，实际观察增量为 0，
        // 不能把官方快照的 100% 当成可靠的本机预估依据。
        var cycle = cycleRecord(
            id: "full-baseline",
            accountKey: "claude:primary",
            app: .claude,
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000),
            usedPercent: 100
        )
        cycle.allowanceSegments[0].baselineUsedPercent = 100
        cycle.allowanceSegments[0].maximumUsedPercent = 100
        cycle.allowanceSegments[0].latestUsedPercent = 100

        var totals = UsageTotals.zero
        totals.inputTokens = 1_000
        totals.costUSD = 20

        let summary = CycleUsageSummary(
            cycle: cycle,
            totals: totals,
            currentAllowanceTotals: totals,
            quality: .exact
        )

        XCTAssertEqual(summary.forecastObservedPercent, 0)
        XCTAssertNil(summary.projectedFullCycleTokens)
        XCTAssertNil(summary.projectedFullCycleCostUSD)
        XCTAssertNil(summary.forecastConfidence)
    }

    func testCycleUsageRollupRejectsV3ForOneTimeRebuild() throws {
        var legacy = CycleUsageRollupPayload()
        legacy.version = 3
        let legacyData = try JSONEncoder().encode(legacy)
        XCTAssertNil(CycleUsageRollupCache.decode(legacyData))

        let current = CycleUsageRollupPayload()
        let currentData = try JSONEncoder().encode(current)
        XCTAssertEqual(
            CycleUsageRollupCache.decode(currentData)?.version,
            CycleUsageRollupPayload.currentVersion
        )

        var legacyV4 = CycleUsageRollupPayload()
        legacyV4.initialRebuildCompletedAt = Date(timeIntervalSince1970: 1_000)
        legacyV4.initialRebuildCompletedApps = nil
        let legacyV4Data = try JSONEncoder().encode(legacyV4)
        XCTAssertEqual(
            CycleUsageRollupCache.decode(legacyV4Data)?.effectiveInitialRebuildCompletedApps,
            [.codex, .claude],
            "旧 v4 的全局完成时间应兼容迁移为两个 Provider 均已完成"
        )

        var partialV4 = CycleUsageRollupPayload()
        partialV4.initialRebuildCompletedApps = [.codex]
        let partialV4Data = try JSONEncoder().encode(partialV4)
        XCTAssertEqual(
            CycleUsageRollupCache.decode(partialV4Data)?.effectiveInitialRebuildCompletedApps,
            [.codex]
        )
    }

    func testCycleForecastUsesKnownCostWhenSomeUsageIsUnpriced() {
        let cycle = cycleRecord(
            id: "partially-unpriced",
            accountKey: "claude:primary",
            app: .claude,
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000),
            usedPercent: 20
        )
        var totals = UsageTotals.zero
        totals.inputTokens = 1_000
        totals.costUSD = 20
        totals.hasUnpricedUsage = true
        let summary = CycleUsageSummary(
            cycle: cycle,
            totals: totals,
            currentAllowanceTotals: totals,
            quality: .incomplete
        )

        XCTAssertEqual(summary.projectedFullCycleTokens, 5_000)
        XCTAssertEqual(summary.projectedFullCycleCostUSD, 100)
        XCTAssertEqual(summary.forecastConfidence, .rough)
    }

    func testCycleForecastKeepsActualUsageBeforeExtraReset() {
        let start = Date(timeIntervalSince1970: 1_000)
        let resetAt = Date(timeIntervalSince1970: 1_500)
        var cycle = cycleRecord(
            id: "benefit-reset",
            accountKey: "claude:primary",
            app: .claude,
            start: start,
            end: Date(timeIntervalSince1970: 2_000),
            usedPercent: 80
        )
        cycle.allowanceSegments[0].endAt = resetAt
        cycle.allowanceSegments.append(QuotaCycleAllowanceSegment(
            id: "benefit-reset-current",
            startAt: resetAt,
            endAt: nil,
            baselineUsedPercent: 0,
            latestUsedPercent: 20,
            maximumUsedPercent: 20,
            firstSampleAt: resetAt,
            lastSampleAt: resetAt.addingTimeInterval(60),
            startReason: .extraReset
        ))
        cycle.latestUsedPercent = 20
        var total = UsageTotals.zero
        total.inputTokens = 5_000
        total.costUSD = 50
        var current = UsageTotals.zero
        current.inputTokens = 1_000
        current.costUSD = 10
        let summary = CycleUsageSummary(
            cycle: cycle,
            totals: total,
            currentAllowanceTotals: current,
            quality: .estimated
        )

        XCTAssertEqual(summary.projectedFullCycleTokens, 9_000)
        XCTAssertEqual(summary.projectedFullCycleCostUSD, 90)
    }

    @MainActor
    func testCycleUsageRebuildRangeKeepsHistoryBucketsAndRefillsAffectedOnes() {
        let start = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 300_000))
        let oldCycle = cycleRecord(
            id: "old-cycle",
            accountKey: "codex:primary:a",
            app: .codex,
            start: start.addingTimeInterval(-30 * 24 * 3_600),
            end: start.addingTimeInterval(-25 * 24 * 3_600)
        )
        let affectedCycle = cycleRecord(
            id: "affected-cycle",
            accountKey: "codex:primary:a",
            app: .codex,
            start: start,
            end: start.addingTimeInterval(7_200)
        )
        func entry(at timestamp: Date, input: Int) -> UsageEntry {
            UsageEntry(
                app: .codex,
                conversationKey: "codex:test",
                model: "gpt-5.6",
                speed: .standard,
                day: UsageDay.startOfDay(for: timestamp),
                timestamp: timestamp,
                inputTokens: input,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                costUSD: 1,
                costBreakdown: nil
            )
        }
        let segment = QuotaCycleAccountSegment(
            id: "a",
            accountKey: "codex:primary:a",
            app: .codex,
            startAt: start.addingTimeInterval(-30 * 24 * 3_600),
            endAt: nil
        )
        let aggregator = CycleUsageAggregator()
        // 先灌入历史桶（100 tokens）+ 受影响窗口桶（10 tokens）
        aggregator.ingest(
            entries: [
                entry(at: oldCycle.startAt.addingTimeInterval(60), input: 100),
                entry(at: affectedCycle.startAt.addingTimeInterval(60), input: 10),
            ],
            cycles: [oldCycle, affectedCycle],
            accountSegments: [segment]
        )
        XCTAssertEqual(aggregator.snapshot().count, 2)

        // 扫描结果同时含旧周期和受影响周期；只能重灌 affected-cycle。
        let rebuildEntries = [
            entry(at: oldCycle.startAt.addingTimeInterval(120), input: 999),
            entry(at: affectedCycle.startAt.addingTimeInterval(120), input: 50),
        ]
        aggregator.rebuildRange(
            exactEntries: rebuildEntries,
            cycles: [oldCycle, affectedCycle],
            accountSegments: [segment],
            affectedCycleIDs: ["affected-cycle"]
        )
        // 相同范围重复重建必须幂等，不能再次累加。
        aggregator.rebuildRange(
            exactEntries: rebuildEntries,
            cycles: [oldCycle, affectedCycle],
            accountSegments: [segment],
            affectedCycleIDs: ["affected-cycle"]
        )

        let byID = Dictionary(grouping: aggregator.snapshot(), by: \.cycleID)
        XCTAssertEqual(byID["old-cycle"]?.first?.inputTokens, 100, "窗口外的历史桶必须原样保留")
        XCTAssertEqual(byID["affected-cycle"]?.first?.inputTokens, 50, "受影响周期内的桶应被新扫描结果重灌")
        XCTAssertEqual(aggregator.snapshot().count, 2)
    }

    @MainActor
    func testCycleUsageRebuildRangeWithEmptyAffectedSetIsNoOp() {
        let start = Date(timeIntervalSince1970: 400_000)
        let cycle = cycleRecord(
            id: "cycle",
            accountKey: "codex:primary:a",
            app: .codex,
            start: start,
            end: start.addingTimeInterval(3_600)
        )
        func entry(at timestamp: Date, input: Int) -> UsageEntry {
            UsageEntry(
                app: .codex,
                conversationKey: "codex:test",
                model: "gpt-5.6",
                speed: .standard,
                day: UsageDay.startOfDay(for: timestamp),
                timestamp: timestamp,
                inputTokens: input,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                costUSD: 1,
                costBreakdown: nil
            )
        }
        let segment = QuotaCycleAccountSegment(
            id: "a",
            accountKey: "codex:primary:a",
            app: .codex,
            startAt: start,
            endAt: nil
        )
        let aggregator = CycleUsageAggregator()
        aggregator.ingest(
            entries: [entry(at: start.addingTimeInterval(60), input: 100)],
            cycles: [cycle],
            accountSegments: [segment]
        )
        // 空受影响集合 = 没有需要重建的周期，不清桶也不追加。
        aggregator.rebuildRange(
            exactEntries: [entry(at: start.addingTimeInterval(120), input: 50)],
            cycles: [cycle],
            accountSegments: [segment],
            affectedCycleIDs: []
        )
        let snapshot = aggregator.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.inputTokens, 100)
    }

    func testCycleUsageAffectedCycleIDsIncludesCyclesCrossingRebuildStart() {
        let dateFrom = Date(timeIntervalSince1970: 10_000)
        let dateTo = Date(timeIntervalSince1970: 20_000)
        let before = cycleRecord(
            id: "before",
            accountKey: "codex:primary:a",
            app: .codex,
            start: dateFrom.addingTimeInterval(-2_000),
            end: dateFrom
        )
        let crossing = cycleRecord(
            id: "crossing",
            accountKey: "codex:primary:a",
            app: .codex,
            start: dateFrom.addingTimeInterval(-1_000),
            end: dateFrom.addingTimeInterval(1_000)
        )
        let inside = cycleRecord(
            id: "inside",
            accountKey: "codex:primary:a",
            app: .codex,
            start: dateFrom,
            end: dateTo
        )
        let after = cycleRecord(
            id: "after",
            accountKey: "codex:primary:a",
            app: .codex,
            start: dateTo,
            end: dateTo.addingTimeInterval(1_000)
        )

        XCTAssertEqual(
            UsageService.affectedCycleIDs(
                cycles: [before, crossing, inside, after],
                since: dateFrom,
                until: dateTo
            ),
            Set(["crossing", "inside"])
        )
        XCTAssertEqual(
            UsageService.rebuildScanStart(
                windowStart: dateFrom,
                cycles: [before, crossing, inside, after],
                affectedCycleIDs: Set(["crossing", "inside"])
            ),
            crossing.startAt,
            "重建扫描必须扩展到跨窗口周期的真实起点"
        )
    }

    func testCycleRebuildAvailabilityTreatsMissingRootAsEmptyAndIsolatesProviderFailures() {
        let claude = ClaudeJSONLScanner.Result(
            entries: [],
            conversationSeeds: [],
            newState: [:],
            newSeenIds: [],
            filesScanned: 0,
            linesParsed: 0,
            failedFileCount: 0
        )
        let codex = CodexJSONLScanner.Result(
            entries: [],
            conversationSeeds: [],
            newState: [:],
            newSeenIds: [],
            filesScanned: 0,
            linesParsed: 0,
            failedFileCount: 0
        )
        let start = Date(timeIntervalSince1970: 10_000)
        let claudeCycle = cycleRecord(
            id: "claude",
            accountKey: "claude:primary",
            app: .claude,
            start: start,
            end: start.addingTimeInterval(18_000)
        )
        let codexCycle = cycleRecord(
            id: "codex",
            accountKey: "codex:primary:a",
            app: .codex,
            start: start,
            end: start.addingTimeInterval(18_000)
        )

        XCTAssertEqual(
            UsageService.cycleRebuildFailedApps(
                claude: claude,
                codex: codex,
                cycles: [claudeCycle, codexCycle]
            ),
            [],
            "从未创建过的 Claude 日志目录表示空数据，不是读取失败"
        )

        var unreadableClaude = claude
        unreadableClaude.failedFileCount = 1
        XCTAssertEqual(
            UsageService.cycleRebuildFailedApps(
                claude: unreadableClaude,
                codex: codex,
                cycles: [codexCycle]
            ),
            [],
            "非受影响 Provider 的读取失败不应阻塞本轮重建"
        )
        let failedApps = UsageService.cycleRebuildFailedApps(
            claude: unreadableClaude,
            codex: codex,
            cycles: [claudeCycle, codexCycle]
        )
        XCTAssertEqual(
            failedApps,
            [.claude],
            "真正读取失败时只冻结对应 Provider"
        )
        XCTAssertEqual(
            UsageService.cycleRebuildableCycleIDs(
                cycles: [claudeCycle, codexCycle],
                requestedCycleIDs: [claudeCycle.id, codexCycle.id],
                failedApps: failedApps
            ),
            [codexCycle.id],
            "Claude 失败时 Codex 周期仍应继续清桶重灌"
        )

        let completedApps = UsageService.updatedInitialCycleRebuildApps(
            completedApps: [],
            requestedApps: [.codex, .claude],
            failedApps: [.claude]
        )
        XCTAssertEqual(completedApps, [.codex])
        XCTAssertEqual(
            UsageService.pendingInitialCycleRebuildApps(
                cycles: [claudeCycle, codexCycle],
                completedApps: completedApps
            ),
            [.claude],
            "下次启动只应重试失败的 Claude，不应再次全量扫描 Codex"
        )
    }

    func testCycleAxisCostUsesCompactTieredPrecision() {
        XCTAssertEqual(StatsFormatter.axisCost(120), "$120")
        XCTAssertEqual(StatsFormatter.axisCost(12.6), "$13")
        XCTAssertEqual(StatsFormatter.axisCost(1.25), "$1.25")
        XCTAssertEqual(StatsFormatter.axisCost(0.5), "$0.50")
        XCTAssertEqual(StatsFormatter.axisCost(0.125), "$0.125")
    }

    func testSuccessfulCycleRebuildPreservesUnrelatedScanWarning() {
        let scanWarning = "usage scan incomplete: 1 log source(s) unreadable; retrying next scan"

        XCTAssertEqual(
            UsageService.lastErrorAfterCycleRebuild(
                current: scanWarning,
                rebuildWarning: nil
            ),
            scanWarning,
            "受限重建成功不能抹掉前置增量扫描发现的读取失败"
        )
        XCTAssertNil(
            UsageService.lastErrorAfterCycleRebuild(
                current: "cycle usage rebuild incomplete: Claude Code logs unreadable",
                rebuildWarning: nil
            ),
            "周期重建恢复成功后应清除自己留下的旧告警"
        )
        XCTAssertEqual(
            UsageService.lastErrorAfterCycleRebuild(
                current: scanWarning,
                rebuildWarning: "cycle usage rebuild incomplete: Codex logs unreadable"
            ),
            "cycle usage rebuild incomplete: Codex logs unreadable"
        )
    }

    @MainActor
    func testCycleUsageAggregatorSeparatesUsageAcrossAllowanceReset() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let benefitResetAt = Date(timeIntervalSince1970: 1_500)
        var cycle = cycleRecord(
            id: "allowance-buckets",
            accountKey: "claude:primary",
            app: .claude,
            start: start,
            end: Date(timeIntervalSince1970: 2_000),
            usedPercent: 80
        )
        cycle.allowanceSegments[0].endAt = benefitResetAt
        cycle.allowanceSegments.append(QuotaCycleAllowanceSegment(
            id: "allowance-buckets-current",
            startAt: benefitResetAt,
            endAt: nil,
            baselineUsedPercent: 0,
            latestUsedPercent: 20,
            maximumUsedPercent: 20,
            firstSampleAt: benefitResetAt,
            lastSampleAt: benefitResetAt.addingTimeInterval(60),
            startReason: .extraReset
        ))
        cycle.latestUsedPercent = 20
        func entry(at timestamp: Date, tokens: Int) -> UsageEntry {
            UsageEntry(
                app: .claude,
                conversationKey: "claude:test",
                model: "claude-sonnet-5",
                speed: .standard,
                day: UsageDay.startOfDay(for: timestamp),
                timestamp: timestamp,
                inputTokens: tokens,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                costUSD: Decimal(tokens) / 100,
                costBreakdown: nil
            )
        }
        let aggregator = CycleUsageAggregator()
        aggregator.ingest(
            entries: [
                entry(at: Date(timeIntervalSince1970: 1_200), tokens: 400),
                entry(at: Date(timeIntervalSince1970: 1_600), tokens: 100),
            ],
            cycles: [cycle],
            accountSegments: [QuotaCycleAccountSegment(
                id: "claude",
                accountKey: cycle.accountKey,
                app: .claude,
                startAt: start,
                endAt: nil
            )]
        )

        let summary = try XCTUnwrap(aggregator.summaries(
            cycles: [cycle],
            kind: .weekly,
            app: .claude,
            now: cycle.endAt.addingTimeInterval(1)
        ).first)
        XCTAssertEqual(summary.totals.totalTokens, 500)
        XCTAssertEqual(summary.currentAllowanceTotals.totalTokens, 100)
        XCTAssertEqual(summary.projectedFullCycleTokens, 900)
    }

    func testCycleSummaryDistinguishesEmptyInferredHistory() {
        let cycle = cycleRecord(
            id: "empty-history",
            accountKey: "claude:primary",
            app: .claude,
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        let empty = CycleUsageSummary(cycle: cycle, totals: .zero, quality: .estimated)
        XCTAssertFalse(empty.hasLocalUsage)
        XCTAssertNil(empty.projectedFullCycleTokens)
        XCTAssertNil(empty.projectedFullCycleCostUSD)
        XCTAssertNil(empty.forecastConfidence)

        var unpriced = UsageTotals.zero
        unpriced.requestCount = 1
        unpriced.hasUnpricedUsage = true
        XCTAssertTrue(CycleUsageSummary(cycle: cycle, totals: unpriced, quality: .estimated).hasLocalUsage)
    }

    @MainActor
    func testCycleRebuildIgnoresEntriesBeforeFeatureTrackingStarted() throws {
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 100_000))
        let cycle = cycleRecord(
            id: "weekly-residual",
            accountKey: "claude:primary",
            app: .claude,
            start: day,
            end: Calendar.current.date(byAdding: .day, value: 1, to: day)!
        )
        let beforeTracking = UsageEntry(
            app: .claude,
            conversationKey: "claude:test",
            model: "claude-opus-4-8",
            speed: .standard,
            day: day,
            timestamp: day.addingTimeInterval(60),
            inputTokens: 40,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            costUSD: 4,
            costBreakdown: nil
        )
        var afterTracking = beforeTracking
        afterTracking.timestamp = day.addingTimeInterval(180)
        let aggregator = CycleUsageAggregator()
        aggregator.rebuild(
            exactEntries: [beforeTracking, afterTracking],
            cycles: [cycle],
            accountSegments: [QuotaCycleAccountSegment(
                id: "claude",
                accountKey: "claude:primary",
                app: .claude,
                startAt: day.addingTimeInterval(120),
                endAt: nil
            )]
        )
        let summary = try XCTUnwrap(aggregator.summaries(
            cycles: [cycle],
            kind: .weekly,
            app: .claude,
            now: cycle.endAt.addingTimeInterval(1)
        ).first)

        XCTAssertEqual(summary.totals.totalTokens, 40)
        XCTAssertEqual(summary.totals.costUSD, 4)
    }

    func testClaudeAssistantUsageMapsFastStandardAndMissingSpeed() throws {
        let fast = try XCTUnwrap(ClaudeJSONLScanner.parseAssistantLine(claudeAssistantLine(
            messageID: "msg-fast",
            speed: "fast"
        )))
        let standard = try XCTUnwrap(ClaudeJSONLScanner.parseAssistantLine(claudeAssistantLine(
            messageID: "msg-standard",
            speed: "standard"
        )))
        let unknown = try XCTUnwrap(ClaudeJSONLScanner.parseAssistantLine(claudeAssistantLine(
            messageID: "msg-unknown",
            speed: nil
        )))

        XCTAssertEqual(fast.speed, .fast)
        XCTAssertEqual(standard.speed, .standard)
        XCTAssertEqual(unknown.speed, .unknown)
        XCTAssertEqual(fast.cacheReadTokens, 30)
        XCTAssertEqual(fast.cacheCreationTokens, 40)
    }

    func testClaudeRepeatedStreamingLinesKeepSameMessageIdentity() throws {
        let first = try XCTUnwrap(ClaudeJSONLScanner.parseAssistantLine(claudeAssistantLine(
            messageID: "msg-stream",
            speed: "fast",
            outputTokens: 10,
            stopReason: nil
        )))
        let completed = try XCTUnwrap(ClaudeJSONLScanner.parseAssistantLine(claudeAssistantLine(
            messageID: "msg-stream",
            speed: "fast",
            outputTokens: 20,
            stopReason: "end_turn"
        )))
        var candidates: [String: ClaudeJSONLScanner.ParsedAssistant] = [:]
        ClaudeJSONLScanner.mergeCandidate(first, into: &candidates)
        ClaudeJSONLScanner.mergeCandidate(completed, into: &candidates)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates["msg-stream"]?.outputTokens, 20)
        XCTAssertEqual(candidates["msg-stream"]?.stopReason, "end_turn")
        XCTAssertFalse(ClaudeJSONLScanner.isComplete(first))
        XCTAssertTrue(ClaudeJSONLScanner.isComplete(completed))
    }

    func testClaudeCacheCreationTTLParsingPreservesAggregate() throws {
        let legacy = try XCTUnwrap(ClaudeJSONLScanner.parseAssistantLine(claudeAssistantLine(
            messageID: "msg-legacy-cache",
            speed: "standard",
            cacheCreationTokens: 40
        )))
        XCTAssertEqual(legacy.cacheCreationTokens, 40)
        XCTAssertEqual(legacy.cacheCreation5mTokens, 40)
        XCTAssertEqual(legacy.cacheCreation1hTokens, 0)

        let detailed = try XCTUnwrap(ClaudeJSONLScanner.parseAssistantLine(claudeAssistantLine(
            messageID: "msg-detailed-cache",
            speed: "standard",
            cacheCreationTokens: 100,
            cacheCreation5mTokens: 40,
            cacheCreation1hTokens: 60
        )))
        XCTAssertEqual(detailed.cacheCreationTokens, 100)
        XCTAssertEqual(detailed.cacheCreation5mTokens, 40)
        XCTAssertEqual(detailed.cacheCreation1hTokens, 60)

        let mismatched = try XCTUnwrap(ClaudeJSONLScanner.parseAssistantLine(claudeAssistantLine(
            messageID: "msg-mismatched-cache",
            speed: "standard",
            cacheCreationTokens: 100,
            cacheCreation5mTokens: 1,
            cacheCreation1hTokens: 30
        )))
        XCTAssertEqual(mismatched.cacheCreationTokens, 100)
        XCTAssertEqual(mismatched.cacheCreation5mTokens, 70)
        XCTAssertEqual(mismatched.cacheCreation1hTokens, 30)

        let clamped = try XCTUnwrap(ClaudeJSONLScanner.parseAssistantLine(claudeAssistantLine(
            messageID: "msg-clamped-cache",
            speed: "standard",
            cacheCreationTokens: 100,
            cacheCreation5mTokens: 20,
            cacheCreation1hTokens: 130
        )))
        XCTAssertEqual(clamped.cacheCreationTokens, 100)
        XCTAssertEqual(clamped.cacheCreation5mTokens, 0)
        XCTAssertEqual(clamped.cacheCreation1hTokens, 100)
    }

    func testCodexServiceTierTransitionsAndUnknownValue() {
        let transitions = ["default", "priority", "default"].map {
            CodexJSONLScanner.speed(fromServiceTier: $0)
        }

        XCTAssertEqual(transitions, [.standard, .fast, .standard])
        XCTAssertEqual(CodexJSONLScanner.speed(fromServiceTier: "future-tier"), .unknown)
        XCTAssertEqual(CodexJSONLScanner.speed(fromServiceTier: nil), .unknown)
    }

    func testCodexThreadSettingsFixtureReadsNestedPriorityTier() throws {
        let fixture: [String: Any] = [
            "type": "event_msg",
            "payload": [
                "type": "thread_settings_applied",
                "thread_settings": [
                    "model": "gpt-5.6-sol",
                    "service_tier": "priority",
                ],
            ],
        ]

        let settings = try XCTUnwrap(CodexJSONLScanner.threadSettings(from: fixture))

        XCTAssertEqual(settings.model, "gpt-5.6-sol")
        XCTAssertEqual(settings.speed, .fast)
    }

    func testCodexIncrementalStateKeepsFastTierAndCumulativeSignature() throws {
        let state = ScanFileState(
            mtime: 10,
            offset: 200,
            lastModel: "gpt-5.6-sol",
            lastServiceTier: .fast,
            lastCodexTotalUsageSignature: "100:20:0:30:5:150",
            conversationID: "thread-1",
            conversationCwd: "/tmp/project",
            conversationGitBranch: nil,
            conversationIsSidechain: nil,
            fallbackTitle: nil
        )

        let decoded = try JSONDecoder().decode(
            ScanFileState.self,
            from: JSONEncoder().encode(state)
        )

        XCTAssertEqual(decoded.lastServiceTier, .fast)
        XCTAssertEqual(decoded.lastCodexTotalUsageSignature, state.lastCodexTotalUsageSignature)
    }

    func testCodexTruncationResetsTierModelAndDuplicateGuard() {
        var state = ScanFileState(
            mtime: 10,
            offset: 200,
            lastModel: "gpt-5.6-sol",
            lastServiceTier: .fast,
            lastCodexTotalUsageSignature: "signature",
            conversationID: "thread-1",
            conversationCwd: "/tmp/project",
            conversationGitBranch: nil,
            conversationIsSidechain: nil,
            fallbackTitle: nil
        )

        CodexJSONLScanner.resetForTruncation(&state)

        XCTAssertEqual(state.offset, 0)
        XCTAssertNil(state.lastModel)
        XCTAssertNil(state.lastServiceTier)
        XCTAssertNil(state.lastCodexTotalUsageSignature)
        XCTAssertEqual(state.conversationID, "thread-1")
    }

    func testCodexCumulativeUsageSignatureFiltersOnlyUnchangedTotals() {
        let total: [String: Any] = [
            "input_tokens": 100,
            "cached_input_tokens": 20,
            "output_tokens": 30,
            "reasoning_output_tokens": 5,
            "total_tokens": 150,
        ]
        var changed = total
        changed["output_tokens"] = 31

        XCTAssertEqual(
            CodexJSONLScanner.totalUsageSignature(total),
            CodexJSONLScanner.totalUsageSignature(total)
        )
        XCTAssertNotEqual(
            CodexJSONLScanner.totalUsageSignature(total),
            CodexJSONLScanner.totalUsageSignature(changed)
        )
        XCTAssertNil(CodexJSONLScanner.totalUsageSignature([:]))
    }

    func testFastPricingUsesExplicitTierRatesAndKeepsUnpricedAsNil() throws {
        let standard = try XCTUnwrap(Pricing.costBreakdown(
            app: .codex,
            model: "gpt-5.6-sol",
            speed: .standard,
            input: 100_000,
            output: 100_000,
            cacheRead: 100_000,
            cacheCreation: 100_000,
            at: Date(timeIntervalSince1970: 0),
            inputTotal: 100_000
        ))
        XCTAssertEqual(standard.input, 0.5)
        XCTAssertEqual(standard.output, 3)
        XCTAssertEqual(standard.cacheRead, 0.05)
        XCTAssertEqual(standard.cacheCreation, 0.625)

        let claude = try XCTUnwrap(Pricing.costBreakdown(
            app: .claude,
            model: "claude-opus-4-8",
            speed: .fast,
            input: 1_000_000,
            output: 1_000_000,
            cacheRead: 1_000_000,
            cacheCreation: 1_000_000,
            at: Date(timeIntervalSince1970: 0)
        ))
        XCTAssertEqual(claude.input, 10)
        XCTAssertEqual(claude.output, 50)
        XCTAssertEqual(claude.cacheRead, 1)
        XCTAssertEqual(claude.cacheCreation, 12.5)

        let codex = try XCTUnwrap(Pricing.costBreakdown(
            app: .codex,
            model: "gpt-5.6-sol",
            speed: .fast,
            input: 100_000,
            output: 100_000,
            cacheRead: 100_000,
            cacheCreation: 100_000,
            at: Date(timeIntervalSince1970: 0),
            inputTotal: 100_000
        ))
        XCTAssertEqual(codex.input, 1)
        XCTAssertEqual(codex.output, 6)
        XCTAssertEqual(codex.cacheRead, 0.1)
        XCTAssertEqual(codex.cacheCreation, 1.25)

        XCTAssertNil(Pricing.costBreakdown(
            app: .codex,
            model: "gpt-5.6-sol",
            speed: .fast,
            input: 272_001,
            output: 1,
            cacheRead: 0,
            cacheCreation: 0,
            at: Date(timeIntervalSince1970: 0),
            inputTotal: 272_001
        ))
        XCTAssertNil(Pricing.costBreakdown(
            app: .claude,
            model: "claude-future-model",
            speed: .fast,
            input: 1,
            output: 1,
            cacheRead: 0,
            cacheCreation: 0,
            at: Date(timeIntervalSince1970: 0)
        ))
        XCTAssertNil(Pricing.costBreakdown(
            app: .claude,
            model: "claude-opus-4-8",
            speed: .unknown,
            input: 1,
            output: 1,
            cacheRead: 0,
            cacheCreation: 0,
            at: Date(timeIntervalSince1970: 0)
        ))
    }

    func testLiteLLMDecoderSeparatesStandardAndOpenAIPriorityRates() throws {
        let data = Data(#"""
        {
          "gpt-future": {
            "litellm_provider": "openai",
            "input_cost_per_token": 0.000005,
            "output_cost_per_token": 0.000030,
            "cache_read_input_token_cost": 0.0000005,
            "input_cost_per_token_priority": 0.000010,
            "output_cost_per_token_priority": 0.000060,
            "cache_read_input_token_cost_priority": 0.000001
          },
          "claude-future": {
            "litellm_provider": "anthropic",
            "input_cost_per_token": 0.000005,
            "output_cost_per_token": 0.000025,
            "input_cost_per_token_priority": 0.000010,
            "output_cost_per_token_priority": 0.000050
          }
        }
        """#.utf8)

        let decoded = try LiteLLMPricingDecoder.decode(data)
        XCTAssertEqual(decoded.standard["gpt-future"], ModelPrice(
            input: 5,
            output: 30,
            cacheRead: 0.5,
            cacheCreation: 0
        ))
        XCTAssertEqual(decoded.codexFast["gpt-future"], ModelPrice(
            input: 10,
            output: 60,
            cacheRead: 1,
            cacheCreation: 0
        ))
        XCTAssertNil(decoded.codexFast["claude-future"])
        XCTAssertTrue(decoded.claudeFast.isEmpty)
    }

    func testModelsDevDecoderReadsOfficialFastModeAndIgnoresReseller() throws {
        let data = Data(#"""
        {
          "anthropic": {
            "models": {
              "claude-opus-5": {
                "cost": {
                  "input": 5,
                  "output": 25,
                  "cache_read": 0.5,
                  "cache_write": 6.25
                },
                "experimental": {
                  "modes": {
                    "fast": {
                      "cost": {
                        "input": 10,
                        "output": 50,
                        "cache_read": 1,
                        "cache_write": 12.5
                      }
                    }
                  }
                }
              }
            }
          },
          "reseller": {
            "models": {
              "claude-opus-5": {
                "cost": {"input": 1, "output": 1},
                "experimental": {
                  "modes": {
                    "fast": {"cost": {"input": 2, "output": 2}}
                  }
                }
              }
            }
          }
        }
        """#.utf8)

        let decoded = try ModelsDevPricingDecoder.decode(data)
        XCTAssertEqual(decoded.standard["claude-opus-5"], ModelPrice(
            input: 5,
            output: 25,
            cacheRead: 0.5,
            cacheCreation: 6.25
        ))
        XCTAssertEqual(decoded.claudeFast["claude-opus-5"], ModelPrice(
            input: 10,
            output: 50,
            cacheRead: 1,
            cacheCreation: 12.5
        ))
        XCTAssertNil(decoded.codexFast["claude-opus-5"])
    }

    func testMissingPriceRefreshSkipsUnknownTierAndIntentionalInternalModel() {
        XCTAssertFalse(Pricing.needsRemotePriceRefresh(
            model: "future-model",
            app: .codex,
            speed: .unknown
        ))
        XCTAssertFalse(Pricing.needsRemotePriceRefresh(
            model: "codex-auto-review",
            app: .codex,
            speed: .standard
        ))
        XCTAssertTrue(Pricing.needsRemotePriceRefresh(
            model: "ccbar-pi-future-model-019fc5c5",
            app: .pi,
            speed: .standard
        ))
        XCTAssertTrue(Pricing.needsRemotePriceRefresh(
            model: "ccbar-opencode-future-model-019fc5c5",
            app: .opencode,
            speed: .standard
        ))
        XCTAssertEqual(Pricing.normalize(model: "openai-codex/gpt-5.5-codex"), "gpt-5.5-codex")
        XCTAssertEqual(Pricing.normalize(model: "anthropic/claude-sonnet-4-5"), "claude-sonnet-4-5")
    }

    func testGPT55StandardLongContextProAndFastRates() throws {
        let standardShort = try XCTUnwrap(Pricing.costBreakdown(
            app: .codex,
            model: "gpt-5.5",
            speed: .standard,
            input: 100_000,
            output: 100_000,
            cacheRead: 100_000,
            cacheCreation: 0,
            at: Date(timeIntervalSince1970: 0),
            inputTotal: 272_000
        ))
        XCTAssertEqual(standardShort.input, 0.5)
        XCTAssertEqual(standardShort.output, 3)
        XCTAssertEqual(standardShort.cacheRead, 0.05)

        let standardLong = try XCTUnwrap(Pricing.costBreakdown(
            app: .codex,
            model: "gpt-5.5",
            speed: .standard,
            input: 100_000,
            output: 100_000,
            cacheRead: 100_000,
            cacheCreation: 0,
            at: Date(timeIntervalSince1970: 0),
            inputTotal: 272_001
        ))
        XCTAssertEqual(standardLong.input, 1)
        XCTAssertEqual(standardLong.output, 4.5)
        XCTAssertEqual(standardLong.cacheRead, 0.1)

        let fast = try XCTUnwrap(Pricing.costBreakdown(
            app: .codex,
            model: "gpt-5.5",
            speed: .fast,
            input: 100_000,
            output: 100_000,
            cacheRead: 100_000,
            cacheCreation: 0,
            at: Date(timeIntervalSince1970: 0),
            inputTotal: 100_000
        ))
        XCTAssertEqual(fast.input, 1.25)
        XCTAssertEqual(fast.output, 7.5)
        XCTAssertEqual(fast.cacheRead, 0.125)

        let pro = try XCTUnwrap(Pricing.costBreakdown(
            app: .codex,
            model: "gpt-5.5-pro",
            speed: .standard,
            input: 100_000,
            output: 100_000,
            cacheRead: 100_000,
            cacheCreation: 0,
            at: Date(timeIntervalSince1970: 0),
            inputTotal: 100_000
        ))
        XCTAssertEqual(pro.input, 3)
        XCTAssertEqual(pro.output, 18)
        XCTAssertEqual(pro.cacheRead, 3)
    }

    func testGPT56SolPromoPricingOnlyAppliesFromEffectiveDate() throws {
        let beforePromo = ISO8601DateFormatter().date(from: "2026-08-20T23:59:59Z")!
        let promo = ISO8601DateFormatter().date(from: "2026-08-21T00:00:00Z")!

        for model in ["gpt-5.6", "gpt-5.6-sol"] {
            let oldShort = try XCTUnwrap(Pricing.costBreakdown(
                app: .codex, model: model, speed: .standard,
                input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheCreation: 1_000_000,
                at: beforePromo, inputTotal: 100_000
            ))
            XCTAssertEqual(oldShort, CostBreakdown(input: 5, output: 30, cacheRead: 0.5, cacheCreation: 6.25))

            let promoShort = try XCTUnwrap(Pricing.costBreakdown(
                app: .codex, model: model, speed: .standard,
                input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheCreation: 1_000_000,
                at: promo, inputTotal: 100_000
            ))
            XCTAssertEqual(promoShort, CostBreakdown(input: 4, output: 20, cacheRead: 0.4, cacheCreation: 5))

            let promoLong = try XCTUnwrap(Pricing.costBreakdown(
                app: .codex, model: model, speed: .standard,
                input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheCreation: 1_000_000,
                at: promo, inputTotal: 272_001
            ))
            XCTAssertEqual(promoLong, CostBreakdown(input: 8, output: 30, cacheRead: 0.8, cacheCreation: 10))

            let oldFast = try XCTUnwrap(Pricing.costBreakdown(
                app: .codex, model: model, speed: .fast,
                input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheCreation: 1_000_000,
                at: beforePromo, inputTotal: 100_000
            ))
            XCTAssertEqual(oldFast, CostBreakdown(input: 10, output: 60, cacheRead: 1, cacheCreation: 12.5))

            let promoFast = try XCTUnwrap(Pricing.costBreakdown(
                app: .codex, model: model, speed: .fast,
                input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheCreation: 1_000_000,
                at: promo, inputTotal: 100_000
            ))
            XCTAssertEqual(promoFast, CostBreakdown(input: 8, output: 40, cacheRead: 0.8, cacheCreation: 10))

            XCTAssertNil(Pricing.costBreakdown(
                app: .codex, model: model, speed: .fast,
                input: 272_001, output: 1, cacheRead: 0, cacheCreation: 0,
                at: promo, inputTotal: 272_001
            ))
        }
    }

    func testGPT6AndClaudeOpus55Rates() throws {
        let date = ISO8601DateFormatter().date(from: "2026-09-23T00:00:00Z")!

        let astraShort = try XCTUnwrap(Pricing.costBreakdown(
            app: .codex, model: "gpt-6-astra", speed: .standard,
            input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheCreation: 1_000_000,
            at: date, inputTotal: 272_000
        ))
        XCTAssertEqual(astraShort, CostBreakdown(input: 10, output: 50, cacheRead: 1, cacheCreation: 12.5))

        let astraLong = try XCTUnwrap(Pricing.costBreakdown(
            app: .codex, model: "gpt-6-astra", speed: .standard,
            input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheCreation: 1_000_000,
            at: date, inputTotal: 272_001
        ))
        XCTAssertEqual(astraLong, CostBreakdown(input: 20, output: 75, cacheRead: 2, cacheCreation: 25))

        let astraFast = try XCTUnwrap(Pricing.costBreakdown(
            app: .codex, model: "gpt-6-astra", speed: .fast,
            input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheCreation: 0,
            at: date, inputTotal: 100_000
        ))
        XCTAssertEqual(astraFast, CostBreakdown(input: 20, output: 100, cacheRead: 2, cacheCreation: 0))
        XCTAssertEqual(Pricing.billingEquivalentMultiplier(app: .codex, model: "gpt-6-astra", speed: .fast), 2.5)

        let opusStandard = try XCTUnwrap(Pricing.costBreakdown(
            app: .claude, model: "claude-opus-5-5", speed: .standard,
            input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheCreation: 1_000_000,
            cacheCreation1h: 1_000_000, at: date
        ))
        XCTAssertEqual(opusStandard, CostBreakdown(input: 4, output: 20, cacheRead: 0.2, cacheCreation: 13))

        let opusFast = try XCTUnwrap(Pricing.costBreakdown(
            app: .claude, model: "claude-opus-5-5", speed: .fast,
            input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheCreation: 1_000_000,
            at: date
        ))
        XCTAssertEqual(opusFast, CostBreakdown(input: 8, output: 40, cacheRead: 0.4, cacheCreation: 10))
        XCTAssertEqual(Pricing.billingEquivalentMultiplier(app: .claude, model: "claude-opus-5-5", speed: .fast), 2)
    }

    func testClaudeCacheCreationTTLUsesSeparateStandardAndFastRates() throws {
        let standard5m = try XCTUnwrap(Pricing.costBreakdown(
            app: .claude,
            model: "claude-sonnet-5",
            speed: .standard,
            input: 0,
            output: 0,
            cacheRead: 0,
            cacheCreation: 100_000,
            at: Date(timeIntervalSince1970: 0)
        ))
        XCTAssertEqual(standard5m.cacheCreation, 0.25)

        let standard1h = try XCTUnwrap(Pricing.costBreakdown(
            app: .claude,
            model: "claude-sonnet-5",
            speed: .standard,
            input: 0,
            output: 0,
            cacheRead: 0,
            cacheCreation: 0,
            cacheCreation1h: 100_000,
            at: Date(timeIntervalSince1970: 0)
        ))
        XCTAssertEqual(standard1h.cacheCreation, 0.4)

        let standardMixed = try XCTUnwrap(Pricing.costBreakdown(
            app: .claude,
            model: "claude-sonnet-5",
            speed: .standard,
            input: 0,
            output: 0,
            cacheRead: 0,
            cacheCreation: 100_000,
            cacheCreation1h: 100_000,
            at: Date(timeIntervalSince1970: 0)
        ))
        XCTAssertEqual(standardMixed.cacheCreation, 0.65)

        let opus48Fast5m = try XCTUnwrap(Pricing.costBreakdown(
            app: .claude,
            model: "claude-opus-4-8",
            speed: .fast,
            input: 0,
            output: 0,
            cacheRead: 0,
            cacheCreation: 100_000,
            at: Date(timeIntervalSince1970: 0)
        ))
        XCTAssertEqual(opus48Fast5m.cacheCreation, 1.25)

        let opus48Fast1h = try XCTUnwrap(Pricing.costBreakdown(
            app: .claude,
            model: "claude-opus-4-8",
            speed: .fast,
            input: 0,
            output: 0,
            cacheRead: 0,
            cacheCreation: 0,
            cacheCreation1h: 100_000,
            at: Date(timeIntervalSince1970: 0)
        ))
        XCTAssertEqual(opus48Fast1h.cacheCreation, 2)

        let opus48Fast = try XCTUnwrap(Pricing.costBreakdown(
            app: .claude,
            model: "claude-opus-4-8",
            speed: .fast,
            input: 0,
            output: 0,
            cacheRead: 0,
            cacheCreation: 100_000,
            cacheCreation1h: 100_000,
            at: Date(timeIntervalSince1970: 0)
        ))
        XCTAssertEqual(opus48Fast.cacheCreation, 3.25)

        for model in ["claude-opus-4-7", "claude-opus-4-6"] {
            let historicalFast5m = try XCTUnwrap(Pricing.costBreakdown(
                app: .claude,
                model: model,
                speed: .fast,
                input: 0,
                output: 0,
                cacheRead: 0,
                cacheCreation: 100_000,
                at: Date(timeIntervalSince1970: 0)
            ))
            XCTAssertEqual(historicalFast5m.cacheCreation, 3.75)

            let historicalFast1h = try XCTUnwrap(Pricing.costBreakdown(
                app: .claude,
                model: model,
                speed: .fast,
                input: 0,
                output: 0,
                cacheRead: 0,
                cacheCreation: 0,
                cacheCreation1h: 100_000,
                at: Date(timeIntervalSince1970: 0)
            ))
            XCTAssertEqual(historicalFast1h.cacheCreation, 6)

            let historicalFast = try XCTUnwrap(Pricing.costBreakdown(
                app: .claude,
                model: model,
                speed: .fast,
                input: 0,
                output: 0,
                cacheRead: 0,
                cacheCreation: 100_000,
                cacheCreation1h: 100_000,
                at: Date(timeIntervalSince1970: 0)
            ))
            XCTAssertEqual(historicalFast.cacheCreation, 9.75)
        }

        let haikuStandard = try XCTUnwrap(Pricing.costBreakdown(
            app: .claude,
            model: "claude-haiku-4-5",
            speed: .standard,
            input: 0,
            output: 0,
            cacheRead: 0,
            cacheCreation: 100_000,
            cacheCreation1h: 100_000,
            at: Date(timeIntervalSince1970: 0)
        ))
        XCTAssertEqual(haikuStandard.cacheCreation, 0.325)
    }

    @MainActor
    func testUnknownPriceStillAggregatesAsZeroCost() {
        let entry = UsageEntry(
            app: .codex,
            conversationKey: "codex:auto-review",
            model: "codex-auto-review",
            speed: .standard,
            day: Date(timeIntervalSince1970: 0),
            timestamp: Date(timeIntervalSince1970: 0),
            inputTokens: 100,
            outputTokens: 10,
            cacheReadTokens: 20,
            cacheCreationTokens: 0,
            costUSD: Pricing.cost(
                app: .codex,
                model: "codex-auto-review",
                speed: .standard,
                input: 100,
                output: 10,
                cacheRead: 20,
                cacheCreation: 0,
                at: Date(timeIntervalSince1970: 0)
            ),
            costBreakdown: nil
        )
        XCTAssertNil(entry.costUSD)

        let usage = UsageAggregator()
        usage.ingest([entry])
        let bucket = usage.snapshot().first
        XCTAssertEqual(bucket?.costUSD, 0)
        XCTAssertEqual(bucket?.inputTokens, 100)
        XCTAssertEqual(bucket?.outputTokens, 10)
        XCTAssertEqual(bucket?.cacheReadTokens, 20)
    }

    @MainActor
    func testResolvedCostMatchesDailyAndConversationRollups() {
        let timestamp = Date(timeIntervalSince1970: 1_786_075_934)
        let breakdown = CostBreakdown(
            input: Decimal(string: "0.01")!,
            output: Decimal(string: "0.02")!,
            cacheRead: Decimal(string: "0.003")!,
            cacheCreation: Decimal(string: "0.004")!
        )
        let entry = UsageEntry(
            app: .opencode,
            conversationKey: "opencode:resolved-cost",
            model: "openai-codex/gpt-5.5-codex",
            speed: .standard,
            day: UsageDay.startOfDay(for: timestamp),
            timestamp: timestamp,
            inputTokens: 1_000,
            outputTokens: 2_000,
            cacheReadTokens: 300,
            cacheCreationTokens: 400,
            costUSD: breakdown.total,
            costBreakdown: breakdown
        )

        assertRollupsMatch(entries: [entry], seeds: [])
    }

    func testFastEquivalentTokensAreSeparateFromRawTokens() {
        var breakdown = UsageSpeedBreakdown()
        breakdown.add(speed: .standard, totals: usageTotals(tokens: 100), app: .codex, model: "gpt-5.6-sol")
        breakdown.add(speed: .fast, totals: usageTotals(tokens: 100), app: .codex, model: "gpt-5.6-sol")

        XCTAssertEqual(breakdown.summary, .mixed)
        XCTAssertEqual(breakdown.standard.totalTokens + breakdown.fast.totalTokens, 200)
        XCTAssertEqual(breakdown.fastBillingEquivalentTokens, 250)
        XCTAssertEqual(breakdown.fastMinimumMultiplier, 2.5)
        XCTAssertEqual(breakdown.fastMaximumMultiplier, 2.5)
        XCTAssertEqual(Pricing.billingEquivalentMultiplier(app: .codex, model: "gpt-5.6-sol", speed: .fast), 2.5)
        XCTAssertEqual(Pricing.billingEquivalentMultiplier(app: .claude, model: "claude-opus-4-7", speed: .fast), 6)

        var fastOnly = UsageSpeedBreakdown()
        fastOnly.add(speed: .fast, totals: usageTotals(tokens: 100), app: .claude, model: "claude-opus-4-8")
        XCTAssertEqual(fastOnly.summary, .fast)

        var unpriced = UsageSpeedBreakdown()
        unpriced.add(speed: .fast, totals: usageTotals(tokens: 100), app: .codex, model: "gpt-future")
        XCTAssertTrue(unpriced.hasUnpricedFastEquivalent)
        XCTAssertNil(unpriced.fastMinimumMultiplier)
    }

    @MainActor
    func testFastMultiplierHidesKnownRangeWhenUnknownModelsAreMixedIn() {
        var breakdown = UsageSpeedBreakdown()
        breakdown.add(speed: .fast, totals: usageTotals(tokens: 100), app: .codex, model: "gpt-5.6-sol")
        breakdown.add(speed: .fast, totals: usageTotals(tokens: 100), app: .codex, model: "gpt-future")

        XCTAssertEqual(breakdown.fast.totalTokens, 200)
        XCTAssertEqual(breakdown.fastBillingEquivalentTokens, 250)
        XCTAssertEqual(breakdown.fastMinimumMultiplier, 2.5)
        XCTAssertTrue(breakdown.hasUnpricedFastEquivalent)
        XCTAssertEqual(StatsFormatter.fastMultiplier(breakdown), "—")
    }

    @MainActor
    func testCodexFixtureScansTierTransitionsIncrementallyAndAfterTruncation() async throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sessions = temporary.appendingPathComponent("sessions", isDirectory: true)
        let archived = temporary.appendingPathComponent("archived", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let conversationID = "11111111-1111-4111-8111-111111111111"
        let file = try copyFixture(
            named: "codex-fast-scan",
            to: sessions.appendingPathComponent("rollout-2026-07-16T00-00-00-\(conversationID).jsonl")
        )

        let first = await CodexJSONLScanner.scan(previous: [:], roots: [sessions, archived], indexedTitles: [:])
        XCTAssertEqual(first.entries.map(\.speed), [.standard, .fast, .standard])
        XCTAssertEqual(first.entries.map(\.requestCount).reduce(0, +), 3)
        XCTAssertEqual(first.newState[conversationID]?.lastServiceTier, .standard)
        assertRollupsMatch(entries: first.entries, seeds: first.conversationSeeds)

        try appendJSONL("""
        {"timestamp":"2026-07-16T00:00:09Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"gpt-5.6-sol","service_tier":"priority"}}}
        {"timestamp":"2026-07-16T00:00:10Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":350,"cached_input_tokens":70,"output_tokens":45,"reasoning_output_tokens":7,"total_tokens":395},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":15,"reasoning_output_tokens":2,"total_tokens":115}}}}
        {"timestamp":"2026-07-16T00:00:11Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":100,"output_tokens":70,"reasoning_output_tokens":10,"total_tokens":570},"last_token_usage":{"input_tokens":150,"cached_input_tokens":30,"output_tokens":25,"reasoning_output_tokens":3,"total_tokens":175}}}}
        """, to: file)

        let second = await CodexJSONLScanner.scan(previous: first.newState, roots: [sessions, archived], indexedTitles: [:])
        XCTAssertEqual(second.entries.count, 1)
        XCTAssertEqual(second.entries.first?.speed, .fast)
        XCTAssertEqual(second.newState[conversationID]?.lastServiceTier, .fast)

        let unchanged = await CodexJSONLScanner.scan(previous: second.newState, roots: [sessions, archived], indexedTitles: [:])
        XCTAssertTrue(unchanged.entries.isEmpty)
        XCTAssertEqual(unchanged.linesParsed, 0)

        let truncated = """
        {"timestamp":"2026-07-16T02:00:00Z","type":"session_meta","payload":{"id":"\(conversationID)","cwd":"/tmp/ccbar-fixture"}}
        {"timestamp":"2026-07-16T02:00:01Z","type":"turn_context","payload":{"model":"gpt-5.6-terra"}}
        {"timestamp":"2026-07-16T02:00:02Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"gpt-5.6-terra","service_tier":"priority"}}}
        {"timestamp":"2026-07-16T02:00:03Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":50,"cached_input_tokens":10,"output_tokens":5,"reasoning_output_tokens":1,"total_tokens":55},"last_token_usage":{"input_tokens":50,"cached_input_tokens":10,"output_tokens":5,"reasoning_output_tokens":1,"total_tokens":55}}}}

        """
        try Data(truncated.utf8).write(to: file, options: [.atomic])

        let afterTruncation = await CodexJSONLScanner.scan(previous: second.newState, roots: [sessions, archived], indexedTitles: [:])
        XCTAssertEqual(afterTruncation.entries.count, 1)
        XCTAssertEqual(afterTruncation.entries.first?.model, "gpt-5.6-terra")
        XCTAssertEqual(afterTruncation.entries.first?.speed, .fast)
        XCTAssertEqual(afterTruncation.newState[conversationID]?.lastModel, "gpt-5.6-terra")
    }

    @MainActor
    func testClaudeFixtureDefersPartialLineDeduplicatesFilesAndResumesByOffset() throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let projects = temporary.appendingPathComponent("projects", isDirectory: true)
        let container = projects.appendingPathComponent("fixture-project", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let mainFile = try copyFixture(
            named: "claude-fast-scan",
            to: container.appendingPathComponent("claude-session.jsonl")
        )
        let duplicateLine = try fixtureLine(named: "claude-fast-scan", containing: "\"msg-standard\"")
        try Data("\(duplicateLine)\n".utf8).write(
            to: container.appendingPathComponent("duplicate.jsonl"),
            options: [.atomic]
        )
        let emptyIndex = ConversationTitleIndex.ClaudeIndex(titles: [:], projects: [:])

        let first = ClaudeJSONLScanner.scan(
            previous: [:],
            seenMessageIds: [],
            root: projects,
            conversationIndex: emptyIndex
        )
        XCTAssertEqual(first.entries.count, 3)
        XCTAssertEqual(first.entries.filter { $0.speed == .standard }.count, 1)
        XCTAssertEqual(first.entries.filter { $0.speed == .fast }.count, 1)
        XCTAssertEqual(first.entries.filter { $0.speed == .unknown }.count, 1)
        XCTAssertFalse(first.newSeenIds.contains("msg-stream"))
        XCTAssertEqual(first.newSeenIds.filter { $0 == "msg-standard" }.count, 1)
        assertRollupsMatch(entries: first.entries, seeds: first.conversationSeeds)

        try appendJSONL(claudeAssistantLine(
            messageID: "msg-stream",
            speed: "fast",
            outputTokens: 40,
            stopReason: "end_turn",
            cacheCreationTokens: 50,
            cacheCreation5mTokens: 20,
            cacheCreation1hTokens: 30,
            sessionID: "claude-fixture-session"
        ), to: mainFile)

        let second = ClaudeJSONLScanner.scan(
            previous: first.newState,
            seenMessageIds: first.newSeenIds,
            root: projects,
            conversationIndex: emptyIndex
        )
        let streamed = try XCTUnwrap(second.entries.first)
        XCTAssertEqual(second.entries.count, 1)
        XCTAssertEqual(streamed.speed, .fast)
        XCTAssertEqual(streamed.cacheCreationTokens, 50)
        XCTAssertEqual(streamed.costBreakdown?.cacheCreation, Decimal(plainString: "0.00085"))
        XCTAssertEqual(second.newSeenIds.filter { $0 == "msg-stream" }.count, 1)

        let unchanged = ClaudeJSONLScanner.scan(
            previous: second.newState,
            seenMessageIds: second.newSeenIds,
            root: projects,
            conversationIndex: emptyIndex
        )
        XCTAssertTrue(unchanged.entries.isEmpty)
        XCTAssertEqual(unchanged.linesParsed, 0)
    }

    /// 落盘 schema 的版本号守卫：任何一处结构变更都必须在这里显式改数，避免忘记 bump
    /// 导致旧缓存与新字段混用（DSH 贡献缓存同样纳入守卫）。
    func testFastCacheSchemaVersionsAreUpgradedTogether() {
        XCTAssertEqual(ScanState.currentVersion, 15)
        XCTAssertEqual(UsageRollupPayload.currentVersion, 10)
        XCTAssertEqual(ConversationRollupPayload.currentVersion, 8)
        XCTAssertEqual(DshContributionPayload.currentVersion, 1)
        XCTAssertEqual(QuotaCyclePayload.currentVersion, 4)
        XCTAssertEqual(CycleUsageRollupPayload.currentVersion, 4)
        XCTAssertEqual(PricingCatalogCachePayload.currentVersion, 2)
        XCTAssertEqual(Pricing.fingerprint(knownUsage: []).count, 64)
    }

    /// 价格变化不再自动失效缓存：指纹漂移时扫描缓存仍然有效。
    /// 缓存目录一律注入临时目录：测试绝不能读写用户真机缓存，删掉 watermark
    /// 会让下一次启动全量重扫 GB 级日志。
    func testScanCacheLoadKeepsStateWhenPricingFingerprintDiffers() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var state = ScanState()
        state.generationID = "gen-fingerprint-drift"
        state.pricingFingerprint = "stale-fingerprint"
        try ScanCache.save(state, in: directory)

        guard case .valid(let loaded) = ScanCache.load(in: directory) else {
            return XCTFail("价格指纹不同不应使扫描缓存失效")
        }
        XCTAssertEqual(loaded.generationID, "gen-fingerprint-drift")
    }

    /// 结构失效路径必须保留：版本不匹配仍然全量重建。
    func testScanCacheLoadStillInvalidatesOnVersionMismatch() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var state = ScanState()
        state.generationID = "gen-version-mismatch"
        state.version = ScanState.currentVersion + 1
        try ScanCache.save(state, in: directory)

        guard case .invalidated = ScanCache.load(in: directory) else {
            return XCTFail("版本不匹配仍必须使扫描缓存失效")
        }
    }

    /// 价格变化不再自动失效缓存：指纹漂移时日聚合 rollup 的桶保留。
    func testUsageRollupCacheLoadKeepsBucketsWhenPricingFingerprintDiffers() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var payload = UsageRollupPayload()
        payload.generationID = "gen-rollup-drift"
        payload.pricingFingerprint = "stale-fingerprint"
        payload.buckets = [
            UsageBucket(
                app: .claude,
                model: "claude-test",
                speed: .standard,
                day: Date(timeIntervalSince1970: 1_788_000_000),
                inputTokens: 10,
                outputTokens: 5,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                costUSD: 0,
                requestCount: 1,
                hasUnpricedUsage: false
            )
        ]
        try UsageRollupCache.save(payload, in: directory)

        let loaded = UsageRollupCache.load(in: directory)
        XCTAssertEqual(loaded.generationID, "gen-rollup-drift")
        XCTAssertEqual(loaded.buckets.count, 1)
    }

    private func codexRoot(
        primarySeconds: Int,
        secondarySeconds: Int?
    ) -> [String: Any] {
        var rate: [String: Any] = [
            "primary_window": [
                "used_percent": 32,
                "limit_window_seconds": primarySeconds,
                "reset_at": 1_800_000_000,
            ],
        ]
        if let secondarySeconds {
            rate["secondary_window"] = [
                "used_percent": 12,
                "limit_window_seconds": secondarySeconds,
                "reset_at": 1_800_100_000,
            ]
        } else {
            rate["secondary_window"] = NSNull()
        }
        return ["plan_type": "plus", "rate_limit": rate]
    }

    private func snapshot(
        kind: QuotaLimitKind,
        usedPercent: Double,
        reset: Date?
    ) -> QuotaSnapshot {
        let seconds: Int?
        switch kind {
        case .fiveHour: seconds = 18_000
        case .weekly, .modelWeekly: seconds = 604_800
        case .unknown: seconds = nil
        }
        let window = QuotaWindow(
            usedPercent: usedPercent,
            resetsAt: reset,
            windowSeconds: seconds
        )
        return QuotaSnapshot(
            app: .codex,
            primaryLimit: .standard(kind: kind, window: window),
            secondaryLimit: nil,
            planType: "plus",
            fetchedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func snapshot(
        fiveHour: Double,
        weekly: Double,
        fiveHourEnd: Date,
        weeklyEnd: Date
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            app: .claude,
            primaryLimit: .standard(
                kind: .fiveHour,
                window: QuotaWindow(usedPercent: fiveHour, resetsAt: fiveHourEnd, windowSeconds: 18_000)
            ),
            secondaryLimit: .standard(
                kind: .weekly,
                window: QuotaWindow(usedPercent: weekly, resetsAt: weeklyEnd, windowSeconds: 604_800)
            ),
            planType: nil,
            fetchedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func cycleRecord(
        id: String,
        accountKey: String,
        app: UsageApp,
        start: Date,
        end: Date,
        usedPercent: Double = 25
    ) -> QuotaCycleRecord {
        QuotaCycleRecord(
            id: id,
            accountKey: accountKey,
            app: app,
            limitID: "weekly",
            limitKind: .weekly,
            startAt: start,
            endAt: end,
            scheduledEndAt: end,
            firstSampleAt: start,
            lastSampleAt: end,
            latestUsedPercent: usedPercent,
            allowanceSegments: [QuotaCycleAllowanceSegment(
                id: "\(id)-allowance",
                startAt: start,
                endAt: nil,
                baselineUsedPercent: 0,
                latestUsedPercent: usedPercent,
                maximumUsedPercent: usedPercent,
                firstSampleAt: start,
                lastSampleAt: end,
                startReason: .initial
            )],
            source: .api,
            boundaryQuality: .observed
        )
    }

    private func claudeAssistantLine(
        messageID: String,
        speed: String?,
        outputTokens: Int = 20,
        stopReason: String? = "end_turn",
        cacheCreationTokens: Int = 40,
        cacheCreation5mTokens: Int? = nil,
        cacheCreation1hTokens: Int? = nil,
        sessionID: String = "session-1"
    ) -> String {
        var usage: [String: Any] = [
            "input_tokens": 100,
            "output_tokens": outputTokens,
            "cache_read_input_tokens": 30,
            "cache_creation_input_tokens": cacheCreationTokens,
        ]
        if let speed { usage["speed"] = speed }
        if cacheCreation5mTokens != nil || cacheCreation1hTokens != nil {
            usage["cache_creation"] = [
                "ephemeral_5m_input_tokens": cacheCreation5mTokens ?? 0,
                "ephemeral_1h_input_tokens": cacheCreation1hTokens ?? 0,
            ]
        }
        var message: [String: Any] = [
            "id": messageID,
            "model": "claude-opus-4-8",
            "usage": usage,
        ]
        if let stopReason { message["stop_reason"] = stopReason }
        let root: [String: Any] = [
            "type": "assistant",
            "sessionId": sessionID,
            "cwd": "/tmp/project",
            "timestamp": "2026-07-16T00:00:00Z",
            "message": message,
        ]
        let data = try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CCBarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func copyFixture(named name: String, to destination: URL) throws -> URL {
        let source = try XCTUnwrap(
            Bundle(for: QuotaParsingTests.self).url(forResource: name, withExtension: "jsonl")
        )
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private func fixtureLine(named name: String, containing needle: String) throws -> String {
        let source = try XCTUnwrap(
            Bundle(for: QuotaParsingTests.self).url(forResource: name, withExtension: "jsonl")
        )
        let text = try String(contentsOf: source, encoding: .utf8)
        return try XCTUnwrap(text.split(separator: "\n").map(String.init).first { $0.contains(needle) })
    }

    private func appendJSONL(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var value = text
        if !value.hasSuffix("\n") { value.append("\n") }
        try handle.write(contentsOf: Data(value.utf8))
    }

    @MainActor
    private func assertRollupsMatch(entries: [UsageEntry], seeds: [ConversationSeed]) {
        let usage = UsageAggregator()
        let conversations = ConversationAggregator()
        usage.ingest(entries)
        conversations.ingest(entries: entries, seeds: seeds)
        let usageBuckets = usage.snapshot()
        let conversationBuckets = conversations.snapshot().buckets

        for app in UsageApp.allCases {
            for model in Set(entries.filter { $0.app == app }.map(\.model)) {
                for speed in UsageSpeed.allCases {
                    let daily = usageBuckets.filter { $0.app == app && $0.model == model && $0.speed == speed }
                    let detail = conversationBuckets.filter { $0.app == app && $0.model == model && $0.speed == speed }
                    XCTAssertEqual(daily.reduce(0) { $0 + $1.inputTokens }, detail.reduce(0) { $0 + $1.inputTokens })
                    XCTAssertEqual(daily.reduce(0) { $0 + $1.outputTokens }, detail.reduce(0) { $0 + $1.outputTokens })
                    XCTAssertEqual(daily.reduce(0) { $0 + $1.cacheReadTokens }, detail.reduce(0) { $0 + $1.cacheReadTokens })
                    XCTAssertEqual(daily.reduce(0) { $0 + $1.cacheCreationTokens }, detail.reduce(0) { $0 + $1.cacheCreationTokens })
                    XCTAssertEqual(daily.reduce(0) { $0 + $1.requestCount }, detail.reduce(0) { $0 + $1.requestCount })
                    let dailyCost = daily.reduce(Decimal.zero) { $0 + $1.costUSD }
                    let conversationCost = detail.reduce(Decimal.zero) { $0 + $1.costUSD }
                    let componentCost = detail.reduce(Decimal.zero) {
                        $0 + $1.inputCostUSD + $1.outputCostUSD + $1.cacheReadCostUSD + $1.cacheCreationCostUSD
                    }
                    XCTAssertEqual(dailyCost, conversationCost)
                    XCTAssertEqual(conversationCost, componentCost)
                }
            }
        }
    }

    private func usageTotals(tokens: Int) -> UsageTotals {
        UsageTotals(
            inputTokens: tokens,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            costUSD: 0,
            requestCount: 1,
            hasUnpricedUsage: false
        )
    }
}
