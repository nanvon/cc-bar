import XCTest
@testable import CCBar

final class QuotaParsingTests: XCTestCase {
    func testCodexNormalResponseKeepsFiveHourPrimaryAndWeeklySecondary() {
        let fetched = CodexQuotaClient.parse(root: codexRoot(
            primarySeconds: 18_000,
            secondarySeconds: 604_800
        ))

        XCTAssertEqual(fetched.snapshot.primaryLimit?.kind, .fiveHour)
        XCTAssertEqual(fetched.snapshot.secondaryLimit?.kind, .weekly)
        XCTAssertEqual(fetched.snapshot.primaryWindow?.remainingPercent, 68)
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

    func testGrokTurnCompletedUsageParsesTokensAndCostTicks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccbar-grok-scan-\(UUID().uuidString)", isDirectory: true)
        let sessionDir = root
            .appendingPathComponent("%2Ftmp%2Fdemo", isDirectory: true)
            .appendingPathComponent("sess-1", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let line: [String: Any] = [
            "timestamp": 1_784_444_600.0,
            "method": "_x.ai/session/update",
            "params": [
                "sessionId": "sess-1",
                "update": [
                    "sessionUpdate": "turn_completed",
                    "prompt_id": "prompt-abc",
                    "stop_reason": "end_turn",
                    "usage": [
                        "inputTokens": 1000,
                        "outputTokens": 100,
                        "cachedReadTokens": 400,
                        "reasoningTokens": 50,
                        "costUsdTicks": 1_500_000_000,
                        "modelUsage": [
                            "grok-4.5": [
                                "inputTokens": 1000,
                                "outputTokens": 100,
                                "cachedReadTokens": 400,
                                "reasoningTokens": 50,
                                "costUsdTicks": 1_500_000_000
                            ]
                        ]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: line)
        var payload = data
        payload.append(contentsOf: [0x0A])
        try payload.write(to: sessionDir.appendingPathComponent("updates.jsonl"))

        let result = GrokJSONLScanner.scan(previous: [:], seenPromptIds: [], root: root)
        XCTAssertEqual(result.entries.count, 1)
        let entry = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(entry.app, .grok)
        XCTAssertEqual(entry.model, "grok-4.5")
        XCTAssertEqual(entry.inputTokens, 600) // 1000 - 400 cache
        XCTAssertEqual(entry.outputTokens, 150) // output + reasoning
        XCTAssertEqual(entry.cacheReadTokens, 400)
        XCTAssertEqual(entry.costUSD, Decimal(string: "1.5"))
        XCTAssertEqual(entry.conversationKey, "grok:sess-1")
        XCTAssertTrue(result.newSeenIds.contains("prompt-abc"))

        // 增量：seen 后不应重复计费
        let again = GrokJSONLScanner.scan(
            previous: result.newState,
            seenPromptIds: result.newSeenIds,
            root: root
        )
        XCTAssertTrue(again.entries.isEmpty)

        try? FileManager.default.removeItem(at: root)
    }

    func testGrokBillingCreditsMapsWeeklyPrimaryAndProductLimits() {
        let root: [String: Any] = [
            "subscriptionTier": "SuperGrok",
            "config": [
                "creditUsagePercent": 42.0,
                "currentPeriod": [
                    "type": "USAGE_PERIOD_TYPE_WEEKLY",
                    "start": "2026-07-27T02:22:31.057371+00:00",
                    "end": "2026-08-03T02:22:31.057371+00:00"
                ],
                "billingPeriodStart": "2026-07-27T02:22:31.057371+00:00",
                "billingPeriodEnd": "2026-08-03T02:22:31.057371+00:00",
                "productUsage": [
                    ["product": "GrokBuild", "usagePercent": 30.0],
                    ["product": "Api", "usagePercent": 12.0],
                    ["product": "GrokChat"]
                ],
                "isUnifiedBillingUser": true
            ]
        ]

        let fetched = GrokQuotaClient.parse(root: root)
        XCTAssertEqual(fetched.snapshot.app, .grok)
        XCTAssertEqual(fetched.snapshot.primaryLimit?.kind, .weekly)
        XCTAssertEqual(fetched.snapshot.primaryWindow?.usedPercent, 42)
        XCTAssertEqual(fetched.snapshot.primaryWindow?.remainingPercent, 58)
        XCTAssertNotNil(fetched.snapshot.primaryWindow?.resetsAt)
        XCTAssertEqual(fetched.snapshot.planType, "SuperGrok")
        XCTAssertEqual(fetched.planType, "SuperGrok")
        XCTAssertEqual(fetched.snapshot.modelLimits.count, 3)
        let names = Set(fetched.snapshot.modelLimits.compactMap(\.displayName))
        XCTAssertTrue(names.contains("Grok Build"))
        XCTAssertTrue(names.contains("API"))
        XCTAssertTrue(names.contains("Grok Chat"))
        let chat = fetched.snapshot.modelLimits.first { $0.displayName == "Grok Chat" }
        XCTAssertEqual(chat?.window.usedPercent, 0)
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
          "geminiWindow": null,
          "geminiWeekly": null,
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

    func testHistoryResetsBaselineWhenPrimaryKindChanges() {
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

        payload = QuotaHistoryStore.record(
            payload: payload,
            accountKey: "codex:primary",
            app: .codex,
            kind: .codexPrimary,
            snapshot: snapshot(kind: .fiveHour, usedPercent: 40, reset: nil),
            sampledAt: start.addingTimeInterval(120)
        )

        XCTAssertTrue(payload.events.isEmpty)
        XCTAssertEqual(payload.lastSamples["codex:primary"]?.limitKind, .fiveHour)
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
    func testCodexFixtureScansTierTransitionsIncrementallyAndAfterTruncation() throws {
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

        let first = CodexJSONLScanner.scan(previous: [:], roots: [sessions, archived], indexedTitles: [:])
        XCTAssertEqual(first.entries.map(\.speed), [.standard, .fast, .standard])
        XCTAssertEqual(first.entries.map(\.requestCount).reduce(0, +), 3)
        XCTAssertEqual(first.newState[conversationID]?.lastServiceTier, .standard)
        assertRollupsMatch(entries: first.entries, seeds: first.conversationSeeds)

        try appendJSONL("""
        {"timestamp":"2026-07-16T00:00:09Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"gpt-5.6-sol","service_tier":"priority"}}}
        {"timestamp":"2026-07-16T00:00:10Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":350,"cached_input_tokens":70,"output_tokens":45,"reasoning_output_tokens":7,"total_tokens":395},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":15,"reasoning_output_tokens":2,"total_tokens":115}}}}
        {"timestamp":"2026-07-16T00:00:11Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":100,"output_tokens":70,"reasoning_output_tokens":10,"total_tokens":570},"last_token_usage":{"input_tokens":150,"cached_input_tokens":30,"output_tokens":25,"reasoning_output_tokens":3,"total_tokens":175}}}}
        """, to: file)

        let second = CodexJSONLScanner.scan(previous: first.newState, roots: [sessions, archived], indexedTitles: [:])
        XCTAssertEqual(second.entries.count, 1)
        XCTAssertEqual(second.entries.first?.speed, .fast)
        XCTAssertEqual(second.newState[conversationID]?.lastServiceTier, .fast)

        let unchanged = CodexJSONLScanner.scan(previous: second.newState, roots: [sessions, archived], indexedTitles: [:])
        XCTAssertTrue(unchanged.entries.isEmpty)
        XCTAssertEqual(unchanged.linesParsed, 0)

        let truncated = """
        {"timestamp":"2026-07-16T02:00:00Z","type":"session_meta","payload":{"id":"\(conversationID)","cwd":"/tmp/ccbar-fixture"}}
        {"timestamp":"2026-07-16T02:00:01Z","type":"turn_context","payload":{"model":"gpt-5.6-terra"}}
        {"timestamp":"2026-07-16T02:00:02Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"gpt-5.6-terra","service_tier":"priority"}}}
        {"timestamp":"2026-07-16T02:00:03Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":50,"cached_input_tokens":10,"output_tokens":5,"reasoning_output_tokens":1,"total_tokens":55},"last_token_usage":{"input_tokens":50,"cached_input_tokens":10,"output_tokens":5,"reasoning_output_tokens":1,"total_tokens":55}}}}

        """
        try Data(truncated.utf8).write(to: file, options: [.atomic])

        let afterTruncation = CodexJSONLScanner.scan(previous: second.newState, roots: [sessions, archived], indexedTitles: [:])
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
        XCTAssertEqual(streamed.costBreakdown?.cacheCreation, 0.00085)
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

    func testFastCacheSchemaVersionsAreUpgradedTogether() {
        XCTAssertEqual(ScanState.currentVersion, 9)
        XCTAssertEqual(UsageRollupPayload.currentVersion, 8)
        XCTAssertEqual(ConversationRollupPayload.currentVersion, 5)
        XCTAssertEqual(Pricing.fingerprint(knownModels: []).count, 64)
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
                    XCTAssertEqual(daily.reduce(Decimal.zero) { $0 + $1.costUSD }, detail.reduce(Decimal.zero) { $0 + $1.costUSD })
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
